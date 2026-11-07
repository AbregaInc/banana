// The shared cloud mailbox of one Google account (docs/design/MAIL-CLOUD-SYNC.md): what Gmail has
// told the service about each message, in order, and the feed the devices read it from. Metadata
// only: ids, thread ids, label ids, dates. Content is sealed in R2 by src/mailbox.js.
//
// Synchronous SQL over the same two-call port as src/space.js, {exec(sql, ...args) → rows,
// transaction(fn)}, so a Durable Object and node:sqlite both run it and nothing interleaves.
//
// The order rules (MAIL-ENGINE §2 invariants 1, 22, 23, 29; MAIL-BACKFILL-HISTORY-ORDER):
// - a history record applies to a message only if it is newer than what the message reflects;
// - a read replaces the label set only if it is not older;
// - a listing adds a membership only on a message with nothing newer than the scan's floor,
//   and never removes one: absence is a reason to read, never a removal;
// - a label set reaches the devices only once it is exact.

const DAY = 24 * 60 * 60 * 1000;
export const RETAIN_GONE = 30 * DAY;
export const FEED_MAX = 1000;
const SYSTEM_FIRST = ["INBOX", "UNREAD", "STARRED", "DRAFT", "SENT", "IMPORTANT"];
const SYSTEM_LAST = ["TRASH", "SPAM"];

const SCHEMA = [
  "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
  // hist: the newest history record or read reflected in labels. labels: JSON, sorted, or NULL
  // when nothing is known. known: the set is exact. seq: its place in the feed (0 = not yet
  // published). gone: Gmail said it was deleted (a tombstone, kept RETAIN_GONE). cached: bytes
  // of sealed content in R2 (0: none). first_gen: the scan generation that first saw it.
  `CREATE TABLE IF NOT EXISTS msg (id TEXT PRIMARY KEY, thread TEXT NOT NULL, hist INTEGER NOT NULL DEFAULT 0,
     labels TEXT, known INTEGER NOT NULL DEFAULT 0, date INTEGER, seq INTEGER NOT NULL DEFAULT 0,
     gone INTEGER NOT NULL DEFAULT 0, gone_at INTEGER, cached INTEGER NOT NULL DEFAULT 0, used_at INTEGER,
     first_gen INTEGER NOT NULL DEFAULT 0)`,
  "CREATE INDEX IF NOT EXISTS msg_seq ON msg (seq) WHERE seq > 0",
  "CREATE INDEX IF NOT EXISTS msg_gone ON msg (gone_at) WHERE gone = 1",
  "CREATE INDEX IF NOT EXISTS msg_cached ON msg (used_at) WHERE cached > 0",
  // The content fill walks what has no content yet, newest first. Gmail's ids grow with time, so
  // (length, id) descending is newest first without a date (which a listing does not give).
  "CREATE INDEX IF NOT EXISTS msg_fill ON msg (length(id), id) WHERE cached = 0 AND gone = 0",
  // (label, id) pairs the running scan listed; label '' is the listing of every message.
  "CREATE TABLE IF NOT EXISTS mark (label TEXT NOT NULL, id TEXT NOT NULL, PRIMARY KEY (label, id)) WITHOUT ROWID",
  // Messages to read one by one (minimal). prio 0: a device just changed it; 1: everything else.
  "CREATE TABLE IF NOT EXISTS verify (id TEXT PRIMARY KEY, prio INTEGER NOT NULL, reason TEXT NOT NULL, at INTEGER NOT NULL) WITHOUT ROWID",
  // Content to download before anyone asks: 0 the Inbox head, 1 new mail.
  "CREATE TABLE IF NOT EXISTS fetch (id TEXT PRIMARY KEY, prio INTEGER NOT NULL, at INTEGER NOT NULL) WITHOUT ROWID",
];

export function migrate(port) { for (const sql of SCHEMA) port.exec(sql); }

export function getMeta(port, key) { return port.exec("SELECT value FROM meta WHERE key = ?", key)[0]?.value ?? null; }
export function setMeta(port, key, value) {
  if (value === null || value === undefined) port.exec("DELETE FROM meta WHERE key = ?", key);
  else port.exec("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value", key, String(value));
}
const num = (value) => (value === null || value === undefined || value === "" ? null : Number(value));
const labelsOf = (row) => (row?.labels ? JSON.parse(row.labels) : []);
const json = (labels) => JSON.stringify([...new Set(labels)].sort());
const row = (port, id) => port.exec("SELECT * FROM msg WHERE id = ?", id)[0] ?? null;
/** A Gmail id or history number: digits for a history id; ids are short opaque text. */
const validID = (id) => typeof id === "string" && id.length > 0 && id.length <= 256 && !/[\x00-\x1f]/.test(id);

