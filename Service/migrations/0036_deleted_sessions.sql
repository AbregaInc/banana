-- The sessions of an account that was deleted, by hash, for a month: a device still holding one is
-- told the account was deleted (not just "signed out"), so it doesn't sign straight back in and
-- start a new account by itself. Nothing else about the account is kept.
CREATE TABLE deleted_sessions (
  token_hash TEXT   PRIMARY KEY,
  deleted_at BIGINT NOT NULL
);
