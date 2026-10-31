// The data platform's routes (src/sync-routes.js) on the Node adapters: /v2/sync, blobs, the
// Health consent, export, account deletion, the sync push, the change stream, /v1/account's move state.
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { setup, device, pushToken, START, DAY } from "./helpers.js";
import { sha256Hex } from "../src/crypto.js";

const clock = (ms, device = "phone") => `${String(ms).padStart(13, "0")}.0000.${device}`;

/** Ann with an iPhone and a Mac that take pushes, and an iPad that doesn't. */
async function ann() {
  const s = setup();
  s.google.person("c1", "sub-1", "ann@example.com");
  const phone = (await s.signIn("c1", device("phone-0001", { push: pushToken(1) }))).json;
  const mac = (await s.signIn("c1", device("mac-00000001", { platform: "mac", push: pushToken(2) }))).json;
  const ipad = (await s.signIn("c1", device("ipad-0001", { platform: "ipad" }))).json;
  const space = `sp_${phone.account.id}`;
  const sync = (who, body) => s.call("POST", "/v2/sync", { body, session: who.session });
  return { s, phone, mac, ipad, space, sync };
}

async function putBlob(s, session, bytes, { sha, length = bytes.length, query = "", type = "notes.voiceNote" } = {}) {
  const hash = sha ?? await sha256Hex(new TextDecoder().decode(bytes));
  const headers = { authorization: `Bearer ${session}`, "content-type": "application/octet-stream" };
  if (type !== null) headers["x-banana-type"] = type;
  if (length !== null) headers["content-length"] = String(length);
  const r = await s.app.request(`/v2/blobs/${hash}${query}`, { method: "PUT", headers, body: bytes });
  return { status: r.status, json: r.status === 204 ? null : await r.json(), sha: hash };
}

const meal = (title, ms = START) => ({ type: "food.meal", id: "m1", set: { title }, clocks: { title: clock(ms) } });
const extra = (title, ms = START) => ({ type: "plan.extra", id: "e1", set: { title, day: "2026-10-15" }, clocks: { title: clock(ms), day: clock(ms) } });

test("sync: the personal space is made on first use, the device row says what the device is", async () => {
  const { s, phone, mac, space, sync } = await ann();
  const r = await sync(phone, { device: "phone-0001", since: 0, changes: [extra("Swim")] });
  assert.equal(r.status, 200);
  assert.deepEqual([r.json.head, r.json.next, r.json.more, r.json.rejected, r.json.consents], [1, 1, false, [], { health: false }]);
  assert.deepEqual(r.json.applied, [{ type: "plan.extra", id: "e1", clocks: { title: clock(START), day: clock(START) }, deleted: null }]);
  assert.equal(r.json.changes[0].fields.title, "Swim");
  assert.equal(r.json.now, START);
  assert.match(r.json.epoch, /^[0-9a-f]{24}$/);
  assert.deepEqual(await s.db.all("SELECT id, owner, kind FROM spaces"), [{ id: space, owner: phone.account.id, kind: "personal" }]);
  assert.deepEqual(await s.db.all("SELECT space_id, account_id, role FROM space_members"), [{ space_id: space, account_id: phone.account.id, role: "owner" }]);
  assert.equal((await s.db.first("SELECT last_sync_at FROM devices WHERE id = 'phone-0001'")).last_sync_at, START);
  // The Mac pulls it; a hub-only type from the Mac is refused whatever its body says.
  const pulled = await sync(mac, { device: "mac-00000001", since: 0, changes: [{ type: "core.hubStatus", id: "h", set: { v: 1 }, clocks: { v: clock(START, "mac") } }], platform: "iphone" });
  assert.deepEqual(pulled.json.rejected, [{ type: "core.hubStatus", id: "h", reason: "hub_only" }]);
  assert.deepEqual(pulled.json.changes.map((c) => c.id), ["e1"]);
});

