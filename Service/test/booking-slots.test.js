// The slot engine (src/booking/slots.js), BOOKING.md §3 and §12. `npm test` runs every file twice,
// under TZ=UTC and TZ=America/New_York: the server's own zone must never matter.
import { test } from "node:test";
import assert from "node:assert/strict";
import { TZDate } from "@date-fns/tz";
import {
  busyFromEvents, canonicalZone, dateIn, dayAround, defaultStep, generateSlots, instantAt, nearest, wallString, whenLine, shortWhen,
} from "../src/booking/slots.js";

const H = 60 * 60 * 1000, M = 60 * 1000;
const iso = (t) => new Date(t).toISOString();
/** Weekly hours: the same spans on the given weekdays (0 = Sunday). */
const hours = (days, spans) => Array.from({ length: 7 }, (_, w) => (days.includes(w) ? spans : []));
const type = (over) => ({ minutes: 30, hours: hours([0, 1, 2, 3, 4, 5, 6], [[540, 1020]]), timeZone: "UTC", notice: 0, horizonDays: 3, ...over });
const starts = (slots) => slots.map((s) => s.start);
const walls = (slots, zone) => slots.map((s) => wallString(Date.parse(s.start), zone));

test("the server's zone is one of the two this suite runs under", { skip: process.env.TZ ? false : "TZ unset: npm test runs this file under TZ=UTC and TZ=America/New_York" }, () => {
  assert.ok(["UTC", "America/New_York"].includes(process.env.TZ), `npm test runs under TZ=UTC and TZ=America/New_York, not ${process.env.TZ}`);
});

test("probe rows (Fable, 20 Oct): TZDate moves a missing time, Intl catches it, the engine drops it", () => {
  const rows = [
    ["America/New_York", "2026-03-08T02:30", "gap", null],
    ["America/New_York", "2026-11-01T01:30", "overlap", "2026-11-01T05:30:00.000Z"],
    ["Australia/Lord_Howe", "2026-10-04T02:15", "gap half-hour", null],
    ["Pacific/Chatham", "2026-09-27T02:45", "gap +12:45", null],
    ["Asia/Kathmandu", "2026-06-01T09:00", "plain +05:45", "2026-06-01T03:15:00.000Z"],
  ];
  for (const [zone, wall, label, expected] of rows) {
    const [y, m, d, h, mi] = wall.split(/[-T:]/).map(Number);
    const moved = new TZDate(y, m - 1, d, h, mi, 0, 0, zone).getTime();
    assert.equal(wallString(moved, zone) === wall, expected !== null, `${label}: TZDate round-trips only when the time exists`);
    const t = instantAt({ y, m, d }, h * 60 + mi, zone);
    assert.equal(t === null ? null : iso(t), expected, label);
  }
});

test("a time that happens twice is its first occurrence, whatever TZDate picks on this server", () => {
  assert.equal(iso(instantAt({ y: 2026, m: 10, d: 25 }, 90, "Europe/London")), "2026-10-25T00:30:00.000Z");   // BST, not GMT
  assert.equal(iso(instantAt({ y: 2026, m: 11, d: 1 }, 90, "America/New_York")), "2026-11-01T05:30:00.000Z");
  assert.equal(iso(instantAt({ y: 2026, m: 4, d: 5 }, 105, "Australia/Lord_Howe")), "2026-04-04T14:45:00.000Z"); // +11, not +10:30
  assert.equal(iso(instantAt({ y: 2026, m: 4, d: 5 }, 180, "Pacific/Chatham")), "2026-04-04T13:15:00.000Z");    // +13:45
});

test("New York spring forward: 02:00–02:59 don't exist and offer nothing; lengths are elapsed time", () => {
  const now = Date.UTC(2026, 2, 7, 12);
  const slots = generateSlots({ type: type({ timeZone: "America/New_York", hours: hours([0], [[60, 240]]) }), now });
  assert.deepEqual(walls(slots, "America/New_York"), ["2026-03-08T01:00", "2026-03-08T01:30", "2026-03-08T03:00", "2026-03-08T03:30"]);
  assert.deepEqual(slots[1], { start: "2026-03-08T06:30:00.000Z", end: "2026-03-08T07:00:00.000Z" }, "01:30 EST ends at 03:00 EDT, 30 minutes later");
  // Hours that start at 02:00 begin at 03:00 that day, never at 01:30 (Elevate's bug).
  const late = generateSlots({ type: type({ timeZone: "America/New_York", hours: hours([0], [[120, 240]]) }), now });
  assert.deepEqual(walls(late, "America/New_York"), ["2026-03-08T03:00", "2026-03-08T03:30"]);
});

