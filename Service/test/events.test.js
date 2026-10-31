import { test } from "node:test";
import assert from "node:assert/strict";
import { setup, device, pushToken, HOUR, DAY } from "./helpers.js";
import { dispatchAlerts, dirtyReads, MOST_EVENTS_PER_READ } from "../src/events.js";
import { GoogleError } from "../src/google.js";

const MIN = 60 * 1000;
const iso = (ms) => new Date(ms).toISOString();
const timed = (id, start, overrides = {}) => ({
  id, summary: "Standup", status: "confirmed", start: { dateTime: iso(start) }, end: { dateTime: iso(start + 30 * MIN) },
  creator: { email: "ann@example.com", self: true }, organizer: { email: "ann@example.com", self: true }, ...overrides,
});
const notify = (s, channel, token) =>
  s.call("POST", "/v1/google/notify", { headers: { "x-goog-channel-id": channel, "x-goog-channel-token": token, "x-goog-resource-state": "exists" } });

/** Ann signs in with a code (the service has access), two devices with tokens, one live watch on her calendar. */
async function ready(s) {
  s.google.person("c1", "sub-1", "ann@example.com");
  const { session } = (await s.signIn("c1", device("phone-0001", { push: pushToken(1) }))).json;
  await s.call("PUT", "/v1/devices/mac-00000001", { body: { platform: "mac", push: pushToken(2), pushEnv: "development", bundle: "app.banana.Banana" }, session });
  for (const id of ["phone-0001", "mac-00000001"]) await s.call("PUT", "/v1/alerts/held", { body: { device: id, ids: [], calendars: ["ann@example.com"] }, session });
  await s.call("PUT", "/v1/account/alerts", { body: { leads: [5, 0], timeZone: "UTC" }, session });
  const open = (await s.call("POST", "/v1/google/channels", { body: { email: "ann@example.com", calendarId: "ann@example.com" }, session })).json;
  await s.call("PUT", `/v1/google/channels/${open.id}`, { body: { resourceId: "r1", expiration: s.now() + 6 * DAY }, session });
  return { session, channel: open.id, token: open.token };
}
const visible = (s) => s.apns.sends.filter((p) => p.pushType === "alert");

test("a notice reads the calendar with the link's token, plans lead alerts, and the first read rings for nothing", async () => {
  const s = setup();
  const { session, channel, token } = await ready(s);
  s.google.events.set("ann@example.com", [timed("e1", s.now() + 2 * HOUR), timed("e2", s.now() + 3 * MIN)]);
  await notify(s, channel, token);
  await s.settle();
  assert.deepEqual(s.google.listCalls.map((c) => [c.calendarId, Boolean(c.syncToken)]), [["ann@example.com", false]]);
  assert.equal((await s.db.first("SELECT sync_token FROM calendar_sync")).sync_token, "tok-1");
  const alerts = await s.db.all("SELECT id, kind, status, due_at FROM alerts ORDER BY due_at");
  assert.deepEqual(alerts.map((a) => [a.id, a.kind, a.status]), [
    ["ann@example.com|e2|0", "lead", "pending"],          // 3 minutes out: its at-start alert still ahead, no 'now' on a baseline
    ["ann@example.com|e1|5", "lead", "pending"],
    ["ann@example.com|e1|0", "lead", "pending"],
  ]);
  assert.equal(visible(s).length, 0);
  assert.equal(await s.count("event_state"), 2);
  // Without access (an identity-only link) nothing is read.
  const t = setup();
  t.google.identity("t-bob", "sub-2", "bob@example.com");
  const bob = (await t.call("POST", "/v1/google/identity", { body: { idToken: "t-bob", device: device("phone-0002", { push: pushToken(3) }) } })).json;
  const o = (await t.call("POST", "/v1/google/channels", { body: { email: "bob@example.com", calendarId: "bob@example.com" }, session: bob.session })).json;
  await t.call("PUT", `/v1/google/channels/${o.id}`, { body: { resourceId: "r", expiration: t.now() + DAY }, session: bob.session });
  await notify(t, o.id, o.token);
  await t.settle();
  assert.equal(t.google.listCalls.length, 0);
});

