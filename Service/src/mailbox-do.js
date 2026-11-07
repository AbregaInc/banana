// The shared cloud mailbox on Workers: one Durable Object with SQLite storage per Google identity,
// named by its sub (docs/design/MAIL-CLOUD-SYNC.md). src/mailbox.js does the work; the object's
// alarm is the ingestion worker. Content goes to R2 sealed; it never crosses RPC (the Worker reads
// R2 itself), so no message is held to the 32 MiB RPC limit.

import { DurableObject } from "cloudflare:workers";
import { createMailbox } from "./mailbox.js";
import { configFrom } from "./config.js";
import { createGoogle } from "./google.js";
import { createVault } from "./crypto.js";
import { d1 } from "./adapters/d1.js";
import { r2Blobs } from "./adapters/r2.js";

export class Mailbox extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    const config = configFrom(env);
    const random = (n) => crypto.getRandomValues(new Uint8Array(n));
    const deps = {
      config, db: d1(env.DB), google: createGoogle(config, (...args) => fetch(...args)),
      now: Date.now, random, sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
    };
    this.mailbox = createMailbox({
      port: {
        exec: (sql, ...args) => ctx.storage.sql.exec(sql, ...args).toArray(),
        transaction: (fn) => ctx.storage.transactionSync(fn),
      },
      deps, vault: createVault(config.tokenKey, random), blobs: r2Blobs(env.BLOBS),
      alarm: {
        set: async (at) => {
          const current = await ctx.storage.getAlarm();
          if (current === null || current > at) await ctx.storage.setAlarm(at);
        },
      },
      destroy: async () => { await ctx.storage.deleteAlarm(); await ctx.storage.deleteAll(); },
    });
  }

  ensure(who) { return this.mailbox.ensure(who); }
  feed(request) { return this.mailbox.feed(request); }
  check(ids) { return this.mailbox.check(ids); }
  noteAction(ids) { return this.mailbox.noteAction(ids); }
  poke() { return this.mailbox.poke(); }
  profile() { return this.mailbox.profile(); }
  content(request) { return this.mailbox.content(request); }
  lost(id) { return this.mailbox.lost(id); }
  status() { return this.mailbox.status(); }
  wipe() { return this.mailbox.wipe(); }
  arm() { return this.mailbox.arm(); }
  async alarm() { await this.mailbox.run(); }
}

/** deps.mailboxes on Workers: a Google sub names its mailbox (idFromName). */
export function doMailboxes(namespace) {
  return {
    get(sub) {
      const stub = namespace.get(namespace.idFromName(`mail:${sub}`));
      return {
        ensure: (who) => stub.ensure(who), feed: (request) => stub.feed(request), check: (ids) => stub.check(ids),
        noteAction: (ids) => stub.noteAction(ids), poke: () => stub.poke(), profile: () => stub.profile(),
        content: (request) => stub.content(request), lost: (id) => stub.lost(id), status: () => stub.status(),
        wipe: () => stub.wipe(), arm: () => stub.arm(),
      };
    },
  };
}
