// mailgrdb — the store of MAIL-ENGINE.md §4 re-measured through GRDB 7.11.1 with the design's
// own schema and PRAGMAs (the first spike used the raw C API, 8 MB caches, auto-checkpoint on,
// a counter table and a different page query — perf review R-10).
//
//   swift build -c release --build-path <outside the worktree>
//   mailgrdb build <dir> [messages=200000]   index.sqlite + search.sqlite (own file) + intent.sqlite
//   mailgrdb read <dir> | under <dir> | act <dir> | search <dir> | open <dir> | check <dir>
//   mailgrdb prefix <dir> [messages=40000]   FTS5 size and 4-letter cost, prefix '2 3' against '2 3 4'
//
// Every section prints the 1-, 5- and 15-minute load averages beside its numbers.

import Foundation
import GRDB
import SQLite3

func load() -> String { var l = [Double](repeating: 0, count: 3); getloadavg(&l, 3); return String(format: "load %.1f %.1f %.1f", l[0], l[1], l[2]) }
func section(_ title: String) { print("\n== \(title) · \(load())") }
func line(_ label: String, _ samples: [Double]) {
    let s = samples.sorted(); guard !s.isEmpty else { return }
    func q(_ p: Double) -> Double { s[min(s.count - 1, Int(Double(s.count) * p))] }
    print(String(format: "  %@: n=%d p50 %.3f ms · p95 %.3f ms · p99 %.3f ms · max %.3f ms", label, s.count, q(0.5), q(0.95), q(0.99), s.last!))
}
func str(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }
func tie(_ threadPK: Int64) -> Int64 { var z = UInt64(bitPattern: threadPK) &* 0x9E3779B97F4A7C15; z ^= z >> 31; return Int64(z >> 1) }

// MARK: - The design's schema (§4.3) and connections (§4.2)

let indexSchema = """
CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
CREATE TABLE account(account_pk INTEGER PRIMARY KEY, email TEXT NOT NULL UNIQUE, checkpoint TEXT, profile_total INTEGER,
  enum_generation INTEGER NOT NULL DEFAULT 0, enum_checkpoint TEXT, enum_state TEXT, enum_completed_at INTEGER,
  headers_through INTEGER, bodies_through INTEGER, quota_state TEXT, last_sync_at INTEGER, last_sync_result TEXT,
  send_as TEXT, send_as_at INTEGER, labels_at INTEGER, removals TEXT);
CREATE TABLE label(label_pk INTEGER PRIMARY KEY, account_pk INTEGER NOT NULL, gmail_id TEXT NOT NULL, name TEXT NOT NULL,
  kind INTEGER NOT NULL, list_visibility TEXT, message_visibility TEXT, text_color TEXT, background_color TEXT,
  UNIQUE(account_pk, gmail_id));
CREATE INDEX label_by_name ON label(account_pk, name);
CREATE TABLE thread(thread_pk INTEGER PRIMARY KEY, account_pk INTEGER NOT NULL, gmail_id TEXT NOT NULL, tie INTEGER NOT NULL,
  last_date INTEGER NOT NULL DEFAULT 0, message_count INTEGER NOT NULL DEFAULT 0, fetched_count INTEGER NOT NULL DEFAULT 0,
  unread_count INTEGER NOT NULL DEFAULT 0, flags INTEGER NOT NULL DEFAULT 0, subject TEXT, snippet TEXT, people TEXT,
  people_total INTEGER NOT NULL DEFAULT 0, labels TEXT, wake_at INTEGER, returned_at INTEGER, waiting_until INTEGER,
  pending INTEGER NOT NULL DEFAULT 0, UNIQUE(account_pk, gmail_id));
CREATE TABLE message(msg_pk INTEGER PRIMARY KEY, account_pk INTEGER NOT NULL, gmail_id TEXT NOT NULL, thread_pk INTEGER NOT NULL,
  internal_date INTEGER NOT NULL DEFAULT 0, fetch_state INTEGER NOT NULL DEFAULT 0, fetch_class INTEGER NOT NULL DEFAULT 5,
  list_rank INTEGER NOT NULL DEFAULT 0, history_id TEXT, size_estimate INTEGER, flags INTEGER NOT NULL DEFAULT 0,
  vis INTEGER NOT NULL DEFAULT 0, body_kind INTEGER NOT NULL DEFAULT 0, prep_state INTEGER NOT NULL DEFAULT 0,
  fts_rowid INTEGER, fts_state INTEGER NOT NULL DEFAULT 0, fts_dirty INTEGER NOT NULL DEFAULT 0,
  from_addr TEXT, from_name TEXT, subject TEXT, snippet TEXT, recipients TEXT, rfc_message_id TEXT, list_id TEXT,
  auth_domain TEXT, UNIQUE(account_pk, gmail_id));
CREATE INDEX message_by_thread ON message(thread_pk, internal_date);
CREATE UNIQUE INDEX message_by_fts ON message(fts_rowid) WHERE fts_rowid IS NOT NULL;
CREATE INDEX message_stub_queue ON message(account_pk, fetch_class, list_rank) WHERE fetch_state = 0;
CREATE INDEX message_body_queue ON message(account_pk, fetch_class, internal_date DESC) WHERE fetch_state = 1;
CREATE INDEX message_prep_queue ON message(internal_date DESC) WHERE fetch_state = 2 AND prep_state = 0;
CREATE INDEX message_fts_queue ON message(internal_date DESC) WHERE fts_dirty = 1;
CREATE INDEX message_by_rfc_id ON message(rfc_message_id) WHERE rfc_message_id IS NOT NULL;
CREATE TABLE message_label(msg_pk INTEGER NOT NULL, label_pk INTEGER NOT NULL, PRIMARY KEY(msg_pk, label_pk)) WITHOUT ROWID;
CREATE INDEX message_label_by_label ON message_label(label_pk, msg_pk);
CREATE TABLE overlay(msg_pk INTEGER NOT NULL, label_pk INTEGER NOT NULL, want INTEGER NOT NULL, derived INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(msg_pk, label_pk)) WITHOUT ROWID;
CREATE TABLE enum_mark(account_pk INTEGER NOT NULL, generation INTEGER NOT NULL, label_pk INTEGER NOT NULL, msg_pk INTEGER NOT NULL,
  PRIMARY KEY(account_pk, generation, label_pk, msg_pk)) WITHOUT ROWID;
CREATE TABLE verify_queue(msg_pk INTEGER PRIMARY KEY, reason INTEGER NOT NULL, generation INTEGER NOT NULL, queued_at INTEGER NOT NULL,
  outcome INTEGER);
CREATE TABLE held_removal(msg_pk INTEGER PRIMARY KEY, evidence INTEGER NOT NULL, found_at INTEGER NOT NULL, kept INTEGER NOT NULL DEFAULT 0);
CREATE TABLE tombstone(account_pk INTEGER NOT NULL, gmail_id TEXT NOT NULL, at INTEGER NOT NULL, PRIMARY KEY(account_pk, gmail_id)) WITHOUT ROWID;
CREATE TABLE view(view_pk INTEGER PRIMARY KEY, key TEXT NOT NULL UNIQUE, kind INTEGER NOT NULL, account_pk INTEGER, label_pk INTEGER,
  definition TEXT, definition_rev INTEGER NOT NULL DEFAULT 0, built_rev INTEGER NOT NULL DEFAULT 0);
CREATE TABLE view_thread(view_pk INTEGER NOT NULL, sort_key INTEGER NOT NULL, tie INTEGER NOT NULL, thread_pk INTEGER NOT NULL,
  unread INTEGER NOT NULL, PRIMARY KEY(view_pk, sort_key, tie)) WITHOUT ROWID;
CREATE INDEX view_thread_unread ON view_thread(view_pk) WHERE unread = 1;
CREATE INDEX view_thread_by_thread ON view_thread(thread_pk, view_pk);
CREATE TABLE correspondent(addr TEXT PRIMARY KEY, name TEXT, sent INTEGER NOT NULL DEFAULT 0, received INTEGER NOT NULL DEFAULT 0,
  last_date INTEGER NOT NULL DEFAULT 0) WITHOUT ROWID;
CREATE TABLE correspondent_key(key TEXT NOT NULL, addr TEXT NOT NULL, PRIMARY KEY(key, addr)) WITHOUT ROWID;
"""
let ftsSchema = "CREATE VIRTUAL TABLE msg_fts USING fts5(subject, sender, recipients, body, attachments, content='', contentless_delete=1, tokenize='unicode61 remove_diacritics 2', prefix='2 3', detail=full)"
let intentSchema = """
CREATE TABLE label_intent(account TEXT NOT NULL, gmail_msg_id TEXT NOT NULL, label_ref TEXT NOT NULL, want INTEGER NOT NULL,
  seq INTEGER NOT NULL, sent_seq INTEGER, group_id TEXT NOT NULL, origin INTEGER NOT NULL DEFAULT 0, state INTEGER NOT NULL DEFAULT 0,
  attempts INTEGER NOT NULL DEFAULT 0, next_attempt_at INTEGER, error_code TEXT, created_at INTEGER NOT NULL, delivered_at INTEGER,
  PRIMARY KEY(account, gmail_msg_id, label_ref)) WITHOUT ROWID;
CREATE INDEX label_intent_by_state ON label_intent(state, account, seq);
"""
let pageSQL = """
SELECT t.thread_pk, t.account_pk, t.gmail_id, v.sort_key, v.tie, v.unread, t.message_count, t.flags,
       t.subject, t.snippet, t.people, t.people_total, t.labels, t.wake_at, t.returned_at, t.waiting_until, t.pending
FROM view_thread v JOIN thread t ON t.thread_pk = v.thread_pk
WHERE v.view_pk = ?1 AND v.sort_key > 0 AND (v.sort_key, v.tie) < (?2, ?3)
ORDER BY v.sort_key DESC, v.tie DESC LIMIT ?4
"""

