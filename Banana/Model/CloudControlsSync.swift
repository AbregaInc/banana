import CloudKit
import Foundation
import os

/// Routines, one-off alarms, wake sounds and each show's settings, the same on every device
/// (docs/design/ADAPTIVE-LAYOUT.md, rule 5). Change one on the iPhone, the iPad or the Mac and it
/// changes on all of them; the phone then does what only it can — arming alarms, sending a show's
/// episodes to the Watch.
///
/// One small record per item, in its own zone, so a routine edited on the Mac and an alarm added on
/// the phone never overwrite each other. The rules:
/// - The newer *edit* wins, by the edit time inside each record (`ControlEnvelope`).
/// - A delete is a record too (a tombstone) with its own time, so it beats an older edit and loses
///   to a newer one, on every device, whatever order they sync in.
/// - Every device offers everything it has once per kind, so what was made on the Mac reaches the
///   phone as much as the other way round. The exception is the lists every install starts with
///   defaults of (`ControlKind.adoptsPhoneSet`): only the phone offers those, and an iPad or Mac
///   takes the phone's set, so default routines — or one deleted on the phone — can't come back.
///
/// Two instances, one per zone (`ControlChannel`): `shared` for everything above, `meals` for the
/// meal backlog — small and made of stores that need no window, so the iPhone can start it at
/// launch and fetch it alone when a push or a background task wakes it (`MealBacklogWake`).
/// Changes are fetched on coming to the front and while open (`CloudSyncPoll`); edits go up within
/// seconds.
@MainActor
final class CloudControlsSync: NSObject, CKSyncEngineDelegate {
    static let shared = CloudControlsSync(channel: .controls)
    static let meals = CloudControlsSync(channel: .meals)

    /// The instance a kind's changes go to.
    static func owner(of kind: ControlKind) -> CloudControlsSync {
        kind.channel == .meals ? meals : shared
    }

    let channel: ControlChannel
    private let log = Logger(subsystem: "com.boris.banana", category: "cloudcontrols")
    private lazy var container = CKContainer(identifier: AppCloud.containerID)
    /// The record type the other zones use, which production's schema already has; the envelope
    /// goes in `payload`. A new type would need a schema deployment first.
    private static let recordType = "SettingsSnapshot"
    private var stateKey: String { "ckSyncEngine.\(channel.rawValue).state" }
    private var domain: SyncDomain { channel == .meals ? .meals : .controls }

    private struct WeakSource {
        weak var source: CloudControlSource?
    }

    private var engine: CKSyncEngine?
    /// Fetches what changed on other devices — the engine only would on a push (`CloudZonePoller`).
    private var poller: CloudZonePoller?
    private var sources: [ControlKind: WeakSource] = [:]
    private var state = SyncState()
    private var systemFields: [String: Data] = [:]
    private var systemFieldsChanged = false
    private var lastZoneReset: Date?
    /// True while a store applies another device's version, so its own report is ignored.
    private var applyingRemote = false
    /// The ids of each kind seen in the fetch under way — on an iPad or Mac, what the phone's set is.
    private var fetchSeen: [ControlKind: Set<String>] = [:]
    /// Set while reading everything again on purpose: the fresh engine's "signed in" event is then
    /// not a new account, and nothing needs re-offering for it.
    private var deliberateRefetch = false

