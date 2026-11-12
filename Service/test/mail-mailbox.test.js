// The shared cloud mailbox (docs/design/MAIL-CLOUD-SYNC.md): one Google download per message for
// every device, Gmail's order kept, the device feed, content from the store, deletion, pacing.

import test from "node:test";
import assert from "node:assert/strict";
import { setup, device, DAY, pushToken } from "./helpers.js";
import { fakeGmail } from "./fake-gmail.js";
import { sha256Hex } from "../src/crypto.js";
import * as box from "../src/mail-mailbox.js";
import { sqlitePort } from "../src/adapters/spaces-sqlite.js";
import { DatabaseSync } from "node:sqlite";

const EMAIL = "noor@plan.example";

async function mailbox({ count = 0, labels, config = {}, push = false } = {}) {
  const s = setup({ config });
  s.deps.sleep = async (ms) => s.advance(ms);
  const gmail = fakeGmail();
  Object.assign(s.google, { mailRead: gmail.mailRead, mailMessage: gmail.mailMessage, mailMutation: gmail.mailMutation });
  s.google.person("noor", "sub-noor", EMAIL);
  const phone = (await s.signIn("noor", device("device-phone", { capabilities: ["mail"], ...(push ? { push: pushToken(1) } : {}) }))).json;
  const mac = (await s.signIn("noor", device("device-mac1", { platform: "mac", capabilities: ["mail"], ...(push ? { push: pushToken(2) } : {}) }))).json;
  assert.equal(phone.account.id, mac.account.id);
  await s.db.run("INSERT INTO feature_access VALUES (?,?,1,NULL,?)", phone.account.id, "email", s.now());
  s.google.person("mail-noor", "sub-noor", EMAIL, "mail-noor", { scopes: "https://www.googleapis.com/auth/gmail.modify" });
  assert.equal((await s.call("POST", "/v1/google/mail", { session: phone.session, body: { email: EMAIL, code: "mail-noor" } })).status, 200);
  for (let i = 1; i <= count; i++) gmail.add(`m${i}`, labels?.(i) ?? (i % 3 ? ["INBOX", "UNREAD"] : ["Label_1"]));
  const feed = async (who, { after = null, limit = 500, fresh = false } = {}) =>
    s.call("POST", "/v1/mail/feed", { session: who.session, body: { email: EMAIL, limit, ...(after === null ? {} : { after }), ...(fresh ? { fresh: true } : {}) } });
  const read = (who, id, format = "full", extra = {}) => s.call("POST", "/v1/mail/read", { session: who.session,
    body: { email: EMAIL, resource: "message", id, query: [{ name: "format", value: format }], ...extra } });
  const status = () => s.mailboxes.get("sub-noor").status();
  /** Runs the mailbox's alarms, moving the test clock to each next one, until `done()` or `rounds`. */
  async function drain(done = async () => false, rounds = 400) {
    for (let i = 0; i < rounds; i++) {
      await s.mailboxes.due();
      if (await done()) return;
      const wakes = Object.values(s.mailboxes.wakes()).filter((w) => w !== null);
      if (!wakes.length) return;
      const next = Math.min(...wakes);
      if (next > s.now()) s.advance(next - s.now());
    }
    if (!(await done())) assert.fail("the mailbox did not settle");
  }
  const settled = async () => {
    const st = await status();
    return st?.complete && st.counts.verify === 0 && st.counts.fetch === 0;
  };
  /** Every entry from `after` to the head. */
  async function all(who, after = null) {
    const out = [];
    let cursor = after;
    for (;;) {
      const page = await feed(who, { after: cursor, limit: 7 });
      assert.equal(page.status, 200, page.text);
      out.push(...page.json.entries);
      cursor = page.json.cursor;
      if (!page.json.more) return { entries: out, cursor, page: page.json };
    }
  }
  const latest = (entries) => { const m = new Map(); for (const e of entries) m.set(e.id, e); return m; };
  return { s, gmail, phone, mac, feed, read, status, drain, settled, all, latest };
}

test("two devices: every message is downloaded from Google once, and both get the same mailbox", async () => {
  const t = await mailbox({ count: 30 });
  assert.equal((await t.feed(t.phone)).status, 200);
  await t.drain(t.settled);
  const phone = t.latest((await t.all(t.phone)).entries), mac = t.latest((await t.all(t.mac)).entries);
  assert.equal(phone.size, 30);
  assert.deepEqual([...phone.values()], [...mac.values()]);
  for (const [id, entry] of phone) assert.deepEqual(entry.labels, [...t.gmail.messages.get(id).labels].sort(), id);
  for (const who of [t.phone, t.mac]) {
    for (const id of phone.keys()) {
      const answer = await t.read(who, id);
      assert.equal(answer.status, 200);
      assert.equal(answer.json.id, id);
      assert.deepEqual(answer.json.labelIds, phone.get(id).labels);
    }
  }
  for (const id of phone.keys()) assert.equal(t.gmail.reads("message", id, "full"), 1, id);
  // The profile the devices ask for before each read comes from the mailbox, not Google.
  const profiles = t.gmail.reads("profile");
  assert.equal((await t.s.call("POST", "/v1/mail/read", { session: t.mac.session, body: { email: EMAIL, resource: "profile", query: [] } })).json.emailAddress, EMAIL);
  assert.equal(t.gmail.reads("profile"), profiles);
});

test("an archive applied from history is never undone by a listing that began before it", async () => {
  const t = await mailbox({ count: 5, labels: () => ["INBOX"] });
  assert.equal((await t.feed(t.phone)).status, 200);   // handshake: the scan's floor is now
  const before = t.gmail.messages.get("m3");
  // The Inbox listing still answers from before the archive (Gmail's listing behind its history).
  t.gmail.stale.set("INBOX", [...t.gmail.messages.values()].map((m) => ({ id: m.id, threadId: m.threadId })));
  t.gmail.modify("m3", [], ["INBOX"]);
  t.s.advance(11_000);
  assert.equal((await t.feed(t.phone, { fresh: true })).status, 200);   // history poll applies the archive first
  await t.drain(async () => { await t.s.mailboxes.due(); return t.settled(); });
  const m3 = t.latest((await t.all(t.mac)).entries).get("m3");
  assert.deepEqual(m3.labels, []);
  assert.ok(Number(m3.history) >= before.hist);
  assert.ok(t.gmail.reads("message", "m3", "minimal") + t.gmail.reads("message", "m3", "full") >= 1, "settled by a read, not the listing");
  for (const id of ["m1", "m2", "m4", "m5"]) assert.deepEqual(t.latest((await t.all(t.mac)).entries).get(id).labels, ["INBOX"]);
});