struct Stores {
    let index: DatabasePool, intent: DatabaseQueue, searchWriter: DatabaseQueue, searchReader: DatabaseQueue
    init(dir: String, create: Bool) throws {
        // index.sqlite: one writer, two readers, 4 MB caches, NORMAL, auto-checkpoint off.
        var ic = Configuration(); ic.foreignKeysEnabled = false; ic.maximumReaderCount = 2; ic.label = "mail.index"
        ic.prepareDatabase { db in
            try db.execute(sql: "PRAGMA temp_store=MEMORY; PRAGMA cache_size=-4096; PRAGMA busy_timeout=2000")
            if !db.configuration.readonly { try db.execute(sql: "PRAGMA wal_autocheckpoint=0") }
        }
        index = try DatabasePool(path: dir + "/index.sqlite", configuration: ic)
        // intent.sqlite: one connection, 1 MB, FULL + fullfsync — set AFTER opening (GRDB resets synchronous).
        var nc = Configuration(); nc.journalMode = .wal; nc.label = "mail.intent"
        nc.prepareDatabase { db in try db.execute(sql: "PRAGMA cache_size=-1024; PRAGMA wal_autocheckpoint=0; PRAGMA busy_timeout=2000") }
        intent = try DatabaseQueue(path: dir + "/intent.sqlite", configuration: nc)
        try intent.writeWithoutTransaction { try $0.execute(sql: "PRAGMA synchronous=FULL; PRAGMA fullfsync=ON") }
        // search.sqlite: its own writer; a read-only connection with the index attached, 8 MB.
        var sc = Configuration(); sc.journalMode = .wal; sc.label = "mail.indexer"
        sc.prepareDatabase { db in try db.execute(sql: "PRAGMA temp_store=MEMORY; PRAGMA cache_size=-4096; PRAGMA wal_autocheckpoint=0") }
        searchWriter = try DatabaseQueue(path: dir + "/search.sqlite", configuration: sc)
        if create {
            try index.write { try $0.execute(sql: indexSchema) }
            try intent.write { try $0.execute(sql: intentSchema) }
            try searchWriter.write { try $0.execute(sql: ftsSchema) }
        }
        var rc = Configuration(); rc.readonly = true; rc.label = "mail.read.search"
        rc.prepareDatabase { db in
            try db.execute(sql: "PRAGMA temp_store=MEMORY; PRAGMA cache_size=-8192")
            try db.execute(sql: "ATTACH DATABASE ? AS idx", arguments: [dir + "/index.sqlite"])
        }
        searchReader = try DatabaseQueue(path: dir + "/search.sqlite", configuration: rc)
    }
}

