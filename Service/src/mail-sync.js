// The devices' side of the shared cloud mailbox (docs/design/MAIL-CLOUD-SYNC.md): the feed, the
// catch-up check, content served from the mailbox, and the hooks the other Mail routes call.

import { mailLink } from "./mail-grant.js";
import { featureAllowed, googleCapabilities } from "./feature-access.js";

const fail = (status, message) => ({ status, body: { error: { code: status, message } } });
const ID = (x) => typeof x === "string" && x.length > 0 && x.length <= 256 && !/[\x00-\x1f]/.test(x);

/** The account's Mail link when it may read now, or a refusal. The same checks as /v1/mail/read. */
async function readableLink(deps, account, email) {
  if (!deps.mailboxes) return { refusal: fail(404, "Not found.") };
  if (typeof email !== "string" || email.length > 320) return { refusal: fail(400, "bad_request") };
  if (!(await featureAllowed(deps, account, "email"))) return { refusal: fail(403, "Email access is unavailable.") };
  const link = await mailLink(deps, account, email);
  if (!link || !googleCapabilities({ ...link, has_token: Boolean(link.refresh_token) }).mailRead) return { refusal: fail(403, "Connect Email for this Google account.") };
  if (link.client_id && link.client_id !== deps.config.googleClientId) return { refusal: fail(403, "Reconnect Email for this service.") };
  return { link };
}

/** The mailbox of a Google identity, if a device has started one. */
export async function existingMailbox(deps, sub) {
  if (!deps.mailboxes) return null;
  return (await deps.db.first("SELECT 1 AS x FROM mail_mailboxes WHERE google_sub = ?", sub)) ? deps.mailboxes.get(sub) : null;
}

export function parseFeedQuery(query) {
  if (!query || typeof query !== "object") return null;
  const raw = query.after === undefined || query.after === null || query.after === "" ? null : query.after;
  if (raw !== null && typeof raw !== "string") return null;
  const cursor = raw === null ? null : /^(\d{1,15})(?:-(\d{1,9}))?$/.exec(raw);
  if (raw !== null && !cursor) return null;
  const after = cursor ? cursor[1] : null, era = cursor?.[2] ? Number(cursor[2]) : 0;
  const limit = query.limit === undefined ? 500 : query.limit;
  if (!Number.isInteger(limit) || limit < 1 || limit > 1000) return null;
  if (typeof query.email !== "string") return null;
  return { email: query.email.toLowerCase(), after: after === null ? null : Number(after), era, limit, fresh: query.fresh === true };
}

export async function mailFeed(deps, account, request) {
  const { link, refusal } = await readableLink(deps, account, request.email);
  if (refusal) return refusal;
  const mailbox = deps.mailboxes.get(link.sub);
  await mailbox.ensure({ sub: link.sub, email: link.email, account });
  const answer = await mailbox.feed({ after: request.after, era: request.era, limit: request.limit, fresh: request.fresh });
  if (!answer.ready) return { status: 503, body: { error: { code: 503, message: "Mail is being prepared. Retry shortly." } }, retryAfter: 2 };
  if (answer.expired) return fail(410, "Start the feed again from the beginning.");
  const { ready, ...feed } = answer;
  return { status: 200, body: { version: 1, ...feed } };
}

export function parseMailCheck(x) {
  if (!x || typeof x.email !== "string" || !Array.isArray(x.ids) || x.ids.length < 1 || x.ids.length > 100 || !x.ids.every(ID)) return null;
  return { email: x.email.toLowerCase(), ids: [...new Set(x.ids)] };
}

export async function mailCheck(deps, account, request) {
  const { link, refusal } = await readableLink(deps, account, request.email);
  if (refusal) return refusal;
  const mailbox = await existingMailbox(deps, link.sub);
  if (!mailbox) return fail(409, "Read the feed first.");
  return { status: 200, body: await mailbox.check(request.ids) };
}

const formatOf = (request) => request.query.find((x) => x.name === "format")?.value ?? "full";

/** Reads the mailbox answers instead of Gmail: a message's full content and an attachment from
 * the store (Google once on a miss), and the profile from its own position. Everything else, and
 * every account without a mailbox, goes to Gmail as before (null). */
export async function mailboxRead(deps, vault, link, request) {
  const cached = (request.resource === "message" && formatOf(request) === "full") || request.resource === "attachment";
  if (!cached && request.resource !== "profile") return null;
  const mailbox = await existingMailbox(deps, link.sub);
  if (!mailbox) return null;
  if (request.resource === "profile") {
    const profile = await mailbox.profile();
    return profile && { status: 200, body: profile };
  }
  const state = await mailbox.content({ id: request.id, attachmentID: request.attachmentID });
  if (state.passthrough) return state.body ? { status: state.status, body: state.body } : null;
  if (!state.key) return state.retryAfter ? { ...state } : { status: state.status, body: state.body };
  const object = await deps.blobs.get(state.key);
  let plain;
  try {
    if (!object) throw new Error("content missing");
    plain = await vault.openBytes(state.aad, new Uint8Array(await new Response(object.body).arrayBuffer()));
  } catch {
    await mailbox.lost(request.id);   // the next read fetches it again
    return null;
  }
  const body = JSON.parse(new TextDecoder().decode(plain));
  if (request.resource === "message" && state.known) {
    // The stored content with the mailbox's current labels and the position they reflect.
    body.labelIds = state.labels;
    body.historyId = String(state.history);
  }
  return { status: 200, body };
}

