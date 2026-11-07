#if !BANANA_PUBLIC
import Foundation
import GRDB

/// Index-side application of Banana Cloud's mailbox feed (MAIL-CLOUD-SYNC §4). An entry is applied
/// exactly as a per-message read: `MailMessageImporter` with the entry's position as the floor, so
/// the stale-read rule (invariant 23), tombstones (29), kept messages and the overlay all hold. A
/// deletion goes through the same removal rules as `messagesDeleted`, the bulk hold included (3).
/// The feed's cursor is saved in the transaction that applies its page.
enum MailCloudFeedIndex {
    enum Failure: Error { case transactionRequired, invalidPage, changedCursor }
    struct State: Codable, Equatable, Sendable {
        var epoch: String
        var cursor: String?
        /// While a catch-up from zero runs on a device that already held mail: the rows at or below
        /// this key that the feed never named are checked with the cloud before it closes.
        var catchUpMaxPK: Int64?
    }
    struct Applied: Sendable {
        var change = MailStoreChange()
        var deleted: [String] = []
        var held: [String] = []
        var state: State
    }

    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v14-cloud-feed") { db in
            // Rows the running catch-up has seen named by the feed (or already checked).
            try db.execute(sql: "CREATE TABLE cloud_seen(msg_pk INTEGER PRIMARY KEY) WITHOUT ROWID")
        }
        migrator.registerMigration("v15-cloud-content") { db in
            // The feed said the cloud holds this message's content (MAIL-CLOUD-SYNC §5a). The pull
            // walks what is not here yet, newest first; a pull that finds it missing clears it.
            try db.execute(sql: "ALTER TABLE message ADD COLUMN cloud_content INTEGER NOT NULL DEFAULT 0")
            try db.execute(sql: """
                CREATE INDEX message_cloud_pull ON message(account_pk, internal_date DESC, msg_pk DESC)
                WHERE cloud_content = 1 AND (fetch_state < 2 OR prep_state = 0) AND vis != 4
                """)
        }
    }

    static func key(_ account: String) -> String { "cloud-feed:" + account.lowercased() }

    static func state(account: String, in db: Database) throws -> State? {
        guard let raw = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key=?", arguments: [key(account)]) else { return nil }
        return try JSONDecoder().decode(State.self, from: Data(raw.utf8))
    }
    private static func save(_ state: State, account: String, in db: Database) throws {
        let encoded = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        try db.execute(sql: "INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                       arguments: [key(account), encoded])
    }
    private static func accountPK(_ account: String, in db: Database) throws -> Int64 {
        try db.execute(sql: "INSERT OR IGNORE INTO account(email) VALUES (?)", arguments: [account])
        return try Int64.fetchOne(db, sql: "SELECT account_pk FROM account WHERE email=?", arguments: [account])!
    }

    /// Starts from zero with this mailbox `epoch`. What the device already holds is checked at the
    /// end of the catch-up; nothing is removed for being absent from the feed.
    static func begin(account rawAccount: String, epoch: String, in db: Database) throws -> State {
        guard db.isInsideTransaction else { throw Failure.transactionRequired }
        let account = rawAccount.lowercased()
        let owner = try accountPK(account, in: db)
        let held = try Int64.fetchOne(db, sql: "SELECT max(msg_pk) FROM message WHERE account_pk=?", arguments: [owner])
        try db.execute(sql: "DELETE FROM cloud_seen WHERE msg_pk IN (SELECT msg_pk FROM message WHERE account_pk=?)", arguments: [owner])
        try db.execute(sql: "DELETE FROM cloud_seen WHERE msg_pk NOT IN (SELECT msg_pk FROM message)")
        let state = State(epoch: epoch, cursor: nil, catchUpMaxPK: held)
        try save(state, account: account, in: db)
        return state
    }

    /// `finishesPage`: false for all but the last slice of a long page. Applying is by state, so a
    /// slice applied again after a crash changes nothing; only the last slice moves the cursor.
    static func apply(_ page: MailCloudFeedPage, account rawAccount: String, expected: State, nowMS: Int64,
                      finishesPage: Bool = true, in db: Database) throws -> Applied {
        guard db.isInsideTransaction else { throw Failure.transactionRequired }
        let account = rawAccount.lowercased()
        guard try state(account: account, in: db) == expected else { throw Failure.changedCursor }
        guard page.epoch == expected.epoch, !page.cursor.isEmpty, nowMS >= 0 else { throw Failure.invalidPage }
        let owner = try accountPK(account, in: db)
        var result = Applied(state: expected)
        var deletions: [String] = []
        let seen = { (id: String) throws in
            guard expected.catchUpMaxPK != nil else { return }
            try db.execute(sql: "INSERT OR IGNORE INTO cloud_seen(msg_pk) SELECT msg_pk FROM message WHERE account_pk=? AND gmail_id=?",
                           arguments: [owner, id])
        }
        for entry in page.entries {
            guard !entry.id.isEmpty, let position = GmailNumber.unsigned(entry.history) else { throw Failure.invalidPage }
            if entry.deleted == true { deletions.append(entry.id); continue }
            guard let thread = entry.thread, !thread.isEmpty, let labels = entry.labels, labels.allSatisfy({ !$0.isEmpty }) else {
                throw Failure.invalidPage
            }
            let wire = GmailMessage(id: entry.id, threadId: thread, labelIds: labels, historyId: position, internalDate: entry.date)
            do {
                result.change.formUnion(try MailMessageImporter.apply(FetchedMessage(wire: wire, floor: position,
                    headers: MessageHeaders(payload: nil), structure: nil), account: account, myAddresses: [account], in: db))
            } catch MailMessageImporter.Failure.changedThread {
                // Gmail never moves a message between threads; a row that disagrees is left to a read.
            }
            if entry.content == true {
                try db.execute(sql: "UPDATE message SET cloud_content=1 WHERE account_pk=? AND gmail_id=? AND cloud_content=0",
                               arguments: [owner, entry.id])
            }
            try seen(entry.id)
        }
        if !deletions.isEmpty {
            var rows: [String: Row] = [:]
            for offset in stride(from: 0, to: deletions.count, by: 100) {
                let batch = Array(deletions[offset..<min(offset + 100, deletions.count)])
                let slots = Array(repeating: "?", count: batch.count).joined(separator: ",")
                let values: [DatabaseValue] = [owner.databaseValue] + batch.map { $0.databaseValue }
                for row in try Row.fetchAll(db, sql: "SELECT * FROM message WHERE account_pk=? AND vis != 4 AND gmail_id IN (\(slots))",
                                            arguments: StatementArguments(values)) {
                    rows[row["gmail_id"]] = row
                }
            }
            let present = Array(Set(deletions.filter { rows[$0] != nil })).sorted()
            if !present.isEmpty {
                var threads = Set<Int64>()
                let removals = try String.fetchOne(db, sql: "SELECT removals FROM account WHERE account_pk=?", arguments: [owner])
                let removed = try MailHistoryIndex.removeStated(present, rows: rows, accountPK: owner, removals: removals,
                    evidence: 1, nowMS: nowMS, threads: &threads, in: db)
                result.deleted = removed.deleted; result.held = removed.held
                for id in removed.held { try seen(id) }
                for thread in threads {
                    result.change.formUnion(try MailIndexWriter.rebuildThread(thread,
                        facts: MailMessageImporter.facts(threadPK: thread, in: db), myAddresses: [account], in: db))
                }
            }
        }
        guard finishesPage else { return result }
        result.state.cursor = page.cursor
        try save(result.state, account: account, in: db)
        try db.execute(sql: "UPDATE account SET last_sync_at=? WHERE account_pk=?", arguments: [nowMS, owner])
        return result
    }

    /// Rows the device held when the catch-up began that the feed has not named, `limit` at a time.
    static func unseen(account rawAccount: String, state: State, limit: Int, in db: Database) throws -> [String] {
        guard let maxPK = state.catchUpMaxPK else { return [] }
        return try String.fetchAll(db, sql: """
            SELECT m.gmail_id FROM message m JOIN account a ON a.account_pk=m.account_pk
            WHERE a.email=? AND m.msg_pk<=? AND m.vis!=4
              AND NOT EXISTS(SELECT 1 FROM cloud_seen s WHERE s.msg_pk=m.msg_pk)
              AND NOT EXISTS(SELECT 1 FROM held_removal h WHERE h.msg_pk=m.msg_pk)
            ORDER BY m.msg_pk LIMIT ?
            """, arguments: [rawAccount.lowercased(), maxPK, limit])
    }

    /// Ids handed to the cloud's check: their answers come through the feed.
    static func checked(account rawAccount: String, ids: [String], in db: Database) throws {
        guard db.isInsideTransaction else { throw Failure.transactionRequired }
        let owner = try accountPK(rawAccount.lowercased(), in: db)
        for id in ids {
            try db.execute(sql: "INSERT OR IGNORE INTO cloud_seen(msg_pk) SELECT msg_pk FROM message WHERE account_pk=? AND gmail_id=?",
                           arguments: [owner, id])
        }
    }

    static func finishCatchUp(account rawAccount: String, expected: State, in db: Database) throws -> State {
        guard db.isInsideTransaction else { throw Failure.transactionRequired }
        let account = rawAccount.lowercased()
        guard try state(account: account, in: db) == expected else { throw Failure.changedCursor }
        let owner = try accountPK(account, in: db)
        try db.execute(sql: "DELETE FROM cloud_seen WHERE msg_pk IN (SELECT msg_pk FROM message WHERE account_pk=?)", arguments: [owner])
        try db.execute(sql: "DELETE FROM cloud_seen WHERE msg_pk NOT IN (SELECT msg_pk FROM message)")
        var next = expected
        next.catchUpMaxPK = nil
        try save(next, account: account, in: db)
        return next
    }
}

#endif
