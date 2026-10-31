import CryptoKit
import XCTest

/// `SpaceSync` end to end: real engines, the real `HTTPSyncTransport`, and the real service on
/// Node over plain HTTP on this Mac (docs/design/DATA-PLATFORM.md §4, §7, §12). Stores are the
/// engine tests' fakes (`TestStore`). Run by `tools/e2e-sync.sh`, which starts a fresh service,
/// seeds one account with an iPhone, an iPad and a Mac (`Service/tools/e2e-seed.mjs`) and passes
/// the seed's path as `TEST_RUNNER_BANANA_E2E`; without it every test here is skipped.
///
/// The space is shared by every test of a run, so each test makes its own record ids and looks
/// only at those.
@MainActor
final class SpaceSyncHTTPTests: XCTestCase {
    struct Seed: Decodable {
        var host: String
        var account: String
        var sessions: [String: String]
        var devices: [String: String]
    }

    private var seed: Seed!
    private var catalog: DataCatalog!
    private var logs: SpaceSyncTests.LogBox!
    private var engines: [SpaceSync] = []
    private let extra = "plan.extra"
    /// This test's own ids.
    private var run = ""

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["BANANA_E2E"], !path.isEmpty else {
            throw XCTSkip("no local service: run tools/e2e-sync.sh")
        }
        seed = try JSONDecoder().decode(Seed.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "DataCatalog", withExtension: "json"))
        catalog = try DataCatalog.decode(Data(contentsOf: url))
        logs = SpaceSyncTests.LogBox()
        run = String(UUID().uuidString.prefix(8))
    }

    override func tearDown() async throws {
        for engine in engines { await engine.stop() }
        engines = []
        if testRun?.hasSucceeded == false, let logs {
            print("engine log:\n" + logs.all.suffix(60).joined(separator: "\n"))
        }
    }

    // MARK: - Engines on the real transport

    /// One device's engine: `who` is phone (the hub), mac or ipad.
    private func engine(_ who: String, store: TestStore, skew: TimeInterval = 0, wire: Wire? = nil) async throws -> SpaceSync {
        let device = try XCTUnwrap(seed.devices[who])
        var config = SpaceSync.Configuration(device: device, isHub: who == "phone", catalog: catalog)
        if skew != 0 { config.now = { Date().addingTimeInterval(skew) } }
        config.debounce = .seconds(3_600)   // the tests run passes themselves
        config.blobRetryBase = 0.05
        let logs = self.logs!
        config.log = { logs.add("\(who): \($0)") }
        let session = seed.sessions[who], account = seed.account
        let http = HTTPSyncTransport(host: seed.host, account: account, credentials: { (session, account) })
        let engine = try SpaceSync(mirror: RecordMirror(), transport: WireTransport(inner: http, wire: wire ?? Wire()), config: config)
        await engine.registerAdapter(store)
        store.engine = engine
        engines.append(engine)
        return engine
    }

    /// A spoke that may seed these types (the phone has).
    private func spoke(_ who: String, store: TestStore, wire: Wire? = nil) async throws -> SpaceSync {
        let engine = try await engine(who, store: store, wire: wire)
        await engine.setHubPresence(.seeded(Set(store.types)))
        await engine.seed(types: store.types)
        return engine
    }

    /// An app call to the service (`BananaService`), as `BananaAccount` sends it.
    private func call(_ call: BananaService.Call, as who: String) async throws -> (Data, Int) {
        let request = BananaService.request(call, host: seed.host, session: seed.sessions[who])
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// A file for a blob field, named by its real SHA-256 (the service checks it).
    private func attach(_ store: TestStore, _ type: String, _ id: String, field: String, data: Data) throws -> BlobReference {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-blob-\(UUID().uuidString)")
        try data.write(to: url)
        store.files["\(type)/\(id)/\(field)"] = url
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return BlobReference(sha256: sha, size: Int64(data.count), ext: "bin")
    }

    // MARK: - (a) a record, (b) per-field merge, (c) a delete

    func testARecordMadeOnThePhoneAppearsOnTheMac() async throws {
        let id = "a-\(run)"
        let phoneStore = TestStore(types: [extra])
        let phone = try await engine("phone", store: phoneStore)
        await phone.seed(types: [extra])
        phoneStore.set(extra, id, ["title": .string("Oats"), "minutes": .int(20)])
        await phone.syncNow(reason: "test")
        let left = await phone.status().pendingRecords
        XCTAssertEqual(left, 0, "acknowledged")

        let macStore = TestStore(types: [extra])
        _ = try await spoke("mac", store: macStore)
        XCTAssertEqual(macStore.items[extra]?[id], ["title": .string("Oats"), "minutes": .int(20)])
    }

    func testEditsToDifferentFieldsOnTwoDevicesMergeFieldByField() async throws {
        let id = "b-\(run)"
        let phoneStore = TestStore(types: [extra]), macStore = TestStore(types: [extra])
        let phone = try await engine("phone", store: phoneStore)
        await phone.seed(types: [extra])
        phoneStore.set(extra, id, ["title": .string("Run"), "note": .string("easy")])
        await phone.syncNow(reason: "test")
        let mac = try await spoke("mac", store: macStore)
        XCTAssertEqual(macStore.items[extra]?[id]?["title"], .string("Run"))

        // Both edit before either hears of the other's edit.
        phoneStore.set(extra, id, ["title": .string("Long run"), "note": .string("easy")])
        macStore.set(extra, id, ["title": .string("Run"), "note": .string("hilly")])
        await phone.syncNow(reason: "test")
        await mac.syncNow(reason: "test")
        await phone.syncNow(reason: "test")
        let merged: [String: JSONValue] = ["title": .string("Long run"), "note": .string("hilly")]
        XCTAssertEqual(phoneStore.items[extra]?[id], merged)
        XCTAssertEqual(macStore.items[extra]?[id], merged)
    }

    func testADeleteOnTheMacReachesThePhoneAndANewDevice() async throws {
        let id = "c-\(run)"
        let phoneStore = TestStore(types: [extra]), macStore = TestStore(types: [extra])
        let phone = try await engine("phone", store: phoneStore)
        await phone.seed(types: [extra])
        phoneStore.set(extra, id, ["title": .string("Gone soon")])
        await phone.syncNow(reason: "test")
        let mac = try await spoke("mac", store: macStore)
        XCTAssertNotNil(macStore.items[extra]?[id])

        macStore.delete(extra, id)
        await mac.syncNow(reason: "test")
        await phone.syncNow(reason: "test")
        XCTAssertNil(phoneStore.items[extra]?[id], "the phone removed it")
        let padStore = TestStore(types: [extra])
        _ = try await spoke("ipad", store: padStore)
        XCTAssertNil(padStore.items[extra]?[id], "a device that never had it doesn't get it")
    }

    // MARK: - (d) blobs

    func testBlobsGoUpAndComeDownEagerAndLazy() async throws {
        let listen = "podcast.listen", transcript = "podcast.transcript"
        let lid = "l-\(run)", tid = "t-\(run)"
        let phoneStore = TestStore(types: [listen, transcript])
        let phone = try await engine("phone", store: phoneStore)
        await phone.seed(types: [listen, transcript])
        var bytes = [UInt8](repeating: 0, count: 3_000_000)
        XCTAssertEqual(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes), errSecSuccess)
        let routeData = Data(bytes)
        let bodyData = Data(String(repeating: "words \(run) ", count: 40_000).utf8)
        let route = try attach(phoneStore, listen, lid, field: "route", data: routeData)
        let body = try attach(phoneStore, transcript, tid, field: "body", data: bodyData)
        phoneStore.set(listen, lid, ["title": .string("A walk"), "route": route.value])
        phoneStore.set(transcript, tid, ["title": .string("Words"), "body": body.value])
        await phone.syncNow(reason: "test")
        let left = await phone.status().pendingRecords
        XCTAssertEqual(left, 0, "both blobs went up, then their records")
        XCTAssertFalse(logs.all.contains { $0.contains("blob_missing") })

        // Straight off the service: the blob is there, by its hash.
        let head = try await call(.blob(method: "HEAD", sha256: route.sha256), as: "mac")
        XCTAssertEqual(head.1, 200)

        let macStore = TestStore(types: [listen, transcript])
        let mac = try await spoke("mac", store: macStore)
        await mac.blobsSettled()
        XCTAssertEqual(macStore.items[listen]?[lid]?["route"], route.value)
        XCTAssertEqual(macStore.storedBlobs["\(listen)/\(lid)/route"], routeData, "eager: down with its record")
        XCTAssertNil(macStore.storedBlobs["\(transcript)/\(tid)/body"], "lazy: not yet")
        let fetched = await mac.ensureBlob(type: transcript, id: tid, field: "body")
        XCTAssertTrue(fetched)
        XCTAssertEqual(macStore.storedBlobs["\(transcript)/\(tid)/body"], bodyData, "lazy: on first use")
    }

    // MARK: - (e) the Health consent

    func testHealthWaitsForTheConsentThenSyncsAndAWithdrawalDropsIt() async throws {
        let meal = "food.meal", id = "m-\(run)"
        var answer = try await call(.healthConsent(granted: false, version: "1", device: seed.devices["phone"]!), as: "phone")
        XCTAssertEqual(answer.1, 204, "starts withdrawn")

        let phoneStore = TestStore(types: [meal])
        let phone = try await engine("phone", store: phoneStore)
        await phone.setHealthConsent(true)
        phoneStore.items[meal] = [id: ["title": .string("Porridge")]]
        await phone.seed(types: [meal])
        var status = await phone.status()
        XCTAssertFalse(status.healthConsent, "the service has no consent: T2 stops")
        XCTAssertTrue(status.waitingToSeed.contains(meal))
        XCTAssertEqual(try phone.mirror.read { try $0.count(type: meal) }, 0)

        answer = try await call(.healthConsent(granted: true, version: "1", device: seed.devices["phone"]!), as: "phone")
        XCTAssertEqual(answer.1, 204)
        await phone.syncNow(reason: "test")
        status = await phone.status()
        XCTAssertTrue(status.healthConsent, "the answer carries the consent")
        XCTAssertEqual(status.pendingRecords, 0)

        let macStore = TestStore(types: [meal])
        let mac = try await spoke("mac", store: macStore)
        XCTAssertEqual(macStore.items[meal]?[id], ["title": .string("Porridge")], "the meal reached the Mac")
        let macConsent = await mac.status().healthConsent
        XCTAssertTrue(macConsent)

        answer = try await call(.healthConsent(granted: false, version: "1", device: seed.devices["phone"]!), as: "phone")
        XCTAssertEqual(answer.1, 204)
        await phone.setHealthConsent(false)
        await phone.consentWithdrawalConfirmed()
        await mac.syncNow(reason: "test")
        let after = await mac.status()
        XCTAssertFalse(after.healthConsent, "the Mac heard of the withdrawal")
        XCTAssertEqual(try mac.mirror.read { try $0.count(type: meal) }, 0, "T2 left the Mac's mirror")
        XCTAssertEqual(macStore.items[meal]?[id], ["title": .string("Porridge")], "its store keeps its own copy")

        let padStore = TestStore(types: [meal])
        _ = try await spoke("ipad", store: padStore)
        XCTAssertNil(padStore.items[meal]?[id], "the service has no T2 left")
    }

    // MARK: - (f) paging over HTTP

    func testThousandsOfRecordsArriveCompletePagedByCountAndBytes() async throws {
        // 1,000 tiny records fill a page by count; 1,500 of about 5 KB pass 4 MB first.
        let phoneStore = TestStore(types: [extra])
        let phone = try await engine("phone", store: phoneStore)
        let filler = String(repeating: "x", count: 5_000)
        var expected: [String: [String: JSONValue]] = [:]
        for n in 0..<2_500 {
            var fields: [String: JSONValue] = ["title": .string("R\(n)")]
            if n >= 1_000 { fields["note"] = .string(filler) }
            expected["f-\(run)-\(n)"] = fields
        }
        phoneStore.items[extra] = expected
        await phone.seed(types: [extra])
        let left = await phone.status().pendingRecords
        XCTAssertEqual(left, 0, "every record went up")
        let seeded = await phone.isSeeded
        XCTAssertTrue(seeded)

        let wire = Wire()
        let macStore = TestStore(types: [extra])
        let mac = try await spoke("mac", store: macStore, wire: wire)
        let mine = (macStore.items[extra] ?? [:]).filter { $0.key.hasPrefix("f-\(run)-") }
        XCTAssertEqual(mine.count, 2_500)
        XCTAssertEqual(mine, expected)
        let pages = wire.answers
        XCTAssertTrue(pages.contains { $0.records == 1_000 && $0.more }, "a page cut by count: \(pages)")
        XCTAssertTrue(pages.contains { $0.records > 0 && $0.records < 1_000 && $0.more }, "a page cut by bytes: \(pages)")
        XCTAssertFalse(try XCTUnwrap(pages.last).more)
        let cursor = await mac.status().cursor
        XCTAssertEqual(cursor, pages.last?.head, "the cursor reached the head")
    }

    // MARK: - (g) a fast clock

    func testAnHourFastDeviceIsRefusedLearnsTheOffsetAndDoesntOverwriteALaterEdit() async throws {
        let id = "g-\(run)"
        let wire = Wire()
        let phoneStore = TestStore(types: [extra])
        let phone = try await engine("phone", store: phoneStore, skew: 3_600, wire: wire)
        wire.offline = true
        await phone.seed(types: [extra])          // no answer yet: nothing has told it its clock is fast
        phoneStore.set(extra, id, ["title": .string("From the fast phone")])
        wire.offline = false
        await phone.syncNow(reason: "test")
        XCTAssertTrue(logs.all.contains { $0.contains("refused: clock") }, "refused first")
        let offset = await phone.status().offset
        XCTAssertEqual(Double(offset), -3_600_000, accuracy: 5_000)
        let left = await phone.status().pendingRecords
        XCTAssertEqual(left, 0, "then taken, stamped again")

        let macStore = TestStore(types: [extra])
        let mac = try await spoke("mac", store: macStore)
        XCTAssertEqual(macStore.items[extra]?[id], ["title": .string("From the fast phone")])
        try await Task.sleep(for: .milliseconds(20))
        macStore.set(extra, id, ["title": .string("Later, on the Mac")])
        await mac.syncNow(reason: "test")
        await phone.syncNow(reason: "test")
        XCTAssertEqual(phoneStore.items[extra]?[id], ["title": .string("Later, on the Mac")],
                       "the fast phone's edit didn't outrank the later one")
        let padStore = TestStore(types: [extra])
        _ = try await spoke("ipad", store: padStore)
        XCTAssertEqual(padStore.items[extra]?[id], ["title": .string("Later, on the Mac")])
    }

    // MARK: - (h) the move's state on /v1/account

    func testTheAccountReportsWhatThePhoneSeededAndWhenEveryDeviceFlipped() async throws {
        let phoneStore = TestStore(types: [extra])
        let phone = try await engine("phone", store: phoneStore)
        phoneStore.items[extra] = ["h-\(run)": ["title": .string("Seeded")]]
        await phone.seed(types: [extra])
        let seeded = await phone.isSeeded
        XCTAssertTrue(seeded)
        try await phone.reportSyncState(seededAt: Date(), flippedAt: nil)
        var account = try await accountAnswer()
        XCTAssertEqual(account.id, seed.account)
        XCTAssertTrue(account.seeded?.contains(extra) == true, "the iPhone's seeded types: \(String(describing: account.seeded))")
        XCTAssertEqual(account.hasIPhone, true)

        try await phone.reportSyncState(seededAt: nil, flippedAt: Date())
        account = try await accountAnswer()
        XCTAssertEqual(account.flipped, false, "the iPad and the Mac still write iCloud")
        XCTAssertTrue(account.seeded?.contains(extra) == true, "a flip leaves the seeded list as it was")

        for who in ["mac", "ipad"] {
            let engine = try await engine(who, store: TestStore(types: [extra]))
            try await engine.reportSyncState(seededAt: Date(), flippedAt: Date())
        }
        account = try await accountAnswer()
        XCTAssertEqual(account.flipped, true, "every device stopped writing iCloud")
        XCTAssertEqual(account.icloud, "keep", "the purge waits for the account's flag")
    }

    private func accountAnswer() async throws -> BananaService.Account {
        let (data, status) = try await call(.account, as: "phone")
        XCTAssertEqual(status, 200)
        return try JSONDecoder().decode(BananaService.Account.self, from: data)
    }
}

