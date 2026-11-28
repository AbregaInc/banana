-- The operation sweep looks one item's operations up by account and item. Without this index it
-- scanned the account's whole table once per stuck operation and overloaded D1.
CREATE INDEX provider_operations_item ON provider_operations(account_id, resource_key, created_at);
