// Sender images for Mail (docs/design/MAIL-UX.md, "Sender images"). A device asks for the senders it
// shows; the service finds each one's image, keeps it, and hands out an id the device fetches once.
// No device ever asks Gravatar, a brand's site or Google for a picture: those would learn who writes
// to the owner, and when he reads it.
//
// Two tiers:
//   - shared, for every Banana user: from public sources only (BIMI, Gravatar, a site's icon, a
//     person's own Google profile photo). The first person to show a sender pays for the fetch.
//   - per user: a photo the owner set on one of his Google contacts. It is his, is served to him
//     alone, and goes with the account (or with Mail, or the Google link).
//
// The order, for one address: his contact's photo → the person's profile photo → the brand's BIMI
// logo → Gravatar → the site's icon (automated senders) → none, and the device keeps the monogram.
// Mail-provider domains (gmail.com, outlook.com…) never get a brand logo or site icon.
//
// Never logged: an address, a hash of one, a URL.

import { featureAllowed } from "./feature-access.js";
import { mailLink } from "./mail-grant.js";
import { GoogleRefused } from "./google.js";
import {
  addressParts, isProvider, isAutomated, sha256Hex, bimiLogo, gravatar, siteIcon, googlePhoto, sniff,
} from "./sender-sources.js";

const HOUR = 60 * 60 * 1000;
const DAY = 24 * HOUR;
export const TTL = {
  found: 14 * DAY,       // an image, kept and served this long before it is asked for again
  none: 3 * DAY,         // the source has nothing
  failed: HOUR,          // the source could not be asked: soon again
  contacts: DAY,         // his contacts are read again after this
};
export const MOST_ADDRESSES = 50;
const MOST_CONTACT_ROWS = 10_000;     // per Google account
const MOST_CONTACT_PAGES = 5;         // per kind, 1000 people each
const ANSWER_WITHIN = 2_500;          // what is not found by then keeps going, and is "pending"
const AT_ONCE = 6;
const CONTACTS_SCOPE = "https://www.googleapis.com/auth/contacts.readonly";
const OTHER_CONTACTS_SCOPE = "https://www.googleapis.com/auth/contacts.other.readonly";
export const SENDER_SCOPES = [CONTACTS_SCOPE, OTHER_CONTACTS_SCOPE];

const sharedKey = (image) => `senders/shared/${image}`;
const ownKey = (account, image) => `senders/u/${account}/${image}`;

/** The request's addresses, distinct, at most MOST_ADDRESSES; null when it is not one. */
export function parseSenders(body) {
  if (!body || typeof body !== "object" || !Array.isArray(body.addresses)) return null;
  if (body.addresses.length === 0 || body.addresses.length > MOST_ADDRESSES) return null;
  const out = [];
  for (const a of body.addresses) {
    if (typeof a !== "string" || a.length > 320) return null;
    if (!out.includes(a)) out.push(a);
  }
  return out;
}

/** Work started for one shared key, so two requests in one isolate fetch it once. */
const flights = new Map();

