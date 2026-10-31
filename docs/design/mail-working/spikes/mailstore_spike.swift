// mailstore_spike.swift — measurements behind docs/design/MAIL-ENGINE.md.
//
// Build:  swiftc -O mailstore_spike.swift -lsqlite3 -o mailstore_spike
// Run:    ./mailstore_spike build <dir> [messages=200000]      (synthetic store, the schema in the doc)
//         ./mailstore_spike read  <dir>                        (list pages, thread, counts, plans)
//         ./mailstore_spike fts   <dir>                        (search-as-you-type latencies)
//         ./mailstore_spike ftssize <dir> [messages=200000]    (index size per FTS5 configuration)
//         ./mailstore_spike write <dir>                        (batch ingest, single triage write, WAL, readers under write)
//         ./mailstore_spike fsync <dir>                        (intent-db commit cost per synchronous mode)
//         ./mailstore_spike cold  <dir>                        (fresh connection: open + first page; snapshot-file alternative)
//
// System libsqlite3, raw C API, no dependencies. Everything is deterministic (SplitMix64, fixed seed).

import Foundation
import SQLite3

let SQLITE_TRANSIENT_ = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Tiny SQLite wrapper

final class DB {
    var h: OpaquePointer?
    var cache: [String: OpaquePointer] = [:]
    init(_ path: String, readonly: Bool = false) {
        let flags = (readonly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)) | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &h, flags, nil) == SQLITE_OK else { fatalError("open \(path): \(String(cString: sqlite3_errmsg(h)))") }
        sqlite3_busy_timeout(h, 5000)
    }
    deinit { for s in cache.values { sqlite3_finalize(s) }; sqlite3_close(h) }
    func exec(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(h, sql, nil, nil, &err) != SQLITE_OK { fatalError("exec \(sql.prefix(120)): \(err.map { String(cString: $0) } ?? "?")") }
    }
    func stmt(_ sql: String) -> OpaquePointer {
        if let s = cache[sql] { sqlite3_reset(s); sqlite3_clear_bindings(s); return s }
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(h, sql, -1, &s, nil) == SQLITE_OK, let s else { fatalError("prepare \(sql.prefix(160)): \(String(cString: sqlite3_errmsg(h)))") }
        cache[sql] = s
        return s
    }
    func scalarInt(_ sql: String) -> Int64 {
        let s = stmt(sql); defer { sqlite3_reset(s) }
        return sqlite3_step(s) == SQLITE_ROW ? sqlite3_column_int64(s, 0) : -1
    }
    func scalarText(_ sql: String) -> String {
        let s = stmt(sql); defer { sqlite3_reset(s) }
        return sqlite3_step(s) == SQLITE_ROW ? String(cString: sqlite3_column_text(s, 0)) : ""
    }
    func plan(_ sql: String) -> String {
        var out: [String] = []
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(h, "EXPLAIN QUERY PLAN " + sql, -1, &s, nil) == SQLITE_OK else { return "plan failed: \(String(cString: sqlite3_errmsg(h)))" }
        while sqlite3_step(s) == SQLITE_ROW { out.append(String(cString: sqlite3_column_text(s, 3))) }
        sqlite3_finalize(s)
        return out.joined(separator: " | ")
    }
}
@inline(__always) func bind(_ s: OpaquePointer, _ i: Int32, _ v: Int64) { sqlite3_bind_int64(s, i, v) }
@inline(__always) func bind(_ s: OpaquePointer, _ i: Int32, _ v: String) { sqlite3_bind_text(s, i, v, -1, SQLITE_TRANSIENT_) }
@inline(__always) func bindBytes(_ s: OpaquePointer, _ i: Int32, _ v: [UInt8]) {
    v.withUnsafeBufferPointer { p in _ = sqlite3_bind_text(s, i, UnsafeRawPointer(p.baseAddress)?.assumingMemoryBound(to: CChar.self), Int32(p.count), SQLITE_TRANSIENT_) }
}
@discardableResult @inline(__always) func step(_ s: OpaquePointer) -> Int32 { sqlite3_step(s) }
func run(_ s: OpaquePointer) { let rc = sqlite3_step(s); if rc != SQLITE_DONE && rc != SQLITE_ROW { fatalError("step rc=\(rc)") }; sqlite3_reset(s) }

// MARK: - Deterministic random

struct RNG {
    var s: UInt64
    init(_ seed: UInt64) { s = seed }
    mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func chance(_ p: Double) -> Bool { unit() < p }
}

// MARK: - Timing

func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func ms(_ a: UInt64, _ b: UInt64) -> Double { Double(b - a) / 1_000_000 }
func stats(_ label: String, _ samples: [Double]) {
    let s = samples.sorted()
    guard !s.isEmpty else { print("  \(label): no samples"); return }
    func q(_ p: Double) -> Double { s[min(s.count - 1, Int(Double(s.count) * p))] }
    print(String(format: "  %@: n=%d p50=%.3f ms p95=%.3f ms p99=%.3f ms max=%.3f ms", label, s.count, q(0.5), q(0.95), q(0.99), s.last!))
}
func fileSize(_ path: String) -> Int64 { ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int64) ?? 0 }
func mb(_ bytes: Int64) -> String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }

// MARK: - Synthetic mailbox

/// A Zipf vocabulary of pronounceable pseudo-words: real mail has ~10^5 distinct tokens with a long tail.
struct Vocab {
    var words: [[UInt8]] = []
    var cumulative: [Double] = []
    init(count: Int, rng: inout RNG) {
        let onsets = ["b","c","d","f","g","h","j","k","l","m","n","p","r","s","t","v","w","z","br","ch","cl","cr","dr","fl","gr","pl","pr","sh","st","tr","th"]
        let nuclei = ["a","e","i","o","u","ai","ea","ou","io","ee"]
        let codas = ["","","n","r","s","t","l","m","nd","st","ng","rt"]
        var seen = Set<String>()
        while words.count < count {
            let syllables = 1 + rng.int(4)
            var w = ""
            for _ in 0..<syllables { w += onsets[rng.int(onsets.count)] + nuclei[rng.int(nuclei.count)] + codas[rng.int(codas.count)] }
            if seen.insert(w).inserted { words.append(Array(w.utf8)) }
        }
        var total = 0.0
        cumulative.reserveCapacity(count)
        for rank in 1...count { total += 1.0 / pow(Double(rank), 1.02); cumulative.append(total) }
        for i in 0..<count { cumulative[i] /= total }
    }
    func pick(_ rng: inout RNG) -> [UInt8] {
        let u = rng.unit()
        var lo = 0, hi = cumulative.count - 1
        while lo < hi { let mid = (lo + hi) / 2; if cumulative[mid] < u { lo = mid + 1 } else { hi = mid } }
        return words[lo]
    }
    func text(words n: Int, _ rng: inout RNG) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(n * 7)
        for i in 0..<n { if i > 0 { out.append(0x20) }; out.append(contentsOf: pick(&rng)) }
        return out
    }
}

struct Person { let name: [UInt8]; let addr: [UInt8] }

let accountWeights: [Double] = [0.50, 0.30, 0.15, 0.05]
// Labels per account, by local index: 0 INBOX 1 UNREAD 2 STARRED 3 IMPORTANT 4 SENT 5 DRAFT 6 TRASH 7 SPAM
// 8 CATEGORY_PERSONAL 9 SOCIAL 10 PROMOTIONS 11 UPDATES 12 FORUMS 13.. user labels
let systemLabels = ["INBOX","UNREAD","STARRED","IMPORTANT","SENT","DRAFT","TRASH","SPAM","CATEGORY_PERSONAL","CATEGORY_SOCIAL","CATEGORY_PROMOTIONS","CATEGORY_UPDATES","CATEGORY_FORUMS"]
let userLabelsPerAccount = 40
let labelsPerAccount = systemLabels.count + userLabelsPerAccount
func labelPK(_ account: Int, _ local: Int) -> Int64 { Int64(account * 100 + local + 1) }
// Views: one per (account,label) with view_pk = label_pk; unified twins 9001.. for the system labels;
// "all mail" per account 8001.. and unified 9100; three split views 9201..9203 over the unified inbox.
func unifiedViewPK(_ local: Int) -> Int64 { Int64(9001 + local) }
func allMailViewPK(_ account: Int) -> Int64 { Int64(8001 + account) }
let unifiedAllMail: Int64 = 9100
let splitVIP: Int64 = 9201, splitNews: Int64 = 9202, splitOther: Int64 = 9203

