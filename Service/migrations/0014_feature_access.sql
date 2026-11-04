-- Eligibility belongs to the existing authenticated Banana account, never to a device
-- or to an unverified email supplied by a client. Each deployment has its own grants.
CREATE TABLE feature_access (
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  feature TEXT NOT NULL CHECK (feature IN ('email', 'calendarCloud')),
  enabled INTEGER NOT NULL CHECK (enabled IN (0, 1)),
  expires_at BIGINT,
  updated_at BIGINT NOT NULL,
  PRIMARY KEY (account_id, feature)
);