test("New York fall back: 01:00–01:59 are offered once, the first time", () => {
  const now = Date.UTC(2026, 9, 31, 12);
  const hourly = generateSlots({ type: type({ timeZone: "America/New_York", minutes: 60, hours: hours([0], [[0, 180]]) }), now });
  assert.deepEqual(starts(hourly), ["2026-11-01T04:00:00.000Z", "2026-11-01T05:00:00.000Z", "2026-11-01T07:00:00.000Z"]);
  assert.equal(hourly[1].end, "2026-11-01T06:00:00.000Z", "an hour from 01:00 EDT ends at 01:00 EST");
  const half = generateSlots({ type: type({ timeZone: "America/New_York", hours: hours([0], [[0, 180]]) }), now });
  assert.equal(half.length, 6);
  assert.equal(new Set(walls(half, "America/New_York")).size, 6, "no wall time twice");
  // A meeting across the change is measured in elapsed time: 01:30 EDT + 90 min = 02:00 EST.
  const long = generateSlots({ type: type({ timeZone: "America/New_York", minutes: 90, step: 30, hours: hours([0], [[60, 180]]) }), now });
  assert.deepEqual(long.map((s) => [wallString(Date.parse(s.start), "America/New_York"), (Date.parse(s.end) - Date.parse(s.start)) / M]),
    [["2026-11-01T01:00", 90], ["2026-11-01T01:30", 90]]);
});

test("Europe/London both changes", () => {
  const spring = generateSlots({ type: type({ timeZone: "Europe/London", hours: hours([0], [[0, 180]]) }), now: Date.UTC(2026, 2, 28, 12) });
  assert.deepEqual(walls(spring, "Europe/London"), ["2026-03-29T00:00", "2026-03-29T00:30", "2026-03-29T02:00", "2026-03-29T02:30"]);
  assert.deepEqual(starts(spring).slice(2), ["2026-03-29T01:00:00.000Z", "2026-03-29T01:30:00.000Z"]);
  const fall = generateSlots({ type: type({ timeZone: "Europe/London", minutes: 60, hours: hours([0], [[60, 180]]) }), now: Date.UTC(2026, 9, 24, 12) });
  assert.deepEqual(starts(fall), ["2026-10-25T00:00:00.000Z", "2026-10-25T02:00:00.000Z"]);
});

test("Australia/Lord_Howe: the half-hour change", () => {
  const slots = generateSlots({ type: type({ timeZone: "Australia/Lord_Howe", minutes: 15, hours: hours([0], [[90, 210]]) }), now: Date.UTC(2026, 9, 2) });
  assert.deepEqual(walls(slots, "Australia/Lord_Howe"),
    ["2026-10-04T01:30", "2026-10-04T01:45", "2026-10-04T02:30", "2026-10-04T02:45", "2026-10-04T03:00", "2026-10-04T03:15"]);
  assert.equal(slots[1].end, slots[2].start, "01:45 + 15 min is 02:30, the next slot");
});

test("Asia/Kolkata (+05:30) and Asia/Kathmandu (+05:45): the grid is on the host's wall clock", () => {
  const now = Date.UTC(2026, 5, 1);
  const kolkata = generateSlots({ type: type({ timeZone: "Asia/Kolkata", hours: hours([1], [[540, 600]]) }), now });
  assert.deepEqual(starts(kolkata), ["2026-06-01T03:30:00.000Z", "2026-06-01T04:00:00.000Z"]);
  const kathmandu = generateSlots({ type: type({ timeZone: "Asia/Kathmandu", minutes: 15, hours: hours([1], [[540, 600]]) }), now });
  assert.deepEqual(walls(kathmandu, "Asia/Kathmandu"), ["2026-06-01T09:00", "2026-06-01T09:15", "2026-06-01T09:30", "2026-06-01T09:45"]);
  assert.equal(kathmandu[0].start, "2026-06-01T03:15:00.000Z");
});