let indexDDL = """
CREATE TABLE account(account_pk INTEGER PRIMARY KEY, email TEXT NOT NULL UNIQUE, history_id TEXT);
CREATE TABLE label(label_pk INTEGER PRIMARY KEY, account_pk INTEGER NOT NULL, gmail_id TEXT NOT NULL, name TEXT NOT NULL, kind INTEGER NOT NULL, UNIQUE(account_pk, gmail_id));
CREATE TABLE thread(
  thread_pk INTEGER PRIMARY KEY, account_pk INTEGER NOT NULL, gmail_id TEXT NOT NULL,
  last_date INTEGER NOT NULL DEFAULT 0, message_count INTEGER NOT NULL DEFAULT 0, fetched_count INTEGER NOT NULL DEFAULT 0,
  unread_count INTEGER NOT NULL DEFAULT 0, flags INTEGER NOT NULL DEFAULT 0,
  subject TEXT, snippet TEXT, senders TEXT, labels TEXT,
  UNIQUE(account_pk, gmail_id));
CREATE TABLE message(
  msg_pk INTEGER PRIMARY KEY, account_pk INTEGER NOT NULL, gmail_id TEXT NOT NULL, thread_pk INTEGER NOT NULL,
  internal_date INTEGER NOT NULL DEFAULT 0, fetch_state INTEGER NOT NULL DEFAULT 0, fts_rowid INTEGER,
  history_id TEXT, size_estimate INTEGER, flags INTEGER NOT NULL DEFAULT 0, vis INTEGER NOT NULL DEFAULT 0,
  from_addr TEXT, from_name TEXT, subject TEXT, snippet TEXT, recipients TEXT, list_id TEXT,
  UNIQUE(account_pk, gmail_id));
CREATE INDEX message_by_thread ON message(thread_pk, internal_date);
CREATE UNIQUE INDEX message_by_fts ON message(fts_rowid) WHERE fts_rowid IS NOT NULL;
CREATE TABLE message_label(msg_pk INTEGER NOT NULL, label_pk INTEGER NOT NULL, PRIMARY KEY(msg_pk, label_pk)) WITHOUT ROWID;
CREATE INDEX message_label_by_label ON message_label(label_pk, msg_pk);
CREATE TABLE overlay(msg_pk INTEGER NOT NULL, label_pk INTEGER NOT NULL, want INTEGER NOT NULL, PRIMARY KEY(msg_pk, label_pk)) WITHOUT ROWID;
CREATE TABLE view_thread(view_pk INTEGER NOT NULL, sort_key INTEGER NOT NULL, thread_pk INTEGER NOT NULL, unread INTEGER NOT NULL,
  PRIMARY KEY(view_pk, sort_key, thread_pk)) WITHOUT ROWID;
CREATE INDEX view_thread_unread ON view_thread(view_pk) WHERE unread = 1;
CREATE INDEX view_thread_by_thread ON view_thread(thread_pk, view_pk);
CREATE INDEX message_stub_queue ON message(account_pk, flags, msg_pk) WHERE fetch_state = 0;
CREATE INDEX message_body_queue ON message(account_pk, flags, internal_date DESC) WHERE fetch_state = 1;
CREATE INDEX message_fts_queue ON message(internal_date DESC) WHERE fetch_state = 9;
CREATE TABLE view_count(view_pk INTEGER PRIMARY KEY, threads INTEGER NOT NULL, unread INTEGER NOT NULL);
CREATE TABLE correspondent(addr TEXT PRIMARY KEY, name TEXT, sent INTEGER NOT NULL DEFAULT 0, received INTEGER NOT NULL DEFAULT 0, last_date INTEGER NOT NULL DEFAULT 0) WITHOUT ROWID;
CREATE TABLE correspondent_key(key TEXT NOT NULL, addr TEXT NOT NULL, PRIMARY KEY(key, addr)) WITHOUT ROWID;
"""

func ftsDDL(_ name: String, detail: String, prefix: String?) -> String {
    var opts = "subject, sender, recipients, body, attachments, content='', contentless_delete=1, tokenize='unicode61 remove_diacritics 2', detail=\(detail)"
    if let prefix { opts += ", prefix='\(prefix)'" }
    return "CREATE VIRTUAL TABLE \(name) USING fts5(\(opts));"
}

func applyPragmas(_ db: DB, writer: Bool) {
    db.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA temp_store=MEMORY; PRAGMA cache_size=-8000;")
    if writer { db.exec("PRAGMA wal_autocheckpoint=1000;") }
}

struct Msg {
    var pk: Int64; var account: Int; var threadPK: Int64; var date: Int64
    var labels: [Int]            // local label indexes
    var from: Int; var to: Int
    var subject: [UInt8]; var body: [UInt8]; var snippet: [UInt8]
    var fromMe: Bool
}

/// Generates threads newest-last (dates ascend with index) so the caller can insert in any order.
struct Generator {
    var rng = RNG(0xBA4A4A)
    let vocab: Vocab
    let people: [Person]
    let personCumulative: [Double]
    let nowMs: Int64 = 1_791_000_000_000   // Oct 2026
    let spanMs: Int64 = 10 * 365 * 86_400_000
    var nextThread: Int64 = 1
    var nextMsg: Int64 = 1
    var usedFts = Set<Int64>()

    init() {
        var r = RNG(42)
        vocab = Vocab(count: 120_000, rng: &r)
        var ppl: [Person] = []
        let domains = ["example.com","acme.io","mail.test","corp.example","news.example","shop.example","uni.example","team.example"]
        for i in 0..<30_000 {
            let first = String(decoding: vocab.words[1000 + r.int(4000)], as: UTF8.self)
            let last = String(decoding: vocab.words[5000 + r.int(20000)], as: UTF8.self)
            ppl.append(Person(name: Array("\(first.capitalized) \(last.capitalized)".utf8),
                              addr: Array("\(first).\(last)\(i % 97)@\(domains[r.int(domains.count)])".utf8)))
        }
        people = ppl
        var total = 0.0; var cum: [Double] = []
        for rank in 1...ppl.count { total += 1.0 / pow(Double(rank), 1.1); cum.append(total) }
        personCumulative = cum.map { $0 / total }
    }
    mutating func person() -> Int {
        let u = rng.unit(); var lo = 0, hi = personCumulative.count - 1
        while lo < hi { let mid = (lo + hi) / 2; if personCumulative[mid] < u { lo = mid + 1 } else { hi = mid } }
        return lo
    }
    mutating func account() -> Int {
        let u = rng.unit(); var acc = 0.0
        for (i, w) in accountWeights.enumerated() { acc += w; if u < acc { return i } }
        return accountWeights.count - 1
    }
    mutating func threadSize() -> Int {
        let u = rng.unit()
        if u < 0.62 { return 1 }; if u < 0.80 { return 2 }; if u < 0.92 { return 3 + rng.int(3) }
        if u < 0.98 { return 6 + rng.int(10) }; return 16 + rng.int(45)
    }
    /// Body length in words: log-normal, median ~170 words (~1.2 KB), mean ~360 words (~2.5 KB), capped at 4,500 (~32 KB).
    mutating func bodyWords() -> Int {
        let u1 = max(rng.unit(), 1e-12), u2 = rng.unit()
        let z = sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
        return min(4500, max(8, Int(exp(5.14 + 1.22 * z))))
    }
    mutating func ftsRowid(dateMs: Int64) -> Int64 {
        var slot = Int64(rng.next() & 0xFFFFF)
        var id = (dateMs << 20) | slot
        while !usedFts.insert(id).inserted { slot = (slot + 1) & 0xFFFFF; id = (dateMs << 20) | slot }
        return id
    }
    /// One thread's messages. `recency` in 0...1 (1 = newest) drives the date and the inbox/unread odds.
    mutating func thread(recency: Double) -> [Msg] {
        let acct = account()
        let tpk = nextThread; nextThread += 1
        let n = threadSize()
        let start = nowMs - Int64((1 - recency) * Double(spanMs))
        let subject = vocab.text(words: 3 + rng.int(7), &rng)
        let other = person()
        let inbox = rng.chance(recency > 0.985 ? 0.55 : (recency > 0.95 ? 0.08 : 0.004))
        let category: Int? = rng.chance(0.55) ? [10, 10, 10, 10, 10, 11, 11, 11, 11, 9, 12][rng.int(11)] : (rng.chance(0.5) ? 8 : nil)
        var user: [Int] = []
        if rng.chance(0.25) { user.append(13 + rng.int(userLabelsPerAccount)) }
        if rng.chance(0.05) { user.append(13 + rng.int(userLabelsPerAccount)) }
        let trashed = rng.chance(0.005), spam = !trashed && rng.chance(0.003)
        let important = rng.chance(0.15), starred = rng.chance(0.01)
        var out: [Msg] = []
        var t = start
        for i in 0..<n {
            let fromMe = category == nil || category == 8 ? rng.chance(i == 0 ? 0.2 : 0.45) : false
            var labels: [Int] = []
            if trashed { labels.append(6) } else if spam { labels.append(7) } else {
                if fromMe { labels.append(4) } else {
                    if inbox { labels.append(0) }
                    if let category { labels.append(category) }
                    if rng.chance(inbox ? 0.35 : (category == 10 ? 0.25 : 0.03)) { labels.append(1) }
                }
                if important { labels.append(3) }
                if starred && i == n - 1 { labels.append(2) }
                labels.append(contentsOf: user)
            }
            let body = vocab.text(words: bodyWords(), &rng)
            out.append(Msg(pk: nextMsg, account: acct, threadPK: tpk, date: t, labels: Array(Set(labels)).sorted(),
                           from: fromMe ? acct : other, to: fromMe ? other : acct,
                           subject: subject, body: body, snippet: Array(body.prefix(140)), fromMe: fromMe))
            nextMsg += 1
            t += Int64(60_000 + rng.int(3 * 86_400_000))
        }
        return out
    }
}

