#if !BANANA_PUBLIC
import GRDB

/// Cache-only index schema from MAIL-ENGINE 4.3, including the owner's retention
/// fields and the separate recipient summary used by Sent/Drafts row mapping.
/// Intent and provider state remain outside this migration.
enum MailIndexSchema {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1") { db in
            try db.execute(sql: schema)
        }
    }

    static let schema = """
    CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
    -- 'derived_version', 'created_at', 'unclean' (set while the engine runs)
    
    CREATE TABLE account(
      account_pk        INTEGER PRIMARY KEY,
      email             TEXT NOT NULL UNIQUE,   -- lower-cased
      checkpoint        TEXT,     -- Gmail historyId the cache is current to; NULL = no usable position
      profile_total     INTEGER,  -- users.getProfile messagesTotal at the last handshake
      enum_generation   INTEGER NOT NULL DEFAULT 0,
      enum_checkpoint   TEXT,     -- the position when the running enumeration began
      enum_state        TEXT,     -- JSON {listing, pageToken, done, maxPKAtStart, edge}; NULL = none running
      limit_edge        INTEGER,  -- ms; edge used by the last closed enumeration
      enum_completed_at INTEGER,  -- ms
      headers_through   INTEGER,  -- ms; every listed message newer than this has its header
      bodies_through    INTEGER,  -- ms; every listed message newer than this has its body
      quota_state       TEXT,     -- JSON: rate, pauses, {day, bytes}
      last_sync_at      INTEGER,
      last_sync_result  TEXT,     -- MailSyncHealth, encoded
      send_as           TEXT,     -- JSON: identities from settings.sendAs.list
      send_as_at        INTEGER,
      labels_at         INTEGER,  -- ms; when a complete labels response was last applied
      removals          TEXT      -- JSON: deletions applied per hour, last 24 (invariant 3)
    );
    
    CREATE TABLE label(
      label_pk   INTEGER PRIMARY KEY,
      account_pk INTEGER NOT NULL,
      gmail_id   TEXT NOT NULL,   -- 'INBOX', 'Label_12'; 'local:<name>' until Gmail has created it
      name       TEXT NOT NULL,
      kind       INTEGER NOT NULL,  -- 0 system, 1 user, 2 Banana's own (name begins 'Banana/')
      list_visibility TEXT, message_visibility TEXT, text_color TEXT, background_color TEXT,
      UNIQUE(account_pk, gmail_id)
    );
    CREATE INDEX label_by_name ON label(account_pk, name);
    
    CREATE TABLE thread(
      thread_pk     INTEGER PRIMARY KEY,
      account_pk    INTEGER NOT NULL,
      gmail_id      TEXT NOT NULL,
      tie           INTEGER NOT NULL,             -- MailOrderKey.tie: a stable hash of (account, thread id)
      -- everything below is derived by ThreadSummaryRules, overlay applied
      last_date     INTEGER NOT NULL DEFAULT 0,
      message_count INTEGER NOT NULL DEFAULT 0,
      fetched_count INTEGER NOT NULL DEFAULT 0,
      unread_count  INTEGER NOT NULL DEFAULT 0,
      flags         INTEGER NOT NULL DEFAULT 0,   -- MailThreadFlags (appendix A)
      subject TEXT, snippet TEXT,
      people  TEXT,                 -- JSON [{n: name, a: address, u: unread}], six at most
      people_total INTEGER NOT NULL DEFAULT 0,
      recipients TEXT,             -- JSON SummaryPerson array, six at most
      recipients_total INTEGER NOT NULL DEFAULT 0,
      attended_at INTEGER,         -- explicit user attention; not overwritten by resummarise
      labels  TEXT,                 -- ',12,45,' label_pks, effective
      wake_at INTEGER, returned_at INTEGER, waiting_until INTEGER,   -- section 8
      pending INTEGER NOT NULL DEFAULT 0,          -- 0 none, 1 undelivered change, 2 a change was refused
      UNIQUE(account_pk, gmail_id)
    );
    
    CREATE TABLE message(
      msg_pk        INTEGER PRIMARY KEY,
      account_pk    INTEGER NOT NULL,
      gmail_id      TEXT NOT NULL,
      thread_pk     INTEGER NOT NULL,
      internal_date INTEGER NOT NULL DEFAULT 0,   -- ms; 0 while only the id is known
      fetch_state   INTEGER NOT NULL DEFAULT 0,   -- 0 stub (id only), 1 header, 2 full
      fetch_class   INTEGER NOT NULL DEFAULT 5,   -- FetchPlanRules.fetchClass: 0 first … 9 last
      list_rank     INTEGER NOT NULL DEFAULT 0,   -- order in the listing that found it; smaller = newer
      history_id    TEXT,                         -- the newest history record or read reflected in its labels
      size_estimate INTEGER,
      flags         INTEGER NOT NULL DEFAULT 0,   -- MailMessageFlags: fromMe, hasAttachment, hasInvite, labelsKnown (6.1), …
      vis           INTEGER NOT NULL DEFAULT 0,   -- 0 normal, 1 in Trash, 2 in Spam (effective),
                                                  -- 3 rebuilt and not yet confirmed by Gmail, 4 kept though Gmail says gone
      body_kind     INTEGER NOT NULL DEFAULT 0,   -- MailBodyKind once prepared
      prep_state    INTEGER NOT NULL DEFAULT 0,   -- 0 not prepared, 1 being parsed, 2 prepared, 3 shown as text (10.3)
      fts_rowid     INTEGER,                      -- its row id in search.sqlite (4.6)
      fts_state     INTEGER NOT NULL DEFAULT 0,   -- 0 not indexed, 1 header indexed, 2 body indexed
      fts_dirty     INTEGER NOT NULL DEFAULT 0,
      from_addr TEXT, from_name TEXT, subject TEXT, snippet TEXT,   -- cleaned (10.8)
      recipients    TEXT,                         -- JSON {to:[…], cc:[…], bcc:[…]}, addresses
      rfc_message_id TEXT, list_id TEXT,
      auth_domain   TEXT,                         -- MailAuthRules.authenticatedDomain, or NULL
      UNIQUE(account_pk, gmail_id)
    );
    CREATE INDEX message_by_thread ON message(thread_pk, internal_date);
    CREATE UNIQUE INDEX message_by_fts ON message(fts_rowid) WHERE fts_rowid IS NOT NULL;
    CREATE INDEX message_stub_queue ON message(account_pk, fetch_class, list_rank) WHERE fetch_state = 0;
    CREATE INDEX message_body_queue ON message(account_pk, fetch_class, internal_date DESC) WHERE fetch_state = 1;
    CREATE INDEX message_prep_queue ON message(internal_date DESC) WHERE fetch_state = 2 AND prep_state = 0;
    CREATE INDEX message_fts_queue  ON message(internal_date DESC) WHERE fts_dirty = 1;
    CREATE INDEX message_by_rfc_id  ON message(rfc_message_id) WHERE rfc_message_id IS NOT NULL;
    
    -- Gmail's label state, as last told. Never includes the overlay.
    CREATE TABLE message_label(
      msg_pk INTEGER NOT NULL, label_pk INTEGER NOT NULL,
      PRIMARY KEY(msg_pk, label_pk)) WITHOUT ROWID;
    CREATE INDEX message_label_by_label ON message_label(label_pk, msg_pk);
    
    -- A copy of intent.sqlite's undelivered assertions, keyed locally. Rebuilt at launch.
    CREATE TABLE overlay(
      msg_pk INTEGER NOT NULL, label_pk INTEGER NOT NULL, want INTEGER NOT NULL,
      derived INTEGER NOT NULL DEFAULT 0,          -- 1: made by a rule, not by him (8.3)
      PRIMARY KEY(msg_pk, label_pk)) WITHOUT ROWID;
    
    -- What a running enumeration has seen, so it can be compared with what is stored.
    CREATE TABLE enum_mark(
      account_pk INTEGER NOT NULL, generation INTEGER NOT NULL,
      label_pk INTEGER NOT NULL,     -- 0 = the listing of every message
      msg_pk INTEGER NOT NULL,
      PRIMARY KEY(account_pk, generation, label_pk, msg_pk)) WITHOUT ROWID;
    
    -- Messages whose state must be read back one by one before anything is removed (invariant 1).
    CREATE TABLE verify_queue(
      msg_pk INTEGER PRIMARY KEY, reason INTEGER NOT NULL, generation INTEGER NOT NULL,
      queued_at INTEGER NOT NULL,
      outcome INTEGER);              -- NULL not read yet, 1 gone (5.3 step 5)
    
    -- Deletions Gmail has stated that invariant 3 is holding back (5.7).
    CREATE TABLE held_removal(
      msg_pk INTEGER PRIMARY KEY, evidence INTEGER NOT NULL,   -- 1 messagesDeleted, 2 a read's notFound
      found_at INTEGER NOT NULL, kept INTEGER NOT NULL DEFAULT 0);
    
    -- Ids Gmail deleted in the last day; the writer will not store them (invariant 29).
    CREATE TABLE tombstone(
      account_pk INTEGER NOT NULL, gmail_id TEXT NOT NULL, at INTEGER NOT NULL,
      PRIMARY KEY(account_pk, gmail_id)) WITHOUT ROWID;
    
    CREATE TABLE view(
      view_pk INTEGER PRIMARY KEY,
      key     TEXT NOT NULL UNIQUE,   -- MailViewKey as JSON with sorted keys
      kind    INTEGER NOT NULL,       -- 0 label, 1 unified label, 2 all mail, 3 split, 4 special
      account_pk INTEGER, label_pk INTEGER,
      definition TEXT,                -- a split's query
      definition_rev INTEGER NOT NULL DEFAULT 0,
      built_rev INTEGER NOT NULL DEFAULT 0     -- < definition_rev: membership is being rebuilt
    );
    CREATE TABLE view_thread(
      view_pk INTEGER NOT NULL, sort_key INTEGER NOT NULL, tie INTEGER NOT NULL,
      thread_pk INTEGER NOT NULL, unread INTEGER NOT NULL,
      PRIMARY KEY(view_pk, sort_key, tie)) WITHOUT ROWID;
    CREATE INDEX view_thread_unread    ON view_thread(view_pk) WHERE unread = 1;
    CREATE INDEX view_thread_by_thread ON view_thread(thread_pk, view_pk);
    
    CREATE TABLE correspondent(
      addr TEXT PRIMARY KEY, name TEXT,
      sent INTEGER NOT NULL DEFAULT 0, received INTEGER NOT NULL DEFAULT 0,
      last_date INTEGER NOT NULL DEFAULT 0) WITHOUT ROWID;
    CREATE TABLE correspondent_key(      -- name words, the address, its domain; all lower-cased
      key TEXT NOT NULL, addr TEXT NOT NULL, PRIMARY KEY(key, addr)) WITHOUT ROWID;
    """
}

#endif
