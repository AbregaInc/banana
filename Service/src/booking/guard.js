// What stands in front of the booking routes: rate limits (the Workers rate-limiting binding, or a
// counter in memory on Node), Turnstile, and the page cache (caches.default on Workers, memory on
// Node) with a stale-while-revalidate of our own, as the Cache API doesn't do it.

/** The limits, per key, per window: {limit, period seconds}. Workers' binding only takes 10 or 60 s. */
export const LIMITS = {
  slots: { limit: 120, period: 60 },   // page views and slot reads per address
  book: { limit: 10, period: 60 },     // bookings, moves, cancels per address
  code: { limit: 5, period: 60 },      // codes asked for, per address and per email
  api: { limit: 60, period: 60 },      // anonymous API writes (usage, diagnostics) per address
  notify: { limit: 30, period: 60 },   // Google change notices acted on, per channel
  share: { limit: 60, period: 60 },    // a share's reads (the owner's Google quota behind them), per share
  reconcile: { limit: 6, period: 60 }, // calendar-list changes acted on at Google, per Google account
};

/** deps.limit on Workers: one binding per limit (wrangler.toml [[ratelimits]]). */
export function workersLimits(env) {
  const bindings = { slots: env.RL_SLOTS, book: env.RL_BOOK, code: env.RL_CODE, api: env.RL_API, notify: env.RL_NOTIFY, share: env.RL_SHARE, reconcile: env.RL_RECONCILE };
  const memory = memoryLimits();
  return async (name, key) => {
    const binding = bindings[name];
    if (!binding) return memory(name, key);
    try { return (await binding.limit({ key: `${name}:${key}` })).success; } catch { return true; }
  };
}

/** deps.limit in memory: a fixed window per key. */
export function memoryLimits(now = Date.now) {
  const windows = new Map();
  return async (name, key) => {
    const rule = LIMITS[name];
    if (!rule) return true;
    const t = now(), id = `${name}:${key}`;
    let w = windows.get(id);
    if (!w || t - w.at >= rule.period * 1000) { w = { at: t, n: 0 }; windows.set(id, w); }
    if (windows.size > 50_000) windows.clear();
    return ++w.n <= rule.limit;
  };
}

/**
 * deps.turnstile: Cloudflare's siteverify. Without a secret the check fails closed where the booking
 * pages are deployed (`required`); only a local run that says TURNSTILE_SKIP=1 lets everything through.
 */
export function createTurnstile(secret, fetch, { required = true } = {}) {
  if (!secret) {
    let told = false;
    const say = (what) => { if (!told) { console.log(`turnstile: no TURNSTILE_SECRET, ${what}`); told = true; } };
    if (required) return { enabled: false, missing: true, async verify() { say("every unknown browser is refused (set the secret, or TURNSTILE_SKIP=1 locally)"); return false; } };
    return { enabled: false, async verify() { say("skipped"); return true; } };
  }
  return {
    enabled: true,
    async verify(token, ip) {
      if (typeof token !== "string" || !token || token.length > 2048) return false;
      try {
        const response = await fetch("https://challenges.cloudflare.com/turnstile/v0/siteverify", {
          method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" },
          body: new URLSearchParams({ secret, response: token, ...(ip ? { remoteip: ip } : {}) }).toString(),
        });
        const body = await response.json();
        return body?.success === true;
      } catch { return false; }
    },
  };
}

const FRESH = 30_000;       // served as is
const STALE = 300_000;      // served, and rendered again after the answer

/** The page cache on Workers: keys are made-up URLs; each entry carries when it was rendered. */
export function workersPageCache(cache) {
  const url = (key) => `https://book-cache.invalid/${encodeURIComponent(key)}`;
  return {
    async get(key) {
      const hit = await cache.match(url(key));
      if (!hit) return null;
      // The page's own headers go back as they were; the cache's are ours alone.
      let headers = {};
      try { headers = JSON.parse(hit.headers.get("x-page-headers") ?? "{}"); } catch { headers = {}; }
      return { html: await hit.text(), status: hit.status, headers, at: Number(hit.headers.get("x-rendered-at")) };
    },
    async put(key, { html, status, headers, at }) {
      await cache.put(url(key), new Response(html, { status, headers: {
        "content-type": "text/html; charset=utf-8", "x-page-headers": JSON.stringify(headers ?? {}), "x-rendered-at": String(at),
        "cache-control": `public, max-age=${(FRESH + STALE) / 1000}` } }));
    },
    async delete(key) { await cache.delete(url(key)); },
  };
}

/** The page cache in memory (Node; tests). */
export function memoryPageCache() {
  const entries = new Map();
  return {
    entries,
    async get(key) { return entries.get(key) ?? null; },
    async put(key, value) { if (entries.size > 2000) entries.clear(); entries.set(key, value); },
    async delete(key) { entries.delete(key); },
  };
}

/** Fresh: serve. Stale: serve and render again. Older: render now. */
export const cacheAge = (entry, now) => (!entry ? "miss" : now - entry.at < FRESH ? "fresh" : now - entry.at < FRESH + STALE ? "stale" : "miss");

// The CSP nonce: a cached page keeps a placeholder, and every answer from the cache gets a fresh one.
const PLACEHOLDER = "__BOOKING_NONCE__";

/** A rendered page as the cache keeps it: its nonce (from the CSP header) replaced by the placeholder. */
export function cacheable(out) {
  const csp = out.headers?.["content-security-policy"] ?? "";
  const nonce = /'nonce-([A-Za-z0-9+/=_-]{8,})'/.exec(csp)?.[1];
  if (!nonce) return out;
  const swap = (v) => String(v).split(nonce).join(PLACEHOLDER);
  return { ...out, html: swap(out.html), headers: Object.fromEntries(Object.entries(out.headers).map(([k, v]) => [k, swap(v)])) };
}

/** A cached page with a fresh nonce in the HTML and the CSP header. */
export function withFreshNonce(entry, random) {
  let nonce = "";
  for (const b of random(16)) nonce += String.fromCharCode(b);
  nonce = btoa(nonce).replace(/=+$/, "");
  const swap = (v) => String(v).split(PLACEHOLDER).join(nonce);
  return { ...entry, html: swap(entry.html), headers: Object.fromEntries(Object.entries(entry.headers ?? {}).map(([k, v]) => [k, swap(v)])) };
}
