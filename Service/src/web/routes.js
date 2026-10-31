// The cloud app is a read-only view of the same personal space the native apps sync.
// Browser sessions are host-only HttpOnly cookies, isolated from person/guest API sessions.
import { getCookie, setCookie, deleteCookie } from "hono/cookie";
import { CATALOG } from "../catalog.js";
import { createVault, newSecret, newSessionToken, sha256Hex } from "../crypto.js";
import { GoogleRefused } from "../google.js";
import { canRead } from "../booking/busy.js";
import { personalSpace } from "../sync-routes.js";
import { page } from "./page.js";
import { calendarAgenda, calendarSettings, includesCalendar } from "./calendar.js";
import { guestAccount } from "../booking/guests.js";
import { sharingRoutes } from "./sharing.js";

const DAY = 86_400_000;
const SESSION = "__Host-banana-web";
const NONCE = "__Host-banana-web-login";
const options = { httpOnly: true, secure: true, sameSite: "Lax", path: "/" };
const TYPES = new Set(["plan.routine", "plan.alarm", "plan.wake", "plan.extra", "plan.override", "plan.bookingType", "core.wakePlan",
  "food.meal", "food.mealPhoto", "food.supplement", "food.dose", "food.myFood",
  "health.workout", "health.workoutPlan", "health.snapshot", "health.workoutCompletion",
  "podcast.show", "podcast.listen", "podcast.progress", "podcast.transcript", "notes.voiceNote"]);

