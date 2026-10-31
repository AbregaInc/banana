// Calendar watches: what the API and the 15-minute job share. A row in `watches` is a calendar the
// app reads; 'live' rows have a channel at Google, 'failed' ones wait for a retry (backoff).

import { GoogleRefused } from "./google.js";
import { newId, newSecret, uuid } from "./crypto.js";

export const WATCH_TTL_SECONDS = 7 * 24 * 60 * 60; // Google's most for calendar channels
const RETRY_FIRST = 15 * 60 * 1000;
const RETRY_MOST = 24 * 60 * 60 * 1000;

/** How long to wait after the nth failure in a row: 15 min, 30, 1 h … up to a day. */
export const backoff = (failures) => Math.min(RETRY_FIRST * 2 ** Math.max(0, failures - 1), RETRY_MOST);

/** @typedef {{sub: string, account_id: string, refresh_token: string|null, status: string}} Link */

export function audit(deps, account, action) {
  return {
    sql: "INSERT INTO audit (id, account_id, at, action) VALUES (?, ?, ?, ?)",
    params: [newId(deps.random), account, deps.now(), action],
  };
}

/**
 * What was read for event alerts (docs/design/EVENT-ALERTS.md) lives only as long as something
 * watches its calendar: the sync tokens, what was known of the events, and their alerts go with
 * the last watch. Statements for a batch, after the watches' own changes; one link's (`sub`) or,
 * without one, every link's.
 */
export function forgetUnwatched(sub) {
  return ["alerts", "event_state", "calendar_sync"].map((table) => ({
    sql: `DELETE FROM ${table} WHERE ${sub === undefined ? "" : "google_sub = ? AND "}NOT EXISTS
            (SELECT 1 FROM watches w WHERE w.google_sub = ${table}.google_sub AND w.calendar_id = ${table}.calendar_id)`,
    params: sub === undefined ? [] : [sub],
  }));
}

/**
 * Google said invalid_grant: the person removed Banana's access, or the Google account changed or
 * went. The link forgets its refresh token (it no longer works) and its watches, and stays only as
 * the sub and email that let that Google account sign in again. When it was the account's last
 * working link, the account's sessions end: a session lasts exactly as long as Google says yes.
 */
export async function markRefused(deps, link) {
  const changed = await deps.db.run(
    "UPDATE google_links SET status = 'refused', refresh_token = NULL, updated_at = ? WHERE sub = ? AND status = 'ok'",
    deps.now(), link.sub);
  link.status = "refused";
  link.refresh_token = null;
  if (!changed.changes) return;
  const working = await deps.db.first("SELECT COUNT(*) AS n FROM google_links WHERE account_id = ? AND status = 'ok'", link.account_id);
  const statements = [
    { sql: "DELETE FROM watches WHERE google_sub = ?", params: [link.sub] },
    ...forgetUnwatched(link.sub),
    audit(deps, link.account_id, "google_refused"),
  ];
  if (!Number(working?.n)) {
    statements.push({ sql: "DELETE FROM sessions WHERE account_id = ?", params: [link.account_id] },
                    audit(deps, link.account_id, "signed_out"));
  }
  await deps.db.batch(statements);
}

/**
 * An access token for the link. Throws GoogleRefused (after marking the link) when Google refuses.
 * @param {any} deps @param {{open: Function}} vault @param {Link} link
 */
export async function accessToken(deps, vault, link) {
  if (link.status !== "ok" || !link.refresh_token) throw new GoogleRefused("link refused");
  const refresh = await vault.open(link.sub, link.refresh_token);
  try {
    return (await deps.google.refresh(refresh)).accessToken;
  } catch (error) {
    if (error instanceof GoogleRefused) await markRefused(deps, link);
    throw error;
  }
}

/**
 * Opens a channel at Google for one calendar and records it as live. Returns the channel id, or null
 * when another row already watches the calendar. `replacing`: the old row this one renews, dropped as
 * the new one is recorded (the channel at Google is opened first, so no change goes unnoticed).
 */
export async function addWatch(deps, link, calendarId, access, replacing = null) {
  const id = uuid(deps.random);
  const secret = newSecret(deps.random);
  const created = deps.now();
  const answer = await deps.google.watch(access, calendarId, {
    id, token: secret, address: `${deps.config.publicUrl}/v1/google/notify`, ttlSeconds: WATCH_TTL_SECONDS,
  });
  const expires = Number.isFinite(answer.expiration) && answer.expiration > 0 ? answer.expiration : created + WATCH_TTL_SECONDS * 1000;
  // One service watch per calendar (watches_service_calendar): two reconciles racing open two
  // channels, and the second row loses; its channel is closed again rather than left ringing.
  // A renewal drops the old row and records the new one in one transaction: cut off between the two,
  // the calendar would be left with no row (and its alerts forgotten by the job's sweep).
  const insert = {
    sql: `INSERT OR IGNORE INTO watches (channel_id, account_id, google_sub, calendar_id, resource_id, secret, expires_at, status, failures, retry_at, created_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, 'live', 0, NULL, ?)`,
    params: [id, link.account_id, link.sub, calendarId, answer.resourceId, secret, expires, created],
  };
  const results = await deps.db.batch(replacing ? [{ sql: "DELETE FROM watches WHERE channel_id = ?", params: [replacing] }, insert] : [insert]);
  const row = results[results.length - 1];
  if (!row.changes) {
    await stopWatch(deps, access, { channel_id: id, resource_id: answer.resourceId, status: "live" });
    return null;
  }
  return id;
}

