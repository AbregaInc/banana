// Booking, end to end (docs/design/BOOKING.md §5 and §12): reserve in D1 and answer, then make the
// event at Google after the answer; the Undo window, the invite, moving, cancelling, the manage page's
// live read, and the host's push. The conditional insert is the lock: it never holds across an
// await, and two guests racing for one time get one booking.
//
// Never logged: names, emails, notes, event or calendar ids, links.

import { accessToken } from "../calendar.js";
import { GoogleError, GoogleRefused } from "../google.js";
import { newId, hex } from "../crypto.js";
import { dayAround, generateSlots, MINUTE, nearest, shortWhen } from "./slots.js";
import { publicPlace, typesFrom } from "./types.js";
import { readDay, STALE, rebuildSnapshot } from "./busy.js";
import { bookingEmail } from "./email.js";
import { icsFile } from "./ics.js";

const DAY = 24 * 60 * MINUTE;
export const UNDO = 5000;                  // the Undo window after a booking
const LEASE = 2 * MINUTE;                  // the minute job takes over work not done by then
const TRIES = 3;                           // Google tries before a booking is marked failed, and for each step after
const BEYOND = 400 * DAY;
const LIVE = ["pending", "confirmed"];

// ---- the host, as one read ----

const HOST_SQL = `SELECT h.handle, h.account_id, h.time_zone AS handle_zone, a.display_name, a.time_zone AS account_zone,
    s.horizon_json, s.types_json, s.computed_at, s.told_at,
    (SELECT g.name FROM google_links g WHERE g.account_id = h.account_id AND g.status <> 'unlinked' ORDER BY g.created_at LIMIT 1) AS google_name,
    (SELECT g.email FROM google_links g WHERE g.account_id = h.account_id AND g.status <> 'unlinked' ORDER BY g.created_at LIMIT 1) AS google_email
  FROM booking_handles h JOIN accounts a ON a.id = h.account_id LEFT JOIN busy_snapshot s ON s.account_id = h.account_id`;
// The live bookings, and today's finished ones (perDay counts the whole host day): a day starts at
// most 26 hours before now in any zone.
// Every row of the account (live, cancelled, failed) whose meeting isn't long over: its events at
// Google count by the row, so a cancel frees the time at once, before Google and the snapshot
// catch up.
const BOOKINGS_SQL = `SELECT b.id, b.type_id, b.status, b.start_at, b.end_at, b.block_start, b.block_end FROM bookings b
  JOIN booking_handles h ON h.account_id = b.account_id WHERE b.end_at > ?`;
const TODAY_BACK = 26 * 60 * MINUTE;

function hostFrom(row, bookings, now) {
  if (!row) return null;
  let horizon = null, records = [];
  try { horizon = row.horizon_json ? JSON.parse(row.horizon_json) : null; } catch { horizon = null; }
  try { records = row.types_json ? JSON.parse(row.types_json) : []; } catch { records = []; }
  const zone = row.handle_zone ?? row.account_zone ?? null;
  return {
    handle: row.handle, account: row.account_id, zone, accountZone: row.account_zone ?? zone,
    name: row.display_name || row.google_name || row.handle, email: row.google_email ?? null,
    computedAt: Number(row.computed_at ?? 0), toldAt: Number(row.told_at ?? 0),
    horizon: horizon && Number.isFinite(horizon.from) ? horizon : null,
    types: typesFrom(row.types_json ? records : [], zone),
    bookings: bookings.filter((b) => LIVE.includes(b.status ?? "confirmed"))
      .map((b) => ({ ...b, start_at: Number(b.start_at), end_at: Number(b.end_at), block_start: Number(b.block_start), block_end: Number(b.block_end) })),
    ownIds: new Set(bookings.map((b) => b.id)),
    now,
  };
}

/**
 * The host behind a handle (or an account), with its snapshot and live bookings: two D1 reads in
 * parallel on the read replica. A host with no snapshot yet waits for its first build; a stale one
 * is served and rebuilt after the answer.
 */
export async function readHost(ctx, { handle, account }) {
  const { deps } = ctx;
  const read = deps.replica ?? deps.db;
  const t = deps.now();
  const where = handle ? "h.handle = ?" : "h.account_id = ?";
  const key = handle ?? account;
  const [row, bookings] = await Promise.all([read.first(`${HOST_SQL} WHERE ${where}`, key), read.all(`${BOOKINGS_SQL} AND ${where}`, t - TODAY_BACK, key)]);
  let host = hostFrom(row, bookings, t);
  if (!host) return null;
  if (!host.computedAt) {
    try { await rebuildSnapshot(deps, host.account, { vault: ctx.vault, force: true }); }
    catch (error) { console.log(`booking: first snapshot failed (${error.name})`); }
    const fresh = await deps.db.first(`${HOST_SQL} WHERE h.account_id = ?`, host.account);
    host = hostFrom(fresh, bookings, t);
  } else if (t - host.computedAt > STALE) {
    deps.defer(rebuildSnapshot(deps, host.account, { vault: ctx.vault }).catch((error) => console.log(`booking: snapshot failed (${error.name})`)));
  }
  return host;
}

/** Why the host can't take bookings of this type now, or null. */
export function refusal(host, type) {
  if (!host?.horizon) return "unknown";
  if (host.horizon.unknown > 0) return "unknown";
  if (!type || !type.active) return "inactive";
  if (!writerOf(host, type)) return "no_writer";
  return null;
}

