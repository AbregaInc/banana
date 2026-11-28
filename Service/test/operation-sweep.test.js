import test from "node:test";
import assert from "node:assert/strict";
import { setup, device, DAY, TOKEN_KEY as TOKEN } from "./helpers.js";
import { createVault } from "../src/crypto.js";
import { providerOperation, operationFailure } from "../src/provider-operation.js";
import { sweepStaleOperations, settleOperation, SWEEP_AFTER, SWEEP_BATCH, SWEEP_PER_ACCOUNT, NEVER_REPLAY_UNSENT, interleave, CANDIDATES_SQL, EARLIER_SQL, SUPERSEDED_SQL } from "../src/operation-sweep.js";

async function world() {
  const s = setup();
  s.google.person("c", "sub-ann", "ann@example.com");
  const ann = (await s.signIn("c", device("phone-0001"))).json;
  s.google.person("c2", "sub-bob", "bob@example.com");
  const bob = (await s.signIn("c2", device("phone-0002"))).json;
  s.google.person("c3", "sub-cat", "cat@example.com");
  const cat = (await s.signIn("c3", device("phone-0003"))).json;
  const account = ann.account.id;
  const subOf = { [ann.account.id]: "sub-ann", [bob.account.id]: "sub-bob", [cat.account.id]: "sub-cat" };
  const vault = createVault(TOKEN, s.deps.random);
  const run = async (reachable, request, who = account) => providerOperation(s.deps, vault, {
    account: who, operationID: request.operationID, googleSub: subOf[who], provider: "test", resource: { item: request.item }, request,
    enabled: async () => true,
    prepare: async () => (reachable ? null : operationFailure(502, "temporarily unavailable")),
    dispatch: async () => ({ status: 200, body: { sent: request.operationID } }), reconcile: async () => ({ retry: true }),
  });
  const sent = [];
  // What the service resumes: the same operation through the same entry a device uses, its provider now reachable.
  const handlers = [
    { parse: (x) => x?.kind === "label", run: (_d, _v, acct, req) => { sent.push(req.operationID); return run(true, req, acct); }, maxUnsentAge: null },
    { parse: (x) => x?.kind === "event", run: (_d, _v, acct, req) => { sent.push(req.operationID); return run(true, req, acct); }, maxUnsentAge: NEVER_REPLAY_UNSENT },
  ];
  const stuck = (request, who = account) => run(false, request, who);
  const rows = () => s.deps.db.all("SELECT operation_id,state,response_status FROM provider_operations ORDER BY created_at,operation_id");
  return { s, vault, account, other: bob.account.id, third: cat.account.id, handlers, stuck, run, sent, rows };
}
const op = (n, item, kind = "label") => ({ kind, item, operationID: `00000000-0000-4000-8000-${String(n).padStart(12, "0")}` });

test("an operation nothing finishes is resumed by the service, and a device's retry gets the saved answer", async () => {
  const { s, vault, handlers, stuck, run, sent, rows } = await world();
  await stuck(op(1, "m1"));
  s.advance(SWEEP_AFTER + 1000);
  const out = await sweepStaleOperations(s.deps, vault, handlers);
  assert.deepEqual(out, { replayed: 1, settled: 0, skipped: 0, failed: 0 });
  assert.deepEqual((await rows()).map((r) => [r.state, r.response_status]), [["done", 200]]);
  // The device retries with the same identity: the saved answer, no second send.
  assert.equal((await run(true, op(1, "m1"))).status, 200);
  assert.deepEqual(sent, [op(1, "m1").operationID]);
});

test("a device is given time first: a fresh operation is left alone", async () => {
  const { s, vault, handlers, stuck, sent } = await world();
  await stuck(op(1, "m1"));
  s.advance(SWEEP_AFTER - 1000);
  assert.deepEqual(await sweepStaleOperations(s.deps, vault, handlers), { replayed: 0, settled: 0, skipped: 0, failed: 0 });
  assert.deepEqual(sent, []);
});