test("the dispatcher sends a lead alert at its second to the devices that don't hold it, once; a sync read reads only changes", async () => {
  const s = setup();
  const { session, channel, token } = await ready(s);
  s.google.events.set("ann@example.com", [timed("e1", s.now() + 10 * MIN)]);
  await notify(s, channel, token);
  await s.settle();
  // The phone holds its own copy of the 5-minute alert; the Mac holds nothing.
  await s.call("PUT", "/v1/alerts/held", { body: { device: "phone-0001", ids: ["ann@example.com|e1|5"], calendars: ["ann@example.com"] }, session });

  const slept = [];
  const sleep = async (ms) => { slept.push(ms); s.advance(ms); };
  assert.deepEqual((await dispatchAlerts(s.deps, sleep)).due, 0);     // 5 minutes out: not within the minute
  s.advance(4 * MIN + 30 * 1000);
  const r = await dispatchAlerts(s.deps, sleep);
  assert.deepEqual([r.due, slept], [1, [30 * 1000]]);                   // waited to the exact second
  const sent = visible(s);
  assert.deepEqual(sent.map((p) => [p.token, p.priority, p.payload.aps.alert.body, p.payload.b.id]),
    [[pushToken(2), 10, "Starts in 5 minutes, at 12:10 PM.", "ann@example.com|e1|5"]]);
  assert.equal(sent[0].payload.aps.category, "EVENT_ALERT");
  assert.equal((await s.db.first("SELECT status FROM alerts WHERE id = 'ann@example.com|e1|5'")).status, "sent");
  // Again: nothing more for that id.
  await dispatchAlerts(s.deps, sleep);
  assert.equal(visible(s).length, 1);

  // Ann moves the meeting an hour later: the next notice is a sync read; pending alerts are re-planned.
  s.google.changed.set("ann@example.com", [timed("e1", s.now() + 70 * MIN)]);
  await notify(s, channel, token);
  await s.settle();
  assert.equal(s.google.listCalls.at(-1).syncToken, "tok-1");
  const rows = await s.db.all("SELECT id, status, due_at FROM alerts ORDER BY id");
  assert.deepEqual(rows.map((a) => [a.id, a.status]), [["ann@example.com|e1|0", "pending"], ["ann@example.com|e1|5", "sent"]]);
  assert.equal(rows[0].due_at, s.now() + 70 * MIN);
  // A gone sync token: read in full again, no ring for what is already known.
  s.google.tokenGone = true;
  s.google.events.set("ann@example.com", [timed("e1", s.now() + 70 * MIN)]);
  await notify(s, channel, token);
  await s.settle();
  assert.equal(s.google.listCalls.at(-1).timeMin !== undefined, true);
  assert.equal(visible(s).length, 1);
});

test("someone else's new meeting rings at once on every device; cleared on one, cleared on the others", async () => {
  const s = setup();
  const { session, channel, token } = await ready(s);
  s.google.events.set("ann@example.com", []);
  await notify(s, channel, token);                        // the baseline
  await s.settle();
  s.advance(5000);
  s.google.changed.set("ann@example.com", [timed("e9", s.now() + 2 * DAY, { creator: { email: "bob@y.com", displayName: "Bob" } })]);
  await notify(s, channel, token);
  await s.settle();
  const rang = visible(s);
  assert.deepEqual(rang.map((p) => [p.token, p.payload.b.kind]).sort(), [[pushToken(1), "changed"], [pushToken(2), "changed"]]);
  assert.match(rang[0].payload.aps.alert.body, /^Added by Bob · /);
  assert.equal((await s.db.first("SELECT status FROM alerts WHERE kind = 'changed'")).status, "sent");
  assert.equal(await s.count("alerts", "kind = 'lead' AND status = 'pending'"), 2);

  // Dismissed on the phone: the Mac is told to take it down.
  const before = s.apns.sends.length;
  const r = await s.call("POST", "/v1/alerts/clear", { body: { id: "ann@example.com|e9|changed", device: "phone-0001" }, session });
  assert.deepEqual(r.json, { cleared: true, told: 1 });
  const clear = s.apns.sends[before];
  assert.deepEqual([clear.token, clear.pushType ?? "background", clear.payload], [pushToken(2), "background", { aps: { "content-available": 1 }, b: { k: "alert-clear", id: "ann@example.com|e9|changed" } }]);
  // Clearing the 'changed' alert leaves the lead alerts pending.
  assert.equal(await s.count("alerts", "kind = 'lead' AND status = 'pending'"), 2);
  // A day later the dispatcher sweeps what was sent or cleared.
  s.advance(DAY + MIN);
  await dispatchAlerts(s.deps, async () => {});
  assert.equal(await s.count("alerts", "status IN ('sent', 'cleared')"), 0);
});

