#if !BANANA_PUBLIC
import Foundation
import GRDB

/// Durable enumeration state. Listings may add knowledge, but absence only queues
/// a per-message read. Every page and its continuation share one index transaction.
enum MailReconcileIndex {
    enum Failure: Error { case transactionRequired, invalidPage, invalidState, wrongAccount }
    struct State: Codable, Equatable, Sendable {
        var generation: Int64
        var labels: [String]
        var listing = 0 // labels.count is the final, unfiltered listing
        var pageToken: String?
        var maxPKAtStart: Int64
        var startedAt: UInt64
        var closeAfterPK: Int64 = 0
        var phase: Phase = .listing
        enum Phase: String, Codable, Sendable { case listing, closing, verifying }
        var label: String? { labels.indices.contains(listing) ? labels[listing] : nil }
    }

    static func state(account: String, in db: Database) throws -> State? {
        guard let text = try String.fetchOne(db, sql: "SELECT enum_state FROM account WHERE email=?", arguments: [account]) else { return nil }
        return try JSONDecoder().decode(State.self, from: Data(text.utf8))
    }

    /// The initial version enumerates everything, matching the current live source.
    /// Dated retention/claim listings must extend this state before a limited sync
    /// setting is exposed; a partial listing must never masquerade as a full one.
    static func begin(profile: GmailProfile, labels: [GmailLabel], account: String, in db: Database) throws -> State {
        guard db.isInsideTransaction else { throw Failure.transactionRequired }
        guard MailAddressRules.isValid(account), account == account.lowercased(),
              profile.emailAddress?.lowercased() == account else { throw Failure.wrongAccount }
        guard let position = profile.historyId, position > 0,
              profile.messagesTotal.map({ $0 >= 0 }) ?? true else { throw Failure.invalidPage }
        if let existing = try state(account: account, in: db) { return existing }
        _ = try MailLabelCatalog.replace(labels, account: account, in: db)
        let owner = try Row.fetchOne(db, sql: "SELECT account_pk,checkpoint,enum_generation FROM account WHERE email=?", arguments: [account])!
        let pk: Int64 = owner[0], generation: Int64 = owner[2]
        guard generation < Int64.max else { throw Failure.invalidState }
        let raw: String? = owner[1]
        let checkpoint = max(raw.flatMap(GmailNumber.unsigned) ?? 0, position)
        let priority = ["INBOX", "UNREAD", "STARRED", "DRAFT", "SENT", "IMPORTANT"]
        let ids = labels.compactMap(\.id).sorted {
            let l = priority.firstIndex(of: $0) ?? ($0 == "TRASH" || $0 == "SPAM" ? 100 : 50)
            let r = priority.firstIndex(of: $1) ?? ($1 == "TRASH" || $1 == "SPAM" ? 100 : 50)
            return l == r ? $0 < $1 : l < r
        }
        let maxPK = try Int64.fetchOne(db, sql: "SELECT coalesce(max(msg_pk),0) FROM message WHERE account_pk=?", arguments: [pk])!
        let value = State(generation: generation + 1, labels: ids, maxPKAtStart: maxPK, startedAt: checkpoint)
        try db.execute(sql: "UPDATE account SET checkpoint=?,profile_total=?,enum_generation=?,enum_checkpoint=? WHERE account_pk=?",
            arguments: [String(checkpoint), profile.messagesTotal, value.generation, String(checkpoint), pk])
        try save(value, account: account, in: db)
        return value
    }

    static func apply(_ page: GmailIDPage, account: String, expected: State, floor: UInt64,
                      nowMS: Int64, reuseStatements: Bool = true,
                      reuseProjectionStatements: Bool = true, in db: Database) throws -> (State, MailStoreChange) {
        let pk = try owner(account: account, expected: expected, in: db)
        guard expected.phase == .listing, floor >= expected.startedAt, nowMS >= 0,
              page.nextPageToken != "", page.nextPageToken == nil || page.nextPageToken != expected.pageToken,
              (page.messages?.count ?? 0) <= 500 else { throw Failure.invalidPage }
        let current = try String.fetchOne(db, sql: "SELECT checkpoint FROM account WHERE account_pk=?", arguments: [pk])
        guard let current = current.flatMap(GmailNumber.unsigned), floor <= current else { throw Failure.invalidState }
        var next = expected
        var touched = Set<Int64>(), seen = Set<String>()
        let labelPK = try expected.label.map { id -> Int64 in
            guard let value = try Int64.fetchOne(db, sql: "SELECT label_pk FROM label WHERE account_pk=? AND gmail_id=?", arguments: [pk, id]) else { throw Failure.invalidState }
            return value
        } ?? 0
        // Fixed SQL strings keep the connection-owned cache bounded. The uncached
        // policy is retained for same-workload performance/correctness comparisons.
        func statement(_ sql: String) throws -> Statement {
            try reuseStatements ? db.cachedStatement(sql: sql) : db.makeStatement(sql: sql)
        }
        for item in page.messages ?? [] {
            guard let id = item.id, !id.isEmpty, let threadID = item.threadId, !threadID.isEmpty,
                  seen.insert(id).inserted else { throw Failure.invalidPage }
            if try Bool.fetchOne(statement("SELECT EXISTS(SELECT 1 FROM tombstone WHERE account_pk=? AND gmail_id=?)"), arguments: [pk, id]) == true { continue }
            try statement("INSERT OR IGNORE INTO thread(account_pk,gmail_id,tie) VALUES(?,?,?)").execute(
                arguments: [pk, threadID, MailMessageImporter.tie(account: account, thread: threadID)])
            let thread = try Int64.fetchOne(statement("SELECT thread_pk FROM thread WHERE account_pk=? AND gmail_id=?"), arguments: [pk, threadID])!
            try statement("INSERT OR IGNORE INTO message(account_pk,gmail_id,thread_pk,history_id,fetch_class) VALUES(?,?,?,?,?)").execute(
                arguments: [pk, id, thread, String(floor), expected.label == "INBOX" ? 0 : 2])
            let row = try Row.fetchOne(statement("SELECT msg_pk,thread_pk,history_id,vis FROM message WHERE account_pk=? AND gmail_id=?"), arguments: [pk, id])!
            let message: Int64 = row[0], storedThread: Int64 = row[1], version: String? = row[2], visibility: Int = row[3]
            guard storedThread == thread else { throw Failure.invalidPage }
            if message <= expected.maxPKAtStart {
                try statement("INSERT OR IGNORE INTO enum_mark(account_pk,generation,label_pk,msg_pk) VALUES(?,?,?,?)").execute(
                    arguments: [pk, expected.generation, labelPK, message])
            }
            guard visibility != 4 else { continue }
            if labelPK != 0 {
                if (version.flatMap(GmailNumber.unsigned) ?? 0) > floor {
                    try queue(message, generation: expected.generation, nowMS: nowMS, in: db)
                } else {
                    try statement("INSERT OR IGNORE INTO message_label(msg_pk,label_pk) VALUES(?,?)").execute(arguments: [message, labelPK])
                    if db.changesCount > 0 { touched.insert(thread) }
                }
            }
        }
        if let token = page.nextPageToken { next.pageToken = token }
        else {
            next.pageToken = nil
            next.listing += 1
            if next.listing > next.labels.count { next.phase = .closing }
        }
        try save(next, account: account, in: db)
        var change = MailStoreChange()
        for thread in touched {
            change.formUnion(try MailIndexWriter.rebuildThread(thread, facts: MailMessageImporter.facts(threadPK: thread, in: db), myAddresses: [account], reuseStatements: reuseProjectionStatements, in: db))
        }
        return (next, change)
    }