test("changes to one item go oldest first, one per run, so they stay in order", async () => {
  const { s, vault, handlers, stuck, sent } = await world();
  await stuck(op(1, "m1")); s.advance(1000);
  await stuck(op(2, "m1")); s.advance(1000);
  await stuck(op(3, "m2")); s.advance(SWEEP_AFTER + 1000);
  const first = await sweepStaleOperations(s.deps, vault, handlers);
  assert.equal(first.replayed, 2); // the oldest of m1, and m2's only one
  assert.deepEqual(sent, [op(1, "m1").operationID, op(3, "m2").operationID]);
  const second = await sweepStaleOperations(s.deps, vault, handlers);
  assert.equal(second.replayed, 1);
  assert.equal(sent.at(-1), op(2, "m1").operationID);
});

test("an earlier change is not replayed once a later one on the same item has gone out", async () => {
  const { s, vault, handlers, stuck, run, sent, rows } = await world();
  await stuck(op(1, "m1")); s.advance(1000);
  assert.equal((await run(true, op(2, "m1"))).status, 200); // the later change went out on its own
  s.advance(SWEEP_AFTER + 1000);
  assert.deepEqual(await sweepStaleOperations(s.deps, vault, handlers), { replayed: 0, settled: 0, skipped: 0, failed: 0 });
  assert.deepEqual(sent, []);
  assert.equal((await rows()).find((r) => r.operation_id === op(1, "m1").operationID).state, "pending");
});

test("a calendar change that never went out is never applied, at any age: 412 with the receipt a device looks for", async () => {
  const { s, vault, handlers, stuck, run, sent, rows } = await world();
  await stuck(op(1, "e1", "event"));
  s.advance(SWEEP_AFTER + 1000); // just past the quiet period, not old
  assert.deepEqual(await sweepStaleOperations(s.deps, vault, handlers), { replayed: 0, settled: 1, skipped: 0, failed: 0 });
  assert.deepEqual(sent, []); // nothing was applied
  assert.deepEqual((await rows()).map((r) => [r.state, r.response_status]), [["done", 412]]);
  const answer = await run(true, op(1, "e1", "event"));
  assert.equal(answer.status, 412);
  assert.deepEqual(answer.body.bananaOperation, { id: op(1, "e1", "event").operationID, state: "done" });
  // A mail label change of any age is replayed, not expired.
  await stuck(op(2, "m1")); s.advance(10 * DAY);
  assert.equal((await sweepStaleOperations(s.deps, vault, handlers)).replayed, 1);
});

test("a calendar change that already went out is still resumed, with its stored version", async () => {
  const { s, vault, handlers, stuck, rows, sent } = await world();
  await stuck(op(1, "e1", "event"));
  await s.deps.db.run("UPDATE provider_operations SET state='uncertain', dispatch_cipher=? WHERE operation_id=?", "sealed-context", op(1, "e1", "event").operationID);
  s.advance(SWEEP_AFTER + 1000);
  const out = await sweepStaleOperations(s.deps, vault, handlers);
  assert.equal(out.settled, 0);
  assert.equal(out.replayed + out.failed, 1);
  assert.equal(sent.length, 1); // handed to the calendar handler, which reconciles against Google
});

test("a lease that ran out and an outcome never confirmed are resumed too", async () => {
  const { s, vault, handlers, stuck, rows } = await world();
  await stuck(op(1, "m1")); await stuck(op(2, "m2"));
  await s.deps.db.run("UPDATE provider_operations SET state='running',lease='x',lease_until=? WHERE operation_id=?", s.deps.now() + 1000, op(1, "m1").operationID);
  await s.deps.db.run("UPDATE provider_operations SET state='uncertain' WHERE operation_id=?", op(2, "m2").operationID);
  s.advance(SWEEP_AFTER + 2000);
  assert.equal((await sweepStaleOperations(s.deps, vault, handlers)).replayed, 2);
  assert.deepEqual((await rows()).map((r) => r.state), ["done", "done"]);
});

test("what no handler owns (a draft, a send) is never sent by the service", async () => {
  const { s, vault, handlers, stuck, sent, rows } = await world();
  await stuck(op(1, "d1", "draft-send"));
  s.advance(8 * DAY - 1000);
  assert.deepEqual(await sweepStaleOperations(s.deps, vault, handlers), { replayed: 0, settled: 0, skipped: 1, failed: 0 });
  assert.deepEqual(sent, []);
  assert.equal((await rows())[0].state, "pending");
});