/** Ends a channel at Google. Errors are ignored: an unknown channel's notices are ignored anyway. */
export async function stopWatch(deps, access, row) {
  if (!access || !row.resource_id || row.status !== "live") return;
  try { await deps.google.stop(access, { id: row.channel_id, resourceId: row.resource_id }); } catch { /* ignored */ }
}

/** Failures of a watch are on the record once an hour per account, not once per calendar per try. */
const AUDIT_FAILURES_EVERY = 60 * 60 * 1000;
/** A calendar refused this many times in a row (two weeks at the longest wait) is given up. */
export const MOST_WATCH_FAILURES = 14;

function auditFailure(deps, account) {
  return {
    sql: `INSERT INTO audit (id, account_id, at, action) SELECT ?, ?, ?, 'watch_failed'
          WHERE NOT EXISTS (SELECT 1 FROM audit WHERE account_id = ? AND action = 'watch_failed' AND at > ?)`,
    params: [newId(deps.random), account, deps.now(), account, deps.now() - AUDIT_FAILURES_EVERY],
  };
}

/** A calendar whose channel couldn't be opened: remembered, retried later. */
async function addFailed(deps, link, calendarId, failures = 1) {
  const t = deps.now();
  await deps.db.batch([
    { sql: `INSERT OR IGNORE INTO watches (channel_id, account_id, google_sub, calendar_id, resource_id, secret, expires_at, status, failures, retry_at, created_at)
            VALUES (?, ?, ?, ?, NULL, ?, NULL, 'failed', ?, ?, ?)`,
      params: [uuid(deps.random), link.account_id, link.sub, calendarId, newSecret(deps.random), failures, t + backoff(failures), t] },
    auditFailure(deps, link.account_id),
  ]);
}

/** An existing row whose renewal or retry failed: waits longer next time. */
export async function postpone(deps, row) {
  const failures = Number(row.failures ?? 0) + 1;
  // After MOST_WATCH_FAILURES the calendar is given up: a next calendar list brings it back.
  const change = failures >= MOST_WATCH_FAILURES
    ? { sql: "DELETE FROM watches WHERE channel_id = ?", params: [row.channel_id] }
    : { sql: "UPDATE watches SET failures = ?, retry_at = ? WHERE channel_id = ?", params: [failures, deps.now() + backoff(failures), row.channel_id] };
  await deps.db.batch([change, auditFailure(deps, row.account_id)]);
}

/**
 * Makes the link's watches match the calendars the app reads: opens channels for new ones, stops
 * and forgets the ones no longer listed.
 * @param {any} deps @param {any} vault @param {Link} link @param {string[]} ids
 */
export async function reconcile(deps, vault, link, ids) {
  // Without the service's own Google permission (a link made by identity token), the devices
  // open the watches themselves (/v1/google/channels).
  if (!link.refresh_token) return;
  const rows = await deps.db.all("SELECT * FROM watches WHERE google_sub = ? AND managed_by = 'service'", link.sub);
  const wanted = new Set(ids);
  // A failed row for a calendar already waits for its retry; it is not opened again here.
  const failedWait = new Set(rows.filter((r) => r.status === "failed").map((r) => r.calendar_id));
  const have = new Set(rows.map((r) => r.calendar_id));
  const gone = rows.filter((r) => !wanted.has(r.calendar_id));
  const added = ids.filter((id) => !have.has(id) && !failedWait.has(id));
  if (!gone.length && !added.length) return;

  let access = null;
  try { access = await accessToken(deps, vault, link); }
  catch (error) {
    // Refused: the link's watches are gone with its token, and none are wanted until it connects again.
    if (error instanceof GoogleRefused) return;
    console.log(`calendars: no access token (${error.name})`);
  }

  for (const row of gone) {
    await stopWatch(deps, access, row);
    await deps.db.run("DELETE FROM watches WHERE channel_id = ?", row.channel_id);
  }
  if (gone.length) await deps.db.batch(forgetUnwatched(link.sub));
  for (const id of added) {
    if (!access) { await addFailed(deps, link, id); continue; }
    try { await addWatch(deps, link, id, access); }
    catch (error) {
      console.log(`calendars: watch failed (${error.status ?? error.name})`);
      await addFailed(deps, link, id);
    }
  }
}

/** Before a link goes: stops its channels and revokes its refresh token at Google. Never throws. */
export async function forget(deps, vault, link) {
  let refresh = null;
  try { refresh = link.refresh_token ? await vault.open(link.sub, link.refresh_token) : null; } catch { refresh = null; }
  if (!refresh) return;
  const live = await deps.db.all("SELECT channel_id, resource_id, status FROM watches WHERE google_sub = ? AND status = 'live'", link.sub);
  if (live.length && link.status === "ok") {
    try {
      const access = (await deps.google.refresh(refresh)).accessToken;
      for (const row of live) await stopWatch(deps, access, row);
    } catch { /* refused or down: the channels end on their own within a week, and their notices are ignored */ }
  }
  try { await deps.google.revoke(refresh); } catch { /* ignored */ }
}