/** After a device's label change reached Gmail: the mailbox reads it, so other devices see it. */
export async function noteMailAction(deps, sub, ids) {
  try { await (await existingMailbox(deps, sub))?.noteAction(ids); }
  catch (error) { console.log(`mailbox: action note failed (${error.name})`); }
}
/** After a draft or a send: the mailbox polls history now. */
export async function pokeMailbox(deps, sub) {
  try { await (await existingMailbox(deps, sub))?.poke(); }
  catch (error) { console.log(`mailbox: poke failed (${error.name})`); }
}
/** Mail turned off, the Google account unlinked, the Banana account deleted: all of it goes. */
export async function wipeMailbox(deps, sub) {
  if (!deps.mailboxes) return;
  await deps.mailboxes.get(sub).wipe();
  await deps.db.run("DELETE FROM mail_mailboxes WHERE google_sub = ?", sub);
}

// ---- bulk content (MAIL-CLOUD-SYNC §5a) ----

export const CONTENT_IDS_MOST = 50;
export const CONTENT_BYTES_MOST = 8 * 1024 * 1024;   // a response stops here; the rest is "later"

export function parseMailContent(x) {
  if (!x || typeof x.email !== "string" || x.email.length > 320 || !Array.isArray(x.ids) || x.ids.length < 1
      || x.ids.length > CONTENT_IDS_MOST || !x.ids.every(ID)) return null;
  return { email: x.email.toLowerCase(), ids: [...new Set(x.ids)] };
}

/** Many messages' stored content in one answer, for a device's pull. Only from the store: nothing
 * here asks Google, so a pull costs no Gmail quota. Each entry is the stored Gmail `full` message
 * with the mailbox's current labels and position, or `{id, missing}` (not stored yet: read it one
 * by one, or wait for the fill), `{id, gone}` (Gmail deleted it) or `{id, later}` (the answer is
 * full: ask again). An account reads only its own mailbox: the session's account must hold this
 * address's Mail link, and the content opens only with its own sub and id (the AAD). */
export async function mailContent(deps, vault, account, request) {
  const { link, refusal } = await readableLink(deps, account, request.email);
  if (refusal) return refusal;
  const mailbox = await existingMailbox(deps, link.sub);
  if (!mailbox) return fail(409, "Read the feed first.");
  const states = await mailbox.contents(request.ids);
  const messages = [];
  let bytes = 0;
  for (const state of states) {
    if (!state.key) { messages.push(state.gone ? { id: state.id, gone: true } : { id: state.id, missing: true }); continue; }
    if (bytes >= CONTENT_BYTES_MOST) { messages.push({ id: state.id, later: true }); continue; }
    const object = await deps.blobs.get(state.key);
    let body;
    try {
      if (!object) throw new Error("content missing");
      const plain = await vault.openBytes(state.aad, new Uint8Array(await new Response(object.body).arrayBuffer()));
      bytes += plain.length;
      body = JSON.parse(new TextDecoder().decode(plain));
    } catch {
      await mailbox.lost(state.id);
      messages.push({ id: state.id, missing: true });
      continue;
    }
    if (state.known) { body.labelIds = state.labels; body.historyId = String(state.history); }
    messages.push({ id: state.id, message: body });
  }
  return { status: 200, body: { version: 1, messages } };
}

// ---- Gmail push (MAIL-CLOUD-SYNC §2a) ----

/** The Pub/Sub push body's notice: `{emailAddress, historyId}` in base64 `message.data`. Only the
 * address is used, to find the mailbox; the historyId wakes nothing beyond "read history now". */
export function parsePushNotice(x) {
  const data = x?.message?.data;
  if (typeof data !== "string" || data.length > 4096) return null;
  try {
    const notice = JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(data), (c) => c.charCodeAt(0))));
    const email = notice?.emailAddress;
    return typeof email === "string" && email.length <= 320 && email.includes("@") ? { email: email.toLowerCase() } : null;
  } catch { return null; }
}

/** Pub/Sub's push: verified (its OIDC token, our audience, our service account), then the mailbox
 * of that address is woken. Unknown addresses and malformed notices are acknowledged (204) so
 * Pub/Sub does not retry them; a bad or missing token is refused (401). */
export async function mailPush(deps, authorization, body) {
  const audience = deps.config.mailPushAudience || `${deps.config.publicUrl}/v1/mail/push`;
  const serviceAccount = deps.config.mailPushServiceAccount;
  if (!deps.mailboxes || !deps.config.mailPushTopic || !serviceAccount) return { status: 404 };
  const match = /^Bearer ([A-Za-z0-9._-]{20,8192})$/.exec(authorization ?? "");
  if (!match) return { status: 401 };
  try { await deps.google.verifyPushToken(match[1], { audience, serviceAccount }); }
  catch (error) { console.log(`mail push: refused (${error.message})`); return { status: 401 }; }
  const notice = parsePushNotice(body);
  if (!notice) return { status: 204 };
  const row = await deps.db.first(`SELECT m.google_sub FROM mail_mailboxes m JOIN google_links g ON g.sub = m.google_sub
    WHERE g.email = ? AND g.status <> 'unlinked' LIMIT 1`, notice.email);
  if (!row) return { status: 204 };
  await deps.mailboxes.get(row.google_sub).wake();
  return { status: 204, woke: true };
}

/** Before Mail access is forgotten: end the mailbox's Gmail watch while a token still works. */
export async function stopMailWatch(deps, sub) {
  try { await (await existingMailbox(deps, sub))?.stopWatch(); }
  catch (error) { console.log(`mailbox: watch stop failed (${error.name})`); }
}
