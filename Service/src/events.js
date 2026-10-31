// Event alerts, the moving parts (docs/design/EVENT-ALERTS.md): read a calendar that Google says
// changed, decide its alerts (src/alerts.js), keep them, send the immediate ones, and dispatch the
// timed ones when they are due. Never logged: titles, emails, calendar or event ids.

import { personalSpace } from "./sync-routes.js";
import { calendarNotifies } from "./calendar-preferences.js";
import { accessToken } from "./calendar.js";
import { createVault, sha256Hex } from "./crypto.js";
import { GoogleError, GoogleRefused } from "./google.js";
import { DEFAULT_LEADS, alertId, alertPayload, clearPayload, collapseId, decide } from "./alerts.js";

const DAY = 24 * 60 * 60 * 1000;
export const READ_BACK = DAY;            // the first read starts a day ago
export const READ_AHEAD = 30 * DAY;      // and reaches a month out
export const KEEP_DONE = DAY;            // sent or cleared alerts stay a day, for the record
export const DISPATCH_WINDOW = 60 * 1000;

/** The account's lead times and time zone, as its devices last reported them. */
export async function alertSettings(db, account) {
  const row = await db.first("SELECT alert_leads, time_zone FROM accounts WHERE id = ?", account);
  let leads = DEFAULT_LEADS;
  try { const parsed = JSON.parse(row?.alert_leads ?? "null"); if (Array.isArray(parsed)) leads = parsed; } catch { /* default */ }
  return { leads, timeZone: row?.time_zone ?? null };
}

/**
 * Reads what changed on one calendar and brings its alerts up to date. Returns what it did.
 * @param {import("./app.js").Deps} deps
 * @param {{seal: Function, open: Function}} vault
 * @param {{sub: string, account_id: string, email: string, refresh_token: string|null, status: string}} link
 * @param {string} calendarId
 */
/** Events taken from one read, earliest first (one Google page). A changed recurring series can hand out
 * years of instances; the ones past this bound get no event_state row, so a later change to one of them
 * is judged new (filtered for a series by the `known` check below). Nothing waits more than a month ahead,
 * and the daily plan reads the next month in full, so the bound costs no alert. */
export const MOST_EVENTS_PER_READ = 2500;