test("the Inbox comes first: its newest messages are listed and downloaded before any other label", async () => {
  const t = await mailbox({ count: 60, labels: (i) => (i % 2 ? ["INBOX"] : ["Label_1", "SENT"]) });
  assert.equal((await t.feed(t.phone)).status, 200);
  await t.drain(t.settled);
  const calls = t.gmail.calls;
  const lists = calls.map((c, i) => ({ ...c, i })).filter((c) => c.resource === "messages");
  assert.equal(lists[0].label, "INBOX");
  const otherList = lists.find((c) => c.label !== "INBOX").i;
  const headReads = calls.map((c, i) => ({ ...c, i })).filter((c) => c.resource === "message" && c.format === "full");
  assert.equal(headReads.length, 30);    // the 30 Inbox messages fit the head page
  assert.ok(headReads.every((c) => c.i < otherList), "head content before other labels");
});

test("a message a listing skipped is put back in the Inbox by the Inbox check", async () => {
  const t = await mailbox({ count: 8, labels: () => ["INBOX"] });
  t.gmail.skip.set("INBOX", new Set(["m4"]));
  assert.equal((await t.feed(t.phone)).status, 200);
  await t.drain(t.settled);
  assert.deepEqual(t.latest((await t.all(t.phone)).entries).get("m4").labels, []);
  t.gmail.skip.clear();
  t.s.advance(10 * 60_000);
  assert.equal((await t.feed(t.phone)).status, 200);   // a device is reading
  await t.drain(async () => (t.latest((await t.all(t.phone)).entries).get("m4").labels.length > 0), 50);
  assert.deepEqual(t.latest((await t.all(t.phone)).entries).get("m4").labels, ["INBOX"]);
});

test("a device catches up from zero, then from its cursor, and starts again after the horizon", async () => {
  const t = await mailbox({ count: 12 });
  await t.feed(t.phone);
  await t.drain(t.settled);
  const first = await t.all(t.phone);
  assert.equal(t.latest(first.entries).size, 12);
  assert.equal(first.page.complete, true);
  assert.match(first.page.epoch, /^[0-9a-f]{32}$/);
  // Nothing new: the cursor answers nothing.
  assert.deepEqual((await t.all(t.phone, first.cursor)).entries, []);
  t.gmail.add("m13", ["INBOX", "UNREAD"]);
  t.gmail.modify("m1", [], ["UNREAD"]);
  t.gmail.remove("m2");
  t.s.advance(11_000);
  await t.feed(t.phone, { fresh: true });
  await t.drain(t.settled);
  const next = await t.all(t.phone, first.cursor);
  const changes = t.latest(next.entries);
  assert.deepEqual([...changes.keys()].sort(), ["m1", "m13", "m2"]);
  assert.equal(changes.get("m2").deleted, true);
  assert.deepEqual(changes.get("m13").labels, ["INBOX", "UNREAD"]);
  assert.equal(changes.get("m1").labels.includes("UNREAD"), false);
  // Tombstones last 30 days; a cursor from before the horizon starts again from zero.
  t.s.advance(31 * DAY);
  await t.feed(t.phone);
  await t.drain(async () => (await t.feed(t.phone, { after: first.cursor })).status === 410, 50);
  assert.equal((await t.feed(t.phone, { after: first.cursor })).status, 410);
  const again = t.latest((await t.all(t.phone)).entries);
  assert.equal(again.has("m2"), false);
  assert.equal(again.size, 12);
});

test("a change made on the phone reaches the Mac with Gmail's own position", async () => {
  const t = await mailbox({ count: 4 });
  await t.feed(t.phone);
  await t.drain(t.settled);
  const mac = await t.all(t.mac);
  const operation = await t.s.call("POST", "/v1/mail/operation", { session: t.phone.session,
    body: { email: EMAIL, id: "m1", action: "modify", add: [], remove: ["UNREAD"], operationID: "4b8c5c4e-7a51-4d6b-9a25-3b1f3d5f2a10" } });
  assert.equal(operation.status, 200, operation.text);
  await t.drain(t.settled, 20);
  const changes = (await t.all(t.mac, mac.cursor)).entries;
  assert.deepEqual(changes.map((e) => e.id), ["m1"]);
  assert.deepEqual(changes[0].labels, ["INBOX"]);
  assert.equal(changes[0].history, String(t.gmail.messages.get("m1").hist));
  // The history record of that same change, polled later, is not newer: nothing moves again.
  t.s.advance(11_000);
  await t.feed(t.mac, { fresh: true });
  await t.drain(t.settled, 20);
  assert.deepEqual((await t.all(t.mac, (await t.all(t.mac, mac.cursor)).cursor)).entries, []);
});

test("content is stored sealed on the first read, served from the store after, with current labels", async () => {
  const t = await mailbox({ count: 3, labels: () => ["Label_1"] });
  await t.feed(t.phone);
  await t.drain(t.settled);
  assert.equal(t.gmail.reads("message", "m2", "full"), 0);   // not in the Inbox head
  const first = await t.read(t.phone, "m2");
  assert.equal(first.status, 200);
  assert.equal(t.gmail.reads("message", "m2", "full"), 1);
  const keys = await t.s.deps.blobs.list(`mail/${await sha256Hex("sub-noor")}/`, 100);
  assert.equal(keys.length, 1);
  const stored = new Uint8Array(await new Response((await t.s.deps.blobs.get(keys[0])).body).arrayBuffer());
  assert.equal(Buffer.from(stored).includes("Subject m2"), false, "content is sealed at rest");
  // A label change after it was stored: the copy served carries the newer state.
  t.gmail.modify("m2", ["STARRED"], []);
  t.s.advance(11_000);
  await t.feed(t.mac, { fresh: true });
  const second = await t.read(t.mac, "m2");
  assert.equal(t.gmail.reads("message", "m2", "full"), 1);
  assert.deepEqual(second.json.labelIds, ["Label_1", "STARRED"]);
  assert.equal(second.json.historyId, String(t.gmail.messages.get("m2").hist));
  assert.equal(second.json.payload.headers[0].value, "Subject m2");
  // Attachments are stored the same way; verification reads (minimal) always ask Gmail.
  const attachment = { resource: "attachment", id: "m2", attachmentID: "att-1", query: [] };
  for (const who of [t.phone, t.mac]) assert.equal((await t.s.call("POST", "/v1/mail/read", { session: who.session, body: { email: EMAIL, ...attachment } })).json.data, "YWJj");
  assert.equal(t.gmail.reads("attachment", "m2"), 1);
  const minimal = t.gmail.reads("message", "m2", "minimal");
  await t.read(t.mac, "m2", "minimal");
  assert.equal(t.gmail.reads("message", "m2", "minimal"), minimal + 1);
  // A message Gmail deleted is not served from the store.
  t.gmail.remove("m2");
  t.s.advance(11_000);
  await t.feed(t.mac, { fresh: true });
  assert.equal((await t.read(t.phone, "m2")).status, 404);
  assert.equal((await t.s.deps.blobs.list(`mail/${await sha256Hex("sub-noor")}/`, 100)).length, 0);
});

