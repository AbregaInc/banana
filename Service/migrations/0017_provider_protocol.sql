-- A provider cutover can be granted only after every registered device supports cloud-only
-- delivery and durable ownership. An old client registering again closes experimental access.
ALTER TABLE devices ADD COLUMN provider_protocol INTEGER NOT NULL DEFAULT 0;
