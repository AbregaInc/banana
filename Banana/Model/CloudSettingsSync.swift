import CloudKit
import Foundation
import OSLog

/// Instant cross-device settings sync via CloudKit push — the production fast path when
/// devices are NOT on the same Wi-Fi. Three tiers total: the LAN peer channel covers
/// co-located devices instantly, this covers everywhere-else in seconds, and legacy KVS
/// remains a slow fallback for old builds.
///
/// Deliberately its own tiny `CKSyncEngine` with its own zone: settings must never be able
/// to disturb the Progress engine that guards listening history. One record, rare writes —
/// so unlike progress, automatic (push-scheduled) sync is safe and gives the low latency.
@MainActor
final class CloudSettingsSync: NSObject, CKSyncEngineDelegate {
    static let shared = CloudSettingsSync()

    private let log = Logger(subsystem: "com.boris.banana", category: "cloudsync")
    /// Lazy for the same reason as CloudProgressSync: constructing CKContainer on a build
    /// without iCloud entitlements can terminate the process. `startIfPossible` probes the
    /// entitlement first and never touches this on unentitled builds.
    private lazy var container = CKContainer(identifier: AppCloud.containerID)
    private static let zoneName = "Settings"
    private static let recordType = "SettingsSnapshot"
    private static let recordName = "smart-settings"
    private static let stateKey = "ckSyncEngine.settings.state"
    private static let systemFieldsKey = "ckSyncEngine.settings.systemFields"

    private var engine: CKSyncEngine?
    private var pendingPayload: Data?

    /// Incoming snapshots land here; SmartScheduleStore's last-writer-wins adoption decides.
    var onSnapshot: ((Data) -> Void)?

    private override init() { super.init() }

    // MARK: - The move off iCloud (`LegacyCloud`)

    private var mode: LegacyCloudMode { LegacyCloud.mode(.personal) }

    /// The mode changed (`LegacyCloud.set`): read-only drops what waits (the engine stays as it is:
    /// made again, it would bring back what it had queued); off, the engine goes.
    func modeChanged() {
        guard let engine else { return }
        guard mode.reads else {
            self.engine = nil
            log.notice("settings cloudsync off: every device has moved")
            return
        }
        guard !mode.writes else { return }
        dropUnwritable(engine)
        log.notice("settings cloudsync read-only")
    }

    /// Read-only: what the engine has queued goes, the zone save too.
    private func dropUnwritable(_ engine: CKSyncEngine) {
        guard !mode.writes else { return }
        engine.state.remove(pendingRecordZoneChanges: engine.state.pendingRecordZoneChanges)
        engine.state.remove(pendingDatabaseChanges: engine.state.pendingDatabaseChanges)
        pendingPayload = nil
    }

    /// The move's complete fetch (`LegacyChannel.drainToEnd`): what waits goes up while it still
    /// writes, then the one record is read and handed over.
    func drainToEnd() async throws -> DrainResult {
        // No iCloud for this build (unentitled, turned off): nothing was ever here.
        guard !ProcessInfo.processInfo.arguments.contains("--disable-icloud"), Self.hasCloudKitEntitlement else { return DrainResult() }
        guard let engine else {
            if !mode.reads { return DrainResult() }   // off: done
            throw LegacyDrainError.notRunning("settings zone")
        }
        var result = DrainResult()
        if !engine.state.pendingRecordZoneChanges.isEmpty { result.note(\.dirty, type: "core.smartSettings", id: Self.recordName) }
        if mode.writes {
            do { try await engine.sendChanges(.init(scope: .zoneIDs([zoneID]))) } catch {
                log.notice("settings drain: send deferred: \(error.localizedDescription, privacy: .public)")
            }
        }
        do {
            let record = try await container.privateCloudDatabase.record(for: recordID)
            applyFetched(record)
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            // Never saved by any device: nothing to read.
        }
        return result
    }

