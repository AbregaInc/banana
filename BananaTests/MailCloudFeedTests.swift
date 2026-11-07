import XCTest
import GRDB

/// Banana Cloud's shared mailbox feed on the device (MAIL-CLOUD-SYNC §4, §8): fakes only.
final class MailCloudFeedTests: XCTestCase {
    typealias Entry = MailCloudFeedPage.Entry
    static let account = "noor@plan.example"

    /// A feed the test writes page by page; it records what was asked.
    actor Feed: MailCloudFeedSource {
        var epoch = "epoch-1"
        var entries: [Entry] = []          // the whole feed, in order; a cursor is an index
        var complete = true
        var unavailable = false
        var expiredOnce = false
        var asked: [String?] = []
        var checks: [[String]] = []
        var onCheck: (@Sendable ([String]) async -> Void)?
        func set(_ entries: [Entry], complete: Bool = true) { self.entries = entries; self.complete = complete }
        func append(_ more: [Entry]) { entries += more }
        func configure(epoch: String? = nil, unavailable: Bool? = nil, expiredOnce: Bool? = nil, complete: Bool? = nil) {
            if let epoch { self.epoch = epoch }
            if let unavailable { self.unavailable = unavailable }
            if let expiredOnce { self.expiredOnce = expiredOnce }
            if let complete { self.complete = complete }
        }
        func page(account: String, after: String?, limit: Int, fresh: Bool) async throws -> MailCloudFeedPage {
            asked.append(after)
            if unavailable { throw MailCloudFeedError.unavailable }
            if expiredOnce, after != nil { expiredOnce = false; throw MailCloudFeedError.expired }
            let start = after.flatMap(Int.init) ?? 0
            let slice = Array(entries[min(start, entries.count)..<min(start + limit, entries.count)])
            return MailCloudFeedPage(epoch: epoch, cursor: String(start + slice.count), more: start + slice.count < entries.count,
                                     complete: complete, entries: slice)
        }
        func check(account: String, ids: [String]) async throws { checks.append(ids) }
    }

    /// A Gmail that records any request: the feed path must make none.
    actor Gmail: GmailAPI {
        var operations: [String] = []
        func profile(token: String) async throws -> GmailProfile { operations.append("profile"); return GmailProfile(emailAddress: MailCloudFeedTests.account, historyId: 10) }
        func labels(token: String) async throws -> [GmailLabel] {
            operations.append("labels")
            return ["INBOX", "SENT", "DRAFT", "TRASH", "SPAM", "UNREAD", "STARRED"].map { GmailLabel(id: $0, name: $0, type: "system") }
        }
        func history(token: String, start: String, pageToken: String?, maxResults: Int) async throws -> GmailHistoryPage {
            operations.append("history"); return GmailHistoryPage(historyId: 10)
        }
        func listMessages(token: String, labelIDs: [String], query: String?, includeSpamTrash: Bool, pageToken: String?, maxResults: Int) async throws -> GmailIDPage {
            operations.append("list"); return GmailIDPage()
        }
        func message(token: String, id: String, format: GmailFormat) async throws -> GmailMessage { operations.append("get"); throw GmailError.notFound }
        func thread(token: String, id: String, format: GmailFormat) async throws -> GmailThread { throw GmailError.malformed }
        func attachment(token: String, messageID: String, attachmentID: String) async throws -> GmailPartBody { throw GmailError.malformed }
        func modify(token: String, id: String, add: [String], remove: [String]) async throws { XCTFail("Sync may not mutate Gmail") }
        func trash(token: String, id: String) async throws { XCTFail("Sync may not mutate Gmail") }
        func untrash(token: String, id: String) async throws { XCTFail("Sync may not mutate Gmail") }
    }

