// The Banana service's HTTP API (docs/design/ACCOUNTS.md). No platform code: everything outside
// comes in through `deps`, so the same app runs on Workers (src/worker.js) and Node (src/node.js).
//
// Never logged: tokens, codes, emails, calendar ids, push tokens.

import { Hono } from "hono";
import { rows as usageRows } from "./usage.js";
import { MOST_PER_DAY, reportRows } from "./diagnostics.js";
import { GoogleRefused } from "./google.js";
import { constantTimeEqual, createVault, newId, newSecret, newSessionToken, sha256Hex, uuid } from "./crypto.js";
import { audit, forget, forgetUnwatched, reconcile, WATCH_TTL_SECONDS } from "./calendar.js";
import { clearAlert, syncCalendar } from "./events.js";
import { syncRoutes, syncSummary, wipeSpaces } from "./sync-routes.js";
import { bookingApp } from "./booking/routes.js";
import { bookingApi, forgetHost } from "./booking/api.js";
import { bookingContext, reconcile as reconcileBookings } from "./booking/jobs.js";
import { rebuildSnapshot, refreshTypes } from "./booking/busy.js";
import { createSigner } from "./booking/sign.js";
import { memoryEmail } from "./booking/email.js";
import { createTurnstile, memoryLimits } from "./booking/guard.js";
import { webRoutes } from "./web/routes.js";
import { sourceRoutes } from "./source-offer.js";

/**
 * @typedef {{
 *   all(sql: string, ...params: any[]): Promise<any[]>,
 *   first(sql: string, ...params: any[]): Promise<any|null>,
 *   run(sql: string, ...params: any[]): Promise<{changes: number}>,
 *   batch(list: {sql: string, params?: any[]}[]): Promise<{changes: number}[]>,
 * }} Db
 * @typedef {{
 *   db: Db,
 *   google: ReturnType<typeof import("./google.js").createGoogle>,
 *   apns: ReturnType<typeof import("./apns.js").createApns>,
 *   config: ReturnType<typeof import("./config.js").configFrom>,
 *   defer: (work: Promise<any>) => void,
 *   now: () => number,
 *   random: (n: number) => Uint8Array,
 *   spaces: {get(id: string): {sync: Function, recordBlob: Function, setConsent: Function,
 *            withdrawConsent: Function, counts: Function, wipe: Function, export: () => Promise<Response>}},
 *   blobs: {put: Function, get: Function, head: Function, move: Function, delete: Function, list: Function},
 *   changes?: {send(records: object[]): Promise<void>} | null,
 *   sleep?: (ms: number) => Promise<void>,
 *   replica?: Db,                   // a read replica session (D1 Sessions API), for the booking pages' reads
 *   email?: {send(message: object): Promise<{id: string|null}>},
 *   limit?: (name: string, key: string) => Promise<boolean>,
 *   turnstile?: {enabled: boolean, verify(token: string, ip: string): Promise<boolean>},
 *   pageCache?: {get: Function, put: Function, delete: Function} | null,
 * }} Deps
 *
 * spaces: one database per space (src/space-do.js on Workers, src/adapters/spaces-sqlite.js on
 * Node); blobs: R2 (src/adapters/r2.js) or a directory (src/adapters/blobs-fs.js); changes: the
 * optional Pipeline the change stream goes to (DATA-PLATFORM.md §9).
 */

const DAY = 24 * 60 * 60 * 1000;
const PUSH_GAP = 3000;
const MOST_DEVICES = 25;              // device rows per account
const MOST_DEVICE_WATCHES = 100;      // channels a person's devices may hold open at once
const MOST_DIAGNOSTIC_BYTES = 128 * 1024 * 1024;   // kept per day across everyone
const MOST_COUNT_ROWS_PER_DAY = 20_000;            // distinct usage rows a day across everyone
const CALENDAR_PUSH = { aps: { "content-available": 1 }, b: { k: "calendar" } };
const TOO_LARGE = Symbol("too large");
const BAD = Symbol("bad");

/** The device an app sends, or null when it isn't one. */
export function parseDevice(input, id = input?.id) {
  if (!input || typeof input !== "object") return null;
  const push = input.push ?? null;
  if (typeof id !== "string" || !/^[A-Za-z0-9-]{8,64}$/.test(id)) return null;
  if (!["iphone", "ipad", "mac"].includes(input.platform)) return null;
  if (push !== null && (typeof push !== "string" || !/^[0-9A-Fa-f]{16,200}$/.test(push))) return null;
  if (!["development", "production"].includes(input.pushEnv)) return null;
  if (typeof input.bundle !== "string" || !/^[A-Za-z0-9.-]{3,100}$/.test(input.bundle)) return null;
  return { id, platform: input.platform, push: push && push.toLowerCase(), pushEnv: input.pushEnv, bundle: input.bundle };
}

