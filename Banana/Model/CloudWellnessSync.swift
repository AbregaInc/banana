import CloudKit
import Foundation
import os

/// Meals, supplements and doses between the phone and the Mac, over CloudKit — so what you log
/// on one shows up on the other. Before this, `wellness.json` never left the phone except inside
/// a manual iCloud backup, which is why the Mac had no Nutrition page.
///
/// One record per item in its own zone; the local file stays the source of truth. The rules:
/// - The newer *edit* wins, by the edit time carried inside each record (`WellnessCloudEnvelope`),
///   not by when a copy happened to reach the server.
/// - Only an explicit delete removes anything; an item missing from the cloud is never removed
///   for being missing.
/// - A delete made here stays remembered until CloudKit confirms it, so nothing in between — a
///   fetch, a conflict, an iCloud sign-out and back — can bring the item back.
/// - This device's history is offered once; after that only edits go up. An old item without a
///   cloud copy (restored from a backup, say) is never re-uploaded just for lacking one.
///
/// The record naming, the conflict rule and the merge are pure (`WellnessCloudRecords.swift`)
/// and tested there.
@MainActor
final class CloudWellnessSync: NSObject, CKSyncEngineDelegate {
    static let shared = CloudWellnessSync()

    private let log = Logger(subsystem: "com.boris.banana", category: "cloudwellness")
    private lazy var container = CKContainer(identifier: AppCloud.containerID)
    private static let zoneName = "Wellness"
    /// The record type the Fitness zone already uses, which production's schema has, with the
    /// item as JSON in `payload`. A new type would need a schema deployment before the first
    /// save could land.
    private static let recordType = "SettingsSnapshot"
    private static let stateKey = "ckSyncEngine.wellness.state"

    private var engine: CKSyncEngine?
    /// Fetches what changed on other devices — the engine only would on a push (`CloudZonePoller`).
    private var poller: CloudZonePoller?
    private weak var wellness: WellnessStore?
    private var state = SyncState()
    /// CloudKit's system fields per record, so an edit updates the record rather than colliding
    /// with it. Large (thousands of records), so written once per batch rather than per change:
    /// losing some costs only an extra conflict round trip.
    private var systemFields: [String: Data] = [:]
    private var systemFieldsChanged = false
    private var lastZoneReset: Date?

