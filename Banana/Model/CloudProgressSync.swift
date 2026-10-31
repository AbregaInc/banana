import Foundation
import CloudKit
import Combine
import os

/// The operational sync layer for podcast progress — the crown jewels — across the user's devices,
/// via CloudKit's private database. One tiny `EpisodeProgress` record per episode (record name = the
/// episode's stable GUID, identical on every device), merged last-write-wins by `updatedAt`. That is
/// the same rule `PodcastLibrary.applyRemoteProgress` already uses, lifted to record granularity, so a
/// stale device can NEVER wipe the set the way the old whole-file snapshot did.
///
/// Everything lives in the SIGNED-IN user's private database, so it's multi-tenant for free: we sync
/// "this user's progress," never anything account-specific. The catalogue, cues, and history are
/// deliberately out of scope for this first slice — prove the round-trip on progress, then extend.
///
/// The JSON stores stay the local source of truth; this only mirrors changes up and applies remote
/// changes back through the library's existing merge. Uses `CKSyncEngine` (iOS 17+/macOS 14+) so we
/// don't hand-roll change tokens, batching, retries, and the push subscription.
@MainActor
final class CloudProgressSync: NSObject, CKSyncEngineDelegate {
    static let shared = CloudProgressSync()

    private let log = Logger(subsystem: "com.boris.banana", category: "cloudsync")
    /// Lazy is important: merely constructing CKContainer on an unsigned Simulator build can
    /// terminate inside CloudKit before `start` gets a chance to discover that sync is disabled.
    private lazy var container = CKContainer(identifier: AppCloud.containerID)
    private static let zoneName = "Progress"
    private static let recordType = "EpisodeProgress"
    private static let stateKey = "ckSyncEngine.progress.state"
    private static let seededKey = "ckSyncEngine.progress.seeded"
    /// Set once this device has read every progress record again under the tie rule.
    private static let maxSystemFieldRecords = 512
    private static let persistenceQueue = DispatchQueue(
        label: "com.boris.banana.cloud-progress-persistence",
        qos: .utility)

