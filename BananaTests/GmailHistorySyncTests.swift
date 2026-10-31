import XCTest
import GRDB

final class GmailHistorySyncTests: XCTestCase {
    actor Provider: GmailAPI {
        let account: String
        let replies: [Result<GmailHistoryPage, GmailError>]
        var requests: [(String, String?)] = []
        init(_ replies: [Result<GmailHistoryPage, GmailError>], account: String = "a@example.com") {
            self.replies = replies; self.account = account
        }
        func profile(token: String) async throws -> GmailProfile { GmailProfile(emailAddress: account, historyId: 10) }
        func history(token: String, start: String, pageToken: String?, maxResults: Int) async throws -> GmailHistoryPage {
            XCTAssertEqual(maxResults, 100)
            let index = requests.count; requests.append((start, pageToken))
            guard replies.indices.contains(index) else { throw GmailError.malformed }
            return try replies[index].get()
        }
        func labels(token: String) async throws -> [GmailLabel] { throw GmailError.malformed }
        func listMessages(token: String, labelIDs: [String], query: String?, includeSpamTrash: Bool, pageToken: String?, maxResults: Int) async throws -> GmailIDPage { throw GmailError.malformed }
        func message(token: String, id: String, format: GmailFormat) async throws -> GmailMessage { throw GmailError.malformed }
        func thread(token: String, id: String, format: GmailFormat) async throws -> GmailThread { throw GmailError.malformed }
        func attachment(token: String, messageID: String, attachmentID: String) async throws -> GmailPartBody { throw GmailError.malformed }
        func modify(token: String, id: String, add: [String], remove: [String]) async throws { XCTFail("History must never mutate Gmail"); throw GmailError.malformed }
        func trash(token: String, id: String) async throws { XCTFail("History must never mutate Gmail"); throw GmailError.malformed }
        func untrash(token: String, id: String) async throws { XCTFail("History must never mutate Gmail"); throw GmailError.malformed }
    }
    private func stores(checkpoint: String? = "1") async throws -> MailStores {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("history-sync-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let stores = try await Task.detached { try MailStores.open(MailDirectories(root: root), migrations: MailSlices.migrations()) }.value
        try await stores.index.write { try $0.execute(sql: "INSERT INTO account(email,checkpoint,last_sync_at) VALUES('a@example.com',?,100)", arguments: [checkpoint]) }
        return stores
    }
    private func worker(_ stores: MailStores, _ api: Provider,
                        committed: @escaping GmailHistorySync.Committed = { _, _ in }) -> GmailHistorySync {
        GmailHistorySync(stores: stores, writer: MailWriter(stores: stores, sink: nil), api: api,
            token: { _ in "fixture" }, recover: { _ in }, committed: committed)
    }
    private func checkpoint(_ stores: MailStores) async throws -> String? {
        try await stores.index.read { try String.fetchOne($0, sql: "SELECT checkpoint FROM account") }
    }
    private var first: GmailHistoryPage {
        GmailHistoryPage(history: [GmailHistoryRecord(id: 2, messagesAdded: [GmailHistoryChange(message: GmailMessage(id: "m", threadId: "t"))])], nextPageToken: "next", historyId: 10)
    }

    func testPaginationKeepsRequestFloorAndCommitsEmptyFinalPosition() async throws {
        let stores = try await stores(), api = Provider([.success(first), .success(GmailHistoryPage(historyId: 10))])
        let result = try await worker(stores, api).poll(account: "a@example.com", nowMS: 101)
        XCTAssertEqual(result, .current(checkpoint: 10, committedPages: 2, hasMore: false))
        let requests = await api.requests
        XCTAssertEqual(requests.map { $0.0 }, ["1", "1"])
        XCTAssertEqual(requests.map { $0.1 }, [nil, "next"])
        let saved = try await checkpoint(stores); XCTAssertEqual(saved, "10")
    }

    func testFailedSecondPageRestartsFromFirstCommittedCheckpoint() async throws {
        let stores = try await stores(), api = Provider([.success(first), .failure(.server(503))])
        do { _ = try await worker(stores, api).poll(account: "a@example.com", nowMS: 101); XCTFail() }
        catch { XCTAssertEqual(error as? GmailError, .server(503)) }
        let saved = try await checkpoint(stores); XCTAssertEqual(saved, "2")
        let resumed = Provider([.success(GmailHistoryPage(historyId: 10))])
        _ = try await worker(stores, resumed).poll(account: "a@example.com", nowMS: 3_600_102)
        let requests = await resumed.requests; XCTAssertEqual(requests.first?.0, "2")
        let end = try await checkpoint(stores); XCTAssertEqual(end, "10")
    }

    func testExpiredCheckpointRequestsReconciliationButOtherFailuresPreserveIt() async throws {
        for failure in [GmailError.notFound, .unexplained(404), .server(503)] {
            let stores = try await stores(), api = Provider([.failure(failure)])
            do {
                let result = try await worker(stores, api).poll(account: "a@example.com", nowMS: 101)
                XCTAssertEqual(failure, .notFound); XCTAssertEqual(result, .needsReconcile)
            } catch { XCTAssertEqual(error as? GmailError, failure); XCTAssertNotEqual(failure, .notFound) }
            let saved = try await checkpoint(stores); XCTAssertEqual(saved, failure == .notFound ? nil : "1")
        }
    }

    func testWrongAccountAndMissingCheckpointNeverReadHistory() async throws {
        let stores = try await stores(), wrong = Provider([], account: "other@example.com")
        do { _ = try await worker(stores, wrong).poll(account: "a@example.com", nowMS: 101); XCTFail() }
        catch { XCTAssertTrue(error is GmailHistorySync.Failure) }
        let wrongRequests = await wrong.requests; XCTAssertTrue(wrongRequests.isEmpty)
        let empty = try await self.stores(checkpoint: nil), valid = Provider([])
        let result = try await worker(empty, valid).poll(account: "a@example.com", nowMS: 101)
        XCTAssertEqual(result, .needsReconcile)
        let validRequests = await valid.requests; XCTAssertTrue(validRequests.isEmpty)
    }

    func testPageLimitYieldsWithDurableContinuation() async throws {
        let stores = try await stores(), api = Provider([.success(first)])
        let result = try await worker(stores, api).poll(account: "a@example.com", nowMS: 101, maximumPages: 1)
        XCTAssertEqual(result, .current(checkpoint: 2, committedPages: 1, hasMore: true))
        let saved = try await checkpoint(stores); XCTAssertEqual(saved, "2")
    }

    func testPostCommitFailureLeavesStubAndCheckpointForRecovery() async throws {
        let stores = try await stores(), api = Provider([.success(first)])
        enum Injected: Error { case failure }
        do {
            _ = try await worker(stores, api, committed: { _, _ in throw Injected.failure }).poll(account: "a@example.com", nowMS: 101)
            XCTFail()
        } catch { XCTAssertTrue(error is Injected) }
        let saved = try await checkpoint(stores); XCTAssertEqual(saved, "2")
        let stubs = try await stores.index.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM message WHERE fetch_state=0") }
        XCTAssertEqual(stubs, 1)
    }
}