export async function syncCalendar(deps, vault, link, calendarId) {
  const { db, now } = deps;
  const t = now();
  const result = { read: 0, alerts: 0, sent: 0, full: false, truncated: 0 };
  if (!link.refresh_token || link.status !== "ok") return { ...result, skipped: "no access" };
  let access;
  try { access = await accessToken(deps, vault, link); }
  catch (error) { return { ...result, skipped: error instanceof GoogleRefused ? "refused" : "no token" }; }

  const sync = await db.first("SELECT sync_token FROM calendar_sync WHERE google_sub = ? AND calendar_id = ?", link.sub, calendarId);
  let page;
  let baseline = false;
  if (sync?.sync_token) {
    try { page = await deps.google.listEvents(access, calendarId, { syncToken: sync.sync_token }); }
    catch (error) {
      if (!(error instanceof GoogleError && error.status === 410)) throw error;
      page = null;   // the token is gone: read in full
    }
  }
  if (!page) {
    baseline = !sync;
    page = await deps.google.listEvents(access, calendarId, { timeMin: new Date(t - READ_BACK).toISOString(), timeMax: new Date(t + READ_AHEAD).toISOString() });
    result.full = true;
  }
  // The new token is kept only after every event of this delta is processed (below): a read that
  // stops halfway is read again next time, instead of its remaining changes being lost for good.
  const { leads, timeZone } = await alertSettings(db, link.account_id);
  const immediate = [];
  // Google can deliver years of expanded instances in one change. Process the earliest first.
  const seenSeries = new Set();
  const events = [...(page.events ?? [])].sort((a, b) =>
    Date.parse(a.start?.dateTime ?? a.start?.date ?? '') - Date.parse(b.start?.dateTime ?? b.start?.date ?? '')).slice(0, MOST_EVENTS_PER_READ);
  result.truncated = Math.max(0, (page.events?.length ?? 0) - events.length);
  for (const event of events) {
    if (!event?.id) continue;
    result.read++;
    const previous = await db.first(
      "SELECT start_at, end_at, status, response, title_hash FROM event_state WHERE google_sub = ? AND calendar_id = ? AND event_id = ?",
      link.sub, calendarId, event.id);
    const d = decide({ event, calendarId, selfEmail: link.email, now: t, leads, timeZone, previous, baseline });
    let alerts = withinMonth(d.alerts, t);
    // Read again unchanged (a delta re-read after a failure): its pending alerts stand.
    const unchanged = previous && d.state && ["start_at", "end_at", "status", "response", "title_hash"].every((k) => (previous[k] ?? null) === (d.state[k] ?? null));
    if (unchanged && !alerts.length) continue;
    const series = event.recurringEventId || (event.recurrence?.length ? event.id : null);
    const announcement = a => a.kind === 'invite' || a.kind === 'changed' && !previous;
    if (series && (baseline || alerts.some(announcement))) {
      const seriesHash = await sha256Hex(event.iCalUID || JSON.stringify([calendarId, series]));
      // Seed from pre-upgrade instances too: a series already known must not announce each
      // newly-expanded future occurrence after this release.
      if (seenSeries.has(seriesHash)) alerts = alerts.filter(a => !announcement(a));
      else {
        seenSeries.add(seriesHash);
        const known = await db.first(`SELECT 1 AS yes FROM event_state WHERE google_sub = ? AND calendar_id = ?
          AND (event_id = ? OR substr(event_id, 1, length(?) + 1) = ? || '_') LIMIT 1`,
          link.sub, calendarId, series, series, series);
        const receipt = await db.run('INSERT OR IGNORE INTO series_invitations (account_id, series_hash, first_seen_at) VALUES (?, ?, ?)',
          link.account_id, seriesHash, t);
        if (baseline || known || !receipt.changes) alerts = alerts.filter(a => !announcement(a));
      }
    }
    // Accept/Decline must reply to the series, not just the first expanded occurrence.
    alerts = alerts.map(a => a.kind === 'invite' && series ? { ...a, id: alertId(calendarId, series, 'invite') } : a);
    const statements = [];
    const keep = alerts.map((a) => a.id);
    // Pending alerts this event no longer wants (moved, cancelled, declined, became all-day).
    const pending = await db.all(
      "SELECT id FROM alerts WHERE google_sub = ? AND calendar_id = ? AND event_id = ? AND status = 'pending'", link.sub, calendarId, event.id);
    for (const row of pending) if (!keep.includes(row.id)) statements.push({ sql: "DELETE FROM alerts WHERE id = ? AND status = 'pending'", params: [row.id] });
    for (const a of alerts) statements.push(upsertAlert(link, calendarId, a.kind === "invite" && series ? series : event.id, a, t));
    if (d.state) {
      statements.push({
        sql: `INSERT INTO event_state (google_sub, calendar_id, event_id, start_at, end_at, status, response, title_hash, updated_at)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
              ON CONFLICT (google_sub, calendar_id, event_id) DO UPDATE SET start_at = excluded.start_at, end_at = excluded.end_at,
                status = excluded.status, response = excluded.response, title_hash = excluded.title_hash, updated_at = excluded.updated_at`,
        params: [link.sub, calendarId, event.id, d.state.start_at, d.state.end_at, d.state.status, d.state.response, d.state.title_hash, t],
      });
    } else {
      statements.push({ sql: "DELETE FROM event_state WHERE google_sub = ? AND calendar_id = ? AND event_id = ?", params: [link.sub, calendarId, event.id] });
    }
    if (statements.length) await db.batch(statements);
    result.alerts += alerts.length;
    for (const a of alerts) if (a.dueAt <= t) immediate.push(a.id);
  }
  await db.run(
    `INSERT INTO calendar_sync (google_sub, calendar_id, sync_token, read_at, planned_at) VALUES (?, ?, ?, ?, ?)
     ON CONFLICT (google_sub, calendar_id) DO UPDATE SET sync_token = excluded.sync_token, read_at = excluded.read_at,
       planned_at = COALESCE(excluded.planned_at, calendar_sync.planned_at)`,
    link.sub, calendarId, page.syncToken ?? null, t, result.full ? t : null);
  for (const id of immediate) result.sent += await sendAlert(deps, id);
  return result;
}