    private var engine: CKSyncEngine?
    private var startTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var flushAgain = false
    private var flushReasons: Set<String> = []
    private var queuedBeforeStart: Set<String> = []
    private weak var library: PodcastLibrary?
    private var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: Self.zoneName) }

    /// Per episode, the newest progress CloudKit is known to hold — confirmed by a save, or seen in
    /// a fetch. What `reconcileUploads` measures local changes against (`ProgressReconcile`).
    private var confirmedAt: [String: Date] = [:]

    /// Per-record system fields (change tags), so an update carries the server's tag and doesn't
    /// trip `serverRecordChanged`. Persisted next to the app's other data.
    private var systemFields: [String: Data] = [:]
    private var systemFieldOrder: [String] = []

    private override init() { super.init() }

    var isRunning: Bool { engine != nil }

    /// Whether this build can sync progress through iCloud at all.
    private static var iCloudAvailable: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return enabled && AppCloud.hasContainerEntitlement
        #endif
    }

    // MARK: - The move off iCloud (`LegacyCloud`)

    private var mode: LegacyCloudMode { LegacyCloud.mode(.personal) }

    /// The mode changed (`LegacyCloud.set`): read-only drops what waits to go up (the engine never
    /// sends on its own); off, the engine and the poller go.
    func modeChanged() {
        guard let engine else { return }
        guard mode.reads else {
            self.engine = nil
            poller = nil
            log.notice("cloudsync (progress) off: every device has moved")
            return
        }
        guard !mode.writes else { return }
        engine.state.remove(pendingRecordZoneChanges: engine.state.pendingRecordZoneChanges)
        engine.state.remove(pendingDatabaseChanges: engine.state.pendingDatabaseChanges)
        queuedBeforeStart.removeAll()
        log.notice("cloudsync (progress) read-only")
    }

    /// The move's complete fetch (`LegacyChannel.drainToEnd`): a flush (ours up while it still
    /// writes, then theirs), every change since the last poll read to the end, and every episode
    /// here asked for by name. Progress is never deleted, so nothing is absent or pending delete.
    func drainToEnd() async throws -> DrainResult {
        // No iCloud for this build (the Simulator, unentitled, progress sync turned off).
        guard Self.iCloudAvailable else { return DrainResult() }
        guard let engine, let poller else {
            if !mode.reads { return DrainResult() }   // off: done
            throw LegacyDrainError.notRunning("progress zone")   // still starting (it waits for the library)
        }
        var result = DrainResult()
        for case .saveRecord(let id) in engine.state.pendingRecordZoneChanges {
            result.note(\.dirty, type: "podcast.progress", id: id.recordName)
        }
        if mode.writes {
            do { try await engine.sendChanges(.init(scope: .zoneIDs([zoneID]))) } catch {
                log.notice("cloudsync (progress) drain: send deferred: \(error.localizedDescription, privacy: .public)")
            }
        }
        try await engine.fetchChanges(.init(scope: .zoneIDs([zoneID])))
        _ = try await poller.drainToEnd(listing: false)
        if let library { await fetchProgressNow(for: library.knownEpisodeIDs(), why: "the move off iCloud") }
        return result
    }

    /// Cross-device progress is a product guarantee, not a beta opt-in.  Older installs can still
    /// retain an explicit `false` for troubleshooting, but a device with no stored preference joins
    /// the shared state automatically.  Uploads remain commit-based (pause/stop/switch/background),
    /// never on the playback heartbeat, so this does not add radio wakeups while listening.
    static var enabled: Bool {
        get {
            if ProcessInfo.processInfo.arguments.contains("--cloudsync") { return true }
            guard UserDefaults.standard.object(forKey: "cloudProgressSyncEnabled") != nil else {
                return true
            }
            return UserDefaults.standard.bool(forKey: "cloudProgressSyncEnabled")
        }
        set { UserDefaults.standard.set(newValue, forKey: "cloudProgressSyncEnabled") }
    }

    // MARK: - Lifecycle

    func start(library: PodcastLibrary) {
        self.library = library
        guard Self.enabled else { log.notice("cloudsync disabled — not starting"); return }
        guard mode.reads else { log.notice("cloudsync (progress) off: moved to the Banana service"); return }
        guard engine == nil, startTask == nil else { return }
        guard AppCloud.hasContainerEntitlement else {
            log.notice("cloudsync unavailable: expected iCloud entitlement is missing")
            return
        }
        #if targetEnvironment(simulator)
        // Local unsigned Simulator builds have no usable iCloud entitlement. More importantly,
        // older code initialized CKContainer before reaching this decision and crashed at launch.
        log.notice("cloudsync unavailable in this Simulator build")
        return
        #else
        let serializedState = loadState()
        let zoneName = Self.zoneName
        startTask = Task { @MainActor [weak self, weak library] in
            async let loadedFields = Task.detached(priority: .utility) {
                Self.readSystemFields(zoneName: zoneName)
            }.value
            await library?.whenLoaded()
            guard let self, let library else { return }
            let fields = await loadedFields
            self.finishStart(library: library, fields: fields, serializedState: serializedState)
            self.startTask = nil
        }
        #endif
    }

    private func finishStart(library: PodcastLibrary, fields: [String: Data],
                             serializedState: CKSyncEngine.State.Serialization?) {
        guard engine == nil else { return }
        systemFields = fields
        systemFieldOrder = fields.keys.sorted()
        confirmedAt = Self.readConfirmed()
        pruneSystemFieldsIfNeeded()
        var config = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: serializedState,
            delegate: self)
        // Manual send/fetch cadence. Left automatic, the engine schedules a send soon after every
        // enqueue — and progress enqueues every 30 s of playback, so listening cost a CloudKit
        // radio wake twice a minute (the probable "sync killed background playback" mechanism).
        // With automaticallySync off, pending changes just accumulate in the engine's durable
        // state and move only when flushNow() runs — pause/stop/switch/finish/background — so a
        // listening session costs ZERO radio until it ends.
        config.automaticallySync = false
        let engine = CKSyncEngine(config)
        SyncProgress.shared.started(.progress)
        if poller == nil {
            poller = CloudZonePoller(database: container.privateCloudDatabase, zoneName: Self.zoneName,
                                     tokenKey: "zonePoll.progress") { [weak self] records, _ in
                self?.ingestFetched(records)
            }
            parked = UserDefaults.standard.data(forKey: Self.parkedKey)
                .flatMap { try? JSONDecoder().decode(ParkedProgress.self, from: $0) } ?? ParkedProgress()
            library.onEpisodesArrived = { [weak self] in self?.releaseParked() }
            releaseParked()
        }
        self.engine = engine
        if !mode.writes {
            // Read-only: what a saved state had queued stays here.
            engine.state.remove(pendingRecordZoneChanges: engine.state.pendingRecordZoneChanges)
            engine.state.remove(pendingDatabaseChanges: engine.state.pendingDatabaseChanges)
        }
        // The custom zone must exist before records land in it. Saving an existing zone is a no-op.
        if mode.writes { engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneName: Self.zoneName))]) }
        // Seed local progress we've never synced (records we have no system fields for). On a device
        // with data this uploads it; on a fresh device this is empty and the engine fetches instead.
        // System fields are a bounded update cache, not a catalogue of everything in CloudKit.
        // Once the zone has been seeded, evicted old change tags must NOT make every launch upload
        // hundreds of completed episodes again. The engine itself durably retains pending work.
        let previouslySeeded = UserDefaults.standard.bool(forKey: Self.seededKey)
            || !systemFields.isEmpty
        var unsynced = queuedBeforeStart
        if !previouslySeeded, mode.writes { unsynced.formUnion(library.allProgressEpisodeIDs()) }
        queuedBeforeStart.removeAll()
        if !unsynced.isEmpty { enqueue(Array(unsynced)) }
        log.notice("cloudsync started; seeding \(unsynced.count) unsynced progress records")
        reconcileUploads()
        flushNow(reason: "start")   // initial send of the seed + fetch of remote changes
        if !UserDefaults.standard.bool(forKey: Self.byEpisodeReadKey) {
            UserDefaults.standard.set(true, forKey: Self.byEpisodeReadKey)
            fetchLibraryProgress(why: "once, for progress older builds dropped")
        }
    }

    /// Queue episodes for upload. Cheap and idempotent — pending changes persist in the engine's
    /// durable state and move on the next flushNow(); enqueueing costs no radio by itself.
    func enqueue(_ episodeIDs: [String]) {
        guard !episodeIDs.isEmpty, mode.writes else { return }   // read-only: progress stays here
        guard let engine else {
            if Self.enabled { queuedBeforeStart.formUnion(episodeIDs) }
            return
        }
        engine.state.add(pendingRecordZoneChanges: episodeIDs.map {
            .saveRecord(CKRecord.ID(recordName: $0, zoneID: zoneID))
        })
    }

    /// Move pending changes now — send ours, pull theirs. THE radio commit point: called on
    /// pause/stop/switch/finish/background/foreground, never on a tick. No-op while sync is off.
    /// (With automaticallySync = false, push notifications don't auto-fetch either; the
    /// foreground flush is what picks up another device's session.)
    /// Whether a poll is due: its zone changed (nil: couldn't tell), or its first read isn't done.
    func needsRefresh(changedZones: Set<String>?) -> Bool {
        guard let poller else { return false }
        return changedZones.map { $0.contains(Self.zoneName) } ?? true || !poller.caughtUp
    }

    func flushNow(reason: String) {
        guard engine != nil else { return }
        // Coming forward is when a lost change gets its second chance.
        if reason == "foreground" { reconcileUploads() }
        flushReasons.insert(reason)
        if flushTask != nil {
            flushAgain = true
            return
        }
        flushTask = Task { @MainActor [weak self] in
            await self?.drainFlushes()
        }
    }

    /// Which step the running flush is on, for the slow-flush line.
    private var flushStep = "idle"

    private func drainFlushes() async {
        guard let engine else {
            flushTask = nil
            return
        }
        repeat {
            flushAgain = false
            let reasons = flushReasons.sorted().joined(separator: "+")
            flushReasons.removeAll()
            let began = Date()
            // A flush that takes this long is stuck on something; say which step.
            let watchdog = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                PlaybackDiagnostics.shared.log("☁️ progress flush slow", "(\(reasons)) still on \(self?.flushStep ?? "?") after 30s")
            }
            defer { watchdog.cancel() }
            do {
                flushStep = "send"
                if mode.writes { try await engine.sendChanges(.init(scope: .zoneIDs([zoneID]))) }
                flushStep = "fetch"
                try await engine.fetchChanges(.init(scope: .zoneIDs([zoneID])))
                UserDefaults.standard.set(true, forKey: Self.seededKey)
                // Success is logged too — the device-verification protocol watches for exactly
                // this line (one per commit point, none during playback).
                log.notice("cloudsync flush (\(reasons, privacy: .public)) complete")
            } catch {
                // Offline is normal (airplane mode, a dead spot) — the pending state is durable
                // and the next flush point retries. Log at notice, not error.
                log.notice("cloudsync flush (\(reasons, privacy: .public)) deferred: \(error.localizedDescription, privacy: .public)")
                PlaybackDiagnostics.shared.log("☁️ progress send", "deferred (\(reasons)): \(error.localizedDescription)")
            }
            // The engine's fetch is a no-op without a push; this asks the server itself — whether
            // or not the send went through, so other devices' progress still arrives. Not awaited:
            // a device's first poll reads the zone's whole history (minutes), and sends mustn't wait.
            if let poller { Task { await poller.poll() } }
            flushStep = "done"
            let took = Date().timeIntervalSince(began)
            if took > 10 { PlaybackDiagnostics.shared.log("☁️ progress flush", "(\(reasons)) took \(Int(took))s") }
        } while flushAgain
        flushTask = nil
    }

    /// Queue every episode changed here since CloudKit last confirmed it (`ProgressReconcile`).
    /// Cheap: a comparison per episode with progress, then one enqueue.
    private func reconcileUploads() {
        guard let library, engine != nil, mode.writes else { return }
        let stale = library.allProgressEpisodeIDs().filter {
            ProgressReconcile.needsUpload(localStamp: library.progressStamp(for: $0), confirmed: confirmedAt[$0])
        }
        guard !stale.isEmpty else { return }
        enqueue(stale)
        log.notice("cloudsync reconcile: re-sending \(stale.count) progress record(s) CloudKit hasn't confirmed")
        PlaybackDiagnostics.shared.log("☁️ progress reconcile", "re-sending \(stale.count) unconfirmed")
    }

    private func confirm(_ record: CKRecord) {
        guard let at = record["updatedAt"] as? Date else { return }
        let name = record.recordID.recordName
        if at > (confirmedAt[name] ?? .distantPast) {
            confirmedAt[name] = at
            confirmedSavePending = true
        }
    }

    private var confirmedSavePending = false

    private func saveConfirmedIfNeeded() {
        guard confirmedSavePending else { return }
        confirmedSavePending = false
        let snapshot = confirmedAt
        let url = Self.confirmedURL
        Self.persistenceQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private nonisolated static var confirmedURL: URL {
        AppSupport.directory.appendingPathComponent("ckProgressConfirmed.json")
    }

    private nonisolated static func readConfirmed() -> [String: Date] {
        guard let data = try? Data(contentsOf: confirmedURL),
              let map = try? JSONDecoder().decode([String: Date].self, from: data) else { return [:] }
        return map
    }

    // MARK: - CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard syncEngine === engine else { return }   // a late event from an engine let go (off)
        switch event {
        case .stateUpdate(let e):
            saveState(e.stateSerialization)

        case .willFetchChanges:
            SyncProgress.shared.willFetch(.progress)

        case .didFetchChanges:
            SyncProgress.shared.didFetch(.progress)

        case .accountChange(let e):
            handleAccountChange(e)

        case .fetchedRecordZoneChanges(let e):
            // Only this zone's records. Fetches are scoped to it now (`nextFetchChangesOptions`),
            // but the engine shares the database with every other sync, so check anyway.
            ingestFetched(e.modifications.map(\.record))

        case .sentRecordZoneChanges(let e):
            for saved in e.savedRecords {
                rememberSystemFields(saved)
                confirm(saved)
            }
            for failed in e.failedRecordSaves { resolveFailedSave(failed, syncEngine: syncEngine) }
            saveConfirmedIfNeeded()
            if !e.savedRecords.isEmpty {
                log.notice("cloudsync sent \(e.savedRecords.count) record(s)")
            }

        default:
            // willFetch/didFetch/willSend/didSend, database-change events, and anything added in a
            // future OS — none of which we need to act on for progress.
            break
        }
    }

    /// Fetch this engine's zone only. Every sync in the app shares the private database, and by
    /// default an engine fetches every zone in it: each one was downloading all the others'
    /// records — the workouts' raw-sample files included — and caching them as its own.
    func nextFetchChangesOptions(_ context: CKSyncEngine.FetchChangesContext,
                                 syncEngine: CKSyncEngine) async -> CKSyncEngine.FetchChangesOptions {
        var options = context.options
        options.scope = .zoneIDs([zoneID])
        return options
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                   syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !changes.isEmpty else { return nil }
        guard mode.writes else {
            syncEngine.state.remove(pendingRecordZoneChanges: changes)   // moved off iCloud
            return nil
        }

        // Build every record up front on the main actor, so the batch's record provider is a pure
        // lookup and never has to reach back into library state off-actor.
        var built: [CKRecord.ID: CKRecord] = [:]
        for change in changes {
            guard case .saveRecord(let id) = change else { continue }
            if let record = buildRecord(for: id) {
                built[id] = record
            } else {
                // No local progress for this episode anymore — drop the pending save.
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(id)])
            }
        }
        let records = built   // capture an immutable copy in the record provider
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { records[$0] }
    }

    // MARK: - Record <-> library

    private func buildRecord(for id: CKRecord.ID) -> CKRecord? {
        guard let library, let v = library.progressValue(episodeID: id.recordName) else { return nil }
        let record = existingRecord(for: id.recordName) ?? CKRecord(recordType: Self.recordType, recordID: id)
        record["position"] = v.position as CKRecordValue
        record["completed"] = (v.completed ? 1 : 0) as CKRecordValue
        record["updatedAt"] = v.updatedAt as CKRecordValue
        return record
    }

    /// Whether this device's copy beats the server's on a tie (`ProgressTie`): then the server
    /// holds the losing copy, and ours goes up again.
    private func oursBeatsTie(_ record: CKRecord) -> Bool {
        guard let library, let at = record["updatedAt"] as? Date else { return false }
        return library.localWinsTie(episodeID: record.recordID.recordName,
                                    position: record["position"] as? Double ?? 0,
                                    completed: (record["completed"] as? Int ?? 0) == 1,
                                    at: at)
    }

    private func applyFetched(_ record: CKRecord) {
        rememberSystemFields(record)
        guard let library else { return }
        let position = record["position"] as? Double ?? 0
        let completed = (record["completed"] as? Int ?? 0) == 1
        let at = record["updatedAt"] as? Date ?? record.modificationDate ?? Date()
        let episodeID = record.recordID.recordName
        // An episode of a show whose feed hasn't loaded here yet: keep it for when it has.
        guard library.knowsEpisode(episodeID) else {
            parked.park(episodeID, .init(position: position, completed: completed, at: at))
            parkedChanged = true
            return
        }
        let applied = LegacyCloud.applyingFromCloud {
            library.applyCloudProgress(episodeID: episodeID, position: position, completed: completed, at: at)
        }
        // A late arrival for the data platform (§3 seeding rule 6), at the library's own stamp.
        if applied { SyncReport.arrived(PodcastProgressAdapter.type, [episodeID]) }
    }

    /// Progress that came before its episode did (`ParkedProgress`).
    private var parked = ParkedProgress()
    private var parkedChanged = false
    private static let parkedKey = "cloudProgressParked"
    /// Once per device, every episode's progress is read again: builds before parking dropped
    /// progress that came before its episode, and before the tie rule (`ProgressTie`) two copies
    /// stamped alike each stayed put — a record already fetched is never delivered again.
    private static let byEpisodeReadKey = "cloudProgressByEpisodeRead.v1"

    private func saveParkedIfNeeded() {
        guard parkedChanged else { return }
        parkedChanged = false
        UserDefaults.standard.set(try? JSONEncoder().encode(parked), forKey: Self.parkedKey)
    }

    /// Apply parked progress whose episodes this device now has.
    private func releaseParked() {
        guard let library, !parked.isEmpty else { return }
        let known = library.knownEpisodeIDs()
        let ready = parked.release { known.contains($0) }
        guard !ready.isEmpty else { return }
        parkedChanged = true
        LegacyCloud.applyingFromCloud {
            library.applyingRemoteBatch {
                for (episodeID, entry) in ready {
                    if library.applyCloudProgress(episodeID: episodeID, position: entry.position,
                                                  completed: entry.completed, at: entry.at) {
                        SyncReport.arrived(PodcastProgressAdapter.type, [episodeID])
                    }
                }
            }
        }
        saveParkedIfNeeded()
        PlaybackDiagnostics.shared.log("☁️ progress parked", "applied \(ready.count) now their episodes are here; \(parked.entries.count) still waiting")
    }

    /// A save failed. The only one worth handling for progress is `serverRecordChanged`: another
    /// device wrote a newer record. Adopt the server copy (our LWW merge decides which value sticks),
    /// then let normal flow continue — this is the record-level protection the snapshot never had.
    private func resolveFailedSave(_ failed: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave,
                                   syncEngine: CKSyncEngine) {
        let error = failed.error
        switch error.code {
        case .serverRecordChanged:
            if let server = error.serverRecord {
                applyFetched(server)   // adopt server system fields + merge its value
                // What the server holds, so a reconcile doesn't re-send it — unless ours beats it
                // on a tie, when the server's copy is the one that has to go.
                if !oursBeatsTie(server) { confirm(server) }
                // The engine dequeued this save when it failed. If OUR value is the newer one
                // (the LWW merge just rejected the server's), nothing would re-upload it until
                // this episode's progress next changed — which for a final pause is never.
                // Re-stage it; with the adopted system fields the retry succeeds.
                if mode.writes { syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(failed.record.recordID)]) }
            }
        case .zoneNotFound, .userDeletedZone:
            // Re-create the zone. Do NOT mass re-enqueue every record here — the failed saves stay
            // pending and retry once the zone exists, and re-adding the whole library on every
            // failure is exactly the CPU-burning loop that can get a background audio app killed.
            forgetSystemFields()
            UserDefaults.standard.removeObject(forKey: Self.seededKey)
            if mode.writes { syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneName: Self.zoneName))]) }
        default:
            // Anything else (network, quota, throttle): drop this pending save and let CKSyncEngine's
            // own backoff govern retries. No re-enqueue → no loop.
            syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(failed.record.recordID)])
            log.error("cloudsync save failed for \(failed.record.recordID.recordName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func forgetSystemFields() {
        systemFields.removeAll()
        systemFieldOrder.removeAll()
        saveSystemFields()
    }

    /// Fetched progress records — from the engine or the poller (`CloudZonePoller`) — through the
    /// library's last-write-wins merge. Progress deletions are not a thing we model.
    private func ingestFetched(_ records: [CKRecord]) {
        let mine = records.filter { $0.recordID.zoneID == zoneID }
        // Batch the per-record progress.json rewrite and Watch-resume relay to once per fetch
        // instead of once per record — see PodcastLibrary.applyingRemoteBatch.
        // rememberSystemFields still runs per record inside applyFetched either way.
        if let library {
            LegacyCloud.applyingFromCloud {
                library.applyingRemoteBatch {
                    for record in mine { applyFetched(record) }
                }
            }
        } else {
            for record in mine { applyFetched(record) }
        }
        var oursAgain: [String] = []
        for record in mine {
            if oursBeatsTie(record) { oursAgain.append(record.recordID.recordName) }
            else { confirm(record) }
        }
        saveConfirmedIfNeeded()
        saveParkedIfNeeded()
        if !oursAgain.isEmpty, mode.writes {
            enqueue(oursAgain)
            PlaybackDiagnostics.shared.log("☁️ progress tie", "re-sending \(oursAgain.count) this device wins")
            flushNow(reason: "tie")
        }
        if !mine.isEmpty {
            log.notice("cloudsync fetched \(mine.count) record change(s)")
        }
        SyncProgress.shared.received(.progress, count: mine.count)
    }

    /// Fetches what changed on other devices — the engine only would on a push (`CloudZonePoller`).
    private var poller: CloudZonePoller?

    /// Get the progress of every episode this device has, from iCloud: shows have just arrived
    /// here (subscribed on another device), and progress that came before their episodes did had
    /// nothing to apply to.
    func fetchLibraryProgress(why: String) {
        guard let library else { return }
        fetchProgress(for: library.knownEpisodeIDs(), why: why)
    }

    /// Ask iCloud for these episodes' progress by name — a progress record is named for its
    /// episode — instead of reading the zone's history of changes from the start: months of saves,
    /// most of them since overwritten, took many minutes of paging before the first current record.
    private func fetchProgress(for episodeIDs: Set<String>, why: String) {
        Task { @MainActor [weak self] in await self?.fetchProgressNow(for: episodeIDs, why: why) }
    }

    private func fetchProgressNow(for episodeIDs: Set<String>, why: String) async {
        guard engine != nil, !episodeIDs.isEmpty else { return }
        let zoneID = zoneID
        let ids = episodeIDs.sorted().map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
        let database = container.privateCloudDatabase
        var found = 0
        var failed: String?
        for start in stride(from: 0, to: ids.count, by: 400) {
            let chunk = Array(ids[start..<min(start + 400, ids.count)])
            do {
                // An episode with no progress anywhere has no record: that one fails alone.
                let records = try await database.records(for: chunk).values.compactMap { try? $0.get() }
                found += records.count
                if !records.isEmpty { ingestFetched(records) }
            } catch {
                failed = error.localizedDescription
            }
        }
        PlaybackDiagnostics.shared.log("☁️ progress by episode",
            "\(why): \(found) of \(ids.count) episodes have progress in iCloud\(failed.map { "; some couldn't be read — \($0)" } ?? "")")
    }

    private func handleAccountChange(_ e: CKSyncEngine.Event.AccountChange) {
        // On any account transition, forget cached record identity so we never mix two accounts'
        // data, then re-seed from local for the (possibly new) signed-in account.
        systemFields.removeAll()
        systemFieldOrder.removeAll()
        saveSystemFields()
        confirmedAt.removeAll()          // a new account has confirmed nothing
        confirmedSavePending = true
        saveConfirmedIfNeeded()
        UserDefaults.standard.removeObject(forKey: Self.stateKey)
        UserDefaults.standard.removeObject(forKey: Self.seededKey)
        if let library { enqueue(library.allProgressEpisodeIDs()) }
        log.notice("cloudsync account change: \(String(describing: e.changeType), privacy: .public)")
    }

    // MARK: - System-fields cache

    private func existingRecord(for recordName: String) -> CKRecord? {
        guard let data = systemFields[recordName],
              let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        let record = CKRecord(coder: coder)
        coder.finishDecoding()
        // Never build on another zone's record, whatever the cache says.
        guard record?.recordID.zoneID == zoneID else { return nil }
        return record
    }

    private func rememberSystemFields(_ record: CKRecord) {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        let key = record.recordID.recordName
        systemFields[key] = coder.encodedData
        systemFieldOrder.removeAll { $0 == key }
        systemFieldOrder.append(key)
        pruneSystemFieldsIfNeeded()
        scheduleSystemFieldsSave()
    }

    /// A system-fields blob is an optimization, not the source of truth. If an old record's fields
    /// are evicted, its next edit may receive `serverRecordChanged`; that path already adopts the
    /// server fields and retries safely. Bounding this cache prevents years of completed episodes
    /// from turning every sync batch into an ever-growing JSON encode.
    private func pruneSystemFieldsIfNeeded() {
        guard systemFieldOrder.count > Self.maxSystemFieldRecords else { return }
        let overflow = systemFieldOrder.count - Self.maxSystemFieldRecords
        for key in systemFieldOrder.prefix(overflow) { systemFields[key] = nil }
        systemFieldOrder.removeFirst(overflow)
    }

    /// Coalesce the system-fields write. A first sync touches every record in the library, and
    /// writing the WHOLE map per record made that O(n²) disk churn — hundreds of atomic rewrites
    /// of the same growing file in one batch. One write per settle instead.
    private var systemFieldsSavePending = false
    private func scheduleSystemFieldsSave() {
        guard !systemFieldsSavePending else { return }
        systemFieldsSavePending = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            self.systemFieldsSavePending = false
            self.saveSystemFields()
        }
    }

    private nonisolated static var systemFieldsURL: URL {
        let dir = AppSupport.directory
        return dir.appendingPathComponent("ckProgressRecords.json")
    }

    /// Only this zone's records. Before fetches were scoped to the zone, every other engine's
    /// records (workouts, settings, meals) arrived here too and took up the cache.
    private nonisolated static func readSystemFields(zoneName: String) -> [String: Data] {
        guard let data = try? Data(contentsOf: systemFieldsURL),
              let map = try? JSONDecoder().decode([String: Data].self, from: data) else { return [:] }
        return map.filter { _, fields in cachedZoneName(fields) == zoneName }
    }

    private nonisolated static func cachedZoneName(_ fields: Data) -> String? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: fields) else { return nil }
        coder.requiresSecureCoding = true
        let record = CKRecord(coder: coder)
        coder.finishDecoding()
        return record?.recordID.zoneID.zoneName
    }

    private func saveSystemFields() {
        let snapshot = systemFields
        let url = Self.systemFieldsURL
        Self.persistenceQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Engine state

    private func loadState() -> CKSyncEngine.State.Serialization? {
        guard let data = UserDefaults.standard.data(forKey: Self.stateKey) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    private func saveState(_ state: CKSyncEngine.State.Serialization) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: Self.stateKey)
    }
}

