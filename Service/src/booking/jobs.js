// Booking's share of the scheduled work. Every minute: bookings whose event isn't made yet (the
// answer's own try died, or Google failed: three tries, then failed), invites held past the Undo
// window, cancelled events still at Google, and reminders. Every 15 minutes: busy snapshots older
// than 10 minutes, what the host changed at Google, retention, and the daily check of guests' grants.
//
// Never logged: names, emails, ids.

import { createVault } from "../crypto.js";
import { GoogleRefused } from "../google.js";
import { MINUTE } from "./slots.js";
import { STALE, rebuildSnapshot } from "./busy.js";
import { complete, deleteAtGoogle, liveRow, mail, patchTime, readHost, releaseInvite } from "./book.js";
import { forgetGuest } from "./guests.js";

const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;
const KEEP_BOOKINGS = 30 * DAY;      // the guest's details, after the meeting
const KEEP_GUESTS = 730 * DAY;       // a guest account with no use
const KEEP_GUEST_SESSIONS = 365 * DAY;
const BATCH = 25;

/** Every minute. */
export async function bookingMinute(ctx) {
  const { db, now } = ctx.deps;
  const t = now();
  const out = { completed: 0, invited: 0, moved: 0, deleted: 0, reminded: 0 };
  // Work is bounded by the meeting: a reservation whose meeting ended before its event was made fails quietly.
  await db.run("UPDATE bookings SET status = 'failed', next_at = NULL WHERE status = 'pending' AND end_at <= ?", t);
  for (const r of await db.all("SELECT id FROM bookings WHERE status = 'pending' AND next_at <= ? AND end_at > ? ORDER BY next_at LIMIT ?", t, t, BATCH)) {
    if ((await complete(ctx, r.id)) === "confirmed") out.completed++;
  }
  for (const r of await db.all(
    "SELECT id FROM bookings WHERE status = 'confirmed' AND invite IN ('held', 'sending') AND next_at <= ? AND end_at > ? ORDER BY next_at LIMIT ?", t, t, BATCH)) {
    if (await releaseInvite(ctx, r.id)) out.invited++;
  }
  for (const r of await db.all(
    "SELECT id FROM bookings WHERE status = 'confirmed' AND patch_pending = 1 AND next_at <= ? AND end_at > ? ORDER BY next_at LIMIT ?", t, t, BATCH)) {
    if (await patchTime(ctx, r.id, null, { fromJob: true })) out.moved++;
  }
  for (const r of await db.all(
    "SELECT id FROM bookings WHERE status = 'cancelled' AND google_pending = 1 AND next_at <= ? AND end_at > ? ORDER BY next_at LIMIT ?", t, t, BATCH)) {
    if (await deleteAtGoogle(ctx, r.id)) out.deleted++;
  }
  // What the meeting outlived is let go: nothing about it matters any more.
  await db.run("UPDATE bookings SET google_pending = 0, patch_pending = 0, next_at = NULL WHERE (google_pending = 1 OR patch_pending = 1) AND end_at <= ?", t);
  out.reminded = await reminders(ctx);
  return out;
}

/**
 * The 24-hour and 1-hour emails, once each. One a booking made (or moved) inside its window is
 * skipped. Before sending, the event is read: gone or moved at Google, the guest gets that news
 * once instead. When Google can't be asked (the host's token refused, Google down), the row is sent.
 */
export async function reminders(ctx) {
  const { db, now } = ctx.deps;
  const t = now();
  // Windows already past at booking time, or passed while nothing ran: skipped, not sent late.
  await db.batch([
    { sql: "UPDATE bookings SET reminded_24 = 2 WHERE reminded_24 = 0 AND status = 'confirmed' AND (timed_at > start_at - ? OR start_at <= ?)", params: [DAY, t + HOUR] },
    { sql: "UPDATE bookings SET reminded_1 = 2 WHERE reminded_1 = 0 AND status = 'confirmed' AND (timed_at > start_at - ? OR start_at <= ?)", params: [HOUR, t] },
  ]);
  const due = await db.all(
    `SELECT * FROM bookings WHERE status = 'confirmed' AND invite IN ('sent', 'failed') AND guest_email IS NOT NULL
       AND ((reminded_24 = 0 AND start_at <= ?) OR (reminded_1 = 0 AND start_at <= ?)) ORDER BY start_at LIMIT ?`, t + DAY, t + HOUR, BATCH);
  let sent = 0;
  for (const row of due) {
    const which = row.reminded_1 === 0 && Number(row.start_at) <= t + HOUR ? "reminded_1" : "reminded_24";
    const claimed = await db.run(`UPDATE bookings SET ${which} = 1 WHERE id = ? AND ${which} = 0`, row.id);
    if (!claimed.changes) continue;
    const host = await readHost(ctx, { account: row.account_id });
    const live = await liveRow(ctx, row);
    if (live.changed === "cancelled") { await mail(ctx, "cancelled", live, host); continue; }
    if (live.changed === "moved") { await mail(ctx, "moved", live, host); continue; }
    if (live.status === "cancelled") continue;
    if (await mail(ctx, which === "reminded_1" ? "reminder1" : "reminder24", live, host)) sent++;
  }
  return sent;
}