test("held ids belong to the account's own device; bad leads are refused", async () => {
  const s = setup();
  const { session } = await ready(s);
  assert.equal((await s.call("PUT", "/v1/alerts/held", { body: { device: "someone-else", ids: ["x"] }, session })).status, 404);
  assert.equal((await s.call("PUT", "/v1/alerts/held", { body: { device: "phone-0001", ids: ["a", "a", "b"] }, session })).status, 204);
  assert.equal(await s.count("held_alerts"), 2);
  assert.equal((await s.call("PUT", "/v1/account/alerts", { body: { leads: [5, -1] }, session })).status, 400);
  assert.equal((await s.call("PUT", "/v1/account/alerts", { body: { leads: [15, 0] }, session })).status, 204);
  assert.deepEqual(JSON.parse((await s.db.first("SELECT alert_leads FROM accounts")).alert_leads), [15, 0]);
});

test("a device that never reported what it holds (an older build) gets no alert and no clear", async () => {
  const s = setup();
  const { session, channel, token } = await ready(s);
  await s.call("PUT", "/v1/devices/ipad-0000001", { body: { platform: "ipad", push: pushToken(3), pushEnv: "development", bundle: "app.banana.Banana" }, session });
  s.google.events.set("ann@example.com", []);
  await notify(s, channel, token);
  await s.settle();
  s.advance(5000);
  s.google.changed.set("ann@example.com", [timed("e9", s.now() + DAY, { creator: { email: "bob@y.com", displayName: "Bob" } })]);
  await notify(s, channel, token);
  await s.settle();
  assert.deepEqual(visible(s).map((p) => p.token).sort(), [pushToken(1), pushToken(2)]);
  const before = s.apns.sends.length;
  const r = await s.call("POST", "/v1/alerts/clear", { body: { id: "ann@example.com|e9|changed", device: "phone-0001" }, session });
  assert.deepEqual(r.json, { cleared: true, told: 1 });
  assert.deepEqual(s.apns.sends.slice(before).map((p) => p.token), [pushToken(2)]);
});

test("with event alerts off the service reads no event and the dispatcher sends nothing", async () => {
  const s = setup();
  s.deps.config.eventAlerts = false;
  const { channel, token } = await ready(s);
  s.google.events.set("ann@example.com", [timed("e1", s.now() + 2 * MIN)]);
  await notify(s, channel, token);
  await s.settle();
  assert.equal(s.google.listCalls.length, 0);
  assert.equal(await s.count("alerts"), 0);
});

