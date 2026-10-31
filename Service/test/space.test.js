// The space core (src/space.js) on node:sqlite: the merge fixtures shared with the app, convergence
// across simulated devices, paging, retries, clamping, and the checks a sync makes.
import { test } from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { readFileSync } from "node:fs";
import { sqlitePort } from "../src/adapters/spaces-sqlite.js";
import * as space from "../src/space.js";
import { canonical, merge, visible } from "../src/space.js";
import { fsBlobs } from "../src/adapters/blobs-fs.js";
import { trashStep } from "../src/trash.js";
import { sha256Hex } from "../src/crypto.js";
import { tempDir } from "./helpers.js";

const FIXTURES = JSON.parse(readFileSync(new URL("../../Shared/SyncMergeFixtures.json", import.meta.url), "utf8"));
const NOW = Date.UTC(2026, 9, 19, 12);
const port = () => sqlitePort(new DatabaseSync(":memory:"));
const clock = (ms, counter = 0, device = "phone") => `${String(ms).padStart(13, "0")}.${counter.toString(16).padStart(4, "0")}.${device}`;
const sha = (n) => String(n).repeat(64).slice(0, 64);
const syncAs = (p, changes, { platform = "iphone", device = "phone-0001", since = 0, now = NOW, ...rest } = {}) =>
  space.sync(p, { account: "acc", device, platform, since, changes, now, ...rest });
const rows = (p, sql, ...args) => p.exec(sql, ...args);

function permutations(list) {
  if (list.length <= 1) return [list];
  return list.flatMap((x, i) => permutations([...list.slice(0, i), ...list.slice(i + 1)]).map((rest) => [x, ...rest]));
}

const TYPE_FOR = { field: "core.smartSettings", whole: "podcast.progress" };

test("merge fixtures: every order of the changes ends at the same state, pure and through a sync", () => {
  for (const c of FIXTURES.cases) {
    for (const order of permutations(c.changes)) {
      const label = `${c.name}: ${JSON.stringify(order)}`;
      let state = c.start;
      for (const change of order) state = merge(state, { set: {}, clocks: {}, ...change }, c.merge);
      assert.deepEqual({ fields: state.fields, clocks: state.clocks, deleted: state.deleted, visible: visible(state) }, c.expect, label);

      const p = port();
      const type = TYPE_FOR[c.merge];
      const sent = [...(c.start ? [{ set: c.start.fields, clocks: c.start.clocks, delete: c.start.deleted }] : []), ...order];
      for (const change of sent) {
        const { answer } = syncAs(p, [{ type, id: "r", ...change }], { now: 1760000000000 });
        assert.deepEqual(answer.rejected, [], label);
      }
      const { answer } = syncAs(p, [], { now: 1760000000000 });
      const r = answer.changes[0];
      assert.deepEqual({ fields: r.fields, clocks: r.clocks, deleted: r.deleted, visible: visible(r) }, c.expect, `${label} (sync)`);
    }
  }
});

test("canonical JSON sorts keys at every depth and compares as UTF-8, null lowest", () => {
  assert.equal(canonical({ b: 1, a: { d: [3, { z: 1, y: 2 }], c: null } }), '{"a":{"c":null,"d":[3,{"y":2,"z":1}]},"b":1}');
  assert.equal(space.compareText("￿", "\u{1F600}"), -1, "code point order, not UTF-16");
  assert.equal(space.compareValues(null, ""), -1);
  assert.equal(space.compareValues(false, null), 1);
});

// ---- convergence: a tiny client, as the app's mirror will be (DATA-PLATFORM.md §3, §4, §6) ----