    private struct SyncState: Codable {
        /// When this device's copy of each record was last edited — here, or where it came from.
        var revisions: [String: Date] = [:]
        /// Edited here, and CloudKit hasn't yet confirmed saving that edit.
        var dirty: Set<String> = []
        /// Deleted: here, or on the device whose delete was the newest edit.
        var tombstones: Set<String> = []
        /// The phone: whether it has offered everything once (before kinds were seeded one by one).
        var seeded = false
        /// The kinds this device has offered everything of once.
        var seededKinds: Set<String> = []
        /// The item id behind a record name that had to be hashed (`ControlKind.safeID`).
        var keys: [String: String] = [:]
        /// An iPad or Mac: what it had of each kind before it first synced, until it takes the
        /// phone's set in place of it. Nil until recorded.
        var legacy: [String: Set<String>]?
        /// An iPad or Mac: the kinds whose set it has taken from the phone.
        var adopted: Set<String> = []

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            revisions = try c.decodeIfPresent([String: Date].self, forKey: .revisions) ?? [:]
            dirty = try c.decodeIfPresent(Set<String>.self, forKey: .dirty) ?? []
            tombstones = try c.decodeIfPresent(Set<String>.self, forKey: .tombstones) ?? []
            seeded = try c.decodeIfPresent(Bool.self, forKey: .seeded) ?? false
            seededKinds = try c.decodeIfPresent(Set<String>.self, forKey: .seededKinds) ?? []
            keys = try c.decodeIfPresent([String: String].self, forKey: .keys) ?? [:]
            legacy = try c.decodeIfPresent([String: Set<String>].self, forKey: .legacy)
            adopted = try c.decodeIfPresent(Set<String>.self, forKey: .adopted) ?? []
        }
    }

    private var stateURL: URL { AppSupport.directory.appendingPathComponent("cloud-\(channel.rawValue)-sync.plist") }
    private var systemFieldsURL: URL { AppSupport.directory.appendingPathComponent("cloud-\(channel.rawValue)-fields.plist") }

    /// Off without iCloud, in the Simulator, and in an unentitled local Mac build.
    private static let isAvailable: Bool = {
        #if targetEnvironment(simulator)
        return false
        #else
        return !ProcessInfo.processInfo.arguments.contains("--disable-icloud") && AppCloud.hasContainerEntitlement
        #endif
    }()

    private init(channel: ControlChannel) {
        self.channel = channel
        super.init()
        if Self.isAvailable { loadFromDisk() }
    }

    var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: channel.zoneName) }

    // MARK: - The move off iCloud (`LegacyCloud`)

    /// A kind's mode: this zone carries personal kinds and health ones (`LegacyInventory`).
    private func mode(_ kind: ControlKind) -> LegacyCloudMode {
        LegacyCloud.mode(LegacyInventory.tier(ofControlKind: kind.rawValue))
    }
    private func writes(_ kind: ControlKind) -> Bool { mode(kind).writes }
    private func writes(name: String) -> Bool { ControlKind.parse(name).map { writes($0.kind) } ?? false }
    /// Some kind of this zone still writes iCloud / still reads it.
    private var anyWrites: Bool { channel.kinds.contains { writes($0) } }
    private var anyReads: Bool { channel.kinds.contains { mode($0).reads } }
    /// What no longer writes leaves the engine's queue, the zone save with it once nothing writes:
    /// after a mode change, and after an engine is made from a saved state (which keeps what was
    /// queued then). Sends are also refused batch by batch, so nothing queued can go up anyway.
    private func dropUnwritable(_ engine: CKSyncEngine) -> Int {
        let stopped = engine.state.pendingRecordZoneChanges.filter { change in
            guard case .saveRecord(let id) = change else { return true }   // nothing here deletes records
            return !writes(name: id.recordName)
        }
        engine.state.remove(pendingRecordZoneChanges: stopped)
        if !anyWrites { engine.state.remove(pendingDatabaseChanges: engine.state.pendingDatabaseChanges) }
        return stopped.count
    }

    /// The modes changed (`LegacyCloud.set`): what no longer writes leaves the queue. The engine
    /// stays as it is (made again, it would bring back what it had queued). With every kind off,
    /// the engine and the poller go.
    func modeChanged() {
        guard Self.isAvailable, let engine else { return }
        guard anyReads else {
            self.engine = nil
            poller = nil
            log.notice("\(self.channel.rawValue, privacy: .public) cloudsync off: every device has moved")
            return
        }
        let stopped = dropUnwritable(engine)
        log.notice("\(self.channel.rawValue, privacy: .public) cloudsync mode changed; \(stopped) unsent change(s) dropped")
    }

    /// The move's complete fetch (`LegacyChannel.drainToEnd`): while the zone still writes, what
    /// waits goes up first; then everything since the last poll is read to the end, through the
    /// usual merge. Deletes here are tombstones, so nothing is absent for being missing.
    func drainToEnd() async throws -> DrainResult {
        // No iCloud for this build (the Simulator, unentitled, turned off): nothing was ever here.
        guard Self.isAvailable else { return DrainResult() }
        guard let engine, let poller else {
            if !anyReads { return DrainResult() }   // off: done
            throw LegacyDrainError.notRunning("\(channel.rawValue) zone")
        }
        if anyWrites {
            do { try await engine.sendChanges(.init(scope: .zoneIDs([zoneID]))) } catch {
                log.notice("\(self.channel.rawValue, privacy: .public) drain: send deferred: \(error.localizedDescription, privacy: .public)")
            }
        }
        SyncProgress.shared.willFetch(domain)
        defer { SyncProgress.shared.didFetch(domain) }
        _ = try await poller.drainToEnd(listing: false)
        return ControlDrain.result(dirty: state.dirty, tombstones: state.tombstones, keys: state.keys)
    }
    /// Started, with somewhere to fetch from.
    var isRunning: Bool { engine != nil }
    private func recordID(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name, zoneID: zoneID) }
    private var fetchOptions: CKSyncEngine.FetchChangesOptions { .init(scope: .zoneIDs([zoneID])) }

    // MARK: - Lifecycle

    func register(_ source: CloudControlSource, for kind: ControlKind) {
        sources[kind] = WeakSource(source: source)
    }

    private func itemIDs(_ kind: ControlKind) -> [String] {
        sources[kind]?.source?.cloudItemIDs(kind) ?? []
    }

    /// The record for `id`, remembering the id when its name had to be hashed.
    private func name(_ kind: ControlKind, _ id: String) -> String {
        let name = kind.recordName(id)
        if ControlKind.safeID(id) != id { state.keys[name] = id }
        return name
    }

    /// The store's id for a record: the one remembered for a hashed name, or the name's own.
    private func itemID(forName name: String, parsed: String) -> String { state.keys[name] ?? parsed }

    /// After every store is registered and loaded — an empty list mid-decode is not the phone's set.
    func start() {
        guard engine == nil, Self.isAvailable, anyReads else { return }
        let isHub = DeviceRole.current.isHub
        // Before kinds were seeded one by one, the phone seeded the first four together.
        if state.seeded, state.seededKinds.isEmpty {
            state.seededKinds = [ControlKind.routine, .alarm, .wake, .podcast].map(\.rawValue).reduce(into: []) { $0.insert($1) }
        }
        for kind in channel.kinds where !state.seededKinds.contains(kind.rawValue) {
            // The lists every install starts with defaults of are the phone's to offer.
            guard isHub || !kind.adoptsPhoneSet else { continue }
            guard sources[kind]?.source != nil else { continue }   // not registered on this platform
            guard writes(kind) else { continue }   // moved off iCloud: nothing to offer there
            for id in itemIDs(kind) {
                let name = name(kind, id)
                if state.revisions[name] == nil { state.revisions[name] = ControlEnvelope.unedited }
                state.dirty.insert(name)
            }
            state.seededKinds.insert(kind.rawValue)
        }
        // Show settings an earlier build counted as applied though their show wasn't here: not
        // applied, so a later read of everything (once the show arrives) must apply them.
        let showsHere = Set(itemIDs(.podcast))
        if sources[.podcast]?.source != nil {
            for name in state.revisions.keys where name.hasPrefix(ControlKind.podcast.rawValue + "-") {
                guard let parsed = ControlKind.parse(name), parsed.kind == .podcast,
                      !showsHere.contains(itemID(forName: name, parsed: parsed.id)),
                      !state.tombstones.contains(name), !state.dirty.contains(name) else { continue }
                state.revisions[name] = nil
            }
        }
        if !isHub, state.legacy == nil {
            var legacy: [String: Set<String>] = [:]
            for kind in channel.kinds where kind.adoptsPhoneSet {
                legacy[kind.rawValue] = Set(itemIDs(kind))
            }
            state.legacy = legacy
        }
        saveState()
        let serialized = UserDefaults.standard.data(forKey: stateKey)
            .flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        makeEngine(serialized: serialized)
        poller = CloudZonePoller(database: container.privateCloudDatabase, zoneName: channel.zoneName,
                                 tokenKey: "zonePoll.\(channel.rawValue)",
                                 backgroundOK: channel == .meals) { [weak self] records, deletions in
            self?.ingestPolled(records, deletions)
        }
        SyncProgress.shared.started(domain)
        queuePending()
        log.notice("\(self.channel.rawValue, privacy: .public) cloudsync started; \(self.state.dirty.count) to send")
        exchangeSoon()
        pollNow()
    }

    private func makeEngine(serialized: CKSyncEngine.State.Serialization?) {
        var config = CKSyncEngine.Configuration(database: container.privateCloudDatabase,
                                                stateSerialization: serialized, delegate: self)
        // Read-only (the move off iCloud): no sending on its own; fetches are asked for.
        config.automaticallySync = anyWrites
        let made = CKSyncEngine(config)
        engine = made
        _ = dropUnwritable(made)
    }

    private func queuePending() {
        guard let engine, anyWrites else { return }
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        engine.state.add(pendingRecordZoneChanges: state.dirty.filter { writes(name: $0) }.map { .saveRecord(recordID($0)) })
    }

    /// Read every record again from the start — once shows have arrived here, so their settings,
    /// which may have come before them and couldn't be applied then, are. Nothing is re-sent.
    func refetchAll() {
        guard engine != nil else { return }
        deliberateRefetch = true
        UserDefaults.standard.removeObject(forKey: stateKey)
        makeEngine(serialized: nil)
        queuePending()
        log.notice("controls cloudsync reading everything again")
        exchangeSoon()
        poller?.startOver()
        pollNow()
    }

    /// Whether a poll is due: its zone changed (nil: couldn't tell), or its first read isn't done.
    func needsRefresh(changedZones: Set<String>?) -> Bool {
        guard let poller else { return false }
        return changedZones.map { $0.contains(channel.zoneName) } ?? true || !poller.caughtUp
    }

    /// Pull now — when the app comes to the front, and every minute while it's open.
    func refresh() {
        guard let engine else { return }
        let options = fetchOptions
        Task { try? await engine.fetchChanges(options) }
        pollNow()
    }

    private func pollNow() {
        Task { @MainActor in await fetchNow() }
    }

    /// Fetches what changed elsewhere and waits for it — for a push or a background task, which
    /// have to finish before the app is suspended again.
    func fetchNow() async {
        guard let poller else { return }
        SyncProgress.shared.willFetch(domain)
        await poller.poll()
        SyncProgress.shared.didFetch(domain)
    }

    /// Records the poller fetched, through the same merge as the engine's own.
    private func ingestPolled(_ records: [CKRecord], _ deletions: [CKRecord.ID]) {
        guard let engine else { return }
        for record in records where record.recordID.zoneID == zoneID {
            incoming(record, engine: engine)
        }
        for id in deletions where id.zoneID == zoneID {
            if systemFields.removeValue(forKey: id.recordName) != nil { systemFieldsChanged = true }
        }
        SyncProgress.shared.received(domain, count: records.count)
        adoptPhoneSets()
        saveState()
        saveSystemFields()
    }

    private func exchangeSoon() {
        Task { @MainActor [weak self] in
            for delay in [0, 5] {
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard let self, let engine = self.engine else { return }
                do {
                    if self.anyWrites { try await engine.sendChanges(.init(scope: .zoneIDs([self.zoneID]))) }
                    try await engine.fetchChanges(self.fetchOptions)
                    return
                } catch {
                    self.log.notice("\(self.channel.rawValue, privacy: .public) cloudsync exchange deferred: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    // MARK: - Local changes (called by the stores)

    fileprivate func editedAt(_ kind: ControlKind, id: String) -> Date? {
        state.revisions[kind.recordName(id)]
    }

    func changed(_ kind: ControlKind, id: String) { mark(kind, id: id, deleted: false) }

    func deleted(_ kind: ControlKind, id: String) { mark(kind, id: id, deleted: true) }

    /// Found here, maybe already made elsewhere (`ControlChangeReporter.offered`): it goes up as
    /// unedited, so anything another device actually did to it wins.
    func offered(_ kind: ControlKind, id: String) {
        guard Self.isAvailable, !applyingRemote, !ControlChangeReporter.isApplyingFromSpace, writes(kind) else { return }
        let name = name(kind, id)
        guard state.revisions[name] == nil else { return }   // already known here: nothing to offer
        state.revisions[name] = ControlEnvelope.unedited
        state.dirty.insert(name)
        state.tombstones.remove(name)
        saveState()
        engine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID(name))])
    }

    private func mark(_ kind: ControlKind, id: String, deleted: Bool) {
        // The data platform's records, and the account-change clear, are nothing for this sync.
        guard Self.isAvailable, !applyingRemote, !ControlChangeReporter.isApplyingFromSpace else { return }
        let name = name(kind, id)
        // Read-only, the edit time and the delete are still kept: they stop an older copy from an
        // old build undoing this edit. Nothing is sent (batches skip what doesn't write), but it
        // stays dirty, so the move's drain hands it over: a delete made here before the seed.
        state.revisions[name] = Date()
        state.dirty.insert(name)
        if deleted { state.tombstones.insert(name) } else { state.tombstones.remove(name) }
        // Touched here since syncing began: it's this device's edit now, not a leftover.
        state.legacy?[kind.rawValue]?.remove(id)
        saveState()
        guard writes(kind) else { return }
        engine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID(name))])
    }

    @discardableResult
    private func apply(_ kind: ControlKind, id: String, item: Data?) -> Bool {
        applyingRemote = true
        defer { applyingRemote = false }
        // Not registered on this platform (the Mac has no alarms to arm, say): nothing to do, and
        // nothing to retry.
        guard let source = sources[kind]?.source else { return true }
        return LegacyCloud.applyingFromCloud {
            let applied = source.applyCloud(kind, id: id, item: item)
            // An item from an old build, after this device moved: a late arrival for the data
            // platform, any kind (`MoveOver.changed` tells it from an edit made here). The
            // store's own report meanwhile doesn't go to it as well (`ControlsAdapter.ownReport`).
            if applied { ControlsAdapter.legacyApplied(kind, id: id, deleted: item == nil) }
            return applied
        }
    }

    // MARK: - CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard syncEngine === engine else { return }
        switch event {
        case .stateUpdate(let event):
            if let data = try? JSONEncoder().encode(event.stateSerialization) {
                UserDefaults.standard.set(data, forKey: stateKey)
            }
        case .accountChange(let event):
            accountChanged(event)
        case .fetchedDatabaseChanges(let event):
            if event.deletions.contains(where: { $0.zoneID == zoneID }) {
                zoneWasReset("the \(channel.zoneName) zone was deleted in iCloud")
            }
        case .willFetchChanges:
            fetchSeen = [:]
            SyncProgress.shared.willFetch(domain)
        case .fetchedRecordZoneChanges(let event):
            for modification in event.modifications where modification.record.recordID.zoneID == zoneID {
                incoming(modification.record, engine: syncEngine)
            }
            SyncProgress.shared.received(domain, count: event.modifications.count)
            // Nothing here deletes records (deletes are tombstones), so a record gone from the
            // server went with a reset; its system fields are all that's stale.
            for deletion in event.deletions where deletion.recordID.zoneID == zoneID {
                if systemFields.removeValue(forKey: deletion.recordID.recordName) != nil { systemFieldsChanged = true }
            }
            saveState()
            saveSystemFields()
        case .didFetchChanges:
            adoptPhoneSets()
            SyncProgress.shared.didFetch(domain)
        case .sentRecordZoneChanges(let event):
            sent(event, engine: syncEngine)
            saveState()
            saveSystemFields()
        default:
            break
        }
    }

    func nextFetchChangesOptions(_ context: CKSyncEngine.FetchChangesContext,
                                 syncEngine: CKSyncEngine) async -> CKSyncEngine.FetchChangesOptions {
        var options = context.options
        options.scope = .zoneIDs([zoneID])
        return options
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                   syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard syncEngine === engine else { return nil }
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        guard !pending.isEmpty else { return nil }
        // Which items still exist, by kind — cheap (ids only). The items themselves are encoded one
        // at a time below, as the batch fills: a first sync offers thousands of listening sessions
        // and megabytes of transcripts, and a batch only takes what fits in one request.
        var present: [ControlKind: Set<String>] = [:]
        var gone: [CKSyncEngine.PendingRecordZoneChange] = []
        var changes: [CKSyncEngine.PendingRecordZoneChange] = []
        for change in pending {
            // Nothing here deletes records; an old queued delete has nothing to do.
            guard case .saveRecord(let id) = change, let parsed = ControlKind.parse(id.recordName) else {
                gone.append(change)
                continue
            }
            let name = id.recordName
            // Moved off iCloud since it was queued: it stays here.
            guard writes(parsed.kind) else {
                gone.append(change)
                continue
            }
            if !state.tombstones.contains(name) {
                if present[parsed.kind] == nil { present[parsed.kind] = Set(itemIDs(parsed.kind)) }
                guard present[parsed.kind]?.contains(itemID(forName: name, parsed: parsed.id)) == true else {
                    // Gone here without a delete being recorded (a restore, an expired alarm):
                    // nothing to send, and nothing to delete everywhere else either.
                    gone.append(change)
                    state.dirty.remove(name)
                    continue
                }
            }
            changes.append(change)
        }
        if !gone.isEmpty {
            syncEngine.state.remove(pendingRecordZoneChanges: gone)
            saveState()
        }
        guard !changes.isEmpty else { return nil }
        let fields = systemFields
        let recordType = Self.recordType
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { [weak self] id in
            guard let payload = await self?.payload(forName: id.recordName) else { return nil }
            let record = fields[id.recordName].flatMap(Self.record(fromSystemFields:))
                ?? CKRecord(recordType: recordType, recordID: id)
            record["payload"] = payload as CKRecordValue
            return record
        }
    }

    /// One record's payload, encoded now. Nil for an item that's gone, or too big for a record.
    private func payload(forName name: String) -> Data? {
        guard let parsed = ControlKind.parse(name) else { return nil }
        let id = itemID(forName: name, parsed: parsed.id)
        let hashedKey = ControlKind.safeID(id) == id ? nil : id
        let editedAt = state.revisions[name] ?? ControlEnvelope.unedited
        let envelope: ControlEnvelope
        if state.tombstones.contains(name) {
            envelope = .tombstone(at: editedAt, key: hashedKey)
        } else {
            guard let item = sources[parsed.kind]?.source?.cloudItem(parsed.kind, id: id) else { return nil }
            envelope = .edit(item, at: editedAt, key: hashedKey)
        }
        guard let data = try? JSONEncoder().encode(envelope) else { return nil }
        guard data.count <= ControlEnvelope.largestPayload else {
            // Too big for one record even compressed. Leave it out rather than fail every batch.
            log.error("control record too big to sync (\(data.count) bytes): \(name, privacy: .public)")
            state.dirty.remove(name)
            engine?.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID(name))])
            saveState()
            return nil
        }
        return data
    }

    // MARK: - Records

    /// Another device's copy: take it if it's the newer edit; if ours is newer, send ours again.
    private func incoming(_ record: CKRecord, engine: CKSyncEngine) {
        let name = record.recordID.recordName
        guard let parsed = ControlKind.parse(name) else {
            log.error("unrecognised control record ignored: \(name, privacy: .public)")
            return
        }
        let kind = parsed.kind
        // Another zone's kind (a record from before the meal backlog had its own): not ours.
        guard kind.channel == channel else { return }
        // Off: every device has moved; nothing more comes in.
        guard mode(kind).reads else { return }
        storeSystemFields(record)
        guard let data = record["payload"] as? Data,
              let envelope = try? JSONDecoder().decode(ControlEnvelope.self, from: data) else {
            log.error("control record payload failed to decode: \(name, privacy: .public)")
            return
        }
        // A hashed name's item id travels in the record.
        let id = envelope.key ?? itemID(forName: name, parsed: parsed.id)
        if envelope.key != nil { state.keys[name] = id }
        fetchSeen[kind, default: []].insert(id)
        let local = state.revisions[name]
        if ControlMerge.remoteWins(remote: envelope.editedAt, local: local) {
            let item = envelope.deleted ? nil : envelope.unpackedItem
            if !envelope.deleted, item == nil {
                log.error("control record item failed to unpack: \(name, privacy: .public)")
                return
            }
            // Not applicable yet (settings for a show that isn't here): not counted as seen, so
            // reading everything again once the show arrives applies it.
            guard apply(kind, id: id, item: item) else { return }
            state.revisions[name] = envelope.editedAt
            state.dirty.remove(name)
            if envelope.deleted { state.tombstones.insert(name) } else { state.tombstones.remove(name) }
            state.legacy?[kind.rawValue]?.remove(id)
            engine.state.remove(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
        } else if let local, local > envelope.editedAt, !state.dirty.contains(name), writes(kind) {
            state.dirty.insert(name)
            engine.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
        }
    }

    /// An iPad or Mac, once the phone's set of a kind has arrived: drop what it had of its own
    /// that the phone doesn't (`ControlMerge.localOnly`).
    private func adoptPhoneSets() {
        defer { fetchSeen = [:] }
        guard !DeviceRole.current.isHub, var legacy = state.legacy else { return }
        var changed = false
        for kind in channel.kinds where kind.adoptsPhoneSet && !state.adopted.contains(kind.rawValue) {
            let seen = fetchSeen[kind] ?? []
            guard !seen.isEmpty else { continue }   // the phone hasn't published this kind yet
            let drop = ControlMerge.localOnly(local: legacy[kind.rawValue] ?? [], server: seen)
            for id in drop { apply(kind, id: id, item: nil) }
            state.adopted.insert(kind.rawValue)
            legacy[kind.rawValue] = nil
            changed = true
            log.notice("controls cloudsync took the phone's \(kind.rawValue, privacy: .public) set; dropped \(drop.count) of this device's own")
        }
        guard changed else { return }
        state.legacy = legacy
        saveState()
    }

    private func sent(_ event: CKSyncEngine.Event.SentRecordZoneChanges, engine: CKSyncEngine) {
        var zoneMissing = false
        for record in event.savedRecords {
            let name = record.recordID.recordName
            storeSystemFields(record)
            // Only clean if what went up is the latest edit: an older upload finishing while a
            // newer edit waits must not mark the newer one sent.
            let sentAt = (record["payload"] as? Data)
                .flatMap { try? JSONDecoder().decode(ControlEnvelope.self, from: $0) }?.editedAt
            if let sentAt, sentAt >= (state.revisions[name] ?? ControlEnvelope.unedited) {
                state.dirty.remove(name)
            }
        }
        for failed in event.failedRecordSaves {
            let id = failed.record.recordID
            switch failed.error.code {
            case .serverRecordChanged:
                // Saved elsewhere first: `incoming` takes theirs if newer, or re-sends ours on top
                // of the server's record (whose system fields it keeps).
                if let server = failed.error.serverRecord { incoming(server, engine: engine) }
            case .zoneNotFound, .userDeletedZone:
                zoneMissing = true
            case .unknownItem:
                // The record went with a reset; make it afresh.
                if systemFields.removeValue(forKey: id.recordName) != nil { systemFieldsChanged = true }
                if writes(name: id.recordName) { engine.state.add(pendingRecordZoneChanges: [.saveRecord(id)]) }
            default:
                log.error("control save failed for \(id.recordName, privacy: .public): \(failed.error.localizedDescription, privacy: .public)")
            }
        }
        if zoneMissing { zoneWasReset("the \(channel.zoneName) zone was missing on save") }
    }

    /// Everything this device should have up there: what it has (not its pre-sync leftovers) and
    /// every delete it knows of.
    private func everythingToOffer() -> Set<String> {
        var names = state.tombstones.filter { writes(name: $0) }
        for kind in channel.kinds where writes(kind) {
            let leftovers = state.legacy?[kind.rawValue] ?? []
            for id in itemIDs(kind) where !leftovers.contains(id) {
                names.insert(name(kind, id))
            }
        }
        return names
    }

    private func zoneWasReset(_ reason: String) {
        // Nothing of this zone writes iCloud any more: it isn't made again.
        guard let engine, anyWrites else { return }
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        if let lastZoneReset, Date().timeIntervalSince(lastZoneReset) < 60 { return }
        lastZoneReset = Date()
        log.notice("\(self.channel.rawValue, privacy: .public) cloudsync re-offering everything: \(reason, privacy: .public)")
        systemFields.removeAll()
        systemFieldsChanged = true
        state.dirty.formUnion(everythingToOffer())
        saveState()
        saveSystemFields()
        engine.state.add(pendingRecordZoneChanges: state.dirty.map { .saveRecord(recordID($0)) })
    }

    private func accountChanged(_ event: CKSyncEngine.Event.AccountChange) {
        log.notice("\(self.channel.rawValue, privacy: .public) cloudsync account change: \(String(describing: event.changeType), privacy: .public)")
        // A fresh engine reading everything again reports "signed in" — the same account.
        if deliberateRefetch, case .signIn = event.changeType {
            deliberateRefetch = false
            return
        }
        systemFields.removeAll()
        systemFieldsChanged = true
        switch event.changeType {
        case .signIn, .switchAccounts:
            state.dirty.formUnion(everythingToOffer())
            saveState()
            queuePending()
        case .signOut:
            break
        @unknown default:
            break
        }
        saveSystemFields()
    }

    // MARK: - System fields

    private func storeSystemFields(_ record: CKRecord) {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        systemFields[record.recordID.recordName] = archiver.encodedData
        systemFieldsChanged = true
    }

    private nonisolated static func record(fromSystemFields data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        let record = CKRecord(coder: coder)
        coder.finishDecoding()
        return record
    }

    // MARK: - Files

    private func loadFromDisk() {
        if let data = try? Data(contentsOf: stateURL) {
            do {
                state = try PropertyListDecoder().decode(SyncState.self, from: data)
            } catch {
                log.fault("\(self.channel.rawValue, privacy: .public) sync state unreadable, starting over: \(error.localizedDescription, privacy: .public)")
            }
        }
        if let data = try? Data(contentsOf: systemFieldsURL),
           let decoded = try? PropertyListDecoder().decode([String: Data].self, from: data) {
            systemFields = decoded
        }
    }

    private func saveState() {
        guard Self.isAvailable else { return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    private func saveSystemFields() {
        guard Self.isAvailable, systemFieldsChanged else { return }
        systemFieldsChanged = false
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(systemFields) else { return }
        try? data.write(to: systemFieldsURL, options: .atomic)
    }
}

extension ControlChangeReporter {
    /// Points every store's reports at the sync, and the personal kinds' at the move off iCloud
    /// too (`MoveOver`, which does nothing until its engine runs; health and food join it in
    /// `alsoReportHealthToSpace`): the legacy sync decides by its mode whether it still writes
    /// iCloud. Called once at launch, before anything can change.
    static func connectToCloud() {
        changed = { kind, id in
            CloudControlsSync.owner(of: kind).changed(kind, id: id)
            if let type = ControlsAdapter.ownReport(kind, id: id) { MoveOver.changed(type: type, ids: [id]) }
        }
        deleted = { kind, id in
            CloudControlsSync.owner(of: kind).deleted(kind, id: id)
            // A route goes with its listen; on its own it's not a deleted listen.
            if kind != .listenRoute, let type = ControlsAdapter.ownReport(kind, id: id) { MoveOver.deleted(type: type, ids: [id]) }
        }
        offered = { kind, id in
            CloudControlsSync.owner(of: kind).offered(kind, id: id)
            if let type = ControlsAdapter.ownReport(kind, id: id) { MoveOver.offered(type: type, ids: [id]) }
        }
    }
}

extension CloudControlsSync {
    /// An item's last edit as this sync knows it (here, or on the device it came from): its seed
    /// clock (docs/design/DATA-PLATFORM.md §3 seeding rule 3). Nil when it has none.
    static func editedAt(_ kind: ControlKind, id: String) -> Date? {
        owner(of: kind).editedAt(kind, id: id)
    }
}

