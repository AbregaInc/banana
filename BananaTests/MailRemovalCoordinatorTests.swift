import XCTest
import GRDB

final class MailRemovalCoordinatorTests: XCTestCase {
    private func setup() async throws -> (MailStores, MailIntentStore, MailRemovalCoordinator) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("removal-review-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let stores = try await Task.detached { try MailStores.open(MailDirectories(root: root), migrations: MailSlices.migrations()) }.value
        let intent = try await Task.detached { try MailIntentStore(directories: stores.directories) }.value
        try await stores.index.write { db in
            try db.execute(sql: "INSERT INTO account(account_pk,email) VALUES(1,'a@example.com'),(2,'b@example.com')")
            for i in 1...3 {
                try db.execute(sql: "INSERT INTO thread(thread_pk,account_pk,gmail_id,tie) VALUES(?,?,?,?)", arguments: [i, i == 3 ? 2 : 1, "t\(i)", i])
                try db.execute(sql: "INSERT INTO message(msg_pk,account_pk,gmail_id,thread_pk,internal_date,fetch_state) VALUES(?,?,?,?,10,1)", arguments: [i, i == 3 ? 2 : 1, "m\(i)", i])
                try db.execute(sql: "INSERT INTO held_removal(msg_pk,evidence,found_at) VALUES(?,1,1)", arguments: [i])
            }
        }
        return (stores, intent, MailRemovalCoordinator(stores: stores, intent: intent, writer: MailWriter(stores: stores, sink: nil)))
    }
    func testKeepUsesExactReviewSetAndLeavesNewHoldAndOtherAccountAlone() async throws {
        let (stores, intent, coordinator) = try await setup()
        let review = try await coordinator.review(account: "a@example.com", at: 1)
        XCTAssertEqual(review.count, 2)
        try await stores.index.write { db in
            try db.execute(sql: "INSERT INTO message(msg_pk,account_pk,gmail_id,thread_pk,internal_date) VALUES(4,1,'new',1,10)")
            try db.execute(sql: "INSERT INTO held_removal(msg_pk,evidence,found_at) VALUES(4,1,1)")
        }
        try await coordinator.answer(review.id, choice: .keepHere, at: 2)
        let kept = try await stores.index.read { try Int64.fetchAll($0, sql: "SELECT msg_pk FROM message WHERE vis=4 ORDER BY msg_pk") }
        XCTAssertEqual(kept, [1, 2])
        let remaining = try await stores.index.read { try Int64.fetchAll($0, sql: "SELECT msg_pk FROM held_removal WHERE kept=0 ORDER BY msg_pk") }
        XCTAssertEqual(remaining, [3, 4])
        let pending = try await intent.pendingRemovalReviews()
        XCTAssertTrue(pending.isEmpty)
        let changes = try await stores.index.read { db in
            try OutboxRules.assertions(for: .trash, account: "a@example.com", messages: MailMessageImporter.facts(threadPK: 2, in: db), asOf: 100)
        }
        XCTAssertTrue(changes.isEmpty, "Kept mail cannot generate a Gmail mutation")
        try await stores.index.write { db in
            _ = try MailMessageImporter.apply(FetchedMessage(wire: GmailMessage(id: "m2", threadId: "t2", labelIds: ["TRASH"], historyId: 50),
                floor: 50, headers: MessageHeaders(payload: nil), structure: nil), account: "a@example.com", myAddresses: ["a@example.com"], in: db)
        }
        let labels = try await stores.index.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM message_label WHERE msg_pk=2") }
        XCTAssertEqual(labels, 0, "Late provider reads must not alter kept mail")
    }
    func testCommittedChoiceReplaysAfterRestart() async throws {
        let (stores, intent, coordinator) = try await setup()
        let review = try await coordinator.review(account: "a@example.com", at: 1)
        try await intent.commitRemovalReview(review.id, choice: .remove)
        let reopened = try await Task.detached { try MailIntentStore(directories: stores.directories) }.value
        let resumed = MailRemovalCoordinator(stores: stores, intent: reopened, writer: MailWriter(stores: stores, sink: nil))
        try await resumed.recover(at: 2)
        try await resumed.recover(at: 3)
        let remaining = try await stores.index.read { try Int64.fetchAll($0, sql: "SELECT msg_pk FROM message") }
        let tombstones = try await stores.index.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM tombstone") }
        XCTAssertEqual(remaining, [3]); XCTAssertEqual(tombstones, 2)
        let pending = try await reopened.pendingRemovalReviews()
        XCTAssertTrue(pending.isEmpty)
    }
    func testUncommittedReviewIsNeverAppliedByRecovery() async throws {
        let (stores, intent, coordinator) = try await setup()
        let review = try await coordinator.review(account: "a@example.com", at: 1)
        try await coordinator.recover(at: 2)
        let count = try await stores.index.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM message") }
        XCTAssertEqual(count, 3)
        try await intent.discardUncommittedStages()
        let discarded = try await intent.removalReview(review.id)
        XCTAssertNil(discarded)
    }
    func testFailedCleanupRetainsCommittedChoiceForRetry() async throws {
        let (stores, intent, coordinator) = try await setup()
        let protected = stores.directories.intentAttachments.appendingPathComponent("draft.bin")
        try Data([42]).write(to: protected)
        try await stores.blobs.write { db in
            try db.execute(sql: "INSERT INTO attachment(account,gmail_id,part_id,path) VALUES('a@example.com','m1','p',?)", arguments: [protected.path])
        }
        let review = try await coordinator.review(account: "a@example.com", at: 1)
        do { try await coordinator.answer(review.id, choice: .remove, at: 2); XCTFail() }
        catch { XCTAssertTrue(error is MailRemovalRecovery.Failure) }
        let pending = try await intent.pendingRemovalReviews()
        XCTAssertEqual(pending, [review.id])
        XCTAssertEqual(try Data(contentsOf: protected), Data([42]))
        // Correct the invalid cache reference; no user file is deleted by repair.
        try await stores.blobs.write { try $0.execute(sql: "UPDATE attachment SET path=NULL") }
        try await coordinator.recover(at: 3)
        let remaining = try await intent.pendingRemovalReviews()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testReviewAndKeepCostWithOneHundredHeldMessages() async throws {
        let (stores, _, coordinator) = try await setup()
        try await stores.index.write { db in
            for i in 4...101 {
                try db.execute(sql: "INSERT INTO thread(thread_pk,account_pk,gmail_id,tie) VALUES(?,1,?,?)", arguments: [i, "t\(i)", i])
                try db.execute(sql: "INSERT INTO message(msg_pk,account_pk,gmail_id,thread_pk,internal_date,fetch_state) VALUES(?,1,?,?,10,1)", arguments: [i, "m\(i)", i])
                try db.execute(sql: "INSERT INTO held_removal(msg_pk,evidence,found_at) VALUES(?,1,1)", arguments: [i])
            }
        }
        let start = ContinuousClock.now
        let review = try await coordinator.review(account: "a@example.com", at: 1)
        let prepared = ContinuousClock.now
        try await coordinator.answer(review.id, choice: .keepHere, at: 2)
        let finished = ContinuousClock.now
        func ms(_ duration: Duration) -> Double {
            let parts = duration.components
            return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
        }
        let prepareMS = ms(start.duration(to: prepared)), answerMS = ms(prepared.duration(to: finished))
        XCTAssertEqual(review.count, 100)
        if let path = ProcessInfo.processInfo.environment["MAIL_REMOVAL_REVIEW_BENCHMARK_OUTPUT"] {
            let data = try JSONSerialization.data(withJSONObject: ["messages": 100, "prepareMS": prepareMS, "answerMS": answerMS,
                "scope": "First disk review snapshot and full-fsync keep decision/projection; no UI, warm or eviction acceptance"], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path))
        }
        XCTAssertLessThan(prepareMS, 100); XCTAssertLessThan(answerMS, 100)
    }
}