test("a content read that Google's token endpoint or Gmail drops answers later (429), never 502", async () => {
  const t = await mailbox({ count: 3, labels: () => ["Label_1"] });
  await t.feed(t.phone);
  await t.drain(t.settled);
  // Google's token endpoint fails for a moment (not a refusal of the grant).
  const refresh = t.s.google.refresh;
  t.s.google.refresh = async () => { throw new Error("token endpoint unreachable"); };
  t.s.advance(3_600_000);   // past the cached access token
  const offline = await t.read(t.phone, "m2");
  assert.equal(offline.status, 429, offline.text);
  t.s.google.refresh = refresh;
  // Gmail's connection drops mid-request.
  const mailRead = t.s.google.mailRead;
  t.s.google.mailRead = async () => { throw new TypeError("Network connection lost."); };
  const dropped = await t.read(t.phone, "m2");
  assert.equal(dropped.status, 429, dropped.text);
  t.s.google.mailRead = mailRead;
  // Both are "later": the next read stores and serves it.
  const ok = await t.read(t.phone, "m2");
  assert.equal(ok.status, 200);
  assert.equal(ok.json.id, "m2");
});

test("a device's catch-up check publishes what Gmail still has and what it deleted", async () => {
  const t = await mailbox({ count: 2 });
  await t.feed(t.phone);
  await t.drain(t.settled);
  const { cursor } = await t.all(t.phone);
  // The device holds m1 (known), and two ids from before the mailbox: one Gmail still has (added
  // outside the mailbox's view), one it deleted.
  t.gmail.messages.set("old", { id: "old", threadId: "t-old", labels: new Set(["Label_1"]), internalDate: 1, hist: 900 });
  const answer = await t.s.call("POST", "/v1/mail/check", { session: t.mac.session, body: { email: EMAIL, ids: ["m1", "old", "gone-long-ago"] } });
  assert.deepEqual(answer.json, { read: 2 });
  await t.drain(t.settled, 20);
  const entries = t.latest((await t.all(t.mac, cursor)).entries);
  assert.deepEqual(entries.get("old").labels, ["Label_1"]);
  assert.equal(entries.get("gone-long-ago").deleted, true);
  assert.ok(entries.has("m1"));
});

test("turning Mail off, unlinking or deleting the account wipes the mailbox and its stored content", async () => {
  for (const how of ["mail-off", "unlink", "delete-account", "eligibility"]) {
    const t = await mailbox({ count: 3 });
    await t.feed(t.phone);
    await t.drain(t.settled);
    await t.read(t.phone, "m3");
    const prefix = `mail/${await sha256Hex("sub-noor")}/`;
    assert.ok((await t.s.deps.blobs.list(prefix, 100)).length > 0);
    if (how === "mail-off") assert.equal((await t.s.call("DELETE", "/v1/google/mail", { session: t.phone.session, body: { email: EMAIL } })).status, 204);
    if (how === "unlink") assert.equal((await t.s.call("DELETE", "/v1/google", { session: t.phone.session, body: { email: EMAIL } })).status, 204);
    if (how === "delete-account") {
      t.s.google.person("delete-code", "sub-noor", EMAIL);
      assert.equal((await t.s.call("DELETE", "/v1/account", { session: t.phone.session, body: { code: "delete-code" } })).status, 204);
    }
    if (how === "eligibility") {
      await t.s.db.run("UPDATE feature_access SET expires_at=? WHERE feature='email'", t.s.now() - 1);
      t.s.advance(11_000);
      await t.s.mailboxes.get("sub-noor").arm();
      await t.s.mailboxes.due();
    }
    assert.deepEqual(await t.s.deps.blobs.list(prefix, 100), [], how);
    assert.equal(await t.status(), null, how);
    assert.equal(await t.s.count("mail_mailboxes"), 0, how);
    if (how !== "delete-account") assert.notEqual((await t.feed(t.phone)).status, 200, how);
  }
});

test("every Google read the mailbox makes is paced, and backfill never queues ahead of a person", async () => {
  const t = await mailbox({ count: 20 });
  await t.feed(t.phone);
  await t.drain(t.settled);
  const pacing = async () => Number((await t.s.db.first("SELECT next_at FROM mail_read_pacing WHERE google_sub='sub-noor'")).next_at);
  // A content miss reserves its 60 units like any other read.
  t.gmail.add("new-1", ["Label_1"]);
  t.s.advance(11_000);
  await t.feed(t.mac, { fresh: true });
  await t.drain(t.settled, 20);
  const before = await pacing();
  await t.s.db.run("UPDATE mail_read_pacing SET next_at=? WHERE google_sub='sub-noor'", t.s.now() + 5_000);
  // Backfill (a new scan after history expired) takes no slot that isn't free now.
  t.gmail.oldest = Number.MAX_SAFE_INTEGER;
  t.s.advance(11_000);
  await t.s.mailboxes.get("sub-noor").poke();
  await t.drain(async () => (await t.status()).scanning === "listing", 50);
  await t.s.db.run("UPDATE mail_read_pacing SET next_at=? WHERE google_sub='sub-noor'", t.s.now() + 5_000);
  const start = t.s.now(), calls = t.gmail.calls.length;
  await t.s.mailboxes.due();
  assert.ok(t.s.mailboxes.wakes()["sub-noor"] >= start + 5_000, "the step waits for the slot instead of reading");
  assert.ok(t.gmail.calls.slice(calls).every((c) => c.resource !== "messages"), "no listing taken from a busy queue");
  assert.ok(before > 0);
  // Eventually it all settles again, paced.
  t.gmail.oldest = 0;
  await t.drain(t.settled);
  assert.ok(await pacing() > before);
});