/// What ThreadSummaryRules + ViewMembershipRules will do in the real store, done here so the write
/// path being timed is the real shape: one thread row, one membership row per (view, thread).
struct Summary { var lastDate: Int64 = 0; var count = 0; var unread = 0; var memberships: [Int64: (sort: Int64, unread: Bool)] = [:]; var labels = Set<Int>() }
func summarise(_ msgs: [Msg]) -> Summary {
    var s = Summary()
    let allHidden = msgs.allSatisfy { $0.labels.contains(6) || $0.labels.contains(7) }
    for m in msgs {
        let hidden = m.labels.contains(6) || m.labels.contains(7)
        let isUnread = m.labels.contains(1)
        if !hidden || allHidden { s.lastDate = max(s.lastDate, m.date); s.count += 1; if isUnread { s.unread += 1 } }
        func add(_ view: Int64) {
            var e = s.memberships[view] ?? (0, false)
            e.sort = max(e.sort, m.date); e.unread = e.unread || isUnread
            s.memberships[view] = e
        }
        for l in m.labels where l != 1 {
            if hidden && l != 6 && l != 7 { continue }
            s.labels.insert(l)
            add(labelPK(m.account, l))
            if l < systemLabels.count { add(unifiedViewPK(l)) }
        }
        if !hidden {
            add(allMailViewPK(m.account)); add(unifiedAllMail)
            if m.labels.contains(0) {
                // Three saved-query splits over the unified inbox: VIP senders, newsletters, the rest.
                if m.from < 40 { add(splitVIP) } else if m.labels.contains(10) || m.labels.contains(11) { add(splitNews) } else { add(splitOther) }
            }
        }
    }
    return s
}

final class IndexWriter {
    let db: DB
    let withFTS: Bool
    var counts: [Int64: (threads: Int, unread: Int)] = [:]
    init(db: DB, withFTS: Bool) { self.db = db; self.withFTS = withFTS }
    func insertThread(_ msgs: [Msg], gen: inout Generator) {
        let s = summarise(msgs)
        let first = msgs[0]
        let t = db.stmt("INSERT INTO thread(thread_pk, account_pk, gmail_id, last_date, message_count, fetched_count, unread_count, flags, subject, snippet, senders, labels) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)")
        bind(t, 1, first.threadPK); bind(t, 2, Int64(first.account + 1)); bind(t, 3, String(format: "%016llx", UInt64(first.threadPK) &* 0x9E3779B97F4A7C15))
        bind(t, 4, s.lastDate); bind(t, 5, Int64(s.count)); bind(t, 6, Int64(msgs.count)); bind(t, 7, Int64(s.unread)); bind(t, 8, 0)
        bindBytes(t, 9, first.subject); bindBytes(t, 10, msgs.last!.snippet)
        bindBytes(t, 11, gen.people[first.from].name)
        bind(t, 12, "," + s.labels.sorted().map { String(labelPK(first.account, $0)) }.joined(separator: ",") + ",")
        run(t)
        for m in msgs {
            let fts = gen.ftsRowid(dateMs: m.date)
            let q = db.stmt("INSERT INTO message(msg_pk, account_pk, gmail_id, thread_pk, internal_date, fetch_state, fts_rowid, history_id, size_estimate, flags, vis, from_addr, from_name, subject, snippet, recipients) VALUES(?,?,?,?,?,2,?,?,?,?,?,?,?,?,?,?)")
            bind(q, 1, m.pk); bind(q, 2, Int64(m.account + 1)); bind(q, 3, String(format: "%016llx", UInt64(m.pk) &* 0xD6E8FEB86659FD93))
            bind(q, 4, m.threadPK); bind(q, 5, m.date); bind(q, 6, fts); bind(q, 7, String(m.pk * 7)); bind(q, 8, Int64(m.body.count * 12))
            bind(q, 9, m.fromMe ? 1 : 0); bind(q, 10, m.labels.contains(6) ? 1 : (m.labels.contains(7) ? 2 : 0))
            bindBytes(q, 11, gen.people[m.from].addr); bindBytes(q, 12, gen.people[m.from].name)
            bindBytes(q, 13, m.subject); bindBytes(q, 14, m.snippet); bindBytes(q, 15, gen.people[m.to].addr)
            run(q)
            for l in m.labels {
                let ml = db.stmt("INSERT INTO message_label(msg_pk, label_pk) VALUES(?,?)")
                bind(ml, 1, m.pk); bind(ml, 2, labelPK(m.account, l)); run(ml)
            }
            if withFTS {
                let f = db.stmt("INSERT INTO msg_fts(rowid, subject, sender, recipients, body, attachments) VALUES(?,?,?,?,?,'')")
                bind(f, 1, fts); bindBytes(f, 2, m.subject)
                bindBytes(f, 3, gen.people[m.from].name + [0x20] + gen.people[m.from].addr)
                bindBytes(f, 4, gen.people[m.to].addr); bindBytes(f, 5, m.body); run(f)
            }
        }
        for (view, e) in s.memberships {
            let v = db.stmt("INSERT INTO view_thread(view_pk, sort_key, thread_pk, unread) VALUES(?,?,?,?)")
            bind(v, 1, view); bind(v, 2, e.sort); bind(v, 3, first.threadPK); bind(v, 4, e.unread ? 1 : 0); run(v)
            var c = counts[view] ?? (0, 0); c.threads += 1; if e.unread { c.unread += 1 }; counts[view] = c
        }
    }
    func flushCounts() {
        for (view, c) in counts {
            let s = db.stmt("INSERT INTO view_count(view_pk, threads, unread) VALUES(?,?,?) ON CONFLICT(view_pk) DO UPDATE SET threads = threads + excluded.threads, unread = unread + excluded.unread")
            bind(s, 1, view); bind(s, 2, Int64(c.threads)); bind(s, 3, Int64(c.unread)); run(s)
        }
        counts = [:]
    }
}

func seedStatic(_ db: DB, gen: Generator) {
    db.exec("BEGIN")
    for a in 0..<accountWeights.count {
        let s = db.stmt("INSERT INTO account(account_pk, email, history_id) VALUES(?,?,?)")
        bind(s, 1, Int64(a + 1)); bind(s, 2, "account\(a)@example.com"); bind(s, 3, "1000"); run(s)
        for l in 0..<labelsPerAccount {
            let q = db.stmt("INSERT INTO label(label_pk, account_pk, gmail_id, name, kind) VALUES(?,?,?,?,?)")
            bind(q, 1, labelPK(a, l)); bind(q, 2, Int64(a + 1))
            bind(q, 3, l < systemLabels.count ? systemLabels[l] : "Label_\(l)"); bind(q, 4, l < systemLabels.count ? systemLabels[l] : "Project/\(l)")
            bind(q, 5, l < systemLabels.count ? 0 : 1); run(q)
        }
    }
    for p in gen.people {
        let s = db.stmt("INSERT OR IGNORE INTO correspondent(addr, name, sent, received, last_date) VALUES(?,?,1,1,0)")
        bindBytes(s, 1, p.addr); bindBytes(s, 2, p.name); run(s)
        let name = String(decoding: p.name, as: UTF8.self).lowercased()
        let addr = String(decoding: p.addr, as: UTF8.self)
        var keys = name.split(separator: " ").map(String.init)
        keys.append(addr)
        if let at = addr.firstIndex(of: "@") { keys.append(String(addr[addr.index(after: at)...])) }
        for k in keys {
            let q = db.stmt("INSERT OR IGNORE INTO correspondent_key(key, addr) VALUES(?,?)")
            bind(q, 1, k); bindBytes(q, 2, p.addr); run(q)
        }
    }
    db.exec("COMMIT")
}

