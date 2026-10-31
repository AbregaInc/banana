import { test } from "node:test";
import assert from "node:assert/strict";
import { alertId, alertPayload, collapseId, decide, leadBody, when } from "../src/alerts.js";

const NOW = Date.UTC(2026, 9, 19, 14, 0, 0);   // 10:00 New York
const MIN = 60 * 1000;
const iso = (ms) => new Date(ms).toISOString();
const timed = (id, start, overrides = {}) => ({
  id, summary: "Standup", status: "confirmed",
  start: { dateTime: iso(start), timeZone: "America/New_York" }, end: { dateTime: iso(start + 30 * MIN) },
  creator: { email: "noor@x.com", self: true }, organizer: { email: "noor@x.com", self: true },
  ...overrides,
});
const args = (event, extra = {}) => ({ event, calendarId: "noor@x.com", selfEmail: "noor@x.com", now: NOW, leads: [5, 0], timeZone: "America/New_York", ...extra });
const ids = (d) => d.alerts.map((a) => a.id.split("|")[2]).sort();

test("his own timed event ahead: a lead alert per lead, nothing immediate, and the words say the time", () => {
  const d = decide(args(timed("e1", NOW + 60 * MIN)));
  assert.deepEqual(ids(d), ["0", "5"]);
  const five = d.alerts.find((a) => a.id === alertId("noor@x.com", "e1", 5));
  assert.equal(five.dueAt, NOW + 55 * MIN);
  assert.equal(five.body, "Starts in 5 minutes, at 11:00 AM.");
  assert.equal(d.alerts.find((a) => a.id.endsWith("|0")).body, "Starting now.");
  assert.equal(d.state.status, "confirmed");
});

test("added inside the lead window: 'Starting now' at once, and only then", () => {
  const d = decide(args(timed("e2", NOW + 3 * MIN)));
  assert.deepEqual(ids(d), ["0", "now"]);        // the at-start one is still ahead; the 5-minute one is past
  assert.equal(d.alerts.find((a) => a.kind === "now").body, "Starts in 3 minutes, at 10:03 AM.");
  const onlyLate = decide(args(timed("e2", NOW + 3 * MIN), { leads: [5] }));
  assert.deepEqual(ids(onlyLate), ["now"]);
  // Known already and not moved: no second 'now'.
  const known = decide(args(timed("e2", NOW + 3 * MIN), { leads: [5], previous: { start_at: NOW + 3 * MIN, end_at: NOW + 33 * MIN, status: "confirmed", response: null, title_hash: "x" } }));
  assert.deepEqual(ids(known), []);
  // A first full read never rings for what is already there.
  assert.deepEqual(ids(decide(args(timed("e2", NOW + 3 * MIN), { leads: [5], baseline: true }))), []);
});

test("an invitation he hasn't answered: visible once, any date, no lead alerts until he accepts", () => {
  const invite = timed("e3", NOW + 3 * 24 * 60 * MIN, {
    creator: { email: "ann@y.com", displayName: "Ann" }, organizer: { email: "ann@y.com", displayName: "Ann" },
    attendees: [{ email: "ann@y.com", organizer: true, responseStatus: "accepted" }, { email: "noor@x.com", self: true, responseStatus: "needsAction" }],
  });
  const d = decide(args(invite));
  assert.deepEqual(ids(d), ["invite"]);
  assert.equal(d.alerts[0].body, "Invitation from Ann · Thu 22 Oct, 10:00 AM");
  assert.equal(alertPayload(d.alerts[0], { calendarId: "c", eventId: "e3", email: "noor@x.com" }).aps.category, "EVENT_INVITE");
  // Accepted: the lead alerts, and no 'changed' (his reply is his own change).
  const accepted = { ...invite, attendees: [invite.attendees[0], { email: "noor@x.com", self: true, responseStatus: "accepted" }] };
  const a = decide(args(accepted, { previous: { start_at: invite.start && Date.parse(invite.start.dateTime), end_at: Date.parse(invite.end.dateTime), status: "confirmed", response: "needsAction", title_hash: "x" } }));
  assert.deepEqual(ids(a), ["0", "5"]);
  // Declined: nothing, and pending ones go.
  const declined = { ...invite, attendees: [invite.attendees[0], { email: "noor@x.com", self: true, responseStatus: "declined" }] };
  assert.deepEqual(ids(decide(args(declined))), []);
  assert.ok(decide(args(declined)).dropPending);
});