// MARK: - Writing a batch the way sync will (rows, exact label sets, summary, view rows)

func writeThreads(_ db: Database, _ threads: [[Msg]], gen: inout Generator, fts: inout [(Int64, Msg)]) throws {
    let t = try db.cachedStatement(sql: "INSERT INTO thread(thread_pk, account_pk, gmail_id, tie, last_date, message_count, fetched_count, unread_count, flags, subject, snippet, people, people_total, labels) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)")
    let m = try db.cachedStatement(sql: "INSERT INTO message(msg_pk, account_pk, gmail_id, thread_pk, internal_date, fetch_state, fetch_class, history_id, size_estimate, flags, vis, body_kind, prep_state, fts_rowid, fts_dirty, from_addr, from_name, subject, snippet, recipients, rfc_message_id) VALUES(?,?,?,?,?,2,?,?,?,?,?,1,2,?,1,?,?,?,?,?,?)")
    let l = try db.cachedStatement(sql: "INSERT INTO message_label(msg_pk, label_pk) VALUES(?,?)")
    let v = try db.cachedStatement(sql: "INSERT INTO view_thread(view_pk, sort_key, tie, thread_pk, unread) VALUES(?,?,?,?,?)")
    for msgs in threads {
        let s = summarise(msgs), first = msgs[0], tk = tie(first.threadPK)
        try t.execute(arguments: [first.threadPK, first.account + 1, String(format: "%016llx", UInt64(first.threadPK) &* 0x9E3779B97F4A7C15), tk,
                                  s.lastDate, s.count, msgs.count, s.unread, 0, str(first.subject), str(msgs.last!.snippet),
                                  "[{\"n\":\"\(str(gen.people[first.from].name))\",\"a\":\"\(str(gen.people[first.from].addr))\",\"u\":false}]", 1,
                                  "," + s.labels.sorted().map { String(labelPK(first.account, $0)) }.joined(separator: ",") + ","])
        for msg in msgs {
            let rowid = gen.ftsRowid(dateMs: msg.date)
            try m.execute(arguments: [msg.pk, msg.account + 1, String(format: "%016llx", UInt64(msg.pk) &* 0xD6E8FEB86659FD93), msg.threadPK, msg.date,
                                      msg.labels.contains(0) ? 0 : 2, String(msg.pk * 7), msg.body.count * 12, msg.fromMe ? 1 : 0,
                                      msg.labels.contains(6) ? 1 : (msg.labels.contains(7) ? 2 : 0), rowid,
                                      str(gen.people[msg.from].addr), str(gen.people[msg.from].name), str(msg.subject), str(msg.snippet),
                                      "{\"to\":[\"\(str(gen.people[msg.to].addr))\"]}", "<\(msg.pk)@example.com>"])
            for label in msg.labels { try l.execute(arguments: [msg.pk, labelPK(msg.account, label)]) }
            fts.append((rowid, msg))
        }
        for (view, e) in s.memberships { try v.execute(arguments: [view, e.sort, tk, first.threadPK, e.unread ? 1 : 0]) }
    }
}
func writeFTS(_ db: Database, _ rows: [(Int64, Msg)], gen: Generator) throws {
    let f = try db.cachedStatement(sql: "INSERT OR REPLACE INTO msg_fts(rowid, subject, sender, recipients, body, attachments) VALUES(?,?,?,?,?,'')")
    for (rowid, msg) in rows {
        try f.execute(arguments: [rowid, str(msg.subject), str(gen.people[msg.from].name) + " " + str(gen.people[msg.from].addr), str(gen.people[msg.to].addr), str(msg.body)])
    }
}
func nextBatch(_ gen: inout Generator, messages: Int, recency: Double) -> [[Msg]] {
    var out: [[Msg]] = [], n = 0
    while n < messages { let t = gen.thread(recency: recency); out.append(t); n += t.count }
    return out
}
func size(_ path: String) -> String { mb(fileSize(path)) }

