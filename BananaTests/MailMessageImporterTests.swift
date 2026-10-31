import XCTest
import GRDB

final class MailMessageImporterTests: XCTestCase {
    private func stores() async throws -> MailStores {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-import-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try await Task.detached { try MailStores.open(MailDirectories(root: root), migrations: MailSlices.migrations()) }.value
    }
    private func fetched(_ json: String, floor: UInt64 = 1) throws -> FetchedMessage {
        let wire = try JSONDecoder().decode(GmailMessage.self, from: Data(json.utf8))
        return FetchedMessage(wire: wire, floor: floor, headers: MessageHeaders(payload: wire.payload), structure: nil)
    }
    private let original = #"{"id":"m1","threadId":"t1","historyId":"20","internalDate":"123000","labelIds":["INBOX","UNREAD"],"snippet":"Hello","payload":{"headers":[{"name":"From","value":"Sender <sender@example.com>"},{"name":"To","value":"a@example.com"},{"name":"Subject","value":"Subject"}]}}"#
    private func rows(_ stores: MailStores, view: MailViewKey = .unified(.inbox)) async throws -> [IndexRow] {
        try await MailIndexReader(stores: stores).page(PageRequest(view: view, account: nil, filters: [], before: nil, limit: 50))
    }
    func testArrivalBoundaryImportCostAgainstTriggerAblation() async throws {
        let reference = try await stores(), current = try await stores()
        // Isolated temporary control only: identical importer/schema, arrival triggers off.
        try await reference.index.write {
            try $0.execute(sql: "DROP TRIGGER message_arrival_insert; DROP TRIGGER message_arrival_move")
        }
        let writers = [MailWriter(stores: reference, sink: nil), MailWriter(stores: current, sink: nil)]
        var samples: [[Double]] = [[], []]
        for batch in 0..<8 {
            let values = (0..<20).map { index -> FetchedMessage in
                let id = "m\(batch)-\(index)"
                let wire = GmailMessage(id: id, threadId: id, labelIds: ["INBOX", "UNREAD"], historyId: 1, internalDate: Int64(1000 + batch * 20 + index),
                    payload: GmailPart(headers: [GmailHeader(name: "Subject", value: "Import \(id)")]))
                return FetchedMessage(wire: wire, floor: 1, headers: MessageHeaders(payload: wire.payload), structure: nil)
            }
            for variant in (batch % 2 == 0 ? [0, 1] : [1, 0]) {
                let start = ContinuousClock.now
                _ = try await writers[variant].transact { db in
                    var change = MailStoreChange()
                    for value in values {
                        change.formUnion(try MailMessageImporter.apply(value, account: "a@example.com", myAddresses: ["a@example.com"], in: db))
                    }
                    return change
                }
                let duration = start.duration(to: .now).components
                samples[variant].append(Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15)
            }
        }
        let old = try await rows(reference), new = try await rows(current)
        XCTAssertEqual(old.map(\.thread), new.map(\.thread))
        XCTAssertEqual(old.map(\.subject), new.map(\.subject))
        XCTAssertTrue(new.allSatisfy { ($0.actionBoundary ?? 0) > 0 })
        if let path = ProcessInfo.processInfo.environment["MAIL_IMPORT_BENCHMARK_OUTPUT"] {
            let data = try JSONSerialization.data(withJSONObject: ["batchSize": 20,
                "samplesMS": ["withoutArrivalTriggers": samples[0], "withArrivalTriggers": samples[1]],
                "scope": "Alternating disk import batches; first then warm; temporary trigger ablation, not UI or eviction acceptance"], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path))
        }
        for values in samples { for value in values { XCTAssertLessThan(value, 100) } }
    }
    func testFetchedMetadataFeedsConversationRows() async throws {
        let stores = try await stores(), value = try fetched(original)
        _ = try await stores.index.write { db in
            try MailMessageImporter.apply(value, account: "A@EXAMPLE.COM", myAddresses: ["a@example.com"], in: db)
        }
        let rows = try await rows(stores)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.subject, "Subject")
        XCTAssertEqual(rows.first?.people.first?.a, "sender@example.com")
        XCTAssertEqual(rows.first?.account, "a@example.com")
        XCTAssertEqual(rows.first?.unread, true)
        let state = try await stores.index.read { try Int.fetchOne($0, sql: "SELECT fetch_state FROM message") }
        XCTAssertEqual(state, 1)
    }
    func testPartialAndStaleResponsesPreserveKnownData() async throws {
        let stores = try await stores()
        let values = try [fetched(original), fetched(#"{"id":"m1","threadId":"t1","historyId":"21"}"#),
            fetched(#"{"id":"m1","threadId":"t1","historyId":"21","payload":{"headers":[{"name":"Subject","value":null}]}}"#),
            fetched(#"{"id":"m1","threadId":"t1","historyId":"19","labelIds":[],"snippet":"stale"}"#)]
        for value in values {
            _ = try await stores.index.write { db in
                try MailMessageImporter.apply(value, account: "a@example.com", myAddresses: [], in: db)
            }
        }
        let rows = try await rows(stores)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.subject, "Subject")
        XCTAssertEqual(rows.first?.snippet, "Hello")
        XCTAssertEqual(rows.first?.unread, true)
    }
    func testNewerLabelsReplaceProviderStateButKeepLocalOverlay() async throws {
        let stores = try await stores(), value = try fetched(original)
        _ = try await stores.index.write { db in
            try MailMessageImporter.apply(value, account: "a@example.com", myAddresses: [], in: db)
            try db.execute(sql: "INSERT INTO overlay(msg_pk,label_pk,want) SELECT m.msg_pk,l.label_pk,0 FROM message m,label l WHERE l.gmail_id='INBOX'")
        }
        let refresh = try fetched(original, floor: 30)
        _ = try await stores.index.write { db in
            try MailMessageImporter.apply(refresh, account: "a@example.com", myAddresses: [], in: db)
        }
        let inbox = try await rows(stores)
        let done = try await rows(stores, view: .done(account: nil))
        XCTAssertTrue(inbox.isEmpty)
        XCTAssertEqual(done.count, 1)
        XCTAssertEqual(done.first?.pending, 1)
        let rawInbox = try await stores.index.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM message_label ml JOIN label l ON l.label_pk=ml.label_pk WHERE l.gmail_id='INBOX'") }
        XCTAssertEqual(rawInbox, 1)
    }
    func testTombstonePreventsResurrection() async throws {
        let stores = try await stores(), value = try fetched(original)
        _ = try await stores.index.write { db in
            try db.execute(sql: "INSERT INTO account(account_pk,email) VALUES (1,'a@example.com')")
            try db.execute(sql: "INSERT INTO tombstone VALUES (1,'m1',1)")
            try MailMessageImporter.apply(value, account: "a@example.com", myAddresses: [], in: db)
        }
        let count = try await stores.index.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM message") }
        XCTAssertEqual(count, 0)
    }
    func testThreadIdentityMismatchRollsBack() async throws {
        let stores = try await stores(), value = try fetched(original)
        _ = try await stores.index.write { db in
            try MailMessageImporter.apply(value, account: "a@example.com", myAddresses: [], in: db)
        }
        let wrong = try fetched(#"{"id":"m1","threadId":"different","historyId":"30"}"#)
        do {
            _ = try await stores.index.write { db in
                try MailMessageImporter.apply(wrong, account: "a@example.com", myAddresses: [], in: db)
            }
            XCTFail()
        } catch MailMessageImporter.Failure.changedThread {}
        let count = try await stores.index.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM thread") }
        XCTAssertEqual(count, 1)
    }
    func testExplicitEmptyLabelsRemoveInboxWithoutDeletingMessage() async throws {
        let stores = try await stores(), value = try fetched(original)
        _ = try await stores.index.write { db in
            try MailMessageImporter.apply(value, account: "a@example.com", myAddresses: [], in: db)
        }
        let cleared = try fetched(#"{"id":"m1","threadId":"t1","historyId":"22","labelIds":[]}"#)
        _ = try await stores.index.write { db in
            try MailMessageImporter.apply(cleared, account: "a@example.com", myAddresses: [], in: db)
        }
        let inbox = try await rows(stores)
        let all = try await rows(stores, view: .allMail(account: nil))
        XCTAssertTrue(inbox.isEmpty)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.subject, "Subject")
        XCTAssertEqual(all.first?.unread, false)
    }
    func testRepeatedImportDoesNotDuplicateAndAccountIDsAreIndependent() async throws {
        let stores = try await stores(), value = try fetched(original)
        for account in ["a@example.com", "b@example.com", "a@example.com"] {
            _ = try await stores.index.write { db in
                try MailMessageImporter.apply(value, account: account, myAddresses: [account], in: db)
            }
        }
        let rows = try await rows(stores)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.account)), ["a@example.com", "b@example.com"])
        let count = try await stores.index.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM message") }
        XCTAssertEqual(count, 2)
    }
}