// MARK: - build

func build(dir: String, messages: Int, withFTS: Bool = true, batch: Int = 50) {
    try? FileManager.default.removeItem(atPath: dir)
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = dir + "/index.sqlite"
    let db = DB(path)
    applyPragmas(db, writer: true)
    db.exec(indexDDL)
    if withFTS { db.exec(ftsDDL("msg_fts", detail: "full", prefix: "2 3")) }
    var gen = Generator()
    seedStatic(db, gen: gen)
    let writer = IndexWriter(db: db, withFTS: withFTS)
    // Newest first, as the backfill does: thread i of N has recency 1 - i/N.
    var done = 0, threads = 0, textBytes: Int64 = 0
    let estimatedThreads = Int(Double(messages) / 2.49)
    let t0 = now()
    var batchStart = now(); var batchTimes: [Double] = []
    db.exec("BEGIN")
    var inBatch = 0
    while done < messages {
        let recency = max(0, 1 - Double(threads) / Double(estimatedThreads))
        let msgs = gen.thread(recency: pow(recency, 0.7))
        writer.insertThread(msgs, gen: &gen)
        for m in msgs { textBytes += Int64(m.body.count + m.subject.count) }
        done += msgs.count; threads += 1; inBatch += msgs.count
        if inBatch >= batch {
            writer.flushCounts()
            db.exec("COMMIT")
            batchTimes.append(ms(batchStart, now()))
            batchStart = now(); inBatch = 0
            db.exec("BEGIN")
        }
    }
    writer.flushCounts()
    db.exec("COMMIT")
    let t1 = now()
    print("build: \(done) messages in \(threads) threads, indexed text \(mb(textBytes)), \(String(format: "%.1f", ms(t0, t1) / 1000)) s  (\(Int(Double(done) / (ms(t0, t1) / 1000))) msg/s, newest-first inserts, \(batch) per transaction, \(withFTS ? "FTS detail=full prefix='2 3' in the same file" : "NO FTS in this file"))")
    stats("ingest transaction of ~\(batch) messages (thread rows, labels, views, counters\(withFTS ? ", FTS" : ""))", batchTimes)
    print("  WAL before checkpoint: \(mb(fileSize(path + "-wal")))")
    let c0 = now(); db.exec("PRAGMA wal_checkpoint(TRUNCATE)"); print(String(format: "  checkpoint(TRUNCATE): %.1f ms", ms(c0, now())))
    print("  index.sqlite: \(mb(fileSize(path)))")
    report(db)
}

func report(_ db: DB) {
    print("  rows: message=\(db.scalarInt("SELECT count(*) FROM message")) thread=\(db.scalarInt("SELECT count(*) FROM thread")) message_label=\(db.scalarInt("SELECT count(*) FROM message_label")) view_thread=\(db.scalarInt("SELECT count(*) FROM view_thread"))")
    print("  unified inbox threads=\(db.scalarInt("SELECT count(*) FROM view_thread WHERE view_pk=\(unifiedViewPK(0))")) unread there=\(db.scalarInt("SELECT count(*) FROM view_thread WHERE view_pk=\(unifiedViewPK(0)) AND unread=1")); unified all mail threads=\(db.scalarInt("SELECT count(*) FROM view_thread WHERE view_pk=\(unifiedAllMail)")) unread there=\(db.scalarInt("SELECT count(*) FROM view_thread WHERE view_pk=\(unifiedAllMail) AND unread=1"))")
    // Per-table bytes via dbstat (compiled into the system library on macOS).
    var s: OpaquePointer?
    if sqlite3_prepare_v2(db.h, "SELECT name, sum(pgsize) FROM dbstat GROUP BY name ORDER BY 2 DESC LIMIT 16", -1, &s, nil) == SQLITE_OK {
        print("  bytes by b-tree:")
        while sqlite3_step(s) == SQLITE_ROW { print("    \(String(cString: sqlite3_column_text(s, 0))): \(mb(sqlite3_column_int64(s, 1)))") }
    } else { print("  (dbstat unavailable)") }
    sqlite3_finalize(s)
}

// MARK: - read

let pageSQL = """
SELECT t.thread_pk, t.account_pk, v.sort_key, v.unread, t.message_count, t.flags, t.subject, t.snippet, t.senders, t.labels
FROM view_thread v JOIN thread t ON t.thread_pk = v.thread_pk
WHERE v.view_pk = ?1 AND (v.sort_key, v.thread_pk) < (?2, ?3)
ORDER BY v.sort_key DESC, v.thread_pk DESC LIMIT ?4
"""

func page(_ db: DB, view: Int64, before: (Int64, Int64) = (Int64.max, Int64.max), limit: Int64 = 50) -> (rows: Int, last: (Int64, Int64)) {
    let s = db.stmt(pageSQL)
    bind(s, 1, view); bind(s, 2, before.0); bind(s, 3, before.1); bind(s, 4, limit)
    var n = 0; var last = before; var bytes = 0
    while sqlite3_step(s) == SQLITE_ROW {
        n += 1; last = (sqlite3_column_int64(s, 2), sqlite3_column_int64(s, 0))
        for c: Int32 in 6...9 { bytes += Int(sqlite3_column_bytes(s, c)); _ = sqlite3_column_text(s, c) }
    }
    sqlite3_reset(s)
    return (n, last)
}

