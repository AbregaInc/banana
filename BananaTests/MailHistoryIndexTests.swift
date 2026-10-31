import XCTest
import GRDB

final class MailHistoryIndexTests: XCTestCase {
    private func database(count: Int = 1, onDisk: Bool = false) throws -> any DatabaseWriter {
        let queue: any DatabaseWriter
        if onDisk {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-history-" + UUID().uuidString)
            addTeardownBlock { try? FileManager.default.removeItem(at: root) }
            queue = try MailStores.open(MailDirectories(root: root), migrations: MailSlices.migrations()).index
        } else { queue = try DatabaseQueue() }
        try MailSlices.migrations().index.migrate(queue)
        try queue.write { db in
            for account in ["a@example.com", "b@example.com"] {
                for n in 0..<count {
                    let wire = GmailMessage(id: "m\(n)", threadId: "t\(n)", labelIds: ["INBOX"], snippet: "Needle", historyId: 1,
                        internalDate: Int64(n + 1), payload: GmailPart(headers: [GmailHeader(name: "Subject", value: "Needle")]))
                    _ = try MailMessageImporter.apply(FetchedMessage(wire: wire, floor: 1,
                        headers: MessageHeaders(payload: wire.payload), structure: nil), account: account, myAddresses: [account], in: db)
                }
            }
            try db.execute(sql: "UPDATE account SET checkpoint='1'")
        }
        return queue
    }
    private func delta(_ id: String, labels: [String]? = nil) -> GmailHistoryChange {
        GmailHistoryChange(message: GmailMessage(id: id, threadId: "t" + id.dropFirst()), labelIds: labels)
    }
    private func labels(_ db: Database, account: String = "a@example.com") throws -> Set<String> {
        Set(try String.fetchAll(db, sql: "SELECT l.gmail_id FROM message_label ml JOIN label l ON l.label_pk=ml.label_pk JOIN account a ON a.account_pk=l.account_pk WHERE a.email=?", arguments: [account]))
    }

    func testPageChangesAndCheckpointRollBackTogether() throws {
        let queue = try database()
        let page = GmailHistoryPage(history: [GmailHistoryRecord(id: 2, labelsAdded: [delta("m0", labels: ["STARRED"])])], historyId: 9)
        enum Injected: Error { case failure }
        XCTAssertThrowsError(try queue.write { db in
            _ = try MailHistoryIndex.apply(page, account: "a@example.com", after: 1, nowMS: 100, in: db)
            throw Injected.failure
        })
        try queue.read { db in
            XCTAssertEqual(try labels(db), ["INBOX"])
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT checkpoint FROM account WHERE email='a@example.com'"), "1")
        }
        try queue.write { db in
            let applied = try MailHistoryIndex.apply(page, account: "a@example.com", after: 1, nowMS: 100, in: db)
            XCTAssertEqual(applied.checkpoint, 9)
            XCTAssertEqual(try labels(db), ["INBOX", "STARRED"])
            XCTAssertEqual(try labels(db, account: "b@example.com"), ["INBOX"])
        }
    }

    func testIntermediatePageUsesLastRecordAndStaleWorkerCannotOverwriteIt() throws {
        let queue = try database()
        let page = GmailHistoryPage(history: [GmailHistoryRecord(id: 2, labelsRemoved: [delta("m0", labels: ["INBOX"])])], nextPageToken: "next", historyId: 10)
        try queue.write { db in
            XCTAssertEqual(try MailHistoryIndex.apply(page, account: "a@example.com", after: 1, nowMS: 100, in: db).checkpoint, 2)
        }
        XCTAssertThrowsError(try queue.write { try MailHistoryIndex.apply(page, account: "a@example.com", after: 1, nowMS: 101, in: $0) })
        try queue.read { XCTAssertEqual(try String.fetchOne($0, sql: "SELECT checkpoint FROM account WHERE email='a@example.com'"), "2") }
    }

    func testPositiveDeletionRemovesSearchAndMembershipsOnlyForItsAccount() throws {
        let queue = try database()
        try queue.write { db in
            let page = GmailHistoryPage(history: [GmailHistoryRecord(id: 2, messagesDeleted: [delta("m0")])], historyId: 2)
            let value = try MailHistoryIndex.apply(page, account: "a@example.com", after: 1, nowMS: 100, in: db)
            XCTAssertEqual(value.deleted, ["m0"])
            XCTAssertTrue(value.held.isEmpty)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM message"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM mail_header_search"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM tombstone"), 1)
            XCTAssertEqual(try labels(db, account: "b@example.com"), ["INBOX"])
        }
    }

