#!/usr/bin/env node
// Renders every booking page with sample views, serves them with their real headers and fake
// answers for the routes the pages call, and, when Playwright is installed somewhere, screenshots
// them at 390, 768 and 1280 px, walks the main flows and runs Lighthouse on the times page.
//
//   node Service/tools/booking-preview.mjs --out DIR                 render only (check_book.py uses this)
//   node Service/tools/booking-preview.mjs --out DIR --serve         render and serve on :8787
//   node Service/tools/booking-preview.mjs --out DIR --shots --deps D
//        D holds node_modules with playwright (and lighthouse); nothing is installed into the repo.
//
// No real accounts, no real Google: every answer comes from the fake routes below.

import { createServer } from "node:http";
import { mkdirSync, writeFileSync, readFileSync, existsSync } from "node:fs";
import { join, dirname, resolve, extname } from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";
import { execFileSync } from "node:child_process";
import * as pages from "../src/booking/pages/index.js";
import { kit } from "../src/booking/pages/kit.js";

const K = kit();
const HERE = dirname(fileURLToPath(import.meta.url));
const PUBLIC = resolve(HERE, "../public");
const arg = (name, fallback = null) => { const i = process.argv.indexOf(name); return i > 0 ? process.argv[i + 1] : fallback; };
const flag = (name) => process.argv.includes(name);
const OUT = resolve(arg("--out", join(process.env.TMPDIR || "/tmp", "booking-preview")));
const PORT = Number(arg("--port", "8787"));
const TEST_SITEKEY = "1x00000000000000000000AA";   // Cloudflare's always-passes test key

// ---------- sample data ----------

const MIN = 60000, DAY = 86400000;
/** Weekday slots on the host's wall clock, from `fromDay` days ahead, for `days` days. */
function hostSlots(zone, { days = 30, from = 9 * 60, to = 17 * 60, step = 30, minutes = 30, skip = () => false, startAt = Date.now(), weekends = false } = {}) {
  const out = [];
  const today = K.key(startAt, zone);
  for (let n = 0; n < days; n++) {
    const k = K.step(today, n), [y, mo, d] = k.split("-").map(Number);
    const wd = new Date(Date.UTC(y, mo - 1, d, 12)).getUTCDay();
    if (!weekends && (wd === 0 || wd === 6)) continue;
    for (let m = from; m + minutes <= to; m += step) {
      let t = Date.UTC(y, mo - 1, d, 0, m);
      t -= K.offset(t, zone) * MIN;
      t = Date.UTC(y, mo - 1, d, 0, m) - K.offset(t, zone) * MIN;   // again, across a change
      if (t < startAt + 4 * 3600000 || skip(t)) continue;
      out.push({ start: new Date(t).toISOString(), end: new Date(t + minutes * MIN).toISOString() });
    }
  }
  return out;
}

const host = { handle: "noor", name: "Noor Haddad", photoUrl: null };
const MEET = { id: "meet", kind: "meet", label: "Google Meet" };
const ZOOM = { id: "zoom", kind: "zoom", label: "Zoom" };
const PHONE = { id: "phone", kind: "phone_host_calls", label: "Phone call" };
const THEY_CALL = { id: "call", kind: "phone_guest_calls", label: "Call Noor" };
const ROOM = { id: "addr", kind: "in_person", label: "In person", address: "61 Wythe Ave, Brooklyn" };
const NY = "America/New_York";
const intro = (extra = {}) => ({ slug: "intro", title: "Intro call", minutes: 30, places: [MEET], hostZone: NY, nextSlot: null, ...extra });
const slotsNY = hostSlots(NY);
const none = { state: "none" };
const sam = { state: "remembered", name: "Sam Lee", email: "sam@example.com", phone: "+1 917 555 0142", zone: "Asia/Tokyo" };
const verified = (manage) => ({ ...sam, state: "verified", zone: "Europe/London",
  upcoming: [{ manageUrl: manage, hostName: "Ana Ruiz", title: "Design review", start: slotsNY[6].start, end: slotsNY[6].end }] });