func read(dir: String) {
    let db = DB(dir + "/index.sqlite", readonly: true)
    applyPragmasReader(db)
    print("query plans:")
    print("  page: \(db.plan(pageSQL.replacingOccurrences(of: "?1", with: "1").replacingOccurrences(of: "?2", with: "9").replacingOccurrences(of: "?3", with: "9").replacingOccurrences(of: "?4", with: "50")))")
    print("  unread count (partial index): \(db.plan("SELECT count(*) FROM view_thread WHERE view_pk = 9001 AND unread = 1"))")
    print("  thread messages: \(db.plan("SELECT msg_pk FROM message WHERE thread_pk = 5 ORDER BY internal_date"))")
    print("  thread labels: \(db.plan("SELECT ml.msg_pk, ml.label_pk FROM message m JOIN message_label ml ON ml.msg_pk = m.msg_pk WHERE m.thread_pk = 5"))")
    print("  unified by IN-list instead of a twin view: \(db.plan("SELECT thread_pk FROM view_thread WHERE view_pk IN (1,101,201,301) ORDER BY sort_key DESC LIMIT 50"))")

    print("list pages (50 rows, every column a row draws):")
    for (name, view) in [("unified inbox", unifiedViewPK(0)), ("account 0 inbox", labelPK(0, 0)), ("unified all mail", unifiedAllMail),
                         ("split: other", splitOther), ("a user label", labelPK(0, 20)), ("unified promotions", unifiedViewPK(10))] {
        var first: [Double] = []
        for _ in 0..<200 { let a = now(); _ = page(db, view: view); first.append(ms(a, now())) }
        stats("\(name) — first page", first)
    }
    // Keyset walk through all of "unified all mail": every page costs the same.
    var cursor: (Int64, Int64) = (Int64.max, Int64.max); var walk: [Double] = []; var pages = 0; var total = 0
    while true {
        let a = now(); let r = page(db, view: unifiedAllMail, before: cursor); walk.append(ms(a, now()))
        total += r.rows; pages += 1
        if r.rows < 50 { break }
        cursor = r.last
    }
    stats("unified all mail — keyset walk, \(pages) pages, \(total) threads", walk)
    stats("  … last 100 pages of that walk (deepest)", Array(walk.suffix(100)))
    // The same depth with OFFSET, to show why keyset.
    let off = max(0, total - 60)
    var offs: [Double] = []
    for _ in 0..<20 {
        let s = db.stmt("SELECT thread_pk FROM view_thread WHERE view_pk = ?1 ORDER BY sort_key DESC, thread_pk DESC LIMIT 50 OFFSET ?2")
        bind(s, 1, unifiedAllMail); bind(s, 2, Int64(off)); let a = now(); while sqlite3_step(s) == SQLITE_ROW {}; offs.append(ms(a, now())); sqlite3_reset(s)
    }
    stats("unified all mail — same last page by OFFSET \(off)", offs)

    print("unified inbox without twin views (IN-list over 4 per-account views, sorted):")
    var inlist: [Double] = []
    for _ in 0..<200 {
        let s = db.stmt("SELECT t.thread_pk, t.subject FROM view_thread v JOIN thread t ON t.thread_pk = v.thread_pk WHERE v.view_pk IN (1,101,201,301) ORDER BY v.sort_key DESC, v.thread_pk DESC LIMIT 50")
        let a = now(); while sqlite3_step(s) == SQLITE_ROW {}; inlist.append(ms(a, now())); sqlite3_reset(s)
    }
    stats("inbox via IN-list", inlist)
    var inall: [Double] = []
    for _ in 0..<20 {
        let s = db.stmt("SELECT t.thread_pk, t.subject FROM view_thread v JOIN thread t ON t.thread_pk = v.thread_pk WHERE v.view_pk IN (8001,8002,8003,8004) ORDER BY v.sort_key DESC, v.thread_pk DESC LIMIT 50")
        let a = now(); while sqlite3_step(s) == SQLITE_ROW {}; inall.append(ms(a, now())); sqlite3_reset(s)
    }
    stats("all mail via IN-list", inall)

    print("counts:")
    for (name, view) in [("unified inbox", unifiedViewPK(0)), ("unified all mail", unifiedAllMail), ("unified promotions", unifiedViewPK(10))] {
        var partial: [Double] = [], counter: [Double] = [], full: [Double] = []
        var n: Int64 = 0
        for _ in 0..<200 {
            var s = db.stmt("SELECT count(*) FROM view_thread WHERE view_pk = ?1 AND unread = 1"); bind(s, 1, view)
            var a = now(); step(s); n = sqlite3_column_int64(s, 0); partial.append(ms(a, now())); sqlite3_reset(s)
            s = db.stmt("SELECT unread FROM view_count WHERE view_pk = ?1"); bind(s, 1, view)
            a = now(); step(s); counter.append(ms(a, now())); sqlite3_reset(s)
            s = db.stmt("SELECT count(*) FROM view_thread WHERE view_pk = ?1"); bind(s, 1, view)
            a = now(); step(s); full.append(ms(a, now())); sqlite3_reset(s)
        }
        print("  \(name): \(n) unread")
        stats("    unread by partial index", partial); stats("    unread from counter row", counter); stats("    total by count(*) over the view", full)
    }

    print("thread assembly (messages + effective labels):")
    var sizes: [Int: [Double]] = [:]
    var rng = RNG(7)
    let maxThread = db.scalarInt("SELECT max(thread_pk) FROM thread")
    for _ in 0..<3000 {
        let tpk = Int64(1 + rng.int(Int(maxThread)))
        let a = now()
        let s = db.stmt("SELECT msg_pk, internal_date, flags, from_addr, from_name, subject, snippet, recipients FROM message WHERE thread_pk = ?1 ORDER BY internal_date")
        bind(s, 1, tpk); var n = 0
        while sqlite3_step(s) == SQLITE_ROW { n += 1; _ = sqlite3_column_text(s, 6) }
        sqlite3_reset(s)
        let l = db.stmt("SELECT ml.msg_pk, ml.label_pk FROM message m JOIN message_label ml ON ml.msg_pk = m.msg_pk WHERE m.thread_pk = ?1")
        bind(l, 1, tpk); while sqlite3_step(l) == SQLITE_ROW {}; sqlite3_reset(l)
        let o = db.stmt("SELECT o.msg_pk, o.label_pk, o.want FROM message m JOIN overlay o ON o.msg_pk = m.msg_pk WHERE m.thread_pk = ?1")
        bind(o, 1, tpk); while sqlite3_step(o) == SQLITE_ROW {}; sqlite3_reset(o)
        let bucket = n == 1 ? 1 : (n <= 5 ? 5 : (n <= 15 ? 15 : 60))
        sizes[bucket, default: []].append(ms(a, now()))
    }
    for k in sizes.keys.sorted() { stats("threads of ≤\(k) messages", sizes[k]!) }

    print("recipient autocomplete (30,000 correspondents, prefix on name words, address, domain):")
    var ac: [Double] = []
    for prefix in ["a", "br", "sha", "stou", "example", "chea", "t", "plo", "gr", "news"] {
        for _ in 0..<50 {
            let s = db.stmt("SELECT c.addr, c.name, c.sent, c.received FROM correspondent_key k JOIN correspondent c ON c.addr = k.addr WHERE k.key >= ?1 AND k.key < ?2 ORDER BY c.sent DESC, c.last_date DESC LIMIT 8")
            bind(s, 1, prefix); bind(s, 2, prefix + "\u{10FFFF}")
            let a = now(); while sqlite3_step(s) == SQLITE_ROW {}; ac.append(ms(a, now())); sqlite3_reset(s)
        }
    }
    stats("autocomplete", ac)
}

func applyPragmasReader(_ db: DB) { db.exec("PRAGMA temp_store=MEMORY; PRAGMA cache_size=-8000; PRAGMA query_only=1;") }

// MARK: - fts

func fts(dir: String) {
    let db = DB(dir + "/index.sqlite", readonly: true)
    applyPragmasReader(db)
    var r = RNG(42)
    let vocab = Vocab(count: 120_000, rng: &r)
    func w(_ rank: Int) -> String { String(decoding: vocab.words[rank], as: UTF8.self) }
    func hits(_ match: String) -> Int64 {
        let s = db.stmt("SELECT count(*) FROM msg_fts WHERE msg_fts MATCH ?1"); bind(s, 1, match); step(s); let n = sqlite3_column_int64(s, 0); sqlite3_reset(s); return n
    }
    // Newest 50 conversations for a query: stream matches newest-first, stop at 50 distinct threads.
    let sql = "SELECT m.thread_pk, m.msg_pk FROM msg_fts f JOIN message m ON m.fts_rowid = f.rowid WHERE f.msg_fts MATCH ?1 AND m.vis = 0 ORDER BY f.rowid DESC LIMIT 400"
    print("plan: \(db.plan(sql.replacingOccurrences(of: "?1", with: "'abc'")))")
    func search(_ match: String) -> (Double, Int) {
        let s = db.stmt(sql); bind(s, 1, match)
        let a = now(); var seen = Set<Int64>(); var scanned = 0
        while seen.count < 50, sqlite3_step(s) == SQLITE_ROW { seen.insert(sqlite3_column_int64(s, 0)); scanned += 1 }
        let t = ms(a, now()); sqlite3_reset(s); return (t, scanned)
    }
    func bench(_ label: String, _ match: String) {
        var times: [Double] = []
        for _ in 0..<40 { times.append(search(match).0) }
        print("  [\(label)] MATCH \(match)  → \(hits(match)) matching messages")
        stats("    newest 50 conversations", times)
    }
    print("search-as-you-type (prefix index '2 3'):")
    let common = w(3), mid = w(900), rare = w(60_000)
    bench("1 char", "\(common.prefix(1))*")
    bench("2 chars", "\(common.prefix(2))*")
    bench("3 chars", "\(common.prefix(3))*")
    bench("4 chars (no prefix index at this length)", "\(mid.prefix(4))*")
    bench("5 chars", "\(mid.prefix(5))*")
    bench("very common word", "\"\(common)\"")
    bench("mid word", "\"\(mid)\"")
    bench("rare word", "\"\(rare)\"")
    bench("two common words AND", "\"\(w(5))\" AND \"\(w(9))\"")
    bench("common AND rare", "\"\(w(5))\" AND \"\(rare)\"")
    bench("word then prefix", "\"\(w(40))\" \(w(700).prefix(3))*")
    bench("phrase of two common words", "\"\(w(5)) \(w(9))\"")
    bench("subject column only", "subject : \"\(w(50))\"")
    bench("sender column prefix", "sender : \(w(1500).prefix(3))*")
    bench("no hits", "\"zzzzqqqq\"")
    // Worst case for the streaming plan: a common term AND-ed with a filter that almost nothing passes.
    let worst = "SELECT m.thread_pk FROM msg_fts f JOIN message m ON m.fts_rowid = f.rowid WHERE f.msg_fts MATCH ?1 AND m.account_pk = 4 AND m.vis = 0 ORDER BY f.rowid DESC LIMIT 400"
    var worstT: [Double] = []
    for _ in 0..<10 {
        let s = db.stmt(worst); bind(s, 1, "\"\(common)\"")
        let a = now(); var seen = Set<Int64>()
        while seen.count < 50, sqlite3_step(s) == SQLITE_ROW { seen.insert(sqlite3_column_int64(s, 0)) }
        worstT.append(ms(a, now())); sqlite3_reset(s)
    }
    stats("very common word restricted to the smallest account (5% of mail)", worstT)
    // And ordered by relevance instead of date, for comparison.
    var rank: [Double] = []
    for _ in 0..<10 {
        let s = db.stmt("SELECT rowid FROM msg_fts WHERE msg_fts MATCH ?1 ORDER BY rank LIMIT 50"); bind(s, 1, "\"\(common)\"")
        let a = now(); while sqlite3_step(s) == SQLITE_ROW {}; rank.append(ms(a, now())); sqlite3_reset(s)
    }
    stats("very common word ORDER BY rank (bm25) LIMIT 50", rank)
    // Interrupt: a superseded query must stop at once.
    let s = db.stmt("SELECT count(*) FROM msg_fts WHERE msg_fts MATCH ?1"); bind(s, 1, "\(common.prefix(1))*")
    let a = now()
    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(2)) { sqlite3_interrupt(db.h) }
    let rc = sqlite3_step(s); let t = ms(a, now()); sqlite3_reset(s)
    print(String(format: "  sqlite3_interrupt 2 ms into a count over a 1-char prefix: rc=%d after %.2f ms", rc, t))
}

