import Foundation
import GRDB

// Frozen initial query for controlled same-process comparison. Not production code.
extension MailIndexReader {
    func searchReference(_ query: MailLocalSearchQuery) async throws -> [IndexRow] {
        guard (1...MailTuning.listCap).contains(query.limit), (query.before?.group ?? 0) == 0 else { throw Failure.invalidLimit }
        guard let match = query.match else { return [] }
        return try await stores.index.read { db in
            var predicates = ["mail_header_search MATCH ?", "t.last_date > 0"]
            var arguments: [(any DatabaseValueConvertible)?] = [match]
            if let account = query.account { predicates.append("a.email=?"); arguments.append(account.lowercased()) }
            if query.filters.contains(.unread) { predicates.append("t.unread_count > 0") }
            for (filter, flag) in [(MailFilter.starred, MailThreadFlags.starred), (.important, .important), (.noReply, .lastIsMine)] where query.filters.contains(filter) {
                predicates.append("(t.flags & ?) != 0"); arguments.append(flag.rawValue)
            }
            if let before = query.before {
                predicates.append("(t.last_date,t.tie) < (?,?)"); arguments += [before.sortKey, before.tie]
            }
            arguments.append(query.limit)
            return try Row.fetchAll(db, sql: """
                SELECT DISTINCT t.thread_pk,a.email,t.gmail_id,t.last_date,t.tie,t.unread_count>0,
                       t.message_count,t.flags,t.subject,t.snippet,t.people,t.people_total,
                       t.labels,t.wake_at,t.returned_at,t.waiting_until,t.pending,
                       t.last_date,t.recipients,t.recipients_total
                FROM mail_header_search JOIN message m ON m.msg_pk=mail_header_search.rowid
                JOIN thread t ON t.thread_pk=m.thread_pk JOIN account a ON a.account_pk=t.account_pk
                WHERE \(predicates.joined(separator: " AND "))
                ORDER BY t.last_date DESC,t.tie DESC LIMIT ?
                """, arguments: StatementArguments(arguments)).map(Self.decode)
        }
    }
}