function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function device(name, skew, world) {
  // issued: every clock this device made, with the offset it had then (to stamp it again).
  const me = { name, offset: 0, last: "", seen: "", records: new Map(), pending: new Map(), cursor: 0, issued: new Map() };
  const top = (a, b) => (a > b ? a : b);
  const ms = (c) => Number(c.slice(0, 13));
  const counter = (c) => parseInt(c.slice(14, 18), 16);
  me.issue = () => {
    const physical = world.t + skew + me.offset;
    const high = top(me.last, me.seen);
    me.last = !high || physical > ms(high) ? clock(physical, 0, name) : clock(ms(high), counter(high) + 1, name);
    me.issued.set(me.last, me.offset);
    return me.last;
  };
  me.receive = (c) => { if (c) me.seen = top(me.seen, c); };
  const key = (type, id) => `${type}|${id}`;
  me.edit = (type, id, field, value) => {
    const c = me.issue();
    world.edits.push({ key: key(type, id), field, value, clock: c });
    me.records.set(key(type, id), merge(me.records.get(key(type, id)) ?? null, { set: { [field]: value }, clocks: { [field]: c } }));
    const p = me.pending.get(key(type, id)) ?? { type, id, set: {}, clocks: {}, delete: null };
    p.set[field] = value;
    p.clocks[field] = c;
    me.pending.set(key(type, id), p);
  };
  me.remove = (type, id) => {
    const c = me.issue();
    world.edits.push({ key: key(type, id), delete: c });
    me.records.set(key(type, id), merge(me.records.get(key(type, id)) ?? null, { set: {}, clocks: {}, delete: c }));
    const p = me.pending.get(key(type, id)) ?? { type, id, set: {}, clocks: {}, delete: null };
    p.delete = c;
    me.pending.set(key(type, id), p);
  };
  me.request = (withChanges = true) => ({
    since: me.cursor,
    changes: withChanges ? [...me.pending.values()].map((p) => ({ type: p.type, id: p.id, set: { ...p.set }, clocks: { ...p.clocks }, delete: p.delete })) : [],
  });
  // A "clock" rejection: every clock this device made too far ahead is stamped again with the
  // offset it has now learned (its own time less the error), wherever it is: what's waiting to go,
  // its own records, and the test's list of edits. Then it issues from there.
  me.restamp = (most) => {
    const moved = new Map();
    for (const [c, offset] of [...me.issued]) {
      if (ms(c) <= most) continue;
      const again = clock(ms(c) + me.offset - offset, counter(c), name);
      moved.set(c, again);
      me.issued.delete(c);
      me.issued.set(again, me.offset);
    }
    const map = (c) => moved.get(c) ?? c;
    for (const p of me.pending.values()) {
      for (const f of Object.keys(p.clocks)) p.clocks[f] = map(p.clocks[f]);
      if (p.delete !== null) p.delete = map(p.delete);
    }
    for (const r of me.records.values()) {
      for (const f of Object.keys(r.clocks)) r.clocks[f] = map(r.clocks[f]);
      if (r.deleted !== null) r.deleted = map(r.deleted);
    }
    for (const e of world.edits) { if (e.clock) e.clock = map(e.clock); if (e.delete) e.delete = map(e.delete); }
    me.last = [...me.issued.keys()].reduce(top, "");
  };
  me.take = (answer) => {
    const localNow = world.t + skew + me.offset;
    if (Math.abs(answer.now - localNow) > 30_000) me.offset += answer.now - localNow;
    if (answer.rejected.some((r) => r.reason === "clock")) me.restamp(answer.now + 5 * 60_000);
    // An outgoing field is done once the space holds its clock or a higher one (a higher one won).
    for (const a of answer.applied) {
      const p = me.pending.get(key(a.type, a.id));
      Object.values(a.clocks).forEach(me.receive);
      me.receive(a.deleted);
      if (!p) continue;
      for (const f of Object.keys(p.set)) if (a.clocks[f] !== undefined && a.clocks[f] >= p.clocks[f]) { delete p.set[f]; delete p.clocks[f]; }
      if (p.delete !== null && a.deleted !== null && a.deleted >= p.delete) p.delete = null;
      if (!Object.keys(p.set).length && p.delete === null) me.pending.delete(key(a.type, a.id));
    }
    for (const r of answer.changes) {
      Object.values(r.clocks).forEach(me.receive);
      me.receive(r.deleted);
      me.records.set(key(r.type, r.id), merge(me.records.get(key(r.type, r.id)) ?? null, { set: r.fields, clocks: r.clocks, delete: r.deleted }));
    }
    me.cursor = answer.next;
    return answer.more;
  };
  return me;
}