/** @param {import("./app.js").Deps & {outbound?: typeof fetch, rasterSvg?: Function}} deps */
export function senderImages(deps, vault) {
  const { db, blobs, now } = deps;
  const sources = { fetch: deps.outbound ?? ((...a) => fetch(...a)), rasterSvg: deps.rasterSvg ?? null };
  const answerWithin = deps.senderAnswerWithin ?? ANSWER_WITHIN;

  /** Stores bytes under their hash; the id. */
  async function store(key, bytes) {
    const image = await sha256Hex(bytes);
    if (!(await blobs.head(key(image)))) await blobs.put(key(image), bytes, { sha256: image });
    return image;
  }

  async function sharedRows(keys) {
    const rows = new Map();
    for (let i = 0; i < keys.length; i += 90) {
      const part = keys.slice(i, i + 90);
      for (const r of await db.all(`SELECT key, image, expires_at FROM sender_images WHERE key IN (${part.map(() => "?").join(",")})`, ...part)) rows.set(r.key, r);
    }
    return rows;
  }

  async function writeShared(key, answer) {
    const t = now();
    let image = null, ttl = TTL.none;
    if (answer.image) { image = await store(sharedKey, answer.image.bytes); ttl = TTL.found; }
    else if (answer.failed) ttl = TTL.failed;
    await db.run(`INSERT INTO sender_images (key, image, checked_at, expires_at) VALUES (?, ?, ?, ?)
      ON CONFLICT (key) DO UPDATE SET image = excluded.image, checked_at = excluded.checked_at, expires_at = excluded.expires_at`,
      key, image, t, t + ttl);
    return image;
  }

  /**
   * A shared source's image id, or null: from the row while it is fresh, else asked of the source
   * (once per isolate at a time). `ask` returns a source answer.
   */
  async function shared(rows, key, ask) {
    const row = rows.get(key);
    if (row && Number(row.expires_at) > now()) return row.image ?? null;
    let flight = flights.get(key);
    if (!flight) {
      flight = (async () => writeShared(key, await ask()))().finally(() => flights.delete(key));
      flights.set(key, flight);
    }
    const image = await flight;
    rows.set(key, { key, image, expires_at: now() + TTL.found });
    return image;
  }

  // ---- his contacts ----

  async function contactLinks(account) {
    const links = await db.all("SELECT email FROM google_links WHERE account_id = ? AND status <> 'unlinked'", account);
    const out = [];
    for (const { email } of links) {
      const link = await mailLink(deps, account, email);
      if (!link?.refresh_token || link.status !== "ok") continue;
      const scopes = new Set(String(link.scopes ?? "").split(/\s+/));
      const kinds = [scopes.has(CONTACTS_SCOPE) && "connections", scopes.has(OTHER_CONTACTS_SCOPE) && "other"].filter(Boolean);
      out.push({ link, kinds });
    }
    return out;
  }

  /** Reads his Google contacts' photos again where they are a day old (or never read). */
  async function syncContacts(account) {
    for (const { link, kinds } of await contactLinks(account)) {
      if (kinds.length === 0) {
        // Contacts not (or no longer) granted: what an earlier grant gave goes.
        if (await db.first("SELECT 1 AS x FROM sender_contact_syncs WHERE account_id = ? AND google_sub = ?", account, link.sub)) await forgetContacts(deps, account, link.sub);
        continue;
      }
      const synced = await db.first("SELECT synced_at FROM sender_contact_syncs WHERE account_id = ? AND google_sub = ?", account, link.sub);
      if (synced && now() - Number(synced.synced_at) < TTL.contacts) continue;
      try { await readContacts(account, link, kinds); }
      catch (error) {
        // Refused (the API off, or the grant withdrawn): what it gave goes, and it is tried again
        // in a day, not on every lookup.
        if (error instanceof GoogleRefused) await forgetContacts(deps, account, link.sub);
        else console.log(`senders: contacts unavailable (${error.name} ${error.status ?? ""})`);
        await db.run(`INSERT INTO sender_contact_syncs (account_id, google_sub, synced_at) VALUES (?, ?, ?)
          ON CONFLICT (account_id, google_sub) DO UPDATE SET synced_at = excluded.synced_at`, account, link.sub, now());
      }
    }
  }

  async function readContacts(account, link, kinds) {
    const { accessToken } = await deps.google.refresh(await vault.open(link.sub, link.refresh_token));
    const found = new Map();   // `${hash} ${source}` → url
    for (const kind of kinds) {
      let page = null;
      for (let n = 0; n < MOST_CONTACT_PAGES; n++) {
        const { people, next } = await deps.google.contacts(accessToken, kind, page);
        for (const person of people) {
          for (const [source, url] of contactPhotos(person)) {
            for (const e of person.emailAddresses ?? []) {
              const parts = addressParts(e?.value);
              if (!parts || found.size >= MOST_CONTACT_ROWS) continue;
              const id = `${await sha256Hex(parts.address)} ${source}`;
              if (!found.has(id)) found.set(id, url);
            }
          }
        }
        if (!next) break;
        page = next;
      }
    }
    // A contact photo already copied stays copied while its URL is the same.
    const kept = new Map((await db.all("SELECT address_hash, photo_url, image, image_checked_at FROM sender_contacts WHERE account_id = ? AND google_sub = ? AND source = 'contact' AND image IS NOT NULL", account, link.sub))
      .map((r) => [r.address_hash, r]));
    const rows = [...found].map(([id, url]) => {
      const [hash, source] = id.split(" ");
      const old = source === "contact" ? kept.get(hash) : null;
      const same = old && old.photo_url === url;
      return [account, link.sub, hash, source, url, same ? old.image : null, same ? old.image_checked_at : null];
    });
    const statements = [{ sql: "DELETE FROM sender_contacts WHERE account_id = ? AND google_sub = ?", params: [account, link.sub] }];
    for (let i = 0; i < rows.length; i += 14) {   // D1 binds at most 100 values a statement
      const part = rows.slice(i, i + 14);
      statements.push({ sql: `INSERT INTO sender_contacts (account_id, google_sub, address_hash, source, photo_url, image, image_checked_at) VALUES ${part.map(() => "(?, ?, ?, ?, ?, ?, ?)").join(", ")}`, params: part.flat() });
    }
    statements.push({ sql: `INSERT INTO sender_contact_syncs (account_id, google_sub, synced_at) VALUES (?, ?, ?)
      ON CONFLICT (account_id, google_sub) DO UPDATE SET synced_at = excluded.synced_at`, params: [account, link.sub, now()] });
    for (let i = 0; i < statements.length; i += 50) await db.batch(statements.slice(i, i + 50));
    // Copies of photos no longer on any contact of his go.
    const gone = [...kept.values()].filter((r) => !rows.some((row) => row[2] === r.address_hash && row[5] === r.image));
    await removeUnused(deps, account, gone.map((r) => r.image));
  }

  /** His contact's own photo for an address: copied for him alone, the id. */
  async function contactPhoto(account, row) {
    if (row.image && now() - Number(row.image_checked_at ?? 0) < TTL.found) return row.image;
    if (!row.image && row.image_checked_at && now() - Number(row.image_checked_at) < TTL.none) return null;
    const answer = await googlePhoto(sources, row.photo_url);
    if (answer.failed) return row.image ?? null;
    const image = answer.image ? await store((i) => ownKey(account, i), answer.image.bytes) : null;
    await db.run("UPDATE sender_contacts SET image = ?, image_checked_at = ? WHERE account_id = ? AND google_sub = ? AND address_hash = ? AND source = 'contact'",
      image, now(), account, row.google_sub, row.address_hash);
    if (row.image && row.image !== image) await removeUnused(deps, account, [row.image]);
    return image;
  }

  // ---- one address ----

  async function resolve(account, parts, hash, rows, contacts) {
    const mine = contacts.filter((c) => c.address_hash === hash);
    for (const row of mine.filter((c) => c.source === "contact")) {
      const image = await contactPhoto(account, row);
      if (image) return image;
    }
    // The person's own Google photo. Only a 'profile' photo is ever asked for here: what goes into
    // the shared tier is what the person shows everyone, never a photo one user set on a contact.
    const profile = mine.find((c) => c.source === "profile");
    const pKey = `p:${hash}`;
    const pRow = rows.get(pKey);
    if (profile) {
      const image = await shared(rows, pKey, () => googlePhoto(sources, profile.photo_url));
      if (image) return image;
    } else if (pRow?.image) return pRow.image;   // someone else's contacts found it; it is public
    const brandable = !isProvider(parts);
    const domainHash = await sha256Hex(parts.domain);
    if (brandable) {
      const image = await shared(rows, `b:${domainHash}`, () => bimiLogo(sources, parts));
      if (image) return image;
    }
    const g = await shared(rows, `g:${hash}`, () => gravatar(sources, hash));
    if (g) return g;
    if (brandable && isAutomated(parts)) {
      const organisationHash = await sha256Hex(parts.organisation);
      const image = await shared(rows, `i:${organisationHash}`, () => siteIcon(sources, parts));
      if (image) return image;
    }
    return null;
  }

  /** {senders: [{address, image}|{address, pending: true}]} for the request's addresses. */
  async function answer(account, addresses) {
    const known = [];
    for (const address of addresses) {
      const parts = addressParts(address);
      known.push({ address, parts, hash: parts ? await sha256Hex(parts.address) : null });
    }
    const valid = known.filter((k) => k.parts);
    // His contacts, read now when they never were (bounded by the same wait), else again in the background.
    const never = !(await db.first("SELECT 1 AS x FROM sender_contact_syncs WHERE account_id = ? LIMIT 1", account));
    const sync = syncContacts(account).catch((error) => console.log(`senders: contacts failed (${error.name})`));
    deps.defer(sync);
    if (never) await within(sync, answerWithin);
    const hashes = [...new Set(valid.map((k) => k.hash))];
    const contacts = [];
    for (let i = 0; i < hashes.length; i += 90) {
      const part = hashes.slice(i, i + 90);
      contacts.push(...await db.all(`SELECT google_sub, address_hash, source, photo_url, image, image_checked_at FROM sender_contacts
        WHERE account_id = ? AND address_hash IN (${part.map(() => "?").join(",")})`, account, ...part));
    }
    const keys = [];
    for (const k of valid) {
      keys.push(`p:${k.hash}`, `g:${k.hash}`, `b:${await sha256Hex(k.parts.domain)}`, `i:${await sha256Hex(k.parts.organisation)}`);
    }
    const rows = await sharedRows([...new Set(keys)]);
    const finished = new Map();
    const queue = [...valid];
    const workers = Array.from({ length: Math.min(AT_ONCE, queue.length) }, async () => {
      for (let k = queue.shift(); k; k = queue.shift()) {
        const image = await resolve(account, k.parts, k.hash, rows, contacts).catch((error) => {
          console.log(`senders: resolve failed (${error.name})`);
          return null;
        });
        finished.set(k.address, image);
      }
    });
    const all = Promise.all(workers);
    deps.defer(all);
    await within(all, answerWithin);
    return known.map((k) => !k.parts ? { address: k.address, image: null }
      : finished.has(k.address) ? { address: k.address, image: finished.get(k.address) }
      : { address: k.address, pending: true });
  }

  /** The bytes of an image id he may see: his own contact copy, else a shared image. */
  async function image(account, id) {
    const own = await db.first("SELECT 1 AS x FROM sender_contacts WHERE account_id = ? AND image = ? LIMIT 1", account, id);
    if (own) return blobs.get(ownKey(account, id));
    const shared = await db.first("SELECT 1 AS x FROM sender_images WHERE image = ? LIMIT 1", id);
    if (shared) return blobs.get(sharedKey(id));
    return null;
  }

  return { answer, image, syncContacts };
}

