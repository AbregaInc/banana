-- One APNs provider token (the signed JWT) for every Worker isolate and Durable Object. Each made
-- its own, and Apple refuses pushes with 429 TooManyProviderTokenUpdates when a key's token changes
-- more than once in 20 minutes: silent pushes (new mail, calendar) were dropped.
CREATE TABLE apns_provider_tokens (
  key_id TEXT PRIMARY KEY,
  token TEXT NOT NULL,
  issued_at INTEGER NOT NULL
);
