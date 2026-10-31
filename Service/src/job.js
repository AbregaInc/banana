// The 15-minute job: renews calendar watches a day before Google ends them, retries the ones that
// failed, and once a day makes sure Google still says yes to each working link (a refused one ends
// its watches, and with the account's last working link its sessions). Links Google refused are
// skipped until the person connects them again.

import { GoogleRefused } from "./google.js";
import { createVault } from "./crypto.js";
import { accessToken, addWatch, forgetUnwatched, postpone, stopWatch } from "./calendar.js";
import { KEEP as KEEP_DIAGNOSTICS } from "./diagnostics.js";

const RENEW_BEFORE = 24 * 60 * 60 * 1000;
const CHECK_EVERY = 24 * 60 * 60 * 1000;
const CHECKS_PER_RUN = 200;
const STALE_DEVICE = 30 * 24 * 60 * 60 * 1000;
const KEEP_COUNTS = 400 * 24 * 60 * 60 * 1000;
const MOST_RENEWALS_PER_RUN = 200;   // Google calls a minute from the job; the rest wait a minute

/** @param {import("./app.js").Deps} deps */
export async function runJob(deps) {
  const vault = createVault(deps.config.tokenKey, deps.random);
  const t = deps.now();
  const due = await deps.db.all(
    `SELECT w.*, g.refresh_token AS link_refresh_token, g.status AS link_status, g.account_id AS link_account_id
     FROM watches w JOIN google_links g ON g.sub = w.google_sub
     WHERE g.status = 'ok' AND w.managed_by = 'service' AND (w.retry_at IS NULL OR w.retry_at <= ?)
       AND ((w.status = 'live' AND w.expires_at < ?) OR w.status = 'failed')
     ORDER BY COALESCE(w.retry_at, w.expires_at), w.channel_id LIMIT ?`, t, t + RENEW_BEFORE, MOST_RENEWALS_PER_RUN);   // the oldest need first

  const result = { renewed: 0, retried: 0, failed: 0, refused: 0 };
  const bySub = new Map();
  for (const row of due) (bySub.get(row.google_sub) ?? bySub.set(row.google_sub, []).get(row.google_sub)).push(row);

  for (const [sub, rows] of bySub) {
    const link = { sub, account_id: rows[0].link_account_id, refresh_token: rows[0].link_refresh_token, status: rows[0].link_status };
    let access;
    try { access = await accessToken(deps, vault, link); }
    catch (error) {
      if (error instanceof GoogleRefused) { result.refused++; continue; }
      for (const row of rows) { await postpone(deps, row); result.failed++; }
      continue;
    }
    for (const row of rows) {
      try {
        // The new channel first, so no change goes unnoticed; then the old one ends.
        await addWatch(deps, link, row.calendar_id, access, row.channel_id);
        await stopWatch(deps, access, row);
        if (row.status === "live") result.renewed++; else result.retried++;
      } catch (error) {
        console.log(`job: watch failed (${error.status ?? error.name})`);
        await postpone(deps, row);
        result.failed++;
      }
    }
  }
  // Once a day per working link: does Google still say yes?
  result.checked = 0;
  const stale = await deps.db.all(
    `SELECT sub, account_id, refresh_token, status FROM google_links
     WHERE status = 'ok' AND refresh_token IS NOT NULL AND (checked_at IS NULL OR checked_at < ?) ORDER BY checked_at, sub LIMIT ?`,
    t - CHECK_EVERY, CHECKS_PER_RUN);
  for (const link of stale) {
    try {
      await accessToken(deps, vault, link);
      await deps.db.run("UPDATE google_links SET checked_at = ? WHERE sub = ?", t, link.sub);
      result.checked++;
    } catch (error) {
      if (error instanceof GoogleRefused) result.refused++;   // markRefused has done the rest
    }
  }
  // Device-made channels that ended (the devices renew theirs) or never got confirmed are forgotten.
  await deps.db.run(
    "DELETE FROM watches WHERE managed_by = 'device' AND ((status = 'live' AND expires_at < ?) OR (status = 'pending' AND created_at < ?))",
    t, t - RENEW_BEFORE);
  // And what was read for alerts on calendars nothing watches any more.
  await deps.db.batch(forgetUnwatched());
  // A device that lost its push token (Apple said it's gone: a reinstall, a build replaced) and
  // hasn't checked in for a month is gone too; one that comes back registers itself again.
  await deps.db.run("DELETE FROM devices WHERE push_token IS NULL AND updated_at < ?", t - STALE_DEVICE);
  // Crash and performance reports go after 90 days; usage totals after 400 days.
  await deps.db.run("DELETE FROM diagnostics WHERE received_at < ?", t - KEEP_DIAGNOSTICS);
  await deps.db.run("DELETE FROM counts WHERE day < ?", new Date(t - KEEP_COUNTS).toISOString().slice(0, 10));
  return result;
}