function converge(seed) {
  const random = rng(seed);
  const pick = (list) => list[Math.floor(random() * list.length)];
  const world = { t: NOW, edits: [] };
  const p = port();
  const skews = [0, 4 * 60_000, -4 * 60_000, 7 * 60_000, 90_000];   // one device 7 min fast: clamped until it learns
  const devices = skews.map((s, i) => device(`dev${i}`, s, world));
  const records = Array.from({ length: 20 }, (_, i) => (i < 15 ? ["core.smartSettings", `s${i}`] : ["podcast.progress", `p${i}`]));
  const values = [1, 2, 3, null, "x", "", [2, 1], { b: 1, a: 2 }, true];
  const late = [];   // requests that reach the service again later (a duplicate on the network)
  let refused = 0;
  const page = () => ({ pageRecords: pick([3, 1000]), pageBytes: pick([400, 4 * 1024 * 1024]) });
  const send = (d, request) => {
    const { answer } = space.sync(p, { account: "acc", device: d.name, platform: "iphone", now: world.t, ...request, ...page() });
    assert.deepEqual(answer.rejected.filter((r) => r.reason !== "clock"), [], `seed ${seed}`);
    refused += answer.rejected.length;
    return answer;
  };
  const syncOnce = (d, { lossy }) => {
    let request = d.request();
    for (let pages = 0; pages < 50; pages++) {
      const answer = send(d, request);
      // A request the network delivers again, a little later (one refused for its clocks isn't:
      // a duplicate minutes late, after the clock came within reach, isn't how HTTP fails).
      if (lossy && random() < 0.1 && !answer.rejected.length) late.push(request);
      // An edit made while the request was out, often to a field it carried: it must stay pending.
      if (lossy && request.changes.length && random() < 0.3) {
        const sent = pick(request.changes);
        d.edit(sent.type, sent.id, pick(Object.keys(sent.set).concat(sent.type === "podcast.progress" ? ["v"] : ["a"])), pick(values));
      }
      if (lossy && random() < 0.2) return;           // the answer is lost: nothing changes on the device
      if (lossy && random() < 0.1) d.take(send(d, request));   // sent twice, both answers read
      if (!d.take(answer)) return;
      request = d.request(false);
    }
  };

  for (let step = 0; step < 400; step++) {
    world.t += Math.floor(random() * 20_000);
    const d = pick(devices);
    const r = random();
    const [type, id] = pick(records);
    if (r < 0.55) d.edit(type, id, type === "podcast.progress" ? "v" : pick(["a", "b", "c"]), pick(values));
    else if (r < 0.65) d.remove(type, id);
    else if (r < 0.95) syncOnce(d, { lossy: true });
    else if (late.length) send(d, late.splice(Math.floor(random() * late.length), 1)[0]);
  }
  // Everyone comes online for good. Time passes too, past the fast device's clocks.
  for (let round = 0; round < 40 && (round < 3 || devices.some((d) => d.pending.size)); round++) {
    world.t += 30_000;
    for (const d of devices) syncOnce(d, { lossy: false });
  }
  for (const d of devices) syncOnce(d, { lossy: false });

  const held = new Map(rows(p, "SELECT type, id, fields, clocks, deleted FROM records")
    .map((r) => [`${r.type}|${r.id}`, canonical({ fields: JSON.parse(r.fields), clocks: JSON.parse(r.clocks), deleted: r.deleted ?? null })]));
  // And that state is what every edit ever made adds up to, worked out without the merge: per field
  // the highest clock issued anywhere, and the highest delete clock.
  const expected = new Map();
  for (const e of world.edits) {
    const r = expected.get(e.key) ?? { fields: {}, clocks: {}, deleted: null };
    if (e.delete) { if (r.deleted === null || e.delete > r.deleted) r.deleted = e.delete; }
    else if (!(e.field in r.clocks) || e.clock > r.clocks[e.field]) { r.clocks[e.field] = e.clock; r.fields[e.field] = e.value; }
    expected.set(e.key, r);
  }
  assert.deepEqual(held, new Map([...expected].map(([k, r]) => [k, canonical(r)])), `seed ${seed}: the space isn't every edit's sum`);
  for (const d of devices) {
    assert.equal(d.pending.size, 0, `seed ${seed}: ${d.name} still has changes to send`);
    const mine = new Map([...d.records].map(([k, s]) => [k, canonical({ fields: s.fields, clocks: s.clocks, deleted: s.deleted })]));
    assert.deepEqual(mine, held, `seed ${seed}: ${d.name} differs from the space`);
  }
  return { records: held.size, refused };
}

test("convergence: devices with skewed clocks (one refused until it stamps again), offline edits, deletes, lost answers, retries and duplicates end equal to the space", () => {
  let refused = 0;
  for (let seed = 1; seed <= 40; seed++) refused += converge(seed).refused;
  assert.ok(refused > 0, "the fast device was refused for its clock at least once");
});

// ---- the sync call ----

test("paging: 1,000 records a page, `next` is the last one's seq, `more` until the end", () => {
  const p = port();
  for (let batch = 0; batch < 3; batch++) {
    const changes = Array.from({ length: 400 }, (_, i) => ({ type: "plan.extra", id: `e${batch * 400 + i}`, set: { n: i }, clocks: { n: clock(NOW) } }));
    syncAs(p, changes);
  }
  const first = syncAs(p, []).answer;
  assert.deepEqual([first.head, first.changes.length, first.next, first.more], [1200, 1000, 1000, true]);
  assert.deepEqual(first.changes.slice(0, 2).map((r) => r.seq), [1, 2]);
  const second = syncAs(p, [], { since: first.next }).answer;
  assert.deepEqual([second.changes.length, second.next, second.more], [200, 1200, false]);
  const empty = syncAs(p, [], { since: second.next }).answer;
  assert.deepEqual([empty.changes.length, empty.next, empty.more], [0, 1200, false]);
  // A cursor past the head (the space was started over) reads from the start.
  assert.equal(syncAs(p, [], { since: 5000 }).answer.changes[0].seq, 1);
});

test("paging: about 4 MB a page, and always at least one record", () => {
  const p = port();
  const big = "x".repeat(200 * 1024);
  for (let i = 0; i < 25; i++) syncAs(p, [{ type: "plan.extra", id: `big${i}`, set: { text: big }, clocks: { text: clock(NOW) } }]);
  const first = syncAs(p, []).answer;
  assert.ok(first.more);
  assert.ok(first.changes.length >= 18 && first.changes.length <= 20, `${first.changes.length} records`);
  assert.ok(JSON.stringify(first.changes).length <= 4.1 * 1024 * 1024);
  let since = first.next, total = first.changes.length;
  for (;;) {
    const page = syncAs(p, [], { since }).answer;
    total += page.changes.length;
    since = page.next;
    if (!page.more) break;
  }
  assert.equal(total, 25);
  // A page smaller than one record still carries it.
  assert.equal(syncAs(p, [], { pageBytes: 10 }).answer.changes.length, 1);
});

