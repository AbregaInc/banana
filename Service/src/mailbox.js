// One Google account's shared cloud mailbox at work (docs/design/MAIL-CLOUD-SYNC.md): the
// ingestion worker that downloads from Gmail once for every device, the content cache, and the
// calls the routes make. The state and its order rules are src/mail-mailbox.js; this file is the
// network, the pacing and the alarm. A Durable Object runs it on Workers (src/mailbox-do.js),
// node:sqlite on Node (src/adapters/mailboxes-sqlite.js); both hand in the same pieces.

import * as box from "./mail-mailbox.js";
import { reserveMailRead, nextMailReadAt } from "./mail-read-pacing.js";
import { mailLink } from "./mail-grant.js";
import { featureAllowed, googleCapabilities } from "./feature-access.js";
import { GoogleRefused } from "./google.js";
import { sha256Hex, hex } from "./crypto.js";

const SECOND = 1000, MINUTE = 60 * SECOND, DAY = 24 * 60 * MINUTE;
export const CACHE_MOST = 16 * 1024 * 1024;   // larger content is passed through, not stored
const ACTIVE = 2 * MINUTE;                       // a device read the feed this recently
const POLL_ACTIVE = 10 * SECOND, POLL_RECENT = 2 * MINUTE, POLL_IDLE = 30 * MINUTE;
const LABEL_CHECK_EVERY = 10 * MINUTE;
const STEPS_PER_ALARM = 25;
const BACKOFF = MINUTE;

class Retry extends Error { constructor(at) { super("retry"); this.at = at; } }
class Unauthorized extends Error {}

const encoder = new TextEncoder(), decoder = new TextDecoder();
const notFound = (body) => body?.error?.code === 404 && (body.error.status === "NOT_FOUND" || body.error.errors?.some((e) => e?.reason === "notFound"));

/** The bytes of a Gmail answer: a stream on the real port, a body on test fakes. `tooLarge` past `cap`. */
async function answerBytes(answer, cap) {
  if (answer.body !== undefined || !answer.stream) {
    const bytes = encoder.encode(JSON.stringify(answer.body ?? null));
    return bytes.length > cap ? { tooLarge: true } : { bytes };
  }
  const reader = answer.stream.getReader();
  const chunks = [];
  let size = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > cap) { await reader.cancel().catch(() => {}); return { tooLarge: true }; }
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const c of chunks) { bytes.set(c, offset); offset += c.byteLength; }
  return { bytes };
}
const parse = (bytes) => { try { return JSON.parse(decoder.decode(bytes)); } catch { return undefined; } };

/** R2 keys: nothing in them names the account or the message in the clear. */
export async function contentKey(sub, id, attachmentID = null) {
  const base = `mail/${await sha256Hex(sub)}/${await sha256Hex(id)}`;
  return attachmentID ? `${base}/a-${await sha256Hex(attachmentID)}` : `${base}/m`;
}
export const contentAAD = (sub, id, attachmentID = null) => `mail-content:${sub}:${id}${attachmentID ? `:${attachmentID}` : ""}`;

/**
 * @param {{port: {exec: Function, transaction: Function}, deps: object, vault: object, blobs: object,
 *   alarm: {set(at: number): Promise<void>|void}, destroy?: () => Promise<void>|void}} parts
 */
