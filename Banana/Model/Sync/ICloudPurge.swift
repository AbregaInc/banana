import Foundation

/// The purge (docs/design/DATA-PLATFORM.md §8 step 4): everything Banana left in iCloud is deleted,
/// once the account says so, and again every week while it does.
///
/// **The gate.** Nothing is deleted unless all of these hold:
/// - the data platform is on (`SpaceSyncFlag`);
/// - `/v1/account` says `"icloud": "purge"` (every device active in 30 days has seeded and
///   flipped, and, on the author's account, his yes);
/// - this device has flipped: no tier writes iCloud (its mode isn't `readWrite`) and each tier's
///   move is past its seed (`flipped`, `held` or `off`);
/// - every tier's legacy readers are `off`, or `readOnly` with nothing of the move still to do
///   (no delete waiting to reach the space, no item waiting to leave the stores).
///
/// It runs at most once a launch, and again a week after the last complete run (kept per account):
/// an old build coming back after 30 days would otherwise make a zone again. Each step is
/// idempotent (what isn't there is done), so a run that stopped partway (offline, signed out of
/// iCloud) simply runs again at the next launch. Before each step it checks again that no tier
/// writes iCloud.
///
/// **What goes**, in this order:
/// 1. the legacy channels go `off`, so nothing reads or makes again what follows;
/// 2. the meals zone's subscription;
/// 3. the six zones of the container's private database (`zones`), and with Fitness the bad
///    records `CloudFitnessZonePurgeTool` was made for;
/// 4. every key-value key of DATA-INVENTORY.md but the two that stay (`LegacyKVS.keptKeys`), each
///    first copied to this device if it hadn't been read since the move (`LegacyKVS`);
/// 5. iCloud Drive's `Documents/backup.plist`, `previous-backup.plist`, `Transcripts/` and
///    `VoiceNotes/`;
/// 6. in the legacy container (`AppCloud.legacyContainerID`), what the read-once restore reads
///    there: its `Documents/backup.plist` and `previous-backup.plist`. A build not entitled to
///    that container can't reach it, and says so;
/// 7. this device's own bookkeeping for the purged zones (`localState`): the engines' saved
///    state, the poll tokens, the system fields, what was queued to send.
///
/// The time of the last complete run is kept here (`Record.purgedAt`): the service's
/// `PUT /v2/devices/:id/sync-state` takes `seededAt`, `flippedAt` and `seeded` only.
@MainActor
final class ICloudPurge {
    /// The private database's zones (DATA-INVENTORY.md "CloudKit").
    static let zones = ["Controls", "Meals", "Wellness", "Settings", "Fitness", "Progress"]
    /// The meals zone's push (`MealBacklogWake.subscriptionID`).
    static let mealsSubscriptionID = "meals-zone-changes"
    /// The moved key-value keys: the inventory's, which leaves out the two that stay.
    static var keys: [String] { LegacyInventory.keys.keys.filter { !LegacyKVS.keptKeys.contains($0) }.sorted() }
    /// Under the container's `Documents/`.
    static let driveItems = ["backup.plist", "previous-backup.plist", "Transcripts", "VoiceNotes"]
    /// Under the legacy container's `Documents/`: what `CloudBackup`'s restore reads there.
    static let legacyDriveItems = ["backup.plist", "previous-backup.plist"]
    static let repeatInterval: TimeInterval = 7 * 86_400

    /// This device's bookkeeping for the purged zones: nothing in it is anyone's data, and with it
    /// gone no engine has a zone save or a record queued.
    enum LocalState {
        /// `UserDefaults` keys with these prefixes: every CKSyncEngine's saved state and queues
        /// (`ckSyncEngine.<zone>.…`) and the zone polls' change tokens.
        static let prefixes = ["ckSyncEngine.", "zonePoll."]
        static let keys = ["dbChanges.private.token", "mealsPush.subscribed.v1"]
        /// In `AppSupport.directory`: the syncs' state and system fields.
        static let files = [
            "cloud-controls-sync.plist", "cloud-controls-fields.plist",
            "cloud-meals-sync.plist", "cloud-meals-fields.plist",
            "cloud-wellness-sync.plist", "cloud-wellness-fields.plist",
            "ckProgressRecords.json", "ckProgressConfirmed.json",
        ]
    }

