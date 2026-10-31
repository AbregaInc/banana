import { test } from "node:test";
import assert from "node:assert/strict";
import { setup, device, pushToken, TOKEN_KEY, DAY } from "./helpers.js";
import { createVault, sha256Hex } from "../src/crypto.js";

test("health, unknown routes, signed-out calls", async () => {
  const s = setup();
  const health = await s.call("GET", "/v1/health");
  assert.deepEqual([health.status, health.text], [200, "ok"]);
  assert.equal((await s.call("GET", "/nope")).status, 404);
  assert.equal((await s.call("GET", "/v1/google")).status, 404);
  for (const [method, path] of [["GET", "/v1/account"], ["PUT", "/v1/devices/phone-0001"], ["PUT", "/v1/google/calendars"]]) {
    const r = await s.call(method, path, method === "GET" ? {} : { body: {} });
    assert.deepEqual([r.status, r.json], [401, { error: "signed_out" }], `${method} ${path}`);
  }
  assert.equal((await s.call("GET", "/v1/account", { session: "unknown-session-token-0000000000" })).status, 401);
});

test("sign-in makes an account and a session", async () => {
  const s = setup();
  s.google.person("c1", "sub-1", "Ann@Example.com");
  const r = await s.signIn("c1", device("phone-0001", { push: pushToken(1) }));
  assert.equal(r.status, 200);
  assert.match(r.json.session, /^[A-Za-z0-9_-]{43}$/);
  assert.deepEqual(r.json.account, { id: r.json.account.id, google: [{ email: "ann@example.com", status: "ok", watching: 0, access: true }], devices: 1, seeded: [], flipped: false, icloud: "keep" });
  // Only the session's hash is kept.
  const row = await s.db.first("SELECT * FROM sessions");
  assert.equal(row.token_hash, await sha256Hex(r.json.session));
  assert.equal(row.account_id, r.json.account.id);
  const me = await s.call("GET", "/v1/account", { session: r.json.session });
  assert.deepEqual(me.json, r.json.account);
  assert.deepEqual((await s.db.all("SELECT action FROM audit")).map((a) => a.action), ["link"]);
});

test("a second Google account on a signed-in device links to the same account", async () => {
  const s = setup();
  s.google.person("c1", "sub-1", "ann@example.com");
  s.google.person("c2", "sub-2", "ann@work.example");
  const first = await s.signIn("c1", device("phone-0001"));
  const second = await s.signIn("c2", device("phone-0001"), first.json.session);
  assert.equal(second.status, 200);
  assert.equal(second.json.session, undefined);
  assert.equal(second.json.account.id, first.json.account.id);
  assert.deepEqual(second.json.account.google.map((g) => g.email), ["ann@example.com", "ann@work.example"]);
  assert.equal(await s.count("accounts"), 1);
});

test("the same Google account from a signed-out device finds the same account", async () => {
  const s = setup();
  s.google.person("c1", "sub-1", "ann@example.com");
  const phone = await s.signIn("c1", device("phone-0001"));
  const mac = await s.signIn("c1", device("mac-00000001", { platform: "mac" }));
  assert.equal(mac.json.account.id, phone.json.account.id);
  assert.notEqual(mac.json.session, phone.json.session);
  assert.equal(mac.json.account.devices, 2);
  assert.equal(await s.count("accounts"), 1);
  assert.equal(await s.count("sessions"), 2);
});

test("a Google account that belongs to another account: 409", async () => {
  const s = setup();
  s.google.person("c1", "sub-1", "ann@example.com");
  s.google.person("c2", "sub-2", "bob@example.com");
  const ann = await s.signIn("c1", device("phone-0001"));
  await s.signIn("c2", device("phone-0002"));
  const r = await s.signIn("c2", device("phone-0001"), ann.json.session);
  assert.deepEqual([r.status, r.json], [409, { error: "other_account" }]);
  assert.equal((await s.db.first("SELECT account_id FROM google_links WHERE sub = 'sub-2'")).account_id === ann.json.account.id, false);
});

test("Google refuses the code: 401 google_refused, nothing made", async () => {
  const s = setup();
  const r = await s.signIn("not-a-code", device("phone-0001"));
  assert.deepEqual([r.status, r.json], [401, { error: "google_refused" }]);
  assert.equal(await s.count("accounts"), 0);
});

