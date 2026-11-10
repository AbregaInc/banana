// The APNs port: silent pushes with token-based auth (a .p8 key), WebCrypto only.
// APNs speaks HTTP/2 only, so the `fetch` given here must do HTTP/2 (src/adapters/http2.js on Node).

import { base64url, fromBase64 } from "./crypto.js";

const HOSTS = { production: "api.push.apple.com", development: "api.sandbox.push.apple.com" };
const JWT_LIFETIME = 50 * 60 * 1000; // Apple wants a new one at most every 20 min, at least every 60
const JWT_GAP = 20 * 60 * 1000;      // never replace a shared token younger than this (Apple's floor)

const encoder = new TextEncoder();
const json64 = (value) => base64url(encoder.encode(JSON.stringify(value)));

/** The DER bytes inside a PEM (or bare base64) private key; escaped newlines from env are fine. */
export function pemBytes(pem) {
  const body = String(pem).replace(/\\n/g, "\n").replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  return fromBase64(body);
}

/** The provider token every isolate shares, in the database (migration 0028). */
export function sharedProviderTokens(db) {
  const read = (keyId) => db.first("SELECT token, issued_at AS issuedAt FROM apns_provider_tokens WHERE key_id = ?", keyId);
  return {
    read,
    /** Stores `token` unless the one stored is younger than `gap` (and is not `replacing`, a token
     * Apple refused). Returns the token in force afterwards: concurrent makers settle on one. */
    async offer(keyId, token, issuedAt, { gap, replacing = null }) {
      await db.run(`INSERT INTO apns_provider_tokens (key_id, token, issued_at) VALUES (?, ?, ?)
        ON CONFLICT (key_id) DO UPDATE SET token = excluded.token, issued_at = excluded.issued_at
        WHERE apns_provider_tokens.issued_at <= ? OR apns_provider_tokens.token = ?`,
        keyId, token, issuedAt, issuedAt - gap, replacing ?? "");
      return read(keyId);
    },
  };
}

/**
 * @param {{apnsKey?: string, apnsKeyId?: string, apnsTeamId?: string}} config
 * @param {typeof fetch} fetch
 * @param {() => number} [now]
 * @param {ReturnType<typeof sharedProviderTokens>|null} [tokens] one token for every isolate;
 *   without it each instance makes its own (tests, a single Node process).
 */
export function createApns(config, fetch, now = Date.now, tokens = null) {
  let key;
  let jwt = null;
  let jwtAt = 0;
  let refused = null;   // the token Apple last refused (403): never adopted again

  async function mint() {
    if (!config.apnsKey || !config.apnsKeyId || !config.apnsTeamId) throw new Error("APNs key is not set");
    key ??= crypto.subtle.importKey("pkcs8", pemBytes(config.apnsKey), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
    const issuedAt = now();
    const input = `${json64({ alg: "ES256", kid: config.apnsKeyId })}.${json64({ iss: config.apnsTeamId, iat: Math.floor(issuedAt / 1000) })}`;
    // WebCrypto's ECDSA signature is r||s (IEEE P1363), which is exactly what a JWT's ES256 wants.
    const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, await key, encoder.encode(input));
    return { token: `${input}.${base64url(new Uint8Array(signature))}`, issuedAt };
  }
  const usable = (stored) => stored && typeof stored.token === "string" && stored.token !== refused
    && now() - Number(stored.issuedAt) < JWT_LIFETIME;
  const adopt = (stored) => { jwt = stored.token; jwtAt = Number(stored.issuedAt); return jwt; };

  async function bearer() {
    if (jwt && now() - jwtAt < JWT_LIFETIME) return jwt;
    if (tokens && config.apnsKeyId) {
      try { const stored = await tokens.read(config.apnsKeyId); if (usable(stored)) return adopt(stored); }
      catch (error) { console.log(`apns: shared token unreadable (${error.name})`); }
    }
    const made = await mint();
    if (tokens && config.apnsKeyId) {
      try {
        const kept = await tokens.offer(config.apnsKeyId, made.token, made.issuedAt, { gap: JWT_GAP, replacing: refused });
        if (usable(kept)) return adopt(kept);
      } catch (error) { console.log(`apns: shared token not stored (${error.name})`); }
    }
    return adopt(made);
  }

  return {
    /** The current provider token (exposed for tests). */
    bearer,

    /**
     * @param {{token: string, env: string, topic: string, payload: object, collapseId?: string,
     *          pushType?: "background"|"alert", priority?: 5|10}} push
     *   Background pushes must be priority 5 (Apple); a visible alert goes at 10, at once.
     * @returns {Promise<{ok: boolean, status: number, reason: string|null}>}
     */
    async send({ token, env, topic, payload, collapseId, pushType = "background", priority }) {
      const host = HOSTS[env] ?? HOSTS.production;
      const headers = {
        authorization: `bearer ${await bearer()}`,
        "apns-topic": topic,
        "apns-push-type": pushType,
        "apns-priority": String(priority ?? (pushType === "alert" ? 10 : 5)),
        "content-type": "application/json",
      };
      if (collapseId) headers["apns-collapse-id"] = collapseId;
      const response = await fetch(`https://${host}/3/device/${token}`, { method: "POST", headers, body: JSON.stringify(payload) });
      let reason = null;
      if (!response.ok) {
        try { reason = (await response.json()).reason ?? null; } catch { reason = null; }
        // An expired or refused provider token: make a new one next time.
        if (response.status === 403) { refused = jwt; jwt = null; }
        // Another isolate's token is in force: read the shared one again next time.
        else if (response.status === 429 && reason === "TooManyProviderTokenUpdates" && tokens) jwt = null;
      }
      return { ok: response.ok, status: response.status, reason };
    },
  };
}