    /// What the gate looks at.
    struct Situation {
        /// The data platform is on (`SpaceSyncFlag`).
        var asked: Bool
        /// `/v1/account`'s `icloud`.
        var icloud: String?
        /// The move on this device, for this account.
        var move: MoveOver.State
    }

    enum Skip: Equatable {
        case notAsked
        case notFlagged
        /// This tier still writes iCloud, or hasn't finished its seed.
        case notFlipped(LegacyTier)
        /// This tier reads iCloud with something of the move still to do.
        case readersBusy(LegacyTier)
        case ranThisLaunch
        case notDue
        /// This process may not use iCloud (no entitlement, `--disable-icloud`, the Simulator).
        case noICloud
    }

    struct Report: Equatable {
        var subscriptions = 0
        var zonesDeleted = 0
        var zonesGone = 0
        var keysRemoved = 0
        var driveFiles = 0
        var legacyFiles = 0
        /// False when this build can't reach the legacy container; nil when none is configured.
        var legacyReachable: Bool?
        var localCleared = 0
        /// What will be tried again at the next launch.
        var failures: [String] = []
    }

    enum Outcome: Equatable {
        case skipped(Skip)
        case done(Report)
        /// Something couldn't be deleted now: tried again at the next launch.
        case incomplete(Report)
    }

    /// Kept per account.
    struct Record: Codable, Equatable {
        /// The last complete run: the next is due a week later.
        var purgedAt: Date?
        /// The first complete run.
        var firstPurgedAt: Date?
    }

    /// The accounts purged (or tried) in this process: at most once a launch.
    final class LaunchMemory {
        static let shared = LaunchMemory()
        var accounts: Set<String> = []
        init() {}
    }

    struct Dependencies {
        var cloudKit: any ICloudPurgeCloudKit
        var drive: any ICloudPurgeDrive
        /// iCloud's key-value store itself (never `LegacyKVS`, which would keep the write here).
        var keyValues: any LegacyKeyValueStore
        /// Where `LegacyKVS` keeps this device's copies (`UserDefaults.standard`).
        var keyValueCopies: UserDefaults
        /// The container this build syncs through, and the earlier app's.
        var container: String
        var legacyContainer: String?
        /// Whether this process may use iCloud at all.
        var iCloudAllowed: Bool
        /// This device's bookkeeping (`LocalState`): its defaults and its support folder.
        var localDefaults: UserDefaults
        var supportDirectory: URL
        /// Where the record is kept (`stateKey(account:)`) and in what.
        var account: String
        var defaults: UserDefaults
        /// Each tier's mode now (`LegacyCloud.mode`), and how a tier is turned off (`LegacyCloud.set`).
        var mode: @MainActor (LegacyTier) -> LegacyCloudMode
        var turnOff: @MainActor (LegacyTier) -> Void
        var launch: LaunchMemory = .shared
        var now: () -> Date = { Date() }
        var log: (String) -> Void = { _ in }
    }

    let deps: Dependencies

    init(_ deps: Dependencies) { self.deps = deps }

    static func stateKey(account: String) -> String { "iCloudPurge.\(account)" }

    var record: Record {
        deps.defaults.data(forKey: Self.stateKey(account: deps.account))
            .flatMap { try? JSONDecoder().decode(Record.self, from: $0) } ?? Record()
    }

    private func save(_ record: Record) {
        if let data = try? JSONEncoder().encode(record) { deps.defaults.set(data, forKey: Self.stateKey(account: deps.account)) }
    }

    // MARK: - The gate