test("a bad device is refused before Google is asked", async () => {
  const s = setup();
  s.google.person("c1", "sub-1", "ann@example.com");
  for (const bad of [device("short"), device("phone-0001", { platform: "android" }), device("phone-0001", { push: "xyz" }),
                     device("phone-0001", { pushEnv: "staging" }), device("phone-0001", { bundle: "a b" }), null]) {
    assert.equal((await s.signIn("c1", bad)).status, 400);
  }
  assert.equal((await s.call("POST", "/v1/google", { body: { device: device("phone-0001") } })).status, 400);
  assert.equal(s.google.calls.exchange, 0);
});

test("the refresh token is stored sealed, and only opens on its own row", async () => {
  const s = setup();
  s.google.person("c1", "sub-1", "ann@example.com", "1//plain-refresh-token");
  await s.signIn("c1", device("phone-0001"));
  const { refresh_token: stored } = await s.db.first("SELECT refresh_token FROM google_links WHERE sub = 'sub-1'");
  assert.match(stored, /^v1\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/);
  assert.ok(!stored.includes("plain-refresh-token"));
  const vault = createVault(TOKEN_KEY, s.deps.random);
  assert.equal(await vault.open("sub-1", stored), "1//plain-refresh-token");
  await assert.rejects(vault.open("sub-2", stored));
});

test("devices: upsert, move between accounts, delete only your own", async () => {
  const s = setup();
  s.google.person("c1", "sub-1", "ann@example.com");
  s.google.person("c2", "sub-2", "bob@example.com");
  const ann = (await s.signIn("c1", device("phone-0001"))).json;
  const bob = (await s.signIn("c2", device("phone-0002"))).json;

  const put = (id, session, body = { platform: "ipad", push: pushToken(3), pushEnv: "development", bundle: "app.banana.Banana" }) =>
    s.call("PUT", `/v1/devices/${id}`, { body, session });
  assert.equal((await put("ipad-0001", ann.session)).status, 204);
  assert.equal((await put("ipad-0001", ann.session)).status, 204);
  let row = await s.db.first("SELECT * FROM devices WHERE id = 'ipad-0001'");
  assert.deepEqual([row.account_id, row.platform, row.push_token, row.push_env], [ann.account.id, "ipad", pushToken(3), "development"]);
  assert.equal((await s.call("GET", "/v1/account", { session: ann.session })).json.devices, 2);
  assert.equal((await put("ipad-0001", ann.session, { platform: "ipad" })).status, 400);

  // A session cannot take another account's device row by naming its id (audit run-1: a stranger
  // knowing a device id could cut it off); the same device signing in as Bob moves it, on the record.
  assert.equal((await put("ipad-0001", bob.session)).status, 409);
  row = await s.db.first("SELECT * FROM devices WHERE id = 'ipad-0001'");
  assert.equal(row.account_id, ann.account.id);
  assert.equal((await s.signIn("c2", device("ipad-0001", { platform: "ipad", push: pushToken(3) }), bob.session)).status, 200);
  row = await s.db.first("SELECT * FROM devices WHERE id = 'ipad-0001'");
  assert.equal(row.account_id, bob.account.id);
  assert.equal(await s.count("audit", "action = 'device_moved'"), 1);

  // Ann can't delete Bob's device; Bob can.
  assert.equal((await s.call("DELETE", "/v1/devices/ipad-0001", { session: ann.session })).status, 204);
  assert.equal(await s.count("devices", "id = 'ipad-0001'"), 1);
  assert.equal((await s.call("DELETE", "/v1/devices/ipad-0001", { session: bob.session })).status, 204);
  assert.equal(await s.count("devices", "id = 'ipad-0001'"), 0);
});

test("a session's last use is written at most once a day", async () => {
  const s = setup();
  s.google.person("c1", "sub-1", "ann@example.com");
  const { session } = (await s.signIn("c1", device("phone-0001"))).json;
  const first = (await s.db.first("SELECT last_used_at FROM sessions")).last_used_at;
  s.advance(DAY / 2);
  await s.call("GET", "/v1/account", { session });
  assert.equal((await s.db.first("SELECT last_used_at FROM sessions")).last_used_at, first);
  s.advance(DAY);
  await s.call("GET", "/v1/account", { session });
  assert.equal((await s.db.first("SELECT last_used_at FROM sessions")).last_used_at, s.now());
});

test("unlinking one Google account stops its watches, revokes its token, keeps the rest", async () => {
  const s = setup();
  s.google.person("c1", "sub-1", "ann@example.com");
  s.google.person("c2", "sub-2", "ann@work.example");
  const { session } = (await s.signIn("c1", device("phone-0001"))).json;
  await s.signIn("c2", device("phone-0001"), session);
  await s.call("PUT", "/v1/google/calendars", { body: { email: "ann@work.example", ids: ["work"] }, session });
  await s.settle();
  const r = await s.call("DELETE", "/v1/google", { body: { email: "Ann@Work.example" }, session });
  assert.equal(r.status, 204);
  assert.deepEqual(s.google.calls.revoke, ["refresh-sub-2"]);
  assert.equal(s.google.calls.stop.length, 1);
  assert.equal(await s.count("watches"), 0);
  assert.deepEqual((await s.call("GET", "/v1/account", { session })).json.google.map((g) => g.email), ["ann@example.com"]);
  assert.ok((await s.db.all("SELECT action FROM audit")).some((a) => a.action === "unlink"));
});

