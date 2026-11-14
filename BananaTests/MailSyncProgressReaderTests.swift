import XCTest
import GRDB

final class MailSyncProgressReaderTests: XCTestCase {
    func testCountsOnlyEligibleContentInEachAccountsActualQueue() throws {
        let queue = try DatabaseQueue()
        try MailSlices.migrations().index.migrate(queue)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO account(account_pk,email) VALUES(1,'a@example.com'),(2,'b@example.com')")
            for key in 1...8 {
                try db.execute(sql: "INSERT INTO message(msg_pk,account_pk,gmail_id,thread_pk,fetch_state,prep_state,vis,cloud_content) VALUES(?,1,?,1,?,?,?,?)",
                    arguments: [key, "m\(key)", key == 2 || key == 6 ? 2 : 0, key == 6 ? 0 : 2, key == 3 ? 4 : 0, key == 5 ? 0 : 1])
            }
            try db.execute(sql: "INSERT INTO held_removal(msg_pk,evidence,found_at) VALUES(4,1,1)")
            let direct = try MailSyncProgressReader.pending(accounts: ["a@example.com", "b@example.com"], in: db)
            XCTAssertEqual(direct["a@example.com"]?.count, 4)
            XCTAssertEqual(direct["b@example.com"]?.count, 0)
            _ = try MailCloudFeedIndex.begin(account: "a@example.com", epoch: "e", in: db)
            let cloud = try MailSyncProgressReader.pending(accounts: ["a@example.com"], in: db)
            XCTAssertEqual(cloud["a@example.com"]?.count, 3, "cloud-unavailable old mail is not a pending content download")
            XCTAssertEqual(cloud["a@example.com"]?.isExact, true)
        }
    }
    func testLargeQueuesRemainAnExplicitLowerBound() throws {
        let queue = try DatabaseQueue()
        try MailSlices.migrations().index.migrate(queue)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO account(account_pk,email) VALUES(1,'a@example.com')")
            for key in 1...2_000 {
                try db.execute(sql: "INSERT INTO message(msg_pk,account_pk,gmail_id,thread_pk) VALUES(?,1,?,1)", arguments: [key, "m\(key)"])
            }
            let pending = try XCTUnwrap(MailSyncProgressReader.pending(accounts: ["a@example.com"], in: db)["a@example.com"])
            XCTAssertEqual(pending.count, MailSyncProgressReader.countLimit + 1)
            XCTAssertFalse(pending.isExact)
        }
    }
    func testProgressCountingCostAndBoundedVersusExactAblation() throws {
        let budget = CostBudget(self)
        let queue = try DatabaseQueue()
        try MailSlices.migrations().index.migrate(queue)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO account(account_pk,email) VALUES(1,'a@example.com')")
            var previous = 0
            for size in [2_000, 180_000] {
                let insert = try db.makeStatement(sql: "INSERT INTO message(msg_pk,account_pk,gmail_id,thread_pk) VALUES(?,1,?,1)")
                for key in (previous + 1)...size { try insert.execute(arguments: [key, "m\(key)"]) }
                previous = size
                var bounded: [Double] = [], exact: [Double] = []
                for _ in 0..<5 {
                    for limit in [MailSyncProgressReader.countLimit, 200_000] {
                        let start = ContinuousClock.now
                        let count = try XCTUnwrap(MailSyncProgressReader.pending(accounts: ["a@example.com"], in: db, limit: limit)["a@example.com"])
                        let duration = start.duration(to: .now).components
                        let ms = Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15
                        if limit == MailSyncProgressReader.countLimit {
                            XCTAssertEqual(count.count, 1_001); XCTAssertFalse(count.isExact); bounded.append(ms)
                        } else { XCTAssertEqual(count.count, size); XCTAssertTrue(count.isExact); exact.append(ms) }
                    }
                }
                print("MAIL_PROGRESS_COUNT_ABLATION retained=\(size) bounded_ms=\(bounded) exact_ms=\(exact)")
                budget.expect(bounded, below: 100, "Header progress query exceeded its component ceiling")
            }
        }
        try budget.finish()
    }

}
