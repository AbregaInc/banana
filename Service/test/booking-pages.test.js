// The booking pages (src/booking/pages): every render function, escaping, the CSP nonce, nothing
// loaded from elsewhere but Turnstile, times in the guest's zone (a DST week, +05:45, a guest 13 h
// away), the page script's budget, and that the minified scripts come from the current sources.

import { test } from "node:test";
import assert from "node:assert/strict";
import vm from "node:vm";
import { gzipSync } from "node:zlib";
import { readFileSync } from "node:fs";
import * as pages from "../src/booking/pages/index.js";
import { jsonData } from "../src/booking/pages/index.js";
import { kit } from "../src/booking/pages/kit.js";
import { SCRIPTS, HEAD, KIT, SOURCE } from "../src/booking/pages/scripts.gen.js";
import { sources } from "../src/booking/pages/sources.js";
import { hashOf } from "../tools/build-book-scripts.mjs";
import { CSS } from "../src/booking/pages/style.js";

const K = kit();
const gz = (s) => gzipSync(s, { level: 9 }).length;
const MIN = 60000;
const NY = "America/New_York";
const MEET = { id: "meet", kind: "meet", label: "Google Meet" };
const PHONE = { id: "phone", kind: "phone_host_calls", label: "Phone call" };
const ROOM = { id: "addr", kind: "in_person", label: "In person", address: "61 Wythe Ave, Brooklyn" };
const host = { handle: "noor", name: "Noor Haddad", photoUrl: null };
const type = (extra = {}) => ({ slug: "intro", title: "Intro call", minutes: 30, places: [MEET], hostZone: NY, nextSlot: null, ...extra });
const slot = (iso, minutes = 30) => ({ start: new Date(iso).toISOString(), end: new Date(Date.parse(iso) + minutes * MIN).toISOString() });

/** A host's weekday 9–5 in New York, as UTC slots, from a day for `days` days (2030, so always ahead). */
function nineToFive(from = Date.UTC(2030, 9, 21), days = 30) {
  const out = [];
  for (let n = 0; n < days; n++) {
    const k = K.step(K.key(from, NY), n), [y, m, d] = k.split("-").map(Number);
    const wd = new Date(Date.UTC(y, m - 1, d, 12)).getUTCDay();
    if (wd === 0 || wd === 6) continue;
    for (let w = 540; w < 1020; w += 30) {
      const guess = Date.UTC(y, m - 1, d, 0, w);
      const t = guess - K.offset(guess - K.offset(guess, NY) * MIN, NY) * MIN;
      out.push(slot(new Date(t).toISOString()));
    }
  }
  return out;
}
const SLOTS = nineToFive();
const sam = { state: "remembered", name: "Sam Lee", email: "sam@example.com", phone: "+1 917 555 0142", zone: "Asia/Tokyo" };
const booking = (s = SLOTS[3], extra = {}) => ({ start: s.start, end: s.end, place: MEET, placeDetail: "https://meet.google.com/abc-defg-hij",
  manageUrl: "/m/9f2c4e.sig", icsUrl: "/b/9f2c4e.ics?sig=x", statusUrl: "/m/9f2c4e.sig/state", guestEmail: "sam@example.com", undoUntil: null,
  status: "confirmed", invite: "sent", meet: "ready", ...extra });

const SAMPLES = {
  profile: { host, zone: NY, locale: "en-US", guest: null, types: [type({ nextSlot: SLOTS[0] }), type({ slug: "deep", title: "Deep dive", minutes: 60, nextSlot: null })] },
  times: { host, type: type(), slots: SLOTS, guest: null, zone: NY, locale: "en-US", turnstileSiteKey: "1x00000000000000000000AA", connect: { url: "/b/connect?return=/noor/intro" }, busy: null, csrf: "c" },
  confirmed: { host, type: type(), booking: booking(), guest: sam, zone: "Asia/Tokyo" },
  manage: { host, type: type(), booking: booking(), slots: SLOTS, guest: sam, csrf: "c", zone: "Asia/Tokyo" },
  cancelled: { host, type: type(), booking: booking(), zone: NY },
  notTaking: { host },
  notFound: undefined,
  code: { email: "sam@example.com", csrf: "c", returnTo: "/noor/intro" },
  forget: { guest: sam, upcomingCount: 2, csrf: "c" },
};

