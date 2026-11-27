#if !BANANA_PUBLIC
import GRDB

/// Each source records changes in the transaction that changes the searchable text. The derived
/// index acknowledges precisely the version it committed, so an interrupted replacement is retried.
enum MailRankedSchema {
    static func register(in migrations: inout MailMigrations) {
        migrations.index.registerMigration("mail-ranked-messages-v1") { db in
            try epoch(db)
            try db.execute(
                sql: """
                    CREATE TABLE ranked_dirty(msg INTEGER PRIMARY KEY, version BLOB NOT NULL);
                    CREATE TABLE ranked_hint(msg INTEGER NOT NULL, kind INTEGER NOT NULL, term TEXT NOT NULL,
                        account INTEGER NOT NULL, date INTEGER NOT NULL, PRIMARY KEY(msg,kind,term)) WITHOUT ROWID;
                    CREATE INDEX ranked_hint_lookup ON ranked_hint(kind,term,account,date DESC,msg DESC);
                    """)
            let fields = [
                "subject", "snippet", "from_name", "from_addr", "recipients", "fts_state", "internal_date",
                "account_pk", "gmail_id", "thread_pk",
            ]
            let changed = fields.map { "old." + $0 + " IS NOT new." + $0 }.joined(separator: " OR ")
            for (event, ref, condition) in [
                ("INSERT", "new", ""), ("DELETE", "old", ""),
                ("UPDATE OF " + fields.joined(separator: ","), "new", " WHEN " + changed),
            ] {
                try db.execute(
                    sql: """
                        CREATE TRIGGER ranked_message_\(ref)_\(event.prefix(3)) AFTER \(event) ON message\(condition) BEGIN
                        INSERT INTO ranked_dirty VALUES(\(ref).msg_pk,randomblob(16)) ON CONFLICT(msg) DO UPDATE SET version=excluded.version; END
                        """)
            }
        }
        migrations.blobs.registerMigration("mail-ranked-attachments-and-text-v1") { db in
            try epoch(db)
            try db.execute(
                sql: """
                    CREATE TABLE ranked_blob_dirty(account TEXT NOT NULL, gmail_id TEXT NOT NULL, version BLOB NOT NULL,
                        PRIMARY KEY(account,gmail_id)) WITHOUT ROWID;
                    """)
            for (table, column) in [("prepared", "text"), ("attachment", "filename,inline"), ("content", "structure")] {
                try db.execute(
                    sql: """
                        CREATE TRIGGER ranked_\(table)_move AFTER UPDATE OF account,gmail_id ON \(table)
                        WHEN old.account IS NOT new.account OR old.gmail_id IS NOT new.gmail_id BEGIN
                        INSERT INTO ranked_blob_dirty VALUES(old.account,old.gmail_id,randomblob(16))
                            ON CONFLICT(account,gmail_id) DO UPDATE SET version=excluded.version;
                        INSERT INTO ranked_blob_dirty VALUES(new.account,new.gmail_id,randomblob(16))
                            ON CONFLICT(account,gmail_id) DO UPDATE SET version=excluded.version; END
                        """)
                for (event, ref) in [("INSERT", "new"), ("DELETE", "old"), ("UPDATE OF " + column, "new")] {
                    try db.execute(
                        sql: """
                            CREATE TRIGGER ranked_\(table)_\(event.prefix(3)) AFTER \(event) ON \(table) BEGIN
                            INSERT INTO ranked_blob_dirty VALUES(\(ref).account,\(ref).gmail_id,randomblob(16)) ON CONFLICT(account,gmail_id) DO UPDATE SET version=excluded.version; END
                            """)
                }
            }
        }
    }

    private static func epoch(_ db: Database) throws {
        try db.execute(
            sql:
                "CREATE TABLE ranked_epoch(id TEXT NOT NULL); INSERT INTO ranked_epoch VALUES(lower(hex(randomblob(16))))"
        )
    }
}
#endif
