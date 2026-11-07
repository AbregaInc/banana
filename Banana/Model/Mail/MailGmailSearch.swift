#if !BANANA_PUBLIC
import Foundation
import GRDB

/// Gmail's half of a search (MAIL-ENGINE 9.4). The device answers at once; Gmail is asked
/// `settle` after the text stops changing, in the interactive lane (`/v1/mail/read`, paced at
/// the service), and its matches join the same list (`MailSearchMerge`).
///
/// A conversation Gmail found that the device does not hold yet is read at header level — the
/// newest matching message, 20 units — and stored as the fill would store it, so its row comes
/// from the index like any other, its header is in the local index from then on, and opening it
/// fetches the rest. At most `reads` header reads per step; the list asks for the next step as
/// it is scrolled toward the end (`askGmail`), and the next page of Gmail's listing is asked for
/// when the hits already listed are used up.
///
/// One session per query (text, account, filters), shared by the observations of that query
/// while the list grows. Every other query's session is cancelled with its requests when its
/// last observation goes.
@MainActor final class MailGmailSearch {
    struct Key: Hashable {
        var text: String
        var account: String?
        var filters: Set<MailFilter>
        init?(_ scope: MailScope) {
            guard case .search(let text) = scope.place else { return nil }
            self.text = text; account = scope.account?.lowercased(); filters = scope.filters
        }
    }
    struct Hit: Hashable, Sendable {
        var account: String
        var thread: String
        var message: String
    }
    enum Phase: Equatable { case waiting, asking, ready, failed, offline }

    final class Session {
        let key: Key
        let query: String
        let accounts: [String]
        var cursors: [String: String] = [:]
        var exhausted = Set<String>()
        var listed: [Hit] = []
        var threads = Set<String>()
        /// `listed[..<resolved]` can be read from the device.
        var resolved = 0
        /// Conversations this search brought to the device: found by Gmail, whatever the
        /// device's own index says of them now that their headers are stored.
        var brought = Set<MailConversationID>()
        var phase = Phase.waiting
        var task: Task<Void, Never>?
        /// The oldest row this search has delivered (`MailSearchMerge`).
        var frontier: MailOrderKey?
        var hasMore: Bool { resolved < listed.count || exhausted.count < accounts.count }
        init(key: Key, query: String, accounts: [String]) {
            self.key = key; self.query = query; self.accounts = accounts
        }
    }

    struct Dependencies {
        var api: any GmailAPI
        var token: @Sendable (String) async throws -> String
        /// Stores header-level reads of one account, as the fill does.
        var store: @Sendable ([FetchedMessage], String) async throws -> Void
        /// Accounts Gmail may be asked for now: connected, granted, on.
        var accounts: @MainActor () -> [String]
        /// A session changed without a store commit: read the search lists again.
        var changed: @MainActor () -> Void
    }

    var settle: Duration = .milliseconds(400)
    var reads = 10
    var hitsPerStep = 50
    var pageSize = 50
    private let stores: MailStores
    private let deps: Dependencies
    private var sessions: [Key: Session] = [:]

    init(stores: MailStores, dependencies: Dependencies) {
        self.stores = stores; deps = dependencies
    }

    // MARK: - Driving

    /// The session for this search, made — and asked after `settle` — when there is something to
    /// ask Gmail and an account to ask. `retry` restarts one that failed (a new observation of
    /// the same search: the list's Retry, or Retry on its last row).
    func session(for scope: MailScope, retry: Bool) -> Session? {
        guard let key = Key(scope) else { return nil }
        if let session = sessions[key] {
            if retry, [.failed, .offline].contains(session.phase) { start(session, after: nil) }
            return session
        }
        guard let query = MailGmailQuery.translate(key.text, filters: key.filters) else { return nil }
        let accounts = deps.accounts().map { $0.lowercased() }.filter { key.account == nil || $0 == key.account }
        guard !accounts.isEmpty else { return nil }
        let session = Session(key: key, query: query, accounts: accounts)
        sessions[key] = session
        start(session, after: settle)
        return session
    }

    /// `askGmail` for a search: now rather than after `settle`, the next step, or again after a failure.
    func ask(_ scope: MailScope) {
        guard let session = session(for: scope, retry: true) else { return }
        switch session.phase {
        case .asking: return
        case .ready: if session.hasMore { start(session, after: nil) }
        case .waiting, .failed, .offline: start(session, after: nil)
        }
    }

    /// Keeps the sessions of these scopes; every other one is cancelled with its requests.
    func keep(_ scopes: [MailScope]) {
        let wanted = Set(scopes.compactMap(Key.init))
        for (key, session) in sessions where !wanted.contains(key) {
            session.task?.cancel(); sessions[key] = nil
        }
    }

    func cancelAll() { keep([]) }

