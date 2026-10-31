// Booking end to end (docs/design/BOOKING.md §5, §12; src/booking/CONTRACT.md): the routes on the
// booking host, a fake Google and a memory outbox. No real account is ever used.
import { test } from "node:test";
import assert from "node:assert/strict";
import { setup, device, pushToken, DAY, HOUR, TOKEN_KEY } from "./helpers.js";
import { memoryEmail } from "../src/booking/email.js";
import { createSigner } from "../src/booking/sign.js";
import { bookingContext, bookingMinute, bookingQuarter } from "../src/booking/jobs.js";
import { pushTo } from "../src/app.js";
import { sha256Hex } from "../src/crypto.js";

const BOOK = "https://book.test";
const MIN = 60 * 1000;
const signer = createSigner(TOKEN_KEY);

/** A service with the booking host, a host account with handle "noor" and an iPhone that takes pushes. */
async function hostReady({ scopes, name = "Noor Haddad", deps = {}, handle = "noor", config = {} } = {}) {
  const email = memoryEmail({ log: false, enabled: true });
  const s = setup({ config: { bookUrl: BOOK, ...config }, deps: { email, pageCache: null, ...deps } });
  s.email = email;
  s.google.person("code-noor", "sub-noor", "noor@example.com", "refresh-noor", { name, ...(scopes ? { scopes } : {}) });
  const signed = await s.signIn("code-noor", device("phone-0001", { push: pushToken(1) }));
  s.session = signed.json.session;
  s.account = signed.json.account.id;
  if (handle) {
    const put = await s.call("PUT", "/v1/booking", { session: s.session, body: { handle, timeZone: "America/New_York" } });
    assert.equal(put.status, 200, JSON.stringify(put.json));
    await s.settle();
  }
  s.jar = new Map();
  /** A call on the booking host, keeping cookies like a browser. */
  s.page = async (method, path, { body, origin = BOOK, csrf, cookies = s.jar, headers = {} } = {}) => {
    const init = { method, headers: { ...headers } };
    if (body !== undefined) { init.body = JSON.stringify(body); init.headers["content-type"] = "application/json"; }
    if (origin && method !== "GET") init.headers.origin = origin;
    if (cookies.size) init.headers.cookie = [...cookies].map(([k, v]) => `${k}=${v}`).join("; ");
    if (csrf === undefined && cookies.has("__Host-bk") && method !== "GET") init.headers["x-csrf-token"] = await signer.csrf(await sha256Hex(cookies.get("__Host-bk")));
    else if (csrf) init.headers["x-csrf-token"] = csrf;
    const response = await s.app.request(`${BOOK}${path}`, init);
    for (const c of response.headers.getSetCookie()) {
      const [pair] = c.split(";");
      const [k, v] = pair.split("=");
      if (/max-age=0/i.test(c) || v === "") cookies.delete(k); else cookies.set(k, v);
    }
    const text = await response.text();
    let json;
    try { json = JSON.parse(text); } catch { json = undefined; }
    return { status: response.status, json, text, headers: response.headers };
  };
  s.slots = async (path = "/noor/meeting") => (await s.page("GET", `${path}/slots`)).json.slots;
  s.book = (start, over = {}) => s.page("POST", "/noor/meeting/book", {
    body: { key: over.key ?? `key-${Math.random().toString(36).slice(2, 12)}`, start, place: over.place, name: over.name ?? "Sam Lee",
      email: over.email ?? "sam@example.com", phone: over.phone, note: over.note, zone: over.zone ?? "Europe/London", turnstile: over.turnstile },
    cookies: over.cookies ?? s.jar });
  s.work = bookingContext(s.deps, { push: (a, o) => pushTo(s.deps, a, o), signer });
  s.minute = () => bookingMinute(s.work);
  s.row = (where = "1 = 1", ...params) => s.db.first(`SELECT * FROM bookings WHERE ${where} ORDER BY created_at DESC`, ...params);
  s.events = () => s.google.events.get("primary-refresh-noor") ?? s.google.events.set("primary-refresh-noor", []).get("primary-refresh-noor");
  s.mails = (kind) => s.email.sent.filter((m) => !kind || m.kind === kind);
  s.alerts = () => s.apns.sends.filter((p) => p.pushType === "alert");
  return s;
}
const ref = (booking) => booking.manageUrl.split("/").pop();
const pageData = (html) => JSON.parse(/<script type="application\/json" id="bk">([\s\S]*?)<\/script>/.exec(html)[1]);