test("deleting the account removes every row and revokes every token", async () => {
  const s = setup();
  s.google.person("c1", "sub-1", "ann@example.com");
  s.google.person("c2", "sub-2", "ann@work.example");
  s.google.person("c3", "sub-3", "bob@example.com");
  const ann = (await s.signIn("c1", device("phone-0001", { push: pushToken(1) }))).json;
  await s.signIn("c2", device("mac-00000001", { platform: "mac" }), ann.session);
  const bob = (await s.signIn("c3", device("phone-0002"))).json;
  await s.call("PUT", "/v1/google/calendars", { body: { email: "ann@example.com", ids: ["primary", "family"] }, session: ann.session });
  await s.call("PUT", "/v1/google/calendars", { body: { email: "ann@work.example", ids: ["work"] }, session: ann.session });
  await s.settle();
  const usage = { platform: "iphone", channel: "appstore", version: "1.0 (60)", cohort: "2026-W42", since: 0, calendar: true, events: [{ event: "active", count: 1 }] };
  await s.call("POST", "/v1/usage", { body: usage, session: ann.session });
  await s.call("POST", "/v1/usage", { body: usage, session: bob.session });

  // A fresh sign-in with one of Ann's Google accounts (the work one) deletes it; its new token is revoked too.
  s.google.person("fresh", "sub-2", "ann@work.example", "refresh-sub-2-fresh");
  const r = await s.call("DELETE", "/v1/account", { body: { code: "fresh" }, session: ann.session });
  assert.equal(r.status, 204);
  await s.settle();
  assert.deepEqual(s.google.calls.revoke.sort(), ["refresh-sub-1", "refresh-sub-2", "refresh-sub-2-fresh"]);
  assert.equal(s.google.calls.stop.length, 3);
  const id = ann.account.id;
  for (const [table, column] of [["accounts", "id"], ["google_links", "account_id"], ["sessions", "account_id"], ["devices", "account_id"],
                                 ["watches", "account_id"], ["account_usage", "account_id"]]) {
    assert.equal(await s.count(table, `${column} = ?`, id), 0, table);
  }
  assert.deepEqual(await s.db.all("SELECT account_id, action FROM audit WHERE account_id = ?", id), [{ account_id: id, action: "delete" }]);
  // Bob and the anonymous totals are untouched; Ann's session is gone.
  assert.equal(await s.count("google_links", "sub = 'sub-3'"), 1);
  assert.equal(await s.count("account_usage", "account_id = ?", bob.account.id), 1);
  assert.equal((await s.db.first("SELECT count FROM counts")).count, 2);
  assert.equal((await s.call("GET", "/v1/account", { session: ann.session })).status, 401);
  // Signing in again with the same Google account makes a new account.
  s.google.person("c4", "sub-1", "ann@example.com");
  const again = (await s.signIn("c4", device("phone-0001"))).json;
  assert.notEqual(again.account.id, id);
});

test("deleting needs a fresh Google sign-in to that account; a session alone never deletes", async () => {
  const s = setup();
  s.google.person("c1", "sub-1", "ann@example.com");
  s.google.person("c2", "sub-2", "bob@example.com");
  const ann = (await s.signIn("c1", device("phone-0001"))).json;
  await s.signIn("c2", device("phone-0002"));
  const del = (body, session) => s.call("DELETE", "/v1/account", { body, session });

  assert.deepEqual([(await del({}, ann.session)).status, (await del({}, ann.session)).json], [401, { error: "google_sign_in_required" }]);
  assert.equal((await s.call("DELETE", "/v1/account", { session: ann.session })).status, 401);
  assert.deepEqual((await del({ code: "used-or-made-up" }, ann.session)).json, { error: "google_refused" });
  // Bob's Google account can't delete Ann's account from Ann's device.
  s.google.person("bob-fresh", "sub-2", "bob@example.com");
  assert.deepEqual((await del({ code: "bob-fresh" }, ann.session)).json, { error: "other_account" });
  // A Google account Banana has never seen has nothing to delete.
  s.google.person("new", "sub-9", "new@example.com");
  assert.deepEqual((await del({ code: "new" })).json, { error: "no_account" });
  assert.equal(await s.count("accounts"), 2);

  // Without any session (the website, or a device whose session ended), the fresh sign-in is enough.
  s.google.person("ann-fresh", "sub-1", "ann@example.com");
  assert.equal((await del({ code: "ann-fresh" })).status, 204);
  assert.equal(await s.count("accounts"), 1);
});

