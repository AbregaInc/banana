import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { setup } from "./helpers.js";

const route = "/v1/assistant/model-catalog";
const key = "public/assistant-model-catalog-v1";

async function put(blobs, text) {
  const body = new TextEncoder().encode(text);
  await blobs.put(key, body, { sha256: createHash("sha256").update(body).digest("hex") });
}

test("model catalog serves only the fixed publish object without sign-in", async () => {
  const { app, deps } = setup();
  const missing = await app.request(route);
  assert.equal(missing.status, 404);
  assert.equal(missing.headers.get("cache-control"), "no-store");
  const fixture = '{"payload":"fixture","signature":"fixture"}';
  await put(deps.blobs, fixture);
  const response = await app.request(route + "?channel=beta&key=other");
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("cache-control"), "public, max-age=300");
  assert.equal(await response.text(), fixture);
});

test("model catalog refuses an oversized object", async () => {
  const { app, deps } = setup();
  await put(deps.blobs, "x".repeat(128 * 1024 + 1));
  const response = await app.request(route);
  assert.equal(response.status, 503);
  assert.equal(response.headers.get("cache-control"), "no-store");
});
