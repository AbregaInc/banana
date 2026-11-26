-- One Google account, one grant: Mail reads google_links like Calendar does (since eb9248af).
-- The separate Mail grant is gone. Not additive: apply it as its own step, after the service that
-- no longer reads this table is deployed (tools/release/migration-additive.py refuses it in a
-- routine deploy).
DROP TABLE IF EXISTS mail_grants;
