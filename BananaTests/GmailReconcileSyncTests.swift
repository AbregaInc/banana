import XCTest
import GRDB

final class GmailReconcileSyncTests: XCTestCase {
    actor Provider: GmailAPI {
        let stores: MailStores
        let account: String
        var replies: [Result<GmailIDPage, GmailError>]
        var requests: [String?] = []
        init(stores: MailStores, replies: [Result<GmailIDPage, GmailError>] = [], account: String = "a@example.com") {
            self.stores = stores; self.replies = replies; self.account = account
        }
        func profile(token: String) async throws -> GmailProfile { GmailProfile(emailAddress: account, historyId: 10) }
        func labels(token: String) async throws -> [GmailLabel] {
            ["INBOX", "SENT", "DRAFT", "TRASH", "SPAM", "UNREAD", "STARRED"].map { GmailLabel(id: $0, name: $0, type: "system") }
        }
        func listMessages(token: String, labelIDs: [String], query: String?, includeSpamTrash: Bool, pageToken: String?, maxResults: Int) async throws -> GmailIDPage {
            let checkpoint = try await stores.index.read { try String.fetchOne($0, sql: "SELECT checkpoint FROM account WHERE email='a@example.com'") }
            XCTAssertEqual(checkpoint, "10", "Handshake must commit before the first request")
            XCTAssertEqual(maxResults, 100); XCTAssertTrue(includeSpamTrash); XCTAssertNil(query)
            requests.append(pageToken)
            return try replies.isEmpty ? GmailIDPage() : replies.removeFirst().get()
        }
        func history(token: String, start: String, pageToken: String?, maxResults: Int) async throws -> GmailHistoryPage { throw GmailError.malformed }
        func message(token: String, id: String, format: GmailFormat) async throws -> GmailMessage { throw GmailError.malformed }
        func thread(token: String, id: String, format: GmailFormat) async throws -> GmailThread { throw GmailError.malformed }
        func attachment(token: String, messageID: String, attachmentID: String) async throws -> GmailPartBody { throw GmailError.malformed }
        func modify(token: String, id: String, add: [String], remove: [String]) async throws { XCTFail("Enumeration must not mutate Gmail"); throw GmailError.malformed }
        func trash(token: String, id: String) async throws { XCTFail("Enumeration must not mutate Gmail"); throw GmailError.malformed }
        func untrash(token: String, id: String) async throws { XCTFail("Enumeration must not mutate Gmail"); throw GmailError.malformed }
    }
    private func stores() async throws -> MailStores {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reconcile-sync-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try await Task.detached { try MailStores.open(MailDirectories(root: root), migrations: MailSlices.migrations()) }.value
    }
    private func worker(_ stores: MailStores, _ api: Provider) -> GmailReconcileSync {
        GmailReconcileSync(stores: stores, writer: MailWriter(stores: stores, sink: nil), api: api, token: { _ in "fixture" })
    }
    func testHandshakeThenEveryListingStopsAtVerification() async throws {
        let stores = try await stores(), api = Provider(stores: stores)
        let result = try await worker(stores, api).enumerate(account: "a@example.com", nowMS: 1)
        guard case .needsVerification(let state) = result else { return XCTFail("Did not complete all listings") }
        XCTAssertEqual(state.phase, .verifying)
        let requests = await api.requests
        XCTAssertEqual(requests.count, 8)
        let saved = try await stores.index.read { try MailReconcileIndex.state(account: "a@example.com", in: $0) }
        XCTAssertEqual(saved, state)
    }
    func testPageFailureResumesDurableCursorOnNewWorker() async throws {
        let stores = try await stores()
        let api = Provider(stores: stores, replies: [
            .success(GmailIDPage(messages: [GmailMessageRef(id: "m", threadId: "t")], nextPageToken: "p2")),
            .failure(.server(503)), .success(GmailIDPage())])
        do { _ = try await worker(stores, api).enumerate(account: "a@example.com", nowMS: 1); XCTFail() }
        catch { XCTAssertEqual(error as? GmailError, .server(503)) }
        let saved = try await stores.index.read { try MailReconcileIndex.state(account: "a@example.com", in: $0) }
        XCTAssertEqual(saved?.pageToken, "p2")
        let resumed = try await worker(stores, api).enumerate(account: "a@example.com", nowMS: 2, maximumSteps: 1)
        guard case .more(let state) = resumed else { return XCTFail() }
        XCTAssertEqual(state.listing, 1); XCTAssertNil(state.pageToken)
        let requests = await api.requests
        XCTAssertEqual(requests, [nil, "p2", "p2"])
    }
    func testRejectedContinuationRestartsOnlyListingAndPreservesEvidence() async throws {
        let stores = try await stores()
        let api = Provider(stores: stores, replies: [
            .success(GmailIDPage(messages: [GmailMessageRef(id: "m", threadId: "t")], nextPageToken: "expired")),
            .failure(.refused(.invalidArgument)), .success(GmailIDPage())])
        let first = try await worker(stores, api).enumerate(account: "a@example.com", nowMS: 1, maximumSteps: 1)
        guard case .more(let original) = first else { return XCTFail() }
        try await stores.index.write { db in
            try db.execute(sql: "INSERT INTO enum_mark(account_pk,generation,label_pk,msg_pk) SELECT account_pk,?,0,msg_pk FROM message", arguments: [original.generation])
        }
        let restarted = try await worker(stores, api).enumerate(account: "a@example.com", nowMS: 2)
        guard case .more(let repaired) = restarted else { return XCTFail() }
        var expected = original; expected.pageToken = nil
        XCTAssertEqual(repaired, expected)
        let evidence = try await stores.index.read { db in
            (try Int.fetchOne(db, sql: "SELECT count(*) FROM enum_mark"),
             try Int.fetchOne(db, sql: "SELECT count(*) FROM message"),
             try String.fetchOne(db, sql: "SELECT checkpoint FROM account WHERE email='a@example.com'"))
        }
        XCTAssertEqual(evidence.0, 1); XCTAssertEqual(evidence.1, 1); XCTAssertEqual(evidence.2, "10")
        let resumed = try await worker(stores, api).enumerate(account: "a@example.com", nowMS: 3, maximumSteps: 1)
        guard case .more(let next) = resumed else { return XCTFail() }
        XCTAssertEqual(next.listing, original.listing + 1)
        let requests = await api.requests
        XCTAssertEqual(requests, [nil, "expired", nil])
    }

