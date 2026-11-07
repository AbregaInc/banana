// The shared cloud mailbox (docs/design/MAIL-CLOUD-SYNC.md): one Google download per message for
// every device, Gmail's order kept, the device feed, content from the store, deletion, pacing.

import test from "node:test";
import assert from "node:assert/strict";
import { setup, device, DAY } from "./helpers.js";
import { fakeGmail } from "./fake-gmail.js";
import { sha256Hex } from "../src/crypto.js";
import * as box from "../src/mail-mailbox.js";
import { sqlitePort } from "../src/adapters/spaces-sqlite.js";
import { DatabaseSync } from "node:sqlite";

const EMAIL = "noor@plan.example";

async function mailbox({ count = 0, labels } = {}) {
  const s = setup();
  s.deps.sleep = async (ms) => s.advance(ms);
  const gmail = fakeGmail();
  Object.assign(s.google, { mailRead: gmail.mailRead, mailMessage: gmail.mailMessage, mailMutation: gmail.mailMutation });
  s.google.person("noor", "sub-noor", EMAIL);
  const phone = (await s.signIn("noor", device("device-phone"))).json;
  const mac = (await s.signIn("noor", device("device-mac1", { platform: "mac" }))).json;
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