const scriptsOf = (html) => [...html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/g)].map((m) => ({ attrs: m[1], body: m[2] }));

test("every page in CONTRACT.md renders, with its status and security headers", () => {
  const contract = readFileSync(new URL("../src/booking/CONTRACT.md", import.meta.url), "utf8");
  for (const name of [...contract.matchAll(/^\| `(\w+)\(/gm)].map((m) => m[1])) assert.equal(typeof pages[name], "function", `${name} is exported`);
  for (const [name, view] of Object.entries(SAMPLES)) {
    const r = pages[name](view);
    assert.equal(r.status, name === "notFound" ? 404 : 200, name);
    assert.match(r.html, /^<!doctype html><html lang="en(-[A-Z]{2})?"/, name);
    assert.match(r.html, /<\/body><\/html>$/, name);
    const h = r.headers;
    assert.equal(h["content-type"], "text/html; charset=utf-8");
    assert.equal(h["referrer-policy"], "no-referrer");
    assert.equal(h["x-content-type-options"], "nosniff");
    assert.match(h["content-security-policy"], /frame-ancestors 'none'/);
    assert.match(h["content-security-policy"], /default-src 'none'/);
    assert.match(h["content-security-policy"], /base-uri 'none'/);
  }
});

test("every script carries the response's nonce, and the nonce changes per response", () => {
  const seen = new Set();
  for (const [name, view] of Object.entries(SAMPLES)) {
    const r = pages[name](view);
    const nonce = /'nonce-([A-Za-z0-9+/]+)'/.exec(r.headers["content-security-policy"])?.[1];
    assert.ok(nonce && nonce.length >= 20, `${name} has a nonce`);
    assert.ok(!seen.has(nonce), "fresh per response");
    seen.add(nonce);
    for (const s of scriptsOf(r.html)) {
      if (/type="application\/json"/.test(s.attrs)) continue;   // data, never run
      assert.match(s.attrs, new RegExp(`nonce="${nonce.replace(/[+/]/g, "\\$&")}"`), `${name}: a script without the nonce`);
    }
  }
});

test("nothing is loaded from elsewhere except Turnstile", () => {
  for (const [name, view] of Object.entries(SAMPLES)) {
    const r = pages[name](view);
    const csp = r.headers["content-security-policy"];
    for (const host of csp.match(/https?:\/\/[^\s;]+/g) || []) assert.equal(host, "https://challenges.cloudflare.com", `${name} CSP`);
    for (const m of r.html.matchAll(/<(script|link|img|iframe|source|video|audio)\b[^>]*\b(src|href)="([^"]*)"/g)) {
      assert.ok(m[3].startsWith("/") || m[3].startsWith("data:"), `${name}: <${m[1]}> loads ${m[3]}`);
    }
    assert.ok(!/<img\b/.test(r.html), `${name} has no images`);
    assert.match(r.html, /<svg viewBox="0 0 48 48"/, `${name}: the logo is inline`);
  }
  // The scripts: Turnstile is the only thing they load; Google Maps is a link they may draw.
  for (const [name, src] of Object.entries(SCRIPTS)) {
    for (const url of src.match(/https?:\/\/[^"' ]+/g) || []) {
      assert.ok(url.startsWith("https://challenges.cloudflare.com/turnstile/") || url.startsWith("https://www.google.com/maps/") || url === "https://",
        `${name} script mentions ${url}`);
    }
  }
});

test("names, titles, notes and links from people are escaped everywhere", () => {
  const evil = "</script><script>alert(1)</script><img src=x onerror=alert(2)>\"'&";
  const views = {
    profile: { host: { handle: "x", name: evil }, types: [type({ title: evil, nextSlot: SLOTS[0] })], guest: { state: "verified", name: evil, email: "a@b.co", upcoming: [{ manageUrl: "javascript:alert(3)", hostName: evil, title: evil, start: SLOTS[1].start, end: SLOTS[1].end }] }, zone: NY },
    times: { ...SAMPLES.times, host: { handle: "x", name: evil }, type: type({ title: evil, places: [MEET, { id: evil, kind: "link", label: evil }] }), guest: { state: "remembered", name: evil, email: "a@b.co", phone: evil } },
    confirmed: { ...SAMPLES.confirmed, host: { name: evil }, type: type({ title: evil }), booking: booking(SLOTS[3], { placeDetail: "javascript:alert(4)", guestEmail: evil, place: { id: "l", kind: "link", label: evil } }) },
    manage: { ...SAMPLES.manage, host: { name: evil, handle: evil }, type: type({ title: evil }), booking: booking(SLOTS[3], { place: { id: "a", kind: "in_person", label: evil, address: evil }, placeDetail: evil, manageUrl: "/m/x\"><script>.sig" }) },
    cancelled: { host: { name: evil, handle: evil }, type: type({ title: evil, slug: evil }), booking: booking() },
    notTaking: { host: { name: evil } },
    code: { email: evil, csrf: evil, returnTo: "//evil.example" },
    forget: { guest: { state: "verified", name: evil, email: evil }, upcomingCount: evil, csrf: evil },
  };
  for (const [name, view] of Object.entries(views)) {
    const { html } = pages[name](view);
    assert.ok(!html.includes("<script>alert"), `${name}: raw script`);
    assert.ok(!html.includes("<img src=x"), `${name}: raw img`);
    assert.ok(!/href="javascript:/i.test(html), `${name}: javascript: link`);
    assert.ok(!html.includes('"><script>'), `${name}: attribute breakout`);
    const scripts = scriptsOf(html);
    for (const s of scripts) assert.ok(!/<\/script|<!--/i.test(s.body), `${name}: a script body could end early`);
    const data = scripts.find((s) => /application\/json/.test(s.attrs));
    if (data) assert.doesNotThrow(() => JSON.parse(data.body), `${name}: data is JSON`);
  }
  // The code page sends people back only to this site.
  assert.match(pages.code(views.code).html, /"ret":"\/"/);
  assert.equal(jsonData({ a: "</script><!--\u2028" }), '{"a":"\\u003c/script\\u003e\\u003c!--\\u2028"}');
});

test("times are rendered in the guest's zone, grouped by their own day, whatever the server's zone", () => {
  const before = process.env.TZ;
  try {
    for (const tz of ["UTC", "America/New_York", "Pacific/Chatham"]) {
      process.env.TZ = tz;
      // +05:45: New York's 9:00 on Mon 21 Oct 2030 (EDT) is 18:45 in Kathmandu.
      const kt = pages.times({ ...SAMPLES.times, zone: "Asia/Kathmandu" }).html;
      assert.match(kt, /<h2 id="day">Mon, Oct 21<\/h2>/, tz);
      assert.match(kt, /data-s="1918818000000">6:45\u00a0pm</, tz);
      assert.match(kt, /<span data-zn>Kathmandu time<\/span>/, tz);
      assert.equal(K.offset(Date.UTC(2030, 9, 21), "Asia/Kathmandu"), 345);
      assert.equal(K.offset(Date.UTC(2030, 0, 15), "Pacific/Chatham"), 825);   // +13:45 in its summer

      // A guest 13 hours ahead: New York's Tue 9–5 is Tokyo's Tue 10 pm to Wed 5:30 am.
      const tue = SLOTS.filter((s) => K.key(s.start, NY) === "2030-10-22");
      const days = K.days(tue.map((s) => Date.parse(s.start)), "Asia/Tokyo");
      assert.deepEqual(days.map((d) => [d.k, d.s.length]), [["2030-10-22", 4], ["2030-10-23", 12]], tz);
      const tokyo = pages.times({ ...SAMPLES.times, slots: tue, zone: "Asia/Tokyo" }).html;
      assert.match(tokyo, /<h2 id="day">Tue, Oct 22<\/h2>/);
      assert.match(tokyo, /class="t" data-s="\d+">10:00\u00a0pm</);
      assert.match(tokyo, /data-k="2030-10-23" aria-pressed="false" tabindex="-1"><small>Wed<\/small> 23<span class="sr"> October<\/span>/);

      // The week the clocks change (UK 27 Oct 2030, US 3 Nov 2030): 9:00 in New York stays 9:00 there,
      // and moves in London as each side changes.
      const fri = SLOTS.find((s) => K.key(s.start, NY) === "2030-11-01"), mon = SLOTS.find((s) => K.key(s.start, NY) === "2030-11-04");
      assert.equal(fri.start, "2030-11-01T13:00:00.000Z");
      assert.equal(mon.start, "2030-11-04T14:00:00.000Z");
      assert.equal(K.time(fri.start, NY, "en-US"), "9:00\u00a0am");
      assert.equal(K.time(mon.start, NY, "en-US"), "9:00\u00a0am");
      assert.equal(K.time(fri.start, "Europe/London", "en-US"), "1:00\u00a0pm");
      assert.equal(K.time(mon.start, "Europe/London", "en-US"), "2:00\u00a0pm");
      const oct25 = SLOTS.find((s) => K.key(s.start, NY) === "2030-10-25"), oct28 = SLOTS.find((s) => K.key(s.start, NY) === "2030-10-28");
      assert.equal(K.time(oct25.start, "Europe/London", "en-US"), "2:00\u00a0pm");   // BST
      assert.equal(K.time(oct28.start, "Europe/London", "en-US"), "1:00\u00a0pm");   // GMT, New York still EDT
      const london = pages.times({ ...SAMPLES.times, slots: [fri, mon], zone: "Europe/London" }).html;
      assert.match(london, /data-s="1919768400000">1:00\u00a0pm</);

      // The strip steps by calendar dates and names each one, across both changes.
      assert.equal(K.step("2030-10-26", 1), "2030-10-27");
      assert.equal(K.step("2030-11-02", 2), "2030-11-04");
      assert.equal(K.dayName("2030-11-03", "en-US"), "Sun, Nov 3");
      // The host's time beside the guest's on the card, when they differ.
      const card = K.card({ booking: booking(fri), zone: "Asia/Tokyo", loc: "en-US", host, type: type() });
      assert.match(card, /<b>Fri, Nov 1, 10:00–10:30\u00a0pm<\/b><br>Tokyo time · 9:00\u00a0am for Noor</);
      const late = SLOTS.find((s) => s.start === "2030-11-01T20:30:00.000Z");
      assert.match(K.card({ booking: booking(late), zone: "Asia/Tokyo", loc: "en-US", host, type: type() }), /<b>Sat, Nov 2, 5:30–6:00\u00a0am<\/b><br>Tokyo time · Fri, Nov 1 4:30\u00a0pm for Noor</);
      assert.ok(!K.card({ booking: booking(fri), zone: "America/Toronto", loc: "en-US", host, type: type() }).includes(" for Noor"), "same offset, no second time");
    }
  } finally {
    if (before === undefined) delete process.env.TZ; else process.env.TZ = before;
  }
});

test("zone names: canonical, old aliases mapped, abbreviations refused, cities named", () => {
  assert.equal(K.zoneOk("Asia/Calcutta"), "Asia/Kolkata");
  assert.equal(K.zoneOk("Asia/Katmandu"), "Asia/Kathmandu");
  assert.equal(K.zoneOk("Etc/UTC"), "UTC");
  assert.equal(K.zoneOk("EST"), null);
  assert.equal(K.zoneOk("Mars/Olympus"), null);
  assert.equal(K.zoneName("America/New_York"), "New York time");
  assert.equal(K.zoneName("America/Argentina/Buenos_Aires"), "Buenos Aires time");
  assert.equal(K.zoneName("UTC"), "UTC");
  assert.equal(K.zoneName("Etc/GMT+5"), "GMT-5");
  // A view's zone that isn't valid falls back to the guest's, then the type's.
  assert.match(pages.times({ ...SAMPLES.times, zone: "PST" }).html, /data-z="America\/New_York"/);
});

test("the slots travel packed, the busy times of a connected guest are left out", () => {
  const starts = SLOTS.slice(0, 20).map((s) => Date.parse(s.start));
  assert.deepEqual(K.unpack(K.pack(starts)), starts);
  const r = pages.times({ ...SAMPLES.times, slots: SLOTS.slice(0, 4), busy: [{ start: SLOTS[1].start, end: SLOTS[2].end }] });
  const data = JSON.parse(scriptsOf(r.html).find((s) => /application\/json/.test(s.attrs)).body);
  assert.deepEqual(K.unpack(data.s), [Date.parse(SLOTS[0].start), Date.parse(SLOTS[3].start)]);
  assert.match(r.html, /Hiding your busy times/);
  assert.ok(!r.html.includes("Only times I&#39;m free"));
  assert.match(pages.times(SAMPLES.times).html, /href="\/b\/connect\?return=\/noor\/intro">Only times I'm free/);
});

test("what each page says and offers", () => {
  const times = pages.times({ ...SAMPLES.times, guest: { ...sam, state: "verified", upcoming: [{ manageUrl: "/m/a.b", hostName: "Ana Ruiz", title: "Review", start: SLOTS[2].start, end: SLOTS[2].end }] } }).html;
  assert.match(times, /Your next time: <time[^>]*>[^<]+<\/time> with Ana · <a class="lk" href="\/m\/a.b">Change<\/a>/);
  assert.match(times, /Booking as Sam · <button type="button" class="lk" id="notyou">not you\?<\/button>/);
  assert.match(times, /id="soon"[^>]*><span>Soonest<\/span><time/);
  assert.match(times, /autocomplete="name"/);
  assert.match(times, /autocomplete="email"/);
  assert.ok(!times.includes('autocomplete="tel"'), "no phone field without a phone place");
  assert.ok(!times.includes('name="place"'), "no place choice with one place");
  const several = pages.times({ ...SAMPLES.times, type: type({ places: [MEET, PHONE, ROOM] }) }).html;
  assert.match(several, /autocomplete="tel"/);
  assert.equal((several.match(/name="place"/g) || []).length, 3);
  assert.match(pages.times({ ...SAMPLES.times, slots: [] }).html, /<p class="none" id="none">No times open<\/p>/);

  const conf = pages.confirmed(SAMPLES.confirmed).html;
  assert.match(conf, /Booked/);
  assert.match(conf, /data-copy="https:\/\/meet.google.com\/abc-defg-hij">Copy/);
  assert.match(conf, /Invite sent to sam@example.com/);
  assert.match(conf, /href="\/b\/9f2c4e.ics\?sig=x">Add to calendar/);
  assert.match(conf, /href="\/m\/9f2c4e.sig#cancel">Cancel/);
  const held = pages.confirmed({ ...SAMPLES.confirmed, booking: booking(SLOTS[3], { invite: "held", undoUntil: new Date(Date.now() + 4000).toISOString() }) }).html;
  assert.match(held, /Sending invite to/);
  assert.match(held, /data-undo>Undo/);
  assert.match(pages.confirmed({ ...SAMPLES.confirmed, booking: booking(SLOTS[3], { place: PHONE, placeDetail: "+1 917 555 0142" }) }).html, /Noor calls you on \+1 917 555 0142/);
  assert.match(pages.confirmed({ ...SAMPLES.confirmed, booking: booking(SLOTS[3], { place: ROOM, placeDetail: ROOM.address }) }).html, /61 Wythe Ave, Brooklyn · <a href="https:\/\/www.google.com\/maps\/search\/\?api=1&amp;query=61%20Wythe/);

  const manage = pages.manage(SAMPLES.manage).html;
  assert.match(manage, /<span class="t cur" aria-current="true">[^<]+<span class="sr">, your time<\/span><\/span>/);
  assert.match(manage, /Your time/);
  assert.match(manage, /Reason \(optional\)/);
  assert.match(pages.notTaking(SAMPLES.notTaking).html, /Noor isn't taking bookings right now/);
  assert.match(pages.code(SAMPLES.code).html, /autocomplete="one-time-code" inputmode="numeric"/);
  assert.match(pages.forget(SAMPLES.forget).html, /Your 2 upcoming times stay on the hosts&#39; calendars. Reminders stop./);
  assert.match(pages.forget({ ...SAMPLES.forget, upcomingCount: 1 }).html, /Your upcoming time stays on the host&#39;s calendar./);
  // The copy rule: no "X, never Y" tails.
  for (const [name, view] of Object.entries(SAMPLES)) assert.ok(!/, never /i.test(pages[name](view).html.replace(/<script[\s\S]*?<\/script>/g, "")), name);
});

test("no page code parses a date-only string", () => {
  for (const f of ["kit.js", "client.js", "index.js"]) {
    const src = readFileSync(new URL(`../src/booking/pages/${f}`, import.meta.url), "utf8").replace(/\/\/.*$/gm, "");
    assert.ok(!/new Date\(\s*["'`]/.test(src), `${f}: new Date("…")`);
    assert.ok(!/Date\.parse\(\s*(k|key|day)\b/.test(src), `${f}: Date.parse of a day key`);
  }
});

test("the first load stays inside its budget", () => {
  const r = pages.times(SAMPLES.times);
  const markup = r.html.replace(/<script nonce[^>]*>[\s\S]*?<\/script>/g, "").replace(/<style>[\s\S]*?<\/style>/, "");
  assert.ok(gz(markup) <= 12000, `HTML ${gz(markup)}`);
  for (const [name, src] of Object.entries(SCRIPTS)) assert.ok(gz(src) <= 10000, `${name} script ${gz(src)}`);
  assert.ok(gz(CSS) <= 6000, `CSS ${gz(CSS)}`);
  assert.ok(HEAD.length < 400);
  const fonts = ["400", "700"].map((w) => readFileSync(new URL(`../public/book/fonts/IBMPlexMono-${w}.woff2`, import.meta.url)).length);
  assert.ok(fonts[0] + fonts[1] <= 50000, `fonts ${fonts}`);
  assert.equal((r.html.match(/rel="preload"/g) || []).length, 2, "the two fonts, preloaded");
});

test("the page scripts are esbuild's output of the current sources, and the kit in them gives what the server's gives", () => {
  assert.equal(SOURCE, hashOf(sources()), "pages/kit.js or pages/client.js changed: run node tools/build-book-scripts.mjs");
  for (const [name, src] of Object.entries(SCRIPTS)) assert.doesNotThrow(() => new vm.Script(src), name);
  const box = {};
  vm.runInNewContext(KIT, box);
  const small = box.__kit();
  const at = Date.parse("2030-11-03T06:30:00Z"), starts = SLOTS.map((s) => Date.parse(s.start));
  for (const z of ["America/New_York", "Asia/Kathmandu", "Pacific/Chatham", "Europe/London"]) {
    assert.equal(small.time(at, z, "en-US"), K.time(at, z, "en-US"));
    assert.equal(small.key(at, z), K.key(at, z));
    assert.equal(small.offset(at, z), K.offset(at, z));
    assert.equal(small.strip(K.days(starts, z), null, "en-GB"), K.strip(K.days(starts, z), null, "en-GB"));
    assert.equal(small.cal(K.days(starts, z), null, "en-US"), K.cal(K.days(starts, z), null, "en-US"));
  }
  assert.equal(small.card({ booking: booking(), zone: "Asia/Tokyo", loc: "en-US", host, type: type() }), K.card({ booking: booking(), zone: "Asia/Tokyo", loc: "en-US", host, type: type() }));
});

test("a time across the guest's midnight, the strip, the month grid and links", () => {
  // New York's 10:30 am is Tokyo's 11:30 pm: the range names two clocks, no dates.
  const late = slot("2030-10-22T14:30:00.000Z");
  assert.equal(K.range(late.start, late.end, "Asia/Tokyo", "en-US"), "11:30 pm–12:00 am");
  assert.match(K.card({ booking: booking(late), zone: "Asia/Tokyo", loc: "en-US", host, type: type() }), /<b>Tue, Oct 22, 11:30 pm–12:00 am<\/b>/);
  assert.equal(K.range(SLOTS[0].start, SLOTS[0].end, NY, "en-US"), "9:00–9:30 am");

  // Weekdays only: no weekend chips; the month over the first chip and over the 1st.
  const ds = K.days(SLOTS.map((s) => Date.parse(s.start)), NY), strip = K.strip(ds, ds[0].k, "en-US");
  assert.ok(!/<small>(Sat|Sun)<\/small>/.test(strip));
  assert.match(strip, /data-k="2030-10-21" aria-pressed="true"><i aria-hidden="true">Oct<\/i>/);
  assert.match(strip, /data-k="2030-11-01"[^>]*><i aria-hidden="true">Nov<\/i>/);
  const weekend = K.strip(K.days([Date.parse("2030-10-25T14:00:00Z"), Date.parse("2030-10-26T14:00:00Z")], NY), null, "en-US");
  assert.match(weekend, /<small>Sat<\/small>/);

  // The month grid: every day of each month, the week as the locale starts it.
  const us = K.cal(ds, ds[0].k, "en-US"), gb = K.cal(ds, ds[0].k, "en-GB");
  assert.match(us, /<h3>October<\/h3><div class="cg"><b aria-hidden="true">S<\/b><b aria-hidden="true">M<\/b>/);
  assert.match(gb, /<h3>October<\/h3><div class="cg"><b aria-hidden="true">M<\/b>/);
  assert.equal((us.match(/<h3>/g) || []).length, 2);
  assert.match(us, /data-k="2030-10-01" disabled>1<span class="sr"> October, no times<\/span>/);
  assert.match(gb, /<\/b><i><\/i><button type="button" class="d" data-k="2030-10-01"/, "1 Oct 2030 is a Tuesday: one blank before it");
  assert.match(us, /<\/b><i><\/i><i><\/i><button type="button" class="d" data-k="2030-10-01"/, "two blanks from Sunday");

  // Links: only http(s), mail, tel and this site.
  assert.equal(K.href("//evil.example/x"), "#");
  assert.equal(K.href("javascript:alert(1)"), "#");
  assert.equal(K.href("/m/a.b"), "/m/a.b");
});

test("the card: Booking… while sending, a failed invite, no email offers without email", () => {
  const b = booking();
  assert.match(K.card({ booking: b, zone: NY, loc: "en-US", host, type: type(), sending: true }), /<h2 id="card-t" tabindex="-1">Booking…<\/h2>/);
  assert.ok(!K.card({ booking: b, zone: NY, loc: "en-US", host, type: type(), sending: true }).includes("Invite"));
  assert.match(K.card({ booking: { ...b, invite: "failed" }, zone: NY, loc: "en-US", host, type: type() }), /Invite didn't go out. Details emailed to sam@example.com/);
  assert.match(K.card({ booking: { ...b, invite: "failed" }, zone: NY, loc: "en-US", host, type: type(), mail: false }), /Invite didn't go out<\/p>/);
  // The Meet link stands alone once it's there; the label shows while it's coming.
  assert.match(K.card({ booking: b, zone: NY, loc: "en-US", host, type: type() }), /<p class="link"><a href="https:\/\/meet.google.com\/abc-defg-hij"/);
  assert.match(K.card({ booking: { ...b, placeDetail: null, invite: "held" }, zone: NY, loc: "en-US", host, type: type() }), /<p>Google Meet<\/p>/);
  // The confirmation page counts Undo from undoMs.
  const conf = pages.confirmed({ ...SAMPLES.confirmed, booking: booking(SLOTS[3], { undoMs: 3000, undoUntil: null, invite: "held" }) }).html;
  assert.match(conf, /animation-duration:3000ms/);
});

test("layout and words: the meta line, Time zone beside a next time, lang from an English locale", () => {
  const times = pages.times(SAMPLES.times).html;
  assert.match(times, /<p class="meta">30 min · Google Meet · with Noor Haddad<\/p>/);
  assert.ok(!times.includes('class="mono"'), "no avatar box");
  assert.match(times, /<div class="cal" id="cal"/);
  assert.match(times, /<div id="ts2"><\/div><button class="btn book">Book<\/button>/, "Turnstile sits above Book");
  assert.match(times, /aria-label="Change time zone">Change<\/button>/);
  const verified = pages.times({ ...SAMPLES.times, guest: { ...sam, state: "verified", upcoming: [{ manageUrl: "/m/a.b", hostName: "Ana", start: SLOTS[2].start, end: SLOTS[2].end }] } }).html;
  assert.match(verified, /aria-label="Change time zone">Time zone<\/button>/);
  assert.match(pages.times({ ...SAMPLES.times, locale: "en-GB" }).html, /<html lang="en-GB"/);
  assert.match(pages.times({ ...SAMPLES.times, locale: "de-DE" }).html, /<html lang="en"/);
  const manage = pages.manage(SAMPLES.manage).html;
  assert.match(manage, /id="cx">Cancel time<\/button>/);
  assert.ok(!manage.includes("<h2>Cancel</h2>"));
  assert.match(manage, /Noor knows\./);
  assert.ok(!pages.profile(SAMPLES.profile).html.includes('class="host"'), "no second host row on the profile");
  // The zone picker starts with the major cities, in order of their offset now.
  assert.match(times, /<ul class="zl" id="zl"><li><button type="button" data-z="America\/Los_Angeles">Los Angeles<small>GMT-\d+<\/small><\/button>/);
  assert.match(times, /"za":"America\/Los_Angeles:pst/);
});

test("a booking the host cancelled inside the window, and the manage page's columns", () => {
  const card = K.card({ booking: booking(SLOTS[3], { status: "cancelled", invite: "held" }), zone: NY, loc: "en-US", host, type: type() });
  assert.match(card, /<h2 id="card-t" tabindex="-1">Cancelled<\/h2>/);
  assert.ok(!/Sending invite|Add to calendar|class="ck"/.test(card));
  const manage = pages.manage(SAMPLES.manage).html;
  assert.match(manage, /<main class="w"><div class="cols"><div class="side"><h1>Intro call<\/h1>/);
  assert.match(manage, /<div data-rl><div class="cal" id="cal"[\s\S]*<\/div><\/div><div><section class="sec" id="change"/, "the month grid on the left, the times on the right");
  assert.ok(manage.indexOf('id="cancel"') > manage.indexOf('id="grid"'), "Cancel follows the times in the right column");
  assert.match(manage, /style="--r:\d+;--r4:\d+"/);
});

test("a move's Undo goes to POST /b/undo, never as a move back", () => {
  const data = JSON.parse(/<script type="application\/json" id="bk">([\s\S]*?)<\/script>/.exec(pages.manage(SAMPLES.manage).html)[1]);
  assert.equal(data.u.undo, "/b/undo");
  const src = sources().manage, revert = src.slice(src.indexOf("function revert(o)"), src.indexOf("function summary()"));
  assert.match(revert, /api\(U\.undo, \{ manage:/);
  assert.ok(!/U\.move/.test(revert), "the undo of a move doesn't post a move");
  assert.match(revert, /Your old time went\. You keep /);
});