test("sync: refused requests", async () => {
  const { s, phone, sync } = await ann();
  s.google.person("c2", "sub-2", "bob@example.com");
  const bob = (await s.signIn("c2", device("phone-0002"))).json;
  assert.equal((await s.call("POST", "/v2/sync", { body: { device: "phone-0001" } })).status, 401);
  assert.deepEqual((await sync(phone, { device: "phone-0002", changes: [] })).json, { error: "unknown_device" }, "Bob's phone isn't Ann's");
  assert.equal((await sync(phone, { device: "nope-0000", changes: [] })).status, 404);
  for (const body of [{ changes: [] }, { device: "phone-0001", since: -1 }, { device: "phone-0001", since: 1.5 }, { device: "phone-0001", changes: {} }]) {
    assert.equal((await sync(phone, body)).status, 400, JSON.stringify(body));
  }
  assert.equal((await s.call("POST", "/v2/sync", { body: "{not json", session: phone.session })).status, 400);
  assert.deepEqual((await sync(phone, { device: "phone-0001", changes: Array.from({ length: 501 }, () => extra("x")) })).json, { error: "too_many_changes" });
  assert.equal((await s.call("POST", "/v2/sync", { body: JSON.stringify({ device: "phone-0001", pad: "x".repeat(2 * 1024 * 1024) }), session: phone.session })).status, 413);
  assert.deepEqual((await sync(phone, { device: "phone-0001", space: `sp_${bob.account.id}` })).json, { error: "not_member" });
  assert.equal((await sync(bob, { device: "phone-0002", space: `sp_${phone.account.id}` })).status, 403);
});

test("sync push: to the account's other devices with a push token, at most once every 3 s, the rest when the window ends, never for a no-op", async () => {
  const { s, phone, mac, sync } = await ann();
  await sync(phone, { device: "phone-0001", changes: [extra("Swim")] });
  await s.settle();
  assert.deepEqual(s.apns.sends.map((p) => [p.token, p.collapseId, p.pushType ?? "background"]), [[pushToken(2), "sync", "background"]]);
  assert.deepEqual(s.apns.sends[0].payload, { aps: { "content-available": 1 }, b: { k: "sync" } });
  assert.match((await s.db.first("SELECT push_status FROM devices WHERE id = 'mac-00000001'")).push_status, /^200/);

  // Within 3 s: no push at once, one when the window ends (the test clock jumps to it).
  s.advance(1000);
  await sync(phone, { device: "phone-0001", changes: [extra("Run", START + 1000)] });
  assert.equal(s.apns.sends.length, 1);
  await s.settle();
  assert.deepEqual([s.sleeps, s.now(), s.apns.sends.map((p) => p.token)], [[2000], START + 3000, [pushToken(2), pushToken(2)]]);

  s.advance(3000);
  await sync(phone, { device: "phone-0001", changes: [extra("Run", START + 1000)] });   // a retry: nothing changes
  await sync(phone, { device: "phone-0001", changes: [] });
  await s.settle();
  assert.equal(s.apns.sends.length, 2, "a no-op pushes nothing");

  await sync(mac, { device: "mac-00000001", changes: [extra("Walk", START + 5000)] });
  await s.settle();
  assert.deepEqual(s.apns.sends.slice(2).map((p) => p.token), [pushToken(1)], "the Mac's change goes to the phone, not the Mac");
});

test("trailing sync push: one per window, to every device once two devices' changes joined it; a lost one doesn't block the next", async () => {
  const { s, phone, mac, sync } = await ann();
  await sync(phone, { device: "phone-0001", changes: [extra("Swim")] });
  s.advance(500);
  await sync(phone, { device: "phone-0001", changes: [extra("Run", START + 500)] });
  s.advance(500);
  await sync(mac, { device: "mac-00000001", changes: [extra("Walk", START + 1000)] });
  await sync(phone, { device: "phone-0001", changes: [extra("Row", START + 1001)] });
  await s.settle();
  assert.deepEqual(s.sleeps, [2500], "one waiter for the window");
  assert.deepEqual(s.apns.sends.map((p) => p.collapseId), ["sync", "sync", "sync"]);
  assert.deepEqual([s.apns.sends[0].token, s.apns.sends.slice(1).map((p) => p.token).sort()], [pushToken(2), [pushToken(1), pushToken(2)]],
    "the leading push to the Mac, then the trailing one to both");
  assert.deepEqual(await s.db.first("SELECT sync_push_due_at, sync_push_from FROM accounts"), { sync_push_due_at: null, sync_push_from: null });

  // A slot whose waiter died with its isolate: stale after 10 s, then the next change opens a new one.
  s.advance(10_000);
  await s.db.run("UPDATE accounts SET last_sync_push_at = ?, sync_push_due_at = ?, sync_push_from = 'phone-0001'", s.now() - 1000, s.now() - 11_000);
  await sync(mac, { device: "mac-00000001", changes: [extra("Hike", s.now())] });
  await s.settle();
  assert.deepEqual(s.apns.sends.slice(3).map((p) => p.token), [pushToken(1)]);
});

