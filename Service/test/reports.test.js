// POST /v1/reports: problem reports, spikes and ratings, with their objects in R2, kept 90 days.
import { test } from "node:test";
import assert from "node:assert/strict";
import { parseReport, blobKey, MOST_NOTE, ATTACHMENTS } from "../src/reports.js";
import { runJob } from "../src/job.js";
import { setup, device, DAY } from "./helpers.js";

const b64 = (text) => Buffer.from(text).toString("base64");
const base = {
  platform: "iphone", channel: "testflight", variant: "beta", version: "1.0 (84)", os: "27.1", device: "iPhone18,1",
};
const spike = (id = "spike-0001", extra = {}) => ({
  ...base, id, kind: "spike", detector: "storm", signature: "occurrences↻", page: "plan",
  numbers: { rate: 154, cpu: 92.5, window: 15 },
  attachments: [{ name: "log", type: "text/plain", data: b64("12-01 10:00:00.000  🌀 STORM: occurrences↻ at 154/s\n") }],
  ...extra,
});
const mailReport = (id = "problem-0001") => ({
  ...base, id, kind: "problem", page: "mail", note: "The table is squashed",
  context: { messageId: "18c2f0a1b2c3d4e5", preparerVersion: 3 },
  attachments: [
    { name: "screenshot", type: "image/jpeg", data: b64("\xff\xd8\xff fake jpeg") },
    { name: "mail-html", type: "text/html", data: b64("<table><tr><td>Hello</td></tr></table>") },
    { name: "mail-prepared", type: "application/json", data: b64('{"blocks":[]}') },
  ],
});

test("a report is whole or refused: the allow-lists, the pairing of kind with detector and rating", () => {
  assert.ok(parseReport(spike()));
  assert.ok(parseReport(mailReport()));
  assert.ok(parseReport({ ...base, id: "rating-0001", kind: "rating", rating: "up", page: "assistant" }));
  assert.equal(parseReport({ ...spike(), detector: undefined }), null, "a spike names its detector");
  assert.equal(parseReport({ ...mailReport(), detector: "storm" }), null, "only a spike has one");
  assert.equal(parseReport({ ...spike(), detector: "rm -rf" }), null);
  assert.equal(parseReport({ ...base, id: "rating-0002", kind: "rating", page: "assistant" }), null, "a rating is up or down");
  assert.equal(parseReport({ ...base, id: "rating-0003", kind: "rating", rating: "down", page: "assistant", note: "words" }), null,
    "a rating carries nothing of the person's");
  assert.equal(parseReport({ ...spike(), platform: "android" }), null);
  assert.equal(parseReport({ ...spike(), variant: "nightly" }), null);
  assert.equal(parseReport({ ...spike(), version: "1.0; DROP TABLE" }), null);
  assert.equal(parseReport({ ...spike(), id: "../../etc" }), null);
  assert.equal(parseReport({ ...spike(), page: "secret" }), null);
  assert.equal(parseReport({ ...mailReport(), note: "x".repeat(MOST_NOTE + 1) }), null);
  assert.equal(parseReport({ ...spike(), numbers: { "bad key!": 1 } }), null);
  assert.equal(parseReport({ ...spike(), numbers: { nested: { a: 1 } } }), null);
});

test("attachments: named, typed, sized, base64; one of each", () => {
  const with_ = (attachments) => parseReport({ ...mailReport(), attachments });
  assert.equal(with_([{ name: "keys", type: "text/plain", data: b64("x") }]), null, "a name off the list");
  assert.equal(with_([{ name: "log", type: "application/x-sh", data: b64("x") }]), null, "a type off the list");
  assert.equal(with_([{ name: "log", type: "text/plain", data: "not base64!" }]), null);
  assert.equal(with_([{ name: "log", type: "text/plain", data: "" }]), null, "empty");
  assert.equal(with_([{ name: "log", type: "text/plain", data: b64("a") }, { name: "log", type: "text/plain", data: b64("b") }]), null);
  const big = Buffer.alloc(ATTACHMENTS.log.most + 1, 65).toString("base64");
  assert.equal(with_([{ name: "log", type: "text/plain", data: big }]), null, "too large");
  const parsed = with_([{ name: "log", type: "text/plain", data: b64("line\n") }]);
  assert.deepEqual(JSON.parse(parsed.row.attachments), [{ name: "log", type: "text/plain", size: 5 }]);
});

test("a report is kept with its objects and no account, a retry is not kept twice", async () => {
  const s = setup();
  s.google.person("c1", "sub-1", "ann@example.com");
  const { session } = (await s.signIn("c1", device("phone-0001"))).json;
  assert.equal((await s.call("POST", "/v1/reports", { body: mailReport(), session })).status, 204);
  assert.equal((await s.call("POST", "/v1/reports", { body: mailReport() })).status, 204, "the same id again");
  const rows = await s.db.all("SELECT * FROM problem_reports");
  assert.equal(rows.length, 1);
  const row = rows[0];
  assert.equal(row.kind, "problem");
  assert.equal(row.page, "mail");
  assert.equal(row.note, "The table is squashed");
  assert.equal(row.pulled_at, null);
  assert.ok(!Object.keys(row).some((k) => /account|session|ip|address/.test(k)), "nothing ties it to a person");
  assert.deepEqual(JSON.parse(row.context), { messageId: "18c2f0a1b2c3d4e5", preparerVersion: 3 });
  const html = await s.deps.blobs.get(blobKey(row.id, "mail-html"));
  assert.equal(await new Response(html.body).text(), "<table><tr><td>Hello</td></tr></table>");
  assert.ok(await s.deps.blobs.head(blobKey(row.id, "screenshot")));
});

test("bad bodies are refused; the per-address limit applies", async () => {
  const s = setup();
  assert.equal((await s.call("POST", "/v1/reports", { body: "{not json" })).status, 400);
  assert.equal((await s.call("POST", "/v1/reports", { body: { ...spike(), kind: "other" } })).status, 400);
  let last;
  for (let i = 0; i < 61; i++) last = (await s.call("POST", "/v1/reports", { body: spike(`spike-${String(i).padStart(4, "0")}`) })).status;
  assert.equal(last, 429);
  assert.equal(await s.count("problem_reports"), 58, "the two refused bodies counted against the address too");
});

test("a day's reports stop at a number, and reports go with their objects after 90 days", async () => {
  const s = setup();
  const t = s.now();
  await s.db.run(`INSERT INTO problem_reports (id, received_at, kind, detector, signature, rating, platform, channel, variant, version, os, device, page, note, numbers, context, attachments, bytes)
                  VALUES ('flood', ?, 'spike', 'cpu', NULL, NULL, 'iphone', 'dev', 'beta', '1.0 (1)', '27.0', 'iPhone18,1', 'plan', NULL, '{}', '{}', '[]', ?)`,
                  t, 2 * 1024 * 1024 * 1024);
  assert.equal((await s.call("POST", "/v1/reports", { body: spike() })).status, 429, "the day's bytes");
  await s.db.run("DELETE FROM problem_reports");
  assert.equal((await s.call("POST", "/v1/reports", { body: spike() })).status, 204);
  assert.ok(await s.deps.blobs.head(blobKey("spike-0001", "log")));
  s.advance(91 * DAY);
  await runJob(s.deps);
  assert.equal(await s.count("problem_reports"), 0);
  assert.equal(await s.deps.blobs.head(blobKey("spike-0001", "log")), null);
});
