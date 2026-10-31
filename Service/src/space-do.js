// A space on Workers: one Durable Object with SQLite storage per space, running src/space.js over
// ctx.storage.sql (DATA-PLATFORM.md §2). Small calls go over RPC; the export streams through fetch()
// as a Response, never as an RPC return value (32 MiB limit). Blob moves to the trash run on the
// object's alarm, a batch at a time.

import { DurableObject } from "cloudflare:workers";
import * as space from "./space.js";
import { trashStep } from "./trash.js";
import { r2Blobs } from "./adapters/r2.js";

export class Space extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    // sql.exec gives a cursor; BEGIN/COMMIT aren't allowed, transactionSync is the transaction.
    this.port = {
      exec: (sql, ...args) => ctx.storage.sql.exec(sql, ...args).toArray(),
      transaction: (fn) => ctx.storage.transactionSync(fn),
    };
  }

  async sync(request) {
    const result = space.sync(this.port, request);
    if (result.trashed) await this.arm();
    return result;
  }
  recordBlob(sha, size, at, type) { return space.recordBlob(this.port, sha, size, at, type); }
  consents() { return space.consents(this.port); }
  setConsent(kind, consent) { space.setConsent(this.port, kind, consent); }
  counts() { return space.counts(this.port); }
  setCalendarPreference(request) { return space.setCalendarPreference(this.port, request); }
  read(type, id) { return space.read(this.port, type, id); }
  list(type) { return space.list(this.port, type); }
  browse(type, after) { return space.browse(this.port, type, after); }
  webBlob(type, id, field) { return space.webBlob(this.port, type, id, field); }

  async withdrawConsent(kind, spaceId) {
    const result = space.withdrawConsent(this.port, kind, { space: spaceId });
    await this.arm();
    return result;
  }

  async wipe(spaceId) {
    space.wipe(this.port, { space: spaceId, now: Date.now() });
    await this.arm();
  }

  /** The alarm runs whenever there's trash to move or a wipe to finish. */
  async arm() {
    if (space.trashPending(this.port) && (await this.ctx.storage.getAlarm()) === null) await this.ctx.storage.setAlarm(Date.now());
  }

  // A batch per alarm. Failures are caught in trashStep and come back later with backoff.
  async alarm() {
    const step = await trashStep(this.port, r2Blobs(this.env.BLOBS), { now: Date.now() });
    if (step.wiped) {
      await this.ctx.storage.deleteAll();
      space.reset(this.port);
    } else if (step.next !== null) {
      await this.ctx.storage.setAlarm(step.next);
    }
  }

  async fetch(request) {
    if (new URL(request.url).pathname === "/export") return space.exportResponse(this.port);
    return new Response(null, { status: 404 });
  }
}

/** deps.spaces on Workers: a space id names its object (idFromName). */
export function doSpaces(namespace) {
  return {
    get(id) {
      const stub = namespace.get(namespace.idFromName(id));
      return {
        sync: (request) => stub.sync({ ...request, space: id }),
        recordBlob: (sha, size, at, type) => stub.recordBlob(sha, size, at, type),
        consents: () => stub.consents(),
        setConsent: (kind, consent) => stub.setConsent(kind, consent),
        withdrawConsent: (kind) => stub.withdrawConsent(kind, id),
        counts: () => stub.counts(),
        setCalendarPreference: (request) => stub.setCalendarPreference(request),
        read: (type, recordId) => stub.read(type, recordId),
        list: (type) => stub.list(type),
        browse: (type, after) => stub.browse(type, after),
        webBlob: (type, recordId, field) => stub.webBlob(type, recordId, field),
        wipe: () => stub.wipe(id),
        export: () => stub.fetch("https://space/export"),
      };
    },
  };
}
