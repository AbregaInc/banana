import XCTest
import GRDB

/// Message text from Banana Cloud in bulk (MAIL-CLOUD-SYNC §5a): fakes only, no network.
final class MailCloudPullTests: XCTestCase {
    static let account = "a@example.com"
    typealias Entry = MailCloudFeedPage.Entry

    /// A whole `full` message with a plain body, as the cloud stores it.
    static func full(_ id: String, thread: String? = nil, date: Int64, history: UInt64 = 100) -> GmailMessage {
        let json = """
        {"id":"\(id)","threadId":"\(thread ?? "t-" + id)","historyId":"\(history)","internalDate":"\(date)","labelIds":["INBOX"],
         "payload":{"partId":"0","mimeType":"text/plain","headers":[{"name":"From","value":"sender@example.com"},{"name":"Subject","value":"S \(id)"}],
         "body":{"size":5,"data":"SGVsbG8"}}}
        """
        return try! JSONDecoder().decode(GmailMessage.self, from: Data(json.utf8))
    }

    /// The cloud: a feed, and the content it holds. Records each bulk request.
    actor Cloud: MailCloudFeedSource {
        var entries: [Entry] = []
        var accountEntries: [String: [Entry]] = [:]
        var held: [String: GmailMessage] = [:]
        var asked: [[String]] = []
        var askedAccounts: [String] = []
        /// Every bulk request, failed ones included.
        var attempts = 0
        var failure: Error?
        /// Fail only this many requests, then answer again (a dropped connection that comes back).
        var failuresLeft = Int.max
        var latency: Duration = .zero
        func set(_ entries: [Entry]) { self.entries = entries }
        func set(_ entries: [Entry], for account: String) { accountEntries[account] = entries }
        func hold(_ messages: [GmailMessage]) { for m in messages { held[m.id!] = m } }
        func fail(_ error: Error?, times: Int = Int.max) { failure = error; failuresLeft = times }
        func slow(_ value: Duration) { latency = value }
        func page(account: String, after: String?, limit: Int, fresh: Bool) async throws -> MailCloudFeedPage {
            if latency > .zero { try await Task.sleep(for: latency) }
            let entries = accountEntries[account] ?? entries
            let start = after.flatMap(Int.init) ?? 0
            let slice = Array(entries[min(start, entries.count)..<min(start + limit, entries.count)])
            return MailCloudFeedPage(epoch: "e1", cursor: String(start + slice.count), more: start + slice.count < entries.count,
                                     complete: true, entries: slice)
        }
        func check(account: String, ids: [String]) async throws {}
        func contents(account: String, ids: [String]) async throws -> [MailCloudContent] {
            if latency > .zero { try await Task.sleep(for: latency) }
            attempts += 1
            if let failure, failuresLeft > 0 { failuresLeft -= 1; throw failure }
            asked.append(ids); askedAccounts.append(account)
            return ids.map { held[$0].map(MailCloudContent.message) ?? .missing($0) }
        }
    }

    /// Gmail: answers the per-message path, slowly if asked; counts what it was asked.
    actor Gmail: GmailAPI {
        var messages: [String: GmailMessage] = [:]
        var calls: [String] = []
        var latency: Duration = .zero
        func hold(_ list: [GmailMessage]) { for m in list { messages[m.id!] = m } }
        func slow(_ value: Duration) { latency = value }
        private func wait() async throws { if latency > .zero { try await Task.sleep(for: latency) } }
        func profile(token: String) async throws -> GmailProfile {
            calls.append("profile"); try await wait()
            return GmailProfile(emailAddress: MailCloudPullTests.account, messagesTotal: messages.count, historyId: 100)
        }
        func message(token: String, id: String, format: GmailFormat) async throws -> GmailMessage {
            calls.append("message:\(id)"); try await wait()
            guard let m = messages[id] else { throw GmailError.notFound }
            return m
        }
        func thread(token: String, id: String, format: GmailFormat) async throws -> GmailThread {
            calls.append("thread:\(id)"); try await wait()
            let list = messages.values.filter { $0.threadId == id }.sorted { ($0.internalDate ?? 0) < ($1.internalDate ?? 0) }
                .map { m -> GmailMessage in var h = m; h.payload?.body = nil; return h }
            return GmailThread(id: id, historyId: 100, messages: list)
        }
        func attachment(token: String, messageID: String, attachmentID: String) async throws -> GmailPartBody { throw GmailError.malformed }
        func labels(token: String) async throws -> [GmailLabel] { [] }
        func listMessages(token: String, labelIDs: [String], query: String?, includeSpamTrash: Bool, pageToken: String?, maxResults: Int) async throws -> GmailIDPage { GmailIDPage() }
        func history(token: String, start: String, pageToken: String?, maxResults: Int) async throws -> GmailHistoryPage { GmailHistoryPage(historyId: 100) }
        func modify(token: String, id: String, add: [String], remove: [String]) async throws { XCTFail("no writes") }
        func trash(token: String, id: String) async throws { XCTFail("no writes") }
        func untrash(token: String, id: String) async throws { XCTFail("no writes") }
    }

    /// Thirty days after the epoch: the fixtures' small dates are old mail, not new arrivals.
    final class Clock: @unchecked Sendable { var now: Int64 = 30 * 86_400_000 }

    private func stores() async throws -> MailStores {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-pull-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try await Task.detached { try MailStores.open(MailDirectories(root: root), migrations: MailSlices.migrations()) }.value
    }
    private func entry(_ id: String, date: Int64, content: Bool = true, thread: String? = nil,
                       labels: [String] = ["INBOX"]) -> Entry {
        Entry(id: id, thread: thread ?? "t-" + id, history: "100", date: date, labels: labels, deleted: nil, content: content)
    }

    /// The feed applied (as a sync pass does), and a pull over it.
    private func setup(_ cloud: Cloud, gmail: Gmail = Gmail(), clock: Clock = Clock(), accounts: [String] = [account],
                       pace: @escaping @Sendable () -> MailWorkPace = { .full }) async throws -> (MailStores, MailCloudPull) {
        let stores = try await stores()
        let writer = MailWriter(stores: stores, sink: nil)
        let feed = MailCloudFeedSync(stores: stores, writer: writer, source: cloud, recover: { _ in })
        for account in accounts {
            var progress = try await feed.pass(account: account, nowMS: 1)
            while progress?.hasMore == true { progress = try await feed.pass(account: account, nowMS: 1) }
        }
        let loader = GmailConversationLoader(stores: stores, writer: writer, api: gmail, token: { _ in "fixture" })
        return (stores, MailCloudPull(stores: stores, loader: loader, source: cloud, clock: { clock.now }, pace: pace, sleep: { _ in }))
    }

