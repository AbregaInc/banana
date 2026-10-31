-- Web-only, read-only sharing. These grants never create space_members or native sessions.
-- Draft permissions are separate from published permissions: editing cannot expand access.
CREATE TABLE web_shares (
  id TEXT PRIMARY KEY,
  owner_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  email TEXT NOT NULL,
  guest_sub TEXT,
  guest_name TEXT,
  status TEXT NOT NULL DEFAULT 'draft',
  draft_policy TEXT NOT NULL,
  draft_version INTEGER NOT NULL DEFAULT 1,
  policy TEXT,
  published_version INTEGER,
  previewed_version INTEGER,
  previewed_at BIGINT,
  send_status TEXT,
  last_sent_at BIGINT,
  created_at BIGINT NOT NULL,
  updated_at BIGINT NOT NULL,
  accepted_at BIGINT,
  revoked_at BIGINT
);
CREATE INDEX web_shares_owner ON web_shares(owner_id, created_at);
CREATE INDEX web_shares_email ON web_shares(email, status);
CREATE INDEX web_shares_subject ON web_shares(guest_sub, status);

CREATE TABLE web_share_mail_limits (
  owner_id TEXT PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
  window_at BIGINT NOT NULL,
  sent INTEGER NOT NULL
);
