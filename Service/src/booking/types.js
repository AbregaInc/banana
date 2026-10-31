// Booking types (docs/design/BOOKING.md §4): `plan.bookingType` records in the person's space, edited
// in the app, read here and checked field by field. An account with a handle and no type gets the
// default one. The record's fields:
//
//   title        "Meeting"                       ≤ 80 characters
//   slug         "meeting"                       [a-z0-9-]{1,40}, unique among the account's types
//   minutes      30                              5–480
//   hours        Mon–Fri 09:00–17:00             7 lists, index 0 = Sunday, of [startMinute, endMinute]
//                                                 on the host's wall clock (0–1440, start < end)
//   timeZone     the handle's zone               an IANA name; fixed once set
//   step         the length if it divides 60, else 15
//   bufferBefore, bufferAfter   0                minutes, 0–240
//   notice       240                             minutes from now, 0–43200
//   horizonDays  30                              1–90
//   perDay       null                            bookings of this type a day at most, 1–50
//   locations    [{kind: "meet"}]                see placeOf; the first is the default
//   calendar     null                            {email, id}: where the events go; null = the primary
//                                                 calendar of the oldest Google link
//   active       true
//   order        0                               where it sits on the profile

import { canonicalZone, defaultStep } from "./slots.js";

export const TYPE = "plan.bookingType";
const KINDS = ["meet", "zoom", "phone_host_calls", "phone_guest_calls", "in_person", "link"];
const LABELS = { meet: "Google Meet", zoom: "Zoom", phone_host_calls: "Phone call", phone_guest_calls: "Phone call", in_person: "In person", link: "Video call" };
const WEEKDAYS_9_TO_5 = [[], [[540, 1020]], [[540, 1020]], [[540, 1020]], [[540, 1020]], [[540, 1020]], []];

const int = (v, lo, hi, fallback) => (Number.isInteger(v) && v >= lo && v <= hi ? v : fallback);
const text = (v, most) => (typeof v === "string" && v.trim() && v.length <= most ? v.trim().replace(/[\u0000-\u001f\u007f]/g, "") : null);
const https = (v) => { try { const u = new URL(String(v)); return u.protocol === "https:" && String(v).length <= 500 ? u.toString() : null; } catch { return null; } };

/** One place a type offers, checked; null when it isn't one. */
export function placeOf(raw, index) {
  if (!raw || typeof raw !== "object" || !KINDS.includes(raw.kind)) return null;
  const place = { id: /^[a-z0-9_-]{1,40}$/.test(raw.id ?? "") ? raw.id : index === 0 ? raw.kind : `${raw.kind}-${index}`,
    kind: raw.kind, label: text(raw.label, 60) ?? LABELS[raw.kind] };
  if (raw.kind === "zoom" || raw.kind === "link") { place.url = https(raw.url); if (!place.url) return null; }
  if (raw.kind === "phone_guest_calls") { place.phone = text(raw.phone, 32); if (!place.phone) return null; }
  if (raw.kind === "in_person") { place.address = text(raw.address, 200); if (!place.address) return null; }
  return place;
}

/** The hours as the engine takes them, or null when they aren't hours. */
function hoursOf(raw) {
  const days = Array.isArray(raw) ? raw : raw && typeof raw === "object" ? Array.from({ length: 7 }, (_, w) => raw[w] ?? raw[String(w)] ?? []) : null;
  if (!days || days.length !== 7) return null;
  return days.map((spans) => (Array.isArray(spans) ? spans : [])
    .filter((s) => Array.isArray(s) && Number.isInteger(s[0]) && Number.isInteger(s[1]) && s[0] >= 0 && s[1] <= 1440 && s[0] < s[1])
    .slice(0, 12).map((s) => [s[0], s[1]]));
}

/**
 * A type as the service uses it, from a record's fields; null when the record can't be a type.
 * @param {string} id the record's id
 * @param {object} fields
 * @param {{zone: string|null}} defaults the handle's zone, for a type without its own
 */