    /// After a snapshot of `scope` was delivered: nothing at or above its last row goes away.
    func delivered(_ snapshot: MailListSnapshot) {
        guard snapshot.scope.before == nil, let key = Key(snapshot.scope), let session = sessions[key],
              let last = snapshot.rows.last?.key else { return }
        session.frontier = session.frontier.map { min($0, last) } ?? last
    }

    private func start(_ session: Session, after delay: Duration?) {
        session.task?.cancel()
        session.phase = delay == nil ? .asking : .waiting
        session.task = Task { [weak self, weak session] in
            if let delay {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let session else { return }
                session.phase = .asking
                self?.deps.changed()
            }
            guard let self, let session else { return }
            let phase: Phase
            do { try await self.step(session); phase = .ready }
            catch { phase = Self.isOffline(error) ? .offline : .failed }
            guard !Task.isCancelled, self.sessions[session.key] === session else { return }
            session.phase = phase; session.task = nil
            self.deps.changed()
        }
    }

    /// Lists until there are hits to resolve, then resolves the next of them.
    private func step(_ session: Session) async throws {
        while session.resolved >= session.listed.count, session.exhausted.count < session.accounts.count {
            for account in session.accounts where !session.exhausted.contains(account) {
                try Task.checkCancellation()
                let token = try await deps.token(account)
                let page = try await deps.api.listMessages(token: token, labelIDs: [], query: session.query,
                    includeSpamTrash: false, pageToken: session.cursors[account], maxResults: pageSize)
                try Task.checkCancellation()
                for reference in page.messages ?? [] {
                    guard let id = reference.id, !id.isEmpty, let thread = reference.threadId, !thread.isEmpty,
                          session.threads.insert(account + "\u{0}" + thread).inserted else { continue }
                    session.listed.append(Hit(account: account, thread: thread, message: id))
                }
                if let next = page.nextPageToken, !next.isEmpty, next != session.cursors[account] {
                    session.cursors[account] = next
                } else { session.exhausted.insert(account) }
            }
        }
        let batch = Array(session.listed[session.resolved..<min(session.listed.count, session.resolved + hitsPerStep)])
        guard !batch.isEmpty else { return }
        let held = try await stores.index.read { try Self.held(batch, in: $0) }
        var missing: [Hit] = []
        var through = batch.count
        for (index, hit) in batch.enumerated() where !held.contains(hit) {
            if missing.count == reads { through = index; break }
            missing.append(hit)
        }
        if !missing.isEmpty {
            let read = try await Self.readHeaders(missing, api: deps.api, token: deps.token)
            for account in Set(read.map(\.account)).sorted() {
                try Task.checkCancellation()
                let fetched = read.filter { $0.account == account }.map {
                    FetchedMessage(wire: $0.message, floor: 0, headers: MessageHeaders(payload: $0.message.payload), structure: nil)
                }
                for message in read where message.account == account {
                    if let thread = message.message.threadId { session.brought.insert(MailConversationID(account: account, thread: thread)) }
                }
                try await deps.store(fetched, account)
            }
        }
        try Task.checkCancellation()
        session.resolved += through
    }