    /// Nil when the purge may run; otherwise why not. Pure, but for the modes.
    func gate(_ situation: Situation) -> Skip? {
        guard situation.asked else { return .notAsked }
        guard situation.icloud == "purge" else { return .notFlagged }
        for tier in LegacyTier.allCases {
            let phase = situation.move[tier].phase
            guard !deps.mode(tier).writes, [.flipped, .held, .off].contains(phase) else { return .notFlipped(tier) }
        }
        for tier in LegacyTier.allCases where deps.mode(tier) == .readOnly {
            let move = situation.move[tier]
            if !move.pendingDeletes.isEmpty || !move.absent.isEmpty { return .readersBusy(tier) }
        }
        return nil
    }

    private var writesNowhere: Bool { LegacyTier.allCases.allSatisfy { !deps.mode($0).writes } }

    // MARK: - The run

    /// The purge, if the gate is open and it's due. `MoveOver` calls this after each step.
    @discardableResult
    func runIfDue(_ situation: Situation) async -> Outcome {
        if let skip = gate(situation) { return .skipped(skip) }
        guard !deps.launch.accounts.contains(deps.account) else { return .skipped(.ranThisLaunch) }
        if let last = record.purgedAt, deps.now().timeIntervalSince(last) < Self.repeatInterval { return .skipped(.notDue) }
        deps.launch.accounts.insert(deps.account)
        guard deps.iCloudAllowed else {
            deps.log("not purged: this process can't use iCloud")
            return .skipped(.noICloud)
        }
        deps.log("purging what Banana left in iCloud")
        var report = Report()

        // 1. Nothing reads or makes again what goes next.
        for tier in LegacyTier.allCases where deps.mode(tier) != .off { deps.turnOff(tier) }

        // 2–3. CloudKit.
        if step("the meals zone's subscription", &report) {
            do {
                if try await deps.cloudKit.subscriptionIDs(container: deps.container).contains(Self.mealsSubscriptionID) {
                    switch try await deps.cloudKit.deleteSubscriptions([Self.mealsSubscriptionID], container: deps.container)[Self.mealsSubscriptionID] {
                    case .deleted?: report.subscriptions += 1
                    case .failed(let why)?: report.failures.append("subscription: \(why)")
                    case .missing?, nil: break
                    }
                }
                deps.log("meals zone subscription: \(report.subscriptions) deleted")
            } catch {
                report.failures.append("subscription: \(error.localizedDescription)")
            }
        }
        if step("the zones", &report) {
            do {
                let present = try await deps.cloudKit.zoneNames(container: deps.container).intersection(Self.zones)
                report.zonesGone = Self.zones.count - present.count
                if !present.isEmpty {
                    let results = try await deps.cloudKit.deleteZones(present.sorted(), container: deps.container)
                    for name in present.sorted() {
                        switch results[name] {
                        case .deleted?: report.zonesDeleted += 1
                        case .missing?: report.zonesGone += 1
                        case .failed(let why)?: report.failures.append("zone \(name): \(why)")
                        case nil: report.failures.append("zone \(name): no answer")
                        }
                    }
                }
                deps.log("zones: \(report.zonesDeleted) deleted, \(report.zonesGone) already gone")
            } catch {
                report.failures.append("zones: \(error.localizedDescription)")
            }
        }

        // 4. The key-value store.
        if step("the key-value keys", &report) {
            for key in Self.keys {
                LegacyKVS.keepCopyIfMissing(forKey: key, from: deps.keyValues, local: deps.keyValueCopies)
                guard deps.keyValues.object(forKey: key) != nil else { continue }
                deps.keyValues.removeObject(forKey: key)
                report.keysRemoved += 1
            }
            deps.keyValues.synchronize()
            deps.log("key-value store: \(report.keysRemoved) of \(Self.keys.count) key(s) removed, \(LegacyKVS.keptKeys.count) kept")
        }

        // 5. iCloud Drive.
        if step("iCloud Drive", &report) {
            if let documents = await deps.drive.documents(container: deps.container) {
                for item in Self.driveItems {
                    do { report.driveFiles += try await deps.drive.remove(documents.appendingPathComponent(item)) } catch {
                        report.failures.append("Drive \(item): \(error.localizedDescription)")
                    }
                }
                deps.log("iCloud Drive: \(report.driveFiles) file(s) removed")
            } else {
                report.failures.append("iCloud Drive isn't available")
            }
        }

        // 6. The legacy container.
        if let legacy = deps.legacyContainer, step("the legacy container", &report) {
            if let documents = await deps.drive.documents(container: legacy) {
                report.legacyReachable = true
                for item in Self.legacyDriveItems {
                    do { report.legacyFiles += try await deps.drive.remove(documents.appendingPathComponent(item)) } catch {
                        report.failures.append("legacy \(item): \(error.localizedDescription)")
                    }
                }
                deps.log("legacy container \(legacy): \(report.legacyFiles) file(s) removed")
            } else {
                // Not a failure to retry: this build isn't entitled to it (or its Drive is off).
                report.legacyReachable = false
                deps.log("⚠️ legacy container \(legacy): this build can't reach it (not in its entitlements); nothing deleted there")
            }
        }

        // 7. This device's bookkeeping for the zones that went.
        report.localCleared = clearLocalState()
        deps.log("local sync state: \(report.localCleared) item(s) cleared")

        guard report.failures.isEmpty else {
            deps.log("purge incomplete, tried again at the next launch: \(report.failures.joined(separator: "; "))")
            return .incomplete(report)
        }
        let now = deps.now()
        var kept = record
        kept.purgedAt = now
        kept.firstPurgedAt = kept.firstPurgedAt ?? now
        save(kept)
        deps.log("purged; again in a week while the account asks (kept on this device: the service has no field for it)")
        return .done(report)
    }