test("someone else adds or moves an event: visible at once, any date; his own change is silent", () => {
  const byAnn = timed("e4", NOW + 5 * 24 * 60 * MIN, { creator: { email: "ann@y.com", displayName: "Ann" }, organizer: { email: "noor@x.com", self: true } });
  const added = decide(args(byAnn));
  assert.deepEqual(ids(added), ["0", "5", "changed"]);
  assert.equal(added.alerts.find((a) => a.kind === "changed").body, "Added by Ann · Sat 24 Oct, 10:00 AM");
  const prev = { start_at: NOW + 5 * 24 * 60 * MIN, end_at: NOW + 5 * 24 * 60 * MIN + 30 * MIN, status: "confirmed", response: null, title_hash: "x" };
  const moved = decide(args({ ...byAnn, start: { dateTime: iso(NOW + 6 * 24 * 60 * MIN) }, end: { dateTime: iso(NOW + 6 * 24 * 60 * MIN + 30 * MIN) } }, { previous: prev }));
  assert.equal(moved.alerts.find((a) => a.kind === "changed").body, "Moved by Ann · Sun 25 Oct, 10:00 AM");
  // Same event, nothing about its time changed (a guest replied): no 'changed'.
  assert.deepEqual(ids(decide(args(byAnn, { previous: prev }))), ["0", "5"]);
  // His own: only the lead alerts.
  assert.deepEqual(ids(decide(args(timed("e5", NOW + 5 * 24 * 60 * MIN)))), ["0", "5"]);
});

test("Gmail-made events ring at once; cancellations by others ring once; Banana's blocks never", () => {
  const gmail = timed("e6", NOW + 2 * 24 * 60 * MIN, { eventType: "fromGmail", creator: { email: "unknownorganizer@calendar.google.com" } });
  const g = decide(args(gmail));
  assert.equal(g.alerts.find((a) => a.kind === "changed").body, "From Gmail · Wed 21 Oct, 10:00 AM");
  const prev = { start_at: NOW + 60 * MIN, end_at: NOW + 90 * MIN, status: "confirmed", response: null, title_hash: "x" };
  const cancelled = decide(args({ id: "e7", status: "cancelled", creator: { email: "ann@y.com", displayName: "Ann" } }, { previous: prev }));
  assert.deepEqual(ids(cancelled), ["cancelled"]);
  assert.equal(cancelled.alerts[0].body, "Cancelled by Ann · was Today 11:00 AM");
  assert.equal(cancelled.state, null);
  // His own cancellation: silent, pending ones dropped.
  const mine = decide(args({ id: "e7", status: "cancelled", creator: { self: true } }, { previous: prev }));
  assert.deepEqual([ids(mine), mine.dropPending], [[], true]);
  const block = decide(args(timed("e8", NOW + 60 * MIN, { extendedProperties: { private: { bananaVariant: "banana", bananaItemID: "x" } } })));
  assert.deepEqual([block.alerts, block.state], [[], null]);
  // All-day: no lead alerts.
  assert.deepEqual(ids(decide(args({ id: "e9", summary: "Holiday", status: "confirmed", start: { date: "2026-10-20" }, end: { date: "2026-10-21" }, creator: { self: true } }))), []);
});

test("words and ids", () => {
  assert.equal(leadBody(NOW + 90 * MIN, NOW, "America/New_York"), "Starts at 11:30 AM.");
  assert.equal(leadBody(NOW + MIN, NOW, "UTC"), "Starts in 1 minute, at 2:01 PM.");
  assert.equal(when(NOW + 24 * 60 * MIN, NOW, "America/New_York"), "Tomorrow 10:00 AM");
  assert.equal(alertId("a@b.com", "ev1", "now"), "a@b.com|ev1|now");
  assert.match(collapseId("a@b.com|ev1|5"), /^a-[0-9a-f]{1,16}$/);
  assert.ok(collapseId("x").length <= 64);
  const p = alertPayload({ id: "c|e|5", kind: "lead", title: "T", body: "B" }, { calendarId: "c", eventId: "e", email: "m" });
  assert.deepEqual(p, { aps: { alert: { title: "T", body: "B" }, sound: "default", category: "EVENT_ALERT", "thread-id": "c|e", "interruption-level": "time-sensitive" },
    b: { k: "alert", id: "c|e|5", kind: "lead", cal: "c", event: "e", email: "m" } });
});
