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
        var predicates = ["v.view_pk = ?", "v.sort_key > 0"]
        var arguments: [(any DatabaseValueConvertible)?] = [viewPK]
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
            FROM view_thread v JOIN thread t ON t.thread_pk=v.thread_pk
            JOIN account a ON a.account_pk=t.account_pk
            WHERE \(predicates.joined(separator: " AND "))
            ORDER BY v.sort_key DESC, v.tie DESC LIMIT ?
            """
        return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)).map(Self.decode)
    }

    func counts(_ request: PageRequest) async throws -> ViewCounts {
        let key = try Self.viewKey(request.view)
        return try await stores.index.read { db in
            guard let viewPK = try Int64.fetchOne(db, sql: "SELECT view_pk FROM view WHERE key=?", arguments: [key]) else {
                return ViewCounts(unread: 0, total: MailCount(value: 0, isAtLeast: false), stillLoading: 0)
            }
            var predicates = ["v.view_pk = ?"]
            var arguments: [(any DatabaseValueConvertible)?] = [viewPK]
            Self.filters(request, predicates: &predicates, arguments: &arguments)
            let base = """
                FROM view_thread v JOIN thread t ON t.thread_pk=v.thread_pk
                JOIN account a ON a.account_pk=t.account_pk
                WHERE \(predicates.joined(separator: " AND "))
                """
            let values = StatementArguments(arguments)
            let total = try Int.fetchOne(db, sql: "SELECT count(*) FROM (SELECT 1 \(base) AND v.sort_key > 0 LIMIT 10001)", arguments: values) ?? 0
            let unread = try Int.fetchOne(db, sql: "SELECT count(*) \(base) AND v.unread=1", arguments: values) ?? 0
            let loading = try Int.fetchOne(db, sql: "SELECT count(*) \(base) AND v.sort_key <= 0", arguments: values) ?? 0
            return ViewCounts(unread: unread, total: MailCount(value: min(10000, total), isAtLeast: total > 10000), stillLoading: loading)
        }
    }

    private static func filters(_ request: PageRequest, predicates: inout [String],
                                arguments: inout [(any DatabaseValueConvertible)?]) {
        if let account = request.account {
            predicates.append("a.email = ?"); arguments.append(account.lowercased())
        }
        if request.filters.contains(.unread) { predicates.append("v.unread = 1") }
        for (filter, flag) in [(MailFilter.starred, MailThreadFlags.starred), (.important, .important), (.noReply, .lastIsMine)] {
            if request.filters.contains(filter) {
                predicates.append("(t.flags & ?) != 0"); arguments.append(flag.rawValue)
            }
        }
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
            subject: row[8] ?? "", snippet: row[9] ?? "", people: try people(10), peopleTotal: row[11],
            labelPKs: labelPKs, wakeAt: row[13], returnedAt: row[14], waitingUntil: row[15], pending: row[16],
            lastDate: row[17], recipients: try people(18), recipientsTotal: row[19],
            actionBoundary: row.count > 20 ? row[20] : nil)
    }
}

#endif