    /// An HTML message nested deeper than the preparer takes (`MailHTMLPreparer.Failure.tooComplex`).
    /// More pieces than preparation walks, and no plain part to show instead: it cannot be prepared.
    /// (Depth alone no longer stops it: deep content is read flat.)
    static func tooComplex(_ id: String, date: Int64, labels: [String] = ["INBOX"]) -> GmailMessage {
        let html = "<html><body>" + String(repeating: "<i></i>", count: MailHTMLPreparer.maximumNodes) + "deep</body></html>"
        let data = Data(html.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let json = """
        {"id":"\(id)","threadId":"t-\(id)","historyId":"100","internalDate":"\(date)","labelIds":\(String(decoding: try! JSONEncoder().encode(labels), as: UTF8.self)),
         "payload":{"partId":"0","mimeType":"text/html","headers":[{"name":"From","value":"news@example.com"},{"name":"Subject","value":"Deep \(id)"}],
         "body":{"size":\(html.utf8.count),"data":"\(data)"}}}
        """
        return try! JSONDecoder().decode(GmailMessage.self, from: Data(json.utf8))
    }
    static func full(_ id: String, date: Int64, labels: [String]) -> GmailMessage {
        var m = full(id, date: date); m.labelIds = labels; return m
    }
    private func id(_ m: String) -> MailMessageID { MailMessageID(account: Self.account, message: m) }
    private func conversation(_ m: String) -> MailConversationID { MailConversationID(account: Self.account, thread: "t-" + m) }
    private func here(_ stores: MailStores, _ m: String) async throws -> Bool {
        try await MailBlobStore(stores: stores).prepared(account: Self.account, messageID: m) != nil
    }

    func testPlanTakesOpenedThenScreenThenFillOneAccountAtATime() {
        let a = (1...3).map { id("o\($0)") }, b = MailMessageID(account: "b@example.com", message: "x")
        XCTAssertEqual(MailCloudPull.plan(opened: [id("o1")], screen: [id("s1")], fill: [id("f1")], inFlight: [], blocked: [])?.tier, .opened)
        XCTAssertEqual(MailCloudPull.plan(opened: [id("o1")], screen: [id("s1")], fill: [], inFlight: [id("o1")], blocked: [])?.ids, [id("s1")])
        XCTAssertEqual(MailCloudPull.plan(opened: [b] + a, screen: [], fill: [], inFlight: [], blocked: [])?.ids, [b], "one account a request")
        XCTAssertEqual(MailCloudPull.plan(opened: [b] + a, screen: [], fill: [], inFlight: [], blocked: ["b@example.com"])?.ids, a)
        XCTAssertNil(MailCloudPull.plan(opened: [], screen: [], fill: [], inFlight: [], blocked: []))
        let many = (1...60).map { id("f\($0)") }
        XCTAssertEqual(MailCloudPull.plan(opened: [], screen: [], fill: many, inFlight: [], blocked: [])?.ids.count, MailCloudPull.batch)
    }

    func testVisibleRowsArePulledBeforeTheFillAndTheFillGoesNewestFirst() async throws {
        let cloud = Cloud()
        let dates = (1...60).map { Int64($0) * 1000 }
        await cloud.set(dates.enumerated().map { entry("m\($0.offset + 1)", date: $0.element) })
        await cloud.hold(dates.enumerated().map { Self.full("m\($0.offset + 1)", date: $0.element) })
        let (stores, pull) = try await setup(cloud)
        // Rows 10–14 are on screen (an older stretch of the list): they come first.
        _ = try await pull.onScreen((10...14).map { conversation("m\($0)") })
        let first = try await pull.step(fill: true)
        XCTAssertEqual(first.tier, .screen)
        XCTAssertEqual(Set(first.stored), Set((10...14).map { id("m\($0)") }))
        var steps = [first]
        while true { let s = try await pull.step(fill: true); if !s.worked { break }; steps.append(s) }
        let asked = await cloud.asked
        XCTAssertEqual(asked.count, 4, "5 on screen, then 55 in batches of 25")
        XCTAssertEqual(asked[1], (36...60).reversed().map { "m\($0)" }, "then the rest, newest first, a batch at a time")
        XCTAssertEqual(asked[2].first, "m35")
        XCTAssertEqual(asked[3], (1...5).reversed().map { "m\($0)" })
        XCTAssertFalse(asked.dropFirst().joined().contains("m12"), "nothing is asked twice")
        for n in 1...60 { let ok = try await here(stores, "m\(n)"); XCTAssertTrue(ok, "m\(n)") }
        let pending = try await stores.index.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM message WHERE fetch_state<2") }
        XCTAssertEqual(pending, 0)
    }

    func testAnOpenedConversationGoesAheadOfTheScreenAndTheFill() async throws {
        let cloud = Cloud()
        await cloud.set((1...40).map { entry("m\($0)", date: Int64($0) * 1000) } + [entry("r1", date: 1, thread: "t-old"), entry("r2", date: 2, thread: "t-old")])
        await cloud.hold((1...40).map { Self.full("m\($0)", date: Int64($0) * 1000) }
                         + [Self.full("r1", thread: "t-old", date: 1), Self.full("r2", thread: "t-old", date: 2)])
        let (stores, pull) = try await setup(cloud)
        _ = try await pull.onScreen((1...20).map { conversation("m\($0)") })
        let fallback = try await pull.open(MailConversationID(account: Self.account, thread: "t-old"))
        XCTAssertEqual(fallback, [])
        let step = try await pull.step(fill: true)
        XCTAssertEqual(step.tier, .opened)
        XCTAssertEqual(step.stored, [id("r2"), id("r1")], "the whole conversation, newest first")
        let opened = try await here(stores, "r1")
        XCTAssertTrue(opened)
        let next = try await pull.step(fill: true)
        XCTAssertEqual(next.tier, .screen)
        // Scrolling away replaces what is wanted: rows no longer on screen are not pulled as such.
        _ = try await pull.onScreen([conversation("m30")])
        let pending = await pull.pending
        XCTAssertEqual(pending.screen, [id("m30")])
    }

    func testWhatTheCloudLacksFallsBackForOpenedRowsAndClearsTheFlagForTheFill() async throws {
        let cloud = Cloud()
        await cloud.set([entry("a", date: 3000), entry("b", date: 2000), entry("c", date: 1000)])
        await cloud.hold([Self.full("a", date: 3000)])   // b and c: the feed said so, the store no longer has them
        let (stores, pull) = try await setup(cloud)
        _ = try await pull.open(conversation("b"))
        let opened = try await pull.step(fill: false)
        XCTAssertEqual(opened.fallback, [MailCloudPull.Fallback(id: id("b"), urgent: true)], "opened mail is read the per-message way at once")
        let fill = try await pull.step(fill: true)
        XCTAssertEqual(fill.tier, .fill)
        XCTAssertEqual(fill.stored, [id("a")])
        XCTAssertEqual(fill.fallback, [], "the fill waits for the feed instead")
        let flagged = try await stores.index.read { try String.fetchAll($0, sql: "SELECT gmail_id FROM message WHERE cloud_content=1 ORDER BY gmail_id") }
        XCTAssertEqual(flagged, ["a"], "cleared until the feed says the cloud has them")
        let idle = try await pull.step(fill: true)
        XCTAssertFalse(idle.worked)
    }

    func testAServiceWithoutBulkContentSendsOpenedAndVisibleMailThePerMessageWay() async throws {
        let cloud = Cloud()
        await cloud.set([entry("a", date: 1000)])
        await cloud.fail(MailCloudFeedError.unavailable)
        let (_, pull) = try await setup(cloud)
        _ = try await pull.open(conversation("a"))
        let step = try await pull.step(fill: true)
        XCTAssertEqual(step.fallback, [MailCloudPull.Fallback(id: id("a"), urgent: true)])
        let cloudNow = try await pull.isCloud(Self.account)
        XCTAssertFalse(cloudNow, "ten minutes on the per-message path")
        let visible = try await pull.onScreen([conversation("a")])
        XCTAssertEqual(visible, [MailCloudPull.Fallback(id: id("a"), urgent: false)])
    }

    func testARateLimitBacksOffUntilItsRetryTime() async throws {
        let cloud = Cloud(), clock = Clock()
        await cloud.set([entry("a", date: 1000)])
        await cloud.hold([Self.full("a", date: 1000)])
        await cloud.fail(GmailError.limited(.user, retryAfter: 30))
        let (stores, pull) = try await setup(cloud, clock: clock)
        let limited = try await pull.step(fill: true)
        XCTAssertTrue(limited.worked)
        XCTAssertTrue(limited.stored.isEmpty)
        await cloud.fail(nil)
        clock.now += 29_000
        let waiting = try await pull.step(fill: true)
        XCTAssertFalse(waiting.worked, "nothing is asked before Google's retry time")
        let asked = await cloud.asked
        XCTAssertEqual(asked, [])
        clock.now += 2_000
        let after = try await pull.step(fill: true)
        XCTAssertEqual(after.stored, [id("a")])
        let ok = try await here(stores, "a")
        XCTAssertTrue(ok)
    }

    func testARestartResumesWhereThePullStoppedWithoutAskingAgain() async throws {
        let cloud = Cloud()
        await cloud.set((1...60).map { entry("m\($0)", date: Int64($0) * 1000) })
        await cloud.hold((1...60).map { Self.full("m\($0)", date: Int64($0) * 1000) })
        let (stores, pull) = try await setup(cloud)
        _ = try await pull.step(fill: true)    // the newest 25, then the process goes
        let gmail = Gmail()
        let again = MailCloudPull(stores: stores, loader: GmailConversationLoader(stores: stores, writer: MailWriter(stores: stores, sink: nil), api: gmail,
            token: { _ in "fixture" }), source: cloud)
        while true { let s = try await again.step(fill: true); if !s.worked { break } }
        let asked = await cloud.asked
        XCTAssertEqual(asked.flatMap { $0 }.count, 60, "each message asked for once across the restart")
        XCTAssertEqual(asked[1].first, "m35", "it goes on below what is here")
        let calls = await gmail.calls
        XCTAssertEqual(calls, [], "no Gmail request")
    }

    func testStoredCloudMailKeepsNewerLabelsFromTheFeed() async throws {
        // Invariant 23: the cloud's copy carries an older position than what the feed applied.
        let cloud = Cloud()
        await cloud.set([Entry(id: "a", thread: "t-a", history: "200", date: 1000, labels: ["INBOX", "STARRED"], deleted: nil, content: true)])
        await cloud.hold([Self.full("a", date: 1000, history: 150)])
        let (stores, pull) = try await setup(cloud)
        _ = try await pull.step(fill: true)
        let labels = try await stores.index.read { db in
            try String.fetchAll(db, sql: "SELECT l.gmail_id FROM message_label ml JOIN label l ON l.label_pk=ml.label_pk JOIN message m ON m.msg_pk=ml.msg_pk WHERE m.gmail_id='a' ORDER BY 1")
        }
        XCTAssertEqual(labels, ["INBOX", "STARRED"])
        let ok = try await here(stores, "a")
        XCTAssertTrue(ok)
    }

    // MARK: New Inbox mail known only by id (Beta 108: a badge of 4, an Inbox without them)

    private func fetchState(_ stores: MailStores, _ m: String) async throws -> Int? {
        try await stores.index.read { try Int.fetchOne($0, sql: "SELECT fetch_state FROM message WHERE gmail_id=?", arguments: [m]) }
    }

    /// One message in the batch whose HTML the preparer refuses used to fail the whole batch, and
    /// the same newest-first batch was asked again on every kick: nothing in it, nor in any later
    /// account, was ever stored. Now the others are stored and it is listed with its headers.
    func testOneMessageThatCannotBePreparedDoesNotHoldBackItsBatch() async throws {
        let cloud = Cloud()
        await cloud.set((1...5).map { entry("m\($0)", date: Int64($0) * 1000) })
        await cloud.hold([1, 2, 4, 5].map { Self.full("m\($0)", date: Int64($0) * 1000) } + [Self.tooComplex("m3", date: 3000)])
        let (stores, pull) = try await setup(cloud)
        let step = try await pull.step(fill: true)
        XCTAssertEqual(step.tier, .fill)
        XCTAssertEqual(Set(step.stored), Set([5, 4, 2, 1].map { id("m\($0)") }))
        XCTAssertTrue(step.problems.contains { $0.contains("tooComplex") }, "\(step.problems)")
        for n in [1, 2, 4, 5] { let ok = try await here(stores, "m\(n)"); XCTAssertTrue(ok, "m\(n)") }
        let deep = try await stores.index.read { try Row.fetchOne($0, sql: "SELECT fetch_state, subject, cloud_content FROM message WHERE gmail_id='m3'") }
        XCTAssertEqual(deep?[0] as Int?, 1, "its headers are in: the row is listed")
        XCTAssertEqual(deep?[1] as String?, "Deep m3")
        XCTAssertEqual(deep?[2] as Int?, 0, "the fill does not ask for it again")
        let idle = try await pull.step(fill: true)
        XCTAssertFalse(idle.worked, "no batch is asked again and again")
    }

    /// New Inbox mail known only by id is not listed until its headers arrive, so it comes first,
    /// newest first, even while the work pace stops the screen and the fill (a warm device, Low
    /// Power Mode). Archived new mail and old mail wait for the fill.
    func testNewInboxArrivalsComeFirstWhateverThePace() async throws {
        let cloud = Cloud(), clock = Clock()
        let old = (1...30).map { entry("o\($0)", date: Int64($0) * 1000) }
        let fresh = [entry("n1", date: clock.now - 120_000, labels: ["INBOX", "UNREAD"]),
                     entry("n2", date: clock.now - 60_000, labels: ["INBOX", "UNREAD"]),
                     entry("arch", date: clock.now - 30_000, labels: ["UNREAD"])]
        await cloud.set(old + fresh)
        await cloud.hold((1...30).map { Self.full("o\($0)", date: Int64($0) * 1000) }
                         + [Self.full("n1", date: clock.now - 120_000, labels: ["INBOX", "UNREAD"]),
                            Self.full("n2", date: clock.now - 60_000, labels: ["INBOX", "UNREAD"]),
                            Self.full("arch", date: clock.now - 30_000, labels: ["UNREAD"])])
        let (stores, pull) = try await setup(cloud, clock: clock, pace: { .stopped })
        let reader = MailIndexReader(stores: stores)
        let inbox = PageRequest(view: .unified(.inbox), account: nil, filters: [], before: nil, limit: 50)
        let before = try await reader.counts(inbox)
        XCTAssertEqual(before.unread, 0, "nothing listed, nothing counted")
        _ = try await pull.onScreen((1...5).map { conversation("o\($0)") })
        let step = try await pull.step(fill: true)
        XCTAssertEqual(step.tier, .arrivals)
        XCTAssertEqual(step.stored, [id("n2"), id("n1")], "newest first")
        let asked = await cloud.asked
        XCTAssertEqual(asked, [["n2", "n1"]])
        let next = try await pull.step(fill: true)
        XCTAssertFalse(next.worked, "paced to a stop: the screen and the fill wait")
        let rows = try await reader.page(inbox)
        XCTAssertEqual(rows.prefix(2).map(\.thread), ["t-n2", "t-n1"], "listed at the top of the Inbox")
        let after = try await reader.counts(inbox)
        XCTAssertEqual(after.unread, rows.filter(\.unread).count, "the count is what the list shows")
        XCTAssertEqual(after.unread, 2)
        let archived = try await fetchState(stores, "arch")
        XCTAssertEqual(archived, 0, "not in the Inbox: left to the fill")
    }

    /// An arrival the network dropped goes the per-message way at once and is asked again after the
    /// retry time, without another push and without asking in a loop meanwhile.
    func testAnArrivalTheNetworkDroppedIsAskedAgainAfterItsRetryTime() async throws {
        let cloud = Cloud(), clock = Clock()
        await cloud.set([entry("n1", date: clock.now - 60_000, labels: ["INBOX", "UNREAD"])])
        await cloud.hold([Self.full("n1", date: clock.now - 60_000, labels: ["INBOX", "UNREAD"])])
        await cloud.fail(URLError(.networkConnectionLost), times: 1)
        let (stores, pull) = try await setup(cloud, clock: clock)
        let dropped = try await pull.step(fill: true)
        XCTAssertEqual(dropped.tier, .arrivals)
        XCTAssertEqual(dropped.fallback, [MailCloudPull.Fallback(id: id("n1"), urgent: true)], "Gmail directly, at once")
        XCTAssertFalse(dropped.problems.isEmpty, "the failure is reported")
        let retry = await pull.nextRetry()
        XCTAssertEqual(retry, clock.now + MailCloudPull.transientRetryMS)
        let waiting = try await pull.step(fill: true)
        XCTAssertFalse(waiting.worked)
        let attempts = await cloud.attempts
        XCTAssertEqual(attempts, 1, "nothing asked before the retry time")
        clock.now += MailCloudPull.transientRetryMS
        let again = try await pull.step(fill: true)
        XCTAssertEqual(again.stored, [id("n1")])
        let state = try await fetchState(stores, "n1")
        XCTAssertEqual(state, 2)
        let none = await pull.nextRetry()
        XCTAssertNil(none, "nothing left waiting")
    }

    /// An arrival the cloud does not hold yet: the per-message way at once, then asked again later,
    /// each wait longer than the last, never in a loop.
    func testAnArrivalTheCloudLacksIsAskedAgainLaterNotInALoop() async throws {
        let cloud = Cloud(), clock = Clock()
        await cloud.set([entry("n1", date: clock.now - 60_000, content: false, labels: ["INBOX", "UNREAD"])])
        let (stores, pull) = try await setup(cloud, clock: clock)
        let first = try await pull.step(fill: true)
        XCTAssertEqual(first.fallback, [MailCloudPull.Fallback(id: id("n1"), urgent: true)])
        let idle = try await pull.step(fill: true)
        XCTAssertFalse(idle.worked, "not asked again at once")
        clock.now += MailCloudPull.transientRetryMS
        let second = try await pull.step(fill: true)
        XCTAssertEqual(second.tier, .arrivals)
        let retry = await pull.nextRetry()
        XCTAssertEqual(retry, clock.now + 2 * MailCloudPull.transientRetryMS, "the wait doubles")
        await cloud.hold([Self.full("n1", date: clock.now - 60_000, labels: ["INBOX", "UNREAD"])])
        clock.now += 2 * MailCloudPull.transientRetryMS
        let third = try await pull.step(fill: true)
        XCTAssertEqual(third.stored, [id("n1")])
        let state = try await fetchState(stores, "n1")
        XCTAssertEqual(state, 2)
        let asked = await cloud.asked
        XCTAssertEqual(asked.count, 3)
    }

    /// One account's long backlog no longer keeps another account's newer mail waiting: the fill
    /// takes the newest across accounts (it used to take the first account that had any).
    func testTheFillGoesNewestFirstAcrossAccounts() async throws {
        let cloud = Cloud(), other = "b@example.com"
        await cloud.set((1...40).map { entry("a\($0)", date: Int64($0) * 1000) }, for: Self.account)
        await cloud.set([entry("b1", date: 90_000)], for: other)
        await cloud.hold((1...40).map { Self.full("a\($0)", date: Int64($0) * 1000) } + [Self.full("b1", date: 90_000)])
        let (stores, pull) = try await setup(cloud, accounts: [Self.account, other])
        let first = try await pull.step(fill: true)
        XCTAssertEqual(first.stored, [MailMessageID(account: other, message: "b1")])
        let accounts = await cloud.askedAccounts
        XCTAssertEqual(accounts, [other])
        while try await pull.step(fill: true).worked {}
        let owed = try await stores.index.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM message WHERE fetch_state<2") }
        XCTAssertEqual(owed, 0)
    }
}

/// The live source with the cloud: a push catches up; a row on screen opens with its text here.
@MainActor final class MailCloudPullLiveTests: XCTestCase {
    private final class Access: MailAccountAccess {
        var connectedAccountIDs = [MailCloudPullTests.account]
        func mailGrant(accountID: String) -> MailGrant { .granted }
        func mailAccessToken(accountID: String) async throws -> MailAccessToken { MailAccessToken(value: "fixture", scopes: [MailScopes.gmailModify]) }
        func dropMailAccessToken(accountID: String) {}
        func requestMailAccess(accountID: String) async -> MailAccessOutcome { .granted }
        func forgetMailAccess(accountID: String) async throws {}
        func cancelMailTokenRequests() {}
    }
    private func source(cloud: MailCloudPullTests.Cloud?, gmail: MailCloudPullTests.Gmail) async throws -> (MailStores, MailLiveSource) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-live-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let (stores, intent) = try await Task.detached {
            let directories = try MailDirectories(root: root)
            return (try MailStores.open(directories, migrations: MailSlices.migrations()), try MailIntentStore(directories: directories))
        }.value
        let source = MailLiveSource(stores: stores, access: Access(), api: gmail, cloudFeed: cloud)
        try await source.prepareActions(intent: intent)
        return (stores, source)
    }
    private func id(_ m: String) -> MailMessageID { MailMessageID(account: MailCloudPullTests.account, message: m) }