test("change stream: T1 with a keyed hash of the space and its day; T2 only type and op", async () => {
  const { s, phone, space, sync } = await ann();
  const sent = [];
  s.deps.changes = { async send(records) { sent.push(...records); } };
  await s.call("PUT", "/v2/consents/health", { body: { version: "1", device: "phone-0001" }, session: phone.session });
  await sync(phone, { device: "phone-0001", changes: [extra("Swim"), meal("Oats")] });
  await s.settle();
  assert.equal(sent.length, 2);
  assert.match(sent[0].space, /^[0-9a-f]{64}$/);
  assert.ok(!sent[0].space.includes(phone.account.id) && sent[0].space !== space);
  assert.deepEqual({ ...sent[0], space: "h" }, { at: START, space: "h", type: "plan.extra", op: "create", day: "2026-10-15", fields: {} });
  assert.deepEqual(sent[1], { at: START, type: "food.meal", op: "create" });
});

test("blobs: put streams with its hash checked, always indexes, get and head stream it back", async () => {
  const { s, phone, space, sync } = await ann();
  const bytes = new TextEncoder().encode("a voice note");
  const wrong = await putBlob(s, phone.session, bytes, { sha: "0".repeat(64) });
  assert.deepEqual([wrong.status, wrong.json], [400, { error: "sha_mismatch" }]);
  assert.equal((await putBlob(s, phone.session, bytes, { length: null })).status, 411);
  assert.equal((await putBlob(s, phone.session, bytes, { length: 101 * 1024 * 1024 })).status, 413);
  assert.equal((await putBlob(s, phone.session, bytes, { sha: "XYZ" })).status, 400);
  for (const type of [null, "nope.type", "plan.extra"]) {
    assert.equal((await putBlob(s, phone.session, bytes, { type })).status, 400, `type ${type}: unknown, or one without blobs`);
  }

  const ok = await putBlob(s, phone.session, bytes);
  assert.equal(ok.status, 204);
  assert.ok(existsSync(join(s.dir, "blobs", "s", space, ok.sha)));
  const note = { type: "notes.voiceNote", id: "n1", set: { audio: { $blob: ok.sha, size: bytes.length, ext: "m4a" } }, clocks: { audio: clock(START) } };
  assert.deepEqual((await sync(phone, { device: "phone-0001", changes: [note] })).json.rejected, []);

  const got = await s.app.request(`/v2/blobs/${ok.sha}`, { headers: { authorization: `Bearer ${phone.session}` } });
  assert.deepEqual([got.status, got.headers.get("content-length"), await got.text()], [200, String(bytes.length), "a voice note"]);
  const head = await s.app.request(`/v2/blobs/${ok.sha}`, { method: "HEAD", headers: { authorization: `Bearer ${phone.session}` } });
  assert.deepEqual([head.status, head.headers.get("content-length"), await head.text()], [200, String(bytes.length), ""]);
  assert.equal((await s.call("GET", `/v2/blobs/${"1".repeat(64)}`, { session: phone.session })).status, 404);

  // A blob already in storage but missing from the index (a Worker died between the two): the
  // next put answers 204 and indexes it.
  const other = new TextEncoder().encode("a photo");
  const otherSha = await sha256Hex("a photo");
  await s.deps.blobs.put(`s/${space}/${otherSha}`, [other], { sha256: otherSha });
  const photo = { type: "podcast.listen", id: "l1", set: { route: { $blob: otherSha } }, clocks: { route: clock(START) } };
  assert.deepEqual((await sync(phone, { device: "phone-0001", changes: [photo] })).json.rejected.map((r) => r.reason), ["blob_missing"]);
  assert.equal((await putBlob(s, phone.session, other, { type: "podcast.listen" })).status, 204);
  assert.deepEqual((await sync(phone, { device: "phone-0001", changes: [photo] })).json.rejected, []);
});

