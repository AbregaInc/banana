import XCTest

/// The private database, held in memory: zones and subscriptions per container.
@MainActor
final class FakePurgeCloudKit: ICloudPurgeCloudKit {
    var zones: [String: Set<String>] = [:]
    var subscriptions: [String: Set<String>] = [:]
    /// Listed, but gone by the time they're deleted (another device purged meanwhile).
    var vanishing: Set<String> = []
    var offline = false
    /// Run at every call (a test changes the world mid-run).
    var onCall: (() -> Void)?
    private(set) var deletedZones: [String] = []
    private(set) var deletedSubscriptions: [String] = []
    private(set) var calls = 0

    struct Offline: Error {}

    private func call() throws {
        calls += 1
        onCall?()
        if offline { throw Offline() }
    }

    func zoneNames(container: String) async throws -> Set<String> {
        try call()
        return zones[container] ?? []
    }

    func deleteZones(_ names: [String], container: String) async throws -> [String: ICloudPurgeOutcome] {
        try call()
        var results: [String: ICloudPurgeOutcome] = [:]
        for name in names {
            if vanishing.contains(name) || zones[container]?.contains(name) != true {
                zones[container]?.remove(name)
                results[name] = .missing
            } else {
                zones[container]?.remove(name)
                deletedZones.append(name)
                results[name] = .deleted
            }
        }
        return results
    }

    func subscriptionIDs(container: String) async throws -> Set<String> {
        try call()
        return subscriptions[container] ?? []
    }

    func deleteSubscriptions(_ ids: [String], container: String) async throws -> [String: ICloudPurgeOutcome] {
        try call()
        var results: [String: ICloudPurgeOutcome] = [:]
        for id in ids {
            let had = subscriptions[container]?.remove(id) != nil
            if had { deletedSubscriptions.append(id) }
            results[id] = had ? .deleted : .missing
        }
        return results
    }
}

/// iCloud Drive, held in memory: the files of each reachable container, by path.
@MainActor
final class FakePurgeDrive: ICloudPurgeDrive {
    var reachable: Set<String> = []
    var files: Set<String> = []
    var failing: Set<String> = []
    private(set) var removed: [String] = []

    struct Busy: Error {}

    static func documents(_ container: String) -> URL { URL(fileURLWithPath: "/fake/\(container)/Documents") }

    func documents(container: String) async -> URL? {
        reachable.contains(container) ? Self.documents(container) : nil
    }

    func remove(_ url: URL) async throws -> Int {
        if failing.contains(url.lastPathComponent) { throw Busy() }
        let going = files.filter { $0 == url.path || $0.hasPrefix(url.path + "/") }
        files.subtract(going)
        removed.append(contentsOf: going.sorted())
        return going.count
    }
}

/// iCloud's key-value store, held in memory, counting what was written.
final class PurgeKeyValues: LegacyKeyValueStore {
    var values: [String: Any] = [:]
    private(set) var writes: [String] = []
    private(set) var synchronized = 0

    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { writes.append(key); values[key] = value }
    func removeObject(forKey key: String) { writes.append(key); values[key] = nil }
    func synchronize() -> Bool { synchronized += 1; return true }
}

/// The purge (docs/design/DATA-PLATFORM.md §8 step 4): its gate, what it deletes, the kept keys,
/// idempotency, the weekly repeat, and never while a tier writes iCloud. Against fakes: nothing
/// here touches iCloud.
@MainActor
final class ICloudPurgeTests: XCTestCase {
    private let container = "iCloud.test.banana"
    private let legacy = "iCloud.test.quarters"
    private var cloudKit: FakePurgeCloudKit!
    private var drive: FakePurgeDrive!
    private var keyValues: PurgeKeyValues!
    private var defaults: UserDefaults!
    private var support: URL!
    private var modes: LegacyCloudModeStore!
    private var launch: ICloudPurge.LaunchMemory!
    private var now = Date()
    private var logs: [String] = []

    /// Not Banana's: left alone.
    private let otherZone = "Elsewhere"