func build(dir: String, messages: Int) throws {
    try? FileManager.default.removeItem(atPath: dir)
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let s = try Stores(dir: dir, create: true)
    section("build \(messages) messages, newest first, 50 per index transaction, FTS in its own file")
    print("  pragmas read back — index writer: journal \(try s.index.writeWithoutTransaction { try String.fetchOne($0, sql: "PRAGMA journal_mode")! }), synchronous \(try s.index.writeWithoutTransaction { try Int.fetchOne($0, sql: "PRAGMA synchronous")! }), wal_autocheckpoint \(try s.index.writeWithoutTransaction { try Int.fetchOne($0, sql: "PRAGMA wal_autocheckpoint")! }), cache_size \(try s.index.writeWithoutTransaction { try Int.fetchOne($0, sql: "PRAGMA cache_size")! }); intent: synchronous \(try s.intent.read { try Int.fetchOne($0, sql: "PRAGMA synchronous")! }), fullfsync \(try s.intent.read { try Int.fetchOne($0, sql: "PRAGMA fullfsync")! })")
    var gen = Generator()
    try s.index.write { db in
        for a in 0..<accountWeights.count {
            try db.execute(sql: "INSERT INTO account(account_pk, email, checkpoint) VALUES(?,?,?)", arguments: [a + 1, "account\(a)@example.com", "1000"])
            for l in 0..<labelsPerAccount {
                try db.execute(sql: "INSERT INTO label(label_pk, account_pk, gmail_id, name, kind) VALUES(?,?,?,?,?)",
                               arguments: [labelPK(a, l), a + 1, l < systemLabels.count ? systemLabels[l] : "Label_\(l)", l < systemLabels.count ? systemLabels[l] : "Project/\(l)", l < systemLabels.count ? 0 : 1])
            }
        }
        for p in gen.people {
            try db.execute(sql: "INSERT OR IGNORE INTO correspondent(addr, name, sent, received) VALUES(?,?,1,1)", arguments: [str(p.addr), str(p.name)])
            let name = str(p.name).lowercased(), addr = str(p.addr)
            var keys = name.split(separator: " ").map(String.init); keys.append(addr)
            if let at = addr.firstIndex(of: "@") { keys.append(String(addr[addr.index(after: at)...])) }
            for k in keys { try db.execute(sql: "INSERT OR IGNORE INTO correspondent_key(key, addr) VALUES(?,?)", arguments: [k, addr]) }
        }
    }
    var done = 0, threads = 0, indexTimes: [Double] = [], ftsTimes: [Double] = [], text: Int64 = 0
    let estimated = Int(Double(messages) / 2.49), t0 = now()
    var sinceCheckpoint = 0
    while done < messages {
        var batch: [[Msg]] = [], n = 0
        while n < 50 { let recency = max(0, 1 - Double(threads) / Double(estimated)); let t = gen.thread(recency: pow(recency, 0.7)); batch.append(t); n += t.count; threads += 1 }
        for t in batch { for m in t { text += Int64(m.body.count + m.subject.count) } }
        var fts: [(Int64, Msg)] = []
        var a = now(); try s.index.write { db in try writeThreads(db, batch, gen: &gen, fts: &fts) }; indexTimes.append(ms(a, now()))
        a = now(); let g = gen; try s.searchWriter.write { db in try writeFTS(db, fts, gen: g) }; ftsTimes.append(ms(a, now()))
        done += n; sinceCheckpoint += n
        if sinceCheckpoint >= 2000 {   // the writer checkpoints when idle and its log is over 8 MB; here: every 2,000 messages
            try s.index.writeWithoutTransaction { try $0.checkpoint(.passive) }; try s.searchWriter.writeWithoutTransaction { try $0.checkpoint(.passive) }; sinceCheckpoint = 0
        }
    }
    let total = ms(t0, now()) / 1000
    try s.index.writeWithoutTransaction { try $0.checkpoint(.truncate) }; try s.searchWriter.writeWithoutTransaction { try $0.checkpoint(.truncate) }
    print(String(format: "  %d messages in %d conversations, %.1f MB of indexed text, %.1f s in all · %@", done, threads, Double(text) / 1_048_576, total, load()))
    line("index transaction of ~50 messages (GRDB, cached statements, explicit checkpoints)", indexTimes)
    line("search transaction of the same ~50 messages (FTS5, own file)", ftsTimes)
    print("  index.sqlite \(size(dir + "/index.sqlite")) · search.sqlite \(size(dir + "/search.sqlite")) (\(Int(Double(fileSize(dir + "/search.sqlite")) / Double(text) * 100)) % of the text)")
    try s.index.read { db in
        print("  rows: message \(try Int.fetchOne(db, sql: "SELECT count(*) FROM message")!) · thread \(try Int.fetchOne(db, sql: "SELECT count(*) FROM thread")!) · message_label \(try Int.fetchOne(db, sql: "SELECT count(*) FROM message_label")!) · view_thread \(try Int.fetchOne(db, sql: "SELECT count(*) FROM view_thread")!)")
        for row in try Row.fetchAll(db, sql: "SELECT name, sum(pgsize) FROM dbstat GROUP BY name ORDER BY 2 DESC LIMIT 8") { print("    \(row[0] as String): \(mb(row[1]))") }
    }
}

// MARK: - Reads through the pool