/** The Google link and calendar a type's events go to. */
export function writerOf(host, type) {
  const write = host.horizon?.write ?? null;
  if (type.calendar) {
    // The calendar the app picked: through the link that reads it, or the link of its email (a
    // calendar left out of busy time can still take the events).
    const cal = host.horizon?.calendars?.find((c) => c.id === type.calendar.id) ?? null;
    if (cal && (host.horizon.writers ?? [host.horizon.write]).some((w) => w?.sub === cal.sub)) return { sub: cal.sub, id: cal.id };
    const link = (host.horizon?.writers ?? []).find((w) => w.email === type.calendar.email);
    return link ? { sub: link.sub, id: type.calendar.id } : null;
  }
  return write ? { sub: write.sub, id: "primary" } : null;
}

/** The free slots of a type: the snapshot, the bookings, the engine. `except` leaves one booking's row out (a move). */
export function slotsOf(host, type, { now = host.now, except = null, days = null, live = null } = {}) {
  const busy = [];
  // An event a booking of this account made counts by its row in D1, the truth for it: a move or a
  // cancel shows at once, before Google and the snapshot catch up (cancelled rows are among
  // ownIds). Any other booking's event (another account's, a row long gone) is busy like any event,
  // unless it is marked Free.
  const own = new Set([...(host.ownIds ?? []), ...host.bookings.map((r) => r.id)]);
  if (except) own.add(except);
  for (const b of live ?? host.horizon?.busy ?? []) {
    if (b[2] && (own.has(b[2]) || b[3] === 0)) continue;
    busy.push([b[0], b[1]]);
  }
  if (!live && host.horizon) busy.push([host.horizon.to, host.horizon.to + BEYOND]);   // past the snapshot: unknown
  for (const r of host.bookings) if (r.id !== except) busy.push([r.block_start, r.block_end]);
  const booked = host.bookings.filter((r) => r.type_id === type.id && r.id !== except).map((r) => r.start_at);
  return generateSlots({ type, now, busy, booked, days });
}

// ---- views ----

export async function manageRef(ctx, manageId) { return `${manageId}.${await ctx.signer.manage(manageId)}`; }

function placeDetail(row) {
  if (row.status !== "confirmed" && row.place_kind !== "phone_host_calls" && row.place_kind !== "in_person") return null;
  return row.place_detail ?? null;
}

/** The booking as the pages take it (CONTRACT.md's confirmed.view.booking, plus its state). */
export async function bookingView(ctx, row, { nearestSlots = null } = {}) {
  const ref = await manageRef(ctx, row.manage_id);
  const t = ctx.deps.now();
  // Undo: the booking's own window while nobody is invited yet, or a move's while Google hasn't heard of it.
  const end = row.invite === "held" && Number(row.undo_until) > t && LIVE.includes(row.status) ? Number(row.undo_until)
    : row.status === "confirmed" && Number(row.move_undo_until) > t ? Number(row.move_undo_until) : null;
  const until = end ? new Date(end).toISOString() : null;
  return {
    start: new Date(Number(row.start_at)).toISOString(),
    end: new Date(Number(row.end_at)).toISOString(),
    place: row.place_kind ? { id: row.place_id, kind: row.place_kind, label: row.place_label ?? placeLabel(row.place_kind) } : null,
    placeDetail: placeDetail(row),
    manageUrl: `/m/${ref}`,
    icsUrl: `/b/${row.manage_id}.ics?sig=${ref.split(".")[1]}`,
    statusUrl: `/m/${ref}/state`,
    guestEmail: row.guest_email ?? null,
    undoUntil: until,
    undoMs: end ? end - t : 0,                           // what's left of it, by the service's clock
    undoes: end ? (Number(row.move_undo_until) === end ? "move" : "booking") : null,
    status: row.status,
    invite: row.invite,
    meet: row.place_kind === "meet" ? row.meet_state ?? "pending" : null,
    ...(nearestSlots ? { nearest: nearestSlots } : {}),
  };
}
const placeLabel = (kind) => ({ meet: "Google Meet", zoom: "Zoom", phone_host_calls: "Phone call", phone_guest_calls: "Phone call", in_person: "In person", link: "Video call" })[kind] ?? null;

/** What a booking email needs beyond the row. */
async function mailFields(ctx, row, host) {
  const ref = await manageRef(ctx, row.manage_id);
  const base = ctx.config.bookUrl;
  const type = host?.types.find((x) => x.id === row.type_id);
  return {
    ...row, hostName: host?.name ?? "your host", hostEmail: host?.email ?? null,
    manageUrl: `${base}/m/${ref}`, pageUrl: host ? `${base}/${host.handle}${type ? `/${type.slug}` : ""}` : base,
  };
}

/** Sends one booking email; failures are logged, never thrown. */
export async function mail(ctx, kind, row, host, extra = {}) {
  if (!row.guest_email) return false;
  try {
    await ctx.deps.email.send(bookingEmail(kind, { ...(await mailFields(ctx, row, host)), ...extra }, { from: ctx.config.emailFrom }));
    return true;
  } catch (error) {
    console.log(`booking: ${kind} email failed (${error.code ?? error.name})`);
    return false;
  }
}

/** A visible push to the host's devices, in the host's zone. */
/**
 * A visible push to the host's devices, in the host's zone. With `row`, a tap opens the booking's
 * event: `b.cal` is its calendar's Google id ("primary" named by the link's email, which is that
 * calendar's id) and `b.event` the event's id, left out when the event is deleted (`gone`).
 * `b.start` is the booking's start (ms) whenever there is a row, and `b.cancelled` is true on the
 * pushes about a cancel, so the app can open the Plan on that day.
 * Payload: {aps: {alert: {title, body}, sound, thread-id}, b: {k: "booking", cal?, event?, start?, cancelled?}}.
 */