    override func setUp() async throws {
        cloudKit = FakePurgeCloudKit()
        cloudKit.zones[container] = Set(ICloudPurge.zones).union(["_defaultZone", otherZone])
        cloudKit.subscriptions[container] = [ICloudPurge.mealsSubscriptionID, "someone-else"]
        drive = FakePurgeDrive()
        drive.reachable = [container, legacy]
        let docs = FakePurgeDrive.documents(container).path
        let old = FakePurgeDrive.documents(legacy).path
        drive.files = ["\(docs)/backup.plist", "\(docs)/previous-backup.plist",
                       "\(docs)/Transcripts/a.lzfse", "\(docs)/Transcripts/b.lzfse",
                       "\(docs)/VoiceNotes/n.m4a", "\(docs)/VoiceNotes/n.json", "\(docs)/VoiceNotes/m.deleted",
                       "\(docs)/unrelated.txt",
                       "\(old)/backup.plist", "\(old)/previous-backup.plist", "\(old)/unrelated.txt"]
        keyValues = PurgeKeyValues()
        for key in LegacyInventory.keys.keys { keyValues.values[key] = Data("v-\(key)".utf8) }
        keyValues.values["googleCalendar.accountHint.v1"] = "me@example.com"
        keyValues.values["podcastPeerGroupToken.v1"] = "secret"
        defaults = UserDefaults(suiteName: "icloud-purge-\(UUID().uuidString)")
        support = FileManager.default.temporaryDirectory.appendingPathComponent("icloud-purge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        for name in ICloudPurge.LocalState.files { try Data("x".utf8).write(to: support.appendingPathComponent(name)) }
        try Data("keep".utf8).write(to: support.appendingPathComponent("wellness.json"))
        for key in ["ckSyncEngine.controls.state", "ckSyncEngine.fitness.revisions", "zonePoll.wellness",
                    "dbChanges.private.token", "mealsPush.subscribed.v1"] {
            defaults.set(Data("s".utf8), forKey: key)
        }
        defaults.set(true, forKey: "onboardingDone")
        modes = LegacyCloudModeStore(defaults: defaults, account: "acc", enabled: true)
        modes.set(.readOnly, for: .personal)
        modes.set(.readOnly, for: .health)
        launch = ICloudPurge.LaunchMemory()
        now = Date()
        logs = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: support)
    }

    private func purge(iCloudAllowed: Bool = true, legacyContainer: String?? = .none,
                       modes: LegacyCloudModeStore? = nil) -> ICloudPurge {
        let store = modes ?? self.modes!
        return ICloudPurge(ICloudPurge.Dependencies(
            cloudKit: cloudKit, drive: drive, keyValues: keyValues, keyValueCopies: defaults,
            container: container, legacyContainer: legacyContainer ?? legacy, iCloudAllowed: iCloudAllowed,
            localDefaults: defaults, supportDirectory: support, account: "acc", defaults: defaults,
            mode: { store.mode($0) }, turnOff: { store.set(.off, for: $0) }, launch: launch,
            now: { [unowned self] in self.now }, log: { [unowned self] in self.logs.append($0) }))
    }

    /// Both tiers past their seed: personal flipped, health held (no consent).
    private func situation(asked: Bool = true, icloud: String? = "purge", _ edit: (inout MoveOver.State) -> Void = { _ in })
    -> ICloudPurge.Situation {
        var move = MoveOver.State()
        move.personal.phase = .flipped
        move.health.phase = .held
        edit(&move)
        return ICloudPurge.Situation(asked: asked, icloud: icloud, move: move)
    }

    private func newLaunch() { launch = ICloudPurge.LaunchMemory() }

    private func assertNothingDeleted(_ line: UInt = #line) {
        XCTAssertEqual(cloudKit.deletedZones, [], line: line)
        XCTAssertEqual(cloudKit.deletedSubscriptions, [], line: line)
        XCTAssertEqual(keyValues.writes, [], line: line)
        XCTAssertEqual(drive.removed, [], line: line)
        XCTAssertNotNil(defaults.data(forKey: "ckSyncEngine.controls.state"), line: line)
    }

    // MARK: - The gate

    func testEachMissingConditionDeletesNothing() async {
        let cases: [(String, ICloudPurge.Situation, ICloudPurge.Skip)] = [
            ("--no-space-sync", situation(asked: false), .notAsked),
            ("the account keeps iCloud", situation(icloud: "keep"), .notFlagged),
            ("an older service", situation(icloud: nil), .notFlagged),
            ("personal still seeding", situation { $0.personal.phase = .seeding }, .notFlipped(.personal)),
            ("personal not started", situation { $0.personal.phase = .waiting }, .notFlipped(.personal)),
            ("health still seeding", situation { $0.health.phase = .seeding }, .notFlipped(.health)),
            ("a delete still to reach the space", situation { $0.personal.pendingDeletes = ["plan.extra": ["x"]] },
             .readersBusy(.personal)),
            ("an item still to leave the stores", situation { $0.health.absent = ["food.meal": ["m"]] }, .readersBusy(.health)),
        ]
        for (name, situation, skip) in cases {
            newLaunch()
            let outcome = await purge().runIfDue(situation)
            XCTAssertEqual(outcome, .skipped(skip), name)
            assertNothingDeleted()
        }
        XCTAssertEqual(modes.mode(.personal), .readOnly, "the readers aren't touched either")
    }

