// The slot engine (docs/design/BOOKING.md §3, §12 "Engine corrections"). Pure: a booking type, the
// clock and the busy time in, the free slots out, as UTC instants. Nothing here reads the server's
// own time zone: days step on the host zone's date parts, a wall time becomes an instant with
// @date-fns/tz's TZDate, and Intl (hourCycle h23) turns it back. A wall time that doesn't come back
// the same (spring forward) is no slot; one that happens twice (fall back) is offered once, at its
// first occurrence (instantAt), and every length is elapsed time.

import { TZDate } from "@date-fns/tz";

export const MINUTE = 60_000;
const DAY_MINUTES = 1440;
const DAY_MS = 24 * 60 * MINUTE;

// ICU still names a few zones by their old spellings; the page and the emails want today's.
const PREFERRED = {
  "Asia/Calcutta": "Asia/Kolkata", "Asia/Katmandu": "Asia/Kathmandu", "Europe/Kiev": "Europe/Kyiv",
  "Asia/Saigon": "Asia/Ho_Chi_Minh", "Asia/Rangoon": "Asia/Yangon", "Asia/Dacca": "Asia/Dhaka",
  "Asia/Thimbu": "Asia/Thimphu", "Asia/Ulan_Bator": "Asia/Ulaanbaatar", "Atlantic/Faeroe": "Atlantic/Faroe",
  "America/Godthab": "America/Nuuk", "Pacific/Truk": "Pacific/Chuuk", "Pacific/Ponape": "Pacific/Pohnpei",
  "Pacific/Enderbury": "Pacific/Kanton", "America/Buenos_Aires": "America/Argentina/Buenos_Aires",
  "America/Catamarca": "America/Argentina/Catamarca", "America/Cordoba": "America/Argentina/Cordoba",
  "America/Jujuy": "America/Argentina/Jujuy", "America/Mendoza": "America/Argentina/Mendoza",
  "America/Indianapolis": "America/Indiana/Indianapolis", "America/Louisville": "America/Kentucky/Louisville",
  "Asia/Chongqing": "Asia/Shanghai", "Asia/Harbin": "Asia/Shanghai", "Etc/UTC": "UTC", "Etc/GMT": "UTC",
  "Europe/Uzhgorod": "Europe/Kyiv", "Europe/Zaporozhye": "Europe/Kyiv", "Asia/Choibalsan": "Asia/Ulaanbaatar",
};

/**
 * An IANA zone name, checked and in its canonical spelling, or null. Abbreviations (EST, PST…) are
 * refused, as they are ambiguous: a name must contain "/" or be UTC.
 */
export function canonicalZone(name) {
  if (typeof name !== "string") return null;
  const s = name.trim();
  if (!s || s.length > 64 || !(s.includes("/") || /^utc$/i.test(s))) return null;
  let resolved;
  try { resolved = new Intl.DateTimeFormat("en-US", { timeZone: s }).resolvedOptions().timeZone; } catch { return null; }
  if (resolved === "GMT") resolved = "UTC";
  return PREFERRED[resolved] ?? resolved;
}

const formatters = new Map();
function formatter(zone) {
  let f = formatters.get(zone);
  if (!f) {
    f = new Intl.DateTimeFormat("en-US", { timeZone: zone, year: "numeric", month: "2-digit", day: "2-digit",
      hour: "2-digit", minute: "2-digit", hourCycle: "h23", weekday: "short" });
    formatters.set(zone, f);
  }
  return f;
}
const WEEKDAYS = { Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 };

/** An instant's wall-clock parts in a zone: {y, m (1–12), d, h, mi, weekday (0 = Sunday)}. */
export function partsIn(ms, zone) {
  const p = {};
  for (const part of formatter(zone).formatToParts(new Date(ms))) p[part.type] = part.value;
  return { y: Number(p.year), m: Number(p.month), d: Number(p.day), h: Number(p.hour) % 24, mi: Number(p.minute), weekday: WEEKDAYS[p.weekday] };
}

const pad = (n, w = 2) => String(n).padStart(w, "0");
const wallText = (y, m, d, h, mi) => `${pad(y, 4)}-${pad(m)}-${pad(d)}T${pad(h)}:${pad(mi)}`;

/** "YYYY-MM-DDTHH:mm" of an instant in a zone. */
export function wallString(ms, zone) {
  const p = partsIn(ms, zone);
  return wallText(p.y, p.m, p.d, p.h, p.mi);
}