test("Pacific/Chatham: +12:45, its day before UTC's, and its spring gap", () => {
  const plain = generateSlots({ type: type({ timeZone: "Pacific/Chatham", hours: hours([1], [[540, 570]]) }), now: Date.UTC(2026, 4, 30) });
  assert.deepEqual(starts(plain), ["2026-05-31T20:15:00.000Z"], "Monday 1 June 09:00 there is Sunday evening in UTC");
  const gap = generateSlots({ type: type({ timeZone: "Pacific/Chatham", minutes: 15, hours: hours([0], [[150, 240]]) }), now: Date.UTC(2026, 8, 25) });
  assert.deepEqual(walls(gap, "Pacific/Chatham"), ["2026-09-27T02:30", "2026-09-27T03:45"]);
});

test("southern hemisphere: Sydney springs forward in October; Santiago's midnight doesn't exist", () => {
  const sydney = generateSlots({ type: type({ timeZone: "Australia/Sydney", hours: hours([0], [[60, 240]]) }), now: Date.UTC(2026, 9, 2) });
  assert.deepEqual(walls(sydney, "Australia/Sydney"), ["2026-10-04T01:00", "2026-10-04T01:30", "2026-10-04T03:00", "2026-10-04T03:30"]);
  // Chile moves 00:00 → 01:00 on 6 Sep 2026: Saturday's hours to 24:00 end at that moment.
  const santiago = generateSlots({ type: type({ timeZone: "America/Santiago", minutes: 60, hours: hours([6], [[1320, 1440]]).map((d, w) => (w === 0 ? [[0, 120]] : d)), horizonDays: 4 }), now: Date.UTC(2026, 8, 4) });
  assert.deepEqual(walls(santiago, "America/Santiago"), ["2026-09-05T22:00", "2026-09-05T23:00", "2026-09-06T01:00"]);
  assert.equal(santiago[1].end, santiago[2].start, "23:00 -04 plus an hour is 01:00 -03");
});

test("endMinutes = 1440 is 00:00 of the next day", () => {
  const slots = generateSlots({ type: type({ timeZone: "Europe/Berlin", minutes: 60, hours: hours([2], [[1320, 1440]]) }), now: Date.UTC(2026, 9, 19) });
  assert.deepEqual(walls(slots, "Europe/Berlin"), ["2026-10-20T22:00", "2026-10-20T23:00"]);
  assert.equal(wallString(Date.parse(slots[1].end), "Europe/Berlin"), "2026-10-21T00:00");
  // A span can't cross midnight: one past 1440 is ignored.
  assert.deepEqual(generateSlots({ type: type({ hours: hours([2], [[1320, 1500]]) }), now: Date.UTC(2026, 9, 19) }), []);
});

test("a horizon across a DST change keeps 09:00 on the host's clock", () => {
  const slots = generateSlots({ type: type({ timeZone: "America/New_York", minutes: 60, hours: hours([1, 2, 3, 4, 5], [[540, 600]]), horizonDays: 10 }),
    now: Date.UTC(2026, 9, 28, 12) });
  assert.deepEqual(starts(slots), ["2026-10-28T13:00:00.000Z", "2026-10-29T13:00:00.000Z", "2026-10-30T13:00:00.000Z", "2026-11-02T14:00:00.000Z",
    "2026-11-03T14:00:00.000Z", "2026-11-04T14:00:00.000Z", "2026-11-05T14:00:00.000Z", "2026-11-06T14:00:00.000Z"]);
  assert.ok(walls(slots, "America/New_York").every((w) => w.endsWith("T09:00")));
});

test("a guest 13 hours away whose today is the host's tomorrow: days come from the host's zone, grouping is the guest's", () => {
  const now = Date.UTC(2026, 9, 20, 23);   // Tue 19:00 in New York, Wed 08:00 in Tokyo
  const slots = generateSlots({ type: type({ timeZone: "America/New_York", hours: hours([1, 2, 3, 4, 5], [[540, 1020]]), horizonDays: 2 }), now });
  assert.equal(slots.length, 16, "only Wednesday: the host's Tuesday is over, and the horizon's last day is today + 1");
  assert.equal(slots[0].start, "2026-10-21T13:00:00.000Z");
  assert.deepEqual([...new Set(slots.map((s) => dateIn(Date.parse(s.start), "Asia/Tokyo")))], ["2026-10-21", "2026-10-22"],
    "in Tokyo the host's Wednesday runs from Wednesday 22:00 into Thursday");
});

