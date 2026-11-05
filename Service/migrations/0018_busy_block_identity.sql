-- One service-owned provider identity per logical busy block, shared by every device.
-- Provider IDs stay encrypted; indexed hashes contain no titles, addresses or item IDs.
CREATE TABLE busy_block_identities (
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  logical_key TEXT NOT NULL,
  event_key TEXT NOT NULL,
  event_cipher TEXT NOT NULL,
  owner_operation TEXT NOT NULL,
  established INTEGER NOT NULL DEFAULT 0,
  retired INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (account_id, logical_key)
);
CREATE UNIQUE INDEX busy_block_provider_identity ON busy_block_identities(account_id, event_key);
