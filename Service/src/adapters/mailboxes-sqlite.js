// deps.mailboxes on Node: one node:sqlite file per Google identity, running src/mailbox.js with the
// same calls as the Durable Object (src/mailbox-do.js). The alarm is a timer on a server; tests
// pass `timers: false` and run the alarms themselves (`due()`).

import { DatabaseSync } from "node:sqlite";
import { mkdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { createMailbox } from "../mailbox.js";
import { createVault, sha256Hex } from "../crypto.js";
import { sqlitePort } from "./spaces-sqlite.js";

/**
 * @param {string} dir
 * @param {{deps: object, blobs: object, timers?: boolean}} options `deps` is read at each call, so
 *   a test may replace its ports (google, sleep) after this is made.
 */
export function mailboxesSqlite(dir, { deps, blobs, timers = true }) {
  mkdirSync(dir, { recursive: true });
  const open = new Map();   // sub → {db, mailbox, wake, timer}
  const vault = () => createVault(deps.config.tokenKey, deps.random);

  async function get(sub) {
    let entry = open.get(sub);
    if (entry) return entry;
    const file = join(dir, `${await sha256Hex(sub)}.sqlite`);
    const db = new DatabaseSync(file);
    db.exec("PRAGMA journal_mode = WAL");
    entry = { db, wake: null, timer: null, file };
    entry.mailbox = createMailbox({
      port: sqlitePort(db), deps: new Proxy({}, { get: (_, key) => deps[key] }), vault: vault(), blobs,
      alarm: {
        set(at) {
          if (entry.wake !== null && entry.wake <= at) return;
          entry.wake = at;
          if (!timers) return;
          clearTimeout(entry.timer);
          entry.timer = setTimeout(() => fire(sub), Math.max(0, at - deps.now()));
          entry.timer.unref?.();
        },
      },
      destroy() {
        clearTimeout(entry.timer);
        entry.db.close();
        open.delete(sub);
        for (const suffix of ["", "-wal", "-shm"]) rmSync(`${file}${suffix}`, { force: true });
      },
    });
    open.set(sub, entry);
    return entry;
  }

  async function fire(sub) {
    const entry = await get(sub);
    entry.wake = null;
    await entry.mailbox.run();
  }

  const call = (sub, name) => async (...args) => (await get(sub)).mailbox[name](...args);
  return {
    get(sub) {
      return Object.fromEntries(["ensure", "senderPolicy", "feed", "check", "noteAction", "noteLabel", "poke", "profile", "content", "contents", "wake", "watch", "stopWatch", "lost", "status", "wipe", "arm"]
        .map((name) => [name, call(sub, name)]));
    },
    /** Runs every alarm that is due now, until none is (tests; `limit` bounds a runaway). */
    async due({ limit = 200 } = {}) {
      let ran = 0;
      for (;;) {
        const ready = [...open.entries()].filter(([, e]) => e.wake !== null && e.wake <= deps.now());
        if (!ready.length || ran >= limit) return ran;
        for (const [sub] of ready) { await fire(sub); ran++; }
      }
    },
    /** When each open mailbox's alarm is set for (tests). */
    wakes() { return Object.fromEntries([...open.entries()].map(([sub, e]) => [sub, e.wake])); },
    close() { for (const e of open.values()) { clearTimeout(e.timer); e.db.close(); } open.clear(); },
  };
}
