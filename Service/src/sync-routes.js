// The data platform's routes (docs/design/DATA-PLATFORM.md §4, §7, §8): sync, blobs, the Health
// consent, export, and what devices report of their move off iCloud. The records live in the
// spaces (deps.spaces), the files in deps.blobs; D1 knows the spaces and who belongs to them.
//
// Never logged: record contents, blob hashes, space or device ids.

import { CATALOG } from "./catalog.js";
import { fromBase64, hmacHex } from "./crypto.js";

const DAY = 24 * 60 * 60 * 1000;
const ACTIVE = 30 * DAY;
const MOST_SYNC_BODY = 2 * 1024 * 1024;
const MOST_CHANGES = 500;
const MOST_BLOB = 100 * 1024 * 1024;   // the zone's request limit
const MOST_CONSENT_VERSIONS = 20;   // active consent versions logged per account
const SYNC_GAP = 3000;
const STALE_SLOT = 10_000;            // a trailing push not sent by then was lost with its isolate
const SYNC_PUSH = { aps: { "content-available": 1 }, b: { k: "sync" } };
const SHA = /^[0-9a-f]{64}$/;

/** Each account's own space. */
export const personalSpace = (account) => `sp_${account}`;
const blobKey = (space, sha) => `s/${space}/${sha}`;
const recent = (d, t) => Math.max(Number(d.updated_at ?? 0), Number(d.last_sync_at ?? 0)) >= t - ACTIVE;
const list = (json) => { try { const v = JSON.parse(json ?? "null"); return Array.isArray(v) ? v : []; } catch { return []; } };

/**
 * What /v1/account says of the move off iCloud (§3 seeding rule 2, §8.4):
 * - seeded: the types the account's iPhone has seeded (an iphone row active in the last 30 days),
 *   or null when there is none, and a spoke seeds on its own;
 * - flipped: every device row active in the last 30 days has stopped writing iCloud (the drain
 *   can stop); false with none;
 * - icloud: "purge" when the account's flag allows it and every device row active in the last 30
 *   days has its seed acknowledged and has stopped writing iCloud; else "keep".
 */
export async function syncSummary(deps, account) {
  const t = deps.now();
  const devices = (await deps.db.all(
    "SELECT platform, seeded_types, seeded_at, flipped_at, updated_at, last_sync_at FROM devices WHERE account_id = ?", account))
    .filter((d) => recent(d, t));
  const phones = devices.filter((d) => d.platform === "iphone");
  const flag = await deps.db.first("SELECT icloud_purge_ok FROM accounts WHERE id = ?", account);
  const flipped = devices.length > 0 && devices.every((d) => d.flipped_at != null);
  const purge = Number(flag?.icloud_purge_ok) === 1 && flipped && devices.every((d) => d.seeded_at != null);
  return {
    seeded: phones.length ? [...new Set(phones.flatMap((d) => list(d.seeded_types)))].sort() : null,
    flipped,
    icloud: purge ? "purge" : "keep",
  };
}

/**
 * Account deletion (§9): every space the account alone belongs to is wiped (its blobs go to the
 * trash afterwards, a batch at a time). Returns the D1 statements for the deletion's batch.
 */
export async function wipeSpaces(deps, account) {
  const alone = await deps.db.all(
    `SELECT m.space_id FROM space_members m WHERE m.account_id = ?
       AND NOT EXISTS (SELECT 1 FROM space_members o WHERE o.space_id = m.space_id AND o.account_id <> ?)`, account, account);
  for (const { space_id } of alone) await deps.spaces.get(space_id).wipe();
  return [
    { sql: "DELETE FROM space_members WHERE account_id = ?", params: [account] },
    { sql: "DELETE FROM spaces WHERE owner = ? AND id NOT IN (SELECT space_id FROM space_members)", params: [account] },
    // A space shared with others outlives its owner (none yet): another member takes it.
    { sql: "UPDATE spaces SET owner = (SELECT m.account_id FROM space_members m WHERE m.space_id = spaces.id ORDER BY m.created_at LIMIT 1) WHERE owner = ?", params: [account] },
    { sql: "DELETE FROM consents_log WHERE account_id = ?", params: [account] },
  ];
}

/**
 * @param {import("hono").Hono} app
 * @param {import("./app.js").Deps} deps
 * @param {{signedIn: Function, readJson: Function, TOO_LARGE: symbol, BAD: symbol,
 *          push: (account: string, push: {payload: object, collapseId: string, except?: string, label?: string}) => Promise<void>,
 *          onAccepted?: ((account: string, types: Set<string>) => void) | null}} shared
 */