function nextSeq(port) {
  const n = Number(getMeta(port, "seq") ?? 0) + 1;
  setMeta(port, "seq", n);
  return n;
}
function publish(port, id) { port.exec("UPDATE msg SET seq = ? WHERE id = ?", nextSeq(port), id); }
export function generation(port) { return Number(getMeta(port, "gen") ?? 0); }
export function checkpoint(port) { return num(getMeta(port, "checkpoint")); }
export function scanState(port) { const s = getMeta(port, "scan"); return s ? JSON.parse(s) : null; }
export function complete(port) { return getMeta(port, "complete") !== null; }

/** Creates the mailbox's tables and identity once; afterwards checks it is the same account. */
export function ensure(port, { sub, email, account, epoch, now }) {
  migrate(port);
  return port.transaction(() => {
    const existing = getMeta(port, "sub");
    if (existing && existing !== sub) throw new Error("mailbox belongs to another identity");
    if (!existing) {
      setMeta(port, "sub", sub);
      setMeta(port, "epoch", epoch);
      setMeta(port, "created_at", now);
    }
    setMeta(port, "email", email.toLowerCase());
    setMeta(port, "account", account);
    return identity(port);
  });
}
export function identity(port) {
  return { sub: getMeta(port, "sub"), email: getMeta(port, "email"), account: getMeta(port, "account"), epoch: getMeta(port, "epoch") };
}

/** The scan order: the Inbox first, then what a person looks at, then the rest; INBOX and UNREAD
 * are listed a second time before the unlabelled listing, so a message that slid across a page
 * boundary while the first listing ran is still found. */
export function scanOrder(labels) {
  const ids = new Set(labels);
  const first = SYSTEM_FIRST.filter((l) => ids.has(l));
  const categories = [...ids].filter((l) => l.startsWith("CATEGORY_")).sort();
  const last = SYSTEM_LAST.filter((l) => ids.has(l));
  const rest = [...ids].filter((l) => !first.includes(l) && !last.includes(l) && !categories.includes(l)).sort();
  return [...first, ...categories, ...rest, ...last, ...["INBOX", "UNREAD"].filter((l) => ids.has(l)), ""];
}

/** The handshake (MAIL-ENGINE 5.3 step 1): the position is stored before any listing, so every
 * change made while listing is replayed from history. Starts a scan generation. */
export function begin(port, { historyId, labels, now }) {
  return port.transaction(() => {
    setMeta(port, "checkpoint", historyId);
    setMeta(port, "polled_at", now);
    setMeta(port, "labels", JSON.stringify(labels));
    const gen = generation(port) + 1;
    setMeta(port, "gen", gen);
    port.exec("DELETE FROM mark");
    const scan = { gen, floor: historyId, order: scanOrder(labels), index: 0, token: null, phase: "listing", after: 0, head: gen === 1 };
    setMeta(port, "scan", JSON.stringify(scan));
    return scan;
  });
}

/** History expired (Gmail's 404): forget the position; the next step handshakes and rescans. */
export function expire(port) {
  port.transaction(() => { setMeta(port, "checkpoint", null); setMeta(port, "scan", null); port.exec("DELETE FROM mark"); });
}

function queueVerify(port, id, reason, now, prio = 1) {
  port.exec(`INSERT INTO verify (id, prio, reason, at) VALUES (?, ?, ?, ?)
    ON CONFLICT (id) DO UPDATE SET prio = MIN(verify.prio, excluded.prio)`, id, prio, reason, now);
}
function queueFetch(port, id, prio, now) {
  port.exec("INSERT INTO fetch (id, prio, at) VALUES (?, ?, ?) ON CONFLICT (id) DO UPDATE SET prio = MIN(fetch.prio, excluded.prio)", id, prio, now);
}
export function verifyNext(port, { limit, prio = null }) {
  return prio === null
    ? port.exec("SELECT id, reason FROM verify ORDER BY prio, at, id LIMIT ?", limit)
    : port.exec("SELECT id, reason FROM verify WHERE prio <= ? ORDER BY prio, at, id LIMIT ?", prio, limit);
}
export function verifyDone(port, id) { port.exec("DELETE FROM verify WHERE id = ?", id); }
export function fetchNext(port, limit) { return port.exec("SELECT id FROM fetch ORDER BY prio, at, id LIMIT ?", limit).map((r) => r.id); }
export function fetchDone(port, id) { port.exec("DELETE FROM fetch WHERE id = ?", id); }
/** New mail (history added it) whose content is still owed. */
export function isNewMail(port, id) { return port.exec("SELECT 1 AS x FROM fetch WHERE id = ? AND prio = 1", id).length > 0; }

