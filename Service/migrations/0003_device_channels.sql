-- Calendar watches made by the devices themselves (docs/design/ACCOUNTS.md, 18 Oct 2026): a device
-- asks the service for a channel id and secret, opens the watch at Google with its own access, and
-- reports it; it renews and closes its watches too. 'service' rows are the ones the service opens
-- with its own Google permission (build 56); their renewal stays the job's.
-- status is now pending | live | failed.
ALTER TABLE watches ADD COLUMN managed_by TEXT NOT NULL DEFAULT 'service';
