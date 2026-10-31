// The APNs port: silent pushes with token-based auth (a .p8 key), WebCrypto only.
// APNs speaks HTTP/2 only, so the `fetch` given here must do HTTP/2 (src/adapters/http2.js on Node).

import { base64url, fromBase64 } from "./crypto.js";

const HOSTS = { production: "api.push.apple.com", development: "api.sandbox.push.apple.com" };
const JWT_LIFETIME = 50 * 60 * 1000; // Apple wants a new one at most every 20 min, at least every 60

const encoder = new TextEncoder();
const json64 = (value) => base64url(encoder.encode(JSON.stringify(value)));

/** The DER bytes inside a PEM (or bare base64) private key; escaped newlines from env are fine. */
export function pemBytes(pem) {
  const body = String(pem).replace(/\\n/g, "\n").replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  return fromBase64(body);
}

/**
 * @param {{apnsKey?: string, apnsKeyId?: string, apnsTeamId?: string}} config
 * @param {typeof fetch} fetch
 * @param {() => number} [now]
 */
export function createApns(config, fetch, now = Date.now) {
  let key;
  let jwt = null;
  let jwtAt = 0;

  async function bearer() {
    if (jwt && now() - jwtAt < JWT_LIFETIME) return jwt;
    if (!config.apnsKey || !config.apnsKeyId || !config.apnsTeamId) throw new Error("APNs key is not set");
    key ??= crypto.subtle.importKey("pkcs8", pemBytes(config.apnsKey), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
    const issuedAt = now();
    const input = `${json64({ alg: "ES256", kid: config.apnsKeyId })}.${json64({ iss: config.apnsTeamId, iat: Math.floor(issuedAt / 1000) })}`;
    // WebCrypto's ECDSA signature is r||s (IEEE P1363), which is exactly what a JWT's ES256 wants.
    const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, await key, encoder.encode(input));
    jwt = `${input}.${base64url(new Uint8Array(signature))}`;
    jwtAt = issuedAt;
    return jwt;
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
        if (response.status === 403) jwt = null;
      }
      return { ok: response.ok, status: response.status, reason };
    },
  };
}
