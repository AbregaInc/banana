#if !BANANA_PUBLIC
import Foundation
import GRDB

/// Per-id evidence and generation-wide removal policy. Network errors never enter
/// this API as deletion evidence; the worker accepts only a structured notFound.
enum MailVerificationIndex {
    enum Failure: Error { case transactionRequired, staleGeneration, invalidMessage, unreadRows }
    struct Request: Equatable, Sendable {
        var messagePK: Int64
        var messageID: String
        var threadID: String
        var storedHistory: String?
        var floor: UInt64
        var generation: Int64
    }
    struct Applied: Sendable {
        var change = MailStoreChange()
        var deleted: [String] = []
        var held: [String] = []
        var finished = false
        var needsRead = false
    }
    private struct Decision: Codable { var generation: Int64; var hold: Bool }

    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v6-verification-evidence") { db in
            try db.execute(sql: "ALTER TABLE verify_queue ADD COLUMN observed_history TEXT")
        }
    }

    static func requests(account: String, in db: Database) throws -> [Request] {
        let state = try generation(account: account, in: db)
        guard let raw = try String.fetchOne(db, sql: "SELECT checkpoint FROM account WHERE email=?", arguments: [account]),
              let floor = GmailNumber.unsigned(raw), floor > 0 else { throw Failure.staleGeneration }
        return try Row.fetchAll(db, sql: """
            SELECT m.msg_pk,m.gmail_id,t.gmail_id,m.history_id FROM verify_queue q
            JOIN message m ON m.msg_pk=q.msg_pk JOIN thread t ON t.thread_pk=m.thread_pk
            JOIN account a ON a.account_pk=m.account_pk
            WHERE a.email=? AND q.generation=? AND q.outcome IS NULL AND m.vis!=4
            ORDER BY m.msg_pk LIMIT 50
            """, arguments: [account, state.generation]).map {
                Request(messagePK: $0[0], messageID: $0[1], threadID: $0[2], storedHistory: $0[3], floor: floor, generation: state.generation)
            }
    }

    static func found(_ message: GmailMessage, request: Request, account: String, in db: Database) throws -> MailStoreChange {
        guard db.isInsideTransaction else { throw Failure.transactionRequired }
        guard try generation(account: account, in: db).generation == request.generation else { throw Failure.staleGeneration }
        guard message.id == request.messageID, message.threadId == request.threadID,
              let labels = message.labelIds, labels.allSatisfy({ !$0.isEmpty }) else { throw Failure.invalidMessage }
        guard try pending(request, account: account, in: db) else { return MailStoreChange() }
        // A message's own history position takes precedence over the request floor.
        let floor = message.historyId ?? request.floor
        let change = try MailMessageImporter.apply(FetchedMessage(wire: message, floor: floor,
            headers: MessageHeaders(payload: message.payload), structure: nil), account: account, myAddresses: [account], in: db)
        try db.execute(sql: "DELETE FROM verify_queue WHERE msg_pk=? AND generation=?", arguments: [request.messagePK, request.generation])
        return change
    }

    static func gone(_ request: Request, account: String, in db: Database) throws {
        guard db.isInsideTransaction else { throw Failure.transactionRequired }
        guard try generation(account: account, in: db).generation == request.generation else { throw Failure.staleGeneration }
        guard try pending(request, account: account, in: db) else { return }
        // A concurrent history update invalidates this read's absence evidence.
        try db.execute(sql: """
            UPDATE verify_queue SET outcome=1,observed_history=? WHERE msg_pk=? AND generation=?
            AND EXISTS(SELECT 1 FROM message m WHERE m.msg_pk=verify_queue.msg_pk AND m.history_id IS ? AND m.vis!=4)
            """, arguments: [request.storedHistory, request.messagePK, request.generation, request.storedHistory])
    }

    /// At most 50 positive removals per commit. The aggregate hold decision is
    /// persisted once, so splitting a generation into batches cannot bypass it.
    static func resolveBatch(account: String, nowMS: Int64, in db: Database) throws -> Applied {
        guard db.isInsideTransaction else { throw Failure.transactionRequired }
        let state = try generation(account: account, in: db)
        guard nowMS >= 0, let owner = try Row.fetchOne(db, sql: "SELECT account_pk,removals FROM account WHERE email=?", arguments: [account]) else { throw Failure.staleGeneration }
        let pk: Int64 = owner[0], rawHistory: String? = owner[1]
        let key = "reconcile-removal:" + account
        var result = Applied()
        // Re-read changed messages before any further decision. This also handles
        // a newer history page arriving after a previous resolve batch committed.
        let stale = try Int64.fetchAll(db, sql: """
            SELECT q.msg_pk FROM verify_queue q JOIN message m ON m.msg_pk=q.msg_pk
            WHERE m.account_pk=? AND q.generation=? AND q.outcome=1
              AND m.history_id IS NOT q.observed_history LIMIT 50
            """, arguments: [pk, state.generation])
        for message in stale {
            try db.execute(sql: "UPDATE verify_queue SET outcome=NULL,observed_history=NULL WHERE msg_pk=?", arguments: [message])
        }
        if !stale.isEmpty {
            try db.execute(sql: "DELETE FROM meta WHERE key=?", arguments: [key])
            result.needsRead = true
            return result
        }
        // Kept messages are outside removal accounting and future verification.
        try db.execute(sql: "DELETE FROM verify_queue WHERE generation=? AND msg_pk IN (SELECT msg_pk FROM message WHERE account_pk=? AND vis=4)", arguments: [state.generation, pk])
        let unread = try Int.fetchOne(db, sql: "SELECT count(*) FROM verify_queue q JOIN message m ON m.msg_pk=q.msg_pk WHERE m.account_pk=? AND q.generation=? AND q.outcome IS NULL", arguments: [pk, state.generation])!
        guard unread == 0 else { result.needsRead = true; return result }
        let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM verify_queue q JOIN message m ON m.msg_pk=q.msg_pk WHERE m.account_pk=? AND q.generation=? AND q.outcome=1", arguments: [pk, state.generation])!
        if count == 0 {
            try db.execute(sql: "UPDATE account SET enum_state=NULL,enum_checkpoint=NULL WHERE account_pk=?", arguments: [pk])
            try db.execute(sql: "DELETE FROM meta WHERE key=?", arguments: [key])
            result.finished = true
            return result
        }
        let history = try rawHistory.map { try JSONDecoder().decode([MailRemovalRules.Hour].self, from: Data($0.utf8)) } ?? []
        let held = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM held_removal h JOIN message m ON m.msg_pk=h.msg_pk WHERE m.account_pk=? AND h.kept=0)", arguments: [pk])!
        var decision: Decision
        if let saved = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key=?", arguments: [key]) {
            decision = try JSONDecoder().decode(Decision.self, from: Data(saved.utf8))
            guard decision.generation == state.generation else { throw Failure.staleGeneration }
        } else {
            let cached = try Int.fetchOne(db, sql: "SELECT count(*) FROM message WHERE account_pk=? AND vis!=4", arguments: [pk])!
            let policy = try MailRemovalRules.decide(removals: count, cachedMessages: cached, previous: history, hasUnresolvedHold: held, nowMS: nowMS)
            decision = Decision(generation: state.generation, hold: policy.hold)
            let encoded = String(decoding: try JSONEncoder().encode(decision), as: UTF8.self)
            try db.execute(sql: "INSERT INTO meta(key,value) VALUES(?,?)", arguments: [key, encoded])
        }
        if held && !decision.hold {
            decision.hold = true
            let encoded = String(decoding: try JSONEncoder().encode(decision), as: UTF8.self)
            try db.execute(sql: "UPDATE meta SET value=? WHERE key=?", arguments: [encoded, key])
        }
        let rows = try Row.fetchAll(db, sql: """
            SELECT m.msg_pk,m.gmail_id,m.thread_pk FROM verify_queue q JOIN message m ON m.msg_pk=q.msg_pk
            WHERE m.account_pk=? AND q.generation=? AND q.outcome=1 ORDER BY m.msg_pk LIMIT 50
            """, arguments: [pk, state.generation])
        var threads = Set<Int64>()
        for row in rows {
            let message: Int64 = row[0], id: String = row[1], thread: Int64 = row[2]
            if decision.hold {
                try db.execute(sql: "INSERT OR IGNORE INTO held_removal(msg_pk,evidence,found_at) VALUES(?,2,?)", arguments: [message, nowMS])
                result.held.append(id)
            } else {
                try db.execute(sql: "INSERT OR REPLACE INTO tombstone(account_pk,gmail_id,at) VALUES(?,?,?)", arguments: [pk, id, nowMS])
                for table in ["message_label", "overlay", "enum_mark", "held_removal"] {
                    try db.execute(sql: "DELETE FROM \(table) WHERE msg_pk=?", arguments: [message])
                }
                try db.execute(sql: "DELETE FROM message WHERE msg_pk=?", arguments: [message])
                threads.insert(thread); result.deleted.append(id)
            }
            try db.execute(sql: "DELETE FROM verify_queue WHERE msg_pk=?", arguments: [message])
        }
        if !result.deleted.isEmpty {
            // Record only deletions actually committed, not all promised by the
            // persisted decision. A crash cannot count unprocessed rows as applied.
            let cached = try Int.fetchOne(db, sql: "SELECT count(*) FROM message WHERE account_pk=? AND vis!=4", arguments: [pk])!
            var hours = try MailRemovalRules.decide(removals: 0, cachedMessages: cached, previous: history, hasUnresolvedHold: false, nowMS: nowMS).history
            hours.append(.init(hour: nowMS / 3_600_000, count: result.deleted.count))
            let encoded = String(decoding: try JSONEncoder().encode(hours), as: UTF8.self)
            try db.execute(sql: "UPDATE account SET removals=? WHERE account_pk=?", arguments: [encoded, pk])
        }
        for thread in threads {
            result.change.formUnion(try MailIndexWriter.rebuildThread(thread,
                facts: MailMessageImporter.facts(threadPK: thread, in: db), myAddresses: [account], in: db))
        }
        return result
    }

    private static func generation(account: String, in db: Database) throws -> MailReconcileIndex.State {
        guard let state = try MailReconcileIndex.state(account: account, in: db), state.phase == .verifying else { throw Failure.staleGeneration }
        return state
    }
    private static func pending(_ request: Request, account: String, in db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM verify_queue q JOIN message m ON m.msg_pk=q.msg_pk
            JOIN account a ON a.account_pk=m.account_pk WHERE a.email=? AND m.msg_pk=?
            AND m.gmail_id=? AND q.generation=? AND q.outcome IS NULL AND m.vis!=4)
            """, arguments: [account, request.messagePK, request.messageID, request.generation]) == true
    }
}

#endif
