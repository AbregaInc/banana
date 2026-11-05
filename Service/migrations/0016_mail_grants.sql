-- Mail consent cannot replace the Calendar refresh token. Both grants belong to the same
-- existing Banana/Google identity, and record the OAuth client that actually received the code.
CREATE TABLE mail_grants (
  google_sub TEXT PRIMARY KEY REFERENCES google_links(sub) ON DELETE CASCADE,
  refresh_token TEXT,
  scopes TEXT NOT NULL,
  client_id TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('ok','refused','unlinked')),
  granted_at BIGINT NOT NULL,
  updated_at BIGINT NOT NULL
);
