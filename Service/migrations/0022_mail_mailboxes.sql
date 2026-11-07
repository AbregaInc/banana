-- The shared cloud mailboxes (docs/design/MAIL-CLOUD-SYNC.md): which Google identities have one, for
-- whom, and when a device last read it. The mailbox itself is a Durable Object named by the sub.
CREATE TABLE mail_mailboxes (
 google_sub TEXT PRIMARY KEY REFERENCES google_links(sub) ON DELETE CASCADE,
 account_id TEXT NOT NULL,
 created_at INTEGER NOT NULL,
 read_at INTEGER
);
CREATE INDEX mail_mailboxes_account ON mail_mailboxes (account_id);