test("disconnecting keeps who the Google account is, so it signs in to the same account and can delete it", async () => {
  const s = setup();
  s.google.person("c1", "sub-1", "ann@example.com");
  const ann = (await s.signIn("c1", device("phone-0001"))).json;
  assert.equal((await s.call("DELETE", "/v1/google", { body: { email: "ann@example.com" }, session: ann.session })).status, 204);
  const link = await s.db.first("SELECT status, refresh_token FROM google_links");
  assert.deepEqual([link.status, link.refresh_token], ["unlinked", null]);
  // Still signed in, with no Google account listed and none to watch.
  const me = await s.call("GET", "/v1/account", { session: ann.session });
  assert.deepEqual([me.status, me.json.google], [200, []]);
  assert.equal((await s.call("PUT", "/v1/google/calendars", { body: { email: "ann@example.com", ids: ["primary"] }, session: ann.session })).status, 404);
  // Signing in again from another device finds the same account.
  s.google.person("c2", "sub-1", "ann@example.com", "refresh-sub-1-new");
  const again = (await s.signIn("c2", device("mac-00000001", { platform: "mac" }))).json;
  assert.equal(again.account.id, ann.account.id);
  assert.deepEqual(again.account.google.map((g) => g.status), ["ok"]);
});

test("access: an identity link has none, a code sign-in gives it, a code without a refresh token leaves things as they were", async () => {
  const s = setup();
  s.google.identity("t-ann", "sub-1", "ann@example.com");
  const first = await s.call("POST", "/v1/google/identity", { body: { idToken: "t-ann", device: device("phone-0001") } });
  const { session } = first.json;
  assert.deepEqual(first.json.account.google.map((g) => [g.status, g.access]), [["ok", false]]);

  // Signing in again with a code: the service now holds a token, the link is 'ok' with access.
  s.google.person("c1", "sub-1", "ann@example.com");
  const again = await s.signIn("c1", device("phone-0001"), session);
  assert.deepEqual(again.json.account.google.map((g) => [g.status, g.access]), [["ok", true]]);
  assert.ok((await s.db.first("SELECT refresh_token FROM google_links")).refresh_token);

  // Google leaves the refresh token out of a later exchange (already granted): the held one stays.
  s.google.person("c2", "sub-1", "ann@example.com", null);
  const kept = await s.signIn("c2", device("phone-0001"), session);
  assert.deepEqual(kept.json.account.google.map((g) => [g.status, g.access]), [["ok", true]]);

  // A second Google account, by identity: no access; a code without a token for it: still 'ok', no access, not 'refused'.
  s.google.identity("t-work", "sub-2", "ann@work.example");
  await s.call("POST", "/v1/google/identity", { body: { idToken: "t-work", device: device("phone-0001") }, session });
  s.google.person("c3", "sub-2", "ann@work.example", null);
  const work = await s.signIn("c3", device("phone-0001"), session);
  assert.deepEqual(work.json.account.google.map((g) => [g.email, g.status, g.access]),
    [["ann@example.com", "ok", true], ["ann@work.example", "ok", false]]);
  // Identity sign-ins never take access away.
  const back = await s.call("POST", "/v1/google/identity", { body: { idToken: "t-ann", device: device("phone-0001") }, session });
  assert.equal(back.json.account.google[0].access, true);
});

test("an account holds a handful of device rows, not thousands (audit run-1)", async () => {
  const s = setup();
  s.google.person("c1", "sub-1", "ann@example.com");
  const { session } = (await s.signIn("c1", device("phone-0001"))).json;
  let last;
  for (let n = 2; n <= 26; n++) {
    last = await s.call("PUT", `/v1/devices/dev-${String(n).padStart(5, "0")}`, { session,
      body: { platform: "ipad", push: n.toString(16).padStart(64, "0"), pushEnv: "production", bundle: "app.banana.Banana" } });
  }
  assert.equal(last.status, 409);
  assert.equal(last.json.error, "too_many_devices");
  assert.equal(await s.count("devices"), 25);
  // One of its own again is fine.
  assert.equal((await s.call("PUT", "/v1/devices/dev-00002", { session, body: { platform: "ipad", pushEnv: "production", bundle: "app.banana.Banana" } })).status, 204);
});
