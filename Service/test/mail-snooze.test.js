// Snooze by hidden Gmail labels (MAIL-ENGINE §8): the rules, the createLabel operation, and the
// shared mailbox waking a conversation on time with every device asleep.

import test from "node:test";
import assert from "node:assert/strict";
import { setup, device, pushToken, DAY, HOUR } from "./helpers.js";
import { fakeGmail } from "./fake-gmail.js";
import { snoozedName, parseBananaLabel, snoozeAssertions } from "../src/mail-snooze.js";
import { runJob } from "../src/job.js";

const EMAIL = "noor@plan.example", SUB = "sub-noor";
const MINUTE = 60_000;
/** A time a snooze label can name exactly (the device rounds up to five minutes). */
const five = (ms) => Math.ceil(ms / (5 * MINUTE)) * 5 * MINUTE;
let ops = 0;
const opID = () => `00000000-0000-4000-8000-${String(++ops).padStart(12, "0")}`;

// ---- the rules ----

test("snoozedName rounds up to five minutes in UTC; parse is strict", () => {
  assert.equal(snoozedName(Date.UTC(2026, 10, 7, 9, 5)), "Banana/Snoozed/20261107T0905Z");
  assert.equal(snoozedName(Date.UTC(2026, 10, 7, 9, 5, 0, 1)), "Banana/Snoozed/20261107T0910Z");
  assert.equal(snoozedName(Date.UTC(2026, 10, 7, 9, 1)), "Banana/Snoozed/20261107T0905Z");
  assert.equal(snoozedName(Date.UTC(2026, 11, 31, 23, 56)), "Banana/Snoozed/20270101T0000Z");
  assert.deepEqual(parseBananaLabel("Banana/Snoozed/20261107T0905Z"), { kind: "snoozed", at: Date.UTC(2026, 10, 7, 9, 5) });
  assert.deepEqual(parseBananaLabel("Banana/Returned"), { kind: "returned" });
  assert.deepEqual(parseBananaLabel("Banana/Muted"), { kind: "muted" });
  for (const name of ["Banana/Snoozed/20261131T0900Z", "Banana/Snoozed/20261107T2400Z", "Banana/Snoozed/20261107T0960Z",
    "Banana/Snoozed/20261107T0905", "Banana/Snoozed/2026-11-07T0905Z", "banana/Returned", "Banana/Returned/x", "Banana/Waiting/20261107T0905Z", "Work", null])
    assert.equal(parseBananaLabel(name), null, String(name));
});

const T = Date.UTC(2026, 10, 7, 9, 5);
const NAMES = new Map([["L_S", "Banana/Snoozed/20261107T0905Z"], ["L_S2", "Banana/Snoozed/20261108T0905Z"], ["L_R", "Banana/Returned"], ["Label_1", "Work"]]);
const msg = (id, labels, date) => ({ id, labels, internalDate: String(date) });

test("wake: INBOX, UNREAD on the last message that is not a draft, first; Returned on exactly the snoozed ones", () => {
  const thread = [msg("a", ["L_S"], 1), msg("b", ["L_S", "Label_1"], 2), msg("draft", ["DRAFT"], 3)];
  assert.deepEqual(snoozeAssertions(thread, NAMES, T - 1).changes, []);
  const due = snoozeAssertions(thread, NAMES, T);
  assert.equal(due.rule, "wake");
  assert.deepEqual(due.changes, [{ id: "b", add: ["INBOX", "UNREAD", "L_R"], remove: [] }, { id: "a", add: ["L_R"], remove: [] }]);
  // A newer message without the snooze label (his reply sent from Gmail) takes INBOX but not Returned.
  const replied = [...thread, msg("sent", ["SENT"], 4)];
  assert.deepEqual(snoozeAssertions(replied, NAMES, T).changes,
    [{ id: "sent", add: ["INBOX", "UNREAD"], remove: [] }, { id: "a", add: ["L_R"], remove: [] }, { id: "b", add: ["L_R"], remove: [] }]);
  // Equal dates: the id decides, the same on every reader.
  assert.equal(snoozeAssertions([msg("x", ["L_S"], 5), msg("y", ["L_S"], 5)], NAMES, T).changes[0].id, "y");
  // The latest Snoozed time on the conversation is its time.
  assert.deepEqual(snoozeAssertions([msg("a", ["L_S"], 1), msg("b", ["L_S2"], 2)], NAMES, T + HOUR).changes, []);
  // No Returned label yet: the wake says so instead of half-happening.
  const unnamed = new Map([["L_S", NAMES.get("L_S")]]);
  assert.deepEqual(snoozeAssertions(thread, unnamed, T), { rule: "wake", changes: [], missing: "Banana/Returned" });
  // Already woken (by a device): nothing.
  assert.deepEqual(snoozeAssertions([msg("a", ["L_S", "L_R", "INBOX"], 1)], NAMES, T).changes, []);
});