func page(_ db: Database, view: Int64, before: (Int64, Int64) = (.max, .max), limit: Int = 50) throws -> (Int, (Int64, Int64)) {
    let st = try db.cachedStatement(sql: pageSQL)
    let rows = try Row.fetchCursor(st, arguments: [view, before.0, before.1, limit])
    var n = 0, last = before
    while let r = try rows.next() {
        n += 1; last = (r[3], r[4])
        let _: String? = r[8]; let _: String? = r[9]; let _: String? = r[10]; let _: String? = r[12]
    }
    return (n, last)
}
func read(dir: String) throws {
    let s = try Stores(dir: dir, create: false)
    section("reads through DatabasePool.read (4 MB cache, the design's page query)")
    try s.index.read { db in
        for r in try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + pageSQL, arguments: [1, 9, 9, 50]) { print("  plan: \(r[3] as String)") }
        for r in try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN SELECT count(*) FROM view_thread WHERE view_pk = 9001 AND unread = 1") { print("  count plan: \(r[3] as String)") }
        for r in try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN SELECT thread_pk FROM view_thread WHERE view_pk = 9001 AND unread = 1 AND sort_key > 0 ORDER BY sort_key DESC, tie DESC LIMIT 50") { print("  unread-only page plan: \(r[3] as String)") }
    }
    for (name, view) in [("unified inbox", unifiedViewPK(0)), ("unified all mail", unifiedAllMail), ("a user label", labelPK(0, 20))] {
        var t: [Double] = []
        for _ in 0..<300 { let a = now(); _ = try s.index.read { try page($0, view: view) }; t.append(ms(a, now())) }
        line("\(name), first 50", t)
    }
    var walk: [Double] = [], cursor: (Int64, Int64) = (.max, .max), pages = 0, total = 0
    while true {
        let a = now(); let r = try s.index.read { try page($0, view: unifiedAllMail, before: cursor) }; walk.append(ms(a, now()))
        total += r.0; pages += 1; if r.0 < 50 { break }; cursor = r.1
    }
    line("keyset walk of all mail, \(pages) pages, \(total) conversations", walk)
    for limit in [400, 2000] {
        var t: [Double] = []
        for _ in 0..<40 { let a = now(); _ = try s.index.read { try page($0, view: unifiedAllMail, limit: limit) }; t.append(ms(a, now())) }
        line("one read of the newest \(limit) rows of all mail", t)
    }
    var c1: [Double] = [], c12: [Double] = [], ct: [Double] = [], unreadN = 0
    let twelve = [unifiedViewPK(0), unifiedViewPK(2), unifiedViewPK(3), unifiedViewPK(10), unifiedViewPK(11), splitVIP, splitNews, splitOther, labelPK(0, 0), labelPK(1, 0), labelPK(2, 0), labelPK(3, 0)]
    for _ in 0..<300 {
        var a = now(); unreadN = try s.index.read { try Int.fetchOne($0.cachedStatement(sql: "SELECT count(*) FROM view_thread WHERE view_pk = ? AND unread = 1"), arguments: [unifiedAllMail])! }; c1.append(ms(a, now()))
        a = now(); try s.index.read { db in let st = try db.cachedStatement(sql: "SELECT count(*) FROM view_thread WHERE view_pk = ? AND unread = 1"); for v in twelve { _ = try Int.fetchOne(st, arguments: [v]) } }; c12.append(ms(a, now()))
        a = now(); _ = try s.index.read { try Int.fetchOne($0.cachedStatement(sql: "SELECT count(*) FROM view_thread WHERE view_pk = ? AND sort_key > 0"), arguments: [unifiedAllMail]) }; ct.append(ms(a, now()))
    }
    line("unread count, all mail (\(unreadN) unread), partial index", c1); line("unread counts for twelve views, one read", c12); line("total count of all mail", ct)
    var conv: [Double] = []; var rng = RNG(7)
    let maxThread = try s.index.read { try Int.fetchOne($0, sql: "SELECT max(thread_pk) FROM thread")! }
    for _ in 0..<2000 {
        let tpk = 1 + rng.int(maxThread); let a = now()
        try s.index.read { db in
            let m = try Row.fetchCursor(db.cachedStatement(sql: "SELECT msg_pk, gmail_id, internal_date, flags, body_kind, from_addr, from_name, subject, snippet, recipients FROM message WHERE thread_pk = ? ORDER BY internal_date"), arguments: [tpk])
            while let r = try m.next() { let _: String? = r[8] }
            let l = try Row.fetchCursor(db.cachedStatement(sql: "SELECT ml.msg_pk, ml.label_pk FROM message m JOIN message_label ml ON ml.msg_pk = m.msg_pk WHERE m.thread_pk = ?"), arguments: [tpk]); while try l.next() != nil {}
            let o = try Row.fetchCursor(db.cachedStatement(sql: "SELECT o.msg_pk, o.label_pk, o.want FROM message m JOIN overlay o ON o.msg_pk = m.msg_pk WHERE m.thread_pk = ?"), arguments: [tpk]); while try o.next() != nil {}
        }
        conv.append(ms(a, now()))
    }
    line("a conversation's rows, labels and overlay (2,000 at random)", conv)
    var ac: [Double] = []
    for prefix in ["br", "sha", "stou", "example", "chea", "plo", "gr", "news"] { for _ in 0..<40 {
        let a = now(); try s.index.read { db in let c = try Row.fetchCursor(db.cachedStatement(sql: "SELECT c.addr, c.name, c.sent FROM correspondent_key k JOIN correspondent c ON c.addr = k.addr WHERE k.key >= ? AND k.key < ? ORDER BY c.sent DESC, c.last_date DESC LIMIT 8"), arguments: [prefix, prefix + "\u{10FFFF}"]); while try c.next() != nil {} }
        ac.append(ms(a, now())) } }
    line("recipient lookup, two or more letters, 30,000 addresses", ac)
    // The first-frame file: 50 rows.
    struct Row50: Codable { var thread: String; var account: String; var sortKey: Int64; var tie: Int64; var unread: Bool; var count: Int; var subject: String; var snippet: String; var people: String; var labels: [String] }
    let rows: [Row50] = try s.index.read { db in try Row.fetchAll(db, sql: pageSQL, arguments: [unifiedViewPK(0), Int64.max, Int64.max, 50]).map { r in
        Row50(thread: r[2], account: "account0@example.com", sortKey: r[3], tie: r[4], unread: (r[5] as Int) == 1, count: r[6], subject: r[8] ?? "", snippet: r[9] ?? "", people: r[10] ?? "", labels: ["Label_20"]) } }
    let url = URL(fileURLWithPath: dir + "/first-page.json"); let data = try JSONEncoder().encode(rows); try data.write(to: url, options: .atomic)
    var snap: [Double] = []
    for _ in 0..<300 { let a = now(); _ = try JSONDecoder().decode([Row50].self, from: Data(contentsOf: url)); snap.append(ms(a, now())) }
    line("first-page.json, \(rows.count) rows, \(data.count) bytes: read and decode", snap)
}

// MARK: - A reader while sync writes (R-11): batches of 50 and of 20

