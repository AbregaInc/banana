// One space's data (docs/design/DATA-PLATFORM.md §3, §4, §7): records with a clock per field, their
// full history, the blob index and the consent row, in the space's own SQLite database.
//
// Synchronous over a two-call port, {exec(sql, ...args) → rows, transaction(fn)}: a Durable Object
// (ctx.storage.sql, transactionSync; src/space-do.js) and node:sqlite (src/adapters/spaces-sqlite.js)
// both run this file. Nothing here awaits, so one sync is one transaction and nothing interleaves.
//
// A clock is an HLC, "<13-digit ms>.<4-hex counter>.<device>", compared as plain text.

import { calendarInfoID } from "./calendar-preferences.js";
import { CATALOG, T2_TYPES } from "./catalog.js";

export const PAGE_RECORDS = 1000;
export const PAGE_BYTES = 4 * 1024 * 1024;
export const MOST_FIELD_BYTES = 256 * 1024;
/** A clock further ahead of the service's time than this is refused ("clock"): the device learns
 * the offset from the answer's `now` and stamps the change again. */
export const MOST_AHEAD = 5 * 60 * 1000;
const HLC = /^\d{13}\.[0-9a-f]{4}\.[A-Za-z0-9_-]{1,64}$/;
const SHA = /^[0-9a-f]{64}$/;
const encoder = new TextEncoder();

const SCHEMA = [
  `CREATE TABLE IF NOT EXISTS records (type TEXT NOT NULL, id TEXT NOT NULL, fields TEXT NOT NULL, clocks TEXT NOT NULL,
     deleted TEXT, seq INTEGER NOT NULL, PRIMARY KEY (type, id))`,
  "CREATE INDEX IF NOT EXISTS records_seq ON records (seq)",
  // before/after: the changed fields only, {fields, clocks, deleted?}; before is null for a new record.
  `CREATE TABLE IF NOT EXISTS history (seq INTEGER NOT NULL, type TEXT NOT NULL, id TEXT NOT NULL, device TEXT NOT NULL,
     at INTEGER NOT NULL, before TEXT, after TEXT NOT NULL)`,
  "CREATE INDEX IF NOT EXISTS history_seq ON history (seq)",
  "CREATE INDEX IF NOT EXISTS history_type ON history (type)",
  // head, hlc, space, wiping (since when), epoch: a random id for this life of the space, new at
  // every wipe, so a device tells "emptied" (a new epoch) from "restored to earlier" (head < cursor).
  "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
  // type: what it was uploaded for; tier T2 when that type is under the Health consent (any T1
  // upload of the same bytes makes it T1, so a withdrawal never takes a blob T1 data still needs).
  "CREATE TABLE IF NOT EXISTS blobs (sha TEXT PRIMARY KEY, size INTEGER NOT NULL, at INTEGER NOT NULL, type TEXT NOT NULL, tier TEXT NOT NULL)",
  "CREATE TABLE IF NOT EXISTS consent (kind TEXT PRIMARY KEY, version TEXT NOT NULL, at INTEGER NOT NULL, device TEXT)",
  // Which record named which blob, at which change: kept as long as the history that names it, so a
  // withdrawal finds what T1 data still names with one indexed lookup per blob.
  "CREATE TABLE IF NOT EXISTS blob_refs (sha TEXT NOT NULL, type TEXT NOT NULL, id TEXT NOT NULL, seq INTEGER NOT NULL)",
  "CREATE INDEX IF NOT EXISTS blob_refs_sha ON blob_refs (sha)",
  "CREATE INDEX IF NOT EXISTS blob_refs_type ON blob_refs (type)",
  // Blobs no record names any more, waiting to be moved to the R2 trash (src/trash.js), a batch at a
  // time; and the ones moved, so an upload of the same bytes afterwards brings its file back.
  "CREATE TABLE IF NOT EXISTS trash (sha TEXT PRIMARY KEY)",
  "CREATE TABLE IF NOT EXISTS trashed (sha TEXT PRIMARY KEY)",
];