/**
 * Starting-soon alerts are kept only a month ahead (the privacy policy: a title waits up to a
 * month). Google's change feed hands out every instance of a recurring series that changed, years
 * of them; those further out are planned by `planAhead` as they come within the month.
 */
const withinMonth = (alerts, now) => alerts.filter((a) => a.kind !== "lead" || a.dueAt <= now + READ_AHEAD);

/** A new alert is pending; an existing pending one takes the new time and words (a move
 * re-plans); one already sent or cleared is left alone (no second ring for the same id). */
function upsertAlert(link, calendarId, eventId, a, t) {
  return {
    sql: `INSERT INTO alerts (id, account_id, google_sub, calendar_id, event_id, kind, due_at, title, body, status, created_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?)
          ON CONFLICT (id) DO UPDATE SET due_at = excluded.due_at, title = excluded.title, body = excluded.body
            WHERE alerts.status = 'pending'`,
    params: [a.id, link.account_id, link.sub, calendarId, eventId, a.kind, a.dueAt, a.title, a.body, t],
  };
}

const PLAN_EVERY = DAY;
const PLANS_PER_RUN = 5;

/**
 * Once a day per watched calendar: reads the next month and plans the starting-soon alerts of the
 * events that came within it. Plans only, silently: it never rings and never changes what the
 * change feed knows of an event, except to remember one it has never seen. An event changed since
 * the last change-feed read is left to the feed.
 * @param {import("./app.js").Deps} deps
 */
export async function planAhead(deps) {
  const { db, now } = deps;
  const t = now();
  const due = await db.all(
    `SELECT g.sub, g.account_id, g.email, g.refresh_token, g.status, c.calendar_id, c.read_at
     FROM calendar_sync c JOIN google_links g ON g.sub = c.google_sub
     WHERE g.status = 'ok' AND g.refresh_token IS NOT NULL AND (c.planned_at IS NULL OR c.planned_at < ?)
       AND EXISTS (SELECT 1 FROM watches w WHERE w.google_sub = c.google_sub AND w.calendar_id = c.calendar_id AND w.status = 'live')
     ORDER BY c.planned_at LIMIT ?`, t - PLAN_EVERY, PLANS_PER_RUN);
  if (!due.length) return 0;
  const vault = createVault(deps.config.tokenKey, deps.random);
  let planned = 0;
  for (const row of due) {
    try {
      const access = await accessToken(deps, vault, row);
      const page = await deps.google.listEvents(access, row.calendar_id, { timeMin: new Date(t).toISOString(), timeMax: new Date(t + READ_AHEAD).toISOString() });
      const { leads, timeZone } = await alertSettings(db, row.account_id);
      const statements = [];
      for (const event of page.events ?? []) {
        if (!event?.id) continue;
        const updated = Date.parse(event.updated ?? "");
        if (Number.isFinite(updated) && updated > Number(row.read_at)) continue;
        const previous = await db.first(
          "SELECT start_at, end_at, status, response, title_hash FROM event_state WHERE google_sub = ? AND calendar_id = ? AND event_id = ?",
          row.sub, row.calendar_id, event.id);
        const d = decide({ event, calendarId: row.calendar_id, selfEmail: row.email, now: t, leads, timeZone, previous, baseline: true });
        for (const a of withinMonth(d.alerts, t)) if (a.kind === "lead") statements.push(upsertAlert(row, row.calendar_id, event.id, a, t));
        if (!previous && d.state) {
          statements.push({
            sql: `INSERT INTO event_state (google_sub, calendar_id, event_id, start_at, end_at, status, response, title_hash, updated_at)
                  VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT (google_sub, calendar_id, event_id) DO NOTHING`,
            params: [row.sub, row.calendar_id, event.id, d.state.start_at, d.state.end_at, d.state.status, d.state.response, d.state.title_hash, t],
          });
        }
      }
      statements.push({ sql: "UPDATE calendar_sync SET planned_at = ? WHERE google_sub = ? AND calendar_id = ?", params: [t, row.sub, row.calendar_id] });
      await db.batch(statements);
      planned++;
    } catch (error) { console.log(`alerts: plan ahead failed (${error.name} ${error.status ?? ""})`); }
  }
  return planned;
}

