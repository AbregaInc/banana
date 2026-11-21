-- A device session records the Google account that proved it, so disconnecting or refusing that
-- Google account can end exactly the sessions it stands behind.
ALTER TABLE sessions ADD COLUMN google_sub TEXT;
-- Sessions made before this: where the account has one Google account, that one proved them.
-- Accounts with several keep NULL (unknown); such a session ends at the next disconnect.
UPDATE sessions SET google_sub = (SELECT MIN(sub) FROM google_links g WHERE g.account_id = sessions.account_id)
 WHERE kind = 'person' AND (SELECT COUNT(*) FROM google_links g WHERE g.account_id = sessions.account_id) = 1;
