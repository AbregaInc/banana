#if !BANANA_PUBLIC
import Foundation
import GRDB

/// The body half of local search (MAIL-ENGINE 4.6): each prepared message's own text in
/// `search.sqlite`, contentless, beside the header index that `index.sqlite` keeps by trigger
/// (`MailLocalSearchSchema`). The text stays in `blobs.sqlite`; this file holds only the index.
///
/// **The row id is the date.** `internal_date << 20 | (msg_pk & 0xFFFFF)`, so FTS5 hands matches
/// back newest first without sorting and a search stops after a short scan whatever the number
/// of hits; `body_doc` maps it back to the message. A match counts only while its message says
/// it is indexed (`fts_state = 2`), so a removed message, or a reused `msg_pk`, never matches
/// text that is not its own.
enum MailBodySearchSchema {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1-body-search") { db in
            // contentless_delete needs SQLite 3.43; an older one keeps its own copy of the text.
            let version = try String.fetchOne(db, sql: "SELECT sqlite_version()") ?? "0"
            let parts = version.split(separator: ".").compactMap { Int($0) }
            let contentless = (parts.first ?? 0, parts.dropFirst().first ?? 0) >= (3, 43)
            try db.execute(sql: """
                CREATE VIRTUAL TABLE msg_fts USING fts5(body,
                  \(contentless ? "content='', contentless_delete=1," : "")
                  tokenize='unicode61 remove_diacritics 2', prefix='2 3');
                CREATE TABLE body_doc(rowid INTEGER PRIMARY KEY, msg_pk INTEGER NOT NULL);
                CREATE INDEX body_doc_by_message ON body_doc(msg_pk);
                """)
        }
    }

    static func registerIndex(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v15-body-search-queue") { db in
            // The indexer's queue: prepared bodies not yet in search.sqlite, newest first.
            try db.execute(sql: "CREATE INDEX message_body_fts_queue ON message(internal_date DESC) WHERE prep_state = 2 AND fts_state < 2")
        }
    }

    static func rowID(date: Int64?, message: Int64) -> Int64 {
        (max(0, date ?? 0) << 20) | (message & 0xFFFFF)
    }
}

/// Indexes prepared bodies in batches, newest first, off the main thread: a read of the queue,
/// one `search.sqlite` transaction, then the writer marks them indexed. A crash between the two
/// leaves them queued, and indexing one again replaces its entry. It keeps up with bodies
/// arriving in bulk by draining while there is work and yielding between batches; nothing it does
/// touches the main actor, and the mark it writes changes no list.
actor MailSearchIndexer {
    private let stores: MailStores
    private let markIndexed: @Sendable ([Int64]) async throws -> Void
    private var task: Task<Void, Never>?
    private var again = false
    var pause: Duration { ProcessInfo.processInfo.isLowPowerModeEnabled ? .milliseconds(250) : .milliseconds(25) }

    init(stores: MailStores, markIndexed: @escaping @Sendable ([Int64]) async throws -> Void) {
        self.stores = stores; self.markIndexed = markIndexed
    }

    nonisolated func kick() { Task { await self.start() } }
    nonisolated func stop() { Task { await self.cancel() } }

    private func start() {
        again = true
        guard task == nil else { return }
        task = Task(priority: .utility) { await self.drain() }
    }
    private func cancel() { task?.cancel(); task = nil }

    private func drain() async {
        while again, !Task.isCancelled {
            again = false
            do {
                while !Task.isCancelled, try await indexBatch() > 0 { try await Task.sleep(for: pause) }
            } catch { break }
        }
        task = nil
    }

    /// One batch. Returns how many messages it took off the queue.
    @discardableResult
    func indexBatch(limit: Int = MailKnobs.indexerBatchMessages) async throws -> Int {
        let queued = try await stores.index.read { db in
            try Row.fetchAll(db, sql: """
                SELECT m.msg_pk,m.internal_date,a.email,m.gmail_id FROM message m
                JOIN account a ON a.account_pk=m.account_pk
                WHERE m.prep_state=2 AND m.fts_state<2 ORDER BY m.internal_date DESC LIMIT ?
                """, arguments: [limit]).map { row -> (pk: Int64, date: Int64?, account: String, id: String) in
                (row[0], row[1], row[2], row[3])
            }
        }
        guard !queued.isEmpty else { return 0 }
        try Task.checkCancellation()
        let texts: [Int64: String] = try await stores.blobs.read { db in
            var result: [Int64: String] = [:]
            for message in queued {
                guard let data = try Data.fetchOne(db, sql: "SELECT text FROM prepared WHERE account=? AND gmail_id=?",
                                                   arguments: [message.account, message.id]),
                      let text = String(data: try MailBlobCodec.decode(data), encoding: .utf8) else { continue }
                result[message.pk] = String(text.prefix(16_000))
            }
            return result
        }
        try Task.checkCancellation()
        try await stores.searchWriter.write { db in
            for message in queued {
                for old in try Int64.fetchAll(db, sql: "SELECT rowid FROM body_doc WHERE msg_pk=?", arguments: [message.pk]) {
                    try db.execute(sql: "DELETE FROM msg_fts WHERE rowid=?", arguments: [old])
                }
                try db.execute(sql: "DELETE FROM body_doc WHERE msg_pk=?", arguments: [message.pk])
                guard let text = texts[message.pk], !text.isEmpty else { continue }
                let rowID = MailBodySearchSchema.rowID(date: message.date, message: message.pk)
                // Another message at the same millisecond with the same low bits: the newer write wins.
                try db.execute(sql: "DELETE FROM msg_fts WHERE rowid=?", arguments: [rowID])
                try db.execute(sql: "INSERT OR REPLACE INTO body_doc(rowid,msg_pk) VALUES (?,?)", arguments: [rowID, message.pk])
                try db.execute(sql: "INSERT INTO msg_fts(rowid,body) VALUES (?,?)", arguments: [rowID, text])
            }
        }
        try await markIndexed(queued.map(\.pk))
        return queued.count
    }

    /// The writer's half: marks these messages indexed, if their body is still the prepared one.
    static func mark(_ messages: [Int64], in db: Database) throws -> MailStoreChange {
        guard !messages.isEmpty else { return MailStoreChange() }
        try db.execute(sql: "UPDATE message SET fts_state=2,fts_dirty=0 WHERE prep_state=2 AND msg_pk IN ("
                       + Array(repeating: "?", count: messages.count).joined(separator: ",") + ")",
                       arguments: StatementArguments(messages))
        return MailStoreChange()
    }
}