const prepared = new WeakSet();
function ready(port) {
  if (prepared.has(port)) return;
  for (const sql of SCHEMA) port.exec(sql);
  prepared.add(port);
}
/** After the storage underneath was dropped (a Durable Object's deleteAll). */
export const reset = (port) => { prepared.delete(port); };

// ---- canonical JSON and the merge (shared with the app: Shared/SyncMergeFixtures.json) ----

const hasSurrogates = /[\uD800-\uDFFF]/;
/** UTF-8 byte order, which is code point order (JS's < compares UTF-16 units, which differ above U+FFFF). */
export function compareText(a, b) {
  if (!hasSurrogates.test(a) && !hasSurrogates.test(b)) return a < b ? -1 : a > b ? 1 : 0;
  const x = [...a], y = [...b];
  for (let i = 0; i < Math.min(x.length, y.length); i++) {
    const d = x[i].codePointAt(0) - y[i].codePointAt(0);
    if (d) return d < 0 ? -1 : 1;
  }
  return x.length - y.length < 0 ? -1 : x.length > y.length ? 1 : 0;
}

function sorted(value) {
  if (Array.isArray(value)) return value.map(sorted);
  if (value && typeof value === "object") {
    const out = Object.create(null);   // a "__proto__" key in a value is a key like any other
    for (const k of Object.keys(value).sort(compareText)) out[k] = sorted(value[k]);
    return out;
  }
  return value;
}
/** Keys sorted at every depth, no spaces. */
export const canonical = (value) => JSON.stringify(sorted(value));

/** Equal clocks (only duplicates): the greater canonical JSON wins, null lowest. */
export function compareValues(a, b) {
  if (a === null || b === null || a === undefined || b === undefined) return (a ?? null) === (b ?? null) ? 0 : (a ?? null) === null ? -1 : 1;
  return compareText(canonical(a), canonical(b));
}

const own = (o, k) => Object.prototype.hasOwnProperty.call(o, k);

/**
 * The one merge rule, pure. state: {fields, clocks, deleted} or null; change: {set, clocks, delete}.
 * field (and whole, whose only field is `v`): per field the higher clock wins. deleted is a register.
 * append: a record with any field ignores further sets.
 */
export function merge(state, change, mode = "field") {
  const out = { fields: { ...(state?.fields ?? {}) }, clocks: { ...(state?.clocks ?? {}) }, deleted: state?.deleted ?? null };
  const locked = mode === "append" && Object.keys(out.fields).length > 0;
  if (!locked) {
    for (const [k, value] of Object.entries(change.set ?? {})) {
      const clock = change.clocks[k];
      const held = own(out.clocks, k) ? out.clocks[k] : undefined;
      if (held === undefined || clock > held || (clock === held && compareValues(value, out.fields[k]) > 0)) {
        out.fields[k] = value;
        out.clocks[k] = clock;
      }
    }
  }
  const del = change.delete ?? null;
  if (del !== null && (out.deleted === null || del > out.deleted)) out.deleted = del;
  return out;
}

/** Gone while the delete clock is higher than every field clock; a later edit brings it back. */
export const visible = (state) => state.deleted === null || Object.values(state.clocks).some((c) => c >= state.deleted);

// ---- small helpers over the port ----

const meta = (port, key) => port.exec("SELECT value FROM meta WHERE key = ?", key)[0]?.value ?? null;
const setMeta = (port, key, value) =>
  port.exec("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value", key, String(value));
const parseRecord = (row) => row && { fields: JSON.parse(row.fields), clocks: JSON.parse(row.clocks), deleted: row.deleted ?? null };
const isBlobRef = (v) => v !== null && typeof v === "object" && !Array.isArray(v) && own(v, "$blob");
const bytes = (text) => encoder.encode(text).length;

/** The shas a record's fields name (a field whose value is {"$blob": sha, …}). */
function refsIn(fields, into) {
  for (const v of Object.values(fields ?? {})) if (isBlobRef(v) && typeof v.$blob === "string") into.add(v.$blob);
  return into;
}