test("came back early, left the inbox, and the bin end a snooze instead of waking it", () => {
  // A reply arrived before the time: every Snoozed label goes, nothing is woken.
  const early = snoozeAssertions([msg("a", ["L_S", "L_S2"], 1), msg("reply", ["INBOX", "UNREAD"], 2)], NAMES, T - DAY);
  assert.equal(early.rule, "early");
  assert.deepEqual(early.changes, [{ id: "a", add: [], remove: ["L_S", "L_S2"] }]);
  // Archived in Gmail after it came back: Returned and Snoozed go.
  const left = snoozeAssertions([msg("a", ["L_S", "L_R"], 1), msg("b", ["L_S", "L_R"], 2)], NAMES, T + DAY);
  assert.equal(left.rule, "left");
  assert.deepEqual(left.changes, [{ id: "a", add: [], remove: ["L_S", "L_R"] }, { id: "b", add: [], remove: ["L_S", "L_R"] }]);
  // Every snoozed message is in the bin: its labels go, it is not woken into the Inbox.
  const binned = snoozeAssertions([msg("a", ["L_S", "TRASH"], 1), msg("b", ["SENT"], 2)], NAMES, T);
  assert.equal(binned.rule, "binned");
  assert.deepEqual(binned.changes, [{ id: "a", add: [], remove: ["L_S"] }]);
  // One snoozed message in the bin, one not: the bin is ignored and the other wakes.
  assert.deepEqual(snoozeAssertions([msg("a", ["L_S", "SPAM"], 3), msg("b", ["L_S"], 2)], NAMES, T).changes,
    [{ id: "b", add: ["INBOX", "UNREAD", "L_R"], remove: [] }]);
});

// ---- the service ----

async function mailbox() {
  const s = setup();
  s.deps.sleep = async (ms) => s.advance(ms);
  const gmail = fakeGmail();
  for (const name of ["mailRead", "mailMessage", "mailMutation", "mailLabels", "mailCreateLabel"]) s.google[name] = gmail[name];
  s.google.person("noor", SUB, EMAIL);
  const phone = (await s.signIn("noor", device("device-phone", { push: pushToken(1) }))).json;
  const mac = (await s.signIn("noor", device("device-mac1", { platform: "mac", push: pushToken(2) }))).json;
  await s.db.run("INSERT INTO feature_access VALUES (?,?,1,NULL,?)", phone.account.id, "email", s.now());
  s.google.person("mail-noor", SUB, EMAIL, "mail-noor", { scopes: "https://www.googleapis.com/auth/gmail.modify" });
  assert.equal((await s.call("POST", "/v1/google/mail", { session: phone.session, body: { email: EMAIL, code: "mail-noor" } })).status, 200);
  for (const [id, thread] of [["a1", "t-a"], ["a2", "t-a"], ["b1", "t-b"], ["c1", "t-c"]]) gmail.add(id, ["INBOX", "UNREAD"], thread);
  const operation = (body, who = phone) => s.call("POST", "/v1/mail/operation", { session: who.session, body: { email: EMAIL, operationID: opID(), ...body } });
  const status = () => s.mailboxes.get(SUB).status();
  const wake = () => s.mailboxes.wakes()[SUB] ?? null;
  const settled = async () => { const st = await status(); return st?.complete && st.counts.verify === 0 && st.counts.fetch === 0; };
  async function drain(done = settled, rounds = 400) {
    for (let i = 0; i < rounds; i++) {
      await s.mailboxes.due();
      if (await done()) return;
      const w = wake();
      if (w === null) return;
      if (w > s.now()) s.advance(w - s.now());
    }
    assert.fail("the mailbox did not settle");
  }
  /** Runs every alarm up to `at` (not past it), then moves the clock to `at`. */
  async function until(at) {
    for (;;) {
      await s.mailboxes.due();
      const w = wake();
      if (w === null || w > at) { if (at > s.now()) s.advance(at - s.now()); return; }
      s.advance(Math.max(0, w - s.now()));
    }
  }
  /** What a device sends to snooze a conversation until `until`: the label, then each message. */
  async function snooze(ids, at, who = phone) {
    const made = await operation({ action: "createLabel", name: snoozedName(at) }, who);
    assert.equal(made.status, 200, made.text);
    for (const id of ids) assert.equal((await operation({ id, action: "modify", add: [made.json.id], remove: ["INBOX"] }, who)).status, 200);
    return made.json.id;
  }
  const labels = (id) => [...gmail.messages.get(id).labels].sort();
  const writesTo = (ids) => gmail.writes.filter((w) => ids.includes(w.id)).length;
  const mailPushes = () => s.apns.sends.filter((p) => p.collapseId === "mail");
  async function feedLabels() {
    const out = new Map();
    for (let after = null; ;) {
      const page = await s.call("POST", "/v1/mail/feed", { session: mac.session, body: { email: EMAIL, limit: 500, ...(after === null ? {} : { after }) } });
      assert.equal(page.status, 200, page.text);
      for (const e of page.json.entries) out.set(e.id, e.labels);
      after = page.json.cursor;
      if (!page.json.more) return out;
    }
  }
  assert.equal((await s.call("POST", "/v1/mail/feed", { session: phone.session, body: { email: EMAIL } })).status, 200);
  await drain();
  return { s, gmail, phone, mac, operation, status, wake, drain, until, snooze, labels, writesTo, mailPushes, feedLabels };
}