test("what was read for alerts goes with the last watch of its calendar, with the link, and with the account", async () => {
  const read = async (s, channel, token) => {
    s.google.events.set("ann@example.com", [timed("e1", s.now() + 2 * HOUR)]);
    await notify(s, channel, token);
    await s.settle();
  };
  const held = async (s) => Promise.all(["alerts", "event_state", "calendar_sync"].map((t) => s.count(t)));

  // The device closes its only channel on the calendar.
  let s = setup();
  let r = await ready(s);
  await read(s, r.channel, r.token);
  assert.deepEqual(await held(s), [2, 1, 1]);
  await s.call("DELETE", `/v1/google/channels/${r.channel}`, { session: r.session });
  assert.deepEqual(await held(s), [0, 0, 0]);

  // The Google account is disconnected.
  s = setup();
  r = await ready(s);
  await read(s, r.channel, r.token);
  assert.equal((await s.call("DELETE", "/v1/google", { body: { email: "ann@example.com" }, session: r.session })).status, 204);
  assert.deepEqual(await held(s), [0, 0, 0]);

  // The account is deleted: everything goes, held alerts included, and the foreign keys hold.
  s = setup();
  r = await ready(s);
  await read(s, r.channel, r.token);
  await s.call("PUT", "/v1/alerts/held", { body: { device: "phone-0001", ids: ["ann@example.com|e1|5"], calendars: ["ann@example.com"] }, session: r.session });
  s.google.person("fresh", "sub-1", "ann@example.com");
  assert.equal((await s.call("DELETE", "/v1/account", { body: { code: "fresh" }, session: r.session })).status, 204);
  assert.deepEqual([...await held(s), await s.count("held_alerts"), await s.count("accounts")], [0, 0, 0, 0, 0]);
});

test("a watched calendar never read is read silently within the minute, so its first change rings", async () => {
  const s = setup();
  const { channel, token } = await ready(s);
  s.google.events.set("ann@example.com", [timed("e1", s.now() + 2 * HOUR, { creator: { email: "bob@y.com", displayName: "Bob" } })]);
  const r = await dispatchAlerts(s.deps, async () => {});
  assert.equal(r.first, 1);
  assert.equal(visible(s).length, 0);                                   // what was there rings for nothing
  assert.equal(await s.count("alerts", "kind = 'lead' AND status = 'pending'"), 2);
  assert.equal((await dispatchAlerts(s.deps, async () => {})).first, 0); // read once
  // The very first notice is already a change: Bob's new meeting rings.
  s.advance(5000);
  s.google.changed.set("ann@example.com", [timed("e2", s.now() + DAY, { creator: { email: "bob@y.com", displayName: "Bob" } })]);
  await notify(s, channel, token);
  await s.settle();
  assert.deepEqual(visible(s).map((p) => p.payload.b.kind), ["changed", "changed"]);
});

const dispatch = (s) => dispatchAlerts(s.deps, async () => {});
/** A second watched calendar of Ann's (a team calendar), read once. */
async function second(s, session, calendarId) {
  const open = (await s.call("POST", "/v1/google/channels", { body: { email: "ann@example.com", calendarId }, session })).json;
  await s.call("PUT", `/v1/google/channels/${open.id}`, { body: { resourceId: `r-${calendarId}`, expiration: s.now() + 6 * DAY }, session });
  return open;
}

test("a device rings only for the calendars it says it alerts for and not for an event it skips; one that hasn't said gets nothing", async () => {
  const s = setup();
  const { session, channel, token } = await ready(s);
  const launches = await second(s, session, "launches@group");
  for (const [ch, cal] of [[{ id: channel, token }, "ann@example.com"], [launches, "launches@group"]]) {
    s.google.events.set(cal, []);
    await notify(s, ch.id, ch.token);
    await s.settle();
  }
  // The phone skips e2; the Mac reports like build 60, without its calendars.
  await s.call("PUT", "/v1/alerts/held", { body: { device: "phone-0001", ids: [], calendars: ["ann@example.com"], quiet: ["ann@example.com|e2"] }, session });
  await s.call("PUT", "/v1/alerts/held", { body: { device: "mac-00000001", ids: [] }, session });
  s.advance(5000);
  const bob = { creator: { email: "bob@y.com", displayName: "Bob" } };
  s.google.changed.set("ann@example.com", [timed("e1", s.now() + DAY, bob), timed("e2", s.now() + DAY + HOUR, bob)]);
  s.google.changed.set("launches@group", [timed("l1", s.now() + DAY, bob)]);
  for (const ch of [{ id: channel, token }, launches]) await notify(s, ch.id, ch.token);
  await s.settle();
  assert.deepEqual(visible(s).map((p) => [p.token, p.payload.b.id]), [[pushToken(1), "ann@example.com|e1|changed"]]);
  // And clears go only to devices that have said.
  const before = s.apns.sends.length;
  assert.deepEqual((await s.call("POST", "/v1/alerts/clear", { body: { id: "ann@example.com|e1|changed", device: "mac-00000001" }, session })).json, { cleared: true, told: 1 });
  assert.deepEqual(s.apns.sends.slice(before).map((p) => p.token), [pushToken(1)]);
  assert.equal((await s.call("PUT", "/v1/alerts/held", { body: { device: "phone-0001", ids: [], calendars: "all" }, session })).status, 400);
});

