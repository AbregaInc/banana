-- Snooze (docs/design/MAIL-ENGINE.md §8): when each shared mailbox next has a conversation to wake,
-- so the quarter-hour job can set an alarm that was lost even when no device reads the mailbox.
ALTER TABLE mail_mailboxes ADD COLUMN wake_at INTEGER;
CREATE INDEX mail_mailboxes_wake ON mail_mailboxes (wake_at) WHERE wake_at IS NOT NULL;