// MARK: - Fitness + Health cache sync

/// Operational phone↔Mac sync for the data behind Fitness and Rhythm. Apple Health itself is
/// deliberately not treated as a shared database: only the phone can query the user's HealthKit
/// store. We mirror its derived cache, complete raw workout streams, and voice-note metadata
/// through one live CloudKit engine; iCloud Drive is reserved for optional note-audio attachments.
@MainActor
final class CloudFitnessSync: NSObject, ObservableObject, CKSyncEngineDelegate {
    static let shared = CloudFitnessSync()

    private let log = Logger(subsystem: "com.boris.banana", category: "cloudfitness")
    private lazy var container = CKContainer(identifier: AppCloud.containerID)
    private static let zoneName = "Fitness"
    // The private-zone type already stores the summary payload. `samplesAsset` is a CloudKit
    // asset on workout records: summary + raw file commit atomically as one record revision.
    private static let recordType = "SettingsSnapshot"
    private static let healthRecordName = "health-cache"
    private static let stateKey = "ckSyncEngine.fitness.state"
    private static let revisionsKey = "ckSyncEngine.fitness.revisions"
    private static let systemFieldsKey = "ckSyncEngine.fitness.systemFields"
    /// Record names with a local change not yet confirmed saved by CloudKit. Gates the
    /// launch-time reseed loop in `start()`/`seedLocal*`/`.accountChange` so it only re-offers
    /// records CloudKit doesn't already have, instead of re-uploading the whole local catalogue
    /// on every launch. Written synchronously on every insert/removal (unlike `systemFields`,
    /// below, which is safe to coalesce): losing a `dirty` insert across a background/terminate
    /// would mean a one-off local edit (e.g. a trim) is never re-offered to the peer device.
    private static let dirtyKey = "ckSyncEngine.fitness.dirty"
    /// Workout record names whose most recent successful save did NOT include the raw-sample
    /// CKAsset (deferred by a schema rejection — see `shouldAttachSamplesAsset`). Lets the
    /// launch-time reseed re-offer just that record once the schema cooldown clears, without
    /// re-offering every already-fully-synced workout too.
    private static let assetPendingKey = "ckSyncEngine.fitness.assetPending"
    private static let notesMigrationKey = "cloudNotesUseCloudKitIndex"
    /// A production schema can temporarily lag a client that adds a new CKAsset field. Do not
    /// make that prevent the compact, already-useful derived workout summary from syncing.
    /// We retry raw-asset attachment after this short cooldown, so schema deployment eventually
    /// upgrades the same records to the complete canonical stream without user intervention.
    private static let samplesAssetBlockedUntilKey = "fitnessCloud.samplesAssetBlockedUntil"
    private static let samplesAssetRetryDelay: TimeInterval = 15 * 60
    /// The one piece of bookkeeping `syncState` needs beyond the sets this class already keeps:
    /// when the backlog (`dirty` ∪ `assetPending`) last reached zero. Persisted so "up to date as
    /// of ⟨time⟩" survives a relaunch instead of resetting to "never synced" every cold start.
    private static let lastSuccessKey = "ckSyncEngine.fitness.lastSuccess"