// MARK: - ftssize

func ftssize(dir: String, messages: Int) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let configs: [(String, String, String?)] = [
        ("full_p23", "full", "2 3"), ("full_p2", "full", "2"), ("full_nop", "full", nil), ("column_p23", "column", "2 3"), ("column_nop", "column", nil), ("none_nop", "none", nil),
    ]
    for (name, detail, prefix) in configs {
        let path = dir + "/fts_\(name).sqlite"
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        let db = DB(path); applyPragmas(db, writer: true)
        db.exec(ftsDDL("msg_fts", detail: detail, prefix: prefix))
        var gen = Generator()
        var done = 0, threads = 0; var text: Int64 = 0
        let t0 = now(); db.exec("BEGIN"); var inBatch = 0
        while done < messages {
            for m in gen.thread(recency: 0.5) {
                let f = db.stmt("INSERT INTO msg_fts(rowid, subject, sender, recipients, body, attachments) VALUES(?,?,?,?,?,'')")
                bind(f, 1, gen.ftsRowid(dateMs: m.date)); bindBytes(f, 2, m.subject)
                bindBytes(f, 3, gen.people[m.from].name + [0x20] + gen.people[m.from].addr); bindBytes(f, 4, gen.people[m.to].addr); bindBytes(f, 5, m.body); run(f)
                text += Int64(m.body.count + m.subject.count); done += 1; inBatch += 1
            }
            threads += 1
            if inBatch >= 50 { db.exec("COMMIT; BEGIN"); inBatch = 0 }
        }
        db.exec("COMMIT"); let t1 = now()
        db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        let raw = fileSize(path)
        let o0 = now(); db.exec("INSERT INTO msg_fts(msg_fts) VALUES('optimize')"); db.exec("PRAGMA wal_checkpoint(TRUNCATE)"); db.exec("VACUUM"); db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        print(String(format: "detail=%@ prefix=%@: %d msgs, text %@, build %.1f s, size %@ (%.0f%% of text); after optimize+vacuum %@ (%.0f%%, %.1f s)",
                     detail, prefix ?? "none", done, mb(text), ms(t0, t1) / 1000, mb(raw), Double(raw) / Double(text) * 100, mb(fileSize(path)), Double(fileSize(path)) / Double(text) * 100, ms(o0, now()) / 1000))
    }
}

// MARK: - write