function consentsOf(port) {
  return { health: port.exec("SELECT 1 AS x FROM consent WHERE kind = 'health'").length > 0 };
}

/** A change as sent, checked; {reason} when it can't be taken. */
function check(raw, platform, consents) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return { reason: "bad" };
  const entry = CATALOG.get(raw.type);
  if (!entry) return { reason: "unknown_type" };
  if (typeof raw.id !== "string" || !raw.id || raw.id.length > 200) return { reason: "bad" };
  const set = raw.set ?? {};
  const clocks = raw.clocks ?? {};
  const del = raw.delete ?? null;
  const plain = (o) => o && typeof o === "object" && !Array.isArray(o);
  if (!plain(set) || !plain(clocks)) return { reason: "bad" };
  const keys = Object.keys(set);
  if (keys.some((k) => !k || k.length > 200 || k === "__proto__" || typeof clocks[k] !== "string" || !HLC.test(clocks[k]))) return { reason: "bad" };
  if (Object.keys(clocks).some((k) => !own(set, k))) return { reason: "bad" };
  if (del !== null && (typeof del !== "string" || !HLC.test(del))) return { reason: "bad" };
  if (entry.merge === "whole" && keys.some((k) => k !== "v")) return { reason: "bad" };
  for (const k of keys) if (isBlobRef(set[k]) && (typeof set[k].$blob !== "string" || !SHA.test(set[k].$blob))) return { reason: "bad" };
  if (entry.writers === "hub" && platform !== "iphone") return { reason: "hub_only" };
  if (entry.tier === "T2" && !consents.health) return { reason: "consent" };
  return { entry, change: { set, clocks: Object.fromEntries(keys.map((k) => [k, clocks[k]])), delete: del } };
}

/** What changed between two states: the changed fields only, or null for a no-op. */
function delta(before, after) {
  const b = { fields: {}, clocks: {} };
  const a = { fields: {}, clocks: {} };
  let any = false;
  for (const k of Object.keys(after.clocks)) {
    const had = before !== null && own(before.clocks, k);
    if (had && before.clocks[k] === after.clocks[k] && canonical(before.fields[k]) === canonical(after.fields[k])) continue;
    any = true;
    if (had) { b.fields[k] = before.fields[k]; b.clocks[k] = before.clocks[k]; }
    a.fields[k] = after.fields[k];
    a.clocks[k] = after.clocks[k];
  }
  if ((before?.deleted ?? null) !== after.deleted) { any = true; b.deleted = before?.deleted ?? null; a.deleted = after.deleted; }
  return any ? { before: before === null ? null : b, after: a } : null;
}

/** A record's day for analytics: the catalog's `day` field, as an ISO date. */
function dayOf(entry, fields) {
  const v = entry.day ? fields[entry.day] : undefined;
  if (typeof v === "number" && Number.isFinite(v)) return new Date(v).toISOString().slice(0, 10);
  if (typeof v === "string" && /^\d{4}-\d{2}-\d{2}/.test(v)) return v.slice(0, 10);
  return null;
}

const newEpoch = () => Array.from(crypto.getRandomValues(new Uint8Array(12)), (b) => b.toString(16).padStart(2, "0")).join("");
/** The space's epoch, made with the space. */
function epochOf(port) {
  let epoch = meta(port, "epoch");
  if (epoch === null) { epoch = newEpoch(); setMeta(port, "epoch", epoch); }
  return epoch;
}

const tooFar = (clock, most) => clock !== null && Number(clock.slice(0, 13)) > most;

// ---- the calls ----

/**
 * One sync (§4), one transaction: takes the changes sent, then answers with what changed after
 * `since`. Returns {answer, accepted}: the answer for the device; `accepted` for the change stream
 * (T1 {type, op, day, fields: the catalog's analytics fields}; T2 {type, op}).
 */
