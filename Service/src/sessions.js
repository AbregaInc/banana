// Device sessions (docs/design/ACCOUNTS.md). Shared by the routes and the job.

/** How long a session proven by a Google account the service can't ask about holds without a fresh proof. */
export const SESSION_PROOF = 30 * 24 * 60 * 60 * 1000;
