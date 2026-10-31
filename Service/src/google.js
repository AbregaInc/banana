// The Google port: trading the app's one-time code, access tokens, calendar watches, revoking, and
// for booking (docs/design/BOOKING.md) the calendar list, events made, read, moved and deleted, and free/busy.
// Errors never carry a token, a code, an email or a calendar id in their message.

import { fromBase64 } from "./crypto.js";

const TOKEN_URL = "https://oauth2.googleapis.com/token";
const CERTS_URL = "https://www.googleapis.com/oauth2/v3/certs";
const REVOKE_URL = "https://oauth2.googleapis.com/revoke";
const CALENDAR = "https://www.googleapis.com/calendar/v3";
const FETCH_TIMEOUT = 15_000;

/** Google said no for good (invalid_grant): the person has to connect again. */
export class GoogleRefused extends Error {
  constructor(message = "google refused") { super(message); this.name = "GoogleRefused"; }
}

/** Anything else that went wrong talking to Google: worth trying again later. */
export class GoogleError extends Error {
  constructor(message, status) { super(message); this.name = "GoogleError"; this.status = status; }
}

const form = (fields) => new URLSearchParams(fields).toString();

async function readJson(response) {
  try { return await response.json(); } catch { return {}; }
}

/**
 * @param {{googleClientId?: string, googleClientSecret?: string, googleRedirectUri?: string}} config
 * @param {typeof fetch} fetch
 * @param {() => number} [now]
 */
