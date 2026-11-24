// Exact sender and domain rules, scoped by the existing Google-identity mailbox. Addresses are
// hashed before storage; blocked mail is changed through Gmail and read back.
import addressparser from "nodemailer/lib/addressparser/index.js";
import { sha256Hex } from "./crypto.js";

export function senderAddress(value) {
  if (typeof value !== "string" || value.length > 320 || /[\x00-\x1f\x7f]/.test(value)) return null;
  const parsed = addressparser(value);
  if (parsed.length !== 1 || !parsed[0].address || parsed[0].group) return null;
  const address = parsed[0].address.trim().toLowerCase();
  return address.includes("@") && address.lastIndexOf("@") > 0 ? address : null;
}

function senderDomain(value) {
  if (typeof value !== "string" || value.length > 253 || !/^[\p{L}\p{M}0-9._-]+$/u.test(value)) return null;
  try {
    const host = new URL(`https://${value}`).hostname.toLowerCase();
    const labels = host.split(".");
    return labels.length >= 2 && labels.every(label => /^[a-z0-9_](?:[a-z0-9_-]{0,61}[a-z0-9_])?$/.test(label))
      && /[a-z]/.test(labels.at(-1)) ? host : null;
  } catch { return null; }
}

export function parseSenderPolicy(value) {
  if (!value || typeof value.email !== "string" || value.email.length > 320) return null;
  const scope = value.scope ?? "address";
  if (scope !== "address" && scope !== "domain") return null;
  const sender = scope === "domain" ? senderDomain(value.sender) : senderAddress(value.sender);
  if (!sender || sender !== value.sender.trim().toLowerCase()) return null;
  const read = value.blocked === undefined;
  if (!read && (typeof value.blocked !== "boolean" || !Number.isSafeInteger(value.revision)
      || value.revision < 0 || typeof value.operation !== "string" || !/^[a-f0-9-]{36}$/i.test(value.operation))) return null;
  return { email: value.email.toLowerCase(), sender, scope,
    ...(read ? {} : { blocked: value.blocked, revision: value.revision, operation: value.operation }) };
}

export const senderKey = (address, scope = "address") =>
  sha256Hex((scope === "domain" ? "domain\0" : "") + address.toLowerCase());
export const hasBlockedSenders = (port) => Boolean(port.exec("SELECT EXISTS(SELECT 1 FROM sender_policy WHERE blocked=1) AS yes")[0].yes);
export function senderPolicy(port, key) {
  const row = port.exec("SELECT blocked,revision,operation FROM sender_policy WHERE sender=?", key)[0];
  return row ? { blocked: Boolean(row.blocked), revision: Number(row.revision), operation: row.operation }
    : { blocked: false, revision: 0, operation: null };
}
export function setSenderPolicy(port, key, request, now = Date.now()) {
  return port.transaction(() => {
    const current = senderPolicy(port, key);
    if (current.operation === request.operation) return { status: 200, body: current };
    if (current.revision !== request.revision) return { status: 409, body: current };
    if (current.revision >= Number.MAX_SAFE_INTEGER) return { status: 409, body: current };
    const next = { blocked: request.blocked, revision: current.revision + 1, operation: request.operation };
    const since = next.blocked ? (current.blocked
      ? Number(port.exec("SELECT blocked_since FROM sender_policy WHERE sender=?", key)[0].blocked_since) : now) : 0;
    port.exec("INSERT INTO sender_policy(sender,blocked,revision,operation,blocked_since) VALUES(?,?,?,?,?) ON CONFLICT(sender) DO UPDATE SET blocked=excluded.blocked,revision=excluded.revision,operation=excluded.operation,blocked_since=excluded.blocked_since",
      key, Number(next.blocked), next.revision, next.operation, since);
    return { status: 200, body: next };
  });
}

export async function matchingSenderPolicy(port, message, ownAddress) {
  const labels = message.labelIds ?? [];
  if (!labels.some(id => ["INBOX", "SPAM"].includes(id)) || labels.some(id => ["TRASH", "SENT", "DRAFT"].includes(id))) return null;
  const from = (message.payload?.headers ?? []).filter((h) => h.name?.toLowerCase() === "from");
  if (from.length !== 1) return null;
  const address = senderAddress(from[0].value);
  if (address === null || address === ownAddress.toLowerCase()) return null;
  const received = Number(message.internalDate);
  if (!Number.isFinite(received)) return null;
  const domain = senderDomain(address.slice(address.lastIndexOf("@") + 1));
  const [key, domainKey] = await Promise.all([senderKey(address), domain ? senderKey(domain, "domain") : null]);
  const row = port.exec("SELECT blocked_since FROM sender_policy WHERE sender IN (?,?) AND blocked=1 AND blocked_since<=? ORDER BY blocked_since LIMIT 1",
    key, domainKey, received)[0];
  return row ? { period: Number(row.blocked_since) } : null;
}
export async function blockedSender(port, message, ownAddress) {
  const labels = message.labelIds ?? [];
  return labels.includes("INBOX") && !labels.includes("SPAM") && await matchingSenderPolicy(port, message, ownAddress) !== null;
}
export function senderRuleWasApplied(port, id, period) {
  return Number(port.exec("SELECT period FROM sender_policy_applied WHERE id=?", id)[0]?.period) === period;
}
export function recordSenderRuleApplied(port, id, period) {
  port.exec("INSERT INTO sender_policy_applied(id,period) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET period=excluded.period WHERE sender_policy_applied.period<>excluded.period", id, period);
}