export async function pushHost(ctx, account, body, collapse, { row = null, gone = false, cancelled = false } = {}) {
  const b = { k: "booking" };
  try {
    if (row && Number.isFinite(Number(row.start_at))) b.start = Number(row.start_at);
    if (cancelled) b.cancelled = true;
    if (row?.calendar_id) {
      let cal = row.calendar_id;
      if (cal === "primary") cal = (await ctx.deps.db.first("SELECT email FROM google_links WHERE sub = ?", row.calendar_sub))?.email ?? null;
      if (cal) {
        b.cal = cal;
        if (!gone && row.id) b.event = row.id;
      }
    }
    await ctx.push(account, {
      payload: { aps: { alert: { title: "Booking", body }, sound: "default", "thread-id": "booking" }, b },
      collapseId: collapse, pushType: "alert", priority: 10, label: "push(booking)",
    });
  } catch (error) { console.log(`push(booking): failed (${error.name})`); }
}

// ---- the event at Google ----

const escapeHtml = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

/** The event's description: the note, the phone, and the change link. HTML, as Google renders it. */
function description(row, manageUrl) {
  const lines = [];
  if (row.note) lines.push(escapeHtml(row.note).replace(/\n/g, "<br>"));
  if (row.place_kind === "phone_host_calls" && row.guest_phone) lines.push(`Call ${escapeHtml(row.guest_name)} on ${escapeHtml(row.guest_phone)}`);
  if (row.place_kind === "phone_guest_calls" && row.place_detail) lines.push(`${escapeHtml(row.guest_name)} calls ${escapeHtml(row.place_detail)}`);
  lines.push(`Booked with Banana. Change or cancel: <a href="${escapeHtml(manageUrl)}">${escapeHtml(manageUrl)}</a>`);
  return lines.join("<br><br>");
}

function eventBody(row, type, manageUrl, { withGuest }) {
  const event = {
    id: row.id,
    summary: `${row.type_title}: ${row.guest_name ?? "Guest"}`,
    description: description(row, manageUrl),
    start: { dateTime: new Date(Number(row.start_at)).toISOString(), timeZone: type?.timeZone ?? "UTC" },
    end: { dateTime: new Date(Number(row.end_at)).toISOString(), timeZone: type?.timeZone ?? "UTC" },
    reminders: { useDefault: true },
    guestsCanModify: false,
    extendedProperties: { private: { bananaBooking: row.id } },
  };
  if (withGuest) event.attendees = [{ email: row.guest_email, displayName: row.guest_name ?? undefined }];
  if (row.place_kind === "meet") event.conferenceData = { createRequest: { requestId: row.id, conferenceSolutionKey: { type: "hangoutsMeet" } } };
  else if (["zoom", "link"].includes(row.place_kind)) event.location = row.place_detail;
  else if (row.place_kind === "in_person") event.location = row.place_detail;
  else if (row.place_kind === "phone_host_calls") event.location = row.guest_phone ? `Phone: ${row.guest_phone}` : "Phone";
  else if (row.place_kind === "phone_guest_calls") event.location = row.place_detail ? `Phone: ${row.place_detail}` : "Phone";
  return event;
}

/** The Meet link and state from an event Google returned. */
function meetOf(event) {
  const status = event?.conferenceData?.createRequest?.status?.statusCode;
  const video = event?.conferenceData?.entryPoints?.find((e) => e.entryPointType === "video")?.uri ?? null;
  if (video) return { state: "ready", url: video };
  if (status === "pending") return { state: "pending", url: null };
  return { state: "disabled", url: null };
}

async function linkAccess(ctx, sub) {
  const link = await ctx.deps.db.first("SELECT sub, account_id, email, refresh_token, scopes, status FROM google_links WHERE sub = ?", sub);
  if (!link) throw new GoogleRefused("link gone");
  return accessToken(ctx.deps, ctx.vault, link);
}

// ---- reserve (the answer) ----

const BOOKING_COLUMNS = `id, manage_id, account_id, type_id, type_title, start_at, end_at, block_start, block_end, status, invite, undo_until,
  place_id, place_kind, place_detail, meet_state, guest_account_id, guest_name, guest_email, guest_phone, guest_zone, note, idem_key,
  ip_hash, calendar_sub, calendar_id, attempts, next_at, created_at, timed_at, updated_at`;

/**
 * Reserves a slot: the exact start must be one the engine offers now, then one conditional insert
 * takes it, unless another booking (padded by buffers) overlaps, the email already has a future
 * time of this type, or the day is full. The event is made after the answer (`complete`).
 * @returns {Promise<{kind: "booked"|"taken"|"existing"|"full", row?: object, nearest?: object[]}>}
 */
