// POST /v1/diagnostics: anonymous crash, hang and performance reports, kept 90 days.
import { test } from "node:test";
import assert from "node:assert/strict";
import { reportRows, MOST_PAYLOAD } from "../src/diagnostics.js";
import { runJob } from "../src/job.js";
import { setup, device, DAY } from "./helpers.js";

const base = { platform: "iphone", channel: "appstore", version: "1.0 (61)", os: "27.0.1" };
const crash = { kind: "crash", signature: "EXC_BAD_ACCESS/11", payload: { callStackTree: { callStacks: [] }, diagnosticMetaData: { osVersion: "iPhone OS 27.0.1" } } };

test("a batch of reports becomes rows; a report off the list or too large is dropped alone", () => {
  const rows = reportRows({ ...base, reports: [crash, { kind: "screenshot", payload: {} }, { kind: "hang", payload: "x" },
                                               { kind: "metrics", payload: { big: "x".repeat(MOST_PAYLOAD) } }] });
  assert.deepEqual(rows.map((r) => [r.kind, r.signature, r.os]), [["crash", "EXC_BAD_ACCESS/11", "27.0.1"]]);
  assert.equal(reportRows({ ...base, platform: "android", reports: [] }), null);
  assert.equal(reportRows({ ...base, version: "1.0; DROP TABLE", reports: [] }), null);
  assert.equal(reportRows({ ...base, os: "iPhone OS", reports: [crash] })[0].os, null);
});

test("reports are kept with no account even when a session comes along, and go after 90 days", async () => {
  const s = setup();
  s.google.person("c1", "sub-1", "ann@example.com");
  const { session } = (await s.signIn("c1", device("phone-0001"))).json;
  assert.equal((await s.call("POST", "/v1/diagnostics", { body: { ...base, reports: [crash, crash] }, session })).status, 204);
  assert.equal((await s.call("POST", "/v1/diagnostics", { body: { ...base, reports: [crash] } })).status, 204);
  const rows = await s.db.all("SELECT * FROM diagnostics");
  assert.equal(rows.length, 3);
  assert.deepEqual(Object.keys(rows[0]).sort(), ["channel", "id", "kind", "os", "payload", "platform", "received_at", "signature", "version"]);
  assert.equal((await s.call("POST", "/v1/diagnostics", { body: { platform: "iphone" } })).status, 400);
  s.advance(91 * DAY);
  await runJob(s.deps);
  assert.equal(await s.count("diagnostics"), 0);
});

test("reports stop at a number of bytes a day, not only a number of rows (audit run-1)", async () => {
  const s = setup();
  const t = s.now();
  // 128 MiB of payload already kept today (two rows of 64 MiB of text).
  for (const id of ["big-1", "big-2"]) {
    await s.db.run(`INSERT INTO diagnostics (id, received_at, kind, signature, platform, channel, version, os, payload)
                    VALUES (?, ?, 'metrics', NULL, 'iphone', 'appstore', '1.0 (1)', NULL, hex(zeroblob(32 * 1024 * 1024)))`, id, t);
  }
  assert.equal((await s.call("POST", "/v1/diagnostics", { body: { ...base, reports: [crash] } })).status, 429);
  await s.db.run("DELETE FROM diagnostics");
  assert.equal((await s.call("POST", "/v1/diagnostics", { body: { ...base, reports: [crash] } })).status, 204);
  for (let i = 0; i < 59; i++) await s.call("POST", "/v1/diagnostics", { body: { ...base, reports: [crash] } });
  assert.equal((await s.call("POST", "/v1/diagnostics", { body: { ...base, reports: [crash] } })).status, 429, "the per-address limit");
});