    func testBananaServiceRecognisesTheMailPush() {
        XCTAssertTrue(BananaService.isMailPush(["aps": ["content-available": 1], "b": ["k": "mail"]]))
        XCTAssertFalse(BananaService.isMailPush(["aps": ["content-available": 1], "b": ["k": "calendar"]]))
        XCTAssertFalse(BananaService.isMailPush(["aps": ["content-available": 1]]))
        XCTAssertFalse(BananaService.isCalendarPush(["b": ["k": "mail"]]))
    }

    func testAPushPullsTheFeedAndTheNewMessagesTextWithMailClosed() async throws {
        let cloud = MailCloudPullTests.Cloud(), gmail = MailCloudPullTests.Gmail()
        await cloud.set([Entry(id: "n1", thread: "t-n1", history: "100", date: 5000, labels: ["INBOX", "UNREAD"], deleted: nil, content: true)])
        await cloud.hold([MailCloudPullTests.full("n1", date: 5000)])
        let (stores, source) = try await source(cloud: cloud, gmail: gmail)
        // Mail is not on screen (never activated): only the push's window runs anything.
        let ok = await source.catchUpFromPush(budget: .seconds(5))
        XCTAssertTrue(ok)
        let body = await source.body(id("n1"))
        XCTAssertNotEqual(body, .notOnDevice)
        let calls = await gmail.calls
        XCTAssertEqual(calls, [], "the text came from the cloud, not Gmail")
        let state = try await stores.index.read { try Int.fetchOne($0, sql: "SELECT fetch_state FROM message WHERE gmail_id='n1'") }
        XCTAssertEqual(state, 2)
    }
    typealias Entry = MailCloudFeedPage.Entry

