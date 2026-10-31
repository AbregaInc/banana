// A whole service on an in-memory SQLite database with fake Google and APNs ports.

import { createApp } from "../src/app.js";
import { sqlite } from "../src/adapters/sqlite.js";
import { fsBlobs } from "../src/adapters/blobs-fs.js";
import { spacesSqlite } from "../src/adapters/spaces-sqlite.js";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// Space files and blobs go in a temporary folder per setup, removed when the test process ends.
const folders = [];
process.on("exit", () => { for (const f of folders) rmSync(f, { recursive: true, force: true }); });
export function tempDir() {
  const dir = mkdtempSync(join(tmpdir(), "banana-service-"));
  folders.push(dir);
  return dir;
}
import { GoogleError, GoogleRefused } from "../src/google.js";
import { base64url } from "../src/crypto.js";

export const TOKEN_KEY = base64url(new Uint8Array(32).fill(7));
export const START = Date.UTC(2026, 9, 15, 12, 0, 0);
export const HOUR = 60 * 60 * 1000;
export const DAY = 24 * HOUR;

export function device(id, overrides = {}) {
  return { id, platform: "iphone", push: null, pushEnv: "production", bundle: "app.banana.Banana", ...overrides };
}
export const pushToken = (n) => String(n).repeat(64).slice(0, 64);

export function fakeGoogle() {
  const people = new Map();
  const refused = new Set();
  const calls = { exchange: 0, refresh: [], watch: [], stop: [], revoke: [] };
  return {
    people, refused, calls, failWatch: false,
    /** A code the fake will trade for this Google account. */
    person(code, sub, email, refreshToken = `refresh-${sub}`, extra = {}) {
      people.set(code, { sub, email, refreshToken, scopes: "openid email https://www.googleapis.com/auth/calendar", ...extra });
    },
    identities: new Map(),
    /** An identity token the fake will accept for this Google account. */
    identity(token, sub, email) { this.identities.set(token, { sub, email }); },
    async verifyIdToken(token) {
      const who = this.identities.get(token);
      if (!who) throw new GoogleRefused("id_token signature");
      return { ...who };
    },
    async exchangeCode(code) {
      calls.exchange++;
      const p = people.get(code);
      if (!p) throw new GoogleRefused("invalid_grant");
      return { ...p };
    },
    async refresh(refreshToken) {
      calls.refresh.push(refreshToken);
      if (refused.has(refreshToken)) throw new GoogleRefused("invalid_grant");
      return { accessToken: `access-${refreshToken}`, expiresAt: Infinity };
    },
    async watch(accessToken, calendarId, options) {
      if (this.failWatch) throw new GoogleError("watch 500", 500);
      this.calls.watch.push({ accessToken, calendarId, ...options });
      return { resourceId: `resource-${options.id}`, expiration: this.clock() + options.ttlSeconds * 1000 };
    },
    async stop(accessToken, channel) { calls.stop.push({ accessToken, ...channel }); },
    /** Events per calendar: `events.set(calendarId, [...])`; a listing hands them out with a token
     * `tok-<n>`, and a sync read hands out only `changed.get(calendarId)` (then clears it). */
    events: new Map(), changed: new Map(), listCalls: [], tokenGone: false,
    async listEvents(accessToken, calendarId, params) {
      this.listCalls.push({ calendarId, ...params });
      if (params.syncToken) {
        if (this.tokenGone) { this.tokenGone = false; throw new GoogleError("events 410", 410); }
        const items = this.changed.get(calendarId) ?? [];
        this.changed.set(calendarId, []);
        return { events: items, syncToken: `tok-${this.listCalls.length}` };
      }
      return { events: this.events.get(calendarId) ?? [], syncToken: `tok-${this.listCalls.length}` };
    },
    async revoke(refreshToken) { calls.revoke.push(refreshToken); },
    clock: () => 0,

    // ---- booking: calendar lists, events made, read, moved, deleted, free/busy ----
    /** Calendars per refresh token; without an entry, one primary calendar `primary-<refresh>`. */
    calendars: new Map(),
    /** "ready" (the Meet link at once), "pending" (then ready on the next read), or "disabled". */
    meet: "ready",
    /** Fail this many inserts with a 500; `lostInsert`: the next insert gets through but its answer is lost. */
    failInsert: 0, lostInsert: false,
    failPatch: 0, failList: false, freeBusyAnswer: [], freeBusyCalls: [],
    booking: { insert: [], get: [], patch: [], delete: [] },
    tokenOf: (access) => String(access).replace(/^access-/, ""),
    calendarsOf(access) {
      const rt = this.tokenOf(access);
      return this.calendars.get(rt) ?? [{ id: `primary-${rt}`, summary: "Primary", timeZone: "America/New_York", primary: true, accessRole: "owner" }];
    },
    resolve(access, calendarId) { return calendarId === "primary" ? this.calendarsOf(access).find((c) => c.primary)?.id ?? calendarId : calendarId; },
    async calendarList(access) {
      if (this.failList) throw new GoogleError("calendarList 500", 500);
      if (refused.has(this.tokenOf(access))) throw new GoogleError("calendarList 401", 401);
      return this.calendarsOf(access).map((c) => ({ ...c }));
    },
    findEvent(access, calendarId, eventId) {
      const list = this.events.get(this.resolve(access, calendarId)) ?? [];
      return list.find((e) => e.id === eventId) ?? null;
    },
    async insertEvent(access, calendarId, event, { sendUpdates }) {
      const cal = this.resolve(access, calendarId);
      this.booking.insert.push({ calendarId: cal, event: structuredClone(event), sendUpdates });
      if (this.gate) await this.gate;   // a test holds Google back here
      if (this.failInsert > 0) { this.failInsert--; throw new GoogleError("insert 500", 500); }
      if (this.findEvent(access, cal, event.id)) throw new GoogleError("insert 409", 409);
      const made = { ...structuredClone(event), status: "confirmed", updated: new Date(this.clock()).toISOString() };
      if (event.conferenceData?.createRequest) {
        made.conferenceData = this.meet === "ready"
          ? { createRequest: { ...event.conferenceData.createRequest, status: { statusCode: "success" } }, entryPoints: [{ entryPointType: "video", uri: `https://meet.google.com/${event.id.slice(0, 3)}-abcd-efg` }] }
          : { createRequest: { ...event.conferenceData.createRequest, status: { statusCode: this.meet === "pending" ? "pending" : "failure" } } };
      }
      if (!this.events.has(cal)) this.events.set(cal, []);
      this.events.get(cal).push(made);
      if (this.lostInsert) { this.lostInsert = false; throw new GoogleError("insert lost", 502); }
      return structuredClone(made);
    },
    async getEvent(access, calendarId, eventId) {
      this.booking.get.push({ calendarId, eventId });
      const e = this.findEvent(access, calendarId, eventId);
      if (!e) return null;
      if (e.conferenceData?.createRequest?.status?.statusCode === "pending") {
        e.conferenceData = { createRequest: { ...e.conferenceData.createRequest, status: { statusCode: "success" } }, entryPoints: [{ entryPointType: "video", uri: "https://meet.google.com/later-link" }] };
      }
      return structuredClone(e);
    },
    async patchEvent(access, calendarId, eventId, patch, { sendUpdates }) {
      this.booking.patch.push({ calendarId, eventId, patch: structuredClone(patch), sendUpdates });
      if (this.failPatch > 0) { this.failPatch--; throw new GoogleError("patch 500", 500); }
      const e = this.findEvent(access, calendarId, eventId);
      if (!e) return null;
      Object.assign(e, structuredClone(patch));
      return structuredClone(e);
    },
    async deleteEvent(access, calendarId, eventId, { sendUpdates }) {
      this.booking.delete.push({ calendarId, eventId, sendUpdates });
      const cal = this.resolve(access, calendarId);
      this.events.set(cal, (this.events.get(cal) ?? []).filter((e) => e.id !== eventId));
    },
    async freeBusy(access, options) {
      this.freeBusyCalls.push({ access, ...options });
      if (refused.has(this.tokenOf(access))) throw new GoogleRefused("invalid_grant");
      return structuredClone(this.freeBusyAnswer);
    },
  };
}

