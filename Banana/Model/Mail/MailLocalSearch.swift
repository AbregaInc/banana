#if !BANANA_PUBLIC
import Foundation
import GRDB

/// Initial offline search: all retained message headers/snippets, not just loaded rows.
/// Literal word-prefix AND matching; operators belong to a future query-parser layer.
struct MailLocalSearchQuery: Equatable, Sendable {
    var text: String
    var account: String?
    var filters: Set<MailFilter> = []
    var before: MailOrderKey?
    var limit: Int = 50

    var definition: LiveFilter? { LiveFilter.fromSearchExpression(text, scope: "mail") }
    var match: String? {
        let words = (definition?.text ?? text).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        var parts = words.map { "\"" + $0 + "\"*" }
        for person in definition?.terms.filter({ $0.field == "person" }) ?? [] {
            let senderWords = person.value.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            if !senderWords.isEmpty { parts.append("sender : (" + senderWords.map { "\"" + $0 + "\"*" }.joined(separator: " AND ") + ")") }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " AND ")
    }
}

enum MailLocalSearchSchema {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v2-local-header-search") { db in
            // Atomic with message updates, so a deleted/edited message never leaves a stale hit.
            // Full prepared bodies retain their separate search-store boundary.
            try db.execute(sql: "CREATE VIRTUAL TABLE mail_header_search USING fts5(subject,snippet,sender,recipients, tokenize='unicode61 remove_diacritics 2')")
            func fields(_ prefix: String) -> String {
                """
                \(prefix)msg_pk, \(prefix)subject, \(prefix)snippet,
                coalesce(\(prefix)from_name,'') || ' ' || coalesce(\(prefix)from_addr,''),
                (SELECT group_concat(j.value,' ') FROM json_tree(coalesce(\(prefix)recipients,'{}')) j WHERE j.type='text')
                """
            }
            try db.execute(sql: "INSERT INTO mail_header_search(rowid,subject,snippet,sender,recipients) SELECT \(fields("")) FROM message")
            try db.execute(sql: """
                CREATE TRIGGER mail_search_insert AFTER INSERT ON message BEGIN
                    INSERT INTO mail_header_search(rowid,subject,snippet,sender,recipients) SELECT \(fields("new."));
                END;
                CREATE TRIGGER mail_search_update AFTER UPDATE OF subject,snippet,from_name,from_addr,recipients ON message BEGIN
                    DELETE FROM mail_header_search WHERE rowid=old.msg_pk;
                    INSERT INTO mail_header_search(rowid,subject,snippet,sender,recipients) SELECT \(fields("new."));
                END;
                CREATE TRIGGER mail_search_delete AFTER DELETE ON message BEGIN
                    DELETE FROM mail_header_search WHERE rowid=old.msg_pk;
                END;
                """)
        }
    }
}

extension MailIndexReader {
    func search(_ query: MailLocalSearchQuery) async throws -> [IndexRow] {
        try await stores.index.read { try Self.search(query, in: $0) }
    }

    static func search(_ query: MailLocalSearchQuery, in db: Database, includingBoundary: Bool = false) throws -> [IndexRow] {
        guard (1...MailTuning.listCap).contains(query.limit), (query.before?.group ?? 0) == 0 else { throw Failure.invalidLimit }
        let definition = query.definition
        guard definition?.canRun != false else { return [] }
        guard query.match != nil || definition?.isEmpty == false else { return [] }
        var predicates = ["t.last_date > 0"]
        var arguments: [(any DatabaseValueConvertible)?] = []
        if let match = query.match { predicates.append("mail_header_search MATCH ?"); arguments.append(match) }
        if let interval = definition?.interval() {
            predicates.append("t.last_date >= ? AND t.last_date < ?")
            arguments += [Int64(interval.start.timeIntervalSince1970 * 1000), Int64(interval.end.timeIntervalSince1970 * 1000)]
        }
        for term in definition?.terms ?? [] {
            if term.field == "unread" { predicates.append(term.value == "true" ? "t.unread_count > 0" : "t.unread_count = 0") }
            if let flag = ["starred": MailThreadFlags.starred, "important": .important][term.field] {
                predicates.append("(t.flags & ?) \(term.value == "true" ? "!=" : "=") 0"); arguments.append(flag.rawValue)
            }
        }
        if let account = query.account { predicates.append("a.email=?"); arguments.append(account.lowercased()) }
        if query.filters.contains(.unread) { predicates.append("t.unread_count > 0") }
        for (filter, flag) in [(MailFilter.starred, MailThreadFlags.starred), (.important, .important), (.noReply, .lastIsMine)] where query.filters.contains(filter) {
            predicates.append("(t.flags & ?) != 0"); arguments.append(flag.rawValue)
        }
        if let before = query.before {
            predicates.append("(t.last_date,t.tie) \(includingBoundary ? "<=" : "<") (?,?)"); arguments += [before.sortKey, before.tie]
        }
        arguments.append(query.limit)
        let from = query.match != nil
            ? "mail_header_search JOIN message m ON m.msg_pk=mail_header_search.rowid JOIN thread t ON t.thread_pk=m.thread_pk JOIN account a ON a.account_pk=t.account_pk"
            : "thread t JOIN account a ON a.account_pk=t.account_pk"
        return try Row.fetchAll(db, sql: """
            WITH hits AS (
                SELECT DISTINCT t.thread_pk,t.last_date,t.tie
                FROM \(from)
                WHERE \(predicates.joined(separator: " AND "))
                ORDER BY t.last_date DESC,t.tie DESC LIMIT ?
            )
            SELECT t.thread_pk,a.email,t.gmail_id,t.last_date,t.tie,t.unread_count>0,
                   t.message_count,t.flags,t.subject,t.snippet,t.people,t.people_total,
                   t.labels,t.wake_at,t.returned_at,t.waiting_until,t.pending,
                   t.last_date,t.recipients,t.recipients_total,t.arrival_seq
            FROM hits JOIN thread t ON t.thread_pk=hits.thread_pk
            JOIN account a ON a.account_pk=t.account_pk
            ORDER BY t.last_date DESC,t.tie DESC
            """, arguments: StatementArguments(arguments)).map(Self.decode)
    }
}

#endif
