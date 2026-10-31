import XCTest

/// A store as an adapter sees it: items by type and id, each a JSON object, plus what a test needs
/// to set (edit times, defaults, items it can't take yet, blob files) and to read back.
@MainActor
final class TestStore: RecordAdapter {
    let types: [String]
    var items: [String: [String: [String: JSONValue]]] = [:]
    var editedAt: [String: Date] = [:]
    var ranks: [String: Int] = [:]
    var defaults: [String: [String: JSONValue]] = [:]
    /// Ids `apply` says false for: their parent isn't here yet.
    var refuse: Set<String> = []
    var files: [String: URL] = [:]
    var storedBlobs: [String: Data] = [:]
    var applied: [String: Int] = [:]
    var applyCalls: [String: Int] = [:]
    /// What `refused(type:id:reason:)` was told.
    var refusals: [String] = []
    /// Applying the first id also edits the second (a store that derives one item from another).
    var cascade: [String: (type: String, id: String, fields: [String: JSONValue])] = [:]
    /// A type whose items wait for an item of another type with the same id (settings for a show).
    var needsParent: [String: String] = [:]
    /// The engine this store reports its edits to, as stores report to `ControlChangeReporter`.
    var engine: SpaceSync?
    /// Reports go through `MoveOver`'s hooks, as the app's stores' do.
    var viaMoveOver = false

    private func reportChanged(_ type: String, _ ids: [String]) {
        if viaMoveOver { MoveOver.changed(type: type, ids: ids) } else { engine?.changed(type: type, ids: ids) }
    }

    private func reportDeleted(_ type: String, _ ids: [String]) {
        if viaMoveOver { MoveOver.deleted(type: type, ids: ids) } else { engine?.deleted(type: type, ids: ids) }
    }

    init(types: [String]) { self.types = types }

    private func key(_ type: String, _ id: String, _ field: String? = nil) -> String {
        [type, id, field].compactMap { $0 }.joined(separator: "/")
    }

    // An edit made here.
    func set(_ type: String, _ id: String, _ fields: [String: JSONValue], at date: Date? = nil) {
        items[type, default: [:]][id] = fields
        if let date { editedAt[key(type, id)] = date }
        reportChanged(type, [id])
    }

    func delete(_ type: String, _ id: String) {
        items[type]?[id] = nil
        reportDeleted(type, [id])
    }

    func attach(_ type: String, _ id: String, field: String, data: Data) -> BlobReference {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-blob-\(UUID().uuidString)")
        try! data.write(to: url)
        files[key(type, id, field)] = url
        return BlobReference(sha256: Self.sha(data), size: Int64(data.count), ext: "bin")
    }

    static func sha(_ data: Data) -> String {
        // Content-addressed enough for tests: 64 hex characters that depend on the bytes.
        var hash: UInt64 = 1469598103934665603
        for byte in data { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return String(repeating: String(format: "%016llx", hash), count: 4)
    }

    // RecordAdapter

    func snapshot(_ type: String) -> [String: any Encodable & Sendable] {
        (items[type] ?? [:]).mapValues { JSONValue.object($0) }
    }

    func seedClock(_ type: String, id: String) -> Date? { editedAt[key(type, id)] }
    func seedRank(_ type: String, id: String) -> Int { ranks[key(type, id)] ?? 0 }
    func defaultEncoding(_ type: String) -> [String: JSONValue]? { defaults[type] }

    func apply(_ type: String, records: [(id: String, fields: [String: JSONValue])]) -> [String: Bool] {
        var results: [String: Bool] = [:]
        var taken: [String] = []
        applyCalls[type, default: 0] += 1
        for record in records {
            guard !refuse.contains(record.id) else { results[record.id] = false; continue }
            if let parent = needsParent[type], items[parent]?[record.id] == nil { results[record.id] = false; continue }
            items[type, default: [:]][record.id] = record.fields.filter { !$0.value.isNull }
            applied[type, default: 0] += 1
            results[record.id] = true
            taken.append(record.id)
        }
        // A store's mutators report what they did; the engine must see it as no change.
        if !taken.isEmpty { reportChanged(type, taken) }
        for id in taken {
            if let derived = cascade[id] { set(derived.type, derived.id, derived.fields) }
        }
        return results
    }

    func refused(type: String, id: String, reason: String) { refusals.append("\(type) \(id) \(reason)") }

    func remove(_ type: String, ids: [String]) {
        for id in ids { items[type]?[id] = nil }
        reportDeleted(type, ids)
    }

    func blobFile(_ type: String, id: String, field: String) -> URL? { files[key(type, id, field)] }

    func storeBlob(_ type: String, id: String, field: String, file: URL) {
        storedBlobs[key(type, id, field)] = try? Data(contentsOf: file)
    }
}

extension SpaceSync {
    /// What `MoveOver` sends as the device's sync state (it calls the transport itself), for the
    /// engine's tests: the types seeded here with `seededAt`.
    func reportSyncState(seededAt: Date?, flippedAt: Date?) async throws {
        let seeded = status().seeded
        try await transport.reportSyncState(device: config.device, seededAt: seededAt, flippedAt: flippedAt,
                                            seeded: seededAt == nil ? nil : seeded.sorted())
    }
}

/// `SpaceSync` against the in-memory service (docs/design/DATA-PLATFORM.md §3, §4, §6).
@MainActor
final class SpaceSyncTests: XCTestCase {
    private var catalog: DataCatalog!
    private var server: MemorySyncServer!
    private var logs: LogBox!

    final class LogBox: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    }

