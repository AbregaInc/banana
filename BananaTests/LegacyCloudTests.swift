import XCTest

/// iCloud key-value data held in memory, as `NSUbiquitousKeyValueStore` would hold it.
final class FakeKeyValueStore: LegacyKeyValueStore {
    var values: [String: Any] = [:]
    private(set) var writes: [String] = []

    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) {
        writes.append(key)
        values[key] = value
    }
    func removeObject(forKey key: String) {
        writes.append(key)
        values[key] = nil
    }
    func synchronize() -> Bool { true }
}

/// The legacy channels' modes (docs/design/DATA-PLATFORM.md §3, §8): what `readOnly` and `off`
/// let through, where they are kept, and the inventory against the catalog.
@MainActor
final class LegacyCloudTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "legacy-cloud-\(UUID().uuidString)")
    }

    private final class Modes: @unchecked Sendable {
        var personal = LegacyCloudMode.readWrite
        var health = LegacyCloudMode.readWrite
        func mode(_ tier: LegacyTier) -> LegacyCloudMode { tier == .personal ? personal : health }
    }

    // MARK: - The key-value gate

    func testReadWriteGoesToICloudAsToday() {
        let cloud = FakeKeyValueStore()
        let kvs = LegacyKVS(store: cloud, local: defaults, mode: { _ in .readWrite }, notifying: cloud)
        kvs.set(Data([1]), forKey: "appSettings")
        XCTAssertEqual(cloud.values["appSettings"] as? Data, Data([1]))
        XCTAssertEqual(kvs.data(forKey: "appSettings"), Data([1]))
        kvs.removeObject(forKey: "appSettings")
        XCTAssertNil(cloud.values["appSettings"])
    }

    func testReadOnlyNeverWritesICloudAndKeepsTheWriteOnThisDevice() {
        let cloud = FakeKeyValueStore()
        cloud.values["guestPicks.v1"] = ["sam": ["sam@old.com": 1]]
        let modes = Modes()
        modes.personal = .readOnly
        let kvs = LegacyKVS(store: cloud, local: defaults, mode: { modes.mode($0) }, notifying: cloud)

        kvs.set(["sam": ["sam@new.com": 2]], forKey: "guestPicks.v1")
        XCTAssertTrue(cloud.writes.isEmpty, "nothing reaches iCloud")
        XCTAssertEqual(cloud.values["guestPicks.v1"] as? [String: [String: Int]], ["sam": ["sam@old.com": 1]])
        XCTAssertEqual(kvs.dictionary(forKey: "guestPicks.v1") as? [String: [String: Int]], ["sam": ["sam@new.com": 2]],
                       "the store still reads its own last write")

        kvs.removeObject(forKey: "guestPicks.v1")
        XCTAssertTrue(cloud.writes.isEmpty)
        XCTAssertNil(kvs.object(forKey: "guestPicks.v1"), "removed here, though iCloud still has it")

        cloud.values["taskDurations.v1"] = Data([7])
        XCTAssertEqual(kvs.data(forKey: "taskDurations.v1"), Data([7]), "reads go on: late arrivals")

        modes.personal = .off
        kvs.set(Data([9]), forKey: "taskDurations.v1")
        XCTAssertTrue(cloud.writes.isEmpty)
        XCTAssertEqual(kvs.data(forKey: "taskDurations.v1"), Data([9]))
    }

    func testTheTwoKeptKeysAlwaysGoToICloud() {
        let cloud = FakeKeyValueStore()
        let kvs = LegacyKVS(store: cloud, local: defaults, mode: { _ in .off }, notifying: cloud)
        kvs.set("noor@plan.example", forKey: "googleCalendar.accountHint.v1")
        kvs.set("token", forKey: "podcastPeerGroupToken.v1")
        XCTAssertEqual(Set(cloud.writes), ["googleCalendar.accountHint.v1", "podcastPeerGroupToken.v1"])
        kvs.set(Data([1]), forKey: "hubStatus.v1")
        XCTAssertEqual(cloud.writes.count, 2)
    }

    func testEachKeyFollowsItsOwnTier() {
        let cloud = FakeKeyValueStore()
        let modes = Modes()
        modes.health = .readOnly
        let kvs = LegacyKVS(store: cloud, local: defaults, mode: { modes.mode($0) }, notifying: cloud)
        kvs.set(Data([1]), forKey: "appSettings")
        kvs.set(["oats": ["usda:1": 1]], forKey: "foodSearchPicks.v1")
        kvs.set(Data([2]), forKey: "healthRemovalRequests.v1")
        XCTAssertEqual(cloud.writes, ["appSettings"], "personal data still writes; health and food don't")
        XCTAssertEqual(kvs.mode(forKey: "mealEstimators.v1"), .readOnly)
        XCTAssertEqual(kvs.mode(forKey: "some.unknown.key"), .readWrite, "an unknown key is personal data")
        modes.personal = .readOnly
        XCTAssertEqual(kvs.mode(forKey: "some.unknown.key"), .readOnly, "and gated with it")
    }

    // MARK: - The outbox (CloudWellnessSync queues every save and delete through it)

    func testTheOutboxDropsSavesAndDeletesOnceTheTierNoLongerWrites() {
        var mode = LegacyCloudMode.readWrite
        var queued: [String] = [], unqueued: [String] = []
        let outbox = LegacyOutbox<String>(mode: { mode }, add: { queued += $0 }, remove: { unqueued += $0 })

        XCTAssertTrue(outbox.queue(["save meal-1"]))
        mode = .readOnly
        XCTAssertFalse(outbox.queue(["save meal-2", "delete meal-3"]))
        outbox.unqueue(["save meal-1"])
        mode = .off
        XCTAssertFalse(outbox.queue(["save meal-4"]))
        XCTAssertEqual(queued, ["save meal-1"], "read-only and off queue nothing for iCloud")
        XCTAssertEqual(unqueued, ["save meal-1"], "taking a change out of the queue is not a write")
    }

    func testWellnessDrainNamesTheAbsentOnceSyncedItemsAndNothingElse() {
        let synced = UUID(), deletedElsewhere = UUID(), neverSynced = UUID(), dirty = UUID(), deletedHere = UUID()
        let supplement = UUID()
        func name(_ id: UUID) -> String { WellnessCloudRecord.meal(id).name }
        let dose = WellnessCloudRecord.dose(supplementID: supplement, day: "20261019").name
        let local: Set<String> = [name(synced), name(deletedElsewhere), name(neverSynced), name(dirty), dose]
        let result = WellnessCloudRecord.drainResult(
            local: local, confirmed: [name(synced), name(deletedElsewhere), name(dirty), dose],
            dirty: [name(dirty)], deletes: [name(deletedHere)],
            present: [name(synced), name(dirty), "meal-something-else"])

        XCTAssertEqual(result.absent, ["food.meal": [deletedElsewhere.uuidString],
                                       "food.dose": ["\(supplement.uuidString)-20261019"]])
        XCTAssertEqual(result.dirty, ["food.meal": [dirty.uuidString]])
        XCTAssertEqual(result.pendingDeletes, ["food.meal": [deletedHere.uuidString]])

        let unlisted = WellnessCloudRecord.drainResult(local: local, confirmed: local, dirty: [], deletes: [], present: [])
        XCTAssertTrue(unlisted.absent.isEmpty, "an empty listing never drops anything")
        let noZone = WellnessCloudRecord.drainResult(local: local, confirmed: local, dirty: [], deletes: [], present: nil)
        XCTAssertTrue(noZone.absent.isEmpty)
    }

    func testAnItemMadeHereAndNeverSentIsNeverAbsent() {
        // Read-only (or a drain again after a crash): a meal logged here has an edit time but
        // iCloud never confirmed it, so its absence from the zone means nothing.
        let old = UUID(), madeHere = UUID()
        func name(_ id: UUID) -> String { WellnessCloudRecord.meal(id).name }
        let result = WellnessCloudRecord.drainResult(
            local: [name(old), name(madeHere)], confirmed: [name(old)], dirty: [], deletes: [],
            present: ["meal-someone-else"])
        XCTAssertEqual(result.absent, ["food.meal": [old.uuidString]])
    }

    func testAZoneWithBothTiersKeepsEachChannelsOwnPart() {
        var drained = DrainResult()
        drained.note(\.dirty, type: "plan.routine", id: "r")
        drained.note(\.pendingDeletes, type: "health.workoutPlan", id: "p")
        drained.note(\.absent, type: "food.myFood", id: "f")
        drained.note(\.absent, type: "podcast.listen", id: "l")
        let health = drained.only(LegacyInventory.controlsHealth)
        XCTAssertEqual(health, DrainResult(dirty: [:], pendingDeletes: ["health.workoutPlan": ["p"]], absent: ["food.myFood": ["f"]]))
        let personal = drained.only(LegacyInventory.controls)
        XCTAssertEqual(personal, DrainResult(dirty: ["plan.routine": ["r"]], pendingDeletes: [:], absent: ["podcast.listen": ["l"]]))
    }

    // MARK: - Another device's key-value change

    private func externalChange(_ object: AnyObject, _ keys: [String]) {
        NotificationCenter.default.post(name: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: object,
                                        userInfo: [NSUbiquitousKeyValueStoreChangedKeysKey: keys])
    }

    func testReadOnlyTakesAnotherDevicesChangeOverItsOwnCopyAndOffDoesNot() async throws {
        let cloud = FakeKeyValueStore()
        let modes = Modes()
        modes.personal = .readOnly
        let kvs = LegacyKVS(store: cloud, local: defaults, mode: { modes.mode($0) }, notifying: cloud)
        var heard = 0
        let observer = kvs.observeExternalChanges(tier: .personal) {
            XCTAssertTrue(LegacyCloud.isApplyingFromCloud(type: "plan.taskDuration", id: "any"), "an arrival")
            heard += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        kvs.set(Data([1]), forKey: "taskDurations.v1")   // this device's own write, kept here
        cloud.values["taskDurations.v1"] = Data([2])     // an old build's, in iCloud
        externalChange(cloud, ["taskDurations.v1"])
        try await until { heard == 1 }
        XCTAssertEqual(kvs.data(forKey: "taskDurations.v1"), Data([2]), "the arrival is taken over the copy")
        XCTAssertTrue(cloud.writes.isEmpty)

        modes.personal = .off
        cloud.values["taskDurations.v1"] = Data([3])
        externalChange(cloud, ["taskDurations.v1"])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(heard, 1, "off: nobody hears it")
        XCTAssertEqual(kvs.data(forKey: "taskDurations.v1"), Data([2]), "off: only the copy")

        cloud.values["missedRepeats.v1"] = ["k": 1]
        XCTAssertEqual(kvs.dictionary(forKey: "missedRepeats.v1") as? [String: Int], ["k": 1],
                       "a key first read when off starts from the last value seen in iCloud")
        cloud.values["missedRepeats.v1"] = ["k": 2]
        XCTAssertEqual(kvs.dictionary(forKey: "missedRepeats.v1") as? [String: Int], ["k": 1])
    }

    private func until(_ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(2)
        while !condition() {
            guard Date() < end else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testDeletesHeldOnTheDeviceSurviveARelaunchAndGoOnlyOnceTheMoveKeptThem() {
        let key = "held-\(UUID().uuidString)"
        let tierOf: @Sendable (String) -> LegacyTier = { $0.hasPrefix("note-") ? .personal : .health }
        let held = HeldDeletes(key: key, defaults: defaults, tierOf: tierOf)
        held.add(["workout-A", "note-B"])
        XCTAssertEqual(HeldDeletes(key: key, defaults: defaults, tierOf: tierOf).all, ["workout-A", "note-B"], "kept across a relaunch")
        let relaunched = HeldDeletes(key: key, defaults: defaults, tierOf: tierOf)
        XCTAssertEqual(relaunched.handOver(), ["workout-A", "note-B"])
        relaunched.add(["workout-C"])   // a delete made after the drain read them, before it was kept
        relaunched.kept(tier: .health)   // the health tier's move kept its part
        XCTAssertEqual(relaunched.all, ["note-B", "workout-C"], "only what was handed over and kept goes")
        relaunched.add(["workout-D"])
        XCTAssertFalse(relaunched.all.contains("workout-D"), "a drained tier holds nothing more: the move has its deletes")
        relaunched.add(["note-E"])
        XCTAssertTrue(relaunched.all.contains("note-E"), "the other tier hasn't drained")
        relaunched.kept(tier: .personal)
        XCTAssertEqual(relaunched.all, ["workout-C", "note-E"], "note-E came after the hand-over")
        relaunched.remove(["workout-C", "note-E"])   // made again here
        XCTAssertTrue(relaunched.all.isEmpty)
        let again = HeldDeletes(key: key, defaults: defaults, tierOf: tierOf)
        again.add(["workout-F", "note-G"])
        XCTAssertTrue(again.all.isEmpty, "drained is kept across a relaunch too")
    }

    func testAControlsDrainHandsOverEditsAndDeletesButNotARoutesTombstone() {
        let hashed = ControlKind.listen.recordName(String(repeating: "x", count: 200))
        let result = ControlDrain.result(
            dirty: ["routine-r1", "alarm-a1", "listenRoute-l1", "workoutPlan-p1", hashed],
            tombstones: ["alarm-a1", "listenRoute-l1"],
            keys: [hashed: String(repeating: "x", count: 200)])
        XCTAssertEqual(result.dirty, ["plan.routine": ["r1"], "health.workoutPlan": ["p1"],
                                      "podcast.listen": [String(repeating: "x", count: 200)]])
        XCTAssertEqual(result.pendingDeletes, ["plan.alarm": ["a1"]], "a route's tombstone isn't a deleted listen")
        XCTAssertTrue(result.absent.isEmpty, "Controls deletes are tombstones: nothing is absent for being missing")
    }

    // MARK: - Where the modes are kept

    func testModesAreKeptPerAccountAndOnlyWithSpaceSync() {
        let a = LegacyCloudModeStore(defaults: defaults, account: "acc-a", enabled: true)
        XCTAssertEqual(a.all, LegacyCloudModes(personal: .readWrite, health: .readOnly), "legacy personal sync can write; health never can")
        a.set(.off, for: .personal)
        XCTAssertEqual(a.mode(.personal), .off)
        XCTAssertEqual(a.mode(.health), .readOnly)
        XCTAssertEqual(LegacyCloudModeStore(defaults: defaults, account: "acc-a", enabled: true).mode(.personal), .off,
                       "kept across launches")
        a.bind(account: "acc-b")
        XCTAssertEqual(a.mode(.personal), .readOnly, "another account's own modes, over the device's floor")
        a.bind(account: "acc-a")
        XCTAssertEqual(a.mode(.personal), .off)

        let fresh = UserDefaults(suiteName: "legacy-cloud-fresh-\(UUID().uuidString)")!
        let without = LegacyCloudModeStore(defaults: fresh, account: "acc-a", enabled: false)
        XCTAssertEqual(without.mode(.personal), .readWrite, "with the data platform off (--no-space-sync) nothing changes")
        XCTAssertFalse(without.set(.off, for: .personal))
    }

    func testWithNoAccountNothingWritesICloud() {
        let fresh = UserDefaults(suiteName: "legacy-cloud-unbound-\(UUID().uuidString)")!
        let unbound = LegacyCloudModeStore(defaults: fresh, account: nil, enabled: true)
        XCTAssertEqual(unbound.all, LegacyCloudModes(personal: .readOnly, health: .readOnly), "§2: no account, no iCloud")
        XCTAssertTrue(unbound.mode(.personal).reads && unbound.mode(.health).reads, "the read-only channels still read")
        XCTAssertFalse(unbound.set(.off, for: .personal), "no account: nothing to keep a mode for")
        XCTAssertEqual(LegacyCloudModeStore(defaults: fresh, account: "acc-a", enabled: true).all,
                       LegacyCloudModes(personal: .readOnly, health: .readOnly), "and never again on this device, for any account")
        let platformOff = UserDefaults(suiteName: "legacy-cloud-off-\(UUID().uuidString)")!
        XCTAssertEqual(LegacyCloudModeStore(defaults: platformOff, account: nil, enabled: false).all,
                       LegacyCloudModes(personal: .readWrite, health: .readOnly),
                       "health never writes iCloud, even with the data platform off")
    }

    func testHealthCannotWriteICloudWithAnyAccountOrSyncFlag() {
        for enabled in [false, true] {
            for account: String? in [nil, "already-bound"] {
                let name = "health-cloud-policy-\(UUID().uuidString)"
                let isolated = UserDefaults(suiteName: name)!
                defer { isolated.removePersistentDomain(forName: name) }
                let store = LegacyCloudModeStore(defaults: isolated, account: account, enabled: enabled)
                XCTAssertEqual(store.mode(.health), .readOnly)
                _ = store.set(.readWrite, for: .health)
                XCTAssertFalse(store.mode(.health).writes)
                XCTAssertTrue(store.mode(.health).reads, "old data remains available for migration")
                store.bind(account: "another-account")
                XCTAssertFalse(store.mode(.health).writes)
                let reopened = LegacyCloudModeStore(defaults: isolated, account: "another-account", enabled: enabled)
                XCTAssertFalse(reopened.mode(.health).writes)
                if enabled {
                    _ = reopened.set(.off, for: .health)
                    XCTAssertEqual(reopened.mode(.health), .off, "a completed purge remains off")
                }
            }
        }
    }

    func testADeviceThatHasMovedNeverWritesICloudAgain() {
        let store = LegacyCloudModeStore(defaults: defaults, account: "acc-a", enabled: true)
        store.set(.readOnly, for: .health)
        XCTAssertEqual(LegacyCloudModeStore(defaults: defaults, account: "acc-b", enabled: true).mode(.health), .readOnly,
                       "not for another account")
        XCTAssertEqual(LegacyCloudModeStore(defaults: defaults, account: "acc-b", enabled: true).mode(.personal), .readWrite,
                       "the floor is per tier")
        XCTAssertEqual(LegacyCloudModeStore(defaults: defaults, account: "acc-a", enabled: false).mode(.health), .readOnly,
                       "nor with the data platform off")
        store.bind(account: nil)   // the account was deleted: its mirror is forgotten
        XCTAssertEqual(store.mode(.health), .readOnly)
    }

    // MARK: - The inventory

    func testTheInventoryCoversTheCatalogWithTheRightTiers() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "DataCatalog", withExtension: "json"))
        let catalog = try DataCatalog.decode(Data(contentsOf: url))
        let personal = LegacyInventory.controls.union(LegacyInventory.progress).union(LegacyInventory.fitnessNotes)
            .union(LegacyInventory.settings).union(LegacyInventory.drive).union(LegacyInventory.kvs)
        let health = LegacyInventory.controlsHealth.union(LegacyInventory.meals).union(LegacyInventory.wellness)
            .union(LegacyInventory.fitness).union(LegacyInventory.kvsHealth)
        XCTAssertEqual(personal.union(health).union(LegacyInventory.withoutLegacy), Set(catalog.types.map(\.type)),
                       "every type leaves some legacy channel, or never lived in iCloud")
        XCTAssertTrue(LegacyInventory.withoutLegacy.isDisjoint(with: personal.union(health)))
        XCTAssertEqual(health, catalog.healthTypes, "health channels carry exactly the T2 types")
        XCTAssertTrue(personal.isDisjoint(with: catalog.healthTypes))
        for entry in catalog.types {
            XCTAssertEqual(LegacyInventory.isHealth(entry.type), entry.isHealth, entry.type)
        }
        let kinds = Set(ControlKind.allCases.map(\.rawValue))
        XCTAssertEqual(Set(LegacyInventory.controlKinds.keys), kinds, "every control kind has its type")
        for kind in ControlKind.allCases {
            let type = try XCTUnwrap(LegacyInventory.controlKinds[kind.rawValue])
            let carried = kind.channel == .meals ? LegacyInventory.meals
                : LegacyInventory.controls.union(LegacyInventory.controlsHealth)
            XCTAssertTrue(carried.contains(type), "\(kind) → \(type)")
        }
        XCTAssertTrue(LegacyKVS.keptKeys.isDisjoint(with: LegacyInventory.keys.keys))
    }

    // MARK: - What /v1/account says

    func testTheAccountSaysWhoHasSeededAndWhetherThereIsAnIPhone() throws {
        func decode(_ json: String) throws -> BananaService.Account {
            try JSONDecoder().decode(BananaService.Account.self, from: Data(json.utf8))
        }
        let base = #""id":"acc","google":[],"devices":2"#
        let seeded = try decode("{\(base),\"seeded\":[\"plan.extra\"],\"icloud\":\"keep\"}")
        XCTAssertEqual(seeded.seeded, ["plan.extra"])
        XCTAssertEqual(seeded.hasIPhone, true)
        XCTAssertEqual(MoveOver.Account(seeded).presence, .seeded(["plan.extra"]))
        XCTAssertFalse(MoveOver.Account(seeded).allFlipped)

        let noPhone = try decode("{\(base),\"seeded\":null,\"icloud\":\"purge\"}")
        XCTAssertEqual(noPhone.hasIPhone, false)
        XCTAssertEqual(MoveOver.Account(noPhone).presence, .none)
        XCTAssertTrue(MoveOver.Account(noPhone).allFlipped, "purge needs every device flipped")

        let older = try decode("{\(base)}")
        XCTAssertNil(older.hasIPhone)
        XCTAssertEqual(MoveOver.Account(older).presence, .unknown)

        let roundTrip = try JSONDecoder().decode(BananaService.Account.self, from: JSONEncoder().encode(noPhone))
        XCTAssertEqual(roundTrip, noPhone)
    }
}
