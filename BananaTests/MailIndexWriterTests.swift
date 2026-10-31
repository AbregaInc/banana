import XCTest
import GRDB

final class MailIndexWriterTests: XCTestCase {
    private func stores() async throws -> MailStores {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-writer-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let stores = try await Task.detached {
            try MailStores.open(MailDirectories(root: root), migrations: MailSlices.migrations())
        }.value
        try await stores.index.write { db in
            try db.execute(sql: "INSERT INTO account(account_pk,email) VALUES (1,'a@example.com'),(2,'b@example.com')")
            try db.execute(sql: "INSERT INTO thread(thread_pk,account_pk,gmail_id,tie,attended_at,wake_at) VALUES (1,1,'same-id',1,42,99),(2,2,'same-id',2,NULL,NULL)")
        }
        return stores
    }
    private func fact(labels: Set<String> = ["INBOX", "UNREAD"], date: Int64 = 100) -> MessageFacts {
        MessageFacts(gmailID: "m1", internalDate: date, fetchState: 1, vis: 0, labels: labels,
            labelsKnown: true, bananaLabels: [], fromName: "Sender", fromAddress: "sender@example.com",
            isFromMe: false, toAddresses: ["a@example.com"], ccAddresses: [], subject: "Real subject",
            snippet: "Preview", hasAttachment: false, hasInvite: false, listID: nil,
            hasUndeliveredIntent: false, hasRefusedIntent: false)
    }
    private func page(_ view: MailViewKey) -> PageRequest {
        PageRequest(view: view, account: nil, filters: [], before: nil, limit: 50)
    }
    func testCommittedSummaryFeedsRealReaderAndSurvivesReopen() async throws {
        let stores = try await stores(), facts = [fact()]
        _ = try await stores.index.write { db in
            try MailIndexWriter.rebuildThread(1, facts: facts, myAddresses: ["a@example.com"], in: db)
        }
        let directories = stores.directories
        try stores.searchReader.close()
        try stores.searchWriter.close()
        try stores.blobs.close()
        try stores.index.close()
        // Reopen independently to verify persisted rows rather than an in-memory return value.
        let reopened = try await Task.detached { try MailStores.open(directories, migrations: MailSlices.migrations()) }.value
        let rows = try await MailIndexReader(stores: reopened).page(page(.unified(.inbox)))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.subject, "Real subject")
        XCTAssertEqual(rows.first?.people.first?.a, "sender@example.com")
        XCTAssertEqual(rows.first?.recipients.first?.a, "a@example.com")
        XCTAssertEqual(rows.first?.wakeAt, 99)
        let attention = try await reopened.index.read { try Int.fetchOne($0, sql: "SELECT attended_at FROM thread WHERE thread_pk=1") }
        XCTAssertEqual(attention, 42)
    }
    func testLabelReplacementMovesMembershipWithoutDuplicates() async throws {
        let stores = try await stores(), original = [fact()], archived = [fact(labels: ["STARRED"], date: 200)]
        for facts in [original, archived, archived] {
            let change = try await stores.index.write { db in
                try MailIndexWriter.rebuildThread(1, facts: facts, myAddresses: [], in: db)
            }
            XCTAssertEqual(change.conversations, [MailConversationID(account: "a@example.com", thread: "same-id")])
            XCTAssertTrue(change.viewKeys.contains(try MailIndexReader.viewKey(.allMail(account: nil))))
        }
        let reader = MailIndexReader(stores: stores)
        let inbox = try await reader.page(page(.unified(.inbox)))
        let done = try await reader.page(page(.done(account: nil)))
        let stars = try await reader.page(page(.unified(.starred)))
        XCTAssertTrue(inbox.isEmpty)
        XCTAssertEqual(done.map(\.threadPK), [1])
        XCTAssertEqual(stars.map(\.threadPK), [1])
        XCTAssertEqual(stars.first?.sortKey, 200)
        XCTAssertEqual(stars.first?.unread, false)
    }
    func testSameProviderThreadIDStaysAccountIsolated() async throws {
        let stores = try await stores(), facts = [fact()]
        try await stores.index.write { db in
            try MailIndexWriter.rebuildThread(1, facts: facts, myAddresses: [], in: db)
            try MailIndexWriter.rebuildThread(2, facts: facts, myAddresses: [], in: db)
        }
        let reader = MailIndexReader(stores: stores)
        let all = try await reader.page(page(.unified(.inbox)))
        let account = try await reader.page(page(.label(account: "a@example.com", labelID: "INBOX")))
        XCTAssertEqual(Set(all.map(\.account)), ["a@example.com", "b@example.com"])
        XCTAssertEqual(account.map(\.threadPK), [1])
    }
    func testFailureRollsBackSummaryAndMembershipTogether() async throws {
        enum Injected: Error { case failed }
        let stores = try await stores(), facts = [fact()]
        do {
            try await stores.index.write { db in
                try MailIndexWriter.rebuildThread(1, facts: facts, myAddresses: [], in: db)
                throw Injected.failed
            }
            XCTFail()
        } catch Injected.failed {}
        let rows = try await MailIndexReader(stores: stores).page(page(.unified(.inbox)))
        XCTAssertTrue(rows.isEmpty)
        let count = try await stores.index.read { try Int.fetchOne($0, sql: "SELECT message_count FROM thread WHERE thread_pk=1") }
        XCTAssertEqual(count, 0)
    }
    func testRefreshPreservesSchedulerMembershipAndExistingLabelMetadata() async throws {
        let stores = try await stores(), facts = [fact()]
        let snoozed = try MailIndexReader.viewKey(.snoozed)
        try await stores.index.write { db in
            try db.execute(sql: "INSERT INTO view(view_pk,key,kind) VALUES (10,?,4)", arguments: [snoozed])
            try db.execute(sql: "INSERT INTO view_thread VALUES (10,99,1,1,0)")
            try db.execute(sql: "INSERT INTO label(account_pk,gmail_id,name,kind,background_color) VALUES (1,'INBOX','Inbox',0,'#123456')")
            try MailIndexWriter.rebuildThread(1, facts: facts, myAddresses: [], in: db)
        }
        let rows = try await MailIndexReader(stores: stores).page(page(.snoozed))
        XCTAssertEqual(rows.map(\.threadPK), [1])
        XCTAssertEqual(rows.first?.sortKey, 99)
        let color = try await stores.index.read { try String.fetchOne($0, sql: "SELECT background_color FROM label WHERE gmail_id='INBOX'") }
        XCTAssertEqual(color, "#123456")
    }
}