/** One page of Gmail history, applied from `start` (the stored checkpoint), which moves to the
 * page's last record, or to the response's own position after the final page. Returns the ids
 * whose stored content must go (Gmail deleted them). */
export function applyHistory(port, page, { start, now }) {
  const records = Array.isArray(page?.history) ? page.history : [];
  const end = num(page?.historyId);
  if (end === null || !Number.isFinite(end) || end < start || (page.nextPageToken && !records.length)
      || !records.every((r) => num(r?.id) > start && num(r.id) <= end)) throw new Error("history page invalid");
  return port.transaction(() => {
    if (checkpoint(port) !== start) throw new Error("checkpoint moved");
    const gen = generation(port);
    const dropContent = [];
    for (const record of records) {
      const h = num(record.id);
      for (const added of record.messagesAdded ?? []) {
        const m = added?.message;
        if (!validID(m?.id) || !validID(m.threadId)) continue;
        if (!row(port, m.id)) {
          // New mail: content is fetched now, and the read that brings it makes the labels exact.
          port.exec("INSERT INTO msg (id, thread, hist, labels, first_gen) VALUES (?, ?, ?, ?, ?)",
            m.id, m.threadId, h, Array.isArray(m.labelIds) ? json(m.labelIds) : null, gen);
          queueFetch(port, m.id, 1, now);
        }
      }
      for (const deleted of record.messagesDeleted ?? []) {
        const m = deleted?.message;
        if (!validID(m?.id)) continue;
        const r = row(port, m.id);
        if (!r) {
          // A device may hold it from before: say so in the feed.
          port.exec("INSERT INTO msg (id, thread, hist, gone, gone_at, first_gen) VALUES (?, ?, ?, 1, ?, ?)", m.id, validID(m.threadId) ? m.threadId : "", h, now, gen);
          publish(port, m.id);
        } else if (!r.gone && h > r.hist) {
          port.exec("UPDATE msg SET gone = 1, gone_at = ?, hist = ? WHERE id = ?", now, h, m.id);
          port.exec("DELETE FROM verify WHERE id = ?", m.id);
          port.exec("DELETE FROM fetch WHERE id = ?", m.id);
          if (r.cached) dropContent.push(m.id);
          publish(port, m.id);
        }
      }
      for (const [list, add] of [[record.labelsAdded, true], [record.labelsRemoved, false]]) {
        for (const change of list ?? []) {
          const m = change?.message, ids = change?.labelIds;
          if (!validID(m?.id) || !Array.isArray(ids)) continue;
          const r = row(port, m.id);
          if (!r) {
            // Unknown here: a stub that says something newer than any running scan's floor has
            // spoken for it (so a listing can't put back what this record took away), and a read.
            if (!validID(m.threadId)) continue;
            port.exec("INSERT INTO msg (id, thread, hist, labels, first_gen) VALUES (?, ?, ?, ?, ?)",
              m.id, m.threadId, h, json(add ? ids.filter(validID) : []), gen);
            queueVerify(port, m.id, "history", now);
            continue;
          }
          if (r.gone || h <= r.hist) continue;
          const labels = new Set(labelsOf(r));
          for (const l of ids) if (validID(l)) add ? labels.add(l) : labels.delete(l);
          port.exec("UPDATE msg SET labels = ?, hist = ? WHERE id = ?", json(labels), h, m.id);
          if (r.known) publish(port, m.id);
        }
      }
    }
    const next = page.nextPageToken ? num(records.at(-1).id) : end;
    setMeta(port, "checkpoint", next);
    setMeta(port, "polled_at", now);
    return { checkpoint: next, dropContent };
  });
}

/** One page of a listing (ids and thread ids). `floor` is the checkpoint when the scan began. With
 * `mark`, pairs are recorded for the close. Adds only. With `verifyOnly` (the periodic label check,
 * whose listing may lag Gmail's history) a difference is never applied, only read. */
