// What the server and the page share: escaping, time zones, formatting, the day model and the
// booked card. `kit` is self-contained (it refers to nothing outside itself) because the page's
// script is built from its source text (tools/build-book-scripts.mjs), so the server's HTML and the
// page's re-renders come from the same code.
//
// Times: instants are epoch milliseconds or ISO strings with Z. A day is a key "YYYY-MM-DD" in a
// zone, found with Intl parts; a key is only ever turned back into a date at 12:00 UTC to name its
// weekday, and stepped with Date.UTC, never parsed with `new Date("YYYY-MM-DD")`.

export function kit() {
  const NB = "\u00a0";
  const esc = (s) => String(s == null ? "" : s).replace(/[&<>"']/g, (c) => "&#" + c.charCodeAt(0) + ";");
  // Old names some browsers still report, and the names people use for them now.
  const OLD = { "Asia/Calcutta": "Asia/Kolkata", "Asia/Katmandu": "Asia/Kathmandu", "Asia/Saigon": "Asia/Ho_Chi_Minh", "Europe/Kiev": "Europe/Kyiv", "Etc/UTC": "UTC" };
  const F = new Map();
  const fmt = (loc, zone, o) => {
    const k = loc + "|" + zone + "|" + JSON.stringify(o);
    let f = F.get(k);
    if (!f) F.set(k, (f = new Intl.DateTimeFormat(loc, Object.assign({ timeZone: zone }, o))));
    return f;
  };
  /** A zone name the page can use, canonical, or null (abbreviations like EST are refused). */
  const zoneOk = (z) => {
    if (typeof z !== "string" || !(z === "UTC" || z.indexOf("/") > 0)) return null;
    try {
      const r = fmt("en-US", OLD[z] || z, {}).resolvedOptions().timeZone;
      return OLD[r] || r;
    } catch (e) { return null; }
  };
  const city = (z) => {
    if (z === "UTC") return "UTC";
    const m = /^Etc\/GMT([+-])(\d+)$/.exec(z);
    if (m) return "GMT" + (m[1] === "+" ? "-" : "+") + m[2];   // Etc signs are inverted
    return z.slice(z.lastIndexOf("/") + 1).replace(/_/g, " ");
  };
  const zoneName = (z) => (city(z).indexOf("GMT") === 0 || z === "UTC" ? city(z) : city(z) + " time");
  // "3:00 PM" → "3:00 pm"; the narrow and thin spaces become ones the font has.
  const clean = (parts) => parts.map((p) => (p.type === "dayPeriod" ? p.value.toLowerCase() : p.value)).join("")
    .replace(/\u202f/g, NB).replace(/\u2009/g, "");
  const HM = { hour: "numeric", minute: "2-digit" };
  const ms = (t) => (typeof t === "number" ? t : Date.parse(t));
  const time = (t, z, loc) => clean(fmt(loc, z, HM).formatToParts(ms(t)));
  // Across the guest's midnight Intl would add both dates; two times read better.
  const range = (a, b, z, loc) => (key(a, z) === key(b, z) ? clean(fmt(loc, z, HM).formatRangeToParts(ms(a), ms(b))) : time(a, z, loc) + "–" + time(b, z, loc));
  const offset = (t, z) => {   // minutes east of UTC at that instant
    const p = {};
    for (const x of fmt("en-US", z, { hourCycle: "h23", year: "numeric", month: "numeric", day: "numeric", hour: "numeric", minute: "numeric", second: "numeric" }).formatToParts(ms(t))) p[x.type] = +x.value;
    return Math.round((Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, p.second) - Math.floor(ms(t) / 1000) * 1000) / 60000);
  };
  const key = (t, z) => {
    const p = {};
    for (const x of fmt("en-US", z, { year: "numeric", month: "2-digit", day: "2-digit" }).formatToParts(ms(t))) p[x.type] = x.value;
    return p.year + "-" + p.month + "-" + p.day;
  };
  const noon = (k) => { const a = k.split("-"); return Date.UTC(+a[0], a[1] - 1, +a[2], 12); };
  const step = (k, n) => { const a = k.split("-"); return new Date(Date.UTC(+a[0], a[1] - 1, +a[2] + n, 12)).toISOString().slice(0, 10); };
  const DAY = { weekday: "short", day: "numeric", month: "short" };
  const dayName = (k, loc, o) => fmt(loc, "UTC", o || DAY).format(noon(k));
  const day = (t, z, loc) => dayName(key(t, z), loc);
  /** "today", "tomorrow" or "Tue, Oct 21", for the instant in the zone. */
  const when = (t, z, loc, now) => {
    const k = key(t, z), today = key(now, z);
    return k === today ? "today" : k === step(today, 1) ? "tomorrow" : dayName(k, loc);
  };
  /** Starts that overlap nothing busy. Both lists in ms; `busy` [[start, end]]. */
  const free = (starts, len, busy) => (busy && busy.length
    ? starts.filter((s) => !busy.some((b) => s < b[1] && s + len > b[0])) : starts);
  // Starts travel as epoch minutes, the first whole and each next one as the gap from the last.
  const pack = (starts) => starts.map((s, i) => (i ? (s - starts[i - 1]) / 60000 : s / 60000));
  const unpack = (a) => { let t = 0; return a.map((d) => (t += d * 60000)); };
  /** The days in the zone: [{k, s: [ms]}] in order, only days that have times. */
  const days = (starts, z) => {
    const out = [];
    for (const s of starts) {
      const k = key(s, z), last = out[out.length - 1];
      if (last && last.k === k) last.s.push(s); else out.push({ k: k, s: [s] });
    }
    return out;
  };
  const wd = (k) => new Date(noon(k)).getUTCDay();   // 0 is Sunday
  const weekStart = (loc) => {   // the locale's first weekday, as 0–6
    try { const l = new Intl.Locale(fmt(loc, "UTC", {}).resolvedOptions().locale), w = l.getWeekInfo ? l.getWeekInfo() : l.weekInfo; return w ? w.firstDay % 7 : 1; } catch (e) { return 1; }
  };
  const dayButton = (k, on, sel, inner) => '<button type="button" class="d" data-k="' + k + '"' +
    (on ? (k === sel ? ' aria-pressed="true"' : ' aria-pressed="false" tabindex="-1"') : " disabled") + ">" + inner + "</button>";
  const sr = (k, loc, on) => '<span class="sr"> ' + esc(dayName(k, loc, { month: "long" })) + (on ? "" : ", no times") + "</span>";
  /** The month grid, one month at a time as Calendly and Cal.com page it: the month of `month`
   * ("YYYY-MM", else the selected day's, else the first with times), its name with the year, and
   * arrows that go only where a day with times is. Weeks start as the locale starts them. */
  const cal = (ds, sel, loc, month) => {
    if (!ds.length) return "";
    const have = new Set(ds.map((d) => d.k)), ws = weekStart(loc), first = ds[0].k, last = ds[ds.length - 1].k;
    let m = (month || (have.has(sel) ? sel : first)).slice(0, 7);
    if (m < first.slice(0, 7)) m = first.slice(0, 7); else if (m > last.slice(0, 7)) m = last.slice(0, 7);
    const prev = ds.filter((d) => d.k.slice(0, 7) < m).pop(), next = ds.find((d) => d.k.slice(0, 7) > m);
    const arrow = (to, label, glyph) => '<button type="button" class="mn"' + (to ? ' data-m="' + to.k.slice(0, 7) + '"' : " disabled") + ' aria-label="' + label + '">' + glyph + "</button>";
    let k = m + "-01";
    let h = '<div class="mo"><div class="mh"><h3>' + esc(dayName(k, loc, { month: "long", year: "numeric" })) + "</h3>" +
      arrow(prev, "Previous month", "\u2039") + arrow(next, "Next month", "\u203a") + '</div><div class="cg">';
    for (let i = 0; i < 7; i++) h += '<b aria-hidden="true">' + esc(dayName(step("2023-01-01", (ws + i) % 7), loc, { weekday: "narrow" })) + "</b>";
    h += "<i></i>".repeat((wd(k) - ws + 7) % 7);
    for (; k.slice(0, 7) === m; k = step(k, 1)) h += dayButton(k, have.has(k), sel, esc(dayName(k, loc, { day: "numeric" })) + sr(k, loc, have.has(k)));
    return h + "</div></div>";
  };
  /** One day's times. `cur` is the booked start a manage page keeps: the same tile, filled. */
  const grid = (d, z, loc, cur) => {
    let h = "";
    for (const s of d ? d.s : []) {
      h += s === cur
        ? '<span class="t cur" aria-current="true">' + esc(time(s, z, loc)) + '<span class="sr">, your time</span></span>'
        : '<button type="button" class="t" data-s="' + s + '">' + esc(time(s, z, loc)) + "</button>";
    }
    return h;
  };
  const firstName = (n) => String(n || "").trim().split(/\s+/)[0];
  const href = (u) => (/^(https?:|mailto:|tel:|\/(?!\/))/i.test(String(u || "")) ? esc(u) : "#");
  const CHECK = '<svg class="ck" viewBox="0 0 24 24" aria-hidden="true"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg>';
  /** Where they meet, as the card shows it. */
  const place = (p, detail, host, pending) => {
    if (!p) return "";
    const k = p.kind, lab = esc(p.label || ""), first = esc(firstName(host && host.name));
    if (k === "phone_host_calls") return "<p>" + first + " calls you" + (detail ? " on " + esc(detail) : "") + "</p>";
    if (k === "phone_guest_calls") return "<p>Call " + first + (detail ? ' on <a href="tel:' + esc(String(detail).replace(/[^+\d]/g, "")) + '">' + esc(detail) + "</a>" : "") + "</p>";
    if (k === "in_person") {
      const a = detail || p.address || "";
      return "<p>" + esc(a) + (a ? ' · <a href="https://www.google.com/maps/search/?api=1&amp;query=' + encodeURIComponent(a) + '" rel="noopener" target="_blank">Map</a>' : "") + "</p>";
    }
    if (detail && /^https?:/i.test(detail)) {
      return '<p class="link"><a href="' + href(detail) + '" rel="noopener" target="_blank">' + esc(detail.replace(/^https?:\/\//, "")) +
        '</a> <button type="button" class="q" data-copy="' + esc(detail) + '">Copy</button></p>';
    }
    return "<p>" + lab + (pending ? "" : k === "meet" ? " · link in the invite" : "") + "</p>";
  };
  /**
   * The booked card: the confirmation page and the sheet after a tap. `b` is the booking; with no
   * manageUrl yet it is still being made, so the links wait.
   */
  const card = (o) => {
    const b = o.booking, z = o.zone, loc = o.loc, host = o.host || {}, type = o.type || {};
    const p = typeof b.place === "object" && b.place ? b.place : (type.places || []).find((x) => x.id === b.place) || null;
    const hz = type.hostZone, first = firstName(host.name);
    const theirs = hz && hz !== z && offset(b.start, hz) !== offset(b.start, z)
      ? " · " + (key(b.start, hz) !== key(b.start, z) ? day(b.start, hz, loc) + " " : "") + time(b.start, hz, loc) + " for " + first : "";
    const ready = !!b.manageUrl, sent = b.invite ? b.invite === "sent" : ready && !o.pending;
    // Cancelled while it was being made (the host deleted it): the time and nothing to do with it.
    if (b.status === "cancelled") return '<h2 id="card-t" tabindex="-1">Cancelled</h2><p class="when"><b>' + esc(day(b.start, z, loc) + ", " + range(b.start, b.end, z, loc)) + "</b><br>" +
      esc(zoneName(z)) + "</p><p>" + esc(type.title || "") + (first ? " with " + esc(host.name) : "") + "</p>";
    return (o.head || o.sending ? "" : CHECK) + '<h2 id="card-t" tabindex="-1">' + esc(o.head || (o.sending ? "Booking…" : o.moved ? "Moved" : "Booked")) + "</h2>" +
      '<p class="when"><b>' + esc(day(b.start, z, loc) + ", " + range(b.start, b.end, z, loc)) + "</b><br>" + esc(zoneName(z) + theirs) + "</p>" +
      "<p>" + esc(type.title || "") + (first ? " with " + esc(host.name) : "") + "</p>" +
      place(p, b.placeDetail, host, !sent) +
      (b.guestEmail && !o.sending ? '<p class="inv">' + (b.invite === "failed" ? "Invite didn't go out" + (o.mail === false ? "" : ". Details emailed to " + esc(b.guestEmail))
        : (sent ? "Invite sent to " : "Sending invite to ") + esc(b.guestEmail)) + "</p>" : "") +
      '<p class="acts">' + (b.icsUrl ? '<a class="btn" href="' + href(b.icsUrl) + '">Add to calendar</a>' : '<span class="btn off">Add to calendar</span>') +
      (o.head || o.moved ? "" : ready ? '<a href="' + href(b.manageUrl) + '">Change</a><a href="' + href(b.manageUrl) + '#cancel">Cancel</a>' : "<span>Change</span><span>Cancel</span>") + "</p>";
  };
  return { NB, esc, zoneOk, city, zoneName, time, range, offset, key, step, noon, dayName, day, when, free, pack, unpack, days, cal, grid, firstName, href, place, card, fmt };
}
