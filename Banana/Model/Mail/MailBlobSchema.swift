#if !BANANA_PUBLIC
import GRDB

/// Cached original and prepared content from MAIL-ENGINE 4.7. Durable intent is separate.
enum MailBlobSchema {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1") { db in try db.execute(sql: schema) }
        migrator.registerMigration("v2-preparation-revision") { db in
            try db.execute(sql: "ALTER TABLE content ADD COLUMN content_rev INTEGER NOT NULL DEFAULT 1")
            try db.execute(sql: "ALTER TABLE prepared ADD COLUMN source_rev INTEGER NOT NULL DEFAULT 0")
        }
    }
    static let schema = """
    CREATE TABLE content(
      account TEXT NOT NULL, gmail_id TEXT NOT NULL,
      thread_id TEXT NOT NULL, internal_date INTEGER NOT NULL,
      size_estimate INTEGER, snippet TEXT,
      fts_rowid INTEGER NOT NULL,  -- assigned once (4.6)
      headers   BLOB NOT NULL,     -- zlib: JSON [[name, value], …], every header, in order
      structure BLOB NOT NULL,     -- zlib: JSON MIME tree without data (MIMEStructure)
      html      BLOB,              -- zlib: the HTML part as received, decoded to UTF-8; NULL if none
      plain     BLOB,              -- zlib: the text/plain part as received; NULL if none
      level     INTEGER NOT NULL,  -- 1 header only, 2 with bodies
      bytes     INTEGER NOT NULL,  -- stored size, for eviction accounting
      stored_at INTEGER NOT NULL, opened_at INTEGER,
      PRIMARY KEY(account, gmail_id)) WITHOUT ROWID;
    
    CREATE TABLE prepared(         -- section 10: made once, when the body arrives
      account TEXT NOT NULL, gmail_id TEXT NOT NULL, prep_version INTEGER NOT NULL,
      body  BLOB NOT NULL,         -- zlib: PreparedBody as JSON (fragment, native text, pictures, …)
      text  BLOB NOT NULL,         -- zlib: PreparedBody.ownText, for the indexer and excerpts
      bytes INTEGER NOT NULL, made_at INTEGER NOT NULL,
      PRIMARY KEY(account, gmail_id)) WITHOUT ROWID;
    
    CREATE TABLE attachment(
      account TEXT NOT NULL, gmail_id TEXT NOT NULL, part_id TEXT NOT NULL,
      filename TEXT, declared_mime TEXT, sniffed_mime TEXT, size INTEGER,
      content_id TEXT, inline INTEGER NOT NULL DEFAULT 0,
      attachment_id TEXT,          -- Gmail's; may change between reads — never a key
      state INTEGER NOT NULL DEFAULT 0,   -- 0 not downloaded, 1 downloaded
      path TEXT, bytes INTEGER, used_at INTEGER, keep INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY(account, gmail_id, part_id)) WITHOUT ROWID;
    
    CREATE TABLE remote_image(
      url_hash TEXT PRIMARY KEY, bytes INTEGER NOT NULL, mime TEXT, fetched_at INTEGER NOT NULL,
      used_at INTEGER NOT NULL) WITHOUT ROWID;
    CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
    """
}

#endif