func write(dir: String) {
    let path = dir + "/index.sqlite"
    let db = DB(path); applyPragmas(db, writer: true)
    let inboxView = unifiedViewPK(0)
    // 1. One triage action on one thread, the whole write path: overlay rows for its messages, the
    //    thread row, its view memberships, the counters — in one transaction. This is what a held
    //    `e` does once per repeat.
    var targets: [(Int64, Int64, Int64)] = []   // thread, sort, unread
    do {
        let s = db.stmt("SELECT thread_pk, sort_key, unread FROM view_thread WHERE view_pk = ?1 ORDER BY sort_key DESC LIMIT 600"); bind(s, 1, inboxView)
        while sqlite3_step(s) == SQLITE_ROW { targets.append((sqlite3_column_int64(s, 0), sqlite3_column_int64(s, 1), sqlite3_column_int64(s, 2))) }
        sqlite3_reset(s)
    }
    func archive(_ t: (Int64, Int64, Int64)) {
        db.exec("BEGIN IMMEDIATE")
        let acct = db.stmt("SELECT account_pk FROM thread WHERE thread_pk = ?1"); bind(acct, 1, t.0); step(acct); let a = Int(sqlite3_column_int64(acct, 0)) - 1; sqlite3_reset(acct)
        let ms_ = db.stmt("SELECT m.msg_pk FROM message m JOIN message_label ml ON ml.msg_pk = m.msg_pk WHERE m.thread_pk = ?1 AND ml.label_pk = ?2")
        bind(ms_, 1, t.0); bind(ms_, 2, labelPK(a, 0)); var ids: [Int64] = []
        while sqlite3_step(ms_) == SQLITE_ROW { ids.append(sqlite3_column_int64(ms_, 0)) }; sqlite3_reset(ms_)
        for id in ids { let o = db.stmt("INSERT OR REPLACE INTO overlay(msg_pk, label_pk, want) VALUES(?,?,0)"); bind(o, 1, id); bind(o, 2, labelPK(a, 0)); run(o) }
        let u = db.stmt("UPDATE thread SET labels = replace(labels, ?2, ',') WHERE thread_pk = ?1"); bind(u, 1, t.0); bind(u, 2, ",\(labelPK(a, 0)),"); run(u)
        for view in [inboxView, labelPK(a, 0), splitVIP, splitNews, splitOther] {
            let d = db.stmt("DELETE FROM view_thread WHERE view_pk = ?1 AND sort_key = ?2 AND thread_pk = ?3"); bind(d, 1, view); bind(d, 2, t.1); bind(d, 3, t.0); run(d)
            if sqlite3_changes(db.h) > 0 {
                let c = db.stmt("UPDATE view_count SET threads = threads - 1, unread = unread - ?2 WHERE view_pk = ?1"); bind(c, 1, view); bind(c, 2, t.2); run(c)
            }
        }
        db.exec("COMMIT")
    }
    var one: [Double] = []
    for t in targets.prefix(300) { let a = now(); archive(t); one.append(ms(a, now())) }
    print("triage write path (index.sqlite, WAL, synchronous=NORMAL):")
    stats("archive one conversation, one transaction each", one)
    // The same, group-committed: 20 actions that arrived within one tick share a transaction.
    var grouped: [Double] = []
    var rest = Array(targets.dropFirst(300))
    while rest.count >= 20 {
        let chunk = Array(rest.prefix(20)); rest.removeFirst(20)
        let a = now()
        db.exec("BEGIN IMMEDIATE")
        for t in chunk {
            let d = db.stmt("DELETE FROM view_thread WHERE view_pk = ?1 AND sort_key = ?2 AND thread_pk = ?3"); bind(d, 1, inboxView); bind(d, 2, t.1); bind(d, 3, t.0); run(d)
            let o = db.stmt("INSERT OR REPLACE INTO overlay(msg_pk, label_pk, want) VALUES(?,?,0)"); bind(o, 1, t.0); bind(o, 2, 1); run(o)
        }
        db.exec("COMMIT")
        grouped.append(ms(a, now()))
    }
    stats("20 archives in one transaction (simplified rows)", grouped)

    // 2. Readers under write: one thread ingests 50-message transactions continuously (the backfill),
    //    another runs the inbox page query on its own connection, a third the search.
    let stop = DispatchSemaphore(value: 0)
    var readerTimes: [Double] = [], searchTimes: [Double] = [], writerTimes: [Double] = []
    let group = DispatchGroup()
    var running = true
    let lock = NSLock()
    func isRunning() -> Bool { lock.lock(); defer { lock.unlock() }; return running }
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        let r = DB(path, readonly: true); applyPragmasReader(r)
        while isRunning() { let a = now(); _ = page(r, view: unifiedAllMail); readerTimes.append(ms(a, now())); usleep(2000) }
        group.leave()
    }
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        let r = DB(path, readonly: true); applyPragmasReader(r)
        var rr = RNG(42); let vocab = Vocab(count: 120_000, rng: &rr)
        var i = 0
        while isRunning() {
            let word = String(decoding: vocab.words[200 + (i * 37) % 3000], as: UTF8.self); i += 1
            let s = r.stmt("SELECT m.thread_pk FROM msg_fts f JOIN message m ON m.fts_rowid = f.rowid WHERE f.msg_fts MATCH ?1 AND m.vis = 0 ORDER BY f.rowid DESC LIMIT 100")
            bind(s, 1, "\(word.prefix(3))*"); let a = now(); while sqlite3_step(s) == SQLITE_ROW {}; searchTimes.append(ms(a, now())); sqlite3_reset(s); usleep(3000)
        }
        group.leave()
    }
    var gen = Generator(); gen.nextThread = db.scalarInt("SELECT max(thread_pk) FROM thread") + 1; gen.nextMsg = db.scalarInt("SELECT max(msg_pk) FROM message") + 1
    gen.rng = RNG(0xFEED)
    let writer = IndexWriter(db: db, withFTS: true)
    var maxWal: Int64 = 0; var added = 0
    let w0 = now()
    while ms(w0, now()) < 20_000 {
        let a = now(); db.exec("BEGIN IMMEDIATE"); var inBatch = 0
        while inBatch < 50 {
            var msgs = gen.thread(recency: 0.2 + gen.rng.unit() * 0.5)
            // Avoid colliding with fts rowids already in the store: shift into a fresh millisecond range.
            for i in msgs.indices { msgs[i].date += 7 }
            if (try? { writer.insertThreadSafe(msgs, gen: &gen) }()) != nil { inBatch += msgs.count; added += msgs.count }
        }
        writer.flushCounts(); db.exec("COMMIT"); writerTimes.append(ms(a, now()))
        maxWal = max(maxWal, fileSize(path + "-wal"))
    }
    lock.lock(); running = false; lock.unlock()
    group.wait(); _ = stop
    print("readers under a writer ingesting continuously for 20 s (+\(added) messages):")
    stats("writer: 50-message ingest transaction", writerTimes)
    stats("reader A: all-mail first page, own connection", readerTimes)
    stats("reader B: 3-char prefix search, own connection", searchTimes)
    print("  largest WAL seen with wal_autocheckpoint=1000 while two readers were active: \(mb(maxWal))")
    var c0 = now(); db.exec("PRAGMA wal_checkpoint(PASSIVE)"); print(String(format: "  checkpoint(PASSIVE) after the run: %.1f ms", ms(c0, now())))
    c0 = now(); db.exec("PRAGMA wal_checkpoint(TRUNCATE)"); print(String(format: "  checkpoint(TRUNCATE): %.1f ms; WAL now %@", ms(c0, now()), mb(fileSize(path + "-wal"))))

    // 3. A reader that never ends its transaction pins the WAL: how big it grows in 5 s of ingest.
    let pin = DB(path, readonly: true); applyPragmasReader(pin)
    pin.exec("BEGIN"); _ = pin.scalarInt("SELECT count(*) FROM account")
    let p0 = now(); var pinned: Int64 = 0
    while ms(p0, now()) < 5_000 {
        db.exec("BEGIN IMMEDIATE"); var inBatch = 0
        while inBatch < 50 { var msgs = gen.thread(recency: 0.3); for i in msgs.indices { msgs[i].date += 11 }; writer.insertThreadSafe(msgs, gen: &gen); inBatch += msgs.count }
        writer.flushCounts(); db.exec("COMMIT"); pinned = max(pinned, fileSize(path + "-wal"))
    }
    print("  WAL after 5 s of ingest while one reader held a read transaction open: \(mb(pinned)) (it cannot be checkpointed past that reader)")
    pin.exec("COMMIT")
    c0 = now(); db.exec("PRAGMA wal_checkpoint(TRUNCATE)"); print(String(format: "  checkpoint(TRUNCATE) once it let go: %.1f ms", ms(c0, now())))

    // 4. Deleting messages from a contentless-delete FTS index (trash purge, account removal).
    var del: [Double] = []
    let victims = db.stmt("SELECT msg_pk, fts_rowid FROM message WHERE fts_rowid IS NOT NULL ORDER BY msg_pk DESC LIMIT 2000")
    var ids: [(Int64, Int64)] = []
    while sqlite3_step(victims) == SQLITE_ROW { ids.append((sqlite3_column_int64(victims, 0), sqlite3_column_int64(victims, 1))) }; sqlite3_reset(victims)
    var k = 0
    while k + 50 <= ids.count {
        let a = now(); db.exec("BEGIN IMMEDIATE")
        for (pk, f) in ids[k..<(k + 50)] {
            var s = db.stmt("DELETE FROM msg_fts WHERE rowid = ?1"); bind(s, 1, f); run(s)
            s = db.stmt("DELETE FROM message_label WHERE msg_pk = ?1"); bind(s, 1, pk); run(s)
            s = db.stmt("DELETE FROM message WHERE msg_pk = ?1"); bind(s, 1, pk); run(s)
        }
        db.exec("COMMIT"); del.append(ms(a, now())); k += 50
    }
    stats("delete 50 messages (row, labels, FTS entry) per transaction", del)
}

extension IndexWriter {
    /// Like insertThread, but tolerant of an fts rowid already present (the write test adds to an existing store).
    func insertThreadSafe(_ msgs: [Msg], gen: inout Generator) {
        var fresh = msgs
        for i in fresh.indices { fresh[i].date += Int64(gen.rng.int(900_000)) }
        insertThread(fresh, gen: &gen)
    }
}

// MARK: - fsync (the intent database: one tiny commit per user action)

func fsync(dir: String) {
    for (name, pragmas) in [("WAL + synchronous=NORMAL", "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;"),
                            ("WAL + synchronous=FULL", "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;"),
                            ("WAL + synchronous=FULL + fullfsync", "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA fullfsync=ON; PRAGMA checkpoint_fullfsync=ON;")] {
        let path = dir + "/intent_test.sqlite"
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        let db = DB(path); db.exec(pragmas)
        db.exec("CREATE TABLE label_intent(account TEXT NOT NULL, gmail_msg_id TEXT NOT NULL, label_ref TEXT NOT NULL, want INTEGER NOT NULL, seq INTEGER NOT NULL, group_id TEXT NOT NULL, state INTEGER NOT NULL DEFAULT 0, attempts INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, PRIMARY KEY(account, gmail_msg_id, label_ref)) WITHOUT ROWID;")
        var times: [Double] = []
        for i in 0..<400 {
            let a = now()
            db.exec("BEGIN IMMEDIATE")
            for j in 0..<3 {   // a 3-message conversation archived: three assertions
                let s = db.stmt("INSERT OR REPLACE INTO label_intent(account, gmail_msg_id, label_ref, want, seq, group_id, created_at) VALUES(?,?,?,?,?,?,?)")
                bind(s, 1, "account0@example.com"); bind(s, 2, String(format: "%016x", i * 10 + j)); bind(s, 3, "INBOX"); bind(s, 4, 0); bind(s, 5, Int64(i)); bind(s, 6, UUID().uuidString); bind(s, 7, Int64(i)); run(s)
            }
            db.exec("COMMIT")
            times.append(ms(a, now()))
        }
        stats("intent commit, \(name)", times)
    }
}

// MARK: - cold

