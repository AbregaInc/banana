// Hours that follow where the owner is (src/booking/whereabouts.js, BOOKING.md §13). Like the slot
// engine's own tests, `npm test` runs this under TZ=UTC and TZ=America/New_York.
import { test } from "node:test";
import assert from "node:assert/strict";
import { generateSlots, wallString } from "../src/booking/slots.js";
import { placed, normaliseType, typeView } from "../src/booking/types.js";
import { STALE, whereaboutsFrom, zoneAt, zoneOf } from "../src/booking/whereabouts.js";

const H = 60 * 60 * 1000, M = 60 * 1000, DAY = 24 * H;
const at = (s) => Date.parse(s);
const hours = (days, spans) => Array.from({ length: 7 }, (_, w) => (days.includes(w) ? spans : []));
const WEEKDAYS = hours([1, 2, 3, 4, 5], [[540, 1020]]);
const starts = (slots) => slots.map((s) => s.start);
const onDay = (slots, day) => slots.filter((s) => s.start.startsWith(day));

// Thursday 15 Oct 2026, 08:00 in New York. Home is New York. A week in London: out Saturday night,
// back Wednesday 28th (London's clocks go back on Sunday 25th, New York's not until 1 Nov).
const NOW = at("2026-10-15T12:00:00Z");
const OUT = { departs: at("2026-10-17T22:00:00Z"), arrives: at("2026-10-18T07:00:00Z") };
const BACK = { departs: at("2026-10-28T11:00:00Z"), arrives: at("2026-10-28T19:00:00Z") };
const TRIP = {
  current: "America/New_York", home: "America/New_York",
  stays: [{ from: OUT.arrives, to: BACK.departs, zone: "Europe/London" }],
  flights: [OUT, BACK],
  updatedAt: NOW - H,
};
const fixed = (over = {}) => ({ minutes: 30, hours: WEEKDAYS, timeZone: "America/New_York", notice: 0, horizonDays: 14, ...over });
const travelling = (over = {}, record = TRIP, now = NOW) => ({ ...fixed(over), where: whereaboutsFrom({ v: record }, now) });

test("no record: the type's own zone, exactly as before", () => {
  assert.equal(whereaboutsFrom(null, NOW), null);
  assert.equal(whereaboutsFrom({ current: "Europe/London", updatedAt: NOW }, NOW), null, "the fields live in v");
  const [type] = placed([fixed()], null);
  assert.equal(type.where, null);
  assert.deepEqual(generateSlots({ type, now: NOW }), generateSlots({ type: fixed(), now: NOW }));
  assert.equal(zoneOf(type, NOW), "America/New_York");
});

test("a record older than 14 days is not trusted: the type's zone again", () => {
  assert.ok(whereaboutsFrom({ v: { ...TRIP, updatedAt: NOW - STALE + M } }, NOW));
  assert.equal(whereaboutsFrom({ v: { ...TRIP, updatedAt: NOW - STALE - M } }, NOW), null);
  assert.equal(whereaboutsFrom({ v: { ...TRIP, current: "EST" } }, NOW), null, "no zone for now: nothing known");
});

test("a trip abroad: the same wall hours, in London while there, New York before and after", () => {
  const slots = generateSlots({ type: travelling(), now: NOW });
  // Friday 16th at home: 09:00 New York.
  assert.equal(onDay(slots, "2026-10-16")[0].start, "2026-10-16T13:00:00.000Z");
  // Monday 19th in London: 09:00–17:00 BST.
  const monday = onDay(slots, "2026-10-19");
  assert.equal(monday[0].start, "2026-10-19T08:00:00.000Z");
  assert.equal(monday.at(-1).start, "2026-10-19T15:30:00.000Z");
  assert.equal(monday.length, 16);
  assert.ok(monday.every((s) => wallString(Date.parse(s.start), "Europe/London") >= "2026-10-19T09:00"));
  assert.equal(zoneAt(travelling().where, at("2026-10-20T12:00:00Z")), "Europe/London");
});

test("DST inside a stay: London's clocks go back on the 25th and the hours stay 09:00 there", () => {
  const slots = generateSlots({ type: travelling(), now: NOW });
  assert.equal(onDay(slots, "2026-10-23")[0].start, "2026-10-23T08:00:00.000Z", "Friday: 09:00 BST");
  assert.equal(onDay(slots, "2026-10-26")[0].start, "2026-10-26T09:00:00.000Z", "Monday: 09:00 GMT");
  // Sunday 01:00–03:00 London: 01:00 and 01:30 happen twice, offered once (the first).
  const night = generateSlots({ type: travelling({ hours: hours([0], [[60, 180]]) }), now: NOW });
  assert.deepEqual(starts(onDay(night, "2026-10-25")), ["2026-10-25T00:00:00.000Z", "2026-10-25T00:30:00.000Z", "2026-10-25T02:00:00.000Z", "2026-10-25T02:30:00.000Z"]);
  assert.deepEqual(onDay(night, "2026-10-18"), [], "the 18th's night is spent in the air");
});

test("spring forward inside a stay: a wall time that doesn't exist there is no slot", () => {
  const now = at("2026-09-30T00:00:00Z");
  const record = { current: "America/New_York", home: "America/New_York", updatedAt: now,
    stays: [{ from: at("2026-10-01T00:00:00Z"), to: at("2026-10-10T00:00:00Z"), zone: "Australia/Sydney" }],
    flights: [{ departs: at("2026-09-30T08:00:00Z"), arrives: at("2026-10-01T00:00:00Z") }] };
  const type = { ...fixed({ hours: hours([0], [[120, 240]]) }), where: whereaboutsFrom({ v: record }, now) };
  const sydney = generateSlots({ type, now }).filter((s) => Date.parse(s.start) < record.stays[0].to)
    .map((s) => wallString(Date.parse(s.start), "Australia/Sydney"));
  assert.deepEqual(sydney, ["2026-10-04T03:00", "2026-10-04T03:30"], "02:00–03:00 doesn't exist on 4 Oct in Sydney");
});