export async function reserve(ctx, host, type, input) {
  const { deps } = ctx;
  const t = deps.now();
  const slots = slotsOf(host, type, { now: t });
  const start = Date.parse(input.start);
  const match = slots.find((s) => s.start === input.start);
  if (!match) return { kind: "taken", nearest: nearest(slots, start) };
  const end = start + type.minutes * MINUTE;
  const blockStart = start - type.bufferBefore * MINUTE, blockEnd = end + type.bufferAfter * MINUTE;
  const writer = writerOf(host, type);
  const place = input.place;
  const detail = place.kind === "zoom" || place.kind === "link" ? place.url
    : place.kind === "phone_guest_calls" ? place.phone
    : place.kind === "in_person" ? place.address
    : place.kind === "phone_host_calls" ? input.phone : null;
  const day = type.perDay ? dayAround(start, type.timeZone) : null;
  const row = {
    id: hex(deps.random(16)), manage_id: newId(deps.random), account_id: host.account, type_id: type.id, type_title: type.title,
    start_at: start, end_at: end, block_start: blockStart, block_end: blockEnd, status: "pending", invite: "held", undo_until: t + UNDO,
    place_id: place.id, place_kind: place.kind, place_detail: detail, meet_state: place.kind === "meet" ? "pending" : null,
    guest_account_id: input.guestAccount, guest_name: input.name, guest_email: input.email, guest_phone: input.phone ?? null,
    guest_zone: input.zone, note: input.note ?? null, idem_key: input.key, ip_hash: input.ipHash, calendar_sub: writer.sub, calendar_id: writer.id,
    attempts: 0, next_at: t + LEASE, created_at: t, timed_at: t, updated_at: t,
  };
  const columns = BOOKING_COLUMNS.split(",").map((s) => s.trim());
  const inserted = await deps.db.run(
    `INSERT INTO bookings (${columns.join(", ")}) SELECT ${columns.map(() => "?").join(", ")}
     WHERE NOT EXISTS (SELECT 1 FROM bookings WHERE account_id = ? AND status IN ('pending', 'confirmed') AND block_start < ? AND block_end > ?)
       AND NOT EXISTS (SELECT 1 FROM bookings WHERE account_id = ? AND type_id = ? AND guest_email = ? AND status IN ('pending', 'confirmed') AND end_at > ?)
       AND (? = 0 OR (SELECT COUNT(*) FROM bookings WHERE account_id = ? AND type_id = ? AND status IN ('pending', 'confirmed') AND start_at >= ? AND start_at < ?) < ?)`,
    ...columns.map((k) => row[k]),
    host.account, blockEnd, blockStart,
    host.account, type.id, input.email, t,
    type.perDay ? 1 : 0, host.account, type.id, day?.from ?? 0, day?.to ?? 0, type.perDay ?? 0);
  if (inserted.changes) return { kind: "booked", row, fresh: true };
  // Why not: the same request again (a retry racing its first try), the email's own time, or the slot.
  const again = await findRetry(ctx, input);
  if (again) return { kind: "booked", row: again };
  const own = await deps.db.first(
    "SELECT * FROM bookings WHERE account_id = ? AND type_id = ? AND guest_email = ? AND status IN ('pending', 'confirmed') AND end_at > ? ORDER BY start_at LIMIT 1",
    host.account, type.id, input.email, t);
  if (own) return { kind: "existing", row: own };
  const live = await deps.db.all("SELECT id, type_id, start_at, end_at, block_start, block_end FROM bookings WHERE account_id = ? AND status IN ('pending', 'confirmed') AND end_at > ?", host.account, t);
  const fresh = { ...host, bookings: live.map((b) => ({ ...b, start_at: Number(b.start_at), end_at: Number(b.end_at), block_start: Number(b.block_start), block_end: Number(b.block_end) })) };
  return { kind: "taken", nearest: nearest(slotsOf(fresh, type, { now: t }), start) };
}

/** A post seen before: the same key, email and start. */
export const findRetry = (ctx, input) => ctx.deps.db.first(
  "SELECT * FROM bookings WHERE idem_key = ? AND guest_email = ? AND start_at = ?", input.key, input.email, Date.parse(input.start));

// ---- complete (after the answer, and the minute job's retries) ----

/**
 * Makes the event for a pending booking: the slot's day is read again from Google (the snapshot may
 * be behind), the event is inserted with the guest held back while Undo is open, Meet is asked for,
 * and the booking is confirmed. A failure is tried again by the minute job, three times in all; then
 * the booking fails, the guest is emailed and the host pushed.
 * @param {{first?: boolean}} options first: right after the answer (the reservation's own try)
 */