test("consent: written to the space, then the log, both safe to retry; withdrawing clears T2 and trashes its blobs", async () => {
  const { s, phone, mac, space, sync } = await ann();
  assert.deepEqual((await sync(phone, { device: "phone-0001", changes: [meal("Oats")] })).json.rejected, [{ type: "food.meal", id: "m1", reason: "consent" }]);
  assert.equal((await s.call("PUT", "/v2/consents/health", { body: {}, session: phone.session })).status, 400);
  // A T2 blob needs the yes as well: refused before, nothing stored.
  const before = await putBlob(s, mac.session, new TextEncoder().encode("early.jpg"), { type: "food.mealPhoto" });
  assert.deepEqual([before.status, before.json], [403, { error: "consent" }]);
  assert.ok(!existsSync(join(s.dir, "blobs", "s", space, before.sha)));
  for (let i = 0; i < 2; i++) {
    assert.equal((await s.call("PUT", "/v2/consents/health", { body: { version: "1", device: "phone-0001" }, session: phone.session })).status, 204);
  }
  assert.deepEqual(await s.db.all("SELECT account_id, kind, version, granted_at, withdrawn_at, device, via FROM consents_log"),
    [{ account_id: phone.account.id, kind: "health", version: "1", granted_at: START, withdrawn_at: null, device: "phone-0001", via: "app" }]);

  const photo = await putBlob(s, mac.session, new TextEncoder().encode("oats.jpg"), { type: "food.mealPhoto" });
  // Uploaded for a T2 type but never named by a patch (the app stopped before sending it).
  const samples = await putBlob(s, mac.session, new TextEncoder().encode("samples"), { type: "health.workout" });
  const voice = await putBlob(s, mac.session, new TextEncoder().encode("voice"));
  assert.deepEqual([photo.status, samples.status, voice.status], [204, 204, 204]);
  const withPhoto = { type: "food.mealPhoto", id: "p1", set: { v: { $blob: photo.sha, ext: "jpg" } }, clocks: { v: clock(START, "mac") } };
  const taken = await sync(mac, { device: "mac-00000001", changes: [meal("Oats"), withPhoto, extra("Swim")] });
  assert.deepEqual([taken.json.rejected, taken.json.consents], [[], { health: true }]);

  s.advance(1000);
  assert.equal((await s.call("DELETE", "/v2/consents/health", { session: phone.session })).status, 204);
  assert.equal((await s.call("DELETE", "/v2/consents/health", { session: phone.session })).status, 204);
  await s.settle();
  const after = await sync(mac, { device: "mac-00000001", since: 0, changes: [meal("Again", START + 5)] });
  assert.deepEqual(after.json.changes.map((c) => c.type), ["plan.extra"]);
  assert.deepEqual([after.json.rejected.map((r) => r.reason), after.json.consents], [["consent"], { health: false }]);
  assert.equal((await s.db.first("SELECT withdrawn_at FROM consents_log")).withdrawn_at, START + 1000);
  assert.ok(!existsSync(join(s.dir, "blobs", "s", space, photo.sha)));
  assert.ok(existsSync(join(s.dir, "blobs", "trash", space, photo.sha)), "the photo waits in the trash");
  assert.ok(existsSync(join(s.dir, "blobs", "trash", space, samples.sha)), "and the samples nothing named");
  assert.ok(existsSync(join(s.dir, "blobs", "s", space, voice.sha)), "a T1 blob stays");
  assert.equal((await putBlob(s, mac.session, new TextEncoder().encode("late.jpg"), { type: "food.mealPhoto" })).status, 403);
});

