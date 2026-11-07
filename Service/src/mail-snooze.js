// Snooze by hidden Gmail labels (MAIL-ENGINE §8): the label names, and the rules the shared
// mailbox runs on one conversation's fresh state so a snooze returns on time with every device
// asleep. Pure, except pushMailChange: the one place a wake tells the devices.
//
// §8.2 rules 1 (wake), 2 (came back early) and 5 (left the inbox). Every change is a desired end
// state, so a device that wakes the same conversation too changes nothing twice.

import { pushTo } from "./app.js";

export const SNOOZED_PREFIX = "Banana/Snoozed/";
export const RETURNED = "Banana/Returned";
export const MUTED = "Banana/Muted";
const FIVE_MINUTES = 5 * 60 * 1000;
const SNOOZED = /^Banana\/Snoozed\/(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})Z$/;
/** The names the createLabel operation will make: Banana's own hidden labels and nothing else. */
export const BANANA_LABEL = /^Banana\/(Snoozed\/\d{8}T\d{4}Z|Returned|Muted)$/;

const pad = (n, width = 2) => String(n).padStart(width, "0");

/** `Banana/Snoozed/<yyyyMMdd'T'HHmm'Z'>`, rounded up to five minutes so at most 288 exist a day. */
export function snoozedName(ms) {
  const d = new Date(Math.ceil(ms / FIVE_MINUTES) * FIVE_MINUTES);
  return `${SNOOZED_PREFIX}${pad(d.getUTCFullYear(), 4)}${pad(d.getUTCMonth() + 1)}${pad(d.getUTCDate())}T${pad(d.getUTCHours())}${pad(d.getUTCMinutes())}Z`;
}

/** {kind:"snoozed", at} | {kind:"returned"} | {kind:"muted"} | null. A time that is no real UTC
 * minute (20261131, 2460) is not Banana's label. */
export function parseBananaLabel(name) {
  if (typeof name !== "string") return null;
  if (name === RETURNED) return { kind: "returned" };
  if (name === MUTED) return { kind: "muted" };
  const m = SNOOZED.exec(name);
  if (!m) return null;
  const [y, mo, d, h, mi] = m.slice(1).map(Number);
  const at = Date.UTC(y, mo - 1, d, h, mi);
  const back = new Date(at);
  if (back.getUTCFullYear() !== y || back.getUTCMonth() !== mo - 1 || back.getUTCDate() !== d || back.getUTCHours() !== h || back.getUTCMinutes() !== mi) return null;
  return { kind: "snoozed", at };
}

const BIN = ["TRASH", "SPAM"];

/** What a conversation's labels say. `messages`: [{id, labels: [label ids], internalDate}], one
 * thread; `names`: Map label id → name. `due` is when a rule applies (0: now), or null. */
export function snoozeState(messages, names) {
  const kind = (id) => parseBananaLabel(names.get(id));
  let returnedID = null;
  for (const [id, name] of names) if (name === RETURNED) returnedID = id;
  const facts = messages.map((m) => {
    const labels = new Set(Array.isArray(m.labels) ? m.labels : []);
    const snoozed = [...labels].filter((l) => kind(l)?.kind === "snoozed");
    return { id: m.id, date: Number(m.internalDate ?? 0), labels, snoozed,
      returned: returnedID !== null && labels.has(returnedID), binned: BIN.some((l) => labels.has(l)) };
  });
  const live = facts.filter((f) => !f.binned);
  const carriers = live.filter((f) => f.snoozed.length);
  const returned = live.filter((f) => f.returned), inbox = live.filter((f) => f.labels.has("INBOX"));
  const at = carriers.length ? Math.max(...carriers.flatMap((f) => f.snoozed.map((l) => kind(l).at))) : null;
  let rule = null, due = null;
  if (carriers.length && !returned.length && !inbox.length) { rule = "wake"; due = at; }
  else if (carriers.length && inbox.length && !returned.length) { rule = "early"; due = 0; }
  else if (returned.length && !inbox.length) { rule = "left"; due = 0; }
  else if (!carriers.length && facts.some((f) => f.binned && (f.snoozed.length || f.returned))) { rule = "binned"; due = 0; }
  return { rule, due, at, facts, live, carriers, returnedID };
}

/**
 * The changes due now on one conversation's FRESH state: [{id, add, remove}], each only what is
 * not already true, the message that gets INBOX first (Returned on a conversation with no INBOX
 * anywhere would read as rule 5 to another device). `missing` names a label the wake needs that
 * has no id yet: create it, then ask again.
 * @returns {{rule: string|null, changes: {id: string, add: string[], remove: string[]}[], missing: string|null}}
 */
export function snoozeAssertions(messages, names, now) {
  const state = snoozeState(messages, names);
  const { rule, due, facts, live, carriers, returnedID } = state;
  const none = { rule: null, changes: [], missing: null };
  if (rule === null || due > now) return none;
  const strip = (list) => list
    .map((f) => ({ id: f.id, add: [], remove: [...f.snoozed, ...(f.returned ? [returnedID] : [])] }))
    .filter((c) => c.remove.length);
  if (rule === "early") return { rule, changes: strip(carriers), missing: null };
  if (rule === "left") return { rule, changes: strip(live.filter((f) => f.snoozed.length || f.returned)), missing: null };
  if (rule === "binned") return { rule, changes: strip(facts.filter((f) => f.binned)), missing: null };
  // Wake: INBOX on the last message that is not a draft (a draft takes no label; were it the
  // target, Returned would land and INBOX would not, and rule 5 would end the snooze for good);
  // Returned on exactly the messages that carry the Snoozed label.
  const target = live.filter((f) => !f.labels.has("DRAFT"))
    .sort((a, b) => a.date - b.date || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0)).at(-1);
  if (!target) return none;
  if (returnedID === null) return { rule, changes: [], missing: RETURNED };
  const want = (f, labels) => ({ id: f.id, add: labels.filter((l) => !f.labels.has(l)), remove: [] });
  const changes = [want(target, ["INBOX", "UNREAD", ...(target.snoozed.length ? [returnedID] : [])])];
  for (const f of carriers) if (f !== target) changes.push(want(f, [returnedID]));
  return { rule, changes: changes.filter((c) => c.add.length), missing: null };
}

/** The silent push after the mailbox woke a conversation: the devices read the feed. The one call
 * site, so moving pushTo (to src/push.js) changes one import. */
export function pushMailChange(deps, account) {
  return pushTo(deps, account, { payload: { aps: { "content-available": 1 }, b: { k: "mail" } }, collapseId: "mail", label: "push(mail-snooze)" });
}