    /// Mail on screen, the cloud pull dropped by the network: the new message is asked again at its
    /// retry time and listed, with no push and no reopening of Mail. The badge's count follows the list.
    func testANewArrivalTheNetworkDroppedLoadsWhileMailIsOpenWithoutAnotherPush() async throws {
        let cloud = MailCloudPullTests.Cloud(), gmail = MailCloudPullTests.Gmail()
        let date = Int64(Date().timeIntervalSince1970 * 1000) - 60_000
        await cloud.set([Entry(id: "n1", thread: "t-n1", history: "100", date: date, labels: ["INBOX", "UNREAD"], deleted: nil, content: true)])
        await cloud.hold([MailCloudPullTests.full("n1", date: date, labels: ["INBOX", "UNREAD"])])
        await cloud.fail(URLError(.networkConnectionLost), times: 1)
        let (stores, source) = try await source(cloud: cloud, gmail: gmail)
        _ = await source.catchUpFromPush(budget: .zero)   // the feed only: n1 known by id
        var unread: [Int] = []
        let places = source.observePlaces { unread.append($0.mailboxCounts[.inbox]?.unread.value ?? 0) }
        defer { places.cancel() }
        let start = ContinuousClock.now
        source.setVisible(true)
        defer { source.setVisible(false) }
        var state: Int?
        while ContinuousClock.now - start < .seconds(15) {
            state = try await stores.index.read { try Int.fetchOne($0, sql: "SELECT fetch_state FROM message WHERE gmail_id='n1'") }
            if state == 2 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let elapsed = start.duration(to: .now)
        XCTAssertEqual(state, 2, "loaded after the retry time")
        XCTAssertLessThan(elapsed, .seconds(10))
        let attempts = await cloud.attempts
        XCTAssertGreaterThanOrEqual(attempts, 2, "asked again after the drop")
        while ContinuousClock.now - start < .seconds(15), unread.last != 1 { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(unread.first, 0, "not counted while not listed")
        XCTAssertEqual(unread.last, 1, "counted once listed")
    }

    /// Inside a push's window: a pull the network dropped is tried again when its retry time
    /// comes inside the window.
    func testAPushRetriesAPullTheNetworkDroppedInsideItsWindow() async throws {
        let cloud = MailCloudPullTests.Cloud(), gmail = MailCloudPullTests.Gmail()
        let date = Int64(Date().timeIntervalSince1970 * 1000) - 60_000
        await cloud.set([Entry(id: "n1", thread: "t-n1", history: "100", date: date, labels: ["INBOX", "UNREAD"], deleted: nil, content: true)])
        await cloud.hold([MailCloudPullTests.full("n1", date: date, labels: ["INBOX", "UNREAD"])])
        await cloud.fail(URLError(.networkConnectionLost), times: 1)
        let (stores, source) = try await source(cloud: cloud, gmail: gmail)
        let ok = await source.catchUpFromPush(budget: .seconds(12))
        XCTAssertTrue(ok)
        let state = try await stores.index.read { try Int.fetchOne($0, sql: "SELECT fetch_state FROM message WHERE gmail_id='n1'") }
        XCTAssertEqual(state, 2)
        let attempts = await cloud.attempts
        XCTAssertEqual(attempts, 2)
    }

    /// The user-visible effect, measured honestly on the component: the time from opening a
    /// conversation to its text being readable, with a modelled 150 ms per network request.
    /// Before: the per-message path a conversation took when opened (a thread read, then the
    /// body). After: the row was on screen first, so its text was pulled before the open.
    func testOpeningARowThatWasOnScreenFindsItsTextAlreadyHere() async throws {
        let latency = Duration.milliseconds(150)
        let messages = (1...12).map { MailCloudPullTests.full("m\($0)", date: Int64($0) * 1000) }
        let entries = messages.map { Entry(id: $0.id!, thread: $0.threadId, history: "100", date: $0.internalDate, labels: ["INBOX"], deleted: nil, content: true) }

        func openToText(_ source: MailLiveSource, _ m: String) async -> Double {
            let start = ContinuousClock.now
            let observation = source.observeConversation(MailConversationID(account: MailCloudPullTests.account, thread: "t-" + m)) { _ in }
            defer { observation.cancel() }
            while await source.body(id(m)) == .notOnDevice, ContinuousClock.now - start < .seconds(10) {
                try? await Task.sleep(for: .milliseconds(5))
            }
            let d = (ContinuousClock.now - start).components
            return Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15
        }

        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        let opened = ["m5", "m6", "m7", "m8", "m9"]

        // Before: the open's critical path as it was, a thread read then the body read (each a
        // modelled round trip plus the profile check), timed on the loader directly. (Timed
        // through a live source, the fake mailbox's sync backoff also held the per-message queue,
        // which would overstate it.)
        let gmail = MailCloudPullTests.Gmail()
        await gmail.hold(messages); await gmail.slow(latency)
        let (beforeStores, _) = try await source(cloud: nil, gmail: gmail)
        let loader = GmailConversationLoader(stores: beforeStores, writer: MailWriter(stores: beforeStores, sink: nil), api: gmail, token: { _ in "fixture" })
        var beforeMS: [Double] = []
        for m in opened {
            let start = ContinuousClock.now
            let ids = try await loader.thread(MailConversationID(account: MailCloudPullTests.account, thread: "t-" + m))
            for message in ids { try await loader.body(message) }
            let readable = try await MailBlobStore(stores: beforeStores).prepared(account: MailCloudPullTests.account, messageID: m)
            XCTAssertNotNil(readable)
            let d = start.duration(to: .now).components
            beforeMS.append(Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15)
        }

        // After: the cloud holds the text; the rows are on screen for a moment before the tap.
        let cloud = MailCloudPullTests.Cloud(), quiet = MailCloudPullTests.Gmail()
        await cloud.set(entries); await cloud.hold(messages); await cloud.slow(latency)
        let (_, after) = try await source(cloud: cloud, gmail: quiet)
        _ = await after.catchUpFromPush(budget: .milliseconds(1))   // the feed only: rows known, no text yet
        let early = await after.body(id("m7"))
        XCTAssertEqual(early, .notOnDevice, "nothing pulled before the row is shown")
        after.setVisible(true)
        after.onScreen(opened.map { MailConversationID(account: MailCloudPullTests.account, thread: "t-" + $0) })
        // The rows stay on screen until their text is here (a person reading the list), timed.
        let shown = ContinuousClock.now
        var ready = false
        while !ready, ContinuousClock.now - shown < .seconds(10) {
            ready = true
            for m in opened { if await after.body(id(m)) == .notOnDevice { ready = false } }
            if !ready { try await Task.sleep(for: .milliseconds(10)) }
        }
        let shownToReady = shown.duration(to: .now).components
        let readyMS = Double(shownToReady.seconds) * 1000 + Double(shownToReady.attoseconds) / 1e15
        XCTAssertTrue(ready, "the visible rows' text arrived while they were on screen")
        var afterMS: [Double] = []
        for m in opened { afterMS.append(await openToText(after, m)) }
        after.setVisible(false)
        let report = "MAIL_OPEN_TO_TEXT_MS latency=150 shown_to_ready=\(String(format: "%.0f", readyMS)) before=\(beforeMS.map { String(format: "%.1f", $0) }) median=\(String(format: "%.1f", median(beforeMS))) after=\(afterMS.map { String(format: "%.1f", $0) }) median=\(String(format: "%.1f", median(afterMS)))"
        print(report)
        let attachment = XCTAttachment(string: report); attachment.name = "open-to-text"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertLessThan(median(afterMS) * 3, median(beforeMS), report)
        XCTAssertGreaterThan(median(beforeMS), 300, "a thread read and a body read, each a round trip")
        let gmailCalls = await quiet.calls
        XCTAssertEqual(gmailCalls.filter { $0.hasPrefix("message:") || $0.hasPrefix("thread:") }, [], "no Gmail read of a message or thread on the cloud path")
    }
}

/// Preparation happens ahead: on arrival from the cloud, after a preparer change, and an open
/// reads prepared output (MAIL-ENGINE 10.2). Fakes only.
@MainActor final class MailPrepareAheadTests: XCTestCase {
    typealias Entry = MailCloudFeedPage.Entry
    static let account = MailCloudPullTests.account

    /// A newsletter-sized HTML message (about 60 KB): paragraphs, links, emphasis, a table.
    static func html(_ id: String, date: Int64) -> GmailMessage {
        var html = "<html><body><table><tr><td><h1>Issue \(id)</h1></td></tr></table>"
        for n in 0..<220 {
            html += "<p>Paragraph \(n) with <b>bold</b>, <i>italic</i> and <a href=\"https://example.com/\(id)/\(n)\">a link</a>. "
            html += String(repeating: "Some ordinary words in a sentence. ", count: 6) + "</p>"
        }
        html += "</body></html>"
        let data = Data(html.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let json = """
        {"id":"\(id)","threadId":"t-\(id)","historyId":"100","internalDate":"\(date)","labelIds":["INBOX"],
         "payload":{"partId":"0","mimeType":"text/html","headers":[{"name":"From","value":"news@example.com"},{"name":"Subject","value":"Issue \(id)"}],
         "body":{"size":\(html.utf8.count),"data":"\(data)"}}}
        """
        return try! JSONDecoder().decode(GmailMessage.self, from: Data(json.utf8))
    }

    private final class Access: MailAccountAccess {
        var connectedAccountIDs = [MailPrepareAheadTests.account]
        func mailGrant(accountID: String) -> MailGrant { .granted }
        func mailAccessToken(accountID: String) async throws -> MailAccessToken { MailAccessToken(value: "fixture", scopes: [MailScopes.gmailModify]) }
        func dropMailAccessToken(accountID: String) {}
        func requestMailAccess(accountID: String) async -> MailAccessOutcome { .granted }
        func forgetMailAccess(accountID: String) async throws {}
        func cancelMailTokenRequests() {}
    }
    private func id(_ m: String) -> MailMessageID { MailMessageID(account: Self.account, message: m) }
    private func conversation(_ m: String) -> MailConversationID { MailConversationID(account: Self.account, thread: "t-" + m) }

    /// Originals stored through the cloud pull, prepared as they arrive.
    private func stored(_ messages: [GmailMessage]) async throws -> (MailStores, GmailConversationLoader, MailCloudPull) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("prepare-ahead-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let stores = try await Task.detached { try MailStores.open(MailDirectories(root: root), migrations: MailSlices.migrations()) }.value
        let cloud = MailCloudPullTests.Cloud()
        await cloud.set(messages.map { Entry(id: $0.id!, thread: $0.threadId, history: "100", date: $0.internalDate, labels: ["INBOX"], deleted: nil, content: true) })
        await cloud.hold(messages)
        let writer = MailWriter(stores: stores, sink: nil)
        let feed = MailCloudFeedSync(stores: stores, writer: writer, source: cloud, recover: { _ in })
        var progress = try await feed.pass(account: Self.account, nowMS: 1)
        while progress?.hasMore == true { progress = try await feed.pass(account: Self.account, nowMS: 1) }
        let loader = GmailConversationLoader(stores: stores, writer: writer, api: MailCloudPullTests.Gmail(), token: { _ in "fixture" })
        let pull = MailCloudPull(stores: stores, loader: loader, source: cloud)
        while try await pull.step(fill: true).worked {}
        return (stores, loader, pull)
    }
    /// Marks every prepared body as made by the previous preparer: what a version change does.
    private func bumpVersion(_ stores: MailStores) async throws {
        try await stores.blobs.write { try $0.execute(sql: "UPDATE prepared SET prep_version=?", arguments: [MailHTMLPreparer.version - 1]) }
    }
    private func current(_ stores: MailStores, _ m: String) async throws -> Bool {
        try await MailBlobStore(stores: stores).prepared(account: Self.account, messageID: m) != nil
    }

    func testCloudContentIsPreparedAsItArrives() async throws {
        let (stores, loader, _) = try await stored((1...6).map { Self.html("m\($0)", date: Int64($0) * 1000) })
        for n in 1...6 { let ok = try await current(stores, "m\(n)"); XCTAssertTrue(ok, "m\(n)") }
        let ahead = await loader.preparedAhead, onRequest = await loader.preparedOnRequest
        XCTAssertEqual(ahead, 6)
        XCTAssertEqual(onRequest, 0)
        let states = try await stores.index.read { try Int.fetchAll($0, sql: "SELECT prep_state FROM message ORDER BY gmail_id") }
        XCTAssertEqual(states, Array(repeating: 2, count: 6))
    }

    func testAPreparerChangeIsMadeGoodNewestFirstAPieceAtATime() async throws {
        let count = MailReprepare.piece + 6
        let (stores, loader, _) = try await stored((1...count).map { MailCloudPullTests.full("m\($0)", date: Int64($0) * 1000) })
        try await bumpVersion(stores)
        let stale = try await current(stores, "m\(count)")
        XCTAssertFalse(stale, "a new preparer makes every stored body stale")
        final class Pauses: @unchecked Sendable { let lock = NSLock(); var values: [TimeInterval] = [] }
        let recorded = Pauses()
        let pass = MailReprepare(stores: stores, loader: loader, pace: { .paced(share: 0.2) },
                                 sleep: { value in recorded.lock.withLock { recorded.values.append(value) } })
        let first = try await pass.step()
        XCTAssertEqual(first.prepared, MailReprepare.piece)
        XCTAssertTrue(first.more)
        let newest = try await current(stores, "m\(count)"), oldest = try await current(stores, "m1")
        XCTAssertTrue(newest, "the newest first")
        XCTAssertFalse(oldest, "the oldest waits for the next piece")
        XCTAssertEqual(recorded.lock.withLock { recorded.values.count }, MailReprepare.piece, "paced: a pause after each")
        let second = try await pass.step()
        XCTAssertEqual(second.prepared, 6)
        XCTAssertFalse(second.more)
        for n in 1...count { let ok = try await current(stores, "m\(n)"); XCTAssertTrue(ok, "m\(n)") }
        let idle = try await pass.step()
        XCTAssertEqual(idle, MailReprepare.Step())
        // Stopped (warm, Low Power, Mail not in use): nothing runs.
        try await bumpVersion(stores)
        let stopped = MailReprepare(stores: stores, loader: loader, pace: { .stopped })
        let none = try await stopped.step()
        XCTAssertEqual(none.prepared, 0)
    }

    func testAnOpenedConversationWithAStaleBodyIsNamedFirst() async throws {
        let (stores, loader, _) = try await stored((1...3).map { MailCloudPullTests.full("m\($0)", date: Int64($0) * 1000) })
        try await bumpVersion(stores)
        let pass = MailReprepare(stores: stores, loader: loader, pace: { .full })
        let named = try await pass.stale(in: conversation("m2"))
        XCTAssertEqual(named, [id("m2")])
        let fresh = try await loader.prepareStored(id("m2"))
        XCTAssertTrue(fresh)
        let none = try await pass.stale(in: conversation("m2"))
        XCTAssertEqual(none, [])
    }

    /// The live source: an open reads what is prepared and never calls the preparer; it prepares
    /// on open only when nothing current is there. Also measures open → text readable, p50/p95.
    func testOpeningReadsPreparedOutputAndMeasuresTheOpen() async throws {
        let messages = (1...24).map { Self.html("m\($0)", date: Int64($0) * 1000) }
        let (stores, _, _) = try await stored(messages)
        let intent = try await Task.detached { try MailIntentStore(directories: stores.directories) }.value
        let source = MailLiveSource(stores: stores, access: Access(), api: MailCloudPullTests.Gmail())
        try await source.prepareActions(intent: intent)

        func percentile(_ values: [Double], _ p: Double) -> Double { let s = values.sorted(); return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))] }
        func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
        /// Open → the reader has the body and its styled blocks (the conversation read, the body
        /// read and decode, styling off the main thread; not SwiftUI layout). `styling` is that
        /// styling's own cost, which no longer runs on the main thread.
        func open(_ m: String) async -> (total: Double, styling: Double) {
            let start = ContinuousClock.now
            let reader = MailReaderModel(id: conversation(m), source: source)
            while ContinuousClock.now - start < .seconds(10) {
                if let body = reader.bodies[id(m)], body != .notOnDevice, reader.styled[id(m)] != nil { break }
                if reader.conversation != nil { reader.revealBody(id(m)) }
                try? await Task.sleep(for: .milliseconds(1))
            }
            let total = ms(start.duration(to: .now))
            var styling = 0.0
            if let body = reader.bodies[id(m)] {
                let s0 = ContinuousClock.now
                _ = MailAttributedText.blocks(body)
                styling = ms(s0.duration(to: .now))
            }
            return (total, styling)
        }

        /// As it was: the body read, then styled on the main thread when the card is drawn.
        func openStyledOnMain(_ m: String) async -> (total: Double, main: Double) {
            let start = ContinuousClock.now
            let observation = source.observeConversation(conversation(m)) { _ in }
            defer { observation.cancel() }
            var body = await source.body(id(m))
            while body == .notOnDevice, ContinuousClock.now - start < .seconds(10) {
                try? await Task.sleep(for: .milliseconds(1)); body = await source.body(id(m))
            }
            let s0 = ContinuousClock.now
            _ = MailAttributedText.blocks(body)
            return (ms(start.duration(to: .now)), ms(s0.duration(to: .now)))
        }

        // Prepared ahead: no preparation on open at all.
        source.setVisible(true)
        var oldTotal: [Double] = [], oldMain: [Double] = []
        for n in 1...12 { let r = await openStyledOnMain("m\(n)"); oldTotal.append(r.total); oldMain.append(r.main) }
        var prepared: [Double] = [], styling: [Double] = []
        for n in 1...12 { let r = await open("m\(n)"); prepared.append(r.total); styling.append(r.styling) }
        var counts = await source.preparationCounts()
        XCTAssertEqual(counts.onRequest, 0, "an open with a prepared body never calls the preparer")

        // A preparer change with no walk (as before this change): each open prepares on request.
        // Timed on the path an open's body request takes (`GmailConversationLoader.body`), then
        // the reader's read and styling. Counted: every one is a preparation on request.
        source.setVisible(false)
        try await bumpVersion(stores)
        let staleNow = try await current(stores, "m1")
        XCTAssertFalse(staleNow, "the change made m1 stale")
        let shownStale = await source.body(id("m1"))
        XCTAssertEqual(shownStale, .notOnDevice, "a stale prepared body is not shown")
        let unwalked = GmailConversationLoader(stores: stores, writer: MailWriter(stores: stores, sink: nil), api: MailCloudPullTests.Gmail(), token: { _ in "fixture" })
        var stale: [Double] = []
        for n in 1...12 {
            let start = ContinuousClock.now
            try await unwalked.body(id("m\(n)"))
            let body = await source.body(id("m\(n)"))
            _ = MailAttributedText.blocks(body)
            stale.append(ms(start.duration(to: .now)))
        }
        let onOpen = await unwalked.preparedOnRequest
        XCTAssertEqual(onOpen, 12, "without the walk, every stale open prepared on request")

        // With the walk: a preparer change is made good newest first while Mail is open.
        try await bumpVersion(stores)
        let aheadBefore = await source.preparationCounts().ahead
        source.setVisible(true)
        // After the walk: every body current again; opens prepare nothing.
        let walkStart = ContinuousClock.now
        while ContinuousClock.now - walkStart < .seconds(60) {
            var all = true
            for n in 13...24 { if try await !current(stores, "m\(n)") { all = false } }
            if all { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let walkEnd = ContinuousClock.now
        let walkedDuring = await source.preparationCounts().ahead - aheadBefore
        let before = await source.preparationCounts().onRequest
        var rewalked: [Double] = []
        for n in 13...24 { rewalked.append(await open("m\(n)").total) }
        let after = await source.preparationCounts().onRequest
        source.setVisible(false)
        XCTAssertEqual(after, before, "after the walk, opens prepare nothing")

        let fmt = { (v: Double) in String(format: "%.1f", v) }
        let report = "STYLED_ON_MAIN_BEFORE_MS p50=\(fmt(percentile(oldTotal, 0.5))) p95=\(fmt(percentile(oldTotal, 0.95))) main_thread_styling_p50=\(fmt(percentile(oldMain, 0.5))) p95=\(fmt(percentile(oldMain, 0.95))) | MAIL_OPEN_PREPARED_MS p50=\(fmt(percentile(prepared, 0.5))) p95=\(fmt(percentile(prepared, 0.95))) styling_off_main_p50=\(fmt(percentile(styling, 0.5))) styling_off_main_p95=\(fmt(percentile(styling, 0.95))) | STALE_PREPARE_ON_OPEN_MS p50=\(fmt(percentile(stale, 0.5))) p95=\(fmt(percentile(stale, 0.95))) prepared_on_request=\(onOpen)/12 | WALK prepared=\(walkedDuring) walk_ms=\(fmt(ms(walkStart.duration(to: walkEnd)))) | AFTER_WALK_MS p50=\(fmt(percentile(rewalked, 0.5))) p95=\(fmt(percentile(rewalked, 0.95)))"
        print(report)
        let attachment = XCTAttachment(string: report); attachment.name = "open-prepared"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertGreaterThanOrEqual(walkedDuring, 12, "the walk re-prepared the newest twelve first (and goes on to the rest)")
        XCTAssertLessThan(percentile(prepared, 0.5), percentile(stale, 0.5), report)
    }
}