test("export: every record with its history, the blob list and the consent, as NDJSON", async () => {
  const { s, phone, sync } = await ann();
  const blob = await putBlob(s, phone.session, new TextEncoder().encode("x"));
  await s.call("PUT", "/v2/consents/health", { body: { version: "1" }, session: phone.session });
  await sync(phone, { device: "phone-0001", changes: [extra("Swim"), meal("Oats")] });
  await sync(phone, { device: "phone-0001", changes: [extra("Run", START + 1)] });
  const r = await s.app.request("/v2/export", { headers: { authorization: `Bearer ${phone.session}` } });
  assert.equal(r.status, 200);
  assert.equal(r.headers.get("content-type"), "application/x-ndjson");
  const lines = (await r.text()).trim().split("\n").map((l) => JSON.parse(l));
  assert.deepEqual(lines.map((l) => l.kind), ["record", "record", "history", "history", "history", "blob", "consent"]);
  assert.deepEqual(lines.find((l) => l.kind === "blob").sha, blob.sha);
  assert.equal(lines.find((l) => l.kind === "record" && l.type === "plan.extra").fields.title, "Run");
});

test("account delete: the space is wiped, its blobs go to the trash, the space rows go", async () => {
  const { s, phone, space, sync } = await ann();
  const blob = await putBlob(s, phone.session, new TextEncoder().encode("route"));
  await s.call("PUT", "/v2/consents/health", { body: { version: "1" }, session: phone.session });
  await sync(phone, { device: "phone-0001", changes: [extra("Swim")] });
  s.google.person("fresh", "sub-1", "ann@example.com");
  assert.equal((await s.call("DELETE", "/v1/account", { body: { code: "fresh" }, session: phone.session })).status, 204);
  await s.settle();
  for (const table of ["spaces", "space_members", "consents_log", "accounts", "devices"]) assert.equal(await s.count(table), 0, table);
  assert.ok(!existsSync(join(s.dir, "spaces", `${space}.sqlite`)), "the space's database is gone");
  assert.ok(!existsSync(join(s.dir, "blobs", "s", space, blob.sha)));
  assert.ok(existsSync(join(s.dir, "blobs", "trash", space, blob.sha)));
});

test("/v1/account: `seeded` is the recent iPhone's types; `icloud` is purge only with the flag and every recent device seeded and flipped", async () => {
  const { s, phone, mac, ipad, sync } = await ann();
  const account = async () => (await s.call("GET", "/v1/account", { session: mac.session })).json;
  const state = (who, id, body) => s.call("PUT", `/v2/devices/${id}/sync-state`, { body, session: who.session });
  assert.deepEqual([(await account()).seeded, (await account()).icloud], [[], "keep"]);

  assert.equal((await state(phone, "phone-0001", { seeded: ["plan.extra", "food.meal", "plan.extra"], seededAt: START })).status, 204);
  assert.deepEqual((await account()).seeded, ["food.meal", "plan.extra"]);
  assert.equal((await state(phone, "mac-00000001", { seeded: ["nope.type"] })).status, 400);
  assert.equal((await state(phone, "mac-00000001", { seededAt: "today" })).status, 400);
  assert.equal((await state(phone, "unknown-0001", { seededAt: START })).status, 404);

  await state(phone, "phone-0001", { flippedAt: START });
  await state(mac, "mac-00000001", { seededAt: START, flippedAt: START });
  await state(ipad, "ipad-0001", { seededAt: START });
  await s.db.run("UPDATE accounts SET icloud_purge_ok = 1");
  assert.deepEqual([(await account()).flipped, (await account()).icloud], [false, "keep"], "the iPad hasn't flipped");
  await state(ipad, "ipad-0001", { flippedAt: START + 1 });
  assert.deepEqual([(await account()).flipped, (await account()).icloud], [true, "purge"]);
  await s.db.run("UPDATE accounts SET icloud_purge_ok = 0");
  assert.deepEqual([(await account()).flipped, (await account()).icloud], [true, "keep"], "flipped needs no flag; the purge does");

  // A month later only the Mac has been in touch: the stale phone and iPad don't count.
  await s.db.run("UPDATE accounts SET icloud_purge_ok = 1");
  await state(ipad, "ipad-0001", { flippedAt: null });
  s.advance(31 * DAY);
  await sync(mac, { device: "mac-00000001", changes: [] });
  assert.deepEqual([(await account()).seeded, (await account()).flipped, (await account()).icloud], [null, true, "purge"]);

  // The device row moving to another account forgets its move state.
  s.google.person("c2", "sub-2", "bob@example.com");
  await s.signIn("c2", device("mac-00000001", { platform: "mac" }));
  assert.deepEqual(await s.db.first("SELECT seeded_at, flipped_at FROM devices WHERE id = 'mac-00000001'"), { seeded_at: null, flipped_at: null });
});