test("one account takes at most SWEEP_PER_ACCOUNT operations a run, so the rest wait their turn", async () => {
  const { s, vault, handlers, stuck } = await world();
  for (let i = 0; i < SWEEP_PER_ACCOUNT * 2 + 3; i++) { await stuck(op(i + 1, `m${i}`)); s.advance(10); }
  s.advance(SWEEP_AFTER + 1000);
  assert.equal((await sweepStaleOperations(s.deps, vault, handlers)).replayed, SWEEP_PER_ACCOUNT);
  assert.equal((await sweepStaleOperations(s.deps, vault, handlers)).replayed, SWEEP_PER_ACCOUNT);
  assert.equal((await sweepStaleOperations(s.deps, vault, handlers)).replayed, 3);
});

test("a big backlog on one account never starves another: accounts take turns", async () => {
  const { s, vault, account, other, handlers, stuck, rows } = await world();
  for (let i = 0; i < 30; i++) { await stuck(op(i + 1, `a${i}`), account); s.advance(10); } // the older, bigger backlog
  for (let i = 0; i < 3; i++) { await stuck(op(100 + i, `b${i}`), other); s.advance(10); }
  s.advance(SWEEP_AFTER + 1000);
  const out = await sweepStaleOperations(s.deps, vault, handlers);
  assert.equal(out.replayed, SWEEP_PER_ACCOUNT + 3); // ten of the big one and all three of the small one, first run
  const mine = (await s.deps.db.all("SELECT state FROM provider_operations WHERE account_id=?", other)).map((r) => r.state);
  assert.deepEqual(mine, ["done", "done", "done"]);
  assert.equal((await rows()).filter((r) => r.state === "pending").length, 20);
});

test("when the whole batch is not enough, every account still gets a share of it", async () => {
  const { s, vault, account, other, third, handlers, stuck } = await world();
  // Three accounts with ten stuck each: thirty against a batch of twenty-five. The oldest are one account's.
  for (const who of [account, other, third]) for (let i = 0; i < SWEEP_PER_ACCOUNT; i++) { await stuck(op(i + 1 + 100 * [account, other, third].indexOf(who), `${who}-${i}`), who); s.advance(10); }
  s.advance(SWEEP_AFTER + 1000);
  const out = await sweepStaleOperations(s.deps, vault, handlers);
  assert.equal(out.replayed, SWEEP_BATCH);
  const done = async (who) => (await s.deps.db.all("SELECT 1 FROM provider_operations WHERE account_id=? AND state='done'", who)).length;
  const shares = [await done(account), await done(other), await done(third)];
  assert.ok(Math.min(...shares) >= 8, `every account takes its turn, got ${shares}`);
  assert.equal(shares.reduce((a, b) => a + b, 0), SWEEP_BATCH);
});

test("interleave: oldest first within an account, accounts in turn", () => {
  const r = (a, n) => ({ account_id: a, n });
  assert.deepEqual(interleave([r("A", 1), r("A", 2), r("A", 3), r("B", 4), r("C", 5), r("B", 6)]).map((x) => x.n), [1, 4, 5, 2, 6, 3]);
  assert.deepEqual(interleave([]), []);
});

test("settleOperation does not touch an operation that is already done", async () => {
  const { s, vault, account, run, rows } = await world();
  assert.equal((await run(true, op(1, "m1"))).status, 200);
  await settleOperation(s.deps, vault, account, op(1, "m1").operationID, 412, "late");
  assert.deepEqual((await rows()).map((r) => [r.state, r.response_status]), [["done", 200]]);
});

test("every sweep query reads an index range, never the table (the first version scanned it per operation and overloaded D1)", async () => {
  const { s } = await world();
  const plan = async (sql, ...args) => (await s.deps.db.all("EXPLAIN QUERY PLAN " + sql, ...args)).map((r) => r.detail).join("\n");
  const candidates = await plan(CANDIDATES_SQL, 1, 1, 1, 100);
  const earlier = await plan(EARLIER_SQL, "a", "k", 1, 1, "o");
  const superseded = await plan(SUPERSEDED_SQL, "a", "k", 1);
  assert.match(candidates, /provider_operations_pending/);
  assert.match(earlier, /provider_operations_item \(account_id=\? AND resource_key=\?/);
  assert.match(superseded, /provider_operations_item \(account_id=\? AND resource_key=\?/);
  for (const text of [candidates, earlier, superseded]) assert.doesNotMatch(text, /SCAN/);
});