test("createLabel makes Banana's label once, hidden; a second operation gets the same label; other names are refused", async () => {
  const t = await mailbox();
  const name = snoozedName(t.s.now() + DAY);
  const first = await t.operation({ action: "createLabel", name });
  assert.equal(first.status, 200, first.text);
  assert.equal(first.json.name, name);
  assert.match(first.json.id, /^Label_/);
  assert.deepEqual(t.gmail.created, [{ name, labelListVisibility: "labelHide", messageListVisibility: "hide" }]);
  const again = await t.operation({ action: "createLabel", name }, t.mac);
  assert.equal(again.status, 200);
  assert.equal(again.json.id, first.json.id);
  assert.equal(t.gmail.created.length, 1);
  // A device that lost the race (Gmail's 409) gets the label the other made.
  t.gmail.label("Banana/Returned");
  const raced = t.s.google.mailLabels;
  let lists = 0;   // the first listing doesn't show it yet; the create answers 409
  t.s.google.mailLabels = async (token) => { const all = await raced(token); return lists++ ? all : all.filter((l) => l.name !== "Banana/Returned"); };
  const returned = await t.operation({ action: "createLabel", name: "Banana/Returned" });
  assert.equal(returned.status, 200, returned.text);
  assert.equal(returned.json.id, t.gmail.labelID("Banana/Returned"));
  t.s.google.mailLabels = raced;
  for (const body of [{ name: "Work" }, { name: "Banana/Snoozed/20261131T0900Z" }, { name: "Banana/Snoozed/2026-11-07" }, { name: "Banana/Waiting/20261107T0905Z" },
    { name: "Banana/Muted", id: "a1" }, { name: "Banana/Muted", add: [] }, { name: 7 }])
    assert.equal((await t.operation({ action: "createLabel", ...body })).status, 400, JSON.stringify(body));
  assert.equal(t.gmail.created.length, 2);
});

test("a snooze made through the operation route wakes at its time with no device reading, and the devices hear of it", async () => {
  const t = await mailbox();
  const at = five(t.s.now() + 3 * DAY);
  const snoozed = await t.snooze(["a1", "a2"], at);
  await t.drain();
  assert.deepEqual(t.labels("a1"), [snoozed, "UNREAD"].sort());
  const writes = t.gmail.writes.length;
  // Days pass with nobody reading: the mailbox idles, and its alarm is never later than the wake.
  await t.until(at - MINUTE);
  assert.ok(t.wake() <= at, "the alarm is set for the snooze");
  assert.equal(t.gmail.writes.length, writes, "nothing before the time");
  assert.equal(t.mailPushes().length, 0);
  assert.equal(Number((await t.s.db.first("SELECT wake_at FROM mail_mailboxes")).wake_at), at);
  await t.until(at);
  await t.s.mailboxes.due();
  const returned = t.gmail.labelID("Banana/Returned");
  assert.ok(returned, "the mailbox made Banana/Returned");
  assert.deepEqual(t.gmail.created.at(-1), { name: "Banana/Returned", labelListVisibility: "labelHide", messageListVisibility: "hide" });
  assert.deepEqual(t.labels("a2"), ["INBOX", "UNREAD", returned, snoozed].sort());
  assert.deepEqual(t.labels("a1"), ["UNREAD", returned, snoozed].sort());
  assert.deepEqual(t.gmail.writes.slice(writes).map((w) => w.id), ["a2", "a1"], "the INBOX change first");
  // One silent push, to each device.
  assert.equal(t.mailPushes().length, 2);
  for (const p of t.mailPushes()) assert.deepEqual(p.payload, { aps: { "content-available": 1 }, b: { k: "mail" } });
  await t.drain();
  const feed = await t.feedLabels();
  assert.deepEqual(feed.get("a2"), t.labels("a2"));
  assert.deepEqual(feed.get("a1"), t.labels("a1"));
  assert.equal((await t.s.db.first("SELECT wake_at FROM mail_mailboxes")).wake_at, null);
});