    private var engine: CKSyncEngine?
    private weak var fitness: FitnessStore?
    private weak var health: HealthKitStore?
    private weak var notes: VoiceNoteStore?
    private var pendingDeletes: Set<UUID> = []
    /// Deletes made here that iCloud won't get from this device any more (`HeldDeletes`).
    private let heldDeletes = HeldDeletes(key: "ckSyncEngine.fitness.droppedDeletes",
                                          tierOf: { $0.hasPrefix("note-") ? .personal : .health })

    /// The move kept what the drain returned for this tier.
    func drainKept(tier: LegacyTier) { heldDeletes.kept(tier: tier) }

    /// What a drain hands over when there's no zone to read: the deletes held here.
    private func heldOnly() -> DrainResult {
        var result = DrainResult()
        for name in heldDeletes.handOver() {
            switch CloudFitnessRecordRouting.classify(name, healthRecordName: Self.healthRecordName) {
            case .workout(let id): result.note(\.pendingDeletes, type: "health.workout", id: id.uuidString)
            case .note(let id): result.note(\.pendingDeletes, type: "notes.voiceNote", id: id.uuidString)
            case .health, .unrecognised: break
            }
        }
        return result
    }
    private var revisions: [String: Date] = [:]
    private var systemFields: [String: Data] = [:]
    private var dirty: Set<String> = []
    private var assetPending: Set<String> = []

    /// The user-facing verdict — see `FitnessSyncState`'s doc comment. Updated only at settle
    /// points (`recomputeSyncState()`'s callers), never once per record inside a batch, so a big
    /// fetch never republishes (and re-renders every observer) hundreds of times in a row.
    @Published private(set) var syncState: FitnessSyncState = .unavailable
    /// Whether a send exchange is in flight right now — toggled by `willSendChanges`/
    /// `didSendChanges`. Combined with `fetching` below to answer "currently syncing."
    private var sending = false
    /// Whether a fetch exchange is in flight right now — toggled by `willFetchChanges`/
    /// `didFetchChanges`.
    private var fetching = false
    /// Set on a `.signOut` account change, cleared on `.signIn`/`.switchAccounts`. `engine != nil`
    /// alone isn't enough: the engine keeps existing after a sign-out, it just can't do anything
    /// useful — this is what lets `recomputeSyncState()` say "unavailable" instead of showing a
    /// stale success once the account that produced it is gone.
    private var accountSignedOut = false
    /// The most recent moment the backlog reached zero, if ever. See `lastSuccessKey`.
    private var lastSyncSuccess: Date?

    private override init() { super.init() }

    // MARK: - The move off iCloud (`LegacyCloud`)

    /// Workouts and the Health snapshot are health data (T2); voice notes are personal (T1).
    private func mode(forName name: String) -> LegacyCloudMode {
        LegacyCloud.mode(name.hasPrefix("note-") ? .personal : .health)
    }
    private var workoutsWrite: Bool { LegacyCloud.mayWrite(.health) }
    private var notesWrite: Bool { LegacyCloud.mayWrite(.personal) }
    private var anyWrites: Bool { workoutsWrite || notesWrite }
    private var anyReads: Bool { LegacyCloud.mayRead(.health) || LegacyCloud.mayRead(.personal) }

