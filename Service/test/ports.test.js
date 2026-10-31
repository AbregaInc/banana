// The real Google and APNs ports against a fake fetch, the crypto, and the SQLite adapter.
import { test } from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createApns } from "../src/apns.js";
import { createGoogle, GoogleRefused, GoogleError } from "../src/google.js";
import { base64url, constantTimeEqual, createVault, fromBase64 } from "../src/crypto.js";
import { sqlite } from "../src/adapters/sqlite.js";

const random = (n) => crypto.getRandomValues(new Uint8Array(n));

function fakeFetch(answer) {
  const calls = [];
  const f = async (url, init = {}) => {
    calls.push({ url: String(url), ...init });
    const { status = 200, body = {} } = typeof answer === "function" ? answer(String(url), init, calls.length) : answer;
    return new Response(status === 204 ? null : JSON.stringify(body), { status });
  };
  f.calls = calls;
  return f;
}

const idToken = (claims) => `${base64url(new TextEncoder().encode('{"alg":"RS256"}'))}.${base64url(new TextEncoder().encode(JSON.stringify(claims)))}.sig`;
const NOW = Date.UTC(2026, 9, 15, 12);
const config = { googleClientId: "web-client.apps.googleusercontent.com", googleClientSecret: "secret", googleRedirectUri: "" };
const good = { iss: "https://accounts.google.com", aud: config.googleClientId, sub: "1234", email: "Ann@Example.com", email_verified: true, exp: NOW / 1000 + 3600 };

test("google: the code is traded with the web client and an empty redirect", async () => {
  const fetch = fakeFetch({ body: { access_token: "at", expires_in: 3599, refresh_token: "rt", scope: "openid email", id_token: idToken(good) } });
  const google = createGoogle(config, fetch, () => NOW);
  assert.deepEqual(await google.exchangeCode("4/code"), { sub: "1234", email: "ann@example.com", refreshToken: "rt", scopes: "openid email", name: null, accessToken: "at" });
  const sent = new URLSearchParams(fetch.calls[0].body);
  assert.equal(fetch.calls[0].url, "https://oauth2.googleapis.com/token");
  assert.deepEqual(Object.fromEntries(sent), { client_id: config.googleClientId, client_secret: "secret", code: "4/code", grant_type: "authorization_code", redirect_uri: "" });
  // The access token from the trade is reused.
  assert.deepEqual(await google.refresh("rt"), { accessToken: "at", expiresAt: NOW + 3599_000 });
  assert.equal(fetch.calls.length, 1);
});

test("google: id_token claims are checked", async () => {
  for (const bad of [{ ...good, aud: "other" }, { ...good, iss: "https://evil.example" }, { ...good, exp: NOW / 1000 - 1 }, { ...good, email_verified: false }]) {
    const google = createGoogle(config, fakeFetch({ body: { access_token: "at", refresh_token: "rt", id_token: idToken(bad) } }), () => NOW);
    await assert.rejects(google.exchangeCode("c"), GoogleRefused);
  }
});

test("google: invalid_grant is GoogleRefused, other failures are GoogleError", async () => {
  const refused = createGoogle(config, fakeFetch({ status: 400, body: { error: "invalid_grant" } }), () => NOW);
  await assert.rejects(refused.exchangeCode("c"), GoogleRefused);
  await assert.rejects(refused.refresh("rt"), GoogleRefused);
  const down = createGoogle(config, fakeFetch({ status: 500, body: {} }), () => NOW);
  await assert.rejects(down.refresh("rt"), GoogleError);
  const misconfigured = createGoogle(config, fakeFetch({ status: 400, body: { error: "invalid_client" } }), () => NOW);
  await assert.rejects(misconfigured.refresh("rt"), (e) => e instanceof GoogleError && !(e instanceof GoogleRefused) && !e.message.includes("rt"));
});

test("google: access tokens are cached until a minute before they end", async () => {
  let clock = NOW;
  const fetch = fakeFetch((url, init, n) => ({ body: { access_token: `at${n}`, expires_in: 3600 } }));
  const google = createGoogle(config, fetch, () => clock);
  assert.equal((await google.refresh("rt")).accessToken, "at1");
  clock += 58 * 60 * 1000;
  assert.equal((await google.refresh("rt")).accessToken, "at1");
  clock += 90 * 1000;
  assert.equal((await google.refresh("rt")).accessToken, "at2");
  assert.equal((await google.refresh("other")).accessToken, "at3");
});

