#if !BANANA_PUBLIC
import Foundation
import GRDB

enum MailSyncFill {
    struct Item: Sendable { var key: Int64; var id: MailMessageID }
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v7-sync-fill-queue") { db in
            try db.execute(sql: "CREATE INDEX message_sync_fill ON message(account_pk,msg_pk) WHERE (fetch_state<2 OR prep_state=0) AND vis!=4")
        }
    }
    static func page(account: String, after: Int64, in db: Database) throws -> [Item] {
        try Row.fetchAll(db, sql: """
            SELECT m.msg_pk,m.gmail_id FROM message m
            WHERE m.account_pk=(SELECT account_pk FROM account WHERE email=?) AND m.msg_pk>?
              AND (m.fetch_state<2 OR m.prep_state=0) AND m.vis!=4
              AND NOT EXISTS(SELECT 1 FROM held_removal h WHERE h.msg_pk=m.msg_pk)
            ORDER BY m.msg_pk LIMIT 16
            """, arguments: [account, after]).map { Item(key: $0[0], id: MailMessageID(account: account, message: $0[1])) }
    }
}

#endif
