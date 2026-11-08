// Local workerd acceptance of the shared mailbox on a real Durable Object (SQLite storage,
// transactionSync, alarms), local D1 with the production migrations and local R2. Gmail is the
// in-memory fake from the service tests: no Google request, no credential, no real message.
import { DurableObject } from "cloudflare:workers";
import { createMailbox } from "../../src/mailbox.js";
import { createVault, base64url } from "../../src/crypto.js";
import { d1 } from "../../src/adapters/d1.js";
import { r2Blobs } from "../../src/adapters/r2.js";
import { fakeGmail } from "../../test/fake-gmail.js";

const KEY = base64url(new Uint8Array(32).fill(7));
const random = (n) => crypto.getRandomValues(new Uint8Array(n));
const EMAIL = "noor@plan.example", SUB = "sub-fixture", ACCOUNT = "account-fixture";

export class CheckMailbox extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.gmail = fakeGmail({ email: EMAIL });
    for (let i = 1; i <= 40; i++) this.gmail.add(`m${i}`, i % 2 ? ["INBOX", "UNREAD"] : ["Label_1"]);
    const google = { mailRead: (...a) => this.gmail.mailRead(...a), refresh: async () => ({ accessToken: "fixture", expiresAt: Infinity }) };
    this.deps = { config: { googleClientId: "web-client", tokenKey: KEY }, db: d1(env.DB), google, now: Date.now, random, sleep: async () => {} };
    this.vault = createVault(KEY, random);
    this.mailbox = createMailbox({
      port: { exec: (sql, ...args) => ctx.storage.sql.exec(sql, ...args).toArray(), transaction: (fn) => ctx.storage.transactionSync(fn) },
      deps: this.deps, vault: this.vault, blobs: r2Blobs(env.BLOBS),
      alarm: { set: async (at) => { const c = await ctx.storage.getAlarm(); if (c === null || c > at) await ctx.storage.setAlarm(at); } },
      destroy: async () => { await ctx.storage.deleteAlarm(); await ctx.storage.deleteAll(); },
    });
  }
  async alarm() { await this.mailbox.run(); }
  async check() {
    const db = this.env.DB, now = Date.now();
    for (const sql of ["DELETE FROM mail_mailboxes", "DELETE FROM mail_read_pacing", "DELETE FROM feature_access", "DELETE FROM mail_grants", "DELETE FROM google_links", "DELETE FROM accounts"]) await db.prepare(sql).run();
    await db.prepare("INSERT INTO accounts (id, created_at) VALUES (?, ?)").bind(ACCOUNT, now).run();
    await db.prepare("INSERT INTO google_links (sub, account_id, email, refresh_token, scopes, status, created_at, updated_at) VALUES (?, ?, ?, NULL, '', 'ok', ?, ?)").bind(SUB, ACCOUNT, EMAIL, now, now).run();
    await db.prepare("INSERT INTO mail_grants VALUES (?, ?, 'https://www.googleapis.com/auth/gmail.modify', 'web-client', 'ok', ?, ?)").bind(SUB, await this.vault.seal(SUB, "fixture-refresh"), now, now).run();
    await db.prepare("INSERT INTO feature_access VALUES (?, 'email', 1, NULL, ?)").bind(ACCOUNT, now).run();
    const results = {};
    await this.mailbox.ensure({ sub: SUB, email: EMAIL, account: ACCOUNT });
    results.handshake = (await this.mailbox.feed({ after: null, limit: 1000, fresh: true })).ready;
    for (let i = 0; i < 60; i++) { await this.mailbox.run({ steps: 25 }); const s = await this.mailbox.status(); if (s.complete && !s.counts.verify && !s.counts.fetch) break; await db.prepare("UPDATE mail_read_pacing SET next_at = 0").run(); }
    const feed = await this.mailbox.feed({ after: null, limit: 1000 });
    results.entries = feed.entries.length;
    results.complete = feed.complete;
    results.alarm = (await this.ctx.storage.getAlarm()) !== null;
    const first = await this.mailbox.content({ id: "m2" }), second = await this.mailbox.content({ id: "m2" });
    results.contentStoredOnce = Boolean(first.key) && first.key === second.key && this.gmail.reads("message", "m2", "full") === 1;
    const object = await this.env.BLOBS.get(first.key);
    const plain = JSON.parse(new TextDecoder().decode(await this.vault.openBytes(first.aad, new Uint8Array(await object.arrayBuffer()))));
    results.contentOpens = plain.id === "m2";
    this.gmail.modify("m1", [], ["UNREAD"]);
    await this.mailbox.poke(); await this.mailbox.run();
    const m1 = (await this.mailbox.feed({ after: Number(feed.cursor), limit: 10 })).entries.find((e) => e.id === "m1");
    results.historyApplied = Boolean(m1) && !m1.labels.includes("UNREAD") && m1.history === String(this.gmail.messages.get("m1").hist);
    // The content fill on real Durable Object SQLite (its expression index and keyset walk), then
    // the bulk pull. The pace gap and the read slot are cleared between runs to finish quickly.
    const before = this.gmail.calls.length;
    for (let i = 0; i < 200; i++) {
      await db.prepare("UPDATE mail_read_pacing SET next_at = 0").run();
      this.ctx.storage.sql.exec("DELETE FROM meta WHERE key = 'fill_next_at'");
      await this.mailbox.run({ steps: 5 });
      if ((await this.mailbox.status()).fill.done !== null) break;
    }
    const filled = await this.mailbox.status();
    const fillReads = this.gmail.calls.slice(before).filter((c) => c.resource === "message" && c.format === "full").map((c) => Number(c.id.slice(1)));
    results.filled = filled.counts.cached === 40 && filled.fill.done !== null;
    results.fillNewestFirst = fillReads.length > 0 && fillReads.every((n, i) => i === 0 || n < fillReads[i - 1]);
    results.feedSaysContent = (await this.mailbox.feed({ after: null, limit: 1000 })).entries.filter((e) => e.content).length === 40;
    const bulk = await this.mailbox.contents(["m40", "m1", "nope"]);
    results.bulk = Boolean(bulk[0].key && bulk[1].key && bulk[2].missing);
    await this.mailbox.wipe();
    results.wiped = (await this.env.BLOBS.list({ prefix: "mail/" })).objects.length === 0 && (await db.prepare("SELECT COUNT(*) AS n FROM mail_mailboxes").first()).n === 0;
    results.passed = results.handshake && results.entries === 40 && results.complete && results.alarm && results.contentStoredOnce && results.contentOpens && results.historyApplied && results.filled && results.fillNewestFirst && results.feedSaysContent && results.bulk && results.wiped;
    return results;
  }
}

export default {
  async fetch(request, env) {
    const stub = env.MAILBOXES.get(env.MAILBOXES.idFromName(`check-${Date.now()}`));
    const results = await stub.check();
    return Response.json(results, { status: results.passed ? 200 : 500 });
  },
};