    func testRejectedFirstPagePropagatesWithoutRestartLoop() async throws {
        let stores = try await stores()
        let api = Provider(stores: stores, replies: [.failure(.refused(.invalidArgument))])
        do { _ = try await worker(stores, api).enumerate(account: "a@example.com", nowMS: 1); XCTFail() }
        catch { XCTAssertEqual(error as? GmailError, .refused(.invalidArgument)) }
        let requests = await api.requests
        XCTAssertEqual(requests.count, 1)
        let saved = try await stores.index.read { try MailReconcileIndex.state(account: "a@example.com", in: $0) }
        XCTAssertEqual(saved?.listing, 0)
        XCTAssertNil(saved?.pageToken)
    }

    func testWrongAccountNeverStartsEnumeration() async throws {
        let stores = try await stores(), api = Provider(stores: stores, account: "other@example.com")
        do { _ = try await worker(stores, api).enumerate(account: "a@example.com", nowMS: 1); XCTFail() }
        catch { XCTAssertTrue(error is GmailReconcileSync.Failure) }
        let requests = await api.requests
        XCTAssertTrue(requests.isEmpty)
        let saved = try await stores.index.read { try MailReconcileIndex.state(account: "a@example.com", in: $0) }
        XCTAssertNil(saved)
    }
}