test("the same meeting on two calendars rings once on a device: not where it holds the other copy, not twice from the service", async () => {
  const s = setup();
  const { session, channel, token } = await ready(s);
  const work = await second(s, session, "ann@work.example");
  const start = s.now() + 20 * MIN;
  s.google.events.set("ann@example.com", [timed("a1", start, { summary: "Design review" })]);
  s.google.events.set("ann@work.example", [timed("w1", start, { summary: "design  Review" })]);
  for (const ch of [{ id: channel, token }, work]) await notify(s, ch.id, ch.token);
  await s.settle();
  // The phone holds its own 5-minute alert for the work copy; the Mac holds nothing.
  const calendars = ["ann@example.com", "ann@work.example"];
  await s.call("PUT", "/v1/alerts/held", { body: { device: "phone-0001", ids: ["ann@work.example|w1|5"], calendars }, session });
  await s.call("PUT", "/v1/alerts/held", { body: { device: "mac-00000001", ids: [], calendars }, session });
  s.advance(start - 5 * MIN - s.now());
  await dispatch(s);
  assert.deepEqual(visible(s).map((p) => p.token), [pushToken(2)]);   // the Mac, once; the phone rings its own
  s.advance(5 * MIN);
  await dispatch(s);
  assert.deepEqual(visible(s).map((p) => [p.token, p.payload.b.id.endsWith("|0")]).slice(1).sort(), [[pushToken(1), true], [pushToken(2), true]]);
});

test("nothing waits more than a month ahead: years of a changed series plan nothing, and the daily plan picks events up as they come within the month", async () => {
  const s = setup();
  const { channel, token } = await ready(s);
  const far = timed("f1", s.now() + 40 * DAY);
  s.google.events.set("ann@example.com", [far]);
  await notify(s, channel, token);
  await s.settle();
  assert.equal(await s.count("alerts"), 0);
  assert.equal(await s.count("event_state"), 1);
  // A change to a weekly series: Google hands out every instance, years of them.
  s.advance(5000);
  s.google.changed.set("ann@example.com", Array.from({ length: 200 }, (_, i) => timed(`s_${i}`, s.now() + (i + 1) * 7 * DAY)));
  await notify(s, channel, token);
  await s.settle();
  assert.equal(await s.count("alerts", `due_at > ${s.now() + 30 * DAY}`), 0);
  assert.equal(await s.count("alerts", "kind = 'lead'"), 8);           // the four weeks within the month
  // An older row from before is swept.
  await s.db.run(`INSERT INTO alerts (id, account_id, google_sub, calendar_id, event_id, kind, due_at, title, body, status, created_at)
                  SELECT 'old|x|5', id, 'sub-1', 'ann@example.com', 'x', 'lead', ?, 't', 'b', 'pending', 0 FROM accounts`, s.now() + 400 * DAY);
  assert.equal((await dispatch(s)).planned, 0);                        // read today already
  assert.equal(await s.count("alerts", "id = 'old|x|5'"), 0);
  // Fifteen days on, the daily plan reads the month again: the far event is within it now.
  s.advance(15 * DAY);
  s.google.events.set("ann@example.com", [far, { ...timed("new1", s.now() + 2 * DAY), updated: iso(s.now() + 1) }]);
  assert.equal((await dispatch(s)).planned, 1);
  assert.deepEqual((await s.db.all("SELECT id FROM alerts WHERE event_id IN ('f1', 'new1') ORDER BY id")).map((r) => r.id),
    ["ann@example.com|f1|0", "ann@example.com|f1|5"]);                 // one changed since the last feed read is the feed's
  assert.equal(visible(s).filter((p) => /\|(f1|new1)\|/.test(p.payload.b.id)).length, 0);  // planned silently
  assert.equal((await dispatch(s)).planned, 0);
});