test("the feed answers only an eligible account's own Mail link, and refuses what it cannot parse", async () => {
  const t = await mailbox({ count: 1 });
  for (const body of [{}, { email: EMAIL, after: "x" }, { email: EMAIL, limit: 0 }, { email: EMAIL, limit: 5000 }, { email: EMAIL, after: 5 }])
    assert.equal((await t.s.call("POST", "/v1/mail/feed", { session: t.phone.session, body })).status, 400, JSON.stringify(body));
  assert.equal((await t.s.call("POST", "/v1/mail/feed", { body: { email: EMAIL } })).status, 401);
  assert.equal((await t.s.call("POST", "/v1/mail/feed", { session: t.phone.session, body: { email: "someone@plan.example" } })).status, 403);
  assert.equal((await t.s.call("POST", "/v1/mail/check", { session: t.phone.session, body: { email: EMAIL, ids: ["m1"] } })).status, 409);
  await t.s.db.run("UPDATE feature_access SET expires_at=? WHERE feature='email'", t.s.now() - 1);
  assert.equal((await t.feed(t.phone)).status, 403);
  assert.equal(t.gmail.calls.length, 0);
});

test("listings add and never remove; a read older than what is stored changes nothing", () => {
  const port = sqlitePort(new DatabaseSync(":memory:"));
  box.ensure(port, { sub: "sub", email: EMAIL, account: "acc", epoch: "e", now: 1 });
  const scan = box.begin(port, { historyId: 100, labels: ["INBOX", "UNREAD"], now: 1 });
  box.applyListing(port, { label: "INBOX", ids: [{ id: "a", threadId: "t" }], floor: scan.floor, now: 1 });
  box.applyListing(port, { label: "", ids: [{ id: "a", threadId: "t" }], floor: scan.floor, now: 1 });
  for (let s = box.scanState(port); s; s = box.scanState(port)) {
    if (s.phase === "listing") box.setMeta(port, "scan", JSON.stringify({ ...s, phase: "closing", after: 0 }));
    else box.closeBatch(port, { scan: s, now: 1 });
  }
  assert.deepEqual(box.feed(port, { after: null, limit: 10 }).entries.map((e) => e.labels), [["INBOX"]]);
  box.applyRead(port, { id: "a", threadId: "t", labelIds: ["INBOX", "STARRED"], historyId: "150" }, { now: 2 });
  box.applyRead(port, { id: "a", threadId: "t", labelIds: [], historyId: "120" }, { now: 3 });
  const [entry] = box.feed(port, { after: null, limit: 10 }).entries;
  assert.deepEqual(entry.labels, ["INBOX", "STARRED"]);
  assert.equal(entry.history, "150");
  // A later listing without STARRED says nothing about it.
  box.applyListing(port, { label: "UNREAD", ids: [], floor: 160, now: 4, mark: false });
  assert.deepEqual(box.feed(port, { after: null, limit: 10 }).entries[0].labels, ["INBOX", "STARRED"]);
  // A deleted message is not stored again by a read in flight (invariant 29).
  box.applyGone(port, "a", { now: 5 });
  assert.equal(box.applyRead(port, { id: "a", threadId: "t", labelIds: ["INBOX"], historyId: "200" }, { now: 6 }).gone, true);
  assert.equal(box.feed(port, { after: null, limit: 10 }).entries[0].deleted, true);
});

// ---- the content fill, the bulk pull, Gmail push (MAIL-CLOUD-SYNC §2a, §5) ----

/** Full reads made after `from` (an index into gmail.calls), in order. */
const fullReads = (gmail, from = 0) => gmail.calls.slice(from).filter((c) => c.resource === "message" && c.format === "full").map((c) => c.id);
/** Runs alarms until the fill says it is done. */
async function fillDone(t) { await t.drain(async () => (await t.status()).fill.done !== null, 2000); }

test("the fill stores every message's content newest first after the scan, and skips Spam and Trash", async () => {
  const t = await mailbox({ count: 40, labels: (i) => (i === 7 ? ["SPAM"] : i === 8 ? ["TRASH"] : i % 4 ? ["Label_1"] : ["INBOX"]) });
  assert.equal((await t.feed(t.phone)).status, 200);
  await t.drain(t.settled);
  const from = t.gmail.calls.length;
  await fillDone(t);
  const filled = fullReads(t.gmail, from);
  const expected = Array.from({ length: 40 }, (_, i) => `m${40 - i}`).filter((id) => !["m7", "m8"].includes(id) && Number(id.slice(1)) % 4 !== 0);
  assert.deepEqual(filled, expected, "newest first, each once, the Inbox head already there");
  const st = await t.status();
  assert.equal(st.counts.cached, 38);
  // The devices learn it from the feed: every stored message says so.
  const entries = t.latest((await t.all(t.mac)).entries);
  for (const [id, e] of entries) assert.equal(e.content === true, !["m7", "m8"].includes(id), id);
});

test("the fill stops at its window and resumes from its watermark after a restart", async () => {
  // The fake's mail is dated 1 September; the clock is 15 October; a 30-day window holds none of it.
  const t = await mailbox({ count: 60, labels: () => ["Label_1"], config: { mailFillDays: 30 } });
  assert.equal((await t.feed(t.phone)).status, 200);
  await t.drain(t.settled);
  let from = t.gmail.calls.length;
  // A few reads, then the process goes (the Durable Object is evicted) and comes back.
  for (let i = 0; i < 6; i++) { await t.s.mailboxes.due(); t.s.advance(2000); }
  const before = fullReads(t.gmail, from);
  assert.ok(before.length >= 3 && before.length < 20, String(before.length));
  const mark = (await t.status()).fill.after;
  assert.equal(mark, before.at(-1));
  t.s.mailboxes.close();
  assert.equal((await t.feed(t.phone)).status, 200);   // arms the alarm again
  from = t.gmail.calls.length;
  await fillDone(t);
  const after = fullReads(t.gmail, from);
  assert.equal(new Set([...before, ...after]).size, before.length + after.length, "nothing read twice");
  assert.equal(after[0], `m${Number(mark.slice(1)) - 1}`, "the walk goes on below the watermark");
  assert.equal(before.length + after.length, 20, "twenty in a row older than the window end it");
  const done = (await t.status()).fill;
  assert.ok(done.done !== null);
  // Done is done: hours later nothing more is read until the next walk is due.
  const quiet = t.gmail.calls.length;
  t.s.advance(60 * 60 * 1000);
  await t.s.mailboxes.due();
  assert.equal(fullReads(t.gmail, quiet).length, 0);
});