export function sync(port, { device, platform, since = 0, changes = [], now, space, pageRecords = PAGE_RECORDS, pageBytes = PAGE_BYTES }) {
  ready(port);
  return port.transaction(() => {
    const consents = consentsOf(port);
    const epoch = epochOf(port);
    const startHead = Number(meta(port, "head") ?? 0);
    const startHlc = meta(port, "hlc") ?? "";
    let head = startHead, hlc = startHlc;
    const most = now + MOST_AHEAD;
    const applied = [], rejected = [], accepted = [];
    let trashed = 0;

    for (const raw of changes) {
      const checked = check(raw, platform, consents);
      const key = { type: typeof raw?.type === "string" ? raw.type : null, id: typeof raw?.id === "string" ? raw.id : null };
      if (checked.reason) { rejected.push({ ...key, reason: checked.reason }); continue; }
      const { entry, change } = checked;
      // Never brought down to a limit: a clamped clock would move with every retry and beat the
      // edits made elsewhere in between. The whole record waits for the device to stamp it again.
      if (Object.values(change.clocks).some((c) => tooFar(c, most)) || tooFar(change.delete, most)) { rejected.push({ ...key, reason: "clock" }); continue; }
      const named = [...refsIn(change.set, new Set())];
      if (named.some((sha) => !port.exec("SELECT 1 AS x FROM blobs WHERE sha = ?", sha).length)) { rejected.push({ ...key, reason: "blob_missing" }); continue; }

      const before = parseRecord(port.exec("SELECT fields, clocks, deleted FROM records WHERE type = ? AND id = ?", key.type, key.id)[0]) ?? null;
      const after = merge(before, change, entry.merge);
      const fieldsText = canonical(after.fields);
      if (bytes(fieldsText) > MOST_FIELD_BYTES) { rejected.push({ ...key, reason: "too_large" }); continue; }
      const d = delta(before, after);
      if (d) {
        head++;
        port.exec(
          `INSERT INTO records (type, id, fields, clocks, deleted, seq) VALUES (?, ?, ?, ?, ?, ?)
           ON CONFLICT (type, id) DO UPDATE SET fields = excluded.fields, clocks = excluded.clocks, deleted = excluded.deleted, seq = excluded.seq`,
          key.type, key.id, fieldsText, canonical(after.clocks), after.deleted, head);
        port.exec("INSERT INTO history (seq, type, id, device, at, before, after) VALUES (?, ?, ?, ?, ?, ?, ?)",
          head, key.type, key.id, String(device), now, d.before === null ? null : canonical(d.before), canonical(d.after));
        for (const sha of refsIn(d.after.fields, new Set())) port.exec("INSERT INTO blob_refs (sha, type, id, seq) VALUES (?, ?, ?, ?)", sha, key.type, key.id, head);
        // keep: "latest" (a derived copy, such as the Health snapshot): the blob a field named
        // before goes to the trash, unless something else still names it. Its history rows stay,
        // naming a blob that's gone.
        if (entry.keep === "latest" && before) {
          const still = refsIn(after.fields, new Set());
          for (const sha of refsIn(before.fields, new Set())) {
            if (still.has(sha)) continue;
            port.exec("DELETE FROM blob_refs WHERE sha = ? AND type = ? AND id = ?", sha, key.type, key.id);
            if (port.exec("SELECT 1 AS x FROM blob_refs WHERE sha = ? LIMIT 1", sha).length) continue;
            if (!port.exec("SELECT 1 AS x FROM blobs WHERE sha = ?", sha).length) continue;
            port.exec("DELETE FROM blobs WHERE sha = ?", sha);
            port.exec("INSERT INTO trash (sha) VALUES (?) ON CONFLICT (sha) DO NOTHING", sha);
            trashed++;
          }
        }
        for (const c of [...Object.values(change.clocks), change.delete]) if (c !== null && c > hlc) hlc = c;
        const op = before === null ? "create" : visible(before) && !visible(after) ? "delete" : "update";
        accepted.push(entry.tier === "T2" ? { type: key.type, op }
          : { type: key.type, op, day: dayOf(entry, after.fields), fields: Object.fromEntries(entry.analytics.filter((f) => own(after.fields, f)).map((f) => [f, after.fields[f]])) });
      }
      applied.push({ ...key, clocks: after.clocks, deleted: after.deleted });
    }
    // A pull writes nothing.
    if (head !== startHead) setMeta(port, "head", head);
    if (hlc !== startHlc) setMeta(port, "hlc", hlc);
    if (trashed && space) setMeta(port, "space", space);

    // A cursor past the head means the space was started over (a wipe): read it from the start.
    const from = Number.isInteger(since) && since >= 0 && since <= head ? since : 0;
    // Sizes first, so a page of large records is never read only to be cut.
    const sizes = port.exec(
      `SELECT seq, length(CAST(fields AS BLOB)) + length(CAST(clocks AS BLOB)) + length(CAST(id AS BLOB)) + length(type) + 64 AS n
       FROM records WHERE seq > ? ORDER BY seq LIMIT ?`, from, pageRecords + 1);
    let last = from, total = 0, count = 0;
    for (const row of sizes) {
      if (count === pageRecords || (count > 0 && total + Number(row.n) > pageBytes)) break;
      total += Number(row.n);
      count++;
      last = Number(row.seq);
    }
    const page = count === 0 ? [] : port.exec(
      "SELECT type, id, fields, clocks, deleted, seq FROM records WHERE seq > ? AND seq <= ? ORDER BY seq", from, last);
    return {
      answer: {
        now, epoch, head, next: last, more: count < sizes.length, applied,
        changes: page.map((r) => ({ type: r.type, id: r.id, ...parseRecord(r), seq: Number(r.seq) })),
        rejected, consents,
      },
      accepted,
      trashed,
    };
  });
}