test("a held alert the service hasn't planned yet stays held, so it never rings twice once planned", async () => {
  const s = setup();
  const { session } = await ready(s);
  await s.call("PUT", "/v1/alerts/held", { body: { device: "phone-0001", ids: ["ann@example.com|later|5"], calendars: ["ann@example.com"] }, session });
  await dispatch(s);
  assert.equal(await s.count("held_alerts"), 1);
});


test("synced calendar mutes stop pending server alerts on sleeping devices and unmute resumes later alerts", async () => {
  const s=setup(); const {session,channel,token}=await ready(s);
  s.google.events.set("ann@example.com",[timed("quiet",s.now()+10*MIN)]);
  await notify(s,channel,token); await s.settle();
  const account=(await s.call("GET","/v1/account",{session})).json.id;
  const stub=s.deps.spaces.get(`sp_${account}`);
  const update=async muted => {
    await stub.sync({platform:"mac",device:"mac",now:s.now(),changes:[{type:"core.smartSettings",id:"smart-settings",
      set:{v:{updatedAt:s.now()/1000-978307200,settings:{mutedCalendarIDs:muted}}},clocks:{v:`${s.now()}.0000.mac`}}]});
  };
  await update(["ann@example.com"]);
  s.advance(5*MIN); await dispatchAlerts(s.deps,async ms=>s.advance(ms));
  assert.equal(visible(s).length,0,"Old device reports cannot bypass a synced mute");
  await update([]);
  s.advance(5*MIN); await dispatchAlerts(s.deps,async ms=>s.advance(ms));
  assert.equal(visible(s).length,2,"Both platforms receive the remaining at-start alert after unmuting");
});

test("a muted duplicate cannot suppress the enabled calendar's server alert", async () => {
  const s=setup(); const {session,channel,token}=await ready(s);
  const work=await second(s,session,"ann@work.example");
  const start=s.now()+20*MIN;
  s.google.events.set("ann@example.com",[timed("a1",start,{summary:"Design review"})]);
  s.google.events.set("ann@work.example",[timed("w1",start,{summary:"Design review"})]);
  for(const ch of [{id:channel,token},work]) await notify(s,ch.id,ch.token);
  await s.settle();
  const account=(await s.call("GET","/v1/account",{session})).json.id;
  await s.deps.spaces.get(`sp_${account}`).sync({platform:"mac",device:"mac",now:s.now(),changes:[{
    type:"core.smartSettings",id:"smart-settings",set:{v:{settings:{mutedCalendarIDs:["ann@example.com"]}}},clocks:{v:`${s.now()}.0000.mac`}}]});
  for(const id of ["phone-0001","mac-00000001"]) await s.call("PUT","/v1/alerts/held",{
    session,body:{device:id,ids:[],calendars:["ann@example.com","ann@work.example"]}});
  s.advance(15*MIN);await dispatch(s);
  assert.equal(visible(s).length,2);
  assert.ok(visible(s).every(p=>p.payload.b.id.startsWith("ann@work.example|")));
});