const bookingOf = (slot, place, extra = {}) => ({
  start: slot.start, end: slot.end, place, placeDetail: null, manageUrl: "/m/9f2c4e.sig", icsUrl: "/b/9f2c4e.ics?sig=x",
  guestEmail: "sam@example.com", undoUntil: null, status: "confirmed", ...extra,
});
// The week the clocks change: UK on 25 Oct 2026, US on 1 Nov 2026.
const dstSlots = hostSlots(NY, { startAt: Date.UTC(2026, 9, 21, 12), days: 16 });
const common = { turnstileSiteKey: TEST_SITEKEY, csrf: "csrf-preview", connect: { url: "/b/connect?return=/noor/intro" }, busy: null };

export const VIEWS = {
  "times-ny-none": ["times", { ...common, host, type: intro(), slots: slotsNY, guest: none, zone: NY }],
  "times-tokyo-remembered": ["times", { ...common, host, type: intro(), slots: slotsNY, guest: sam, zone: "Asia/Tokyo" }],
  "times-london-verified-busy": ["times", { locale: "en-GB", ...common, host, type: intro(), slots: slotsNY, guest: verified("/m/77aa.sig"), zone: "Europe/London", connect: null,
    busy: [{ start: slotsNY[1].start, end: slotsNY[3].end }] }],
  "times-kathmandu-places": ["times", { ...common, host, type: intro({ title: "Studio visit", minutes: 45, places: [MEET, ZOOM, PHONE, ROOM] }),
    slots: hostSlots(NY, { step: 45, minutes: 45 }), guest: none, zone: "Asia/Kathmandu" }],
  "times-dst-london": ["times", { ...common, host, type: intro(), slots: dstSlots, guest: none, zone: "Europe/London" }],
  "times-phone-remembered": ["times", { ...common, host, type: intro({ title: "Quick call", minutes: 15, places: [PHONE] }), slots: hostSlots(NY, { step: 15, minutes: 15 }), guest: sam, zone: NY }],
  "times-empty": ["times", { ...common, host, type: intro(), slots: [], guest: none, zone: NY }],
  "times-xss": ["times", { ...common, host: { handle: "x", name: "<script>alert(1)</script>Eve" }, type: intro({ title: "<img src=x onerror=alert(1)>" }), slots: slotsNY.slice(0, 4),
    guest: { state: "remembered", name: "</script><script>alert(2)</script>", email: "a@b.co" }, zone: NY }],
  "profile": ["profile", { host, zone: NY, guest: none, types: [
    intro({ nextSlot: slotsNY[0] }), intro({ slug: "deep", title: "Deep dive", minutes: 60, nextSlot: slotsNY[4] }), intro({ slug: "coffee", title: "Coffee", minutes: 30, places: [ROOM], nextSlot: null })] }],
  "profile-verified-tokyo": ["profile", { host, zone: "Asia/Tokyo", guest: verified("/m/77aa.sig"), types: [intro({ nextSlot: slotsNY[0] }), intro({ slug: "deep", title: "Deep dive", minutes: 60, nextSlot: slotsNY[4] })] }],
  "confirmed-meet-undo": ["confirmed", { host, type: intro(), zone: "Asia/Tokyo", guest: sam, csrf: "c",
    booking: bookingOf(slotsNY[2], MEET, { placeDetail: "https://meet.google.com/abc-defg-hij", undoUntil: new Date(Date.now() + 600000).toISOString() }) }],
  "confirmed-invite-failed": ["confirmed", { host, type: intro(), zone: NY, guest: sam, canEmail: true, booking: bookingOf(slotsNY[2], MEET, { invite: "failed", placeDetail: "https://meet.google.com/abc-defg-hij" }) }],
  "times-weekends-gb": ["times", { ...common, host, type: intro({ title: "Weekend walk", minutes: 60, places: [ROOM] }), slots: hostSlots("Europe/London", { weekends: true, step: 60, minutes: 60, from: 600, to: 960 }), guest: none, zone: "Europe/London", locale: "en-GB" }],
  "confirmed-phone": ["confirmed", { host, type: intro({ places: [PHONE] }), zone: NY, guest: sam, booking: bookingOf(slotsNY[2], PHONE, { placeDetail: "+1 917 555 0142" }) }],
  "confirmed-they-call": ["confirmed", { host, type: intro({ places: [THEY_CALL] }), zone: "Europe/Berlin", guest: sam, booking: bookingOf(slotsNY[2], THEY_CALL, { placeDetail: "+1 646 555 0199" }) }],
  "confirmed-in-person": ["confirmed", { host, type: intro({ places: [ROOM] }), zone: NY, guest: sam, booking: bookingOf(slotsNY[2], ROOM, { placeDetail: ROOM.address }) }],
  "confirmed-zoom-pending": ["confirmed", { host, type: intro({ places: [ZOOM] }), zone: "America/Los_Angeles", guest: none, booking: bookingOf(slotsNY[2], ZOOM, { status: "pending" }) }],
  "manage": ["manage", { host, type: intro(), zone: "Asia/Tokyo", guest: sam, csrf: "c", slots: slotsNY,
    booking: bookingOf(slotsNY[5], MEET, { placeDetail: "https://meet.google.com/abc-defg-hij", manageUrl: "/m/9f2c4e.sig" }) }],
  "cancelled": ["cancelled", { host, type: intro(), zone: NY, booking: bookingOf(slotsNY[5], MEET) }],
  "not-taking": ["notTaking", { host }],
  "not-found": ["notFound", undefined],
  "code": ["code", { email: "sam@example.com", csrf: "c", returnTo: "/p/times-ny-none" }],
  "forget": ["forget", { guest: sam, upcomingCount: 2, csrf: "c" }],
  "forget-none": ["forget", { guest: sam, upcomingCount: 0, csrf: "c" }],
};

