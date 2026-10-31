-- Receipt only: no event titles or bodies, retained so later expanded instances cannot ring again.
CREATE TABLE series_invitations (
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  series_hash TEXT NOT NULL,
  first_seen_at BIGINT NOT NULL,
  PRIMARY KEY (account_id, series_hash)
);