/** The space's consents, {health: bool}. */
export function consents(port) {
  ready(port);
  return consentsOf(port);
}

/**
 * A blob now in storage, uploaded for `type` (idempotent; a blob is never overwritten). Takes it
 * off the trash list; {restore: true} when it was on it or already moved, so the route brings its
 * file back from the trash if it's gone. A T2 blob needs the Health consent, checked here too: one
 * withdrawn after the route's check is refused ({ok: false, reason: "consent"}), and the route
 * removes what it put.
 */
export function recordBlob(port, sha, size, at, type) {
  ready(port);
  const entry = CATALOG.get(type);
  if (!SHA.test(sha) || !entry) throw new Error("bad blob");
  return port.transaction(() => {
    if (entry.tier === "T2" && !consentsOf(port).health) return { ok: false, reason: "consent" };
    port.exec(`INSERT INTO blobs (sha, size, at, type, tier) VALUES (?, ?, ?, ?, ?)
               ON CONFLICT (sha) DO UPDATE SET tier = 'T1' WHERE excluded.tier = 'T1'`, sha, Number(size), Number(at), type, entry.tier);
    const restore = port.exec("SELECT sha FROM trash WHERE sha = ? UNION SELECT sha FROM trashed WHERE sha = ?", sha, sha).length > 0;
    port.exec("DELETE FROM trash WHERE sha = ?", sha);
    port.exec("DELETE FROM trashed WHERE sha = ?", sha);
    return { ok: true, restore };
  });
}

/** The space's yes to a kind of consent. A retry of the same words keeps the first time. */
export function setConsent(port, kind, { version, at, device = null }) {
  ready(port);
  port.exec(`INSERT INTO consent (kind, version, at, device) VALUES (?, ?, ?, ?)
             ON CONFLICT (kind) DO UPDATE SET version = excluded.version, at = excluded.at, device = excluded.device
               WHERE consent.version <> excluded.version`,
    kind, String(version), Number(at), device);
}

/**
 * Withdraws a consent. For health, in the same transaction: every T2 record and its history are
 * hard-deleted, and every T2 blob (uploaded for a T2 type, or named by T2 data) that nothing left
 * names leaves the index for the trash list. Returns {records, blobs: [sha]}. Safe to repeat.
 */