// ---------- render ----------

export function renderAll(out = OUT) {
  mkdirSync(out, { recursive: true });
  const index = [];
  for (const [name, [fn, view]] of Object.entries(VIEWS)) {
    const r = pages[fn](view);
    writeFileSync(join(out, `${name}.html`), r.html);
    writeFileSync(join(out, `${name}.headers.json`), JSON.stringify({ status: r.status, headers: r.headers }));
    index.push(name);
  }
  writeFileSync(join(out, "index.json"), JSON.stringify(index));
  return index;
}

// ---------- serve, with fake routes ----------

const TYPES = {};
const sent = (res, status, body, type = "application/json") => { res.writeHead(status, { "content-type": type }); res.end(body == null ? "" : typeof body === "string" ? body : JSON.stringify(body)); };
function serve(out) {
  const taken = new Set();
  return createServer((req, res) => {
    const url = new URL(req.url, "http://x");
    let body = "";
    req.on("data", (c) => { body += c; });
    req.on("end", () => {
      const json = body ? JSON.parse(body) : {};
      const p = url.pathname;
      const later = (ms, f) => setTimeout(f, ms);
      if (p.startsWith("/book/")) {
        const file = join(PUBLIC, p);
        if (!existsSync(file)) return sent(res, 404, "");
        res.writeHead(200, { "content-type": extname(file) === ".woff2" ? "font/woff2" : "text/plain", "cache-control": "public, max-age=31536000, immutable" });
        return res.end(readFileSync(file));
      }
      if (p.startsWith("/p/")) {
        const name = p.slice(3).replace(/\.html$/, "");
        if (!existsSync(join(out, `${name}.html`))) return sent(res, 404, "nope", "text/plain");
        // Re-rendered on each load, so "now" and the nonce are fresh.
        const [fn, view] = VIEWS[name];
        const r = pages[fn](view);
        res.writeHead(r.status, r.headers);
        return res.end(r.html);
      }
      if (/^\/[^/]+\/[^/]+\/book$/.test(p) && req.method === "POST") {
        // The second time of any day is "taken" once, to show the nearest times.
        const ms = Date.parse(json.start), day = K.key(ms, json.zone || "UTC");
        const ofDay = slotsNY.map((s) => Date.parse(s.start)).filter((s) => K.key(s, json.zone || "UTC") === day);
        if (ofDay.indexOf(ms) === 1 && !taken.has(ms)) {
          taken.add(ms);
          const near = slotsNY.filter((s) => Date.parse(s.start) > ms).slice(1, 4);
          return later(250, () => sent(res, 409, { taken: true, nearest: near }));
        }
        if (!json.name || !/@/.test(json.email || "")) return later(150, () => sent(res, 400, { field: json.name ? "email" : "name", error: "invalid" }));
        const place = (json.place && [MEET, ZOOM, PHONE, ROOM, THEY_CALL].find((x) => x.id === json.place)) || MEET;
        const booking = { start: json.start, end: new Date(ms + 30 * MIN).toISOString(), place, placeDetail: place.kind === "phone_host_calls" ? json.phone : place.kind === "in_person" ? place.address : null,
          manageUrl: "/m/9f2c4e.sig", icsUrl: "/b/9f2c4e.ics?sig=x", guestEmail: json.email, undoUntil: new Date(Date.now() + 5000).toISOString(), undoMs: 5000,
          status: "pending", invite: "held", meet: place.kind === "meet" ? "pending" : null, statusUrl: `/b/status/9f2c4e?place=${place.id}` };
        TYPES.last = booking;
        return later(220, () => sent(res, 200, { booking }));
      }
      if (p.startsWith("/b/status/")) {
        const b = TYPES.last || {};
        const link = { meet: "https://meet.google.com/abc-defg-hij", zoom: "https://zoom.us/j/5551234567" }[url.searchParams.get("place")] || b.placeDetail;
        return sent(res, 200, { booking: { ...b, status: "confirmed", invite: "sent", meet: b.meet ? "ready" : null, undoMs: 0, placeDetail: link } });
      }
      if (p === "/b/undo" || p === "/b/forget" || p === "/b/code" || p === "/b/not-me" || /\/cancel$/.test(p)) return later(120, () => sent(res, 204, null));
      if (/\/move$/.test(p)) {
        const ms = Date.parse(json.start);
        // As the route answers: the moved booking, with the service's own Undo window for the move.
        return later(200, () => sent(res, 200, { booking: { start: json.start, end: new Date(ms + 30 * MIN).toISOString(), status: "confirmed", invite: "sent",
          undoMs: 5000, undoes: "move", undoUntil: new Date(Date.now() + 5000).toISOString() } }));
      }
      if (p === "/b/code/verify") return later(150, () => sent(res, json.code === "123456" ? 204 : 400, null));
      if (/\/slots$/.test(p)) return sent(res, 200, { slots: slotsNY, busy: [] });
      if (p === "/" || p === "/index.html") {
        const list = JSON.parse(readFileSync(join(out, "index.json"), "utf8"));
        return sent(res, 200, `<!doctype html><meta charset=utf-8><title>Booking preview</title><ul>${list.map((n) => `<li><a href="/p/${n}">${n}</a>`).join("")}</ul>`, "text/html");
      }
      const notFound = pages.notFound();
      res.writeHead(404, notFound.headers);
      res.end(notFound.html);
    });
  }).listen(PORT);
}