/** "YYYY-MM-DD" of an instant in a zone. */
export const dateIn = (ms, zone) => wallString(ms, zone).slice(0, 10);

/** A calendar date n days on from (y, m, d): plain date arithmetic, no zone involved. */
export function addDays({ y, m, d }, n) {
  const t = new Date(Date.UTC(y, m - 1, d + n));
  return { y: t.getUTCFullYear(), m: t.getUTCMonth() + 1, d: t.getUTCDate(), weekday: t.getUTCDay() };
}

/** The zone's offset from UTC at an instant, in ms (wall clock minus UTC). */
export function offsetAt(ms, zone) {
  const p = partsIn(ms, zone);
  return Date.UTC(p.y, p.m - 1, p.d, p.h, p.mi) - Math.floor(ms / MINUTE) * MINUTE;
}

const steadyCache = new Map();
/** The zone's offset over a whole local day when it doesn't change that day, else null. Read
 * from instants 14 hours outside the day (no zone is further from UTC), so the whole day lies
 * between them; no zone changes its offset twice within two days. */
function steadyOffset(y, m, d, zone) {
  const key = `${zone}|${y}-${m}-${d}`;
  let v = steadyCache.get(key);
  if (v === undefined) {
    const a = offsetAt(Date.UTC(y, m - 1, d) - 14 * 60 * MINUTE, zone);
    const b = offsetAt(Date.UTC(y, m - 1, d + 1) + 14 * 60 * MINUTE, zone);
    v = a === b ? a : null;
    if (steadyCache.size > 20_000) steadyCache.clear();
    steadyCache.set(key, v);
  }
  return v;
}

/**
 * The instant of a wall time (`minute` from 00:00, 0–1440) on a date in a zone. Strict (the
 * default): null when that wall time doesn't exist there (spring forward). Loose: moved forward by
 * the gap, for the ends of spans and days. 1440 is 00:00 of the next day.
 *
 * A wall time that happens twice (fall back) is its first occurrence. TZDate alone doesn't promise
 * that: measured 20 Oct 2026 (1.5.0), Europe/London's 01:30 on 25 Oct came out as the second
 * occurrence on a server in UTC and as the first on one in Europe/London or Asia/Tokyo. So its
 * answer is one candidate among the instants made with the offsets a day either side, every
 * candidate is checked with Intl, and the earliest that shows the wall time wins: the same answer
 * on any server.
 */
export function instantAt(date, minute, zone, { strict = true } = {}) {
  if (minute >= DAY_MINUTES) return instantAt(addDays(date, Math.floor(minute / DAY_MINUTES)), minute % DAY_MINUTES, zone, { strict });
  const { y, m, d } = addDays(date, 0);
  const h = Math.floor(minute / 60), mi = minute % 60;
  const guess = Date.UTC(y, m - 1, d, h, mi);
  // Most days have one offset from end to end: then the instant is plain arithmetic.
  const steady = steadyOffset(y, m, d, zone);
  if (steady !== null) return guess - steady;
  const wall = wallText(y, m, d, h, mi);
  const earlier = guess - offsetAt(guess - DAY_MS, zone);
  const candidates = [new TZDate(y, m - 1, d, h, mi, 0, 0, zone).getTime(), earlier, guess - offsetAt(guess + DAY_MS, zone)];
  let best = null;
  for (const t of candidates) if (Number.isFinite(t) && wallString(t, zone) === wall && (best === null || t < best)) best = t;
  if (best !== null || strict) return best;
  return earlier;   // in a gap: the offset from before it, which lands as far past the gap as the time was into it
}

/** The step between start times: the length when it divides an hour, else 15 minutes (Elevate). */
export const defaultStep = (minutes) => (60 % minutes === 0 ? minutes : 15);

/**
 * Busy intervals as disjoint, sorted [start, end] pairs.
 * @param {Array<[number, number]|{start: number, end: number}>} busy
 */
export function mergeIntervals(busy) {
  const list = busy.map((b) => (Array.isArray(b) ? [b[0], b[1]] : [b.start, b.end]))
    .filter(([s, e]) => Number.isFinite(s) && Number.isFinite(e) && e > s).sort((a, b) => a[0] - b[0]);
  const out = [];
  for (const [s, e] of list) {
    const last = out[out.length - 1];
    if (last && s <= last[1]) last[1] = Math.max(last[1], e);
    else out.push([s, e]);
  }
  return out;
}