export function applyListing(port, { label, ids, floor, now, mark = true, verifyOnly = false }) {
  return port.transaction(() => {
    const gen = generation(port);
    for (const listed of ids) {
      if (!validID(listed?.id) || !validID(listed.threadId)) continue;
      if (mark) port.exec("INSERT OR IGNORE INTO mark (label, id) VALUES (?, ?)", label, listed.id);
      const r = row(port, listed.id);
      if (!r) {
        port.exec("INSERT INTO msg (id, thread, hist, labels, first_gen) VALUES (?, ?, ?, ?, ?)",
          listed.id, listed.threadId, floor, json(label && !verifyOnly ? [label] : []), gen);
        if (verifyOnly) queueVerify(port, listed.id, "listing", now);
        continue;
      }
      if (r.gone || !label) continue;
      const labels = labelsOf(r);
      if (labels.includes(label)) continue;
      if (r.hist <= floor && !verifyOnly) {
        port.exec("UPDATE msg SET labels = ? WHERE id = ?", json([...labels, label]), listed.id);
        if (r.known) publish(port, listed.id);
      } else {
        // Something newer than this listing has spoken for the message: read it, don't guess.
        queueVerify(port, listed.id, "listing", now);
      }
    }
  });
}

/** One batch of the close (MAIL-ENGINE 5.3 step 4). A message that existed before this scan and
 * was not listed again under each of its labels is read, never removed. A message every listing
 * has now seen has its exact label set, and is published. Returns true when the close is done. */
export function closeBatch(port, { scan, now, limit = 500 }) {
  return port.transaction(() => {
    const rows = port.exec("SELECT rowid AS r, * FROM msg WHERE rowid > ? AND gone = 0 ORDER BY rowid LIMIT ?", scan.after, limit);
    const marked = (label, id) => port.exec("SELECT 1 AS x FROM mark WHERE label = ? AND id = ?", label, id).length > 0;
    for (const r of rows) {
      const listed = marked("", r.id);
      if (r.first_gen < scan.gen && r.hist <= scan.floor) {
        if (!listed || labelsOf(r).some((l) => !marked(l, r.id))) queueVerify(port, r.id, "close", now);
        continue;
      }
      if (r.known) continue;
      if (listed && r.hist <= scan.floor) {
        // Every listing since the floor has spoken, and nothing newer has: the set is exact.
        port.exec("UPDATE msg SET known = 1, labels = COALESCE(labels, '[]') WHERE id = ?", r.id);
        publish(port, r.id);
      } else if (r.hist > scan.floor && !port.exec("SELECT 1 AS x FROM fetch WHERE id = ?", r.id).length) {
        queueVerify(port, r.id, "close", now);   // history spoke after the floor: only a read makes it exact
      }
    }
    if (rows.length === limit) {
      setMeta(port, "scan", JSON.stringify({ ...scan, after: rows.at(-1).r }));
      return false;
    }
    port.exec("DELETE FROM mark");
    setMeta(port, "scan", null);
    setMeta(port, "complete", scan.gen);
    setMeta(port, "fill", null);   // the scan may have found more: the fill walks again from the newest
    return true;
  });
}

/** A per-message read (minimal, metadata or full). Missing labelIds in a per-message read means
 * no labels (MAIL-ENGINE 5.6). `floor` is the checkpoint when the request left: the read shows
 * Gmail at least that new, and Gmail's own `historyId` is the last record that changed the
 * message, so the read stands at the later of the two. Stale reads change nothing; a deleted id
 * is not stored again. */
export function applyRead(port, message, { floor, now }) {
  const h = Math.max(num(message?.historyId) ?? 0, floor ?? 0);
  if (!validID(message?.id) || !validID(message.threadId)) throw new Error("message invalid");
  const labels = Array.isArray(message.labelIds) ? message.labelIds.filter(validID) : [];
  const date = num(message.internalDate);
  return port.transaction(() => {
    const r = row(port, message.id);
    if (r?.gone) return { stale: true, gone: true };
    port.exec("DELETE FROM verify WHERE id = ?", message.id);
    if (!r) {
      port.exec("INSERT INTO msg (id, thread, hist, labels, known, date, first_gen) VALUES (?, ?, ?, ?, 1, ?, ?)",
        message.id, message.threadId, h, json(labels), date, generation(port));
      publish(port, message.id);
      return { stale: false };
    }
    if (h < r.hist) {
      if (r.date === null && date !== null) {
        port.exec("UPDATE msg SET date = ? WHERE id = ?", date, message.id);
        if (r.known) publish(port, message.id);
      }
      return { stale: true };
    }
    const next = json(labels);
    const changed = !r.known || r.labels !== next || (date !== null && r.date !== date);
    port.exec("UPDATE msg SET labels = ?, known = 1, hist = ?, date = COALESCE(?, date) WHERE id = ?", next, h, date, message.id);
    if (changed) publish(port, message.id);
    return { stale: false };
  });
}