export function syncRoutes(app, deps, { signedIn, readJson, TOO_LARGE, BAD, push, onAccepted = null }) {
  const { db, now, defer } = deps;

  /** The space a call names (default: the account's own, made on first use), or null when the
   * account isn't a member. */
  async function spaceFor(account, requested) {
    const own = personalSpace(account);
    const id = requested ?? own;
    if (typeof id !== "string") return null;
    if (await db.first("SELECT 1 AS x FROM space_members WHERE space_id = ? AND account_id = ?", id, account)) return id;
    if (id !== own) return null;
    const t = now();
    await db.batch([
      { sql: "INSERT INTO spaces (id, owner, kind, created_at) VALUES (?, ?, 'personal', ?) ON CONFLICT (id) DO NOTHING", params: [own, account, t] },
      { sql: "INSERT INTO space_members (space_id, account_id, role, created_at) VALUES (?, ?, 'owner', ?) ON CONFLICT (space_id, account_id) DO NOTHING",
        params: [own, account, t] },
    ]);
    return own;
  }
  const notMember = (c) => c.json({ error: "not_member" }, 403);
  const sleep = deps.sleep ?? ((ms) => new Promise((resolve) => setTimeout(resolve, ms)));

  // ---- the sync push: at most one every 3 s per account, and none lost ----
  // A change inside the 3 s after a push joins one trailing push, sent when the window ends: one
  // slot per account in D1 (sync_push_due_at), opened by the first such change, which waits for it
  // (waitUntil on Workers, well inside its 30 s). sync_push_from is the one device whose changes
  // it carries, kept out of the push, or "*" once changes from two devices joined (it goes to all).
  // A slot whose isolate died is stale after 10 s, and the next change opens a new one.
  async function syncPush(account, from, t) {
    const leading = await db.run(
      `UPDATE accounts SET last_sync_push_at = ? WHERE id = ? AND (last_sync_push_at IS NULL OR last_sync_push_at <= ?)
         AND (sync_push_due_at IS NULL OR sync_push_due_at < ?)`, t, account, t - SYNC_GAP, t - STALE_SLOT);
    if (leading.changes) return defer(push(account, { payload: SYNC_PUSH, collapseId: "sync", except: from, label: "push(sync)" })
      .catch((error) => console.log(`push(sync): failed (${error.name})`)));
    const row = await db.first("SELECT last_sync_push_at FROM accounts WHERE id = ?", account);
    const due = Math.max(Number(row?.last_sync_push_at ?? t) + SYNC_GAP, t);
    const opened = await db.run(
      "UPDATE accounts SET sync_push_due_at = ?, sync_push_from = ? WHERE id = ? AND (sync_push_due_at IS NULL OR sync_push_due_at < ?)",
      due, from, account, t - STALE_SLOT);
    if (!opened.changes) {
      await db.run("UPDATE accounts SET sync_push_from = '*' WHERE id = ? AND sync_push_from <> ?", account, from);
      return;
    }
    defer((async () => {
      await sleep(due - t);
      // The slot is this waiter's while its due time stands; a change that joins between the read
      // and the claim makes the claim miss, and the loop reads again.
      for (let tries = 0; tries < 5; tries++) {
        const slot = await db.first("SELECT sync_push_due_at, sync_push_from FROM accounts WHERE id = ?", account);
        if (Number(slot?.sync_push_due_at) !== due) return;
        const claimed = await db.run(
          `UPDATE accounts SET last_sync_push_at = ?, sync_push_due_at = NULL, sync_push_from = NULL
           WHERE id = ? AND sync_push_due_at = ? AND sync_push_from = ?`, now(), account, due, slot.sync_push_from);
        if (claimed.changes) {
          return push(account, { payload: SYNC_PUSH, collapseId: "sync", except: slot.sync_push_from === "*" ? null : slot.sync_push_from, label: "push(sync, trailing)" });
        }
      }
    })().catch((error) => console.log(`push(sync): failed (${error.name})`)));
  }

  // The change stream (§9): T1 with a keyed hash of the space, its day and the catalog's analytics
  // fields; T2 only what happened to which type. Never in the way of the answer.
  let analyticsKey;
  async function stream(space, accepted, at) {
    analyticsKey ??= deps.config.analyticsKey || await hmacHex(fromBase64(deps.config.tokenKey), "banana analytics v1");
    const hashed = await hmacHex(analyticsKey, space);
    await deps.changes.send(accepted.map((a) => (CATALOG.get(a.type)?.tier === "T2" ? { at, type: a.type, op: a.op } : { at, space: hashed, ...a })));
  }

  app.post("/v2/sync", signedIn, async (c) => {
    const body = await readJson(c, MOST_SYNC_BODY);
    if (body === TOO_LARGE) return c.json({ error: "too_large" }, 413);
    const changes = body?.changes ?? [];
    const since = body?.since ?? 0;
    if (body === BAD || typeof body?.device !== "string" || !Array.isArray(changes) || !Number.isInteger(since) || since < 0) {
      return c.json({ error: "bad_request" }, 400);
    }
    if (changes.length > MOST_CHANGES) return c.json({ error: "too_many_changes" }, 413);
    const account = c.get("account");
    // The device row, not the request, says what the device is (hub-only types).
    const device = await db.first("SELECT id, platform FROM devices WHERE id = ? AND account_id = ?", body.device, account);
    if (!device) return c.json({ error: "unknown_device" }, 404);
    const space = await spaceFor(account, body.space);
    if (!space) return notMember(c);
    const t = now();
    const { answer, accepted } = await deps.spaces.get(space).sync({ account, device: device.id, platform: device.platform, since, changes, now: t });
    await db.run("UPDATE devices SET last_sync_at = ? WHERE id = ?", t, device.id);
    if (accepted.length) {
      // The other devices fetch: at most one push every 3 s per account, never to the sender. All of
      // it after the answer.
      defer(syncPush(account, device.id, t).catch((error) => console.log(`push(sync): failed (${error.name})`)));
      if (deps.changes) defer(stream(space, accepted, t).catch((error) => console.log(`changes: failed (${error.name})`)));
      if (onAccepted && space === personalSpace(account)) onAccepted(account, new Set(accepted.map((a) => a.type)));
    }
    return c.json(answer);
  });

  // ---- blobs: content-addressed, never overwritten, streamed both ways ----

  // X-Banana-Type names the catalog type the blob is for (one with blobs): its tier goes in the
  // index, so a withdrawal finds every T2 blob, named by a record or not. T2 needs the consent.
  app.put("/v2/blobs/:sha", signedIn, async (c) => {
    const sha = c.req.param("sha");
    const type = c.req.header("x-banana-type");
    const entry = CATALOG.get(type);
    if (!SHA.test(sha) || !entry?.blobs) return c.json({ error: "bad_request" }, 400);
    const length = c.req.header("content-length");
    if (length === undefined || !/^\d+$/.test(length)) return c.json({ error: "length_required" }, 411);
    if (Number(length) > MOST_BLOB) return c.json({ error: "too_large" }, 413);
    const space = await spaceFor(c.get("account"), c.req.query("space"));
    if (!space) return notMember(c);
    const stub = deps.spaces.get(space);
    if (entry.tier === "T2" && !(await stub.consents()).health) {
      await c.req.raw.body?.cancel();
      return c.json({ error: "consent" }, 403);
    }
    const key = blobKey(space, sha);
    let size = (await deps.blobs.head(key))?.size;
    const fresh = size == null;
    if (fresh) {
      const ok = await deps.blobs.put(key, c.req.raw.body ?? new Blob([]).stream(), { sha256: sha });
      if (!ok) return c.json({ error: "sha_mismatch" }, 400);
      size = Number(length);
    } else {
      await c.req.raw.body?.cancel();
    }
    // Always, even when it was already there: a put whose index write was lost heals on the retry.
    // The space checks the consent again, in case it was withdrawn meanwhile.
    const indexed = await stub.recordBlob(sha, size, now(), type);
    if (!indexed.ok) {
      if (fresh) await deps.blobs.delete(key);
      return c.json({ error: "consent" }, 403);
    }
    // These bytes were on their way to the trash: if the file left meanwhile, it comes back.
    if (indexed.restore && !(await deps.blobs.head(key))) await deps.blobs.move(`trash/${space}/${sha}`, key);
    return c.body(null, 204);
  });

  // GET streams the blob; Hono answers HEAD with this route, and then only its size is read.
  app.get("/v2/blobs/:sha", signedIn, async (c) => {
    const sha = c.req.param("sha");
    if (!SHA.test(sha)) return c.json({ error: "bad_request" }, 400);
    const space = await spaceFor(c.get("account"), c.req.query("space"));
    if (!space) return notMember(c);
    const head = c.req.method === "HEAD";
    const found = head ? await deps.blobs.head(blobKey(space, sha)) : await deps.blobs.get(blobKey(space, sha));
    if (!found) return c.json({ error: "not_found" }, 404);
    return new Response(head ? null : found.body, { headers: {
      "content-type": "application/octet-stream", "content-length": String(found.size), "cache-control": "private, max-age=31536000, immutable" } });
  });

  // ---- the Health consent (§7): the space first, then the D1 log; both safe to retry ----

  app.put("/v2/consents/health", signedIn, async (c) => {
    const body = await readJson(c, 4096);
    const version = body?.version;
    const deviceId = body?.device ?? null;
    if (typeof version !== "string" || !/^[A-Za-z0-9._-]{1,64}$/.test(version) || (deviceId !== null && (typeof deviceId !== "string" || deviceId.length > 64))) {
      return c.json({ error: "bad_request" }, 400);
    }
    const account = c.get("account");
    // The log names the consent texts a person agreed to: a handful, not one row per made-up string.
    const active = await db.first("SELECT COUNT(*) AS n FROM consents_log WHERE account_id = ? AND kind = 'health' AND withdrawn_at IS NULL AND version <> ?", account, version);
    if (Number(active.n) >= MOST_CONSENT_VERSIONS) return c.json({ error: "too_many_versions" }, 409);
    const space = await spaceFor(account);
    const t = now();
    await deps.spaces.get(space).setConsent("health", { version, at: t, device: deviceId });
    await db.run(
      `INSERT INTO consents_log (account_id, kind, version, granted_at, withdrawn_at, device, via)
       SELECT ?, 'health', ?, ?, NULL, ?, 'app' WHERE NOT EXISTS
         (SELECT 1 FROM consents_log WHERE account_id = ? AND kind = 'health' AND version = ? AND withdrawn_at IS NULL)`,
      account, version, t, deviceId, account, version);
    return c.body(null, 204);
  });

  // Every T2 record and its history go at once; the blobs follow to the trash in batches.
  app.delete("/v2/consents/health", signedIn, async (c) => {
    const account = c.get("account");
    const space = await spaceFor(account);
    await deps.spaces.get(space).withdrawConsent("health");
    await db.run("UPDATE consents_log SET withdrawn_at = ? WHERE account_id = ? AND kind = 'health' AND withdrawn_at IS NULL", now(), account);
    return c.body(null, 204);
  });

  // ---- export (GDPR Art. 20): every record, its history, the blob list, as NDJSON, streamed ----

  app.get("/v2/export", signedIn, async (c) => {
    const space = await spaceFor(c.get("account"), c.req.query("space"));
    if (!space) return notMember(c);
    const response = await deps.spaces.get(space).export();
    return new Response(response.body, { headers: {
      "content-type": "application/x-ndjson", "content-disposition": 'attachment; filename="banana-export.ndjson"' } });
  });

  // ---- what a device reports of its move off iCloud (§8) ----

  app.put("/v2/devices/:id/sync-state", signedIn, async (c) => {
    const body = await readJson(c, 65_536);
    const when = (v) => (v === undefined ? undefined : v === null ? null : Number.isInteger(v) && v > 0 && v <= now() + DAY ? v : false);
    const seededAt = when(body?.seededAt);
    const flippedAt = when(body?.flippedAt);
    const seeded = body?.seeded;
    if (!body || typeof body !== "object" || seededAt === false || flippedAt === false
        || (seeded !== undefined && (!Array.isArray(seeded) || seeded.length > 200 || !seeded.every((t) => CATALOG.has(t))))) {
      return c.json({ error: "bad_request" }, 400);
    }
    const sets = [], params = [];
    if (seededAt !== undefined) { sets.push("seeded_at = ?"); params.push(seededAt); }
    if (flippedAt !== undefined) { sets.push("flipped_at = ?"); params.push(flippedAt); }
    if (seeded !== undefined) { sets.push("seeded_types = ?"); params.push(JSON.stringify([...new Set(seeded)].sort())); }
    const changed = await db.run(`UPDATE devices SET ${sets.length ? sets.join(", ") : "id = id"} WHERE id = ? AND account_id = ?`,
      ...params, c.req.param("id"), c.get("account"));
    return changed.changes ? c.body(null, 204) : c.json({ error: "unknown_device" }, 404);
  });
}