/** A push to every device of the account (but `except`), recording what APNs said of each
 * (`devices.pushed_at`, `push_status`): the evidence that a push went out, and where. Silent unless
 * `pushType` is "alert" (a booking's news to its host). */
export async function pushTo(deps, account, { payload, collapseId, except = null, label = "push", pushType, priority }) {
  const { db, now } = deps;
  const devices = await db.all(
    "SELECT id, platform, push_token, push_env, bundle FROM devices WHERE account_id = ? AND push_token IS NOT NULL AND id <> ?", account, except ?? "");
  const outcomes = await Promise.all(devices.map(async (d) => {
    let status;
    try {
      const answer = await deps.apns.send({ token: d.push_token, env: d.push_env, topic: d.bundle, payload, collapseId,
        ...(pushType ? { pushType } : {}), ...(priority ? { priority } : {}) });
      status = `${answer.status}${answer.reason ? ` ${answer.reason}` : ""}`;
      const gone = answer.status === 410
        || (answer.status === 400 && (answer.reason === "BadDeviceToken" || answer.reason === "DeviceTokenNotForTopic"));
      if (gone) await db.run("UPDATE devices SET push_token = NULL WHERE id = ? AND push_token = ?", d.id, d.push_token);
    } catch (error) {
      status = `failed ${error.name}`;
    }
    await db.run("UPDATE devices SET pushed_at = ?, push_status = ? WHERE id = ?", now(), status, d.id);
    return `${d.platform ?? ""}${d.push_env === "development" ? "(dev)" : ""} ${status}`.trim();
  }));
  console.log(`${label}: ${devices.length} device(s): ${outcomes.join(", ") || "none"}`);
}

