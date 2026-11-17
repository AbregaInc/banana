-- Personal exports are independent of guest invitations. Permissions are immutable per key.
CREATE TABLE web_personal_feeds (
  id TEXT PRIMARY KEY,
  owner_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  creator_sub TEXT NOT NULL,
  name TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  policy TEXT NOT NULL,
  issued_version INTEGER NOT NULL DEFAULT 1,
  created_at BIGINT NOT NULL,
  last_used_at BIGINT,
  revoked_at BIGINT
);
CREATE INDEX web_personal_feeds_owner ON web_personal_feeds(owner_id, created_at);
