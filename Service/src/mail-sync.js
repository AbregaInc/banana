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
