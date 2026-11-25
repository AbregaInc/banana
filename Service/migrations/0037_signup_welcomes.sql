CREATE TABLE signup_welcomes (
  account_id TEXT PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
  google_sub TEXT NOT NULL REFERENCES google_links(sub) ON DELETE CASCADE,
  available_at BIGINT NOT NULL,
  state TEXT NOT NULL DEFAULT 'pending'
);
CREATE INDEX signup_welcomes_due ON signup_welcomes(state, available_at);