    func testNeverWhileATierWritesICloud() async {
        // The modes say readWrite (the modes made with the platform off, nothing moved), whatever the
        // state says.
        let writing = LegacyCloudModeStore(defaults: UserDefaults(suiteName: "icloud-purge-rw-\(UUID().uuidString)")!,
                                           account: "acc", enabled: false)
        let outcome = await purge(modes: writing).runIfDue(situation())
        XCTAssertEqual(outcome, .skipped(.notFlipped(.personal)))
        assertNothingDeleted()

        // Current mode stores refuse health writes altogether. Inject a legacy/invalid writer
        // at the purge boundary so the safety gate remains tested independently of that floor.
        let half = ICloudPurge(ICloudPurge.Dependencies(
            cloudKit: cloudKit, drive: drive, keyValues: keyValues, keyValueCopies: defaults,
            container: container, legacyContainer: legacy, iCloudAllowed: true,
            localDefaults: defaults, supportDirectory: support, account: "acc", defaults: defaults,
            mode: { $0 == .health ? .readWrite : .off }, turnOff: { _ in },
            launch: ICloudPurge.LaunchMemory(), now: { [unowned self] in self.now }))
        newLaunch()
        let second = await half.runIfDue(situation())
        XCTAssertEqual(second, .skipped(.notFlipped(.health)))
        assertNothingDeleted()
    }

    func testATierWritingAgainMidRunStopsEveryLaterStep() async {
        // The modes say read-only and the purge's turning-off doesn't take; then a tier writes
        // again as the first CloudKit call is made.
        var mode = LegacyCloudMode.readOnly
        let purge = ICloudPurge(ICloudPurge.Dependencies(
            cloudKit: cloudKit, drive: drive, keyValues: keyValues, keyValueCopies: defaults,
            container: container, legacyContainer: legacy, iCloudAllowed: true,
            localDefaults: defaults, supportDirectory: support, account: "acc", defaults: defaults,
            mode: { _ in mode }, turnOff: { _ in }, launch: launch, now: { [unowned self] in self.now }))
        cloudKit.onCall = { mode = .readWrite }
        let outcome = await purge.runIfDue(situation())
        guard case .incomplete(let report) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(cloudKit.deletedZones, [])
        XCTAssertEqual(keyValues.writes, [])
        XCTAssertEqual(drive.removed, [])
        XCTAssert(report.failures.contains { $0.contains("writes iCloud again") })
        XCTAssertNil(purge.record.purgedAt)
    }

    func testNoICloudInThisProcessDeletesNothing() async {
        let outcome = await purge(iCloudAllowed: false).runIfDue(situation())
        XCTAssertEqual(outcome, .skipped(.noICloud))
        assertNothingDeleted()
    }

    func testReadersAlreadyOffMayPurgeEvenWithLeftovers() async {
        modes.set(.off, for: .personal)
        modes.set(.off, for: .health)
        let outcome = await purge().runIfDue(situation { $0.personal.phase = .off; $0.health.pendingDeletes = ["food.meal": ["m"]] })
        guard case .done = outcome else { return XCTFail("\(outcome)") }
    }

    // MARK: - What goes

