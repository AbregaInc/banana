-- Event alerts sent by the service (docs/design/EVENT-ALERTS.md, 19 Oct 2026).
-- The lead times and time zone the account's devices report.
ALTER TABLE accounts ADD COLUMN alert_leads TEXT;    -- JSON minutes, e.g. "[5,0]"; null = the default
ALTER TABLE accounts ADD COLUMN time_zone TEXT;      -- IANA zone of the device that last reported

-- Google's sync token per calendar the service reads.
CREATE TABLE calendar_sync (
  google_sub  TEXT   NOT NULL REFERENCES google_links (sub),
  calendar_id TEXT   NOT NULL,
  sync_token  TEXT,
  read_at     BIGINT NOT NULL,
  PRIMARY KEY (google_sub, calendar_id)
);

-- What the service knew of an event last time, to tell a move from a reply. No title: a hash.
CREATE TABLE event_state (
  google_sub  TEXT   NOT NULL REFERENCES google_links (sub),
  calendar_id TEXT   NOT NULL,
  event_id    TEXT   NOT NULL,
  start_at    BIGINT,
  end_at      BIGINT,
  status      TEXT   NOT NULL,
  response    TEXT,
  title_hash  TEXT   NOT NULL,
  updated_at  BIGINT NOT NULL,
  PRIMARY KEY (google_sub, calendar_id, event_id)
);

-- An alert to send, or sent: id is `calendarId|eventId|lead`, shared with the devices' own
-- local alerts. The title and body are the words of the push; the row goes a day after it is
-- sent or cleared (the dispatcher sweeps).
CREATE TABLE alerts (
  id          TEXT   PRIMARY KEY,
  account_id  TEXT   NOT NULL REFERENCES accounts (id),
  google_sub  TEXT   NOT NULL,
  calendar_id TEXT   NOT NULL,
  event_id    TEXT   NOT NULL,
  kind        TEXT   NOT NULL,     -- lead | now | invite | changed | cancelled
  due_at      BIGINT NOT NULL,
  title       TEXT   NOT NULL,
  body        TEXT   NOT NULL,
  status      TEXT   NOT NULL,     -- pending | sent | cleared
  created_at  BIGINT NOT NULL,
  sent_at     BIGINT,
  cleared_at  BIGINT
);
CREATE INDEX alerts_due ON alerts (status, due_at);
CREATE INDEX alerts_event ON alerts (google_sub, calendar_id, event_id);
CREATE INDEX alerts_account ON alerts (account_id);

-- Which device holds which alert itself (its own local notification), so the service needn't push it there.
CREATE TABLE held_alerts (
  device_id TEXT NOT NULL,
  alert_id  TEXT NOT NULL,
  PRIMARY KEY (device_id, alert_id)
);
