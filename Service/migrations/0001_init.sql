-- Banana service, first schema (docs/design/ACCOUNTS.md).
-- Plain SQL that SQLite, D1 and Postgres all take: no WITHOUT ROWID, no SQLite-only functions.
-- Times are milliseconds since 1970 (BIGINT: an INTEGER in SQLite and D1, 64-bit in Postgres).
-- Ids are text the service makes from random bytes. Nothing here holds an event, a title, an
-- attendee or mail.

CREATE TABLE accounts (
  id           TEXT   PRIMARY KEY,
  created_at   BIGINT NOT NULL,
  last_push_at BIGINT              -- the last calendar push to its devices (pushes are 3 s apart at least)
);

-- A Google account (by Google's sub) belongs to one Banana account.
CREATE TABLE google_links (
  sub           TEXT   PRIMARY KEY,
  account_id    TEXT   NOT NULL REFERENCES accounts (id),
  email         TEXT   NOT NULL,   -- lowercased
  refresh_token TEXT,              -- AES-256-GCM, "v1.<iv>.<ciphertext>", the sub as additional data; never plain
  scopes        TEXT   NOT NULL,   -- as Google granted them, space-separated
  status        TEXT   NOT NULL,   -- ok | refused (Google said invalid_grant: the person reconnects)
  created_at    BIGINT NOT NULL,
  updated_at    BIGINT NOT NULL
);
CREATE INDEX google_links_account ON google_links (account_id);

-- One row per session token; only its SHA-256 is kept.
CREATE TABLE sessions (
  token_hash   TEXT   PRIMARY KEY,
  account_id   TEXT   NOT NULL REFERENCES accounts (id),
  created_at   BIGINT NOT NULL,
  last_used_at BIGINT NOT NULL      -- updated at most once a day
);
CREATE INDEX sessions_account ON sessions (account_id);

CREATE TABLE devices (
  id         TEXT   PRIMARY KEY,    -- the app's own device id
  account_id TEXT   NOT NULL REFERENCES accounts (id),
  platform   TEXT   NOT NULL,       -- iphone | ipad | mac
  push_token TEXT,                  -- hex; cleared when Apple says it's no longer good
  push_env   TEXT   NOT NULL,       -- development | production
  bundle     TEXT   NOT NULL,       -- the app's bundle id, the push topic
  updated_at BIGINT NOT NULL
);
CREATE INDEX devices_account ON devices (account_id);

-- A calendar the app reads, and Google's channel watching it. The rows are also the list of
-- calendars wanted: a watch Google refused stays as status 'failed' and is retried with backoff.
CREATE TABLE watches (
  channel_id  TEXT    PRIMARY KEY,
  account_id  TEXT    NOT NULL REFERENCES accounts (id),
  google_sub  TEXT    NOT NULL REFERENCES google_links (sub),
  calendar_id TEXT    NOT NULL,
  resource_id TEXT,               -- Google's, needed to stop the channel; null while failed
  secret      TEXT    NOT NULL,   -- the channel token Google sends back with every notice
  expires_at  BIGINT,             -- when Google ends the channel; null while failed
  status      TEXT    NOT NULL,   -- live | failed
  failures    INTEGER NOT NULL DEFAULT 0,
  retry_at    BIGINT,             -- not before this (backoff after a failure)
  created_at  BIGINT  NOT NULL
);
CREATE INDEX watches_link ON watches (google_sub);
CREATE INDEX watches_account ON watches (account_id);
CREATE INDEX watches_expiry ON watches (status, expires_at);

-- Usage per account: the same allow-listed words as counts, per day.
CREATE TABLE account_usage (
  account_id TEXT    NOT NULL REFERENCES accounts (id),
  day        TEXT    NOT NULL,
  event      TEXT    NOT NULL,
  name       TEXT    NOT NULL,
  detail     TEXT    NOT NULL,
  platform   TEXT    NOT NULL,
  version    TEXT    NOT NULL,
  count      INTEGER NOT NULL,
  PRIMARY KEY (account_id, day, event, name, detail, platform, version)
);

-- The anonymous daily totals from before (docs/design/TELEMETRY.md), columns unchanged.
-- A row is a count of one kind of thing on one day, among copies alike in what the app says
-- about itself — never one device.
CREATE TABLE counts (
  day      TEXT    NOT NULL,  -- UTC date the batch arrived, 2026-10-15
  event    TEXT    NOT NULL,  -- active, onboarding, feature, failure, setup
  name     TEXT    NOT NULL,  -- for active: ""; else from the allow-list in src/usage.js
  detail   TEXT    NOT NULL,  -- a second allow-listed word, or ""
  platform TEXT    NOT NULL,  -- iphone, ipad, mac
  channel  TEXT    NOT NULL,  -- appstore, testflight, dev
  version  TEXT    NOT NULL,  -- 1.0 (55)
  cohort   TEXT    NOT NULL,  -- ISO week the copy was first opened, 2026-W42
  since    INTEGER NOT NULL,  -- days since that first opening, capped at 400
  calendar INTEGER NOT NULL,  -- 1 when a calendar is connected
  count    INTEGER NOT NULL,
  PRIMARY KEY (day, event, name, detail, platform, channel, version, cohort, since, calendar)
);

-- Access log: who, when, what. Nothing else (no email, no calendar, no address).
CREATE TABLE audit (
  id         TEXT   PRIMARY KEY,
  account_id TEXT   NOT NULL,     -- no reference: the 'delete' row outlives the account
  at         BIGINT NOT NULL,
  action     TEXT   NOT NULL      -- link | unlink | delete | google_refused | watch_failed
);
CREATE INDEX audit_account ON audit (account_id);
