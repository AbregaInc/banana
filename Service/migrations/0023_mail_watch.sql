-- Gmail push for the shared cloud mailboxes (docs/design/MAIL-CLOUD-SYNC.md §2a): when each
-- mailbox's users.watch ends (ms), so the quarter-hour job renews it a day before. NULL: no watch.
ALTER TABLE mail_mailboxes ADD COLUMN watch_expires_at INTEGER;