/** Whether [s, e) meets any of the merged intervals (binary search). */
export function overlaps(merged, s, e) {
  let lo = 0, hi = merged.length;
  while (lo < hi) { const mid = (lo + hi) >> 1; if (merged[mid][1] <= s) lo = mid + 1; else hi = mid; }
  return lo < merged.length && merged[lo][0] < e;
}

/**
 * The free slots of a booking type, over its whole horizon.
 * @param {{
 *   type: {minutes: number, step?: number, hours: number[][][], timeZone: string, bufferBefore?: number,
 *          bufferAfter?: number, notice?: number, horizonDays?: number, perDay?: number|null},
 *   now: number,
 *   busy?: Array<[number, number]>,     // Google's busy and the bookings, unpadded instants
 *   booked?: number[],                   // starts of this type's bookings, for perDay
 *   days?: {from: number, to: number},   // only the days whose start lies in [from, to) (a day re-read)
 * }} input
 *   `hours[weekday]` (0 = Sunday) is a list of [startMinute, endMinute] spans on the host's wall
 *   clock; a span never crosses midnight (1440 is the most). Buffers and notice are minutes.
 * @returns {{start: string, end: string}[]} UTC ISO strings, in order.
 */
export function generateSlots({ type, now, busy = [], booked = [], days = null }) {
  const zone = type.timeZone;
  const minutes = type.minutes;
  const step = type.step || defaultStep(minutes);
  const length = minutes * MINUTE;
  const before = (type.bufferBefore ?? 0) * MINUTE, after = (type.bufferAfter ?? 0) * MINUTE;
  const earliest = now + (type.notice ?? 0) * MINUTE;
  const horizon = type.horizonDays ?? 30;
  const merged = mergeIntervals(busy);
  const perDay = type.perDay ?? null;
  const counts = new Map();
  if (perDay) for (const s of booked) { const k = dateIn(s, zone); counts.set(k, (counts.get(k) ?? 0) + 1); }

  const today = partsIn(now, zone);
  const out = [];
  const seen = new Set();
  for (let n = 0; n < horizon; n++) {
    const date = addDays(today, n);
    const key = `${pad(date.y, 4)}-${pad(date.m)}-${pad(date.d)}`;
    if (perDay && (counts.get(key) ?? 0) >= perDay) continue;
    if (days) {
      const dayStart = instantAt(date, 0, zone, { strict: false });
      if (dayStart >= days.to || instantAt(date, DAY_MINUTES, zone, { strict: false }) <= days.from) continue;
    }
    for (const span of type.hours[date.weekday] ?? []) {
      const [a, b] = span;
      if (!(Number.isInteger(a) && Number.isInteger(b) && a >= 0 && b <= DAY_MINUTES && a < b)) continue;
      const spanEnd = instantAt(date, b, zone, { strict: false });
      for (let minute = Math.ceil(a / step) * step; minute < b; minute += step) {
        const start = instantAt(date, minute, zone);
        if (start === null) continue;                    // a wall time that doesn't exist: no slot
        const end = start + length;
        if (end > spanEnd) break;
        if (start < earliest || start <= now) continue;
        if (overlaps(merged, start - before, end + after)) continue;
        if (seen.has(start)) continue;
        seen.add(start);
        out.push(start);
      }
    }
  }
  return out.sort((x, y) => x - y).map((s) => ({ start: new Date(s).toISOString(), end: new Date(s + length).toISOString() }));
}

/** The n slots nearest to a wanted start, in order of time (the "taken" answer). */
export function nearest(slots, wanted, n = 3) {
  const t = typeof wanted === "number" ? wanted : Date.parse(wanted);
  return [...slots].sort((a, b) => Math.abs(Date.parse(a.start) - t) - Math.abs(Date.parse(b.start) - t)
    || Date.parse(a.start) - Date.parse(b.start)).slice(0, n).sort((a, b) => Date.parse(a.start) - Date.parse(b.start));
}

/** A UTC ISO string with Z as a slot start is written on the wire (the exact form generateSlots makes). */
export const isSlotString = (s) => typeof s === "string" && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(s);

/**
 * The busy intervals of a calendar's events, as Google returns them (`singleEvents=true`).
 * Skipped: cancelled, transparent (Free), working-location, declined by the calendar's owner.
 * All-day events count when Busy, from start.date 00:00 to end.date 00:00 in the calendar's zone.
 * Each interval is [start, end], or [start, end, bookingId] for an event a booking made. A booking's
 * event is kept even when Free, as [start, end, bookingId, 0], so a snapshot shows where it is.
 */