test("notice is elapsed time from now; the horizon's last day is today + horizonDays − 1", () => {
  const now = Date.UTC(2026, 9, 20, 10, 7);
  const slots = generateSlots({ type: type({ notice: 4 * 60, horizonDays: 2 }), now });
  assert.equal(slots[0].start, "2026-10-20T14:30:00.000Z", "10:07 + 4 h = 14:07, so 14:30 is the first");
  assert.equal(slots.at(-1).start, "2026-10-21T16:30:00.000Z");
  assert.deepEqual(generateSlots({ type: type({ horizonDays: 1 }), now: Date.UTC(2026, 9, 20, 18) }), []);
});

test("busy time, padded by the type's buffers", () => {
  const now = Date.UTC(2026, 9, 19);
  const t = type({ hours: hours([2], [[540, 720]]) });
  const busy = [[Date.UTC(2026, 9, 20, 10), Date.UTC(2026, 9, 20, 10, 30)]];
  assert.deepEqual(walls(generateSlots({ type: t, now, busy }), "UTC").map((w) => w.slice(11)), ["09:00", "09:30", "10:30", "11:00", "11:30"]);
  const padded = generateSlots({ type: { ...t, bufferBefore: 15, bufferAfter: 15 }, now, busy });
  assert.deepEqual(walls(padded, "UTC").map((w) => w.slice(11)), ["09:00", "11:00", "11:30"]);
  // Overlapping and touching busy intervals merge.
  const many = generateSlots({ type: t, now, busy: [[Date.UTC(2026, 9, 20, 9), Date.UTC(2026, 9, 20, 10)], [Date.UTC(2026, 9, 20, 9, 30), Date.UTC(2026, 9, 20, 11)]] });
  assert.deepEqual(walls(many, "UTC").map((w) => w.slice(11)), ["11:00", "11:30"]);
});

test("perDay counts in the host's zone", () => {
  const now = Date.UTC(2026, 9, 19);
  const t = type({ timeZone: "Asia/Tokyo", hours: hours([2, 3], [[540, 600]]), perDay: 1 });
  // 00:30 UTC on 20 Oct is 09:30 on Tuesday in Tokyo: Tuesday is full; Wednesday isn't.
  const slots = generateSlots({ type: t, now, booked: [Date.UTC(2026, 9, 20, 0, 30)] });
  assert.deepEqual([...new Set(slots.map((s) => dateIn(Date.parse(s.start), "Asia/Tokyo")))], ["2026-10-21"]);
});

test("step: the length when it divides an hour, else 15; several spans a day", () => {
  assert.equal(defaultStep(30), 30);
  assert.equal(defaultStep(20), 20);
  assert.equal(defaultStep(45), 15);
  assert.equal(defaultStep(90), 15);
  const slots = generateSlots({ type: type({ minutes: 45, hours: hours([2], [[540, 600], [780, 840]]) }), now: Date.UTC(2026, 9, 19) });
  assert.deepEqual(walls(slots, "UTC").map((w) => w.slice(11)), ["09:00", "09:15", "13:00", "13:15"]);
});

test("nearest three, in time order", () => {
  const slots = generateSlots({ type: type({ hours: hours([2], [[540, 720]]) }), now: Date.UTC(2026, 9, 19) });
  assert.deepEqual(starts(nearest(slots, "2026-10-20T10:10:00.000Z")), ["2026-10-20T09:30:00.000Z", "2026-10-20T10:00:00.000Z", "2026-10-20T10:30:00.000Z"]);
});

test("zone names: checked, canonical, no abbreviations", () => {
  assert.equal(canonicalZone("America/New_York"), "America/New_York");
  assert.equal(canonicalZone("US/Eastern"), "America/New_York");
  assert.equal(canonicalZone("Asia/Calcutta"), "Asia/Kolkata");
  assert.equal(canonicalZone("Asia/Kolkata"), "Asia/Kolkata");
  assert.equal(canonicalZone("Europe/Kiev"), "Europe/Kyiv");
  assert.equal(canonicalZone("utc"), "UTC");
  assert.equal(canonicalZone("Etc/UTC"), "UTC");
  for (const bad of ["EST", "PST", "GMT", "Mars/Olympus", "", null, 5, "x".repeat(80)]) assert.equal(canonicalZone(bad), null, String(bad));
});

