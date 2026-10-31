// A fresh local database for the end-to-end sync check (tools/e2e-sync.sh): every migration
// applied (opening it does that, as src/node.js does on start), then one account with an iPhone,
// an iPad and a Mac, each with its own session. No Google, no APNs: the devices carry made-up push
// tokens, so the sync pushes are tried and fail (no APNs key), which must not get in sync's way.
//
//   DATABASE_PATH=/tmp/e2e/banana.db PORT=8787 node tools/e2e-seed.mjs > seed.json
//
// Prints {host, account, sessions: {phone, mac, ipad}, devices: {phone, mac, ipad}}. Sessions are
// random tokens; only their SHA-256 goes in the database, as for real ones.

import { sqlite } from "../src/adapters/sqlite.js";
import { base64url, sha256Hex } from "../src/crypto.js";
import { existsSync } from "node:fs";

const path = process.env.DATABASE_PATH;
if (!path) { console.error("DATABASE_PATH is required"); process.exit(1); }
if (existsSync(path)) { console.error(`${path} exists: the check wants a fresh database`); process.exit(1); }
const port = Number(process.env.PORT || 8787);

const random = (n) => crypto.getRandomValues(new Uint8Array(n));
const db = sqlite(path);
const now = Date.now();
const account = base64url(random(16));
const suffix = base64url(random(6)).replace(/_/g, "-");
const platforms = { phone: "iphone", ipad: "ipad", mac: "mac" };
const sessions = {}, devices = {};
const statements = [{ sql: "INSERT INTO accounts (id, created_at) VALUES (?, ?)", params: [account, now] }];
let n = 1;
for (const [who, platform] of Object.entries(platforms)) {
  const id = `e2e-${who}-${suffix}`;
  const session = base64url(random(32));
  devices[who] = id;
  sessions[who] = session;
  statements.push(
    { sql: "INSERT INTO sessions (token_hash, account_id, created_at, last_used_at) VALUES (?, ?, ?, ?)",
      params: [await sha256Hex(session), account, now, now] },
    { sql: "INSERT INTO devices (id, account_id, platform, push_token, push_env, bundle, updated_at) VALUES (?, ?, ?, ?, 'development', 'app.banana.e2e', ?)",
      params: [id, account, platform, String(n++).repeat(64), now] },
  );
}
await db.batch(statements);
db.close();
console.log(JSON.stringify({ host: `http://127.0.0.1:${port}`, account, sessions, devices }));