test("google: watch, stop and revoke send what Google expects", async () => {
  const fetch = fakeFetch((url) => url.endsWith("/watch") ? { body: { resourceId: "res", expiration: String(NOW + 1000) } } : { status: 204 });
  const google = createGoogle(config, fetch, () => NOW);
  assert.deepEqual(await google.watch("at", "family#x@group.calendar.google.com", { id: "chan", token: "secret", address: "https://s.example/v1/google/notify", ttlSeconds: 604800 }),
    { resourceId: "res", expiration: NOW + 1000 });
  assert.equal(fetch.calls[0].url, "https://www.googleapis.com/calendar/v3/calendars/family%23x%40group.calendar.google.com/events/watch");
  assert.equal(fetch.calls[0].headers.authorization, "Bearer at");
  assert.deepEqual(JSON.parse(fetch.calls[0].body), { id: "chan", type: "web_hook", address: "https://s.example/v1/google/notify", token: "secret", params: { ttl: "604800" } });
  await google.stop("at", { id: "chan", resourceId: "res" });
  assert.equal(fetch.calls[1].url, "https://www.googleapis.com/calendar/v3/channels/stop");
  assert.deepEqual(JSON.parse(fetch.calls[1].body), { id: "chan", resourceId: "res" });
  await google.revoke("rt");
  assert.equal(fetch.calls[2].url, "https://oauth2.googleapis.com/revoke");
  assert.equal(new URLSearchParams(fetch.calls[2].body).get("token"), "rt");
});

async function p8() {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  const b64 = btoa(String.fromCharCode(...der)).match(/.{1,64}/g).join("\n");
  return { pem: `-----BEGIN PRIVATE KEY-----\n${b64}\n-----END PRIVATE KEY-----\n`, publicKey: pair.publicKey };
}

test("apns: the provider JWT is ES256 and verifies with the matching public key", async () => {
  const { pem, publicKey } = await p8();
  let clock = NOW;
  const fetch = fakeFetch({ status: 200, body: {} });
  const apns = createApns({ apnsKey: pem, apnsKeyId: "KEY123ABCD", apnsTeamId: "TEAM123456" }, fetch, () => clock);
  const answer = await apns.send({ token: "ab".repeat(32), env: "development", topic: "app.banana.Banana", payload: { aps: { "content-available": 1 } }, collapseId: "calendar" });
  assert.deepEqual(answer, { ok: true, status: 200, reason: null });

  const call = fetch.calls[0];
  assert.equal(call.url, `https://api.sandbox.push.apple.com/3/device/${"ab".repeat(32)}`);
  assert.equal(call.headers["apns-topic"], "app.banana.Banana");
  assert.equal(call.headers["apns-push-type"], "background");
  assert.equal(call.headers["apns-priority"], "5");
  assert.equal(call.headers["apns-collapse-id"], "calendar");
  const jwt = call.headers.authorization.replace(/^bearer /, "");
  const [header, claims, signature] = jwt.split(".");
  assert.deepEqual(JSON.parse(new TextDecoder().decode(fromBase64(header))), { alg: "ES256", kid: "KEY123ABCD" });
  assert.deepEqual(JSON.parse(new TextDecoder().decode(fromBase64(claims))), { iss: "TEAM123456", iat: NOW / 1000 });
  assert.equal(fromBase64(signature).length, 64); // r||s, not DER
  assert.ok(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, publicKey, fromBase64(signature), new TextEncoder().encode(`${header}.${claims}`)));

  // Reused for 50 minutes, then a new one; production goes to the production host.
  clock += 49 * 60 * 1000;
  await apns.send({ token: "cd".repeat(32), env: "production", topic: "t.t", payload: {} });
  assert.equal(fetch.calls[1].headers.authorization, call.headers.authorization);
  assert.equal(fetch.calls[1].url, `https://api.push.apple.com/3/device/${"cd".repeat(32)}`);
  clock += 2 * 60 * 1000;
  await apns.send({ token: "cd".repeat(32), env: "production", topic: "t.t", payload: {} });
  assert.notEqual(fetch.calls[2].headers.authorization, call.headers.authorization);
});

test("apns: a refusal comes back with Apple's reason", async () => {
  const { pem } = await p8();
  const apns = createApns({ apnsKey: pem.replace(/\n/g, "\\n"), apnsKeyId: "K", apnsTeamId: "T" }, fakeFetch({ status: 410, body: { reason: "Unregistered" } }), () => NOW);
  assert.deepEqual(await apns.send({ token: "ab", env: "production", topic: "t", payload: {} }), { ok: false, status: 410, reason: "Unregistered" });
});

