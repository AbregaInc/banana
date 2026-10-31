import XCTest
import GRDB

final class MailIndexSchemaTests: XCTestCase {
    private func database() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        var migrations = DatabaseMigrator()
        MailIndexSchema.register(in: &migrations)
        try migrations.migrate(queue)
        return queue
    }

    func testRepeatedMigrationPreservesRowsAndUnsignedHistoryID() throws {
        let queue = try database()
        try queue.write { db in
            try db.execute(sql: "INSERT INTO account(email, checkpoint, limit_edge) VALUES (?, ?, ?)",
                           arguments: ["a@example.com", "18446744073709551615", 100])
        }
        var migrations = DatabaseMigrator()
        MailIndexSchema.register(in: &migrations)
        try migrations.migrate(queue)
        try queue.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT checkpoint FROM account"), "18446744073709551615")
            XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT limit_edge FROM account"), 100)
        }
    }

    func testProviderIDsAreUniqueWithinAccountAndIndependentAcrossAccounts() throws {
        let queue = try database()
        try queue.write { db in
            try db.execute(sql: "INSERT INTO account(account_pk,email) VALUES (1,'a@example.com'),(2,'b@example.com')")
            try db.execute(sql: "INSERT INTO thread(account_pk,gmail_id,tie) VALUES (1,'same',1),(2,'same',2)")
            XCTAssertThrowsError(try db.execute(sql: "INSERT INTO thread(account_pk,gmail_id,tie) VALUES (1,'same',3)"))
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM thread"), 2)
        }
    }

    func testAttentionAndRecipientSummariesHaveIndependentStorage() throws {
        let queue = try database()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO thread(account_pk,gmail_id,tie,people,people_total,recipients,recipients_total,attended_at)
                VALUES (1,'t',1,'[]',0,'[]',7,123)
                """)
            try db.execute(sql: "UPDATE thread SET last_date=456,subject='New subject'")
            let row = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM thread"))
            XCTAssertEqual(row["attended_at"] as Int64, 123)
            XCTAssertEqual(row["recipients_total"] as Int, 7)
        }
    }

    func testDatedAndUnreadPagesUseMembershipIndexesWithoutSorting() throws {
        let queue = try database()
        try queue.read { db in
            for unread in [false, true] {
                let sql = """
                    EXPLAIN QUERY PLAN
                    SELECT t.thread_pk, v.sort_key, v.tie FROM view_thread v
                    JOIN thread t ON t.thread_pk=v.thread_pk
                    WHERE v.view_pk=1 AND v.sort_key>0
                    \(unread ? "AND v.unread=1" : "")
                    AND (v.sort_key,v.tie)<(1000,1000)
                    ORDER BY v.sort_key DESC,v.tie DESC LIMIT 100
                    """
                let details = try Row.fetchAll(db, sql: sql).map { $0["detail"] as String }.joined(separator: "\n")
                XCTAssertFalse(details.contains("TEMP B-TREE"), details)
                XCTAssertFalse(details.contains("SCAN v"), details)
                XCTAssertTrue(details.contains("SEARCH v"), details)
            }
        }
    }
}
