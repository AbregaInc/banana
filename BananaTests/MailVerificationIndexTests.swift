import XCTest
import GRDB

final class MailVerificationIndexTests: XCTestCase {
    private let account = "a@example.com"
    private func setup(count: Int) throws -> (DatabaseQueue, String) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("verify-index-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("index.sqlite").path
        let queue = try DatabaseQueue(path: path)
        try MailSlices.migrations().index.migrate(queue)
        var state = try queue.write { db in
            try db.execute(sql: "INSERT INTO account(account_pk,email) VALUES(1,'a@example.com')")
            for i in 1...count {
                try db.execute(sql: "INSERT INTO thread(thread_pk,account_pk,gmail_id,tie) VALUES(?,1,?,?)", arguments: [i, "t\(i)", i])
                try db.execute(sql: "INSERT INTO message(msg_pk,account_pk,gmail_id,thread_pk,history_id) VALUES(?,1,?,?,'1')", arguments: [i, "m\(i)", i])
            }
            let labels = ["INBOX", "SENT", "DRAFT", "TRASH", "SPAM", "UNREAD", "STARRED"].map { GmailLabel(id: $0, name: $0, type: "system") }
            return try MailReconcileIndex.begin(profile: GmailProfile(emailAddress: account, historyId: 10), labels: labels, account: account, in: db)
        }
        while state.phase == .listing {
            let expected = state
            state = try queue.write { try MailReconcileIndex.apply(GmailIDPage(), account: account, expected: expected, floor: 10, nowMS: 1, in: $0).0 }
        }
        while state.phase == .closing {
            let expected = state
            state = try queue.write { try MailReconcileIndex.closeBatch(account: account, expected: expected, nowMS: 1, in: $0) }
        }
        return (queue, path)
    }
    private func markGone(_ queue: DatabaseQueue) throws {
        while true {
            let requests = try queue.read { try MailVerificationIndex.requests(account: account, in: $0) }
            if requests.isEmpty { return }
            try queue.write { db in
                for request in requests { try MailVerificationIndex.gone(request, account: account, in: db) }
            }
        }
    }

    func testGenerationWaitsForAllOutcomesAndHoldsLargeRemoval() throws {
        let (queue, _) = try setup(count: 30)
        let requests = try queue.read { try MailVerificationIndex.requests(account: account, in: $0) }
        try queue.write { db in
            for request in requests.prefix(20) { try MailVerificationIndex.gone(request, account: account, in: db) }
        }
        let partial = try queue.write { try MailVerificationIndex.resolveBatch(account: account, nowMS: 2, in: $0) }
        XCTAssertTrue(partial.needsRead); XCTAssertTrue(partial.deleted.isEmpty)
        try markGone(queue)
        let held = try queue.write { try MailVerificationIndex.resolveBatch(account: account, nowMS: 2, in: $0) }
        XCTAssertEqual(held.held.count, 30); XCTAssertTrue(held.deleted.isEmpty)
        let count = try queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM message") }
        XCTAssertEqual(count, 30)
        let done = try queue.write { try MailVerificationIndex.resolveBatch(account: account, nowMS: 3, in: $0) }
        XCTAssertTrue(done.finished)
    }

    func testBatchDecisionSurvivesReopenWithoutRejudgingSmallerDenominator() throws {
        let (queue, path) = try setup(count: 180)
        try queue.write { try $0.execute(sql: "DELETE FROM verify_queue WHERE msg_pk>55") }
        try markGone(queue)
        let start = ContinuousClock.now
        let first = try queue.write { try MailVerificationIndex.resolveBatch(account: account, nowMS: 2, in: $0) }
        let elapsed = start.duration(to: .now).components
        let ms = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        if let path = ProcessInfo.processInfo.environment["MAIL_VERIFICATION_BENCHMARK_OUTPUT"] {
            let data = try JSONSerialization.data(withJSONObject: ["messages": 50, "firstBatchMS": ms,
                "scope": "Temporary disk index: aggregate decision, 50 deletions and summaries; no UI, warm or eviction acceptance"], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path))
        }
        XCTAssertLessThan(ms, 100)
        XCTAssertEqual(first.deleted.count, 50)
        try queue.close()
        let reopened = try DatabaseQueue(path: path)
        let second = try reopened.write { try MailVerificationIndex.resolveBatch(account: account, nowMS: 3, in: $0) }
        XCTAssertEqual(second.deleted.count, 5); XCTAssertTrue(second.held.isEmpty)
        let final = try reopened.write { try MailVerificationIndex.resolveBatch(account: account, nowMS: 4, in: $0) }
        XCTAssertTrue(final.finished)
        let count = try reopened.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM tombstone") }
        XCTAssertEqual(count, 55)
        let raw = try reopened.read { try String.fetchOne($0, sql: "SELECT removals FROM account")! }
        let hours = try JSONDecoder().decode([MailRemovalRules.Hour].self, from: Data(raw.utf8))
        XCTAssertEqual(hours.reduce(0) { $0 + $1.count }, 55)
    }

    func testNewHistoryInvalidatesAbsenceBeforeAndAfterRecording() throws {
        let (queue, _) = try setup(count: 1)
        let request = try queue.read { try MailVerificationIndex.requests(account: account, in: $0)[0] }
        try queue.write { db in
            try db.execute(sql: "UPDATE message SET history_id='20' WHERE msg_pk=1")
            try MailVerificationIndex.gone(request, account: account, in: db)
        }
        let next = try queue.read { try MailVerificationIndex.requests(account: account, in: $0)[0] }
        try queue.write { db in
            try MailVerificationIndex.gone(next, account: account, in: db)
            try db.execute(sql: "UPDATE message SET history_id='21' WHERE msg_pk=1")
        }
        let result = try queue.write { try MailVerificationIndex.resolveBatch(account: account, nowMS: 2, in: $0) }
        XCTAssertTrue(result.needsRead); XCTAssertTrue(result.deleted.isEmpty)
        let count = try queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM message") }
        XCTAssertEqual(count, 1)
    }

    func testReadRequiresKnownLabelsAndStaleReadPreservesNewerMembership() throws {
        let (queue, _) = try setup(count: 1)
        let request = try queue.read { try MailVerificationIndex.requests(account: account, in: $0)[0] }
        XCTAssertThrowsError(try queue.write { try MailVerificationIndex.found(GmailMessage(id: "m1", threadId: "t1"), request: request, account: account, in: $0) })
        try queue.write { db in
            try db.execute(sql: "UPDATE message SET history_id='20' WHERE msg_pk=1")
            try db.execute(sql: "INSERT INTO message_label(msg_pk,label_pk) SELECT 1,label_pk FROM label WHERE gmail_id='INBOX'")
            _ = try MailVerificationIndex.found(GmailMessage(id: "m1", threadId: "t1", labelIds: [], historyId: 2), request: request, account: account, in: db)
        }
        let labels = try queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM message_label") }
        let pending = try queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM verify_queue") }
        XCTAssertEqual(labels, 1); XCTAssertEqual(pending, 0)
    }

    func testRemovalTransactionRollbackPreservesEvidenceAndRows() throws {
        let (queue, _) = try setup(count: 1)
        try markGone(queue)
        enum Injected: Error { case rollback }
        XCTAssertThrowsError(try queue.write { db in
            _ = try MailVerificationIndex.resolveBatch(account: account, nowMS: 2, in: db)
            throw Injected.rollback
        })
        let evidence = try queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM verify_queue WHERE outcome=1") }
        let count = try queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM message") }
        XCTAssertEqual(evidence, 1); XCTAssertEqual(count, 1)
    }
}