export function normaliseType(id, fields, { zone }) {
  if (!fields || typeof fields !== "object") return null;
  const minutes = int(fields.minutes, 5, 480, 30);
  const timeZone = canonicalZone(fields.timeZone) ?? canonicalZone(zone);
  if (!timeZone) return null;
  const slug = typeof fields.slug === "string" && /^[a-z0-9-]{1,40}$/.test(fields.slug) ? fields.slug : null;
  if (!slug) return null;
  const places = (Array.isArray(fields.locations) && fields.locations.length ? fields.locations : [{ kind: "meet" }])
    .slice(0, 6).map(placeOf).filter(Boolean);
  const calendar = fields.calendar && typeof fields.calendar === "object" && typeof fields.calendar.id === "string" && fields.calendar.id.length <= 300
    ? { email: typeof fields.calendar.email === "string" ? fields.calendar.email.toLowerCase() : null, id: fields.calendar.id } : null;
  return {
    id,
    title: text(fields.title, 80) ?? "Meeting",
    slug,
    minutes,
    hours: hoursOf(fields.hours) ?? WEEKDAYS_9_TO_5,
    timeZone,
    step: int(fields.step, 5, 240, defaultStep(minutes)),
    bufferBefore: int(fields.bufferBefore, 0, 240, 0),
    bufferAfter: int(fields.bufferAfter, 0, 240, 0),
    notice: int(fields.notice, 0, 43_200, 240),
    horizonDays: int(fields.horizonDays, 1, 90, 30),
    perDay: fields.perDay == null ? null : int(fields.perDay, 1, 50, null),
    places: places.length ? places : [placeOf({ kind: "meet" }, 0)],
    calendar,
    active: fields.active !== false,
    order: int(fields.order, -1000, 1000, 0),
  };
}

/** The type an account with a handle and no type of its own offers. */
export const defaultType = (zone) => normaliseType("default", { title: "Meeting", slug: "meeting" }, { zone });

/**
 * The account's types, from the records the space holds (or the default when there are none),
 * active or not, in profile order; a second type with a slug already taken is left out.
 */
export function typesFrom(records, zone) {
  const list = (records ?? []).map((r) => normaliseType(r.id, r.fields, { zone })).filter(Boolean);
  if (!(records ?? []).length) { const d = defaultType(zone); return d ? [d] : []; }
  const seen = new Set();
  return list.sort((a, b) => a.order - b.order || a.title.localeCompare(b.title) || a.id.localeCompare(b.id))
    .filter((t) => (seen.has(t.slug) ? false : seen.add(t.slug)));
}

/** A place as the page may show it before booking: no Zoom link and no host phone number yet. */
export const publicPlace = (p) => ({ id: p.id, kind: p.kind, label: p.label, ...(p.kind === "in_person" ? { address: p.address } : {}) });

/** The type as the pages take it (CONTRACT.md). */
export const typeView = (t, nextSlot = null) => ({ slug: t.slug, title: t.title, minutes: t.minutes, places: t.places.map(publicPlace), hostZone: t.timeZone, nextSlot });

// ---- the handle ----

export const RESERVED = new Set([
  "m", "b", "v1", "v2", "v3", "assets", "privacy", "support", "api", "book", "booking", "www", "mail", "admin", "help", "about",
  "terms", "legal", "security", "status", "health", "login", "signin", "signup", "logout", "settings", "account", "accounts",
  "guest", "guests", "manage", "cancel", "connect", "code", "forget", "undo", "static", "public", "fonts", "img", "css", "js",
  "app", "apps", "banana", "bananatheapp", "beta", "test", "root", "null", "undefined", "new", "edit", "me", "you", "team",
  "teams", "blog", "docs", "home", "index", "robots", "sitemap", "favicon", "well-known",
]);

/** Why a handle can't be used ("invalid" | "reserved"), or null when it can. */
export function handleProblem(handle) {
  if (typeof handle !== "string" || !/^[a-z0-9-]{3,30}$/.test(handle) || handle.startsWith("-") || handle.endsWith("-") || handle.includes("--")) return "invalid";
  if (RESERVED.has(handle)) return "reserved";
  return null;
}

/** Handles to suggest from a name, best first: "Noor Haddad" → noor, noor-haddad, noorhaddad, noorh. */
export function handleIdeas(name, email) {
  const plain = (s) => String(s ?? "").normalize("NFKD").replace(/[̀-ͯ]/g, "").toLowerCase();
  const words = plain(name).split(/[^a-z0-9]+/).filter(Boolean);
  const local = plain(String(email ?? "").split("@")[0]).replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
  const out = [];
  if (words.length) {
    out.push(words[0], words.join("-"), words.join(""));
    if (words.length > 1) out.push(words[0] + words.at(-1)[0], `${words[0]}-${words.at(-1)}`);
  }
  if (local) out.push(local);
  return [...new Set(out.map((h) => h.slice(0, 30).replace(/-+$/, "")).filter((h) => !handleProblem(h)))];
}
