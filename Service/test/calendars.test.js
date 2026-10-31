import { test } from "node:test";
import assert from "node:assert/strict";
import { setup, device, pushToken, DAY, HOUR } from "./helpers.js";
import { runJob } from "../src/job.js";

/** The job's watch results; the daily link check has tests of its own. */
const job = async (deps) => { const { checked, ...rest } = await runJob(deps); return rest; };

async function signedIn(s) {
  s.google.person("c1", "sub-1", "ann@example.com");
  const ann = (await s.signIn("c1", device("phone-0001", { push: pushToken(1) }))).json;
  await s.call("PUT", "/v1/devices/ipad-0001", { body: { platform: "ipad", push: pushToken(2), pushEnv: "development", bundle: "app.banana.Banana.beta" }, session: ann.session });
  await s.call("PUT", "/v1/devices/mac-00000001", { body: { platform: "mac", push: null, pushEnv: "production", bundle: "app.banana.Banana" }, session: ann.session });
  return ann;
}
const calendars = (s, session, ids, email = "ann@example.com") => s.call("PUT", "/v1/google/calendars", { body: { email, ids }, session });
const notify = (s, channel, token, state = "exists") =>
  s.call("POST", "/v1/google/notify", { headers: { "x-goog-channel-id": channel, "x-goog-channel-token": token, "x-goog-resource-state": state, "x-goog-resource-id": "r" } });

