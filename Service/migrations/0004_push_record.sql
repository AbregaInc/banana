-- What came of the last calendar push to each device (18 Oct 2026), so "did the push reach the
-- phone" can be answered from the database: when the service last sent one, and APNs's answer
-- ("200", "410 Unregistered", "failed TypeError"). No payload, no token.
ALTER TABLE devices ADD COLUMN pushed_at BIGINT;
ALTER TABLE devices ADD COLUMN push_status TEXT;