/** Gmail's structured notFound for exactly this message id: a positive statement. */
export function applyGone(port, id, { now }) {
  return port.transaction(() => {
    port.exec("DELETE FROM verify WHERE id = ?", id);
    port.exec("DELETE FROM fetch WHERE id = ?", id);
    const r = row(port, id);
    if (r?.gone) return { cached: false };
    if (!r) port.exec("INSERT INTO msg (id, thread, gone, gone_at, first_gen) VALUES (?, '', 1, ?, ?)", id, now, generation(port));
    else port.exec("UPDATE msg SET gone = 1, gone_at = ? WHERE id = ?", now, id);
    publish(port, id);
    return { cached: Boolean(r?.cached) };
  });
}

/** After a device's action: read the message first, so the result reaches the other devices with
 * Gmail's own position for it. */
export function noteAction(port, ids, now) {
  port.transaction(() => { for (const id of ids) if (validID(id)) queueVerify(port, id, "action", now, 0); });
}

/** A device catching up from zero names what it holds that the feed never did: each is published
 * again if known, or read. */
export function check(port, ids, now) {
  return port.transaction(() => {
    let read = 0;
    for (const id of ids) {
      if (!validID(id)) continue;
      const r = row(port, id);
      if (r && (r.known || r.gone)) publish(port, id);
      else { queueVerify(port, id, "check", now); read++; }
    }
    return { read };
  });
}

/** The feed: each message once, at its latest published state, after `after`. A cursor names the
 * purge era it was issued in: one issued before tombstones it had not seen were purged (seq below
 * the horizon) can't be served; a walk from zero that began after the purge can. */
export function feed(port, { after, era = 0, limit }) {
  const horizon = Number(getMeta(port, "horizon") ?? 0), current = Number(getMeta(port, "era") ?? 0);
  if (after !== null && era < current && after < horizon) return { expired: true };
  const rows = port.exec("SELECT id, thread, hist, labels, date, gone, seq, cached FROM msg WHERE seq > ? ORDER BY seq LIMIT ?", after ?? 0, limit);
  const seq = rows.length ? rows.at(-1).seq : after ?? 0;
  return {
    epoch: getMeta(port, "epoch"),
    cursor: current ? `${seq}-${current}` : String(seq),
    more: rows.length === limit,
    complete: complete(port),
    entries: rows.map((r) => r.gone
      ? { id: r.id, history: String(r.hist), deleted: true }
      : { id: r.id, thread: r.thread, history: String(r.hist), date: r.date, labels: labelsOf(r), ...(r.cached > 0 ? { content: true } : {}) }),
  };
}

/** What a content request needs to know of one message. */
export function contentState(port, id) {
  const r = row(port, id);
  return r && { gone: Boolean(r.gone), cached: r.cached, known: Boolean(r.known), labels: labelsOf(r), history: r.hist, thread: r.thread, date: r.date };
}
/** Content is stored. A known message is published again, so the devices learn from the feed that
 * its content can be pulled from here (MAIL-CLOUD-SYNC §5). Returns whether it was published. */
export function markCached(port, id, bytes, now) {
  return port.transaction(() => {
    const r = row(port, id);
    port.exec("UPDATE msg SET cached = MAX(cached, ?), used_at = ? WHERE id = ?", bytes, now, id);
    if (!r || r.gone || r.cached > 0 || !r.known) return false;
    publish(port, id);
    return true;
  });
}
export function touch(port, id, now) { port.exec("UPDATE msg SET used_at = ? WHERE id = ? AND cached > 0", now, id); }
export function uncache(port, id) { port.exec("UPDATE msg SET cached = 0, used_at = NULL WHERE id = ?", id); }

/** Tombstones older than RETAIN_GONE go; a cursor from before them can't be served (410). Content
 * nobody has read for `unusedFor` is dropped. Returns the ids whose stored content must go. */