    override func setUp() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "DataCatalog", withExtension: "json"))
        catalog = try DataCatalog.decode(Data(contentsOf: url))
        server = MemorySyncServer(catalog: catalog)
        server.hubDevices = ["phone"]
        logs = LogBox()
    }

    private func engine(_ device: String, hub: Bool, store: TestStore, mirror: RecordMirror? = nil,
                        skew: TimeInterval = 0) async throws -> SpaceSync {
        var config = SpaceSync.Configuration(device: device, isHub: hub, catalog: catalog)
        if skew != 0 { config.now = { Date().addingTimeInterval(skew) } }
        config.debounce = .seconds(3_600)   // the tests run passes themselves
        config.blobRetryBase = 0.05
        let logs = self.logs!
        config.log = { logs.add("\(device): \($0)") }
        let engine = try SpaceSync(mirror: mirror ?? RecordMirror(), transport: MemoryTransport(server: server, device: device),
                                   config: config)
        await engine.registerAdapter(store)
        store.engine = engine
        return engine
    }

    private let extra = "plan.extra"
    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    // MARK: - The queue

    func testEditsMadeOfflineWaitAndGoOnceTheServiceIsBack() async throws {
        let store = TestStore(types: [extra])
        let phone = try await engine("phone", hub: true, store: store)
        await phone.seed(types: [extra])
        server.offline = ["phone"]
        store.set(extra, "a", ["title": .string("Oats")])
        await phone.syncNow(reason: "test")
        XCTAssertNil(server.record(extra, "a"))
        let waiting = await phone.status().pendingRecords
        XCTAssertEqual(waiting, 1)

        server.offline = []
        await phone.syncNow(reason: "test")
        XCTAssertEqual(server.visible(type: extra)["a"], ["title": .string("Oats")])
        let left = await phone.status().pendingRecords
        XCTAssertEqual(left, 0)
    }

    func testAPullPagesUntilTheServiceSaysNoMoreAndTheCursorMovesOnlyToNext() async throws {
        for n in 0..<10 {
            server.inject(extra, "r\(n)", set: ["title": .string("R\(n)")], clock: HLC(ms: 1_760_000_000_000 + Int64(n), device: "mac").text)
        }
        server.pageSize = 3
        let store = TestStore(types: [extra])
        let phone = try await engine("phone", hub: true, store: store)
        await phone.seed(types: [extra])
        XCTAssertEqual(store.items[extra]?.count, 10)
        let cursor = await phone.status().cursor
        XCTAssertEqual(cursor, server.seq)
        XCTAssertGreaterThanOrEqual(server.requests.filter { $0.device == "phone" }.count, 4, "10 records, 3 a page")
        let sinces = server.requests.map(\.since)
        XCTAssertEqual(sinces, sinces.sorted(), "the cursor only goes forward")
    }

    func testAWipedSpaceIsReadAgainFromTheStart() async throws {
        let store = TestStore(types: [extra])
        let mirror = try RecordMirror()
        try mirror.write { try $0.setMeta("cursor", Int64(500)) }   // from before the wipe
        server.inject(extra, "a", set: ["title": .string("A")], clock: "1760000000000.0000.mac")
        let phone = try await engine("phone", hub: true, store: store, mirror: mirror)
        await phone.seed(types: [extra])
        XCTAssertEqual(store.items[extra]?["a"], ["title": .string("A")])
        let cursor = await phone.status().cursor
        XCTAssertEqual(cursor, 1)
    }

    // MARK: - Acknowledging

    func testAnEditMadeWhileTheRequestWasOutIsNeitherLostNorOverwritten() async throws {
        let store = TestStore(types: [extra])
        let phone = try await engine("phone", hub: true, store: store)
        await phone.seed(types: [extra])
        store.set(extra, "a", ["title": .string("A")])
        let server = self.server!
        server.beforeSync = { request in
            guard request.changes.contains(where: { $0.id == "a" }) else { return }
            server.beforeSync = nil
            // Mid-flight: another device changes another field, and this device edits the title.
            server.inject("plan.extra", "a", set: ["kcal": .int(250)], clock: "1760000000000.0000.mac")
            await MainActor.run { store.set("plan.extra", "a", ["title": .string("B")]) }
        }
        await phone.syncNow(reason: "test")
        XCTAssertEqual(server.visible(type: extra)["a"], ["title": .string("A"), "kcal": .int(250)])
        XCTAssertEqual(store.items[extra]?["a"], ["title": .string("B")], "the answer didn't overwrite the edit made meanwhile")

        await phone.syncNow(reason: "test")
        XCTAssertEqual(server.visible(type: extra)["a"], ["title": .string("B"), "kcal": .int(250)])
        XCTAssertEqual(store.items[extra]?["a"], ["title": .string("B"), "kcal": .int(250)], "and then it got the other field")
        let left = await phone.status().pendingRecords
        XCTAssertEqual(left, 0)
    }

    func testALostAnswerIsSafeToRetry() async throws {
        let store = TestStore(types: [extra])
        let phone = try await engine("phone", hub: true, store: store)
        await phone.seed(types: [extra])
        store.set(extra, "a", ["title": .string("A")])
        server.dropAnswers = ["phone": 1]
        await phone.syncNow(reason: "test")
        XCTAssertNotNil(server.record(extra, "a"), "applied, but the answer never came")
        let seqBefore = server.seq
        await phone.syncNow(reason: "test")
        XCTAssertEqual(server.seq, seqBefore, "the retry is no change: no new seq")
        let left = await phone.status().pendingRecords
        XCTAssertEqual(left, 0)
    }

    func testAFieldOverwrittenElsewhereWithALaterClockIsNotSentForever() async throws {
        let store = TestStore(types: [extra])
        let phone = try await engine("phone", hub: true, store: store)
        await phone.seed(types: [extra])
        // A clock far ahead of this device's, already in the space.
        server.inject(extra, "a", set: ["title": .string("Later")], clock: "1999999999999.0000.mac")
        server.now = { 1_999_999_999_999 }
        store.set(extra, "a", ["title": .string("Mine")])
        await phone.syncNow(reason: "test")
        let left = await phone.status().pendingRecords
        XCTAssertEqual(left, 0)
        XCTAssertEqual(store.items[extra]?["a"], ["title": .string("Later")], "the later edit came in")
    }

    // MARK: - Refused

    func testARefusedRecordLeavesTheQueueAndIsLogged() async throws {
        let store = TestStore(types: [extra])
        let phone = try await engine("phone", hub: true, store: store)
        await phone.seed(types: [extra])
        server.refuse = [extra: "too_large"]
        store.set(extra, "a", ["title": .string("A")])
        await phone.syncNow(reason: "test")
        XCTAssertNil(server.record(extra, "a"))
        let left = await phone.status().pendingRecords
        XCTAssertEqual(left, 0)
        XCTAssertEqual(store.items[extra]?["a"], ["title": .string("A")], "the store keeps it")
        XCTAssertTrue(logs.all.contains { $0.contains("refused: too_large") })
    }

    func testWithoutTheConsentHealthStaysHereAndSeedsOnceItComes() async throws {
        let store = TestStore(types: ["food.meal"])
        let phone = try await engine("phone", hub: true, store: store)
        await phone.setHealthConsent(true)
        server.consent = false
        store.items["food.meal"] = ["m1": ["title": .string("Oats")]]
        await phone.seed(types: ["food.meal"])
        XCTAssertNil(server.record("food.meal", "m1"))
        var status = await phone.status()
        XCTAssertFalse(status.healthConsent, "refused for consent: T2 stops")
        XCTAssertEqual(status.pendingRecords, 0)
        XCTAssertTrue(status.waitingToSeed.contains("food.meal"))
        XCTAssertEqual(try phone.mirror.read { try $0.count(type: "food.meal") }, 0, "T2 rows left the mirror")
        XCTAssertEqual(store.items["food.meal"]?["m1"], ["title": .string("Oats")], "the store keeps its meal")

        server.consent = true
        await phone.syncNow(reason: "test")
        status = await phone.status()
        XCTAssertTrue(status.healthConsent, "every answer says the consent")
        XCTAssertEqual(server.visible(type: "food.meal")["m1"], ["title": .string("Oats")], "and with it the type seeds")
    }

    func testASpokeNeverSendsAHubOnlyType() async throws {
        let store = TestStore(types: ["core.hubStatus"])
        let mac = try await engine("mac", hub: false, store: store)
        await mac.setHubPresence(.seeded(["core.hubStatus"]))
        await mac.seed(types: ["core.hubStatus"])
        store.set("core.hubStatus", "status", ["v": .object(["charging": .bool(true)])])
        await mac.syncNow(reason: "test")
        XCTAssertTrue(server.requests.allSatisfy { $0.changes.isEmpty })
    }

    // MARK: - Blobs

    func testBlobsGoUpBeforeTheirRecordAndAStuckOneHoldsBackOnlyItsOwn() async throws {
        let listen = "podcast.listen"
        let store = TestStore(types: [listen])
        let phone = try await engine("phone", hub: true, store: store)
        await phone.seed(types: [listen])
        let r1 = store.attach(listen, "l1", field: "route", data: Data("route one".utf8))
        let r2 = store.attach(listen, "l2", field: "route", data: Data("route two".utf8))
        server.failingPuts = [r1.sha256]
        store.set(listen, "l1", ["title": .string("One"), "route": r1.value])
        store.set(listen, "l2", ["title": .string("Two"), "route": r2.value])
        await phone.syncNow(reason: "test")
        XCTAssertNil(server.record(listen, "l1"), "its blob didn't go up, so neither did its record")
        XCTAssertEqual(server.visible(type: listen)["l2"]?["route"], r2.value)
        XCTAssertNotNil(server.blobs[r2.sha256])

        server.failingPuts = []
        await phone.syncNow(reason: "test")
        XCTAssertNil(server.record(listen, "l1"), "a failed upload backs off before it's tried again")
        try await Task.sleep(for: .milliseconds(120))   // past the (test-sized) backoff
        await phone.syncNow(reason: "test")
        XCTAssertEqual(server.visible(type: listen)["l1"]?["route"], r1.value)
        XCTAssertFalse(logs.all.contains { $0.contains("blob_missing") }, "no patch ever named a blob the service lacked")
    }

    func testAFieldWhoseFileIsntReadyWaitsWhileTheRestOfItsRecordGoes() async throws {
        let listen = "podcast.listen"
        let store = TestStore(types: [listen])
        let phone = try await engine("phone", hub: true, store: store)
        await phone.seed(types: [listen])
        let data = Data("a route still growing".utf8)
        let ref = BlobReference(sha256: TestStore.sha(data), size: Int64(data.count), ext: "bin")
        store.set(listen, "l1", ["title": .string("Live"), "route": ref.value])   // no file yet
        await phone.syncNow(reason: "test")
        XCTAssertEqual(server.visible(type: listen)["l1"], ["title": .string("Live")])
        _ = store.attach(listen, "l1", field: "route", data: data)                // the listen ended
        await phone.syncNow(reason: "test")
        XCTAssertEqual(server.visible(type: listen)["l1"]?["route"], ref.value)
    }

    func testEagerBlobsComeDownWithTheirRecordAndLazyOnesOnFirstUse() async throws {
        let phoneStore = TestStore(types: ["podcast.listen", "podcast.transcript"])
        let phone = try await engine("phone", hub: true, store: phoneStore)
        await phone.seed(types: ["podcast.listen", "podcast.transcript"])
        let route = phoneStore.attach("podcast.listen", "l1", field: "route", data: Data("route".utf8))
        let body = phoneStore.attach("podcast.transcript", "t1", field: "body", data: Data("words".utf8))
        phoneStore.set("podcast.listen", "l1", ["route": route.value])
        phoneStore.set("podcast.transcript", "t1", ["body": body.value])
        await phone.syncNow(reason: "test")

        let macStore = TestStore(types: ["podcast.listen", "podcast.transcript"])
        let mac = try await engine("mac", hub: false, store: macStore)
        await mac.setHubPresence(.seeded(["podcast.listen", "podcast.transcript"]))
        await mac.seed(types: ["podcast.listen", "podcast.transcript"])
        await mac.blobsSettled()
        XCTAssertEqual(macStore.storedBlobs["podcast.listen/l1/route"], Data("route".utf8), "eager")
        XCTAssertNil(macStore.storedBlobs["podcast.transcript/t1/body"], "lazy: not yet")
        let fetched = await mac.ensureBlob(type: "podcast.transcript", id: "t1", field: "body")
        XCTAssertTrue(fetched)
        XCTAssertEqual(macStore.storedBlobs["podcast.transcript/t1/body"], Data("words".utf8))
    }

    func testAT2BlobRefusedForConsentStopsHealth() async throws {
        let store = TestStore(types: ["food.mealPhoto"])
        let phone = try await engine("phone", hub: true, store: store)
        await phone.setHealthConsent(true)
        await phone.seed(types: ["food.mealPhoto"])
        server.consent = false
        let photo = store.attach("food.mealPhoto", "p1", field: "v", data: Data("jpeg".utf8))
        store.set("food.mealPhoto", "p1", ["v": photo.value])
        await phone.syncNow(reason: "test")
        let status = await phone.status()
        XCTAssertFalse(status.healthConsent)
        XCTAssertNil(server.blobs[photo.sha256])
    }

    // MARK: - Replay

    func testARecordTheStoreCantTakeYetWaitsAndIsReplayed() async throws {
        let phoneStore = TestStore(types: [extra])
        let phone = try await engine("phone", hub: true, store: phoneStore)
        await phone.seed(types: [extra])
        phoneStore.set(extra, "a", ["title": .string("Held")])
        await phone.syncNow(reason: "test")

        let macStore = TestStore(types: [extra])
        macStore.refuse = ["a"]
        let mac = try await engine("mac", hub: false, store: macStore)
        await mac.setHubPresence(.seeded([extra]))
        await mac.seed(types: [extra])
        XCTAssertNil(macStore.items[extra]?["a"])
        XCTAssertEqual(try mac.mirror.read { try $0.waitingIDs(type: self.extra) }, ["a"])

        macStore.refuse = []
        await mac.replay(types: [extra])
        XCTAssertEqual(macStore.items[extra]?["a"], ["title": .string("Held")])
        XCTAssertEqual(try mac.mirror.read { try $0.waitingIDs(type: self.extra) }, [])
    }

    // MARK: - Seeding (§3)

    func testASpokeTakesThePhonesSetOfAPhoneSetKindAndDropsItsOwn() async throws {
        let routine = "plan.routine"
        let phoneStore = TestStore(types: [routine])
        phoneStore.items[routine] = ["r1": ["title": .string("Gym (phone)")], "r2": ["title": .string("Read")]]
        phoneStore.editedAt = ["\(routine)/r1": t0, "\(routine)/r2": t0]
        let phone = try await engine("phone", hub: true, store: phoneStore)
        await phone.seed(types: [routine])
        XCTAssertEqual(server.visible(type: routine).count, 2)

        let macStore = TestStore(types: [routine])
        macStore.items[routine] = ["r1": ["title": .string("Gym (old)")], "m1": ["title": .string("Default routine")]]
        let mac = try await engine("mac", hub: false, store: macStore)
        await mac.setHubPresence(.seeded([routine]))
        await mac.seed(types: [routine])
        XCTAssertEqual(macStore.items[routine], ["r1": ["title": .string("Gym (phone)")], "r2": ["title": .string("Read")]])
        XCTAssertTrue(server.requests.filter { $0.device == "mac" }.allSatisfy { $0.changes.isEmpty }, "the spoke seeded nothing")
        XCTAssertEqual(server.visible(type: routine).count, 2, "phone-set kinds don't multiply")

        macStore.set(routine, "r2", ["title": .string("Read more")])
        await mac.syncNow(reason: "test")
        XCTAssertEqual(server.visible(type: routine)["r2"], ["title": .string("Read more")], "after that, edits flow")
    }

    func testASpokeWaitsForTheHubsSeedButSeedsAloneWithNoIPhone() async throws {
        let routine = "plan.routine"
        let macStore = TestStore(types: [routine])
        macStore.items[routine] = ["m1": ["title": .string("Mine")]]
        let mac = try await engine("mac", hub: false, store: macStore)
        await mac.seed(types: [routine])
        XCTAssertNil(server.record(routine, "m1"), "unknown hub: wait")
        await mac.setHubPresence(.none)
        XCTAssertEqual(server.visible(type: routine)["m1"], ["title": .string("Mine")], "no iPhone: phone-set kinds seed as edited")
    }

    func testWhatASpokeAddsBeforeItsFirstPullSurvivesThePhonesSet() async throws {
        let alarm = "plan.alarm"
        let phoneStore = TestStore(types: [alarm])
        phoneStore.items[alarm] = ["p1": ["title": .string("7:00")]]
        let phone = try await engine("phone", hub: true, store: phoneStore)
        await phone.seed(types: [alarm])

        let ipadStore = TestStore(types: [alarm])
        ipadStore.items[alarm] = ["old": ["title": .string("A default")]]
        let ipad = try await engine("ipad", hub: false, store: ipadStore)
        await ipad.setHubPresence(.seeded([alarm]))
        server.offline = ["ipad"]
        await ipad.seed(types: [alarm])   // waits for the phone's set; no pull yet
        ipadStore.set(alarm, "new", ["title": .string("6:30")])   // added here meanwhile
        await ipad.syncNow(reason: "test")
        server.offline = []
        await ipad.syncNow(reason: "test")
        await ipad.syncNow(reason: "test")

        XCTAssertEqual(Set((ipadStore.items[alarm] ?? [:]).keys), ["p1", "new"], "the leftover goes; what was added here stays")
        XCTAssertEqual(Set(server.visible(type: alarm).keys), ["p1", "new"], "and syncs")
    }

    func testWhatASpokeAddsWhileItWaitsForThePhonesSetSurvivesARelaunch() async throws {
        let alarm = "plan.alarm"
        let phoneStore = TestStore(types: [alarm])
        phoneStore.items[alarm] = ["p1": ["title": .string("7:00")]]
        let phone = try await engine("phone", hub: true, store: phoneStore)
        await phone.seed(types: [alarm])

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("touched-\(UUID().uuidString).sqlite")
        let ipadStore = TestStore(types: [alarm])
        ipadStore.items[alarm] = ["old": ["title": .string("A default")]]
        let ipad = try await engine("ipad", hub: false, store: ipadStore, mirror: try RecordMirror(url: file))
        await ipad.setHubPresence(.seeded([alarm]))
        server.offline = ["ipad"]
        await ipad.seed(types: [alarm])
        ipadStore.set(alarm, "new", ["title": .string("6:30")])
        await ipad.syncNow(reason: "test")
        await ipad.stop()

        server.offline = []
        let relaunched = try await engine("ipad", hub: false, store: ipadStore, mirror: try RecordMirror(url: file))
        await relaunched.setHubPresence(.seeded([alarm]))
        await relaunched.syncNow(reason: "test")
        await relaunched.syncNow(reason: "test")
        XCTAssertEqual(Set((ipadStore.items[alarm] ?? [:]).keys), ["p1", "new"], "kept across the relaunch")
        XCTAssertEqual(Set(server.visible(type: alarm).keys), ["p1", "new"])
    }

    func testADeleteOnATypeNotSeededYetBecomesATombstoneOnceItIs() async throws {
        let phoneStore = TestStore(types: [extra])
        phoneStore.items[extra] = ["x": ["title": .string("X")], "y": ["title": .string("Y")]]
        let phone = try await engine("phone", hub: true, store: phoneStore)
        await phone.seed(types: [extra])

        let macStore = TestStore(types: [extra])
        macStore.items[extra] = ["x": ["title": .string("X")], "y": ["title": .string("Y")]]
        let mac = try await engine("mac", hub: false, store: macStore)
        await mac.setHubPresence(.seeded([]))
        await mac.seed(types: [extra])   // the phone's seed of it isn't acknowledged yet: waits
        macStore.delete(extra, "x")
        await mac.syncNow(reason: "test")
        XCTAssertNil(server.record(extra, "x")?.deleted, "nothing goes before the type seeds")

        await mac.setHubPresence(.seeded([extra]))
        await mac.syncNow(reason: "test")
        XCTAssertNotNil(server.record(extra, "x")?.deleted, "the delete made meanwhile is this device's")
        XCTAssertEqual(Set(server.visible(type: extra).keys), ["y"])
    }

    func testAStartedOverSpaceSeedsAgainOnlyWhatWasAskedToSeed() async throws {
        let override = "plan.override"
        let store = TestStore(types: [extra, override])
        store.items[extra] = ["a": ["title": .string("A")]]
        store.items[override] = ["o": ["title": .string("Not moved yet")]]
        let phone = try await engine("phone", hub: true, store: store)
        await phone.seed(types: [extra])
        server.wipe()
        await phone.syncNow(reason: "test")
        XCTAssertNotNil(server.visible(type: extra)["a"])
        XCTAssertNil(server.record(override, "o"), "a type still waiting to move isn't seeded by a wipe")
    }

    func testDefaultSeedsOnlyWhatDiffersTheHubAtOneASpokeAtZero() async throws {
        let settings = "core.appSettings"
        let defaults: [String: JSONValue] = ["unit": .string("km"), "theme": .string("auto"), "week": .string("mon")]
        let phoneStore = TestStore(types: [settings])
        phoneStore.defaults = [settings: defaults]
        phoneStore.items[settings] = ["app": ["unit": .string("km"), "theme": .string("dark"), "week": .string("sat")]]
        let phone = try await engine("phone", hub: true, store: phoneStore)
        await phone.seed(types: [settings])
        let sent = try XCTUnwrap(server.requests.last { $0.device == "phone" && !$0.changes.isEmpty }?.changes.first)
        XCTAssertEqual(Set(sent.set.keys), ["theme", "week"], "only what differs from the default")
        XCTAssertEqual(Set(sent.clocks.values), ["0000000000001.0000.phone"])

        let macStore = TestStore(types: [settings])
        macStore.defaults = [settings: defaults]
        macStore.items[settings] = ["app": ["unit": .string("mi"), "theme": .string("auto"), "week": .string("sun")]]
        let mac = try await engine("mac", hub: false, store: macStore)
        await mac.setHubPresence(.seeded([settings]))
        await mac.seed(types: [settings])
        let macSent = try XCTUnwrap(server.requests.last { $0.device == "mac" && !$0.changes.isEmpty }?.changes.first)
        XCTAssertEqual(Set(macSent.set.keys), ["unit", "week"])
        XCTAssertEqual(Set(macSent.clocks.values), ["0000000000000.0000.mac"])
        await phone.syncNow(reason: "test")

        let converged: [String: JSONValue] = ["unit": .string("mi"), "theme": .string("dark"), "week": .string("sat")]
        XCTAssertEqual(server.visible(type: settings)["app"], converged, "the hub wins where both differ; a spoke's beats a default")
        XCTAssertEqual(phoneStore.items[settings]?["app"], converged)
        XCTAssertEqual(macStore.items[settings]?["app"], converged)

        phoneStore.set(settings, "app", ["unit": .string("km"), "theme": .string("dark"), "week": .string("sat")])
        await phone.syncNow(reason: "test")
        await mac.syncNow(reason: "test")
        XCTAssertEqual(macStore.items[settings]?["app"]?["unit"], .string("km"), "any real edit beats every seed")
    }

    func testASpokeOnTheDefaultStaysQuiet() async throws {
        let settings = "core.appSettings"
        let store = TestStore(types: [settings])
        store.defaults = [settings: ["unit": .string("km")]]
        store.items[settings] = ["app": ["unit": .string("km")]]
        let mac = try await engine("mac", hub: false, store: store)
        await mac.setHubPresence(.seeded([settings]))
        await mac.seed(types: [settings])
        XCTAssertTrue(server.requests.allSatisfy { $0.changes.isEmpty })
    }

    func testEditedSeedsUseTheItemsOwnTimeAndRank() async throws {
        let progress = "podcast.progress"
        let store = TestStore(types: [progress])
        store.items[progress] = ["e1": ["v": .object(["position": .int(0), "completed": .bool(true)])]]
        store.editedAt = ["\(progress)/e1": t0]
        store.ranks = ["\(progress)/e1": 1]
        let phone = try await engine("phone", hub: true, store: store)
        await phone.seed(types: [progress])
        XCTAssertEqual(server.record(progress, "e1")?.clocks["v"], "1760000000000.0001.phone", "completed seeds at .0001")
    }

    func testDrainArrivalsEnterWithTheirSeedClockNotAFreshOne() async throws {
        let store = TestStore(types: [extra])
        let phone = try await engine("phone", hub: true, store: store)
        await phone.seed(types: [extra])
        store.items[extra] = ["late": ["title": .string("From an old iPad")]]
        store.editedAt = ["\(extra)/late": t0]
        await phone.seedArrived(type: extra, ids: ["late"])
        XCTAssertEqual(server.record(extra, "late")?.clocks["title"], "1760000000000.0000.phone")
    }

    func testTheSeedCountsOnlyOnceEveryRecordCameBack() async throws {
        let store = TestStore(types: [extra])
        store.items[extra] = ["a": ["title": .string("A")], "b": ["title": .string("B")]]
        let phone = try await engine("phone", hub: true, store: store)
        let told = LogBox()
        await phone.setSeedAcknowledgedHandler { told.add("seeded") }
        server.offline = ["phone"]
        await phone.seed(types: [extra])
        var seeded = await phone.isSeeded
        XCTAssertFalse(seeded, "not acknowledged yet")
        server.offline = []
        await phone.syncNow(reason: "test")
        seeded = await phone.isSeeded
        XCTAssertTrue(seeded)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(told.all, ["seeded"])
        try await phone.reportSyncState(seededAt: t0, flippedAt: nil)
        XCTAssertEqual(server.syncStates["phone"]?.seeded, [extra])
    }

    func testARefusedSeedRecordMeansNotSeeded() async throws {
        let store = TestStore(types: [extra])
        store.items[extra] = ["a": ["title": .string("A")]]
        server.refuse = [extra: "too_large"]
        let phone = try await engine("phone", hub: true, store: store)
        await phone.seed(types: [extra])
        let seeded = await phone.isSeeded
        XCTAssertFalse(seeded)
    }

    // MARK: - Clock offset

    func testTheOffsetIsLearnedFromTheAnswers() async throws {
        let store = TestStore(types: [extra])
        let phone = try await engine("phone", hub: true, store: store)
        server.now = { Int64(Date().timeIntervalSince1970 * 1000) - 120_000 }
        await phone.syncNow(reason: "test")
        let offset = await phone.status().offset
        XCTAssertEqual(Double(offset), -120_000, accuracy: 2_000)
    }

    func testAnHourFastDeviceIsRefusedReStampsAndDoesntOverwriteALaterEdit() async throws {
        let phoneStore = TestStore(types: [extra])
        let phone = try await engine("phone", hub: true, store: phoneStore, skew: 3_600)
        server.offline = ["phone"]
        await phone.seed(types: [extra])          // no answer yet: nothing has told it its clock is fast
        phoneStore.set(extra, "a", ["title": .string("From the fast phone")])
        server.offline = []
        await phone.syncNow(reason: "test")
        XCTAssertTrue(logs.all.contains { $0.contains("refused: clock") }, "refused first")
        let written = try XCTUnwrap(server.record(extra, "a")?.clocks["title"].flatMap(HLC.init), "then accepted, re-stamped")
        let real = HLCClock.ms(Date())
        XCTAssertLessThan(written.ms, real + 5 * 60 * 1000, "an honest clock")
        let offset = await phone.status().offset
        XCTAssertEqual(Double(offset), -3_600_000, accuracy: 5_000)
        let left = await phone.status().pendingRecords
        XCTAssertEqual(left, 0)

        let macStore = TestStore(types: [extra])
        let mac = try await engine("mac", hub: false, store: macStore)
        await mac.setHubPresence(.seeded([extra]))
        await mac.seed(types: [extra])
        try await Task.sleep(for: .milliseconds(20))
        macStore.set(extra, "a", ["title": .string("Later, on the Mac")])
        await mac.syncNow(reason: "test")
        await phone.syncNow(reason: "test")
        XCTAssertEqual(server.visible(type: extra)["a"], ["title": .string("Later, on the Mac")])
        XCTAssertEqual(phoneStore.items[extra]?["a"], ["title": .string("Later, on the Mac")],
                       "the fast phone's edit didn't outrank the later one")
    }

    func testASeedFromTheFutureIsSeededAtTheCorrectedNow() {
        var clock = HLCClock(device: "phone")
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        XCTAssertEqual(clock.seedMs(now.addingTimeInterval(-60), now: now), HLCClock.ms(now) - 60_000, "the item's own time")
        XCTAssertEqual(clock.seedMs(now.addingTimeInterval(3_600), now: now), HLCClock.ms(now), "an hour ahead: now")
        clock.learn(serverNow: HLCClock.ms(now) - 3_600_000, sent: now, received: now)
        XCTAssertEqual(clock.seedMs(now, now: now), HLCClock.ms(now) - 3_600_000, "now, as the service has it")
    }

    func testAFastClockIsStampedAgainAtItsPhysicalTimePlusTheOffsetKnownNow() throws {
        var clock = HLCClock(device: "phone")
        let real = Date(timeIntervalSince1970: 1_760_000_000)
        clock.observe("1760000000500.0003.mac", fromService: true)
        let fast = clock.issue(now: real.addingTimeInterval(3_600 + 7))   // an edit 7 s in, an hour fast, offset 0
        clock.learn(serverNow: HLCClock.ms(real) + 60_000, sent: real.addingTimeInterval(3_660), received: real.addingTimeInterval(3_660))
        let most = HLCClock.ms(real) + 60_000 + HLCClock.mostAhead
        let moved = try XCTUnwrap(clock.restamped(fast.text, offsetAtIssue: 0, mostMs: most, now: real.addingTimeInterval(3_660)).flatMap(HLC.init))
        XCTAssertEqual(moved.ms, HLCClock.ms(real) + 7_000, "the edit's own time, told honestly; not the time of the retry")
        XCTAssertEqual(moved.counter, fast.counter)
        XCTAssertNil(clock.restamped("1760000000500.0003.mac", offsetAtIssue: 0, mostMs: most, now: real), "another device's clock never moves")
        clock.lower(mostMs: most)
        XCTAssertEqual(clock.state.lastIssued, "1760000000500.0003.mac", "down to the service's highest, whatever the shift")
        let next = clock.issue(now: real.addingTimeInterval(3_668))
        XCTAssertEqual(next.ms, HLCClock.ms(real) + 68_000, "and it issues on from there")
    }

    // MARK: - Echoes

    func testApplyingARecordIsntSentBack() async throws {
        let phoneStore = TestStore(types: [extra])
        let phone = try await engine("phone", hub: true, store: phoneStore)
        await phone.seed(types: [extra])
        phoneStore.set(extra, "a", ["title": .string("A"), "tags": .array([.string("x")])])
        await phone.syncNow(reason: "test")

        let macStore = TestStore(types: [extra])
        let mac = try await engine("mac", hub: false, store: macStore)
        await mac.setHubPresence(.seeded([extra]))
        await mac.seed(types: [extra])
        await mac.syncNow(reason: "the echo's pass")
        XCTAssertTrue(server.requests.filter { $0.device == "mac" }.allSatisfy { $0.changes.isEmpty },
                      "the store reported what it was handed; nothing went back")
        phoneStore.delete(extra, "a")
        await phone.syncNow(reason: "test")
        let seq = server.seq
        await mac.syncNow(reason: "test")
        await mac.syncNow(reason: "the echo's pass")
        XCTAssertNil(macStore.items[extra]?["a"])
        XCTAssertEqual(server.seq, seq, "the removal's echo sent no second tombstone")
    }

    // MARK: - Fable's review of Stage B

    func testAnEngineStartedAgainOnItsMirrorCarriesOnWhereItLeftOff() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = RecordMirror.url(account: "acc", in: folder)
        let store = TestStore(types: [extra])
        store.items[extra] = ["a": ["title": .string("Seeded")]]
        server.offline = ["phone"]
        var phone: SpaceSync? = try await engine("phone", hub: true, store: store, mirror: RecordMirror(url: url))
        await phone!.seed(types: [extra])
        store.set(extra, "b", ["title": .string("Edited offline")])
        await phone!.syncNow(reason: "test")
        let before = await phone!.status()
        XCTAssertEqual(before.pendingRecords, 2)
        XCTAssertFalse(before.isSeeded)
        let lastClock = try XCTUnwrap(try RecordMirror(url: url).read { try $0.pending(RecordKey(type: self.extra, id: "b")) }?.fields["title"]?.clock.clock)
        await phone!.stop()
        phone = nil

        let again = try await engine("phone", hub: true, store: store, mirror: RecordMirror(url: url))
        let after = await again.status()
        XCTAssertEqual(after.pendingRecords, 2, "what waited still waits")
        XCTAssertEqual(after.seeded, [extra])
        XCTAssertFalse(after.isSeeded, "the seed still needs its acknowledgement")
        server.offline = []
        store.set(extra, "c", ["title": .string("After the restart")])
        await again.syncNow(reason: "test")
        XCTAssertEqual(server.visible(type: extra).count, 3)
        let seeded = await again.isSeeded
        XCTAssertTrue(seeded)
        XCTAssertGreaterThan(try XCTUnwrap(server.record(extra, "c")?.clocks["title"]), lastClock, "the clock went on from its saved state")
    }

    func testAPatchRefusedAsBlobMissingIsSentAgainAfterTheBlob() async throws {
        let listen = "podcast.listen"
        let store = TestStore(types: [listen])
        let phone = try await engine("phone", hub: true, store: store)
        await phone.seed(types: [listen])
        let route = store.attach(listen, "l1", field: "route", data: Data("route".utf8))
        // The device uploaded it once; the service's index then lost it.
        try phone.mirror.write { try $0.setUploaded(route.sha256, true) }
        store.set(listen, "l1", ["route": route.value])
        await phone.syncNow(reason: "test")
        XCTAssertTrue(logs.all.contains { $0.contains("refused: blob_missing") })
        await phone.syncNow(reason: "test")
        XCTAssertEqual(server.visible(type: listen)["l1"]?["route"], route.value)
    }

    func testAFastDeleteIsRefusedThenStampedAgainAndTaken() async throws {
        let store = TestStore(types: [extra])
        store.items[extra] = ["a": ["title": .string("A")]]
        let phone = try await engine("phone", hub: true, store: store, skew: 3_600)
        server.offline = ["phone"]
        await phone.seed(types: [extra])     // no answer yet: the clock's an hour fast and doesn't know it
        store.delete(extra, "a")
        server.offline = []
        await phone.syncNow(reason: "test")
        XCTAssertTrue(logs.all.contains { $0.contains("refused: clock") }, "the fast delete was refused first")
        let deleted = try XCTUnwrap(server.record(extra, "a")?.deleted.flatMap(HLC.init), "then taken")
        XCTAssertLessThan(deleted.ms, HLCClock.ms(Date()) + 5 * 60 * 1000, "at an honest time")
        XCTAssertNil(server.visible(type: extra)["a"])
        let left = await phone.status().pendingRecords
        XCTAssertEqual(left, 0)
    }

    func testAFastClockRefusedAfterTheOffsetWasLearnedStillRecovers() async throws {
        // The held-back blob: the record is edited while the clock is an hour fast and its only
        // field waits for its file; a pull teaches the offset (shift 0 from then on); then the
        // file is ready and the record goes, still with the fast clock, and is refused.
        let listen = "podcast.listen"
        let store = TestStore(types: [listen])
        let phone = try await engine("phone", hub: true, store: store, skew: 3_600)
        server.offline = ["phone"]
        await phone.seed(types: [listen])
        let data = Data("a route".utf8)
        let ref = BlobReference(sha256: TestStore.sha(data), size: Int64(data.count), ext: "bin")
        store.set(listen, "l1", ["route": ref.value])   // no file yet
        server.offline = []
        await phone.syncNow(reason: "test")
        let learned = await phone.status().offset
        XCTAssertEqual(Double(learned), -3_600_000, accuracy: 5_000, "a pull taught it the offset")
        XCTAssertNil(server.record(listen, "l1"))
        _ = store.attach(listen, "l1", field: "route", data: data)
        await phone.syncNow(reason: "test")
        XCTAssertTrue(logs.all.contains { $0.contains("refused: clock") })
        XCTAssertEqual(server.visible(type: listen)["l1"]?["route"], ref.value, "stamped again at its real time, and taken")
    }

    func testAStoreEditMadeWhileApplyingIsKeptAndTheEchoIsnt() async throws {
        let phoneStore = TestStore(types: [extra])
        let phone = try await engine("phone", hub: true, store: phoneStore)
        await phone.seed(types: [extra])
        phoneStore.set(extra, "a", ["title": .string("Source")])
        await phone.syncNow(reason: "test")

        let macStore = TestStore(types: [extra])
        macStore.cascade = ["a": (extra, "derived", ["title": .string("Made from a")])]
        let mac = try await engine("mac", hub: false, store: macStore)
        await mac.setHubPresence(.seeded([extra]))
        await mac.seed(types: [extra])
        await mac.syncNow(reason: "test")
        let sent = server.requests.filter { $0.device == "mac" }.flatMap(\.changes).map(\.id)
        XCTAssertEqual(sent, ["derived"], "the derived item went up; the applied one's echo didn't")
        XCTAssertEqual(server.visible(type: extra)["derived"], ["title": .string("Made from a")])
    }

    func testRequestsStayUnderTheByteCapAndHalveAfterA413() async throws {
        let store = TestStore(types: [extra])
        var config = SpaceSync.Configuration(device: "phone", isHub: true, catalog: catalog)
        config.debounce = .seconds(3_600)
        config.batchBytes = 400
        let phone = try SpaceSync(mirror: RecordMirror(), transport: MemoryTransport(server: server, device: "phone"), config: config)
        await phone.registerAdapter(store)
        store.engine = phone
        for n in 0..<8 { store.items[extra, default: [:]]["r\(n)"] = ["title": .string(String(repeating: "x", count: 120))] }
        server.tooLargeAbove = 1
        await phone.seed(types: [extra])
        XCTAssertEqual(server.visible(type: extra).count, 8)
        let sizes = server.requests.map { $0.changes.count }.filter { $0 > 0 }
        XCTAssertTrue(sizes.allSatisfy { $0 == 1 }, "after the 413, one at a time: \(sizes)")
        server.tooLargeAbove = nil
        for n in 0..<8 { store.set(extra, "r\(n)", ["title": .string(String(repeating: "y", count: 120))]) }
        let before = server.requests.count
        await phone.syncNow(reason: "test")
        for request in server.requests.dropFirst(before) {
            XCTAssertLessThanOrEqual(try request.body().count, 400 + 200, "near the byte cap")
        }
        XCTAssertGreaterThan(server.requests.count - before, 2, "the eight went in several requests")
    }

    func testAWithdrawalHereIsntUndoneByAStaleAnswer() async throws {
        let store = TestStore(types: ["food.meal"])
        let phone = try await engine("phone", hub: true, store: store)
        await phone.setHealthConsent(true)
        await phone.setHealthConsent(false)                  // withdrawn here; the service not told yet
        await phone.syncNow(reason: "test")                  // the service still says yes
        var consent = await phone.status().healthConsent
        XCTAssertFalse(consent, "a stale yes doesn't bring it back")
        await phone.consentWithdrawalConfirmed()
        try await Task.sleep(for: .milliseconds(5))
        await phone.syncNow(reason: "test")                  // given again elsewhere, after the withdrawal
        consent = await phone.status().healthConsent
        XCTAssertTrue(consent)
    }

    func testEagerBlobsThatFailAreTriedAgain() async throws {
        let phoneStore = TestStore(types: ["podcast.listen"])
        let phone = try await engine("phone", hub: true, store: phoneStore)
        await phone.seed(types: ["podcast.listen"])
        let route = phoneStore.attach("podcast.listen", "l1", field: "route", data: Data("route".utf8))
        phoneStore.set("podcast.listen", "l1", ["route": route.value])
        await phone.syncNow(reason: "test")

        server.failingGets = [route.sha256]
        let macStore = TestStore(types: ["podcast.listen"])
        let mac = try await engine("mac", hub: false, store: macStore)
        await mac.setHubPresence(.seeded(["podcast.listen"]))
        await mac.seed(types: ["podcast.listen"])
        await mac.blobsSettled()
        XCTAssertNil(macStore.storedBlobs["podcast.listen/l1/route"])
        let wanted = await mac.status().blobsWanted
        XCTAssertEqual(wanted, 1, "still wanted, for later")
        server.failingGets = []
        try await Task.sleep(for: .milliseconds(200))       // past the (test-sized) backoff
        await mac.blobsSettled()
        XCTAssertEqual(macStore.storedBlobs["podcast.listen/l1/route"], Data("route".utf8))
    }

    func testABlobRefusedForGoodWaitsForTheNextChangeWhileTheRestGoes() async throws {
        let listen = "podcast.listen"
        let store = TestStore(types: [listen])
        let phone = try await engine("phone", hub: true, store: store)
        await phone.seed(types: [listen])
        let route = store.attach(listen, "l1", field: "route", data: Data("bad".utf8))
        server.refusingPuts = [route.sha256: 400]
        store.set(listen, "l1", ["title": .string("One"), "route": route.value])
        await phone.syncNow(reason: "test")
        XCTAssertEqual(server.visible(type: listen)["l1"], ["title": .string("One")])
        await phone.syncNow(reason: "test")
        XCTAssertEqual(logs.all.filter { $0.contains("route refused") }.count, 1, "not tried again by itself")
        server.refusingPuts = [:]
        store.set(listen, "l1", ["title": .string("One"), "route": route.value])   // reported again
        await phone.syncNow(reason: "test")
        XCTAssertEqual(server.visible(type: listen)["l1"]?["route"], route.value)
    }

    func testARefusalIsKeptCountedAndToldToTheStore() async throws {
        let store = TestStore(types: [extra])
        let phone = try await engine("phone", hub: true, store: store)
        await phone.seed(types: [extra])
        server.refuse = [extra: "too_large"]
        store.set(extra, "a", ["title": .string("A")])
        await phone.syncNow(reason: "test")
        let refused = await phone.status().refused
        XCTAssertEqual(refused, 1)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(store.refusals, ["plan.extra a too_large"])
        server.refuse = [:]
        store.set(extra, "a", ["title": .string("A")])     // the same item, reported again
        await phone.syncNow(reason: "test")
        XCTAssertEqual(server.visible(type: extra)["a"], ["title": .string("A")], "sent whole once more")
        let left = await phone.status().refused
        XCTAssertEqual(left, 0)
    }

    func testAnItemMadeAgainOverATombstoneComesBackExactlyAsTheStoreHasIt() async throws {
        let store = TestStore(types: [extra])
        let phone = try await engine("phone", hub: true, store: store)
        await phone.seed(types: [extra])
        store.set(extra, "a", ["title": .string("Oats"), "kcal": .int(300)])
        await phone.syncNow(reason: "test")
        store.delete(extra, "a")
        await phone.syncNow(reason: "test")
        store.set(extra, "a", ["title": .string("Oats")])
        await phone.syncNow(reason: "test")
        XCTAssertEqual(server.visible(type: extra)["a"], ["title": .string("Oats")], "the old kcal didn't come back")
        XCTAssertEqual(server.record(extra, "a")?.fields["kcal"], .null)
    }

    func testANewEpochEmptiesTheMirrorAndSeedsAgainFromTheStores() async throws {
        let store = TestStore(types: [extra])
        store.items[extra] = ["a": ["title": .string("A")]]
        store.editedAt = ["\(extra)/a": t0]
        let phone = try await engine("phone", hub: true, store: store)
        await phone.seed(types: [extra])
        let firstEpoch = await phone.status().epoch
        XCTAssertNotNil(firstEpoch)
        server.wipe()
        await phone.syncNow(reason: "test")
        let status = await phone.status()
        XCTAssertNotEqual(status.epoch, firstEpoch)
        XCTAssertEqual(server.visible(type: extra)["a"], ["title": .string("A")], "seeded again from the store")
        XCTAssertEqual(server.record(extra, "a")?.clocks["title"], "1760000000000.0000.phone", "with its own time")
        XCTAssertTrue(status.isSeeded)
    }

    func testARestoredSpaceGetsBackWhatThisDeviceHolds() async throws {
        let store = TestStore(types: [extra])
        let phone = try await engine("phone", hub: true, store: store)
        await phone.seed(types: [extra])
        store.set(extra, "a", ["title": .string("A")])
        await phone.syncNow(reason: "test")
        store.set(extra, "b", ["title": .string("B")])
        await phone.syncNow(reason: "test")
        server.restore(toSeq: 0)    // back to before both
        await phone.syncNow(reason: "test")
        XCTAssertEqual(server.visible(type: extra), ["a": ["title": .string("A")], "b": ["title": .string("B")]])
    }

    func testRecordsWaitingForTheirParentAreReplayedWhenItArrivesAndNotOnTheTick() async throws {
        let phoneStore = TestStore(types: ["podcast.show", "podcast.settings"])
        let phone = try await engine("phone", hub: true, store: phoneStore)
        await phone.seed(types: ["podcast.show", "podcast.settings"])
        phoneStore.set("podcast.settings", "show1", ["speed": .double(1.5)])
        await phone.syncNow(reason: "test")

        let macStore = TestStore(types: ["podcast.show", "podcast.settings"])
        macStore.needsParent = ["podcast.settings": "podcast.show"]
        let mac = try await engine("mac", hub: false, store: macStore)
        await mac.setHubPresence(.seeded(["podcast.show", "podcast.settings"]))
        await mac.seed(types: ["podcast.show", "podcast.settings"])
        XCTAssertNil(macStore.items["podcast.settings"]?["show1"], "held back: its show isn't here")
        let calls = macStore.applyCalls["podcast.settings"] ?? 0
        await mac.syncNow(reason: "tick")
        XCTAssertEqual(macStore.applyCalls["podcast.settings"] ?? 0, calls, "not offered again on a plain pass")

        phoneStore.set("podcast.show", "show1", ["title": .string("The Show")])
        await phone.syncNow(reason: "test")
        await mac.syncNow(reason: "push")
        XCTAssertEqual(macStore.items["podcast.settings"]?["show1"], ["speed": .double(1.5)], "replayed once the show came")
    }

    func testASpokeSeedsItsOwnPhoneSetKindWhenThePhonesSetIsEmpty() async throws {
        let routine = "plan.routine"
        let macStore = TestStore(types: [routine])
        macStore.items[routine] = ["m1": ["title": .string("Mine")]]
        let mac = try await engine("mac", hub: false, store: macStore)
        await mac.setHubPresence(.seeded([routine]))     // the iPhone seeded it, with nothing in it
        await mac.seed(types: [routine])
        XCTAssertEqual(server.visible(type: routine)["m1"], ["title": .string("Mine")])
        XCTAssertEqual(macStore.items[routine]?["m1"], ["title": .string("Mine")], "nothing dropped")
    }

    func testANonFiniteNumberGoesAsNullAndIsLogged() async throws {
        let store = TestStore(types: [extra])
        let phone = try await engine("phone", hub: true, store: store)
        await phone.seed(types: [extra])
        store.set(extra, "a", ["title": .string("A"), "pace": .double(.nan)])
        await phone.syncNow(reason: "test")
        XCTAssertEqual(server.record(extra, "a")?.fields["pace"], .null)
        XCTAssertTrue(logs.all.contains { $0.contains("plan.extra a: not a finite number") })
    }

    // MARK: - Convergence

    func testTwoDevicesConvergeThroughOneServiceWithRandomEdits() async throws {
        for seed in [19_10_2026, 1, 2, 3, 42] as [UInt64] {
            setUpServer()
            try await convergeWithRandomEdits(seed: seed)
        }
    }

    private func setUpServer() {
        server = MemorySyncServer(catalog: catalog)
        server.hubDevices = ["phone"]
    }

    private func convergeWithRandomEdits(seed: UInt64) async throws {
        var rng = SeededGenerator(seed: seed)
        let phoneStore = TestStore(types: [extra]), macStore = TestStore(types: [extra])
        let phone = try await engine("phone", hub: true, store: phoneStore)
        let mac = try await engine("mac", hub: false, store: macStore)
        await phone.seed(types: [extra])
        await mac.setHubPresence(.seeded([extra]))
        await mac.seed(types: [extra])
        let ids = ["a", "b", "c", "d", "e"]
        let titles = ["Oats", "Eggs", "Rice", "Soup"]
        for _ in 0..<300 {
            let store = Bool.random(using: &rng) ? phoneStore : macStore
            let id = ids.randomElement(using: &rng)!
            switch Int.random(in: 0..<10, using: &rng) {
            case 0...4:
                var fields = store.items[extra]?[id] ?? [:]
                fields["title"] = .string(titles.randomElement(using: &rng)!)
                if Bool.random(using: &rng) { fields["kcal"] = .int(Int64.random(in: 100...900, using: &rng)) }
                if Int.random(in: 0..<4, using: &rng) == 0 { fields["kcal"] = nil }   // cleared
                store.set(extra, id, fields)
            case 5:
                if store.items[extra]?[id] != nil { store.delete(extra, id) }
            case 6:
                server.offline = Bool.random(using: &rng) ? ["phone"] : (Bool.random(using: &rng) ? ["mac"] : [])
            case 7, 8:
                await phone.syncNow(reason: "random")
            default:
                await mac.syncNow(reason: "random")
            }
        }
        server.offline = []
        for _ in 0..<3 {
            await phone.syncNow(reason: "settle")
            await mac.syncNow(reason: "settle")
        }
        let expected = server.visible(type: extra)
        XCTAssertFalse(expected.isEmpty, "seed \(seed)")
        for device in ["phone", "mac"] {
            XCTAssertTrue(server.requests.contains { $0.device == device && !$0.changes.isEmpty }, "\(device) sent edits (seed \(seed))")
        }
        XCTAssertEqual(phoneStore.items[extra] ?? [:], expected, "seed \(seed)")
        XCTAssertEqual(macStore.items[extra] ?? [:], expected, "seed \(seed)")
        let pending = await (phone.status().pendingRecords, mac.status().pendingRecords)
        XCTAssertEqual(pending.0, 0, "seed \(seed)")
        XCTAssertEqual(pending.1, 0, "seed \(seed)")
    }
}

/// A repeatable random sequence (SplitMix64).
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