test('recurring invitations ring once for the earliest occurrence, say series, and stay deduped after alert cleanup', async () => {
  const s = setup(), { channel, token } = await ready(s);
  s.google.changed.set('ann@example.com', []); await notify(s, channel, token); await s.settle();
  const invite = (i) => timed(`series_${i}`, s.now() + i * DAY, { recurringEventId: 'series', iCalUID: 'series@example.com',
    organizer: { email: 'coach@example.com' }, creator: { email: 'coach@example.com' },
    attendees: [{ email: 'ann@example.com', self: true, responseStatus: 'needsAction' }] });
  s.google.changed.set('ann@example.com', [invite(4), invite(2), invite(3)]);
  await notify(s, channel, token); await s.settle();
  assert.equal(visible(s).length, 2, 'one notification on each of the two devices');
  for (const push of visible(s)) {
    assert.match(push.payload.aps.alert.body, /Recurring series/);
    assert.equal(push.payload.b.event, 'series', 'Accept and Decline address the series master');
    assert.equal(push.payload.b.id, 'ann@example.com|series|invite');
  }
  await s.db.run("DELETE FROM alerts WHERE kind = 'invite'");
  s.google.changed.set('ann@example.com', [invite(5)]);
  await notify(s, channel, token); await s.settle();
  assert.equal(visible(s).length, 2);
  const accepted = { ...invite(6), attendees: [{ self: true, responseStatus: 'accepted' }] };
  s.google.changed.set('ann@example.com', [accepted]); await notify(s, channel, token); await s.settle();
  assert.equal((await s.db.first("SELECT COUNT(*) AS n FROM alerts WHERE event_id = 'series_6' AND kind = 'lead'")).n, 2, 'occurrence reminders are still planned');
});

test('existing unanswered recurring series are silent when another instance appears after upgrading', async () => {
  const s = setup(), { channel, token } = await ready(s);
  s.google.events.set('ann@example.com', []); await notify(s, channel, token); await s.settle();
  await s.db.run("INSERT INTO event_state (google_sub,calendar_id,event_id,start_at,end_at,status,response,title_hash,updated_at) VALUES ('sub-1','ann@example.com','old-series_20261001',?,?, 'confirmed','needsAction','x',?)",s.now(),s.now()+HOUR,s.now());
  s.google.changed.set('ann@example.com', [timed('old-series_20261101',s.now()+DAY,{recurringEventId:'old-series',attendees:[{self:true,responseStatus:'needsAction'}]})]);
  await notify(s,channel,token); await s.settle();
  assert.equal(visible(s).length,0);
});

test('automatically accepted recurring invitations announce only once but keep each occurrence reminder', async () => {
  const s=setup(), {channel,token}=await ready(s);
  s.google.events.set('ann@example.com',[]);await notify(s,channel,token);await s.settle();
  s.google.changed.set('ann@example.com',[1,2,3].map(i=>timed(`auto_${i}`,s.now()+i*DAY,{recurringEventId:'auto',iCalUID:'auto@example.com',creator:{email:'coach@example.com'},attendees:[{self:true,responseStatus:'accepted'}]})));
  await notify(s,channel,token);await s.settle();
  assert.equal(visible(s).length,2);assert.match(visible(s)[0].payload.aps.alert.body,/Recurring series/);
  assert.equal((await s.db.first("SELECT COUNT(*) AS n FROM alerts WHERE kind='lead'")).n,6);
});

