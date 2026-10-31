// Crypto for the service, WebCrypto only (Workers and Node both have it).

const subtle = globalThis.crypto.subtle;
const encoder = new TextEncoder();
const decoder = new TextDecoder();

/** @param {Uint8Array} bytes */
export function base64url(bytes) {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** @param {string} text base64 or base64url, padded or not */
export function fromBase64(text) {
  const s = text.replace(/-/g, "+").replace(/_/g, "/").replace(/\s+/g, "");
  const bin = atob(s + "=".repeat((4 - (s.length % 4)) % 4));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/** @param {Uint8Array} bytes */
export const hex = (bytes) => Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");

/** SHA-256 of a string, as lowercase hex. */
export async function sha256Hex(text) {
  return hex(new Uint8Array(await subtle.digest("SHA-256", encoder.encode(text))));
}

/** HMAC-SHA256 of a string, as lowercase hex. @param {Uint8Array|string} key */
export async function hmacHex(key, text) {
  const raw = typeof key === "string" ? encoder.encode(key) : key;
  const k = await subtle.importKey("raw", raw, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return hex(new Uint8Array(await subtle.sign("HMAC", k, encoder.encode(text))));
}

/** A new session token: 32 random bytes, base64url. Only its SHA-256 is stored. */
export const newSessionToken = (random) => base64url(random(32));

/** A random secret for a Google channel's token (Google allows up to 256 characters). */
export const newSecret = (random) => base64url(random(32));

/** A random id for rows the service makes. */
export const newId = (random) => base64url(random(16));

/** A version 4 UUID from random bytes (Google channel ids). */
export function uuid(random) {
  const b = random(16);
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  const h = hex(b);
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

/** Compares two strings without stopping at the first difference (channel secrets). */
export function constantTimeEqual(a, b) {
  if (typeof a !== "string" || typeof b !== "string") return false;
  const x = encoder.encode(a);
  const y = encoder.encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

/**
 * Refresh tokens at rest: AES-256-GCM with the deployment's TOKEN_KEY (base64 of 32 bytes), as
 * `v1.<iv>.<ciphertext>` (base64url). The Google sub is the additional data, so a value only opens
 * on its own row. A new key would be `v2.` with the old key kept to open `v1.` values until they
 * are rewritten.
 * @param {string} tokenKey
 * @param {(n: number) => Uint8Array} random
 */
export function createVault(tokenKey, random) {
  let key;
  const getKey = () => {
    if (!key) {
      if (!tokenKey) throw new Error("TOKEN_KEY is not set");
      const raw = fromBase64(tokenKey);
      if (raw.length !== 32) throw new Error("TOKEN_KEY must be 32 bytes, base64");
      key = subtle.importKey("raw", raw, { name: "AES-GCM" }, false, ["encrypt", "decrypt"]);
    }
    return key;
  };
  return {
    /** @param {string} sub @param {string} plain */
    async seal(sub, plain) {
      const iv = random(12);
      const sealed = await subtle.encrypt({ name: "AES-GCM", iv, additionalData: encoder.encode(`google:${sub}`) },
        await getKey(), encoder.encode(plain));
      return `v1.${base64url(iv)}.${base64url(new Uint8Array(sealed))}`;
    },
    /** @param {string} sub @param {string} value */
    async open(sub, value) {
      const [version, iv, data] = String(value).split(".");
      if (version !== "v1" || !iv || !data) throw new Error("unknown sealed value");
      const plain = await subtle.decrypt({ name: "AES-GCM", iv: fromBase64(iv), additionalData: encoder.encode(`google:${sub}`) },
        await getKey(), fromBase64(data));
      return decoder.decode(plain);
    },
  };
}