export function busyFromEvents(events, calendarZone) {
  const zone = canonicalZone(calendarZone) ?? "UTC";
  const out = [];
  for (const e of events ?? []) {
    if (!e || e.status === "cancelled" || e.eventType === "workingLocation") continue;
    const booking = e.extendedProperties?.private?.bananaBooking;
    const tagged = typeof booking === "string";
    const self = Array.isArray(e.attendees) ? e.attendees.find((a) => a?.self === true) : null;
    const free = e.transparency === "transparent" || self?.responseStatus === "declined";
    if (free && !tagged) continue;
    let s, t;
    if (e.start?.dateTime && e.end?.dateTime) { s = Date.parse(e.start.dateTime); t = Date.parse(e.end.dateTime); }
    else if (e.start?.date && e.end?.date) { s = dayStart(e.start.date, zone); t = dayStart(e.end.date, zone); }
    if (!(Number.isFinite(s) && Number.isFinite(t) && t > s)) continue;
    out.push(tagged ? (free ? [s, t, booking, 0] : [s, t, booking]) : [s, t]);
  }
  return out;
}

/** 00:00 of a "YYYY-MM-DD" date in a zone (moved forward when midnight doesn't exist there). */
export function dayStart(text, zone) {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(text));
  if (!m) return NaN;
  return instantAt({ y: Number(m[1]), m: Number(m[2]), d: Number(m[3]) }, 0, zone, { strict: false });
}

/** The host-zone day [00:00, 24:00) holding an instant, as instants. */
export function dayAround(ms, zone) {
  const p = partsIn(ms, zone);
  return { from: instantAt(p, 0, zone, { strict: false }), to: instantAt(p, DAY_MINUTES, zone, { strict: false }) };
}

// ---- words for people: "Tue 21 Oct, 3:00–3:30 pm, New York time" ----

/** "New York time", from the IANA id's city. */
export function zoneLabel(zone) {
  if (!zone || zone === "UTC") return "UTC";
  const city = zone.split("/").pop().replace(/_/g, " ");
  return `${city} time`;
}

/** "3:00 pm" at the instant, in the zone. */
export function clockIn(ms, zone) {
  const p = partsIn(ms, zone);
  const h12 = p.h % 12 === 0 ? 12 : p.h % 12;
  return `${h12}:${pad(p.mi)} ${p.h < 12 ? "am" : "pm"}`;
}

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const DAY_NAMES = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

/** "Tue 21 Oct" at the instant, in the zone. */
export function dateLabel(ms, zone) {
  const p = partsIn(ms, zone);
  return `${DAY_NAMES[p.weekday]} ${p.d} ${MONTHS[p.m - 1]}`;
}

/** The zone's short name at the instant ("EDT"), or its offset ("GMT+1") where Intl has no name. */
export function zoneAbbreviation(ms, zone) {
  try {
    return new Intl.DateTimeFormat("en-US", { timeZone: zone, timeZoneName: "short" }).formatToParts(new Date(ms)).find((p) => p.type === "timeZoneName")?.value ?? "";
  } catch { return ""; }
}

/**
 * "Tue 21 Oct, 3:00–3:30 pm, New York time": every part worked out at the meeting's instants. When
 * the offset changes between the two ends (a meeting across a fall back), each end says which
 * clock it is on: "1:30 am EDT–1:30 am EST".
 */
export function whenLine(start, end, zone) {
  const a = clockIn(start, zone), b = clockIn(end, zone);
  let range;
  if (offsetAt(start, zone) !== offsetAt(end, zone)) {
    range = `${a} ${zoneAbbreviation(start, zone)}–${b} ${zoneAbbreviation(end, zone)}`;
  } else {
    const sameHalf = a.slice(-2) === b.slice(-2) && dateIn(start, zone) === dateIn(end, zone);
    range = sameHalf ? `${a.slice(0, -3)}–${b}` : `${a}–${b}`;
  }
  return `${dateLabel(start, zone)}, ${range}, ${zoneLabel(zone)}`;
}

/** "Tue 3:00 pm" (the push to the host). */
export const shortWhen = (ms, zone) => `${DAY_NAMES[partsIn(ms, zone).weekday]} ${clockIn(ms, zone)}`;
