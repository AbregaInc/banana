-- Google links live as long as Google keeps saying yes (docs/design/ACCOUNTS.md, 18 Oct 2026).
-- status is now ok | refused | unlinked. A refused or unlinked link keeps its sub and email, so
-- signing in with that Google account again finds the same Banana account, and only that Google
-- account can delete it; its refresh token is gone.
-- checked_at: when the service last made sure Google still says yes (once a day).
ALTER TABLE google_links ADD COLUMN checked_at BIGINT;