/**
 * Sends one pending alert to every device of its account that doesn't hold it, and marks it
 * sent. Returns the number of devices pushed. The row's status is the claim: two senders
 * racing send once.
 */
export async function sendAlert(deps, id) {
  const { db, now } = deps;
  const claimed = await db.run("UPDATE alerts SET status = 'sent', sent_at = ? WHERE id = ? AND status = 'pending'", now(), id);
  if (!claimed.changes) return 0;
  const alert = await db.first("SELECT a.*, g.email FROM alerts a JOIN google_links g ON g.sub = a.google_sub WHERE a.id = ?", id);
  if (!alert) return 0;
  // Read the synced choice at dispatch, including for devices asleep since it changed.
  const preferences = await deps.spaces.get(personalSpace(alert.account_id)).read("core.smartSettings", "smart-settings");
  if (!calendarNotifies(preferences, alert.calendar_id)) return 0;
  const devices = await ringingDevices(db, alert, preferences);
  const payload = alertPayload({ id: alert.id, kind: alert.kind, title: alert.title, body: alert.body },
    { calendarId: alert.calendar_id, eventId: alert.event_id, email: alert.email });
  const outcomes = await Promise.all(devices.map(async (d) => {
    try {
      const answer = await deps.apns.send({ token: d.push_token, env: d.push_env, topic: d.bundle, payload, collapseId: collapseId(id), pushType: "alert", priority: 10 });
      const gone = answer.status === 410 || (answer.status === 400 && (answer.reason === "BadDeviceToken" || answer.reason === "DeviceTokenNotForTopic"));
      if (gone) await db.run("UPDATE devices SET push_token = NULL WHERE id = ? AND push_token = ?", d.id, d.push_token);
      return `${d.platform} ${answer.status}${answer.reason ? ` ${answer.reason}` : ""}`;
    } catch (error) { return `${d.platform} failed ${error.name}`; }
  }));
  console.log(`alert: ${alert.kind} to ${devices.length} device(s): ${outcomes.join(", ") || "none"}`);
  return devices.length;
}

const lead = (id) => id.slice(id.lastIndexOf("|") + 1);
const eventOf = (id) => id.slice(0, id.lastIndexOf("|"));
const plainTitle = (s) => String(s ?? "").toLowerCase().replace(/\s+/g, " ").trim();
/** Two alerts for one meeting: the same lead and the same title (callers match the second). */
const sameMeeting = (a, b) => lead(a.id) === lead(b.id) && plainTitle(a.title) === plainTitle(b.title);
const parsed = (json) => { try { const v = JSON.parse(json ?? "null"); return Array.isArray(v) ? v : null; } catch { return null; } };

/**
 * The devices an alert rings on: the account's devices that have said what they ring for (build
 * 61 on), alert for its calendar and weren't told to skip its event. And the same meeting on two
 * calendars (an invitation that reached two accounts) rings once on a device, as the devices show
 * it once (same lead, same second, same title): not where the device holds the other copy's
 * alert, nor where the other copy has already rung.
 */