/**
 * After a snapshot: the host's own changes to booked events, seen in it (an event moved, or missing
 * from the calendar), confirmed with one read each, and the guest told once. Only events on
 * calendars the snapshot read can be judged; the others are left to the reminders' read.
 */
export async function reconcile(ctx, account, horizon) {
  const { db } = ctx.deps;
  if (!horizon?.busy) return 0;
  const seen = new Map(horizon.busy.filter((b) => b[2]).map((b) => [b[2], b]));
  const read = (row) => (horizon.calendars ?? []).some((c) => c.sub === row.calendar_sub && (c.id === row.calendar_id || (row.calendar_id === "primary" && c.primary)));
  const rows = await db.all(
    "SELECT * FROM bookings WHERE account_id = ? AND status = 'confirmed' AND invite IN ('sent', 'failed') AND patch_pending = 0 AND start_at >= ? AND end_at <= ?",
    account, horizon.from, horizon.to);
  let told = 0;
  for (const row of rows) {
    if (!read(row)) continue;
    const b = seen.get(row.id);
    if (b && b[0] === Number(row.start_at) && b[1] === Number(row.end_at)) continue;
    const live = await liveRow(ctx, row);
    if (!live.changed) continue;
    const host = await readHost(ctx, { account });
    if (await mail(ctx, live.changed, live, host)) told++;
  }
  return told;
}

/** Every 15 minutes. */
export async function bookingQuarter(ctx) {
  const { deps } = ctx;
  const { db, now } = deps;
  const t = now();
  const out = { rebuilt: 0, told: 0, swept: 0, guests: 0, checked: 0 };
  const stale = await db.all(
    `SELECT h.account_id FROM booking_handles h LEFT JOIN busy_snapshot s ON s.account_id = h.account_id
     WHERE s.computed_at IS NULL OR s.computed_at < ? ORDER BY s.computed_at LIMIT ?`, t - STALE, BATCH);
  for (const { account_id } of stale) {
    try {
      const written = await rebuildSnapshot(deps, account_id, { vault: ctx.vault });
      if (written) { out.rebuilt++; out.told += await reconcile(ctx, account_id, written.horizon); }
    } catch (error) { console.log(`booking: snapshot failed (${error.name})`); }
  }
  const swept = await db.run("DELETE FROM bookings WHERE end_at < ?", t - KEEP_BOOKINGS);
  out.swept = swept.changes;
  await db.batch([
    { sql: "DELETE FROM sessions WHERE kind = 'guest' AND last_used_at < ?", params: [t - KEEP_GUEST_SESSIONS] },
    { sql: "DELETE FROM email_codes WHERE expires_at < ? AND window_at < ?", params: [t, t - DAY] },
  ]);
  for (const g of await db.all("SELECT account_id FROM guests WHERE last_seen_at < ? LIMIT ?", t - KEEP_GUESTS, BATCH)) {
    await forgetGuest(deps, ctx.vault, g.account_id);
    out.guests++;
  }
  // Once a day per grant: does Google still say yes? A refusal ends the grant (the guest connects again).
  for (const g of await db.all(
    "SELECT sub, refresh_token FROM guest_grants WHERE status = 'ok' AND refresh_token IS NOT NULL AND (checked_at IS NULL OR checked_at < ?) LIMIT ?", t - DAY, 100)) {
    try {
      await deps.google.refresh(await ctx.vault.open(`guest:${g.sub}`, g.refresh_token));
      await db.run("UPDATE guest_grants SET checked_at = ? WHERE sub = ?", t, g.sub);
      out.checked++;
    } catch (error) {
      if (error instanceof GoogleRefused) await db.run("UPDATE guest_grants SET status = 'refused', refresh_token = NULL, updated_at = ? WHERE sub = ?", t, g.sub);
    }
  }
  return out;
}

/** The context the jobs and routes share. */
export function bookingContext(deps, { push, signer }) {
  return { deps, vault: createVault(deps.config.tokenKey, deps.random), signer, config: deps.config, push };
}