/** @param {Deps} deps */
export function createApp(deps) {
  const { db, now, random, defer } = deps;
  const vault = createVault(deps.config.tokenKey, random);
  deps.email ??= memoryEmail();
  deps.limit ??= memoryLimits(now);
  deps.turnstile ??= createTurnstile(deps.config.turnstileSecret, fetch, { required: deps.config.turnstileRequired !== false });
  const app = new Hono();
  sourceRoutes(app, deps.config);

  // The booking pages answer on the booking host only (book.bananatheapp.com, beta-book.…), and the
  // API never does there. SERVE_AS=book makes every request a booking one (local runs).
  const signer = createSigner(deps.config.tokenKey);
  const pushAny = (account, options) => pushTo(deps, account, options);
  const booking = deps.config.bookUrl ? bookingApp(deps, { vault, signer, push: pushAny }) : null;
  let bookHost = null;
  try { bookHost = deps.config.bookUrl ? new URL(deps.config.bookUrl).host.toLowerCase() : null; } catch { bookHost = null; }
  const onBookHost = (c) => {
    if (!booking) return false;
    if (deps.config.serveAs === "book") return true;
    const host = (c.req.header("host") ?? new URL(c.req.url).host).toLowerCase();
    return host === bookHost;
  };
  app.use("*", async (c, next) => {
    if (!onBookHost(c)) return next();
    let executionCtx;
    try { executionCtx = c.executionCtx; } catch { executionCtx = undefined; }
    return booking.fetch(c.req.raw, c.env, executionCtx);
  });
  const bookingWork = bookingContext(deps, { push: pushAny, signer });
  /** A watch said a calendar changed: the account's busy snapshot, again, after the answer. */
  const rebuildBusy = (account) => defer((async () => {
    if (!(await db.first("SELECT 1 AS x FROM booking_handles WHERE account_id = ?", account))) return;
    const written = await rebuildSnapshot(deps, account, { vault });
    if (written) await reconcileBookings(bookingWork, account, written.horizon);
  })().catch((error) => console.log(`booking: snapshot failed (${error.name})`)));

  // ---- helpers ----

  /** The client's address for the anonymous routes' limits: Cloudflare's header, or the socket on Node. */
  const clientIp = (c) => deps.clientIp?.(c) ?? c.req.header("cf-connecting-ip") ?? "local";

  async function readJson(c, limit) {
    if (Number(c.req.header("content-length") || 0) > limit) return TOO_LARGE;
    const text = await c.req.text();
    if (text.length > limit) return TOO_LARGE;
    try { return JSON.parse(text); } catch { return BAD; }
  }

  /** The account of the bearer session, or null. */
  async function sessionAccount(c) {
    const match = /^Bearer ([A-Za-z0-9_-]{20,200})$/.exec(c.req.header("authorization") ?? "");
    if (!match) return null;
    const hash = await sha256Hex(match[1]);
    // Person sessions only: a guest's (the booking pages' cookie) never reaches the API.
    const row = await db.first("SELECT account_id, last_used_at FROM sessions WHERE token_hash = ? AND kind = 'person'", hash);
    if (!row) return null;
    const t = now();
    if (t - Number(row.last_used_at) >= DAY) await db.run("UPDATE sessions SET last_used_at = ? WHERE token_hash = ?", t, hash);
    return row.account_id;
  }

  const signedIn = async (c, next) => {
    const account = await sessionAccount(c);
    if (!account) return c.json({ error: "signed_out" }, 401);
    c.set("account", account);
    await next();
  };

  webRoutes(app, deps, { signer, onCalendarSettingsChanged: (account) => {
    rebuildBusy(account);
    defer(pushTo(deps, account, { payload: { aps: { "content-available": 1 }, b: { k: "sync" } },
      collapseId: "sync", label: "push(calendar settings)" }));
  } });

  const deviceOwner = async (id) => (await db.first("SELECT account_id FROM devices WHERE id = ?", id))?.account_id ?? null;
  /** An account holds at most MOST_DEVICES rows (a person's own devices are a handful). */
  const roomForDevice = async (account) => Number((await db.first("SELECT COUNT(*) AS n FROM devices WHERE account_id = ?", account)).n) < MOST_DEVICES;

  function deviceStatements(device, account) {
    const t = now();
    const out = [{
      sql: `INSERT INTO devices (id, account_id, platform, push_token, push_env, bundle, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (id) DO UPDATE SET account_id = excluded.account_id, platform = excluded.platform,
              push_token = excluded.push_token, push_env = excluded.push_env, bundle = excluded.bundle, updated_at = excluded.updated_at,
              seeded_types = CASE WHEN devices.account_id = excluded.account_id THEN devices.seeded_types END,
              seeded_at = CASE WHEN devices.account_id = excluded.account_id THEN devices.seeded_at END,
              flipped_at = CASE WHEN devices.account_id = excluded.account_id THEN devices.flipped_at END`,
      params: [device.id, account, device.platform, device.push, device.pushEnv, device.bundle, t],
    }];
    // A push token reaches one device: an older row holding it (a reinstall) lets go of it.
    if (device.push) out.push({ sql: "UPDATE devices SET push_token = NULL WHERE push_token = ? AND id <> ?", params: [device.push, device.id] });
    return out;
  }

  async function summary(account) {
    const links = await db.all(
      `SELECT g.email, g.status, g.refresh_token IS NOT NULL AS has_token,
              (SELECT COUNT(*) FROM watches w WHERE w.google_sub = g.sub AND w.status = 'live' AND w.expires_at > ?) AS watching
       FROM google_links g WHERE g.account_id = ? AND g.status <> 'unlinked' ORDER BY g.created_at, g.email`, now(), account);
    const devices = await db.first("SELECT COUNT(*) AS n FROM devices WHERE account_id = ?", account);
    return {
      id: account,
      // access: the service holds working Google access of its own for this link (a sealed
      // refresh token from a code sign-in, not refused). Without it the app asks the person to
      // sign in again, so the service can read events and send alerts itself.
      google: links.map((l) => ({ email: l.email, status: l.status, watching: Number(l.watching), access: Boolean(l.has_token) && l.status === "ok" })),
      devices: Number(devices?.n ?? 0),
      ...(await syncSummary(deps, account)),
    };
  }

  const linkByEmail = (account, email) =>
    db.first("SELECT * FROM google_links WHERE account_id = ? AND email = ? AND status <> 'unlinked'", account, String(email).toLowerCase());

  /** Trades a one-time code, answering for the route when Google says no or can't be reached. */
  async function exchange(c, code) {
    try { return { google: await deps.google.exchangeCode(code) }; }
    catch (error) {
      if (error instanceof GoogleRefused) return { answer: c.json({ error: "google_refused" }, 401) };
      console.log(`google: code exchange failed (${error.name} ${error.status ?? ""})`);
      return { answer: c.json({ error: "google_unavailable" }, 502) };
    }
  }

  const pushDevices = (account, options) => pushTo(deps, account, options);
  /** "A calendar changed", to every device of the account. */
  const pushCalendar = (account) => pushDevices(account, { payload: CALENDAR_PUSH, collapseId: "calendar" });

  // ---- routes ----

  app.get("/v1/health", (c) => c.text("ok"));

  app.post("/v1/google", async (c) => {
    const body = await readJson(c, 16_384);
    const code = body?.code;
    const device = parseDevice(body?.device);
    if (typeof code !== "string" || !code || code.length > 2048 || !device) return c.json({ error: "bad_request" }, 400);
    // A session that no longer exists (the account was deleted elsewhere) counts as signed out.
    const current = await sessionAccount(c);

    const { google, answer } = await exchange(c, code);
    if (answer) return answer;
    return signInAs(c, google, device, current);
  });

  // A device signs in, or links another Google account, with nothing for the person to do: the
  // identity token the app gets from Google with the refresh token it already holds proves who it
  // is. It grants the service no Google access of its own; the device opens the calendar watches.
  app.post("/v1/google/identity", async (c) => {
    const body = await readJson(c, 16_384);
    const idToken = body?.idToken;
    const device = parseDevice(body?.device);
    if (typeof idToken !== "string" || !idToken || idToken.length > 8192 || !device) return c.json({ error: "bad_request" }, 400);
    const current = await sessionAccount(c);
    let who;
    try { who = await deps.google.verifyIdToken(idToken); }
    catch (error) {
      if (error instanceof GoogleRefused) return c.json({ error: "google_refused" }, 401);
      console.log(`google: identity check failed (${error.name} ${error.status ?? ""})`);
      return c.json({ error: "google_unavailable" }, 502);
    }
    return signInAs(c, { ...who, refreshToken: null, scopes: "" }, device, current);
  });

  /** Signs in as, or links, the Google account `google` ({sub, email, refreshToken|null, scopes}). */
  async function signInAs(c, google, device, current) {
    const existing = await db.first("SELECT sub, account_id, refresh_token, scopes, status FROM google_links WHERE sub = ?", google.sub);
    if (current && existing && existing.account_id !== current) return c.json({ error: "other_account" }, 409);

    const t = now();
    const account = current ?? existing?.account_id ?? newId(random);
    const statements = [];
    if (!current && !existing) statements.push({ sql: "INSERT INTO accounts (id, created_at) VALUES (?, ?)", params: [account, t] });

    // Google may leave out the refresh token when this app was already granted; then the one we
    // hold stays. A sign-in by identity token brings none: the link is "ok" (the person is who they
    // say), with whatever permission the service already had, if any.
    const sealed = google.refreshToken ? await vault.seal(google.sub, google.refreshToken) : existing?.refresh_token ?? null;
    const byIdentity = !google.refreshToken && !google.scopes;
    // 'refused' means Google rejected the token the service held (invalid_grant); it ends only
    // with a new token. Anything else is 'ok': the person is who they say, and `access` in the
    // summary says whether the service holds a token of its own.
    const status = google.refreshToken ? "ok" : existing?.status === "refused" ? "refused" : "ok";
    const scopes = byIdentity ? existing?.scopes ?? "" : google.scopes;
    if (!byIdentity && !google.refreshToken) console.log(`google: code exchange brought no refresh token (${existing?.refresh_token ? "keeping the one held" : "none held"})`);
    statements.push({
      sql: `INSERT INTO google_links (sub, account_id, email, refresh_token, scopes, status, created_at, updated_at, name) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (sub) DO UPDATE SET email = excluded.email, refresh_token = excluded.refresh_token,
              scopes = excluded.scopes, status = excluded.status, updated_at = excluded.updated_at, name = COALESCE(excluded.name, google_links.name)`,
      params: [google.sub, account, google.email.toLowerCase(), sealed, scopes, status, t, t, typeof google.name === "string" ? google.name.slice(0, 120) : null],
    });
    // Connected again: calendars waiting for a retry are tried at the next job run.
    if (existing) statements.push({ sql: "UPDATE watches SET retry_at = NULL, failures = 0 WHERE google_sub = ?", params: [google.sub] });
    // The device: a row another account holds moves to this one (the same device, signed in as
    // someone else), on the record; a new row only while the account has room.
    const owner = await deviceOwner(device.id);
    if (owner && owner !== account) statements.push(audit(deps, account, "device_moved"));
    if (!owner && !(await roomForDevice(account))) return c.json({ error: "too_many_devices" }, 409);
    statements.push(...deviceStatements(device, account));
    let session;
    if (!current) {
      session = newSessionToken(random);
      statements.push({ sql: "INSERT INTO sessions (token_hash, account_id, created_at, last_used_at) VALUES (?, ?, ?, ?)",
        params: [await sha256Hex(session), account, t, t] });
    }
    statements.push(audit(deps, account, "link"));
    await db.batch(statements);
    return c.json({ ...(session ? { session } : {}), account: await summary(account) });
  }

  app.get("/v1/account", signedIn, async (c) => c.json(await summary(c.get("account"))));

  // Deleting needs a fresh Google sign-in: a one-time code (single use, minutes old at most) from a
  // Google account linked to the account, in the app or on the website. A session alone, however
  // valid, never deletes. With a session as well, both must name the same account.
  app.delete("/v1/account", async (c) => {
    const body = await readJson(c, 4096);
    const code = typeof body === "object" ? body?.code : undefined;
    if (typeof code !== "string" || !code || code.length > 2048) return c.json({ error: "google_sign_in_required" }, 401);
    const { google, answer } = await exchange(c, code);
    if (answer) return answer;
    const owner = await db.first("SELECT account_id FROM google_links WHERE sub = ?", google.sub);
    if (google.refreshToken) defer(deps.google.revoke(google.refreshToken).catch(() => {}));
    if (!owner) return c.json({ error: "no_account" }, 404);
    const current = await sessionAccount(c);
    if (current && current !== owner.account_id) return c.json({ error: "other_account" }, 409);
    const account = owner.account_id;
    const links = await db.all("SELECT * FROM google_links WHERE account_id = ?", account);
    for (const link of links) await forget(deps, vault, link);
    // The data first (the space empties at once; its blobs follow to the trash), then the rows.
    const spaces = await wipeSpaces(deps, account);
    await db.batch([
      ...spaces,
      { sql: "DELETE FROM watches WHERE account_id = ?", params: [account] },
      ...links.flatMap((link) => forgetUnwatched(link.sub)),
      { sql: "DELETE FROM alerts WHERE account_id = ?", params: [account] },
      { sql: "DELETE FROM held_alerts WHERE device_id IN (SELECT id FROM devices WHERE account_id = ?)", params: [account] },
      { sql: "DELETE FROM google_links WHERE account_id = ?", params: [account] },
      { sql: "DELETE FROM sessions WHERE account_id = ?", params: [account] },
      { sql: "DELETE FROM devices WHERE account_id = ?", params: [account] },
      { sql: "DELETE FROM account_usage WHERE account_id = ?", params: [account] },
      { sql: "DELETE FROM audit WHERE account_id = ?", params: [account] },
      ...forgetHost(account),
      { sql: "DELETE FROM accounts WHERE id = ?", params: [account] },
      audit(deps, account, "delete"),
    ]);
    return c.body(null, 204);
  });

  app.put("/v1/devices/:id", signedIn, async (c) => {
    const body = await readJson(c, 4096);
    const device = parseDevice(typeof body === "object" ? body : null, c.req.param("id"));
    if (!device) return c.json({ error: "bad_request" }, 400);
    // A session names its own devices only: another account's row is not taken over here (a device
    // changes hands only through a sign-in, which proves a Google identity and is audited).
    const owner = await deviceOwner(device.id);
    if (owner && owner !== c.get("account")) return c.json({ error: "other_account" }, 409);
    if (!owner && !(await roomForDevice(c.get("account")))) return c.json({ error: "too_many_devices" }, 409);
    await db.batch(deviceStatements(device, c.get("account")));
    return c.body(null, 204);
  });

  app.delete("/v1/devices/:id", signedIn, async (c) => {
    await db.run("DELETE FROM devices WHERE id = ? AND account_id = ?", c.req.param("id"), c.get("account"));
    return c.body(null, 204);
  });

  app.put("/v1/google/calendars", signedIn, async (c) => {
    const body = await readJson(c, 65_536);
    const ids = body?.ids;
    if (typeof body?.email !== "string" || !Array.isArray(ids) || ids.length > 100
        || !ids.every((id) => typeof id === "string" && id.length > 0 && id.length <= 300)) {
      return c.json({ error: "bad_request" }, 400);
    }
    const link = await linkByEmail(c.get("account"), body.email);
    if (!link) return c.json({ error: "unknown_google" }, 404);
    const unique = [...new Set(ids)];
    // Each change can mean a hundred calls at Google: so many a minute per Google account.
    if (!(await deps.limit("reconcile", link.sub))) return c.json({ error: "rate" }, 429);
    defer(reconcile(deps, vault, link, unique).catch((error) => console.log(`calendars: reconcile failed (${error.name})`)));
    return c.json({ watching: unique.length }, 202);
  });

  app.delete("/v1/google", signedIn, async (c) => {
    const body = await readJson(c, 4096);
    if (typeof body?.email !== "string") return c.json({ error: "bad_request" }, 400);
    const account = c.get("account");
    const link = await linkByEmail(account, body.email);
    if (!link) return c.body(null, 204); // already gone
    await forget(deps, vault, link);
    // The sub and email stay (status 'unlinked'), so this Google account can sign in to the same
    // account again, and delete it.
    await db.batch([
      { sql: "DELETE FROM watches WHERE google_sub = ?", params: [link.sub] },
      ...forgetUnwatched(link.sub),
      { sql: "UPDATE google_links SET status = 'unlinked', refresh_token = NULL, updated_at = ? WHERE sub = ?", params: [now(), link.sub] },
      // A booking guest who proved this email was linked to the person through it: no longer.
      { sql: "UPDATE guests SET person_account_id = NULL WHERE person_account_id = ? AND email = ?", params: [account, link.email] },
      audit(deps, account, "unlink"),
    ]);
    return c.body(null, 204);
  });

  // ---- calendar watches the devices open themselves ----
  // The device asks for a channel (id, secret, address), opens it at Google with its own access,
  // then reports Google's answer. It renews a channel before it ends and closes the ones it no
  // longer wants. The service only checks notices against the secret and pushes.

  app.get("/v1/google/channels", signedIn, async (c) => {
    const rows = await db.all(
      `SELECT w.channel_id, g.email, w.calendar_id, w.resource_id, w.status, w.expires_at FROM watches w
       JOIN google_links g ON g.sub = w.google_sub WHERE w.account_id = ? AND w.managed_by = 'device' ORDER BY w.created_at`,
      c.get("account"));
    return c.json({ channels: rows.map((r) => ({ id: r.channel_id, email: r.email, calendarId: r.calendar_id,
      resourceId: r.resource_id, status: r.status, expiresAt: r.expires_at == null ? null : Number(r.expires_at) })) });
  });

  app.post("/v1/google/channels", signedIn, async (c) => {
    const body = await readJson(c, 4096);
    const calendarId = body?.calendarId;
    if (typeof body?.email !== "string" || typeof calendarId !== "string" || !calendarId || calendarId.length > 300) {
      return c.json({ error: "bad_request" }, 400);
    }
    const link = await linkByEmail(c.get("account"), body.email);
    if (!link) return c.json({ error: "unknown_google" }, 404);
    const open = await db.first("SELECT COUNT(*) AS n FROM watches WHERE account_id = ? AND managed_by = 'device'", c.get("account"));
    if (Number(open.n) >= MOST_DEVICE_WATCHES) return c.json({ error: "too_many_channels" }, 409);
    const id = uuid(random), secret = newSecret(random);
    await db.run(
      `INSERT INTO watches (channel_id, account_id, google_sub, calendar_id, resource_id, secret, expires_at, status, failures, retry_at, created_at, managed_by)
       VALUES (?, ?, ?, ?, NULL, ?, NULL, 'pending', 0, NULL, ?, 'device')`,
      id, c.get("account"), link.sub, calendarId, secret, now());
    return c.json({ id, token: secret, address: `${deps.config.publicUrl}/v1/google/notify`, ttlSeconds: WATCH_TTL_SECONDS }, 201);
  });

  app.put("/v1/google/channels/:id", signedIn, async (c) => {
    const body = await readJson(c, 4096);
    const expiration = Number(body?.expiration);
    // Google's channels live a week at most: a later date is not Google's answer.
    if (typeof body?.resourceId !== "string" || !body.resourceId || !(expiration > now()) || expiration > now() + (WATCH_TTL_SECONDS + 3600) * 1000) {
      return c.json({ error: "bad_request" }, 400);
    }
    const changed = await db.run(
      "UPDATE watches SET resource_id = ?, expires_at = ?, status = 'live' WHERE channel_id = ? AND account_id = ? AND managed_by = 'device'",
      body.resourceId, expiration, c.req.param("id"), c.get("account"));
    return changed.changes ? c.body(null, 204) : c.json({ error: "not_found" }, 404);
  });

  app.delete("/v1/google/channels/:id", signedIn, async (c) => {
    const row = await db.first("SELECT google_sub FROM watches WHERE channel_id = ? AND account_id = ? AND managed_by = 'device'",
      c.req.param("id"), c.get("account"));
    if (!row) return c.body(null, 204);
    await db.batch([{ sql: "DELETE FROM watches WHERE channel_id = ?", params: [c.req.param("id")] }, ...forgetUnwatched(row.google_sub)]);
    return c.body(null, 204);
  });

  // Google's change notice. Always 200, and fast: anything else makes Google retry.
  app.post("/v1/google/notify", async (c) => {
    const channel = c.req.header("x-goog-channel-id");
    const token = c.req.header("x-goog-channel-token") ?? "";
    const state = c.req.header("x-goog-resource-state");
    if (!channel) return c.body(null, 200);
    const watch = await db.first(
      "SELECT w.account_id, w.secret, w.google_sub, w.calendar_id FROM watches w WHERE w.channel_id = ? AND w.status = 'live'", channel);
    if (!watch || !constantTimeEqual(token, watch.secret)) return c.body(null, 200);
    if (state === "sync") return c.body(null, 200);
    const t = now();
    // At most one push per account every 3 s: the row update decides, so two notices racing push once.
    const claimed = await db.run("UPDATE accounts SET last_push_at = ? WHERE id = ? AND (last_push_at IS NULL OR last_push_at <= ?)",
      t, watch.account_id, t - PUSH_GAP);
    if (claimed.changes) defer(pushCalendar(watch.account_id).catch((error) => console.log(`push: failed (${error.name})`)));
    // The reads a notice starts are bounded per channel (a device holds its channel's secret and
    // could replay). Past the bound the calendar is marked, and the dispatcher reads it next minute.
    if (!(await deps.limit("notify", channel))) {
      await db.run("UPDATE watches SET dirty_at = COALESCE(dirty_at, ?) WHERE channel_id = ?", t, channel);
      return c.body(null, 200);
    }
    rebuildBusy(watch.account_id);
    // And the alerts (docs/design/EVENT-ALERTS.md): read what changed on that calendar, with the
    // link's own access, and ring what should ring. Nothing without access.
    if (deps.config.eventAlerts) defer((async () => {
      const link = await db.first("SELECT sub, account_id, email, refresh_token, status FROM google_links WHERE sub = ?", watch.google_sub);
      if (!link?.refresh_token || link.status !== "ok") return;
      const r = await syncCalendar(deps, vault, link, watch.calendar_id);
      console.log(`alerts: read ${r.read} event(s)${r.full ? " (full)" : ""}, ${r.alerts} alert(s), sent ${r.sent}${r.skipped ? `, skipped: ${r.skipped}` : ""}`);
    })().catch((error) => console.log(`alerts: failed (${error.name} ${error.status ?? ""})`)));
    return c.body(null, 200);
  });

  // ---- event alerts (docs/design/EVENT-ALERTS.md) ----

  // The lead times and time zone the person's devices use: the service words its alerts the same.
  app.put("/v1/account/alerts", signedIn, async (c) => {
    const body = await readJson(c, 4096);
    const leads = body?.leads;
    const timeZone = body?.timeZone;
    if (!Array.isArray(leads) || leads.length > 10 || !leads.every((l) => Number.isInteger(l) && l >= 0 && l <= 24 * 60)
        || (timeZone != null && (typeof timeZone !== "string" || timeZone.length > 64))) {
      return c.json({ error: "bad_request" }, 400);
    }
    await db.run("UPDATE accounts SET alert_leads = ?, time_zone = COALESCE(?, time_zone) WHERE id = ?",
      JSON.stringify([...new Set(leads)]), timeZone ?? null, c.get("account"));
    return c.body(null, 204);
  });

  // Which alerts this device holds itself (its local notifications): the service won't push those to it.
  app.put("/v1/alerts/held", signedIn, async (c) => {
    const body = await readJson(c, 65_536);
    const ids = body?.ids;
    const deviceId = body?.device;
    if (typeof deviceId !== "string" || !Array.isArray(ids) || ids.length > 500
        || !ids.every((id) => typeof id === "string" && id.length > 0 && id.length <= 600)) {
      return c.json({ error: "bad_request" }, 400);
    }
    // What it rings for (build 61 on): the calendars it alerts for and the events it skips.
    const list = (v, most) => v === undefined ? undefined
      : Array.isArray(v) && v.length <= most && v.every((s) => typeof s === "string" && s.length > 0 && s.length <= 600) ? [...new Set(v)] : null;
    const calendars = list(body?.calendars, 200);
    const quiet = list(body?.quiet, 500);
    if (calendars === null || quiet === null) return c.json({ error: "bad_request" }, 400);
    const device = await db.first("SELECT id FROM devices WHERE id = ? AND account_id = ?", deviceId, c.get("account"));
    if (!device) return c.json({ error: "unknown_device" }, 404);
    // A device that reports what it holds and what it rings for takes the service's alerts from
    // now on; one that hasn't (a build from before) gets none, so its own alerts never come twice
    // and nothing rings for a calendar it leaves out.
    const statements = [{ sql: "UPDATE devices SET alerts_at = ?, alert_calendars = ?, quiet_events = ? WHERE id = ?",
                          params: [now(), calendars ? JSON.stringify(calendars) : null, JSON.stringify(quiet ?? []), deviceId] },
                        { sql: "DELETE FROM held_alerts WHERE device_id = ?", params: [deviceId] }];
    for (const id of new Set(ids)) statements.push({ sql: "INSERT INTO held_alerts (device_id, alert_id) VALUES (?, ?)", params: [deviceId, id] });
    await db.batch(statements);
    return c.body(null, 204);
  });

  // An alert dismissed or opened on one device: cleared everywhere.
  app.post("/v1/alerts/clear", signedIn, async (c) => {
    const body = await readJson(c, 4096);
    if (typeof body?.id !== "string" || !body.id || body.id.length > 600) return c.json({ error: "bad_request" }, 400);
    const r = await clearAlert(deps, c.get("account"), body.id, typeof body.device === "string" ? body.device : null);
    return c.json(r);
  });

  // The usage batch (docs/design/TELEMETRY.md): anonymous totals always, and per account when signed in.
  app.post("/v1/usage", async (c) => {
    if (!(await deps.limit("api", clientIp(c)))) return c.body(null, 429);
    const body = await readJson(c, 16_384);
    if (body === TOO_LARGE) return c.body(null, 413);
    const add = body === BAD ? null : usageRows(body);
    if (add === null) return c.body(null, 400);
    const account = await sessionAccount(c);
    const day = new Date(now()).toISOString().slice(0, 10);
    // The table holds daily totals, a small set of rows a day; a flood of made-up versions stops here.
    const rows = await db.first("SELECT COUNT(*) AS n FROM counts WHERE day = ?", day);
    if (Number(rows.n) + add.length > MOST_COUNT_ROWS_PER_DAY) return c.body(null, 429);
    const statements = [];
    for (const r of add) {
      statements.push({
        sql: `INSERT INTO counts (day, event, name, detail, platform, channel, version, cohort, since, calendar, count)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
              ON CONFLICT (day, event, name, detail, platform, channel, version, cohort, since, calendar)
              DO UPDATE SET count = counts.count + excluded.count`,
        params: [day, r.event, r.name, r.detail, r.platform, r.channel, r.version, r.cohort, r.since, r.calendar, r.count],
      });
      if (account) statements.push({
        sql: `INSERT INTO account_usage (account_id, day, event, name, detail, platform, version, count)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?)
              ON CONFLICT (account_id, day, event, name, detail, platform, version)
              DO UPDATE SET count = account_usage.count + excluded.count`,
        params: [account, day, r.event, r.name, r.detail, r.platform, r.version, r.count],
      });
    }
    if (statements.length) await db.batch(statements);
    return c.body(null, 204);
  });

  // Crash, hang and performance reports (docs/design/DIAGNOSTICS.md): anonymous, never read
  // together with a session, so nothing ties one to an account.
  app.post("/v1/diagnostics", async (c) => {
    if (!(await deps.limit("api", clientIp(c)))) return c.body(null, 429);
    const body = await readJson(c, 262_144);
    if (body === TOO_LARGE) return c.body(null, 413);
    const add = body === BAD ? null : reportRows(body);
    if (add === null) return c.body(null, 400);
    const t = now();
    // A flood stops at a number of reports and at a number of bytes a day.
    const today = await db.first("SELECT COUNT(*) AS n, COALESCE(SUM(LENGTH(payload)), 0) AS bytes FROM diagnostics WHERE received_at >= ?", t - DAY);
    const adding = add.reduce((sum, r) => sum + r.payload.length, 0);
    if (Number(today?.n) + add.length > MOST_PER_DAY || Number(today?.bytes) + adding > MOST_DIAGNOSTIC_BYTES) return c.body(null, 429);
    if (add.length) {
      await db.batch(add.map((r) => ({
        sql: `INSERT INTO diagnostics (id, received_at, kind, signature, platform, channel, version, os, payload)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        params: [newId(random), t, r.kind, r.signature, r.platform, r.channel, r.version, r.os, r.payload],
      })));
    }
    return c.body(null, 204);
  });

  // ---- the data platform (docs/design/DATA-PLATFORM.md) ----
  syncRoutes(app, deps, { signedIn, readJson, TOO_LARGE, BAD, push: pushDevices, onAccepted: (account, types) => {
    // A booking type or the calendars left out changed in the app: the booking pages follow at once.
    if (types.has("plan.bookingType")) defer(refreshTypes(deps, account).catch((error) => console.log(`booking: types failed (${error.name})`)));
    if (types.has("core.smartSettings")) rebuildBusy(account);
  } });

  // ---- booking, the host's side (docs/design/BOOKING.md §7) ----
  bookingApi(app, deps, { signedIn, readJson, vault });

  app.notFound((c) => c.json({ error: "not_found" }, 404));
  app.onError((error, c) => {
    console.log(`error: ${error.name}: ${error.message}`);
    return c.json({ error: "server" }, 500);
  });

  return app;
}