func under(dir: String) throws {
    let s = try Stores(dir: dir, create: false)
    var gen = Generator(); gen.rng = RNG(0xFEED)
    gen.nextThread = try s.index.read { try Int64.fetchOne($0, sql: "SELECT max(thread_pk) FROM thread")! } + 1
    gen.nextMsg = try s.index.read { try Int64.fetchOne($0, sql: "SELECT max(msg_pk) FROM message")! } + 1
    for batchSize in [50, 20] {
        section("a list reader while sync writes transactions of \(batchSize) messages for 8 s (no FTS in this file)")
        var readerTimes: [Double] = [], running = true; let lock = NSLock(); let group = DispatchGroup(); group.enter()
        DispatchQueue.global(qos: .userInteractive).async {
            while true { lock.lock(); let go = running; lock.unlock(); if !go { break }
                let a = now(); _ = try? s.index.read { try page($0, view: unifiedAllMail) }; readerTimes.append(ms(a, now())); usleep(2000) }
            group.leave()
        }
        var writerTimes: [Double] = [], prepared: [[[Msg]]] = []
        for _ in 0..<400 { var b = nextBatch(&gen, messages: batchSize, recency: 0.2 + gen.rng.unit() * 0.6); for i in b.indices { for j in b[i].indices { b[i][j].date += Int64(gen.rng.int(900_000)) + 13 } }; prepared.append(b) }
        let t0 = now(); var i = 0, wal: Int64 = 0
        while ms(t0, now()) < 8000, i < prepared.count {
            var fts: [(Int64, Msg)] = []; let a = now()
            try s.index.write { db in try writeThreads(db, prepared[i], gen: &gen, fts: &fts) }
            writerTimes.append(ms(a, now())); i += 1; wal = max(wal, fileSize(dir + "/index.sqlite-wal")); usleep(1000)
        }
        lock.lock(); running = false; lock.unlock(); group.wait()
        line("writer: one transaction of \(batchSize)", writerTimes); line("reader: first 50 of all mail", readerTimes)
        let a = now(); try s.index.writeWithoutTransaction { try $0.checkpoint(.passive) }
        print(String(format: "  log reached %@; passive checkpoint %.1f ms", mb(wal), ms(a, now())))
    }
}

// MARK: - An action: the intent commit (full fsync), then the index write-through

func act(dir: String) throws {
    let s = try Stores(dir: dir, create: false)
    section("an action, as §6.4 writes it: intent first (FULL + fullfsync), then overlay + thread + view rows")
    let targets: [(Int64, Int64, Int64, Int, Int)] = try s.index.read { db in
        try Row.fetchAll(db, sql: "SELECT v.thread_pk, v.sort_key, v.tie, t.account_pk, v.unread FROM view_thread v JOIN thread t ON t.thread_pk = v.thread_pk WHERE v.view_pk = ? ORDER BY v.sort_key DESC LIMIT 1200", arguments: [unifiedViewPK(0)]).map { ($0[0], $0[1], $0[2], ($0[3] as Int) - 1, $0[4]) } }
    var intentT: [Double] = [], indexT: [Double] = [], both: [Double] = []; var seq = 0
    for t in targets.prefix(1000) {
        let ids: [Int64] = try s.index.read { try Int64.fetchAll($0.cachedStatement(sql: "SELECT m.msg_pk FROM message m JOIN message_label ml ON ml.msg_pk = m.msg_pk WHERE m.thread_pk = ? AND ml.label_pk = ?"), arguments: [t.0, labelPK(t.3, 0)]) }
        let a = now()
        try s.intent.write { db in
            let st = try db.cachedStatement(sql: "INSERT OR REPLACE INTO label_intent(account, gmail_msg_id, label_ref, want, seq, group_id, created_at) VALUES(?,?,?,?,?,?,?)")
            for id in ids { seq += 1; try st.execute(arguments: ["account\(t.3)@example.com", String(format: "%016llx", id), "INBOX", 0, seq, "g\(t.0)", seq]) }
        }
        let b = now()
        try s.index.write { db in
            let o = try db.cachedStatement(sql: "INSERT OR REPLACE INTO overlay(msg_pk, label_pk, want) VALUES(?,?,0)")
            for id in ids { try o.execute(arguments: [id, labelPK(t.3, 0)]) }
            try db.cachedStatement(sql: "UPDATE thread SET labels = replace(labels, ?, ','), pending = 1 WHERE thread_pk = ?").execute(arguments: [",\(labelPK(t.3, 0)),", t.0])
            let d = try db.cachedStatement(sql: "DELETE FROM view_thread WHERE thread_pk = ? AND view_pk = ?")
            for view in [unifiedViewPK(0), labelPK(t.3, 0), splitVIP, splitNews, splitOther] { try d.execute(arguments: [t.0, view]) }
        }
        let c = now(); intentT.append(ms(a, b)); indexT.append(ms(b, c)); both.append(ms(a, c))
    }
    line("intent commit (1–60 assertions, full fsync, through GRDB)", intentT)
    line("index write-through (overlay, thread row, five view rows)", indexT)
    line("both: accepted → durable and in the index", both)
    print("  index log after 1,000 actions: \(size(dir + "/index.sqlite-wal")); intent log: \(size(dir + "/intent.sqlite-wal"))")
    var a = now(); try s.index.writeWithoutTransaction { try $0.checkpoint(.passive) }; print(String(format: "  passive checkpoint of that index log: %.1f ms", ms(a, now())))
    a = now(); try s.intent.writeWithoutTransaction { try $0.checkpoint(.passive) }; print(String(format: "  passive checkpoint of the intent log: %.1f ms", ms(a, now())))
    // Group commit: what one commit costs when it carries everything that arrived during the last one.
    for k in [1, 5, 20, 50] {
        var t: [Double] = []
        for _ in 0..<60 { let a = now(); try s.intent.write { db in
            let st = try db.cachedStatement(sql: "INSERT OR REPLACE INTO label_intent(account, gmail_msg_id, label_ref, want, seq, group_id, created_at) VALUES(?,?,?,?,?,?,?)")
            for _ in 0..<(k * 3) { seq += 1; try st.execute(arguments: ["account0@example.com", "x\(seq)", "INBOX", 0, seq, "grp", seq]) } }
            t.append(ms(a, now())) }
        line("one intent commit carrying \(k) action(s) of three assertions", t)
    }
    // Deleting messages: row, labels, view rows; the FTS entry separately.
    let victims: [(Int64, Int64)] = try s.index.read { try Row.fetchAll($0, sql: "SELECT msg_pk, fts_rowid FROM message ORDER BY msg_pk DESC LIMIT 1000").map { ($0[0], $0[1]) } }
    var del: [Double] = [], delF: [Double] = [], k = 0
    while k + 50 <= victims.count {
        let chunk = Array(victims[k..<(k + 50)]); var a = now()
        try s.index.write { db in for (pk, _) in chunk { try db.cachedStatement(sql: "DELETE FROM message_label WHERE msg_pk = ?").execute(arguments: [pk]); try db.cachedStatement(sql: "DELETE FROM message WHERE msg_pk = ?").execute(arguments: [pk]) } }
        del.append(ms(a, now())); a = now()
        try s.searchWriter.write { db in for (_, f) in chunk { try db.cachedStatement(sql: "DELETE FROM msg_fts WHERE rowid = ?").execute(arguments: [f]) } }
        delF.append(ms(a, now())); k += 50
    }
    line("delete 50 messages from the index", del); line("delete their 50 entries from search.sqlite", delF)
}

