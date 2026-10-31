// Where availability comes from (docs/design/BOOKING.md §2, §12 "How the speed is reached"): a busy
// snapshot per account, the next month of busy intervals (times only) from every included Google
// calendar, rebuilt after the response whenever a watch reports a change and by the 15-minute job.
// The slots read is that row plus the bookings in D1 and the engine; only booking re-reads Google,
// for the slot's day. A link the service can't read makes its calendars unknown, and unknown is
// never free: the page offers nothing until it reconnects.
//
// Never logged: calendar ids, emails, event contents.

import { calendarInfoID } from "../calendar-preferences.js";
import { accessToken } from "../calendar.js";
import { GoogleRefused } from "../google.js";
import { busyFromEvents, canonicalZone } from "./slots.js";
import { TYPE, typesFrom } from "./types.js";
import { personalSpace } from "../sync-routes.js";

const MINUTE = 60_000;
const DAY = 24 * 60 * MINUTE;
export const STALE = 10 * MINUTE;            // older than this: served, and rebuilt after the answer
const CLAIM = MINUTE;                       // a rebuild that hasn't finished by then is taken over
const FIELDS = "items(id,status,start,end,transparency,eventType,attendees(self,responseStatus),extendedProperties/private),nextPageToken";

/** Whether a link's grant lets the service read busy time: its events and its calendar list. */
export function canRead(scopes) {
  const s = new Set(String(scopes ?? "").split(/\s+/).map((x) => x.replace("https://www.googleapis.com/auth/", "")));
  if (s.has("calendar") || s.has("calendar.readonly")) return true;
  const events = s.has("calendar.events") || s.has("calendar.events.readonly");
  const list = s.has("calendar.calendarlist.readonly") || s.has("calendar.calendarlist");
  return events && list;
}
/** Whether it lets the service make events. */
export function canWrite(scopes) {
  const s = new Set(String(scopes ?? "").split(/\s+/).map((x) => x.replace("https://www.googleapis.com/auth/", "")));
  return s.has("calendar") || s.has("calendar.events");
}

/** The calendars the person leaves out of their busy time (core.smartSettings), by id and by name. */
function exclusions(settings) {
  const v = settings?.v ?? settings ?? {};
  const ids = new Set(Array.isArray(v.settings?.excludedCalendarIDs) ? v.settings.excludedCalendarIDs.filter((x) => typeof x === "string") : []);
  const named = new Set((v.calendarIDsAreGoogle === true ? [] : Array.isArray(v.excludedCalendars) ? v.excludedCalendars : [])
    .filter((c) => c && typeof c.calendarTitle === "string").map((c) => `${String(c.sourceTitle ?? "").toLowerCase()}\n${c.calendarTitle}`));
  return { ids, named };
}

/**
 * Reads the account's busy time from Google over [from, to): the included calendars of every link.
 * Returns {busy, calendars: [{sub, id, tz}], unknown, failed, write: {sub, email}|null, writers}: `unknown`
 * counts links the service can't read (refused, no token, too narrow a grant), `failed` the reads
 * that went wrong this time (worth keeping an older snapshot for).
 */
export async function readBusy(deps, vault, account, { from, to, settings = null, zone = null }) {
  const links = await deps.db.all(
    "SELECT sub, account_id, email, refresh_token, scopes, status FROM google_links WHERE account_id = ? AND status <> 'unlinked' ORDER BY created_at, sub", account);
  const { ids: excluded, named } = exclusions(settings);
  const out = { busy: [], calendars: [], unknown: 0, failed: 0, write: null };
  await Promise.all(links.map(async (link) => {
    if (link.status !== "ok" || !link.refresh_token || !canRead(link.scopes)) { out.unknown++; return; }
    let access;
    try { access = await accessToken(deps, vault, link); }
    catch (error) { if (error instanceof GoogleRefused) out.unknown++; else out.failed++; return; }
    let list;
    try { list = await deps.google.calendarList(access); }
    catch { out.failed++; return; }
    const calendars = list.filter((c) => c?.id && !c.hidden && !c.deleted && !excluded.has(c.id) && !excluded.has(calendarInfoID(c.id))
      && !named.has(`${link.email}\n${c.summary ?? ""}`));
    await Promise.all(calendars.map(async (c) => {
      const tz = canonicalZone(c.timeZone) ?? canonicalZone(zone) ?? "UTC";
      try {
        const page = await deps.google.listEvents(access, c.id, { timeMin: new Date(from).toISOString(), timeMax: new Date(to).toISOString(), fields: FIELDS });
        out.busy.push(...busyFromEvents(page.events, tz));
        out.calendars.push({ sub: link.sub, id: c.id, tz, ...(c.primary ? { primary: true } : {}) });
      } catch { out.failed++; }
    }));
  }));
  // Where events go by default: the primary calendar of the oldest link that may make them.
  const writers = links.filter((l) => l.status === "ok" && l.refresh_token && canWrite(l.scopes));
  out.write = writers[0] ? { sub: writers[0].sub, email: writers[0].email } : null;
  out.writers = writers.map((l) => ({ sub: l.sub, email: l.email }));
  out.calendars.sort((a, b) => (a.sub + a.id < b.sub + b.id ? -1 : 1));
  out.busy.sort((a, b) => a[0] - b[0] || a[1] - b[1]);
  return out;
}