export function webRoutes(app, deps, { signer, onCalendarSettingsChanged = () => {} }) {
  const origin = deps.config.publicUrl;
  const webOrigin = deps.config.webUrl || origin;
  const callback = `${origin}/v1/google/callback`;
  const home = deps.config.webUrl ? `${webOrigin}/` : `${origin}/app/`;
  const vault = createVault(deps.config.tokenKey, deps.random);
  const fail = (c, reason) => c.redirect(`${home}?error=${reason}`, 303);
  const noCache = async (c, next) => {
    c.header("Cache-Control", "no-store");
    c.header("Referrer-Policy", "no-referrer");
    c.header("X-Content-Type-Options", "nosniff");
    c.header("X-Frame-Options", "DENY");
    c.header("Content-Security-Policy", "default-src 'none'; script-src 'self'; worker-src 'self'; style-src 'self'; font-src 'self'; img-src 'self' https:; media-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'");
    await next();
  };
  app.use("/app", noCache);
  app.use("/", noCache);
  app.use("/app/*", noCache);
  app.use("/share/*", noCache);
  app.use("/v1/google/callback", noCache);

  async function session(c) {
    const token = getCookie(c, SESSION);
    if (!token || !/^[A-Za-z0-9_-]{43}$/.test(token)) return null;
    const hash = await sha256Hex(token);
    const row = await deps.db.first(
      "SELECT s.account_id, s.created_at, s.profile, a.kind FROM sessions s JOIN accounts a ON a.id = s.account_id WHERE s.token_hash = ? AND s.kind = 'web'", hash);
    if (!row || Number(row.created_at) < deps.now() - 30 * DAY) return null;
    let identity = {};
    try { identity = JSON.parse(row.profile ?? '{}'); } catch { /* old session */ }
    if (row.kind === 'guest') {
      if (typeof identity.sub !== 'string' || typeof identity.email !== 'string') return null;
      const guest = await deps.db.first('SELECT email, name FROM guests WHERE account_id = ? AND verified_at IS NOT NULL', row.account_id);
      if (!guest || guest.email !== identity.email) return null;
      deps.defer(deps.db.run('UPDATE guests SET last_seen_at = ? WHERE account_id = ?', deps.now(), row.account_id));
      return { account: row.account_id, hash, kind: 'guest', sub: identity.sub, authEmail: identity.email, ...guest };
    }
    // An account's last link may have been removed on another device.
    const who = await deps.db.first(`SELECT g.email, g.name, g.sub FROM google_links g JOIN accounts a ON a.id = g.account_id
      WHERE g.account_id = ? AND a.kind = 'person' AND g.status <> 'unlinked' ORDER BY g.created_at LIMIT 1`, row.account_id);
    if (!who) return null;
    return { account: row.account_id, hash, kind: 'person', ...who, sub: identity.sub ?? who.sub, authEmail: identity.email ?? who.email };
  }
  const webSignedIn = async (c, next) => {
    const who = await session(c);
    if (!who) return c.json({ error: "signed_out" }, 401);
    c.set("web", who);
    return next();
  };
  const signedIn = async (c, next) => webSignedIn(c, async () => {
    if (c.get('web').kind !== 'person') return c.json({ error: 'owner_required' }, 403);
    return next();
  });
  const ownSpace = (c) => deps.spaces.get(personalSpace(c.get("web").account));

  app.get("/", (c) => deps.config.webUrl && new URL(c.req.url).origin === webOrigin ? c.html(page({ homePath: "/" })) : c.notFound());
  app.get("/app", (c) => c.redirect(home, 302));
  app.get("/app/", (c) => deps.config.webUrl ? c.redirect(home, 302) : c.html(page()));
  const shareID = v => typeof v === 'string' && /^[A-Za-z0-9_-]{22}$/.test(v) ? v : null;
  const destination = id => id ? `${webOrigin}/share/${id}` : home;
  app.get('/share/:id', c => shareID(c.req.param('id')) ? c.html(page({ homePath: deps.config.webUrl ? '/' : '/app/' })) : c.notFound());
  app.get("/app/auth/google", async (c) => {
    if (!deps.config.googleClientId || !origin) return fail(c, "unavailable");
    let browser, share = shareID(c.req.query('share'));
    if (deps.config.webUrl) {
      if (new URL(c.req.url).origin === webOrigin) {
        browser = newSecret(deps.random);
        setCookie(c, NONCE, browser, { ...options, maxAge: 600 });
        const flow = await signer.seal("web-start", { n: browser, ...(share ? { share } : {}) }, deps.now() + 600_000);
        return c.redirect(`${origin}/app/auth/google?flow=${encodeURIComponent(flow)}`, 302);
      }
      const flow = await signer.unseal("web-start", c.req.query("flow"), deps.now());
      if (!flow?.n) return c.redirect(`${webOrigin}/app/auth/google`, 302);
      browser = flow.n;
      share = shareID(flow.share);
    }
    const nonce = newSecret(deps.random);
    setCookie(c, NONCE, nonce, { ...options, maxAge: 600 });
    const state = await signer.seal("web-login", { n: nonce, ...(browser ? { browser } : {}), ...(share ? { share } : {}) }, deps.now() + 600_000);
    const params = new URLSearchParams({ client_id: deps.config.googleClientId, redirect_uri: callback,
      response_type: "code", scope: "openid email profile", state, prompt: "select_account" });
    return c.redirect(`https://accounts.google.com/o/oauth2/v2/auth?${params}`, 302);
  });
  app.get("/v1/google/callback", async (c) => {
    const nonce = getCookie(c, NONCE);
    deleteCookie(c, NONCE, options);
    const state = await signer.unseal("web-login", c.req.query("state"), deps.now());
    if (!nonce || !state || state.n !== nonce) return fail(c, "expired");
    if (c.req.query("error")) return fail(c, "cancelled");
    const code = c.req.query("code");
    if (!code || code.length > 4096) return fail(c, "expired");
    let who;
    try { who = await deps.google.exchangeCode(code, { redirectUri: callback }); }
    catch (e) { return fail(c, e instanceof GoogleRefused ? "refused" : "unavailable"); }
    // Viewing an existing account never creates a fresh account or changes Google's stored grants.
    const link = await deps.db.first(`SELECT g.account_id FROM google_links g JOIN accounts a ON a.id = g.account_id
      WHERE g.sub = ? AND g.status <> 'unlinked' AND a.kind = 'person'`, who.sub);
    let accountID = link?.account_id;
    if (!accountID) {
      const invitation = await deps.db.first(`SELECT id FROM web_shares WHERE status IN ('invited', 'active') AND policy IS NOT NULL
        AND (guest_sub = ? OR (guest_sub IS NULL AND email = ?)) LIMIT 1`, who.sub, who.email);
      if (!invitation) return fail(c, "no_account");
      accountID = await guestAccount(deps, who.email, { name: who.name, verified: true });
    }
    const identity = { sub: who.sub, email: who.email, name: who.name ?? null };
    if (deps.config.webUrl) {
      // An API-host nonce stays host-only. The app redeems this single-use, 60-second handoff
      // for its own host-only session; a long-lived session never travels in a URL.
      const handoff = newSessionToken(deps.random);
      await deps.db.batch([
        { sql: "DELETE FROM sessions WHERE kind = 'web-handoff' AND created_at <= ?", params: [deps.now() - 60_000] },
        { sql: "INSERT INTO sessions (token_hash, account_id, kind, created_at, last_used_at, profile) VALUES (?, ?, 'web-handoff', ?, ?, ?)",
          params: [await sha256Hex(handoff), accountID, deps.now(), deps.now(), JSON.stringify({ n: state.browser, identity, share: shareID(state.share) })] },
      ]);
      return c.redirect(`${webOrigin}/app/auth/complete?code=${handoff}`, 303);
    }
    const previous = await session(c);
    const token = newSessionToken(deps.random);
    const hash = await sha256Hex(token);
    const statements = [{ sql: "INSERT INTO sessions (token_hash, account_id, kind, created_at, last_used_at, profile) VALUES (?, ?, 'web', ?, ?, ?)",
      params: [hash, accountID, deps.now(), deps.now(), JSON.stringify(identity)] }];
    if (previous) statements.push({ sql: "DELETE FROM sessions WHERE token_hash = ? AND kind = 'web'", params: [previous.hash] });
    await deps.db.batch(statements);
    setCookie(c, SESSION, token, { ...options, maxAge: 30 * DAY / 1000 });
    return c.redirect(destination(shareID(state.share)), 303);
  });
  app.get("/app/auth/complete", async (c) => {
    if (!deps.config.webUrl || new URL(c.req.url).origin !== webOrigin) return c.notFound();
    const code = c.req.query("code");
    const browser = getCookie(c, NONCE);
    if (!code || !/^[A-Za-z0-9_-]{43}$/.test(code) || !browser) return fail(c, "expired");
    const ticket = await deps.db.first("SELECT profile FROM sessions WHERE token_hash = ? AND kind = 'web-handoff' AND created_at > ?",
      await sha256Hex(code), deps.now() - 60_000);
    let profile;
    try { profile = JSON.parse(ticket?.profile ?? '{}'); } catch { return fail(c, 'expired'); }
    if (profile.n !== browser) return fail(c, 'expired');
    const row = await deps.db.first("DELETE FROM sessions WHERE token_hash = ? AND kind = 'web-handoff' AND created_at > ? AND profile = ? RETURNING account_id",
      await sha256Hex(code), deps.now() - 60_000, ticket.profile);
    if (!row) return fail(c, "expired");
    deleteCookie(c, NONCE, options);
    const token = newSessionToken(deps.random);
    await deps.db.run("INSERT INTO sessions (token_hash, account_id, kind, created_at, last_used_at, profile) VALUES (?, ?, 'web', ?, ?, ?)",
      await sha256Hex(token), row.account_id, deps.now(), deps.now(), JSON.stringify(profile.identity ?? {}));
    setCookie(c, SESSION, token, { ...options, maxAge: 30 * DAY / 1000 });
    return c.redirect(destination(shareID(profile.share)), 303);
  });
  app.post("/app/auth/logout", webSignedIn, async (c) => {
    if (c.req.header("origin") !== webOrigin) return c.json({ error: "origin" }, 403);
    await deps.db.run("DELETE FROM sessions WHERE token_hash = ? AND kind = 'web'", c.get("web").hash);
    deleteCookie(c, SESSION, options);
    return c.body(null, 204);
  });
  app.get("/app/api/account", signedIn, async (c) => {
    const who = c.get("web");
    const stub = ownSpace(c);
    const [consents, counts, latest, smart, preferences, phone] = await Promise.all([stub.consents(), stub.counts(), deps.db.first(
      "SELECT MAX(last_sync_at) AS at FROM devices WHERE account_id = ?", who.account),
      stub.read("core.smartSettings", "smart-settings"), stub.read("core.appSettings", "appSettings"),
      deps.db.first("SELECT bundle FROM devices WHERE account_id = ? AND platform = 'iphone' ORDER BY last_sync_at DESC, updated_at DESC, id LIMIT 1", who.account)]);
    return c.json({ email: who.email, name: who.name, consents,
      counts: Object.fromEntries(Object.entries(counts).filter(([type]) => TYPES.has(type) && (CATALOG.get(type)?.tier !== "T2" || consents.health))),
      calendarSettingsUpdatedAt: smart?.v?.updatedAt ?? null,
      weekStartWeekday: calendarSettings(smart).weekStartWeekday,
      preferences: { distanceUnit: preferences?.distanceUnit ?? null, ownBundleID: phone?.bundle ?? null },
      lastSync: latest?.at ?? null, now: deps.now() });
  });
  app.get("/app/api/records", signedIn, async (c) => {
    const type = c.req.query("type"), after = c.req.query("after") ?? "";
    if (!TYPES.has(type) || after.length > 200) return c.json({ error: "bad_request" }, 400);
    return c.json(await ownSpace(c).browse(type, after));
  });
  async function calendarChoices(c) {
    const links = await deps.db.all("SELECT sub, email, refresh_token, scopes, status FROM google_links WHERE account_id = ? AND status <> 'unlinked' ORDER BY created_at, sub", c.get("web").account);
    const record = await ownSpace(c).read("core.smartSettings", "smart-settings");
    const accounts = await Promise.all(links.map(async link => {
      const account = { sub: link.sub, email: link.email, calendars: [] };
      if (!link.refresh_token || link.status !== "ok" || !canRead(link.scopes)) return { ...account, error: "reconnect" };
      try {
        const { accessToken } = await deps.google.refresh(await vault.open(link.sub, link.refresh_token));
        account.calendars = (await deps.google.calendarList(accessToken)).filter(cal => !cal.deleted && !cal.hidden)
          .map(cal => ({ id: cal.id, title: cal.summaryOverride || cal.summary || "Calendar",
            included: includesCalendar(cal, link.email, record), notifications: !(calendarSettings(record).settings.mutedCalendarIDs ?? []).includes(cal.id) }))
          .sort((a, b) => a.title.localeCompare(b.title));
        return account;
      } catch (e) { return { ...account, error: e instanceof GoogleRefused ? "reconnect" : "retry" }; }
    }));
    return { accounts, ready: Boolean(record?.v?.settings && record.v.calendarIDsAreGoogle === true), updatedAt: record?.v?.updatedAt ?? null };
  }
  app.get("/app/api/calendars", signedIn, async c => c.json(await calendarChoices(c)));
  app.put("/app/api/calendars", signedIn, async c => {
    if (c.req.header("Origin") !== webOrigin) return c.json({ error: "origin" }, 403);
    if (Number(c.req.header("Content-Length") || 0) > 4096) return c.json({ error: "bad_request" }, 400);
    let body;
    try { const raw = await c.req.text(); if (raw.length > 4096) return c.json({ error: "bad_request" }, 400); body = JSON.parse(raw); }
    catch { return c.json({ error: "bad_request" }, 400); }
    if (!body || typeof body.calendarID !== "string" || !["included", "notifications"].includes(body.preference)
      || typeof body.enabled !== "boolean") return c.json({ error: "bad_request" }, 400);
    const choices = await calendarChoices(c);
    if (!choices.accounts.some(a => a.calendars.some(cal => cal.id === body.calendarID))) return c.json({ error: "calendar_unavailable" }, 404);
    if (!choices.ready) return c.json({ error: "not_ready" }, 409);
    const result = await ownSpace(c).setCalendarPreference({ calendarID: body.calendarID, preference: body.preference, enabled: body.enabled, now: deps.now() });
    if (result.error) return c.json(result, result.error === "not_ready" ? 409 : 400);
    onCalendarSettingsChanged(c.get("web").account);
    return c.json({ updatedAt: result.updatedAt });
  });
  // Calendar titles are fetched for this browser request, never retained on the server.
  app.get("/app/api/calendar", signedIn, async (c) => {
    const from = Number(c.req.query("from")), to = Number(c.req.query("to"));
    if (!Number.isFinite(from) || !Number.isFinite(to) || from <= 0 || to <= from || to - from > 8 * DAY
      || Math.abs(from - deps.now()) > 366 * DAY) return c.json({ error: "bad_request" }, 400);
    const links = await deps.db.all("SELECT sub, email, refresh_token, scopes, status FROM google_links WHERE account_id = ? AND status <> 'unlinked' ORDER BY created_at, sub", c.get("web").account);
    const settings = await ownSpace(c).read("core.smartSettings", "smart-settings");
    const results = await Promise.all(links.map(async (link) => {
      const result = { events: [], unavailable: [] };
      if (!link.refresh_token || link.status !== "ok" || !canRead(link.scopes)) {
        result.unavailable.push({ email: link.email, reason: "reconnect" }); return result;
      }
      try {
        const { accessToken } = await deps.google.refresh(await vault.open(link.sub, link.refresh_token));
        const calendars = (await deps.google.calendarList(accessToken)).filter(cal => !cal.deleted && !cal.hidden && includesCalendar(cal, link.email, settings));
        // In bounded groups so a large account does not exhaust the Worker's outgoing connections.
        for (let i = 0; i < calendars.length; i += 4) {
          const group = await Promise.all(calendars.slice(i, i + 4).map(async (cal) => {
            try {
              const { events } = await deps.google.listEvents(accessToken, cal.id, {
                timeMin: new Date(from).toISOString(), timeMax: new Date(to).toISOString(),
                fields: "items(id,iCalUID,originalStartTime,summary,start,end,status,location,description,htmlLink,transparency,attendees,organizer,attachments,extendedProperties,hangoutLink,conferenceData,eventType,recurrence,recurringEventId),nextPageToken,nextSyncToken",
              });
              return events.map(event => ({ event, calendar: cal, email: link.email }));
            } catch { result.unavailable.push({ email: link.email, calendar: cal.summary || "Calendar", reason: "retry" }); return []; }
          }));
          result.events.push(...group.flat());
        }
      } catch (error) {
        result.unavailable.push({ email: link.email, reason: error instanceof GoogleRefused ? "reconnect" : "retry" });
      }
      return result;
    }));
    return c.json({ events: calendarAgenda(results.flatMap(r => r.events), settings, { details: true, includeDeclined: c.req.query("filter") === "1", allDay: c.req.query("filter") === "1" }),
      weekStartWeekday: calendarSettings(settings).weekStartWeekday,
      unavailable: results.flatMap(r => r.unavailable) });
  });
  app.get("/app/api/blob", signedIn, async (c) => {
    const type = c.req.query("type"), id = c.req.query("id"), field = c.req.query("field");
    if (!TYPES.has(type) || !id || id.length > 200 || !field || field.length > 200) return c.json({ error: "bad_request" }, 400);
    const ref = await ownSpace(c).webBlob(type, id, field);
    if (!ref) return c.json({ error: "not_found" }, 404);
    const found = await deps.blobs.get(`s/${personalSpace(c.get("web").account)}/${ref.$blob}`);
    if (!found) return c.json({ error: "not_found" }, 404);
    const mime = { jpg: "image/jpeg", jpeg: "image/jpeg", png: "image/png", webp: "image/webp", m4a: "audio/mp4", wav: "audio/wav", mp3: "audio/mpeg" }[ref.ext] ?? "application/octet-stream";
    return new Response(found.body, { headers: { "content-type": mime, "content-length": String(found.size),
      "cache-control": "no-store", "x-content-type-options": "nosniff", "content-security-policy": "default-src 'none'; sandbox" } });
  });
  sharingRoutes(app, deps, { owner: signedIn, signedIn: webSignedIn, calendarChoices, vault, webOrigin, home });
}