test("two snoozes: the earlier wakes first, and the alarm is set for it", async () => {
  const t = await mailbox();
  const later = five(t.s.now() + 2 * DAY), earlier = five(t.s.now() + DAY);
  await t.snooze(["a1", "a2"], later);
  await t.snooze(["b1"], earlier);
  await t.drain();
  await t.until(earlier - MINUTE);
  assert.ok(t.wake() <= earlier);
  await t.until(earlier);
  await t.s.mailboxes.due();
  assert.ok(t.labels("b1").includes("INBOX"));
  assert.ok(!t.labels("a2").includes("INBOX"));
  await t.until(later - MINUTE);
  assert.ok(t.wake() <= later);
  assert.ok(!t.labels("a2").includes("INBOX"));
  await t.until(later);
  await t.s.mailboxes.due();
  assert.ok(t.labels("a2").includes("INBOX"));
  assert.equal(t.mailPushes().length, 4);   // one push per wake, two devices each
});

test("a conversation a device already woke is not changed again, and a wake runs once per message", async () => {
  const t = await mailbox();
  const at = five(t.s.now() + DAY);
  const snoozed = await t.snooze(["a1", "a2"], at);
  const returned = (await t.operation({ action: "createLabel", name: "Banana/Returned" })).json.id;
  await t.snooze(["b1"], at);
  await t.drain();
  // At the time, the Mac wakes a, in Gmail, before the mailbox's alarm runs.
  await t.until(at - MINUTE);
  t.s.advance(MINUTE);
  t.gmail.modify("a2", ["INBOX", "UNREAD", returned], []);
  t.gmail.modify("a1", [returned], []);
  const before = t.writesTo(["a1", "a2"]);
  await t.s.mailboxes.due();
  assert.equal(t.writesTo(["a1", "a2"]), before, "already woken: no change");
  assert.equal(t.writesTo(["b1"]), 2, "b woken by the mailbox (the device's snooze + the wake)");
  // Running again, and again later: nothing more.
  await t.s.mailboxes.get(SUB).arm();
  await t.drain();
  t.s.advance(HOUR);
  await t.s.mailboxes.get(SUB).arm();
  await t.drain();
  assert.equal(t.writesTo(["a1", "a2"]), before);
  assert.equal(t.writesTo(["b1"]), 2);
  assert.deepEqual(t.labels("a1"), ["UNREAD", returned, snoozed].sort());
  assert.equal(t.mailPushes().length, 2);   // b's wake only
});

test("a snooze survives a restart: the job sets the alarm again from what is stored", async () => {
  const t = await mailbox();
  const at = five(t.s.now() + 8 * DAY);
  await t.snooze(["c1"], at);
  await t.drain();
  t.s.mailboxes.close();   // the alarm is lost with the process
  t.s.advance(8 * DAY - HOUR);
  assert.equal(t.wake(), null);
  const job = await runJob(t.s.deps);
  assert.equal(job.mailboxes, 1);
  assert.equal(t.wake(), at, "set for the wake, not now: no device read it this week");
  await t.until(at);
  await t.s.mailboxes.due();
  assert.ok(t.labels("c1").includes("INBOX"));
  assert.ok(t.labels("c1").includes(t.gmail.labelID("Banana/Returned")));
});

test("Email turned off before the time: nothing is woken, and the mailbox is gone", async () => {
  for (const how of ["feature", "grant"]) {
    const t = await mailbox();
    const at = five(t.s.now() + DAY);
    await t.snooze(["a1", "a2"], at);
    await t.drain();
    const writes = t.gmail.writes.length;
    if (how === "feature") await t.s.db.run("UPDATE feature_access SET enabled = 0");
    else t.s.google.refused.add("mail-noor");
    await t.until(at + HOUR);
    assert.equal(t.gmail.writes.length, writes, how);
    assert.ok(!t.labels("a2").includes("INBOX"), how);
    assert.equal(await t.status(), null, how);
    assert.equal(await t.s.count("mail_mailboxes"), 0, how);
    assert.equal(t.mailPushes().length, 0, how);
  }
});