    private func setup(_ feed: Feed, gmail: Gmail = Gmail()) async throws -> (MailStores, GmailMailboxSync) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-feed-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let (stores, intents) = try await Task.detached {
            let directories = try MailDirectories(root: root)
            return (try MailStores.open(directories, migrations: MailSlices.migrations()), try MailIntentStore(directories: directories))
        }.value
        let sync = GmailMailboxSync(stores: stores, writer: MailWriter(stores: stores, sink: nil), api: gmail,
            token: { _ in "fixture" }, recovery: MailRemovalRecovery(stores: stores, intents: intents), feed: feed)
        return (stores, sync)
    }
    private func entry(_ id: String, _ labels: [String], history: UInt64 = 100, thread: String? = nil) -> Entry {
        Entry(id: id, thread: thread ?? "t-" + id, history: String(history), date: 1_700_000_000_000 + Int64(history), labels: labels, deleted: nil)
    }
    private func deleted(_ id: String, history: UInt64 = 200) -> Entry {
        Entry(id: id, thread: nil, history: String(history), date: nil, labels: nil, deleted: true)
    }
    private func labels(_ stores: MailStores, _ id: String) async throws -> [String]? {
        try await stores.index.read { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM message WHERE gmail_id=?)", arguments: [id]) == true else { return nil }
            return try String.fetchAll(db, sql: """
                SELECT l.gmail_id FROM message m JOIN message_label ml ON ml.msg_pk=m.msg_pk JOIN label l ON l.label_pk=ml.label_pk
                WHERE m.gmail_id=? ORDER BY l.gmail_id
                """, arguments: [id])
        }
    }
    private func hold(_ stores: MailStores, ids: [String]) async throws {
        try await stores.index.write { db in
            for id in ids {
                _ = try MailMessageImporter.apply(FetchedMessage(wire: GmailMessage(id: id, threadId: "t-" + id, labelIds: ["INBOX"], historyId: 50),
                    floor: 50, headers: MessageHeaders(payload: nil), structure: nil), account: Self.account, myAddresses: [Self.account], in: db)
            }
        }
    }
    private func pass(_ sync: GmailMailboxSync, at time: Int64 = 1) async throws -> GmailMailboxSync.Progress {
        try await sync.pass(account: Self.account, nowMS: time)
    }

    func testCatchUpFromZeroThenFromTheCursorWithoutAnyGoogleRequest() async throws {
        let feed = Feed(), gmail = Gmail(), (stores, sync) = try await setup(feed, gmail: gmail)
        await feed.set((1...620).map { entry("m\($0)", $0 % 2 == 0 ? ["INBOX", "UNREAD"] : ["SENT"]) })
        var progress = try await pass(sync)
        while progress.hasMore { progress = try await pass(sync) }
        let count = try await stores.index.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM message") }
        XCTAssertEqual(count, 620)
        let m2 = try await labels(stores, "m2"); XCTAssertEqual(m2, ["INBOX", "UNREAD"])
        let known = try await stores.index.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM message WHERE flags & ? != 0", arguments: [MailMessageFlags.labelsKnown.rawValue]) }
        XCTAssertEqual(known, 620, "a feed entry's label set is exact")
        let stubs = try await stores.index.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM message WHERE fetch_state=0") }
        XCTAssertEqual(stubs, 620, "bodies come through the fill, not the feed")
        // From the cursor: only what changed.
        await feed.append([entry("m2", ["INBOX"], history: 150), entry("m621", ["INBOX", "UNREAD"], history: 151)])
        _ = try await pass(sync, at: 2)
        let read = try await labels(stores, "m2"); XCTAssertEqual(read, ["INBOX"])
        let asked = await feed.asked
        XCTAssertEqual(asked.first!, nil)
        XCTAssertEqual(asked.last!, "620")
        let operations = await gmail.operations
        XCTAssertEqual(operations, [], "an account on the feed lists and polls nothing at Google")
    }

    func testAnEntryOlderThanWhatIsStoredChangesNothing() async throws {
        let feed = Feed(), (stores, sync) = try await setup(feed)
        await feed.set([entry("a", ["INBOX", "STARRED"], history: 300)])
        _ = try await pass(sync)
        await feed.append([entry("a", ["INBOX"], history: 200)])
        _ = try await pass(sync, at: 2)
        let a = try await labels(stores, "a"); XCTAssertEqual(a, ["INBOX", "STARRED"])
        let history = try await stores.index.read { try String.fetchOne($0, sql: "SELECT history_id FROM message WHERE gmail_id='a'") }
        XCTAssertEqual(history, "300")
    }

    func testDeletionsGoThroughTheBulkRemovalHold() async throws {
        let feed = Feed(), (stores, sync) = try await setup(feed)
        let ids = (1...30).map { "m\($0)" }
        await feed.set(ids.map { entry($0, ["INBOX"]) })
        _ = try await pass(sync)
        // Two deletions: applied, with tombstones.
        await feed.append([deleted("m1"), deleted("m2")])
        _ = try await pass(sync, at: 2)
        let m1 = try await labels(stores, "m1"); XCTAssertNil(m1)
        let tombstones = try await stores.index.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM tombstone") }
        XCTAssertEqual(tombstones, 2)
        // Twenty more, more than a third of what is held: held for the person, nothing deleted.
        await feed.append((3...22).map { deleted("m\($0)") })
        _ = try await pass(sync, at: 3)
        let held = try await stores.index.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM held_removal WHERE kept=0") }
        XCTAssertEqual(held, 20)
        let remaining = try await stores.index.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM message") }
        XCTAssertEqual(remaining, 28)
    }

    func testCatchUpChecksWhatTheDeviceHeldOnlyOnceTheCloudIsComplete() async throws {
        let feed = Feed(), (stores, sync) = try await setup(feed)
        try await hold(stores, ids: ["kept", "old-1", "old-2"])
        await feed.set([entry("kept", ["INBOX"]), entry("new", ["INBOX"])], complete: false)
        var progress = try await pass(sync)
        XCTAssertTrue(progress.hasMore, "the catch-up stays open while the cloud's first scan runs")
        var checks = await feed.checks
        XCTAssertEqual(checks, [], "absence from an incomplete feed says nothing")
        await feed.configure(complete: true)
        progress = try await pass(sync, at: 2)
        XCTAssertFalse(progress.hasMore)
        checks = await feed.checks
        XCTAssertEqual(checks, [["old-1", "old-2"]])
        // The cloud's answers arrive through the feed: one still in Gmail, one deleted.
        await feed.append([entry("old-1", ["Label_1"], history: 400), deleted("old-2", history: 401)])
        _ = try await pass(sync, at: 3)
        let old1 = try await labels(stores, "old-1"); XCTAssertEqual(old1, ["Label_1"])
        let old2 = try await labels(stores, "old-2"); XCTAssertNil(old2)
        let open = try await stores.index.read { try MailCloudFeedIndex.state(account: Self.account, in: $0)?.catchUpMaxPK }
        XCTAssertNil(open)
        checks = await feed.checks
        XCTAssertEqual(checks.count, 1, "a closed catch-up checks nothing again")
    }

    func testANewCloudMailboxOrAnExpiredCursorStartsAgainFromZero() async throws {
        let feed = Feed(), (stores, sync) = try await setup(feed)
        await feed.set([entry("a", ["INBOX"]), entry("b", ["INBOX"])])
        _ = try await pass(sync)
        await feed.configure(expiredOnce: true)
        _ = try await pass(sync, at: 2)
        var asked = await feed.asked
        XCTAssertEqual(asked.suffix(2), ["2", nil])
        // Mail turned off and on again in the cloud: a new epoch, a new sequence.
        await feed.configure(epoch: "epoch-2")
        await feed.set([entry("a", ["INBOX", "STARRED"], history: 500)])
        _ = try await pass(sync, at: 3)
        asked = await feed.asked
        XCTAssertEqual(asked.suffix(2), ["2", nil], "a page read from an old epoch's cursor is not used")
        let a = try await labels(stores, "a"); XCTAssertEqual(a, ["INBOX", "STARRED"])
        let b = try await labels(stores, "b"); XCTAssertEqual(b, ["INBOX"], "not named is not absent")
    }

    func testAServiceWithoutTheFeedKeepsTheGmailPath() async throws {
        let feed = Feed(), gmail = Gmail(), (_, sync) = try await setup(feed, gmail: gmail)
        await feed.configure(unavailable: true)
        _ = try await pass(sync)
        let operations = await gmail.operations
        XCTAssertTrue(operations.contains("list"), "the existing reconcile runs")
        // Asked again only after ten minutes.
        _ = try await pass(sync, at: 1_000)
        var asked = await feed.asked
        XCTAssertEqual(asked.count, 1)
        await feed.configure(unavailable: false)
        _ = try await pass(sync, at: 700_000)
        asked = await feed.asked
        XCTAssertEqual(asked.count, 2)
    }

    func testTheTransportMapsStatusesAndKeepsTheAddressOutOfTheURL() async throws {
        let reference = CloudMailReference(email: Self.account, context: "ctx").value
        let page = #"{"version":1,"epoch":"e","cursor":"3-1","more":false,"complete":true,"entries":[{"id":"a","thread":"t","history":"9","date":1,"labels":["INBOX"]},{"id":"b","history":"10","deleted":true}]}"#
        actor Answers { var next: [(Data, Int)] = []; var bodies: [Data] = []
            func push(_ a: (Data, Int)) { next.append(a) }
            func take(_ body: Data) -> (Data, Int) { bodies.append(body); return next.removeFirst() } }
        let answers = Answers()
        let feed = CloudMailFeed(reference: { _ in reference }, transport: { _, route, body in
            XCTAssertEqual(route, reference); return await answers.take(body)
        })
        await answers.push((Data(page.utf8), 200))
        let decoded = try await feed.page(account: Self.account, after: "2", limit: 500, fresh: true)
        XCTAssertEqual(decoded.cursor, "3-1")
        XCTAssertEqual(decoded.entries.last?.deleted, true)
        let firstBody = await answers.bodies[0]
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: firstBody) as? [String: Any])
        XCTAssertEqual(sent["email"] as? String, Self.account)
        XCTAssertEqual(sent["after"] as? String, "2")
        XCTAssertEqual(sent["fresh"] as? Bool, true)
        for (status, expected) in [(404, MailCloudFeedError.unavailable), (410, .expired)] {
            await answers.push((Data(), status))
            do { _ = try await feed.page(account: Self.account, after: nil, limit: 10, fresh: false); XCTFail() }
            catch { XCTAssertEqual(error as? MailCloudFeedError, expected) }
        }
        await answers.push((Data(#"{"error":{"code":503,"message":"x"}}"#.utf8), 503))
        do { _ = try await feed.page(account: Self.account, after: nil, limit: 10, fresh: false); XCTFail() }
        catch { XCTAssertEqual(error as? GmailError, .server(503)) }
        let request = BananaService.request(.mailFeed(try CloudMailFeed.pageBody(email: Self.account, after: nil, limit: 5, fresh: false)),
                                            host: "service.example", session: "session")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v1/mail/feed")
        XCTAssertNil(request.url?.query)
    }
}
