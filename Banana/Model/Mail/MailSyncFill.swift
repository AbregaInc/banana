#if !BANANA_PUBLIC
import Foundation
import GRDB

/// The per-message fill, for an account whose service has no cloud mailbox: every message
/// without its text, newest first (MAIL-ENGINE 5.6), sixteen at a time behind a keyset cursor.
enum MailSyncFill {
    /// Where a walk stands: the last row taken, by (date, row). The walk goes on below it.
    struct Cursor: Equatable, Sendable { var date: Int64; var key: Int64 }
    struct Item: Sendable { var key: Int64; var date: Int64; var id: MailMessageID; var cursor: Cursor { Cursor(date: date, key: key) } }
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v7-sync-fill-queue") { db in
            try db.execute(sql: "CREATE INDEX message_sync_fill ON message(account_pk,msg_pk) WHERE (fetch_state<2 OR prep_state=0) AND vis!=4")
        }
        migrator.registerMigration("v16-sync-fill-newest") { db in
            try db.execute(sql: "DROP INDEX IF EXISTS message_sync_fill")
            try db.execute(sql: """
                CREATE INDEX message_sync_fill_newest ON message(account_pk, internal_date DESC, msg_pk DESC)
                WHERE (fetch_state<2 OR prep_state=0) AND vis!=4
                """)
        }
    }
    static func page(account: String, after: Cursor?, in db: Database) throws -> [Item] {
        let below = after == nil ? "" : "AND (m.internal_date, m.msg_pk) < (?, ?)"
        var arguments: StatementArguments = [account]
        if let after { arguments += [after.date, after.key] }
        return try Row.fetchAll(db, sql: """
            SELECT m.msg_pk,m.internal_date,m.gmail_id FROM message m INDEXED BY message_sync_fill_newest
            WHERE m.account_pk=(SELECT account_pk FROM account WHERE email=?) \(below)
              AND (m.fetch_state<2 OR m.prep_state=0) AND m.vis!=4
              AND NOT EXISTS(SELECT 1 FROM held_removal h WHERE h.msg_pk=m.msg_pk)
            ORDER BY m.internal_date DESC, m.msg_pk DESC LIMIT 16
            """, arguments: arguments).map { Item(key: $0[0], date: $0[1], id: MailMessageID(account: account, message: $0[2])) }
    }
}

#endif