export async function complete(ctx, id, { first = false } = {}) {
  const { deps } = ctx;
  const t = deps.now();
  const claimed = await deps.db.run(
    `UPDATE bookings SET attempts = attempts + 1, next_at = ?, updated_at = ? WHERE id = ? AND status = 'pending'
       AND ${first ? "attempts = 0" : "(next_at IS NULL OR next_at <= ?)"}`, t + LEASE, t, id, ...(first ? [] : [t]));
  if (!claimed.changes) return "skipped";
  const row = await deps.db.first("SELECT * FROM bookings WHERE id = ?", id);
  const host = await readHost(ctx, { account: row.account_id });
  const type = host?.types.find((x) => x.id === row.type_id) ?? null;
  try {
    // The day, read again, live. The booking itself isn't in the way (a retry after an insert got through).
    if (type && host.horizon?.calendars?.length) {
      const day = dayAround(Number(row.start_at), type.timeZone);
      const from = day.from - type.bufferBefore * MINUTE - DAY, to = day.to + type.bufferAfter * MINUTE + DAY;
      const live = await readDay(deps, ctx.vault, row.account_id, host.horizon.calendars, { from, to });
      const others = { ...host, bookings: host.bookings.filter((b) => b.id !== id) };
      const offered = slotsOf(others, type, { now: Number(row.created_at), except: id, days: day, live });
      if (!offered.some((s) => Date.parse(s.start) === Number(row.start_at))) {
        const gone = await deps.db.run("UPDATE bookings SET status = 'taken', next_at = NULL, updated_at = ? WHERE id = ? AND status = 'pending'", deps.now(), id);
        if (gone.changes) await mail(ctx, "taken", row, host);
        // The snapshot was behind: it catches up, so the next page doesn't offer the time again.
        deps.defer(rebuildSnapshot(deps, row.account_id, { vault: ctx.vault }).catch(() => {}));
        console.log("booking: the time was taken at Google meanwhile");
        return "taken";
      }
    }
    const access = await linkAccess(ctx, row.calendar_sub);
    const ref = await manageRef(ctx, row.manage_id);
    const manageUrl = `${ctx.config.bookUrl}/m/${ref}`;
    let event;
    try {
      event = await deps.google.insertEvent(access, row.calendar_id, eventBody(row, type, manageUrl, { withGuest: false }), { sendUpdates: "none" });
    } catch (error) {
      if (!(error instanceof GoogleError && error.status === 409)) throw error;
      event = await deps.google.getEvent(access, row.calendar_id, row.id);   // made by an earlier try
      if (!event || event.extendedProperties?.private?.bananaBooking !== row.id) throw new GoogleError("event id taken", 409);
    }
    let meet = row.place_kind === "meet" ? meetOf(event) : null;
    if (meet?.state === "pending") {
      const again = await deps.google.getEvent(access, row.calendar_id, row.id).catch(() => null);
      meet = meetOf(again ?? event);
      if (meet.state === "disabled" && again?.conferenceData?.createRequest?.status?.statusCode === "pending") meet = { state: "pending", url: null };
    }
    const confirmed = await deps.db.run(
      `UPDATE bookings SET status = 'confirmed', confirmed_at = ?, place_detail = COALESCE(?, place_detail), meet_state = COALESCE(?, meet_state),
         next_at = undo_until, updated_at = ? WHERE id = ? AND status = 'pending'`,
      deps.now(), meet?.url ?? null, meet?.state ?? null, deps.now(), id);
    if (!confirmed.changes) {
      // Undone or cancelled while the event was being made: it goes, quietly (nobody was invited).
      await deps.google.deleteEvent(access, row.calendar_id, row.id, { sendUpdates: "none" }).catch(() => {});
      await deps.db.run("UPDATE bookings SET google_pending = 0 WHERE id = ?", id);
      return "undone";
    }
    const wait = Number(row.undo_until) - deps.now();
    if (wait > 0 && first && deps.sleep) {
      deps.defer((async () => { await deps.sleep(wait); await releaseInvite(ctx, id); })().catch((error) => console.log(`booking: invite failed (${error.name})`)));
    } else if (wait <= 0) {
      await releaseInvite(ctx, id);
    }
    return "confirmed";
  } catch (error) {
    const tries = Number(row.attempts);   // this one included (the claim counted it)
    console.log(`booking: try ${tries} failed (${error.name} ${error.status ?? ""})`.trim());
    if (tries >= TRIES || error instanceof GoogleRefused) {
      const failed = await deps.db.run("UPDATE bookings SET status = 'failed', next_at = NULL, updated_at = ? WHERE id = ? AND status = 'pending'", deps.now(), id);
      if (failed.changes) {
        await mail(ctx, "failed", row, host);
        await pushHost(ctx, row.account_id, `${row.guest_name ?? "A guest"} couldn't book ${row.type_title}: Banana can't reach your Google Calendar`, `bk-${row.manage_id}`, { row, gone: true });
      }
      return "failed";
    }
    await deps.db.run("UPDATE bookings SET next_at = ? WHERE id = ? AND status = 'pending'", deps.now() + (tries === 1 ? MINUTE : 5 * MINUTE), id);
    return "retry";
  }
}

/**
 * After the Undo window: the guest goes on the event with sendUpdates=all (Google's invite), our
 * own confirmation goes, and the host is pushed. An Undo inside the window never sent anything.
 * Three tries; past them, or once the meeting is over, or when Google refuses the host's token,
 * the invite is given up (invite = failed): our own confirmation still goes, and the host is told.
 */
export async function releaseInvite(ctx, id) {
  const { deps } = ctx;
  const t = deps.now();
  const claimed = await deps.db.run(
    `UPDATE bookings SET invite = 'sending', next_at = ?, work_tries = work_tries + 1, updated_at = ? WHERE id = ? AND status = 'confirmed'
       AND ((invite = 'held' AND undo_until <= ?) OR (invite = 'sending' AND next_at <= ?))`, t + LEASE, t, id, t, t);
  if (!claimed.changes) return false;
  const row = await deps.db.first("SELECT * FROM bookings WHERE id = ?", id);
  const host = await readHost(ctx, { account: row.account_id });
  try {
    const access = await linkAccess(ctx, row.calendar_sub);
    if (row.guest_email) {
      const patched = await deps.google.patchEvent(access, row.calendar_id, row.id,
        { attendees: [{ email: row.guest_email, displayName: row.guest_name ?? undefined }] }, { sendUpdates: "all" });
      if (!patched) {
        // The host deleted it before the guest was invited: the booking is off, and as Google
        // never told the guest, we do.
        const gone = await deps.db.run("UPDATE bookings SET status = 'cancelled', cancelled_by = 'host', invite = 'held', sequence = sequence + 1, next_at = NULL, updated_at = ? WHERE id = ? AND status = 'confirmed'", deps.now(), id);
        if (gone.changes && deps.email?.enabled) await mail(ctx, "cancelled", { ...row, status: "cancelled" }, host);
        return false;
      }
    }
    await deps.db.run("UPDATE bookings SET invite = 'sent', next_at = NULL, work_tries = 0, updated_at = ? WHERE id = ?", deps.now(), id);
  } catch (error) {
    console.log(`booking: invite failed (${error.name} ${error.status ?? ""})`.trim());
    const over = error instanceof GoogleRefused || Number(row.work_tries) >= TRIES || deps.now() >= Number(row.end_at);
    if (!over) {
      await deps.db.run("UPDATE bookings SET next_at = ? WHERE id = ? AND invite = 'sending'", deps.now() + MINUTE * Number(row.work_tries), id);
      return false;
    }
    await deps.db.run("UPDATE bookings SET invite = 'failed', next_at = NULL, updated_at = ? WHERE id = ? AND invite = 'sending'", deps.now(), id);
    await pushHost(ctx, row.account_id, `${row.guest_name ?? "A guest"} booked ${row.type_title}, but Banana couldn't invite them: reconnect Google Calendar in Banana`, `bk-${row.manage_id}`, { row });
  }
  await confirmedNews(ctx, id, host);
  return true;
}