func cold(dir: String) {
    let path = dir + "/index.sqlite"
    var open: [Double] = [], firstPage: [Double] = []
    for _ in 0..<30 {
        let a = now()
        let db = DB(path, readonly: true); applyPragmasReader(db)
        let b = now()
        _ = page(db, view: unifiedViewPK(0))
        open.append(ms(a, b)); firstPage.append(ms(a, now()))
    }
    print("fresh connection each time (OS file cache warm — a true cold boot is slower and needs the device):")
    stats("open + pragmas", open)
    stats("open + pragmas + prepare + first inbox page", firstPage)
    // The alternative for the first frame: a small snapshot file with the last page drawn.
    struct Row: Codable { var thread: Int64; var account: Int; var date: Int64; var unread: Bool; var count: Int; var subject: String; var snippet: String; var senders: String; var labels: [Int] }
    let db = DB(path, readonly: true)
    let s = db.stmt(pageSQL); bind(s, 1, unifiedViewPK(0)); bind(s, 2, Int64.max); bind(s, 3, Int64.max); bind(s, 4, 50)
    var rows: [Row] = []
    while sqlite3_step(s) == SQLITE_ROW {
        rows.append(Row(thread: sqlite3_column_int64(s, 0), account: Int(sqlite3_column_int64(s, 1)), date: sqlite3_column_int64(s, 2), unread: sqlite3_column_int64(s, 3) == 1,
                        count: Int(sqlite3_column_int64(s, 4)), subject: String(cString: sqlite3_column_text(s, 6)), snippet: String(cString: sqlite3_column_text(s, 7)),
                        senders: String(cString: sqlite3_column_text(s, 8)), labels: [1, 2, 3]))
    }
    let snap = dir + "/first-page.json"
    let data = try! JSONEncoder().encode(rows); try! data.write(to: URL(fileURLWithPath: snap), options: .atomic)
    var json: [Double] = [], plist: [Double] = []
    for _ in 0..<200 { let a = now(); let d = try! Data(contentsOf: URL(fileURLWithPath: snap)); _ = try! JSONDecoder().decode([Row].self, from: d); json.append(ms(a, now())) }
    let pdata = try! PropertyListEncoder().encode(rows); let psnap = dir + "/first-page.plist"; try! pdata.write(to: URL(fileURLWithPath: psnap))
    for _ in 0..<200 { let a = now(); let d = try! Data(contentsOf: URL(fileURLWithPath: psnap)); _ = try! PropertyListDecoder().decode([Row].self, from: d); plist.append(ms(a, now())) }
    print("  first-page snapshot file: \(rows.count) rows, \(data.count) bytes JSON")
    stats("read + decode snapshot (JSON)", json)
    stats("read + decode snapshot (binary plist)", plist)
}

// MARK: - triage with explicit checkpoints, and a triage write queued behind an ingest batch

func triage(dir: String) {
    let path = dir + "/index.sqlite"
    let db = DB(path); applyPragmas(db, writer: true)
    db.exec("PRAGMA wal_autocheckpoint=0")
    let inboxView = unifiedViewPK(0)
    var targets: [(Int64, Int64, Int64)] = []
    let s = db.stmt("SELECT thread_pk, sort_key, unread FROM view_thread WHERE view_pk = ?1 ORDER BY sort_key DESC LIMIT 1200"); bind(s, 1, inboxView)
    while sqlite3_step(s) == SQLITE_ROW { targets.append((sqlite3_column_int64(s, 0), sqlite3_column_int64(s, 1), sqlite3_column_int64(s, 2))) }
    sqlite3_reset(s)
    func archive(_ t: (Int64, Int64, Int64)) {
        db.exec("BEGIN IMMEDIATE")
        let acct = db.stmt("SELECT account_pk FROM thread WHERE thread_pk = ?1"); bind(acct, 1, t.0); step(acct); let a = Int(sqlite3_column_int64(acct, 0)) - 1; sqlite3_reset(acct)
        let ms_ = db.stmt("SELECT m.msg_pk FROM message m JOIN message_label ml ON ml.msg_pk = m.msg_pk WHERE m.thread_pk = ?1 AND ml.label_pk = ?2")
        bind(ms_, 1, t.0); bind(ms_, 2, labelPK(a, 0)); var ids: [Int64] = []
        while sqlite3_step(ms_) == SQLITE_ROW { ids.append(sqlite3_column_int64(ms_, 0)) }; sqlite3_reset(ms_)
        for id in ids { let o = db.stmt("INSERT OR REPLACE INTO overlay(msg_pk, label_pk, want) VALUES(?,?,0)"); bind(o, 1, id); bind(o, 2, labelPK(a, 0)); run(o) }
        let u = db.stmt("UPDATE thread SET labels = replace(labels, ?2, ',') WHERE thread_pk = ?1"); bind(u, 1, t.0); bind(u, 2, ",\(labelPK(a, 0)),"); run(u)
        for view in [inboxView, labelPK(a, 0), splitVIP, splitNews, splitOther] {
            let d = db.stmt("DELETE FROM view_thread WHERE view_pk = ?1 AND sort_key = ?2 AND thread_pk = ?3"); bind(d, 1, view); bind(d, 2, t.1); bind(d, 3, t.0); run(d)
        }
        db.exec("COMMIT")
    }
    var one: [Double] = []
    for t in targets.prefix(1000) { let a = now(); archive(t); one.append(ms(a, now())) }
    print("triage write path, wal_autocheckpoint=0 (checkpoints run explicitly, never inside a user action's commit):")
    stats("archive one conversation, one transaction each", one)
    print("  WAL after 1000 archives: \(mb(fileSize(path + "-wal")))")
    let c0 = now(); db.exec("PRAGMA wal_checkpoint(PASSIVE)"); print(String(format: "  explicit checkpoint(PASSIVE): %.2f ms", ms(c0, now())))
    // Unread recount for the badge after each change: the partial-index count for 12 views.
    var badge: [Double] = []
    for _ in 0..<200 {
        let a = now()
        for view in [unifiedViewPK(0), unifiedViewPK(2), unifiedViewPK(3), unifiedViewPK(10), unifiedViewPK(11), splitVIP, splitNews, splitOther, labelPK(0, 0), labelPK(1, 0), labelPK(2, 0), labelPK(3, 0)] {
            let c = db.stmt("SELECT count(*) FROM view_thread WHERE view_pk = ?1 AND unread = 1"); bind(c, 1, view); step(c); sqlite3_reset(c)
        }
        badge.append(ms(a, now()))
    }
    stats("unread recount for 12 views by partial index", badge)
}

// MARK: - search with the FTS index in its own file, joined to the index file by ATTACH

func searchSplit(searchDir: String, indexDir: String) {
    let db = DB(searchDir + "/index.sqlite", readonly: true)
    applyPragmasReader(db)
    db.exec("ATTACH DATABASE '\(indexDir)/index.sqlite' AS idx")
    var r = RNG(42)
    let vocab = Vocab(count: 120_000, rng: &r)
    func w(_ rank: Int) -> String { String(decoding: vocab.words[rank], as: UTF8.self) }
    let sql = "SELECT m.thread_pk, m.msg_pk FROM msg_fts f JOIN idx.message m ON m.fts_rowid = f.rowid WHERE f.msg_fts MATCH ?1 AND m.vis = 0 ORDER BY f.rowid DESC LIMIT 400"
    print("plan: \(db.plan(sql.replacingOccurrences(of: "?1", with: "'abc'")))")
    for (label, match) in [("2 chars", "\(w(3).prefix(2))*"), ("3 chars", "\(w(3).prefix(3))*"), ("common word", "\"\(w(3))\""), ("mid word", "\"\(w(900))\""), ("two words", "\"\(w(5))\" AND \"\(w(9))\"")] {
        var times: [Double] = []
        for _ in 0..<40 {
            let s = db.stmt(sql); bind(s, 1, match)
            let a = now(); var seen = Set<Int64>()
            while seen.count < 50, sqlite3_step(s) == SQLITE_ROW { seen.insert(sqlite3_column_int64(s, 0)) }
            times.append(ms(a, now())); sqlite3_reset(s)
        }
        stats("split files, \(label)", times)
    }
}

// MARK: - main

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: mailstore_spike <build|read|fts|ftssize|write|fsync|cold> <dir> [messages]"); exit(2) }
let n = args.count > 3 ? Int(args[3]) ?? 200_000 : 200_000
print("sqlite \(String(cString: sqlite3_libversion())), FTS5=\(sqlite3_compileoption_used("ENABLE_FTS5")), threadsafe=\(sqlite3_threadsafe())")
switch args[1] {
case "build": build(dir: args[2], messages: n)
case "buildnofts": build(dir: args[2], messages: n, withFTS: false, batch: args.count > 4 ? Int(args[4]) ?? 50 : 50)
case "triage": triage(dir: args[2])
case "searchsplit": searchSplit(searchDir: args[2], indexDir: args[3])
case "read": read(dir: args[2])
case "fts": fts(dir: args[2])
case "ftssize": ftssize(dir: args[2], messages: n)
case "write": write(dir: args[2])
case "fsync": fsync(dir: args[2])
case "cold": cold(dir: args[2])
default: print("unknown command")
}