test("a retry is not a change: no new seq, no history, but `applied` again", () => {
  const p = port();
  const change = { type: "food.meal", id: "m1", set: { title: "Oats", kcal: 300 }, clocks: { title: clock(NOW), kcal: clock(NOW) } };
  space.setConsent(p, "health", { version: "1", at: NOW });
  const first = syncAs(p, [change]);
  assert.equal(first.accepted.length, 1);
  const again = syncAs(p, [change, { ...change, set: { title: "Oats" }, clocks: { title: clock(NOW) } }]);
  assert.deepEqual([again.answer.head, again.accepted.length], [1, 0]);
  assert.deepEqual(again.answer.applied.map((a) => a.clocks.title), [clock(NOW), clock(NOW)]);
  assert.equal(rows(p, "SELECT COUNT(*) AS n FROM history")[0].n, 1);
  // A lower clock loses and changes nothing either; the answer shows the clock that's held.
  const older = syncAs(p, [{ ...change, set: { title: "Muesli" }, clocks: { title: clock(NOW - 1) } }]);
  assert.deepEqual([older.answer.head, older.answer.applied[0].clocks.title], [1, clock(NOW)]);
  // A real edit: one history row with the changed field only.
  syncAs(p, [{ ...change, set: { title: "Porridge" }, clocks: { title: clock(NOW + 1) } }], { device: "mac-0001" });
  const h = rows(p, "SELECT seq, device, before, after FROM history ORDER BY seq");
  assert.deepEqual(h.map((r) => [r.seq, r.device]), [[1, "phone-0001"], [2, "mac-0001"]]);
  assert.equal(h[0].before, null);
  assert.deepEqual(JSON.parse(h[1].before), { fields: { title: "Oats" }, clocks: { title: clock(NOW) } });
  assert.deepEqual(JSON.parse(h[1].after), { fields: { title: "Porridge" }, clocks: { title: clock(NOW + 1) } });
});

test("a clock more than 5 minutes ahead: the whole record is refused, until the device stamps it again; an edit made meanwhile stands", () => {
  const p = port();
  const fast = (ms) => clock(ms + 10 * 60_000, 0, "phone");   // the phone is 10 minutes fast
  const phone = { type: "plan.extra", id: "e", set: { title: "Phone", note: "salty" }, clocks: { title: fast(NOW), note: fast(NOW) } };
  const first = syncAs(p, [phone]).answer;
  assert.deepEqual([first.rejected, first.applied, first.head, first.now], [[{ type: "plan.extra", id: "e", reason: "clock" }], [], 0, NOW]);
  assert.equal("clamped" in first, false);

  // The Mac edits the title a second later.
  syncAs(p, [{ type: "plan.extra", id: "e", set: { title: "Mac" }, clocks: { title: clock(NOW + 1000, 0, "mac") } }], { device: "mac-0001", platform: "mac", now: NOW + 1000 });
  // The phone's retries change nothing at all.
  for (let i = 0; i < 3; i++) assert.deepEqual(syncAs(p, [phone], { now: NOW + 2000 + i }).answer.rejected.map((r) => r.reason), ["clock"]);
  assert.deepEqual([rows(p, "SELECT value FROM meta WHERE key = 'head'")[0].value, rows(p, "SELECT COUNT(*) AS n FROM history")[0].n], ["1", 1]);

  // Stamped again with the offset it learned (its edit was made at NOW): the note is taken; the
  // title the Mac set later stays.
  const again = { ...phone, clocks: { title: clock(NOW), note: clock(NOW) } };
  const taken = syncAs(p, [again], { now: NOW + 3000 }).answer;
  assert.deepEqual(taken.rejected, []);
  const r = taken.changes.find((c) => c.id === "e");
  assert.deepEqual([r.fields, r.seq, taken.head], [{ title: "Mac", note: "salty" }, 2, 2]);
  assert.equal(rows(p, "SELECT value FROM meta WHERE key = 'hlc'")[0].value, clock(NOW + 1000, 0, "mac"));
});

test("epoch: the same for the life of a space, new after a wipe", () => {
  const p = port();
  const first = syncAs(p, [{ type: "plan.extra", id: "a", set: { n: 1 }, clocks: { n: clock(NOW) } }]).answer;
  assert.match(first.epoch, /^[0-9a-f]{24}$/);
  assert.equal(syncAs(p, [], { since: 1 }).answer.epoch, first.epoch);
  space.wipe(p, { space: "sp_acc", now: NOW });
  const after = syncAs(p, [], { since: 1 }).answer;
  assert.notEqual(after.epoch, first.epoch);
  assert.deepEqual([after.head, after.changes], [0, []]);
  assert.notEqual(syncAs(port(), []).answer.epoch, first.epoch, "every space its own");
});