test("the sync token moves only once the whole delta is processed: a read that fails halfway is read again, nothing is lost", async () => {
  const s = setup();
  const { channel, token } = await ready(s);
  s.google.events.set("ann@example.com", []);
  await notify(s, channel, token);
  await s.settle();
  assert.equal((await s.db.first("SELECT sync_token FROM calendar_sync")).sync_token, "tok-1");
  const bob = { creator: { email: "bob@y.com", displayName: "Bob" }, organizer: { email: "bob@y.com", displayName: "Bob" },
    attendees: [{ email: "ann@example.com", self: true, responseStatus: "needsAction" }] };
  s.advance(5000);
  const delta = [timed("e1", s.now() + HOUR, bob), timed("e2", s.now() + 2 * HOUR, bob), timed("e3", s.now() + 3 * HOUR, bob)];
  s.google.changed.set("ann@example.com", delta);
  const first = s.deps.db.first.bind(s.deps.db);
  let n = 0;
  s.deps.db.first = async (sql, ...p) => {
    if (sql.startsWith("SELECT start_at, end_at, status, response, title_hash FROM event_state") && ++n === 2) throw new Error("d1 down");
    return first(sql, ...p);
  };
  await notify(s, channel, token);
  await s.settle();
  s.deps.db.first = first;
  assert.equal((await s.db.first("SELECT sync_token FROM calendar_sync")).sync_token, "tok-1", "the old token stays");
  assert.equal(await s.count("alerts", "event_id IN ('e2', 'e3')"), 0);
  // Google serves the delta again for the old token: now every change is announced.
  s.google.changed.set("ann@example.com", delta);
  await notify(s, channel, token);
  await s.settle();
  assert.equal((await s.db.first("SELECT sync_token FROM calendar_sync")).sync_token, "tok-3");
  assert.equal(await s.count("alerts", "kind = 'invite' AND event_id IN ('e1', 'e2', 'e3')"), 3);
});

test("one calendar's flood of instances neither sets the size of a run nor holds the dirty queue (audit run-1, cron)", async () => {
  const s = setup();
  s.google.person("c1", "sub-1", "ann@example.com");
  const { session } = (await s.signIn("c1", device("phone-0001", { push: pushToken(1) }))).json;
  await s.call("PUT", "/v1/account/alerts", { body: { leads: [5, 0], timeZone: "UTC" }, session });
  assert.equal((await s.call("PUT", "/v1/google/calendars", { body: { email: "ann@example.com", ids: ["A", "B"] }, session })).status, 202);
  await s.settle();
  s.google.events.set("A", []);
  s.google.events.set("B", []);
  await dispatchAlerts(s.deps, async () => {});   // the first reads: both calendars hold a sync token now
  const mark = (cal, ago) => s.db.run("UPDATE watches SET dirty_at = ? WHERE calendar_id = ?", s.now() - ago, cal);
  await mark("A", 10 * MIN);
  await mark("B", MIN);
  s.advance(5000);
  // A changed series: Google hands out every instance, more than one page of them.
  const flood = Array.from({ length: MOST_EVENTS_PER_READ + 500 }, (_, i) => ({ ...timed(`series-1_${i}`, s.now() + 31 * DAY + i * MIN), recurringEventId: "series-1" }));
  s.google.changed.set("A", flood);
  s.google.changed.set("B", [timed("b1", s.now() + 2 * DAY)]);
  assert.equal(await dirtyReads(s.deps), 2);
  // One page of the earliest instances is kept, the token still moves, and B is read in the same run.
  assert.equal(await s.count("event_state", "calendar_id = 'A'"), MOST_EVENTS_PER_READ);
  assert.notEqual((await s.db.first("SELECT sync_token FROM calendar_sync WHERE calendar_id = 'A'")).sync_token, "tok-1");
  assert.equal(await s.count("event_state", "calendar_id = 'B'"), 1);
  assert.equal(await s.count("watches", "dirty_at IS NOT NULL"), 0);
  // A read that fails loses its place: the mark is taken before the read and goes to the back on failure.
  await mark("A", 10 * MIN);
  await mark("B", MIN);
  const listEvents = s.google.listEvents.bind(s.google);
  s.google.listEvents = async (access, cal, p) => { if (cal === "A") throw new GoogleError("events 500", 500); return listEvents(access, cal, p); };
  s.advance(5000);
  await dirtyReads(s.deps);
  s.google.listEvents = listEvents;
  assert.equal(Number((await s.db.first("SELECT dirty_at FROM watches WHERE calendar_id = 'A'")).dirty_at), s.now(), "A is marked again, at the back");
  assert.equal((await s.db.first("SELECT dirty_at FROM watches WHERE calendar_id = 'B'")).dirty_at, null);
});