export function createGoogle(config, fetchImpl, now = Date.now) {
  /** @type {Map<string, {accessToken: string, expiresAt: number}>} keyed by refresh token, memory only */
  const cache = new Map();
  // No call waits on Google for longer than this: a hung read must not run a cron loop into the platform's limit.
  const fetch = (url, init = {}) => fetchImpl(url, { ...init, signal: AbortSignal.timeout(FETCH_TIMEOUT) });

  async function token(fields) {
    const response = await fetch(TOKEN_URL, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: form({ client_id: config.googleClientId ?? "", client_secret: config.googleClientSecret ?? "", ...fields }),
    });
    const body = await readJson(response);
    if (!response.ok) {
      if ((response.status === 400 || response.status === 401) && body.error === "invalid_grant") throw new GoogleRefused("invalid_grant");
      throw new GoogleError(`token endpoint ${response.status} ${typeof body.error === "string" ? body.error : ""}`.trim(), response.status);
    }
    return body;
  }

  function remember(refreshToken, body) {
    const expiresAt = now() + Number(body.expires_in ?? 3600) * 1000;
    cache.set(refreshToken, { accessToken: body.access_token, expiresAt });
    return { accessToken: body.access_token, expiresAt };
  }

  /** Google's signing keys, by key id, kept for as long as Google says they may be. */
  let certs = { keys: new Map(), until: 0 };
  async function signingKey(kid) {
    if (now() >= certs.until || !certs.keys.has(kid)) {
      const response = await fetch(CERTS_URL);
      if (!response.ok) throw new GoogleError(`certs ${response.status}`, response.status);
      const body = await readJson(response);
      const maxAge = Number(/max-age=(\d+)/.exec(response.headers.get("cache-control") ?? "")?.[1] ?? 3600);
      const keys = new Map();
      for (const jwk of body.keys ?? []) {
        keys.set(jwk.kid, await crypto.subtle.importKey("jwk", jwk, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"]));
      }
      certs = { keys, until: now() + maxAge * 1000 };
    }
    const key = certs.keys.get(kid);
    if (!key) throw new GoogleRefused("id_token key");
    return key;
  }

  return {
    /**
     * Checks an identity token the app got from Google for one of its own clients (minted with the
     * refresh token it already holds, so no sign-in sheet): Google's signature, issuer, audience,
     * expiry, a verified email. What it proves is who the person is; it grants the service nothing.
     * @param {string} idToken
     * @returns {Promise<{sub: string, email: string}>}
     */
    async verifyIdToken(idToken) {
      const parts = String(idToken).split(".");
      if (parts.length !== 3) throw new GoogleRefused("id_token shape");
      let header, claims;
      try {
        header = JSON.parse(new TextDecoder().decode(fromBase64(parts[0])));
        claims = JSON.parse(new TextDecoder().decode(fromBase64(parts[1])));
      } catch { throw new GoogleRefused("id_token unreadable"); }
      if (header.alg !== "RS256" || typeof header.kid !== "string") throw new GoogleRefused("id_token alg");
      const ok = await crypto.subtle.verify("RSASSA-PKCS1-v1_5", await signingKey(header.kid),
        fromBase64(parts[2]), new TextEncoder().encode(`${parts[0]}.${parts[1]}`));
      if (!ok) throw new GoogleRefused("id_token signature");
      if (claims.iss !== "https://accounts.google.com" && claims.iss !== "accounts.google.com") throw new GoogleRefused("id_token issuer");
      if (!(config.googleAppClientIds ?? []).includes(claims.aud)) throw new GoogleRefused("id_token audience");
      if (!(Number(claims.exp) * 1000 > now())) throw new GoogleRefused("id_token expired");
      if (claims.email_verified !== true && claims.email_verified !== "true") throw new GoogleRefused("email not verified");
      if (typeof claims.sub !== "string" || typeof claims.email !== "string") throw new GoogleRefused("id_token claims");
      return { sub: claims.sub, email: claims.email.toLowerCase(), name: typeof claims.name === "string" ? claims.name : null };
    },

    /**
     * Trades the app's serverAuthCode for the service's own refresh token.
     * @param {string} code
     * @returns {Promise<{sub: string, email: string, refreshToken: string|null, scopes: string}>}
     */
    async exchangeCode(code, { redirectUri } = {}) {
      // An iOS serverAuthCode is redeemed with an empty redirect_uri (it wasn't issued through a
      // redirect). To be confirmed at the first real sign-in; GOOGLE_REDIRECT_URI changes it. The
      // booking pages' own sign-in (a guest connecting) names its callback.
      const body = await token({ code, grant_type: "authorization_code", redirect_uri: redirectUri ?? config.googleRedirectUri ?? "" });
      // The id_token came straight from Google's token endpoint over TLS, so its signature isn't
      // checked; its claims are.
      let claims;
      try { claims = JSON.parse(new TextDecoder().decode(fromBase64(String(body.id_token).split(".")[1]))); }
      catch { throw new GoogleError("no id_token"); }
      if (claims.iss !== "https://accounts.google.com" && claims.iss !== "accounts.google.com") throw new GoogleRefused("id_token issuer");
      if (claims.aud !== config.googleClientId) throw new GoogleRefused("id_token audience");
      if (!(Number(claims.exp) * 1000 > now())) throw new GoogleRefused("id_token expired");
      if (claims.email_verified !== true && claims.email_verified !== "true") throw new GoogleRefused("email not verified");
      if (typeof claims.sub !== "string" || typeof claims.email !== "string") throw new GoogleRefused("id_token claims");
      const refreshToken = typeof body.refresh_token === "string" ? body.refresh_token : null;
      if (refreshToken && body.access_token) remember(refreshToken, body);
      return { sub: claims.sub, email: claims.email.toLowerCase(), refreshToken, scopes: String(body.scope ?? ""),
        name: typeof claims.name === "string" ? claims.name : null, accessToken: typeof body.access_token === "string" ? body.access_token : null };
    },

    /** An access token for this refresh token, from memory until a minute before it ends. */
    async refresh(refreshToken) {
      const cached = cache.get(refreshToken);
      if (cached && cached.expiresAt - 60_000 > now()) return { ...cached };
      cache.delete(refreshToken);
      const body = await token({ refresh_token: refreshToken, grant_type: "refresh_token" });
      return remember(refreshToken, body);
    },

    /**
     * The events of a calendar: a full read between `timeMin` and `timeMax`, or only what changed
     * since `syncToken` (deletions included, as cancelled events). Every page. The parameters match
     * the app's own read, so a token from one continues the other. A `410` is a GoogleError with
     * status 410: the token is gone, read in full.
     * @returns {Promise<{events: object[], syncToken: string|null}>}
     */
    async listEvents(accessToken, calendarId, { syncToken, timeMin, timeMax, fields }) {
      const events = [];
      let nextSyncToken = null, pageToken = null;
      do {
        const params = new URLSearchParams({ singleEvents: "true", maxResults: "2500" });
        if (syncToken) params.set("syncToken", syncToken);
        else { params.set("timeMin", timeMin); params.set("timeMax", timeMax); }
        // The busy read asks for times only: no titles, descriptions or attendees' names cross.
        if (fields) params.set("fields", fields);
        if (pageToken) params.set("pageToken", pageToken);
        const response = await fetch(`${CALENDAR}/calendars/${encodeURIComponent(calendarId)}/events?${params}`, {
          headers: { authorization: `Bearer ${accessToken}` },
        });
        const body = await readJson(response);
        if (!response.ok) throw new GoogleError(`events ${response.status}`, response.status);
        if (Array.isArray(body.items)) events.push(...body.items);
        pageToken = body.nextPageToken ?? null;
        nextSyncToken = body.nextSyncToken ?? nextSyncToken;
      } while (pageToken);
      return { events, syncToken: nextSyncToken };
    },

    /** The calendars of the account, every page (booking: which calendars count as busy, and their zones). */
    async calendarList(accessToken) {
      const items = [];
      let pageToken = null;
      do {
        const params = new URLSearchParams({ maxResults: "250", fields: "items(id,summary,summaryOverride,backgroundColor,timeZone,primary,hidden,deleted,accessRole,selected,dataOwner),nextPageToken" });
        if (pageToken) params.set("pageToken", pageToken);
        const response = await fetch(`${CALENDAR}/users/me/calendarList?${params}`, { headers: { authorization: `Bearer ${accessToken}` } });
        const body = await readJson(response);
        if (!response.ok) throw new GoogleError(`calendarList ${response.status}`, response.status);
        if (Array.isArray(body.items)) items.push(...body.items);
        pageToken = body.nextPageToken ?? null;
      } while (pageToken);
      return items;
    },

    /** One event, or null when Google no longer has it (404, 410). */
    async getEvent(accessToken, calendarId, eventId) {
      const response = await fetch(`${CALENDAR}/calendars/${encodeURIComponent(calendarId)}/events/${encodeURIComponent(eventId)}`, {
        headers: { authorization: `Bearer ${accessToken}` },
      });
      if (response.status === 404 || response.status === 410) return null;
      const body = await readJson(response);
      if (!response.ok) throw new GoogleError(`event ${response.status}`, response.status);
      return body;
    },

    /**
     * Makes an event (a booking). `conferenceDataVersion=1` so Meet can be asked for; a 409 (the
     * id is taken: a retry whose first try got through) is a GoogleError with status 409.
     * @param {{sendUpdates: "all"|"none"}} options
     */
    async insertEvent(accessToken, calendarId, event, { sendUpdates }) {
      const params = new URLSearchParams({ conferenceDataVersion: "1", sendUpdates });
      const response = await fetch(`${CALENDAR}/calendars/${encodeURIComponent(calendarId)}/events?${params}`, {
        method: "POST",
        headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
        body: JSON.stringify(event),
      });
      const body = await readJson(response);
      if (!response.ok) throw new GoogleError(`insert ${response.status}`, response.status);
      return body;
    },

    /** Changes part of an event. Null when Google no longer has it. */
    async patchEvent(accessToken, calendarId, eventId, patch, { sendUpdates }) {
      const params = new URLSearchParams({ conferenceDataVersion: "1", sendUpdates });
      const response = await fetch(`${CALENDAR}/calendars/${encodeURIComponent(calendarId)}/events/${encodeURIComponent(eventId)}?${params}`, {
        method: "PATCH",
        headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
        body: JSON.stringify(patch),
      });
      if (response.status === 404 || response.status === 410) return null;
      const body = await readJson(response);
      if (!response.ok) throw new GoogleError(`patch ${response.status}`, response.status);
      return body;
    },

    /** Deletes an event; one already gone (404, 410) counts as deleted. */
    async deleteEvent(accessToken, calendarId, eventId, { sendUpdates }) {
      const params = new URLSearchParams({ sendUpdates });
      const response = await fetch(`${CALENDAR}/calendars/${encodeURIComponent(calendarId)}/events/${encodeURIComponent(eventId)}?${params}`, {
        method: "DELETE", headers: { authorization: `Bearer ${accessToken}` },
      });
      if (!response.ok && response.status !== 404 && response.status !== 410) throw new GoogleError(`delete ${response.status}`, response.status);
    },

    /** Free/busy of the calendars named (a connected guest's primary). @returns {Promise<Array<{start: string, end: string}>>} */
    async freeBusy(accessToken, { timeMin, timeMax, ids = ["primary"] }) {
      const response = await fetch(`${CALENDAR}/freeBusy`, {
        method: "POST",
        headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
        body: JSON.stringify({ timeMin, timeMax, items: ids.map((id) => ({ id })) }),
      });
      const body = await readJson(response);
      if (!response.ok) throw new GoogleError(`freeBusy ${response.status}`, response.status);
      const out = [];
      for (const cal of Object.values(body.calendars ?? {})) {
        if (Array.isArray(cal.errors) && cal.errors.length) throw new GoogleError("freeBusy calendar error", 502);
        for (const b of cal.busy ?? []) out.push({ start: b.start, end: b.end });
      }
      return out;
    },

    /** Asks Google to call `address` when the calendar changes. */
    async watch(accessToken, calendarId, { id, token: secret, address, ttlSeconds }) {
      const response = await fetch(`${CALENDAR}/calendars/${encodeURIComponent(calendarId)}/events/watch`, {
        method: "POST",
        headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
        body: JSON.stringify({ id, type: "web_hook", address, token: secret, params: { ttl: String(ttlSeconds) } }),
      });
      const body = await readJson(response);
      if (!response.ok) throw new GoogleError(`watch ${response.status}`, response.status);
      return { resourceId: String(body.resourceId), expiration: Number(body.expiration) };
    },

    /** Ends a channel. A channel Google no longer knows (404) counts as ended. */
    async stop(accessToken, { id, resourceId }) {
      const response = await fetch(`${CALENDAR}/channels/stop`, {
        method: "POST",
        headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
        body: JSON.stringify({ id, resourceId }),
      });
      if (!response.ok && response.status !== 404) throw new GoogleError(`stop ${response.status}`, response.status);
    },

    /** Revokes the refresh token (and every access token made from it) at Google. */
    async revoke(refreshToken) {
      cache.delete(refreshToken);
      const response = await fetch(REVOKE_URL, {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: form({ token: refreshToken }),
      });
      if (!response.ok) throw new GoogleError(`revoke ${response.status}`, response.status);
    },
  };
}