    /// Whether this build syncs fitness through iCloud at all.
    private static var iCloudAvailable: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return !ProcessInfo.processInfo.arguments.contains("--disable-icloud") && AppCloud.hasContainerEntitlement
        #endif
    }

    /// What no longer writes leaves the engine's queue, the zone save with it once nothing writes:
    /// after a mode change, and after an engine is made from a saved state (which keeps what was
    /// queued then). Sends are also refused batch by batch.
    private func dropUnwritable(_ engine: CKSyncEngine) -> Int {
        let stopped = engine.state.pendingRecordZoneChanges.filter { !mode(forName: $0.recordName).writes }
        // Deletes leave the queue but not the device: the move's drain carries them (`heldDeletes`).
        heldDeletes.add(stopped.compactMap { change -> String? in
            if case .deleteRecord(let id) = change { return id.recordName }
            return nil
        })
        if !workoutsWrite {
            heldDeletes.add(pendingDeletes.map { recordID(for: $0).recordName })
            pendingDeletes.removeAll()
        }
        engine.state.remove(pendingRecordZoneChanges: stopped)
        if !anyWrites { engine.state.remove(pendingDatabaseChanges: engine.state.pendingDatabaseChanges) }
        return stopped.count
    }

    /// The modes changed (`LegacyCloud.set`): what no longer writes leaves the queue. The engine
    /// stays as it is (made again, it would bring back what it had queued); with both tiers off,
    /// the engine and the poller go.
    func modeChanged() {
        guard let engine else { return }
        guard anyReads else {
            self.engine = nil
            poller = nil
            recomputeSyncState()
            log.notice("fitness cloudsync off: every device has moved")
            return
        }
        let stopped = dropUnwritable(engine)
        recomputeSyncState()
        log.notice("fitness cloudsync mode changed; \(stopped) unsent change(s) dropped")
    }

    private static var savedSerialization: CKSyncEngine.State.Serialization? {
        UserDefaults.standard.data(forKey: stateKey)
            .flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
    }

    private func makeEngine(serialized: CKSyncEngine.State.Serialization?) {
        var config = CKSyncEngine.Configuration(database: container.privateCloudDatabase,
                                                stateSerialization: serialized, delegate: self)
        // Fitness changes are infrequent and benefit from push delivery: a finished workout on the
        // phone should appear on an already-open Mac without waiting for it to foreground.
        // Read-only (the move off iCloud): no sending on its own; fetches are asked for.
        config.automaticallySync = anyWrites
        let made = CKSyncEngine(config)
        engine = made
        _ = dropUnwritable(made)
    }

    /// The move's complete fetch (`LegacyChannel.drainToEnd`): while it still writes, what waits
    /// goes up first; then everything since the last poll is read to the end, and the zone is
    /// listed, so a workout or note iCloud once confirmed (it has system fields) and deleted
    /// elsewhere since shows as absent (§3 seeding rule 1). One made here and never sent never is.
    func drainToEnd() async throws -> DrainResult {
        // No iCloud for this build (the Simulator, unentitled, turned off): nothing in a zone, but
        // the deletes held here still go to the move.
        guard Self.iCloudAvailable else { return heldOnly() }
        guard let engine, let poller else {
            if !anyReads { return heldOnly() }   // off: done
            throw LegacyDrainError.notRunning("fitness zone")
        }
        if anyWrites {
            do { try await engine.sendChanges(.init(scope: .zoneIDs([zoneID]))) } catch {
                log.notice("fitness drain: send deferred: \(error.localizedDescription, privacy: .public)")
            }
        }
        var present: Set<String>?
        do {
            if UserDefaults.standard.data(forKey: Self.stateKey) != nil {
                // This device has been syncing the zone: its own engine catches up from its token in
                // seconds, deletes included. Walking the zone's whole history (every version of the
                // Health snapshot, saved every few minutes for months) took longer than iOS allows.
                try await engine.fetchChanges(.init(scope: .zoneIDs([zoneID])))
                present = nil
            } else {
                present = try await poller.drainToEnd(listing: true)
            }
        } catch CloudZonePoller.DrainError.noZone {
            present = nil   // no zone: nothing can be absent from it
        } catch let error as CKError where error.code == .notAuthenticated {
            return heldOnly()   // signed out of iCloud: nothing to read, the held deletes still go
        }
        var result = DrainResult()
        var deleting = Set(pendingDeletes.map { recordID(for: $0).recordName }).union(heldDeletes.handOver())
        for case .deleteRecord(let id) in engine.state.pendingRecordZoneChanges { deleting.insert(id.recordName) }
        func note(_ keyPath: WritableKeyPath<DrainResult, [String: Set<String>]>, _ name: String) {
            switch CloudFitnessRecordRouting.classify(name, healthRecordName: Self.healthRecordName) {
            case .workout(let id): result.note(keyPath, type: "health.workout", id: id.uuidString)
            case .note(let id): result.note(keyPath, type: "notes.voiceNote", id: id.uuidString)
            case .health: result.note(keyPath, type: "health.snapshot", id: Self.healthRecordName)
            case .unrecognised: break
            }
        }
        for name in dirty.subtracting(deleting) { note(\.dirty, name) }
        for name in deleting { note(\.pendingDeletes, name) }
        if let present, !present.isEmpty {
            var local = Set(fitness?.summaries.map { recordID(for: $0.id).recordName } ?? [])
            local.formUnion(notes?.cloudNotesSnapshot().map { noteRecordID(for: $0.id).recordName } ?? [])
            let onceSynced = local.filter { systemFields[$0] != nil }
            for name in onceSynced.subtracting(present).subtracting(dirty).subtracting(deleting) { note(\.absent, name) }
        }
        return result
    }

    private var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: Self.zoneName) }
    private func recordID(for id: UUID) -> CKRecord.ID {
        // Shared with the DEBUG-only zone purge tool's delete-list validation (see
        // `FitnessZonePurgePlan.workoutRecordName` in Shared/FitnessModels.swift) so there is
        // exactly one place that knows the `workout-<uuid>` naming rule.
        CKRecord.ID(recordName: FitnessZonePurgePlan.workoutRecordName(for: id), zoneID: zoneID)
    }
    private func noteRecordID(for id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: "note-\(id.uuidString)", zoneID: zoneID)
    }
    private var healthRecordID: CKRecord.ID {
        CKRecord.ID(recordName: Self.healthRecordName, zoneID: zoneID)
    }

    private var shouldAttachSamplesAsset: Bool {
        guard let blockedUntil = UserDefaults.standard.object(forKey: Self.samplesAssetBlockedUntilKey) as? Date else {
            return true
        }
        return blockedUntil <= Date()
    }

    /// Each send gets its own file, so a newer snapshot never rewrites one still uploading; files
    /// older than a day go.
    private static func writeHealthAsset(_ snapshot: Data) -> URL? {
        let dir = AppSupport.directory.appendingPathComponent("cloud-health", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cutoff = Date().addingTimeInterval(-86_400)
        for old in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let modified = (try? old.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? FileManager.default.removeItem(at: old) }
        }
        let url = dir.appendingPathComponent("\(UUID().uuidString).lzfse")
        do { try HealthFileProtection.write(snapshot, to: url) } catch { return nil }
        return url
    }

    private func deferSamplesAssetUpload() {
        UserDefaults.standard.set(Date().addingTimeInterval(Self.samplesAssetRetryDelay),
                                  forKey: Self.samplesAssetBlockedUntilKey)
    }

    func start(fitness: FitnessStore, health: HealthKitStore, notes: VoiceNoteStore) {
        self.fitness = fitness
        self.health = health
        self.notes = notes
        // Covers every exit from this method — the early-return guards below (unavailable) and
        // the normal path (after seeding) alike — with exactly one recompute, not one per branch.
        defer { recomputeSyncState() }
        guard engine == nil,
              !ProcessInfo.processInfo.arguments.contains("--disable-icloud"),
              AppCloud.hasContainerEntitlement, anyReads else {
            return
        }
        #if targetEnvironment(simulator)
        return
        #else
        revisions = UserDefaults.standard.dictionary(forKey: Self.revisionsKey) as? [String: Date] ?? [:]
        systemFields = UserDefaults.standard.dictionary(forKey: Self.systemFieldsKey) as? [String: Data] ?? [:]
        purgeForeignSystemFieldsOnce()
        // An absent dirty/assetPending file means empty, i.e. "nothing known to still need a
        // send" — safe: any record that had `systemFields` was saved at least once, and any
        // interrupted send is already durable in CKSyncEngine's own restored pending state.
        dirty = Set(UserDefaults.standard.array(forKey: Self.dirtyKey) as? [String] ?? [])
        assetPending = Set(UserDefaults.standard.array(forKey: Self.assetPendingKey) as? [String] ?? [])
        lastSyncSuccess = UserDefaults.standard.object(forKey: Self.lastSuccessKey) as? Date
        #if os(macOS)
        // This is safe only after a real CloudKit fetch has left note system fields behind. A
        // pristine Mac keeps its local file untouched until then.
        if !UserDefaults.standard.bool(forKey: Self.notesMigrationKey) {
            let cloudIDs = Set(systemFields.keys.compactMap { key -> UUID? in
                guard key.hasPrefix("note-") else { return nil }
                return UUID(uuidString: key.replacingOccurrences(of: "note-", with: ""))
            })
            if !cloudIDs.isEmpty {
                notes.pruneLegacyNotes(notIn: cloudIDs)
                UserDefaults.standard.set(true, forKey: Self.notesMigrationKey)
            }
        }
        #endif
        makeEngine(serialized: Self.savedSerialization)
        guard let engine else { return }
        SyncProgress.shared.started(.fitness)
        // Workouts carry their recordings: the first poll lists the zone without contents and
        // fetches in full only records newer than what this device applied (`revisions` holds
        // each record's server modification date as last applied here).
        poller = CloudZonePoller(
            database: container.privateCloudDatabase, zoneName: Self.zoneName, tokenKey: "zonePoll.fitness",
            isStale: { [weak self] record in
                guard let self, let modified = record.modificationDate else { return true }
                return (self.revisions[record.recordID.recordName] ?? .distantPast) < modified
            },
            ingest: { [weak self] records, deletions in
                await self?.ingestFetched(records, deletions)
            })
        if anyWrites { engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneName: Self.zoneName))]) }
        if workoutsWrite {
            for id in pendingDeletes {
                engine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID(for: id))])
            }
        } else {
            heldDeletes.add(pendingDeletes.map { recordID(for: $0).recordName })
        }
        pendingDeletes.removeAll()
        for summary in fitness.summaries { queue(summary.id, touchedNow: false) }
        #if os(iOS)
        // Capture happens on phone/Watch. A Mac fetches this canonical index instead of reviving
        // stale rows from the retired file-based index.
        for id in notes.allNoteIDs() { queueNote(id, touchedNow: false) }
        #endif
        // The phone is the HealthKit reader and therefore the sole publisher of this cache. An
        // iPad or a Mac may retain an older received cache, but must never race it and overwrite
        // newer phone facts merely because it launched first (`queueHealth` refuses off the hub).
        if health.hasData { queueHealth(touchedNow: false) }
        log.notice("cloudsync started; seeded \(fitness.summaries.count) workouts and \(notes.noteCount) notes")
        // CloudKit's automatic schedule is deliberately opportunistic. That is fine for a later
        // background refresh, but it made a just-opened Mac sit empty while the phone had real
        // workout data. Commit and fetch immediately, with a couple of short retries to cover the
        // two devices being opened in either order.
        syncImmediatelyAfterStart()
        #endif
    }

    /// Workouts this fetch adopted, told to the data platform after the batch.
    private var arrivedWorkouts: Set<UUID> = []

    /// Called inside the apply's scope, so they count as arrivals, not this device's edits.
    private func reportArrivedWorkouts() {
        let arrived = arrivedWorkouts
        arrivedWorkouts = []
        if !arrived.isEmpty { MoveOver.changed(type: FitnessStore.spaceType, ids: arrived.map(\.uuidString).sorted()) }
    }

    /// When this device's copy of a workout was last edited (or fetched), as this sync knows it:
    /// the item's own time for the data platform's seed (DATA-PLATFORM.md §3 seeding rule 3).
    func editedAt(workout id: UUID) -> Date? { revisions[recordID(for: id).recordName] }

    func upsert(_ summary: FitnessSessionSummary) {
        heldDeletes.remove([recordID(for: summary.id).recordName])
        queue(summary.id, touchedNow: true)
        recomputeSyncState()   // one real local change — cheap to recompute right away
    }
    func upsert(_ note: VoiceNote) {
        heldDeletes.remove([noteRecordID(for: note.id).recordName])
        queueNote(note.id, touchedNow: true)
        recomputeSyncState()
    }

    /// The local disk stores decode asynchronously. Seed once they are actually available rather
    /// than treating an empty launch-time array as the phone's complete workout history.
    func seedLocalSummaries(_ summaries: [FitnessSessionSummary]) {
        guard engine != nil else { return }
        for summary in summaries { queue(summary.id, touchedNow: false) }
    }

    func seedLocalHealthIfPresent() {
        guard engine != nil, health?.hasData == true else { return }
        queueHealth(touchedNow: false)   // the phone only — see queueHealth
    }

    func delete(_ id: UUID) {
        let record = recordID(for: id)
        revisions[record.recordName] = Date()
        saveRevisions()
        guard workoutsWrite else {
            heldDeletes.add([record.recordName])   // not for iCloud: for the move's drain
            return
        }
        guard let engine else {
            pendingDeletes.insert(id)
            return
        }
        engine.state.add(pendingRecordZoneChanges: [.deleteRecord(record)])
    }

    func deleteNote(_ id: UUID) {
        let record = noteRecordID(for: id)
        revisions[record.recordName] = Date()
        saveRevisions()
        guard notesWrite else {
            heldDeletes.add([record.recordName])   // not for iCloud: for the move's drain
            return
        }
        guard let engine else { return }
        engine.state.add(pendingRecordZoneChanges: [.deleteRecord(record)])
    }

    func pushHealthSnapshot() {
        // JSONEncoder can never produce empty output for the Payload struct it encodes, so the
        // former `!data.isEmpty` guard was already vacuous — dropped along with the Data argument
        // so this call stays synchronous with HealthKitStore.persist() (see its doc comment).
        //
        // Only the phone publishes: it is the HealthKit reader and therefore the sole publisher of
        // this cache (`queueHealth` refuses anywhere else). `HealthKitStore.hide` and
        // `remove(workoutID:)` called on an iPad or a Mac route through `persist()` -> here and
        // stop; what they did reaches the phone as a request instead (`HealthRemovalInbox`),
        // and comes back to every device in the phone's next snapshot. (`unhide` there is still
        // that device's alone.)
        guard DeviceRole.current.isHub else { return }
        queueHealth(touchedNow: true)
        recomputeSyncState()
    }

    /// - Parameter force: bypass the "already saved with this content" gate. Used by the LWW
    ///   requeue branch in `apply()`, which must always re-send regardless of dirty state.
    private func queue(_ id: UUID, touchedNow: Bool, force: Bool = false) {
        // A workout without its raw file is not an uploadable authoritative record. This matters
        // on a newly installed Mac while it is still fetching; never let its old summary-only
        // cache overwrite the phone's complete asset.
        guard fitness?.samplesFileForCloudSync(id) != nil else {
            log.notice("deferred workout upload until raw samples are local: \(id.uuidString, privacy: .public)")
            return
        }
        let name = recordID(for: id).recordName
        if touchedNow {
            revisions[name] = Date(); saveRevisions()
            if workoutsWrite { markDirty(name) }
        }
        guard workoutsWrite, let engine else { return }   // read-only: the edit time is kept, nothing is sent
        // Gate the launch-time reseed (touchedNow == false) on "never saved, locally dirty, or
        // saved without its raw-sample asset" — a record CloudKit already has byte-for-byte does
        // not need to be re-sent every launch. `touchedNow == true` always passes via `dirty`.
        guard force || dirty.contains(name) || systemFields[name] == nil
            || (assetPending.contains(name) && shouldAttachSamplesAsset) else { return }
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID(for: id))])
    }

    private func queueHealth(touchedNow: Bool, force: Bool = false) {
        // The phone reads Health and is the one publisher of this cache. Every path that would
        // send it — launch seed, a local change, an account-change reseed, a conflict resend —
        // comes through here, so this one check keeps an iPad or a Mac from ever overwriting the
        // phone's facts with its own (an iPad reading its own Health would publish a partial copy
        // with a newer date, and the phone would adopt it).
        guard DeviceRole.current.isHub else { return }
        let name = Self.healthRecordName
        if touchedNow {
            revisions[name] = Date(); saveRevisions()
            if workoutsWrite { markDirty(name) }
        }
        guard workoutsWrite, let engine else { return }
        guard force || dirty.contains(name) || systemFields[name] == nil else { return }
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(healthRecordID)])
    }

    private func queueNote(_ id: UUID, touchedNow: Bool, force: Bool = false) {
        let name = noteRecordID(for: id).recordName
        if touchedNow {
            revisions[name] = Date(); saveRevisions()
            if notesWrite { markDirty(name) }
        }
        guard notesWrite, let engine else { return }
        guard force || dirty.contains(name) || systemFields[name] == nil else { return }
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(noteRecordID(for: id))])
    }

    /// Whether a poll is due: its zone changed (nil: couldn't tell), or its first read isn't done.
    func needsRefresh(changedZones: Set<String>?) -> Bool {
        guard let poller else { return false }
        return changedZones.map { $0.contains(Self.zoneName) } ?? true || !poller.caughtUp
    }

    /// Pull now — the regular fetch while the app is open (`CloudSyncPoll`).
    func refresh() {
        guard let engine else { return }
        let options = CKSyncEngine.FetchChangesOptions(scope: .zoneIDs([zoneID]))
        Task { try? await engine.fetchChanges(options) }
        guard let poller else { return }
        Task { @MainActor in
            SyncProgress.shared.willFetch(.fitness)
            await poller.poll()
            SyncProgress.shared.didFetch(.fitness)
        }
    }

    /// Fetches what changed on other devices — the engine only would on a push (`CloudZonePoller`).
    private var poller: CloudZonePoller?

    /// Fetched records and deletions — from the engine or the poller — applied in one batch.
    private func ingestFetched(_ records: [CKRecord], _ deletions: [CKRecord.ID]) async {
        // Only this zone's records and deletions — see `nextFetchChangesOptions`.
        let modifications = records.filter { $0.recordID.zoneID == zoneID }
        let removed = deletions.filter { $0.zoneID == zoneID }
        // Batch every workout adoption/removal in this fetch into one FitnessStore publish
        // instead of one per record — see FitnessStore.applyingCloudBatch. Harmless (and a
        // no-op) for the note/health records `apply`/`applyDeletion` also handle in the same
        // loop: only the workout branches ever touch the batch's working copy.
        // Only what this batch hands over counts as arriving: a workout deleted here while it waits
        // on the store is still this device's delete.
        var scope: [String: Set<String>?] = [:]
        for name in modifications.map(\.recordID.recordName) + removed.map(\.recordName) {
            switch CloudFitnessRecordRouting.classify(name, healthRecordName: Self.healthRecordName) {
            case .workout(let id): scope["health.workout", default: Set<String>()]?.insert(id.uuidString)
            case .note(let id): scope["notes.voiceNote", default: Set<String>()]?.insert(id.uuidString)
            case .health: scope["health.snapshot"] = .some(nil)
            case .unrecognised: break
            }
        }
        await LegacyCloud.applyingFromCloud(LegacyCloud.ApplyScope(scope)) {
            if let fitness {
                await fitness.applyingCloudBatch {
                    for record in modifications { await self.apply(record) }
                    for id in removed { self.applyDeletion(id) }
                }
            } else {
                for record in modifications { await apply(record) }
                for id in removed { applyDeletion(id) }
            }
            // Workouts from an old build after this device moved: late arrivals for the data
            // platform, once the batch is in the store (`MoveOver.changed`).
            reportArrivedWorkouts()
        }
        SyncProgress.shared.received(.fitness, count: modifications.count)
        // Coalesce this batch's revisions/systemFields writes into one UserDefaults set
        // instead of the 1-3 whole-dictionary writes `apply()` used to do per record.
        persistBookkeeping()
        // Once per fetch batch, however many records it contained — never once per record
        // inside the loop above (that would republish `syncState`, and every observer of it,
        // up to hundreds of times for one big fetch).
        recomputeSyncState()
    }

    private func syncImmediatelyAfterStart() {
        Task { @MainActor [weak self] in
            for delay in [0, 3, 10] {
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard !Task.isCancelled, let self, let engine = self.engine else { return }
                do {
                    if self.anyWrites { try await engine.sendChanges(.init(scope: .zoneIDs([self.zoneID]))) }
                    try await engine.fetchChanges(.init(scope: .zoneIDs([self.zoneID])))
                    self.log.notice("fitness cloudsync launch exchange complete")
                } catch {
                    // Offline/deferred delivery is expected; automatic sync and the next launch
                    // still retry. The point here is to eliminate needless latency when online.
                    self.log.notice("fitness cloudsync launch exchange deferred: \(error.localizedDescription, privacy: .public)")
                    // A hard throw here means the operation didn't run to completion — defensively
                    // clear the in-flight flags in case the matching didSend/didFetchChanges event
                    // (which normally does this) never fired, so `syncState` can't get stuck on
                    // `.syncing` forever after a failed attempt.
                    self.sending = false
                    self.fetching = false
                    self.recomputeSyncState()
                }
            }
        }
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard syncEngine === engine else { return }   // a late event from an engine let go (off)
        switch event {
        case .stateUpdate(let event):
            if let data = try? JSONEncoder().encode(event.stateSerialization) {
                UserDefaults.standard.set(data, forKey: Self.stateKey)
            }
        case .fetchedRecordZoneChanges(let event):
            await ingestFetched(event.modifications.map(\.record), event.deletions.map(\.recordID))
        case .sentRecordZoneChanges(let event):
            for record in event.savedRecords {
                remember(record)
                let name = record.recordID.recordName
                clearDirty(name)
                // Track whether OUR most recent successful send of this workout included the
                // raw-sample asset, so a launch-time reseed knows to re-offer just this record
                // once the schema-rejection cooldown (`shouldAttachSamplesAsset`) clears, instead
                // of re-offering every already-fully-synced workout.
                if name.hasPrefix("workout-") {
                    if record["samplesAsset"] == nil {
                        markAssetPending(name)
                    } else {
                        clearAssetPending(name)
                    }
                }
            }
            for failed in event.failedRecordSaves {
                // Retain the concrete server rejection on-device. CloudKit's OSLog is often not
                // retained on a tethered phone, and without this a failed initial seed looks like
                // an innocuous empty sync state.
                UserDefaults.standard.set(failed.error.localizedDescription,
                                          forKey: "fitnessCloudLastError")
                // `invalidArguments` is how CloudKit reports a field that is absent from the
                // deployed record schema. Requeue the exact same record without the asset: its
                // payload still carries speed, cadence, elevation, splits, and insights, which
                // lets the Mac render the analysis while raw-stream schema rollout catches up.
                let name = failed.record.recordID.recordName
                if name.hasPrefix("workout-") || name == Self.healthRecordName,
                   failed.error.code == .invalidArguments, workoutsWrite {
                    deferSamplesAssetUpload()
                    syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(failed.record.recordID)])
                    log.notice("raw workout asset deferred after schema rejection; syncing derived summary: \(failed.record.recordID.recordName, privacy: .public)")
                    continue
                }
                resolve(failed, engine: syncEngine)
            }
            persistBookkeeping()
            // Once per send batch — see the matching comment on the fetch case above.
            recomputeSyncState()
        case .willSendChanges:
            sending = true
            recomputeSyncState()
        case .didSendChanges:
            sending = false
            recomputeSyncState()
        case .willFetchChanges:
            fetching = true
            SyncProgress.shared.willFetch(.fitness)
            recomputeSyncState()
        case .didFetchChanges:
            fetching = false
            SyncProgress.shared.didFetch(.fitness)
            recomputeSyncState()
        case .accountChange(let event):
            switch event.changeType {
            case .signOut:
                accountSignedOut = true
            case .signIn, .switchAccounts:
                accountSignedOut = false
            @unknown default:
                break   // Leave the last known state alone rather than guess.
            }
            revisions.removeAll()
            systemFields.removeAll()
            // Nothing is "already saved" against a new account — mark every local record dirty
            // so the requeue below (and any later reseed) always re-sends it, exactly as today's
            // unconditional requeue does; unlike today, this also survives a relaunch before the
            // requeue's own sends land, since `dirty` persists across launches.
            var allNames = Set(fitness?.summaries.map { recordID(for: $0.id).recordName } ?? [])
            #if os(iOS)
            allNames.formUnion(notes?.allNoteIDs().map { noteRecordID(for: $0).recordName } ?? [])
            #endif
            if DeviceRole.current.isHub, health?.hasData == true { allNames.insert(Self.healthRecordName) }
            dirty = allNames.filter { mode(forName: $0).writes }
            assetPending.removeAll()
            saveDirty()
            saveAssetPending()
            persistBookkeeping()
            for summary in fitness?.summaries ?? [] { queue(summary.id, touchedNow: false) }
            #if os(iOS)
            for id in notes?.allNoteIDs() ?? [] { queueNote(id, touchedNow: false) }
            #endif
            if health?.hasData == true { queueHealth(touchedNow: false) }
            // Once for the whole reseed above, not once per summary/note/health queue() call.
            recomputeSyncState()
        default:
            break
        }
    }

    /// Fetch this engine's zone only. Every sync in the app shares the private database, and by
    /// default an engine fetches every zone in it: each one was downloading all the others'
    /// records — the workouts' raw-sample files included — and caching them as its own.
    func nextFetchChangesOptions(_ context: CKSyncEngine.FetchChangesContext,
                                 syncEngine: CKSyncEngine) async -> CKSyncEngine.FetchChangesOptions {
        var options = context.options
        options.scope = .zoneIDs([zoneID])
        return options
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                   syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        // Bound payload construction during a full account reseed. Remaining changes stay queued.
        var changes = Array(syncEngine.state.pendingRecordZoneChanges.lazy.filter { context.options.scope.contains($0) }.prefix(200))
        guard !changes.isEmpty else { return nil }
        // Moved off iCloud since it was queued: it stays here.
        let stopped = changes.filter { !mode(forName: $0.recordName).writes }
        if !stopped.isEmpty {
            syncEngine.state.remove(pendingRecordZoneChanges: stopped)
            changes.removeAll { !mode(forName: $0.recordName).writes }
            guard !changes.isEmpty else { return nil }
        }
        // Built once per batch instead of per record: a full reseed (account change, or many
        // queued changes at once) would otherwise do an O(n) `.first(where:)` scan per record,
        // turning the batch into O(n^2).
        let summariesByID = Dictionary(uniqueKeysWithValues: (fitness?.summaries ?? []).map { ($0.id, $0) })
        var records: [CKRecord.ID: CKRecord] = [:]
        for change in changes {
            guard case .saveRecord(let id) = change,
                  let record = build(id, summariesByID: summariesByID) else { continue }
            records[id] = record
        }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { records[$0] }
    }

    private func build(_ id: CKRecord.ID,
                        summariesByID: [UUID: FitnessSessionSummary]) -> CKRecord? {
        let record = existingRecord(for: id.recordName)
            ?? CKRecord(recordType: Self.recordType, recordID: id)
        if id == healthRecordID {
            guard let snapshot = health?.cloudSnapshot() else { return nil }
            // The Health cache rides as an asset: a record holds at most 1 MB, and the workout
            // list alone had passed 830 KB of JSON and grows with every workout. The payload then
            // just says where it is. If the asset field is ever refused, it goes inline (packed,
            // it still fits for now) until the retry.
            if shouldAttachSamplesAsset, let url = Self.writeHealthAsset(snapshot) {
                record["payload"] = HealthSnapshotCoding.inAsset as CKRecordValue
                record["samplesAsset"] = CKAsset(fileURL: url)
            } else {
                record["payload"] = snapshot as CKRecordValue
                record["samplesAsset"] = nil
            }
        } else if id.recordName.hasPrefix("note-") {
            let uuidText = id.recordName.replacingOccurrences(of: "note-", with: "")
            guard let uuid = UUID(uuidString: uuidText),
                  let note = notes?.note(uuid),
                  let payload = try? JSONEncoder().encode(note) else { return nil }
            record["payload"] = payload as CKRecordValue
        } else {
            let uuidText = id.recordName.replacingOccurrences(of: "workout-", with: "")
            guard let uuid = UUID(uuidString: uuidText),
                  let summary = summariesByID[uuid],
                  let samplesURL = fitness?.samplesFileForCloudSync(uuid),
                  let payload = try? JSONEncoder().encode(summary) else { return nil }
            record["payload"] = payload as CKRecordValue
            if shouldAttachSamplesAsset {
                record["samplesAsset"] = CKAsset(fileURL: samplesURL)
            }
        }
        return record
    }

    /// Both branches below route through `CloudFitnessRecordRouting.classify` (`Shared/
    /// FitnessModels.swift`) instead of their own `hasPrefix`/parse chain — see that type's doc
    /// comment for the bug this closes: an unrecognised record name silently misrouted into the
    /// workout branch, and either corrupted the index (on a lucky decode) or vanished with no
    /// trace (on a failed one). The switch below has no `default`, so a future record kind added
    /// to `CloudFitnessRecordKind` without updating this switch is a compile error, not a new
    /// silent gap.
    ///
    /// The `.workout` branch adds a second, narrower guard on top of that fix:
    /// `FitnessSessionSummary.hasPlausibleStart`. Routing only tells you a record's NAME looks
    /// like a workout; it says nothing about whether the payload underneath is a real one. A
    /// record named `workout-<uuid>` whose payload decodes to `start == .distantPast` passes
    /// routing (correct name) and decoding (syntactically valid `Date`) alike, and without the
    /// plausibility check would be adopted as a phantom workout exactly as before this file's fix
    /// — see that property's doc comment for why the check is a floor on `start`, not the exact
    /// sentinel value.
    private func apply(_ record: CKRecord) async {
        guard mode(forName: record.recordID.recordName).reads else { return }   // off: every device has moved
        let remoteDate = record.modificationDate ?? .distantPast
        let kind = CloudFitnessRecordRouting.classify(record.recordID.recordName, healthRecordName: Self.healthRecordName)
        if let localDate = revisions[record.recordID.recordName], localDate > remoteDate {
            // Local wins (LWW) — always re-send, bypassing the dirty/systemFields gate: the
            // server's copy is stale and must be overwritten regardless of our own bookkeeping.
            // Build the re-send on the SERVER's system fields: re-sending on our cached ones
            // carries a stale change tag, which CloudKit rejects ("client oplock error") and
            // hands straight back here — a loop that kept the record from ever saving again.
            // Only the tag: the local revision date stays, so it still wins the next comparison.
            rememberChangeTag(record)
            switch kind {
            case .health: queueHealth(touchedNow: false, force: true)
            case .note(let id): queueNote(id, touchedNow: false, force: true)
            case .workout(let id): queue(id, touchedNow: false, force: true)
            case .unrecognised:
                log.error("unrecognised record name in LWW resend — not re-queued: \(record.recordID.recordName, privacy: .public)")
            }
            return
        }
        guard let payload = record["payload"] as? Data else { return }
        switch kind {
        case .health:
            guard let snapshot = HealthSnapshotCoding.snapshot(payload: payload, asset: {
                (record["samplesAsset"] as? CKAsset)?.fileURL.flatMap { try? Data(contentsOf: $0) }
            }) else {
                log.error("health record's asset missing or unreadable — keeping the local cache")
                return
            }
            revisions[record.recordID.recordName] = remoteDate
            remember(record)
            clearDirty(record.recordID.recordName)
            health?.adoptCloudSnapshot(snapshot)
        case .note:
            guard let note = try? JSONDecoder().decode(VoiceNote.self, from: payload) else {
                // Previously this decode failure fell through into the workout branch below
                // (which had no `hasPrefix("workout-")` guard of its own) and vanished there
                // with no trace — a malformed note was silently discarded as a failed workout
                // decode. Now that the workout branch is properly guarded, a note that fails
                // to decode stays a note failure and is logged as one.
                log.error("dropped note record — payload failed to decode: \(record.recordID.recordName, privacy: .public)")
                return
            }
            revisions[record.recordID.recordName] = remoteDate
            remember(record)
            clearDirty(record.recordID.recordName)
            notes?.adoptCloudNote(note)
        case .workout:
            guard let summary = try? JSONDecoder().decode(FitnessSessionSummary.self, from: payload) else {
                log.error("dropped workout record — payload failed to decode: \(record.recordID.recordName, privacy: .public)")
                return
            }
            // The routing-guard fix above (`.unrecognised`) closes off ANY record whose NAME
            // this app doesn't recognise. It does nothing for a record that IS named
            // `workout-<uuid>` but whose PAYLOAD is corrupt in a way that still decodes cleanly
            // — `Date.distantPast` is a syntactically valid `Date`, so it sails through both the
            // routing guard and the decoder above. Only a plausibility check on the decoded value
            // catches this shape. See `FitnessSessionSummary.hasPlausibleStart` for the rule and
            // why it deliberately checks only `start`, not `sampleCount`.
            guard summary.hasPlausibleStart else {
                log.error("rejected workout record — implausible start date \(summary.start.timeIntervalSinceReferenceDate, privacy: .public): \(record.recordID.recordName, privacy: .public)")
                return
            }
            let assetURL = (record["samplesAsset"] as? CKAsset)?.fileURL
            guard let fitness, await fitness.adoptCloudWorkout(summary, samplesAssetURL: assetURL) else {
                log.error("did not publish remote workout without a safely installed raw asset: \(record.recordID.recordName, privacy: .public)")
                return
            }
            arrivedWorkouts.insert(summary.id)
            revisions[record.recordID.recordName] = remoteDate
            remember(record)
            clearDirty(record.recordID.recordName)
        case .unrecognised:
            // This is the bug that let CloudKit corrupt the fitness index: the workout branch
            // used to be a bare `else` with no name check, so ANY record this app didn't
            // recognise (a different record type, a future schema, a stray key) was attempted
            // as a workout decode. When that attempt happened to succeed, the record was
            // adopted as a phantom workout with whatever `start`/`id` its payload decoded to.
            // When it failed, it vanished with no trace — indistinguishable from "nothing
            // happened." Neither path may re-occur silently: log every unrecognised record
            // name so the next mismatch between this app's record types and what's actually
            // in the zone is visible instead of spreading through the fitness index unnoticed.
            log.error("unrecognised record type reached fitness sync apply — ignoring: \(record.recordID.recordName, privacy: .public)")
        }
    }

    private func applyDeletion(_ recordID: CKRecord.ID) {
        revisions.removeValue(forKey: recordID.recordName)
        saveRevisions()
        switch CloudFitnessRecordRouting.classify(recordID.recordName, healthRecordName: Self.healthRecordName) {
        case .note(let id):
            notes?.removeCloudNote(id)
        case .workout(let id):
            fitness?.removeCloudSummary(id)
        case .health:
            break   // The health cache has no delete path; an intentional no-op.
        case .unrecognised:
            // Same shape as `apply()` above: an unmatched record type used to silently no-op
            // here (excluded from the workout branch only by way of not being the health
            // record, not by way of actually looking like a workout). Now logged.
            log.error("unrecognised record type in deletion — ignoring: \(recordID.recordName, privacy: .public)")
        }
    }

    /// In-memory only — `revisions`/`systemFields` reach UserDefaults via `persistBookkeeping()`,
    /// called once per batch by every caller of `remember()` instead of once per record here.
    private func remember(_ record: CKRecord) {
        revisions[record.recordID.recordName] = record.modificationDate ?? Date()
        rememberChangeTag(record)
    }

    /// The record's system fields (its change tag) without its revision date.
    private func rememberChangeTag(_ record: CKRecord) {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        systemFields[record.recordID.recordName] = archiver.encodedData
    }

    private func resolve(_ failed: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave,
                         engine: CKSyncEngine) {
        guard let error = failed.error as? CKError, error.code == .serverRecordChanged,
              let server = error.serverRecord else {
            // Anything else (network, quota, throttle, a real rejection) — CKSyncEngine's own
            // backoff governs retries, and the record stays in `dirty` so `syncState` keeps
            // truthfully reporting it as waiting rather than silently dropping to "up to date."
            // What was previously missing is this line: nothing reached the Logger for any
            // failure that wasn't `serverRecordChanged`, so a persistently failing save was
            // invisible outside of the `fitnessCloudLastError` UserDefaults string set above.
            log.error("cloudsync save failed for \(failed.record.recordID.recordName, privacy: .public): \(failed.error.localizedDescription, privacy: .public)")
            return
        }
        // This resolution runs as a detached Task, after handleEvent's synchronous
        // .sentRecordZoneChanges case body (and its own persistBookkeeping() call) has already
        // returned — so it must flush its own apply()-driven revisions/systemFields mutation
        // itself, rather than relying on a persist that already happened before this Task ran.
        var scope: [String: Set<String>?] = [:]
        switch CloudFitnessRecordRouting.classify(server.recordID.recordName, healthRecordName: Self.healthRecordName) {
        case .workout(let id): scope["health.workout"] = [id.uuidString]
        case .note(let id): scope["notes.voiceNote"] = [id.uuidString]
        case .health: scope["health.snapshot"] = .some(nil)
        case .unrecognised: break
        }
        Task { @MainActor [weak self, scope] in
            await LegacyCloud.applyingFromCloud(LegacyCloud.ApplyScope(scope)) {
                await self?.apply(server)
                self?.reportArrivedWorkouts()
            }
            self?.persistBookkeeping()
            self?.recomputeSyncState()
        }
    }

    private func saveRevisions() {
        UserDefaults.standard.set(revisions, forKey: Self.revisionsKey)
    }

    /// Before fetches were scoped to this zone, the podcast engine's records arrived here too, and
    /// their system fields were cached beside the workouts' (486 of them on the Mac, next to 333
    /// real ones). Drop them once; `existingRecord` also refuses any that remain.
    private func purgeForeignSystemFieldsOnce() {
        let key = "ckSyncEngine.fitness.foreignFieldsPurged.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let before = systemFields.count
        systemFields = systemFields.filter { _, data in
            guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return false }
            coder.requiresSecureCoding = true
            let record = CKRecord(coder: coder)
            coder.finishDecoding()
            return record?.recordID.zoneID == zoneID
        }
        let foreignNames = Set(revisions.keys).subtracting(systemFields.keys).filter {
            CloudFitnessRecordRouting.classify($0, healthRecordName: Self.healthRecordName) == .unrecognised
        }
        for name in foreignNames { revisions.removeValue(forKey: name) }
        persistBookkeeping()
        UserDefaults.standard.set(true, forKey: key)
        log.notice("fitness cloudsync dropped \(before - self.systemFields.count) cached records from other zones")
    }

    /// Flushes the in-memory `revisions`/`systemFields` mutations `apply()`/`remember()` make
    /// during one CKSyncEngine event to UserDefaults exactly once, instead of the 1-3
    /// whole-dictionary writes those methods used to do per record.
    private func persistBookkeeping() {
        saveRevisions()
        UserDefaults.standard.set(systemFields, forKey: Self.systemFieldsKey)
    }

    /// `dirty`/`assetPending` are written synchronously on every change (unlike
    /// `persistBookkeeping()`, above) — see the doc comment on `dirtyKey`.
    private func markDirty(_ name: String) {
        if dirty.insert(name).inserted { saveDirty() }
    }
    private func clearDirty(_ name: String) {
        if dirty.remove(name) != nil { saveDirty() }
    }
    private func saveDirty() {
        UserDefaults.standard.set(Array(dirty), forKey: Self.dirtyKey)
    }
    private func markAssetPending(_ name: String) {
        if assetPending.insert(name).inserted { saveAssetPending() }
    }
    private func clearAssetPending(_ name: String) {
        if assetPending.remove(name) != nil { saveAssetPending() }
    }
    private func saveAssetPending() {
        UserDefaults.standard.set(Array(assetPending), forKey: Self.assetPendingKey)
    }

    private func existingRecord(for recordName: String) -> CKRecord? {
        guard let data = systemFields[recordName],
              let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        let record = CKRecord(coder: coder)
        coder.finishDecoding()
        // Never build on another zone's record, whatever the cache says.
        guard record?.recordID.zoneID == zoneID else { return nil }
        return record
    }

    // MARK: - Published sync state (see `FitnessSyncState` in Shared/FitnessModels.swift)

    /// Recomputes and (if it actually changed) republishes `syncState` from the live inputs:
    /// whether iCloud is usable right now, whether an exchange is in flight, and the current
    /// `dirty`/`assetPending` backlog. Called only at settle points — see every call site above —
    /// never from inside a per-record loop, so one big CloudKit batch republishes `syncState` (and
    /// re-renders every SwiftUI view observing it) once, not hundreds of times.
    private func recomputeSyncState() {
        let iCloudAvailable = engine != nil && !accountSignedOut
        let exchanging = sending || fetching
        let pendingCount = dirty.union(assetPending).count
        // The backlog reaching zero IS this class's definition of "a sync succeeded" — CKSyncEngine
        // itself exposes no separate success signal for automatic sync (see `FitnessSyncState`'s
        // doc comment). Only recorded while iCloud is actually usable, so a stale success can never
        // survive into the unavailable state — `FitnessSyncStateDerivation.derive` also guards on
        // `iCloudAvailable` independently, so this is belt-and-suspenders, not the only guard.
        if iCloudAvailable, pendingCount == 0 {
            lastSyncSuccess = Date()
            UserDefaults.standard.set(lastSyncSuccess, forKey: Self.lastSuccessKey)
        }
        let next = FitnessSyncStateDerivation.derive(
            iCloudAvailable: iCloudAvailable, exchanging: exchanging,
            pendingCount: pendingCount, lastSuccess: lastSyncSuccess)
        if next != syncState { syncState = next }
    }

    /// Per-workout truth about whether ITS recording has left this device for iCloud — see
    /// `WorkoutCloudUploadState`'s doc comment for exactly what each case does (and does not)
    /// claim. `hasLocalSamples` is supplied by the caller (`FitnessStore.hasLocalSamples`) rather
    /// than re-derived here, since callers already have it for the separate "raw data on this
    /// device" badge and the two questions share nothing else.
    func uploadState(for id: UUID, hasLocalSamples: Bool) -> WorkoutCloudUploadState {
        let name = recordID(for: id).recordName
        let isPending = dirty.contains(name) || assetPending.contains(name)
        // `engine != nil && !accountSignedOut` — same availability signal `recomputeSyncState()`
        // uses. Without it, a device where sync never started (this class's `dirty`/`assetPending`
        // sets never got past their empty initial value — see `start()`'s early-return guards)
        // would read every workout as `.uploaded` by default: empty sets look identical to "fully
        // synced" unless availability is checked separately, which is exactly the false
        // confidence `WorkoutCloudUploadState.unavailable` exists to prevent.
        return WorkoutCloudUploadStateDerivation.derive(
            hasLocalSamples: hasLocalSamples, iCloudAvailable: engine != nil && !accountSignedOut,
            isPending: isPending, exchanging: sending || fetching)
    }

    /// Workouts specifically among the pending backlog — `syncState`'s own `waiting(count:)`
    /// counts notes and the health cache too; Settings wants the workout-only figure.
    var pendingWorkoutCount: Int {
        dirty.union(assetPending).filter { $0.hasPrefix(CloudFitnessRecordRouting.workoutPrefix) }.count
    }

    /// Workouts whose summary reached iCloud but whose raw-sample file is still queued to attach
    /// — Settings' "still uploading" line. A strict subset of `pendingWorkoutCount`.
    var pendingRawRecordingCount: Int { assetPending.count }
}

