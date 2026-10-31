import XCTest
import GRDB

final class GmailVerificationSyncTests: XCTestCase {
    actor Provider: GmailAPI {
        let response: Result<GmailMessage, GmailError>
        let account: String
        var reads = 0
        init(_ response: Result<GmailMessage, GmailError>, account: String = "a@example.com") {
            self.response = response; self.account = account
        }
        func profile(token: String) async throws -> GmailProfile { GmailProfile(emailAddress: account, historyId: 10) }
        func message(token: String, id: String, format: GmailFormat) async throws -> GmailMessage {
            reads += 1; XCTAssertEqual(id, "m"); XCTAssertEqual(format, .minimal)
            return try response.get()
        }
        func labels(token: String) async throws -> [GmailLabel] { throw GmailError.malformed }
        func listMessages(token: String, labelIDs: [String], query: String?, includeSpamTrash: Bool, pageToken: String?, maxResults: Int) async throws -> GmailIDPage { throw GmailError.malformed }
        func history(token: String, start: String, pageToken: String?, maxResults: Int) async throws -> GmailHistoryPage { throw GmailError.malformed }
        func thread(token: String, id: String, format: GmailFormat) async throws -> GmailThread { throw GmailError.malformed }
        func attachment(token: String, messageID: String, attachmentID: String) async throws -> GmailPartBody { throw GmailError.malformed }
        func modify(token: String, id: String, add: [String], remove: [String]) async throws { XCTFail("Verification must not mutate Gmail"); throw GmailError.malformed }
        func trash(token: String, id: String) async throws { XCTFail("Verification must not mutate Gmail"); throw GmailError.malformed }
        func untrash(token: String, id: String) async throws { XCTFail("Verification must not mutate Gmail"); throw GmailError.malformed }
    }
    private func setup() async throws -> MailStores {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("verify-sync-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let stores = try await Task.detached { try MailStores.open(MailDirectories(root: root), migrations: MailSlices.migrations()) }.value
        let state = MailReconcileIndex.State(generation: 1, labels: [], maxPKAtStart: 1, startedAt: 10, phase: .verifying)
        let raw = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        try await stores.index.write { db in
            try db.execute(sql: "INSERT INTO account(account_pk,email,checkpoint,enum_generation,enum_state) VALUES(1,'a@example.com','10',1,?)", arguments: [raw])
            try db.execute(sql: "INSERT INTO thread(thread_pk,account_pk,gmail_id,tie) VALUES(1,1,'t',1)")
            try db.execute(sql: "INSERT INTO message(msg_pk,account_pk,gmail_id,thread_pk,history_id) VALUES(1,1,'m',1,'1')")
            try db.execute(sql: "INSERT INTO verify_queue(msg_pk,reason,generation,queued_at) VALUES(1,1,1,0)")
        }
        return stores
    }
    private func worker(_ stores: MailStores, _ api: Provider, committed: @escaping GmailVerificationSync.Committed = { _, _ in }) -> GmailVerificationSync {
        GmailVerificationSync(stores: stores, writer: MailWriter(stores: stores, sink: nil), api: api,
            token: { _ in "fixture" }, recover: { _ in }, committed: committed)
    }
    func testOnlyStructuredNotFoundCanRemoveMessage() async throws {
        for failure in [GmailError.notFound, .unexplained(404), .server(503), .unauthorized, .malformed] {
            let stores = try await setup(), api = Provider(.failure(failure))
            do {
                let result = try await worker(stores, api).verify(account: "a@example.com", nowMS: 2)
                XCTAssertEqual(failure, .notFound); XCTAssertEqual(result, .finished)
            } catch { XCTAssertEqual(error as? GmailError, failure); XCTAssertNotEqual(failure, .notFound) }
            let count = try await stores.index.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM message") }
            XCTAssertEqual(count, failure == .notFound ? 0 : 1)
            let pending = try await stores.index.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM verify_queue WHERE outcome IS NULL") }
            XCTAssertEqual(pending, failure == .notFound ? 0 : 1)
        }
    }
    func testPositiveReadKeepsMessageAndCompletesVerification() async throws {
        let stores = try await setup(), api = Provider(.success(GmailMessage(id: "m", threadId: "t", labelIds: [], historyId: 10)))
        let result = try await worker(stores, api).verify(account: "a@example.com", nowMS: 2)
        XCTAssertEqual(result, .finished)
        let count = try await stores.index.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM message") }
        XCTAssertEqual(count, 1)
    }
    func testWrongAccountNeverVerifiesOrRemoves() async throws {
        let stores = try await setup(), api = Provider(.failure(.notFound), account: "other@example.com")
        do { _ = try await worker(stores, api).verify(account: "a@example.com", nowMS: 2); XCTFail() }
        catch { XCTAssertTrue(error is GmailVerificationSync.Failure) }
        let reads = await api.reads
        XCTAssertEqual(reads, 0)
        let count = try await stores.index.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM message") }
        XCTAssertEqual(count, 1)
    }
    func testPostCommitFailurePreservesTombstoneForRecovery() async throws {
        let stores = try await setup(), api = Provider(.failure(.notFound))
        enum Injected: Error { case failure }
        do {
            _ = try await worker(stores, api, committed: { _, result in
                if !result.deleted.isEmpty { throw Injected.failure }
            }).verify(account: "a@example.com", nowMS: 2)
            XCTFail()
        } catch { XCTAssertTrue(error is Injected) }
        let tombstones = try await stores.index.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM tombstone") }
        XCTAssertEqual(tombstones, 1)
        let resumed = try await worker(stores, api).verify(account: "a@example.com", nowMS: 3)
        XCTAssertEqual(resumed, .finished)
        let reads = await api.reads
        XCTAssertEqual(reads, 1)
    }
}
