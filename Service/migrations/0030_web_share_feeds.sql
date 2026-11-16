-- Independent read-only credentials, attenuated by the current parent share on every read.
CREATE TABLE web_share_feeds (
  id TEXT PRIMARY KEY,
  share_id TEXT NOT NULL REFERENCES web_shares(id) ON DELETE CASCADE,
  creator_sub TEXT NOT NULL,
  name TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  policy TEXT NOT NULL,
  issued_version INTEGER NOT NULL,
  created_at BIGINT NOT NULL,
  last_used_at BIGINT,
  revoked_at BIGINT
);
CREATE INDEX web_share_feeds_share ON web_share_feeds(share_id, created_at);