#if DEBUG
// MARK: - Fitness zone corruption purge (operator-run, never automatic)
//
// The adopt-side guard above (`apply`'s `.workout` case) stops a phantom record from being
// re-adopted on this device from here on. It does nothing about the phantom records that were
// already written into the CloudKit "Fitness" zone before that guard existed — those still sit
// there, and until they're removed, any device is one full resync away from re-fetching (and
// re-rejecting, endlessly re-logging) the same records forever. This extension is the tool that
// removes them, wired behind two explicit, DEBUG-and-macOS-only launch arguments
// (`CloudFitnessZonePurgeTool`, in its own file) — `--purge-fitness-zone-dry-run` (report only)
// and `--purge-fitness-zone-apply` (report, then delete). Never reached by normal app operation.
//
// This purge does NOT query the zone to find what to delete — see
// `Shared/FitnessModels.swift`'s "Fitness-zone purge delete list" section for why a query cannot
// work in this container (exact CKError included there) and for the pure, unit-tested list-loading
// and overlap-validation logic. This extension is only the CloudKit-dependent half: turning an
// already-validated `FitnessZonePurgeDeleteList` into actual deletions through the sync engine.
extension CloudFitnessSync {
    /// A completed (or partially completed, if interrupted) purge run — written to disk before
    /// any deletion and again after every batch, so the run is auditable regardless of how far it
    /// got. `dryRun` is written into every report so one on disk can never be mistaken for
    /// evidence anything was actually deleted, and `wouldDeleteRecordNames`/`deletedRecordNames`
    /// are mutually exclusive by construction (only one is ever populated) for the same reason.
    struct ZonePurgeRunLog: Sendable, Codable {
        let generatedAt: Date
        /// Local path of the delete-list file this run was given, so the report is self-describing.
        let deleteListPath: String
        let dryRun: Bool
        let phantomCount: Int
        let realCountInFile: Int
        /// Populated ONLY when `dryRun == true` — the exact record names this run would delete had
        /// it been `--purge-fitness-zone-apply`. Always empty for a real run.
        var wouldDeleteRecordNames: [String]
        /// Populated ONLY when `dryRun == false`, appended to after every batch actually sent to
        /// the sync engine. Always empty for a dry run.
        var deletedRecordNames: [String]
        var completedAt: Date?
    }

