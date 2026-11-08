import XCTest
import GRDB

final class MailSyncFillTests: XCTestCase {
    func testFillPagesExcludeCompleteKeptHeldAndOtherAccounts() throws {
        let queue = try DatabaseQueue()
        try MailSlices.migrations().index.migrate(queue)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO account(account_pk,email) VALUES(1,'a@example.com'),(2,'b@example.com')")
            for key in 1...40 {
                try db.execute(sql: "INSERT INTO message(msg_pk,account_pk,gmail_id,thread_pk,fetch_state,prep_state,vis) VALUES(?,?,?,?,?,?,?)",
                    arguments: [key, key == 1 ? 2 : 1, "m\(key)", 1, key == 2 ? 2 : 0, key == 2 ? 2 : 0, key == 3 ? 4 : 0])
            }
            try db.execute(sql: "INSERT INTO held_removal(msg_pk,evidence,found_at) VALUES(4,1,1)")
            // Newest first: every row is undated here, so the newest row first.
            let first = try MailSyncFill.page(account: "a@example.com", after: nil, in: db)
            XCTAssertEqual(first.map(\.key), Array((Int64(25)...40).reversed()))
            let next = try MailSyncFill.page(account: "a@example.com", after: first.last?.cursor, in: db)
            XCTAssertEqual(next.map(\.key), Array((Int64(9)...24).reversed()))
            let last = try MailSyncFill.page(account: "a@example.com", after: next.last?.cursor, in: db)
            XCTAssertEqual(last.map(\.key), [8, 7, 6, 5], "complete, kept, held and other accounts' rows are never listed")
            XCTAssertTrue(first.allSatisfy { $0.id.account == "a@example.com" })
        }
    }

    func testFillWalksNewestMailFirstByDate() throws {
        let queue = try DatabaseQueue()
        try MailSlices.migrations().index.migrate(queue)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO account(account_pk,email) VALUES(1,'a@example.com')")
            // Inserted oldest-last (as history appends new mail after a backfill), dated otherwise.
            for (key, date) in [(1, 500), (2, 100), (3, 900), (4, 300), (5, 700)] {
                try db.execute(sql: "INSERT INTO message(msg_pk,account_pk,gmail_id,thread_pk,internal_date) VALUES(?,1,?,1,?)",
                               arguments: [key, "m\(key)", date])
            }
            let rows = try MailSyncFill.page(account: "a@example.com", after: nil, in: db)
            XCTAssertEqual(rows.map(\.date), [900, 700, 500, 300, 100])
            let after = try MailSyncFill.page(account: "a@example.com", after: rows[1].cursor, in: db)
            XCTAssertEqual(after.map(\.key), [1, 4, 2])
        }
    }

    func testSparseFillUsesBoundedQueueAtLargeRetainedHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fill-cost-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let stores = try await Task.detached { try MailStores.open(MailDirectories(root: root), migrations: MailSlices.migrations()) }.value
        try await stores.index.write { db in
            try db.execute(sql: "INSERT INTO account(account_pk,email) VALUES(1,'a@example.com')")
            try db.execute(sql: "WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<180000) INSERT INTO message(msg_pk,account_pk,gmail_id,thread_pk,fetch_state,prep_state) SELECT i,1,'m'||i,1,CASE WHEN i>179968 THEN 0 ELSE 2 END,CASE WHEN i>179968 THEN 0 ELSE 2 END FROM n")
        }
        var samples: [Double] = []
        for _ in 0..<6 {
            let start = ContinuousClock.now
            let rows = try await stores.index.read { try MailSyncFill.page(account: "a@example.com", after: nil, in: $0) }
            let duration = start.duration(to: .now).components
            let ms = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
            samples.append(ms)
            XCTAssertEqual(rows.count, 16)
            XCTAssertEqual(rows.first?.key, 180000)
            XCTAssertLessThan(ms, 100)
        }
        print("SYNC_FILL_180000_RETAINED_MS \(samples)")
    }
}
