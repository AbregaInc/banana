import XCTest
import GRDB

final class MailSyncCheckpointTests: XCTestCase {
    private func fixture() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try MailSlices.migrations().index.migrate(queue)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO account(account_pk,email,checkpoint,enum_state,enum_checkpoint) VALUES(1,'a@example.com','10','saved-a','10'),(2,'b@example.com','20','saved-b','20')")
            for id in 1...3 {
                let owner = id == 3 ? 2 : 1
                try db.execute(sql: "INSERT INTO thread(thread_pk,account_pk,gmail_id,tie) VALUES(?,?,?,?)", arguments: [id, owner, "t\(id)", id])
                try db.execute(sql: "INSERT INTO message(msg_pk,account_pk,gmail_id,thread_pk) VALUES(?,?,?,?)", arguments: [id, owner, "m\(id)", id])
                try db.execute(sql: "INSERT INTO enum_mark(account_pk,generation,label_pk,msg_pk) VALUES(?,1,0,?)", arguments: [owner, id])
                try db.execute(sql: "INSERT INTO verify_queue(msg_pk,reason,generation,queued_at,outcome) VALUES(?,?,1,1,1)", arguments: [id, id == 2 ? 2 : 1])
                try db.execute(sql: "INSERT INTO held_removal(msg_pk,evidence,found_at,kept) VALUES(?,1,1,?)", arguments: [id, id == 2 ? 1 : 0])
            }
            try db.execute(sql: "INSERT INTO meta(key,value) VALUES('reconcile-removal:a@example.com','decision-a'),('reconcile-removal:b@example.com','decision-b')")
        }
        return queue
    }

    func testExpirationClearsOnlyAccountScanAndPreservesMailAndHolds() throws {
        let queue = try fixture()
        try queue.write { db in
            XCTAssertTrue(try MailSyncCheckpoint.expire(account: "a@example.com", expected: "10", in: db))
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT checkpoint FROM account WHERE account_pk=1"))
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT enum_state FROM account WHERE account_pk=1"))
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT enum_state FROM account WHERE account_pk=2"), "saved-b")
            XCTAssertEqual(try Int64.fetchAll(db, sql: "SELECT msg_pk FROM enum_mark ORDER BY msg_pk"), [3])
            XCTAssertEqual(try Int64.fetchAll(db, sql: "SELECT msg_pk FROM verify_queue ORDER BY msg_pk"), [2, 3])
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM message"), 3)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM held_removal"), 3)
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key='reconcile-removal:a@example.com'"))
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key='reconcile-removal:b@example.com'"), "decision-b")
        }
    }

    func testStaleExpirationCannotEraseAdvancedCheckpointOrScan() throws {
        let queue = try fixture()
        try queue.write { db in
            XCTAssertFalse(try MailSyncCheckpoint.expire(account: "a@example.com", expected: "9", in: db))
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT checkpoint FROM account WHERE account_pk=1"), "10")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT enum_state FROM account WHERE account_pk=1"), "saved-a")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM enum_mark"), 3)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM verify_queue"), 3)
        }
    }

    func testHistoryExpirationAllowsFreshEnumerationHandshake() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("checkpoint-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let stores = try await Task.detached { try MailStores.open(MailDirectories(root: root), migrations: MailSlices.migrations()) }.value
        let labels = ["INBOX", "SENT", "DRAFT", "TRASH", "SPAM", "UNREAD", "STARRED"].map { GmailLabel(id: $0, name: $0, type: "system") }
        let old = try await stores.index.write { db in
            try MailReconcileIndex.begin(profile: GmailProfile(emailAddress: "a@example.com", historyId: 10), labels: labels, account: "a@example.com", in: db)
        }
        let api = GmailHistorySyncTests.Provider([.failure(.notFound)])
        let worker = GmailHistorySync(stores: stores, writer: MailWriter(stores: stores, sink: nil), api: api,
                                      token: { _ in "fixture" }, recover: { _ in }, committed: { _, _ in })
        let result = try await worker.poll(account: "a@example.com", nowMS: 1)
        XCTAssertEqual(result, .needsReconcile)
        let fresh = try await stores.index.write { db in
            try MailReconcileIndex.begin(profile: GmailProfile(emailAddress: "a@example.com", historyId: 20), labels: labels, account: "a@example.com", in: db)
        }
        XCTAssertEqual(fresh.generation, old.generation + 1)
        XCTAssertEqual(fresh.startedAt, 20)
        XCTAssertEqual(fresh.listing, 0)
        XCTAssertNil(fresh.pageToken)
    }

    func testExpirationCostOnDisk() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("checkpoint-cost-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let stores = try await Task.detached { try MailStores.open(MailDirectories(root: root), migrations: MailSlices.migrations()) }.value
        var samples: [Double] = []
        for _ in 0..<3 {
            try await stores.index.write { db in
                try db.execute(sql: "INSERT OR IGNORE INTO account(account_pk,email) VALUES(1,'a@example.com')")
                try db.execute(sql: "UPDATE account SET checkpoint='10',enum_state='in-progress',enum_checkpoint='10' WHERE account_pk=1")
                try db.execute(sql: "WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<10000) INSERT INTO enum_mark(account_pk,generation,label_pk,msg_pk) SELECT 1,1,0,i FROM n")
            }
            let start = ContinuousClock.now
            let expired = try await stores.index.write { try MailSyncCheckpoint.expire(account: "a@example.com", expected: "10", in: $0) }
            let duration = start.duration(to: .now).components
            let ms = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
            samples.append(ms)
            XCTAssertTrue(expired)
            XCTAssertLessThan(ms, 100)
        }
        // Retained in the persistent runner's test.log, including failed samples.
        print("CHECKPOINT_EXPIRATION_10000_MARKS_MS \(samples)")
    }
}
