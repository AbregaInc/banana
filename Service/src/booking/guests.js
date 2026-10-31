// Guests are accounts (docs/design/BOOKING.md §12 "Guests are accounts"). A browser that booked is
// remembered by a __Host- cookie (a guest session, stored hashed): its form is filled with what it
// typed, nothing more. A guest who proved their email (Google, or a 6-digit code) is verified: their
// upcoming times, Forget me, and their free/busy. The API never takes a guest session.
//
// Never logged: emails, names, phone numbers, codes, tokens.

import { getCookie, setCookie, deleteCookie } from "hono/cookie";
import { constantTimeEqual, newId, newSessionToken, sha256Hex } from "../crypto.js";

export const COOKIE = "__Host-bk";
export const CONNECT_COOKIE = "__Host-bkc";
const YEAR = 365 * 24 * 60 * 60 * 1000;
const DAY = 24 * 60 * 60 * 1000;
const CODE_TTL = 10 * 60 * 1000;
const CODE_WINDOW = 15 * 60 * 1000;
const CODES_PER_WINDOW = 3;
const CODE_TRIES = 5;

const cookieOptions = { path: "/", secure: true, httpOnly: true, sameSite: "Lax" };

/** The guest session the browser carries, or null: {hash, accountId, profile, verifiedAt, guest}. */
export async function guestOf(deps, c) {
  const token = getCookie(c, COOKIE);
  if (!token || !/^[A-Za-z0-9_-]{20,200}$/.test(token)) return null;
  const hash = await sha256Hex(token);
  const row = await deps.db.first(
    `SELECT s.account_id, s.profile, s.verified_at, s.last_used_at, g.email, g.name, g.phone, g.zone, g.person_account_id, g.verified_at AS guest_verified_at
     FROM sessions s LEFT JOIN guests g ON g.account_id = s.account_id WHERE s.token_hash = ? AND s.kind = 'guest'`, hash);
  if (!row) return null;
  const t = deps.now();
  if (t - Number(row.last_used_at) >= DAY) {
    deps.defer(deps.db.batch([
      { sql: "UPDATE sessions SET last_used_at = ? WHERE token_hash = ?", params: [t, hash] },
      { sql: "UPDATE guests SET last_seen_at = ? WHERE account_id = ?", params: [t, row.account_id] },
    ]));
  }
  let profile = {};
  try { profile = JSON.parse(row.profile ?? "{}") ?? {}; } catch { /* none */ }
  return {
    hash, accountId: row.account_id, profile, verifiedAt: row.verified_at == null ? null : Number(row.verified_at),
    guest: row.email ? { email: row.email, name: row.name, phone: row.phone, zone: row.zone, personAccountId: row.person_account_id } : null,
  };
}

/** The guest account for an email, made when there is none. Returns its account id. */
export async function guestAccount(deps, email, { name = null, phone = null, zone = null, verified = false, update = true } = {}) {
  const { db, now } = deps;
  const t = now();
  const existing = await db.first("SELECT account_id, verified_at FROM guests WHERE email = ?", email);
  if (existing && !update && !verified) {
    await db.run("UPDATE guests SET last_seen_at = ? WHERE account_id = ?", t, existing.account_id);
    return existing.account_id;
  }
  if (existing) {
    if (existing.verified_at == null && verified) {
      // The first proof of the email: whatever a browser typed before (anyone can type an address)
      // is dropped, the proven owner's own details take its place.
      await db.run("UPDATE guests SET last_seen_at = ?, verified_at = ?, name = ?, phone = ?, zone = ? WHERE account_id = ?",
        t, t, name, phone, zone, existing.account_id);
    } else if (existing.verified_at != null && !verified) {
      // A verified guest's details (name, phone, zone) change only from a verified browser.
      await db.run("UPDATE guests SET last_seen_at = ? WHERE account_id = ?", t, existing.account_id);
    } else {
      await db.run(
        `UPDATE guests SET last_seen_at = ?, name = COALESCE(?, name), phone = COALESCE(?, phone), zone = COALESCE(?, zone) WHERE account_id = ?`,
        t, name, phone, zone, existing.account_id);
    }
    return existing.account_id;
  }
  const id = newId(deps.random);
  const person = await db.first("SELECT account_id FROM google_links WHERE email = ? AND status <> 'unlinked' ORDER BY created_at LIMIT 1", email);
  await db.batch([
    { sql: "INSERT INTO accounts (id, created_at, kind) VALUES (?, ?, 'guest')", params: [id, t] },
    { sql: `INSERT INTO guests (account_id, email, name, phone, zone, person_account_id, verified_at, last_seen_at, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`, params: [id, email, name, phone, zone, verified ? person?.account_id ?? null : null, verified ? t : null, t, t] },
  ]);
  return id;
}

/** A new guest session for the browser, replacing the one it had. */
export async function startSession(deps, c, accountId, { profile, verified }) {
  const t = deps.now();
  const old = getCookie(c, COOKIE);
  const token = newSessionToken(deps.random);
  const statements = [{
    sql: "INSERT INTO sessions (token_hash, account_id, created_at, last_used_at, kind, profile, verified_at) VALUES (?, ?, ?, ?, 'guest', ?, ?)",
    params: [await sha256Hex(token), accountId, t, t, JSON.stringify(profile ?? {}), verified ? t : null],
  }];
  if (old && /^[A-Za-z0-9_-]{20,200}$/.test(old)) statements.push({ sql: "DELETE FROM sessions WHERE token_hash = ? AND kind = 'guest'", params: [await sha256Hex(old)] });
  await deps.db.batch(statements);
  setCookie(c, COOKIE, token, { ...cookieOptions, maxAge: YEAR / 1000 });
  return await sha256Hex(token);
}

