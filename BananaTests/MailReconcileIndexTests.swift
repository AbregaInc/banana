import XCTest
import GRDB
import SQLite3

final class MailReconcileIndexTests: XCTestCase {
    private let account = "a@example.com"
    private var labels: [GmailLabel] {
        ["INBOX", "SENT", "DRAFT", "TRASH", "SPAM", "UNREAD", "STARRED"].map { GmailLabel(id: $0, name: $0, type: "system") }
    }
    private func setup() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try MailSlices.migrations().index.migrate(queue)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO account(account_pk,email) VALUES(1,'a@example.com'),(2,'b@example.com')")
            for id in 1...4 {
                try db.execute(sql: "INSERT INTO thread(thread_pk,account_pk,gmail_id,tie) VALUES(?,1,?,?)", arguments: [id, "t\(id)", id])
                try db.execute(sql: "INSERT INTO message(msg_pk,account_pk,gmail_id,thread_pk,history_id,vis) VALUES(?,1,?,?,?,?)",
                    arguments: [id, "m\(id)", id, id == 3 ? "20" : "1", id == 4 ? 4 : 0])
            }
        }
        return queue
    }
    private func begin(_ db: Database) throws -> MailReconcileIndex.State {
        try MailReconcileIndex.begin(profile: GmailProfile(emailAddress: account, messagesTotal: 4, historyId: 10), labels: labels, account: account, in: db)
    }
    private func finishListings(_ initial: MailReconcileIndex.State, queue: DatabaseQueue,
                                unfiltered: [GmailMessageRef] = []) throws -> MailReconcileIndex.State {
        var current = initial
        while current.phase == .listing {
            let expected = current
            current = try queue.write { db in
                try MailReconcileIndex.apply(GmailIDPage(messages: expected.label == nil ? unfiltered : []),
                    account: account, expected: expected, floor: 10, nowMS: 1, in: db).0
            }
        }
        return current
    }

    func testHandshakeAndPageCommitPreserveCheckpointAndRejectStaleReplay() throws {
        let queue = try setup()
        let state = try queue.write { try begin($0) }
        XCTAssertEqual(state.label, "INBOX")
        let checkpoint = try queue.read { try String.fetchOne($0, sql: "SELECT checkpoint FROM account WHERE account_pk=1") }
        XCTAssertEqual(checkpoint, "10")
        let next = try queue.write { db in
            try MailReconcileIndex.apply(GmailIDPage(messages: [GmailMessageRef(id: "new", threadId: "new-thread")], nextPageToken: "p2"),
                account: account, expected: state, floor: 10, nowMS: 1, in: db).0
        }
        XCTAssertEqual(next.pageToken, "p2")
        let restored = try queue.read { try MailReconcileIndex.state(account: account, in: $0) }
        XCTAssertEqual(restored, next)
        XCTAssertThrowsError(try queue.write { db in
            try MailReconcileIndex.apply(GmailIDPage(), account: account, expected: state, floor: 10, nowMS: 1, in: db)
        })
        let stubs = try queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM message WHERE gmail_id='new' AND fetch_state=0") }
        XCTAssertEqual(stubs, 1)
    }

    func testPartialPageFailureRollsBackBothStubsAndContinuation() throws {
        let queue = try setup(), state = try queue.write { try begin($0) }
        XCTAssertThrowsError(try queue.write { db in
            try MailReconcileIndex.apply(GmailIDPage(messages: [GmailMessageRef(id: "new", threadId: "new-thread"), GmailMessageRef(id: "invalid")], nextPageToken: "p2"),
                account: account, expected: state, floor: 10, nowMS: 1, in: db)
        })
        let restored = try queue.read { try MailReconcileIndex.state(account: account, in: $0) }
        XCTAssertEqual(restored, state)
        let count = try queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM message") }
        XCTAssertEqual(count, 4)
    }

    func testCloseOnlyQueuesAbsenceAndSkipsNewHistoryKeptAndOtherAccounts() throws {
        let queue = try setup(), state = try queue.write { try begin($0) }
        let closing = try finishListings(state, queue: queue, unfiltered: [GmailMessageRef(id: "m1", threadId: "t1")])
        let verifying = try queue.write { try MailReconcileIndex.closeBatch(account: account, expected: closing, nowMS: 2, in: $0) }
        XCTAssertEqual(verifying.phase, .verifying)
        let pending = try queue.read { try Int64.fetchAll($0, sql: "SELECT msg_pk FROM verify_queue ORDER BY msg_pk") }
        XCTAssertEqual(pending, [2])
        let messages = try queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM message") }
        let tombstones = try queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM tombstone") }
        XCTAssertEqual(messages, 4); XCTAssertEqual(tombstones, 0)
        let other = try queue.read { try MailReconcileIndex.state(account: "b@example.com", in: $0) }
        XCTAssertNil(other)
    }

    func testOlderListingCannotRestoreLabelRemovedByNewerHistory() throws {
        let queue = try setup(), state = try queue.write { try begin($0) }
        _ = try queue.write { db in
            try MailReconcileIndex.apply(GmailIDPage(messages: [GmailMessageRef(id: "m3", threadId: "t3")]),
                account: account, expected: state, floor: 10, nowMS: 1, in: db)
        }
        let labels = try queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM message_label WHERE msg_pk=3") }
        let pending = try queue.read { try Int64.fetchAll($0, sql: "SELECT msg_pk FROM verify_queue") }
        XCTAssertEqual(labels, 0); XCTAssertEqual(pending, [3])
    }

    func testCloseFindsMissingMembershipEvenWhenMessageWasListed() throws {
        let queue = try setup(), state = try queue.write { try begin($0) }
        try queue.write { db in
            try db.execute(sql: "INSERT INTO message_label(msg_pk,label_pk) SELECT 1,label_pk FROM label WHERE account_pk=1 AND gmail_id='INBOX'")
        }
        let closing = try finishListings(state, queue: queue, unfiltered: [GmailMessageRef(id: "m1", threadId: "t1"), GmailMessageRef(id: "m2", threadId: "t2")])
        _ = try queue.write { try MailReconcileIndex.closeBatch(account: account, expected: closing, nowMS: 2, in: $0) }
        let pending = try queue.read { try Int64.fetchAll($0, sql: "SELECT msg_pk FROM verify_queue ORDER BY msg_pk") }
        XCTAssertEqual(pending, [1])
        let membership = try queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM message_label WHERE msg_pk=1") }
        XCTAssertEqual(membership, 1, "A listing cannot remove a label")
    }

    func testEnumerationStatementReuseMatchesUncachedAndSurvivesEviction() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reconcile-statements-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let stores = try await Task.detached {
            try (0..<3).map { policy in
                try MailStores.open(MailDirectories(root: root.appendingPathComponent(String(policy))), migrations: MailSlices.migrations())
            }
        }.value
        var states: [MailReconcileIndex.State] = []
        for store in stores {
            states.append(try await store.index.write { db in
                let state = try self.begin(db)
                // The bootstrap wall clock is not part of this statement policy.
                try db.execute(sql: "UPDATE account SET labels_at=1")
                return state
            })
        }
        var measurements: [[String: Any]] = []
        let phases = ["first", "warm", "evictionRecovery", "warmAfterEviction"]
        for (trial, phase) in phases.enumerated() {
            if phase == "evictionRecovery" {
                for store in stores { try await store.index.writeWithoutTransaction { $0.releaseMemory() } }
            }
            let page = GmailIDPage(messages: (0..<500).map {
                GmailMessageRef(id: "m-\(trial)-\($0)", threadId: "t-\(trial)-\($0)")
            }, nextPageToken: "page-\(trial)")
            for index in trial.isMultiple(of: 2) ? [0, 1, 2] : [2, 1, 0] {
                let expected = states[index]
                let cached = index > 0
                let projectionCached = index == 2
                let start = ContinuousClock.now
                states[index] = try await stores[index].index.write { db in
                    try MailReconcileIndex.apply(page, account: self.account, expected: expected,
                        floor: 10, nowMS: 1, reuseStatements: cached,
                        reuseProjectionStatements: projectionCached, in: db).0
                }
                let elapsed = start.duration(to: .now).components
                let ms = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
                let bytes = try await stores[index].index.writeWithoutTransaction { db -> Int32 in
                    var current: Int32 = 0, high: Int32 = 0
                    guard sqlite3_db_status(db.sqliteConnection, SQLITE_DBSTATUS_STMT_USED, &current, &high, 0) == SQLITE_OK else {
                        throw MailReconcileIndex.Failure.invalidState
                    }
                    return current
                }
                measurements.append(["phase": phase, "listingCached": cached,
                    "projectionCached": projectionCached, "durationMS": ms, "statementBytes": bytes])
            }
            XCTAssertEqual(states[0], states[1])
            XCTAssertEqual(states[0], states[2])
            // Compare durable state, derived memberships and cursors, not just row counts.
            for table in ["account", "thread", "message", "message_label", "view", "view_thread", "enum_mark", "verify_queue"] {
                var snapshots: [[String]] = []
                for store in stores {
                    snapshots.append(try await store.index.read { db in
                        try Row.fetchAll(db, sql: "SELECT * FROM \(table)").map { row in
                            try row.columnNames.sorted().map { column in
                                // JSON object member order is not a database-state difference.
                                if column == "enum_state", let text: String = row[column] {
                                    let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
                                    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                                    return column + ":" + String(decoding: data, as: UTF8.self)
                                }
                                let value: DatabaseValue = row[column]
                                return column + ":" + value.description
                            }.joined(separator: "\n")
                        }.sorted()
                    })
                }
                XCTAssertEqual(snapshots[0], snapshots[1], "\(phase): \(table)")
                XCTAssertEqual(snapshots[0], snapshots[2], "\(phase): \(table)")
            }
        }
        if let path = ProcessInfo.processInfo.environment["MAIL_RECONCILE_STATEMENTS_OUTPUT"] {
            let data = try JSONSerialization.data(withJSONObject: ["samples": measurements,
                "scope": "Alternating same-workload disk transactions; statement memory only, not total RSS or physical UI acceptance"], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path))
        }
        for sample in measurements where sample["projectionCached"] as? Bool == true {
            XCTAssertLessThan(try XCTUnwrap(sample["durationMS"] as? Double), 100,
                "Current statement policy must meet the budget in \(sample["phase"] ?? "unknown")")
        }
    }

    func testEnumerationPageCostOnDisk() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reconcile-cost-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let stores = try await Task.detached { try MailStores.open(MailDirectories(root: root), migrations: MailSlices.migrations()) }.value
        var current = try await stores.index.write { try self.begin($0) }
        var timings: [String: [Double]] = [:]
        for size in [100, 500] {
            for trial in 0..<3 {
                let page = GmailIDPage(messages: (0..<size).map {
                    GmailMessageRef(id: "m-\(size)-\(trial)-\($0)", threadId: "t-\(size)-\(trial)-\($0)")
                }, nextPageToken: "next-\(size)-\(trial)")
                let expected = current
                let start = ContinuousClock.now
                current = try await stores.index.write { db in
                    try MailReconcileIndex.apply(page, account: self.account, expected: expected, floor: 10, nowMS: 1, in: db).0
                }
                let elapsed = start.duration(to: .now).components
                timings[String(size), default: []].append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
            }
        }
        if let path = ProcessInfo.processInfo.environment["MAIL_RECONCILE_BENCHMARK_OUTPUT"] {
            let data = try JSONSerialization.data(withJSONObject: ["samplesMS": timings,
                "scope": "Actual disk enumeration page plus durable cursor; first/warm only, no UI or eviction acceptance"], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path))
        }
        for samples in timings.values { for ms in samples { XCTAssertLessThan(ms, 100) } }
    }
}
