import test from "node:test";
import assert from "node:assert/strict";
import { setup, device, DAY, TOKEN_KEY } from "./helpers.js";
import { createVault } from "../src/crypto.js";
import { providerOperation, forgetOldOperations, MOST_UNSENT, MOST_HELD, RECENT_UNSENT, operationFailure } from "../src/provider-operation.js";

async function world() {
  const s = setup();
  s.google.person("c", "sub-ann", "ann@example.com");
  const ann = (await s.signIn("c", device("phone-0001"))).json;
  const vault = createVault(TOKEN_KEY, s.deps.random);
  // An operation whose preparation refuses: its intent is kept, and nothing reaches the provider.
  const refused = (id) => providerOperation(s.deps, vault, {
    account: ann.account.id, operationID: id, googleSub: "sub-ann", provider: "test", resource: { id }, request: { body: "x".repeat(1000) },
    enabled: async () => true, prepare: async () => operationFailure(409, "not now"), dispatch: async () => ({ status: 200, body: {} }), reconcile: async () => null,
  });
  // The same operation, its provider reachable: what a device's retry does.
  const sendable = (id) => providerOperation(s.deps, vault, {
    account: ann.account.id, operationID: id, googleSub: "sub-ann", provider: "test", resource: { id }, request: { body: "x".repeat(1000) },
    enabled: async () => true, prepare: async () => null, dispatch: async () => ({ status: 200, body: {} }), reconcile: async () => null,
  });
  return { s, refused, sendable };
}

test("a burst of MOST_UNSENT operations that never reached their provider is refused; old ones go", async () => {
  const { s, refused } = await world();
  for (let i = 0; i < MOST_UNSENT; i++) assert.equal((await refused(`op-${i}`)).status, 409);
  assert.equal((await refused("op-one-more")).status, 429);
  assert.equal(await s.count("provider_operations"), MOST_UNSENT);
  // A retry of one it already holds still answers as before.
  assert.equal((await refused("op-0")).status, 409);
  s.advance(8 * DAY);
  await forgetOldOperations(s.deps);
  assert.equal(await s.count("provider_operations"), 0);
  assert.equal((await refused("op-later")).status, 409);
});

test("unsent operations older than the burst window never block new ones, and are still sent when retried", async () => {
  const { s, refused, sendable } = await world();
  for (let i = 0; i < MOST_UNSENT; i++) assert.equal((await refused(`op-${i}`)).status, 409);
  assert.equal((await refused("blocked-now")).status, 429);
  s.advance(RECENT_UNSENT + 1000);
  // The stale hundred are still stored, and no longer a wall.
  assert.equal(await s.count("provider_operations"), MOST_UNSENT);
  assert.equal((await refused("fresh-1")).status, 409);
  assert.equal((await refused("fresh-2")).status, 409);
  // Retrying a stale one with the same identity sends it: nothing was deleted or lost.
  assert.equal((await sendable("op-0")).status, 200);
  assert.equal((await sendable("op-99")).status, 200);
});

test("an account never holds more than MOST_HELD unsent operations, however old", async () => {
  const { s, refused } = await world();
  for (let i = 0; i < MOST_HELD; i++) {
    if (i % MOST_UNSENT === 0) s.advance(RECENT_UNSENT + 1000);
    assert.equal((await refused(`op-${i}`)).status, 409);
  }
  s.advance(RECENT_UNSENT + 1000);
  assert.equal((await refused("one-too-many")).status, 429);
  assert.equal(await s.count("provider_operations"), MOST_HELD);
});
