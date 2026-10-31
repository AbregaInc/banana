// deps.spaces on Node: one node:sqlite file per space in a directory, running src/space.js, with
// the same calls as the Durable Object (src/space-do.js). Calls are synchronous underneath, so a
// sync is one transaction and nothing interleaves. Blob moves to the trash run in a loop after the
// call that made them, a batch at a time, as the object's alarm does on Workers.

import { DatabaseSync } from "node:sqlite";
import { mkdirSync, readdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import * as space from "../space.js";
import { TRASH_BATCH, trashStep } from "../trash.js";

const ID = /^[A-Za-z0-9_-]{1,100}$/;

/** A port over one node:sqlite database: {exec, transaction}. */
export function sqlitePort(db) {
  let depth = 0;
  return {
    exec: (sql, ...args) => db.prepare(sql).all(...args).map((r) => ({ ...r })),
    transaction(fn) {
      if (depth) return fn();
      db.exec("BEGIN IMMEDIATE");
      depth++;
      try {
        const result = fn();
        db.exec("COMMIT");
        return result;
      } catch (error) {
        db.exec("ROLLBACK");
        throw error;
      } finally {
        depth--;
      }
    },
  };
}

/**
 * @param {string} dir where the space files live
 * @param {{blobs: ReturnType<typeof import("./blobs-fs.js").fsBlobs>}} options
 */
export function spacesSqlite(dir, { blobs, batch = TRASH_BATCH, now = Date.now, log = console.log }) {
  mkdirSync(dir, { recursive: true });
  const open = new Map();     // id → {db, port}
  const running = new Map();  // id → the trash loop's promise

  function get(id) {
    if (!ID.test(id)) throw new Error("bad space id");
    let s = open.get(id);
    if (!s) {
      const db = new DatabaseSync(join(dir, `${id}.sqlite`));
      db.exec("PRAGMA journal_mode = WAL");
      s = { db, port: sqlitePort(db) };
      open.set(id, s);
    }
    return s;
  }

  const again = new Set();    // more work arrived while the loop ran
  function drain(id) {
    if (running.has(id)) { again.add(id); return running.get(id); }
    const work = (async () => {
      for (;;) {
        again.delete(id);
        const s = open.get(id);
        if (!s) return;
        const step = await trashStep(s.port, blobs, { now: now(), limit: batch, log });
        if (step.wiped) {
          s.db.close();
          open.delete(id);
          for (const suffix of ["", "-wal", "-shm"]) rmSync(join(dir, `${id}.sqlite${suffix}`), { force: true });
          return;
        }
        if (step.next === null && !again.has(id)) return;
        // A failure waits as the alarm would, out of the loop (a timer that doesn't hold the process).
        if (step.next !== null && step.next - now() > 5000) { setTimeout(() => drain(id), step.next - now()).unref(); return; }
      }
    })().catch((error) => log(`trash: failed (${error.name})`)).finally(() => running.delete(id));
    running.set(id, work);
    return work;
  }

  return {
    get(id) {
      const port = () => get(id).port;
      return {
        async sync(request) {
          const result = space.sync(port(), { ...request, space: id });
          if (result.trashed) drain(id);
          return result;
        },
        async recordBlob(sha, size, at, type) { return space.recordBlob(port(), sha, size, at, type); },
        async consents() { return space.consents(port()); },
        async setConsent(kind, consent) { space.setConsent(port(), kind, consent); },
        async withdrawConsent(kind) {
          const result = space.withdrawConsent(port(), kind, { space: id });
          if (space.trashPending(port())) drain(id);
          return result;
        },
        async counts() { return space.counts(port()); },
        async setCalendarPreference(request) { return space.setCalendarPreference(port(), request); },
        async read(type, recordId) { return space.read(port(), type, recordId); },
        async list(type) { return space.list(port(), type); },
        async browse(type, after) { return space.browse(port(), type, after); },
        async webBlob(type, recordId, field) { return space.webBlob(port(), type, recordId, field); },
        async wipe() { space.wipe(port(), { space: id, now: now() }); drain(id); },
        async export() { return space.exportResponse(port()); },
      };
    },
    /** Picks up moves a stopped process left half done (at start). */
    resume() {
      for (const name of readdirSync(dir)) if (name.endsWith(".sqlite")) { get(name.slice(0, -7)); drain(name.slice(0, -7)); }
    },
    /** Waits for every trash loop (tests, shutdown). */
    async idle() { while (running.size) await Promise.all(running.values()); },
    close() { for (const s of open.values()) s.db.close(); open.clear(); },
  };
}
