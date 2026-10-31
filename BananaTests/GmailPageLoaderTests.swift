import XCTest
import GRDB

final class GmailPageLoaderTests: XCTestCase {
    actor Provider: GmailAPI {
        let count: Int, failID: String?, account: String
        var active = 0, maximumActive = 0, requested = 0
        init(count: Int = 53, failID: String? = nil, account: String = "a@example.com") {
            self.count = count; self.failID = failID; self.account = account
        }
        func profile(token: String) async throws -> GmailProfile { GmailProfile(emailAddress: account, messagesTotal: count, historyId: 100) }
        func labels(token: String) async throws -> [GmailLabel] { [] }
        func listMessages(token: String, labelIDs: [String], query: String?, includeSpamTrash: Bool, pageToken: String?, maxResults: Int) async throws -> GmailIDPage {
            let start = pageToken == nil ? 0 : 50
            let end = min(count, start + maxResults)
            let refs = (start..<end).map { GmailMessageRef(id: "m\($0)", threadId: "t\($0)") }
            return GmailIDPage(messages: refs, nextPageToken: end < count ? "next" : nil)
        }
        func message(token: String, id: String, format: GmailFormat) async throws -> GmailMessage {
            active += 1; maximumActive = max(active, maximumActive); requested += 1
            defer { active -= 1 }
            try await Task.sleep(nanoseconds: 1_000_000)
            if id == failID { throw GmailError.server(503) }
            let n = Int(id.dropFirst())!
            return GmailMessage(id: id, threadId: "t\(n)", labelIds: ["INBOX"], historyId: 100,
                internalDate: Int64(1000 + n), payload: GmailPart(headers: [
                    GmailHeader(name: "Subject", value: "Subject \(n)"),
                    GmailHeader(name: "From", value: "sender@example.com")]))
        }
        func history(token: String, start: String, pageToken: String?, maxResults: Int) async throws -> GmailHistoryPage { throw GmailError.malformed }
        func thread(token: String, id: String, format: GmailFormat) async throws -> GmailThread { throw GmailError.malformed }
        func attachment(token: String, messageID: String, attachmentID: String) async throws -> GmailPartBody { throw GmailError.malformed }
        func modify(token: String, id: String, add: [String], remove: [String]) async throws { throw GmailError.malformed }
        func trash(token: String, id: String) async throws { throw GmailError.malformed }
        func untrash(token: String, id: String) async throws { throw GmailError.malformed }
    }
    private func stores() async throws -> MailStores {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-page-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try await Task.detached { try MailStores.open(MailDirectories(root: root), migrations: MailSlices.migrations()) }.value
    }
    func testPagesImportAllRowsWithBoundedRequestsAndNoFalseCheckpoint() async throws {
        let stores = try await stores(), api = Provider()
        let loader = GmailPageLoader(api: api, writer: MailWriter(stores: stores, sink: nil), token: { _ in "fixture" })
        let first = try await loader.load(GmailPageScope(account: "A@EXAMPLE.COM"))
        XCTAssertEqual(first.messages, 50)
        let second = try await loader.load(GmailPageScope(account: "a@example.com"), after: try XCTUnwrap(first.next))
        XCTAssertEqual(second.messages, 3)
        XCTAssertNil(second.next)
        let rows = try await MailIndexReader(stores: stores).page(PageRequest(view: .unified(.inbox), account: nil, filters: [], before: nil, limit: 100))
        XCTAssertEqual(rows.count, 53)
        XCTAssertEqual(rows.first?.subject, "Subject 52")
        let maximum = await api.maximumActive
        XCTAssertLessThanOrEqual(maximum, 4)
        let checkpoint = try await stores.index.read { try String.fetchOne($0, sql: "SELECT checkpoint FROM account") }
        XCTAssertNil(checkpoint)
    }
    func testProviderFailureDoesNotAcknowledgePageOrImportPartialFetch() async throws {
        let stores = try await stores(), api = Provider(failID: "m5")
        let loader = GmailPageLoader(api: api, writer: MailWriter(stores: stores, sink: nil), token: { _ in "fixture" })
        do { _ = try await loader.load(GmailPageScope(account: "a@example.com")); XCTFail() }
        catch { XCTAssertEqual(error as? GmailError, .server(503)) }
        let count = try await stores.index.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM message") }
        XCTAssertEqual(count, 0)
    }
    func testWrongAccountAndScopeCursorNeverWrite() async throws {
        let stores = try await stores(), api = Provider(account: "other@example.com")
        let loader = GmailPageLoader(api: api, writer: MailWriter(stores: stores, sink: nil), token: { _ in "fixture" })
        do { _ = try await loader.load(GmailPageScope(account: "a@example.com")); XCTFail() }
        catch GmailPageLoader.Failure.wrongAccount {}
        let cursor = GmailPageCursor(scope: GmailPageScope(account: "a@example.com", query: "old"), token: "next", historyFloor: 100)
        do { _ = try await loader.load(GmailPageScope(account: "a@example.com", query: "new"), after: cursor); XCTFail() }
        catch GmailPageLoader.Failure.invalidCursor {}
        let requests = await api.requested
        XCTAssertEqual(requests, 0)
    }
    func testCancellationBeforeRequestLeavesDiskUntouched() async throws {
        let stores = try await stores(), api = Provider()
        let loader = GmailPageLoader(api: api, writer: MailWriter(stores: stores, sink: nil), token: { _ in "fixture" })
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await loader.load(GmailPageScope(account: "a@example.com"))
        }
        do { _ = try await task.value; XCTFail() } catch is CancellationError {}
        let count = try await stores.index.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM account") }
        XCTAssertEqual(count, 0)
    }
    func testTransactionFailureDoesNotNotifyObserver() async throws {
        final class Sink: MailChangeSink, @unchecked Sendable {
            let lock = NSLock(); var count = 0
            func committed(_ change: MailStoreChange) { lock.lock(); count += 1; lock.unlock() }
            func read() -> Int { lock.lock(); defer { lock.unlock() }; return count }
        }
        enum Injected: Error { case failed }
        let stores = try await stores(), sink = Sink()
        let writer = MailWriter(stores: stores, sink: sink)
        do {
            _ = try await writer.transact { db in
                try db.execute(sql: "INSERT INTO account(email) VALUES ('a@example.com')")
                throw Injected.failed
            }
            XCTFail()
        } catch Injected.failed {}
        XCTAssertEqual(sink.read(), 0)
        _ = try await writer.transact { db in
            try db.execute(sql: "INSERT INTO account(email) VALUES ('a@example.com')")
            return MailStoreChange()
        }
        XCTAssertEqual(sink.read(), 1)
    }
}