// MARK: - Search on its own read-only connection, the index attached

func search(dir: String) throws {
    let s = try Stores(dir: dir, create: false)
    var r = RNG(42); let vocab = Vocab(count: 120_000, rng: &r)
    func w(_ rank: Int) -> String { str(vocab.words[rank]) }
    let sql = "SELECT m.thread_pk, m.msg_pk FROM msg_fts f JOIN idx.message m ON m.fts_rowid = f.rowid WHERE f.msg_fts MATCH ? AND m.vis = 0 ORDER BY f.rowid DESC LIMIT 400"
    section("search: read-only DatabaseQueue on search.sqlite (8 MB), index.sqlite attached; newest 50 conversations")
    try s.searchReader.read { db in for row in try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql, arguments: ["abc"]) { print("  plan: \(row[3] as String)") } }
    func one(_ match: String) throws -> Double {
        let a = now()
        try s.searchReader.read { db in let c = try Row.fetchCursor(db.cachedStatement(sql: sql), arguments: [match]); var seen = Set<Int64>(); while seen.count < 50, let row = try c.next() { seen.insert(row[0]) } }
        return ms(a, now())
    }
    func many(_ label: String, _ matches: [String], repeats: Int = 3) throws { var t: [Double] = []; for m in matches { for _ in 0..<repeats { t.append(try one(m)) } }; line(label, t) }
    // Forty different words per length, so a number is not one word's luck (the first spike timed one).
    let ranks = (0..<40).map { 150 + $0 * 61 }
    for n in [2, 3, 4, 5, 6] { try many("\(n) letters of the word being typed (40 words × 3)", ranks.map { String(w($0).prefix(n)) + "*" }) }
    try many("a whole common word (rank 3)", ["\"\(w(3))\""], repeats: 40)
    try many("a whole middling word (40 words)", ranks.map { "\"\(w($0))\"" })
    try many("two common words", ["\"\(w(5))\" AND \"\(w(9))\""], repeats: 40)
    try many("a phrase", ["\"\(w(5)) \(w(9))\""], repeats: 40)
    try many("a finished word then two letters", ranks.map { "\"\(w(40))\" \(String(w($0).prefix(2)))*" })
    var rank: [Double] = []
    for _ in 0..<6 { let a = now(); try s.searchReader.read { db in let c = try Row.fetchCursor(db, sql: "SELECT rowid FROM msg_fts WHERE msg_fts MATCH ? ORDER BY rank LIMIT 50", arguments: ["\"\(w(3))\""]); while try c.next() != nil {} }; rank.append(ms(a, now())) }
    line("the same common word ordered by relevance (never done)", rank)
    var stop: [Double] = []
    for _ in 0..<5 {
        let a = now(); DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(2)) { s.searchReader.interrupt() }
        _ = try? s.searchReader.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM msg_fts WHERE msg_fts MATCH ?", arguments: [String(w(3).prefix(1)) + "*"]) }
        stop.append(ms(a, now()) - 2)
    }
    line("interrupt(): time from the call to the query ending", stop)
    // Excerpts need the text; here only the join cost of 50 rows back to the index.
    var page1: [Double] = []
    for _ in 0..<100 { let a = now(); _ = try s.index.read { try page($0, view: unifiedViewPK(0)) }; page1.append(ms(a, now())) }
    line("an inbox page read while the search connection is open", page1)
}

// MARK: - activate(): opening the stores, the overlay rebuild, the first page

func open(dir: String) throws {
    section("activate(): four GRDB stores opened, 30 overlay rows rebuilt from intent, first page read — a fresh process each time would add the page cache")
    var t: [Double] = [], opens: [Double] = []
    for _ in 0..<12 {
        let a = now()
        let s = try Stores(dir: dir, create: false)
        let b = now()
        let rows = try s.intent.read { try Row.fetchAll($0, sql: "SELECT account, gmail_msg_id, label_ref, want FROM label_intent WHERE state < 3 ORDER BY seq DESC LIMIT 30") }
        try s.index.write { db in
            try db.execute(sql: "DELETE FROM overlay WHERE derived = 9")
            let st = try db.cachedStatement(sql: "INSERT OR REPLACE INTO overlay(msg_pk, label_pk, want, derived) VALUES(?,?,?,9)")
            for (i, r) in rows.enumerated() { try st.execute(arguments: [900_000_000 + i, 1, r[3] as Int]) }
        }
        _ = try s.index.read { try page($0, view: unifiedViewPK(0)) }
        t.append(ms(a, now())); opens.append(ms(a, b))
    }
    line("opening the four stores", opens); line("open + overlay rebuild + first page", t)
}