test("a flight day: the morning's hours in London, the afternoon's in New York, nothing in the air", () => {
  const day = onDay(generateSlots({ type: travelling(), now: NOW }), "2026-10-28");
  assert.deepEqual(day.map((s) => s.start), [
    // 09:00–11:00 in London (GMT): the flight leaves at 11:00.
    "2026-10-28T09:00:00.000Z", "2026-10-28T09:30:00.000Z", "2026-10-28T10:00:00.000Z", "2026-10-28T10:30:00.000Z",
    // Landed at 15:00 New York (EDT): 15:00–17:00 there.
    "2026-10-28T19:00:00.000Z", "2026-10-28T19:30:00.000Z", "2026-10-28T20:00:00.000Z", "2026-10-28T20:30:00.000Z",
  ]);
  // The buffers pad the flight like any busy time.
  const padded = onDay(generateSlots({ type: travelling({ bufferBefore: 15, bufferAfter: 15 }), now: NOW }), "2026-10-28");
  assert.deepEqual(padded.map((s) => s.start), ["2026-10-28T09:00:00.000Z", "2026-10-28T09:30:00.000Z", "2026-10-28T10:00:00.000Z",
    "2026-10-28T19:30:00.000Z", "2026-10-28T20:00:00.000Z", "2026-10-28T20:30:00.000Z"]);
});

test("perDay on a day that changes zone: one date, counted where the owner is at each booking", () => {
  const type = travelling({ perDay: 1 });
  const all = onDay(generateSlots({ type, now: NOW }), "2026-10-28");
  assert.equal(all.length, 8);
  // A booking in London that morning fills the date, New York's afternoon too.
  assert.deepEqual(onDay(generateSlots({ type, now: NOW, booked: [at("2026-10-28T09:00:00Z")] }), "2026-10-28"), []);
  // And one in New York that afternoon fills the morning in London.
  assert.deepEqual(onDay(generateSlots({ type, now: NOW, booked: [at("2026-10-28T20:00:00Z")] }), "2026-10-28"), []);
  // 02:00Z on the 29th is the 28th in New York, where the owner is then: it counts for the 28th.
  assert.deepEqual(onDay(generateSlots({ type, now: NOW, booked: [at("2026-10-29T02:00:00Z")] }), "2026-10-28"), []);
});

test("a day re-read (days) regenerates exactly the slots of that day, on a travel day too", () => {
  const type = travelling();
  const all = generateSlots({ type, now: NOW });
  for (const slot of [onDay(all, "2026-10-28")[1], onDay(all, "2026-10-28")[5], onDay(all, "2026-10-19")[3]]) {
    const t = Date.parse(slot.start);
    const zone = zoneOf(type, t);
    const p = wallString(t, zone).slice(0, 10).split("-").map(Number);
    const from = Date.UTC(p[0], p[1] - 1, p[2]) - 14 * H, to = Date.UTC(p[0], p[1] - 1, p[2] + 1) + 14 * H;
    const again = generateSlots({ type, now: NOW, days: { from, to } });
    assert.ok(again.some((s) => s.start === slot.start), slot.start);
  }
});

test("abroad now with no flight known: where the phone is", () => {
  const record = { current: "Asia/Tokyo", home: "America/New_York", stays: [], flights: [], updatedAt: NOW };
  const slots = generateSlots({ type: travelling({ horizonDays: 3 }, record), now: NOW });
  assert.equal(slots[0].start, "2026-10-16T00:00:00.000Z", "Friday 09:00 in Tokyo");
  assert.equal(typeView({ ...normaliseType("t", { slug: "t" }, { zone: "America/New_York" }), where: whereaboutsFrom({ v: record }, NOW) }, null, NOW).hostZone, "Asia/Tokyo");
});

test("followsTravel off: the old fixed zone, whatever the record says", () => {
  const type = normaliseType("t", { slug: "t", followsTravel: false, timeZone: "America/New_York" }, { zone: null });
  assert.equal(type.followsTravel, false);
  assert.equal(normaliseType("t", { slug: "t" }, { zone: "UTC" }).followsTravel, true, "on when absent");
  const [off] = placed([type], whereaboutsFrom({ v: TRIP }, NOW));
  assert.equal(off.where, null);
  assert.equal(typeView(off, null, at("2026-10-20T12:00:00Z")).hostZone, "America/New_York");
});

test("the record is read defensively: bad stays and flights dropped, zones canonical, at most 400", () => {
  const where = whereaboutsFrom({ v: { current: "Asia/Calcutta", updatedAt: NOW,
    stays: [{ from: 5, to: 1, zone: "Europe/Paris" }, { from: NOW, to: NOW + DAY, zone: "PST" }, ...Array.from({ length: 500 }, () => null)],
    flights: [{ departs: NOW, arrives: NOW + 3 * DAY }, { departs: NOW, arrives: NOW - 1 }] } }, NOW);
  assert.equal(where.current, "Asia/Kolkata");
  assert.equal(where.home, "Asia/Kolkata", "home defaults to current");
  assert.deepEqual(where.flights, []);
  assert.deepEqual(where.zones, ["Asia/Kolkata"]);
});
