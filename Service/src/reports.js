// Problem reports (docs/design/PROBLEM-REPORTS.md): what the apps send when something goes wrong,
// automatically (a spike the watchdog caught, a MetricKit diagnostic) or in one tap (Report a
// problem, a 👎 on an answer). Anonymous like the diagnostics: never read with a session, no
// address kept. The small facts are a row in D1; the screenshot, the log, a message's HTML and an
// answer's transcript are objects in R2 under `reports/<id>/<name>`.

import { CHANNELS, PLATFORMS } from "./usage.js";

/** problem: the Report button; spike: the watchdog or MetricKit; rating: 👍 or 👎 on an answer. */
export const KINDS = ["problem", "spike", "rating"];
export const DETECTORS = ["storm", "cpu", "power", "memory", "hang",
  "metrickit-crash", "metrickit-hang", "metrickit-cpu", "metrickit-disk"];
export const VARIANTS = ["stable", "beta"];
export const PAGES = ["plan", "mail", "workouts", "sleep", "trends", "nutrition", "notes", "routines", "library",
  "review", "assistant", "settings", "other"];

/** What may be attached, its types and its largest size in bytes (decoded). */
export const ATTACHMENTS = {
  screenshot: { types: ["image/jpeg", "image/png"], most: 3 * 1024 * 1024 },
  log: { types: ["text/plain"], most: 256 * 1024 },
  stack: { types: ["text/plain", "application/json"], most: 256 * 1024 },
  "mail-html": { types: ["text/html"], most: 2560 * 1024 },
  "mail-prepared": { types: ["application/json"], most: 2560 * 1024 },
  "mail-plain": { types: ["text/plain"], most: 2560 * 1024 },
  ai: { types: ["application/json"], most: 512 * 1024 },
  metrickit: { types: ["application/json"], most: 256 * 1024 },
};
export const MOST_BODY = 12 * 1024 * 1024;          // the whole request, base64 included
export const MOST_CONTEXT = 32 * 1024;              // the inline facts, as JSON
export const MOST_NOTE = 4000;
export const MOST_PER_DAY = 5000;                   // reports a day across everyone
export const MOST_BYTES_PER_DAY = 2 * 1024 * 1024 * 1024;
export const KEEP = 90 * 24 * 60 * 60 * 1000;

const ID = /^[A-Za-z0-9-]{8,64}$/;
const SHORT = /^[\x20-\x7E]{1,80}$/;     // printable ASCII: a device model, a numbers key
const word = (value, list) => (typeof value === "string" && list.includes(value) ? value : null);
const short = (value) => (typeof value === "string" && SHORT.test(value) ? value : null);

