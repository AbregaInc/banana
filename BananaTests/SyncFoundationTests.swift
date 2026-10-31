import XCTest

/// The data platform's pieces under the engine (docs/design/DATA-PLATFORM.md §3, §5): the
/// canonical encoding, the clock, the diff, the merge (on the fixture file the service's tests run
/// too), the catalog and the mirror's acknowledgement rule.
final class SyncFoundationTests: XCTestCase {

    // MARK: - Canonical encoding

    private struct Item: Codable {
        var title: String
        var tags: Set<String>
        var slots: [String: Int]
        var note: String?
        var when: Date
        var kcal: Double
    }

    func testCanonicalEncodingSortsKeysAndSetsAndWritesDatesAsMilliseconds() throws {
        let item = Item(title: "Oats", tags: ["zinc", "a", "Milk"], slots: ["b": 2, "a": 1, "c": 3], note: nil,
                        when: Date(timeIntervalSince1970: 1_760_000_000.123_4), kcal: 320)
        let text = CanonicalJSON.string(try CanonicalJSON.value(of: item))
        XCTAssertEqual(text, #"{"kcal":320,"slots":{"a":1,"b":2,"c":3},"tags":["Milk","a","zinc"],"title":"Oats","when":1760000000123}"#,
                       "sorted keys at every level, a set as a sorted array, nil left out, the date in whole ms, 320.0 as 320")
    }

    func testASetEncodesTheSameWhateverOrderItWasBuiltIn() throws {
        var a = Set<String>(), b = Set<String>()
        let words = (0..<200).map { "w\($0)" }
        words.forEach { a.insert($0) }
        words.reversed().forEach { b.insert($0) }
        XCTAssertEqual(CanonicalJSON.string(try CanonicalJSON.value(of: a)), CanonicalJSON.string(try CanonicalJSON.value(of: b)))
    }

    func testDoublesAreWrittenAsJavaScriptWritesThem() {
        // Each expected text is what `JSON.stringify` printed for the same number (node 22).
        let cases: [(Double, String)] = [
            (0.1, "0.1"), (1e21, "1e+21"), (1e-7, "1e-7"), (1.5e20, "150000000000000000000"), (100.0, "100"),
            (-0.0, "0"), (123.456, "123.456"), (5e-324, "5e-324"), (pow(2, 60), "1152921504606847000"),
            (0.000001, "0.000001"), (1.7976931348623157e308, "1.7976931348623157e+308"), (-2.5e-8, "-2.5e-8"),
            (0.1 + 0.2, "0.30000000000000004"), (12345678901234567890, "12345678901234567000"), (4.35, "4.35"),
            (1e16, "10000000000000000"), (pow(2, 53), "9007199254740992"), (-1e-6, "-0.000001"),
            (9.999999999999999e20, "999999999999999900000"),
        ]
        for (value, expected) in cases {
            XCTAssertEqual(CanonicalJSON.string(.double(value)), expected, "\(value)")
        }
        XCTAssertEqual(CanonicalJSON.string(.int(Int64(1) << 60)), "1152921504606847000",
                       "an integer beyond 2^53 is written as the double the service holds")
        XCTAssertEqual(CanonicalJSON.string(.int(Int64(1) << 53)), "9007199254740992")
        XCTAssertEqual(CanonicalJSON.string(.int((Int64(1) << 53) + 1)), "9007199254740992",
                       "2^53 + 1 is past what JavaScript holds: compared as an integer, written as JS writes it")
    }