export function fakeApns() {
  const sends = [];
  const answers = new Map();
  return {
    sends, answers,
    async send(push) {
      sends.push(push);
      const a = answers.get(push.token) ?? { status: 200, reason: null };
      return { ok: a.status === 200, status: a.status, reason: a.reason };
    },
  };
}

/** @param {{config?: object, deps?: object}} [options] booking tests name the booking host and their own ports */
export function setup(options = {}) {
  let clock = START;
  const pending = [];
  const sleeps = [];
  const timers = [];
  const db = sqlite(":memory:");
  const google = fakeGoogle();
  google.clock = () => clock;
  const apns = fakeApns();
  const dir = tempDir();
  const blobs = fsBlobs(join(dir, "blobs"));
  const spaces = spacesSqlite(join(dir, "spaces"), { blobs });
  const deps = {
    db, google, apns, blobs, spaces, changes: null,
    config: { publicUrl: "https://service.test", tokenKey: TOKEN_KEY, googleClientId: "web-client", googleClientSecret: "", googleRedirectUri: "", apnsKey: "", apnsKeyId: "", apnsTeamId: "", eventAlerts: true,
              emailFrom: "Banana <book@bananatheapp.com>", turnstileRequired: false, ...(options.config ?? {}) },
    defer: (work) => { pending.push(work); },
    now: () => clock,
    // A wait (the trailing sync push) ends when settle() moves the test clock past it.
    sleep: (ms) => new Promise((resolve) => { sleeps.push(ms); timers.push({ ms, resolve }); }),
    random: (n) => crypto.getRandomValues(new Uint8Array(n)),
    ...(options.deps ?? {}),
  };
  const app = createApp(deps);

  async function call(method, path, { body, session, headers = {} } = {}) {
    const init = { method, headers: { ...headers } };
    if (body !== undefined) { init.body = typeof body === "string" ? body : JSON.stringify(body); init.headers["content-type"] = "application/json"; }
    if (session) init.headers.authorization = `Bearer ${session}`;
    const response = await app.request(path, init);
    const text = await response.text();
    let json;
    try { json = JSON.parse(text); } catch { json = undefined; }
    return { status: response.status, json, text };
  }

  return {
    app, db, google, apns, deps, call,
    advance(ms) { clock += ms; },
    now: () => clock,
    dir, sleeps,
    /** Waits for everything handed to defer (and anything that adds), the waits they make (the
     * clock moves on by each), and the spaces' trash moves. */
    async settle() {
      while (pending.length || timers.length) {
        const timer = timers.shift();
        if (timer) { clock += timer.ms; timer.resolve(); }
        if (pending.length) await pending.shift();
      }
      await spaces.idle();
    },
    signIn(code, dev, session) { return call("POST", "/v1/google", { body: { code, device: dev }, session }); },
    count: async (table, where = "1 = 1", ...params) => Number((await db.first(`SELECT COUNT(*) AS n FROM ${table} WHERE ${where}`, ...params)).n),
  };
}
