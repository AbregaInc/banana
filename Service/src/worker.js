// Cloudflare Workers entry: D1 for the database, waitUntil for work after the response, a Cron
// Trigger for the job, a Durable Object per space and R2 for blobs (wrangler.toml).

import { createApp, pushTo } from "./app.js";
import { createApns } from "./apns.js";
import { configFrom } from "./config.js";
import { createGoogle } from "./google.js";
import { runJob } from "./job.js";
import { dispatchAlerts } from "./events.js";
import { d1 } from "./adapters/d1.js";
import { r2Blobs } from "./adapters/r2.js";
import { doSpaces } from "./space-do.js";
import { cloudflareEmail, memoryEmail } from "./booking/email.js";
import { createTurnstile, workersLimits, workersPageCache } from "./booking/guard.js";
import { bookingContext, bookingMinute, bookingQuarter } from "./booking/jobs.js";
import { createSigner } from "./booking/sign.js";

export { Space } from "./space-do.js";

// Ports live as long as the isolate, so Google access tokens and the APNs JWT are reused.
let ports;
function shared(env) {
  if (!ports) {
    const config = configFrom(env);
    const fetcher = (...args) => fetch(...args);
    ports = { config, google: createGoogle(config, fetcher), apns: createApns(config, fetcher), turnstile: createTurnstile(config.turnstileSecret, fetcher, { required: config.turnstileRequired }) };
  }
  return ports;
}

const random = (n) => crypto.getRandomValues(new Uint8Array(n));

function deps(env, ctx) {
  return {
    ...shared(env),
    db: d1(env.DB),
    // The booking pages' reads go to the nearest D1 replica (Sessions API, first read unconstrained).
    replica: typeof env.DB.withSession === "function" ? d1(env.DB.withSession("first-unconstrained")) : undefined,
    // Booking email: Cloudflare Email Service once the domain is onboarded ([[send_email]] EMAIL).
    email: env.EMAIL ? cloudflareEmail(env.EMAIL) : memoryEmail(),
    limit: workersLimits(env),
    pageCache: typeof caches !== "undefined" ? workersPageCache(caches.default) : null,
    spaces: doSpaces(env.SPACES),
    blobs: r2Blobs(env.BLOBS),
    changes: env.CHANGES ?? null,   // the Pipeline, once it exists
    defer: (work) => ctx.waitUntil(Promise.resolve(work).catch((error) => console.log(`deferred: ${error.name}`))),
    now: Date.now,
    sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
    random,
  };
}

export default {
  fetch(request, env, ctx) {
    return createApp(deps(env, ctx)).fetch(request, env, ctx);
  },
  scheduled(event, env, ctx) {
    // Every minute the alert dispatcher; every quarter hour the watch and link job as well.
    const d = deps(env, ctx);
    // At a quarter hour both crons fire, as two invocations: the minute's work runs in one of them only.
    const minute = event.cron !== "*/15 * * * *";
    if (d.config.eventAlerts && minute) ctx.waitUntil(dispatchAlerts(d).then((r) => console.log(`alerts: ${JSON.stringify(r)}`)));
    if (event.cron === "*/15 * * * *") ctx.waitUntil(runJob(d).then((r) => console.log(`job: ${JSON.stringify(r)}`)));
    // Booking: every minute its retries, held invites and reminders; every quarter hour its snapshots and sweeps.
    if (d.config.bookUrl) {
      const work = bookingContext(d, { push: (a, o) => pushTo(d, a, o), signer: createSigner(d.config.tokenKey) });
      if (minute) ctx.waitUntil(bookingMinute(work).then((r) => console.log(`booking: ${JSON.stringify(r)}`)).catch((error) => console.log(`booking: minute failed (${error.name})`)));
      if (event.cron === "*/15 * * * *") ctx.waitUntil(bookingQuarter(work).then((r) => console.log(`booking: ${JSON.stringify(r)}`)).catch((error) => console.log(`booking: quarter failed (${error.name})`)));
    }
  },
};
