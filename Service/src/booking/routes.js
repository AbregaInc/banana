// The booking host's routes (book.bananatheapp.com, beta-book.…), exactly as CONTRACT.md lists them.
// Pages render through ./pages/index.js; the answers to the page's script are JSON. Every POST is
// checked for its Origin; a guest cookie's POSTs also carry the page's CSRF token. Every failure of
// a manage link is a plain 404, never logged.
//
// Never logged: names, emails, phone numbers, notes, links, handles.

import { Hono } from "hono";
import { getCookie, setCookie, deleteCookie } from "hono/cookie";
import { canonicalZone, MINUTE, nearest } from "./slots.js";
import { typeView } from "./types.js";
import { cacheAge, cacheable, withFreshNonce } from "./guard.js";
import {
  bookingView, cancel, complete, findRetry, icsFor, liveRow, mail, manageRef, move, pushHost, readHost, refusal, reserve, slotsOf, undo,
} from "./book.js";
import { CONNECT_COOKIE, checkCode, endSession, forgetGuest, guestAccount, guestOf, guestView, newCode, rememberProfile, startSession } from "./guests.js";
import { codeEmail } from "./email.js";
import { accessToken } from "../calendar.js";
import { GoogleRefused } from "../google.js";

const DAY = 24 * 60 * MINUTE;
const FREEBUSY_SCOPE = "https://www.googleapis.com/auth/calendar.events.freebusy";
const LIVE_READ_TIMEOUT = 1500;
const GUEST_BUSY_TIMEOUT = 250;
const EMAIL = /^[^\s@<>()[\]\\,;:"]{1,64}@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$/;
const HANDLE = /^[a-z0-9-]{3,30}$/;
const SLUG = /^[a-z0-9-]{1,40}$/;

/** Text as typed, checked: trimmed, control characters gone, at most `most` characters, or null. */
export function clean(value, most, { lines = false } = {}) {
  if (value == null) return null;
  if (typeof value !== "string") return undefined;
  const s = (lines ? value.replace(/\r\n?/g, "\n").replace(/[\u0000-\u0009\u000b-\u001f\u007f]/g, "") : value.replace(/[\u0000-\u001f\u007f]/g, "")).trim();
  if (!s) return null;
  return s.length <= most ? s : undefined;
}
export const validEmail = (s) => typeof s === "string" && s.length <= 254 && EMAIL.test(s);

const withTimeout = (promise, ms) => Promise.race([promise, new Promise((resolve) => setTimeout(() => resolve(undefined), ms))]);

/**
 * @param {import("../app.js").Deps & {email: any, limit: Function, turnstile: any, pageCache: any}} deps
 * @param {{vault: any, signer: any, push: Function}} shared
 */
export function bookingApp(deps, { vault, signer, push }) {
  const config = deps.config;
  const ctx = { deps, vault, signer, config, push };
  const app = new Hono();
  // The pages load with the first booking request, so nothing in them can stop the API from starting.
  let pages = null;
  app.use("*", async (c, next) => {
    pages ??= await import("./pages/index.js");
    await next();
  });

  // The client's address: Cloudflare's header on Workers; on Node the socket's peer (deps.clientIp),
  // or x-forwarded-for only where TRUST_FORWARDED_FOR says a proxy in front sets it.
  const ipOf = (c) => deps.clientIp?.(c)
    ?? (config.trustForwardedFor ? c.req.header("x-forwarded-for")?.split(",")[0]?.trim() : null)
    ?? c.req.header("cf-connecting-ip") ?? "local";
  const zoneOfRequest = (c, guest) => canonicalZone(guest?.verifiedAt ? guest.guest?.zone : guest?.profile?.zone)
    ?? canonicalZone(c.req.raw.cf?.timezone) ?? null;
  const localeOf = (c) => (c.req.header("accept-language") ?? "").split(",")[0]?.split(";")[0]?.trim().slice(0, 35) || "en-US";

  function page(c, out, timing = []) {
    const headers = new Headers(out.headers ?? {});
    if (!headers.has("content-type")) headers.set("content-type", "text/html; charset=utf-8");
    if (!headers.has("content-security-policy")) headers.set("content-security-policy", "default-src 'none'; frame-ancestors 'none'; base-uri 'none'");
    if (!headers.has("referrer-policy")) headers.set("referrer-policy", "no-referrer");
    if (timing.length) headers.set("server-timing", [headers.get("server-timing"), ...timing].filter(Boolean).join(", "));
    return new Response(out.html, { status: out.status ?? 200, headers });
  }
  const notFound = (c) => page(c, pages.notFound());
  const json = (c, body, status = 200, extra = {}) => {
    c.header("cache-control", "no-store");
    for (const [k, v] of Object.entries(extra)) c.header(k, v);
    return c.json(body, status);
  };

  async function readBody(c, limit = 8192) {
    const length = Number(c.req.header("content-length") || 0);
    if (length > limit) return null;
    const text = await c.req.text();
    if (text.length > limit) return null;
    try { const v = JSON.parse(text || "{}"); return v && typeof v === "object" && !Array.isArray(v) ? v : null; } catch { return null; }
  }

  // POSTs come from our own pages only: the Origin must be the booking host's. With a guest cookie
  // the page's CSRF token must come too (the cookie is SameSite=Lax as well).
  app.use("*", async (c, next) => {
    if (c.req.method === "POST") {
      const origin = c.req.header("origin");
      if (!origin || origin !== new URL(config.bookUrl).origin) return json(c, { error: "origin" }, 403);
      const guest = await guestOf(deps, c);
      c.set("guest", guest);
      if (guest) {
        const token = c.req.header("x-csrf-token") ?? "";
        if (token !== (await signer.csrf(guest.hash))) return json(c, { error: "csrf" }, 403);
      }
    }
    await next();
  });
  /** The browser's guest session, read once per request. */
  const guestFor = async (c) => {
    if (c.get("guest") === undefined) c.set("guest", await guestOf(deps, c));
    return c.get("guest");
  };

  /** The guest's link to a Banana person holds only while that person still has a Google account with this email. */
  const personStillLinked = async (g) => Boolean(await deps.db.first(
    "SELECT 1 AS yes FROM google_links WHERE account_id = ? AND email = ? AND status <> 'unlinked'", g.personAccountId, g.email));

  /** A verified guest's upcoming times, across hosts. */
  async function upcomingOf(guest) {
    if (!guest?.verifiedAt) return [];
    const rows = await deps.db.all(
      `SELECT b.manage_id, b.type_title, b.start_at, b.end_at, b.account_id, h.handle, a.display_name,
         (SELECT g.name FROM google_links g WHERE g.account_id = b.account_id AND g.status <> 'unlinked' ORDER BY g.created_at LIMIT 1) AS google_name
       FROM bookings b JOIN accounts a ON a.id = b.account_id LEFT JOIN booking_handles h ON h.account_id = b.account_id
       WHERE b.guest_account_id = ? AND b.status IN ('pending', 'confirmed') AND b.end_at > ? ORDER BY b.start_at LIMIT 20`,
      guest.accountId, deps.now());
    return Promise.all(rows.map(async (r) => ({
      manageUrl: `/m/${await manageRef(ctx, r.manage_id)}`, hostName: r.display_name || r.google_name || "",
      title: r.type_title, start: new Date(Number(r.start_at)).toISOString(), end: new Date(Number(r.end_at)).toISOString(),
    })));
  }

  /**
   * A connected guest's busy time over the host's horizon: the Banana person's own snapshot, or
   * their free/busy grant read now (bounded: the page asks /slots again when it isn't back in time),
   * or the signed busy the connect callback handed over.
   */
  async function guestBusy(c, guest, horizon, { wait = true } = {}) {
    const sealed = c.req.query("fb");
    if (sealed) {
      const v = await signer.unseal("busy", sealed, deps.now());
      if (v && (!v.s || v.s === guest?.hash)) return v.b.map(([s, e]) => ({ start: new Date(s * MINUTE).toISOString(), end: new Date(e * MINUTE).toISOString() }));
    }
    if (!guest?.verifiedAt) return null;
    const work = (async () => {
      if (guest.guest?.personAccountId && await personStillLinked(guest.guest)) {
        const row = await (deps.replica ?? deps.db).first("SELECT horizon_json FROM busy_snapshot WHERE account_id = ? AND computed_at > 0", guest.guest.personAccountId);
        if (row) { const h = JSON.parse(row.horizon_json); return h.busy.map(([s, e]) => ({ start: new Date(s).toISOString(), end: new Date(e).toISOString() })); }
      }
      const grant = await deps.db.first("SELECT sub, refresh_token, status FROM guest_grants WHERE account_id = ? AND status = 'ok' ORDER BY updated_at DESC LIMIT 1", guest.accountId);
      if (!grant?.refresh_token) return null;
      try {
        const access = (await deps.google.refresh(await vault.open(`guest:${grant.sub}`, grant.refresh_token))).accessToken;
        return await deps.google.freeBusy(access, { timeMin: new Date(deps.now()).toISOString(), timeMax: new Date(horizon).toISOString() });
      } catch (error) {
        if (error instanceof GoogleRefused) await deps.db.run("UPDATE guest_grants SET status = 'refused', refresh_token = NULL, updated_at = ? WHERE sub = ?", deps.now(), grant.sub);
        return null;
      }
    })().catch(() => null);
    return wait ? work : (await withTimeout(work, GUEST_BUSY_TIMEOUT)) ?? null;
  }

  const hostView = (host) => ({ handle: host.handle, name: host.name, photoUrl: null });
  /** Whether email can be sent at all: without a provider there are no codes and no "we emailed you". */
  const emailOn = () => deps.email?.enabled === true;

  /** The connect link for a guest who hasn't one working yet. */
  async function connectFor(guest, returnTo) {
    if (!config.googleClientId) return null;
    if (guest?.verifiedAt && (guest.guest?.personAccountId
      || await deps.db.first("SELECT 1 AS x FROM guest_grants WHERE account_id = ? AND status = 'ok'", guest.accountId))) return null;
    return { url: `/b/connect?return=${encodeURIComponent(returnTo)}` };
  }

  // ---- the pages ----

  // ---- the page cache: for a browser that carries no guest, keyed by the page, the zone, the
  // locale and the host's version (its snapshot, its types, its latest booking change), so any
  // booking or edit makes a new key. Looked up before the host is read at all.
  const VERSION_SQL = `SELECT s.computed_at, s.types_at, h.updated_at AS handle_at, (SELECT MAX(b.updated_at) FROM bookings b WHERE b.account_id = h.account_id) AS changed
    FROM booking_handles h LEFT JOIN busy_snapshot s ON s.account_id = h.account_id WHERE h.handle = ?`;

  /** The cache key for this request's page, or null when it isn't one to cache. */
  async function cacheKey(c, handle) {
    if (!deps.pageCache || c.req.query("fb") || (await guestFor(c))) return null;
    const v = await (deps.replica ?? deps.db).first(VERSION_SQL, handle);
    if (!v || !Number(v.computed_at)) return null;
    const zone = canonicalZone(c.req.raw.cf?.timezone) ?? "host";
    return `${c.req.path}|${zone}|${localeOf(c)}|${v.computed_at}.${v.types_at ?? 0}.${v.handle_at ?? 0}.${v.changed ?? 0}`;
  }

  /** A cached page: fresh is served, stale is served and rendered again after the answer. */
  async function fromCache(c, key, rerender) {
    const entry = key ? await deps.pageCache.get(key).catch(() => null) : null;
    const age = cacheAge(entry, deps.now());
    if (age === "miss") return null;
    if (age === "stale") deps.defer(rerender().catch(() => {}));
    return page(c, withFreshNonce(entry, deps.random), [`cache;desc=${age}`]);
  }

  /** The times page for one type. */
  async function timesPage(c, host, type, key) {
    const t0 = Date.now();
    const guest = await guestFor(c);
    const out = await renderTimes(c, host, type, { guest, zone: zoneOfRequest(c, guest) ?? type.timeZone, locale: localeOf(c), key });
    return page(c, out, [...(key ? ["cache;desc=miss"] : []), `total;dur=${Date.now() - t0}`]);
  }

  async function renderTimes(c, host, type, { guest, zone, locale, key }) {
    const t0 = Date.now();
    const slots = slotsOf(host, type);
    const engine = Date.now() - t0;
    const path = `/${host.handle}/${type.slug}`;
    const [upcoming, busy, connect] = await Promise.all([upcomingOf(guest), guestBusy(c, guest, host.horizon.to, { wait: false }), connectFor(guest, path)]);
    const out = pages.times({
      host: hostView(host), type: typeView(type, slots[0] ?? null), slots, guest: await guestView(deps, guest, { upcoming }),
      turnstileSiteKey: config.turnstileSiteKey || null, connect, busy, csrf: await signer.csrf(guest?.hash), zone, locale, canEmail: emailOn(),
    });
    out.headers = { ...(out.headers ?? {}), "server-timing": [out.headers?.["server-timing"], `engine;dur=${engine}`].filter(Boolean).join(", ") };
    if (key && deps.pageCache) await deps.pageCache.put(key, { ...cacheable(out), at: deps.now() }).catch(() => {});
    return out;
  }

  /** The rate limit, then the cache, then the host. {limited} | {cached: Response} | {host, key} | null. */
  async function hostPage(c, handle, { cache = false } = {}) {
    if (!HANDLE.test(handle)) return null;
    if (!(await deps.limit("slots", ipOf(c)))) return { limited: true };
    const key = cache ? await cacheKey(c, handle) : null;
    if (key) {
      const cached = await fromCache(c, key, async () => {
        const fresh = await readHost(ctx, { handle });
        const type = pickType(fresh, c.req.param("slug"));
        if (type && !refusal(fresh, type)) await renderTimes(c, fresh, type, { guest: null, zone: zoneOfRequest(c, null) ?? type.timeZone, locale: localeOf(c), key });
      });
      if (cached) return { cached };
    }
    const t0 = Date.now();
    const host = await readHost(ctx, { handle });
    c.set("dbTime", Date.now() - t0);
    return host ? { host, key } : null;
  }
  /** The type a page shows: the slug's, or the only active one. */
  const pickType = (host, slug) => {
    if (!host) return null;
    if (slug) return host.types.find((x) => x.slug === slug) ?? null;
    const active = host.types.filter((x) => x.active);
    return active.length === 1 ? active[0] : null;
  };

  async function notTakingPage(c, host, type) {
    const why = type ? refusal(host, type) : "unknown";
    if (why === "unknown" || why === "no_writer") {
      // Told once a day: a link Google refused, a calendar Banana can't read, nowhere to write.
      const t = deps.now();
      const told = await deps.db.run("UPDATE busy_snapshot SET told_at = ? WHERE account_id = ? AND (told_at IS NULL OR told_at < ?)", t, host.account, t - DAY);
      if (told.changes) deps.defer(pushHost(ctx, host.account, "Someone tried to book you: reconnect Google Calendar in Banana to take bookings", `bk-refused-${host.account.slice(0, 20)}`));
    }
    return page(c, pages.notTaking({ host: hostView(host) }));
  }

  app.get("/", (c) => c.redirect("https://bananatheapp.com", 302));

  app.get("/:handle{[a-z0-9-]{3,30}}", async (c) => {
    const found = await hostPage(c, c.req.param("handle"), { cache: true });
    if (!found) return notFound(c);
    if (found.limited) return c.text("Too many requests", 429);
    if (found.cached) return found.cached;
    const { host, key } = found;
    const active = host.types.filter((x) => x.active);
    if (!active.length) return page(c, pages.notTaking({ host: hostView(host) }));
    if (active.length === 1) {
      if (refusal(host, active[0])) return notTakingPage(c, host, active[0]);
      return timesPage(c, host, active[0], key);
    }
    if (refusal(host, active[0]) === "unknown") return notTakingPage(c, host, null);
    const guest = await guestFor(c);
    const types = active.map((x) => typeView(x, refusal(host, x) ? null : slotsOf(host, x)[0] ?? null));
    return page(c, pages.profile({ host: hostView(host), types, guest: await guestView(deps, guest, { upcoming: await upcomingOf(guest) }),
      zone: zoneOfRequest(c, guest) ?? active[0].timeZone, locale: localeOf(c), canEmail: emailOn() }), [`db;dur=${c.get("dbTime") ?? 0}`]);
  });

  app.get("/:handle{[a-z0-9-]{3,30}}/:slug{[a-z0-9-]{1,40}}", async (c) => {
    const found = await hostPage(c, c.req.param("handle"), { cache: true });
    if (!found) return notFound(c);
    if (found.limited) return c.text("Too many requests", 429);
    if (found.cached) return found.cached;
    const { host, key } = found;
    const type = pickType(host, c.req.param("slug"));
    if (!type) return notFound(c);
    if (refusal(host, type)) return notTakingPage(c, host, type);
    return timesPage(c, host, type, key);
  });

  // For a page left open: the slots again, and a connected guest's busy (CONTRACT.md).
  app.get("/:handle{[a-z0-9-]{3,30}}/:slug{[a-z0-9-]{1,40}}/slots", async (c) => {
    const found = await hostPage(c, c.req.param("handle"));
    if (!found) return json(c, { error: "not_found" }, 404);
    if (found.limited) return json(c, { error: "rate" }, 429);
    const { host } = found;
    const type = host.types.find((x) => x.slug === c.req.param("slug"));
    if (!type) return json(c, { error: "not_found" }, 404);
    if (refusal(host, type)) return json(c, { slots: [], busy: null, taking: false });
    const guest = await guestFor(c);
    const busy = await guestBusy(c, guest, host.horizon.to);
    c.header("cache-control", guest ? "private, no-store" : "public, max-age=30");
    return c.json({ slots: slotsOf(host, type), busy });
  });

  // ---- book ----

  app.post("/:handle{[a-z0-9-]{3,30}}/:slug{[a-z0-9-]{1,40}}/book", async (c) => {
    const ip = ipOf(c);
    if (!(await deps.limit("book", ip))) return json(c, { error: "rate" }, 429);
    const body = await readBody(c);
    if (!body) return json(c, { field: null, error: "bad_request" }, 400);
    const name = clean(body.name, 80), phone = clean(body.phone, 32), note = clean(body.note, 1000, { lines: true });
    const email = typeof body.email === "string" ? body.email.trim().toLowerCase() : "";
    const key = typeof body.key === "string" && /^[A-Za-z0-9_-]{8,64}$/.test(body.key) ? body.key : null;
    if (!key || typeof body.start !== "string") return json(c, { field: null, error: "bad_request" }, 400);
    if (!name) return json(c, { field: "name", error: "required" }, 400);
    if (!validEmail(email)) return json(c, { field: "email", error: "invalid" }, 400);
    if (phone === undefined) return json(c, { field: "phone", error: "invalid" }, 400);
    if (note === undefined) return json(c, { field: "note", error: "too_long" }, 400);

    const host = await readHost(ctx, { handle: c.req.param("handle") });
    const type = host?.types.find((x) => x.slug === c.req.param("slug"));
    if (!host || !type) return json(c, { error: "not_found" }, 404);
    const guest = await guestFor(c);
    // A zone the browser got wrong falls back to the guest's or the request's, then the type's: never UTC.
    const zone = canonicalZone(body.zone) ?? zoneOfRequest(c, guest) ?? type.timeZone;
    if (refusal(host, type)) return json(c, { error: "not_taking" }, 409);
    const place = type.places.find((p) => p.id === body.place) ?? (body.place == null ? type.places[0] : null);
    if (!place) return json(c, { field: "place", error: "invalid" }, 400);
    if (place.kind === "phone_host_calls" && !phone) return json(c, { field: "phone", error: "required" }, 400);

    const input = { key, start: body.start, email, name, phone: phone ?? null, note: note ?? null, zone, place };
    // A retry of a post that got through: the same booking, whatever has happened since.
    const seen = await findRetry(ctx, input);
    if (seen) return json(c, { booking: await bookingView(ctx, seen) });

    // Turnstile is for a browser we don't know; one that booked with this email before books with a
    // tap. Another email from a remembered browser is a first time again.
    const known = guest && (guest.profile?.email === email || (guest.verifiedAt && guest.guest?.email === email));
    if (!known && !(await deps.turnstile.verify(body.turnstile, ip))) return json(c, { field: "turnstile", error: "turnstile" }, 400);

    // The hourly and daily limits, beyond the binding's minute.
    const t = deps.now();
    const ipHash = await signer.ip(ip);
    const [byIp, byHost] = await Promise.all([
      deps.db.first("SELECT COUNT(*) AS n FROM bookings WHERE ip_hash = ? AND created_at > ?", ipHash, t - 60 * MINUTE),
      deps.db.first("SELECT COUNT(*) AS n FROM bookings WHERE account_id = ? AND created_at > ? AND status IN ('pending', 'confirmed')", host.account, t - DAY),
    ]);
    if (Number(byIp?.n) >= 10 || Number(byHost?.n) >= 50) return json(c, { error: "rate" }, 429);

    const result = await reserve(ctx, host, type, { ...input, guestAccount: null, ipHash });
    if (result.kind === "taken" || result.kind === "full") return json(c, { taken: true, nearest: result.nearest ?? [] }, 409);
    if (result.kind === "existing") {
      // The link goes only to the email: whoever typed it may not own it, so it gets one a day.
      const emailed = emailOn() && (await deps.limit("code", `existing:${email}`))
        && (await deps.db.run("UPDATE bookings SET existing_mailed_at = ? WHERE id = ? AND (existing_mailed_at IS NULL OR existing_mailed_at < ?)",
          t, result.row.id, t - DAY)).changes > 0;
      if (emailed) deps.defer(mail(ctx, "existing", result.row, host));
      return json(c, { already: true, emailed: emailOn() }, 409);
    }
    const row = result.row;
    if (result.fresh) {
      // The guest's account only once the time is theirs. Its name and phone change only from a
      // browser that typed this email before; a stranger typing someone's email changes nothing.
      const guestId = guest?.verifiedAt && guest.guest?.email === email ? guest.accountId
        : await guestAccount(deps, email, { name, phone, zone, update: Boolean(known) });
      await deps.db.run("UPDATE bookings SET guest_account_id = ? WHERE id = ?", guestId, row.id);
      row.guest_account_id = guestId;
      deps.defer(complete(ctx, row.id, { first: true }).catch((error) => console.log(`booking: complete failed (${error.name})`)));
    }
    // Remember this browser: what it typed fills the next form.
    const profile = { name, email, phone: phone ?? null, zone };
    if (guest) await rememberProfile(deps, guest.hash, profile);
    else await startSession(deps, c, row.guest_account_id, { profile, verified: false });
    return json(c, { booking: await bookingView(ctx, row) });
  });

  app.post("/b/undo", async (c) => {
    if (!(await deps.limit("book", ipOf(c)))) return json(c, { error: "rate" }, 429);
    const body = await readBody(c, 1024);
    const id = await signer.openManage(body?.manage);
    if (!id) return json(c, { error: "not_found" }, 404);
    const done = await undo(ctx, id);
    if (done === "undone") return c.body(null, 204);
    // A move's old time went in the moment between: the new time stands, and the answer says so.
    if (done === "taken") {
      const row = await deps.db.first("SELECT * FROM bookings WHERE manage_id = ?", id);
      return json(c, { error: "taken", kept: true, booking: await bookingView(ctx, row) }, 409);
    }
    return json(c, { error: "too_late" }, 409);
  });

  // ---- manage ----

  /** The booking a manage reference names, or null (any failure is the same 404). */
  async function managed(ref) {
    const id = await signer.openManage(ref);
    if (!id) return null;
    const row = await deps.db.first("SELECT * FROM bookings WHERE manage_id = ?", id);
    if (!row || deps.now() > Number(row.end_at) + 60 * MINUTE) return null;
    return row;
  }

  app.get("/m/:ref", async (c) => {
    if (!(await deps.limit("slots", ipOf(c)))) return c.text("Too many requests", 429);
    const ref = c.req.param("ref");
    let row = await managed(ref);
    if (!row || ["taken", "failed"].includes(row.status)) return notFound(c);
    row = (await withTimeout(liveRow(ctx, row), LIVE_READ_TIMEOUT)) ?? row;
    const host = await readHost(ctx, { account: row.account_id });
    if (!host) return notFound(c);
    const type = host.types.find((x) => x.id === row.type_id);
    const guest = await guestFor(c);
    const tv = type ? typeView(type) : { slug: "", title: row.type_title, minutes: Math.round((row.end_at - row.start_at) / MINUTE), places: [], hostZone: host.zone };
    const zone = canonicalZone(row.guest_zone) ?? zoneOfRequest(c, guest) ?? tv.hostZone;
    const booking = await bookingView(ctx, row);
    if (row.status === "cancelled") return page(c, pages.cancelled({ host: hostView(host), type: tv, booking, zone, locale: localeOf(c) }));
    const slots = type && !refusal(host, type) ? slotsOf(host, type, { except: row.id }) : [];
    return page(c, pages.manage({ host: hostView(host), type: tv, booking, slots, guest: await guestView(deps, guest, { upcoming: await upcomingOf(guest) }),
      csrf: await signer.csrf(guest?.hash), zone, locale: localeOf(c), canEmail: emailOn() }));
  });

  // The follow-up after a booking: has the invite gone, is the Meet link there (CONTRACT.md).
  app.get("/m/:ref/state", async (c) => {
    const row = await managed(c.req.param("ref"));
    if (!row) return json(c, { error: "not_found" }, 404);
    let nearestSlots = null;
    if (row.status === "taken" || row.status === "failed") {
      const host = await readHost(ctx, { account: row.account_id });
      const type = host?.types.find((x) => x.id === row.type_id);
      nearestSlots = type && !refusal(host, type) ? nearest(slotsOf(host, type).filter((x) => Date.parse(x.start) !== Number(row.start_at)), Number(row.start_at)) : [];
    }
    return json(c, { booking: await bookingView(ctx, row, { nearestSlots }) });
  });

  app.post("/m/:ref/move", async (c) => {
    if (!(await deps.limit("book", ipOf(c)))) return json(c, { error: "rate" }, 429);
    const row = await managed(c.req.param("ref"));
    if (!row) return json(c, { error: "not_found" }, 404);
    const body = await readBody(c, 1024);
    if (typeof body?.start !== "string") return json(c, { error: "bad_request" }, 400);
    if (row.status !== "confirmed") return json(c, { error: row.status === "pending" ? "not_yet" : "not_found" }, row.status === "pending" ? 409 : 404);
    const host = await readHost(ctx, { account: row.account_id });
    const type = host?.types.find((x) => x.id === row.type_id);
    if (!host || !type || refusal(host, type)) return json(c, { taken: true, nearest: [] }, 409);
    const result = await move(ctx, row, host, type, { start: body.start, zone: canonicalZone(body.zone) });
    if (result.kind === "taken") return json(c, { taken: true, nearest: result.nearest }, 409);
    if (result.kind === "unavailable") return json(c, { error: "try_again" }, 503);
    return json(c, { booking: await bookingView(ctx, result.row) });
  });

  app.post("/m/:ref/cancel", async (c) => {
    if (!(await deps.limit("book", ipOf(c)))) return json(c, { error: "rate" }, 429);
    const row = await managed(c.req.param("ref"));
    if (!row) return json(c, { error: "not_found" }, 404);
    const body = await readBody(c, 4096);
    const reason = clean(body?.reason, 1000, { lines: true });
    const host = await readHost(ctx, { account: row.account_id });
    await cancel(ctx, row, host, { by: "guest", reason: reason || null });
    return c.body(null, 204);
  });

  app.get("/b/:file{[A-Za-z0-9_-]{22}\\.ics}", async (c) => {
    const id = c.req.param("file").slice(0, 22);
    const row = await managed(`${id}.${c.req.query("sig") ?? ""}`);
    if (!row) return notFound(c);
    const host = await readHost(ctx, { account: row.account_id });
    const type = host?.types.find((x) => x.id === row.type_id);
    const ics = icsFor(ctx, row, host, type, await manageRef(ctx, row.manage_id));
    return new Response(ics, { headers: { "content-type": "text/calendar; charset=utf-8", "content-disposition": 'attachment; filename="invite.ics"',
      "cache-control": "no-store", "referrer-policy": "no-referrer" } });
  });

  // ---- guests: the code, Google, Forget me ----

  const safeReturn = (r) => (typeof r === "string" && /^\/[A-Za-z0-9/_.-]{0,200}$/.test(r) && !r.startsWith("//") ? r : "/");

  app.get("/b/code", async (c) => {
    if (!emailOn()) return notFound(c);
    const guest = await guestFor(c);
    const email = typeof c.req.query("email") === "string" ? c.req.query("email").trim().toLowerCase() : guest?.profile?.email ?? "";
    return page(c, pages.code({ email: validEmail(email) ? email : "", csrf: await signer.csrf(guest?.hash), returnTo: safeReturn(c.req.query("return")) }));
  });

  // Always 204: whether the email is known is nobody's business.
  app.post("/b/code", async (c) => {
    if (!emailOn()) return json(c, { error: "unavailable" }, 404);
    const body = await readBody(c, 1024);
    const email = typeof body?.email === "string" ? body.email.trim().toLowerCase() : "";
    if (!validEmail(email)) return json(c, { field: "email", error: "invalid" }, 400);
    if ((await deps.limit("code", ipOf(c))) && (await deps.limit("code", email))) {
      const code = await newCode(deps, signer, email);
      if (code) deps.defer(deps.email.send(codeEmail(email, code, { from: config.emailFrom })).catch((error) => console.log(`booking: code email failed (${error.code ?? error.name})`)));
    }
    return c.body(null, 204);
  });

  app.post("/b/code/verify", async (c) => {
    if (!(await deps.limit("code", `verify:${ipOf(c)}`))) return json(c, { error: "rate" }, 429);
    const body = await readBody(c, 1024);
    const email = typeof body?.email === "string" ? body.email.trim().toLowerCase() : "";
    if (!validEmail(email) || !(await checkCode(deps, signer, email, body?.code))) return json(c, { field: "code", error: "code" }, 400);
    const account = await guestAccount(deps, email, { verified: true });
    await linkPerson(account, email);
    const guest = await guestFor(c);
    await startSession(deps, c, account, { profile: { ...(guest?.profile ?? {}), email }, verified: true });
    return c.body(null, 204);
  });

  /** A guest who is also a Banana person: their own calendars count. Only for a proven email. */
  async function linkPerson(account, email, sub = null) {
    const person = sub ? await deps.db.first("SELECT account_id FROM google_links WHERE sub = ? AND status <> 'unlinked'", sub)
      : await deps.db.first("SELECT account_id FROM google_links WHERE email = ? AND status <> 'unlinked' ORDER BY created_at LIMIT 1", email);
    if (person) await deps.db.run("UPDATE guests SET person_account_id = ? WHERE account_id = ?", person.account_id, account);
  }

  app.get("/b/forget", async (c) => {
    const guest = await guestFor(c);
    if (!guest?.verifiedAt) {
      if (!emailOn()) return notFound(c);
      const email = guest?.profile?.email ?? "";
      return page(c, pages.code({ email: validEmail(email) ? email : "", csrf: await signer.csrf(guest?.hash), returnTo: "/b/forget" }));
    }
    const n = await deps.db.first("SELECT COUNT(*) AS n FROM bookings WHERE guest_account_id = ? AND status IN ('pending', 'confirmed') AND end_at > ?", guest.accountId, deps.now());
    return page(c, pages.forget({ guest: await guestView(deps, guest), upcomingCount: Number(n?.n ?? 0), csrf: await signer.csrf(guest.hash) }));
  });

  // "Not you?": this browser forgets who it was. The guest's account and times stay.
  app.post("/b/not-me", async (c) => {
    const guest = await guestFor(c);
    if (guest) await deps.db.run("DELETE FROM sessions WHERE token_hash = ? AND kind = 'guest'", guest.hash);
    endSession(c);
    return c.body(null, 204);
  });

  app.post("/b/forget", async (c) => {
    const guest = await guestFor(c);
    if (!guest) return c.body(null, 204);
    if (!guest.verifiedAt) {
      // Not proven: this browser forgets, the guest's account stays for its owner.
      await deps.db.run("DELETE FROM sessions WHERE token_hash = ? AND kind = 'guest'", guest.hash);
    } else {
      await forgetGuest(deps, vault, guest.accountId);
    }
    endSession(c);
    return c.body(null, 204);
  });

  // Google: one tap to read the guest's free/busy. Offline access is asked only when no grant is held.
  app.get("/b/connect", async (c) => {
    if (!config.googleClientId) return notFound(c);
    const guest = await guestFor(c);
    const returnTo = safeReturn(c.req.query("return"));
    const nonce = Array.from(deps.random(16), (b) => b.toString(16).padStart(2, "0")).join("");
    const held = guest?.verifiedAt ? await deps.db.first("SELECT 1 AS x FROM guest_grants WHERE account_id = ? AND status = 'ok'", guest.accountId) : null;
    const state = await signer.seal("connect", { r: returnTo, n: nonce }, deps.now() + 10 * MINUTE);
    setCookie(c, CONNECT_COOKIE, nonce, { path: "/", secure: true, httpOnly: true, sameSite: "Lax", maxAge: 600 });
    const params = new URLSearchParams({
      client_id: config.googleClientId, redirect_uri: `${config.bookUrl}/b/connect/callback`, response_type: "code", state,
      scope: held ? "openid email" : `openid email profile ${FREEBUSY_SCOPE}`,
      ...(held ? { prompt: "select_account" } : { access_type: "offline", prompt: "consent", include_granted_scopes: "true" }),
      ...(guest?.guest?.email && guest.verifiedAt ? { login_hint: guest.guest.email } : {}),
    });
    return c.redirect(`https://accounts.google.com/o/oauth2/v2/auth?${params}`, 302);
  });

  app.get("/b/connect/callback", async (c) => {
    const state = await signer.unseal("connect", c.req.query("state"), deps.now());
    const nonce = getCookie(c, CONNECT_COOKIE);
    deleteCookie(c, CONNECT_COOKIE, { path: "/", secure: true });
    if (!state || !nonce || state.n !== nonce) return notFound(c);
    const back = safeReturn(state.r);
    const code = c.req.query("code");
    if (!code || code.length > 2048) return c.redirect(back, 303);   // they said no: back to the times
    let who;
    try { who = await deps.google.exchangeCode(code, { redirectUri: `${config.bookUrl}/b/connect/callback` }); }
    catch (error) { console.log(`booking: connect exchange failed (${error.name})`); return c.redirect(back, 303); }
    const account = await guestAccount(deps, who.email, { name: who.name, verified: true });
    await linkPerson(account, who.email, who.sub);
    const scoped = String(who.scopes).split(/\s+/).includes(FREEBUSY_SCOPE);
    const t = deps.now();
    if (who.refreshToken && scoped) {
      await deps.db.run(
        `INSERT INTO guest_grants (sub, account_id, email, refresh_token, scopes, status, checked_at, created_at, updated_at) VALUES (?, ?, ?, ?, ?, 'ok', ?, ?, ?)
         ON CONFLICT (sub) DO UPDATE SET account_id = excluded.account_id, email = excluded.email, refresh_token = excluded.refresh_token,
           scopes = excluded.scopes, status = 'ok', checked_at = excluded.checked_at, updated_at = excluded.updated_at`,
        who.sub, account, who.email, await vault.seal(`guest:${who.sub}`, who.refreshToken), who.scopes, t, t, t);
    }
    const guest = await guestFor(c);
    const hash = await startSession(deps, c, account, { profile: { ...(guest?.profile ?? {}), email: who.email, name: guest?.profile?.name ?? who.name }, verified: true });
    // No grant to keep (Google left the refresh token out): this once, the busy goes back in the link.
    const granted = await deps.db.first("SELECT 1 AS x FROM guest_grants WHERE account_id = ? AND status = 'ok'", account);
    if (!granted && scoped && who.accessToken) {
      try {
        const busy = await deps.google.freeBusy(who.accessToken, { timeMin: new Date(t).toISOString(), timeMax: new Date(t + 92 * DAY).toISOString() });
        const packed = busy.map((b) => [Math.floor(Date.parse(b.start) / MINUTE), Math.ceil(Date.parse(b.end) / MINUTE)]).slice(0, 500);
        const sealed = await signer.seal("busy", { b: packed, s: hash }, t + 30 * MINUTE);
        return c.redirect(`${back}?fb=${encodeURIComponent(sealed)}`, 303);
      } catch (error) { console.log(`booking: connect free/busy failed (${error.name})`); }
    }
    return c.redirect(back, 303);
  });

  app.notFound((c) => (c.req.method === "GET" ? notFound(c) : json(c, { error: "not_found" }, 404)));
  app.onError((error, c) => {
    console.log(`booking error: ${error.name}: ${error.message}`);
    if (c.req.method !== "GET") return json(c, { error: "server" }, 500);
    return pages ? page(c, { ...pages.notFound(), status: 500 }) : c.text("Something went wrong. Try again in a moment.", 500);
  });
  return app;
}
