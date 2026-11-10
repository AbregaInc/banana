// Where the owner will be (docs/design/BOOKING.md §13 "Hours follow where the owner is"): the
// `plan.whereabouts` record the phone publishes, one per space, and the zone it puts each instant
// in. Times and IANA zones only: no airports, cities, titles or places. Merged whole: the record's
// one field `v` holds
//
//   current    the zone the phone is in now
//   home       the zone of home (the phone's trip home, else current)
//   stays      [{from, to, zone}]: time spent where the clock differs from home, landing to next departure
//   flights    [{departs, arrives}]: time in the air (no slots)
//   updatedAt  when the phone worked it out (ms)
//
// A type that follows travel reads its weekly hours, on each day, in the zone the owner is in; the
// type's own zone is the backup whenever there is no record, or only one older than STALE.

import { canonicalZone } from "./slots.js";

export const WHEREABOUTS = "plan.whereabouts";
export const WHEREABOUTS_ID = "whereabouts";
const DAY = 24 * 60 * 60_000;
export const STALE = 14 * DAY;
const LONGEST_FLIGHT = 36 * 60 * 60_000;
const MOST = 400;

const ms = (v) => (typeof v === "number" && Number.isFinite(v) ? v : typeof v === "string" && v ? Date.parse(v) : NaN);

/**
 * The record's fields ({v}), checked, as a timeline the engine reads; null when there is no record, it is
 * older than STALE or has no zone for now (the type's own zone then applies).
 * @returns {{current: string, home: string, flights: number[][], segments: {from: number, to: number, zone: string}[],
 *            zones: string[], updatedAt: number} | null}
 */
export function whereaboutsFrom(record, now) {
  const fields = record?.v;
  if (!fields || typeof fields !== "object") return null;
  const updatedAt = ms(fields.updatedAt);
  if (!Number.isFinite(updatedAt) || now - updatedAt > STALE) return null;
  const current = canonicalZone(fields.current);
  if (!current) return null;
  const home = canonicalZone(fields.home) ?? current;
  const stays = (Array.isArray(fields.stays) ? fields.stays : []).slice(0, MOST)
    .map((s) => ({ from: ms(s?.from), to: ms(s?.to), zone: canonicalZone(s?.zone) }))
    .filter((s) => s.zone && Number.isFinite(s.from) && Number.isFinite(s.to) && s.to > s.from)
    .sort((a, b) => a.from - b.from);
  const flights = (Array.isArray(fields.flights) ? fields.flights : []).slice(0, MOST)
    .map((f) => [ms(f?.departs), ms(f?.arrives)])
    .filter(([d, a]) => Number.isFinite(d) && Number.isFinite(a) && a > d && a - d <= LONGEST_FLIGHT)
    .sort((a, b) => a[0] - b[0]);
  const firstFlight = flights.length ? flights[0][0] : Infinity;
  // Before the first known flight: where the phone is now. After it, outside any stay: home. A stay
  // covering the instant wins (the first one, should two overlap).
  const raw = (t) => stays.find((s) => t >= s.from && t < s.to)?.zone ?? (t < firstFlight ? current : home);
  const points = [...new Set([firstFlight, ...stays.flatMap((s) => [s.from, s.to])].filter(Number.isFinite))].sort((a, b) => a - b);
  const segments = [];
  let from = -Infinity;
  for (const p of [...points, Infinity]) {
    const zone = raw(from !== -Infinity ? from : Number.isFinite(p) ? p - 1 : -8.64e15);
    const last = segments[segments.length - 1];
    if (last && last.zone === zone) last.to = p;
    else segments.push({ from, to: p, zone });
    from = p;
  }
  return { current, home, flights, segments, zones: [...new Set(segments.map((s) => s.zone))], updatedAt };
}

/** The zone the owner is in at an instant (binary search over the timeline). */
export function zoneAt(where, t) {
  const s = where.segments;
  let lo = 0, hi = s.length - 1;
  while (lo < hi) { const mid = (lo + hi + 1) >> 1; if (s[mid].from <= t) lo = mid; else hi = mid - 1; }
  return s[lo].zone;
}

/** Whether the owner is in `zone` at some instant of [from, to). */
export function inZoneDuring(where, zone, from, to) {
  return where.segments.some((s) => s.zone === zone && s.from < to && s.to > from);
}

/** The zone a type's hours are read in at an instant: where the owner is, or the type's own. */
export const zoneOf = (type, t) => (type?.where ? zoneAt(type.where, t) : type?.timeZone ?? "UTC");