function base64Bytes(text) {
  if (typeof text !== "string" || !/^[A-Za-z0-9+/]*={0,2}$/.test(text) || text.length % 4 !== 0) return null;
  const binary = atob(text);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

/** A flat map of short keys to numbers or short words: the detector's readings, the page's ids. */
function facts(value, most = 40) {
  if (value === undefined || value === null) return {};
  if (typeof value !== "object" || Array.isArray(value)) return null;
  const out = {};
  for (const [key, v] of Object.entries(value).slice(0, most)) {
    if (!/^[A-Za-z0-9_.-]{1,40}$/.test(key)) return null;
    if (typeof v === "number" && Number.isFinite(v)) out[key] = v;
    else if (typeof v === "boolean") out[key] = v;
    else if (typeof v === "string" && v.length <= 2000) out[key] = v;
    else if (Array.isArray(v) && v.length <= 200 && v.every((x) => typeof x === "string" && x.length <= 200)) out[key] = v;
    else return null;
  }
  return out;
}

/**
 * One report as the app sends it:
 *   { id, kind, detector?, signature?, rating?, platform, channel, variant, version, os, device,
 *     page, note?, numbers?, context?, attachments?: [{name, type, data (base64)}] }
 * Returns { row, blobs: [{name, type, bytes}] }, or null when it isn't one of ours. Unlike a
 * diagnostics batch nothing is dropped alone: a report is the person's, whole or not at all.
 */
export function parseReport(body) {
  if (!body || typeof body !== "object") return null;
  const id = typeof body.id === "string" && ID.test(body.id) ? body.id : null;
  const kind = word(body.kind, KINDS);
  const platform = word(body.platform, PLATFORMS);
  const channel = word(body.channel, CHANNELS);
  const variant = word(body.variant, VARIANTS);
  const version = typeof body.version === "string" && /^[0-9.]{1,12} \([0-9]{1,6}\)$/.test(body.version) ? body.version : null;
  const os = typeof body.os === "string" && /^[0-9]{1,3}(\.[0-9]{1,3}){0,2}$/.test(body.os) ? body.os : null;
  const device = short(body.device);
  const page = word(body.page, PAGES);
  if (!id || !kind || !platform || !channel || !variant || !version || !os || !device || !page) return null;

  const detector = body.detector === undefined || body.detector === null ? null : word(body.detector, DETECTORS);
  if (kind === "spike" && !detector) return null;
  if (kind !== "spike" && detector) return null;
  const rating = body.rating === undefined || body.rating === null ? null : word(body.rating, ["up", "down"]);
  if ((kind === "rating") !== (rating !== null)) return null;
  const signature = body.signature === undefined || body.signature === null ? null
    : (typeof body.signature === "string" && body.signature.length <= 300 ? body.signature : undefined);
  if (signature === undefined) return null;
  const note = body.note === undefined || body.note === null || body.note === "" ? null
    : (typeof body.note === "string" && body.note.length <= MOST_NOTE ? body.note : undefined);
  if (note === undefined) return null;

  const numbers = facts(body.numbers);
  const context = facts(body.context);
  if (!numbers || !context) return null;
  const inline = JSON.stringify({ numbers, context });
  if (inline.length > MOST_CONTEXT) return null;

  const list = body.attachments ?? [];
  if (!Array.isArray(list) || list.length > Object.keys(ATTACHMENTS).length) return null;
  const blobs = [];
  for (const a of list) {
    const rule = ATTACHMENTS[a?.name];
    if (!rule || !rule.types.includes(a.type) || blobs.some((b) => b.name === a.name)) return null;
    const bytes = base64Bytes(a.data);
    if (!bytes || bytes.length === 0 || bytes.length > rule.most) return null;
    blobs.push({ name: a.name, type: a.type, bytes });
  }
  // A rating is a count: it carries no content of the person's.
  if (kind === "rating" && (blobs.length || note)) return null;

  return {
    row: { id, kind, detector, signature, rating, platform, channel, variant, version, os, device, page, note,
           numbers: JSON.stringify(numbers), context: JSON.stringify(context),
           attachments: JSON.stringify(blobs.map((b) => ({ name: b.name, type: b.type, size: b.bytes.length }))) },
    blobs,
  };
}

export const blobKey = (id, name) => `reports/${id}/${name}`;

async function sha256(bytes) {
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

const stream = (bytes) => new ReadableStream({ start(c) { c.enqueue(bytes); c.close(); } });

/**
 * Keeps one report: its objects first, then its row, so a row never names an object that isn't
 * there. The same id twice (a retry whose answer was lost) is taken without keeping it again.
 * Returns the HTTP status for the app.
 */
export async function keepReport(deps, parsed, now) {
  const { db, blobs } = deps;
  const { row } = parsed;
  if (await db.first("SELECT 1 AS x FROM problem_reports WHERE id = ?", row.id)) return 204;
  const today = await db.first("SELECT COUNT(*) AS n, COALESCE(SUM(bytes), 0) AS bytes FROM problem_reports WHERE received_at >= ?",
    now - 24 * 60 * 60 * 1000);
  const bytes = parsed.blobs.reduce((sum, b) => sum + b.bytes.length, 0) + row.context.length + row.numbers.length + (row.note?.length ?? 0);
  if (Number(today?.n) + 1 > MOST_PER_DAY || Number(today?.bytes) + bytes > MOST_BYTES_PER_DAY) return 429;
  for (const b of parsed.blobs) {
    if (!(await blobs.put(blobKey(row.id, b.name), stream(b.bytes), { sha256: await sha256(b.bytes) }))) return 500;
  }
  await db.run(
    `INSERT OR IGNORE INTO problem_reports (id, received_at, kind, detector, signature, rating, platform, channel, variant,
       version, os, device, page, note, numbers, context, attachments, bytes)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    row.id, now, row.kind, row.detector, row.signature, row.rating, row.platform, row.channel, row.variant,
    row.version, row.os, row.device, row.page, row.note, row.numbers, row.context, row.attachments, bytes);
  return 204;
}

/** The 15-minute job: reports older than KEEP go, objects first. A few hundred at a time. */
export async function forgetOldReports(deps, now) {
  const old = await deps.db.all("SELECT id, attachments FROM problem_reports WHERE received_at < ? LIMIT 200", now - KEEP);
  for (const r of old) {
    let names = [];
    try { names = JSON.parse(r.attachments).map((a) => a.name); } catch { names = []; }
    for (const name of names) await deps.blobs.delete(blobKey(r.id, name));
    await deps.db.run("DELETE FROM problem_reports WHERE id = ?", r.id);
  }
  return old.length;
}

/** The route: anonymous, limited per address like the other anonymous writes. */
export function reportRoutes(app, deps, { readJson, TOO_LARGE, BAD, clientIp }) {
  app.post("/v1/reports", async (c) => {
    if (!(await deps.limit("api", clientIp(c)))) return c.body(null, 429);
    const body = await readJson(c, MOST_BODY);
    if (body === TOO_LARGE) return c.body(null, 413);
    const parsed = body === BAD ? null : parseReport(body);
    if (!parsed) return c.body(null, 400);
    return c.body(null, await keepReport(deps, parsed, deps.now()));
  });
}