    enum ZonePurgeError: Error {
        /// `start(fitness:health:notes:)` never constructed a `CKSyncEngine` for this launch —
        /// either iCloud is unavailable (Simulator, missing entitlement, `--disable-icloud`) or
        /// this ran before `wireUp()` reached that call. Refusing here, rather than constructing
        /// `container` fresh, matters: `container`'s own doc comment warns that merely
        /// constructing a `CKContainer` on an unsigned/unentitled build can terminate the process
        /// outside CloudKit's normal error handling.
        case engineNotStarted
    }

    /// Validates `deleteList` against a FRESH read of the live local index (see
    /// `FitnessZonePurgePlan.validate` for the two checks and why both must pass), then either
    /// reports what it would delete (`dryRun == true`, no CloudKit writes at all) or actually
    /// deletes, through the sync engine's own deletion path
    /// (`state.add(pendingRecordZoneChanges: [.deleteRecord(...)])` + `sendChanges()` — the
    /// identical mechanism the ordinary `delete(_:)` above uses for a real workout) in batches of
    /// `batchSize`, writing `reportURL` before deleting anything and again after every batch so
    /// the run is fully auditable even if it is interrupted partway through.
    ///
    /// SAFETY: validation always runs against a freshly computed set of local real record names —
    /// never a cached or caller-supplied one — so a stale delete list (evidence gathered before a
    /// new real workout synced) is caught here even if it looked safe when the list was generated.
    /// Throws (aborting before any write) rather than skipping just the offending name, because a
    /// list that overlaps reality anywhere means the list itself is wrong.
    ///
    /// Idempotent: a record already gone (deleted by an earlier run of this same method, or never
    /// present) is simply a no-op delete as far as the sync engine's batch send is concerned —
    /// `sendChanges()` reports per-record failures through the delegate, it does not throw for one
    /// missing record — so re-running after a partial or complete previous purge is safe and never
    /// errors on a record that is already gone.
    @discardableResult
    func purgeCorruptWorkouts(deleteList: FitnessZonePurgeDeleteList, deleteListPath: String,
                              dryRun: Bool, reportURL: URL, batchSize: Int = 200) async throws -> ZonePurgeRunLog {
        guard let engine else { throw ZonePurgeError.engineNotStarted }

        let liveRealRecordNames = Set((fitness?.summaries ?? []).map { FitnessZonePurgePlan.workoutRecordName(for: $0.id) })
        try FitnessZonePurgePlan.validate(deleteList, liveRealRecordNames: liveRealRecordNames)

        var runLog = ZonePurgeRunLog(generatedAt: Date(), deleteListPath: deleteListPath, dryRun: dryRun,
                                     phantomCount: deleteList.phantomRecordNames.count,
                                     realCountInFile: deleteList.realRecordNames.count,
                                     wouldDeleteRecordNames: dryRun ? deleteList.phantomRecordNames : [],
                                     deletedRecordNames: [], completedAt: nil)
        Self.writeRunLog(runLog, to: reportURL)   // written BEFORE any deletion — the pre-purge record

        guard !dryRun else {
            runLog.completedAt = Date()
            Self.writeRunLog(runLog, to: reportURL)
            return runLog
        }

        var start = 0
        let names = deleteList.phantomRecordNames
        while start < names.count {
            let end = min(start + batchSize, names.count)
            let batch = names[start..<end]
            let ids = batch.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
            // Moved off iCloud: nothing is deleted there by this device any more (Stage E purges).
            guard workoutsWrite else { break }
            engine.state.add(pendingRecordZoneChanges: ids.map { .deleteRecord($0) })
            try await engine.sendChanges()
            runLog.deletedRecordNames.append(contentsOf: batch)
            Self.writeRunLog(runLog, to: reportURL)
            start = end
        }
        runLog.completedAt = Date()
        Self.writeRunLog(runLog, to: reportURL)
        return runLog
    }

    private static func writeRunLog(_ log: ZonePurgeRunLog, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(log) else { return }
        PrivateReport.write(data, toPath: url.path)
    }
}
#endif

extension CKSyncEngine.PendingRecordZoneChange {
    /// The record a queued save or delete is for.
    var recordName: String {
        switch self {
        case .saveRecord(let id), .deleteRecord(let id): id.recordName
        @unknown default: ""
        }
    }
}
