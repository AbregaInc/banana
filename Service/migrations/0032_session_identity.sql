-- A device session records the Google account that proved it (google_sub) and when (proven_at).
-- Disconnecting that Google account, or Google refusing it, ends the session (ended_at) without
-- deleting it, so the app is told to prove itself again rather than that the account is gone. A
-- session proven by a Google account the service holds no token for (it can't ask Google about
-- it) needs a fresh proof every 30 days; the app gives one by itself.
-- A booking guest's session records the Google account it proved (an emailed code leaves it
-- NULL): what came from Google opens only to that browser.
ALTER TABLE sessions ADD COLUMN google_sub TEXT;
ALTER TABLE sessions ADD COLUMN proven_at BIGINT;
ALTER TABLE sessions ADD COLUMN ended_at BIGINT;
-- Sessions made before this: where the account has one Google account, that one proved them.
-- Accounts with several keep NULL (unknown); such a session ends at the next disconnect, and the
-- app proves itself again.
UPDATE sessions SET google_sub = (SELECT MIN(sub) FROM google_links g WHERE g.account_id = sessions.account_id)
 WHERE kind = 'person' AND (SELECT COUNT(*) FROM google_links g WHERE g.account_id = sessions.account_id) = 1;
-- Their 30 days start now.
UPDATE sessions SET proven_at = CAST(strftime('%s', 'now') AS INTEGER) * 1000 WHERE kind = 'person';
