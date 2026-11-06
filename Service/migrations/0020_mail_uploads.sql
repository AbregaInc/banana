-- Temporary attachment parts, scoped to one authenticated pending Gmail operation.
-- Rows survive account removal until the associated object has actually been deleted.
CREATE TABLE mail_uploads (
 account_id TEXT NOT NULL,
 operation_id TEXT NOT NULL,
 chunk_hash TEXT NOT NULL,
 bytes INTEGER NOT NULL CHECK(bytes BETWEEN 0 AND 1048576),
 state TEXT NOT NULL CHECK(state IN ('uploading','ready','deleting')),
 updated_at BIGINT NOT NULL,
 PRIMARY KEY(account_id,operation_id,chunk_hash)
);
CREATE INDEX mail_uploads_expiry ON mail_uploads(updated_at);