test("a pull writes nothing; a request's own records come back in its answer", () => {
  const p = port();
  syncAs(p, [{ type: "plan.extra", id: "a", set: { n: 1 }, clocks: { n: clock(NOW) } }]);
  const meta = () => JSON.stringify(rows(p, "SELECT key, value FROM meta ORDER BY key"));
  const before = meta();
  let writes = 0;
  const watched = { exec: (sql, ...args) => { if (/^\s*(INSERT|UPDATE|DELETE)/i.test(sql)) writes++; return p.exec(sql, ...args); }, transaction: p.transaction };
  syncAs(watched, [], { since: 0 });
  assert.deepEqual([writes, meta()], [0, before]);
  const { answer } = syncAs(p, [{ type: "plan.extra", id: "b", set: { n: 2 }, clocks: { n: clock(NOW + 1) } }], { since: 1 });
  assert.deepEqual(answer.changes.map((c) => [c.id, c.seq, c.fields]), [["b", 2, { n: 2 }]]);
});

test("equal clocks from two devices: the greater value wins in either order", () => {
  const c = clock(NOW, 0, "dup");   // only a duplicate (or a bug) makes two values with one clock
  for (const order of [["x", "y"], ["y", "x"]]) {
    const p = port();
    for (const [i, v] of order.entries()) syncAs(p, [{ type: "plan.extra", id: "e", set: { v: { pick: v } }, clocks: { v: c } }], { device: `dev-000${i}` });
    assert.deepEqual(syncAs(p, []).answer.changes[0].fields, { v: { pick: "y" } }, order.join());
  }
});

test('a "__proto__" key inside a value is kept like any other', () => {
  const p = port();
  const value = JSON.parse('{"__proto__": {"x": 1}, "a": 2}');
  assert.equal(canonical(value), '{"__proto__":{"x":1},"a":2}');
  syncAs(p, [{ type: "plan.extra", id: "e", set: { slots: value }, clocks: { slots: clock(NOW) } }]);
  const back = syncAs(p, []).answer.changes[0].fields.slots;
  assert.equal(canonical(back), '{"__proto__":{"x":1},"a":2}');
});

// ---- the trash (src/trash.js) ----

async function trashSpace(n) {
  const p = port();
  const blobs = fsBlobs(tempDir());
  space.setConsent(p, "health", { version: "1", at: NOW });
  const shas = [];
  for (let i = 0; i < n; i++) {
    const h = await sha256Hex(`samples ${i}`);
    await blobs.put(`s/sp_acc/${h}`, [new TextEncoder().encode(`samples ${i}`)], { sha256: h });
    space.recordBlob(p, h, 9, NOW, "health.workout");
    shas.push(h);
  }
  return { p, blobs, shas };
}

test("trash: a batch at a time until done, the next alarm set after each; a failure comes back later, longer each time", async () => {
  const { p, blobs, shas } = await trashSpace(5);
  assert.equal(space.withdrawConsent(p, "health", { space: "sp_acc" }).blobs.length, 5);
  assert.ok(space.trashPending(p));
  const steps = [];
  for (let i = 0; i < 3; i++) steps.push((await trashStep(p, blobs, { now: NOW, limit: 2 })).next);
  assert.deepEqual(steps, [NOW + 1000, NOW + 1000, null]);
  assert.ok(!space.trashPending(p));
  assert.deepEqual(await blobs.list("s/"), []);
  assert.deepEqual(await blobs.list("trash/sp_acc/"), shas.map((h) => `trash/sp_acc/${h}`).sort());

  const again = await trashSpace(1);
  space.withdrawConsent(again.p, "health", { space: "sp_acc" });
  const logs = [];
  const down = { ...again.blobs, move: async () => { throw new Error("R2 down"); } };
  const retries = [];
  for (let i = 0; i < 3; i++) retries.push((await trashStep(again.p, down, { now: NOW, log: (l) => logs.push(l) })).next);
  assert.deepEqual(retries, [NOW + 60_000, NOW + 120_000, NOW + 240_000]);
  assert.match(logs[0], /^trash: batch failed \(Error\), try 1$/);
  // The blob stayed on the list through the failures, and moves once R2 is back.
  assert.deepEqual(await trashStep(again.p, again.blobs, { now: NOW }), { next: null, wiped: false });
  assert.deepEqual([await again.blobs.list("s/"), (await again.blobs.list("trash/")).length], [[], 1]);
});