    func testDeletionHoldSurvivesPagesWhileCheckpointAdvances() throws {
        let queue = try database(count: 50)
        try queue.write { db in
            for batch in 0..<3 {
                let removed = (batch * 10..<batch * 10 + 10).map { delta("m\($0)") }
                let id = UInt64(batch + 2)
                let page = GmailHistoryPage(history: [GmailHistoryRecord(id: id, messagesDeleted: removed)], historyId: id)
                let value = try MailHistoryIndex.apply(page, account: "a@example.com", after: id - 1, nowMS: Int64(100 + batch), in: db)
                XCTAssertEqual(value.deleted.count, batch == 0 ? 10 : 0)
                XCTAssertEqual(value.held.count, batch == 0 ? 0 : 10)
            }
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM held_removal"), 20)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM message WHERE account_pk=(SELECT account_pk FROM account WHERE email='a@example.com')"), 40)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT checkpoint FROM account WHERE email='a@example.com'"), "4")
        }
    }

    func testUnknownLabelDeltaCreatesOnlyAnUnfetchedStub() throws {
        let queue = try database()
        try queue.write { db in
            let page = GmailHistoryPage(history: [GmailHistoryRecord(id: 2, labelsAdded: [delta("m9", labels: ["UNREAD"])])], historyId: 2)
            let value = try MailHistoryIndex.apply(page, account: "a@example.com", after: 1, nowMS: 100, in: db)
            XCTAssertEqual(value.fetch, ["m9"])
            let row = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT fetch_state,flags,history_id FROM message WHERE gmail_id='m9'"))
            XCTAssertEqual(row["fetch_state"] as Int, 0)
            XCTAssertFalse(MailMessageFlags(rawValue: row["flags"]).contains(.labelsKnown))
            XCTAssertEqual(row["history_id"] as String, "2")
            XCTAssertEqual(try labels(db), ["INBOX"])
        }
    }

    func testRecentEmptyPollDoesNotWriteAndInvalidContinuationDoesNotAdvance() throws {
        let queue = try database()
        try queue.write { db in
            try db.execute(sql: "UPDATE account SET last_sync_at=100")
            let before = db.totalChangesCount
            let value = try MailHistoryIndex.apply(GmailHistoryPage(historyId: 2), account: "a@example.com", after: 1, nowMS: 101, in: db)
            XCTAssertEqual(value.checkpoint, 1)
            XCTAssertEqual(db.totalChangesCount, before)
        }
        XCTAssertThrowsError(try queue.write { db in
            try MailHistoryIndex.apply(GmailHistoryPage(nextPageToken: "next", historyId: 2), account: "a@example.com", after: 1, nowMS: 101, in: db)
        })
    }

    func testAtomicHistoryPageCost() throws {
        let queue = try database(count: 100, onDisk: true)
        var samples: [Double] = []
        for trial in 0..<6 {
            let version = UInt64(trial + 2)
            let changes = (0..<100).map { delta("m\($0)", labels: ["STARRED"]) }
            let record = GmailHistoryRecord(id: version,
                labelsAdded: trial % 2 == 0 ? changes : nil,
                labelsRemoved: trial % 2 == 0 ? nil : changes)
            let page = GmailHistoryPage(history: [record], historyId: version)
            let start = ContinuousClock.now
            let result = try queue.write {
                try MailHistoryIndex.apply(page, account: "a@example.com", after: version - 1, nowMS: Int64(trial + 100), in: $0)
            }
            let elapsed = start.duration(to: .now).components
            samples.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
            XCTAssertEqual(result.change.conversations.count, 100)
            XCTAssertEqual(result.checkpoint, version)
        }
        if let path = ProcessInfo.processInfo.environment["MAIL_HISTORY_INDEX_BENCHMARK_OUTPUT"] {
            let data = try JSONSerialization.data(withJSONObject: ["samplesMS": samples,
                "scope": "100 distinct conversations per atomic history page in actual MailStores disk index; first/five warm transactions. Excludes crash/power-loss, UI, device and eviction acceptance."], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path))
        }
        for sample in samples { XCTAssertLessThan(sample, 100) }
    }
}
