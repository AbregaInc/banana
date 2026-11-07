import XCTest
import GRDB

/// Search asks the device and Gmail together (MAIL-ENGINE 9.4): the query sent to Gmail, the one
/// list made from both answers, and the live source asking, paging, cancelling and going without.
@MainActor final class MailGmailSearchTests: XCTestCase {

    // MARK: - Gmail's q

    func testTypedTextGoesToGmailAsTypedAndShortTextDoesNotGo() {
        XCTAssertEqual(MailGmailQuery.translate("from:sam has:attachment invoice", filters: []),
                       "from:sam has:attachment invoice")
        XCTAssertNil(MailGmailQuery.translate("a", filters: []))
        XCTAssertNil(MailGmailQuery.translate("   ", filters: []))
        XCTAssertEqual(MailGmailQuery.translate("  budget ", filters: [.unread, .starred, .noReply]),
                       "budget is:unread is:starred")
    }

    func testAStructuredFilterBecomesGmailOperators() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 12)))
        let filter = LiveFilter(scope: "mail", terms: [
            .init(field: "text", op: "contains", value: "quarterly -report (draft) has:attachment 10:30"),
            .init(field: "person", op: "contains", value: "Ana Ruiz"),
            .init(field: "unread", op: "is", value: "true"),
            .init(field: "starred", op: "is", value: "false"),
            .init(field: "date", op: "in", value: "yesterday"),
        ])
        let start = Int64(calendar.date(from: DateComponents(year: 2026, month: 11, day: 6))!.timeIntervalSince1970)
        XCTAssertEqual(MailGmailQuery.translate(filter.searchExpression, filters: [.unread, .important], now: now, calendar: calendar),
                       "quarterly report draft has:attachment \"10:30\" from:\"Ana Ruiz\" is:unread -is:starred after:\(start - 1) before:\(start + 86_400) is:important")
    }

    func testFlagsAloneAndFiltersThatCannotRunAreNotSentToGmail() {
        let flags = LiveFilter(scope: "mail", terms: [.init(field: "unread", op: "is", value: "true")])
        XCTAssertNil(MailGmailQuery.translate(flags.searchExpression, filters: []))
        let broken = LiveFilter(scope: "mail", terms: [.init(field: "kind", op: "is", value: "meeting")])
        XCTAssertNil(MailGmailQuery.translate(broken.searchExpression, filters: []))
    }

    // MARK: - One list from two answers

    private func row(_ thread: String, _ date: Int64, account: String = "a@example.com") -> MailRow {
        MailRow(id: MailConversationID(account: account, thread: thread), key: MailOrderKey(group: 0, sortKey: date, tie: 0),
                date: Date(timeIntervalSince1970: Double(date)), people: [], peopleTotal: 0, messageCount: 1,
                subject: thread, snippet: "", isUnread: false, isStarred: false, isImportant: false,
                hasAttachment: false, isInvitation: false, inInbox: true, isMuted: false, hasPendingChange: false,
                fromGmailSearch: false, labels: [], reason: nil)
    }

    func testMergeIsNewestFirstWithEachConversationOnceAndGmailsOwnRowsMarked() {
        let result = MailSearchMerge.merge(local: [row("l1", 50), row("both", 40)], localMore: false,
            remote: [row("g-new", 60), row("both", 40), row("g-old", 10), row("g-new", 60)],
            gmailMore: false, frontier: nil, limit: 50)
        XCTAssertEqual(result.rows.map(\.id.thread), ["g-new", "l1", "both", "g-old"])
        XCTAssertEqual(result.rows.filter(\.fromGmailSearch).map(\.id.thread), ["g-new", "g-old"])
        XCTAssertEqual(result.added, 2)
        XCTAssertFalse(result.hasMore)
    }

    func testRowsBelowWhatIsKnownWaitAndRowsAlreadyShownStay() {
        // The device has more below its last row: Gmail's older rows wait for its next page.
        var result = MailSearchMerge.merge(local: [row("l1", 50), row("l2", 40)], localMore: true,
            remote: [row("g1", 45), row("g2", 5)], gmailMore: false, frontier: nil, limit: 50)
        XCTAssertEqual(result.rows.map(\.id.thread), ["l1", "g1", "l2"])
        XCTAssertTrue(result.hasMore)
        // Gmail may still add rows below its oldest: the device's older rows wait for them.
        result = MailSearchMerge.merge(local: [row("l1", 50), row("l2", 20)], localMore: false,
            remote: [row("g1", 30)], gmailMore: true, frontier: nil, limit: 50)
        XCTAssertEqual(result.rows.map(\.id.thread), ["l1", "g1"])
        XCTAssertTrue(result.hasMore)
        // ...but a row this search has already shown is never taken away for that.
        result = MailSearchMerge.merge(local: [row("l1", 50), row("l2", 20)], localMore: false,
            remote: [row("g1", 30)], gmailMore: true, frontier: MailOrderKey(group: 0, sortKey: 20, tie: 0), limit: 50)
        XCTAssertEqual(result.rows.map(\.id.thread), ["l1", "g1", "l2"])
        // The limit is the limit.
        result = MailSearchMerge.merge(local: [row("l1", 50), row("l2", 20)], localMore: false,
            remote: [row("g1", 30)], gmailMore: false, frontier: nil, limit: 2)
        XCTAssertEqual(result.rows.map(\.id.thread), ["l1", "g1"])
        XCTAssertTrue(result.hasMore)
    }

    // MARK: - The live source

    private final class Access: MailAccountAccess {
        var connectedAccountIDs = ["a@example.com"]
        func mailGrant(accountID: String) -> MailGrant { .granted }
        func mailAccessToken(accountID: String) async throws -> MailAccessToken {
            MailAccessToken(value: "fixture", scopes: [MailScopes.gmailModify])
        }
        func dropMailAccessToken(accountID: String) {}
        func requestMailAccess(accountID: String) async -> MailAccessOutcome { .granted }
        func forgetMailAccess(accountID: String) async throws {}
        func cancelMailTokenRequests() {}
    }

    /// Gmail with a search: pages of matches by query and page token, and header reads.
    actor Gmail: GmailAPI {
        struct Page { var refs: [(id: String, thread: String)]; var next: String? }
        var pages: [String: [String: Page]] = [:]   // query → page token ("" first) → page
        var dates: [String: Int64] = [:]
        var failure: Error?
        var hold: Set<String> = []
        private(set) var asked: [(query: String, token: String?)] = []
        private(set) var cancelled: [String] = []
        private(set) var reads: [String] = []

        func set(_ query: String, token: String = "", page: Page) { pages[query, default: [:]][token] = page }
        func set(dates: [String: Int64]) { self.dates.merge(dates) { $1 } }
        func fail(_ error: Error?) { failure = error }
        func holding(_ query: String) { hold.insert(query) }

        func profile(token: String) async throws -> GmailProfile { GmailProfile(emailAddress: "a@example.com", messagesTotal: 0, historyId: 100) }
        func labels(token: String) async throws -> [GmailLabel] { [] }
        func listMessages(token: String, labelIDs: [String], query: String?, includeSpamTrash: Bool,
                          pageToken: String?, maxResults: Int) async throws -> GmailIDPage {
            guard let query else { return GmailIDPage(messages: []) }
            asked.append((query, pageToken))
            if hold.contains(query) {
                do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { cancelled.append(query); throw error }
            }
            if let failure { throw failure }
            let page = pages[query]?[pageToken ?? ""] ?? Page(refs: [], next: nil)
            return GmailIDPage(messages: page.refs.map { GmailMessageRef(id: $0.id, threadId: $0.thread) }, nextPageToken: page.next)
        }
        func message(token: String, id: String, format: GmailFormat) async throws -> GmailMessage {
            reads.append(id)
            let thread = "t" + id.dropFirst()
            return GmailMessage(id: id, threadId: thread, labelIds: ["INBOX"], historyId: 100,
                internalDate: dates[id] ?? 1000, payload: GmailPart(headers: [
                    GmailHeader(name: "Subject", value: "Budget from Gmail \(id)"),
                    GmailHeader(name: "From", value: "sender@example.com")]))
        }
        func history(token: String, start: String, pageToken: String?, maxResults: Int) async throws -> GmailHistoryPage { throw GmailError.malformed }
        func thread(token: String, id: String, format: GmailFormat) async throws -> GmailThread { throw GmailError.malformed }
        func attachment(token: String, messageID: String, attachmentID: String) async throws -> GmailPartBody { throw GmailError.malformed }
        func modify(token: String, id: String, add: [String], remove: [String]) async throws { throw GmailError.malformed }
        func trash(token: String, id: String) async throws { throw GmailError.malformed }
        func untrash(token: String, id: String) async throws { throw GmailError.malformed }
    }

    private func source(_ gmail: Gmail, held: [(thread: String, subject: String, date: Int64)]) async throws -> (MailLiveSource, MailStores) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-gmail-search-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let stores = try await Task.detached { try MailStores.open(MailDirectories(root: root), migrations: MailSlices.migrations()) }.value
        _ = try await MailWriter(stores: stores, sink: nil).transact { db in
            for item in held {
                let wire = GmailMessage(id: "m" + item.thread.dropFirst(), threadId: item.thread, labelIds: ["INBOX"], historyId: 1,
                    internalDate: item.date, payload: GmailPart(headers: [GmailHeader(name: "Subject", value: item.subject)]))
                _ = try MailMessageImporter.apply(FetchedMessage(wire: wire, floor: 1, headers: MessageHeaders(payload: wire.payload),
                    structure: nil), account: "a@example.com", myAddresses: ["a@example.com"], in: db)
            }
            return MailStoreChange()
        }
        let source = MailLiveSource(stores: stores, access: Access(), api: gmail)
        source.activate()
        addTeardownBlock { @MainActor in source.setVisible(false) }
        return (source, stores)
    }

    /// Every snapshot of a search until `until` says it is the one.
    private func watch(_ source: MailLiveSource, _ scope: MailScope, limit: Int = 50,
                       until: @escaping (MailListSnapshot) -> Bool) async -> (MailObservation, [MailListSnapshot]) {
        let done = expectation(description: "search reached the expected state")
        var seen: [MailListSnapshot] = []
        var finished = false
        let observation = source.observeList(scope, limit: limit) { snapshot in
            seen.append(snapshot)
            if !finished, until(snapshot) { finished = true; done.fulfill() }
        }
        await fulfillment(of: [done], timeout: 8)
        return (observation, seen)
    }

    func testGmailMatchesJoinTheDevicesNewestFirstOnceEachAfterTheDevicesOwn() async throws {
        let gmail = Gmail()
        await gmail.set("budget", page: Gmail.Page(refs: [("m-new", "t-new"), ("m-both", "t-both"), ("m-old", "t-old")], next: nil))
        await gmail.set(dates: ["m-new": 6000, "m-old": 1000])
        let (source, stores) = try await source(gmail, held: [("t-local", "Budget review", 5000), ("t-both", "Budget plan", 4000)])
        let scope = MailScope(place: .search("budget"))
        let (observation, seen) = await watch(source, scope) { $0.remote == .done(added: 2, more: false) && $0.rows.count == 4 }
        defer { observation.cancel() }

        let first = try XCTUnwrap(seen.first)
        XCTAssertEqual(first.rows.map(\.id.thread), ["t-local", "t-both"], "the device answers first, alone")
        XCTAssertEqual(first.remote, .pending)
        let last = try XCTUnwrap(seen.last)
        XCTAssertEqual(last.rows.map(\.id.thread), ["t-new", "t-local", "t-both", "t-old"])
        XCTAssertEqual(last.rows.filter(\.fromGmailSearch).map(\.id.thread), ["t-new", "t-old"])
        let reads = await gmail.reads
        XCTAssertEqual(Set(reads), ["m-new", "m-old"], "a conversation the device holds is not read again")
        let asked = await gmail.asked
        XCTAssertEqual(asked.map(\.query), ["budget"])
        // The header read is stored: the device's own index finds it from now on.
        let local = try await MailIndexReader(stores: stores).search(MailLocalSearchQuery(text: "budget", account: nil))
        XCTAssertEqual(Set(local.map(\.thread)), ["t-new", "t-local", "t-both", "t-old"])
    }

    func testScrollingOnAsksForGmailsNextPage() async throws {
        let gmail = Gmail()
        await gmail.set("needle", page: Gmail.Page(refs: [("m1", "t1"), ("m2", "t2"), ("m3", "t3")], next: "p2"))
        await gmail.set("needle", token: "p2", page: Gmail.Page(refs: [("m4", "t4"), ("m5", "t5")], next: nil))
        await gmail.set(dates: ["m1": 5000, "m2": 4000, "m3": 3000, "m4": 2000, "m5": 1000])
        let (source, _) = try await source(gmail, held: [])
        let scope = MailScope(place: .search("needle"))
        var (observation, seen) = await watch(source, scope) { $0.remote == .done(added: 3, more: true) }
        XCTAssertEqual(seen.last?.rows.map(\.id.thread), ["t1", "t2", "t3"])
        XCTAssertEqual(seen.last?.hasMore, true)
        observation.cancel()

        // What the list does when it is scrolled to the end of what it has: observe on, and ask.
        let done = expectation(description: "the next page joined")
        var last: MailListSnapshot?
        observation = source.observeList(scope, limit: 50) { snapshot in
            last = snapshot
            if snapshot.remote == .done(added: 5, more: false) { done.fulfill() }
        }
        source.askGmail(scope)
        await fulfillment(of: [done], timeout: 8)
        observation.cancel()
        XCTAssertEqual(last?.rows.map(\.id.thread), ["t1", "t2", "t3", "t4", "t5"])
        XCTAssertEqual(last?.hasMore, false)
        let asked = await gmail.asked
        XCTAssertEqual(asked.map(\.token), [nil, "p2"])
        _ = seen
    }

    func testANewQueryCancelsTheOneItReplaces() async throws {
        let gmail = Gmail()
        await gmail.holding("alpha")
        await gmail.set("beta", page: Gmail.Page(refs: [], next: nil))
        let (source, _) = try await source(gmail, held: [])
        let started = expectation(description: "alpha is asking Gmail")
        var askedAlpha = false
        let alpha = source.observeList(MailScope(place: .search("alpha")), limit: 50) { _ in }
        // Wait until Gmail has been asked about alpha.
        while !askedAlpha {
            try await Task.sleep(nanoseconds: 50_000_000)
            askedAlpha = await gmail.asked.contains { $0.query == "alpha" }
        }
        started.fulfill()
        await fulfillment(of: [started], timeout: 1)
        let (beta, _) = await watch(source, MailScope(place: .search("beta"))) { _ in true }
        alpha.cancel()
        var cancelled: [String] = []
        for _ in 0..<100 where cancelled.isEmpty {
            try await Task.sleep(nanoseconds: 50_000_000)
            cancelled = await gmail.cancelled
        }
        beta.cancel()
        XCTAssertEqual(cancelled, ["alpha"], "the superseded query's request is cancelled")
    }

    func testOfflineTheDeviceAnswersAloneAndSaysGmailWasNotReachedThenRetries() async throws {
        let gmail = Gmail()
        await gmail.fail(URLError(.notConnectedToInternet))
        await gmail.set("budget", page: Gmail.Page(refs: [("m-new", "t-new")], next: nil))
        await gmail.set(dates: ["m-new": 9000])
        let (source, _) = try await source(gmail, held: [("t-local", "Budget review", 5000)])
        let scope = MailScope(place: .search("budget"))
        let (observation, seen) = await watch(source, scope) { $0.remote == .offline }
        XCTAssertEqual(seen.last?.rows.map(\.id.thread), ["t-local"])
        XCTAssertEqual(seen.last?.rows.first?.fromGmailSearch, false)

        await gmail.fail(nil)
        let back = expectation(description: "asked again")
        var last: MailListSnapshot?
        let again = source.observeList(scope, limit: 50) { snapshot in
            last = snapshot
            if snapshot.remote == .done(added: 1, more: false) { back.fulfill() }
        }
        source.askGmail(scope)
        await fulfillment(of: [back], timeout: 8)
        XCTAssertEqual(last?.rows.map(\.id.thread), ["t-new", "t-local"])
        again.cancel(); observation.cancel()
    }

    func testOnlyConnectedAccountsAreAskedAndNothingIsAskedWithoutText() async throws {
        let gmail = Gmail()
        let (source, _) = try await source(gmail, held: [("t-local", "Budget review", 5000)])
        let flagsOnly = LiveFilter(scope: "mail", terms: [.init(field: "unread", op: "is", value: "false")])
        let (observation, seen) = await watch(source, MailScope(place: .search(flagsOnly.searchExpression))) { _ in true }
        observation.cancel()
        XCTAssertNil(seen.last?.remote, "a list of flags alone is the device's")
        let other = MailScope(place: .search("budget"), account: "elsewhere@example.com")
        let (second, more) = await watch(source, other) { _ in true }
        second.cancel()
        XCTAssertNil(more.last?.remote, "an account that is not connected is not asked")
        let asked = await gmail.asked
        XCTAssertTrue(asked.isEmpty)
    }

    // MARK: - Bodies

    func testPreparedBodiesAreIndexedOffTheMainThreadAndFoundByLocalSearch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-body-search-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let stores = try await Task.detached { try MailStores.open(MailDirectories(root: root), migrations: MailSlices.migrations()) }.value
        let writer = MailWriter(stores: stores, sink: nil)
        _ = try await writer.transact { db in
            for (index, subject) in ["Hello", "Weekly notes"].enumerated() {
                let wire = GmailMessage(id: "m\(index)", threadId: "t\(index)", labelIds: ["INBOX"], historyId: 1,
                    internalDate: Int64(1000 + index), payload: GmailPart(headers: [GmailHeader(name: "Subject", value: subject)]))
                _ = try MailMessageImporter.apply(FetchedMessage(wire: wire, floor: 1, headers: MessageHeaders(payload: wire.payload),
                    structure: nil), account: "a@example.com", myAddresses: ["a@example.com"], in: db)
            }
            try db.execute(sql: "UPDATE message SET fetch_state=2,prep_state=2")
            return MailStoreChange()
        }
        try await stores.blobs.write { db in
            for (id, text) in [("m0", "The zeppelin lands at noon."), ("m1", "Nothing to see here.")] {
                try db.execute(sql: "INSERT INTO prepared(account,gmail_id,prep_version,body,text,bytes,made_at) VALUES (?,?,1,?,?,0,0)",
                    arguments: ["a@example.com", id, try MailBlobCodec.encode(Data("{}".utf8)), try MailBlobCodec.encode(Data(text.utf8))])
            }
        }
        let query = MailLocalSearchQuery(text: "zeppel", account: nil)
        var found = try await MailLocalSearch.rows(query, stores: stores)
        XCTAssertTrue(found.rows.isEmpty, "not indexed yet")

        let indexer = MailSearchIndexer(stores: stores) { messages in
            XCTAssertFalse(Thread.isMainThread)
            _ = try await writer.transact { try MailSearchIndexer.mark(messages, in: $0) }
        }
        let taken = try await indexer.indexBatch()
        XCTAssertEqual(taken, 2)
        let again = try await indexer.indexBatch()
        XCTAssertEqual(again, 0, "an indexed message leaves the queue")
        found = try await MailLocalSearch.rows(query, stores: stores)
        XCTAssertEqual(found.rows.map(\.thread), ["t0"])
        // Header words and body words are one search.
        found = try await MailLocalSearch.rows(MailLocalSearchQuery(text: "weekly", account: nil), stores: stores)
        XCTAssertEqual(found.rows.map(\.thread), ["t1"])

        // A message that is not the one indexed under its row never matches that text.
        try await stores.index.write { db in try db.execute(sql: "UPDATE message SET fts_state=0 WHERE gmail_id='m0'") }
        found = try await MailLocalSearch.rows(query, stores: stores)
        XCTAssertTrue(found.rows.isEmpty)
    }
}
