-- The data platform (docs/design/DATA-PLATFORM.md, 19 Oct 2026). The records themselves live in
-- each space's own database (a Durable Object, or a SQLite file on Node); D1 knows which spaces
-- there are, who belongs to them, the Health consent log, and how far each device is off iCloud.

-- A space: for now each account's own ("sp_" + account id, made on its first /v2 call).
CREATE TABLE spaces (
  id         TEXT   PRIMARY KEY,
  owner      TEXT   NOT NULL REFERENCES accounts (id),
  kind       TEXT   NOT NULL,          -- personal
  created_at BIGINT NOT NULL
);

CREATE TABLE space_members (
  space_id   TEXT   NOT NULL REFERENCES spaces (id),
  account_id TEXT   NOT NULL REFERENCES accounts (id),
  role       TEXT   NOT NULL,          -- owner
  created_at BIGINT NOT NULL,
  PRIMARY KEY (space_id, account_id)
);
CREATE INDEX space_members_account ON space_members (account_id);

-- Every yes and its withdrawal (GDPR Art. 9): which words, when, from which device. The space holds
-- its own consent row too, which is what the sync checks.
CREATE TABLE consents_log (
  account_id   TEXT   NOT NULL,
  kind         TEXT   NOT NULL,        -- health
  version      TEXT   NOT NULL,        -- the words' version
  granted_at   BIGINT NOT NULL,
  withdrawn_at BIGINT,
  device       TEXT,
  via          TEXT   NOT NULL         -- app
);
CREATE INDEX consents_log_account ON consents_log (account_id, kind);

-- What a device reports of its move (§8): the types it seeded (the hub's list tells spokes they
-- may seed), when its seed was all acknowledged, when it stopped writing iCloud, its last sync.
ALTER TABLE devices ADD COLUMN seeded_types TEXT;   -- JSON array of catalog types
ALTER TABLE devices ADD COLUMN seeded_at BIGINT;
ALTER TABLE devices ADD COLUMN flipped_at BIGINT;
ALTER TABLE devices ADD COLUMN last_sync_at BIGINT;

-- 1 once the author (or, later, the gate alone) allows deleting what Banana left in iCloud.
ALTER TABLE accounts ADD COLUMN icloud_purge_ok INTEGER NOT NULL DEFAULT 0;
-- The last "sync" push to the account's devices (at most one every 3 s), apart from calendar pushes,
-- and the one trailing push waiting for the window to end: when, and the device whose changes it
-- carries ("*" for several), which it leaves out.
ALTER TABLE accounts ADD COLUMN last_sync_push_at BIGINT;
ALTER TABLE accounts ADD COLUMN sync_push_due_at BIGINT;
ALTER TABLE accounts ADD COLUMN sync_push_from TEXT;
