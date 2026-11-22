import test from "node:test";
import assert from "node:assert/strict";
import { setup, device, DAY, TOKEN_KEY } from "./helpers.js";
import { createVault } from "../src/crypto.js";
import { providerOperation, forgetOldOperations, MOST_UNSENT, operationFailure } from "../src/provider-operation.js";

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
  return { s, refused };
}

test("an account holds at most MOST_UNSENT operations that never reached their provider; old ones go", async () => {
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