    func testTheFullSetOfDeletes() async throws {
        let purge = purge()
        let outcome = await purge.runIfDue(situation())
        guard case .done(let report) = outcome else { return XCTFail("\(outcome): \(logs)") }

        XCTAssertEqual(Set(cloudKit.deletedZones), Set(["Controls", "Meals", "Wellness", "Settings", "Fitness", "Progress"]))
        XCTAssertEqual(cloudKit.zones[container], ["_defaultZone", otherZone], "nothing else in the database")
        XCTAssertEqual(cloudKit.deletedSubscriptions, [ICloudPurge.mealsSubscriptionID])
        XCTAssertEqual(cloudKit.subscriptions[container], ["someone-else"])

        let moved = Set(LegacyInventory.keys.keys)
        XCTAssertEqual(moved.count, 18)
        XCTAssertEqual(Set(keyValues.writes), moved)
        for key in moved { XCTAssertNil(keyValues.values[key], key) }
        XCTAssertGreaterThan(keyValues.synchronized, 0)

        let docs = FakePurgeDrive.documents(container).path
        let old = FakePurgeDrive.documents(legacy).path
        XCTAssertEqual(drive.files, ["\(docs)/unrelated.txt", "\(old)/unrelated.txt"])
        XCTAssertEqual(report.driveFiles, 7)
        XCTAssertEqual(report.legacyFiles, 2)
        XCTAssertEqual(report.legacyReachable, true)

        XCTAssertEqual(report.subscriptions, 1)
        XCTAssertEqual(report.zonesDeleted, 6)
        XCTAssertEqual(report.zonesGone, 0)
        XCTAssertEqual(report.keysRemoved, 18)

        // This device's bookkeeping for the zones goes; its data and other settings stay.
        for key in ["ckSyncEngine.controls.state", "ckSyncEngine.fitness.revisions", "zonePoll.wellness",
                    "dbChanges.private.token", "mealsPush.subscribed.v1"] {
            XCTAssertNil(defaults.object(forKey: key), key)
        }
        XCTAssertTrue(defaults.bool(forKey: "onboardingDone"))
        for name in ICloudPurge.LocalState.files {
            XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent(name).path), name)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: support.appendingPathComponent("wellness.json").path))
        XCTAssertEqual(report.localCleared, 5 + ICloudPurge.LocalState.files.count)

        // The legacy channels stay off; the run is kept for the weekly repeat.
        XCTAssertEqual(modes.mode(.personal), .off)
        XCTAssertEqual(modes.mode(.health), .off)
        XCTAssertEqual(purge.record.purgedAt, now)
        XCTAssertEqual(purge.record.firstPurgedAt, now)
        XCTAssert(logs.contains("zones: 6 deleted, 0 already gone"), "\(logs)")
        XCTAssert(logs.contains("key-value store: 18 of 18 key(s) removed, 2 kept"), "\(logs)")
    }

    func testTheTwoKeptKeysAreUntouched() async {
        _ = await purge().runIfDue(situation())
        XCTAssertFalse(keyValues.writes.contains("googleCalendar.accountHint.v1"))
        XCTAssertFalse(keyValues.writes.contains("podcastPeerGroupToken.v1"))
        XCTAssertEqual(keyValues.values["googleCalendar.accountHint.v1"] as? String, "me@example.com")
        XCTAssertEqual(keyValues.values["podcastPeerGroupToken.v1"] as? String, "secret")
        XCTAssertFalse(ICloudPurge.keys.contains("googleCalendar.accountHint.v1"))
        XCTAssertFalse(ICloudPurge.keys.contains("podcastPeerGroupToken.v1"))
    }

    /// A key no store has read since the move: its value is kept on this device before it leaves
    /// iCloud, and a copy already made isn't overwritten.
    func testAKeyNotReadSinceTheMoveKeepsItsDeviceCopy() async {
        defaults.set(["v": Data("mine".utf8)], forKey: LegacyKVS.localKey("modules"))
        _ = await purge().runIfDue(situation())
        let copy = defaults.dictionary(forKey: LegacyKVS.localKey("guestPicks.v1"))
        XCTAssertEqual(copy?["v"] as? Data, Data("v-guestPicks.v1".utf8))
        XCTAssertEqual(defaults.dictionary(forKey: LegacyKVS.localKey("modules"))?["v"] as? Data, Data("mine".utf8))
        let kvs = LegacyKVS(store: keyValues, local: defaults, mode: { [modes] in modes!.mode($0) }, notifying: NSObject())
        XCTAssertEqual(kvs.data(forKey: "guestPicks.v1"), Data("v-guestPicks.v1".utf8), "the store still reads it")
    }

    func testTheLegacyContainerOutOfReachIsSaidNotRetried() async {
        drive.reachable = [container]
        let purge = purge()
        let outcome = await purge.runIfDue(situation())
        guard case .done(let report) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(report.legacyReachable, false)
        XCTAssertEqual(report.legacyFiles, 0)
        XCTAssert(logs.contains { $0.contains("can't reach it") }, "\(logs)")
        XCTAssertNotNil(purge.record.purgedAt)
    }

    func testNoLegacyContainerConfigured() async {
        let outcome = await purge(legacyContainer: .some(nil)).runIfDue(situation())
        guard case .done(let report) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertNil(report.legacyReachable)
        XCTAssertEqual(drive.files.filter { $0.hasPrefix(FakePurgeDrive.documents(legacy).path) }.count, 3)
    }

    // MARK: - Idempotent, retried, weekly

    func testASecondRunDeletesNothingNew() async {
        _ = await purge().runIfDue(situation())
        let zones = cloudKit.deletedZones, subscriptions = cloudKit.deletedSubscriptions
        let writes = keyValues.writes, removed = drive.removed
        newLaunch()
        now = now.addingTimeInterval(ICloudPurge.repeatInterval)
        let outcome = await purge().runIfDue(situation())
        guard case .done(let report) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(cloudKit.deletedZones, zones)
        XCTAssertEqual(cloudKit.deletedSubscriptions, subscriptions)
        XCTAssertEqual(keyValues.writes, writes)
        XCTAssertEqual(drive.removed, removed)
        XCTAssertEqual(report, ICloudPurge.Report(zonesGone: 6, legacyReachable: true))
    }

    func testItemsGoneMeanwhileCountAsDone() async {
        cloudKit.vanishing = ["Fitness", "Meals"]
        cloudKit.subscriptions[container] = []
        drive.files = drive.files.filter { !$0.contains("/Transcripts/") }
        let outcome = await purge().runIfDue(situation())
        guard case .done(let report) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(report.zonesDeleted, 4)
        XCTAssertEqual(report.zonesGone, 2)
        XCTAssertEqual(report.subscriptions, 0)
        XCTAssertEqual(cloudKit.zones[container], ["_defaultZone", otherZone])
    }

    func testOfflineIsTriedAgainAtTheNextLaunchAndTheRestGoesNow() async {
        cloudKit.offline = true
        let purge = purge()
        let outcome = await purge.runIfDue(situation())
        guard case .incomplete(let report) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(report.failures.count, 2, "the subscription and the zones")
        XCTAssertEqual(report.keysRemoved, 18, "partial success is fine: each step on its own")
        XCTAssertEqual(report.driveFiles, 7)
        XCTAssertNil(purge.record.purgedAt)

        let same = await purge.runIfDue(situation())
        XCTAssertEqual(same, .skipped(.ranThisLaunch), "once a launch")
        XCTAssertEqual(cloudKit.deletedZones, [])

        cloudKit.offline = false
        newLaunch()
        let again = await self.purge().runIfDue(situation())
        guard case .done(let second) = again else { return XCTFail("\(again)") }
        XCTAssertEqual(second.zonesDeleted, 6)
        XCTAssertEqual(second.keysRemoved, 0)
    }

    func testADriveItemThatCantGoNowIsTriedAgain() async {
        drive.failing = ["VoiceNotes"]
        let outcome = await purge().runIfDue(situation())
        guard case .incomplete(let report) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(report.zonesDeleted, 6)
    }

    func testOnceALaunchThenWeekly() async {
        let first = purge()
        guard case .done = await first.runIfDue(situation()) else { return XCTFail() }
        let same = await first.runIfDue(situation())
        XCTAssertEqual(same, .skipped(.ranThisLaunch))

        // An old build makes a zone again.
        cloudKit.zones[container]?.insert("Progress")
        newLaunch()
        now = now.addingTimeInterval(86_400)
        let early = await purge().runIfDue(situation())
        XCTAssertEqual(early, .skipped(.notDue), "a day later")
        XCTAssertEqual(cloudKit.zones[container]?.contains("Progress"), true)

        newLaunch()
        now = now.addingTimeInterval(6 * 86_400)
        let weekly = await purge().runIfDue(situation())
        guard case .done(let report) = weekly else { return XCTFail("\(weekly)") }
        XCTAssertEqual(report.zonesDeleted, 1)
        XCTAssertEqual(cloudKit.zones[container]?.contains("Progress"), false)
    }

    func testTheRecordIsPerAccount() async {
        _ = await purge().runIfDue(situation())
        let other = ICloudPurge(ICloudPurge.Dependencies(
            cloudKit: cloudKit, drive: drive, keyValues: keyValues, keyValueCopies: defaults,
            container: container, legacyContainer: nil, iCloudAllowed: true,
            localDefaults: defaults, supportDirectory: support, account: "other", defaults: defaults,
            mode: { [modes] in modes!.mode($0) }, turnOff: { [modes] in modes!.set(.off, for: $0) }, launch: launch))
        XCTAssertNil(other.record.purgedAt)
        guard case .done = await other.runIfDue(situation()) else { return XCTFail("another account isn't held by this one's run") }
    }
}