    /// Header reads, four at a time, off the main actor. A message Gmail no longer has is skipped.
    private static func readHeaders(_ hits: [Hit], api: any GmailAPI,
                                    token: @escaping @Sendable (String) async throws -> String)
        async throws -> [(account: String, message: GmailMessage)] {
        let work = Task.detached(priority: .userInitiated) { () async throws -> [(account: String, message: GmailMessage)] in
            var tokens: [String: String] = [:]
            for account in Set(hits.map(\.account)) { tokens[account] = try await token(account) }
            let access = tokens
            return try await withThrowingTaskGroup(of: (Int, GmailMessage?).self) { group in
                func add(_ index: Int) {
                    let hit = hits[index]
                    group.addTask {
                        try Task.checkCancellation()
                        do {
                            let value = try await api.message(token: access[hit.account]!, id: hit.message, format: .header)
                            guard value.id == hit.message, value.threadId == hit.thread else { throw GmailError.malformed }
                            return (index, value)
                        } catch GmailError.notFound { return (index, nil) }
                    }
                }
                var next = 0
                while next < min(4, hits.count) { add(next); next += 1 }
                var result: [(Int, GmailMessage)] = []
                while let (index, value) = try await group.next() {
                    if let value { result.append((index, value)) }
                    if next < hits.count { add(next); next += 1 }
                }
                return result.sorted { $0.0 < $1.0 }.map { (account: hits[$0.0].account, message: $0.1) }
            }
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    static func isOffline(_ error: Error) -> Bool {
        if let error = error as? GmailError { return error == .networkDisabled || error == .unknownOutcome }
        if let error = error as? URLError {
            return [.notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
                    .dnsLookupFailed, .timedOut, .dataNotAllowed, .internationalRoamingOff].contains(error.code)
        }
        return false
    }

    // MARK: - Reading

    /// The search list: the device's matches at once, Gmail's as they are resolved.
    func snapshot(_ scope: MailScope, limit: Int, fresh: Bool, allowedAccounts: Set<String>, through: UInt64,
                  row: (IndexRow) -> MailRow) async throws -> MailListSnapshot {
        guard case .search(let text) = scope.place else { throw MailIndexReader.Failure.unsupportedGroup }
        let query = MailLocalSearchQuery(text: text, account: scope.account, filters: scope.filters,
                                         before: scope.before, limit: limit, allowedAccounts: allowedAccounts)
        let local = try await MailLocalSearch.rows(query, stores: stores)
        let session = self.session(for: scope, retry: fresh)
        var remote: [IndexRow] = []
        if let session, session.resolved > 0 {
            let hits = Array(session.listed.prefix(session.resolved))
            remote = try await stores.index.read {
                try MailIndexReader.threads(hits.map { (account: $0.account, thread: $0.thread) }, filters: scope.filters,
                                            before: scope.before, allowedAccounts: allowedAccounts, in: $0)
            }
        }
        var merged = MailSearchMerge.merge(local: local.rows.map(row), localMore: local.more,
            remote: remote.map(row), gmailMore: session?.hasMore ?? false,
            frontier: scope.before == nil ? session?.frontier : nil, limit: limit)
        if let brought = session?.brought, !brought.isEmpty {
            for index in merged.rows.indices where !merged.rows[index].fromGmailSearch && brought.contains(merged.rows[index].id) {
                merged.rows[index].fromGmailSearch = true; merged.added += 1
            }
        }
        let status: MailRemoteSearch? = session.map { session in
            switch session.phase {
            case .waiting, .asking: return .pending
            case .failed: return .failed
            case .offline: return .offline
            case .ready: return .done(added: merged.added, more: session.hasMore)
            }
        }
        return MailListSnapshot(scope: scope, rows: merged.rows,
            total: MailCount(value: merged.rows.count, isAtLeast: merged.hasMore),
            hasMore: merged.hasMore, stillLoading: 0, isRebuilding: false,
            remote: status, coverage: nil, appliedThrough: through)
    }

    /// The hits whose conversation the device holds: it has a dated row for it.
    nonisolated static func held(_ hits: [Hit], in db: Database) throws -> Set<Hit> {
        let rows = try MailIndexReader.threads(hits.map { (account: $0.account, thread: $0.thread) }, filters: [], before: nil,
                                               allowedAccounts: nil, in: db)
        let present = Set(rows.map { $0.account + "\u{0}" + $0.thread })
        return Set(hits.filter { present.contains($0.account + "\u{0}" + $0.thread) })
    }
}

extension MailIndexReader {
    /// These conversations' rows, where the device holds them, filtered as a list is.
    static func threads(_ ids: [(account: String, thread: String)], filters: Set<MailFilter>, before: MailOrderKey?,
                        allowedAccounts: Set<String>?, in db: Database) throws -> [IndexRow] {
        var byAccount: [String: [String]] = [:]
        for id in ids { byAccount[id.account.lowercased(), default: []].append(id.thread) }
        var result: [IndexRow] = []
        for (account, threads) in byAccount.sorted(by: { $0.key < $1.key }) {
            for offset in stride(from: 0, to: threads.count, by: 400) {
                let chunk = Array(threads[offset..<min(offset + 400, threads.count)])
                var predicates = ["t.last_date > 0", "a.email = ?",
                                  "t.gmail_id IN (" + Array(repeating: "?", count: chunk.count).joined(separator: ",") + ")"]
                var arguments: [(any DatabaseValueConvertible)?] = [account]
                arguments += chunk.map { $0 as (any DatabaseValueConvertible)? }
                constrainAccounts(allowedAccounts, predicates: &predicates, arguments: &arguments)
                if filters.contains(.unread) { predicates.append("t.unread_count > 0") }
                for (filter, flag) in [(MailFilter.starred, MailThreadFlags.starred), (.important, .important), (.noReply, .lastIsMine)]
                where filters.contains(filter) {
                    predicates.append("(t.flags & ?) != 0"); arguments.append(flag.rawValue)
                }
                if let before { predicates.append("(t.last_date,t.tie) < (?,?)"); arguments += [before.sortKey, before.tie] }
                result += try Row.fetchAll(db, sql: """
                    SELECT t.thread_pk,a.email,t.gmail_id,t.last_date,t.tie,t.unread_count>0,
                           t.message_count,t.flags,t.subject,t.snippet,t.people,t.people_total,
                           t.labels,t.wake_at,t.returned_at,t.waiting_until,t.pending,
                           t.last_date,t.recipients,t.recipients_total,t.arrival_seq
                    FROM thread t JOIN account a ON a.account_pk=t.account_pk
                    WHERE \(predicates.joined(separator: " AND "))
                    """, arguments: StatementArguments(arguments)).map(decode)
            }
        }
        return result
    }
}

#endif