export function withdrawConsent(port, kind, { space } = {}) {
  ready(port);
  return port.transaction(() => {
    port.exec("DELETE FROM consent WHERE kind = ?", kind);
    if (kind !== "health") return { records: 0, blobs: [] };
    if (space) setMeta(port, "space", space);
    const marks = T2_TYPES.map(() => "?").join(", ");
    const candidates = port.exec(
      `SELECT sha FROM blobs WHERE tier = 'T2' UNION SELECT sha FROM blob_refs WHERE type IN (${marks})`, ...T2_TYPES).map((r) => r.sha);
    const records = port.exec(`SELECT COUNT(*) AS n FROM records WHERE type IN (${marks})`, ...T2_TYPES)[0].n;
    port.exec(`DELETE FROM records WHERE type IN (${marks})`, ...T2_TYPES);
    port.exec("DELETE FROM meta WHERE key = 'counts'");   // the kept counts named these records
    port.exec(`DELETE FROM history WHERE type IN (${marks})`, ...T2_TYPES);
    port.exec(`DELETE FROM blob_refs WHERE type IN (${marks})`, ...T2_TYPES);
    // What's left in blob_refs is T1 data (records and their history) naming a blob: those stay.
    const blobs = candidates.filter((sha) => !port.exec("SELECT 1 AS x FROM blob_refs WHERE sha = ? LIMIT 1", sha).length
      && port.exec("SELECT 1 AS x FROM blobs WHERE sha = ?", sha).length);
    for (const sha of blobs) {
      port.exec("DELETE FROM blobs WHERE sha = ?", sha);
      port.exec("INSERT INTO trash (sha) VALUES (?) ON CONFLICT (sha) DO NOTHING", sha);
    }
    return { records: Number(records), blobs };
  });
}

/** One record's fields, or null when there is none or it is deleted (the service's own reads:
 * booking types, the calendars a person leaves out). Never a T2 type. */
export function read(port, type, id) {
  ready(port);
  if (CATALOG.get(type)?.tier !== "T1") throw new Error("not a T1 type");
  const row = parseRecord(port.exec("SELECT fields, clocks, deleted FROM records WHERE type = ? AND id = ?", type, id)[0]);
  return row && visible(row) ? row.fields : null;
}

/** Every live record of a T1 type, as {id, fields}, in id order. */
export function list(port, type) {
  ready(port);
  if (CATALOG.get(type)?.tier !== "T1") throw new Error("not a T1 type");
  return port.exec("SELECT id, fields, clocks, deleted FROM records WHERE type = ? ORDER BY id", type)
    .map((r) => ({ id: r.id, ...parseRecord(r) })).filter(visible).map((r) => ({ id: r.id, fields: r.fields }));
}

/**
 * Live records per type. Computed by one pass over the table and kept in meta against the head seq:
 * a web reader (a share's guest, the owner's page) asking again and again costs one meta read until
 * the space changes. (Audit run-1: the scan grows with the owner's history, the reader's cost does not.)
 */
export function counts(port) {
  ready(port);
  const head = meta(port, "head") ?? "0";
  const cached = meta(port, "counts");
  if (cached) {
    try { const c = JSON.parse(cached); if (c.head === head) return c.counts; } catch { /* recomputed */ }
  }
  const out = {};
  for (const r of port.exec("SELECT type, clocks, deleted FROM records")) {
    if (visible({ clocks: JSON.parse(r.clocks), deleted: r.deleted ?? null })) out[r.type] = (out[r.type] ?? 0) + 1;
  }
  setMeta(port, "counts", JSON.stringify({ head, counts: out }));
  return out;
}

/** The signed-in web reader: one page, including T2 only while consent stands. No history. */
export function browse(port, type, after = "", limit = 100) {
  ready(port);
  const entry = CATALOG.get(type);
  if (!entry || (entry.tier === "T2" && !consentsOf(port).health)) return { records: [], next: null };
  const rows = port.exec("SELECT id, fields, clocks, deleted FROM records WHERE type = ? AND id > ? ORDER BY id LIMIT ?",
    type, after, limit + 1);
  const page = rows.slice(0, limit);
  return {
    records: page.map((r) => ({ id: r.id, ...parseRecord(r) })).filter(visible).map((r) => ({ id: r.id, fields: r.fields })),
    next: rows.length > limit ? page.at(-1).id : null,
  };
}

