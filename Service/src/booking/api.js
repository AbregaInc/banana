// The host's booking API, on the API host (Bearer session, person accounts only):
//   GET /v1/booking            {handle, link, suggested, name, timeZone, types}
//   PUT /v1/booking            {handle, name?, timeZone?} → {handle, link}; 400 {error: invalid|reserved|zone}, 409 {error: taken}
//   GET /v1/booking/upcoming   {bookings: [...]}, for an in-app list
// A changed handle's old links 404 (BOOKING.md §12 cut the 90-day redirect).

import { canonicalZone } from "./slots.js";
import { handleIdeas, handleProblem, typesFrom } from "./types.js";
import { rebuildSnapshot } from "./busy.js";

/** @param {import("hono").Hono} app */
export function bookingApi(app, deps, { signedIn, readJson, vault }) {
  const { db, now } = deps;
  const link = (handle) => (handle ? `${deps.config.bookUrl}/${handle}` : null);

  async function suggestions(account) {
    const row = await db.first(
      "SELECT a.display_name, g.name, g.email FROM accounts a LEFT JOIN google_links g ON g.account_id = a.id AND g.status <> 'unlinked' WHERE a.id = ? ORDER BY g.created_at LIMIT 1", account);
    const ideas = handleIdeas(row?.display_name || row?.name, row?.email);
    const taken = ideas.length ? new Set((await db.all(`SELECT handle FROM booking_handles WHERE handle IN (${ideas.map(() => "?").join(", ")})`, ...ideas)).map((r) => r.handle)) : new Set();
    const free = ideas.filter((h) => !taken.has(h));
    if (!free.length && ideas.length) for (let n = 2; n < 10 && free.length < 1; n++) {
      const h = `${ideas[0].slice(0, 27)}-${n}`;
      if (!(await db.first("SELECT 1 AS x FROM booking_handles WHERE handle = ?", h))) free.push(h);
    }
    return { name: row?.display_name || row?.name || null, suggested: free.slice(0, 3) };
  }

  app.get("/v1/booking", signedIn, async (c) => {
    const account = c.get("account");
    const [row, snapshot] = await Promise.all([
      db.first("SELECT h.handle, h.time_zone, a.time_zone AS account_zone FROM accounts a LEFT JOIN booking_handles h ON h.account_id = a.id WHERE a.id = ?", account),
      db.first("SELECT types_json FROM busy_snapshot WHERE account_id = ?", account),
    ]);
    const { name, suggested } = await suggestions(account);
    let records = [];
    try { records = JSON.parse(snapshot?.types_json ?? "[]") ?? []; } catch { records = []; }
    const zone = row?.time_zone ?? row?.account_zone ?? null;
    const types = row?.handle ? typesFrom(records, zone).map((t) => ({ slug: t.slug, title: t.title, active: t.active, link: `${link(row.handle)}/${t.slug}` })) : [];
    return c.json({ handle: row?.handle ?? null, link: link(row?.handle), suggested: row?.handle ? [] : suggested, name, timeZone: zone, types });
  });

  app.put("/v1/booking", signedIn, async (c) => {
    const body = await readJson(c, 4096);
    const account = c.get("account");
    const handle = typeof body?.handle === "string" ? body.handle.trim().toLowerCase() : null;
    const problem = handleProblem(handle);
    if (problem) return c.json({ error: problem }, 400);
    const name = typeof body?.name === "string" ? body.name.replace(/[\u0000-\u001f\u007f]/g, "").trim().slice(0, 80) || null : null;
    const zone = body?.timeZone == null ? null : canonicalZone(body.timeZone);
    if (body?.timeZone != null && !zone) return c.json({ error: "zone" }, 400);
    const t = now();
    const current = await db.first("SELECT h.handle, h.time_zone, a.time_zone AS account_zone FROM accounts a LEFT JOIN booking_handles h ON h.account_id = a.id WHERE a.id = ?", account);
    // The default type's zone is fixed when the handle is made: the app's, else the account's.
    const handleZone = current?.time_zone ?? zone ?? canonicalZone(current?.account_zone);
    // The write is the check: a handle another account holds (or takes in the same moment) changes
    // nothing here, and the loser hears 409.
    let changed;
    try {
      changed = current?.handle && current.handle !== handle
        ? await db.run("UPDATE booking_handles SET handle = ?, updated_at = ? WHERE account_id = ?", handle, t, account)
        : await db.run(
          `INSERT INTO booking_handles (handle, account_id, time_zone, created_at, updated_at) VALUES (?, ?, ?, ?, ?)
           ON CONFLICT (handle) DO UPDATE SET updated_at = excluded.updated_at WHERE booking_handles.account_id = excluded.account_id`,
          handle, account, handleZone, t, t);
    } catch {
      changed = { changes: 0 };   // the handle is another account's (its primary key)
    }
    if (!changed.changes) return c.json({ error: "taken" }, 409);
    const extra = [
      ...(name ? [{ sql: "UPDATE accounts SET display_name = ? WHERE id = ?", params: [name, account] }] : []),
      ...(zone ? [{ sql: "UPDATE accounts SET time_zone = COALESCE(time_zone, ?) WHERE id = ?", params: [zone, account] }] : []),
    ];
    if (extra.length) await db.batch(extra);
    if (!current?.handle) deps.defer(rebuildSnapshot(deps, account, { vault }).catch((error) => console.log(`booking: snapshot failed (${error.name})`)));
    return c.json({ handle, link: link(handle) });
  });

  app.get("/v1/booking/upcoming", signedIn, async (c) => {
    const rows = await db.all(
      `SELECT manage_id, type_title, start_at, end_at, status, invite, guest_name, guest_email, place_kind, place_detail, guest_phone FROM bookings
       WHERE account_id = ? AND status IN ('pending', 'confirmed') AND end_at > ? ORDER BY start_at LIMIT 100`, c.get("account"), now());
    return c.json({ bookings: rows.map((r) => ({
      id: r.manage_id, title: r.type_title, start: new Date(Number(r.start_at)).toISOString(), end: new Date(Number(r.end_at)).toISOString(),
      status: r.status, invited: r.invite === "sent", guest: { name: r.guest_name, email: r.guest_email, phone: r.guest_phone ?? null },
      place: r.place_kind ? { kind: r.place_kind, detail: r.place_detail ?? null } : null,
    })) });
  });
}

/** Statements for DELETE /v1/account: everything booking holds about a host (before the account row). */
export const forgetHost = (account) => [
  { sql: "DELETE FROM bookings WHERE account_id = ?", params: [account] },
  { sql: "DELETE FROM busy_snapshot WHERE account_id = ?", params: [account] },
  { sql: "DELETE FROM booking_handles WHERE account_id = ?", params: [account] },
  { sql: "UPDATE guests SET person_account_id = NULL WHERE person_account_id = ?", params: [account] },
];
