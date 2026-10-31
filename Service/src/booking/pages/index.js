// The booking pages (docs/design/BOOKING.md §12, Service/src/booking/CONTRACT.md). Each render
// function takes a plain view and returns { status, headers, html }: server-rendered in the
// guest's zone, the CSS and script inline, two preloaded fonts, nothing else from us. The only
// outside script is Turnstile, loaded after the page has painted.

import { kit } from "./kit.js";
import { CSS } from "./style.js";
import { HEAD, SCRIPTS } from "./scripts.gen.js";
import { ALIASES, MAJOR } from "./zones.js";

const K = kit();
const { esc, href } = K;
const TURNSTILE = "https://challenges.cloudflare.com";
const FONTS = ["/book/fonts/IBMPlexMono-400.woff2", "/book/fonts/IBMPlexMono-700.woff2"];

// Compact inline artwork keeps booking pages self-contained.
import { LOGO, ICON } from "./brand.gen.js";

function nonce() {
  const b = crypto.getRandomValues(new Uint8Array(16));
  return btoa(String.fromCharCode(...b)).replace(/=+$/, "");
}

/** The security headers every page carries. */
export function headers(n, extra = {}) {
  return {
    "content-type": "text/html; charset=utf-8",
    "content-security-policy": [
      "default-src 'none'",
      `script-src 'nonce-${n}' ${TURNSTILE}`,
      "style-src 'unsafe-inline'",
      "font-src 'self'",
      "img-src 'self' data:",
      `connect-src 'self' ${TURNSTILE}`,
      `frame-src ${TURNSTILE}`,
      "form-action 'self'",
      "base-uri 'none'",
      "frame-ancestors 'none'",
    ].join("; "),
    "referrer-policy": "no-referrer",
    "x-content-type-options": "nosniff",
    "x-frame-options": "DENY",
    "cross-origin-opener-policy": "same-origin",
    "permissions-policy": "camera=(), microphone=(), geolocation=(), payment=(), usb=()",
    "x-robots-tag": "noindex",
    "cache-control": "private, no-cache",
    ...extra,
  };
}

/** JSON that is safe inside <script type="application/json">. */
export const jsonData = (value) => JSON.stringify(value)
  .replace(/</g, "\\u003c").replace(/>/g, "\\u003e").replace(/&/g, "\\u0026")
  .replace(/\u2028/g, "\\u2028").replace(/\u2029/g, "\\u2029");

const zoneOf = (view) => K.zoneOk(view?.zone) || K.zoneOk(view?.guest?.zone) || K.zoneOk(view?.type?.hostZone) || "UTC";
function localeOf(view) {
  try {
    const l = Intl.DateTimeFormat.supportedLocalesOf(String(view?.locale || ""))[0];
    return l ? new Intl.DateTimeFormat(l).resolvedOptions().locale : "en-US";
  } catch {
    return "en-US";
  }
}
// The words are English; an English locale names its variant (en-GB), any other is plain "en".
const langOf = (loc) => (/^en(-|$)/i.test(loc || "") ? loc : "en");
const known = (g) => g && g.state && g.state !== "none" && g.email && (g.name || g.state === "verified") ? g : null;
const t = (iso, f, z, loc, now) => {
  const ms = Date.parse(iso);
  const text = `${f === "w" ? `${K.when(ms, z, loc, now)} ` : `${K.day(ms, z, loc)}, `}${K.time(ms, z, loc)}`;   // "w": today 3:00 pm; "dt": Tue, Oct 21, 3:00 pm
  return `<time datetime="${esc(new Date(ms).toISOString())}" data-f="${f}">${esc(text)}</time>`;
};
/** "30 min · Google Meet · with Noor Haddad": the type, where, and who. */
const metaLine = (type, host) => [`${type.minutes} min`, ...(type.places || []).map((p) => p.label).filter(Boolean), host?.name ? `with ${host.name}` : ""]
  .filter(Boolean).map(esc).join(" · ");
const zoneLink = (z, label = "Change") =>
  `<p class="zone"><span data-zn>${esc(K.zoneName(z))}</span> · <button type="button" class="lk" id="zc" aria-label="Change time zone">${label}</button></p>`;
/** The zone picker, with the major cities in order of their offset now; the script adds this device's
 * zone and the host's above them, and searches everything else. */