/** Waits for `work`, or `ms`, whichever is first; the timer does not outlive it. */
async function within(work, ms) {
  let timer;
  await Promise.race([work, new Promise((resolve) => { timer = setTimeout(resolve, ms); })]);
  clearTimeout(timer);
}

/** Removes his copies of these images that no contact row of his still names. */
async function removeUnused(deps, account, images) {
  for (const image of new Set(images.filter(Boolean))) {
    const still = await deps.db.first("SELECT 1 AS x FROM sender_contacts WHERE account_id = ? AND image = ? LIMIT 1", account, image);
    if (!still) await deps.blobs.delete(ownKey(account, image));
  }
}

/** Everything his contacts gave, for one Google account (`sub`) or all of them. */
export async function forgetContacts(deps, account, sub = null) {
  const where = sub ? "account_id = ? AND google_sub = ?" : "account_id = ?";
  const params = sub ? [account, sub] : [account];
  const images = (await deps.db.all(`SELECT DISTINCT image FROM sender_contacts WHERE ${where} AND image IS NOT NULL`, ...params)).map((r) => r.image);
  await deps.db.batch([
    { sql: `DELETE FROM sender_contacts WHERE ${where}`, params },
    { sql: `DELETE FROM sender_contact_syncs WHERE ${where}`, params },
  ]);
  await removeUnused(deps, account, images);
  if (!sub) {
    // Whatever is left under his prefix (a copy whose row went with an interrupted write).
    for (let keys = await deps.blobs.list(`senders/u/${account}/`); keys.length; keys = await deps.blobs.list(`senders/u/${account}/`)) {
      for (const key of keys) await deps.blobs.delete(key);
    }
  }
}