/// The device's answer to a search: header matches and body matches, one conversation once.
enum MailLocalSearch {
    /// Messages a body search reads before it says there may be more.
    static let bodyScan = 400

    static func rows(_ query: MailLocalSearchQuery, stores: MailStores) async throws -> (rows: [IndexRow], more: Bool) {
        let header = try await MailIndexReader(stores: stores).search(query)
        guard query.bodyMatch != nil, query.definition?.canRun != false else { return (header, header.count == query.limit) }
        let body = try await stores.searchReader.read { try bodyThreads(query, in: $0) }
        let known = Set(header.map(\.threadPK))
        let missing = body.threads.filter { !known.contains($0) }
        var all = header
        if !missing.isEmpty {
            all += try await stores.index.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT t.thread_pk,a.email,t.gmail_id,t.last_date,t.tie,t.unread_count>0,
                           t.message_count,t.flags,t.subject,t.snippet,t.people,t.people_total,
                           t.labels,t.wake_at,t.returned_at,t.waiting_until,t.pending,
                           t.last_date,t.recipients,t.recipients_total,t.arrival_seq
                    FROM thread t JOIN account a ON a.account_pk=t.account_pk
                    WHERE t.thread_pk IN (\(Array(repeating: "?", count: missing.count).joined(separator: ",")))
                    """, arguments: StatementArguments(missing)).map(MailIndexReader.decode)
            }
        }
        all.sort { ($0.sortKey, $0.tie) > ($1.sortKey, $1.tie) }
        let more = header.count == query.limit || body.more || all.count > query.limit
        return (Array(all.prefix(query.limit)), more)
    }

    /// Conversations whose messages' bodies match, newest message first, at most `query.limit`.
    /// Runs on the search reader: `search.sqlite` with `index.sqlite` attached as `idx`.
    static func bodyThreads(_ query: MailLocalSearchQuery, in db: Database) throws -> (threads: [Int64], more: Bool) {
        guard let match = query.bodyMatch else { return ([], false) }
        var predicates = ["msg_fts MATCH ?", "t.last_date > 0"]
        var arguments: [(any DatabaseValueConvertible)?] = [match]
        MailIndexReader.conditions(query, predicates: &predicates, arguments: &arguments)
        for person in query.definition?.terms.filter({ $0.field == "person" }) ?? [] {
            predicates.append("(coalesce(m.from_name,'') || ' ' || coalesce(m.from_addr,'')) LIKE ? ESCAPE '\\'")
            let escaped = person.value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            arguments.append("%" + escaped + "%")
        }
        if let before = query.before {
            // A message is never newer than its conversation's newest.
            predicates.append("f.rowid < ?"); arguments.append(MailBodySearchSchema.rowID(date: before.sortKey + 1, message: 0))
            predicates.append("(t.last_date,t.tie) < (?,?)"); arguments += [before.sortKey, before.tie]
        }
        arguments.append(bodyScan)
        let rows = try Row.fetchAll(db, sql: """
            SELECT t.thread_pk FROM msg_fts f
            JOIN body_doc d ON d.rowid=f.rowid
            JOIN \(MailStores.attachedIndexName).message m ON m.msg_pk=d.msg_pk AND m.fts_state=2
            JOIN \(MailStores.attachedIndexName).thread t ON t.thread_pk=m.thread_pk
            JOIN \(MailStores.attachedIndexName).account a ON a.account_pk=t.account_pk
            WHERE \(predicates.joined(separator: " AND "))
            ORDER BY f.rowid DESC LIMIT ?
            """, arguments: StatementArguments(arguments))
        var seen = Set<Int64>(), threads: [Int64] = []
        for row in rows {
            let pk: Int64 = row[0]
            if seen.insert(pk).inserted { threads.append(pk) }
            if threads.count > query.limit { break }
        }
        return (Array(threads.prefix(query.limit)), rows.count == bodyScan || threads.count > query.limit)
    }
}

#endif