/** A browser may fetch only a blob still named by a live, consented record in its own space. */
export function webBlob(port, type, id, field) {
  ready(port);
  const entry = CATALOG.get(type);
  if (!entry?.blobs?.[field] || (entry.tier === "T2" && !consentsOf(port).health)) return null;
  const record = parseRecord(port.exec("SELECT fields, clocks, deleted FROM records WHERE type = ? AND id = ?", type, id)[0]);
  const ref = record?.fields[field];
  return record && visible(record) && isBlobRef(ref) && SHA.test(ref.$blob) ? ref : null;
}

/**
 * Empties the space at once and marks it as being wiped: its blobs move to the trash afterwards
 * (src/trash.js lists them under `s/<space>/`), and then the storage itself goes.
 */
export function wipe(port, { space, now }) {
  ready(port);
  port.transaction(() => {
    for (const table of ["records", "history", "blobs", "blob_refs", "consent", "trash", "trashed", "meta"]) port.exec(`DELETE FROM ${table}`);
    setMeta(port, "space", space);
    setMeta(port, "wiping", String(now));
    setMeta(port, "epoch", newEpoch());
  });
}

/** What src/trash.js works through: {space, wiping (since when, or null), shas}. */
export function trashList(port, limit) {
  ready(port);
  const wiping = meta(port, "wiping");
  return {
    space: meta(port, "space"),
    wiping: wiping === null ? null : Number(wiping),
    shas: port.exec("SELECT sha FROM trash ORDER BY sha LIMIT ?", limit).map((r) => r.sha),
  };
}
/** Whether there's trash work to do (the alarm is armed while there is). */
export function trashPending(port) {
  ready(port);
  return meta(port, "wiping") !== null || port.exec("SELECT 1 AS x FROM trash LIMIT 1").length > 0;
}
/** Takes one sha off the trash list before its move; false when it's no longer there (an upload of
 * the same bytes took it back). */
export function takeTrash(port, sha) {
  return port.transaction(() => {
    if (!port.exec("SELECT 1 AS x FROM trash WHERE sha = ?", sha).length) return false;
    port.exec("DELETE FROM trash WHERE sha = ?", sha);
    port.exec("INSERT INTO trashed (sha) VALUES (?) ON CONFLICT (sha) DO NOTHING", sha);
    return true;
  });
}
/** A move that failed: the sha goes back on the list, unless an upload took it back meanwhile. */
export function untakeTrash(port, sha) {
  port.transaction(() => {
    if (!port.exec("SELECT 1 AS x FROM trashed WHERE sha = ?", sha).length) return;
    port.exec("DELETE FROM trashed WHERE sha = ?", sha);
    port.exec("INSERT INTO trash (sha) VALUES (?) ON CONFLICT (sha) DO NOTHING", sha);
  });
}
/** After a move: false when an upload took the sha back while its file was moving. */
export const stillTrashed = (port, sha) => port.exec("SELECT 1 AS x FROM trashed WHERE sha = ?", sha).length > 0;

/**
 * Every record, its history, the blob list and the consents, as rows for an NDJSON export
 * (GDPR Art. 20), read a chunk at a time.
 */
export function* exportRows(port, chunk = 200) {
  ready(port);
  for (let after = 0; ;) {
    const rows = port.exec("SELECT type, id, fields, clocks, deleted, seq FROM records WHERE seq > ? ORDER BY seq LIMIT ?", after, chunk);
    for (const r of rows) yield { kind: "record", type: r.type, id: r.id, ...parseRecord(r), seq: Number(r.seq) };
    if (rows.length < chunk) break;
    after = Number(rows.at(-1).seq);
  }
  for (let after = 0; ;) {
    const rows = port.exec("SELECT seq, type, id, device, at, before, after FROM history WHERE seq > ? ORDER BY seq LIMIT ?", after, chunk);
    for (const h of rows) {
      yield { kind: "history", seq: Number(h.seq), type: h.type, id: h.id, device: h.device, at: Number(h.at),
              before: h.before ? JSON.parse(h.before) : null, after: JSON.parse(h.after) };
    }
    if (rows.length < chunk) break;
    after = Number(rows.at(-1).seq);
  }
  for (let after = ""; ;) {
    const rows = port.exec("SELECT sha, size, at, type FROM blobs WHERE sha > ? ORDER BY sha LIMIT ?", after, chunk);
    for (const b of rows) yield { kind: "blob", sha: b.sha, size: Number(b.size), at: Number(b.at), type: b.type };
    if (rows.length < chunk) break;
    after = rows.at(-1).sha;
  }
  for (const c of port.exec("SELECT kind, version, at, device FROM consent ORDER BY kind")) {
    yield { kind: "consent", consent: c.kind, version: c.version, at: Number(c.at), device: c.device ?? null };
  }
}

