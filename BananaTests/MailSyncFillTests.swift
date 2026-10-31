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
            let first = try MailSyncFill.page(account: "a@example.com", after: 0, in: db)
            XCTAssertEqual(first.map(\.key), Array(Int64(5)...20))
            let next = try MailSyncFill.page(account: "a@example.com", after: 20, in: db)
            XCTAssertEqual(next.map(\.key), Array(Int64(21)...36))
            XCTAssertTrue(first.allSatisfy { $0.id.account == "a@example.com" })
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
            let rows = try await stores.index.read { try MailSyncFill.page(account: "a@example.com", after: 0, in: $0) }
            let duration = start.duration(to: .now).components
            let ms = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
            samples.append(ms)
            XCTAssertEqual(rows.count, 16)
            XCTAssertEqual(rows.first?.key, 179969)
            XCTAssertLessThan(ms, 100)
        }
        print("SYNC_FILL_180000_RETAINED_MS \(samples)")
    }
}
