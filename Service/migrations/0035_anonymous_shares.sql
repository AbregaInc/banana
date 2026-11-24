-- What each address sent today through the anonymous routes (reports, diagnostics, usage), so one
-- address can't take the whole day's allowance from everyone. `who` is a hash of the address with
-- a key and the day, so it says nothing about the address and nothing across days. Rows go the
-- next day.
CREATE TABLE anonymous_shares (
  day   TEXT    NOT NULL,
  kind  TEXT    NOT NULL,   -- report | diagnostics | usage
  who   TEXT    NOT NULL,
  n     INTEGER NOT NULL,
  bytes INTEGER NOT NULL,
  PRIMARY KEY (day, kind, who)
);