test("the fill takes only free background slots, at the ceiling less the reserve, and a person's read goes first", async () => {
  const t = await mailbox({ count: 20, labels: () => ["Label_1"] });
  assert.equal((await t.feed(t.phone)).status, 200);
  await t.drain(t.settled);
  const times = [];
  const real = t.gmail.mailRead;
  t.s.google.mailRead = async (token, request) => {
    if (request.resource === "message") times.push({ at: t.s.now(), id: request.id });
    return real(token, request);
  };
  // Someone's read holds the identity's next slot 5 s ahead: the fill reads nothing until it frees.
  const reserved = t.s.now() + 5000;
  await t.s.db.run("UPDATE mail_read_pacing SET next_at = ? WHERE google_sub = 'sub-noor'", reserved);
  await t.s.mailboxes.due();
  await fillDone(t);
  assert.ok(times[0].at >= reserved, "no fill read while a person's slot is reserved");
  assert.equal(times.length, 20);
  for (let i = 1; i < times.length; i++) assert.ok(times[i].at - times[i - 1].at >= 811, `read ${i} ${times[i].at - times[i - 1].at} ms after the last`);
  // A device's read in the middle of a fill is served at once (its own lane), from the store.
  const answer = await t.read(t.phone, "m3");
  assert.equal(answer.status, 200);
});

test("content the fill keeps inside its window is not dropped as unused", () => {
  const db = new DatabaseSync(":memory:");
  const port = sqlitePort(db);
  box.migrate(port);
  const now = Date.UTC(2026, 9, 15);
  for (const [id, date] of [["new", now - 10 * DAY], ["old", now - 300 * DAY]]) {
    port.exec("INSERT INTO msg (id, thread, known, date, cached, used_at, labels) VALUES (?, 't', 1, ?, 100, ?, '[]')", id, date, now - 120 * DAY);
  }
  const dropped = box.maintain(port, { now, keepSince: now - 183 * DAY });
  assert.deepEqual(dropped, ["old"]);
});

test("a device pulls many messages' content at once, from the store only, and only its own", async () => {
  const t = await mailbox({ count: 6, labels: () => ["INBOX"] });
  assert.equal((await t.feed(t.phone)).status, 200);
  await t.drain(t.settled);   // the Inbox head: all six stored
  t.gmail.add("m7", ["Label_1"]);
  t.s.advance(11_000);
  await t.feed(t.phone, { fresh: true });   // m7 is known; its content is owed
  await t.s.db.run("UPDATE mail_read_pacing SET next_at = ? WHERE google_sub = 'sub-noor'", t.s.now() + 60_000);
  const reads = t.gmail.calls.length;
  const pull = await t.s.call("POST", "/v1/mail/content", { session: t.mac.session, body: { email: EMAIL, ids: ["m6", "m2", "m7", "nope"] } });
  assert.equal(pull.status, 200, pull.text);
  assert.equal(t.gmail.calls.length, reads, "a pull asks Google nothing");
  const byID = Object.fromEntries(pull.json.messages.map((m) => [m.id, m]));
  assert.equal(byID.m6.message.id, "m6");
  assert.deepEqual(byID.m6.message.labelIds, ["INBOX"]);
  assert.ok(byID.m6.message.payload, "the full message");
  assert.equal(byID.m7.missing, true);
  assert.equal(byID.nope.missing, true);
  // Sealed: the stored bytes are not the message, and one message's object does not open as another's.
  const keyOf = async (id) => `mail/${await sha256Hex("sub-noor")}/${await sha256Hex(id)}/m`;
  const sealed = await t.s.deps.blobs.get(await keyOf("m6"));
  const bytes = new Uint8Array(await new Response(sealed.body).arrayBuffer());
  assert.ok(!new TextDecoder().decode(bytes).includes("Subject m6"));
  const sha = Buffer.from(await crypto.subtle.digest("SHA-256", bytes)).toString("hex");
  assert.ok(await t.s.deps.blobs.put(await keyOf("m2"), new Blob([bytes]).stream(), { sha256: sha }));
  const swapped = await t.s.call("POST", "/v1/mail/content", { session: t.mac.session, body: { email: EMAIL, ids: ["m2"] } });
  assert.equal(swapped.json.messages[0].missing, true, "m6's object does not open as m2");
  // Another person's session cannot read this address.
  t.s.google.person("other", "sub-other", "other@plan.example");
  const other = (await t.s.signIn("other", device("device-other"))).json;
  const refused = await t.s.call("POST", "/v1/mail/content", { session: other.session, body: { email: EMAIL, ids: ["m6"] } });
  assert.equal(refused.status, 403);
  assert.equal((await t.s.call("POST", "/v1/mail/content", { body: { email: EMAIL, ids: ["m6"] } })).status, 401);
  assert.equal((await t.s.call("POST", "/v1/mail/content", { session: t.mac.session, body: { email: EMAIL, ids: Array.from({ length: 51 }, (_, i) => `x${i}`) } })).status, 400);
});

