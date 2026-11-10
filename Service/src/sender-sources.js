// Where a sender's image comes from, fetched by the service and never by a device
// (docs/design/MAIL-UX.md, "Sender images"): a brand's BIMI logo, Gravatar, and a site's own icon.
// Every fetch is https to a public host name, bounded in time and size, and what comes back is
// kept only when its bytes are an image (PNG, JPEG, GIF or WebP). An SVG (BIMI's format) is checked
// and drawn here, to a PNG, so devices only ever decode bitmaps.
//
// Each source answers {image: {bytes, type}}, {none: true} (asked, and there is nothing), or
// {failed: true} (could not tell: kept for a short time only).

import { getDomain } from "tldts";

export const IMAGE_PX = 128;              // what is asked of each source: a 32 pt face at 3x and some room
const TIMEOUT = 3_000;
const MOST_IMAGE_BYTES = 256 * 1024;
const MOST_SVG_BYTES = 32 * 1024;         // BIMI's own limit for a logo
const MOST_PAGE_BYTES = 256 * 1024;       // a home page read for its icon links; the head comes first
const SMALLEST_ICON = 64;
const AGENT = "BananaSenderImages/1 (+https://bananatheapp.com)";

/**
 * Mail providers: everyone at these domains is a person with the provider's address, so the domain's
 * brand (its BIMI logo or site icon) never stands for them.
 */
const PROVIDERS = [
  "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "msn.com", "passport.com",
  "yahoo.com", "ymail.com", "rocketmail.com", "aol.com", "aim.com", "icloud.com", "me.com", "mac.com",
  "proton.me", "protonmail.com", "protonmail.ch", "pm.me", "tutanota.com", "tuta.io", "tutamail.com",
  "gmx.com", "gmx.net", "gmx.de", "web.de", "mail.com", "yandex.com", "yandex.ru", "mail.ru", "zoho.com",
  "fastmail.com", "fastmail.fm", "hey.com", "qq.com", "163.com", "126.com", "naver.com", "daum.net",
  "comcast.net", "verizon.net", "att.net", "sbcglobal.net", "btinternet.com", "orange.fr", "free.fr",
  "laposte.net", "libero.it", "t-online.de", "seznam.cz", "wp.pl", "o2.pl", "interia.pl", "rediffmail.com",
];
/** Providers with a country's own domain (hotmail.co.uk, yahoo.fr, outlook.de…): by their name. */
const PROVIDER_NAMES = new Set(["hotmail", "outlook", "live", "yahoo", "gmx", "yandex", "aol"]);
const PROVIDER_SET = new Set(PROVIDERS);

/** The address in the one form every key is made from, its parts, and its organisational domain. */
export function addressParts(input) {
  if (typeof input !== "string") return null;
  const address = input.trim().toLowerCase();
  if (address.length > 254) return null;
  const at = address.lastIndexOf("@");
  if (at < 1) return null;
  const local = address.slice(0, at), domain = address.slice(at + 1);
  if (!/^[a-z0-9.-]+$/.test(domain) || !domain.includes(".") || /(^|\.)-|-(\.|$)|\.\./.test(domain)) return null;
  if (/\s/.test(local)) return null;
  const organisation = getDomain(domain, { allowPrivateDomains: false }) ?? domain;
  return { address, local, domain, organisation };
}

export function isProvider(parts) {
  if (PROVIDER_SET.has(parts.organisation) || PROVIDER_SET.has(parts.domain)) return true;
  return PROVIDER_NAMES.has(parts.organisation.split(".")[0]);
}

/**
 * An address a program sends from, not a person: a site's icon may stand for these only.
 * The local part's words, the way clients that show brand icons for automated mail tell them apart.
 */
const AUTOMATED = /^(no-?reply|do-?not-?reply|donotreply|notifications?|notify|alerts?|news(letters?)?|info|hello|hi|support|help|team|updates?|mailer|mail|marketing|billing|receipts?|orders?|accounts?|account-?security|security|service|services|contact|admin|bounce|feedback|digest|community|events?|invoices?|payments?|shipping|store|shop|sales|welcome|reply|automated|system|calendar|reminders?)([+._-].*)?$/;
export function isAutomated(parts) {
  return AUTOMATED.test(parts.local);
}