function zonesDialog(now) {
  const off = (z) => { const m = K.offset(now, z), a = Math.abs(m); return { m, o: `GMT${m ? `${m < 0 ? "-" : "+"}${Math.floor(a / 60)}${a % 60 ? `:${String(a % 60).padStart(2, "0")}` : ""}` : ""}` }; };
  const list = MAJOR.map((z) => ({ z, ...off(z) })).sort((a, b) => a.m - b.m)
    .map((x) => `<li><button type="button" data-z="${esc(x.z)}">${esc(K.city(x.z))}<small>${x.o}</small></button></li>`).join("");
  return `<dialog id="zones" aria-labelledby="zt"><div class="sh zs"><header><h2 id="zt">Time zone</h2><button type="button" class="x" data-x aria-label="Close">×</button></header>` +
    `<input id="zq" type="search" placeholder="City, country or EST" aria-label="Search time zones" autocomplete="off" autocapitalize="off" spellcheck="false" enterkeyhint="search"><ul class="zl" id="zl">${list}</ul></div></dialog>`;
}
const SHEET = `<dialog id="sheet" aria-labelledby="card-t"></dialog>`;
const page = (handle, slug) => `/${encodeURIComponent(handle || "")}/${encodeURIComponent(slug || "")}`;

/** Verified guests see their next time; any recognised guest sees who is booking. */
function nextTime(guest, now) {
  const g = known(guest);
  return g && g.state === "verified" ? (g.upcoming || []).filter((u) => Date.parse(u.end || u.start) > now).sort((a, b) => Date.parse(a.start) - Date.parse(b.start))[0] || null : null;
}
function guestBars(guest, z, loc, now, { asWho = true } = {}) {
  const g = known(guest), next = nextTime(guest, now);
  if (!g) return "";
  return (next ? `<p class="bar" data-rl>Your next time: ${t(next.start, "dt", z, loc, now)} with ${esc(K.firstName(next.hostName))} · <a class="lk" href="${href(next.manageUrl)}">Change</a></p>` : "") +
    (asWho ? `<p class="bar" id="as">Booking as ${esc(g.name ? K.firstName(g.name) : g.email)} · <button type="button" class="lk" id="notyou">not you?</button></p>` : "");
}

function footer(guest) {
  return `<footer><a class="brand" href="https://bananatheapp.com">${LOGO}Banana</a><a class="lk" href="/source">Source code</a>${known(guest) ? '<a class="lk" href="/b/forget">Forget me</a>' : ""}</footer>`;
}

/** The days: a one-row strip on a phone, a month grid wider; the same buttons in both. */
const dayPickers = (ds, sel, loc) => ({
  strip: `<div class="strip" id="strip" role="group" aria-label="Days">${K.strip(ds, sel, loc)}</div>`,
  cal: `<div class="cal" id="cal" role="group" aria-label="Days">${K.cal(ds, sel, loc)}</div>`,
});
const timesGrid = (d, z, loc, cur) =>
  `<div class="grid" id="grid" role="group" aria-labelledby="day" style="--r:${Math.ceil((d ? d.s.length : 1) / 3)};--r4:${Math.ceil((d ? d.s.length : 1) / 4)}">${K.grid(d, z, loc, cur)}</div>`;

/** The whole document around a page's body. */
function shell({ title, body, data, zone, loc, status = 200, extra = {}, head = "", started }) {
  const n = nonce();
  const html = `<!doctype html><html lang="${esc(langOf(loc))}"${zone ? ` data-z="${esc(zone)}" data-l="${esc(loc)}"` : ""}><head><meta charset="utf-8">` +
    `<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover,interactive-widget=resizes-content">` +
    `<title>${esc(title)}</title><meta name="robots" content="noindex"><meta name="theme-color" content="#fbf6ea"><meta name="color-scheme" content="light">` +
    `<link rel="icon" href="${ICON}">` + FONTS.map((f) => `<link rel="preload" href="${f}" as="font" type="font/woff2" crossorigin>`).join("") +
    `<style>${CSS}</style><script nonce="${n}">${HEAD}</script>${head.replaceAll("{nonce}", n)}</head><body>${body}` +
    `<p id="live" class="sr" aria-live="polite"></p>` +
    (data ? `<script type="application/json" id="bk">${jsonData(data)}</script><script nonce="${n}">${SCRIPTS[data.p]}</script>` : "") +
    `</body></html>`;
  const timing = started ? `render;dur=${Math.max(0, Date.now() - started)}` : "render";
  return { status, headers: headers(n, { "server-timing": timing, ...extra }), html };
}

const typeData = (type) => ({ slug: type.slug, title: type.title, minutes: type.minutes, places: type.places || [], hostZone: type.hostZone });

// ---------- the pages ----------

