import XCTest
import GRDB

final class GmailMailboxSyncTests: XCTestCase {
    actor Provider: GmailAPI {
        var account = "a@example.com"
        var position: UInt64 = 10
        var operations: [String] = []
        var historyFailure: GmailError?
        var incompleteOnce = false
        func injectIncompleteHistory() { incompleteOnce = true }
        func configure(account: String? = nil, failure: GmailError? = nil) {
            if let account { self.account = account }
            historyFailure = failure
        }
        func profile(token: String) async throws -> GmailProfile { GmailProfile(emailAddress: account, historyId: position) }
        func labels(token: String) async throws -> [GmailLabel] {
            ["INBOX", "SENT", "DRAFT", "TRASH", "SPAM", "UNREAD", "STARRED"].map { GmailLabel(id: $0, name: $0, type: "system") }
        }
        func history(token: String, start: String, pageToken: String?, maxResults: Int) async throws -> GmailHistoryPage {
            operations.append("history")
            if let historyFailure { throw historyFailure }
            if incompleteOnce {
                incompleteOnce = false; position = 20
                return GmailHistoryPage(history: [GmailHistoryRecord(id: 11)], historyId: position)
            }
            return GmailHistoryPage(historyId: position)
        }
        func listMessages(token: String, labelIDs: [String], query: String?, includeSpamTrash: Bool, pageToken: String?, maxResults: Int) async throws -> GmailIDPage {
            operations.append("list")
            return GmailIDPage()
        }
        func message(token: String, id: String, format: GmailFormat) async throws -> GmailMessage { throw GmailError.notFound }
        func thread(token: String, id: String, format: GmailFormat) async throws -> GmailThread { throw GmailError.malformed }
        func attachment(token: String, messageID: String, attachmentID: String) async throws -> GmailPartBody { throw GmailError.malformed }
        func modify(token: String, id: String, add: [String], remove: [String]) async throws { XCTFail("Sync may not mutate Gmail"); throw GmailError.malformed }
        func trash(token: String, id: String) async throws { XCTFail("Sync may not mutate Gmail"); throw GmailError.malformed }
        func untrash(token: String, id: String) async throws { XCTFail("Sync may not mutate Gmail"); throw GmailError.malformed }
    }
    private func setup(_ api: Provider) async throws -> (MailStores, GmailMailboxSync) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mailbox-sync-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let (stores, intents) = try await Task.detached {
            let directories = try MailDirectories(root: root)
            return (try MailStores.open(directories, migrations: MailSlices.migrations()), try MailIntentStore(directories: directories))
        }.value
        return (stores, GmailMailboxSync(stores: stores, writer: MailWriter(stores: stores, sink: nil), api: api,
            token: { _ in "fixture" }, recovery: MailRemovalRecovery(stores: stores, intents: intents)))
    }

    func testBootstrapYieldsAndPollsHistoryBetweenEnumerationBatches() async throws {
        let api = Provider(), (stores, worker) = try await setup(api)
        var finished = false
        for tick in 1...10 {
            let result = try await worker.pass(account: "a@example.com", nowMS: Int64(tick))
            if !result.hasMore { finished = true; break }
        }
        XCTAssertTrue(finished)
        let operations = await api.operations
        XCTAssertEqual(Array(operations.prefix(5)), ["list", "list", "history", "list", "list"])
        XCTAssertEqual(operations.filter { $0 == "list" }.count, 8)
        let state = try await stores.index.read { try MailReconcileIndex.state(account: "a@example.com", in: $0) }
        XCTAssertNil(state)
        let settled = try await worker.pass(account: "a@example.com", nowMS: 11)
        XCTAssertFalse(settled.hasMore)
        XCTAssertEqual(settled.checkpoint, 10)
    }

    func testHistoryFailureStopsBackfillWithoutLosingContinuation() async throws {
        let api = Provider(), (stores, worker) = try await setup(api)
        _ = try await worker.pass(account: "a@example.com", nowMS: 1)
        let before = try await stores.index.read { try MailReconcileIndex.state(account: "a@example.com", in: $0) }
        await api.configure(failure: .server(503))
        do { _ = try await worker.pass(account: "a@example.com", nowMS: 2); XCTFail() }
        catch { XCTAssertEqual(error as? GmailError, .server(503)) }
        let after = try await stores.index.read { try MailReconcileIndex.state(account: "a@example.com", in: $0) }
        XCTAssertEqual(before, after)
        let operations = await api.operations
        XCTAssertEqual(operations, ["list", "list", "history"])
        await api.configure()
        _ = try await worker.pass(account: "a@example.com", nowMS: 3)
    }

    func testIncompleteHistoryRestartsReconciliationAndEventuallySettles() async throws {
        let api = Provider(), (stores, worker) = try await setup(api)
        _ = try await worker.pass(account: "a@example.com", nowMS: 1)
        let old = try await stores.index.read { try MailReconcileIndex.state(account: "a@example.com", in: $0) }
        await api.injectIncompleteHistory()
        let recovered = try await worker.pass(account: "a@example.com", nowMS: 2)
        XCTAssertTrue(recovered.hasMore)
        let restarted = try await stores.index.read { try MailReconcileIndex.state(account: "a@example.com", in: $0) }
        XCTAssertEqual(restarted?.generation, (old?.generation ?? 0) + 1)
        var complete = false
        for tick in 3...12 {
            let progress = try await worker.pass(account: "a@example.com", nowMS: Int64(tick))
            if !progress.hasMore {
                complete = true; break
            }
        }
        XCTAssertTrue(complete, "Reconciliation must finish instead of retrying the rejected delta")
        let checkpoint = try await stores.index.read { try String.fetchOne($0, sql: "SELECT checkpoint FROM account") }
        XCTAssertEqual(checkpoint, "20")
    }

    func testWrongAccountCannotStartAnyListing() async throws {
        let api = Provider(), (_, worker) = try await setup(api)
        await api.configure(account: "other@example.com")
        do { _ = try await worker.pass(account: "a@example.com", nowMS: 1); XCTFail() }
        catch { XCTAssertTrue(error is GmailHistorySync.Failure) }
        let operations = await api.operations
        XCTAssertTrue(operations.isEmpty)
    }
}
