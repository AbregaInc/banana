// Keyed signatures for the booking pages: the manage link, the guest's CSRF token, the address hash
// for the hourly limit, email codes, and short-lived signed values (the connect state, a connected
// guest's busy). One key per use, each derived from TOKEN_KEY as the analytics key is.

import { base64url, constantTimeEqual, fromBase64 } from "../crypto.js";

const encoder = new TextEncoder();
const decoder = new TextDecoder();
const subtle = globalThis.crypto.subtle;

/** @param {string} tokenKey base64 of 32 bytes */
export function createSigner(tokenKey) {
  const keys = new Map();
  function key(purpose) {
    let k = keys.get(purpose);
    if (!k) {
      k = (async () => {
        const root = await subtle.importKey("raw", fromBase64(tokenKey), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
        const derived = new Uint8Array(await subtle.sign("HMAC", root, encoder.encode(`banana booking ${purpose} v1`)));
        return subtle.importKey("raw", derived, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
      })();
      keys.set(purpose, k);
    }
    return k;
  }
  const mac = async (purpose, text, bytes = 16) =>
    base64url(new Uint8Array(await subtle.sign("HMAC", await key(purpose), encoder.encode(text))).slice(0, bytes));

  return {
    /** The manage link's signature for a manage id. */
    manage: (id) => mac("manage", id),
    /** Whether `<id>.<sig>` is a manage reference we made; the id when it is. */
    async openManage(ref) {
      const m = /^([A-Za-z0-9_-]{22})\.([A-Za-z0-9_-]{22})$/.exec(String(ref ?? ""));
      if (!m) return null;
      return constantTimeEqual(await mac("manage", m[1]), m[2]) ? m[1] : null;
    },
    /** The CSRF token for a guest session (by its hash) or for none. */
    csrf: (sessionHash) => mac("csrf", sessionHash ?? "none"),
    /** A keyed hash of a client address: the hourly limit counts it, nobody can read it back. */
    ip: (address) => mac("ip", String(address ?? ""), 12),
    /** A code's keyed hash, bound to its email. */
    code: (email, code) => mac("code", `${email}\n${code}`, 32),
    /** A signed value with an expiry: `<payload>.<sig>`, base64url. */
    async seal(purpose, value, expiresAt) {
      const payload = base64url(encoder.encode(JSON.stringify({ v: value, e: expiresAt })));
      return `${payload}.${await mac(purpose, payload)}`;
    },
    /** The value of a sealed string, or null when it is forged, for another purpose, or expired. */
    async unseal(purpose, sealed, now) {
      const [payload, sig] = String(sealed ?? "").split(".");
      if (!payload || !sig || payload.length > 16_384) return null;
      if (!constantTimeEqual(await mac(purpose, payload), sig)) return null;
      try {
        const { v, e } = JSON.parse(decoder.decode(fromBase64(payload)));
        return Number(e) > now ? v : null;
      } catch { return null; }
    },
  };
}