test("a reply during the snooze ends it: the Snoozed labels go and nothing wakes at the time", async () => {
  const t = await mailbox();
  const at = five(t.s.now() + DAY);
  const snoozed = await t.snooze(["a1", "a2"], at);
  await t.drain();
  t.s.advance(HOUR);
  t.gmail.add("a3", ["INBOX", "UNREAD"], "t-a");
  await t.drain(async () => !t.labels("a1").includes(snoozed) && !t.labels("a2").includes(snoozed));
  assert.deepEqual(t.labels("a1"), ["UNREAD"]);
  assert.deepEqual(t.labels("a2"), ["UNREAD"]);
  const writes = t.gmail.writes.length;
  // The reply itself is new mail, which pushes once (the coalesced "mail changed" push); nothing
  // wakes at the time, so nothing more is pushed.
  const pushes = t.mailPushes().length;
  await t.until(at + HOUR);
  assert.equal(t.gmail.writes.length, writes);
  assert.equal(t.gmail.labelID("Banana/Returned"), null);
  assert.equal(t.mailPushes().length, pushes);
  assert.equal((await t.s.db.first("SELECT wake_at FROM mail_mailboxes")).wake_at, null);
});

test("archived after it came back: Returned and Snoozed go", async () => {
  const t = await mailbox();
  const at = five(t.s.now() + DAY);
  const snoozed = await t.snooze(["a1", "a2"], at);
  await t.drain();
  await t.until(at);
  await t.s.mailboxes.due();
  const returned = t.gmail.labelID("Banana/Returned");
  assert.ok(t.labels("a2").includes(returned));
  // Archived in Gmail's own app.
  t.s.advance(HOUR);
  t.gmail.modify("a2", [], ["INBOX"]);
  await t.drain(async () => [snoozed, returned].every((l) => !t.labels("a1").includes(l) && !t.labels("a2").includes(l)));
  assert.deepEqual(t.labels("a1"), ["UNREAD"]);
  assert.deepEqual(t.labels("a2"), ["UNREAD"]);
  assert.ok(!t.labels("a2").includes("INBOX"));
  await t.drain();
  const feed = await t.feedLabels();
  assert.deepEqual(feed.get("a2"), ["UNREAD"]);
});

test("a conversation whose change keeps failing waits longer each time instead of spinning the alarm", async () => {
  const t = await mailbox();
  const at = five(t.s.now() + DAY);
  await t.snooze(["a1", "a2"], at);
  await t.snooze(["b1"], at);
  await t.drain();
  const mutate = t.s.google.mailMutation;
  t.s.google.mailMutation = async (token, request) => (request.id === "a2" ? (t.gmail.writes.push({ id: "a2" }), { status: 500, body: { error: { code: 500 } } }) : mutate(token, request));
  const reads = t.gmail.reads("thread", "t-a");
  await t.until(at + 2 * HOUR);
  const tries = t.writesTo(["a2"]) - 1;   // the device's snooze was one
  assert.ok(tries >= 3 && tries <= 9, `tries ${tries}`);
  assert.ok(t.gmail.reads("thread", "t-a") - reads <= tries + 1);
  assert.ok(t.labels("b1").includes("INBOX"), "the other conversation is not held back");
  assert.ok(!t.labels("a2").includes("INBOX"));
  // Gmail answers again: it wakes on the next try.
  t.s.google.mailMutation = mutate;
  await t.until(at + 4 * HOUR);
  assert.ok(t.labels("a2").includes("INBOX"));
});

test("a snooze a device is still delivering, one message at a time, is not taken for one that came back early", async () => {
  const t = await mailbox();
  const at = five(t.s.now() + DAY);
  const made = await t.operation({ action: "createLabel", name: snoozedName(at) });
  assert.equal(made.status, 200, made.text);
  // a1 is snoozed and out of the Inbox; a2, the next request, has not gone yet.
  assert.equal((await t.operation({ id: "a1", action: "modify", add: [made.json.id], remove: ["INBOX"] })).status, 200);
  await t.until(t.s.now() + 30_000);
  assert.ok(t.labels("a1").includes(made.json.id), "half a snooze is left alone while the device finishes");
  assert.equal((await t.operation({ id: "a2", action: "modify", add: [made.json.id], remove: ["INBOX"] })).status, 200);
  await t.until(at - 1);
  assert.ok(t.labels("a1").includes(made.json.id) && t.labels("a2").includes(made.json.id));
  assert.ok(!t.labels("a2").includes("INBOX"), "still away before its time");
  await t.until(at + MINUTE);
  assert.ok(t.labels("a2").includes("INBOX"), "and back at its time");
});