/// What the tests see of the wire: the pages that came back, and a switch to go offline.
final class Wire: @unchecked Sendable {
    struct Page: Equatable, CustomStringConvertible {
        var records: Int, more: Bool, next: Int64?, head: Int64?
        var description: String { "\(records)\(more ? "+" : "")" }
    }

    private let lock = NSLock()
    private var _offline = false
    private var _answers: [Page] = []

    var offline: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _offline }
        set { lock.lock(); _offline = newValue; lock.unlock() }
    }
    var answers: [Page] { lock.lock(); defer { lock.unlock() }; return _answers }

    func note(_ answer: SyncAnswer) {
        lock.lock()
        _answers.append(Page(records: answer.changes.count, more: answer.more, next: answer.next, head: answer.head))
        lock.unlock()
    }
}

/// The real transport, with a `Wire` in front of it.
struct WireTransport: SyncTransport {
    let inner: HTTPSyncTransport
    let wire: Wire

    private func reachable() throws { if wire.offline { throw URLError(.notConnectedToInternet) } }

    func sync(_ request: SyncRequest) async throws -> SyncAnswer {
        try reachable()
        let answer = try await inner.sync(request)
        wire.note(answer)
        return answer
    }

    func putBlob(sha256: String, file: URL, type: String) async throws {
        try reachable()
        try await inner.putBlob(sha256: sha256, file: file, type: type)
    }

    func getBlob(sha256: String) async throws -> URL {
        try reachable()
        return try await inner.getBlob(sha256: sha256)
    }

    func hasBlob(sha256: String) async throws -> Bool {
        try reachable()
        return try await inner.hasBlob(sha256: sha256)
    }

    func reportSyncState(device: String, seededAt: Date?, flippedAt: Date?, seeded: [String]?) async throws {
        try reachable()
        try await inner.reportSyncState(device: device, seededAt: seededAt, flippedAt: flippedAt, seeded: seeded)
    }
}