/** The export as a streamed NDJSON Response (Workers and Node both have web streams). */
export function exportResponse(port) {
  const rows = exportRows(port);
  const stream = new ReadableStream({
    pull(controller) {
      let text = "";
      for (let i = 0; i < 100; i++) {
        const next = rows.next();
        if (next.done) { if (text) controller.enqueue(encoder.encode(text)); controller.close(); return; }
        text += JSON.stringify(next.value) + "\n";
      }
      controller.enqueue(encoder.encode(text));
    },
  });
  return new Response(stream, { headers: { "content-type": "application/x-ndjson" } });
}

/** Atomic web edit of one calendar toggle. Preserve every other native setting and unknown key. */
export function setCalendarPreference(port, { calendarID, preference, enabled, now }) {
  ready(port);
  if (typeof calendarID !== "string" || !calendarID || calendarID.length > 1024
    || !["included", "notifications"].includes(preference) || typeof enabled !== "boolean") return { error: "bad_request" };
  return port.transaction(() => {
    const type = "core.smartSettings", id = "smart-settings";
    const before = parseRecord(port.exec("SELECT fields, clocks, deleted FROM records WHERE type = ? AND id = ?", type, id)[0]);
    if (!before || !visible(before) || !before.fields.v?.settings
      || (preference === "included" && before.fields.v.calendarIDsAreGoogle !== true)) return { error: "not_ready" };
    const fields = structuredClone(before.fields), snapshot = fields.v;
    const key = preference === "included" ? "excludedCalendarIDs" : "mutedCalendarIDs";
    const value = preference === "included" ? calendarInfoID(calendarID) : calendarID;
    const values = new Set(snapshot.settings[key] ?? []);
    if (enabled) values.delete(value); else values.add(value);
    snapshot.settings[key] = [...values].sort();
    snapshot.updatedAt = Math.max(now / 1000 - 978307200, Number(snapshot.updatedAt ?? 0) + 0.001);
    const latest = [meta(port, "hlc") ?? "", ...Object.values(before.clocks)].sort().at(-1);
    let wall = Math.max(now, Number(latest?.slice(0, 13) || 0));
    let counter = wall === Number(latest?.slice(0, 13)) ? parseInt(latest.slice(14, 18), 16) + 1 : 0;
    if (counter > 65535) { wall++; counter = 0; }
    const clock = `${String(wall).padStart(13, "0")}.${counter.toString(16).padStart(4, "0")}.web`;
    if (bytes(canonical(fields)) > MOST_FIELD_BYTES) return { error: "too_large" };
    const clocks = { ...before.clocks, v: clock }, head = Number(meta(port, "head") ?? 0) + 1;
    const after = { fields, clocks, deleted: before.deleted };
    port.exec("UPDATE records SET fields = ?, clocks = ?, seq = ? WHERE type = ? AND id = ?", canonical(fields), canonical(clocks), head, type, id);
    port.exec("INSERT INTO history (seq, type, id, device, at, before, after) VALUES (?, ?, ?, ?, ?, ?, ?)",
      head, type, id, "web", now, canonical(before), canonical(after));
    setMeta(port, "head", head); setMeta(port, "hlc", clock);
    return { settings: snapshot.settings, updatedAt: snapshot.updatedAt };
  });
}