    /// What this device knows about each record. Small, and written the moment it changes: a lost
    /// dirty mark is a lost edit, and a lost pending delete is a meal that comes back.
    private struct SyncState: Codable {
        /// When the copy here was last edited — here, or on the device it came from.
        var revisions: [String: Date] = [:]
        /// Edited here, and CloudKit hasn't yet confirmed saving that edit.
        var dirty: Set<String> = []
        /// Deleted here, and CloudKit hasn't yet confirmed the delete.
        var deletes: Set<String> = []
        /// Whether this device's history has been offered once.
        var seeded = false

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            revisions = try c.decodeIfPresent([String: Date].self, forKey: .revisions) ?? [:]
            dirty = try c.decodeIfPresent(Set<String>.self, forKey: .dirty) ?? []
            deletes = try c.decodeIfPresent(Set<String>.self, forKey: .deletes) ?? []
            seeded = try c.decodeIfPresent(Bool.self, forKey: .seeded) ?? false
        }
    }

    private var stateURL: URL { AppSupport.directory.appendingPathComponent("cloud-wellness-sync.plist") }
    private var systemFieldsURL: URL { AppSupport.directory.appendingPathComponent("cloud-wellness-fields.plist") }

    /// Off without iCloud, in the Simulator, and in an unentitled local Mac build — where nothing
    /// is recorded or written at all.
    private static let isAvailable: Bool = {
        #if targetEnvironment(simulator)
        return false
        #else
        return !ProcessInfo.processInfo.arguments.contains("--disable-icloud") && AppCloud.hasContainerEntitlement
        #endif
    }()

    private override init() {
        super.init()
        // Read before anything can change it: a meal logged in the seconds before `start()` must
        // not write a fresh, empty record of what's synced over the real one.
        if Self.isAvailable { loadFromDisk() }
    }

    private var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: Self.zoneName) }
    private func recordID(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name, zoneID: zoneID) }

    /// Every sync engine in the app shares the private database. Without a scope, a fetch walks
    /// every zone — including Fitness, whose records carry the raw workout files.
    private var fetchOptions: CKSyncEngine.FetchChangesOptions { .init(scope: .zoneIDs([zoneID])) }

    /// Whether this device is syncing at all (entitled, not the Simulator, not turned off).
    var isRunning: Bool { engine != nil }

    // MARK: - The move off iCloud (`LegacyCloud`)

    /// Meals, supplements and doses are health data (T2).
    private var mode: LegacyCloudMode { LegacyCloud.mode(.health) }
    /// Every save and delete this sync queues goes through here, so a mode that doesn't write
    /// drops them (`LegacyOutbox`).
    private var outbox: LegacyOutbox<CKSyncEngine.PendingRecordZoneChange>?

    /// Read-only: everything the engine has queued goes, the zone save too. After a mode change,
    /// and after an engine is made from a saved state (which keeps what was queued then).
    private func dropUnwritable(_ engine: CKSyncEngine) -> Int {
        guard !mode.writes else { return 0 }
        let dropped = engine.state.pendingRecordZoneChanges
        engine.state.remove(pendingRecordZoneChanges: dropped)
        engine.state.remove(pendingDatabaseChanges: engine.state.pendingDatabaseChanges)
        return dropped.count
    }

    /// The mode changed (`LegacyCloud.set`): what waits to go up is dropped. The engine stays as it
    /// is (made again, it would bring back what it had queued); off, the engine and the poller go.
    func modeChanged() {
        guard Self.isAvailable, let engine else { return }
        guard mode.reads else {
            self.engine = nil
            outbox = nil
            poller = nil
            log.notice("wellness cloudsync off: every device has moved")
            return
        }
        guard !mode.writes else { return }
        let dropped = dropUnwritable(engine)
        log.notice("wellness cloudsync read-only; \(dropped) unsent change(s) dropped")
    }

    /// The move's complete fetch (`LegacyChannel.drainToEnd`): while it still writes, what waits
    /// goes up first; then everything since the last poll is read to the end, and the zone is
    /// listed, so an item iCloud once confirmed (it has system fields) and deleted elsewhere since
    /// shows as absent (§3 seeding rule 1). An item made here and never sent is never absent.
    func drainToEnd() async throws -> DrainResult {
        // No iCloud for this build (the Simulator, unentitled, turned off): nothing was ever here.
        guard Self.isAvailable else { return DrainResult() }
        guard let engine, let poller else {
            if !mode.reads { return DrainResult() }   // off: done
            throw LegacyDrainError.notRunning("wellness zone")
        }
        if mode.writes {
            do { try await engine.sendChanges(.init(scope: .zoneIDs([zoneID]))) } catch {
                log.notice("wellness drain: send deferred: \(error.localizedDescription, privacy: .public)")
            }
        }
        SyncProgress.shared.willFetch(.wellness)
        defer { SyncProgress.shared.didFetch(.wellness) }
        var present: Set<String>?
        do {
            if UserDefaults.standard.data(forKey: Self.stateKey) != nil {
                // Synced here before: the engine catches up from its own token, deletes included,
                // without walking the zone's history.
                try await engine.fetchChanges(.init(scope: .zoneIDs([zoneID])))
                present = nil
            } else {
                present = try await poller.drainToEnd(listing: true)
            }
        } catch CloudZonePoller.DrainError.noZone {
            present = nil   // no zone: nothing can be absent from it
        }
        return WellnessCloudRecord.drainResult(local: localNames(), confirmed: Set(systemFields.keys),
                                               dirty: state.dirty, deletes: state.deletes, present: present)
    }

    // MARK: - Lifecycle

    /// After `wellness.whenLoaded()` — an empty list mid-decode is not the phone's history.
    func start(wellness: WellnessStore) {
        self.wellness = wellness
        guard engine == nil, Self.isAvailable, mode.reads else { return }
        wellness.backfillDoseDays()
        if !state.seeded, mode.writes {
            state.dirty.formUnion(localNames())
            state.seeded = true
            saveState()
        }
        let serialized = UserDefaults.standard.data(forKey: Self.stateKey)
            .flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        makeEngine(serialized: serialized)
        poller = CloudZonePoller(database: container.privateCloudDatabase, zoneName: Self.zoneName,
                                 tokenKey: "zonePoll.wellness") { [weak self] records, deletions in
            self?.ingestPolled(records, deletions)
        }
        SyncProgress.shared.started(.wellness)
        queuePending()
        log.notice("wellness cloudsync started; \(self.state.dirty.count) to send, \(self.state.deletes.count) to delete")
        exchangeSoon()
    }

    private func makeEngine(serialized: CKSyncEngine.State.Serialization?) {
        var config = CKSyncEngine.Configuration(database: container.privateCloudDatabase,
                                                stateSerialization: serialized, delegate: self)
        // Meals change a few times a day; push delivery gets one onto an open Mac in seconds.
        // Read-only (the move off iCloud): no sending on its own; fetches are asked for.
        config.automaticallySync = mode.writes
        let engine = CKSyncEngine(config)
        self.engine = engine
        _ = dropUnwritable(engine)
        outbox = LegacyOutbox(mode: { LegacyCloud.mode(.health) },
                              add: { [weak engine] in engine?.state.add(pendingRecordZoneChanges: $0) },
                              remove: { [weak engine] in engine?.state.remove(pendingRecordZoneChanges: $0) })
    }

    /// The zone, every delete not yet confirmed, and every edit not yet confirmed.
    private func queuePending() {
        guard let engine, let outbox, mode.writes else { return }
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        let deletes = state.deletes.map { CKSyncEngine.PendingRecordZoneChange.deleteRecord(recordID($0)) }
        let saves = state.dirty.subtracting(state.deletes).map { CKSyncEngine.PendingRecordZoneChange.saveRecord(recordID($0)) }
        outbox.queue(deletes + saves)
    }

    private func localNames() -> Set<String> {
        guard let wellness else { return [] }
        return Set(wellness.meals.map { WellnessCloudRecord.meal($0.id).name })
            .union(wellness.supplements.map { WellnessCloudRecord.supplement($0.id).name })
            .union(wellness.supplementLogs.map { WellnessCloudRecord.dose($0).name })
    }

    /// After an iCloud backup restore replaced the file: fetch the whole zone again, so what the
    /// other device logged since the backup comes back, and the cloud's copy of anything edited
    /// since wins over the restored one. Nothing restored is uploaded for being restored.
    func resyncAfterRestore() {
        guard engine != nil else { return }
        state.dirty.removeAll()
        state.revisions.removeAll()
        saveState()
        UserDefaults.standard.removeObject(forKey: Self.stateKey)
        makeEngine(serialized: nil)   // no change token: the next fetch is everything
        queuePending()
        log.notice("wellness cloudsync refetching everything after a restore")
        exchangeSoon()
    }

    /// Whether a poll is due: its zone changed (nil: couldn't tell), or its first read isn't done.
    func needsRefresh(changedZones: Set<String>?) -> Bool {
        guard let poller else { return false }
        return changedZones.map { $0.contains(Self.zoneName) } ?? true || !poller.caughtUp
    }

    /// Pull now — when Nutrition opens, and every minute while the app is open.
    func refresh() {
        guard let engine else { return }
        let options = fetchOptions
        Task { try? await engine.fetchChanges(options) }
        guard let poller else { return }
        Task { @MainActor in
            SyncProgress.shared.willFetch(.wellness)
            await poller.poll()
            SyncProgress.shared.didFetch(.wellness)
        }
    }

    /// Records the poller fetched, through the same merge as the engine's own.
    private func ingestPolled(_ records: [CKRecord], _ deletions: [CKRecord.ID]) {
        guard let engine else { return }
        var changes = WellnessCloudChanges()
        for record in records where record.recordID.zoneID == zoneID {
            incoming(record, into: &changes, engine: engine)
        }
        for id in deletions where id.zoneID == zoneID {
            removed(id, into: &changes, engine: engine)
        }
        SyncProgress.shared.received(.wellness, count: records.count)
        LegacyCloud.applyingFromCloud { wellness?.applyCloudChanges(changes) }
        saveState()
        saveSystemFields()
    }

    private func exchangeSoon() {
        Task { @MainActor [weak self] in
            for delay in [0, 5] {
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard let self, let engine = self.engine else { return }
                do {
                    if self.mode.writes { try await engine.sendChanges(.init(scope: .zoneIDs([self.zoneID]))) }
                    try await engine.fetchChanges(self.fetchOptions)
                    return
                } catch {
                    self.log.notice("wellness cloudsync exchange deferred: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// When the copy here was last edited, as this sync knows it: an item's own time for the data
    /// platform's seed (DATA-PLATFORM.md §3 seeding rule 3). Nil where it isn't running.
    func editedAt(_ record: WellnessCloudRecord) -> Date? { state.revisions[record.name] }

    // MARK: - Local changes (called by WellnessStore)

    func saved(_ record: WellnessCloudRecord) {
        guard Self.isAvailable else { return }
        let name = record.name
        // Read-only, the edit time is still kept: it stops an older copy from an old build undoing
        // this edit. Nothing is sent.
        state.revisions[name] = Date()
        if mode.writes { state.dirty.insert(name) }
        state.deletes.remove(name)
        saveState()
        guard let outbox else { return }   // `start()` queues everything dirty
        outbox.unqueue([.deleteRecord(recordID(name))])
        outbox.queue([.saveRecord(recordID(name))])
    }

    func deleted(_ records: [WellnessCloudRecord]) {
        guard Self.isAvailable, !records.isEmpty else { return }
        for record in records {
            let name = record.name
            state.revisions.removeValue(forKey: name)
            state.dirty.remove(name)
            // Read-only too: an older copy fetched later must not bring it back.
            state.deletes.insert(name)
            if systemFields.removeValue(forKey: name) != nil { systemFieldsChanged = true }
            outbox?.unqueue([.saveRecord(recordID(name))])
            outbox?.queue([.deleteRecord(recordID(name))])
        }
        saveState()
    }

    // MARK: - CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        // A late event from an engine replaced after a restore must not overwrite anything.
        guard syncEngine === engine else { return }
        switch event {
        case .stateUpdate(let event):
            if let data = try? JSONEncoder().encode(event.stateSerialization) {
                UserDefaults.standard.set(data, forKey: Self.stateKey)
            }
        case .accountChange(let event):
            accountChanged(event)
        case .willFetchChanges:
            SyncProgress.shared.willFetch(.wellness)
        case .didFetchChanges:
            SyncProgress.shared.didFetch(.wellness)
        case .fetchedDatabaseChanges(let event):
            if event.deletions.contains(where: { $0.zoneID == zoneID }) {
                zoneWasReset("the Wellness zone was deleted in iCloud")
            }
        case .fetchedRecordZoneChanges(let event):
            var changes = WellnessCloudChanges()
            for modification in event.modifications where modification.record.recordID.zoneID == zoneID {
                incoming(modification.record, into: &changes, engine: syncEngine)
            }
            for deletion in event.deletions where deletion.recordID.zoneID == zoneID {
                removed(deletion.recordID, into: &changes, engine: syncEngine)
            }
            SyncProgress.shared.received(.wellness, count: event.modifications.count)
            // One save and one publish for the whole batch, never one per record.
            LegacyCloud.applyingFromCloud { wellness?.applyCloudChanges(changes) }
            saveState()
            saveSystemFields()
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
        guard syncEngine === engine, let wellness else { return nil }
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        guard !pending.isEmpty else { return nil }
        guard mode.writes else {
            syncEngine.state.remove(pendingRecordZoneChanges: pending)   // moved off iCloud
            return nil
        }
        let lookup = Lookup(wellness)
        // A save for an item that's gone here — deleted, or pushed past the 1,500-meal cap before
        // its upload — has nothing to send. Drop it rather than leave it pending forever and
        // walked again on every send.
        let gone = pending.filter { change in
            if case .saveRecord(let id) = change { return !lookup.has(id.recordName) }
            return false
        }
        if !gone.isEmpty {
            syncEngine.state.remove(pendingRecordZoneChanges: gone)
            for case .saveRecord(let id) in gone { state.dirty.remove(id.recordName) }
            saveState()
        }
        let goneSet = Set(gone)
        let changes = pending.filter { !goneSet.contains($0) }
        guard !changes.isEmpty else { return nil }
        let fields = systemFields
        let revisions = state.revisions
        // Built as the batch fills, not all up front: the first sync offers thousands of meals
        // and one batch only takes what fits in a request.
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { id in
            Self.makeRecord(id, lookup: lookup, systemFields: fields[id.recordName],
                            editedAt: revisions[id.recordName] ?? WellnessCloudPayload.unedited)
        }
    }

    // MARK: - Records

    private struct Lookup: Sendable {
        var meals: [UUID: MealEntry]
        var supplements: [UUID: SupplementSchedule]
        /// Newest log per dose record name.
        var doses: [String: SupplementLog]

        @MainActor init(_ wellness: WellnessStore) {
            meals = Dictionary(wellness.meals.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            supplements = Dictionary(wellness.supplements.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var doses: [String: SupplementLog] = [:]
            for log in wellness.supplementLogs {
                let name = WellnessCloudRecord.dose(log).name
                if let existing = doses[name], existing.date >= log.date { continue }
                doses[name] = log
            }
            self.doses = doses
        }

        func has(_ name: String) -> Bool {
            switch WellnessCloudRecord(name: name) {
            case .meal(let id): meals[id] != nil
            case .supplement(let id): supplements[id] != nil
            case .dose: doses[name] != nil
            case nil: false
            }
        }
    }

    private nonisolated static func makeRecord(_ id: CKRecord.ID, lookup: Lookup, systemFields: Data?,
                                               editedAt: Date) -> CKRecord? {
        let payload: Data?
        switch WellnessCloudRecord(name: id.recordName) {
        case .meal(let uuid):
            payload = lookup.meals[uuid].flatMap { WellnessCloudPayload.encode($0, editedAt: editedAt) }
        case .supplement(let uuid):
            payload = lookup.supplements[uuid].flatMap { WellnessCloudPayload.encode($0, editedAt: editedAt) }
        case .dose(_, let day):
            payload = lookup.doses[id.recordName].flatMap { log in
                var log = log
                log.day = day
                return WellnessCloudPayload.encode(log, editedAt: editedAt)
            }
        case nil:
            payload = nil
        }
        guard let payload else { return nil }
        let record = systemFields.flatMap(Self.record(fromSystemFields:))
            ?? CKRecord(recordType: recordType, recordID: id)
        record["payload"] = payload as CKRecordValue
        return record
    }

    /// A copy from iCloud: take it, or keep ours if ours is the newer edit, or ignore it if we
    /// deleted it and the delete is on its way.
    private func incoming(_ record: CKRecord, into changes: inout WellnessCloudChanges, engine: CKSyncEngine) {
        let name = record.recordID.recordName
        guard let kind = WellnessCloudRecord(name: name) else {
            log.error("unrecognised wellness record ignored: \(name, privacy: .public)")
            return
        }
        guard mode.reads else { return }
        storeSystemFields(record)
        guard let payload = record["payload"] as? Data else { return }
        let remoteEditedAt = WellnessCloudPayload.editedAt(payload) ?? WellnessCloudPayload.unedited
        switch WellnessCloudConflict.resolve(localEditedAt: state.revisions[name], remoteEditedAt: remoteEditedAt,
                                             deletedHere: state.deletes.contains(name)) {
        case .ignore:
            return
        case .keepLocal:
            // Read-only: ours stays here, and isn't sent over theirs.
            if outbox?.queue([.saveRecord(record.recordID)]) == true { state.dirty.insert(name) }
            return
        case .adopt:
            break
        }
        switch kind {
        case .meal:
            guard let envelope = WellnessCloudPayload.decode(MealEntry.self, from: payload) else { return dropped(name) }
            changes.meals.append(envelope.item)
        case .supplement:
            guard let envelope = WellnessCloudPayload.decode(SupplementSchedule.self, from: payload) else { return dropped(name) }
            changes.supplements.append(envelope.item)
        case .dose(_, let day):
            guard var envelope = WellnessCloudPayload.decode(SupplementLog.self, from: payload) else { return dropped(name) }
            envelope.item.day = day   // the record's day is the dose's day, whatever this device's time zone
            changes.doses.append(envelope.item)
        }
        state.revisions[name] = remoteEditedAt
        state.dirty.remove(name)
    }

    private func dropped(_ name: String) {
        log.error("wellness record payload failed to decode: \(name, privacy: .public)")
    }

    /// Deleted on another device. A delete wins over an unsent edit here: the item was removed
    /// on purpose, and re-sending the edit would bring it back everywhere.
    private func removed(_ id: CKRecord.ID, into changes: inout WellnessCloudChanges, engine: CKSyncEngine) {
        let name = id.recordName
        state.revisions.removeValue(forKey: name)
        state.dirty.remove(name)
        state.deletes.remove(name)
        if systemFields.removeValue(forKey: name) != nil { systemFieldsChanged = true }
        engine.state.remove(pendingRecordZoneChanges: [.saveRecord(id), .deleteRecord(id)])
        switch WellnessCloudRecord(name: name) {
        case .meal(let uuid): changes.deletedMeals.insert(uuid)
        case .supplement(let uuid): changes.deletedSupplements.insert(uuid)
        case .dose(let supplementID, let day): changes.deletedDoses.append(.init(supplementID: supplementID, day: day))
        case nil: log.error("unrecognised wellness deletion ignored: \(name, privacy: .public)")
        }
    }

    private func sent(_ event: CKSyncEngine.Event.SentRecordZoneChanges, engine: CKSyncEngine) {
        var zoneMissing = false
        for record in event.savedRecords {
            let name = record.recordID.recordName
            storeSystemFields(record)
            // Only clean if what went up is the latest edit: an older upload finishing while a
            // newer edit waits must not mark the newer one sent.
            let sentEditedAt = (record["payload"] as? Data).flatMap(WellnessCloudPayload.editedAt)
            if let sentEditedAt, sentEditedAt >= (state.revisions[name] ?? WellnessCloudPayload.unedited) {
                state.dirty.remove(name)
            }
        }
        for failed in event.failedRecordSaves {
            let id = failed.record.recordID
            switch failed.error.code {
            case .serverRecordChanged:
                // Saved elsewhere first. `incoming` decides between the copies, and keeps the
                // server's system fields either way, so a re-sent save lands.
                guard let server = failed.error.serverRecord else { continue }
                var changes = WellnessCloudChanges()
                incoming(server, into: &changes, engine: engine)
                LegacyCloud.applyingFromCloud { wellness?.applyCloudChanges(changes) }
            case .zoneNotFound, .userDeletedZone:
                zoneMissing = true
            case .unknownItem:
                // Deleted on another device since this one last saw it. Don't re-create it; the
                // delete arrives with the next fetch.
                if systemFields.removeValue(forKey: id.recordName) != nil { systemFieldsChanged = true }
                state.dirty.remove(id.recordName)
            default:
                // Network, throttling, quota: the engine retries on its own; the item stays dirty.
                log.error("wellness save failed for \(id.recordName, privacy: .public): \(failed.error.localizedDescription, privacy: .public)")
            }
        }
        for id in event.deletedRecordIDs { state.deletes.remove(id.recordName) }
        for (id, error) in event.failedRecordDeletes {
            switch error.code {
            case .unknownItem, .zoneNotFound, .userDeletedZone:
                state.deletes.remove(id.recordName)   // already gone
            default:
                log.error("wellness delete failed for \(id.recordName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        if zoneMissing { zoneWasReset("the Wellness zone was missing on save") }
    }

    /// The zone is gone (deleted in iCloud settings, purged, or never made). This device's copy
    /// is the source of truth: forget what the old zone held, and offer everything again.
    private func zoneWasReset(_ reason: String) {
        // Read-only: the zone isn't made again.
        guard let engine, mode.writes else { return }
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        // Once is enough; a burst of failures from one batch shouldn't redo it per record.
        if let lastZoneReset, Date().timeIntervalSince(lastZoneReset) < 60 { return }
        lastZoneReset = Date()
        log.notice("wellness cloudsync re-offering everything: \(reason, privacy: .public)")
        systemFields.removeAll()
        systemFieldsChanged = true
        state.deletes.removeAll()   // nothing left there to delete
        state.dirty.formUnion(localNames())
        saveState()
        saveSystemFields()
        engine.state.add(pendingRecordZoneChanges: state.dirty.map { .saveRecord(recordID($0)) })
    }

    private func accountChanged(_ event: CKSyncEngine.Event.AccountChange) {
        log.notice("wellness cloudsync account change: \(String(describing: event.changeType), privacy: .public)")
        // The engine drops its pending changes on any account change, and the record identity
        // belonged to the old account. Edit times, unsent edits and unconfirmed deletes stay: they
        // are facts about this device, and are what keep an edit or a delete from being undone.
        systemFields.removeAll()
        systemFieldsChanged = true
        switch event.changeType {
        case .signIn, .switchAccounts:
            // Offer everything to whichever account this is; where it already has a copy, the
            // edit times decide. Read-only: nothing to offer.
            guard mode.writes else { break }
            state.dirty.formUnion(localNames())
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
                // Starting over is safe — the first exchange re-offers everything and edit times
                // settle each item — but it shouldn't happen silently.
                log.fault("wellness sync state unreadable, starting over: \(error.localizedDescription, privacy: .public)")
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