    /// Whether a deleting step may go ahead: never while a tier writes iCloud.
    private func step(_ name: String, _ report: inout Report) -> Bool {
        guard writesNowhere else {
            report.failures.append("\(name): a tier writes iCloud again")
            deps.log("⚠️ not deleting \(name): a tier on this device writes iCloud")
            return false
        }
        return true
    }

    private func clearLocalState() -> Int {
        var cleared = 0
        let defaults = deps.localDefaults
        for key in defaults.dictionaryRepresentation().keys
        where LocalState.prefixes.contains(where: key.hasPrefix) || LocalState.keys.contains(key) {
            defaults.removeObject(forKey: key)
            if defaults.object(forKey: key) == nil { cleared += 1 }   // not one the launch arguments set
        }
        for name in LocalState.files {
            let url = deps.supportDirectory.appendingPathComponent(name)
            if (try? FileManager.default.removeItem(at: url)) != nil { cleared += 1 }
        }
        return cleared
    }
}

/// What deleting one item came to.
enum ICloudPurgeOutcome: Equatable {
    case deleted
    /// It wasn't there: done.
    case missing
    case failed(String)
}

/// The container's private database, as the purge needs it.
@MainActor protocol ICloudPurgeCloudKit {
    func zoneNames(container: String) async throws -> Set<String>
    func deleteZones(_ names: [String], container: String) async throws -> [String: ICloudPurgeOutcome]
    func subscriptionIDs(container: String) async throws -> Set<String>
    func deleteSubscriptions(_ ids: [String], container: String) async throws -> [String: ICloudPurgeOutcome]
}

/// iCloud Drive, as the purge needs it.
@MainActor protocol ICloudPurgeDrive {
    /// A ubiquity container's `Documents/`; nil when this build can't reach it (not entitled, or
    /// iCloud Drive is off for the app).
    func documents(container: String) async -> URL?
    /// Removes a file or a folder, coordinated: the number of files that went (0: it wasn't there).
    func remove(_ url: URL) async throws -> Int
}
