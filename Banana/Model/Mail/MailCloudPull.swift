#if !BANANA_PUBLIC
import Foundation
import GRDB

/// Message content from Banana Cloud, many at a time (MAIL-CLOUD-SYNC §5a). The cloud fills every
/// message inside its window ahead of any device and says so in the feed (`cloud_content`); this
/// pulls it, in four tiers, one bulk request at a time:
///
/// 0. a conversation being opened — every message of it not here yet, before anything else;
/// 1. new Inbox mail known only by id (`arrivals`): not listed until its headers are here, so it
///    comes next, whatever the work pace, and is asked again after a failure until it is here;
/// 2. the rows on screen and the few the scroll is heading to;
/// 3. the rest the feed flagged, newest first across accounts (only while Mail is in use, or a
///    push's window).
///
/// A pull asks Google nothing and costs no Gmail quota. What the cloud does not hold yet comes
/// back as `fallback`: for tiers 0 to 2 the caller reads it the per-message way (which, for an
/// account on the cloud mailbox, the cloud also keeps); for tier 3 the flag is cleared and the feed
/// sets it again when the cloud has it. An account whose service has no cloud mailbox gets its
/// opened and on-screen ids straight back as fallback. A message whose text cannot be stored
/// here never holds back its batch: its headers go in, so its row is listed.
actor MailCloudPull {
    static let batch = 25
    /// Messages of one conversation taken at once: the reader shows the newest; older ones have
    /// their own Load control (as `wants` does).
    static let perConversation = 8

    enum Tier: Int, Comparable, Sendable {
        case opened = 0, arrivals = 1, screen = 2, fill = 3
        static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
    }
    struct Fallback: Equatable, Sendable { var id: MailMessageID; var urgent: Bool }
    struct Step: Equatable, Sendable {
        var tier: Tier?
        var stored: [MailMessageID] = []
        var fallback: [Fallback] = []
        /// Why messages of this batch, or the batch, could not be stored (error kinds, for the log).
        var problems: [String] = []
        /// Something was asked; another step may find more.
        var worked: Bool { tier != nil }
    }

    private let stores: MailStores
    private let loader: GmailConversationLoader
    private let source: any MailCloudFeedSource
    private let clock: @Sendable () -> Int64
    private let pace: @Sendable () -> MailWorkPace
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var opened: [MailMessageID] = []
    private var screen: [MailMessageID] = []
    private var inFlight = Set<MailMessageID>()
    private var retryAt: [String: Int64] = [:]          // per account, after a limit or an outage
    private var noCloud: [String: Int64] = [:]          // per account: the service has no bulk content until
    private var arrivalRetry: [MailMessageID: (at: Int64, attempts: Int)] = [:]   // arrivals not here yet
    /// New mail: a message the Inbox holds only by id, dated within this long before now.
    static let arrivalWindowMS: Int64 = 3 * 86_400_000
    /// After a pull that failed for want of a network (or a store that refused a batch).
    static let transientRetryMS: Int64 = 5_000
    /// The longest an arrival waits between attempts (they double from `transientRetryMS`).
    static let arrivalRetryMostMS: Int64 = 300_000

    /// `pace`: the work pace of invariant 31. Every message pulled is prepared as it is stored
    /// (`GmailConversationLoader.storeCloud`), so screen and fill batches pause after it as the pace
    /// says, and do not run while it says stop; an opened conversation is never held back.
    init(stores: MailStores, loader: GmailConversationLoader, source: any MailCloudFeedSource,
         clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
         pace: @escaping @Sendable () -> MailWorkPace = { .full },
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.stores = stores; self.loader = loader; self.source = source; self.clock = clock
        self.pace = pace; self.sleep = sleep
    }

    /// Whether the account syncs from the cloud mailbox (its feed has answered) and the service
    /// offers bulk content.
    func isCloud(_ account: String) async throws -> Bool {
        let account = account.lowercased()
        if let until = noCloud[account], until > clock() { return false }
        return try await stores.index.read { try MailCloudFeedIndex.state(account: account, in: $0) != nil }
    }

    /// The messages of these conversations whose text is not here, newest first, at most
    /// `perConversation` each. `prepareOnly`: content is stored, only preparing it is owed (local).
    private func missing(_ conversations: [MailConversationID]) async throws -> [(id: MailMessageID, thread: String, prepareOnly: Bool)] {
        try await stores.index.read { db in
            var out: [(id: MailMessageID, thread: String, prepareOnly: Bool)] = []
            for conversation in conversations {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT m.gmail_id, m.fetch_state FROM message m JOIN thread t ON t.thread_pk=m.thread_pk
                    JOIN account a ON a.account_pk=t.account_pk
                    WHERE a.email=? AND t.gmail_id=? AND (m.fetch_state<2 OR m.prep_state=0) AND m.vis!=4
                    ORDER BY m.internal_date DESC, m.msg_pk DESC LIMIT ?
                    """, arguments: [conversation.account.lowercased(), conversation.thread, Self.perConversation])
                for row in rows {
                    let state: Int = row[1]
                    out.append((id: MailMessageID(account: conversation.account.lowercased(), message: row[0]), thread: conversation.thread, prepareOnly: state == 2))
                }
            }
            return out
        }
    }

    /// Whether this device holds any row of the conversation.
    func holds(_ conversation: MailConversationID) async throws -> Bool {
        try await stores.index.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM thread t JOIN account a ON a.account_pk=t.account_pk
                WHERE a.email=? AND t.gmail_id=? AND t.message_count>0)
                """, arguments: [conversation.account.lowercased(), conversation.thread]) ?? false
        }
    }

    /// A conversation is being opened: its messages go first. Returns what must come the
    /// per-message way at once (another account, or only preparation owed).
    func open(_ conversation: MailConversationID) async throws -> [Fallback] {
        let wanted = try await missing([conversation])
        guard try await isCloud(conversation.account) else { return wanted.map { Fallback(id: $0.id, urgent: true) } }
        let pull = wanted.filter { !$0.prepareOnly }.map(\.id)
        opened.removeAll { pull.contains($0) }
        opened.insert(contentsOf: pull, at: 0)
        screen.removeAll { pull.contains($0) }
        return wanted.filter(\.prepareOnly).map { Fallback(id: $0.id, urgent: true) }
    }

    /// What is on screen now, and the rows the scroll heads to next, in that order. Replaces the
    /// last call: rows that scrolled away are no longer wanted. For an account without the cloud
    /// mailbox, the newest missing message of each conversation is returned for the per-message
    /// path (bounded by the caller's queue).
    func onScreen(_ conversations: [MailConversationID]) async throws -> [Fallback] {
        let wanted = try await missing(conversations)
        var cloud: [String: Bool] = [:]
        for account in Set(wanted.map(\.id.account)) { cloud[account] = try await isCloud(account) }
        var next: [MailMessageID] = [], fallback: [Fallback] = [], seenThreads = Set<String>()
        for item in wanted {
            if cloud[item.id.account] == true && !item.prepareOnly { next.append(item.id); continue }
            // The per-message way: the newest of each conversation only (the reader opens on it);
            // `missing` lists it first.
            if seenThreads.insert(item.id.account + "\u{0}" + item.thread).inserted {
                fallback.append(Fallback(id: item.id, urgent: false))
            }
        }
        screen = next.filter { !opened.contains($0) }
        return fallback
    }

    /// The next batch: one account, the highest tier first, nothing already in flight. Pure.
    static func plan(opened: [MailMessageID], arrivals: [MailMessageID] = [], screen: [MailMessageID], fill: [MailMessageID],
                     inFlight: Set<MailMessageID>, blocked: Set<String>, limit: Int = batch) -> (tier: Tier, ids: [MailMessageID])? {
        for (tier, list) in [(Tier.opened, opened), (.arrivals, arrivals), (.screen, screen), (.fill, fill)] {
            let free = list.filter { !inFlight.contains($0) && !blocked.contains($0.account) }
            guard let first = free.first else { continue }
            var seen = Set<MailMessageID>()
            let ids = free.filter { $0.account == first.account && seen.insert($0).inserted }.prefix(limit)
            return (tier, Array(ids))
        }
        return nil
    }

    /// The newest messages the feed flagged and this device has no text for, newest first across
    /// accounts: one account's backlog never keeps another's newer mail waiting.
    private func fillCandidates(limit: Int, blocked: Set<String>) async throws -> [MailMessageID] {
        let found: [(id: MailMessageID, date: Int64, pk: Int64)] = try await stores.index.read { db in
            var out: [(id: MailMessageID, date: Int64, pk: Int64)] = []
            for row in try Row.fetchAll(db, sql: "SELECT account_pk,email FROM account ORDER BY account_pk") {
                let owner: Int64 = row[0], account: String = row[1]
                guard !blocked.contains(account), try MailCloudFeedIndex.state(account: account, in: db) != nil else { continue }
                for item in try Row.fetchAll(db, sql: """
                    SELECT m.gmail_id, m.internal_date, m.msg_pk FROM message m INDEXED BY message_cloud_pull
                    WHERE m.account_pk=?
                      AND m.cloud_content=1 AND (m.fetch_state<2 OR m.prep_state=0) AND m.vis!=4 AND m.fetch_state<2
                      AND NOT EXISTS(SELECT 1 FROM held_removal h WHERE h.msg_pk=m.msg_pk)
                    ORDER BY m.internal_date DESC, m.msg_pk DESC LIMIT ?
                    """, arguments: [owner, limit]) {
                    out.append((id: MailMessageID(account: account, message: item[0]), date: item[1], pk: item[2]))
                }
            }
            return out
        }
        return found.sorted { ($0.date, $0.pk) > ($1.date, $1.pk) }.map(\.id)
    }

    /// New mail in the Inbox this device knows only by id (no sender, no subject, so not listed),
    /// newest first, on accounts the cloud mailbox serves, leaving out any waiting to be asked again.
    private func arrivalCandidates(now: Int64, blocked: Set<String>, limit: Int) async throws -> [MailMessageID] {
        let inbox = try MailIndexReader.viewKey(.unified(.inbox))
        let since = now - Self.arrivalWindowMS
        let found: [(id: MailMessageID, date: Int64, pk: Int64)] = try await stores.index.read { db in
            guard let view = try Int64.fetchOne(db, sql: "SELECT view_pk FROM view WHERE key=?", arguments: [inbox]) else { return [] }
            var out: [(id: MailMessageID, date: Int64, pk: Int64)] = []
            for row in try Row.fetchAll(db, sql: "SELECT account_pk,email FROM account ORDER BY account_pk") {
                let owner: Int64 = row[0], account: String = row[1]
                guard !blocked.contains(account), try MailCloudFeedIndex.state(account: account, in: db) != nil else { continue }
                // `message_sync_fill_newest`: the account's owed rows newer than the window's start.
                for item in try Row.fetchAll(db, sql: """
                    SELECT m.gmail_id, m.internal_date, m.msg_pk FROM message m
                    WHERE m.account_pk=? AND m.fetch_state=0 AND m.vis!=4 AND (m.fetch_state<2 OR m.prep_state=0)
                      AND m.internal_date>=?
                      AND EXISTS(SELECT 1 FROM view_thread v WHERE v.thread_pk=m.thread_pk AND v.view_pk=?)
                      AND NOT EXISTS(SELECT 1 FROM held_removal h WHERE h.msg_pk=m.msg_pk)
                    ORDER BY m.internal_date DESC, m.msg_pk DESC LIMIT ?
                    """, arguments: [owner, since, view, limit]) {
                    out.append((id: MailMessageID(account: account, message: item[0]), date: item[1], pk: item[2]))
                }
            }
            return out
        }
        // An arrival that is no longer one (here now, or out of the window) forgets its attempts.
        let current = Set(found.map(\.id))
        arrivalRetry = arrivalRetry.filter { blocked.contains($0.key.account) || current.contains($0.key) }
        return found.sorted { ($0.date, $0.pk) > ($1.date, $1.pk) }.map(\.id).filter { (arrivalRetry[$0]?.at ?? 0) <= now }
    }

    /// Arrivals not here after an attempt are asked again later, the wait doubling each time.
    private func deferArrivals(_ ids: [MailMessageID], now: Int64) {
        for id in ids {
            let attempts = (arrivalRetry[id]?.attempts ?? 0) + 1
            let wait = min(Self.arrivalRetryMostMS, Self.transientRetryMS << Int64(min(attempts - 1, 10)))
            arrivalRetry[id] = (at: now + wait, attempts: attempts)
        }
    }

    /// The soonest time something waiting may be asked again: an account after a failure or a
    /// limit, an arrival not here yet. Nil when nothing waits.
    func nextRetry() -> Int64? {
        let now = clock()
        return (retryAt.values.filter { $0 > now } + arrivalRetry.values.map(\.at).filter { $0 > now }).min()
    }

    /// One bulk request and what it brought. `fill`: tier 3 may run (Mail in use, or a push).
    func step(fill: Bool) async throws -> Step {
        let now = clock()
        let blocked = Set(retryAt.filter { $0.value > now }.keys).union(noCloud.filter { $0.value > now }.keys)
        let stopped = pace().pause(afterWorking: 0) == nil
        let arrivals = try await arrivalCandidates(now: now, blocked: blocked, limit: Self.batch * 2)
        var candidates: [MailMessageID] = []
        if fill && !stopped { candidates = try await fillCandidates(limit: Self.batch * 2, blocked: blocked) }
        guard let plan = Self.plan(opened: opened, arrivals: arrivals, screen: stopped ? [] : screen, fill: candidates,
                                   inFlight: inFlight, blocked: blocked) else {
            return Step(tier: nil)
        }
        let account = plan.ids[0].account
        inFlight.formUnion(plan.ids)
        defer { inFlight.subtract(plan.ids) }
        var step = Step(tier: plan.tier)
        /// Opened mail and arrivals do not wait on the cloud: they go the per-message way at once,
        /// and an arrival is asked again later.
        func urgentFallback(_ ids: [MailMessageID]) -> [Fallback] {
            guard plan.tier <= .arrivals else { return [] }
            if plan.tier == .arrivals { deferArrivals(ids, now: now) }
            return ids.map { Fallback(id: $0, urgent: true) }
        }
        let answers: [MailCloudContent]
        do {
            answers = try await source.contents(account: account, ids: plan.ids.map(\.message))
        } catch MailCloudFeedError.unavailable {
            // An older service: this account's opened and visible mail comes the per-message way.
            noCloud[account] = now + 600_000
            let taken = take(plan.ids, tier: plan.tier)
            step.fallback = plan.tier >= .screen ? taken.map { Fallback(id: $0, urgent: false) } : urgentFallback(taken)
            return step
        } catch GmailError.limited(_, let hint) {
            retryAt[account] = now + Int64(((hint.flatMap { $0.isFinite ? $0 : nil } ?? 30) * 1000).rounded())
            if plan.tier == .arrivals { deferArrivals(plan.ids, now: now) }
            return step
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A transient failure: asked again after `transientRetryMS`.
            retryAt[account] = now + Self.transientRetryMS
            step.problems = [GmailConversationLoader.describe(error)]
            step.fallback = urgentFallback(take(plan.ids, tier: plan.tier == .opened ? .opened : .fill))
            return step
        }
        var messages: [GmailMessage] = [], missing: [MailMessageID] = [], gone: [MailMessageID] = [], done = Set<MailMessageID>()
        for answer in answers {
            let id = MailMessageID(account: account, message: answer.id)
            switch answer {
            case .message(let message): messages.append(message)
            case .missing: missing.append(id); done.insert(id)
            case .gone: gone.append(id); done.insert(id)
            case .later: break
            }
        }
        let started = ContinuousClock.now
        let result: GmailConversationLoader.CloudStored
        do {
            result = try await loader.storeCloud(messages, account: account)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The batch could not be written here (the index or the blob store refused it): the
            // account is asked again shortly, opened mail and arrivals go the per-message way.
            retryAt[account] = now + Self.transientRetryMS
            step.problems = [GmailConversationLoader.describe(error)]
            step.fallback = urgentFallback(take(plan.ids, tier: plan.tier == .opened ? .opened : .fill))
            return step
        }
        if plan.tier >= .screen {
            let work = started.duration(to: .now).components
            if let pause = pace().pause(afterWorking: Double(work.seconds) + Double(work.attoseconds) / 1e18), pause > 0 { try await sleep(pause) }
        }
        let stored = result.stored.map { MailMessageID(account: account, message: $0) }
        let headed = Set(result.headersOnly.map { MailMessageID(account: account, message: $0) })
        step.stored = stored
        step.problems = result.problems
        done.formUnion(stored)
        // A message the cloud sent that could not be stored here (malformed, too large) goes the
        // per-message way, which has its own rules for those.
        let unstored = messages.compactMap(\.id).map { MailMessageID(account: account, message: $0) }.filter { !done.contains($0) }
        missing += unstored; done.formUnion(unstored)
        _ = take(Array(done), tier: plan.tier)
        switch plan.tier {
        case .opened, .screen:
            step.fallback = missing.map { Fallback(id: $0, urgent: plan.tier == .opened) }
        case .arrivals:
            // Stored, or listed now with its headers: done. What the cloud lacks comes the
            // per-message way at once; that and what Gmail deleted (its deletion arrives through
            // the feed) are asked again later, never in a loop.
            for id in stored { arrivalRetry[id] = nil }
            for id in headed { arrivalRetry[id] = nil }
            let owed = missing.filter { !headed.contains($0) }
            deferArrivals(owed + gone, now: now)
            step.fallback = owed.map { Fallback(id: $0, urgent: true) }
        case .fill:
            let cleared = missing.map(\.message)
            if !cleared.isEmpty {
                try await stores.index.write { db in
                    for id in cleared {
                        try db.execute(sql: "UPDATE message SET cloud_content=0 WHERE gmail_id=? AND account_pk=(SELECT account_pk FROM account WHERE email=?)",
                                       arguments: [id, account])
                    }
                }
            }
        }
        return step
    }

    /// Removes ids from their tier's list; returns those that were there.
    private func take(_ ids: [MailMessageID], tier: Tier) -> [MailMessageID] {
        let set = Set(ids)
        switch tier {
        case .opened: opened.removeAll { set.contains($0) }
        case .screen: screen.removeAll { set.contains($0) }
        case .arrivals, .fill: break
        }
        return ids
    }

    /// Opened and on-screen ids still waiting (tests, diagnostics).
    var pending: (opened: [MailMessageID], screen: [MailMessageID]) { (opened, screen) }
}

#endif