/** The booking types and exclusions from the account's space. */
async function fromSpace(deps, account) {
  const space = deps.spaces.get(personalSpace(account));
  const [records, settings] = await Promise.all([space.list(TYPE), space.read("core.smartSettings", "smart-settings")]);
  return { records, settings };
}

/**
 * Rebuilds the account's snapshot. One at a time per account: a change reported while one runs
 * marks it dirty, and it runs again. A rebuild whose reads partly failed keeps the snapshot before
 * it (served stale) unless there was none. Returns the snapshot written, or null.
 * @param {{vault: any, force?: boolean}} options force: the page has no snapshot at all and waits
 */
export async function rebuildSnapshot(deps, account, { vault, force = false }) {
  const { db, now } = deps;
  await db.run("INSERT INTO busy_snapshot (account_id, horizon_json, computed_at) VALUES (?, '{}', 0) ON CONFLICT (account_id) DO NOTHING", account);
  for (let round = 0; round < 3; round++) {
    const t = now();
    const claimed = await db.run(
      "UPDATE busy_snapshot SET rebuilding_at = ?, dirty_at = NULL WHERE account_id = ? AND (rebuilding_at IS NULL OR rebuilding_at < ?)", t, account, t - CLAIM);
    if (!claimed.changes) {
      // One build at a time, forced or not. A reported change marks the row so the holder runs again;
      // a page with no snapshot yet changed nothing and waits for the build in flight instead
      // (readHost reads the row again after this) rather than running its own beside it.
      if (!force) await db.run("UPDATE busy_snapshot SET dirty_at = ? WHERE account_id = ?", t, account);
      else {
        for (let i = 0; i < 15; i++) {
          await new Promise((r) => setTimeout(r, 100));
          const row = await db.first("SELECT computed_at FROM busy_snapshot WHERE account_id = ?", account);
          if (Number(row?.computed_at) > 0) break;
        }
      }
      return null;
    }
    let written = null;
    try {
      const [{ records, settings }, zones] = await Promise.all([fromSpace(deps, account),
        db.first("SELECT h.time_zone AS handle_zone, a.time_zone FROM accounts a LEFT JOIN booking_handles h ON h.account_id = a.id WHERE a.id = ?", account)]);
      const zone = zones?.handle_zone ?? zones?.time_zone ?? null;
      const types = typesFrom(records, zone);
      const days = Math.min(91, Math.max(31, ...types.filter((x) => x.active).map((x) => x.horizonDays + 1)));
      const from = t, to = t + days * DAY;
      const read = await readBusy(deps, vault, account, { from, to, settings, zone });
      const previous = await db.first("SELECT computed_at FROM busy_snapshot WHERE account_id = ?", account);
      const horizon = { from, to, busy: read.busy, calendars: read.calendars, unknown: read.unknown, write: read.write, writers: read.writers };
      if (read.failed && Number(previous?.computed_at) > 0) {
        console.log(`booking: snapshot kept (${read.failed} read(s) failed)`);
        // The claim stays for CLAIM: a snapshot whose reads keep failing is tried once a minute (and
        // by the 15-minute job), however many anonymous page views find it stale.
        await db.run("UPDATE busy_snapshot SET types_json = ?, types_at = ? WHERE account_id = ?", JSON.stringify(records), t, account);
        return null;
      } else {
        if (read.failed) horizon.unknown += read.failed;
        await db.run("UPDATE busy_snapshot SET horizon_json = ?, types_json = ?, types_at = ?, computed_at = ?, rebuilding_at = NULL WHERE account_id = ?",
          JSON.stringify(horizon), JSON.stringify(records), t, t, account);
        written = { horizon, records, computedAt: t };
      }
    } catch (error) {
      await db.run("UPDATE busy_snapshot SET rebuilding_at = NULL WHERE account_id = ?", account);
      throw error;
    }
    const again = await db.first("SELECT dirty_at FROM busy_snapshot WHERE account_id = ?", account);
    if (!again?.dirty_at) return written;
    force = false;
  }
  return null;
}

/** After a type changed in the space: the snapshot's copy of the types, at once. */
export async function refreshTypes(deps, account) {
  const { records } = await fromSpace(deps, account);
  await deps.db.run("UPDATE busy_snapshot SET types_json = ?, types_at = ? WHERE account_id = ?", JSON.stringify(records), deps.now(), account);
}

/**
 * The busy time of one host day, read live from the snapshot's calendars (the booking's check).
 * Throws when a calendar can't be read: the booking is tried again.
 */
export async function readDay(deps, vault, account, calendars, { from, to }) {
  const links = new Map((await deps.db.all(
    "SELECT sub, account_id, email, refresh_token, scopes, status FROM google_links WHERE account_id = ?", account)).map((l) => [l.sub, l]));
  const bySub = new Map();
  for (const c of calendars) (bySub.get(c.sub) ?? bySub.set(c.sub, []).get(c.sub)).push(c);
  const busy = [];
  await Promise.all([...bySub].map(async ([sub, list]) => {
    const link = links.get(sub);
    if (!link) throw new GoogleRefused("link gone");
    const access = await accessToken(deps, vault, link);
    await Promise.all(list.map(async (c) => {
      const page = await deps.google.listEvents(access, c.id, { timeMin: new Date(from).toISOString(), timeMax: new Date(to).toISOString(), fields: FIELDS });
      busy.push(...busyFromEvents(page.events, c.tz));
    }));
  }));
  return busy;
}
