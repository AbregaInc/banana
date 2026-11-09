#if !BANANA_PUBLIC
import Foundation
import GRDB

/// Bounded keyset reads from writer-prepared membership. Retained history stays on disk;
/// the caller supplies the last key to continue without OFFSET or retaining prior pages.
struct MailIndexReader: Sendable {
    let stores: MailStores
    enum Failure: Error { case invalidLimit, unsupportedGroup, corruptSummary }

    static func viewKey(_ view: MailViewKey) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(view), as: UTF8.self)
    }

    func page(_ request: PageRequest) async throws -> [IndexRow] {
        try await stores.index.read { try Self.page(request, in: $0) }
    }

    static func page(_ request: PageRequest, in db: Database, includingBoundary: Bool = false) throws -> [IndexRow] {
        guard (1...MailTuning.listCap).contains(request.limit) else { throw Failure.invalidLimit }
        guard (request.before?.group ?? 0) == 0 else { throw Failure.unsupportedGroup }
        let key = try Self.viewKey(request.view)
        guard let viewPK = try Int64.fetchOne(db, sql: "SELECT view_pk FROM view WHERE key=?", arguments: [key]) else { return [] }
        let scope = try Scope(request, in: db)
        if scope.isEmpty { return [] }
        var predicates = [scope.view, "v.sort_key > 0"]
        var arguments: [(any DatabaseValueConvertible)?] = []
        scope.constrain(&predicates, &arguments)
        Self.filters(request, predicates: &predicates, arguments: &arguments)
        if let before = request.before {
            predicates.append("(v.sort_key, v.tie) \(includingBoundary ? "<=" : "<") (?, ?)")
            arguments += [before.sortKey, before.tie]
        }
        arguments.append(request.limit)
        let sql = """
            SELECT t.thread_pk, a.email, t.gmail_id, v.sort_key, v.tie, v.unread,
                   t.message_count, t.flags, t.subject, t.snippet, t.people, t.people_total,
                   t.labels, t.wake_at, t.returned_at, t.waiting_until, t.pending,
                   t.last_date, t.recipients, t.recipients_total, t.arrival_seq
            \(scope.from)
            WHERE \(predicates.joined(separator: " AND "))
            ORDER BY v.sort_key DESC, v.tie DESC LIMIT ?
            """
        return try Row.fetchAll(db, sql: sql, arguments: StatementArguments([viewPK] + arguments)).map(Self.decode)
    }

    func counts(_ request: PageRequest) async throws -> ViewCounts {
        try await stores.index.read { try Self.counts(request, in: $0) }
    }

    static func counts(_ request: PageRequest, in db: Database) throws -> ViewCounts {
        let key = try Self.viewKey(request.view)
        let none = ViewCounts(unread: 0, total: MailCount(value: 0, isAtLeast: false), stillLoading: 0)
        guard let viewPK = try Int64.fetchOne(db, sql: "SELECT view_pk FROM view WHERE key=?", arguments: [key]) else { return none }
        let scope = try Scope(request, in: db)
        if scope.isEmpty { return none }
        var predicates = [scope.view]
        var arguments: [(any DatabaseValueConvertible)?] = []
        scope.constrain(&predicates, &arguments)
        Self.filters(request, predicates: &predicates, arguments: &arguments)
        let base = "\(scope.from) WHERE \(predicates.joined(separator: " AND "))"
        let values = StatementArguments([viewPK] + arguments)
        if scope.fromThreads {
            // Every row of a small scope is read once, so one pass counts all three.
            let row = try Row.fetchOne(db, sql: """
                SELECT count(*) FILTER (WHERE v.sort_key > 0), count(*) FILTER (WHERE v.unread=1 AND v.sort_key > 0),
                       count(*) FILTER (WHERE v.sort_key <= 0) \(base)
                """, arguments: values)
            let total: Int = row?[0] ?? 0
            return ViewCounts(unread: row?[1] ?? 0, total: MailCount(value: min(10000, total), isAtLeast: total > 10000), stillLoading: row?[2] ?? 0)
        }
        let total = try Int.fetchOne(db, sql: "SELECT count(*) FROM (SELECT 1 \(base) AND v.sort_key > 0 LIMIT 10001)", arguments: values) ?? 0
        // Unread counts what the list shows: a conversation known only by id (a stub, key <= 0)
        // is not listed, so it is not counted either. The badge and the Inbox number read this.
        let unread = try Int.fetchOne(db, sql: "SELECT count(*) \(base) AND v.unread=1 AND v.sort_key > 0", arguments: values) ?? 0
        let loading = try Int.fetchOne(db, sql: "SELECT count(*) \(base) AND v.sort_key <= 0", arguments: values) ?? 0
        return ViewCounts(unread: unread, total: MailCount(value: min(10000, total), isAtLeast: total > 10000), stillLoading: loading)
    }

    /// The accounts a read may show, applied before paging and counting, never by filtering an
    /// already limited result. Which side the read starts from follows the scope's size: a view
    /// is walked in its order and stops at the page's last row, which costs a few rows when the
    /// scope fills the view and every row of the view when the scope is a small part of it, at the
    /// far end. So a scope of at most `threadSideBound` conversations is read from its own threads
    /// (the account's index, then each one's place in the view, sorted), and anything larger from
    /// the view. Both give the same rows in the same order.
    struct Scope {
        static let threadSideBound = 10_000
        /// nil: every account. Empty: none.
        let accounts: [Int64]?
        let fromThreads: Bool
        var isEmpty: Bool { accounts?.isEmpty == true }

        init(_ request: PageRequest, in db: Database) throws {
            var emails: Set<String>?
            if let allowed = request.allowedAccounts { emails = Set(allowed.map { $0.lowercased() }) }
            if let account = request.account?.lowercased() { emails = emails.map { $0.intersection([account]) } ?? [account] }
            guard let emails else { accounts = nil; fromThreads = false; return }
            guard !emails.isEmpty else { accounts = []; fromThreads = false; return }
            let list = emails.sorted()
            accounts = try Int64.fetchAll(db, sql: "SELECT account_pk FROM account WHERE email IN (\(Self.slots(list.count))) ORDER BY account_pk",
                                          arguments: StatementArguments(list))
            guard let accounts, !accounts.isEmpty else { fromThreads = false; return }
            let size = try Int.fetchOne(db, sql: "SELECT count(*) FROM (SELECT 1 FROM thread WHERE account_pk IN (\(Self.slots(accounts.count))) LIMIT ?)",
                                        arguments: StatementArguments(accounts + [Int64(Self.threadSideBound + 1)])) ?? 0
            fromThreads = size <= Self.threadSideBound
        }

        /// The view's key is the first parameter of `from` and `view` together, in either shape.
        var view: String { fromThreads ? "1" : "v.view_pk = ?" }
        var from: String {
            fromThreads
                ? "FROM thread t CROSS JOIN view_thread v INDEXED BY view_thread_by_thread ON v.thread_pk=t.thread_pk AND v.view_pk=? JOIN account a ON a.account_pk=t.account_pk"
                : "FROM view_thread v JOIN thread t ON t.thread_pk=v.thread_pk JOIN account a ON a.account_pk=t.account_pk"
        }

        func constrain(_ predicates: inout [String], _ arguments: inout [(any DatabaseValueConvertible)?]) {
            guard let accounts else { return }
            predicates.append("t.account_pk IN (\(Self.slots(accounts.count)))")
            arguments.append(contentsOf: accounts.map { $0 as (any DatabaseValueConvertible)? })
        }

        static func slots(_ count: Int) -> String { Array(repeating: "?", count: count).joined(separator: ",") }
    }

    private static func filters(_ request: PageRequest, predicates: inout [String],
                                arguments: inout [(any DatabaseValueConvertible)?]) {
        if request.filters.contains(.unread) { predicates.append("v.unread = 1") }
        for (filter, flag) in [(MailFilter.starred, MailThreadFlags.starred), (.important, .important), (.noReply, .lastIsMine)] {
            if request.filters.contains(filter) {
                predicates.append("(t.flags & ?) != 0"); arguments.append(flag.rawValue)
            }
        }
    }

    /// Apply account scope before paging/counting, never by filtering an already
    /// limited result. An explicit empty set means no accounts, not all accounts.
    static func constrainAccounts(_ accounts: Set<String>?, predicates: inout [String],
                                  arguments: inout [(any DatabaseValueConvertible)?]) {
        guard let accounts else { return }
        let ids = Set(accounts.map { $0.lowercased() }).sorted()
        guard !ids.isEmpty else { predicates.append("0"); return }
        predicates.append("a.email IN (" + Array(repeating: "?", count: ids.count).joined(separator: ",") + ")")
        arguments.append(contentsOf: ids.map { $0 as (any DatabaseValueConvertible)? })
    }

    static func decode(_ row: Row) throws -> IndexRow {
        func people(_ column: Int) throws -> [SummaryPerson] {
            guard let json: String = row[column] else { return [] }
            guard let result = try? JSONDecoder().decode([SummaryPerson].self, from: Data(json.utf8)) else {
                throw Failure.corruptSummary
            }
            return result
        }
        let labels: String? = row[12]
        let labelPKs = try (labels ?? "").split(separator: ",").map { value -> Int64 in
            guard let pk = Int64(value) else { throw Failure.corruptSummary }
            return pk
        }
        return IndexRow(threadPK: row[0], account: row[1], thread: row[2], sortKey: row[3],
            tie: row[4], unread: row[5], messageCount: row[6], flags: MailThreadFlags(rawValue: row[7]),
            subject: row[8] ?? "", snippet: MailSnippet.display(row[9] ?? ""), people: try people(10), peopleTotal: row[11],
            labelPKs: labelPKs, wakeAt: row[13], returnedAt: row[14], waitingUntil: row[15], pending: row[16],
            lastDate: row[17], recipients: try people(18), recipientsTotal: row[19],
            actionBoundary: row.count > 20 ? row[20] : nil)
    }
}

#endif
