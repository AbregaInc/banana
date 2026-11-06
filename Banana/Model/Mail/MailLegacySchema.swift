#if !BANANA_PUBLIC
import GRDB

/// Schema steps shipped in earlier Beta installs. Keep their data and reject genuinely unknown schemas.
enum MailLegacySchema {
    static func registerIndex(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v8-download-retry") { db in
            try db.execute(sql: """
                CREATE TABLE download_retry (
                    account TEXT NOT NULL, kind TEXT NOT NULL, id TEXT NOT NULL,
                    attempts INTEGER NOT NULL, retry_at REAL NOT NULL,
                    PRIMARY KEY(account,kind,id))
                """)
        }
        migrator.registerMigration("v9-send-as-directory") { db in
            try db.execute(sql: "CREATE TABLE send_as(account TEXT NOT NULL,address TEXT NOT NULL,record BLOB NOT NULL,PRIMARY KEY(account,address)) WITHOUT ROWID")
        }
        migrator.registerMigration("v10-block-rules") { db in try db.execute(sql: blockSchema) }
        migrator.registerMigration("v11-latest-mail-fill") { db in
            try db.execute(sql: """
                CREATE INDEX message_header_recent ON message(account_pk, length(history_id) DESC, history_id DESC, msg_pk)
                    WHERE fetch_state=0 AND vis!=4;
                CREATE INDEX message_body_recent ON message(account_pk, internal_date DESC, msg_pk DESC)
                    WHERE fetch_state>0 AND (fetch_state<2 OR prep_state=0) AND vis!=4;
                """)
        }
        migrator.registerMigration("v12-durable-header-priority") { db in
            try db.execute(sql: """
                ALTER TABLE message ADD COLUMN header_history TEXT;
                DROP INDEX message_header_recent;
                CREATE INDEX message_header_recent ON message(account_pk, length(header_history) DESC, header_history DESC, msg_pk)
                    WHERE fetch_state=0 AND vis!=4;
                """)
        }
        migrator.registerMigration("v13-known-header-dates") { db in
            try db.execute(sql: """
                DROP INDEX message_header_recent;
                CREATE INDEX message_header_recent ON message(account_pk, length(header_history) DESC, header_history DESC, internal_date DESC, msg_pk)
                    WHERE fetch_state=0 AND vis!=4;
                """)
        }
    }
    static func registerIntent(in migrations: inout DatabaseMigrator) {
        migrations.registerMigration("v6-local-drafts") { db in
            try db.execute(sql: """
                CREATE TABLE draft(
                    id TEXT PRIMARY KEY,account TEXT NOT NULL,version INTEGER NOT NULL,
                    edited_at REAL NOT NULL,state TEXT NOT NULL,record BLOB NOT NULL,
                    thread TEXT NOT NULL,sort_key INTEGER NOT NULL,tie INTEGER NOT NULL,
                    listed INTEGER NOT NULL,summary BLOB NOT NULL,work_at REAL,blocked INTEGER NOT NULL DEFAULT 0) WITHOUT ROWID;
                CREATE INDEX draft_by_account_date ON draft(account,edited_at DESC,id);
                CREATE INDEX draft_by_state ON draft(state,id);
                CREATE INDEX draft_by_thread ON draft(account,thread,edited_at DESC,id);
                CREATE INDEX draft_by_list ON draft(listed,state,sort_key DESC,tie DESC);
                CREATE INDEX draft_work ON draft(work_at,id) WHERE work_at IS NOT NULL;
                CREATE INDEX draft_access ON draft(blocked,account,id);
                CREATE TABLE draft_action(seq INTEGER PRIMARY KEY,draft_id TEXT NOT NULL,kind TEXT NOT NULL,undone INTEGER NOT NULL DEFAULT 0);
                """)
        }
        migrations.registerMigration("v7-block-rules") { db in
            try db.execute(sql: "CREATE TABLE block_rule(id TEXT PRIMARY KEY,account TEXT NOT NULL,kind TEXT NOT NULL,value TEXT NOT NULL,created_at INTEGER NOT NULL) WITHOUT ROWID")
        }
    }
    private static let blockSchema = """
        CREATE TABLE block_rule(id TEXT PRIMARY KEY,account TEXT NOT NULL,kind TEXT NOT NULL,value TEXT NOT NULL,created_at INTEGER NOT NULL) WITHOUT ROWID;
        CREATE INDEX block_rule_match ON block_rule(account,kind,value);
        CREATE TABLE block_message(msg_pk INTEGER NOT NULL,rule TEXT NOT NULL,pending INTEGER NOT NULL DEFAULT 1,
            PRIMARY KEY(msg_pk,rule)) WITHOUT ROWID;
        CREATE INDEX block_message_pending ON block_message(pending,msg_pk);
        CREATE TRIGGER block_message_deleted AFTER DELETE ON message BEGIN
            DELETE FROM block_message WHERE msg_pk=old.msg_pk;
        END;
        """
}
#endif