test("trash: bytes uploaded again come back, whether before, during or after their move", async () => {
  // Before: the upload takes the sha off the list, and the batch skips it.
  const before = await trashSpace(1);
  space.withdrawConsent(before.p, "health", { space: "sp_acc" });
  space.setConsent(before.p, "health", { version: "1", at: NOW });
  assert.deepEqual(space.recordBlob(before.p, before.shas[0], 9, NOW, "health.workout"), { ok: true, restore: true });
  await trashStep(before.p, before.blobs, { now: NOW });
  assert.deepEqual(await before.blobs.list("s/"), [`s/sp_acc/${before.shas[0]}`]);

  // During: the upload lands while the file moves; the batch moves it back.
  const during = await trashSpace(1);
  space.withdrawConsent(during.p, "health", { space: "sp_acc" });
  const racing = { ...during.blobs, async move(from, to) {
    await during.blobs.move(from, to);
    if (to.startsWith("trash/")) space.recordBlob(during.p, during.shas[0], 9, NOW, "notes.voiceNote");
  } };
  await trashStep(during.p, racing, { now: NOW });
  assert.deepEqual([await during.blobs.list("s/"), await during.blobs.list("trash/")], [[`s/sp_acc/${during.shas[0]}`], []]);

  // After: the index says so ({restore: true}); the route brings the file back (test/sync.test.js).
  const after = await trashSpace(1);
  space.withdrawConsent(after.p, "health", { space: "sp_acc" });
  await trashStep(after.p, after.blobs, { now: NOW });
  assert.deepEqual(space.recordBlob(after.p, after.shas[0], 9, NOW, "notes.voiceNote"), { ok: true, restore: true });
  assert.deepEqual(space.recordBlob(after.p, after.shas[0], 9, NOW, "notes.voiceNote"), { ok: true, restore: false });
});

test("a wipe still moving blobs after a day is logged loudly", async () => {
  const { p, blobs } = await trashSpace(3);
  space.wipe(p, { space: "sp_acc", now: NOW });
  const logs = [];
  assert.deepEqual(await trashStep(p, blobs, { now: NOW + 2 * 24 * 3600_000, limit: 2, log: (l) => logs.push(l) }), { next: NOW + 2 * 24 * 3600_000 + 1000, wiped: false });
  assert.match(logs[0], /ALERT a space wipe started 2 day\(s\) ago/);
  await trashStep(p, blobs, { now: NOW, limit: 2 });
  assert.deepEqual(await trashStep(p, blobs, { now: NOW, limit: 2 }), { next: null, wiped: true });
  assert.equal((await blobs.list("trash/sp_acc/")).length, 3);
});

test("checks: unknown types, bad changes, hub-only types, the 256 KB cap", () => {
  const p = port();
  const c = clock(NOW);
  const { answer } = syncAs(p, [
    { type: "nope.thing", id: "x", set: { a: 1 }, clocks: { a: c } },
    { type: "plan.extra", id: "", set: { a: 1 }, clocks: { a: c } },
    { type: "plan.extra", id: "x", set: { a: 1 }, clocks: {} },
    { type: "plan.extra", id: "x", set: { a: 1 }, clocks: { a: "yesterday" } },
    { type: "plan.extra", id: "x", set: {}, clocks: { a: c } },
    { type: "plan.extra", id: "x", set: { a: { $blob: "nothex" } }, clocks: { a: c } },
    { type: "podcast.progress", id: "x", set: { position: 1 }, clocks: { position: c } },
    { type: "core.hubStatus", id: "x", set: { v: 1 }, clocks: { v: c } },
    { type: "plan.extra", id: "big", set: { a: "x".repeat(256 * 1024) }, clocks: { a: c } },
    "not a change",
  ], { platform: "mac" });
  assert.deepEqual(answer.rejected.map((r) => r.reason), ["unknown_type", "bad", "bad", "bad", "bad", "bad", "bad", "hub_only", "too_large", "bad"]);
  assert.deepEqual([answer.head, answer.applied.length], [0, 0]);
  // The iPhone writes hub types.
  assert.deepEqual(syncAs(p, [{ type: "core.hubStatus", id: "x", set: { v: 1 }, clocks: { v: c } }]).answer.rejected, []);
});

test("blobs: a patch naming a blob not in the index is rejected until the blob is recorded", () => {
  const p = port();
  const ref = { $blob: sha(1), size: 3, ext: "jpg" };
  const change = { type: "notes.voiceNote", id: "n", set: { audio: ref }, clocks: { audio: clock(NOW) } };
  assert.deepEqual(syncAs(p, [change]).answer.rejected, [{ type: "notes.voiceNote", id: "n", reason: "blob_missing" }]);
  space.recordBlob(p, sha(1), 3, NOW, "notes.voiceNote");
  space.recordBlob(p, sha(1), 999, NOW + 1, "notes.voiceNote");   // never overwritten
  assert.deepEqual(syncAs(p, [change]).answer.rejected, []);
  assert.deepEqual(rows(p, "SELECT sha, size FROM blobs"), [{ sha: sha(1), size: 3 }]);
});