async function ringingDevices(db, alert, preferences) {
  const devices = await db.all(
    `SELECT id, platform, push_token, push_env, bundle, alert_calendars, quiet_events FROM devices
     WHERE account_id = ? AND push_token IS NOT NULL AND alerts_at IS NOT NULL AND alert_calendars IS NOT NULL`, alert.account_id);
  if (!devices.length) return [];
  const held = await db.all(
    `SELECT h.device_id, h.alert_id AS id, a.due_at, a.title FROM held_alerts h JOIN devices d ON d.id = h.device_id
     LEFT JOIN alerts a ON a.id = h.alert_id WHERE d.account_id = ?`, alert.account_id);
  const rung = alert.kind !== "lead" ? [] : (await db.all(
    "SELECT id, calendar_id, title FROM alerts WHERE account_id = ? AND kind = 'lead' AND due_at = ? AND status IN ('sent', 'cleared') AND id <> ?",
    alert.account_id, alert.due_at, alert.id)).filter((t) => sameMeeting(t, alert));
  return devices.filter((d) => {
    const calendars = (parsed(d.alert_calendars) ?? []).filter(id => calendarNotifies(preferences, id));
    if (!calendars.includes(alert.calendar_id)) return false;
    if ((parsed(d.quiet_events) ?? []).includes(eventOf(alert.id))) return false;
    if (rung.some((t) => calendars.includes(t.calendar_id))) return false;
    return !held.some((h) => h.device_id === d.id
      && (h.id === alert.id || (alert.kind === "lead" && Number(h.due_at) === Number(alert.due_at) && sameMeeting(h, alert))));
  });
}

/** An alert dismissed or opened on one device: cleared, and the other devices told. */
export async function clearAlert(deps, account, id, fromDevice) {
  const { db, now } = deps;
  const changed = await db.run(
    "UPDATE alerts SET status = 'cleared', cleared_at = ? WHERE id = ? AND account_id = ? AND status IN ('pending', 'sent')", now(), id, account);
  const devices = await db.all(
    `SELECT id, platform, push_token, push_env, bundle FROM devices
     WHERE account_id = ? AND push_token IS NOT NULL AND alerts_at IS NOT NULL AND alert_calendars IS NOT NULL AND id <> ?`, account, fromDevice ?? "");
  await Promise.all(devices.map(async (d) => {
    try {
      await deps.apns.send({ token: d.push_token, env: d.push_env, topic: d.bundle, payload: clearPayload(id), collapseId: collapseId(`clear ${id}`) });
    } catch (error) { console.log(`alert-clear: failed (${error.name})`); }
  }));
  return { cleared: Boolean(changed.changes), told: devices.length };
}

/**
 * Every minute: sends the alerts due within the next minute at their exact second, and forgets
 * old sent and cleared ones.
 * @param {import("./app.js").Deps} deps
 * @param {(ms: number) => Promise<void>} [sleep]
 */
export async function dispatchAlerts(deps, sleep = (ms) => new Promise((r) => setTimeout(r, ms))) {
  const { db, now } = deps;
  const t = now();
  const due = await db.all("SELECT id, due_at FROM alerts WHERE status = 'pending' AND due_at <= ? ORDER BY due_at", t + DISPATCH_WINDOW);
  let sent = 0;
  for (const row of due) {
    const wait = Number(row.due_at) - now();
    if (wait > 0) await sleep(wait);
    sent += (await sendAlert(deps, row.id)) >= 0 ? 1 : 0;
  }
  const swept = await db.run("DELETE FROM alerts WHERE status IN ('sent', 'cleared') AND COALESCE(cleared_at, sent_at, created_at) < ?", t - KEEP_DONE);
  // Nothing waits more than a month ahead (withinMonth).
  await db.run("DELETE FROM alerts WHERE status = 'pending' AND kind = 'lead' AND due_at > ?", t + READ_AHEAD);
  // Held alerts of devices that are gone. A device's report replaces its whole list, so a held id
  // the service hasn't planned (yet) stays: forgetting it would ring that device twice once planned.
  await db.run("DELETE FROM held_alerts WHERE device_id NOT IN (SELECT id FROM devices)");
  return { due: due.length, sent, swept: swept.changes, first: await firstReads(deps), dirty: await dirtyReads(deps), planned: await planAhead(deps) };
}

