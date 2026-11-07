#if !BANANA_PUBLIC
import Foundation
import GRDB

/// Message content from Banana Cloud, many at a time (MAIL-CLOUD-SYNC §5a). The cloud fills every
/// message inside its window ahead of any device and says so in the feed (`cloud_content`); this
/// pulls it, in three tiers, one bulk request at a time:
///
/// 0. a conversation being opened — every message of it not here yet, before anything else;
/// 1. the rows on screen and the few the scroll is heading to;
/// 2. the rest the feed flagged, newest first (only while Mail is in use, or a push's window).
///
/// A pull asks Google nothing and costs no Gmail quota. What the cloud does not hold yet comes
/// back as `fallback`: for tiers 0 and 1 the caller reads it the per-message way (which, for an
/// account on the cloud mailbox, the cloud also keeps); for tier 2 the flag is cleared and the feed
/// sets it again when the cloud has it. An account whose service has no cloud mailbox gets its
/// tier 0/1 ids straight back as fallback.
actor MailCloudPull {
    static let batch = 25
    /// Messages of one conversation taken at once: the reader shows the newest; older ones have
    /// their own Load control (as `wants` does).
    static let perConversation = 8

    enum Tier: Int, Comparable, Sendable {
        case opened = 0, screen = 1, fill = 2
        static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
    }
    struct Fallback: Equatable, Sendable { var id: MailMessageID; var urgent: Bool }
    struct Step: Equatable, Sendable {
        var tier: Tier?
        var stored: [MailMessageID] = []
        var fallback: [Fallback] = []
        /// Something was asked; another step may find more.
        var worked: Bool { tier != nil }
    }

    private let stores: MailStores
    private let loader: GmailConversationLoader
    private let source: any MailCloudFeedSource
    private let clock: @Sendable () -> Int64
    private var opened: [MailMessageID] = []
    private var screen: [MailMessageID] = []
    private var inFlight = Set<MailMessageID>()
    private var retryAt: [String: Int64] = [:]          // per account, after a limit or an outage
    private var noCloud: [String: Int64] = [:]          // per account: the service has no bulk content until

    init(stores: MailStores, loader: GmailConversationLoader, source: any MailCloudFeedSource,
         clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.stores = stores; self.loader = loader; self.source = source; self.clock = clock
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
    static func plan(opened: [MailMessageID], screen: [MailMessageID], fill: [MailMessageID],
                     inFlight: Set<MailMessageID>, blocked: Set<String>, limit: Int = batch) -> (tier: Tier, ids: [MailMessageID])? {
        for (tier, list) in [(Tier.opened, opened), (.screen, screen), (.fill, fill)] {
            let free = list.filter { !inFlight.contains($0) && !blocked.contains($0.account) }
            guard let first = free.first else { continue }
            var seen = Set<MailMessageID>()
            let ids = free.filter { $0.account == first.account && seen.insert($0).inserted }.prefix(limit)
            return (tier, Array(ids))
        }
        return nil
    }

    /// The newest messages the feed flagged and this device has no text for, across accounts.
    private func fillCandidates(limit: Int, blocked: Set<String>) async throws -> [MailMessageID] {
        try await stores.index.read { db in
            let accounts = try String.fetchAll(db, sql: "SELECT email FROM account ORDER BY account_pk")
            for account in accounts where !blocked.contains(account) {
                guard try MailCloudFeedIndex.state(account: account, in: db) != nil else { continue }
                let ids = try String.fetchAll(db, sql: """
                    SELECT m.gmail_id FROM message m INDEXED BY message_cloud_pull
                    WHERE m.account_pk=(SELECT account_pk FROM account WHERE email=?)
                      AND m.cloud_content=1 AND (m.fetch_state<2 OR m.prep_state=0) AND m.vis!=4 AND m.fetch_state<2
                      AND NOT EXISTS(SELECT 1 FROM held_removal h WHERE h.msg_pk=m.msg_pk)
                    ORDER BY m.internal_date DESC, m.msg_pk DESC LIMIT ?
                    """, arguments: [account, limit])
                if !ids.isEmpty { return ids.map { MailMessageID(account: account, message: $0) } }
            }
            return []
        }
    }

    /// One bulk request and what it brought. `fill`: tier 2 may run (Mail in use, or a push).
    func step(fill: Bool) async throws -> Step {
        let now = clock()
        let blocked = Set(retryAt.filter { $0.value > now }.keys).union(noCloud.filter { $0.value > now }.keys)
        var candidates: [MailMessageID] = []
        if fill { candidates = try await fillCandidates(limit: Self.batch * 2, blocked: blocked) }
        guard let plan = Self.plan(opened: opened, screen: screen, fill: candidates, inFlight: inFlight, blocked: blocked) else {
            return Step(tier: nil)
        }
        let account = plan.ids[0].account
        inFlight.formUnion(plan.ids)
        defer { inFlight.subtract(plan.ids) }
        var step = Step(tier: plan.tier)
        let answers: [MailCloudContent]
        do {
            answers = try await source.contents(account: account, ids: plan.ids.map(\.message))
        } catch MailCloudFeedError.unavailable {
            // An older service: this account's opened and visible mail comes the per-message way.
            noCloud[account] = now + 600_000
            step.fallback = take(plan.ids, tier: plan.tier).map { Fallback(id: $0, urgent: plan.tier == .opened) }
            return step
        } catch GmailError.limited(_, let hint) {
            retryAt[account] = now + Int64(((hint.flatMap { $0.isFinite ? $0 : nil } ?? 30) * 1000).rounded())
            return step
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A transient failure: opened mail is not left waiting on the cloud.
            retryAt[account] = now + 5_000
            if plan.tier == .opened { step.fallback = take(plan.ids, tier: .opened).map { Fallback(id: $0, urgent: true) } }
            return step
        }
        var messages: [GmailMessage] = [], missing: [MailMessageID] = [], done = Set<MailMessageID>()
        for answer in answers {
            let id = MailMessageID(account: account, message: answer.id)
            switch answer {
            case .message(let message): messages.append(message)
            case .missing: missing.append(id); done.insert(id)
            case .gone: done.insert(id)
            case .later: break
            }
        }
        let stored = try await loader.storeCloud(messages, account: account).map { MailMessageID(account: account, message: $0) }
        step.stored = stored
        done.formUnion(stored)
        // A message the cloud sent that could not be stored here (malformed, too large) goes the
        // per-message way, which has its own rules for those.
        let unstored = messages.compactMap(\.id).map { MailMessageID(account: account, message: $0) }.filter { !done.contains($0) }
        missing += unstored; done.formUnion(unstored)
        _ = take(Array(done), tier: plan.tier)
        switch plan.tier {
        case .opened, .screen:
            step.fallback = missing.map { Fallback(id: $0, urgent: plan.tier == .opened) }
        case .fill:
            let gone = missing.map(\.message)
            if !gone.isEmpty {
                try await stores.index.write { db in
                    for id in gone {
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
        case .fill: break
        }
        return ids
    }

    /// Opened and on-screen ids still waiting (tests, diagnostics).
    var pending: (opened: [MailMessageID], screen: [MailMessageID]) { (opened, screen) }
}

#endif