// ---------- screenshots, flows and Lighthouse ----------

const WIDTHS = [[390, 844, true], [768, 1024, true], [1280, 860, false]];

async function shots(out, deps) {
  const req = createRequire(join(resolve(deps), "noop.js"));
  const { chromium } = req("playwright");
  const dir = join(out, "shots");
  mkdirSync(dir, { recursive: true });
  const browser = await chromium.launch();
  const errors = [];
  const base = `http://localhost:${PORT}`;
  const newPage = async ([w, h, mobile], opts = {}) => {
    const ctx = await browser.newContext({ viewport: { width: w, height: h }, deviceScaleFactor: 2, isMobile: mobile, hasTouch: mobile, timezoneId: opts.tz || "America/New_York", locale: opts.locale || "en-US", reducedMotion: "reduce" });
    const page = await ctx.newPage();
    page.on("pageerror", (e) => errors.push(`${opts.name}: ${e.message}`));
    page.on("console", (m) => { if (m.type() === "error" && !/challenges\.cloudflare|turnstile|Private Access Token|preloaded using link preload/i.test(m.text())) errors.push(`${opts.name}: ${m.text()}`); });
    return page;
  };
  // Each page at each width, the browser in the zone the server rendered for.
  const zoneOfView = (name) => VIEWS[name][1]?.zone || NY;
  for (const name of Object.keys(VIEWS)) {
    for (const size of WIDTHS) {
      const page = await newPage(size, { name, tz: zoneOfView(name) });
      await page.goto(`${base}/p/${name}`, { waitUntil: "load" }).catch(() => {}); await page.waitForTimeout(250);
      await page.screenshot({ path: join(dir, `${name}-${size[0]}.png`), fullPage: true });
      await page.context().close();
    }
  }
  // Flows, at phone width.
  const phone = WIDTHS[0];
  const flow = async (name, tz, steps) => {
    const page = await newPage(phone, { name, tz });
    await page.goto(`${base}/p/${name.split(":")[0]}`, { waitUntil: "load" }).catch(() => {}); await page.waitForTimeout(250);
    let n = 0;
    for (const [label, act] of steps) {
      await act(page);
      await page.screenshot({ path: join(dir, `flow-${name.replace(/[:]/g, "-")}-${++n}-${label}.png`) });
    }
    await page.context().close();
  };
  const settle = (ms) => (page) => page.waitForTimeout(ms);
  // The browser is in Tokyo but the server rendered New York: relabelled before anything shows.
  await flow("times-ny-none:vpn", "Asia/Tokyo", [["relabelled", settle(50)]]);
  await flow("times-ny-none", NY, [
    ["sheet", (p) => p.locator("#grid .t").first().click()],
    ["filled", async (p) => { await p.fill("input[name=name]", "Sam Lee"); await p.fill("input[name=email]", "sam@example.com"); }],
    ["booked", async (p) => { await p.click(".book"); await p.waitForTimeout(400); }],
    ["invite-sent", settle(7000)],
  ]);
  await flow("times-ny-none:taken", NY, [
    ["sheet", (p) => p.locator("#grid .t").nth(1).click()],
    ["nearest", async (p) => { await p.fill("input[name=name]", "Sam Lee"); await p.fill("input[name=email]", "sam@example.com"); await p.click(".book"); await p.waitForTimeout(500); }],
    ["rebooked", async (p) => { await p.locator("[data-n]").first().click(); await p.waitForTimeout(500); }],
  ]);
  await flow("times-ny-none:errors", NY, [["errors", async (p) => { await p.locator("#grid .t").first().click(); await p.click(".book"); }]]);
  await flow("times-tokyo-remembered", "Asia/Tokyo", [
    ["one-tap", async (p) => { await p.click("#soon"); await p.waitForTimeout(30); }],
    ["held", settle(500)],
    ["undone", async (p) => { await p.click("[data-undo]"); await p.waitForTimeout(100); }],
  ]);
  await flow("times-kathmandu-places", "Asia/Kathmandu", [
    ["day-3", (p) => p.locator("#strip .d:not(:disabled)").nth(2).click()],
    ["sheet-places", (p) => p.locator("#grid .t").first().click()],
    ["phone-place", (p) => p.locator(".pl span", { hasText: "Phone call" }).click()],
    ["note", (p) => p.click("[data-note]")],
  ]);
  await flow("times-ny-none:zones", NY, [
    ["picker", (p) => p.click("#zc")],
    ["alias", (p) => p.fill("#zq", "pst")],
    ["india", (p) => p.fill("#zq", "india")],
    ["search", (p) => p.fill("#zq", "kath")],
    ["picked", async (p) => { await p.locator("#zl button").first().click(); await p.waitForTimeout(50); }],
  ]);
  await flow("manage", "Asia/Tokyo", [
    ["moved", async (p) => { await p.locator("#grid button.t").first().click(); await p.waitForTimeout(400); }],
    ["undo-move", async (p) => { await p.click("[data-undo]"); await p.waitForTimeout(400); }],
    ["moved-again", async (p) => { await p.locator("#grid button.t").first().click(); await p.waitForTimeout(400); }],
    ["closed", async (p) => { await p.locator("#sheet [data-x]").click(); }],
    ["cancel", async (p) => { await p.click("#cx"); }],
    ["cancelled", async (p) => { await p.click("#cxgo"); await p.waitForTimeout(300); }],
  ]);
  await flow("code", NY, [["typed", (p) => p.fill("#cd", "12345")], ["wrong", async (p) => { await p.fill("#cd", "123450"); await p.waitForTimeout(300); }]]);
  await flow("forget", NY, [["done", async (p) => { await p.click("#fg"); await p.waitForTimeout(300); }]]);
  await flow("confirmed-meet-undo", "Asia/Tokyo", [["undone", async (p) => { await p.click("[data-undo]"); await p.waitForTimeout(100); }]]);

  // Interaction timing: tap to "Booked" on screen, in the page's own clock.
  const page = await newPage(phone, { name: "timing", tz: "Asia/Tokyo" });
  await page.goto(`${base}/p/times-tokyo-remembered`, { waitUntil: "load" });
  const tap = await page.evaluate(() => new Promise((res) => {
    const t0 = performance.now();
    document.getElementById("soon").click();
    requestAnimationFrame(() => res({ booked: !!document.querySelector("#c"), ms: performance.now() - t0 }));
  }));
  await page.context().close();
  await browser.close();
  return { errors, tap, dir, chrome: chromium.executablePath() };
}

