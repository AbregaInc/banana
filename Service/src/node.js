// Node 24 entry: the same app on @hono/node-server, Node's built-in SQLite, a timer for the job,
// a SQLite file per space and blobs in a directory, under DATA_DIR.
//   DATABASE_PATH=./banana.db DATA_DIR=./data PORT=8787 node src/node.js     (settings: see README.md)

import "./node-runtime.js";

import { serve } from "@hono/node-server";
import { getConnInfo } from "@hono/node-server/conninfo";
import { serveStatic } from "@hono/node-server/serve-static";
import { createApp, pushTo } from "./app.js";
import { createApns } from "./apns.js";
import { configFrom } from "./config.js";
import { createGoogle } from "./google.js";
import { runJob } from "./job.js";
import { sqlite } from "./adapters/sqlite.js";
import { http2Fetch } from "./adapters/http2.js";
import { fsBlobs } from "./adapters/blobs-fs.js";
import { spacesSqlite } from "./adapters/spaces-sqlite.js";
import { join } from "node:path";
import { memoryEmail } from "./booking/email.js";
import { memoryLimits, memoryPageCache } from "./booking/guard.js";
import { bookingContext, bookingMinute, bookingQuarter } from "./booking/jobs.js";
import { createSigner } from "./booking/sign.js";

const config = configFrom(process.env);
const dataDir = process.env.DATA_DIR || "./data";
const blobs = fsBlobs(join(dataDir, "blobs"));
const spaces = spacesSqlite(join(dataDir, "spaces"), { blobs });
spaces.resume();
const deps = {
  db: sqlite(process.env.DATABASE_PATH || "./banana.db"),
  email: memoryEmail(),          // no provider on Node yet: messages are kept in memory and logged
  limit: memoryLimits(),
  // The address the rate limits count: the socket's peer, never a header the client wrote.
  clientIp: (c) => { try { return getConnInfo(c).remote.address ?? null; } catch { return null; } },
  pageCache: memoryPageCache(),
  google: createGoogle(config, fetch),
  apns: createApns(config, http2Fetch), // APNs only speaks HTTP/2; Node's fetch speaks HTTP/1.1
  config,
  spaces,
  blobs,
  changes: null,
  defer: (work) => { Promise.resolve(work).catch((error) => console.log(`deferred: ${error.name}`)); },
  now: Date.now,
  sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
  random: (n) => crypto.getRandomValues(new Uint8Array(n)),
};

const app = createApp(deps);
app.get("/app/assets/*", serveStatic({ root: "./public" }));
app.get("/book/fonts/*", serveStatic({ root: "./public" }));
const port = Number(process.env.PORT || 8787);
serve({ fetch: app.fetch, port }, () => console.log(`banana service on :${port}`));

let running = false;
async function job() {
  if (running) return;
  running = true;
  try { console.log(`job: ${JSON.stringify(await runJob(deps))}`); }
  catch (error) { console.log(`job failed: ${error.name}`); }
  finally { running = false; }
}
setInterval(job, 15 * 60 * 1000);
job();

// Booking's scheduled work (src/booking/jobs.js): a minute's and a quarter hour's.
if (config.bookUrl) {
  const work = bookingContext(deps, { push: (a, o) => pushTo(deps, a, o), signer: createSigner(config.tokenKey) });
  let minuteRunning = false;
  setInterval(async () => {
    if (minuteRunning) return;
    minuteRunning = true;
    try { await bookingMinute(work); } catch (error) { console.log(`booking: minute failed (${error.name})`); } finally { minuteRunning = false; }
  }, 60 * 1000);
  setInterval(() => bookingQuarter(work).catch((error) => console.log(`booking: quarter failed (${error.name})`)), 15 * 60 * 1000);
}