/** Our confirmation email and the host's push, once per booking. */
async function confirmedNews(ctx, id, host) {
  const sent = await ctx.deps.db.run("UPDATE bookings SET confirmed_mail = 1 WHERE id = ? AND confirmed_mail = 0", id);
  if (!sent.changes) return;
  const fresh = await ctx.deps.db.first("SELECT * FROM bookings WHERE id = ?", id);
  const type = host?.types.find((x) => x.id === fresh.type_id);
  const ref = await manageRef(ctx, fresh.manage_id);
  await mail(ctx, "confirmed", fresh, host, { ics: icsFor(ctx, fresh, host, type, ref) });
  if (fresh.invite === "sent") {
    const zone = host?.accountZone ?? type?.timeZone ?? "UTC";
    await pushHost(ctx, fresh.account_id, `${fresh.guest_name ?? "Someone"} booked ${fresh.type_title}, ${shortWhen(Number(fresh.start_at), zone)}`, `bk-${fresh.manage_id}`, { row: fresh });
  }
}

/** The booking's calendar file. */
export function icsFor(ctx, row, host, type, ref) {
  const manageUrl = `${ctx.config.bookUrl}/m/${ref}`;
  const location = row.place_kind === "phone_host_calls" ? `Phone: ${row.guest_phone ?? ""}` : row.status === "confirmed" ? row.place_detail : null;
  return icsFile({
    id: row.id, start: Number(row.start_at), end: Number(row.end_at), now: ctx.deps.now(),
    title: `${row.type_title} with ${host?.name ?? "your host"}`, location: location ?? null,
    description: `Change or cancel: ${manageUrl}`, url: manageUrl, cancelled: row.status === "cancelled",
    sequence: Number(row.sequence ?? 0), modified: Number(row.updated_at ?? row.created_at),
  });
}

// ---- undo, move, cancel ----

/**
 * Undo inside a window. A booking's: cancelled, the event (if made) deleted without a word to
 * anyone. A move's: back to the time before it (if nobody has taken it meanwhile), and Google and
 * the host never hear of the move. Returns "undone", "taken" (the move's old time went: the new
 * one stands) or "too_late".
 */
export async function undo(ctx, manageId) {
  const { deps } = ctx;
  const t = deps.now();
  const changed = await deps.db.run(
    `UPDATE bookings SET status = 'cancelled', cancelled_by = 'undo', google_pending = CASE WHEN status = 'confirmed' THEN 1 ELSE 0 END,
       work_tries = 0, sequence = sequence + 1, next_at = ?, updated_at = ? WHERE manage_id = ? AND status IN ('pending', 'confirmed') AND invite = 'held' AND undo_until > ?`, t, t, manageId, t);
  if (changed.changes) {
    const row = await deps.db.first("SELECT * FROM bookings WHERE manage_id = ?", manageId);
    if (row.google_pending) deps.defer(deleteAtGoogle(ctx, row.id).catch(() => {}));
    return "undone";
  }
  const row = await deps.db.first("SELECT * FROM bookings WHERE manage_id = ? AND status = 'confirmed' AND move_undo_until > ?", manageId, t);
  if (!row) return "too_late";
  let from;
  try { from = JSON.parse(row.moved_from); } catch { return "too_late"; }
  const back = await deps.db.run(
    `UPDATE bookings SET start_at = ?, end_at = ?, block_start = ?, block_end = ?, reminded_24 = ?, reminded_1 = ?, timed_at = ?,
       patch_pending = ?, pending_push = NULL, move_undo_until = NULL, moved_from = NULL, next_at = NULL, sequence = sequence + 1, updated_at = ?
     WHERE id = ? AND status = 'confirmed' AND move_undo_until > ?
       AND NOT EXISTS (SELECT 1 FROM bookings o WHERE o.account_id = ? AND o.id <> ? AND o.status IN ('pending', 'confirmed') AND o.block_start < ? AND o.block_end > ?)`,
    from.start_at, from.end_at, from.block_start, from.block_end, from.reminded_24, from.reminded_1, from.timed_at,
    from.patch_pending ? 1 : 0, t, row.id, t, row.account_id, row.id, from.block_end, from.block_start);
  if (back.changes) return "undone";
  // Someone took the old time in the moment between: the new time stands, and Google hears of it now.
  await deps.db.run("UPDATE bookings SET move_undo_until = NULL, moved_from = NULL, next_at = ? WHERE id = ? AND status = 'confirmed'", t, row.id);
  deps.defer(patchTime(ctx, row.id, null, { fromJob: true }).catch(() => {}));
  return "taken";
}

/**
 * Deletes a cancelled booking's event at Google (the guest told only once they were invited).
 * Three tries; past them, once the meeting is over, or when Google refuses the host's token, it is
 * given up and the host is told to delete the event themselves.
 */