/** What this browser typed, kept on its session (the next form is filled with it). */
export const rememberProfile = (deps, hash, profile) =>
  deps.db.run("UPDATE sessions SET profile = ?, last_used_at = ? WHERE token_hash = ? AND kind = 'guest'", JSON.stringify(profile), deps.now(), hash);

export const endSession = (c) => deleteCookie(c, COOKIE, cookieOptions);

/**
 * The guest as the pages show it (CONTRACT.md): remembered shows what this browser typed;
 * verified shows the guest's own details and their upcoming times.
 */
export async function guestView(deps, session, { upcoming = [] } = {}) {
  if (!session) return { state: "none", name: null, email: null, phone: null, zone: null, upcoming: [] };
  if (session.verifiedAt && session.guest) {
    return { state: "verified", name: session.guest.name ?? session.profile.name ?? null, email: session.guest.email,
      phone: session.guest.phone ?? session.profile.phone ?? null, zone: session.guest.zone ?? null, upcoming };
  }
  return { state: "remembered", name: session.profile.name ?? null, email: session.profile.email ?? null,
    phone: session.profile.phone ?? null, zone: session.profile.zone ?? null, upcoming: [] };
}

// ---- the 6-digit code ----

/** Makes and stores a code for the email, or null when too many were sent lately. */
export async function newCode(deps, signer, email) {
  const { db, now } = deps;
  const t = now();
  const row = await db.first("SELECT sent, window_at FROM email_codes WHERE email = ?", email);
  const inWindow = row && t - Number(row.window_at) < CODE_WINDOW;
  if (inWindow && Number(row.sent) >= CODES_PER_WINDOW) return null;
  const n = new DataView(deps.random(4).buffer).getUint32(0) % 1_000_000;
  const code = String(n).padStart(6, "0");
  await db.run(
    `INSERT INTO email_codes (email, code_hash, expires_at, attempts, sent, window_at) VALUES (?, ?, ?, 0, 1, ?)
     ON CONFLICT (email) DO UPDATE SET code_hash = excluded.code_hash, expires_at = excluded.expires_at, attempts = 0,
       sent = ?, window_at = ?`,
    email, await signer.code(email, code), t + CODE_TTL, t, inWindow ? Number(row.sent) + 1 : 1, inWindow ? Number(row.window_at) : t);
  return code;
}

/** Whether the code is the email's: single use, ten minutes, five tries. */
export async function checkCode(deps, signer, email, code) {
  const { db, now } = deps;
  if (!/^\d{6}$/.test(String(code ?? ""))) return false;
  const t = now();
  // A try is spent first, and only while tries remain: guesses sent together cannot share the five.
  const spent = await db.run("UPDATE email_codes SET attempts = attempts + 1 WHERE email = ? AND expires_at > ? AND attempts < ?", email, t, CODE_TRIES);
  if (!spent.changes) return false;
  const row = await db.first("SELECT code_hash FROM email_codes WHERE email = ?", email);
  if (!row || !constantTimeEqual(await signer.code(email, code), row.code_hash)) return false;
  // Single use, also when two right guesses race: only the one that ends the code wins.
  const used = await db.run("UPDATE email_codes SET expires_at = 0 WHERE email = ? AND expires_at > ?", email, t);
  return used.changes > 0;
}

/**
 * Forget me: the grant revoked at Google, the booking rows anonymised until their events end (their
 * reminders stop), and the guest account gone with its sessions. The hosts' calendars keep their
 * events.
 */
export async function forgetGuest(deps, vault, accountId) {
  const { db } = deps;
  const grants = await db.all("SELECT sub, refresh_token FROM guest_grants WHERE account_id = ?", accountId);
  for (const g of grants) {
    if (!g.refresh_token) continue;
    try { await deps.google.revoke(await vault.open(`guest:${g.sub}`, g.refresh_token)); } catch { /* gone already */ }
  }
  const guest = await db.first("SELECT email FROM guests WHERE account_id = ?", accountId);
  await db.batch([
    { sql: `UPDATE bookings SET guest_name = NULL, guest_email = NULL, guest_phone = NULL, note = NULL, guest_account_id = NULL,
              idem_key = NULL, reminded_24 = 2, reminded_1 = 2, updated_at = ? WHERE guest_account_id = ?`, params: [deps.now(), accountId] },
    ...(guest ? [{ sql: "DELETE FROM email_codes WHERE email = ?", params: [guest.email] }] : []),
    { sql: "DELETE FROM guest_grants WHERE account_id = ?", params: [accountId] },
    { sql: "DELETE FROM sessions WHERE account_id = ? AND kind IN ('guest', 'web', 'web-handoff')", params: [accountId] },
    { sql: "DELETE FROM guests WHERE account_id = ?", params: [accountId] },
    { sql: "DELETE FROM accounts WHERE id = ? AND kind = 'guest'", params: [accountId] },
  ]);
}
