-- Shared editable drafts and immutable send handoffs. Body/recipient data is encrypted.
CREATE TABLE mail_drafts (
 account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
 draft_id TEXT NOT NULL,
 google_sub TEXT NOT NULL,
 revision INTEGER NOT NULL,
 content_hash TEXT NOT NULL,
 content_cipher TEXT NOT NULL,
 state TEXT NOT NULL CHECK(state IN ('editing','queued','sending','sent','failed','uncertain','late','deleted')),
 send_id TEXT,
 send_at BIGINT,
 send_started_at BIGINT,
 result_cipher TEXT,
 checked_at BIGINT,
 updated_at BIGINT NOT NULL,
 PRIMARY KEY(account_id,draft_id)
);
CREATE INDEX mail_drafts_due ON mail_drafts(state,send_at);

-- Retain consumed handoff identities even after cancellation so delayed client requests cannot
-- resurrect a later incarnation of a draft under an older send identity.
CREATE TABLE mail_handoffs (
 account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
 send_id TEXT NOT NULL, draft_id TEXT NOT NULL, revision INTEGER NOT NULL,
 PRIMARY KEY(account_id,send_id)
);