function lighthouse(deps, chrome, out) {
  const bin = join(resolve(deps), "node_modules/.bin/lighthouse");
  if (!existsSync(bin)) return null;
  const results = {};
  for (const name of ["times-ny-none", "times-tokyo-remembered", "profile", "manage", "confirmed-meet-undo"]) {
    const file = join(out, `lighthouse-${name}.json`);
    try {
      execFileSync(bin, [`http://localhost:${PORT}/p/${name}`, "--quiet", "--output=json", `--output-path=${file}`, "--only-categories=performance,accessibility",
        "--form-factor=mobile", `--chrome-flags=--headless=new --no-sandbox`], { env: { ...process.env, CHROME_PATH: chrome }, stdio: "pipe", timeout: 180000 });
      const j = JSON.parse(readFileSync(file, "utf8")), a = j.audits;
      results[name] = { performance: Math.round(j.categories.performance.score * 100), accessibility: Math.round(j.categories.accessibility.score * 100),
        fcp: a["first-contentful-paint"].displayValue, lcp: a["largest-contentful-paint"].displayValue, tbt: a["total-blocking-time"].displayValue,
        cls: a["cumulative-layout-shift"].displayValue, si: a["speed-index"].displayValue, requests: a["network-requests"]?.details?.items?.length,
        failing: j.categories.accessibility.auditRefs.filter((r) => a[r.id] && a[r.id].score !== null && a[r.id].score < 1).map((r) => r.id) };
    } catch (e) {
      results[name] = { error: String(e.message).slice(0, 300) };
    }
  }
  return results;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const list = renderAll(OUT);
  console.log(`rendered ${list.length} pages into ${OUT}`);
  if (flag("--serve") || flag("--shots")) {
    const server = serve(OUT);
    console.log(`serving http://localhost:${PORT}/`);
    if (flag("--shots")) {
      const deps = arg("--deps", process.env.BOOKING_PREVIEW_DEPS || dirname(OUT));
      const r = await shots(OUT, deps);
      console.log(`screenshots in ${r.dir}`);
      console.log(`tap to Booked on screen: ${r.tap.ms.toFixed(1)} ms (card shown: ${r.tap.booked})`);
      console.log(r.errors.length ? `page errors:\n  ${r.errors.join("\n  ")}` : "no page errors");
      if (!flag("--no-lighthouse")) {
        const lh = lighthouse(deps, r.chrome, OUT);
        if (lh) { console.log("lighthouse (mobile):"); for (const [k, v] of Object.entries(lh)) console.log(`  ${k}: ${JSON.stringify(v)}`); }
        else console.log("lighthouse not installed in --deps; skipped");
      }
      server.close();
    }
  }
}