export async function deleteAtGoogle(ctx, id) {
  const { deps } = ctx;
  const claimed = await deps.db.run(
    "UPDATE bookings SET work_tries = work_tries + 1, next_at = ? WHERE id = ? AND status = 'cancelled' AND google_pending = 1", deps.now() + LEASE, id);
  if (!claimed.changes) return false;
  const row = await deps.db.first("SELECT * FROM bookings WHERE id = ?", id);
  try {
    const access = await linkAccess(ctx, row.calendar_sub);
    await deps.google.deleteEvent(access, row.calendar_id, row.id, { sendUpdates: row.invite === "sent" ? "all" : "none" });
    await deps.db.run("UPDATE bookings SET google_pending = 0, next_at = NULL, work_tries = 0 WHERE id = ?", id);
    return true;
  } catch (error) {
    console.log(`booking: delete failed (${error.name} ${error.status ?? ""})`.trim());
    const over = error instanceof GoogleRefused || Number(row.work_tries) >= TRIES || deps.now() >= Number(row.end_at);
    if (!over) {
      await deps.db.run("UPDATE bookings SET next_at = ? WHERE id = ?", deps.now() + 5 * MINUTE, id);
      return false;
    }
    await deps.db.run("UPDATE bookings SET google_pending = 0, next_at = NULL WHERE id = ?", id);
    if (row.invite === "sent" && deps.now() < Number(row.end_at)) {
      await pushHost(ctx, row.account_id, `${row.guest_name ?? "A guest"} cancelled ${row.type_title}: Banana couldn't take it off your calendar, so delete it there`, `bk-${row.manage_id}`, { row, cancelled: true });
    }
    return false;
  }
}

/** The guest cancels: off at once here, the event deleted after the answer (Google tells everyone). */
export async function cancel(ctx, row, host, { by = "guest", reason = null } = {}) {
  const { deps } = ctx;
  const t = deps.now();
  const changed = await deps.db.run(
    `UPDATE bookings SET status = 'cancelled', cancelled_by = ?, google_pending = CASE WHEN status = 'confirmed' THEN 1 ELSE 0 END,
       work_tries = 0, sequence = sequence + 1, next_at = ?, updated_at = ? WHERE id = ? AND status IN ('pending', 'confirmed')`, by, t, t, row.id);
  if (!changed.changes) return false;
  deps.defer(deleteAtGoogle(ctx, row.id).catch(() => {}));
  if (by === "guest" && row.invite === "sent") {
    const zone = host?.accountZone ?? "UTC";
    const why = reason ? `: ${String(reason).slice(0, 120)}` : "";
    deps.defer(pushHost(ctx, row.account_id, `${row.guest_name ?? "A guest"} cancelled ${row.type_title}, ${shortWhen(Number(row.start_at), zone)}${why}`, `bk-${row.manage_id}`, { row, gone: true, cancelled: true }));
  }
  return true;
}

/**
 * The guest moves their booking to another offered time: checked against the snapshot and the day
 * read again, taken with a conditional update (the same lock as a booking), then the same event is
 * moved at Google. A move Google refuses is put back.
 * @returns {Promise<{kind: "moved"|"taken"|"unavailable", row?: object, nearest?: object[]}>}
 */
export async function move(ctx, row, host, type, { start: wanted, zone }) {
  const { deps } = ctx;
  const t = deps.now();
  const slots = slotsOf(host, type, { now: t, except: row.id });
  const start = Date.parse(wanted);
  if (!slots.some((s) => s.start === wanted)) return { kind: "taken", nearest: nearest(slots, start) };
  let access;
  try {
    access = await linkAccess(ctx, row.calendar_sub);
    const day = dayAround(start, type.timeZone);
    const live = await readDay(deps, ctx.vault, row.account_id, host.horizon.calendars, { from: day.from - DAY, to: day.to + DAY });
    const offered = slotsOf({ ...host, bookings: host.bookings.filter((b) => b.id !== row.id) }, type, { now: t, except: row.id, days: day, live });
    if (!offered.some((s) => s.start === wanted)) return { kind: "taken", nearest: nearest(slots.filter((s) => s.start !== wanted), start) };
  } catch (error) {
    console.log(`booking: move check failed (${error.name} ${error.status ?? ""})`.trim());
    return { kind: "unavailable" };
  }
  const end = start + type.minutes * MINUTE;
  const blockStart = start - type.bufferBefore * MINUTE, blockEnd = end + type.bufferAfter * MINUTE;
  // The move stands here at once, with 5 s to undo it; Google and the host hear of it after that
  // (patch_pending from the window's end: the answer's wait, and the minute job behind it).
  const before = JSON.stringify({ start_at: Number(row.start_at), end_at: Number(row.end_at), block_start: Number(row.block_start), block_end: Number(row.block_end),
    reminded_24: Number(row.reminded_24), reminded_1: Number(row.reminded_1), timed_at: Number(row.timed_at), patch_pending: Number(row.patch_pending) });
  const pushBody = `${row.guest_name ?? "A guest"} moved ${row.type_title} to ${shortWhen(start, host.accountZone ?? type.timeZone)}`;
  const moved = await deps.db.run(
    `UPDATE bookings SET start_at = ?, end_at = ?, block_start = ?, block_end = ?, reminded_24 = 0, reminded_1 = 0, timed_at = ?,
       guest_zone = COALESCE(?, guest_zone), sequence = sequence + 1, work_tries = 0, patch_pending = 1, next_at = ?,
       move_undo_until = ?, moved_from = ?, pending_push = ?, updated_at = ?
     WHERE id = ? AND status = 'confirmed'
       AND NOT EXISTS (SELECT 1 FROM bookings o WHERE o.account_id = ? AND o.id <> ? AND o.status IN ('pending', 'confirmed') AND o.block_start < ? AND o.block_end > ?)`,
    start, end, blockStart, blockEnd, t, zone ?? null, t + UNDO, t + UNDO, before, pushBody, t,
    row.id, row.account_id, row.id, blockEnd, blockStart);
  if (!moved.changes) return { kind: "taken", nearest: nearest(slots.filter((s) => s.start !== wanted), start) };
  if (deps.sleep) deps.defer((async () => { await deps.sleep(UNDO); await patchTime(ctx, row.id, null, { fromJob: true }); })().catch(() => {}));
  return { kind: "moved", row: await deps.db.first("SELECT * FROM bookings WHERE id = ?", row.id) };
}