test("consent: T2 needs it, in the same transaction; withdrawing deletes T2 and its history and frees its blobs", () => {
  const p = port();
  const c = clock(NOW);
  const meal = { type: "food.meal", id: "m", set: { title: "Oats", photo: { $blob: sha(1) } }, clocks: { title: c, photo: c } };
  const listen = { type: "podcast.listen", id: "l", set: { route: { $blob: sha(2) }, shared: { $blob: sha(3) } }, clocks: { route: c, shared: c } };
  const workout = { type: "health.workout", id: "w", set: { samples: { $blob: sha(3) } }, clocks: { samples: c } };
  for (const n of [2, 3]) space.recordBlob(p, sha(n), n, NOW, "podcast.listen");
  assert.deepEqual(space.recordBlob(p, sha(1), 1, NOW, "food.mealPhoto"), { ok: false, reason: "consent" }, "a T2 blob needs the yes");

  const refused = syncAs(p, [meal, listen]).answer;
  assert.deepEqual(refused.rejected, [{ type: "food.meal", id: "m", reason: "consent" }]);
  assert.deepEqual(refused.consents, { health: false });

  space.setConsent(p, "health", { version: "1", at: NOW, device: "phone-0001" });
  assert.deepEqual(space.recordBlob(p, sha(1), 1, NOW, "food.mealPhoto"), { ok: true, restore: false });
  space.recordBlob(p, sha(5), 5, NOW, "health.workout");   // uploaded, never named by a patch
  space.recordBlob(p, sha(3), 3, NOW, "health.workout");   // the same bytes as a T1 upload: stays T1
  const taken = syncAs(p, [meal, workout]).answer;
  assert.deepEqual([taken.rejected, taken.consents], [[], { health: true }]);
  syncAs(p, [{ ...meal, set: { title: "Porridge" }, clocks: { title: clock(NOW + 1) } }]);
  assert.deepEqual(space.counts(p), { "podcast.listen": 1, "food.meal": 1, "health.workout": 1 });

  const withdrawn = space.withdrawConsent(p, "health", { space: "sp_acc" });
  // sha(5) goes though nothing named it; sha(3) is named by a T1 listen too, so it stays.
  assert.deepEqual({ ...withdrawn, blobs: withdrawn.blobs.sort() }, { records: 2, blobs: [sha(1), sha(5)] });
  assert.deepEqual(space.counts(p), { "podcast.listen": 1 });
  assert.deepEqual(rows(p, "SELECT type FROM history"), [{ type: "podcast.listen" }]);
  assert.deepEqual(rows(p, "SELECT sha FROM blobs ORDER BY sha").map((r) => r.sha), [sha(2), sha(3)]);
  assert.deepEqual(space.trashList(p, 10), { space: "sp_acc", wiping: null, shas: [sha(1), sha(5)] });

  // A batch that comes after can't bring T2 back.
  const after = syncAs(p, [{ ...meal, set: { title: "Again" }, clocks: { title: clock(NOW + 5) } }]).answer;
  assert.deepEqual([after.rejected.map((r) => r.reason), after.consents], [["consent"], { health: false }]);
  // Withdrawing again is harmless.
  assert.deepEqual(space.withdrawConsent(p, "health", { space: "sp_acc" }), { records: 0, blobs: [] });
  // A retried yes keeps its first time.
  space.setConsent(p, "health", { version: "1", at: NOW + 9 });
  space.setConsent(p, "health", { version: "1", at: NOW + 99 });
  assert.equal(rows(p, "SELECT at FROM consent")[0].at, NOW + 9);
});

test('keep "latest": a new Health snapshot sends the one before to the trash, unless something else names it', () => {
  const p = port();
  space.setConsent(p, "health", { version: "1", at: NOW });
  for (const n of [1, 2, 3, 4]) space.recordBlob(p, sha(n), n, NOW, "health.snapshot");
  const snapshot = (n, ms) => ({ type: "health.snapshot", id: "hub", set: { v: { $blob: sha(n), ext: "json" } }, clocks: { v: clock(ms) } });

  syncAs(p, [snapshot(1, NOW)], { space: "sp_acc" });
  const second = syncAs(p, [snapshot(2, NOW + 1)], { space: "sp_acc" });
  assert.equal(second.trashed, 1);
  assert.deepEqual(space.trashList(p, 10), { space: "sp_acc", wiping: null, shas: [sha(1)] });
  assert.deepEqual(rows(p, "SELECT sha FROM blobs ORDER BY sha").map((r) => r.sha), [sha(2), sha(3), sha(4)]);
  // Both versions stay in the history; the first one's blob is gone.
  assert.equal(rows(p, "SELECT COUNT(*) AS n FROM history WHERE type = 'health.snapshot'")[0].n, 2);

  // A blob another type names (here a workout's samples, kept forever) stays when the snapshot moves on.
  syncAs(p, [{ type: "health.workout", id: "w", set: { samples: { $blob: sha(3) } }, clocks: { samples: clock(NOW) } }], { space: "sp_acc" });
  syncAs(p, [snapshot(3, NOW + 2)], { space: "sp_acc" });
  assert.equal(syncAs(p, [snapshot(4, NOW + 3)], { space: "sp_acc" }).trashed, 0);
  assert.deepEqual(space.trashList(p, 10).shas, [sha(1), sha(2)]);
  // An older snapshot arriving late loses and trashes nothing; other types never trash.
  assert.equal(syncAs(p, [snapshot(1, NOW - 5)], { space: "sp_acc" }).trashed, 0);
  syncAs(p, [{ type: "health.workout", id: "w", set: { samples: { $blob: sha(4) } }, clocks: { samples: clock(NOW + 9) } }], { space: "sp_acc" });
  assert.ok(rows(p, "SELECT 1 FROM blobs WHERE sha = ?", sha(3)).length, "the workout's old samples stay");
});

