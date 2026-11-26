import XCTest
import GRDB

/// The steps `MailApplication.start()` takes before the inbox can show rows, timed against a
/// large mailbox on disk. Each iteration reopens the stores as a new launch does; the OS file
/// cache stays warm, so these are lower bounds for a first launch after a reboot.
@MainActor
final class MailColdStartCostTests: XCTestCase {
    private final class Access: MailAccountAccess {
        var connectedAccountIDs = ["a@example.com", "b@example.com"]
        func mailGrant(accountID: String) -> MailGrant { .granted }
        func mailAccessToken(accountID: String) async throws -> MailAccessToken {
            MailAccessToken(value: "fixture", scopes: [MailScopes.gmailModify])
        }
        func dropMailAccessToken(accountID: String) {}
        func requestMailAccess(accountID: String) async -> MailAccessOutcome { .granted }
        func forgetMailAccess(accountID: String) async throws {}
        func cancelMailTokenRequests() {}
    }

    private func populate(root: URL, count: Int) async throws {
        let stores = try await Task.detached {
            try MailStores.open(MailDirectories(root: root), migrations: MailSlices.migrations())
        }.value
        let key = try MailIndexReader.viewKey(.unified(.inbox))
        try await stores.index.write { db in
            try db.execute(sql: "INSERT INTO account(account_pk,email) VALUES (1,'a@example.com'),(2,'b@example.com')")
            try db.execute(sql: "INSERT INTO view(view_pk,key,kind) VALUES (1,?,1)", arguments: [key])
            try db.execute(sql: """
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n < ?)
                INSERT INTO thread(thread_pk,account_pk,gmail_id,tie,last_date,message_count,flags,subject,
                                   people,people_total,recipients,recipients_total)
                SELECT n,1+n%2,'thread-'||n,n,1000000+n/3,1,
                       512 + CASE WHEN n%5=0 THEN 1 ELSE 0 END + CASE WHEN n%7=0 THEN 32 ELSE 0 END,
                       'Subject '||n,'[]',0,'[{"a":"to@example.com","u":false,"isMe":false}]',1
                FROM seq
                """, arguments: [count])
            // Three messages per conversation, as a real mailbox has: work that walks every
            // message at startup has to show up here.
            try db.execute(sql: """
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n < ?)
                INSERT INTO message(msg_pk,account_pk,gmail_id,thread_pk,internal_date,fetch_state,prep_state,
                                    flags,from_addr,from_name,subject,snippet,recipients)
                SELECT n,1+((n+2)/3)%2,'msg-'||n,(n+2)/3,1000000000+n,2,2,64,
                       'sender'||(n%500)||'@example.com','Sender '||(n%500),'Subject '||((n+2)/3),
                       'A realistic snippet of the message body that runs to about one hundred characters '||n,
                       '{"to":["to@example.com"]}'
                FROM seq
                """, arguments: [count * 3])
            try db.execute(sql: """
                INSERT INTO view_thread(view_pk,sort_key,tie,thread_pk,unread)
                SELECT 1,last_date,tie,thread_pk,CASE WHEN thread_pk%3=0 THEN 1 ELSE 0 END FROM thread
                """)
        }
        // The app's writer checkpoints whenever the log passes 8 MiB; this bulk insert went
        // around it, so do the same here, or every later open replays hundreds of megabytes.
        try await stores.index.writeWithoutTransaction { try $0.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
    }

    func testColdStartStepsBeforeTheFirstInboxRows() async throws {
        // Built by an earlier process when `MAIL_COLD_START_REUSE` is set, so the first
        // iteration is a fresh process opening an existing mailbox, as a launch does.
        // A benchmark, not a check: it builds 540,000 messages. Run it on purpose with
        // `TEST_RUNNER_MAIL_COLD_START_REUSE=1`, twice, and read the second process.
        let reuse = ProcessInfo.processInfo.environment["MAIL_COLD_START_REUSE"] != nil
        try XCTSkipUnless(reuse, "Set MAIL_COLD_START_REUSE to run the cold-start benchmark")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(reuse ? "mail-cold-reused-checkpointed" : "mail-cold-" + UUID().uuidString)
        if !reuse { addTeardownBlock { try? FileManager.default.removeItem(at: root) } }
        if !FileManager.default.fileExists(atPath: root.path) { try await populate(root: root, count: 180_000) }
        print("REUSED_FIXTURE", reuse && FileManager.default.fileExists(atPath: root.appendingPathComponent(".built").path))
        if reuse { FileManager.default.createFile(atPath: root.appendingPathComponent(".built").path, contents: nil) }

        var samples: [String: [Double]] = [:]
        func ms(_ duration: Duration) -> Double {
            Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        }
        let clock = ContinuousClock()
        for _ in 0..<5 {
            let launch = clock.now
            let (stores, intent) = try await Task.detached(priority: .userInitiated) {
                let directories = try MailDirectories(root: root)
                return (try MailStores.open(directories, migrations: MailSlices.migrations()),
                        try MailIntentStore(directories: directories))
            }.value
            let opened = clock.now
            let source = MailLiveSource(stores: stores, access: Access(), api: GmailPageLoaderTests.Provider(count: 0))
            let made = clock.now
            try await source.prepareActions(intent: intent)
            let prepared = clock.now
            var rows = 0
            let delivered = expectation(description: "first inbox rows")
            delivered.assertForOverFulfill = false
            source.setVisible(true)
            let visible = clock.now
            let observation = source.observeList(MailScope(place: .mailbox(.inbox)), limit: 50) { snapshot in
                if !snapshot.rows.isEmpty, rows == 0 { rows = snapshot.rows.count; delivered.fulfill() }
            }
            await fulfillment(of: [delivered], timeout: 10)
            let firstRows = clock.now
            observation.cancel()
            source.setVisible(false)
            XCTAssertEqual(rows, 50)
            samples["openStores", default: []].append(ms(opened - launch))
            samples["makeSource", default: []].append(ms(made - opened))
            samples["prepareActions", default: []].append(ms(prepared - made))
            samples["becomeVisible", default: []].append(ms(visible - prepared))
            samples["firstInboxRows", default: []].append(ms(firstRows - visible))
            samples["total", default: []].append(ms(firstRows - launch))
        }
        let summary = samples.mapValues { values in values.map { ($0 * 100).rounded() / 100 } }
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
        print("MAIL_COLD_START_MS", String(decoding: data, as: UTF8.self))
        add(XCTAttachment(data: data, uniformTypeIdentifier: "public.json"))
    }
}