/**
 * Moves the booking's event at Google to the row's time. True when Google took it. From the
 * minute job (patch_pending): three tries, then given up and the host told.
 */
export async function patchTime(ctx, id, access = null, { fromJob = false, zone: given = null } = {}) {
  const { deps } = ctx;
  if (fromJob) {
    const claimed = await deps.db.run(
      `UPDATE bookings SET work_tries = work_tries + 1, next_at = ? WHERE id = ? AND status = 'confirmed' AND patch_pending = 1
         AND (next_at IS NULL OR next_at <= ?) AND (move_undo_until IS NULL OR move_undo_until <= ?)`, deps.now() + LEASE, id, deps.now(), deps.now());
    if (!claimed.changes) return false;
  }
  const row = await deps.db.first("SELECT * FROM bookings WHERE id = ?", id);
  const host = fromJob ? await readHost(ctx, { account: row.account_id }) : null;
  const zone = given ?? host?.types.find((x) => x.id === row.type_id)?.timeZone ?? "UTC";
  try {
    access ??= await linkAccess(ctx, row.calendar_sub);
    const patched = await deps.google.patchEvent(access, row.calendar_id, row.id, {
      start: { dateTime: new Date(Number(row.start_at)).toISOString(), timeZone: zone },
      end: { dateTime: new Date(Number(row.end_at)).toISOString(), timeZone: zone },
    }, { sendUpdates: row.invite === "sent" ? "all" : "none" });
    if (!patched) throw new GoogleError("event gone", 404);
    await deps.db.run("UPDATE bookings SET patch_pending = 0, work_tries = 0, next_at = NULL, move_undo_until = NULL, moved_from = NULL WHERE id = ?", id);
    const told = await deps.db.run("UPDATE bookings SET pending_push = NULL WHERE id = ? AND pending_push IS NOT NULL", id);
    if (told.changes && row.pending_push) await pushHost(ctx, row.account_id, row.pending_push, `bk-${row.manage_id}`, { row });
    return true;
  } catch (error) {
    console.log(`booking: move failed at Google (${error.name} ${error.status ?? ""})`.trim());
    if (!fromJob) return false;
    const over = error instanceof GoogleRefused || Number(row.work_tries) >= TRIES || deps.now() >= Number(row.end_at);
    if (!over) { await deps.db.run("UPDATE bookings SET next_at = ? WHERE id = ?", deps.now() + 5 * MINUTE, id); return false; }
    await deps.db.run("UPDATE bookings SET patch_pending = 0, pending_push = NULL, next_at = NULL WHERE id = ?", id);
    await pushHost(ctx, row.account_id, `${row.guest_name ?? "A guest"} moved ${row.type_title}, but Banana couldn't move it on your calendar: move it there`, `bk-${row.manage_id}`, { row });
    return false;
  }
}

/**
 * The manage page's truth: the event read live. Gone or cancelled at Google means the host
 * cancelled; another time there means the host moved it (the row follows). Google unreachable: the
 * row as it is.
 */
export async function liveRow(ctx, row) {
  const { deps } = ctx;
  // A move Google hasn't taken yet (or still in its Undo window): the row is the truth.
  if (row.status !== "confirmed" || Number(row.patch_pending)) return row;
  let event;
  try {
    const access = await linkAccess(ctx, row.calendar_sub);
    event = await deps.google.getEvent(access, row.calendar_id, row.id);
  } catch { return row; }
  const t = deps.now();
  if (!event || event.status === "cancelled") {
    const gone = await deps.db.run("UPDATE bookings SET status = 'cancelled', cancelled_by = 'host', sequence = sequence + 1, next_at = NULL, updated_at = ? WHERE id = ? AND status = 'confirmed'", t, row.id);
    return { ...row, status: "cancelled", cancelled_by: "host", changed: gone.changes ? "cancelled" : null };
  }
  const start = Date.parse(event.start?.dateTime ?? ""), end = Date.parse(event.end?.dateTime ?? "");
  if (Number.isFinite(start) && Number.isFinite(end) && (start !== Number(row.start_at) || end !== Number(row.end_at))) {
    const pad = (Number(row.start_at) - Number(row.block_start)), padAfter = (Number(row.block_end) - Number(row.end_at));
    const moved = await deps.db.run(
      "UPDATE bookings SET start_at = ?, end_at = ?, block_start = ?, block_end = ?, reminded_24 = 0, reminded_1 = 0, timed_at = ?, sequence = sequence + 1, updated_at = ? WHERE id = ? AND start_at = ? AND end_at = ?",
      start, end, start - pad, end + padAfter, t, t, row.id, row.start_at, row.end_at);
    return { ...row, start_at: start, end_at: end, block_start: start - pad, block_end: end + padAfter, timed_at: t, changed: moved.changes ? "moved" : null };
  }
  return row;
}

export { publicPlace };
