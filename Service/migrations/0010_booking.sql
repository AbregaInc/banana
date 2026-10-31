-- Booking (docs/design/BOOKING.md, §12 first): a link per account, guests who book and are
-- remembered, the bookings themselves. Plain SQL, as every migration. Booking types are not here:
-- they live in the person's space as `plan.bookingType` records.

-- Guests are accounts too. A guest session lives only on the booking pages (a __Host- cookie), and
-- the API refuses it: `signedIn` takes person sessions only.
ALTER TABLE accounts ADD COLUMN kind TEXT NOT NULL DEFAULT 'person';      -- person | guest
ALTER TABLE accounts ADD COLUMN display_name TEXT;                        -- the host's name on the booking page
ALTER TABLE sessions ADD COLUMN kind TEXT NOT NULL DEFAULT 'person';      -- person | guest
-- A guest session: what this browser typed (JSON {name, email, phone}), shown back only to it; and
-- when it proved the email (Google, or a code), which shows the guest's times and Forget me.
ALTER TABLE sessions ADD COLUMN profile TEXT;
ALTER TABLE sessions ADD COLUMN verified_at BIGINT;
-- The Google account's name, from its identity token (the handle is suggested from it).
ALTER TABLE google_links ADD COLUMN name TEXT;

-- One handle per account: book.bananatheapp.com/<handle>. The zone the default type uses, fixed
-- when the handle was made (a type's zone doesn't follow the host's travel).
CREATE TABLE booking_handles (
  handle     TEXT   PRIMARY KEY,
  account_id TEXT   NOT NULL UNIQUE REFERENCES accounts (id),
  time_zone  TEXT,
  created_at BIGINT NOT NULL,
  updated_at BIGINT NOT NULL
);

-- The next 31 days of the account's busy time, times only (no titles), worked out from its Google
-- calendars when a watch reports a change and by the 15-minute job; and its booking types as last
-- read from the space. The slots read is this row, the bookings, and the engine.
CREATE TABLE busy_snapshot (
  account_id    TEXT   PRIMARY KEY REFERENCES accounts (id),
  horizon_json  TEXT   NOT NULL,   -- {from, to, busy: [[start, end, booking?]], calendars: [{sub, id, tz}], unknown}
  types_json    TEXT,              -- [{id, fields}] of plan.bookingType
  computed_at   BIGINT NOT NULL,   -- 0 until the first build
  types_at      BIGINT,            -- when types_json was last written (the page cache's key changes with it)
  rebuilding_at BIGINT,            -- a rebuild running since (one at a time)
  dirty_at      BIGINT,            -- a change reported while it ran: it runs again
  told_at       BIGINT             -- the last "isn't taking bookings" push to the host
);

-- A booking. `id` is 128 random bits in lowercase hex, and the Google event's id. `manage_id` is the
-- private link's, made apart. Reserved first (status pending, a conditional insert that is the
-- lock), then made at Google after the answer. The guest's details stay until 30 days after the
-- meeting, then the row goes.
CREATE TABLE bookings (
  id               TEXT    PRIMARY KEY,
  manage_id        TEXT    NOT NULL UNIQUE,
  account_id       TEXT    NOT NULL REFERENCES accounts (id),
  type_id          TEXT    NOT NULL,
  type_title       TEXT    NOT NULL,
  start_at         BIGINT  NOT NULL,
  end_at           BIGINT  NOT NULL,
  block_start      BIGINT  NOT NULL,     -- start less the type's buffer before
  block_end        BIGINT  NOT NULL,     -- end plus the buffer after
  status           TEXT    NOT NULL,     -- pending | confirmed | cancelled | taken | failed
  invite           TEXT    NOT NULL,     -- held (Undo still open: the guest isn't on the event yet) | sending | sent
  undo_until       BIGINT,
  place_id         TEXT,
  place_kind       TEXT,                 -- meet | zoom | phone_host_calls | phone_guest_calls | in_person | link
  place_detail     TEXT,                 -- the Meet or Zoom link, the phone number, the address
  meet_state       TEXT,                 -- pending | ready | disabled, for Meet
  guest_account_id TEXT,
  guest_name       TEXT,
  guest_email      TEXT,
  guest_phone      TEXT,
  guest_zone       TEXT,
  note             TEXT,
  idem_key         TEXT,                 -- the client's key, scoped to (email, start)
  ip_hash          TEXT,                 -- keyed hash of the address it came from, for the hourly limit
  calendar_sub     TEXT,                 -- the Google link and calendar the event is on
  calendar_id      TEXT,
  attempts         INTEGER NOT NULL DEFAULT 0,   -- tries at making the event (three)
  work_tries       INTEGER NOT NULL DEFAULT 0,   -- tries at the work after it: the invite, a move's patch, a delete (three each)
  patch_pending    INTEGER NOT NULL DEFAULT 0,   -- 1: a move Google hasn't taken yet (the new time stands)
  move_undo_until  BIGINT,                       -- a move's own Undo window: Google and the host hear of it after
  moved_from       TEXT,                         -- JSON: the times before the last move, for its Undo
  pending_push     TEXT,                         -- the host's push about a move, sent once Google has it
  sequence         INTEGER NOT NULL DEFAULT 0,   -- the calendar file's SEQUENCE: one more at each move or cancel
  next_at          BIGINT,               -- when the minute job next looks at it (a retry, a held invite, a delete)
  google_pending   INTEGER NOT NULL DEFAULT 0,   -- 1: a cancel whose event Google hasn't deleted yet
  reminded_24      INTEGER NOT NULL DEFAULT 0,   -- 0 due, 1 sent, 2 skipped
  reminded_1       INTEGER NOT NULL DEFAULT 0,
  confirmed_mail   INTEGER NOT NULL DEFAULT 0,   -- our own confirmation went
  cancelled_by     TEXT,                 -- guest | host | undo | forget
  created_at       BIGINT  NOT NULL,
  timed_at         BIGINT  NOT NULL,     -- when this time was set (made or moved): a reminder due before it is skipped
  confirmed_at     BIGINT,
  updated_at       BIGINT  NOT NULL
);
CREATE INDEX bookings_account_time ON bookings (account_id, status, start_at);
CREATE INDEX bookings_guest ON bookings (guest_account_id);
CREATE INDEX bookings_email ON bookings (guest_email);
CREATE INDEX bookings_work ON bookings (status, next_at);
CREATE INDEX bookings_idem ON bookings (idem_key);
CREATE INDEX bookings_account_updated ON bookings (account_id, updated_at);

-- A guest, by email: the latest name, phone and zone they gave, when they proved the email, and the
-- Banana person they also are (whose own calendars then count when they book).
CREATE TABLE guests (
  account_id        TEXT   PRIMARY KEY REFERENCES accounts (id),
  email             TEXT   NOT NULL UNIQUE,
  name              TEXT,
  phone             TEXT,
  zone              TEXT,
  person_account_id TEXT,
  verified_at       BIGINT,
  last_seen_at      BIGINT NOT NULL,
  created_at        BIGINT NOT NULL
);

-- A guest's Google free/busy grant, apart from google_links so a host's token is never overwritten.
CREATE TABLE guest_grants (
  sub           TEXT   PRIMARY KEY,
  account_id    TEXT   NOT NULL REFERENCES accounts (id),
  email         TEXT   NOT NULL,
  refresh_token TEXT,              -- sealed as google_links' are, under "guest:<sub>"
  scopes        TEXT   NOT NULL,
  status        TEXT   NOT NULL,   -- ok | refused
  checked_at    BIGINT,            -- the daily "does Google still say yes"
  created_at    BIGINT NOT NULL,
  updated_at    BIGINT NOT NULL
);
CREATE INDEX guest_grants_account ON guest_grants (account_id);

-- A 6-digit code emailed to prove an address: only its keyed hash, ten minutes, five tries.
CREATE TABLE email_codes (
  email      TEXT    PRIMARY KEY,
  code_hash  TEXT    NOT NULL,
  expires_at BIGINT  NOT NULL,
  attempts   INTEGER NOT NULL DEFAULT 0,
  sent       INTEGER NOT NULL DEFAULT 1,   -- codes sent in this window
  window_at  BIGINT  NOT NULL
);