export function createMailbox({ port, deps, vault, blobs, alarm, destroy }) {
  let busy = null;                   // the step in hand: one at a time
  const inflight = new Map();        // content fetches by key: concurrent asks share one download
  let ready = false;
  const now = () => deps.now();
  const setup = () => { if (!ready) { box.migrate(port); ready = true; } };

  async function lock(work, { wait = true } = {}) {
    while (busy) { if (!wait) return undefined; await busy.catch(() => {}); }
    const run = (async () => work())();
    busy = run;
    try { return await run; } finally { if (busy === run) busy = null; }
  }

  /** The current Google access for this mailbox, or null when Email access is gone for good. */
  async function access() {
    const who = box.identity(port);
    if (!who.sub || !who.account) return null;
    if (!(await featureAllowed(deps, who.account, "email"))) return null;
    const link = await mailLink(deps, who.account, who.email);
    if (!link || link.sub !== who.sub || !googleCapabilities({ ...link, has_token: Boolean(link.refresh_token) }).mailRead) return null;
    if (link.client_id && link.client_id !== deps.config.googleClientId) return null;
    try {
      const { accessToken } = await deps.google.refresh(await vault.open(link.sub, link.refresh_token));
      return { token: accessToken, sub: link.sub, email: who.email };
    } catch (error) {
      if (error instanceof GoogleRefused) {
        if (link.mailGrant) await deps.db.run("UPDATE mail_grants SET status='refused',updated_at=? WHERE google_sub=? AND refresh_token=?", now(), link.sub, link.refresh_token);
        return null;
      }
      throw new Retry(now() + BACKOFF);
    }
  }

  /** A Gmail read, paced with every other read of this identity. Background reads only take a
   * free slot; anything else waits its turn (at most ten seconds). */
  async function gmail(who, request, { background = false } = {}) {
    const reservation = await reserveMailRead(deps, who.sub, request, { maxWait: background ? 0 : 10_000 });
    if (!reservation) throw new Retry(await nextMailReadAt(deps, who.sub));
    if (reservation.waitMS > 0) await deps.sleep(reservation.waitMS);
    const answer = await deps.google.mailRead(who.token, request);
    if ([401, 403].includes(answer.status)) {
      const { bytes } = await answerBytes(answer, 64 * 1024);
      const body = bytes && parse(bytes);
      const reasons = body?.error?.errors?.map((e) => e?.reason) ?? [];
      if (answer.status === 401 || reasons.some((r) => ["insufficientPermissions", "authError"].includes(r))) throw new Unauthorized();
      throw new Retry(now() + BACKOFF);
    }
    if (answer.status === 429 || answer.status >= 500) throw new Retry(now() + BACKOFF);
    return answer;
  }
  async function gmailJSON(who, request, options) {
    const answer = await gmail(who, request, options);
    const { bytes, tooLarge } = await answerBytes(answer, 8 * 1024 * 1024);
    if (tooLarge) throw new Retry(now() + BACKOFF);
    return { status: answer.status, body: parse(bytes) };
  }
  const q = (pairs) => Object.entries(pairs).filter(([, v]) => v !== null && v !== undefined).map(([name, value]) => ({ name, value: String(value) }));

  async function dropContent(ids) {
    const who = box.identity(port);
    for (const id of ids) {
      const prefix = (await contentKey(who.sub, id)).slice(0, -1);
      for (const key of await blobs.list(prefix, 1000)) await blobs.delete(key);
    }
  }

  // ---- the steps, in the agreed order ----

  async function handshake(who) {
    const profile = await gmailJSON(who, { resource: "profile", query: [] });
    if (profile.status !== 200) throw new Retry(now() + BACKOFF);
    // Invariant 2: the token answers for this mailbox's own address, or nothing is derived from it.
    if (String(profile.body?.emailAddress ?? "").toLowerCase() !== who.email) throw new Unauthorized();
    const historyId = Number(profile.body.historyId);
    if (!Number.isFinite(historyId) || historyId <= 0) throw new Retry(now() + BACKOFF);
    const labels = await gmailJSON(who, { resource: "labels", query: [] });
    if (labels.status !== 200 || !Array.isArray(labels.body?.labels)) throw new Retry(now() + BACKOFF);
    box.begin(port, { historyId, labels: labels.body.labels.map((l) => l?.id).filter((id) => typeof id === "string" && id), now: now() });
  }

  async function poll(who, { pages = 5 } = {}) {
    const start = box.checkpoint(port);
    let token = null;
    for (let i = 0; i < pages; i++) {
      const answer = await gmailJSON(who, { resource: "history", query: q({ startHistoryId: start, maxResults: 500, pageToken: token }) });
      if (answer.status === 404 && notFound(answer.body)) { box.expire(port); return; }
      if (answer.status !== 200 || !answer.body) throw new Retry(now() + BACKOFF);
      const applied = box.applyHistory(port, answer.body, { start: box.checkpoint(port), now: now() });
      if (applied.dropContent.length) await dropContent(applied.dropContent);
      token = answer.body.nextPageToken ?? null;
      if (!token) break;
    }
    box.setMeta(port, "poll", null);
  }

  async function verifyBatch(who, { prio = null, limit = 10 } = {}) {
    const next = box.verifyNext(port, { limit, prio });
    for (const { id } of next) {
      const floor = box.checkpoint(port);   // before the request leaves (applyRead)
      const answer = await gmailJSON(who, { resource: "message", id, query: q({ format: "minimal" }) });
      if (answer.status === 200 && answer.body?.id === id) box.applyRead(port, answer.body, { floor, now: now() });
      else if (answer.status === 404 && notFound(answer.body)) {
        if (box.applyGone(port, id, { now: now() }).cached) await dropContent([id]);
      } else if (answer.status === 400) box.verifyDone(port, id);   // not a message id Gmail knows how to read
      else throw new Retry(now() + BACKOFF);
    }
    return next.length > 0;
  }

  async function labelCheck(who) {
    for (const label of ["INBOX", "UNREAD"]) {
      const floor = box.checkpoint(port);
      const listed = new Set();
      let token = null, complete = false;
      for (let page = 0; page < 2; page++) {
        const answer = await gmailJSON(who, { resource: "messages", query: q({ labelIds: label, maxResults: 500, pageToken: token }) });
        if (answer.status !== 200) throw new Retry(now() + BACKOFF);
        const ids = Array.isArray(answer.body?.messages) ? answer.body.messages : [];
        for (const m of ids) if (m?.id) listed.add(m.id);
        box.applyListing(port, { label, ids, floor, now: now(), mark: false, verifyOnly: true });
        token = answer.body?.nextPageToken ?? null;
        if (!token) { complete = true; break; }
      }
      if (complete) box.checkLabelAbsence(port, { label, listed, floor, now: now() });
    }
    box.setMeta(port, "label_check_at", now());
  }

  /** One listing page or one close batch. False when the background lane has no free slot. */
  async function scanStep(who, scan) {
    if (scan.phase === "closing") { box.closeBatch(port, { scan, now: now() }); return true; }
    const label = scan.order[scan.index];
    // The first page of the first scan's Inbox is what a person is waiting for: not background.
    const head = scan.head && label === "INBOX" && scan.token === null;
    const request = { resource: "messages", query: q({ labelIds: label || null, includeSpamTrash: "true", maxResults: head ? 50 : 500, pageToken: scan.token }) };
    let answer;
    try { answer = await gmailJSON(who, request, { background: !head }); }
    catch (error) { if (error instanceof Retry && !head) return false; throw error; }
    if (answer.status === 400 && scan.token) {   // Gmail no longer takes this page token: that listing again
      box.setMeta(port, "scan", JSON.stringify({ ...scan, token: null }));
      return true;
    }
    if (answer.status !== 200) throw new Retry(now() + BACKOFF);
    const ids = Array.isArray(answer.body?.messages) ? answer.body.messages : [];
    box.applyListing(port, { label, ids, floor: scan.floor, now: now() });
    if (head) for (const m of ids) if (typeof m?.id === "string") port.exec("INSERT OR IGNORE INTO fetch (id, prio, at) VALUES (?, 0, ?)", m.id, now());
    const token = answer.body?.nextPageToken ?? null;
    const next = { ...scan, head: head ? false : scan.head, token };
    if (!token) { next.index++; next.token = null; }
    if (next.index >= scan.order.length) { next.phase = "closing"; next.after = 0; }
    box.setMeta(port, "scan", JSON.stringify(next));
    return true;
  }

  function pollEvery() {
    const read = Number(box.getMeta(port, "read_at") ?? 0);
    return now() - read < ACTIVE ? POLL_ACTIVE : now() - read < DAY ? POLL_RECENT : POLL_IDLE;
  }
  const pollDue = () => box.getMeta(port, "poll") !== null || now() - Number(box.getMeta(port, "polled_at") ?? 0) >= pollEvery();

  /** One unit of work. Returns when the next is due (ms epoch), or null when the mailbox is gone. */
  async function step() {
    const who = await access();
    if (!who) { await wipe(); return null; }
    if (box.checkpoint(port) === null) { await handshake(who); return now(); }
    if (await verifyBatch(who, { prio: 0 })) return now();
    if (pollDue()) { await poll(who); return now(); }
    const fetch = box.fetchNext(port, 4);
    if (fetch.length) {
      for (const id of fetch) { await content(who, id); box.fetchDone(port, id); }
      return now();
    }
    if (box.complete(port) && now() - Number(box.getMeta(port, "label_check_at") ?? 0) >= LABEL_CHECK_EVERY
        && now() - Number(box.getMeta(port, "read_at") ?? 0) < DAY) { await labelCheck(who); return now(); }
    if (await verifyBatch(who)) return now();
    const scan = box.scanState(port);
    if (scan) return (await scanStep(who, scan)) ? now() : Math.max(now() + 100, await nextMailReadAt(deps, who.sub));
    const dropped = box.maintain(port, { now: now() });
    if (dropped.length) await dropContent(dropped);
    return Number(box.getMeta(port, "polled_at") ?? now()) + pollEvery();
  }

  /** Steps until there is nothing to do now, then the alarm for the next. */
  async function run({ steps = STEPS_PER_ALARM } = {}) {
    setup();
    if (!box.identity(port).sub) return null;
    return lock(async () => {
      let next = now();
      for (let i = 0; i < steps && next !== null && next <= now(); i++) {
        try { next = await step(); }
        catch (error) {
          if (error instanceof Unauthorized) { await wipe(); return null; }
          next = error instanceof Retry ? Math.max(error.at, now() + SECOND) : now() + BACKOFF;
          if (!(error instanceof Retry)) console.log(`mailbox: step failed (${error.name})`);
        }
      }
      if (next !== null) await alarm.set(Math.max(next, now()));
      return next;
    });
  }

  /** The content of one message (Gmail `full`), or one attachment: stored once, from Google once. */
  async function content(who, id, attachmentID = null) {
    const key = await contentKey(who.sub, id, attachmentID);
    const state = box.contentState(port, id);
    if (state?.gone) return { status: 404, body: { error: { code: 404, status: "NOT_FOUND", message: "Not Found" } } };
    if (state?.cached && await blobs.head(key)) {
      box.touch(port, id, now());
      return { key, aad: contentAAD(who.sub, id, attachmentID), ...box.contentState(port, id) };
    }
    if (inflight.has(key)) return inflight.get(key);
    const work = (async () => {
      const request = attachmentID ? { resource: "attachment", id, attachmentID, query: [] } : { resource: "message", id, query: q({ format: "full" }) };
      const floor = box.checkpoint(port) ?? 0;   // before the request leaves (applyRead)
      const answer = await gmail(who, request);
      const { bytes, tooLarge } = await answerBytes(answer, CACHE_MOST);
      if (tooLarge) return { passthrough: true };
      const body = parse(bytes);
      if (answer.status === 404 && !attachmentID && notFound(body)) {
        if (box.applyGone(port, id, { now: now() }).cached) await dropContent([id]);
        return { status: 404, body };
      }
      if (answer.status !== 200 || body === undefined || (!attachmentID && body?.id !== id)) return { status: answer.status === 200 ? 502 : answer.status, body: body ?? { error: { code: 502, message: "Email temporarily unavailable." } } };
      if (!attachmentID) {
        const read = box.applyRead(port, body, { floor, now: now() });
        if (read.gone) return { status: 404, body: { error: { code: 404, status: "NOT_FOUND", message: "Not Found" } } };
      } else if (!box.contentState(port, id)) {
        return { passthrough: true, status: 200, body };   // an attachment of a message this mailbox doesn't know: served, not stored
      }
      const sealed = await vault.sealBytes(contentAAD(who.sub, id, attachmentID), bytes);
      const sha = hex(new Uint8Array(await crypto.subtle.digest("SHA-256", sealed)));
      if (!(await blobs.put(key, new Blob([sealed]).stream(), { sha256: sha }))) throw new Error("content store refused");
      box.markCached(port, id, sealed.length, now());
      return { key, aad: contentAAD(who.sub, id, attachmentID), fetched: true, ...box.contentState(port, id) };
    })();
    inflight.set(key, work);
    try { return await work; } finally { inflight.delete(key); }
  }

  async function wipe() {
    setup();
    const who = box.identity(port);
    if (who.sub) {
      const prefix = `mail/${await sha256Hex(who.sub)}/`;
      for (;;) {
        const keys = await blobs.list(prefix, 1000);
        if (!keys.length) break;
        for (const key of keys) await blobs.delete(key);
      }
      await deps.db.run("DELETE FROM mail_mailboxes WHERE google_sub = ?", who.sub);
    }
    box.drop(port);
    ready = false;
    await destroy?.();
  }

  const arm = async (at = now()) => alarm.set(at);

  return {
    run,
    wipe,
    async ensure({ sub, email, account }) {
      setup();
      const epoch = hex(deps.random(16));
      const who = box.ensure(port, { sub, email, account, epoch, now: now() });
      await deps.db.run(`INSERT INTO mail_mailboxes (google_sub, account_id, created_at, read_at) VALUES (?, ?, ?, ?)
        ON CONFLICT (google_sub) DO UPDATE SET account_id = excluded.account_id, read_at = excluded.read_at`, sub, account, now(), now());
      return who;
    },
    /** The device feed. A fresh request polls Gmail first when the last poll is older than the
     * active cadence; the first request makes the handshake. */
    async feed({ after, era = 0, limit, fresh }) {
      setup();
      box.setMeta(port, "read_at", now());
      if (box.checkpoint(port) === null || (fresh && now() - Number(box.getMeta(port, "polled_at") ?? 0) >= POLL_ACTIVE)) {
        await lock(async () => {
          const who = await access();
          if (!who) return;
          try {
            if (box.checkpoint(port) === null) await handshake(who);
            else await poll(who, { pages: 2 });
          } catch (error) { if (!(error instanceof Retry)) throw error; }
        }, { wait: box.checkpoint(port) === null });
      }
      if (box.checkpoint(port) === null) return { ready: false };
      await arm();
      return { ready: true, ...box.feed(port, { after, era, limit: Math.min(Math.max(1, limit), box.FEED_MAX) }) };
    },
    async check(ids) { setup(); const result = box.check(port, ids, now()); await arm(); return result; },
    async noteAction(ids) { setup(); if (!box.identity(port).sub) return; box.noteAction(port, ids, now()); await arm(); },
    async poke() { setup(); if (!box.identity(port).sub) return; box.setMeta(port, "poll", 1); await arm(); },
    /** The mailbox's own position as Gmail's profile: never newer than Gmail's, so a device's
     * floors stay conservative. Null before the handshake. */
    async profile() {
      setup();
      const who = box.identity(port), position = who.sub ? box.checkpoint(port) : null;
      if (position === null) return null;
      const total = Number(port.exec("SELECT COUNT(*) AS n FROM msg WHERE gone = 0")[0].n);
      return { emailAddress: who.email, historyId: String(position), messagesTotal: total };
    },
    /** What a device's content read gets: a stored copy's key, or a status from Gmail. */
    async content({ id, attachmentID = null }) {
      setup();
      const who = await access();
      if (!who) return { status: 403, body: { error: { code: 403, message: "Email access is unavailable." } } };
      try { return await content(who, id, attachmentID); }
      catch (error) {
        if (error instanceof Retry) return { status: 429, body: { error: { code: 429, message: "Mail reads are queued. Retry shortly." } }, retryAfter: 1 };
        if (error instanceof Unauthorized) return { status: 403, body: { error: { code: 403, message: "Reconnect Email for this Google account." } } };
        throw error;
      }
    },
    /** A stored copy that could not be read back: forget it; the next read fetches it again. */
    async lost(id) { setup(); box.uncache(port, id); },
    async status() { setup(); return box.identity(port).sub ? box.status(port) : null; },
    arm,
  };
}