test("blob put races: a withdrawal during the upload removes what it put; a trash move during it is undone", async () => {
  const { s, phone, space } = await ann();
  const blobs = s.deps.blobs;
  const exists = (prefix, sha) => existsSync(join(s.dir, "blobs", prefix, space, sha));
  await s.call("PUT", "/v2/consents/health", { body: { version: "1" }, session: phone.session });

  // The consent goes while the bytes are on their way: the space refuses them, the route deletes them.
  s.deps.blobs = { ...blobs, async head(key) { await s.deps.spaces.get(space).withdrawConsent("health"); return blobs.head(key); } };
  const raced = await putBlob(s, phone.session, new TextEncoder().encode("late samples"), { type: "health.workout" });
  assert.deepEqual([raced.status, raced.json, exists("s", raced.sha)], [403, { error: "consent" }, false]);
  s.deps.blobs = blobs;

  // Bytes already stored (for a T2 type) are uploaded again for a T1 one, and the withdrawal's
  // trash move runs between the route's look and the index: the file comes back.
  await s.call("PUT", "/v2/consents/health", { body: { version: "1" }, session: phone.session });
  const bytes = new TextEncoder().encode("shared bytes");
  const first = await putBlob(s, phone.session, bytes, { type: "health.workout" });
  assert.equal(first.status, 204);
  s.deps.blobs = { ...blobs, async head(key) {
    const found = await blobs.head(key);
    await s.deps.spaces.get(space).withdrawConsent("health");
    await s.settle();
    return found;
  } };
  const again = await putBlob(s, phone.session, bytes, { type: "notes.voiceNote" });
  s.deps.blobs = blobs;
  assert.equal(again.status, 204);
  assert.deepEqual([exists("s", first.sha), exists("trash", first.sha)], [true, false]);
});

test('keep "latest": publishing a new Health snapshot moves the previous one to the trash', async () => {
  const { s, phone, space, sync } = await ann();
  await s.call("PUT", "/v2/consents/health", { body: { version: "1" }, session: phone.session });
  const shas = [];
  for (const [i, text] of ["snapshot one", "snapshot two"].entries()) {
    const blob = await putBlob(s, phone.session, new TextEncoder().encode(text), { type: "health.snapshot" });
    shas.push(blob.sha);
    const r = await sync(phone, { device: "phone-0001", changes: [{ type: "health.snapshot", id: "hub", set: { v: { $blob: blob.sha } }, clocks: { v: clock(START + i) } }] });
    assert.deepEqual(r.json.rejected, []);
  }
  await s.settle();
  assert.deepEqual([existsSync(join(s.dir, "blobs", "s", space, shas[0])), existsSync(join(s.dir, "blobs", "trash", space, shas[0]))], [false, true]);
  assert.ok(existsSync(join(s.dir, "blobs", "s", space, shas[1])));
});

test("the consent log names a handful of consent texts, not one row per made-up string (audit run-1)", async () => {
  const { s, phone } = await ann();
  assert.equal((await s.call("PUT", "/v2/consents/health", { body: { version: "not a version!", device: "phone-0001" }, session: phone.session })).status, 400);
  let last;
  for (let i = 0; i < 21; i++) last = await s.call("PUT", "/v2/consents/health", { body: { version: `health-2026-10-${String(i).padStart(2, "0")}`, device: "phone-0001" }, session: phone.session });
  assert.equal(last.status, 409);
  assert.equal(await s.count("consents_log", "withdrawn_at IS NULL"), 20);
  // The same version again adds nothing.
  assert.equal((await s.call("PUT", "/v2/consents/health", { body: { version: "health-2026-10-00", device: "phone-0001" }, session: phone.session })).status, 204);
  assert.equal(await s.count("consents_log"), 20);
});