/** GET /<handle> with several types: one row each, with its next time. */
export function profile(view) {
  const started = Date.now(), now = Date.now();
  const { host = {}, types = [], guest = null } = view || {};
  const z = zoneOf({ ...view, type: types[0] }), loc = localeOf(view);
  const rows = types.map((type) => `<li><a class="type" href="${esc(page(host.handle, type.slug))}"><span><b>${esc(type.title)}</b>` +
    `<small>${esc(type.minutes)} min · ${type.nextSlot ? `Next: ${t(type.nextSlot.start, "w", z, loc, now)}` : "No times open"}</small></span><span aria-hidden="true">›</span></a></li>`).join("");
  const body = `<main class="w narrow"><h1>${esc(host.name)}</h1>${guestBars(guest, z, loc, now, { asWho: false })}` +
    (types.length ? `<ul class="types" data-rl>${rows}</ul><div data-rl>${zoneLink(z, nextTime(guest, now) ? "Time zone" : "Change")}</div>` : '<p class="none">No times open</p>') +
    `</main>${footer(guest)}${zonesDialog(now)}`;
  const spec = `<script type="speculationrules" nonce="{nonce}">${jsonData({ prefetch: [{ where: { href_matches: `/${host.handle}/*` }, eagerness: "moderate" }] })}</script>`;
  return shell({ title: host.name || "Book", body, zone: z, loc, started, head: spec,
    data: { p: "profile", z, l: loc, h: { name: host.name, handle: host.handle }, ty: { hostZone: types[0]?.hostZone }, za: ALIASES } });
}

/** The times: Soonest first, then the days and the day's times, in the guest's zone. */
export function times(view) {
  const started = Date.now(), now = Date.now();
  const { host = {}, type = {}, slots = [], guest = null, turnstileSiteKey = null, connect = null, busy = null, csrf = "", canEmail = true } = view || {};
  const z = zoneOf(view), loc = localeOf(view), len = (type.minutes || 30) * 60000;
  const busyMs = (busy || []).map((b) => [Date.parse(b.start), Date.parse(b.end)]);
  const starts = K.free(slots.map((s) => Date.parse(s.start)).filter((s) => Number.isFinite(s)).sort((a, b) => a - b), len, busyMs);
  const ds = K.days(starts, z), first = ds[0], days = dayPickers(ds, first?.k, loc);
  const g = known(guest), base = page(host.handle, type.slug);
  const side = `<div class="side"><h1>${esc(type.title)}</h1><p class="meta">${metaLine(type, host)}</p>` + guestBars(guest, z, loc, now) +
    (first ? `<button type="button" class="btn soon" id="soon" data-s="${starts[0]}" data-rl><span>Soonest</span>${t(new Date(starts[0]).toISOString(), "w", z, loc, now)}</button>` : "") +
    `<div data-rl>${days.cal}</div></div>`;
  const main = `<div data-rl>${days.strip}<div class="row"><h2 id="day">${first ? esc(K.dayName(first.k, loc)) : ""}</h2>${zoneLink(z, nextTime(guest, now) ? "Time zone" : "Change")}</div>` +
    timesGrid(first, z, loc) + `<p class="none" id="none"${starts.length ? " hidden" : ""}>No times open</p>` +
    (busy ? `<p class="more" id="fc">Hiding your busy times</p>` : connect?.url ? `<p class="more" id="fc"><a class="lk" href="${href(connect.url)}">Only times I'm free</a></p>` : "") + `</div>`;
  const body = `<main class="w"><div class="cols">${side}${main}</div><div id="ts"></div></main>${footer(guest)}${SHEET}${zonesDialog(now)}${bookForm(type)}`;
  return shell({
    title: `${type.title || "Book"} · ${host.name || ""}`, body, zone: z, loc, started,
    data: {
      p: "times", z, l: loc, h: { name: host.name, handle: host.handle }, ty: typeData(type), mail: canEmail !== false, za: ALIASES,
      g: g ? { state: g.state, name: g.name, email: g.email, phone: g.phone || "" } : null,
      s: K.pack(starts), ts: turnstileSiteKey || null, c: csrf,
      u: { book: `${base}/book`, slots: `${base}/slots`, undo: "/b/undo", notMe: "/b/not-me" },
    },
  });
}

/** The booking form, as a <template> the script fills in: name, email, the place only when there is
 * a choice, the phone only where the host calls them, the note folded away, Turnstile above Book. */
function bookForm(type) {
  const places = type.places || [];
  const field = (name, label, attrs) => `<label${name === "phone" ? ' id="pl"' : ""}>${label}<input name="${name}" ${attrs} aria-describedby="e-${name}"><span class="err" id="e-${name}" hidden></span></label>`;
  return `<template id="tf"><form class="sh" id="f" novalidate><header><div><h2 id="card-t"></h2><p class="zone"></p></div><button type="button" class="x" data-x aria-label="Close">×</button></header>` +
    field("name", "Name", 'autocomplete="name" maxlength="80" required enterkeyhint="next"') +
    field("email", "Email", 'type="email" inputmode="email" autocomplete="email" autocapitalize="off" spellcheck="false" maxlength="254" required enterkeyhint="go"') +
    (places.length > 1 ? `<fieldset class="places"><legend>Where</legend>${places.map((p, i) => `<label class="pl"><input type="radio" name="place" value="${esc(p.id)}"${i ? "" : " checked"}><span>${esc(p.label)}</span></label>`).join("")}</fieldset>` : "") +
    (places.some((p) => p.kind === "phone_host_calls") ? field("phone", "Phone", 'type="tel" inputmode="tel" autocomplete="tel" maxlength="32" required enterkeyhint="go"') : "") +
    `<p id="nb"><button type="button" class="lk" data-note>Add a note</button></p><label id="nl" hidden>Note<textarea name="note" maxlength="1000"></textarea></label>` +
    `<p class="err" id="e-all" role="alert" hidden></p><div id="ts2"></div><button class="btn book">Book</button></form></template>`;
}

/** After a booking: the same card the sheet shows, as a page. */
export function confirmed(view) {
  const started = Date.now(), now = Date.now();
  const { host = {}, type = {}, booking = {}, guest = null, csrf = "", canEmail = true } = view || {};
  const z = zoneOf(view), loc = localeOf(view);
  const left = booking.undoMs != null ? booking.undoMs : booking.undoUntil ? Date.parse(booking.undoUntil) - now : 0;
  const undo = left > 0 ? `<div class="undo"><i style="animation-duration:${left}ms"></i><button type="button" class="btn" data-undo>Undo</button></div>` : "";
  const body = `<main class="w narrow"><div class="sh card panel" id="c" data-rl>${K.card({ booking, zone: z, loc, host, type, pending: booking.status === "pending", mail: canEmail !== false })}${undo}</div></main>${footer(guest)}`;
  const bye = `<h1>Undone</h1><p class="stack"><a class="btn" href="${esc(page(host.handle, type.slug))}">Pick another time</a></p>`;
  return shell({ title: `Booked · ${type.title || ""}`, body, zone: z, loc, started, extra: { "cache-control": "no-store" },
    data: { p: "confirmed", z, l: loc, h: { name: host.name }, ty: typeData(type), b: { ...booking, undoUntil: left > 0 ? new Date(now + left).toISOString() : null },
      c: csrf, u: { undo: "/b/undo" }, bye } });
}

/** /m/<id>.<sig>: the time they have, other times to move to with one tap, and cancel. */
export function manage(view) {
  const started = Date.now(), now = Date.now();
  const { host = {}, type = {}, booking = {}, slots = [], guest = null, csrf = "", canEmail = true } = view || {};
  const z = zoneOf(view), loc = localeOf(view);
  const cur = Date.parse(booking.start);
  const starts = [...new Set([...slots.map((s) => Date.parse(s.start)), cur].filter((s) => Number.isFinite(s) && s > now))].sort((a, b) => a - b);
  const ds = K.days(starts, z), first = ds.find((d) => d.s.includes(cur)) || ds[0], days = dayPickers(ds, first?.k, loc);
  const url = String(booking.manageUrl || "");
  // Like the times page: on a phone the card, the strip and the times; wider, the card and the month
  // grid on the left, the times and Cancel on the right.
  const side = `<div class="side"><h1>${esc(type.title)}</h1><p class="meta">${metaLine(type, host)}</p>` +
    `<div class="sh card panel" id="mine" data-rl>${K.card({ booking, zone: z, loc, host, type, head: "Your time", mail: canEmail !== false })}</div><div data-rl>${days.cal}</div></div>`;
  const main = `<div><section class="sec" id="change" data-rl>${days.strip}<div class="row"><h2 id="day">${first ? esc(K.dayName(first.k, loc)) : ""}</h2>${zoneLink(z)}</div>` +
    timesGrid(first, z, loc, cur) + `</section>` +
    `<section class="sec" id="cancel"><div class="stack"><button type="button" class="btn ghost" id="cx">Cancel time</button>` +
    `<div id="cxf" class="stack" hidden><label>Reason (optional)<textarea maxlength="1000"></textarea></label><button type="button" class="btn" id="cxgo">Cancel time</button></div></div></section></div>`;
  const body = `<main class="w"><div class="cols">${side}${main}</div></main>${footer(guest)}${SHEET}${zonesDialog(now)}`;
  const bye = `<h1 tabindex="-1">Cancelled</h1><p class="meta">${esc(K.firstName(host.name))} knows.</p><p class="stack"><a class="btn" href="${esc(page(host.handle, type.slug))}">Book another time</a></p>`;
  return shell({
    title: `${type.title || "Your time"} · ${host.name || ""}`, body, zone: z, loc, started, extra: { "cache-control": "no-store" },
    data: { p: "manage", z, l: loc, h: { name: host.name, handle: host.handle }, ty: typeData(type), mail: canEmail !== false, za: ALIASES,
      s: K.pack(starts), cur, b: booking, c: csrf, bye, u: { move: `${url}/move`, cancel: `${url}/cancel`, undo: "/b/undo" } },
  });
}

/** After a cancel. */
export function cancelled(view) {
  const started = Date.now(), now = Date.now();
  const { host = {}, type = {}, booking = {} } = view || {};
  const z = zoneOf(view), loc = localeOf(view);
  const body = `<main class="w narrow"><h1>Cancelled</h1><p class="meta" data-rl>${esc(type.title)} with ${esc(host.name)}, ${booking.start ? t(booking.start, "dt", z, loc, now) : ""}</p>` +
    `<p class="stack"><a class="btn" href="${esc(page(host.handle, type.slug))}">Book another time</a></p></main>${footer(null)}`;
  return shell({ title: "Cancelled", body, zone: z, loc, started, extra: { "cache-control": "no-store" }, data: { p: "cancelled", z, l: loc } });
}

/** A type turned off, or the host's Google link refused. */
export function notTaking(view) {
  const host = view?.host || {};
  const body = `<main class="w narrow"><h1>${esc(K.firstName(host.name) || "This person")} isn't taking bookings right now</h1></main>${footer(null)}`;
  return shell({ title: host.name || "Not taking bookings", body, started: Date.now() });
}

/** Any bad handle, slug or manage link. */
export function notFound() {
  const body = `<main class="w narrow"><h1>Nothing here</h1><p class="meta">Check the link.</p></main>${footer(null)}`;
  return shell({ title: "Nothing here", body, status: 404, started: Date.now() });
}

/** The 6-digit code: one field (paste and AutoFill work), drawn as six boxes. */
export function code(view) {
  const { email = "", csrf = "", returnTo = null } = view || {};
  const body = `<main class="w narrow"><h1>Check your email</h1><p class="meta">Code sent to ${esc(email)}</p>` +
    `<div class="code"><input id="cd" name="code" autocomplete="one-time-code" inputmode="numeric" pattern="[0-9]*" maxlength="6" aria-label="6-digit code" aria-describedby="cerr" autofocus>` +
    `<div class="bx" aria-hidden="true">${"<span></span>".repeat(6)}</div></div><p class="err" id="cerr" role="alert"></p>` +
    `<p><button type="button" class="lk" id="resend">Send a new code</button></p></main>${footer(null)}`;
  const ret = typeof returnTo === "string" && /^\/(?!\/)/.test(returnTo) ? returnTo : "/";
  return shell({ title: "Check your email", body, started: Date.now(), extra: { "cache-control": "no-store" },
    data: { p: "code", email, c: csrf, u: { verify: "/b/code/verify", code: "/b/code", ret } } });
}

/** Forget me: what it costs, in one line, and the button. */
export function forget(view) {
  const { guest = null, upcomingCount = 0, csrf = "" } = view || {};
  const n = Number(upcomingCount) || 0;
  const cost = n > 1 ? `Your ${n} upcoming times stay on the hosts' calendars. Reminders stop.`
    : n === 1 ? "Your upcoming time stays on the host's calendar. Reminders stop."
      : "Banana forgets your name, email and number.";
  const body = `<main class="w narrow"><h1>Forget me</h1><p class="meta">${esc(cost)}</p>` +
    `<p class="stack"><button type="button" class="btn" id="fg">Forget me</button></p></main>${footer(null)}`;
  return shell({ title: "Forget me", body, started: Date.now(), extra: { "cache-control": "no-store" },
    data: { p: "forget", c: csrf, g: known(guest) ? { state: guest.state } : null, u: { forget: "/b/forget" } } });
}