// Pub/Sub's OIDC token, checked for real: an RSA key of the test's own stands in for Google's.
async function pushSigner() {
  const pair = await crypto.subtle.generateKey({ name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" }, true, ["sign", "verify"]);
  const jwk = { ...(await crypto.subtle.exportKey("jwk", pair.publicKey)), kid: "k1", alg: "RS256", use: "sig" };
  const b64 = (bytes) => Buffer.from(bytes).toString("base64url");
  const sign = async (claims, header = { alg: "RS256", kid: "k1", typ: "JWT" }) => {
    const input = `${b64(Buffer.from(JSON.stringify(header)))}.${b64(Buffer.from(JSON.stringify(claims)))}`;
    return `${input}.${b64(new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5", pair.privateKey, new TextEncoder().encode(input))))}`;
  };
  return { jwk, sign };
}

test("a Pub/Sub push token is accepted only from Google, for our audience and service account, in date", async () => {
  const { createGoogle } = await import("../src/google.js");
  const { GoogleRefused } = await import("../src/google.js");
  const signer = await pushSigner();
  const now = Date.UTC(2026, 9, 15);
  const google = createGoogle({}, async () => new Response(JSON.stringify({ keys: [signer.jwk] }), { headers: { "cache-control": "max-age=3600" } }), () => now);
  const audience = "https://service.test/v1/mail/push", serviceAccount = "push@project.iam.gserviceaccount.com";
  const good = { iss: "https://accounts.google.com", aud: audience, email: serviceAccount, email_verified: true, iat: now / 1000 - 10, exp: now / 1000 + 3600 };
  assert.deepEqual(await google.verifyPushToken(await signer.sign(good), { audience, serviceAccount }), { email: serviceAccount });
  for (const [why, claims] of [
    ["audience", { ...good, aud: "https://elsewhere.test/v1/mail/push" }],
    ["issuer", { ...good, iss: "https://evil.test" }],
    ["expired", { ...good, exp: now / 1000 - 120 }],
    ["future", { ...good, iat: now / 1000 + 600 }],
    ["service account", { ...good, email: "someone@project.iam.gserviceaccount.com" }],
    ["unverified", { ...good, email_verified: false }],
  ]) await assert.rejects(google.verifyPushToken(await signer.sign(claims), { audience, serviceAccount }), GoogleRefused, why);
  const forged = (await signer.sign(good)).split(".");
  forged[1] = Buffer.from(JSON.stringify({ ...good, aud: audience, email: serviceAccount, exp: now / 1000 + 99999 })).toString("base64url");
  await assert.rejects(google.verifyPushToken(forged.join("."), { audience, serviceAccount }), GoogleRefused, "signature");
  await assert.rejects(google.verifyPushToken(await signer.sign(good, { alg: "none", kid: "k1" }), { audience, serviceAccount }), GoogleRefused, "alg");
});

const PUSH_CONFIG = { mailPushTopic: "projects/PROJECT/topics/gmail", mailPushServiceAccount: "push@project.iam.gserviceaccount.com" };
const notice = (email, historyId = "1") => ({ message: { data: Buffer.from(JSON.stringify({ emailAddress: email, historyId })).toString("base64"), messageId: "1" }, subscription: "projects/PROJECT/subscriptions/gmail" });

/** A mailbox with a push topic: the fake Google takes watches and accepts `token-good` as Pub/Sub's. */
async function pushed(options = {}) {
  const t = await mailbox({ ...options, config: { ...PUSH_CONFIG, ...(options.config ?? {}) }, push: true });
  const g = t.s.google;
  g.mailWatches = []; g.mailStops = [];
  g.mailWatch = async (token, body) => { g.mailWatches.push({ token, ...body }); return { historyId: String(t.gmail.historyId), expiration: String(t.s.now() + 7 * DAY) }; };
  g.mailStopWatch = async (token) => { g.mailStops.push(token); };
  g.verifyPushToken = async (jwt, expected) => {
    if (jwt !== "token-good-0123456789abcdef") { const { GoogleRefused } = await import("../src/google.js"); throw new GoogleRefused("push token signature"); }
    assert.equal(expected.audience, "https://service.test/v1/mail/push");
    assert.equal(expected.serviceAccount, PUSH_CONFIG.mailPushServiceAccount);
    return { email: expected.serviceAccount };
  };
  const post = (body, token = "token-good-0123456789abcdef") => t.s.call("POST", "/v1/mail/push", { body, headers: token ? { authorization: `Bearer ${token}` } : {} });
  return { ...t, post };
}

test("Gmail's push wakes the right mailbox, which reads history, stores the new mail, and pushes the devices once", async () => {
  const t = await pushed({ count: 3, labels: () => ["INBOX"] });
  assert.equal((await t.feed(t.phone)).status, 200);
  await t.drain(t.settled);
  assert.equal(t.s.google.mailWatches.length, 1, "the mailbox started its watch");
  assert.equal(t.s.google.mailWatches[0].topicName, PUSH_CONFIG.mailPushTopic);
  assert.ok((await t.status()).watchExpires > t.s.now() + 6 * DAY, "recorded");
  // A third device on the account whose build has no Mail (Stable): it takes no mail push.
  const stable = device("device-stable", { platform: "ipad", push: pushToken(3), capabilities: [] });
  assert.equal((await t.s.signIn("noor", stable, t.phone.session)).status, 200);
  t.s.apns.sends.length = 0;
  // A burst of new mail, a notice for each.
  for (const id of ["n1", "n2", "n3"]) t.gmail.add(id, ["INBOX", "UNREAD"]);
  t.s.advance(1000);   // well inside every poll interval: only the push can wake it now
  for (let i = 0; i < 3; i++) assert.equal((await t.post(notice(EMAIL, "99999999"))).status, 204);
  await t.s.mailboxes.due();
  for (const id of ["n1", "n2", "n3"]) assert.equal(t.gmail.reads("message", id, "full"), 1, id);
  const mailPushes = t.s.apns.sends.filter((p) => p.collapseId === "mail");
  assert.equal(mailPushes.length, 2, "one push to each of the two devices with Mail");
  assert.ok(!mailPushes.some((p) => p.token === stable.push), "none to the device without Mail");
  assert.deepEqual(mailPushes[0].payload, { aps: { "content-available": 1 }, b: { k: "mail" } });
  assert.ok(!JSON.stringify(mailPushes[0].payload).includes("@"), "no address in a push");
  // More mail right after: coalesced, the next push waits out the gap.
  t.gmail.add("n4", ["INBOX"]);
  await t.post(notice(EMAIL));
  await t.s.mailboxes.due();
  assert.equal(t.s.apns.sends.filter((p) => p.collapseId === "mail").length, 2, "not yet");
  t.s.advance(15_000);
  await t.s.mailboxes.due();
  assert.equal(t.s.apns.sends.filter((p) => p.collapseId === "mail").length, 4);
  // The new entries reach a device with their content stored.
  const entries = t.latest((await t.all(t.phone)).entries);
  for (const id of ["n1", "n2", "n3", "n4"]) assert.equal(entries.get(id).content, true, id);
});

test("the push endpoint refuses a bad token and ignores what it cannot place", async () => {
  const t = await pushed({ count: 1 });
  assert.equal((await t.feed(t.phone)).status, 200);
  await t.drain(t.settled);
  const polls = t.gmail.reads("history");
  assert.equal((await t.post(notice(EMAIL), null)).status, 401);
  assert.equal((await t.post(notice(EMAIL), "token-bad-0123456789abcdef")).status, 401);
  assert.equal((await t.post(notice("stranger@plan.example"))).status, 204);
  assert.equal((await t.post({ message: { data: "not base64 json" } })).status, 204);
  await t.s.mailboxes.due();
  assert.equal(t.gmail.reads("history"), polls, "nothing woke");
  // Without push configured the route does not exist.
  const plain = await mailbox({ count: 1 });
  assert.equal((await plain.s.call("POST", "/v1/mail/push", { body: notice(EMAIL), headers: { authorization: "Bearer token-good-0123456789abcdef" } })).status, 404);
});

test("with a live watch the idle poll is stretched; without one it is not", async () => {
  const run = async (config) => {
    const t = config ? await pushed({ count: 1 }) : await mailbox({ count: 1 });
    assert.equal((await t.feed(t.phone)).status, 200);
    await t.drain(t.settled);
    t.s.advance(2 * DAY);   // nobody read the feed for two days: the idle cadence
    await t.s.mailboxes.due();
    const before = t.gmail.reads("history");
    t.s.advance(60 * 60 * 1000);
    await t.s.mailboxes.due();
    return t.gmail.reads("history") - before;
  };
  assert.ok((await run(false)) >= 1, "polled within the hour");
  assert.equal(await run(true), 0, "a watched mailbox waits for the push (and polls every two hours)");
});

test("the quarter-hour job renews a watch a day before it ends, and turning Mail off stops it", async () => {
  const { runJob } = await import("../src/job.js");
  const t = await pushed({ count: 1 });
  assert.equal((await t.feed(t.phone)).status, 200);
  await t.drain(t.settled);
  assert.equal(t.s.google.mailWatches.length, 1);
  assert.equal((await runJob(t.s.deps)).mailWatches, undefined, "nothing due");
  t.s.advance(6 * DAY + 60_000);
  const result = await runJob(t.s.deps);
  assert.deepEqual(result.mailWatches, { due: 1, renewed: 1 });
  assert.equal(t.s.google.mailWatches.length, 2);
  const row = await t.s.db.first("SELECT watch_expires_at FROM mail_mailboxes WHERE google_sub = 'sub-noor'");
  assert.equal(Number(row.watch_expires_at), t.s.now() + 7 * DAY);
  assert.equal((await t.s.call("DELETE", "/v1/google/mail", { session: t.phone.session, body: { email: EMAIL } })).status, 204);
  assert.equal(t.s.google.mailStops.length, 1, "stopped while the grant still worked");
  assert.equal(await t.s.count("mail_mailboxes"), 0);
});


// ---- the fill uses the free budget (MAIL-CLOUD-SYNC §5a) ----

/** Times of the mailbox's full reads, and of every sleep a read made waiting for its slot. */
function recordReads(t) {
  const reads = [], waits = [];
  const real = t.gmail.mailRead;
  t.s.google.mailRead = async (token, request) => {
    if (request.resource === "message" && (request.query.find((q) => q.name === "format")?.value ?? "full") === "full") reads.push(t.s.now());
    return t.answer ? t.answer(token, request, real) : real(token, request);
  };
  const sleep = t.s.deps.sleep;
  t.s.deps.sleep = async (ms) => { waits.push(ms); return sleep(ms); };
  return { reads, waits };
}

test("in a quiet minute the fill reads at the ceiling less the reserve: 4,440 units, 74 full reads", async () => {
  const t = await mailbox({ count: 200, labels: () => ["Label_1"] });
  assert.equal((await t.feed(t.phone)).status, 200);
  await t.drain(t.settled);
  const { reads } = recordReads(t);
  const start = t.s.now();
  await t.drain(async () => t.s.now() - start >= 60_000, 5000);
  const inMinute = reads.filter((at) => at - start < 60_000).length;
  assert.ok(inMinute >= 73 && inMinute <= 75, `${inMinute} full reads in a quiet minute`);
  assert.ok(inMinute * 60 <= 4500 - 60 + 60, "never above the ceiling");
});

test("a person's read arriving during a fill burst gets a slot within one slot interval", async () => {
  const t = await mailbox({ count: 120, labels: () => ["Label_1"] });
  assert.equal((await t.feed(t.phone)).status, 200);
  await t.drain(t.settled);
  const { reads, waits } = recordReads(t);
  const start = t.s.now();
  await t.drain(async () => reads.length >= 10, 2000);   // the fill is running flat out
  t.gmail.add("fresh", ["Label_1"]);
  t.s.advance(11_000);
  await t.feed(t.phone, { fresh: true });                // knows "fresh"; not stored
  waits.length = 0;
  const answer = await t.read(t.phone, "fresh");         // a person opens it: an interactive read
  assert.equal(answer.status, 200);
  assert.ok(waits.every((ms) => ms <= 800), `waited ${waits} ms`);
  assert.ok(reads.length >= 10 && start <= t.s.now());
});

test("Google's limit halves the fill for five minutes, then it ramps back to full", async () => {
  const t = await mailbox({ count: 900, labels: () => ["Label_1"] });
  assert.equal((await t.feed(t.phone)).status, 200);
  await t.drain(t.settled);
  const { reads } = recordReads(t);
  await t.drain(async () => reads.length >= 5, 2000);
  let limitOnce = true;
  t.answer = async (token, request, real) => {
    if (limitOnce && request.resource === "message") { limitOnce = false; return { status: 429, body: { error: { code: 429, errors: [{ reason: "rateLimitExceeded" }] } } }; }
    return real(token, request);
  };
  await t.drain(async () => !limitOnce, 200);
  const limitedAt = t.s.now();
  const count = (from, to) => reads.filter((at) => at >= limitedAt + from && at < limitedAt + to).length;
  await t.drain(async () => t.s.now() - limitedAt >= 11 * 60_000, 20_000);
  const halved = count(60_000, 120_000), ramping = count(7 * 60_000, 8 * 60_000), full = count(10 * 60_000, 11 * 60_000);
  assert.ok(halved >= 36 && halved <= 38, `${halved} reads a minute while backed off (37 is half)`);
  assert.ok(ramping > halved && ramping < full, `ramping: ${ramping}`);
  assert.ok(full >= 73 && full <= 75, `${full} reads a minute after the ramp`);
});

test("listings and verification go before the fill", async () => {
  const t = await mailbox({ count: 60, labels: () => ["Label_1"] });
  assert.equal((await t.feed(t.phone)).status, 200);
  await t.drain(t.settled);
  const before = t.gmail.calls.length;
  // A device asks the mailbox to check five messages (verification), and Gmail's history expires
  // (a new scan): both run ahead of any fill read.
  await t.s.call("POST", "/v1/mail/check", { session: t.phone.session, body: { email: EMAIL, ids: ["m1", "m2", "m3", "m4", "m5"] } });
  t.gmail.oldest = Number.MAX_SAFE_INTEGER;
  t.s.advance(11_000);
  await t.feed(t.phone, { fresh: true });   // the poll's 404 expires the position: a new scan
  t.gmail.oldest = 0;
  await t.drain(async () => (await t.status()).fill.done !== null, 3000);
  const calls = t.gmail.calls.slice(before).map((c, i) => ({ ...c, i }));
  const firstFill = calls.find((c) => c.resource === "message" && c.format === "full")?.i ?? Infinity;
  const lastListing = Math.max(...calls.filter((c) => c.resource === "messages").map((c) => c.i));
  assert.ok(Number.isFinite(lastListing), "a scan ran");
  assert.ok(lastListing < firstFill, `every listing before the first fill read: ${calls.slice(0, 30).map((c) => c.resource + (c.format ? ":" + c.format : "")).join(" ")}`);
});

const policyOperation = (n) => `${String(n).padStart(8, '0')}-1111-1111-1111-111111111111`;
function policyRequest(t, who, sender, change = {}) {
  return t.s.call("POST", "/v1/mail/sender-policy", { session: who.session, body: { email: EMAIL, sender, ...change } });
}

test("sender blocking is shared across devices and enforces future incoming mail with Gmail readback", async () => {
  const t = await mailbox(), sender = "offers@shop.example";
  assert.equal((await policyRequest(t, t.phone, sender)).json.blocked, false);
  const block = await policyRequest(t, t.phone, sender, { blocked: true, revision: 0, operation: policyOperation(1) });
  assert.equal(block.status, 200, block.text);
  assert.equal((await policyRequest(t, t.mac, sender)).json.blocked, true);
  for (const [id, from] of [["blocked", sender], ["allowed", "other@shop.example"], ["old", sender]]) {
    t.gmail.add(id); t.gmail.messages.get(id).from = from; t.gmail.messages.get(id).internalDate = t.s.now() + (id === "old" ? -1000 : 1000);
  }
  await t.feed(t.phone);
  await t.drain(async () => t.gmail.messages.get("blocked").labels.has("SPAM") && await t.settled());
  assert.equal(t.gmail.messages.get("blocked").labels.has("INBOX"), false);
  assert.equal(t.gmail.messages.get("allowed").labels.has("INBOX"), true);
  assert.equal(t.gmail.messages.get("old").labels.has("INBOX"), true, "an old message is not newly blocked by a content read");
  assert.equal((await t.read(t.phone, "old")).status, 200);
  assert.equal(t.gmail.messages.get("old").labels.has("INBOX"), true);
  const labels = t.latest((await t.all(t.mac)).entries).get("blocked").labels;
  assert.ok(labels.includes("SPAM")); assert.ok(!labels.includes("INBOX"));
  assert.equal((await policyRequest(t, t.mac, sender, { blocked: false, revision: 1, operation: policyOperation(2) })).status, 200);
  t.gmail.add("later"); t.gmail.messages.get("later").from = sender; t.gmail.messages.get("later").internalDate = t.s.now() + 1000;
  await t.s.mailboxes.get("sub-noor").wake();
  await t.drain(async () => t.latest((await t.all(t.phone)).entries).has("later") && await t.settled());
  assert.ok(t.gmail.messages.get("later").labels.has("INBOX"));
  assert.ok(t.gmail.messages.get("blocked").labels.has("SPAM"));
  assert.equal((await policyRequest(t, t.phone, sender, { blocked: true, revision: 0, operation: policyOperation(1) })).status, 409);
});

test("a lost Gmail spam mutation response reconciles before retry without a duplicate write", async () => {
  const t = await mailbox(), sender = "offers@shop.example";
  await policyRequest(t, t.phone, sender, { blocked: true, revision: 0, operation: policyOperation(1) });
  let lose = true;
  t.s.google.mailMutation = async (...args) => {
    const answer = await t.gmail.mailMutation(...args);
    if (lose) { lose = false; throw new Error("response lost"); }
    return answer;
  };
  t.gmail.add("blocked"); t.gmail.messages.get("blocked").from = sender; t.gmail.messages.get("blocked").internalDate = t.s.now() + 1000;
  await t.feed(t.phone);
  await t.drain(async () => !lose && await t.settled());
  assert.ok(t.gmail.messages.get("blocked").labels.has("SPAM"));
  assert.equal(t.gmail.writes.filter(w => w.id === "blocked" && w.add?.includes("SPAM")).length, 1);
  assert.ok(t.latest((await t.all(t.phone)).entries).get("blocked").labels.includes("SPAM"));
});

test("sender-policy endpoint requires account access and rejects malformed and own-address rules", async () => {
  const t = await mailbox(), sender = "offers@shop.example";
  assert.equal((await t.s.call("POST", "/v1/mail/sender-policy", { body: { email: EMAIL, sender } })).status, 401);
  assert.equal((await policyRequest(t, t.phone, EMAIL)).status, 400);
  assert.equal((await policyRequest(t, t.phone, sender, { blocked: true })).status, 400);
  t.s.google.person("other", "sub-other", "other@plan.example");
  const other = (await t.s.signIn("other", device("device-other"))).json;
  assert.equal((await policyRequest(t, other, sender)).status, 403);
  await t.s.call("DELETE", "/v1/google/mail", { session: t.phone.session, body: { email: EMAIL } });
  assert.equal((await policyRequest(t, t.phone, sender)).status, 403);
});

test("read-only grants cannot change sender policies", async () => {
  const t = await mailbox(), sender = "offers@shop.example";
  await t.s.db.run("UPDATE mail_grants SET scopes=? WHERE google_sub=?", "https://www.googleapis.com/auth/gmail.readonly", "sub-noor");
  assert.equal((await policyRequest(t, t.phone, sender)).status, 200);
  assert.equal((await policyRequest(t, t.phone, sender, { blocked: true, revision: 0, operation: policyOperation(1) })).status, 403);
});

test("an acknowledged unblock fences an in-flight content-read spam application", async () => {
  const t = await mailbox(), sender = "offers@shop.example";
  await policyRequest(t, t.phone, sender, { blocked: true, revision: 0, operation: policyOperation(1) });
  t.gmail.add("blocked"); t.gmail.messages.get("blocked").from = sender; t.gmail.messages.get("blocked").internalDate = t.s.now() + 1000;
  let began, release;
  const started = new Promise(resolve => { began = resolve; });
  const gate = new Promise(resolve => { release = resolve; });
  t.s.google.mailMutation = async (...args) => { began(); await gate; return t.gmail.mailMutation(...args); };
  const reading = t.read(t.phone, "blocked");
  await started;
  let acknowledged = false;
  const unblocking = policyRequest(t, t.mac, sender, { blocked: false, revision: 1, operation: policyOperation(2) }).then(value => { acknowledged = true; return value; });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(acknowledged, false, "unblock waits for already-started rule effects");
  release();
  assert.equal((await reading).status, 200);
  assert.equal((await unblocking).status, 200);
  assert.equal((await policyRequest(t, t.phone, sender)).json.blocked, false);
});
