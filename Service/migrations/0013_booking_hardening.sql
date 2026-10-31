-- Security audit run-1 (26 Oct 2026).
-- The "your time" email for an address that already holds a booking goes at most once a day per booking.
ALTER TABLE bookings ADD COLUMN existing_mailed_at BIGINT;
-- A change notice past the per-channel bound marks the calendar; the dispatcher reads it next minute.
ALTER TABLE watches ADD COLUMN dirty_at BIGINT;
-- One service-managed watch per calendar: duplicates left by overlapping reconciles go (newest kept;
-- an older channel still open at Google answers no known row and is ignored until it expires).
DELETE FROM watches WHERE managed_by = 'service' AND channel_id NOT IN (
  SELECT channel_id FROM watches w1 WHERE w1.managed_by = 'service'
    AND w1.created_at = (SELECT MAX(created_at) FROM watches w2 WHERE w2.managed_by = 'service' AND w2.google_sub = w1.google_sub AND w2.calendar_id = w1.calendar_id));
CREATE UNIQUE INDEX watches_service_calendar ON watches (google_sub, calendar_id) WHERE managed_by = 'service';
