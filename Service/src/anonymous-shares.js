// One address's share of a day's anonymous writes (migration 0035). The global daily caps protect
// the store; these keep one address from spending them for everyone.

import { sha256Hex } from "./crypto.js";

/** Per address per day: how many writes and how many bytes. */
export const SHARES = {
  report: { n: 20, bytes: 64 * 1024 * 1024 },
  diagnostics: { n: 200, bytes: 2 * 1024 * 1024 },
  usage: { n: 2000, bytes: 4 * 1024 * 1024 },
};

const dayOf = (t) => new Date(t).toISOString().slice(0, 10);

/**
 * Takes `n` writes of `bytes` from this address's share for today; false when they don't fit
 * (nothing is taken then). One statement, so two requests at once can't both take the last of it.
 */
export async function takeShare(deps, kind, address, n, bytes) {
  const limit = SHARES[kind];
  if (n > limit.n || bytes > limit.bytes) return false;
  const day = dayOf(deps.now());
  const who = (await sha256Hex(`anonymous-share|${deps.config.tokenKey}|${day}|${address}`)).slice(0, 32);
  const r = await deps.db.run(
    `INSERT INTO anonymous_shares (day, kind, who, n, bytes) VALUES (?, ?, ?, ?, ?)
     ON CONFLICT (day, kind, who) DO UPDATE SET n = anonymous_shares.n + excluded.n, bytes = anonymous_shares.bytes + excluded.bytes
     WHERE anonymous_shares.n + excluded.n <= ? AND anonymous_shares.bytes + excluded.bytes <= ?`,
    day, kind, who, n, bytes, limit.n, limit.bytes);
  return r.changes > 0;
}

/** The job: yesterday's shares go. */
export const forgetShares = (deps) => deps.db.run("DELETE FROM anonymous_shares WHERE day < ?", dayOf(deps.now()));