/** The two routes, on the signed-in owner's session. */
export function senderImageRoutes(app, deps, { signedIn, readJson, vault }) {
  const images = senderImages(deps, vault);

  // A POST, so no address sits in a URL (MAIL-ENGINE invariant 21).
  app.post("/v1/mail/senders", signedIn, async (c) => {
    c.header("Cache-Control", "no-store");
    const account = c.get("account");
    if (!(await featureAllowed(deps, account, "email"))) return c.json({ error: "feature_unavailable" }, 403);
    if (!(await deps.limit("senders", account))) { c.header("Retry-After", "60"); return c.json({ error: "rate" }, 429); }
    const addresses = parseSenders(await readJson(c, 32 * 1024));
    if (!addresses) return c.json({ error: "bad_request" }, 400);
    const senders = await images.answer(account, addresses);
    if (senders.some((s) => s.pending)) c.header("Retry-After", "5");
    return c.json({ senders });
  });

  // An image by its id (the SHA-256 of its bytes): the same id is the same bytes, for good.
  app.get("/v1/mail/sender-image/:id", signedIn, async (c) => {
    const id = c.req.param("id");
    if (!/^[0-9a-f]{64}$/.test(id)) return c.body(null, 404);
    const account = c.get("account");
    if (!(await featureAllowed(deps, account, "email"))) return c.body(null, 403);
    const blob = await images.image(account, id);
    if (!blob) return c.body(null, 404);
    const bytes = new Uint8Array(await new Response(blob.body).arrayBuffer());
    const type = sniff(bytes);
    if (!type) return c.body(null, 404);
    return c.body(bytes, 200, {
      "Content-Type": type, "Cache-Control": "private, max-age=2592000, immutable",
      "X-Content-Type-Options": "nosniff", "Content-Security-Policy": "default-src 'none'",
    });
  });
}

/** A person's photos by where Google says they come from: [["contact"|"profile", url]], the primary first. */
export function contactPhotos(person) {
  const out = new Map();
  const photos = [...(person?.photos ?? [])].sort((a, b) => Number(Boolean(b?.metadata?.primary)) - Number(Boolean(a?.metadata?.primary)));
  for (const photo of photos) {
    if (!photo || photo.default || typeof photo.url !== "string") continue;
    const type = photo.metadata?.source?.type;
    const source = type === "CONTACT" ? "contact" : type === "PROFILE" ? "profile" : null;
    if (source && !out.has(source)) out.set(source, photo.url);
  }
  return [...out];
}
