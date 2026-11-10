-- Booking hours that follow where the owner is (docs/design/BOOKING.md §13): the snapshot keeps the
-- space's plan.whereabouts record beside the types (times and IANA zones only), so the pages read
-- it with the host in one row.
ALTER TABLE busy_snapshot ADD COLUMN whereabouts_json TEXT;
