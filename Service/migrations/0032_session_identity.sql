-- A session records the Google account that proved it. For a device session: disconnecting or
-- refusing that Google account ends exactly the sessions it stands behind. For a booking guest's
-- session: what came from Google (a person's busy times, a free/busy grant) opens only to the
-- browser that proved that Google account; an emailed code leaves it NULL.
ALTER TABLE sessions ADD COLUMN google_sub TEXT;
-- Sessions made before this: where the account has one Google account, that one proved them.
-- Accounts with several keep NULL (unknown); such a session ends at the next disconnect.
UPDATE sessions SET google_sub = (SELECT MIN(sub) FROM google_links g WHERE g.account_id = sessions.account_id)
 WHERE kind = 'person' AND (SELECT COUNT(*) FROM google_links g WHERE g.account_id = sessions.account_id) = 1;
