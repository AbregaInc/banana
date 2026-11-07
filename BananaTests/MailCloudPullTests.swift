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
        var held: [String: GmailMessage] = [:]
        var asked: [[String]] = []
        var failure: Error?
        var latency: Duration = .zero
        func set(_ entries: [Entry]) { self.entries = entries }
        func hold(_ messages: [GmailMessage]) { for m in messages { held[m.id!] = m } }
        func fail(_ error: Error?) { failure = error }
        func slow(_ value: Duration) { latency = value }
        func page(account: String, after: String?, limit: Int, fresh: Bool) async throws -> MailCloudFeedPage {
            if latency > .zero { try await Task.sleep(for: latency) }
            let start = after.flatMap(Int.init) ?? 0
            let slice = Array(entries[min(start, entries.count)..<min(start + limit, entries.count)])
            return MailCloudFeedPage(epoch: "e1", cursor: String(start + slice.count), more: start + slice.count < entries.count,
                                     complete: true, entries: slice)
        }
        func check(account: String, ids: [String]) async throws {}
        func contents(account: String, ids: [String]) async throws -> [MailCloudContent] {
            if latency > .zero { try await Task.sleep(for: latency) }
            if let failure { throw failure }
            asked.append(ids)
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

    final class Clock: @unchecked Sendable { var now: Int64 = 1_000_000 }

    private func stores() async throws -> MailStores {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-pull-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try await Task.detached { try MailStores.open(MailDirectories(root: root), migrations: MailSlices.migrations()) }.value
    }
    private func entry(_ id: String, date: Int64, content: Bool = true, thread: String? = nil) -> Entry {
        Entry(id: id, thread: thread ?? "t-" + id, history: "100", date: date, labels: ["INBOX"], deleted: nil, content: content)
    }

    /// The feed applied (as a sync pass does), and a pull over it.
    private func setup(_ cloud: Cloud, gmail: Gmail = Gmail(), clock: Clock = Clock()) async throws -> (MailStores, MailCloudPull) {
        let stores = try await stores()
        let writer = MailWriter(stores: stores, sink: nil)
        let feed = MailCloudFeedSync(stores: stores, writer: writer, source: cloud, recover: { _ in })
        var progress = try await feed.pass(account: Self.account, nowMS: 1)
        while progress?.hasMore == true { progress = try await feed.pass(account: Self.account, nowMS: 1) }
        let loader = GmailConversationLoader(stores: stores, writer: writer, api: gmail, token: { _ in "fixture" })
        return (stores, MailCloudPull(stores: stores, loader: loader, source: cloud, clock: { clock.now }))
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

        // Before: no cloud content; the rows are known (as the feed or a listing leaves them) and
        // opening reads the conversation and its body from Gmail.
        let gmail = MailCloudPullTests.Gmail()
        await gmail.hold(messages); await gmail.slow(latency)
        let (beforeStores, before) = try await source(cloud: nil, gmail: gmail)
        _ = try await MailWriter(stores: beforeStores, sink: nil).transact { db in
            var change = MailStoreChange()
            for m in messages {
                change.formUnion(try MailMessageImporter.apply(FetchedMessage(wire: GmailMessage(id: m.id, threadId: m.threadId, labelIds: ["INBOX"], historyId: 100, internalDate: m.internalDate),
                    floor: 100, headers: MessageHeaders(payload: nil), structure: nil), account: MailCloudPullTests.account, myAddresses: [MailCloudPullTests.account], in: db))
            }
            return change
        }
        before.setVisible(true)
        var beforeMS: [Double] = []
        for m in opened { beforeMS.append(await openToText(before, m)) }
        before.setVisible(false)

        // After: the cloud holds the text; the rows are on screen for a moment before the tap.
        let cloud = MailCloudPullTests.Cloud(), quiet = MailCloudPullTests.Gmail()
        await cloud.set(entries); await cloud.hold(messages); await cloud.slow(latency)
        let (_, after) = try await source(cloud: cloud, gmail: quiet)
        _ = await after.catchUpFromPush(budget: .milliseconds(1))   // the feed only: rows known, no text yet
        let early = await after.body(id("m7"))
        XCTAssertEqual(early, .notOnDevice, "nothing pulled before the row is shown")
        after.setVisible(true)
        after.onScreen(opened.map { MailConversationID(account: MailCloudPullTests.account, thread: "t-" + $0) })
        try await Task.sleep(for: .milliseconds(600))   // the rows on screen for 0.6 s
        for m in opened {
            let here = await after.body(id(m))
            XCTAssertNotEqual(here, .notOnDevice, "\(m)'s text is on the device before it is opened")
        }
        var afterMS: [Double] = []
        for m in opened { afterMS.append(await openToText(after, m)) }
        after.setVisible(false)
        let report = "MAIL_OPEN_TO_TEXT_MS latency=150 before=\(beforeMS.map { String(format: "%.1f", $0) }) median=\(String(format: "%.1f", median(beforeMS))) after=\(afterMS.map { String(format: "%.1f", $0) }) median=\(String(format: "%.1f", median(afterMS)))"
        print(report)
        let attachment = XCTAttachment(string: report); attachment.name = "open-to-text"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertLessThan(median(afterMS) * 3, median(beforeMS), report)
        XCTAssertGreaterThan(median(beforeMS), 300, "a thread read and a body read, each a round trip")
        let gmailCalls = await quiet.calls
        XCTAssertEqual(gmailCalls.filter { $0.hasPrefix("message:") || $0.hasPrefix("thread:") }, [], "no Gmail read of a message or thread on the cloud path")
    }
}
