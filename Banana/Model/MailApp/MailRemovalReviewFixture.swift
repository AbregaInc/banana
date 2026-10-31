#if !BANANA_PUBLIC
#if DEBUG && targetEnvironment(simulator)
import Foundation
import GRDB

/// Explicit, network-disabled Simulator UI fixture. It never opens the normal
/// BananaMail directory or changes account consent. Normal builds do not select it.
enum MailRemovalReviewFixture {
    static var enabled: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--stress-days") && arguments.contains("--mail-removal-review")
    }
    @MainActor private final class Access: MailAccountAccess {
        var connectedAccountIDs: [String] { ["fixture@example.com"] }
        func mailGrant(accountID: String) -> MailGrant { .none }
        func mailAccessToken(accountID: String) async throws -> MailAccessToken { throw MailAccessError.notGranted }
        func dropMailAccessToken(accountID: String) {}
        func requestMailAccess(accountID: String) async -> MailAccessOutcome { .cancelled }
        func forgetMailAccess(accountID: String) async throws {}
        func cancelMailTokenRequests() {}
    }
    @MainActor static func make() async throws -> MailLiveSource {
        let reset = ProcessInfo.processInfo.arguments.contains("--reset-mail-removal-review")
        let (stores, intent) = try await Task.detached {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("MailRemovalReviewFixture.noindex", isDirectory: true)
            if reset, FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
            let directories = try MailDirectories(root: root)
            return (try MailStores.open(directories, migrations: MailSlices.migrations()), try MailIntentStore(directories: directories))
        }.value
        let seeded = try await stores.index.read { try String.fetchOne($0, sql: "SELECT value FROM meta WHERE key='removal-fixture-v1'") != nil }
        if !seeded {
            let blobs = MailBlobStore(stores: stores)
            for index in 1...52 {
                let suffix = String(format: "%03d", index)
                let wire = GmailMessage(id: "held-" + suffix, threadId: "thread-" + suffix, labelIds: ["INBOX"], historyId: 1,
                    internalDate: 1_791_000_000_000 + Int64(index), payload: GmailPart(partId: "body", mimeType: "text/plain",
                    headers: [GmailHeader(name: "Subject", value: "Removed fixture " + suffix),
                              GmailHeader(name: "From", value: "Fixture Sender <sender@example.com>")],
                    body: GmailPartBody(data: Data("Saved fixture body \(index)".utf8).base64EncodedString())))
                let pk = try await stores.index.write { db -> Int64 in
                    _ = try MailMessageImporter.apply(FetchedMessage(wire: wire, floor: 1, headers: MessageHeaders(payload: wire.payload), structure: nil), account: "fixture@example.com", myAddresses: ["fixture@example.com"], in: db)
                    let pk = try Int64.fetchOne(db, sql: "SELECT msg_pk FROM message WHERE gmail_id=?", arguments: [wire.id])!
                    try db.execute(sql: "INSERT OR IGNORE INTO held_removal(msg_pk,evidence,found_at) VALUES(?,1,1)", arguments: [pk])
                    return pk
                }
                try await blobs.put(wire, account: "fixture@example.com", extraction: MIMEStructure.extract(wire.payload!), ftsRowID: pk, at: 1)
                _ = try await blobs.prepare(account: "fixture@example.com", messageID: wire.id!, at: 1)
                try await stores.index.write { try $0.execute(sql: "UPDATE message SET fetch_state=2,prep_state=2 WHERE msg_pk=?", arguments: [pk]) }
            }
            try await stores.index.write { try $0.execute(sql: "INSERT INTO meta(key,value) VALUES('removal-fixture-v1','1')") }
        }
        let source = MailLiveSource(stores: stores, access: Access(), api: GmailHTTP(networkAllowed: { false }))
        try await source.prepareActions(intent: intent)
        try await source.loadRemovalStatus()
        return source
    }
}
#endif

#endif
