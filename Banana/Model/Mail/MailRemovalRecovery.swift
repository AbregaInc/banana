#if !BANANA_PUBLIC
import Foundation
import GRDB

/// Replays positive index tombstones after a crash between the independent stores.
/// Index transactions must never await the blob writer: blob writes read the index
/// to reject downloads that finish after deletion. Tombstones remain until a future
/// coordinated expiry pass can prove no older work is still in flight.
struct MailRemovalRecovery: Sendable {
    let stores: MailStores
    let intents: MailIntentStore
    enum Failure: Error { case invalidAccount, unsafeAttachmentPath }

    @discardableResult
    func recover(account: String) async throws -> Int {
        guard MailAddressRules.isValid(account), account == account.lowercased() else { throw Failure.invalidAccount }
        var after = ""
        var count = 0
        while true {
            try Task.checkCancellation()
            let boundary = after
            let ids = try await stores.index.read { db in
                try String.fetchAll(db, sql: """
                    SELECT t.gmail_id FROM tombstone t JOIN account a ON a.account_pk=t.account_pk
                    WHERE a.email=? AND t.gmail_id>? ORDER BY t.gmail_id LIMIT 100
                    """, arguments: [account, boundary])
            }
            guard let last = ids.last else { return count }
            try await intents.discardForVerifiedRemoval(account: account, messages: ids)
            for id in ids {
                try Task.checkCancellation()
                // Leave attachment rows until every file deletion succeeds. Replaying
                // a partly completed batch treats already absent files as success.
                let paths = try await stores.blobs.write { db in
                    try db.execute(sql: "DELETE FROM prepared WHERE account=? AND gmail_id=?", arguments: [account, id])
                    try db.execute(sql: "DELETE FROM content WHERE account=? AND gmail_id=?", arguments: [account, id])
                    return try String.fetchAll(db, sql: "SELECT path FROM attachment WHERE account=? AND gmail_id=? AND path IS NOT NULL",
                        arguments: [account, id])
                }
                for path in paths { try removeCachedAttachment(path) }
                try await stores.blobs.write { db in
                    try db.execute(sql: "DELETE FROM attachment WHERE account=? AND gmail_id=?", arguments: [account, id])
                }
            }
            count += ids.count
            after = last
        }
    }

    private func removeCachedAttachment(_ path: String) throws {
        let root = stores.directories.attachments.resolvingSymlinksInPath().standardizedFileURL
        let candidate = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path))
            .resolvingSymlinksInPath().standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else { throw Failure.unsafeAttachmentPath }
        do {
            let values = try candidate.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { throw Failure.unsafeAttachmentPath }
            try FileManager.default.removeItem(at: candidate)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return
        }
    }
}

#endif