    func testStringsAreEscapedAsJavaScriptDoes() throws {
        // node: JSON.stringify of the same object with sorted keys.
        let value = try CanonicalJSON.parse(Data(#"{"b":{"z":1,"a":[true,null,"x\"\\\n\u0001é /"]},"a":2.5,"B":0}"#.utf8))
        XCTAssertEqual(CanonicalJSON.string(value), "{\"B\":0,\"a\":2.5,\"b\":{\"a\":[true,null,\"x\\\"\\\\\\n\\u0001é\u{2028}/\"],\"z\":1}}")
    }

    func testTiesCompareCanonicalTextWithNullLowest() {
        XCTAssertGreaterThan(CanonicalJSON.compare(.array([.string("b"), .string("a")]), .array([.string("a"), .string("b")])), 0)
        XCTAssertLessThan(CanonicalJSON.compare(.null, .string("")), 0, "null loses to any value")
        XCTAssertEqual(CanonicalJSON.compare(.int(1), .double(1)), 0, "1 and 1.0 are one number")
    }

    private struct Reading: Codable { var value: Double; var name: String }

    func testANumberThatIsntFiniteIsWrittenAsNullAndReported() throws {
        let (fields, nonFinite) = try CanonicalJSON.fieldsReporting(of: Reading(value: .nan, name: "pace"))
        XCTAssertEqual(fields["value"], .null)
        XCTAssertEqual(fields["name"], .string("pace"))
        XCTAssertEqual(nonFinite, ["value"])
        XCTAssertEqual(CanonicalJSON.string(.double(.infinity)), "null")
    }

    // MARK: - The protocol, on the service's fixtures

    private struct ProtocolFixtures: Decodable {
        struct Step: Decodable {
            struct Sync: Decodable {
                struct Change: Decodable {
                    var type: String, id: String, set: [String: JSONValue], clocks: [String: String], delete: String?
                }
                var device: String, platform: String, since: Int64, changes: [Change], now: Int64, pageRecords: Int?
            }
            var sync: Sync?
            var answer: SyncAnswer?
            var consent: String?
            var blob: String?
        }
        struct Case: Decodable { var name: String; var steps: [Step] }
        var cases: [Case]
    }

    func testTheInMemoryServiceGivesTheServicesAnswers() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "SyncProtocolFixtures", withExtension: "json"))
        let fixtures = try JSONDecoder().decode(ProtocolFixtures.self, from: Data(contentsOf: url))
        let catalogURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "DataCatalog", withExtension: "json"))
        let catalog = try DataCatalog.decode(Data(contentsOf: catalogURL))
        var answers = 0
        for kase in fixtures.cases {
            let server = MemorySyncServer(catalog: catalog)
            server.consent = false
            for step in kase.steps {
                if step.consent != nil { server.consent = true }
                if let sha = step.blob { try server.put(sha, Data(), device: "fixture") }
                guard let sync = step.sync, var expected = step.answer else { continue }
                server.now = { sync.now }
                let request = SyncRequest(device: sync.device, since: sync.since, changes: sync.changes.map {
                    SyncRequest.Change(type: $0.type, id: $0.id, set: $0.set, clocks: $0.clocks, delete: $0.delete)
                })
                var answer = try server.handle(request, platform: sync.platform, pageRecords: sync.pageRecords)
                answer.epoch = nil
                expected.epoch = nil
                XCTAssertEqual(answer, expected, kase.name)
                answers += 1
            }
        }
        XCTAssertGreaterThanOrEqual(answers, 15)
    }

    // MARK: - The clock

    func testClocksWriteAndReadAndOrderAsText() throws {
        let clock = HLC(ms: 1_760_000_000_000, counter: 10, device: "phone")
        XCTAssertEqual(clock.text, "1760000000000.000a.phone")
        XCTAssertEqual(HLC(clock.text), clock)
        XCTAssertEqual(HLC.fixed(1, device: "mac").text, "0000000000001.0000.mac")
        XCTAssertLessThan(HLC(ms: 999, device: "z"), HLC(ms: 1000, device: "a"), "milliseconds first, padded")
        XCTAssertLessThan(HLC(ms: 1000, counter: 9, device: "z"), HLC(ms: 1000, counter: 10, device: "a"), "then the hex counter")
        XCTAssertNil(HLC("1760000000000.0000"))
    }

    func testIssuedClocksOnlyGoUpEvenWhenTimeStandsStillOrGoesBack() {
        var clock = HLCClock(device: "phone")
        let t = Date(timeIntervalSince1970: 1_760_000_000)
        let a = clock.issue(now: t), b = clock.issue(now: t), c = clock.issue(now: t.addingTimeInterval(-60))
        XCTAssertLessThan(a, b)
        XCTAssertLessThan(b, c)
        XCTAssertEqual(b.counter, 1)
        XCTAssertEqual(c.ms, a.ms, "a clock set back doesn't take time back")
        let d = clock.issue(now: t.addingTimeInterval(1))
        XCTAssertEqual(d.counter, 0, "the counter starts again when time moves")
    }

    func testAnObservedClockIsPassedByTheNextOneIssued() {
        var clock = HLCClock(device: "mac")
        let t = Date(timeIntervalSince1970: 1_760_000_000)
        clock.observe("1760000100000.0005.phone")   // a phone 100 s ahead
        let next = clock.issue(now: t)
        XCTAssertEqual(next.ms, 1_760_000_100_000)
        XCTAssertEqual(next.counter, 6)
        XCTAssertGreaterThan(next.text, "1760000100000.0005.phone")
        clock.observe("1700000000000.0000.old")
        XCTAssertEqual(clock.state.maxSeen, "1760000100000.0005.phone", "maxSeen never goes down")
    }

    func testTheOffsetIsLearnedWhenTheServiceIsMoreThanThirtySecondsOff() {
        var clock = HLCClock(device: "mac")
        let sent = Date(timeIntervalSince1970: 1_760_000_000), received = sent.addingTimeInterval(0.2)
        clock.learn(serverNow: 1_760_000_000_100 + 10_000, sent: sent, received: received)
        XCTAssertEqual(clock.state.offset, 0, "10 s off: left alone")
        clock.learn(serverNow: 1_760_000_000_100 - 120_000, sent: sent, received: received)
        XCTAssertEqual(clock.state.offset, -120_000, "two minutes fast: the service's time, less half the round trip")
        let issued = clock.issue(now: received)
        XCTAssertEqual(issued.ms, HLCClock.ms(received) - 120_000)
        clock.learn(serverNow: 1_760_000_000_100 - 100_000, sent: sent, received: received)
        XCTAssertEqual(clock.state.offset, -120_000, "within 30 s of what it learned: kept")
    }

    // MARK: - Diff

    private struct Meal: Codable {
        var title: String
        var note: String?
        var tags: Set<String>
    }

    func testAClearedOptionalIsSentAsNull() throws {
        let before = try CanonicalJSON.fields(of: Meal(title: "Oats", note: "salty", tags: ["a"]))
        let after = try CanonicalJSON.fields(of: Meal(title: "Oats", note: nil, tags: ["a"]))
        let diff = FieldDiff.changes(from: before, to: after)
        XCTAssertEqual(diff.fields, ["note": .null])
        XCTAssertEqual(diff.cleared, ["note"])
    }

    func testKeysThisAppNeverWroteAreNeverTouched() throws {
        // The mirror holds "photoV2" from a newer app; this app's encodings never had it.
        let before = try CanonicalJSON.fields(of: Meal(title: "Oats", note: nil, tags: []))
        let after = try CanonicalJSON.fields(of: Meal(title: "Porridge", note: nil, tags: []))
        let diff = FieldDiff.changes(from: before, to: after)
        XCTAssertEqual(Set(diff.fields.keys), ["title"])
        var merged = RecordState(fields: ["title": .string("Oats"), "photoV2": .string("x")],
                                 clocks: ["title": "1760000000000.0000.mac", "photoV2": "1760000000000.0000.mac"])
        merged = RecordMerge.apply(RecordChange(set: diff.fields, clocks: ["title": "1760000001000.0000.phone"]),
                                   to: merged, kind: .field).state
        XCTAssertEqual(merged.fields["photoV2"], .string("x"))
    }

    func testReencodingTheSameSetIsNoChange() throws {
        let words = (0..<100).map { "tag\($0)" }
        let a = try CanonicalJSON.fields(of: Meal(title: "Oats", note: nil, tags: Set(words)))
        let b = try CanonicalJSON.fields(of: Meal(title: "Oats", note: nil, tags: Set(words.reversed())))
        XCTAssertTrue(FieldDiff.changes(from: a, to: b).isEmpty)
        XCTAssertEqual(FieldDiff.changes(from: nil, to: b).fields.count, 2, "a first encoding sends every field (note is absent)")
    }

    // MARK: - The merge, on the service's fixtures

    private struct Fixtures: Decodable {
        struct Change: Decodable {
            var set: [String: JSONValue]
            var clocks: [String: String]
            var delete: String?
        }
        struct State: Decodable {
            var fields: [String: JSONValue]
            var clocks: [String: String]
            var deleted: String?
            var visible: Bool?
        }
        struct Case: Decodable {
            var name: String
            var merge: RecordMerge.Kind
            var start: State?
            var changes: [Change]
            var expect: State
        }
        var cases: [Case]
    }

    private func permutations<T>(_ items: [T]) -> [[T]] {
        guard items.count > 1 else { return [items] }
        return items.indices.flatMap { i -> [[T]] in
            var rest = items
            let first = rest.remove(at: i)
            return permutations(rest).map { [first] + $0 }
        }
    }

    func testTheMergeMatchesEveryFixtureInEveryOrder() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "SyncMergeFixtures", withExtension: "json"))
        let fixtures = try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url))
        XCTAssertGreaterThanOrEqual(fixtures.cases.count, 11)
        var runs = 0
        for fixture in fixtures.cases {
            for order in permutations(fixture.changes) {
                var state = fixture.start.map { RecordState(fields: $0.fields, clocks: $0.clocks, deleted: $0.deleted) }
                for change in order {
                    state = RecordMerge.apply(RecordChange(set: change.set, clocks: change.clocks, delete: change.delete),
                                              to: state, kind: fixture.merge).state
                }
                let result = try XCTUnwrap(state, fixture.name)
                XCTAssertEqual(result.fields, fixture.expect.fields, fixture.name)
                XCTAssertEqual(result.clocks, fixture.expect.clocks, fixture.name)
                XCTAssertEqual(result.deleted, fixture.expect.deleted, fixture.name)
                XCTAssertEqual(result.isVisible, fixture.expect.visible ?? true, fixture.name)
                runs += 1
            }
        }
        XCTAssertGreaterThan(runs, fixtures.cases.count, "the orders were tried, not only the file's")
    }

    func testARepeatedChangeIsNoChange() {
        let change = RecordChange(set: ["title": .string("Oats")], clocks: ["title": "1760000000000.0000.mac"])
        let once = RecordMerge.apply(change, to: nil, kind: .field)
        XCTAssertTrue(once.changed)
        XCTAssertFalse(RecordMerge.apply(change, to: once.state, kind: .field).changed, "a retry changes nothing")
    }

    func testAppendIgnoresASecondWrite() {
        let first = RecordMerge.apply(RecordChange(set: ["v": .int(1)], clocks: ["v": "1760000000000.0000.mac"]), to: nil, kind: .append).state
        let second = RecordMerge.apply(RecordChange(set: ["v": .int(2)], clocks: ["v": "1760000009000.0000.mac"]), to: first, kind: .append)
        XCTAssertFalse(second.changed)
        XCTAssertEqual(second.state.fields["v"], .int(1))
    }

    // MARK: - The catalog

    func testTheBundledCatalogLoadsAndNamesEachTypeOnce() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "DataCatalog", withExtension: "json"))
        let catalog = try DataCatalog.decode(Data(contentsOf: url))
        XCTAssertEqual(Set(catalog.types.map(\.type)).count, catalog.types.count)
        XCTAssertEqual(catalog["food.meal"]?.tier, .t2)
        XCTAssertEqual(catalog["podcast.listen"]?.blobFields["route"], .eager)
        XCTAssertEqual(catalog["health.workout"]?.blobFields["samples"], .lazy)
        XCTAssertEqual(catalog["plan.routine"]?.seed, .phoneSet)
        XCTAssertEqual(catalog["core.hubStatus"]?.writers, .hub)
        for entry in catalog.types {
            let module = entry.type.split(separator: ".").first.map(String.init) ?? ""
            // The wake plan too: it's worked out from sleep and recovery.
            XCTAssertEqual(entry.isHealth, ["health", "food"].contains(module) || entry.type == "core.wakePlan",
                           "\(entry.type): health and food need the consent, and the wake plan; nothing else")
        }
    }

    // MARK: - The transport

    func testTheTransportOnlySpeaksForTheAccountItWasMadeFor() async {
        let other = HTTPSyncTransport(host: "service.invalid", account: "acc-1", credentials: { ("session", "acc-2") })
        do {
            _ = try await other.sync(SyncRequest(device: "d", since: 0, changes: []))
            XCTFail("another account's session must not reach this mirror's space")
        } catch {
            XCTAssertEqual(error as? SyncTransportError, .noSession)
        }
        let signedOut = HTTPSyncTransport(host: "service.invalid", account: "acc-1", credentials: { (nil, "acc-1") })
        do {
            _ = try await signedOut.hasBlob(sha256: String(repeating: "a", count: 64))
            XCTFail("no session, no call")
        } catch {
            XCTAssertEqual(error as? SyncTransportError, .noSession)
        }
    }

    func testBlobsAndSyncStateGoWhereTheServiceExpectsThem() throws {
        let put = BananaService.request(.blob(method: "PUT", sha256: "ab"), host: "service.example", session: "s")
        XCTAssertEqual(put.httpMethod, "PUT")
        XCTAssertEqual(put.url?.path, "/v2/blobs/ab")
        let state = BananaService.request(.syncState(device: "d1", seededAt: Date(timeIntervalSince1970: 1_760_000_000),
                                                     flippedAt: nil, seeded: ["b", "a", "a"]), host: "service.example", session: "s")
        XCTAssertEqual(state.url?.path, "/v2/devices/d1/sync-state")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(state.httpBody)) as? [String: Any])
        XCTAssertEqual(body["seededAt"] as? Int64, 1_760_000_000_000)
        XCTAssertNil(body["flippedAt"], "left as the service has it")
        XCTAssertEqual(body["seeded"] as? [String], ["a", "b"])
        XCTAssertTrue(BananaService.isSyncPush(["aps": ["content-available": 1], "b": ["k": "sync"]]))
    }

    func testAHostIsHttpsUnlessADebugBuildNamesALocalServiceWithItsScheme() {
        let real = BananaService.request(.account, host: "api.bananatheapp.com", session: "s")
        XCTAssertEqual(real.url?.absoluteString, "https://api.bananatheapp.com/v1/account")
        // tools/e2e-sync.sh: the service on Node, this Mac's loopback, plain HTTP (DEBUG only).
        let local = BananaService.request(.sync(Data("{}".utf8)), host: "http://127.0.0.1:8787", session: "s")
        XCTAssertEqual(local.url?.absoluteString, "http://127.0.0.1:8787/v2/sync")
        XCTAssertEqual(local.value(forHTTPHeaderField: "Authorization"), "Bearer s")
    }

    // MARK: - The mirror's acknowledgement rule

    func testAFieldIsDoneOnlyWhenTheAnswerHoldsItsClockOrALaterOne() throws {
        let mirror = try RecordMirror()
        let key = RecordKey(type: "plan.extra", id: "x")
        try mirror.write { try $0.enqueue(key, fields: ["title": .string("A")], clock: "1760000000000.0000.mac") }
        // An edit made while that request was out:
        try mirror.write { try $0.enqueue(key, fields: ["title": .string("B")], clock: "1760000000000.0001.mac") }
        try mirror.write { try $0.enqueue(key, fields: ["title": .string("old")], clock: "1750000000000.0000.mac") }
        XCTAssertEqual(try mirror.read { try $0.pending(key) }?.fields["title"]?.value, .string("B"), "the later clock stays queued")
        try mirror.write { try $0.acknowledge(key, clocks: ["title": "1760000000000.0000.mac"], deleted: nil) }
        XCTAssertEqual(try mirror.read { try $0.pending(key) }?.fields["title"]?.clock.clock, "1760000000000.0001.mac",
                       "the answer for the first send doesn't clear the edit made since")
        try mirror.write { try $0.acknowledge(key, clocks: ["title": "1760000000000.0001.mac"], deleted: nil) }
        XCTAssertNil(try mirror.read { try $0.pending(key) })
    }

    func testTheMirrorFileLivesUnderSyncAndIsLeftOutOfBackups() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = RecordMirror.url(account: "acc/1", in: folder)
        XCTAssertEqual(url.lastPathComponent, "acc_1.sqlite")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "sync")
        _ = try RecordMirror(url: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let excluded = try url.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        XCTAssertEqual(excluded, true)
    }
}
