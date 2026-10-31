// Moving a space's blobs to the R2 trash (`trash/<space>/<sha>`, gone after 30 days by a lifecycle
// rule), a batch at a time: one request can't make thousands of R2 calls (DATA-PLATFORM.md §7, §9).
// The Durable Object runs a step per alarm; on Node a loop does (src/adapters/spaces-sqlite.js).

import { stillTrashed, takeTrash, trashList, untakeTrash } from "./space.js";

export const TRASH_BATCH = 200;
const DAY = 24 * 60 * 60 * 1000;
const NEXT_BATCH = 1000;
const RETRY_FIRST = 60 * 1000;
const RETRY_MOST = 60 * 60 * 1000;

/**
 * One batch. A withdrawal's list: the shas it left behind, each taken off the list before it moves
 * and moved back if an upload of the same bytes took it back meanwhile. A wipe: everything still
 * under `s/<space>/`, listed from storage, so a blob put but never indexed goes too.
 * @returns {Promise<{moved: number, more: boolean, wiped: boolean, wipingSince: number|null}>}
 *   wiped: the wipe is done and the space's storage itself can go.
 */
export async function trashBatch(port, blobs, limit = TRASH_BATCH) {
  const { space, wiping, shas } = trashList(port, limit);
  if (!space) return { moved: 0, more: false, wiped: false, wipingSince: null };
  if (wiping !== null) {
    const keys = await blobs.list(`s/${space}/`, limit);
    for (const key of keys) await blobs.move(key, `trash/${key.slice(2)}`);
    return { moved: keys.length, more: keys.length > 0, wiped: keys.length === 0, wipingSince: wiping };
  }
  let moved = 0;
  for (const sha of shas) {
    if (!takeTrash(port, sha)) continue;
    try { await blobs.move(`s/${space}/${sha}`, `trash/${space}/${sha}`); }
    catch (error) { untakeTrash(port, sha); throw error; }
    moved++;
    if (!stillTrashed(port, sha)) await blobs.move(`trash/${space}/${sha}`, `s/${space}/${sha}`);
  }
  return { moved, more: shas.length === limit, wiped: false, wipingSince: null };
}

const failures = new WeakMap();   // per space, as long as it stays in memory

/**
 * One alarm's work: a batch, then when to come back (null: done). A failure is logged and tried
 * again later, 1 min, 2, 4 … up to an hour apart. A wipe still going after a day is logged loudly.
 * @returns {Promise<{next: number|null, wiped: boolean}>}
 */
export async function trashStep(port, blobs, { now, limit = TRASH_BATCH, log = console.log }) {
  try {
    const r = await trashBatch(port, blobs, limit);
    failures.delete(port);
    if (r.wipingSince !== null && now - r.wipingSince > DAY) {
      log(`trash: ALERT a space wipe started ${Math.round((now - r.wipingSince) / DAY)} day(s) ago is still moving blobs`);
    }
    return { next: r.more ? now + NEXT_BATCH : null, wiped: r.wiped };
  } catch (error) {
    const n = (failures.get(port) ?? 0) + 1;
    failures.set(port, n);
    log(`trash: batch failed (${error.name}), try ${n}`);
    return { next: now + Math.min(RETRY_FIRST * 2 ** (n - 1), RETRY_MOST), wiped: false };
  }
}