test("calendars: watches made for new ids, stopped for ids no longer listed", async () => {
  const s = setup();
  const { session } = await signedIn(s);
  const r = await calendars(s, session, ["primary", "family@group.calendar.google.com", "primary"]);
  assert.deepEqual([r.status, r.json], [202, { watching: 2 }]);
  await s.settle();
  assert.deepEqual(s.google.calls.watch.map((w) => w.calendarId), ["primary", "family@group.calendar.google.com"]);
  const first = s.google.calls.watch[0];
  assert.equal(first.address, "https://service.test/v1/google/notify");
  assert.equal(first.ttlSeconds, 604800);
  assert.match(first.id, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  assert.equal(first.accessToken, "access-refresh-sub-1");
  assert.equal((await s.call("GET", "/v1/account", { session })).json.google[0].watching, 2);

  await calendars(s, session, ["primary", "work"]);
  await s.settle();
  assert.deepEqual(s.google.calls.watch.map((w) => w.calendarId), ["primary", "family@group.calendar.google.com", "work"]);
  assert.equal(s.google.calls.stop.length, 1);
  assert.equal(s.google.calls.stop[0].id, s.google.calls.watch[1].id);
  assert.deepEqual((await s.db.all("SELECT calendar_id FROM watches ORDER BY calendar_id")).map((w) => w.calendar_id), ["primary", "work"]);

  // Same list again: nothing asked of Google.
  await calendars(s, session, ["work", "primary"]);
  await s.settle();
  assert.equal(s.google.calls.watch.length, 3);

  assert.deepEqual((await calendars(s, session, ["x"], "someone@else.example")).json, { error: "unknown_google" });
  assert.equal((await calendars(s, session, Array.from({ length: 101 }, (_, i) => `c${i}`))).status, 400);
  assert.equal((await calendars(s, session, ["x".repeat(301)])).status, 400);
});

test("a watch Google refuses is remembered and retried by the job", async () => {
  const s = setup();
  const { session } = await signedIn(s);
  s.google.failWatch = true;
  await calendars(s, session, ["primary"]);
  await s.settle();
  const failed = await s.db.first("SELECT * FROM watches");
  assert.deepEqual([failed.status, failed.failures, failed.retry_at], ["failed", 1, s.now() + 15 * 60 * 1000]);
  assert.ok((await s.db.all("SELECT action FROM audit")).some((a) => a.action === "watch_failed"));
  s.google.failWatch = false;
  assert.deepEqual(await job(s.deps), { renewed: 0, retried: 0, failed: 0, refused: 0 }); // not yet: backoff
  s.advance(16 * 60 * 1000);
  assert.deepEqual(await job(s.deps), { renewed: 0, retried: 1, failed: 0, refused: 0 });
  assert.deepEqual((await s.db.all("SELECT status FROM watches")).map((w) => w.status), ["live"]);
});

test("notify: the right secret pushes every device with a push token; wrong secret, unknown channel and sync push nothing", async () => {
  const s = setup();
  const { session } = await signedIn(s);
  await calendars(s, session, ["primary"]);
  await s.settle();
  const watch = await s.db.first("SELECT channel_id, secret FROM watches");

  for (const [channel, token, state] of [[watch.channel_id, "wrong", "exists"], ["unknown", watch.secret, "exists"], [watch.channel_id, watch.secret, "sync"]]) {
    const r = await notify(s, channel, token, state);
    assert.equal(r.status, 200);
    await s.settle();
    assert.equal(s.apns.sends.length, 0);
  }
  assert.equal((await s.call("POST", "/v1/google/notify")).status, 200);

  assert.equal((await notify(s, watch.channel_id, watch.secret)).status, 200);
  await s.settle();
  assert.deepEqual(s.apns.sends.map((p) => [p.token, p.env, p.topic, p.collapseId]).sort(),
    [[pushToken(1), "production", "app.banana.Banana", "calendar"], [pushToken(2), "development", "app.banana.Banana.beta", "calendar"]]);
  assert.deepEqual(s.apns.sends[0].payload, { aps: { "content-available": 1 }, b: { k: "calendar" } });
});

test("notify: two notices within 3 s push once, a third after 3 s pushes again", async () => {
  const s = setup();
  const { session } = await signedIn(s);
  await calendars(s, session, ["primary", "family"]);
  await s.settle();
  const [a, b] = await s.db.all("SELECT channel_id, secret FROM watches");
  await notify(s, a.channel_id, a.secret);
  s.advance(1000);
  await notify(s, b.channel_id, b.secret);
  await s.settle();
  assert.equal(s.apns.sends.length, 2); // two devices, once
  s.advance(2500);
  await notify(s, a.channel_id, a.secret);
  await s.settle();
  assert.equal(s.apns.sends.length, 4);
});

test("APNs says the token is gone: the device's push token is cleared", async () => {
  const s = setup();
  const { session } = await signedIn(s);
  await calendars(s, session, ["primary"]);
  await s.settle();
  s.apns.answers.set(pushToken(1), { status: 410, reason: "Unregistered" });
  s.apns.answers.set(pushToken(2), { status: 400, reason: "DeviceTokenNotForTopic" });
  const w = await s.db.first("SELECT channel_id, secret FROM watches");
  await notify(s, w.channel_id, w.secret);
  await s.settle();
  assert.deepEqual((await s.db.all("SELECT id, push_token FROM devices ORDER BY id")).map((d) => [d.id, d.push_token]),
    [["ipad-0001", null], ["mac-00000001", null], ["phone-0001", null]]);
  // Other failures leave the token alone.
  await s.call("PUT", "/v1/devices/phone-0001", { body: { platform: "iphone", push: pushToken(1), pushEnv: "production", bundle: "app.banana.Banana" }, session });
  s.apns.answers.set(pushToken(1), { status: 429, reason: "TooManyRequests" });
  s.advance(5000);
  await notify(s, w.channel_id, w.secret);
  await s.settle();
  assert.equal((await s.db.first("SELECT push_token FROM devices WHERE id = 'phone-0001'")).push_token, pushToken(1));
});

test("the job renews a watch that ends within a day and leaves a fresh one alone", async () => {
  const s = setup();
  const { session } = await signedIn(s);
  await calendars(s, session, ["old"]);
  await s.settle();
  s.advance(3 * DAY);
  await calendars(s, session, ["old", "fresh"]);
  await s.settle();
  const before = await s.db.all("SELECT * FROM watches ORDER BY calendar_id");
  assert.equal(before.length, 2);
  s.advance(3.5 * DAY); // "old" ends in 12 h, "fresh" in 3.5 days

  const result = await job(s.deps);
  assert.deepEqual(result, { renewed: 1, retried: 0, failed: 0, refused: 0 });
  const after = await s.db.all("SELECT * FROM watches ORDER BY calendar_id");
  const oldBefore = before.find((w) => w.calendar_id === "old");
  const oldAfter = after.find((w) => w.calendar_id === "old");
  assert.equal(after.length, 2);
  assert.notEqual(oldAfter.channel_id, oldBefore.channel_id);
  assert.equal(oldAfter.expires_at, s.now() + 7 * DAY);
  assert.deepEqual(after.find((w) => w.calendar_id === "fresh"), before.find((w) => w.calendar_id === "fresh"));
  assert.deepEqual(s.google.calls.stop.map((c) => c.id), [oldBefore.channel_id]);
  // The new channel was opened before the old one stopped.
  assert.equal(s.google.calls.watch.at(-1).calendarId, "old");
  // Run again: nothing due.
  assert.deepEqual(await job(s.deps), { renewed: 0, retried: 0, failed: 0, refused: 0 });
  // Its notices now come on the new channel; the old one is unknown.
  await notify(s, oldBefore.channel_id, oldBefore.secret);
  await s.settle();
  assert.equal(s.apns.sends.length, 0);
});

test("a refused refresh marks the link refused, and the job stops trying until it's connected again", async () => {
  const s = setup();
  const { session } = await signedIn(s);
  await calendars(s, session, ["primary"]);
  await s.settle();
  s.google.refused.add("refresh-sub-1");
  s.advance(6.5 * DAY);
  assert.deepEqual(await job(s.deps), { renewed: 0, retried: 0, failed: 0, refused: 1 });
  const link = await s.db.first("SELECT status, refresh_token FROM google_links");
  assert.deepEqual([link.status, link.refresh_token], ["refused", null]);   // the token no longer works: forgotten
  assert.equal(await s.count("watches"), 0);
  assert.deepEqual((await s.db.all("SELECT action FROM audit WHERE action = 'google_refused'")).length, 1);
  // It was the account's only working link, so its sessions ended; the account stays.
  assert.equal((await s.call("GET", "/v1/account", { session })).status, 401);
  assert.equal(await s.count("sessions"), 0);
  assert.equal(await s.count("accounts"), 1);

  const refreshes = s.google.calls.refresh.length;
  s.advance(HOUR);
  assert.deepEqual(await job(s.deps), { renewed: 0, retried: 0, failed: 0, refused: 0 });
  assert.equal(s.google.calls.refresh.length, refreshes);

  // Connecting again (the old session is dead, so as a signed-out device) finds the same account,
  // with a new session; the app sends its calendars again and they are watched with the new token.
  const before = (await s.db.first("SELECT account_id FROM google_links")).account_id;
  s.google.person("again", "sub-1", "ann@example.com", "refresh-sub-1-new");
  const r = await s.signIn("again", device("phone-0001", { push: pushToken(1) }), session);
  assert.equal(r.json.account.id, before);
  assert.ok(r.json.session);
  assert.deepEqual(r.json.account.google.map((g) => g.status), ["ok"]);
  await calendars(s, r.json.session, ["primary"]);
  await s.settle();
  assert.equal(s.google.calls.watch.at(-1).accessToken, "access-refresh-sub-1-new");
});

test("once a day the job asks Google about each working link; a refusal of one of two keeps the sessions", async () => {
  const s = setup();
  s.google.person("c1", "sub-1", "ann@example.com");
  s.google.person("c2", "sub-2", "ann@work.example");
  const { session } = (await s.signIn("c1", device("phone-0001"))).json;
  await s.signIn("c2", device("phone-0001"), session);
  assert.equal((await runJob(s.deps)).checked, 2);
  assert.equal((await runJob(s.deps)).checked, 0);          // checked within the day
  s.advance(DAY + HOUR);
  s.google.refused.add("refresh-sub-2");
  const result = await runJob(s.deps);
  assert.deepEqual([result.checked, result.refused], [1, 1]);
  assert.deepEqual((await s.db.all("SELECT sub, status FROM google_links ORDER BY sub")).map((l) => l.status), ["ok", "refused"]);
  // Ann still has a working link, so she stays signed in.
  assert.equal((await s.call("GET", "/v1/account", { session })).status, 200);
  assert.equal(await s.count("sessions"), 1);

  // The last working link refused too: the sessions end, nothing else is deleted.
  s.advance(DAY + HOUR);
  s.google.refused.add("refresh-sub-1");
  assert.equal((await runJob(s.deps)).refused, 1);
  assert.equal((await s.call("GET", "/v1/account", { session })).status, 401);
  assert.deepEqual([await s.count("accounts"), await s.count("google_links"), await s.count("devices")], [1, 2, 1]);
  assert.ok((await s.db.all("SELECT action FROM audit")).some((a) => a.action === "signed_out"));
});

const identity = (s, token, dev, session) => s.call("POST", "/v1/google/identity", { body: { idToken: token, device: dev }, session });

test("a device signs in by its Google identity token, with nothing for the person to do", async () => {
  const s = setup();
  s.google.identity("t-ann", "sub-1", "ann@example.com");
  s.google.identity("t-work", "sub-2", "ann@work.example");
  const r = await identity(s, "t-ann", device("phone-0001", { push: pushToken(1) }));
  assert.equal(r.status, 200);
  assert.ok(r.json.session);
  assert.deepEqual(r.json.account.google, [{ email: "ann@example.com", status: "ok", watching: 0, access: false }], "no Google access of the service's own yet");
  // Her second Google account links to the same account from the signed-in device.
  const second = await identity(s, "t-work", device("phone-0001"), r.json.session);
  assert.deepEqual(second.json.account.google.map((g) => g.email), ["ann@example.com", "ann@work.example"]);
  // The Mac, signed out, finds the same account by the same Google account.
  const mac = await identity(s, "t-ann", device("mac-00000001", { platform: "mac" }));
  assert.equal(mac.json.account.id, r.json.account.id);
  assert.equal(s.google.calls.exchange, 0);
  assert.deepEqual((await identity(s, "forged", device("phone-0002"))).json, { error: "google_refused" });

  // No Google permission of the service's own: the daily check leaves the links alone.
  s.advance(2 * DAY);
  await runJob(s.deps);
  assert.deepEqual((await s.db.all("SELECT status FROM google_links")).map((l) => l.status), ["ok", "ok"]);
  assert.equal((await s.call("GET", "/v1/account", { session: r.json.session })).status, 200);
});

test("devices open, renew and close their own calendar watches; notices push as before", async () => {
  const s = setup();
  s.google.identity("t-ann", "sub-1", "ann@example.com");
  const { session } = (await identity(s, "t-ann", device("phone-0001", { push: pushToken(1) }))).json;
  const open = await s.call("POST", "/v1/google/channels", { body: { email: "Ann@Example.com", calendarId: "primary" }, session });
  assert.equal(open.status, 201);
  assert.equal(open.json.address, "https://service.test/v1/google/notify");
  assert.equal(open.json.ttlSeconds, 604800);
  const { id, token } = open.json;
  // Not live until the device reports Google's answer.
  assert.equal((await s.call("PUT", `/v1/google/channels/${id}`, { body: { resourceId: "r1", expiration: s.now() - 1 }, session })).status, 400);
  assert.equal((await s.call("PUT", `/v1/google/channels/${id}`, { body: { resourceId: "r1", expiration: s.now() + 7 * DAY }, session })).status, 204);
  const listed = (await s.call("GET", "/v1/google/channels", { session })).json.channels;
  assert.deepEqual(listed.map((c) => [c.email, c.calendarId, c.status, c.resourceId]), [["ann@example.com", "primary", "live", "r1"]]);

  // Google's notice is checked against the secret and pushed.
  await s.call("POST", "/v1/google/notify", { headers: { "x-goog-channel-id": id, "x-goog-channel-token": token, "x-goog-resource-state": "exists" } });
  await s.settle();
  assert.equal(s.apns.sends.length, 1);
  assert.equal((await s.call("POST", "/v1/google/notify", { headers: { "x-goog-channel-id": id, "x-goog-channel-token": "wrong", "x-goog-resource-state": "exists" } })).status, 200);

  // Unknown Google accounts can't get channels; other accounts can't touch them.
  assert.equal((await s.call("POST", "/v1/google/channels", { body: { email: "bob@example.com", calendarId: "x" }, session })).status, 404);
  s.google.identity("t-bob", "sub-9", "bob@example.com");
  const bob = (await identity(s, "t-bob", device("phone-0009"))).json.session;
  assert.equal((await s.call("PUT", `/v1/google/channels/${id}`, { body: { resourceId: "r2", expiration: s.now() + DAY }, session: bob })).status, 404);
  await s.call("DELETE", `/v1/google/channels/${id}`, { session: bob });
  assert.equal(await s.count("watches"), 1);

  // An ended channel and an unconfirmed one are forgotten by the job; closing removes one at once.
  const stale = (await s.call("POST", "/v1/google/channels", { body: { email: "ann@example.com", calendarId: "family" }, session })).json.id;
  s.advance(8 * DAY);
  await runJob(s.deps);
  assert.equal(await s.count("watches"), 0, `${stale} and ${id} are gone`);
  const again = (await s.call("POST", "/v1/google/channels", { body: { email: "ann@example.com", calendarId: "primary" }, session })).json.id;
  assert.equal((await s.call("DELETE", `/v1/google/channels/${again}`, { session })).status, 204);
  assert.equal(await s.count("watches"), 0);
});

test("each push is recorded on the device: when, and what APNs said", async () => {
  const s = setup();
  const { session } = await signedIn(s);
  await calendars(s, session, ["primary"]);
  await s.settle();
  const w = await s.db.first("SELECT channel_id, secret FROM watches");
  s.apns.answers.set(pushToken(2), { status: 410, reason: "Unregistered" });
  await notify(s, w.channel_id, w.secret);
  await s.settle();
  const rows = await s.db.all("SELECT id, pushed_at, push_status, push_token FROM devices ORDER BY id");
  assert.deepEqual(rows.map((d) => [d.id, d.pushed_at, d.push_status, d.push_token]), [
    ["ipad-0001", s.now(), "410 Unregistered", null],
    ["mac-00000001", null, null, null],               // no token: nothing sent, nothing recorded
    ["phone-0001", s.now(), "200", pushToken(1)],
  ]);
});

test("the job forgets a device without a push token after a month, never one that has one", async () => {
  const s = setup();
  const { session } = await signedIn(s);
  // mac-00000001 has no push token; the phone and iPad do.
  s.advance(31 * DAY);
  await job(s.deps);
  assert.deepEqual((await s.db.all("SELECT id FROM devices ORDER BY id")).map((d) => d.id), ["ipad-0001", "phone-0001"]);
  // A device seen within the month stays, token or not.
  await s.call("PUT", "/v1/devices/mac-00000001", { body: { platform: "mac", push: null, pushEnv: "production", bundle: "app.banana.Banana" }, session });
  s.advance(29 * DAY);
  await job(s.deps);
  assert.equal(await s.count("devices"), 3);
});

test("a device's channels: at most a week ahead, at most a hundred open, and a burst of notices reads the calendar once a minute (audit run-1)", async () => {
  const s = setup();
  s.google.person("c1", "sub-1", "ann@example.com");
  const { session } = (await s.signIn("c1", device("phone-0001", { push: pushToken(1) }))).json;
  const open = (await s.call("POST", "/v1/google/channels", { body: { email: "ann@example.com", calendarId: "ann@example.com" }, session })).json;
  // Not Google's answer: a channel that never ends.
  assert.equal((await s.call("PUT", `/v1/google/channels/${open.id}`, { body: { resourceId: "r", expiration: s.now() + 365 * DAY }, session })).status, 400);
  assert.equal((await s.call("PUT", `/v1/google/channels/${open.id}`, { body: { resourceId: "r", expiration: s.now() + 6 * DAY }, session })).status, 204);
  // A hundred channels, then no more.
  let last;
  for (let i = 0; i < 100; i++) last = await s.call("POST", "/v1/google/channels", { body: { email: "ann@example.com", calendarId: `cal-${i}` }, session });
  assert.equal(last.status, 409);
  assert.equal(last.json.error, "too_many_channels");
  assert.equal(await s.count("watches", "managed_by = 'device'"), 100);
  // A burst of notices: the first thirty in a minute read; the rest mark the calendar, which the dispatcher reads.
  s.google.events.set("ann@example.com", []);
  const { dispatchAlerts } = await import("../src/events.js");
  for (let i = 0; i < 35; i++) await notify(s, open.id, open.token);
  await s.settle();
  const reads = s.google.listCalls.filter((c) => c.calendarId === "ann@example.com").length;
  assert.ok(reads <= 30, `reads ${reads}`);
  assert.ok((await s.db.first("SELECT dirty_at FROM watches WHERE channel_id = ?", open.id)).dirty_at, "marked for the dispatcher");
  await dispatchAlerts(s.deps, async () => {});
  assert.equal((await s.db.first("SELECT dirty_at FROM watches WHERE channel_id = ?", open.id)).dirty_at, null);
  assert.equal(s.google.listCalls.filter((c) => c.calendarId === "ann@example.com").length, reads + 1);
});

test("calendar lists: so many changes a minute, one service watch per calendar when two changes race, and the job renews so many a run (audit run-1)", async () => {
  const s = setup();
  const { session } = await signedIn(s);
  // Two changes announce the same new calendar before either reconcile has run: one channel stays.
  const [a, b] = await Promise.all([calendars(s, session, ["primary"]), calendars(s, session, ["primary"])]);
  assert.deepEqual([a.status, b.status], [202, 202]);
  await s.settle();
  assert.equal(await s.count("watches", "calendar_id = 'primary'"), 1);
  assert.equal(s.google.calls.watch.length - s.google.calls.stop.length, 1, "the losing channel is closed at Google");
  // The sixth change in a minute is the last; the seventh waits.
  let last;
  for (let i = 0; i < 5; i++) last = await calendars(s, session, ["primary", `cal-${i}`]);
  assert.equal(last.status, 429);
  await s.settle();
  // Renewal keeps the one-row-per-calendar rule: the new channel replaces the old row.
  s.advance(6 * DAY + 2 * HOUR);
  const before = (await s.db.first("SELECT channel_id FROM watches WHERE calendar_id = 'primary'")).channel_id;
  await runJob(s.deps);
  const after = await s.db.all("SELECT channel_id FROM watches WHERE calendar_id = 'primary'");
  assert.equal(after.length, 1);
  assert.notEqual(after[0].channel_id, before);
  // A pile of failed rows is retried two hundred at a time.
  const t = s.now();
  await s.db.run(`INSERT INTO watches (channel_id, account_id, google_sub, calendar_id, resource_id, secret, expires_at, status, failures, retry_at, created_at)
    WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 250)
    SELECT 'ch-' || i, (SELECT account_id FROM watches LIMIT 1), 'sub-1', 'pile-' || i, NULL, 'secret', NULL, 'failed', 1, NULL, ? FROM n`, t);
  const watchesBefore = s.google.calls.watch.length;
  await runJob(s.deps);
  assert.equal(s.google.calls.watch.length - watchesBefore, 200);
  assert.equal(await s.count("watches", "status = 'failed'"), 50);
});

test("refused calendars: a flood of unreadable ids leaves one audit row an hour, and a calendar refused fourteen times is given up (audit run-1)", async () => {
  const s = setup();
  const { session } = await signedIn(s);
  s.google.failWatch = true;
  for (let round = 0; round < 3; round++) {
    assert.equal((await calendars(s, session, Array.from({ length: 100 }, (_, i) => `r${round}-c${i}`))).status, 202);
    await s.settle();
    assert.equal(await s.count("watches", "status = 'failed'"), 100);
  }
  assert.equal(await s.count("audit", "action = 'watch_failed'"), 1, "one row an hour, not one per calendar");
  s.advance(2 * HOUR);
  await runJob(s.deps);
  assert.equal(await s.count("audit", "action = 'watch_failed'"), 2);
  // Two weeks of daily refusals: the rows go, and the job has nothing left to try.
  for (let day = 0; day < 16; day++) { s.advance(DAY + HOUR); await runJob(s.deps); }
  assert.equal(await s.count("watches"), 0);
  const before = s.google.calls.watch.length;
  s.advance(DAY + HOUR);
  await runJob(s.deps);
  assert.equal(s.google.calls.watch.length, before);
});