test("busy from Google events: what counts", () => {
  const ev = (over) => ({ id: "e", status: "confirmed", start: { dateTime: "2026-10-20T10:00:00Z" }, end: { dateTime: "2026-10-20T11:00:00Z" }, ...over });
  const busy = busyFromEvents([
    ev({}),
    ev({ status: "cancelled" }),
    ev({ transparency: "transparent" }),
    ev({ eventType: "workingLocation" }),
    ev({ attendees: [{ self: true, responseStatus: "declined" }] }),
    ev({ attendees: [{ self: true, responseStatus: "tentative" }], extendedProperties: { private: { bananaBooking: "b1" } } }),
    ev({ start: { date: "2026-10-22" }, end: { date: "2026-10-23" } }),                          // all-day, Busy
    ev({ start: { date: "2026-10-24" }, end: { date: "2026-10-25" }, transparency: "transparent" }), // all-day, Free
    ev({ transparency: "transparent", extendedProperties: { private: { bananaBooking: "b2" } } }),   // a booking's, marked Free
  ], "America/New_York");
  assert.deepEqual(busy, [
    [Date.UTC(2026, 9, 20, 10), Date.UTC(2026, 9, 20, 11)],
    [Date.UTC(2026, 9, 20, 10), Date.UTC(2026, 9, 20, 11), "b1"],
    [Date.UTC(2026, 9, 22, 4), Date.UTC(2026, 9, 23, 4)],       // midnight to midnight in the calendar's zone
    [Date.UTC(2026, 9, 20, 10), Date.UTC(2026, 9, 20, 11), "b2", 0],
  ]);
});

test("a day around an instant, in the host's zone", () => {
  const d = dayAround(Date.UTC(2026, 10, 1, 12), "America/New_York");
  assert.deepEqual([iso(d.from), iso(d.to)], ["2026-11-01T04:00:00.000Z", "2026-11-02T05:00:00.000Z"], "the fall-back day is 25 hours");
  const only = generateSlots({ type: type({ hours: hours([0, 1, 2, 3, 4, 5, 6], [[540, 600]]), horizonDays: 5 }), now: Date.UTC(2026, 9, 19), days: dayAround(Date.UTC(2026, 9, 21, 12), "UTC") });
  assert.deepEqual(starts(only), ["2026-10-21T09:00:00.000Z", "2026-10-21T09:30:00.000Z"]);
});

test("words: times at the meeting's instant, the city's name for the zone", () => {
  const s = Date.UTC(2026, 9, 21, 19), e = s + 30 * M;
  assert.equal(whenLine(s, e, "America/New_York"), "Wed 21 Oct, 3:00–3:30 pm, New York time");
  assert.equal(whenLine(Date.UTC(2026, 9, 21, 15, 30), Date.UTC(2026, 9, 21, 16, 30), "America/New_York"), "Wed 21 Oct, 11:30 am–12:30 pm, New York time");
  assert.equal(whenLine(s, e, "Asia/Kolkata"), "Thu 22 Oct, 12:30–1:00 am, Kolkata time");
  assert.equal(shortWhen(s, "Europe/London"), "Wed 8:00 pm");
  // Across the fall back, each end says which clock it is on.
  assert.equal(whenLine(Date.UTC(2026, 10, 1, 5, 30), Date.UTC(2026, 10, 1, 6, 30), "America/New_York"), "Sun 1 Nov, 1:30 am EDT–1:30 am EST, New York time");
  assert.equal(whenLine(Date.UTC(2026, 9, 25, 0, 30), Date.UTC(2026, 9, 25, 1, 30), "Europe/Berlin"), "Sun 25 Oct, 2:30 am GMT+2–2:30 am GMT+1, Berlin time");
});

test("the whole default horizon is fast enough to render in the request", () => {
  const t0 = performance.now();
  const slots = generateSlots({ type: type({ timeZone: "America/New_York", minutes: 15, hours: hours([1, 2, 3, 4, 5], [[540, 1020]]), horizonDays: 30 }),
    now: Date.UTC(2026, 9, 20), busy: Array.from({ length: 200 }, (_, i) => [Date.UTC(2026, 9, 20) + i * 3 * H, Date.UTC(2026, 9, 20) + i * 3 * H + H]) });
  const ms = performance.now() - t0;
  assert.ok(slots.length > 300);
  assert.ok(ms < 50, `${ms.toFixed(1)} ms`);
});