    private func makeEngine() {
        let serialized = UserDefaults.standard.data(forKey: Self.stateKey)
            .flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        var config = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: serialized,
            delegate: self)
        // Automatic: settings change a handful of times a day; push-scheduled sends give
        // second-level propagation with negligible radio cost (unlike 30s progress ticks).
        // Read-only (the move off iCloud): no sending on its own.
        config.automaticallySync = mode.writes
        let made = CKSyncEngine(config)
        engine = made
        dropUnwritable(made)
    }

    /// True when this build carries its expected iCloud container entitlement. Merely
    /// constructing CKContainer in an unentitled local build can kill the process.
    private static var hasCloudKitEntitlement: Bool {
        AppCloud.hasContainerEntitlement
    }

    func startIfPossible() {
        guard engine == nil else { return }
        guard !ProcessInfo.processInfo.arguments.contains("--disable-icloud") else { return }
        guard Self.hasCloudKitEntitlement else {
            log.notice("settings cloudsync skipped: no iCloud entitlement in this build")
            return
        }
        guard mode.reads else { return }   // moved to the Banana service
        makeEngine()
        guard let engine else { return }
        if mode.writes { engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneName: Self.zoneName))]) }
        log.notice("settings cloudsync started")
    }

    /// Publish the freshest snapshot. Cheap and idempotent — the engine coalesces sends.
    func push(_ payload: Data) {
        guard mode.writes else { return }   // moved off iCloud: the LAN peer and the service carry it
        pendingPayload = payload
        guard let engine else { return }
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
    }

    private var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: Self.zoneName) }
    private var recordID: CKRecord.ID { CKRecord.ID(recordName: Self.recordName, zoneID: zoneID) }

    // MARK: - CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard syncEngine === engine else { return }   // a late event from an engine let go (off)
        switch event {
        case .stateUpdate(let e):
            if let data = try? JSONEncoder().encode(e.stateSerialization) {
                UserDefaults.standard.set(data, forKey: Self.stateKey)
            }

        case .fetchedRecordZoneChanges(let e):
            for mod in e.modifications { applyFetched(mod.record) }

        case .sentRecordZoneChanges(let e):
            for saved in e.savedRecords { rememberSystemFields(saved) }
            for failed in e.failedRecordSaves { resolveFailedSave(failed, syncEngine: syncEngine) }

        case .accountChange:
            break   // adoption is snapshot-driven; a new account simply fetches fresh

        default:
            break
        }
    }

    /// This zone only. By default an engine fetches every zone in the database, and this one's
    /// single remembered record ended up being whichever record arrived last — a podcast
    /// episode's, on the Mac — so a push could be built on someone else's record.
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
        guard mode.writes else {
            syncEngine.state.remove(pendingRecordZoneChanges: changes)
            return nil
        }
        guard !changes.isEmpty, let record = buildRecord() else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { _ in record }
    }

    // MARK: - Record <-> snapshot

    private func buildRecord() -> CKRecord? {
        guard let payload = pendingPayload else { return nil }
        let record = existingRecord() ?? CKRecord(recordType: Self.recordType, recordID: recordID)
        record["payload"] = payload as CKRecordValue
        return record
    }

    private func applyFetched(_ record: CKRecord) {
        // Only the settings record — other syncs' records share the database and the payload key.
        guard record.recordID == recordID else { return }
        rememberSystemFields(record)
        guard let payload = record["payload"] as? Data, mode.reads else { return }
        log.notice("settings cloudsync fetched a snapshot")
        LegacyCloud.applyingFromCloud { onSnapshot?(payload) }
    }

    /// Another device saved first. Adopt its snapshot (LWW decides whether it applies),
    /// take its change tag, and re-send ours if we still hold a pending payload — the
    /// adoption above will have replaced it when the server's copy was newer.
    private func resolveFailedSave(_ failed: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave,
                                   syncEngine: CKSyncEngine) {
        guard let ckError = failed.error as? CKError,
              ckError.code == .serverRecordChanged,
              let server = ckError.serverRecord else { return }
        applyFetched(server)
        if mode.writes { syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)]) }
    }

    private func rememberSystemFields(_ record: CKRecord) {
        guard record.recordID == recordID else { return }
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        UserDefaults.standard.set(archiver.encodedData, forKey: Self.systemFieldsKey)
    }

    private func existingRecord() -> CKRecord? {
        guard let data = UserDefaults.standard.data(forKey: Self.systemFieldsKey),
              let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = true
        // A remembered record that isn't the settings record came from another zone before
        // fetches were scoped; start fresh rather than write settings into it.
        guard let record = CKRecord(coder: unarchiver), record.recordID == recordID else { return nil }
        return record
    }
}