func check(dir: String) throws {
    let s = try Stores(dir: dir, create: false)
    section("integrity")
    var a = now(); let q = try s.index.read { try String.fetchOne($0, sql: "PRAGMA quick_check")! }; print(String(format: "  quick_check(index): %@ in %.2f s", q, ms(a, now()) / 1000))
    a = now(); try s.searchWriter.write { try $0.execute(sql: "INSERT INTO msg_fts(msg_fts) VALUES('integrity-check')") }; print(String(format: "  FTS5 integrity-check(search): %.2f s", ms(a, now()) / 1000))
    a = now(); let missing = try s.index.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM message WHERE fetch_state = 2 AND prep_state = 0")! }; print(String(format: "  bodies awaiting preparation (partial index): %d in %.3f ms", missing, ms(a, now())))
}

// MARK: - prefix '2 3' against '2 3 4'

func prefix(dir: String, messages: Int) throws {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    var r = RNG(42); let vocab = Vocab(count: 120_000, rng: &r)
    for p in ["2 3", "2 3 4"] {
        let path = dir + "/prefix-\(p.replacingOccurrences(of: " ", with: "")).sqlite"
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        var c = Configuration(); c.journalMode = .wal; c.prepareDatabase { try $0.execute(sql: "PRAGMA cache_size=-8192; PRAGMA temp_store=MEMORY") }
        let q = try DatabaseQueue(path: path, configuration: c)
        try q.write { try $0.execute(sql: ftsSchema.replacingOccurrences(of: "prefix='2 3'", with: "prefix='\(p)'")) }
        var gen = Generator(), done = 0, text: Int64 = 0; let t0 = now()
        while done < messages {
            var rows: [(Int64, Msg)] = []
            for t in nextBatch(&gen, messages: 50, recency: 0.5) { for m in t { rows.append((gen.ftsRowid(dateMs: m.date), m)); text += Int64(m.body.count + m.subject.count); done += 1 } }
            let g = gen; try q.write { try writeFTS($0, rows, gen: g) }
        }
        let built = ms(t0, now()) / 1000
        try q.writeWithoutTransaction { try $0.checkpoint(.truncate) }
        section("prefix='\(p)', \(done) messages, \(mb(text)) of text")
        print(String(format: "  built in %.1f s; file %@ = %d %% of the text", built, mb(fileSize(path)), Int(Double(fileSize(path)) / Double(text) * 100)))
        var four: [Double] = []
        for i in 0..<40 { let m = String(str(vocab.words[150 + i * 61]).prefix(4)) + "*"
            for _ in 0..<3 { let a = now(); try q.read { db in let cur = try Int64.fetchCursor(db.cachedStatement(sql: "SELECT rowid FROM msg_fts WHERE msg_fts MATCH ? ORDER BY rowid DESC LIMIT 100"), arguments: [m]); while try cur.next() != nil {} }; four.append(ms(a, now())) } }
        line("four letters, newest 100 messages (40 words × 3)", four)
    }
}


// MARK: - Is the full fsync really happening through GRDB? The same commit under three settings.

func fsync(dir: String) throws {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dir + "/fsync-intent.sqlite" + suffix) }
    var nc = Configuration(); nc.journalMode = .wal
    nc.prepareDatabase { db in try db.execute(sql: "PRAGMA cache_size=-1024; PRAGMA wal_autocheckpoint=0") }
    let q = try DatabaseQueue(path: dir + "/fsync-intent.sqlite", configuration: nc)
    try q.write { try $0.execute(sql: intentSchema) }
    section("one intent commit of three assertions through GRDB, under three settings, interleaved")
    print("  as GRDB leaves it after opening: synchronous \(try q.read { try Int.fetchOne($0, sql: "PRAGMA synchronous")! }), fullfsync \(try q.read { try Int.fetchOne($0, sql: "PRAGMA fullfsync")! })")
    var seq = 0
    var results: [String: [Double]] = [:]
    let settings = [("NORMAL (what GRDB sets)", "PRAGMA synchronous=NORMAL; PRAGMA fullfsync=OFF"),
                    ("FULL, plain fsync", "PRAGMA synchronous=FULL; PRAGMA fullfsync=OFF"),
                    ("FULL + fullfsync (the design)", "PRAGMA synchronous=FULL; PRAGMA fullfsync=ON")]
    for _ in 0..<4 {
        for (name, pragma) in settings {
            try q.writeWithoutTransaction { try $0.execute(sql: pragma) }
            for _ in 0..<100 {
                let a = now()
                try q.write { db in
                    let st = try db.cachedStatement(sql: "INSERT OR REPLACE INTO label_intent(account, gmail_msg_id, label_ref, want, seq, group_id, created_at) VALUES(?,?,?,?,?,?,?)")
                    for _ in 0..<3 { seq += 1; try st.execute(arguments: ["account0@example.com", "x\(seq)", "INBOX", 0, seq, "g", seq]) }
                }
                results[name, default: []].append(ms(a, now()))
            }
        }
    }
    for (name, _) in settings { line(name, results[name]!) }
    print("  read back at the end: synchronous \(try q.read { try Int.fetchOne($0, sql: "PRAGMA synchronous")! }), fullfsync \(try q.read { try Int.fetchOne($0, sql: "PRAGMA fullfsync")! })")
}

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: mailgrdb <build|read|under|act|search|open|check|prefix> <dir> [messages]"); exit(2) }
let n = args.count > 3 ? Int(args[3]) ?? 200_000 : 200_000
print("GRDB 7.11.1 · SQLite \(String(cString: sqlite3_libversion())) · \(Date()) · \(load())")
do {
    switch args[1] {
    case "build": try build(dir: args[2], messages: n)
    case "read": try read(dir: args[2])
    case "under": try under(dir: args[2])
    case "act": try act(dir: args[2])
    case "search": try search(dir: args[2])
    case "open": try open(dir: args[2])
    case "check": try check(dir: args[2])
    case "fsync": try fsync(dir: args[2])
    case "prefix": try prefix(dir: args[2], messages: args.count > 3 ? n : 40_000)
    default: print("unknown command")
    }
} catch { print("FAILED: \(error)"); exit(1) }
