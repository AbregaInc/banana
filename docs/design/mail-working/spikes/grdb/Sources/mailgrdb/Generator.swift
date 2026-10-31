// Extracted unchanged from ../../mailstore_spike.swift: the deterministic synthetic mailbox.
import Foundation
// MARK: - Deterministic random

struct RNG {
    var s: UInt64
    init(_ seed: UInt64) { s = seed }
    mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func chance(_ p: Double) -> Bool { unit() < p }
}

func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func ms(_ a: UInt64, _ b: UInt64) -> Double { Double(b - a) / 1_000_000 }
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