export function maintain(port, { now, unusedFor = 90 * DAY, limit = 500, keepSince = null }) {
  return port.transaction(() => {
    const gone = port.exec("SELECT id, seq, cached FROM msg WHERE gone = 1 AND gone_at < ? ORDER BY gone_at LIMIT ?", now - RETAIN_GONE, limit);
    const horizon = Math.max(Number(getMeta(port, "horizon") ?? 0), ...gone.map((r) => r.seq));
    for (const r of gone) port.exec("DELETE FROM msg WHERE id = ?", r.id);
    if (gone.length) { setMeta(port, "horizon", horizon); setMeta(port, "era", Number(getMeta(port, "era") ?? 0) + 1); }
    // Content the fill keeps (dated inside its window) is not "unused": dropping it would only
    // fetch it again. Older content nobody has read goes.
    const unused = port.exec(`SELECT id FROM msg WHERE cached > 0 AND used_at < ?
      AND NOT (? IS NOT NULL AND date IS NOT NULL AND date >= ?) ORDER BY used_at LIMIT ?`, now - unusedFor, keepSince, keepSince, limit);
    for (const r of unused) uncache(port, r.id);
    return [...gone.filter((r) => r.cached).map((r) => r.id), ...unused.map((r) => r.id)];
  });
}

/** Ids a complete listing of `label` did not name, among the messages stored with it and nothing
 * newer than `floor`: each is read (MAIL-ENGINE 5.8). */
export function checkLabelAbsence(port, { label, listed, floor, now }) {
  return port.transaction(() => {
    const rows = port.exec("SELECT id, labels, hist FROM msg WHERE gone = 0 AND known = 1 AND hist <= ? AND labels LIKE ?", floor, `%"${label}"%`);
    let queued = 0;
    for (const r of rows) if (labelsOf(r).includes(label) && !listed.has(r.id)) { queueVerify(port, r.id, "label-check", now); queued++; }
    return queued;
  });
}

export function status(port) {
  const counts = port.exec(`SELECT COUNT(*) AS messages, SUM(known) AS known, SUM(gone) AS gone, SUM(cached > 0) AS cached, SUM(cached) AS bytes,
    (SELECT COUNT(*) FROM verify) AS verify, (SELECT COUNT(*) FROM fetch) AS fetch FROM msg`)[0];
  const scan = scanState(port);
  return { ...identity(port), checkpoint: checkpoint(port), complete: complete(port), scanning: scan ? scan.phase : null,
    head: Number(getMeta(port, "seq") ?? 0), fill: fillState(port), watchExpires: num(getMeta(port, "watch_expires")), counts: Object.fromEntries(Object.entries(counts).map(([k, v]) => [k, Number(v ?? 0)])) };
}

// ---- the content fill (MAIL-CLOUD-SYNC §5) ----

/** Where the fill stands: `after` the last id it took (it walks down from there), `old` how many
 * in a row it read that were older than its window, `done` when it last reached the end. */
export function fillState(port) {
  const s = getMeta(port, "fill");
  return s ? JSON.parse(s) : { after: null, old: 0, done: null };
}
export function setFillState(port, state) { setMeta(port, "fill", JSON.stringify(state)); }

/** The next messages without content, newest first, below the watermark. Spam and Trash are not
 * filled; a message already dated before `since` is passed over without a read. */
export function fillNext(port, { after = null, limit = 1 }) {
  const below = after === null ? "" : "AND (length(id), id) < (length(?), ?)";
  const args = after === null ? [limit] : [after, after, limit];
  return port.exec(`SELECT id, date, labels FROM msg INDEXED BY msg_fill WHERE cached = 0 AND gone = 0 ${below}
    ORDER BY length(id) DESC, id DESC LIMIT ?`, ...args);
}
export const fillSkips = (r, since) =>
  (r.labels !== null && (labelsOf(r).includes("SPAM") || labelsOf(r).includes("TRASH"))) || (since !== null && r.date !== null && r.date < since);

/** Stored content for each id, as the bulk pull needs it: only messages this mailbox holds. */
export function contentStates(port, ids) {
  return ids.map((id) => ({ id, state: contentState(port, id) }));
}

/** Everything goes: the caller has removed the content first. */
export function drop(port) {
  for (const table of ["meta", "msg", "mark", "verify", "fetch"]) port.exec(`DROP TABLE IF EXISTS ${table}`);
}