export async function sha256Hex(text) {
  const bytes = typeof text === "string" ? new TextEncoder().encode(text) : text;
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// ---- bytes ----

/** The image type the bytes are, by their first bytes: never what a server said. */
export function sniff(bytes) {
  const b = bytes;
  if (b.length >= 8 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47 && b[4] === 0x0d && b[5] === 0x0a && b[6] === 0x1a && b[7] === 0x0a) return "image/png";
  if (b.length >= 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return "image/jpeg";
  if (b.length >= 6 && b[0] === 0x47 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x38 && (b[4] === 0x37 || b[4] === 0x39) && b[5] === 0x61) return "image/gif";
  if (b.length >= 12 && b[0] === 0x52 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x46 && b[8] === 0x57 && b[9] === 0x45 && b[10] === 0x42 && b[11] === 0x50) return "image/webp";
  return null;
}

/** Width and height of a PNG or GIF, or null when the format does not say it in its header. */
export function dimensions(bytes, type) {
  if (type === "image/png" && bytes.length >= 24) {
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    return { width: view.getUint32(16), height: view.getUint32(20) };
  }
  if (type === "image/gif" && bytes.length >= 10) return { width: bytes[6] | (bytes[7] << 8), height: bytes[8] | (bytes[9] << 8) };
  return null;
}

/**
 * Why an SVG may not be drawn, or null. SVG Tiny PS (BIMI's profile) has no scripts, no external
 * references and no foreign content; anything else is refused before it is drawn. The renderer
 * (resvg) runs no script and loads nothing itself either: this is the first wall, not the only one.
 */
export function svgProblem(text) {
  if (typeof text !== "string" || !text.trim()) return "empty";
  if (/<!ENTITY/i.test(text)) return "entity";
  if (!/<svg[\s>/]/i.test(text)) return "not svg";
  if (/<script[\s>]/i.test(text)) return "script";
  if (/<foreignObject[\s>]/i.test(text)) return "foreign object";
  if (/\son[a-z]+\s*=/i.test(text)) return "event handler";
  if (/<(image|use|feImage)\b[^>]*\bhref\s*=\s*["'](?!#)/i.test(text)) return "external reference";
  if (/url\(\s*["']?(?!#)/i.test(text)) return "external url";
  if (/@import/i.test(text)) return "import";
  return null;
}

// ---- fetching ----

/** A host the service may fetch from: a public name over https, never an address, a local name, or a port. */
export function fetchable(url) {
  let u;
  try { u = new URL(url); } catch { return false; }
  if (u.protocol !== "https:" || u.username || u.password || (u.port && u.port !== "443")) return false;
  const host = u.hostname.toLowerCase();
  if (!host.includes(".") || /^[\d.]+$/.test(host) || host.startsWith("[") || host.includes(":")) return false;
  if (/(^|\.)(localhost|local|internal|intranet|lan|home|corp|arpa|test|invalid|example)$/.test(host)) return false;
  return true;
}

/**
 * GET with redirects followed by hand (each checked like the first), a time limit for the whole
 * fetch, and the body cut off at `most` bytes. null for a refused URL; {status} for anything but a
 * whole 200; {status: 200, bytes, contentType}.
 */
export async function boundedGet(fetch, url, { most = MOST_IMAGE_BYTES, accept = "image/*" } = {}) {
  const signal = AbortSignal.timeout(TIMEOUT);
  let at = url;
  for (let hop = 0; hop <= 3; hop++) {
    if (!fetchable(at)) return null;
    const response = await fetch(at, { redirect: "manual", signal, headers: { accept, "user-agent": AGENT } });
    if (response.status >= 300 && response.status < 400) {
      const next = response.headers.get("location");
      await response.body?.cancel?.().catch?.(() => {});
      if (!next) return { status: response.status };
      at = new URL(next, at).toString();
      continue;
    }
    if (response.status !== 200) { await response.body?.cancel?.().catch?.(() => {}); return { status: response.status }; }
    const declared = Number(response.headers.get("content-length") || 0);
    if (declared > most) { await response.body?.cancel?.().catch?.(() => {}); return { status: 413 }; }
    const bytes = await readAtMost(response, most);
    if (!bytes) return { status: 413 };
    return { status: 200, bytes, contentType: (response.headers.get("content-type") ?? "").toLowerCase(), url: at };
  }
  return { status: 310 };
}

async function readAtMost(response, most) {
  if (!response.body) { const all = new Uint8Array(await response.arrayBuffer()); return all.length > most ? null : all; }
  const reader = response.body.getReader();
  const parts = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > most) { await reader.cancel().catch(() => {}); return null; }
    parts.push(value);
  }
  const out = new Uint8Array(size);
  let offset = 0;
  for (const p of parts) { out.set(p, offset); offset += p.byteLength; }
  return out;
}

/** An answer that is an image of the kinds devices decode, or what to say about it. */
function imageAnswer(got, { smallest = 0 } = {}) {
  if (got === null) return { none: true };
  if (got.status === 404 || got.status === 410 || got.status === 403 || got.status === 413) return { none: true };
  if (got.status !== 200) return { failed: true };
  const type = sniff(got.bytes);
  if (!type) return { none: true };
  const size = dimensions(got.bytes, type);
  if (smallest && size && (size.width < smallest || size.height < smallest)) return { none: true };
  return { image: { bytes: got.bytes, type } };
}

// ---- DNS, over HTTPS (Workers has no resolver of its own) ----

/** A name's TXT records, each one string; [] when there are none; null when DNS could not be asked. */
export async function txt(fetch, name) {
  const url = `https://cloudflare-dns.com/dns-query?name=${encodeURIComponent(name)}&type=TXT`;
  let response;
  try { response = await fetch(url, { headers: { accept: "application/dns-json" }, signal: AbortSignal.timeout(TIMEOUT) }); }
  catch { return null; }
  if (!response.ok) return null;
  let body;
  try { body = await response.json(); } catch { return null; }
  if (body.Status === 3) return [];          // NXDOMAIN
  if (body.Status !== 0) return null;
  return (body.Answer ?? []).filter((a) => a.type === 16).map((a) => String(a.data ?? "")
    .split(/"\s*"/).join("").replace(/^"|"$/g, ""));
}

/** The tags of a DMARC or BIMI record ("v=BIMI1; l=https://…"), lower-cased names. */
export function tags(record) {
  const out = {};
  for (const part of record.split(";")) {
    const i = part.indexOf("=");
    if (i < 0) continue;
    out[part.slice(0, i).trim().toLowerCase()] = part.slice(i + 1).trim();
  }
  return out;
}

/**
 * Whether the domain's mail is at DMARC enforcement (quarantine or reject, for all of it): BIMI's own
 * condition for a logo, and what makes a From line at that domain hard to forge into the inbox.
 * The record of the domain itself, else the organisational domain's, whose `sp` covers subdomains.
 */
export async function dmarcEnforced(fetch, parts) {
  const own = await txt(fetch, `_dmarc.${parts.domain}`);
  if (own === null) return null;
  let record = own.find((r) => /^v=DMARC1/i.test(r)), subdomain = false;
  if (!record && parts.domain !== parts.organisation) {
    const org = await txt(fetch, `_dmarc.${parts.organisation}`);
    if (org === null) return null;
    record = org.find((r) => /^v=DMARC1/i.test(r));
    subdomain = true;
  }
  if (!record) return false;
  const t = tags(record);
  const policy = ((subdomain ? t.sp : undefined) ?? t.p ?? "").toLowerCase();
  if (policy !== "quarantine" && policy !== "reject") return false;
  return t.pct === undefined || Number(t.pct) === 100;
}

/**
 * The brand logo from BIMI: `default._bimi.<domain>`, else the organisational domain's record; its
 * `l=` is an https SVG, which is checked and drawn to a PNG. Only for a domain at DMARC enforcement.
 */
export async function bimiLogo({ fetch, rasterSvg }, parts) {
  const enforced = await dmarcEnforced(fetch, parts);
  if (enforced === null) return { failed: true };
  if (!enforced) return { none: true };
  let records = await txt(fetch, `default._bimi.${parts.domain}`);
  if (records === null) return { failed: true };
  let record = records.find((r) => /^v=BIMI1/i.test(r));
  if (!record && parts.domain !== parts.organisation) {
    records = await txt(fetch, `default._bimi.${parts.organisation}`);
    if (records === null) return { failed: true };
    record = records.find((r) => /^v=BIMI1/i.test(r));
  }
  if (!record) return { none: true };
  const location = tags(record).l;
  if (!location) return { none: true };       // "l=" empty: the domain declines a logo
  if (!rasterSvg) return { none: true };
  let got;
  try { got = await boundedGet(fetch, location, { most: MOST_SVG_BYTES, accept: "image/svg+xml" }); }
  catch { return { failed: true }; }
  if (got === null) return { none: true };
  if (got.status !== 200) return got.status >= 500 ? { failed: true } : { none: true };
  const text = new TextDecoder("utf-8", { fatal: false }).decode(got.bytes);
  if (svgProblem(text)) return { none: true };
  let png;
  try { png = await rasterSvg(text, IMAGE_PX); } catch { return { none: true }; }
  if (!png || sniff(png) !== "image/png") return { none: true };
  return { image: { bytes: png, type: "image/png" } };
}

/** Gravatar, by the address's SHA-256: `d=404` makes "no Gravatar" a 404 rather than a stock picture. */
export async function gravatar({ fetch }, addressHash) {
  try { return imageAnswer(await boundedGet(fetch, `https://gravatar.com/avatar/${addressHash}?d=404&s=${IMAGE_PX}`)); }
  catch { return { failed: true }; }
}

/**
 * The site's own icon, as the site publishes it for home screens: `/apple-touch-icon.png` at the
 * organisational domain, else the largest `apple-touch-icon` or sized `icon` its home page links.
 * Never smaller than 64 px, never a favicon.ico.
 */
export async function siteIcon({ fetch }, parts) {
  const base = `https://${parts.organisation}/`;
  try {
    const touch = imageAnswer(await boundedGet(fetch, `${base}apple-touch-icon.png`), { smallest: SMALLEST_ICON });
    if (touch.image) return touch;
    const page = await boundedGet(fetch, base, { most: MOST_PAGE_BYTES, accept: "text/html" });
    if (!page || page.status !== 200) return page && page.status >= 500 ? { failed: true } : { none: true };
    const href = bestIconLink(new TextDecoder().decode(page.bytes), page.url ?? base);
    if (!href) return { none: true };
    return imageAnswer(await boundedGet(fetch, href), { smallest: SMALLEST_ICON });
  } catch { return { failed: true }; }
}

/** The largest home-screen icon a page's head links: apple-touch-icon first, then icons with a size. */
export function bestIconLink(html, pageUrl) {
  const end = html.search(/<\/head>/i);
  const head = end > 0 ? html.slice(0, end) : html;
  const links = [];
  for (const match of head.matchAll(/<link\b[^>]*>/gi)) {
    const tag = match[0];
    const attr = (name) => new RegExp(`\\b${name}\\s*=\\s*(?:"([^"]*)"|'([^']*)'|([^\\s>]+))`, "i").exec(tag)?.slice(1).find((v) => v !== undefined);
    const rel = (attr("rel") ?? "").toLowerCase().split(/\s+/);
    const href = attr("href");
    if (!href || /\.(ico|svg)(\?|$)/i.test(href)) continue;
    const size = Math.max(0, ...String(attr("sizes") ?? "").split(/\s+/).map((s) => Number(/^(\d+)x\d+$/i.exec(s)?.[1] ?? 0)));
    if (rel.includes("apple-touch-icon") || rel.includes("apple-touch-icon-precomposed")) links.push({ href, rank: 2, size: size || 180 });
    else if (rel.includes("icon") && size >= SMALLEST_ICON) links.push({ href, rank: 1, size });
  }
  links.sort((a, b) => b.rank - a.rank || b.size - a.size);
  for (const link of links) {
    try { const url = new URL(link.href, pageUrl).toString(); if (fetchable(url)) return url; } catch { /* next */ }
  }
  return null;
}

/** A Google photo's address, asked at our size; only Google's own photo host. */
export function googlePhotoUrl(url) {
  let u;
  try { u = new URL(url); } catch { return null; }
  if (u.protocol !== "https:" || !/(^|\.)googleusercontent\.com$/i.test(u.hostname)) return null;
  u.searchParams.set("sz", String(IMAGE_PX));
  return u.toString();
}

export async function googlePhoto({ fetch }, url) {
  const at = googlePhotoUrl(url);
  if (!at) return { none: true };
  try { return imageAnswer(await boundedGet(fetch, at)); } catch { return { failed: true }; }
}