test("the change stream entries: T1 with its day and nothing else, T2 bare", () => {
  const p = port();
  space.setConsent(p, "health", { version: "1", at: NOW });
  const c = clock(NOW);
  const { accepted } = syncAs(p, [
    { type: "plan.extra", id: "e", set: { day: "2026-10-19", title: "Swim" }, clocks: { day: c, title: c } },
    { type: "food.meal", id: "m", set: { date: NOW, title: "Oats" }, clocks: { date: c, title: c } },
    { type: "plan.extra", id: "e", set: {}, clocks: {}, delete: clock(NOW + 1) },
  ]);
  assert.deepEqual(accepted, [
    { type: "plan.extra", op: "create", day: "2026-10-19", fields: {} },
    { type: "food.meal", op: "create" },
    { type: "plan.extra", op: "delete", day: "2026-10-19", fields: {} },
  ]);
});

test("export rows: every record, its history, the blob list and the consents; wipe empties the space", () => {
  const p = port();
  space.recordBlob(p, sha(4), 10, NOW, "notes.voiceNote");
  space.setConsent(p, "health", { version: "1", at: NOW, device: "phone-0001" });
  syncAs(p, [{ type: "plan.extra", id: "e", set: { a: 1 }, clocks: { a: clock(NOW) } }]);
  syncAs(p, [{ type: "plan.extra", id: "e", set: { a: 2 }, clocks: { a: clock(NOW + 1) } }]);
  const out = [...space.exportRows(p, 1)];
  assert.deepEqual(out.map((r) => r.kind), ["record", "history", "history", "blob", "consent"]);
  assert.deepEqual(out[0], { kind: "record", type: "plan.extra", id: "e", fields: { a: 2 }, clocks: { a: clock(NOW + 1) }, deleted: null, seq: 2 });
  assert.deepEqual(out[4], { kind: "consent", consent: "health", version: "1", at: NOW, device: "phone-0001" });

  space.wipe(p, { space: "sp_acc", now: NOW });
  assert.deepEqual([...space.exportRows(p)], []);
  assert.deepEqual(space.trashList(p, 10), { space: "sp_acc", wiping: NOW, shas: [] });
  assert.equal(syncAs(p, []).answer.head, 0);
});

test("read and list: the service's own reads of T1 records, deleted ones left out, never T2", () => {
  const p = port();
  syncAs(p, [
    { type: "plan.bookingType", id: "t1", set: { title: "Intro", slug: "intro" }, clocks: { title: clock(NOW - 10), slug: clock(NOW - 10) } },
    { type: "plan.bookingType", id: "t2", set: { title: "Call" }, clocks: { title: clock(NOW - 10) } },
    { type: "core.smartSettings", id: "smart-settings", set: { v: { settings: { excludedCalendarIDs: ["x"] } } }, clocks: { v: clock(NOW - 10) } },
  ]);
  syncAs(p, [{ type: "plan.bookingType", id: "t2", set: {}, clocks: {}, delete: clock(NOW) }]);
  assert.deepEqual(space.read(p, "plan.bookingType", "t1"), { title: "Intro", slug: "intro" });
  assert.equal(space.read(p, "plan.bookingType", "t2"), null);
  assert.equal(space.read(p, "plan.bookingType", "none"), null);
  assert.deepEqual(space.list(p, "plan.bookingType"), [{ id: "t1", fields: { title: "Intro", slug: "intro" } }]);
  assert.deepEqual(space.read(p, "core.smartSettings", "smart-settings").v.settings.excludedCalendarIDs, ["x"]);
  assert.throws(() => space.list(p, "health.workout"));
  assert.throws(() => space.read(p, "nope", "x"));
});

test("counts are kept against the head seq: asked again they cost a meta read, and a change or a withdrawal recomputes them (audit run-1)", () => {
  const p = port();
  const listen = (id, ms) => ({ type: "podcast.listen", id, set: { title: id }, clocks: { title: clock(ms) } });
  syncAs(p, [listen("l1", NOW)]);
  assert.deepEqual(space.counts(p), { "podcast.listen": 1 });
  const kept = JSON.parse(rows(p, "SELECT value FROM meta WHERE key = 'counts'")[0].value);
  assert.deepEqual(kept, { head: rows(p, "SELECT value FROM meta WHERE key = 'head'")[0].value, counts: { "podcast.listen": 1 } });
  assert.deepEqual(space.counts(p), { "podcast.listen": 1 });
  syncAs(p, [listen("l2", NOW + 5)]);
  assert.deepEqual(space.counts(p), { "podcast.listen": 2 });
  assert.equal(JSON.parse(rows(p, "SELECT value FROM meta WHERE key = 'counts'")[0].value).counts["podcast.listen"], 2);
});