    /// A rejected continuation restarts only its listing. Already observed marks
    /// remain positive evidence; restarting must never manufacture absence.
    static func restartListing(account: String, expected: State, in db: Database) throws -> State {
        _ = try owner(account: account, expected: expected, in: db)
        guard expected.phase == .listing, expected.pageToken != nil else { throw Failure.invalidState }
        var next = expected
        next.pageToken = nil
        try save(next, account: account, in: db)
        return next
    }

    /// A bounded close scan, including its bookmark. Newer history wins, and no
    /// absence can directly change visibility, labels, bodies or durable intent.
    static func closeBatch(account: String, expected: State, nowMS: Int64, in db: Database) throws -> State {
        let pk = try owner(account: account, expected: expected, in: db)
        guard expected.phase == .closing, nowMS >= 0 else { throw Failure.invalidState }
        let rows = try Row.fetchAll(db, sql: """
            SELECT msg_pk,history_id,vis FROM message
            WHERE account_pk=? AND msg_pk>? AND msg_pk<=? ORDER BY msg_pk LIMIT 100
            """, arguments: [pk, expected.closeAfterPK, expected.maxPKAtStart])
        var next = expected
        for row in rows {
            let message: Int64 = row[0], raw: String? = row[1], visibility: Int = row[2]
            next.closeAfterPK = message
            guard visibility != 4, (raw.flatMap(GmailNumber.unsigned) ?? 0) <= expected.startedAt else { continue }
            let absent = try Bool.fetchOne(db, sql: """
                SELECT NOT EXISTS(SELECT 1 FROM enum_mark WHERE account_pk=? AND generation=? AND label_pk=0 AND msg_pk=?)
                OR EXISTS(SELECT 1 FROM message_label ml WHERE ml.msg_pk=? AND NOT EXISTS(
                    SELECT 1 FROM enum_mark e WHERE e.account_pk=? AND e.generation=? AND e.label_pk=ml.label_pk AND e.msg_pk=ml.msg_pk))
                """, arguments: [pk, expected.generation, message, message, pk, expected.generation]) == true
            if absent { try queue(message, generation: expected.generation, nowMS: nowMS, in: db) }
        }
        try db.execute(sql: "DELETE FROM enum_mark WHERE account_pk=? AND generation=? AND msg_pk<=?",
            arguments: [pk, expected.generation, next.closeAfterPK])
        if rows.count < 100 {
            next.phase = .verifying
            try db.execute(sql: "UPDATE account SET enum_completed_at=? WHERE account_pk=?", arguments: [nowMS, pk])
        }
        try save(next, account: account, in: db)
        return next
    }

    private static func owner(account: String, expected: State, in db: Database) throws -> Int64 {
        guard db.isInsideTransaction else { throw Failure.transactionRequired }
        guard try state(account: account, in: db) == expected,
              let pk = try Int64.fetchOne(db, sql: "SELECT account_pk FROM account WHERE email=?", arguments: [account]) else { throw Failure.invalidState }
        return pk
    }
    private static func save(_ value: State, account: String, in db: Database) throws {
        let text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        try db.execute(sql: "UPDATE account SET enum_state=? WHERE email=?", arguments: [text, account])
    }
    private static func queue(_ message: Int64, generation: Int64, nowMS: Int64, in db: Database) throws {
        try db.execute(sql: "INSERT OR IGNORE INTO verify_queue(msg_pk,reason,generation,queued_at) VALUES(?,1,?,?)",
            arguments: [message, generation, nowMS])
    }
}

#endif