test("crypto: sealed values differ each time and open only with the right sub and key", async () => {
  const key = base64url(random(32));
  const vault = createVault(key, random);
  const a = await vault.seal("sub-1", "token");
  const b = await vault.seal("sub-1", "token");
  assert.notEqual(a, b);
  assert.equal(await vault.open("sub-1", a), "token");
  await assert.rejects(vault.open("sub-2", a));
  await assert.rejects(createVault(base64url(random(32)), random).open("sub-1", a));
  await assert.rejects(createVault("short", random).seal("s", "t"));
  assert.ok(constantTimeEqual("abc", "abc"));
  assert.ok(!constantTimeEqual("abc", "abd"));
  assert.ok(!constantTimeEqual("abc", "abcd"));
  assert.ok(!constantTimeEqual("", "a"));
});

test("sqlite: migrations apply once, and a database exported from D1 isn't migrated twice", () => {
  const dir = mkdtempSync(join(tmpdir(), "banana-service-"));
  try {
    const path = join(dir, "a.db");
    sqlite(path).close();
    const again = sqlite(path);
    assert.deepEqual(again.raw.prepare("SELECT name FROM migrations_applied").all().map((r) => r.name), ["0001_init.sql", "0002_link_lifecycle.sql", "0003_device_channels.sql", "0004_push_record.sql", "0005_event_alerts.sql", "0006_alert_devices.sql", "0007_plan_ahead.sql", "0008_diagnostics.sql", "0009_spaces.sql", "0010_booking.sql", "0011_web_sharing.sql", "0012_series_invites.sql", "0013_booking_hardening.sql"]);
    again.close();

    // As `wrangler d1 export` leaves it: the tables and wrangler's own record of the migration.
    const exported = join(dir, "d1.db");
    const raw = new DatabaseSync(exported);
    raw.exec("CREATE TABLE d1_migrations (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE, applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL)");
    raw.exec("INSERT INTO d1_migrations (name) VALUES ('0001_init.sql')");
    raw.exec("CREATE TABLE accounts (id TEXT PRIMARY KEY, created_at BIGINT NOT NULL, last_push_at BIGINT)");
    raw.exec("CREATE TABLE google_links (sub TEXT PRIMARY KEY, account_id TEXT NOT NULL, email TEXT NOT NULL, refresh_token TEXT, scopes TEXT NOT NULL, status TEXT NOT NULL, created_at BIGINT NOT NULL, updated_at BIGINT NOT NULL)");
    raw.exec("CREATE TABLE devices (id TEXT PRIMARY KEY, account_id TEXT NOT NULL, platform TEXT NOT NULL, push_token TEXT, push_env TEXT NOT NULL, bundle TEXT NOT NULL, updated_at BIGINT NOT NULL)");
    raw.exec("CREATE TABLE sessions (token_hash TEXT PRIMARY KEY, account_id TEXT NOT NULL, created_at BIGINT NOT NULL, last_used_at BIGINT NOT NULL)");
    raw.exec("CREATE TABLE watches (channel_id TEXT PRIMARY KEY, account_id TEXT NOT NULL, google_sub TEXT NOT NULL, calendar_id TEXT NOT NULL, resource_id TEXT, secret TEXT NOT NULL, expires_at BIGINT, status TEXT NOT NULL, failures INTEGER NOT NULL DEFAULT 0, retry_at BIGINT, created_at BIGINT NOT NULL)");
    raw.close();
    const moved = sqlite(exported);
    // 0001 came with the export; 0002 to 0004 are applied here.
    assert.deepEqual(moved.raw.prepare("SELECT name FROM migrations_applied").all().map((r) => r.name), ["0001_init.sql", "0002_link_lifecycle.sql", "0003_device_channels.sql", "0004_push_record.sql", "0005_event_alerts.sql", "0006_alert_devices.sql", "0007_plan_ahead.sql", "0008_diagnostics.sql", "0009_spaces.sql", "0010_booking.sql", "0011_web_sharing.sql", "0012_series_invites.sql", "0013_booking_hardening.sql"]);
    moved.close();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("sqlite: a batch is all or nothing", async () => {
  const db = sqlite(":memory:");
  await assert.rejects(db.batch([
    { sql: "INSERT INTO accounts (id, created_at) VALUES (?, ?)", params: ["a", 1] },
    { sql: "INSERT INTO accounts (id, created_at) VALUES (?, ?)", params: ["a", 2] },
  ]));
  assert.equal((await db.first("SELECT COUNT(*) AS n FROM accounts")).n, 0);
});

test("google: an identity token is accepted only with Google's signature, our client, in date, verified", async () => {
  const { createGoogle, GoogleRefused } = await import("../src/google.js");
  const { base64url } = await import("../src/crypto.js");
  const pair = await crypto.subtle.generateKey({ name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" }, true, ["sign", "verify"]);
  const jwk = { ...(await crypto.subtle.exportKey("jwk", pair.publicKey)), kid: "k1", alg: "RS256", use: "sig" };
  let certFetches = 0;
  const fetcher = async (url) => {
    assert.equal(url, "https://www.googleapis.com/oauth2/v3/certs");
    certFetches++;
    return new Response(JSON.stringify({ keys: [jwk] }), { headers: { "cache-control": "public, max-age=3600" } });
  };
  const t0 = Date.UTC(2026, 9, 18);
  const google = createGoogle({ googleAppClientIds: ["app-client.apps.googleusercontent.com"] }, fetcher, () => t0);
  const enc = (o) => base64url(new TextEncoder().encode(JSON.stringify(o)));
  async function token(claims, { kid = "k1", key = pair.privateKey } = {}) {
    const head = enc({ alg: "RS256", kid, typ: "JWT" }), body = enc(claims);
    const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(`${head}.${body}`));
    return `${head}.${body}.${base64url(new Uint8Array(sig))}`;
  }
  const good = { iss: "https://accounts.google.com", aud: "app-client.apps.googleusercontent.com", sub: "123", email: "Ann@Example.com", email_verified: true, exp: t0 / 1000 + 600 };
  assert.deepEqual(await google.verifyIdToken(await token(good)), { sub: "123", email: "ann@example.com", name: null });
  await google.verifyIdToken(await token(good));
  assert.equal(certFetches, 1, "keys are kept while Google allows");
  const other = await crypto.subtle.generateKey({ name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" }, true, ["sign"]);
  for (const bad of [
    await token(good, { key: other.privateKey }),
    await token({ ...good, aud: "someone-else" }),
    await token({ ...good, iss: "https://evil.example" }),
    await token({ ...good, exp: t0 / 1000 - 1 }),
    await token({ ...good, email_verified: false }),
    "not.a.token",
  ]) {
    await assert.rejects(google.verifyIdToken(bad), GoogleRefused);
  }
});

test("google (booking): calendar list, events made, read, moved and deleted, free/busy, the booking sign-in's redirect", async () => {
  const seen = [];
  const fetch = fakeFetch((url, init) => {
    seen.push({ url, method: init.method ?? "GET", body: init.body });
    if (url.includes("/calendarList")) return url.includes("pageToken=p2") ? { body: { items: [{ id: "b" }] } } : { body: { items: [{ id: "a", timeZone: "Europe/Paris" }], nextPageToken: "p2" } };
    if (url.includes("/freeBusy")) return { body: { calendars: { primary: { busy: [{ start: "2026-10-20T10:00:00Z", end: "2026-10-20T11:00:00Z" }] } } } };
    if (url.includes("/events/gone")) return { status: 404, body: {} };
    if (init.method === "POST" && url.includes("/events?")) return { status: 409, body: {} };
    if (init.method === "DELETE") return { status: 410, body: {} };
    if (url.includes("oauth2.googleapis.com/token")) return { body: { access_token: "at", id_token: idToken({ ...good, name: "Ann Lee" }), scope: "openid" } };
    return { body: { id: "e1" } };
  });
  const google = createGoogle(config, fetch, () => NOW);
  assert.deepEqual(await google.calendarList("at"), [{ id: "a", timeZone: "Europe/Paris" }, { id: "b" }]);
  assert.match(seen[0].url, /fields=items/);
  assert.equal(await google.getEvent("at", "cal@x", "gone"), null);
  assert.deepEqual(await google.getEvent("at", "cal@x", "e1"), { id: "e1" });
  await assert.rejects(google.insertEvent("at", "cal@x", { id: "e1" }, { sendUpdates: "all" }), (e) => e instanceof GoogleError && e.status === 409);
  const insert = seen.find((c) => c.method === "POST" && c.url.includes("/events?"));
  assert.match(insert.url, /calendars\/cal%40x\/events\?conferenceDataVersion=1&sendUpdates=all/);
  assert.deepEqual(await google.patchEvent("at", "cal@x", "e1", { attendees: [] }, { sendUpdates: "all" }), { id: "e1" });
  assert.equal(seen.at(-1).method, "PATCH");
  await google.deleteEvent("at", "cal@x", "e1", { sendUpdates: "none" });   // 410 counts as deleted
  assert.deepEqual(await google.freeBusy("at", { timeMin: "a", timeMax: "b" }), [{ start: "2026-10-20T10:00:00Z", end: "2026-10-20T11:00:00Z" }]);
  assert.deepEqual(JSON.parse(seen.at(-1).body), { timeMin: "a", timeMax: "b", items: [{ id: "primary" }] });
  const who = await google.exchangeCode("c", { redirectUri: "https://book.example/b/connect/callback" });
  assert.equal(who.name, "Ann Lee");
  assert.equal(new URLSearchParams(fetch.calls.at(-1).body).get("redirect_uri"), "https://book.example/b/connect/callback");
});