const DIRTY_READS_PER_RUN = 10;

/**
 * Calendars whose notices came faster than the per-channel bound (POST /v1/google/notify) are read
 * here, so nothing a burst announced is lost; the mark goes once the read is done.
 * @param {import("./app.js").Deps} deps
 */
export async function dirtyReads(deps) {
  const marked = await deps.db.all(
    `SELECT DISTINCT w.channel_id, g.sub, g.account_id, g.email, g.refresh_token, g.status, w.calendar_id
     FROM watches w JOIN google_links g ON g.sub = w.google_sub
     WHERE w.status = 'live' AND w.dirty_at IS NOT NULL AND g.status = 'ok' AND g.refresh_token IS NOT NULL
     ORDER BY w.dirty_at LIMIT ?`, DIRTY_READS_PER_RUN);
  if (!marked.length) {
    // Marks on channels that cannot be read (no access) would otherwise stay forever.
    await deps.db.run("UPDATE watches SET dirty_at = NULL WHERE dirty_at IS NOT NULL AND dirty_at < ?", deps.now() - 24 * 60 * 60 * 1000);
    return 0;
  }
  const vault = createVault(deps.config.tokenKey, deps.random);
  let read = 0;
  for (const row of marked) {
    // The mark is taken before the read: a read that never returns (a run the platform cuts off) would
    // otherwise keep the head of the queue every minute, ahead of every other calendar's burst.
    const claimed = await deps.db.run("UPDATE watches SET dirty_at = NULL WHERE channel_id = ? AND dirty_at IS NOT NULL", row.channel_id);
    if (!claimed.changes) continue;
    try {
      const r = await syncCalendar(deps, vault, row, row.calendar_id);
      if (!r.skipped) read++;
    } catch (error) {
      console.log(`alerts: dirty read failed (${error.name} ${error.status ?? ""})`);
      // Marked again, at the back of the queue.
      await deps.db.run("UPDATE watches SET dirty_at = COALESCE(dirty_at, ?) WHERE channel_id = ?", deps.now(), row.channel_id);
    }
  }
  return read;
}

const FIRST_READS_PER_RUN = 5;

/**
 * A watched calendar the service has never read is read now, silently, so that its next change is
 * told apart from what was already there and rings. Without this the first change after a calendar
 * is watched (or after the service gets access) would only be the baseline. A few per minute; one
 * that fails is tried again on a later run.
 * @param {import("./app.js").Deps} deps
 */
export async function firstReads(deps) {
  const unread = await deps.db.all(
    `SELECT DISTINCT g.sub, g.account_id, g.email, g.refresh_token, g.status, w.calendar_id
     FROM watches w JOIN google_links g ON g.sub = w.google_sub
     WHERE w.status = 'live' AND g.status = 'ok' AND g.refresh_token IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM calendar_sync c WHERE c.google_sub = w.google_sub AND c.calendar_id = w.calendar_id)
     ORDER BY RANDOM() LIMIT ?`, FIRST_READS_PER_RUN);
  if (!unread.length) return 0;
  const vault = createVault(deps.config.tokenKey, deps.random);
  let read = 0;
  for (const row of unread) {
    try {
      const r = await syncCalendar(deps, vault, row, row.calendar_id);
      if (!r.skipped) read++;
    } catch (error) { console.log(`alerts: first read failed (${error.name} ${error.status ?? ""})`); }
  }
  return read;
}