test("a booking: reserved in the answer, the event made after it, the invite after the Undo window, our email, the host's push", async () => {
  const s = await hostReady();
  const slots = await s.slots();
  // Thu 15 Oct 08:00 in New York, four hours' notice: noon is the first time.
  assert.equal(slots[0].start, "2026-10-15T16:00:00.000Z");
  assert.equal(slots.length, 22 * 16 - 6, "Mon–Fri 9–5 for 30 days; today from noon");
  // Google is held back: the answer comes before the event exists.
  let open;
  s.google.gate = new Promise((resolve) => { open = resolve; });
  const r = await s.book(slots[0].start, { note: "About <b>the plan</b>\nthanks" });
  assert.equal(r.status, 200, r.text);
  assert.equal(r.json.booking.status, "pending");
  assert.ok(r.json.booking.undoUntil);
  assert.equal(r.json.booking.undoMs, 5000);
  assert.match(r.json.booking.manageUrl, /^\/m\/[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{22}$/);
  assert.equal(s.events().length, 0, "Google comes after the answer");
  assert.equal((await s.row()).status, "pending");
  assert.ok(s.jar.get("__Host-bk"), "the browser is remembered");
  open();
  s.google.gate = null;

  await s.settle();
  const [insert] = s.google.booking.insert;
  assert.equal(insert.sendUpdates, "none");
  assert.equal(insert.event.attendees, undefined, "nobody invited while Undo is open");
  assert.equal(insert.event.summary, "Meeting: Sam Lee");
  assert.deepEqual(insert.event.start, { dateTime: "2026-10-15T16:00:00.000Z", timeZone: "America/New_York" });
  assert.equal(insert.event.extendedProperties.private.bananaBooking, insert.event.id);
  assert.match(insert.event.id, /^[0-9a-f]{32}$/);
  assert.deepEqual(insert.event.conferenceData.createRequest, { requestId: insert.event.id, conferenceSolutionKey: { type: "hangoutsMeet" } });
  assert.deepEqual(insert.event.reminders, { useDefault: true });
  assert.match(insert.event.description, /About &#60;b&#62;the plan&#60;\/b&#62;<br>thanks/, "the note is escaped");
  assert.match(insert.event.description, /book\.test\/m\//);
  const [patch] = s.google.booking.patch;
  assert.deepEqual(patch.patch.attendees, [{ email: "sam@example.com", displayName: "Sam Lee" }]);
  assert.equal(patch.sendUpdates, "all");
  const [mail] = s.mails("confirmed");
  assert.equal(mail.to, "sam@example.com");
  assert.equal(mail.replyTo, "noor@example.com");
  assert.match(mail.subject, /Thu 15 Oct, 5:00–5:30 pm, London time/, "in the guest's zone");
  assert.equal(mail.attachments[0].type, "text/calendar");
  const [alert] = s.alerts();
  assert.equal(alert.payload.aps.alert.body, "Sam Lee booked Meeting, Thu 12:00 pm");
  assert.equal(alert.priority, 10);

  const state = await s.page("GET", r.json.booking.statusUrl);
  assert.equal(state.json.booking.status, "confirmed");
  assert.equal(state.json.booking.invite, "sent");
  assert.match(state.json.booking.placeDetail, /^https:\/\/meet\.google\.com\//);
  assert.equal(state.json.booking.undoUntil, null);
  // The slot is gone from the page.
  assert.notEqual((await s.slots())[0].start, slots[0].start);
  const ics = await s.page("GET", state.json.booking.icsUrl);
  assert.equal(ics.headers.get("content-type"), "text/calendar; charset=utf-8");
  assert.match(ics.text, new RegExp(`UID:${insert.event.id}@google.com`));
  assert.match(ics.text, /DTSTART:20261015T160000Z/);
});

test("two guests racing for one time: one booking; the other gets the three nearest", async () => {
  const s = await hostReady();
  const [first] = await s.slots();
  const [a, b] = await Promise.all([
    s.book(first.start, { email: "a@example.com", cookies: new Map() }),
    s.book(first.start, { email: "b@example.com", cookies: new Map() }),
  ]);
  assert.deepEqual([a.status, b.status].sort(), [200, 409]);
  const lost = a.status === 409 ? a : b;
  assert.equal(lost.json.taken, true);
  assert.equal(lost.json.nearest.length, 3);
  assert.ok(!lost.json.nearest.some((x) => x.start === first.start));
  assert.equal(await s.count("bookings"), 1);
});

test("a retried post is the same booking, before and after its event is made", async () => {
  const s = await hostReady();
  const [first] = await s.slots();
  const one = await s.book(first.start, { key: "retry-key-1" });
  const two = await s.book(first.start, { key: "retry-key-1" });
  assert.equal(two.status, 200);
  assert.equal(two.json.booking.manageUrl, one.json.booking.manageUrl);
  await s.settle();
  const three = await s.book(first.start, { key: "retry-key-1" });
  assert.equal(three.json.booking.manageUrl, one.json.booking.manageUrl);
  assert.equal(three.json.booking.status, "confirmed");
  assert.equal(await s.count("bookings"), 1);
  assert.equal(s.google.booking.insert.length, 1);
});

test("an insert whose answer was lost: the retry's 409 reads the event and carries on, one event", async () => {
  const s = await hostReady();
  const [first] = await s.slots();
  s.google.lostInsert = true;
  await s.book(first.start);
  await s.settle();
  assert.equal((await s.row()).status, "pending");
  s.advance(61 * 1000);
  await s.minute();
  await s.settle();
  const row = await s.row();
  assert.equal(row.status, "confirmed");
  assert.equal(row.invite, "sent");
  assert.equal(s.google.booking.insert.length, 2);
  assert.equal(s.events().filter((e) => e.extendedProperties?.private?.bananaBooking).length, 1);
});

test("a time not offered is refused with the three nearest; one taken at Google meanwhile ends as taken, the guest emailed", async () => {
  const s = await hostReady();
  const slots = await s.slots();
  const off = await s.book("2026-10-15T16:10:00.000Z");
  assert.equal(off.status, 409);
  assert.deepEqual(off.json.nearest.map((x) => x.start), slots.slice(0, 3).map((x) => x.start));
  // Something lands on the calendar after the snapshot: the booking's own re-read finds it.
  s.events().push({ id: "busy1", status: "confirmed", start: { dateTime: slots[0].start }, end: { dateTime: slots[0].end } });
  const r = await s.book(slots[0].start);
  assert.equal(r.status, 200);
  await s.settle();
  assert.equal((await s.row()).status, "taken");
  assert.equal(s.google.booking.insert.length, 0);
  assert.equal(s.mails("taken").length, 1);
  const state = await s.page("GET", r.json.booking.statusUrl);
  assert.equal(state.json.booking.status, "taken");
  assert.equal(state.json.booking.nearest.length, 3);
  assert.ok(!state.json.booking.nearest.some((x) => x.start === slots[0].start));
});

test("Meet: a pending link is read once more; Meet turned off leaves the booking confirmed without one", async () => {
  const s = await hostReady();
  s.google.meet = "pending";
  const slots = await s.slots();
  const r = await s.book(slots[0].start);
  await s.settle();
  const state = await s.page("GET", r.json.booking.statusUrl);
  assert.equal(state.json.booking.placeDetail, "https://meet.google.com/later-link");
  assert.equal(state.json.booking.meet, "ready");

  s.google.meet = "disabled";
  const r2 = await s.book(slots[4].start, { email: "kim@example.com", cookies: new Map() });
  await s.settle();
  const state2 = await s.page("GET", r2.json.booking.statusUrl);
  assert.equal(state2.json.booking.status, "confirmed");
  assert.equal(state2.json.booking.meet, "disabled");
  assert.equal(state2.json.booking.placeDetail, null);
});

test("Undo inside the window: nobody is ever invited or emailed, whether the event was made yet or not", async () => {
  const queued = [];
  const wakes = [];
  const s = await hostReady();
  s.deps.defer = (w) => queued.push(w);
  s.deps.sleep = () => new Promise((r) => wakes.push(r));
  const drain = async () => { while (queued.length) await queued.shift(); };
  const slots = await s.slots();
  // Undo while Google is still making the event: it is deleted again as soon as it exists.
  let open;
  s.google.gate = new Promise((r) => { open = r; });
  const early = await s.book(slots[0].start, { email: "early@example.com", cookies: new Map() });
  assert.equal((await s.page("POST", "/b/undo", { body: { manage: ref(early.json.booking) }, cookies: new Map() })).status, 204);
  open();
  await drain();
  assert.equal(s.google.booking.insert.length, 1);
  assert.deepEqual(s.google.booking.delete.map((d) => d.sendUpdates), ["none"]);
  assert.equal(s.events().length, 0);
  s.google.gate = null;

  // Undo after the event is made, the guest still held back: it goes, quietly.
  const r = await s.book(slots[2].start, { cookies: new Map() });
  await queued.shift();                               // made; the invite waits for the window
  assert.equal(s.google.booking.insert.length, 2);
  assert.equal((await s.page("POST", "/b/undo", { body: { manage: ref(r.json.booking) }, cookies: new Map() })).status, 204);
  s.advance(5000);
  for (const wake of wakes) wake();
  await drain();
  assert.equal(s.google.booking.patch.length, 0, "never invited");
  assert.deepEqual(s.google.booking.delete.map((d) => d.sendUpdates), ["none", "none"]);
  assert.equal(s.mails().length, 0);
  assert.equal(s.alerts().length, 0);
  assert.equal((await s.row("guest_email = 'sam@example.com'")).status, "cancelled");
  // After the window, Undo is refused.
  const late = await s.book(slots[6].start, { email: "late@example.com", cookies: new Map() });
  s.advance(6000);
  assert.equal((await s.page("POST", "/b/undo", { body: { manage: ref(late.json.booking) }, cookies: new Map() })).status, 409);
});

test("the minute job is the safety net: an invite held past the window goes out", async () => {
  const s = await hostReady();
  s.deps.sleep = async () => { throw new Error("the isolate went"); };   // it died during the wait
  const [first] = await s.slots();
  await s.book(first.start);
  await s.settle();
  assert.equal((await s.row()).invite, "held");
  s.advance(10 * 1000);
  await s.minute();
  assert.equal((await s.row()).invite, "sent");
  assert.equal(s.google.booking.patch[0].sendUpdates, "all");
  assert.equal(s.mails("confirmed").length, 1);
  await s.minute();
  assert.equal(s.mails("confirmed").length, 1, "once");
});

test("Google failing three times: the booking fails, the guest is emailed, the host pushed", async () => {
  const s = await hostReady();
  const slots = await s.slots();
  const first = slots[5];
  s.google.failInsert = 10;
  await s.book(first.start);
  await s.settle();
  s.advance(61 * 1000);
  await s.minute();
  s.advance(5 * MIN + 1000);
  await s.minute();
  await s.settle();
  assert.equal((await s.row()).status, "failed");
  assert.equal(s.mails("failed").length, 1);
  assert.match(s.alerts().at(-1).payload.aps.alert.body, /couldn't book Meeting/);
  assert.ok((await s.slots()).some((x) => x.start === first.start), "the time is free again");
});

test("move and cancel from the manage link; the host is pushed; Google tells the guest", async () => {
  const s = await hostReady();
  const slots = await s.slots();
  const r = await s.book(slots[2].start);
  await s.settle();
  const m = ref(r.json.booking);
  const manage = await s.page("GET", `/m/${m}`);
  assert.equal(manage.status, 200);
  assert.equal(manage.headers.get("referrer-policy"), "no-referrer");
  const moved = await s.page("POST", `/m/${m}/move`, { body: { start: slots[5].start, zone: "Europe/Paris" } });
  assert.equal(moved.status, 200, moved.text);
  assert.equal(moved.json.booking.start, slots[5].start);
  assert.equal(moved.json.booking.undoMs, 5000);
  assert.equal(moved.json.booking.undoes, "move");
  const patches = s.google.booking.patch.length;
  await s.settle();
  const patch = s.google.booking.patch.at(-1);
  assert.equal(s.google.booking.patch.length, patches + 1, "Google hears of it after the window");
  assert.equal(patch.sendUpdates, "all");
  assert.equal(patch.patch.start.dateTime, slots[5].start);
  assert.match(s.alerts().at(-1).payload.aps.alert.body, /^Sam Lee moved Meeting to Thu 2:30 pm$/);
  assert.ok((await s.slots()).some((x) => x.start === slots[2].start), "the old time is free again");
  assert.equal((await s.row()).guest_zone, "Europe/Paris");

  const taken = await s.book(slots[8].start, { email: "other@example.com", cookies: new Map() });
  await s.settle();
  const clash = await s.page("POST", `/m/${m}/move`, { body: { start: slots[8].start } });
  assert.equal(clash.status, 409);
  assert.equal(clash.json.nearest.length, 3);
  assert.equal(taken.status, 200);

  assert.equal((await s.page("POST", `/m/${m}/cancel`, { body: { reason: "Sick" } })).status, 204);
  await s.settle();
  assert.equal(s.google.booking.delete.at(-1).sendUpdates, "all");
  assert.match(s.alerts().at(-1).payload.aps.alert.body, /Sam Lee cancelled Meeting, .*: Sick$/);
  assert.equal((await s.page("GET", `/m/${m}`)).status, 200);
  assert.match((await s.page("GET", `/m/${m}`)).text, /Cancelled/);
  // A forged or broken link is a plain 404.
  assert.equal((await s.page("GET", `/m/${m.slice(0, -1)}${m.endsWith("A") ? "B" : "A"}`)).status, 404);
  assert.equal((await s.page("GET", "/m/nonsense")).status, 404);
});

test("the host deletes the event: the manage page shows it cancelled; a watch notice tells the guest", async () => {
  const s = await hostReady();
  const slots = await s.slots();
  const one = await s.book(slots[0].start);
  const two = await s.book(slots[3].start, { email: "kim@example.com", cookies: new Map() });
  await s.settle();
  // One deleted, the other moved by the host at Google.
  const events = s.events();
  const id2 = (await s.row("guest_email = 'kim@example.com'")).id;
  s.google.events.set("primary-refresh-noor", events.filter((e) => e.extendedProperties?.private?.bananaBooking === id2));
  const moved = s.events()[0];
  moved.start = { dateTime: slots[10].start };
  moved.end = { dateTime: slots[10].end };
  const page = await s.page("GET", `/m/${ref(one.json.booking)}`);
  assert.match(page.text, /Cancelled/);
  assert.equal((await s.row("guest_email = 'sam@example.com'")).cancelled_by, "host");

  // A notice on a watched calendar rebuilds the snapshot and tells the moved guest once.
  await s.db.run(`INSERT INTO watches (channel_id, account_id, google_sub, calendar_id, resource_id, secret, expires_at, status, failures, created_at, managed_by)
    VALUES ('chan-1', ?, 'sub-noor', 'primary-refresh-noor', 'res', 'secret', ?, 'live', 0, ?, 'device')`, s.account, s.now() + DAY, s.now());
  s.advance(1000);
  await s.call("POST", "/v1/google/notify", { headers: { "x-goog-channel-id": "chan-1", "x-goog-channel-token": "secret", "x-goog-resource-state": "exists" } });
  await s.settle();
  assert.equal(s.mails("moved").length, 1);
  assert.equal(Number((await s.row("guest_email = 'kim@example.com'")).start_at), Date.parse(slots[10].start));
  assert.ok(!(await s.slots()).some((x) => x.start === slots[10].start), "the snapshot follows the calendar");
  assert.equal(two.status, 200);
});

test("reminders: 24 h and 1 h once each; skipped inside their window; moved or gone at Google is told instead; sent from the row when Google says no", async () => {
  const s = await hostReady();
  const slots = await s.slots();
  const later = slots.find((x) => Date.parse(x.start) >= s.now() + 3 * DAY);
  const soon = slots.find((x) => Date.parse(x.start) >= s.now() + 6 * HOUR);   // today, 6 hours ahead
  await s.book(later.start, { email: "far@example.com", cookies: new Map() });
  await s.book(soon.start, { email: "near@example.com", cookies: new Map() });
  await s.settle();
  await s.minute();
  assert.equal(s.mails("reminder24").length, 0);
  assert.equal(Number((await s.row("guest_email = 'near@example.com'")).reminded_24), 2, "made inside 24 h: skipped");
  s.advance(Date.parse(soon.start) - HOUR + MIN - s.now());
  await s.minute();
  assert.deepEqual(s.mails("reminder1").map((m) => m.to), ["near@example.com"]);
  await s.minute();
  assert.equal(s.mails("reminder1").length, 1, "once");
  s.advance(Date.parse(later.start) - DAY + MIN - s.now());
  await s.minute();
  assert.deepEqual(s.mails("reminder24").map((m) => m.to), ["far@example.com"]);
  assert.match(s.mails("reminder24")[0].html, /Change or cancel/);
  // Google refuses the host's token: the 1-hour one still goes, from the row.
  s.google.refused.add("refresh-noor");
  s.advance(Date.parse(later.start) - HOUR + MIN - s.now());
  await s.minute();
  assert.equal(s.mails("reminder1").length, 2);
});

test("reminders: an event the host moved or deleted at Google gets that news instead, once", async () => {
  const s = await hostReady();
  const slots = await s.slots();
  const a = slots.find((x) => Date.parse(x.start) >= s.now() + 3 * DAY);
  const b = slots.find((x) => Date.parse(x.start) >= Date.parse(a.start) + 2 * HOUR);
  await s.book(a.start, { email: "moved@example.com", cookies: new Map() });
  await s.book(b.start, { email: "gone@example.com", cookies: new Map() });
  await s.settle();
  const idA = (await s.row("guest_email = 'moved@example.com'")).id;
  const idB = (await s.row("guest_email = 'gone@example.com'")).id;
  const evA = s.events().find((e) => e.id === idA);
  evA.start = { dateTime: new Date(Date.parse(a.start) + 2 * DAY).toISOString() };
  evA.end = { dateTime: new Date(Date.parse(a.end) + 2 * DAY).toISOString() };
  s.google.events.set("primary-refresh-noor", s.events().filter((e) => e.id !== idB));
  s.advance(Date.parse(b.start) - DAY + MIN - s.now());
  await s.minute();
  await s.minute();
  assert.equal(s.mails("reminder24").length, 0);
  assert.deepEqual(s.mails("moved").map((m) => m.to), ["moved@example.com"]);
  assert.deepEqual(s.mails("cancelled").map((m) => m.to), ["gone@example.com"]);
});

test("guests: remembered by a cookie the API never takes; one tap books; Turnstile only for a browser we don't know; Origin and CSRF checked", async () => {
  let checks = 0;
  const s = await hostReady({ deps: { turnstile: { enabled: true, async verify(token) { checks++; return token === "ok"; } } } });
  const slots = await s.slots();
  assert.equal((await s.book(slots[0].start)).json.field, "turnstile");
  const first = await s.book(slots[0].start, { turnstile: "ok" });
  assert.equal(first.status, 200);
  const cookie = s.jar.get("__Host-bk");
  const page = await s.page("GET", "/noor/meeting");
  assert.equal(page.status, 200);
  assert.deepEqual(pageData(page.text).g, { state: "remembered", name: "Sam Lee", email: "sam@example.com", phone: "" });
  // A second time, one tap: no Turnstile.
  await s.settle();
  const again = await s.page("POST", "/noor/meeting/book", { body: { key: "second-key", start: slots[6].start, name: "Sam Lee", email: "sam@example.com", zone: "Europe/London" } });
  assert.equal(again.status, 409, "one future time per email per type");
  assert.equal(again.json.already, true);
  await s.settle();
  assert.equal(s.mails("existing").length, 1, "the link goes only to the email");
  assert.equal(checks, 2, "Turnstile wasn't asked for the remembered email");
  // Another email from the same browser is a first time: Turnstile again.
  const other = await s.page("POST", "/noor/meeting/book", { body: { key: "third-key", start: slots[6].start, name: "Sam Lee", email: "sam.work@example.com", zone: "Europe/London" } });
  assert.equal(other.json.field, "turnstile");
  const other2 = await s.page("POST", "/noor/meeting/book", { body: { key: "third-key", start: slots[6].start, name: "Sam Lee", email: "sam.work@example.com", zone: "Europe/London", turnstile: "ok" } });
  assert.equal(other2.status, 200);
  // The cookie is no API session, whichever way it is sent.
  assert.equal((await s.call("GET", "/v1/account", { session: cookie })).status, 401);
  assert.equal((await s.call("GET", "/v1/account", { headers: { cookie: `__Host-bk=${cookie}` } })).status, 401);
  assert.equal((await s.call("POST", "/v2/sync", { session: cookie, body: { device: "x", changes: [] } })).status, 401);
  // POSTs need our Origin; with a cookie, the page's CSRF token.
  assert.equal((await s.page("POST", "/b/undo", { body: { manage: "x" }, origin: "https://evil.example" })).status, 403);
  assert.equal((await s.page("POST", "/b/undo", { body: { manage: "x" }, origin: null })).status, 403);
  assert.equal((await s.page("POST", "/b/undo", { body: { manage: "x" }, csrf: "wrong" })).status, 403);
  // The cookie's flags.
  const set = (await s.book(slots[12].start, { email: "new@example.com", cookies: new Map(), turnstile: "ok" })).headers.getSetCookie()[0];
  assert.match(set, /^__Host-bk=[A-Za-z0-9_-]+; Max-Age=31536000; Path=\/; HttpOnly; Secure; SameSite=Lax$/);
});

test("inputs are checked: caps, a real email, a phone when the host calls, control characters gone", async () => {
  const s = await hostReady();
  const [first] = await s.slots();
  const field = async (over) => (await s.book(first.start, { cookies: new Map(), ...over })).json?.field;
  assert.equal(await field({ name: "x".repeat(81) }), "name");
  assert.equal(await field({ name: "" }), "name");
  assert.equal(await field({ email: "not an email" }), "email");
  assert.equal(await field({ email: `${"a".repeat(250)}@x.co` }), "email");
  assert.equal(await field({ note: "n".repeat(1001) }), "note");
  assert.equal(await field({ phone: "1".repeat(33) }), "phone");
  assert.equal(await field({ place: "nowhere" }), "place");
  const ok = await s.book(first.start, { name: "Sam\u0007 Lee", cookies: new Map() });
  assert.equal(ok.status, 200);
  assert.equal((await s.row()).guest_name, "Sam Lee");
  const big = await s.page("POST", "/noor/meeting/book", { body: { key: "k".repeat(20), start: first.start, name: "x", email: "a@b.co", note: "y".repeat(9000) }, cookies: new Map() });
  assert.equal(big.status, 400);
});

test("the 6-digit code: always 204, single use, five tries; a verified guest sees their times; Forget me", async () => {
  const s = await hostReady();
  const slots = await s.slots();
  // The page shows upcoming times by the browser's own clock: a time after today's real date.
  await s.book(slots.find((x) => Date.parse(x.start) > Date.now() + DAY).start, { cookies: new Map() });
  await s.settle();
  assert.equal((await s.page("POST", "/b/code", { body: { email: "sam@example.com" } })).status, 204);
  const [mail] = s.mails("code");
  const code = /^(\d{6}) is your Banana code$/.exec(mail.subject)[1];
  assert.equal((await s.page("POST", "/b/code/verify", { body: { email: "sam@example.com", code: code === "000000" ? "111111" : "000000" } })).status, 400);
  assert.equal((await s.page("POST", "/b/code/verify", { body: { email: "sam@example.com", code } })).status, 204);
  assert.equal((await s.page("POST", "/b/code/verify", { body: { email: "sam@example.com", code } })).status, 400, "single use");
  const page = pageData((await s.page("GET", "/noor/meeting")).text);
  assert.equal(page.g.state, "verified");
  const html = (await s.page("GET", "/noor/meeting")).text;
  assert.match(html, /Your next time/);
  // Five wrong tries end a code (the per-address limit, reset in between, is not what refuses it).
  s.advance(MIN);
  await s.page("POST", "/b/code", { body: { email: "kim@example.com" }, cookies: new Map() });
  const kim = /^(\d{6})/.exec(s.mails("code").at(-1).subject)[1];
  for (let i = 0; i < 5; i++) assert.equal((await s.page("POST", "/b/code/verify", { body: { email: "kim@example.com", code: kim === "123456" ? "654321" : "123456" }, cookies: new Map() })).status, 400);
  s.advance(MIN);
  assert.equal((await s.page("POST", "/b/code/verify", { body: { email: "kim@example.com", code: kim }, cookies: new Map() })).status, 400);
  // Unknown emails get the same answer.
  assert.equal((await s.page("POST", "/b/code", { body: { email: "nobody@example.com" }, cookies: new Map() })).status, 204);

  const forget = await s.page("GET", "/b/forget");
  assert.match(forget.text, /Your upcoming time stays on the host/);
  assert.equal((await s.page("POST", "/b/forget")).status, 204);
  const row = await s.row();
  assert.equal(row.guest_email, null);
  assert.equal(row.guest_name, null);
  assert.equal(Number(row.reminded_24), 2);
  assert.equal(await s.count("guests", "email = 'sam@example.com'"), 0);
  assert.equal(await s.count("sessions", "kind = 'guest'"), 0);
  assert.equal(s.jar.has("__Host-bk"), false);
});

test("Google connect: offline access asked once, the grant kept apart from host links, free/busy on the page", async () => {
  const s = await hostReady();
  s.google.person("guest-code", "sub-guest", "guest@example.com", "refresh-guest",
    { name: "Gus Guest", scopes: "openid email profile https://www.googleapis.com/auth/calendar.events.freebusy", accessToken: "access-guest-once" });
  const go = await s.page("GET", "/b/connect?return=/noor/meeting");
  assert.equal(go.status, 302);
  const url = new URL(go.headers.get("location"));
  assert.equal(url.host, "accounts.google.com");
  assert.equal(url.searchParams.get("access_type"), "offline");
  assert.equal(url.searchParams.get("prompt"), "consent");
  assert.equal(url.searchParams.get("redirect_uri"), `${BOOK}/b/connect/callback`);
  assert.match(url.searchParams.get("scope"), /calendar\.events\.freebusy/);
  // A state that isn't ours, or without its cookie: nothing.
  assert.equal((await s.page("GET", `/b/connect/callback?code=guest-code&state=${url.searchParams.get("state")}`, { cookies: new Map() })).status, 404);
  const back = await s.page("GET", `/b/connect/callback?code=guest-code&state=${encodeURIComponent(url.searchParams.get("state"))}`);
  assert.equal(back.status, 303);
  assert.equal(back.headers.get("location"), "/noor/meeting");
  assert.equal(await s.count("guest_grants", "sub = 'sub-guest' AND status = 'ok'"), 1);
  assert.equal(await s.count("google_links", "sub = 'sub-guest'"), 0, "never a host link");
  s.google.freeBusyAnswer = [{ start: "2026-10-16T14:00:00Z", end: "2026-10-16T15:00:00Z" }];
  const slots = await s.page("GET", "/noor/meeting/slots");
  assert.deepEqual(slots.json.busy, [{ start: "2026-10-16T14:00:00Z", end: "2026-10-16T15:00:00Z" }]);
  assert.equal(slots.headers.get("cache-control"), "private, no-store");
  // Connected: the page offers no connect, and asks identity only the next time.
  assert.equal((await s.page("GET", "/b/connect?return=/noor")).headers.get("location").includes("access_type"), false);
  // Without a refresh token (Google had granted before): the busy rides in the link, once.
  s.google.person("again-code", "sub-two", "two@example.com", null, { scopes: "openid email https://www.googleapis.com/auth/calendar.events.freebusy", accessToken: "access-two" });
  const jar2 = new Map();
  const go2 = new URL((await s.page("GET", "/b/connect?return=/noor/meeting", { cookies: jar2 })).headers.get("location"));
  const back2 = await s.page("GET", `/b/connect/callback?code=again-code&state=${encodeURIComponent(go2.searchParams.get("state"))}`, { cookies: jar2 });
  const loc = back2.headers.get("location");
  assert.match(loc, /^\/noor\/meeting\?fb=/);
  assert.deepEqual((await s.page("GET", `${loc.replace("/noor/meeting", "/noor/meeting/slots")}`, { cookies: jar2 })).json.busy,
    [{ start: "2026-10-16T14:00:00.000Z", end: "2026-10-16T15:00:00.000Z" }]);
  // Forget me revokes the grant at Google.
  assert.equal((await s.page("POST", "/b/forget")).status, 204);
  assert.ok(s.google.calls.revoke.includes("refresh-guest"));
  assert.equal(await s.count("guest_grants"), 0);
});

test("a guest who is a Banana person: their own calendars count", async () => {
  const s = await hostReady();
  s.google.person("code-ann", "sub-ann", "ann@example.com", "refresh-ann");
  const ann = await s.signIn("code-ann", device("mac-00000001", { platform: "mac" }));
  await s.call("PUT", "/v1/booking", { session: ann.json.session, body: { handle: "ann-lee", timeZone: "America/New_York" } });
  await s.settle();
  s.google.events.set("primary-refresh-ann", [{ id: "ann1", status: "confirmed", start: { dateTime: "2026-10-16T14:00:00Z" }, end: { dateTime: "2026-10-16T15:00:00Z" } }]);
  await s.call("PUT", "/v1/booking", { session: ann.json.session, body: { handle: "ann-lee" } });
  s.advance(11 * MIN);
  await bookingQuarter(s.work);
  await s.page("POST", "/b/code", { body: { email: "ann@example.com" } });
  const code = /^(\d{6})/.exec(s.mails("code").at(-1).subject)[1];
  await s.page("POST", "/b/code/verify", { body: { email: "ann@example.com", code } });
  const slots = await s.page("GET", "/noor/meeting/slots");
  assert.deepEqual(slots.json.busy, [{ start: "2026-10-16T14:00:00.000Z", end: "2026-10-16T15:00:00.000Z" }]);
});

test("the host's link refused or too narrow: not taking bookings, the host told once a day", async () => {
  const s = await hostReady({ scopes: "openid email" });
  const page = await s.page("GET", "/noor");
  assert.equal(page.status, 200);
  assert.match(page.text, /isn't taking bookings right now/);
  await s.settle();
  assert.equal(s.alerts().length, 1);
  await s.page("GET", "/noor/meeting");
  await s.settle();
  assert.equal(s.alerts().length, 1, "once a day");
  assert.equal((await s.book("2026-10-15T16:00:00.000Z")).status, 409);
});

test("hosts: booking pages only on the booking host, the API never there", async () => {
  const s = await hostReady();
  assert.equal((await s.page("GET", "/v1/health")).status, 404);
  assert.match((await s.page("GET", "/v1/health")).headers.get("content-type"), /text\/html/);
  const api = await s.call("GET", "/noor");
  assert.equal(api.status, 404);
  assert.deepEqual(api.json, { error: "not_found" });
  assert.equal((await s.page("GET", "/nobody-here")).status, 404);
  assert.equal((await s.page("GET", "/noor/nope")).status, 404);
  assert.equal((await s.page("GET", "/Bad!")).status, 404);
});

test("the handle API: suggested from the Google name, checked, one per handle", async () => {
  const s = await hostReady({ handle: null });
  const before = await s.call("GET", "/v1/booking", { session: s.session });
  assert.deepEqual(before.json.suggested, ["noor", "noor-haddad", "noorhaddad"]);
  assert.equal(before.json.handle, null);
  assert.equal((await s.call("PUT", "/v1/booking", { session: s.session, body: { handle: "api" } })).json.error, "reserved");
  assert.equal((await s.call("PUT", "/v1/booking", { session: s.session, body: { handle: "B!" } })).json.error, "invalid");
  assert.equal((await s.call("PUT", "/v1/booking", { session: s.session, body: { handle: "-ab" } })).json.error, "invalid");
  assert.equal((await s.call("PUT", "/v1/booking", { session: s.session, body: { handle: "noor", timeZone: "EST" } })).json.error, "zone");
  const put = await s.call("PUT", "/v1/booking", { session: s.session, body: { handle: "noor", timeZone: "US/Eastern" } });
  assert.deepEqual(put.json, { handle: "noor", link: "https://book.test/noor" });
  s.google.person("code-x", "sub-x", "noor.h@example.com", "refresh-x", { name: "Noor Haddad" });
  const other = await s.signIn("code-x", device("ipad-0000001", { platform: "ipad" }));
  assert.equal((await s.call("PUT", "/v1/booking", { session: other.json.session, body: { handle: "noor" } })).status, 409);
  assert.deepEqual((await s.call("GET", "/v1/booking", { session: other.json.session })).json.suggested, ["noor-haddad", "noorhaddad", "noorh"]);
  await s.settle();
  const after = await s.call("GET", "/v1/booking", { session: s.session });
  assert.equal(after.json.timeZone, "America/New_York");
  assert.deepEqual(after.json.types, [{ slug: "meeting", title: "Meeting", active: true, link: "https://book.test/noor/meeting" }]);
  // A new handle: the old one's pages are gone.
  await s.call("PUT", "/v1/booking", { session: s.session, body: { handle: "bk" } });
  await s.call("PUT", "/v1/booking", { session: s.session, body: { handle: "noor-k" } });
  assert.equal((await s.page("GET", "/noor")).status, 404);
  assert.equal((await s.page("GET", "/noor-k")).status, 200);
  const upcoming = await s.call("GET", "/v1/booking/upcoming", { session: s.session });
  assert.deepEqual(upcoming.json, { bookings: [] });
  assert.equal((await s.call("GET", "/v1/booking")).status, 401);
});

test("booking types from the space: an edit in the app reaches the page at once", async () => {
  const s = await hostReady();
  const clock = (n) => `${String(s.now()).padStart(13, "0")}.000${n}.phone`;
  const sync = await s.call("POST", "/v2/sync", { session: s.session, body: { device: "phone-0001", changes: [
    { type: "plan.bookingType", id: "t-intro", set: { title: "Intro", slug: "intro", minutes: 15, hours: [[], [], [], [], [[600, 660]], [], []], timeZone: "Asia/Kolkata", notice: 0 },
      clocks: { title: clock(1), slug: clock(1), minutes: clock(1), hours: clock(1), timeZone: clock(1), notice: clock(1) } },
    { type: "plan.bookingType", id: "t-call", set: { title: "Call", slug: "call", locations: [{ kind: "phone_host_calls" }] },
      clocks: { title: clock(2), slug: clock(2), locations: clock(2) } },
  ] } });
  assert.equal(sync.status, 200);
  await s.settle();
  const profile = await s.page("GET", "/noor");
  assert.match(profile.text, /Intro/);
  assert.match(profile.text, /Call/);
  const intro = (await s.page("GET", "/noor/intro/slots")).json.slots;
  assert.equal(intro[0].start, "2026-10-22T04:30:00.000Z", "Thursday 10:00 in Kolkata; today's is past (it's 17:30 there)");
  assert.equal(intro.length, 4 * 4, "four Thursdays in the 30 days, four 15-minute times each");
  assert.equal((await s.page("GET", "/noor/meeting")).status, 404, "the default type goes once there are types");
  const call = await s.page("POST", "/noor/call/book", { body: { key: "call-key-1", start: (await s.slots("/noor/call"))[0].start, name: "Sam", email: "s@example.com", zone: "UTC" }, cookies: new Map() });
  assert.equal(call.json.field, "phone");
});

test("deleting the host's account deletes their bookings and handle", async () => {
  const s = await hostReady();
  const [first] = await s.slots();
  await s.book(first.start);
  await s.settle();
  s.google.person("code-noor-2", "sub-noor", "noor@example.com", "refresh-noor");
  assert.equal((await s.call("DELETE", "/v1/account", { body: { code: "code-noor-2" } })).status, 204);
  assert.equal(await s.count("bookings"), 0);
  assert.equal(await s.count("booking_handles"), 0);
  assert.equal(await s.count("busy_snapshot"), 0);
});

test("rate limits answer 429, and the page cache serves a guest it doesn't know", async () => {
  let allow = true;
  const s = await hostReady({ deps: { limit: async () => allow } });
  allow = false;
  assert.equal((await s.page("GET", "/noor/meeting/slots")).status, 429);
  assert.equal((await s.book("2026-10-15T16:00:00.000Z")).status, 429);
  allow = true;
  const { memoryPageCache } = await import("../src/booking/guard.js");
  s.deps.pageCache = memoryPageCache();
  const one = await s.page("GET", "/noor/meeting", { cookies: new Map() });
  const two = await s.page("GET", "/noor/meeting", { cookies: new Map() });
  assert.match(one.headers.get("server-timing"), /cache;desc=miss/);
  assert.match(two.headers.get("server-timing"), /cache;desc=fresh/);
  s.advance(60 * 1000);
  const three = await s.page("GET", "/noor/meeting", { cookies: new Map() });
  assert.match(three.headers.get("server-timing"), /cache;desc=stale/);
});

test("a type's own calendar takes its events, through the link of its email, even one left out of busy time", async () => {
  const s = await hostReady();
  const clock = `${String(s.now()).padStart(13, "0")}.0001.phone`;
  await s.call("POST", "/v2/sync", { session: s.session, body: { device: "phone-0001", changes: [
    { type: "plan.bookingType", id: "t-team", set: { title: "Team", slug: "team", calendar: { email: "noor@example.com", id: "team@group.calendar.google.com" } },
      clocks: { title: clock, slug: clock, calendar: clock } },
  ] } });
  await s.settle();
  const [first] = await s.slots("/noor/team");
  assert.equal((await s.page("POST", "/noor/team/book", { body: { key: "team-key-01", start: first.start, name: "Sam", email: "sam@example.com", zone: "UTC" } })).status, 200);
  await s.settle();
  assert.equal(s.google.booking.insert[0].calendarId, "team@group.calendar.google.com");
  assert.equal((await s.row()).status, "confirmed");
});

// ---- after Fable's review (20 Oct) ----

test("handles: two accounts racing for one: one gets it, the other 409; a handle change can't take someone's", async () => {
  const s = await hostReady({ handle: null });
  s.google.person("code-x", "sub-x", "x@example.com", "refresh-x");
  const other = await s.signIn("code-x", device("ipad-0000001", { platform: "ipad" }));
  const [a, b] = await Promise.all([
    s.call("PUT", "/v1/booking", { session: s.session, body: { handle: "sam", timeZone: "UTC" } }),
    s.call("PUT", "/v1/booking", { session: other.json.session, body: { handle: "sam", timeZone: "UTC" } }),
  ]);
  assert.deepEqual([a.status, b.status].sort(), [200, 409]);
  assert.equal(await s.count("booking_handles"), 1);
  const loser = a.status === 409 ? s.session : other.json.session;
  assert.equal((await s.call("PUT", "/v1/booking", { session: loser, body: { handle: "kim" } })).status, 200);
  assert.equal((await s.call("PUT", "/v1/booking", { session: loser, body: { handle: "sam" } })).status, 409, "renaming onto a taken handle");
  assert.equal((await s.call("PUT", "/v1/booking", { session: loser, body: { handle: "kim" } })).status, 200, "the same again is fine");
});

test("busy: another account's booking event stays busy; only this account's live rows stand in for their events", async () => {
  const s = await hostReady();
  const slots = await s.slots();
  // An event some other Banana booking put on this calendar (the host is someone else's guest).
  s.events().push({ id: "x", status: "confirmed", start: { dateTime: slots[4].start }, end: { dateTime: slots[4].end }, extendedProperties: { private: { bananaBooking: "f".repeat(32) } } });
  s.advance(11 * MIN);
  await bookingQuarter(s.work);
  assert.ok(!(await s.slots()).some((x) => x.start === slots[4].start));
});

test("a zone the browser got wrong falls back to the type's, never UTC; undoMs counts down", async () => {
  const s = await hostReady();
  const [first] = await s.slots();
  const r = await s.book(first.start, { zone: "EST" });
  assert.equal(r.status, 200);
  assert.equal((await s.row()).guest_zone, "America/New_York");
  s.advance(2000);
  assert.equal((await s.page("GET", r.json.booking.statusUrl)).json.booking.undoMs, 3000);
});

test("bounded: an invite Google keeps refusing is given up after three tries, the guest still told, the host pushed", async () => {
  const s = await hostReady();
  const [first] = await s.slots();
  s.google.failPatch = 10;
  await s.book(first.start);
  await s.settle();
  for (let i = 0; i < 4; i++) { s.advance(5 * MIN); await s.minute(); }
  const row = await s.row();
  assert.equal(row.invite, "failed");
  assert.equal(s.google.booking.patch.length, 3);
  assert.equal(s.mails("confirmed").length, 1);
  assert.match(s.alerts().at(-1).payload.aps.alert.body, /couldn't invite them/);
  s.advance(10 * MIN);
  await s.minute();
  assert.equal(s.google.booking.patch.length, 3, "no fourth try");
});

test("bounded: a delete the host's token can't make stops at once, and the host is told", async () => {
  const s = await hostReady();
  const [first] = await s.slots();
  const r = await s.book(first.start);
  await s.settle();
  s.google.refused.add("refresh-noor");
  await s.page("POST", `/m/${ref(r.json.booking)}/cancel`, { body: {} });
  await s.settle();
  assert.equal(Number((await s.row()).google_pending), 0);
  assert.match(s.alerts().at(-1).payload.aps.alert.body, /delete it there/);
  assert.deepEqual(s.alerts().at(-1).payload.b, { k: "booking", cal: "noor@example.com", event: (await s.row()).id, start: Date.parse(first.start), cancelled: true });
  await s.minute();
  assert.equal(s.google.booking.delete.length, 0);
});

test("a move: 5 s to undo it, and Google and the host hear nothing of an undone one", async () => {
  const queued = [];
  const s = await hostReady();
  const slots = await s.slots();
  const r = await s.book(slots[2].start);
  await s.settle();
  s.deps.defer = (w) => queued.push(w);
  s.deps.sleep = async () => {};                          // the window's wait; the claim itself checks the clock
  const m = ref(r.json.booking);
  const patches = s.google.booking.patch.length, alerts = s.alerts().length;
  const moved = await s.page("POST", `/m/${m}/move`, { body: { start: slots[5].start } });
  assert.equal(moved.json.booking.undoMs, 5000);
  assert.equal((await s.page("POST", "/b/undo", { body: { manage: m } })).status, 204);
  const row = await s.row();
  assert.equal(Number(row.start_at), Date.parse(slots[2].start));
  assert.equal(Number(row.patch_pending), 0);
  s.advance(6000);
  while (queued.length) await queued.shift();
  await s.minute();
  assert.equal(s.google.booking.patch.length, patches, "Google never heard of it");
  assert.equal(s.alerts().length, alerts, "nor the host");
  assert.equal((await s.page("POST", "/b/undo", { body: { manage: m } })).status, 409, "and the window is gone");
});

test("a move's Undo when its old time went meanwhile: the new time stands, the answer says so, Google hears of it", async () => {
  const queued = [];
  const s = await hostReady();
  const slots = await s.slots();
  const r = await s.book(slots[2].start);
  await s.settle();
  s.deps.defer = (w) => queued.push(w);
  s.deps.sleep = async () => {};                          // the window's wait; the claim itself checks the clock
  const m = ref(r.json.booking);
  await s.page("POST", `/m/${m}/move`, { body: { start: slots[5].start } });
  await s.db.run(`INSERT INTO bookings (id, manage_id, account_id, type_id, type_title, start_at, end_at, block_start, block_end, status, invite, created_at, timed_at, updated_at)
    VALUES ('other', 'other-manage-id-000000', ?, 'default', 'Meeting', ?, ?, ?, ?, 'pending', 'held', 1, 1, 1)`,
    s.account, Date.parse(slots[2].start), Date.parse(slots[2].end), Date.parse(slots[2].start), Date.parse(slots[2].end));
  const undone = await s.page("POST", "/b/undo", { body: { manage: m } });
  assert.equal(undone.status, 409);
  assert.equal(undone.json.kept, true);
  assert.equal(undone.json.booking.start, slots[5].start);
  while (queued.length) await queued.shift();
  assert.equal(s.google.booking.patch.at(-1).patch.start.dateTime, slots[5].start);
  assert.match(s.alerts().at(-1).payload.aps.alert.body, /moved Meeting/);
});

test("a move Google refuses stands here and is retried; the manage page's live read doesn't take it back", async () => {
  const s = await hostReady();
  const slots = await s.slots();
  const r = await s.book(slots[2].start);
  await s.settle();
  const m = ref(r.json.booking);
  s.google.failPatch = 1;
  assert.equal((await s.page("POST", `/m/${m}/move`, { body: { start: slots[5].start } })).status, 200);
  await s.settle();
  assert.equal(Number((await s.row()).patch_pending), 1);
  // Google still has the old time: the manage page reads it, and must not call that a host move.
  const page = await s.page("GET", `/m/${m}`);
  assert.equal(page.status, 200);
  assert.equal(Number((await s.row()).start_at), Date.parse(slots[5].start));
  assert.equal(s.mails("moved").length, 0);
  s.advance(6 * MIN);
  await s.minute();
  const row = await s.row();
  assert.equal(Number(row.patch_pending), 0);
  assert.equal(s.google.booking.patch.at(-1).patch.start.dateTime, slots[5].start);
  assert.match(s.alerts().at(-1).payload.aps.alert.body, /moved Meeting/, "the host hears once Google has it");
});

test("the host deletes the event before the guest is invited: the guest is emailed, the follow-up says cancelled", async () => {
  const queued = [];
  let wake;
  const s = await hostReady();
  s.deps.defer = (w) => queued.push(w);
  s.deps.sleep = () => new Promise((r) => { wake = r; });
  const [first] = await s.slots();
  const r = await s.book(first.start);
  await queued.shift();                                  // made, the guest held back
  s.google.events.set("primary-refresh-noor", []);       // the host deletes it in the window
  s.advance(5000);
  wake();
  while (queued.length) await queued.shift();
  assert.equal((await s.page("GET", r.json.booking.statusUrl)).json.booking.status, "cancelled");
  assert.deepEqual(s.mails("cancelled").map((x) => x.to), ["sam@example.com"]);
  assert.equal(s.mails("confirmed").length, 0);
});

test("a cancel frees the time at once, before Google and the snapshot catch up", async () => {
  const s = await hostReady();
  const slots = await s.slots();
  const r = await s.book(slots[2].start);
  await s.settle();
  s.advance(11 * MIN);
  await bookingQuarter(s.work);                           // the snapshot now holds the booking's event
  s.deps.defer = () => {};                                // Google's delete never happens here
  await s.page("POST", `/m/${ref(r.json.booking)}/cancel`, { body: {} });
  assert.ok((await s.slots()).some((x) => x.start === slots[2].start));
});

test("the page cache key changes with the host's name", async () => {
  const s = await hostReady();
  const { memoryPageCache } = await import("../src/booking/guard.js");
  s.deps.pageCache = memoryPageCache();
  await s.page("GET", "/noor/meeting", { cookies: new Map() });
  s.advance(1000);
  await s.call("PUT", "/v1/booking", { session: s.session, body: { handle: "noor", name: "Noor H." } });
  const after = await s.page("GET", "/noor/meeting", { cookies: new Map() });
  assert.match(after.headers.get("server-timing"), /cache;desc=miss/);
  assert.match(after.text, /Noor H\./);
});

test("reconcile reads no event per booking for calendars the snapshot didn't read", async () => {
  const s = await hostReady();
  const [first] = await s.slots();
  await s.book(first.start);
  await s.settle();
  await s.db.run("UPDATE bookings SET calendar_id = 'elsewhere@group.calendar.google.com'");
  const gets = s.google.booking.get.length;
  s.advance(11 * MIN);
  await bookingQuarter(s.work);
  assert.equal(s.google.booking.get.length, gets);
});

test("the page cache: a booking changes the key; every hit has its own nonce, the same in the page and its CSP", async () => {
  const s = await hostReady();
  const { memoryPageCache } = await import("../src/booking/guard.js");
  s.deps.pageCache = memoryPageCache();
  const nonceOf = (p) => [/'nonce-([^']+)'/.exec(p.headers.get("content-security-policy"))[1], /<script nonce="([^"]+)"/.exec(p.text)[1]];
  const one = await s.page("GET", "/noor/meeting", { cookies: new Map() });
  const two = await s.page("GET", "/noor/meeting", { cookies: new Map() });
  const three = await s.page("GET", "/noor/meeting", { cookies: new Map() });
  assert.match(two.headers.get("server-timing"), /cache;desc=fresh/);
  const [n2, h2] = nonceOf(two), [n3, h3] = nonceOf(three);
  assert.equal(n2, h2);
  assert.equal(n3, h3);
  assert.notEqual(n2, n3);
  assert.ok(!two.text.includes("__BOOKING_NONCE__"));
  const [first] = await s.slots();
  await s.book(first.start, { cookies: new Map() });
  const after = await s.page("GET", "/noor/meeting", { cookies: new Map() });
  assert.match(after.headers.get("server-timing"), /cache;desc=miss/);
  assert.match(one.headers.get("server-timing"), /cache;desc=miss/);
});

test("guest rows: nothing until a booking is made; a stranger typing someone's email changes nothing of theirs", async () => {
  const s = await hostReady();
  const slots = await s.slots();
  await s.book("2026-10-15T16:10:00.000Z", { email: "owner@example.com", cookies: new Map() });
  assert.equal(await s.count("guests"), 0, "a refused post makes no guest");
  await s.book(slots[0].start, { email: "owner@example.com", name: "Owner", phone: "+1 555 0100", cookies: new Map() });
  await s.settle();
  await s.db.run("UPDATE bookings SET status = 'cancelled'");
  await s.book(slots[3].start, { email: "owner@example.com", name: "Mallory", phone: "+1 555 6666", cookies: new Map() });
  assert.deepEqual({ ...(await s.db.first("SELECT name, phone FROM guests WHERE email = 'owner@example.com'")) }, { name: "Owner", phone: "+1 555 0100" });
});

test("without an email provider: no codes, and no 'we emailed you'", async () => {
  const s = await hostReady();
  s.email.enabled = false;
  assert.equal((await s.page("GET", "/b/code")).status, 404);
  assert.equal((await s.page("POST", "/b/code", { body: { email: "a@b.co" } })).status, 404);
  const [first, second] = await s.slots();
  await s.book(first.start);
  const again = await s.book(second.start, { key: "another-key-1" });
  assert.deepEqual(again.json, { already: true, emailed: false });
  await s.settle();
  assert.equal(s.mails("existing").length, 0);
});

test("Cloudflare Email Service: the binding gets the documented builder shape", async () => {
  const { cloudflareEmail, bookingEmail } = await import("../src/booking/email.js");
  const calls = [];
  const port = cloudflareEmail({ async send(m) { calls.push(m); return { messageId: "m-1" }; } });
  assert.equal(port.enabled, true);
  const message = bookingEmail("confirmed", {
    guest_email: "sam@example.com", guest_zone: "Europe/London", start_at: Date.UTC(2026, 9, 21, 19), end_at: Date.UTC(2026, 9, 21, 19, 30),
    type_title: "Meeting", hostName: "Noor", hostEmail: "noor@example.com", manageUrl: "https://book.test/m/x", place_kind: "meet", ics: "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n",
  }, { from: (await import("../src/config.js")).configFrom({}).emailFrom });
  assert.deepEqual(await port.send(message), { id: "m-1" });
  const [sent] = calls;
  assert.deepEqual(Object.keys(sent).sort(), ["attachments", "from", "html", "replyTo", "subject", "text", "to"]);
  assert.equal(sent.to, "sam@example.com");
  assert.deepEqual(sent.from, { email: "book@ce.bananatheapp.com", name: "Banana" });
  assert.equal(sent.replyTo, "noor@example.com");
  assert.deepEqual(Object.keys(sent.attachments[0]).sort(), ["content", "disposition", "filename", "type"]);
  assert.equal(atob(sent.attachments[0].content), "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n");
  assert.equal(sent.attachments[0].disposition, "attachment");
});

test(".ics: SEQUENCE goes up with each move, LAST-MODIFIED with each change", async () => {
  const s = await hostReady();
  const slots = await s.slots();
  const r = await s.book(slots[2].start);
  await s.settle();
  const ics = async () => (await s.page("GET", r.json.booking.icsUrl)).text;
  assert.match(await ics(), /SEQUENCE:0/);
  s.advance(MIN);
  await s.page("POST", `/m/${ref(r.json.booking)}/move`, { body: { start: slots[6].start } });
  const moved = await ics();
  assert.match(moved, /SEQUENCE:1/);
  assert.match(moved, new RegExp(`LAST-MODIFIED:${new Date(s.now()).toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "")}`));
});

test("perDay counts the whole host day, finished bookings too", async () => {
  const s = await hostReady();
  const clock = `${String(s.now()).padStart(13, "0")}.0001.phone`;
  await s.call("POST", "/v2/sync", { session: s.session, body: { device: "phone-0001", changes: [
    { type: "plan.bookingType", id: "t-one", set: { title: "One", slug: "one", perDay: 1, notice: 0 }, clocks: { title: clock, slug: clock, perDay: clock, notice: clock } },
  ] } });
  await s.settle();
  assert.equal((await s.slots("/noor/one"))[0].start.slice(0, 10), "2026-10-15");
  // This morning's, already over.
  await s.db.run(`INSERT INTO bookings (id, manage_id, account_id, type_id, type_title, start_at, end_at, block_start, block_end, status, invite, created_at, timed_at, updated_at)
    VALUES ('morning', 'morning-manage-id-0000', ?, 't-one', 'One', ?, ?, ?, ?, 'confirmed', 'sent', 1, 1, 1)`,
    s.account, s.now() - 4 * HOUR, s.now() - 3.5 * HOUR, s.now() - 4 * HOUR, s.now() - 3.5 * HOUR);
  assert.equal((await s.slots("/noor/one"))[0].start.slice(0, 10), "2026-10-16");
});

test("not me: the browser forgets who it was; the guest's account stays", async () => {
  const s = await hostReady();
  const [first] = await s.slots();
  await s.book(first.start);
  assert.ok(s.jar.has("__Host-bk"));
  assert.equal((await s.page("POST", "/b/not-me", { body: {} })).status, 204);
  assert.equal(s.jar.has("__Host-bk"), false);
  assert.equal(await s.count("sessions", "kind = 'guest'"), 0);
  assert.equal(await s.count("guests"), 1);
  assert.equal(pageData((await s.page("GET", "/noor/meeting")).text).g, null);
});

test("the host's pushes open the event: calendar and event ids in b, the event left out once it is deleted", async () => {
  const s = await hostReady();
  s.google.calendars.set("refresh-noor", [{ id: "noor@example.com", summary: "Noor", timeZone: "America/New_York", primary: true }]);
  s.advance(11 * MIN);
  await bookingQuarter(s.work);
  const slots = await s.slots();
  const r = await s.book(slots[2].start);
  await s.settle();
  const id = (await s.row()).id;
  assert.deepEqual(s.alerts().at(-1).payload, {
    aps: { alert: { title: "Booking", body: "Sam Lee booked Meeting, Thu 1:30 pm" }, sound: "default", "thread-id": "booking" },
    b: { k: "booking", cal: "noor@example.com", event: id, start: Date.parse(slots[2].start) },
  });
  const m = ref(r.json.booking);
  await s.page("POST", `/m/${m}/move`, { body: { start: slots[5].start } });
  await s.settle();
  assert.deepEqual(s.alerts().at(-1).payload.b, { k: "booking", cal: "noor@example.com", event: id, start: Date.parse(slots[5].start) });
  await s.page("POST", `/m/${m}/cancel`, { body: {} });
  await s.settle();
  assert.match(s.alerts().at(-1).payload.aps.alert.body, /cancelled/);
  assert.deepEqual(s.alerts().at(-1).payload.b, { k: "booking", cal: "noor@example.com", start: Date.parse(slots[5].start), cancelled: true });
});

// ---- security audit run-1 (needs-validation leads turned into regression tests) ----

test("code guesses sent together share the five tries: the right code past the fifth is refused", async () => {
  const s = await hostReady();
  await s.page("POST", "/b/code", { body: { email: "kim@example.com" }, cookies: new Map() });
  const kim = /^(\d{6})/.exec(s.mails("code").at(-1).subject)[1];
  const wrong = kim === "123456" ? "654321" : "123456";
  const limit = s.deps.limit;
  s.deps.limit = async () => true;   // the per-address limit is its own test; here the counter alone must hold
  const results = await Promise.all([
    ...Array.from({ length: 49 }, () => s.page("POST", "/b/code/verify", { body: { email: "kim@example.com", code: wrong }, cookies: new Map() })),
    s.page("POST", "/b/code/verify", { body: { email: "kim@example.com", code: kim }, cookies: new Map() }),
  ]);
  s.deps.limit = limit;
  assert.equal(results.at(-1).status, 400, "the right code came after the five tries were spent");
  assert.equal(Number((await s.db.first("SELECT attempts FROM email_codes WHERE email = 'kim@example.com'")).attempts), 5);
  assert.equal(await s.count("sessions", "kind = 'guest' AND verified_at IS NOT NULL"), 0);
});

test("code verification is rate limited per address like the code itself", async () => {
  const s = await hostReady();
  let last;
  for (let i = 0; i < 6; i++) last = await s.page("POST", "/b/code/verify", { body: { email: "kim@example.com", code: "000000" }, cookies: new Map() });
  assert.equal(last.status, 429);
});

test("the host's daily cap counts live bookings only: undone or cancelled rows cannot shut the page", async () => {
  const s = await hostReady();
  const slots = await s.slots();
  const t = s.now();
  const dead = Array.from({ length: 50 }, (_, i) => ({
    sql: `INSERT INTO bookings (id, manage_id, account_id, type_id, type_title, start_at, end_at, block_start, block_end, status, invite, undo_until,
            place_id, place_kind, guest_name, guest_email, guest_zone, idem_key, ip_hash, attempts, next_at, created_at, timed_at, updated_at, cancelled_by)
          SELECT 'dead-${i}', 'dead-manage-${String(i).padStart(14, "0")}', account_id, 'meeting', 'Meeting', ?, ?, ?, ?, 'cancelled', 'held', 0,
            'p', 'meet', 'A', 'attacker@example.com', 'UTC', 'dead-key-${i}', 'dead-ip', 0, 0, ?, ?, ?, 'undo' FROM booking_handles WHERE handle = 'noor'`,
    params: [t + HOUR, t + HOUR + 30 * MIN, t + HOUR, t + HOUR + 30 * MIN, t - MIN, t - MIN, t - MIN],
  }));
  await s.db.batch(dead);
  assert.equal(await s.count("bookings", "status = 'cancelled'"), 50);
  const victim = await s.book(slots[0].start, { email: "victim@example.com", cookies: new Map() });
  assert.equal(victim.status, 200, JSON.stringify(victim.json));
  // Live bookings do count.
  await s.db.run("UPDATE bookings SET status = 'confirmed' WHERE id LIKE 'dead-%'");
  const next = await s.book(slots[1].start, { email: "other@example.com", cookies: new Map() });
  assert.equal(next.status, 429);
});

test("an address that already holds a time is told once a day, however often someone types it", async () => {
  const s = await hostReady();
  const slots = await s.slots();
  // A time more than a day ahead, so it still stands after the clock moves a day.
  const far = slots.findIndex((x) => Date.parse(x.start) > s.now() + 2 * DAY);
  assert.equal((await s.book(slots[far].start, { email: "victim@example.com" })).status, 200);
  await s.settle();
  for (let i = 0; i < 4; i++) {
    const r = await s.book(slots[far + 1 + i].start, { email: "victim@example.com" });
    assert.equal(r.status, 409);
    assert.equal(r.json.already, true);
    s.advance(MIN);   // past the per-minute limiter window
  }
  await s.settle();
  assert.equal(s.mails("existing").length, 1);
  s.advance(DAY);
  const later = await s.slots();
  const again = await s.book(later.find((x) => Date.parse(x.start) > s.now() + 2 * DAY).start, { email: "victim@example.com" });
  assert.equal(again.status, 409);
  assert.equal(again.json.already, true);
  await s.settle();
  assert.equal(s.mails("existing").length, 2);
});

test("Turnstile without its secret refuses unknown browsers where the pages are deployed; TURNSTILE_SKIP=1 is for local runs only", async () => {
  const strict = await hostReady({ deps: { turnstile: undefined }, });
  // hostReady's setup() marks tests as local; a deployed Worker reads TURNSTILE_SKIP, unset there.
  const { createTurnstile } = await import("../src/booking/guard.js");
  const required = createTurnstile("", fetch, { required: true });
  assert.equal(required.enabled, false);
  assert.equal(required.missing, true);
  assert.equal(await required.verify("anything", "1.2.3.4"), false);
  const local = createTurnstile("", fetch, { required: false });
  assert.equal(await local.verify(undefined, "1.2.3.4"), true);
  strict.deps.turnstile = required;
  const slots = await strict.slots();
  const r = await strict.book(slots[0].start, { cookies: new Map() });
  assert.equal(r.status, 400);
  assert.equal(r.json.field, "turnstile");
});

test("what a stranger typed never becomes a verified guest's profile; a verified guest's zone changes only from a verified browser", async () => {
  const s = await hostReady();
  const slots = await s.slots();
  const mallory = new Map();
  assert.equal((await s.book(slots[0].start, { email: "owner@example.com", name: "Mallory", phone: "+1 555 6666", zone: "Asia/Tokyo", cookies: mallory })).status, 200);
  await s.settle();
  assert.deepEqual(await s.db.first("SELECT name, phone, zone FROM guests WHERE email = 'owner@example.com'"), { name: "Mallory", phone: "+1 555 6666", zone: "Asia/Tokyo" });
  const owner = new Map();
  await s.page("POST", "/b/code", { body: { email: "owner@example.com" }, cookies: owner });
  const code = /^(\d{6})/.exec(s.mails("code").at(-1).subject)[1];
  assert.equal((await s.page("POST", "/b/code/verify", { body: { email: "owner@example.com", code }, cookies: owner })).status, 204);
  const row = await s.db.first("SELECT name, phone, zone, verified_at FROM guests WHERE email = 'owner@example.com'");
  assert.deepEqual([row.name, row.phone, row.zone], [null, null, null], "the first proof of the email drops what strangers typed");
  assert.ok(row.verified_at);
  const g = pageData((await s.page("GET", "/noor/meeting", { cookies: owner })).text).g;
  assert.equal(g.state, "verified");
  assert.equal(g.name, null);
  // Mallory's browser is 'known' for the email, yet changes nothing of the verified guest.
  await s.db.run("UPDATE bookings SET status = 'cancelled'");
  assert.equal((await s.book(slots[3].start, { email: "owner@example.com", name: "Mallory", zone: "Pacific/Auckland", cookies: mallory })).status, 200);
  assert.deepEqual(await s.db.first("SELECT name, zone FROM guests WHERE email = 'owner@example.com'"), { name: null, zone: null });
  // The owner's own verified browser does.
  await s.db.run("UPDATE bookings SET status = 'cancelled'");
  assert.equal((await s.book(slots[4].start, { email: "owner@example.com", name: "Olive Owner", zone: "Europe/Paris", cookies: owner })).status, 200);
  assert.deepEqual(await s.db.first("SELECT name, zone FROM guests WHERE email = 'owner@example.com'"), { name: null, zone: null },
    "a verified session books under its own account without rewriting the profile (CONTRACT: details come from the proof)");
});

test("a guest's link to a Banana person ends with that person's Google account: no busy time after an unlink", async () => {
  const s = await hostReady();
  s.google.person("code-ann", "sub-ann", "ann@example.com", "refresh-ann");
  const ann = await s.signIn("code-ann", device("mac-00000001", { platform: "mac" }));
  await s.call("PUT", "/v1/booking", { session: ann.json.session, body: { handle: "ann-lee", timeZone: "America/New_York" } });
  await s.settle();
  s.google.events.set("primary-refresh-ann", [{ id: "ann1", status: "confirmed", start: { dateTime: "2026-10-16T14:00:00Z" }, end: { dateTime: "2026-10-16T15:00:00Z" } }]);
  await s.call("PUT", "/v1/booking", { session: ann.json.session, body: { handle: "ann-lee" } });
  s.advance(11 * MIN);
  await bookingQuarter(s.work);
  await s.page("POST", "/b/code", { body: { email: "ann@example.com" } });
  const code = /^(\d{6})/.exec(s.mails("code").at(-1).subject)[1];
  await s.page("POST", "/b/code/verify", { body: { email: "ann@example.com", code } });
  assert.equal((await s.page("GET", "/noor/meeting/slots")).json.busy.length, 1);
  assert.equal((await s.call("DELETE", "/v1/google", { session: ann.json.session, body: { email: "ann@example.com" } })).status, 204);
  assert.equal((await s.page("GET", "/noor/meeting/slots")).json.busy, null, "the former person's calendar is nobody else's business");
  assert.equal((await s.db.first("SELECT person_account_id FROM guests WHERE email = 'ann@example.com'")).person_account_id, null);
});

test("the manage page takes the per-address limit: no unbounded live Google reads from one link", async () => {
  const s = await hostReady();
  const slots = await s.slots();
  const r = await s.book(slots[0].start);
  await s.settle();
  const m = ref(r.json.booking);
  const n = s.google.booking.get.length;
  let refused = null;
  for (let i = 0; i < 125; i++) {
    const page = await s.page("GET", `/m/${m}`, { cookies: new Map() });
    if (page.status === 429) { refused = i; break; }
  }
  assert.ok(refused !== null && refused < 125, "the 120-a-minute limit holds");
  assert.ok(s.google.booking.get.length - n <= 120);
});

test("a header the client wrote is not the client's address: x-forwarded-for is ignored unless a proxy is trusted", async () => {
  const s = await hostReady();
  const slots = await s.slots();
  let last;
  for (let i = 0; i < 11; i++) {
    last = await s.page("POST", "/noor/meeting/book", { cookies: new Map(), headers: { "x-forwarded-for": `203.0.113.${i}` },
      body: { key: `fwd-${i}`, start: slots[i].start, name: "Sam", email: `a${i}@example.com`, zone: "Europe/London" } });
  }
  assert.equal(last.status, 429, "all eleven count against one address");
  const trusting = await hostReady({ config: { trustForwardedFor: true } });
  const ts = await trusting.slots();
  for (let i = 0; i < 11; i++) {
    last = await trusting.page("POST", "/noor/meeting/book", { cookies: new Map(), headers: { "x-forwarded-for": `203.0.113.${i}` },
      body: { key: `fwd-${i}`, start: ts[Math.min(i, ts.length - 1)].start, name: "Sam", email: `b${i}@example.com`, zone: "Europe/London" } });
  }
  assert.notEqual(last.status, 429, "behind a trusted proxy each forwarded address has its own window");
});

test("a stale snapshot whose Google reads keep failing is tried once a minute, not once per anonymous view (audit run-1, snapshot)", async () => {
  const s = await hostReady();
  s.google.failList = true;                 // one read fails each time: the old snapshot is kept, and stays stale
  s.advance(11 * MIN);
  const before = s.google.calls.refresh.length;
  for (let i = 0; i < 20; i++) {
    assert.equal((await s.page("GET", "/noor/meeting", { cookies: new Map() })).status, 200);
    await s.settle();
    s.advance(1000);
  }
  assert.equal(s.google.calls.refresh.length - before, 1, "one rebuild, however many views find the snapshot stale");
  s.advance(MIN + 1);                       // the claim is taken over once it is older than a minute
  await s.page("GET", "/noor/meeting", { cookies: new Map() });
  await s.settle();
  assert.equal(s.google.calls.refresh.length - before, 2, "tried again after a minute");
  s.google.failList = false;
  s.advance(MIN + 1);
  await s.page("GET", "/noor/meeting", { cookies: new Map() });
  await s.settle();
  const snap = await s.db.first("SELECT computed_at FROM busy_snapshot WHERE account_id = ?", s.account);
  assert.equal(Number(snap.computed_at), s.now(), "recovers when Google answers again");
});

test("pages that find no snapshot yet wait for the one build in flight instead of each building their own (audit run-1, snapshot)", async () => {
  const s = await hostReady({ handle: null });
  assert.equal((await s.call("PUT", "/v1/booking", { session: s.session, body: { handle: "noor", timeZone: "America/New_York" } })).status, 200);
  // The deferred first build has not run: five visitors arrive at once.
  const before = s.google.calls.refresh.length;
  const pages = await Promise.all(Array.from({ length: 5 }, () => s.page("GET", "/noor", { cookies: new Map() })));
  assert.deepEqual(pages.map((p) => p.status), [200, 200, 200, 200, 200]);
  assert.equal(s.google.calls.refresh.length - before, 1, "one build for five first views");
  assert.ok(Number((await s.db.first("SELECT computed_at FROM busy_snapshot WHERE account_id = ?", s.account)).computed_at) > 0);
});
