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
import { pushTo } from "./push.js";
import { snoozeAssertions } from "./mail-snooze.js";

const SECOND = 1000, MINUTE = 60 * SECOND, DAY = 24 * 60 * MINUTE;
export const CACHE_MOST = 16 * 1024 * 1024;   // larger content is passed through, not stored
const ACTIVE = 2 * MINUTE;                       // a device read the feed this recently
const POLL_ACTIVE = 10 * SECOND, POLL_RECENT = 2 * MINUTE, POLL_IDLE = 30 * MINUTE;
const LABEL_CHECK_EVERY = 10 * MINUTE;
const STEPS_PER_ALARM = 25;
const BACKOFF = MINUTE;
// With a live Gmail watch (users.watch → Pub/Sub → /v1/mail/push) a change wakes the mailbox at
// once; polling stays as the safety net, at a slower pace.
const POLL_ACTIVE_WATCHED = MINUTE, POLL_RECENT_WATCHED = 10 * MINUTE, POLL_IDLE_WATCHED = 2 * 60 * MINUTE;
export const WATCH_RENEW_BEFORE = DAY;         // Gmail ends a watch after 7 days
// The content fill: every message inside the window, newest first, on the background lane only.
// It uses whatever of the identity's read budget nobody else is using, up to the 4,500 units a
// minute ceiling (mail-read-pacing.js) less one full-read slot a minute kept for a person: 74
// units a second, one full read every 811 ms. A background read only takes a slot that is free
// now, so a person's read never waits behind it for more than one slot (800 ms).
export const FILL_DAYS = 183;                   // six months, the engine's default sync limit
export const FILL_CEILING_UNITS_PER_MINUTE = 4500;
export const FILL_RESERVE_UNITS = 60;           // one full read a minute, for interactive reads only
export const FILL_UNITS_PER_SECOND = (FILL_CEILING_UNITS_PER_MINUTE - FILL_RESERVE_UNITS) / 60;
const FILL_READ_UNITS = 60;                     // a full message read (mail-read-pacing.js)
// When Google says "too many" (429, rateLimitExceeded), the fill halves its rate for five
// minutes (again for each further limit, to an eighth), then ramps back to full over five more.
export const FILL_BACKOFF = 5 * MINUTE;
export const FILL_RAMP = 5 * MINUTE;
const FILL_FLOOR = 0.125;
const FILL_OLD_STOP = 20;                       // this many in a row older than the window: done
const FILL_AGAIN = 6 * 60 * MINUTE;             // a finished fill looks again (skipped, new rows)
// "New mail is here" to the devices: one silent push for a burst, at most one per this gap.
export const PUSH_GAP = 15 * SECOND;
export const MAIL_PUSH = { aps: { "content-available": 1 }, b: { k: "mail" } };
const SNOOZE_THREADS = 5;                        // conversations a step wakes at most

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
    const can = link && googleCapabilities({ ...link, has_token: Boolean(link.refresh_token) });
    if (!link || link.sub !== who.sub || !can.mailRead) return null;
    if (link.client_id && link.client_id !== deps.config.googleClientId) return null;
    try {
      const { accessToken } = await deps.google.refresh(await vault.open(link.sub, link.refresh_token));
      return { token: accessToken, sub: link.sub, email: who.email, account: who.account, modify: can.mailModify };
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
      refused(answer.status, bytes && parse(bytes));
    }
    if (answer.status === 429) { noteLimited(); throw new Retry(now() + BACKOFF); }
    if (answer.status >= 500) throw new Retry(now() + BACKOFF);
    return answer;
  }
  /** The fill's share of the budget now: 1, halved for FILL_BACKOFF after each limit Google
   * stated (to FILL_FLOOR), then ramping back to 1 over FILL_RAMP. */
  function fillFactor(at = now()) {
    const limited = box.getMeta(port, "fill_limited_at");
    if (limited === null) return 1;
    const base = Number(box.getMeta(port, "fill_factor") ?? 1), t = at - Number(limited);
    if (t < FILL_BACKOFF) return base;
    if (t < FILL_BACKOFF + FILL_RAMP) return base + (1 - base) * (t - FILL_BACKOFF) / FILL_RAMP;
    return 1;
  }
  function noteLimited() {
    box.setMeta(port, "fill_factor", Math.max(FILL_FLOOR, fillFactor() / 2));
    box.setMeta(port, "fill_limited_at", now());
  }
  async function gmailJSON(who, request, options) {
    const answer = await gmail(who, request, options);
    const { bytes, tooLarge } = await answerBytes(answer, 8 * 1024 * 1024);
    if (tooLarge) throw new Retry(now() + BACKOFF);
    return { status: answer.status, body: parse(bytes) };
  }
  /** A 401, or a 403 for permission: the grant is gone (the mailbox is wiped). Any other 403 is a
   * rate limit: later. */
  function refused(status, body) {
    const reasons = body?.error?.errors?.map((e) => e?.reason) ?? [];
    if (status === 401 || reasons.some((r) => ["insufficientPermissions", "authError"].includes(r))) throw new Unauthorized();
    if (reasons.some((r) => ["rateLimitExceeded", "userRateLimitExceeded"].includes(r))) noteLimited();
    throw new Retry(now() + BACKOFF);
  }
  /** A Gmail write takes its share of the identity's pacing like any read. */
  async function pace(who, resource) {
    const reservation = await reserveMailRead(deps, who.sub, { resource, query: [] });
    if (!reservation) throw new Retry(await nextMailReadAt(deps, who.sub));
    if (reservation.waitMS > 0) await deps.sleep(reservation.waitMS);
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
    box.replaceLabels(port, labels.body.labels);
  }

  async function refreshLabels(who) {
    const labels = await gmailJSON(who, { resource: "labels", query: [] });
    if (labels.status !== 200 || !Array.isArray(labels.body?.labels)) throw new Retry(now() + BACKOFF);
    box.replaceLabels(port, labels.body.labels);
  }

  // ---- snooze (MAIL-ENGINE §8): the mailbox wakes a conversation on time, every device asleep ----

  /** Banana's hidden label `name`, made in Gmail (a device may have made it meanwhile: 409). */
  async function ensureLabel(who, name) {
    await pace(who, "createLabel");
    let answer;
    try { answer = await deps.google.mailCreateLabel(who.token, { name, labelListVisibility: "labelHide", messageListVisibility: "hide" }); }
    catch { throw new Retry(now() + BACKOFF); }
    if (answer.status === 200 && typeof answer.body?.id === "string") return box.noteLabel(port, answer.body);
    if (answer.status === 409) return refreshLabels(who);
    if ([401, 403].includes(answer.status)) refused(answer.status, answer.body);
    throw new Retry(now() + BACKOFF);
  }

  async function modify(who, change) {
    await pace(who, "modify");
    let answer;
    try { answer = await deps.google.mailMutation(who.token, { id: change.id, action: "modify", add: change.add, remove: change.remove }); }
    catch { throw new Retry(now() + BACKOFF); }
    if (answer.status === 200) return true;
    if ([401, 403].includes(answer.status)) refused(answer.status, answer.body);
    if (answer.status === 404) return false;   // deleted meanwhile: its read says so
    if (answer.status === 400) box.setMeta(port, "labels_due", 1);   // a label Gmail no longer has
    throw new Retry(now() + BACKOFF);
  }

  /** One conversation: read fresh, the rules run on what Gmail says now, the changes made in order.
   * Returns true when it was woken into the Inbox. */
  async function settleThread(who, thread) {
    const floor = box.checkpoint(port);   // before the request leaves (applyRead)
    const answer = await gmailJSON(who, { resource: "thread", id: thread, query: q({ format: "minimal" }) });
    if (answer.status === 404 && notFound(answer.body)) { box.noteAction(port, box.threadMessages(port, thread), now()); return false; }
    if (answer.status !== 200 || !Array.isArray(answer.body?.messages)) throw new Retry(now() + BACKOFF);
    const messages = answer.body.messages.filter((m) => typeof m?.id === "string" && m.threadId === thread);
    for (const m of messages) box.applyRead(port, m, { floor, now: now() });
    const facts = messages.map((m) => ({ id: m.id, labels: m.labelIds ?? [], internalDate: m.internalDate }));
    let result = snoozeAssertions(facts, box.labelNames(port), now());
    if (result.missing) {
      await ensureLabel(who, result.missing);
      result = snoozeAssertions(facts, box.labelNames(port), now());
      if (result.missing) throw new Retry(now() + BACKOFF);
    }
    const changed = [];
    try {
      for (const change of result.changes) if (await modify(who, change)) changed.push(change.id);
    } finally {
      // Read back like a device's action, so the feed carries Gmail's own position for each.
      if (changed.length) box.noteAction(port, changed, now());
    }
    // The first change of a wake is the one that puts it in the Inbox.
    return result.rule === "wake" && changed[0] === result.changes[0]?.id;
  }

  /** The conversations a snooze rule is due on now. False when there are none. */
  async function snoozeStep(who) {
    const due = box.snoozeDue(port, { now: now(), limit: SNOOZE_THREADS });
    if (!due.length) return false;
    if (!who.modify) {   // a read-only grant: nothing can be woken; they wait instead of spinning
      for (const thread of due) box.snoozeSettled(port, thread, now());
      return false;
    }
    let woke = false;
    try {
      for (const thread of due) {
        try { if (await settleThread(who, thread)) woke = true; }
        finally { box.snoozeSettled(port, thread, now()); }
      }
    } finally {
      // The same coalesced "mail changed" push as new mail (pushIfDue): the devices read the feed.
      if (woke) box.setMeta(port, "push_due", now());
    }
    return true;
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

  const watched = () => deps.config.mailPushTopic && Number(box.getMeta(port, "watch_expires") ?? 0) > now();
  function pollEvery() {
    const read = Number(box.getMeta(port, "read_at") ?? 0), w = watched();
    return now() - read < ACTIVE ? (w ? POLL_ACTIVE_WATCHED : POLL_ACTIVE)
      : now() - read < DAY ? (w ? POLL_RECENT_WATCHED : POLL_RECENT) : (w ? POLL_IDLE_WATCHED : POLL_IDLE);
  }
  const pollDue = () => box.getMeta(port, "poll") !== null || now() - Number(box.getMeta(port, "polled_at") ?? 0) >= pollEvery();

  /** One unit of work. Returns when the next is due (ms epoch), or null when the mailbox is gone. */
  async function step() {
    const who = await access();
    if (!who) { await wipe(); return null; }
    if (box.checkpoint(port) === null) { await handshake(who); return now(); }
    if (deps.config.mailPushTopic && Number(box.getMeta(port, "watch_expires") ?? 0) - now() < WATCH_RENEW_BEFORE
        && now() - Number(box.getMeta(port, "watch_tried_at") ?? 0) >= 60 * MINUTE) {
      box.setMeta(port, "watch_tried_at", now());
      try { await watch(who); } catch (error) { if (!(error instanceof Retry)) throw error; }   // polling carries on; tried again in an hour
      return now();
    }
    if (await verifyBatch(who, { prio: 0 })) return now();
    if (pollDue()) { await poll(who); return now(); }
    if (box.getMeta(port, "labels_due") !== null) { await refreshLabels(who); return now(); }
    if (await snoozeStep(who)) return now();
    const fetch = box.fetchNext(port, 4);
    if (fetch.length) {
      for (const id of fetch) { await content(who, id); box.fetchDone(port, id); }
      return now();
    }
    // New mail's content is here: tell the devices (one push for a burst; null once sent).
    const pushAt = await pushIfDue();
    if (box.complete(port) && now() - Number(box.getMeta(port, "label_check_at") ?? 0) >= LABEL_CHECK_EVERY
        && now() - Number(box.getMeta(port, "read_at") ?? 0) < DAY) { await refreshLabels(who); await labelCheck(who); return now(); }
    if (await verifyBatch(who)) return now();
    const scan = box.scanState(port);
    if (scan) return (await scanStep(who, scan)) ? now() : Math.max(now() + 100, await nextMailReadAt(deps, who.sub));
    const fillAt = await fillStep(who);
    if (fillAt !== null && fillAt <= now()) return now();
    const dropped = box.maintain(port, { now: now(), keepSince: fillSince() });
    if (dropped.length) await dropContent(dropped);
    return Math.min(Number(box.getMeta(port, "polled_at") ?? now()) + pollEvery(), fillAt ?? Infinity, pushAt ?? Infinity);
  }

  const fillSince = () => now() - (deps.config.mailFillDays ?? FILL_DAYS) * DAY;

  /** One read of the content fill. Returns when the fill can go on (now: at once), or null when it
   * has nothing to do. It takes only a background slot and at most half the pace, so a device's
   * read is never queued behind it, and stops once it walks out of its window. */
  async function fillStep(who) {
    const state = box.fillState(port);
    if (state.done !== null) {
      if (now() - state.done < FILL_AGAIN) return state.done + FILL_AGAIN;
      box.setFillState(port, { after: null, old: 0, done: null });
      return now();
    }
    const nextAt = Number(box.getMeta(port, "fill_next_at") ?? 0);
    if (nextAt > now()) return nextAt;
    const since = fillSince();
    // Rows already known to be out of the window or in Spam/Trash are passed without a read.
    let after = state.after, old = state.old;
    for (let i = 0; i < 50; i++) {
      const [r] = box.fillNext(port, { after, limit: 1 });
      if (!r) { box.setFillState(port, { after, old, done: now() }); return null; }
      if (!box.fillSkips(r, since)) break;
      after = r.id;
      if (r.date !== null && r.date < since && ++old >= FILL_OLD_STOP) { box.setFillState(port, { after, old, done: now() }); return null; }
    }
    if (after !== state.after) { box.setFillState(port, { after, old, done: null }); return now(); }
    const [next] = box.fillNext(port, { after, limit: 1 });
    let answer;
    try { answer = await content(who, next.id, null, { background: true }); }
    catch (error) {
      if (error instanceof Retry) {
        // No free slot (or Google said wait): the next free slot, and the fill's own pace.
        const paced = now() + Math.ceil(FILL_READ_UNITS * 1000 / (FILL_UNITS_PER_SECOND * fillFactor()));
        if (box.getMeta(port, "fill_limited_at") !== null && now() - Number(box.getMeta(port, "fill_limited_at")) < 1000) {
          box.setMeta(port, "fill_next_at", paced);
          return paced;
        }
        return Math.max(now() + 100, await nextMailReadAt(deps, who.sub));
      }
      throw error;
    }
    const date = box.contentState(port, next.id)?.date ?? null;
    old = date !== null && date < since ? old + 1 : 0;
    // The watermark moves past it whatever the answer (too large, refused, gone): a later walk
    // tries again; a device that opens it asks for it itself.
    box.setFillState(port, { after: next.id, old, done: old >= FILL_OLD_STOP ? now() : null });
    box.setMeta(port, "fill_next_at", now() + Math.ceil(FILL_READ_UNITS * 1000 / (FILL_UNITS_PER_SECOND * fillFactor())));
    if (answer?.fetched) box.setMeta(port, "filled", Number(box.getMeta(port, "filled") ?? 0) + 1);
    return now();
  }

  /** The one silent push to the account's devices: new mail's content was stored, or a snooze
   * woke a conversation. At most one per PUSH_GAP; a burst sends one. Returns when one is next
   * due, or null. */
  async function pushIfDue() {
    const due = box.getMeta(port, "push_due");
    if (due === null) return null;
    const last = Number(box.getMeta(port, "pushed_at") ?? 0);
    if (now() - last < PUSH_GAP) return last + PUSH_GAP;
    box.setMeta(port, "push_due", null);
    box.setMeta(port, "pushed_at", now());
    const { account } = box.identity(port);
    if (account && deps.apns) {
      try { await pushTo(deps, account, { payload: MAIL_PUSH, collapseId: "mail", label: "push(mail)" }); }
      catch (error) { console.log(`mailbox: push failed (${error.name})`); }
    }
    return null;
  }

  /** users.watch: Gmail tells Pub/Sub, Pub/Sub tells /v1/mail/push. No label filter: an include
   * filter is evaluated on the message's labels after the change, so an archive (INBOX removed), a
   * label added to mail outside the Inbox, or a message sent from another client would never wake
   * the mailbox. Every change wakes it; the wake is one history read, coalesced by the lock. */
  async function watch(who) {
    const topic = deps.config.mailPushTopic;
    if (!topic || !deps.google.mailWatch) return null;
    let answer;
    try { answer = await deps.google.mailWatch(who.token, { topicName: topic }); }
    catch (error) {
      // A refused watch is a setup problem (topic, publisher grant), not lost access: keep syncing by polling.
      console.log(`mailbox: watch failed (${error.status ?? error.name})`);
      throw new Retry(now() + BACKOFF);
    }
    const expires = Number(answer?.expiration);
    if (!Number.isFinite(expires) || expires <= now()) throw new Retry(now() + BACKOFF);
    box.setMeta(port, "watch_expires", expires);
    await deps.db.run("UPDATE mail_mailboxes SET watch_expires_at = ? WHERE google_sub = ?", expires, who.sub);
    return expires;
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
      if (next === null) return null;
      // A snooze due before the next step: the alarm is set for it, idle or not.
      const wake = box.snoozeNext(port, { now: now() });
      await alarm.set(Math.max(wake === null ? next : Math.min(next, wake), now()));
      await recordWake(wake);
      return next;
    });
  }

  /** The earliest pending wake, in D1 too: the quarter-hour job sets an alarm that was lost again. */
  async function recordWake(wake) {
    const stored = box.getMeta(port, "wake_at");
    if ((stored === null ? null : Number(stored)) === wake) return;
    try {
      await deps.db.run("UPDATE mail_mailboxes SET wake_at = ? WHERE google_sub = ?", wake, box.identity(port).sub);
      box.setMeta(port, "wake_at", wake);
    } catch (error) { console.log(`mailbox: wake record failed (${error.name})`); }
  }

  /** The content of one message (Gmail `full`), or one attachment: stored once, from Google once. */
  async function content(who, id, attachmentID = null, { background = false } = {}) {
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
      const answer = await gmail(who, request, { background });
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
      const published = box.markCached(port, id, sealed.length, now());
      // New mail (the fetch queue's prio 1) is worth waking the devices for; the fill is not.
      if (published && !background && box.isNewMail(port, id)) box.setMeta(port, "push_due", now());
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
    async noteAction(ids, labels = []) { setup(); if (!box.identity(port).sub) return; box.noteAction(port, ids, now(), labels); await arm(); },
    /** A label a device had Gmail make (the createLabel operation). */
    async noteLabel(label) { setup(); if (!box.identity(port).sub) return; box.noteLabel(port, label); await arm(); },
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
    /** Many messages' stored content at once, for a device's bulk pull: the R2 key of each that is
     * stored, `gone` for one Gmail deleted, `missing` for the rest. Never asks Google: a pull costs
     * no Gmail quota, and what is missing a device reads one by one (or waits for the fill). */
    async contents(ids) {
      setup();
      const who = box.identity(port);
      if (!who.sub) return [];
      const out = [];
      for (const { id, state } of box.contentStates(port, ids)) {
        if (state?.gone) out.push({ id, gone: true });
        else if (state?.cached > 0) {
          box.touch(port, id, now());
          out.push({ id, key: await contentKey(who.sub, id), aad: contentAAD(who.sub, id), known: state.known, labels: state.labels, history: state.history });
        } else out.push({ id, missing: true });
      }
      return out;
    },
    /** Gmail's push (via Pub/Sub) says something changed: read history now. The notice's own
     * historyId is not trusted for anything; the walk starts from the stored checkpoint. */
    async wake() { setup(); if (!box.identity(port).sub) return false; box.setMeta(port, "poll", 1); box.setMeta(port, "woken_at", now()); await arm(); return true; },
    /** Starts or renews the Gmail watch (the quarter-hour job, a day before it ends). */
    async watch() {
      setup();
      if (!box.identity(port).sub || !deps.config.mailPushTopic) return null;
      const who = await access();
      if (!who) { await wipe(); return null; }
      try { return await lock(() => watch(who)); }
      catch (error) { if (error instanceof Retry) return null; throw error; }
    },
    /** Ends the Gmail watch, before Mail access is forgotten. Best effort: an unstopped watch ends
     * within 7 days, and a notice for a mailbox that is gone is dropped. */
    async stopWatch() {
      setup();
      if (!box.identity(port).sub || box.getMeta(port, "watch_expires") === null || !deps.google.mailStopWatch) return false;
      try {
        const who = await access();
        if (who) await deps.google.mailStopWatch(who.token);
      } catch (error) { console.log(`mailbox: watch stop failed (${error.name})`); }
      box.setMeta(port, "watch_expires", null);
      return true;
    },
    /** A stored copy that could not be read back: forget it; the next read fetches it again. */
    async lost(id) { setup(); box.uncache(port, id); },
    async status() { setup(); return box.identity(port).sub ? box.status(port) : null; },
    arm,
  };
}
