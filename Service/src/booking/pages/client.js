// The page's behaviour, in parts. None of it runs on the server: tools/build-book-scripts.mjs joins
// the bodies of the parts a page needs into one function and minifies it with esbuild into
// scripts.gen.js, so a later part uses what `core` declares. Each part refers to nothing outside
// that function except the kit (K) and the page's data (D, from <script type="application/json"
// id="bk">).
//
// One delegated click listener; every tap changes the screen first and lets the network catch up.
/* eslint-disable no-undef, no-unused-vars */

/** Every page: labels in the zone, the days and the times, the one listener, past times dropped. */
export function core(K, D) {
  const doc = document, $ = (s) => doc.querySelector(s), U = D.u || {}, ty = D.ty || {}, host = D.h || {};
  const dur = (ty.minutes || 30) * 60000, spots = ty.places || [], H = [];
  const store = (k, v) => { try { if (v === undefined) return localStorage.getItem(k); localStorage.setItem(k, v); } catch (e) { return null; } };
  const device = K.zoneOk(Intl.DateTimeFormat().resolvedOptions().timeZone);
  let zone = K.zoneOk(store("bk.zone")) || device || D.z || "UTC";
  const loc = undefined, live = $("#live"), sheet = $("#sheet");
  const say = (t) => { live.textContent = ""; setTimeout(() => { live.textContent = t; }, 50); };
  let g = D.g && D.g.state !== "none" && D.g.name && D.g.email ? D.g : null, cur = null;
  const api = (url, body, keep) => fetch(url, body === undefined ? { credentials: "same-origin" } : {
    method: "POST", keepalive: !!keep, credentials: "same-origin",
    headers: { "content-type": "application/json", "x-csrf-token": D.c || "" }, body: JSON.stringify(body),
  }).then((r) => r.text().then((t) => { let j = null; try { j = t ? JSON.parse(t) : null; } catch (e) { j = null; } return { s: r.status, j }; }), () => ({ s: 0, j: null }));
  const iso = (s) => new Date(s).toISOString();
  const ok = (r) => r.s === 200 || r.s === 204;
  const oops = (r) => (r.s === 429 ? "Too many tries. Wait a minute." : r.s ? "That didn't work. Try again." : "No connection. Try again.");
  function relabel() {
    for (const el of doc.querySelectorAll("time[data-f]")) {
      const t = Date.parse(el.dateTime), f = el.dataset.f;
      el.textContent = (f === "w" ? K.when(t, zone, loc, Date.now()) + " " : K.day(t, zone, loc) + ", ") + K.time(t, zone, loc);
    }
    for (const el of doc.querySelectorAll("[data-zn]")) el.textContent = K.zoneName(zone);
  }
  let starts = D.s ? K.unpack(D.s) : [], ds = [], sel = null;
  const calEl = $("#cal"), gridEl = $("#grid");
  function draw() {
    if (!gridEl) return;
    ds = K.days(starts, zone);
    if (!ds.some((d) => d.k === sel)) sel = (ds.find((d) => d.s.indexOf(D.cur) >= 0) || ds[0] || {}).k || null;
    pick(sel);
    const soon = $("#soon");
    if (soon) { soon.hidden = !starts.length; if (starts.length) { soon.dataset.s = starts[0]; $("#soon time").textContent = K.when(starts[0], zone, loc, Date.now()) + " " + K.time(starts[0], zone, loc); } }
    const none = $("#none");
    if (none) none.hidden = !!starts.length;
  }
  // The month shown follows the day picked; the arrows turn it without picking.
  function month(m, focusLabel) {
    if (!calEl) return;
    calEl.innerHTML = K.cal(ds, sel, loc, m);
    if (focusLabel) (calEl.querySelector('.mn[aria-label="' + focusLabel + '"]:not(:disabled)') || calEl.querySelector(".d:not(:disabled)") || calEl.querySelector(".mn:not(:disabled)")).focus();
  }
  function pick(k, focus) {
    sel = k;
    const d = ds.find((x) => x.k === k);
    const n = d ? d.s.length : 1;
    gridEl.style.setProperty("--r2", Math.ceil(n / 2));
    gridEl.style.setProperty("--r", Math.ceil(n / 3));
    gridEl.style.setProperty("--r4", Math.ceil(n / 4));
    gridEl.innerHTML = K.grid(d, zone, loc, D.cur);
    $("#day").textContent = k ? K.dayName(k, loc) : "";
    month(k ? k.slice(0, 7) : null);
    const b = k && calEl && calEl.querySelector('.d[data-k="' + k + '"]');
    if (b && focus) b.focus();
  }
  if (D.cur && starts.indexOf(D.cur) < 0) starts = starts.concat(D.cur).sort((a, b) => a - b);
  ds = K.days(starts, zone);
  const on0 = $(".d[aria-pressed=true]");
  sel = on0 ? on0.dataset.k : null;
  try { if (zone !== D.z || Intl.DateTimeFormat().resolvedOptions().locale !== D.l) { relabel(); draw(); } } finally { doc.documentElement.classList.remove("rz"); }
  // A page left open: past times drop out each minute.
  setInterval(() => {
    const n = starts.filter((s) => s > Date.now() || s === D.cur);
    if (n.length !== starts.length) { starts = n; draw(); }
  }, 60000);
  doc.addEventListener("click", (e) => {
    const t = e.target.closest("button,a,dialog");
    if (!t) return;
    if (t.tagName === "DIALOG") { if (e.target === t) t.close(); return; }
    for (const h of H) if (h(t, t.dataset)) return;
  });
  // A day tapped on a phone brings its times up under the top, as Calendly's second step does; a
  // wider screen has them beside the month already.
  H.push((t, d) => {
    if (d.k) { pick(d.k); if (innerWidth < 768) $("#day").scrollIntoView({ block: "start", behavior: matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth" }); return 1; }
    if (d.m) return month(d.m, t.getAttribute("aria-label")), 1;
    if ("x" in d) return t.closest("dialog").close(), 1;
    if (d.copy) return navigator.clipboard.writeText(d.copy).then(() => { t.textContent = "Copied"; say("Copied"); setTimeout(() => { t.textContent = "Copy"; }, 2000); }), 1;
    if (t.id === "notyou") { g = null; api(U.notMe || "/b/not-me", {}); $("#as").remove(); const s = $("#soon") || $("#grid .t"); if (s) s.focus(); return 1; }
  });
  // Arrows move to the next day with times, and by a week up and down the month grid.
  doc.addEventListener("keydown", (e) => {
    const n = { ArrowRight: 1, ArrowLeft: -1, ArrowDown: 7, ArrowUp: -7 }[e.key];
    if (!n || !e.target.dataset || !e.target.dataset.k) return;
    e.preventDefault();
    const i = ds.findIndex((d) => d.k === sel), want = K.step(sel, n);
    const to = Math.abs(n) === 1 ? ds[i + n] : n > 0 ? ds.find((d) => d.k >= want) : ds.slice().reverse().find((d) => d.k <= want);
    if (to) pick(to.k, true);
  });
}

/** The zone picker: major cities by offset before typing; search by city, country or abbreviation. */
export function zones() {
  const zd = $("#zones"), zl = [];
  // The aliases come in the page's data and the major cities by offset in its HTML (zones.js).
  const ALIAS = {}, base = $("#zl").innerHTML;
  (D.za || "").split("|").forEach((x) => { const i = x.indexOf(":"); ALIAS[x.slice(0, i)] = x.slice(i + 1); });
  const off = (z) => { const m = K.offset(Date.now(), z), a = Math.abs(m); return "GMT" + (m ? (m < 0 ? "-" : "+") + Math.floor(a / 60) + (a % 60 ? ":" + String(a % 60).padStart(2, "0") : "") : ""); };
  const row = (z, sub) => '<li><button type="button" data-z="' + K.esc(z) + '">' + K.esc(K.city(z)) + (sub ? "<small>" + K.esc(sub) + "</small>" : "") + "</button></li>";
  function search(q) {
    if (!zl.length) {
      const seen = {};
      for (const z0 of (Intl.supportedValuesOf ? Intl.supportedValuesOf("timeZone") : []).concat("UTC")) {
        const z = K.zoneOk(z0);
        if (z && !seen[z]) { seen[z] = 1; zl.push({ z, o: off(z), h: " " + (z.replace(/[/_]/g, " ") + " " + (ALIAS[z] || "") + " " + off(z)).toLowerCase() }); }
      }
    }
    const w = q.toLowerCase().split(/\s+/).filter(Boolean);
    let h = "", n = 0;
    if (!w.length) {
      h = (device ? '<li class="og">This device</li>' + row(device, off(device)) : "") +
        (ty.hostZone && ty.hostZone !== device ? '<li class="og">' + K.esc(K.firstName(host.name)) + "</li>" + row(ty.hostZone, off(ty.hostZone)) : "") + base;
    } else {
      // Whole words of a city or an alias first ("india" is Kolkata), then their beginnings
      // (Indianapolis), then any part of the zone's name.
      const top = (x) => " " + K.city(x.z).toLowerCase() + " " + (ALIAS[x.z] || "") + " ";
      const rank = (x) => (w.every((s) => top(x).indexOf(" " + s + " ") >= 0) ? 0 : w.every((s) => top(x).indexOf(" " + s) >= 0) ? 1 : w.every((s) => x.h.indexOf(" " + s) >= 0) ? 2 : 3);
      for (const x of zl.map((x) => [rank(x), x]).filter((a) => a[0] < 3).sort((a, b) => a[0] - b[0]).map((a) => a[1])) if (n++ < 60) h += row(x.z, x.o);
    }
    $("#zl").innerHTML = h || '<li class="none">No match</li>';
    // This device's zone and the host's lead the list, so they go from the cities below.
    for (const z of [device, ty.hostZone]) [].slice.call(doc.querySelectorAll('#zl [data-z="' + z + '"]'), 1).forEach((x) => x.parentNode.remove());
    const b = $('#zl [data-z="' + zone + '"]');
    if (b) b.setAttribute("aria-current", "true");
  }
  H.push((t, d) => {
    if (t.id === "zc") { zd.showModal(); const i = $("#zq"); i.value = ""; search(""); return i.focus(), 1; }
    if (!d.z) return;
    zone = d.z;
    store("bk.zone", zone);
    zd.close();
    relabel();
    draw();
    if (typeof summary === "function") summary();
    return say("Times in " + K.zoneName(zone)), 1;
  });
  doc.addEventListener("input", (e) => { if (e.target.id === "zq") search(e.target.value); });
}

/** The sheet: the booked card and the nearest times, in one <dialog>. Each page says what a tap
 * on a time does (`tap`), on a nearest time (`retry`), and what Undo puts back (`revert`). */
export function sheetPart() {
  function pop(html) {
    sheet.innerHTML = html;
    if (!sheet.open) sheet.showModal();
    fit();
  }
  function fit() {
    const v = window.visualViewport;
    if (v && sheet.open) sheet.style.marginBottom = Math.max(0, innerHeight - v.height - v.offsetTop) + "px";
  }
  if (window.visualViewport) visualViewport.addEventListener("resize", fit);
  // Undo shows from the tap; its countdown starts once the reservation is held, for as long as the
  // service says. While Undo is open the card has no ×.
  function shown(o) {
    const b = o.b, left = o.state === "held" && b.status !== "cancelled" ? o.until - Date.now() : 0, open = (o.state === "sending" || left > 0) && b.status !== "cancelled";
    pop('<div class="sh card" id="c">' + (open ? "" : '<button type="button" class="x" data-x aria-label="Close">×</button>') +
      K.card({ booking: b, zone, loc, host, type: ty, pending: b.status !== "confirmed", moved: o.moved, sending: o.state === "sending", mail: D.mail }) +
      (open ? '<div class="undo">' + (left > 0 ? '<i style="animation-duration:' + left + 'ms"></i>' : "") + '<button type="button" class="btn" data-undo>Undo</button>' +
        (o.edit ? '<button type="button" class="lk" data-edit>Edit</button>' : "") + "</div>" : "") + "</div>");
    if (left > 0) setTimeout(() => { if (cur === o && sheet.open && o.state !== "undone") shown(o); }, left + 30);
  }
  function held(o, b) {
    Object.assign(o.b, b);
    o.state = "held";
    o.until = Date.now() + Math.max(0, Math.min(15000, b.undoMs != null ? b.undoMs : b.undoUntil ? Date.parse(b.undoUntil) - Date.now() : 5000));
    if (cur === o && sheet.open) shown(o);
  }
  function notice(text) {
    pop('<div class="sh"><header><h2 id="card-t" tabindex="-1">' + K.esc(text) + '</h2><button type="button" class="x" data-x aria-label="Close">×</button></header></div>');
    $("#card-t").focus();
  }
  function taken(o, near) {
    const n = near.map((x) => Date.parse(x.start)).filter((x) => x > Date.now());
    pop('<div class="sh"><header><h2 id="card-t" tabindex="-1">That time just went. Nearest:</h2><button type="button" class="x" data-x aria-label="Close">×</button></header>' +
      '<div class="grid near">' + n.map((x) => '<button type="button" class="t" data-n="' + x + '">' + K.esc(K.day(x, zone, loc) + ", " + K.time(x, zone, loc)) + "</button>").join("") + "</div></div>");
    sheet.det = o.det;
    $("#card-t").focus();
  }
  H.push((t, d) => {
    if (d.s) return tap(+d.s), 1;
    if (d.n) return retry(+d.n), 1;
    if (!("undo" in d || "edit" in d) || !cur) return;
    cur.state = "undone";
    say("Undone");
    return revert(cur, "edit" in d), 1;
  });
}

/** Booking: the form, one tap for a recognised guest, Turnstile, a page left open. */
export function bookPart() {
  const ikeys = {};
  let draft = null;
  const placeOf = (id) => spots.find((p) => p.id === id) || spots[0] || null;
  const needsPhone = (id) => { const p = placeOf(id); return !!p && p.kind === "phone_host_calls"; };
  const uid = () => (crypto.randomUUID ? crypto.randomUUID() : String(Math.random()).slice(2) + Date.now());
  const ERR = { name: "Add your name", email: "Check your email", phone: "Add your number" };
  const typed = (f) => { const v = {}; for (const kv of new FormData(f)) v[kv[0]] = String(kv[1]).trim(); return v; };
  // The form is a <template> in the page; this fills it in. What was typed survives a close.
  sheet.addEventListener("close", () => { const f = $("#f"); if (f) draft = typed(f); });
  function form(s, v, err) {
    v = v || {};
    err = err || {};
    pop($("#tf").innerHTML);
    sheet.dataset.s = s;
    const f = $("#f"), el = f.elements;
    $("#card-t").textContent = K.day(s, zone, loc) + ", " + K.range(s, s + dur, zone, loc);
    f.querySelector(".zone").textContent = K.zoneName(zone);
    if (el.place && v.place) el.place.value = v.place;
    for (const n of ["name", "email", "phone", "note"]) {
      const i = el[n], e = $("#e-" + n);
      if (!i) continue;
      i.value = v[n] || "";
      if (e && err[n]) { e.textContent = err[n]; e.hidden = false; i.setAttribute("aria-invalid", "true"); }
    }
    if (v.note) showNote();
    if (err.all) { const a = $("#e-all"); a.textContent = err.all; a.hidden = false; }
    phone();
    const first = f.querySelector("[aria-invalid]") || [].slice.call(f.querySelectorAll("input:not([type=radio]):not([disabled])")).find((i) => !i.value);
    (first || f.querySelector(".book")).focus();
    tsInto("#ts2");
  }
  // The phone field shows, and is asked for, only for a place where the host calls them.
  function phone() {
    const f = $("#f"), l = $("#pl");
    if (!l) return;
    const on = needsPhone(f.elements.place ? f.elements.place.value : spots[0] && spots[0].id);
    l.hidden = !on;
    f.elements.phone.disabled = !on;
  }
  function showNote() {
    $("#nb").hidden = true;
    $("#nl").hidden = false;
  }
  function tap(s) {
    const p = spots[0] && spots[0].id;
    mark(s);
    if (g && !(needsPhone(p) && !g.phone)) reserve(s, { name: g.name, email: g.email, phone: g.phone || "", place: p }, true);
    else form(s, draft || g || (cur && cur.det));
  }
  function retry(s) {
    if (!(sheet.det && sheet.det.email)) return tap(s);
    mark(s);
    reserve(s, sheet.det, !!g);
  }
  function mark(s) {
    for (const b of gridEl.querySelectorAll(".t.on")) b.classList.remove("on");
    const b = s && gridEl.querySelector('[data-s="' + s + '"]');
    if (b) b.classList.add("on");
  }
  // A recognised browser skips Turnstile only with the email it booked with; any other email, or the
  // service asking (400 turnstile), solves it.
  function reserve(s, det, oneTap, check) {
    const skip = !check && g && det.email.toLowerCase() === g.email.toLowerCase();
    if (D.ts && !skip && !dead && needs && !tok) return form(s, det, { all: "Pass the check first" });
    const k = s + "|" + det.email, key = (ikeys[k] = ikeys[k] || uid()), p = placeOf(det.place);
    const o = (cur = { s, det, state: "sending", edit: oneTap,
      b: { start: iso(s), end: iso(s + dur), place: p, placeDetail: needsPhone(det.place) ? det.phone : null, guestEmail: det.email } });
    draft = null;
    shown(o);
    $("#card-t").focus();
    (skip ? Promise.resolve("") : token()).then((tk) => api(U.book, { key, start: iso(s), place: p && p.id, name: det.name, email: det.email, phone: det.phone || undefined,
      note: det.note || undefined, zone, turnstile: tk }, true)).then((r) => {
      const b = r.j && r.j.booking;
      if (o.state === "undone") return r.s === 200 && b && (Object.assign(o.b, b), undoLate(o));
      if (r.s === 200 && b) {
        held(o, b);
        say("Booked, " + K.day(s, zone, loc) + " " + K.time(s, zone, loc));
        return follow(o, 0);
      }
      cur = null;
      mark(null);
      const j = r.j || {};
      if (r.s === 400 && j.field === "turnstile" && skip) return reserve(s, det, oneTap, true);
      if (r.s === 409 && j.already) return notice(j.emailed === false ? "You already have a time booked" : "We've emailed your existing time");
      if (r.s === 409 && j.error) return notice(K.firstName(host.name) + " isn't taking bookings right now");
      if (r.s === 409) return gone(s), taken(o, j.nearest || []);
      const e = {};
      if (r.s === 400 && j.field === "turnstile") e.all = "That check didn't pass. Try again.";
      else if (r.s === 400 && j.field) e[j.field] = ERR[j.field] || "Check this"; else e.all = oops(r);
      form(s, det, e);
    });
  }
  // The invite goes out once Undo has passed; the follow-up says so and brings the Meet link.
  function follow(o, n) {
    const url = o.b.statusUrl, wait = n ? n === 1 ? Math.max(1000, o.until - Date.now() + 1000) : 3000 : 2000;
    if (!url || n > 4) return;
    setTimeout(() => api(url).then((r) => {
      const b = r.j && r.j.booking;
      if (o.state === "undone") return;
      if (r.s === 200 && b) {
        Object.assign(o.b, b);
        if (b.status === "taken" || b.status === "failed") return (cur = null), gone(o.s), taken(o, b.nearest || []);
        if (cur === o && sheet.open) shown(o);
        if (b.status === "cancelled") return say("Cancelled");
        if (b.invite === "sent" && b.meet !== "pending") return say("Invite sent");
      }
      follow(o, n + 1);
    }), wait);
  }
  function gone(s) {
    starts = starts.filter((x) => x !== s);
    draw();
  }
  const unbook = (b) => api(U.undo, { manage: String(b.manageUrl || "").split("/").pop() });
  // Undo after the window (even one tapped during "Booking…" whose answer came late): the booking
  // stands, and the card says so.
  const undoLate = (o) => unbook(o.b).then((r) => { if (r.s === 409) { o.state = "held"; o.until = 0; cur = o; shown(o); say("Too late to undo"); } });
  function revert(o, edit) {
    if (o.b.manageUrl) undoLate(o);
    mark(null);
    if (edit || !o.edit) return form(o.s, o.det);
    cur = null;
    sheet.close();
  }
  H.push((t, d) => {
    if (!("note" in d)) return;
    showNote();
    return $("#nl textarea").focus(), 1;
  });
  doc.addEventListener("change", (e) => { if (e.target.name === "place") phone(); });
  doc.addEventListener("submit", (e) => {
    e.preventDefault();
    const v = typed(e.target), s = +sheet.dataset.s, err = {};
    if (!v.name) err.name = ERR.name;
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v.email || "")) err.email = ERR.email;
    if (needsPhone(v.place) && !/\d{5}/.test((v.phone || "").replace(/\D/g, ""))) err.phone = ERR.phone;
    if (Object.keys(err).length) return form(s, v, err);
    reserve(s, v, false);
  });
  // Turnstile, loaded once the page has painted and solved on the page by the time Book is pressed.
  // Only when it wants a tap does it move into the open form. If it can't load, or takes more than
  // 5 s, the booking goes without it and the service decides.
  let ts = null, tsId = null, tok = null, waiting = [], needs = false, where = null, dead = !D.ts;
  const flush = (t) => waiting.splice(0).forEach((f) => f(t));
  function token() {
    const done = (t) => { tok = null; try { if (where === "#ts") ts.reset(tsId); else tsInto("#ts"); } catch (e) { dead = true; } return t; };
    if (dead) return Promise.resolve("");
    if (tok) return Promise.resolve(done(tok));
    return new Promise((res) => { waiting.push(res); setTimeout(() => res(""), 5000); }).then(done);
  }
  function tsInto(s) {
    const el = $(s);
    if (!ts || tok || !el || (where === s && el.firstChild) || (s === "#ts2" && !needs)) return;
    if (tsId) ts.remove(tsId);
    where = s;
    tsId = ts.render(s, { sitekey: D.ts, appearance: "interaction-only", callback: (t) => { tok = t; needs = false; flush(t); },
      "expired-callback": () => { tok = null; }, "error-callback": () => { dead = true; flush(""); },
      "before-interactive-callback": () => { needs = true; if (where === "#ts") tsInto("#ts2"); } });
  }
  window.bkTs = () => { ts = window.turnstile; tsInto("#ts"); };
  if (D.ts) addEventListener("load", () => setTimeout(() => {
    const sc = doc.createElement("script");
    sc.src = "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit&onload=bkTs";
    sc.async = true;
    sc.onerror = () => { dead = true; flush(""); };
    doc.head.appendChild(sc);
  }, 0));
  // A page left open asks again for the times when it comes back; a calendar just connected
  // hands its busy times over once (?fb=).
  let at = Date.now();
  function fresh(q) {
    at = Date.now();
    api(U.slots + q).then((r) => {
      const j = r.j;
      if (r.s !== 200 || !j || !j.slots) return;
      starts = j.taking === false ? [] : K.free(j.slots.map((x) => Date.parse(x.start)), dur, (j.busy || []).map((x) => [Date.parse(x.start), Date.parse(x.end)]));
      draw();
      if (j.busy && $("#fc")) $("#fc").textContent = "Hiding your busy times";
      if (j.taking === false) $("#none").textContent = K.firstName(host.name) + " isn't taking bookings right now";
    });
  }
  const fb = new URLSearchParams(location.search).get("fb");
  if (fb && U.slots) { history.replaceState(null, "", location.pathname); fresh("?fb=" + encodeURIComponent(fb)); }
  const back = () => { if (!doc.hidden && U.slots && Date.now() - at > 120000) fresh(""); };
  doc.addEventListener("visibilitychange", back);
  addEventListener("focus", back);
}

/** The manage page: move with one tap and Undo; cancel with an optional reason. */
export function managePart() {
  function moveTo(s) {
    const was = D.cur, o = (cur = { s, back: was, state: "sending", moved: true, b: Object.assign({}, D.b, { start: iso(s), end: iso(s + dur) }) });
    D.cur = s;
    draw();
    shown(o);
    o.req = api(U.move, { start: iso(s), zone }).then((r) => {
      const ok200 = r.s === 200 && r.j && r.j.booking;
      if (ok200) o.done = true;
      if (o.state === "undone") return;
      if (ok200) {
        D.b = o.b;
        held(o, r.j.booking);
        summary();
        return say("Moved to " + K.day(s, zone, loc) + " " + K.time(s, zone, loc));
      }
      D.cur = was;
      if (r.s === 409) starts = starts.filter((x) => x !== s);
      draw();
      if (r.s === 409) return taken(o, (r.j && r.j.nearest) || []);
      pop('<div class="sh"><p role="alert" id="card-t">' + oops(r) + '</p><button type="button" class="btn" data-x>OK</button></div>');
    });
  }
  const tap = moveTo, retry = moveTo;
  // Undo waits for the move it undoes to settle, then asks the service to undo it (POST /b/undo: the
  // move hasn't reached Google or the host yet). If the old time went meanwhile, or the window
  // closed, the booking stays where the service has it, and the page says so.
  function revert(o) {
    const kept = Object.assign({}, D.b, o.b);
    D.cur = o.back;
    D.b = Object.assign({}, D.b, { start: iso(o.back), end: iso(o.back + dur) });
    draw();
    summary();
    sheet.close();
    o.req.then(() => (o.done ? api(U.undo, { manage: String(D.b.manageUrl || "").split("/").pop() }) : { s: 204 })).then((r) => {
      if (ok(r)) return;
      const j = r.j || {};
      D.cur = o.s;
      D.b = Object.assign(kept, j.booking || {});
      draw();
      summary();
      notice(j.kept ? "Your old time went. You keep " + K.day(o.s, zone, loc) + ", " + K.time(o.s, zone, loc) : r.s === 409 ? "Too late to undo" : oops(r));
    });
  }
  function summary() {
    $("#mine").innerHTML = K.card({ booking: D.b, zone, loc, host, type: ty, head: "Your time", mail: D.mail });
  }
  H.push((t) => {
    if (t.id === "cx") { $("#cxf").hidden = false; t.hidden = true; return $("#cxf textarea").focus(), 1; }
    if (t.id !== "cxgo") return;
    t.disabled = true;
    api(U.cancel, { reason: $("#cxf textarea").value.trim() || undefined }).then((r) => {
      if (!ok(r)) return (t.disabled = false), say(oops(r));
      $("main").innerHTML = D.bye;
      $("h1").focus();
      say("Cancelled");
    });
    return 1;
  });
  if (location.hash === "#cancel") $("#cx").focus();
}

/** The confirmation page: Undo while the window lasts, and what the service says about it. */
export function confirmedPart() {
  const left = D.b && D.b.undoUntil ? Date.parse(D.b.undoUntil) - Date.now() : 0;
  setTimeout(() => { const u = $(".undo"); if (u) u.remove(); }, Math.max(0, left));
  H.push((t, d) => {
    if (!("undo" in d)) return;
    t.disabled = true;
    api(U.undo, { manage: String(D.b.manageUrl || "").split("/").pop() }).then((r) => {
      if (ok(r)) { $("main").innerHTML = D.bye; return say("Undone"); }
      $(".undo").outerHTML = '<p class="inv" role="status">' + (r.s === 409 ? "Too late to undo" : oops(r)) + "</p>";
    });
    return 1;
  });
}

/** The code page: one field shown as six boxes, sent when the sixth digit arrives. */
export function codePart() {
  const i = $("#cd"), bx = doc.querySelectorAll(".bx span");
  function put() {
    i.value = i.value.replace(/\D/g, "").slice(0, 6);
    bx.forEach((b, n) => { b.textContent = i.value[n] || ""; b.classList.toggle("on", n === Math.min(i.value.length, 5)); });
    if (i.value.length < 6) return;
    i.disabled = true;
    api(U.verify, { email: D.email, code: i.value }).then((r) => {
      i.disabled = false;
      if (ok(r)) return location.replace(U.ret || "/");
      i.value = "";
      put();
      i.focus();
      $("#cerr").textContent = r.s === 400 ? "Wrong code" : oops(r);
    });
  }
  i.addEventListener("input", put);
  put();
  H.push((t) => {
    if (t.id !== "resend") return;
    t.disabled = true;
    api(U.code, { email: D.email }).then((r) => {
      t.textContent = ok(r) ? "Sent" : oops(r);
      say(t.textContent);
      if (!ok(r)) t.disabled = false;
    });
    return 1;
  });
}

/** Forget me. */
export function forgetPart() {
  H.push((t) => {
    if (t.id !== "fg") return;
    t.disabled = true;
    api(U.forget, {}).then((r) => {
      if (!ok(r)) return (t.disabled = false), say(oops(r));
      $("main").innerHTML = '<h1 tabindex="-1">Forgotten</h1>';
      $("h1").focus();
      say("Forgotten");
    });
    return 1;
  });
}
