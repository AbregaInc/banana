// The usage allow-list (moved from Telemetry/test.mjs) and POST /v1/usage.
import { test } from "node:test";
import assert from "node:assert/strict";
import { rows } from "../src/usage.js";
import { setup, device } from "./helpers.js";

const base = { platform: "iphone", channel: "testflight", version: "1.0 (56)", cohort: "2026-W42", since: 3, calendar: true };

test("a day's batch becomes rows of counts", () => {
  assert.deepEqual(rows({ ...base, events: [{ event: "active", count: 1 }, { event: "feature", name: "mealLogged", detail: "scan", count: 2 }] }),
    [{ event: "active", name: "", detail: "", ...base, calendar: 1, count: 1 },
     { event: "feature", name: "mealLogged", detail: "scan", ...base, calendar: 1, count: 2 }]);
});

test("nothing off the lists gets through", () => {
  assert.deepEqual(rows({ ...base, events: [{ event: "feature", name: "Greek yogurt", count: 1 },
                                            { event: "location", name: "", count: 1 },
                                            { event: "feature", name: "mealLogged", detail: "Greek yogurt", count: 1 }] }), []);
});

test("a batch that isn't ours is refused whole", () => {
  assert.equal(rows({ ...base, platform: "android", events: [] }), null);
  assert.equal(rows({ ...base, version: "x; DROP TABLE counts", events: [] }), null);
  assert.equal(rows({ ...base, cohort: "2026-10-15", events: [] }), null);
});

test("counts and days are bounded", () => {
  assert.equal(rows({ ...base, since: 9999, events: [{ event: "active", count: 99999 }] })[0].count, 500);
  assert.equal(rows({ ...base, since: 9999, events: [{ event: "active", count: 1 }] })[0].since, 400);
});

test("setup facts: ranges and states from the list, a code only where a code belongs", () => {
  assert.deepEqual(rows({ ...base, events: [{ event: "setup", name: "calendars", detail: "3-5", count: 1 },
                                            { event: "setup", name: "region", detail: "US", count: 1 },
                                            { event: "setup", name: "region", detail: "Brooklyn", count: 1 },
                                            { event: "setup", name: "calendars", detail: "7", count: 1 },
                                            { event: "setup", name: "os", detail: "27", count: 1 }] }).map((r) => `${r.name}=${r.detail}`),
    ["calendars=3-5", "region=US", "os=27"]);
});

const batch = { ...base, calendar: false, events: [{ event: "active", count: 1 }, { event: "feature", name: "mealLogged", detail: "scan", count: 2 }] };

test("anonymous batch: counts only, added to the day's totals", async () => {
  const s = setup();
  assert.equal((await s.call("POST", "/v1/usage", { body: batch })).status, 204);
  assert.equal((await s.call("POST", "/v1/usage", { body: batch })).status, 204);
  const meal = await s.db.first("SELECT * FROM counts WHERE name = 'mealLogged'");
  assert.equal(meal.count, 4);
  assert.equal(meal.day, "2026-10-15");
  assert.equal(meal.calendar, 0);
  assert.equal(await s.count("counts"), 2);
  assert.equal(await s.count("account_usage"), 0);
});

test("signed-in batch: counts and the account's usage", async () => {
  const s = setup();
  s.google.person("c1", "sub-1", "a@example.com");
  const { json } = await s.signIn("c1", device("phone-0001"));
  await s.call("POST", "/v1/usage", { body: batch, session: json.session });
  await s.call("POST", "/v1/usage", { body: batch, session: json.session });
  assert.equal(await s.count("counts"), 2);
  const rows = await s.db.all("SELECT * FROM account_usage ORDER BY event");
  assert.deepEqual(rows.map((r) => [r.account_id, r.day, r.event, r.name, r.detail, r.platform, r.version, r.count]),
    [[json.account.id, "2026-10-15", "active", "", "", "iphone", "1.0 (56)", 2],
     [json.account.id, "2026-10-15", "feature", "mealLogged", "scan", "iphone", "1.0 (56)", 4]]);
  // A session that's gone just makes it anonymous.
  assert.equal((await s.call("POST", "/v1/usage", { body: batch, session: "x".repeat(43) })).status, 204);
  assert.equal(await s.count("account_usage"), 2);
});

test("bad and oversized batches", async () => {
  const s = setup();
  assert.equal((await s.call("POST", "/v1/usage", { body: "{not json" })).status, 400);
  assert.equal((await s.call("POST", "/v1/usage", { body: { ...batch, platform: "android" } })).status, 400);
  assert.equal((await s.call("POST", "/v1/usage", { body: { ...batch, pad: "x".repeat(20_000) } })).status, 413);
  assert.equal(await s.count("counts"), 0);
});

test("module facts: which ones are on, as on or off", () => {
  const names = ["allModules", "workoutsModule", "foodModule", "notesModule", "podcastsModule"];
  assert.deepEqual(rows({ ...base, events: [...names.map((name) => ({ event: "setup", name, detail: "on", count: 1 })),
                                            { event: "setup", name: "mailModule", detail: "on", count: 1 }] })
    .map((r) => `${r.name}=${r.detail}`), names.map((n) => `${n}=on`));
});

test("legacy health inventory counts are dropped without losing the rest of the batch", () => {
  assert.deepEqual(rows({ ...base, events: [
    ...["workouts7d", "meals7d", "supplements", "myFoods"].map(name => ({ event: "setup", name, detail: "3-5", count: 1 })),
    { event: "active", count: 1 },
  ] }).map(r => r.name), [""]);
});

test("usage rows: a day holds so many, an address sends so much, and totals go after 400 days (audit run-1)", async () => {
  const { runJob } = await import("../src/job.js");
  const { DAY } = await import("./helpers.js");
  const s = setup();
  for (let i = 0; i < 59; i++) assert.equal((await s.call("POST", "/v1/usage", { body: { ...batch, version: `1.${i} (1)` } })).status, 204);
  assert.equal((await s.call("POST", "/v1/usage", { body: batch })).status, 204);
  assert.equal((await s.call("POST", "/v1/usage", { body: batch })).status, 429, "the per-address limit");
  const fresh = setup();
  const day = new Date(fresh.now()).toISOString().slice(0, 10);
  await fresh.db.run(`INSERT INTO counts (day, event, name, detail, platform, channel, version, cohort, since, calendar, count)
    WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 19999)
    SELECT ?, 'active', '', '', 'iphone', 'appstore', 'v' || i, '2026-W42', 0, 0, 1 FROM n`, day);
  assert.equal((await fresh.call("POST", "/v1/usage", { body: batch })).status, 429, "the day's row cap");
  fresh.advance(401 * DAY);
  await runJob(fresh.deps);
  assert.equal(await fresh.count("counts"), 0);
});
