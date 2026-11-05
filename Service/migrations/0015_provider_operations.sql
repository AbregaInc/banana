-- Persist provider intent before dispatch. An expired lease is an unknown outcome, never
-- permission to blindly repeat a mutation. Account deletion removes both intent and receipts.
CREATE TABLE provider_operations (
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  operation_id TEXT NOT NULL,
  google_sub TEXT NOT NULL,
  resource_key TEXT NOT NULL,
  request_hash TEXT NOT NULL,
  request_cipher TEXT NOT NULL,
  dispatch_cipher TEXT,
  state TEXT NOT NULL CHECK (state IN ('pending','running','uncertain','done')),
  lease TEXT,
  lease_until BIGINT,
  response_status INTEGER,
  response_cipher TEXT,
  created_at BIGINT NOT NULL,
  updated_at BIGINT NOT NULL,
  PRIMARY KEY (account_id, operation_id)
);
CREATE INDEX provider_operations_pending ON provider_operations(state, updated_at);
CREATE UNIQUE INDEX provider_operations_writer ON provider_operations(account_id, resource_key)
  WHERE state IN ('running','uncertain');
