#if !BANANA_PUBLIC
import Foundation
import GRDB

enum MailSyncCheckpoint {
    enum Failure: Error { case transactionRequired }

    /// Invalidate only the history position that the failed request actually used.
    /// Cached messages, held removals and durable user choices are not scan state.
    @discardableResult
    static func expire(account: String, expected: String, in db: Database) throws -> Bool {
        guard db.isInsideTransaction else { throw Failure.transactionRequired }
        guard let owner = try Int64.fetchOne(db, sql: "SELECT account_pk FROM account WHERE email=? AND checkpoint=?",
                                             arguments: [account, expected]) else { return false }
        try db.execute(sql: "DELETE FROM enum_mark WHERE account_pk=?", arguments: [owner])
        // Only reconciliation's requests are superseded. Mutation verification
        // remains pending and cannot become deletion evidence from this failure.
        try db.execute(sql: "DELETE FROM verify_queue WHERE reason=1 AND msg_pk IN (SELECT msg_pk FROM message WHERE account_pk=?)",
                       arguments: [owner])
        try db.execute(sql: "DELETE FROM meta WHERE key=?", arguments: ["reconcile-removal:" + account])
        try db.execute(sql: "UPDATE account SET checkpoint=NULL,enum_state=NULL,enum_checkpoint=NULL WHERE account_pk=?",
                       arguments: [owner])
        return true
    }
}

#endif
