#if !BANANA_PUBLIC
import Foundation
import GRDB

/// Durable user intent. Its queue is private and this type never resets or deletes the file.
final class MailIntentStore: MailWriterLog, @unchecked Sendable {
    enum Failure: Error { case invalidGroup, newerSchema, corruptSequence }
    private let queue: DatabaseQueue
    private let checkpointer: MailLogCheckpointer
    private let checkpointLock = NSLock()

    init(directories: MailDirectories) throws {
        queue = try MailStores.openIntentQueue(at: directories.intentDatabase)
        checkpointer = MailLogCheckpointer(logPath: directories.intentDatabase.path + "-wal")
        var migrations = DatabaseMigrator()
        migrations.registerMigration("v1-label-intents") { db in
            try db.execute(sql: """
                CREATE TABLE meta(key TEXT PRIMARY KEY,value TEXT NOT NULL) WITHOUT ROWID;
                INSERT INTO meta VALUES('next_seq','1');
                CREATE TABLE label_intent(
                    account TEXT NOT NULL,gmail_msg_id TEXT NOT NULL,label_ref TEXT NOT NULL,
                    want INTEGER NOT NULL,seq INTEGER NOT NULL,sent_seq INTEGER,group_seq INTEGER NOT NULL,
                    origin INTEGER NOT NULL DEFAULT 0,state INTEGER NOT NULL DEFAULT 0,
                    attempts INTEGER NOT NULL DEFAULT 0,next_attempt_at INTEGER,failure TEXT,
                    created_at INTEGER NOT NULL,delivered_at INTEGER,
                    PRIMARY KEY(account,gmail_msg_id,label_ref)) WITHOUT ROWID;
                CREATE INDEX label_intent_by_state ON label_intent(state,account,seq);
                CREATE TABLE change_group(group_seq INTEGER PRIMARY KEY,account TEXT NOT NULL,
                    change TEXT NOT NULL,conversations INTEGER NOT NULL,created_at INTEGER NOT NULL);
                """)
        }
        migrations.registerMigration("v2-inverse-action-groups") { db in
            try db.execute(sql: "ALTER TABLE change_group ADD COLUMN is_undo INTEGER NOT NULL DEFAULT 0")
        }
        migrations.registerMigration("v3-intent-group-lookup") { db in
            try db.execute(sql: "CREATE INDEX label_intent_by_group ON label_intent(group_seq)")
        }
        migrations.registerMigration("v4-staged-bulk-intents") { db in
            try db.execute(sql: """
                CREATE TABLE action_stage(
                    stage TEXT NOT NULL,account TEXT NOT NULL,thread TEXT NOT NULL,
                    gmail_msg_id TEXT NOT NULL,label_ref TEXT NOT NULL,want INTEGER NOT NULL,
                    previous INTEGER NOT NULL,origin INTEGER NOT NULL,replaced INTEGER,
                    PRIMARY KEY(stage,account,gmail_msg_id,label_ref)) WITHOUT ROWID;
                CREATE TABLE action_inverse(
                    group_seq INTEGER NOT NULL,account TEXT NOT NULL,thread TEXT NOT NULL,
                    gmail_msg_id TEXT NOT NULL,label_ref TEXT NOT NULL,want INTEGER NOT NULL,replaced INTEGER,
                    PRIMARY KEY(group_seq,account,gmail_msg_id,label_ref)) WITHOUT ROWID;
                CREATE INDEX action_stage_by_thread ON action_stage(stage,account,thread);
                CREATE INDEX action_inverse_by_thread ON action_inverse(group_seq,account,thread);
                """)
        }
        migrations.registerMigration("v5-removal-review-intents") { db in
            try db.execute(sql: """
                CREATE TABLE removal_review(id TEXT PRIMARY KEY,account TEXT NOT NULL,
                    choice TEXT,state INTEGER NOT NULL DEFAULT 0,total INTEGER NOT NULL DEFAULT 0,
                    created_at INTEGER NOT NULL) WITHOUT ROWID;
                CREATE TABLE removal_review_item(review TEXT NOT NULL,gmail_id TEXT NOT NULL,
                    PRIMARY KEY(review,gmail_id)) WITHOUT ROWID;
                CREATE UNIQUE INDEX removal_review_pending_account ON removal_review(account) WHERE state=1;
                """)
        }
        guard try queue.read({ try !migrations.hasBeenSuperseded($0) }) else { throw Failure.newerSchema }
        try migrations.migrate(queue)
    }

    func checkpointIfDue() {
        checkpointLock.lock(); defer { checkpointLock.unlock() }
        checkpointer.afterPiece(on: queue)
    }
    func truncateCheckpoint() {
        checkpointLock.lock(); defer { checkpointLock.unlock() }
        checkpointer.truncate(on: queue)
    }

    /// Seed one source's synchronous receipt allocator at startup. A proposed sequence is
    /// checked again in the transaction, so another writer cannot silently reuse it.
    func nextSequence() async throws -> Int64 {
        try await queue.read { try Self.nextSequence(in: $0) }
    }
    private static func nextSequence(in db: Database) throws -> Int64 {
        guard let text = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key='next_seq'"),
              let value = Int64(text), value > 0, value < Int64.max else { throw Failure.corruptSequence }
        return value
    }

    /// One fsync commit owns both the receipt and all its desired label states.
    func record(_ change: MailChange, account: String, assertions: [Assertion], conversations: Int, at: Int64, sequence: Int64? = nil) async throws -> Int64 {
        guard !account.isEmpty, account == account.lowercased(),
              assertions.allSatisfy({ $0.account == account }) else { throw Failure.invalidGroup }
        return try await commit(change, groupAccount: account, assertions: assertions,
                                conversations: conversations, at: at, sequence: sequence)
    }

    /// A unified-list action may touch several accounts, but still has one atomic receipt.
    /// Empty groupAccount means mixed ownership; each assertion always retains its account.
    func record(_ change: MailChange, assertions: [Assertion], conversations: Int, at: Int64, sequence: Int64? = nil) async throws -> Int64 {
        let accounts = Set(assertions.map(\.account))
        return try await commit(change, groupAccount: accounts.count == 1 ? accounts.first! : "",
                                assertions: assertions, conversations: conversations, at: at, sequence: sequence)
    }

    func recordInverse(of change: MailChange, assertions: [Assertion], conversations: Int, at: Int64, sequence: Int64) async throws -> Int64 {
        let accounts = Set(assertions.map(\.account))
        return try await commit(change, groupAccount: accounts.count == 1 ? accounts.first! : "",
                                assertions: assertions, conversations: conversations, at: at, sequence: sequence, isUndo: true)
    }

    private func commit(_ change: MailChange, groupAccount: String, assertions: [Assertion], conversations: Int, at: Int64, sequence: Int64?, isUndo: Bool = false) async throws -> Int64 {
        guard conversations > 0, !assertions.isEmpty,
              assertions.allSatisfy({ !$0.account.isEmpty && $0.account == $0.account.lowercased() && !$0.messageID.isEmpty && !$0.labelRef.isEmpty }) else { throw Failure.invalidGroup }
        let encoded = String(decoding: try JSONEncoder().encode(change), as: UTF8.self)
        return try await queue.write { db in
            let next = try Self.nextSequence(in: db)
            let seq = sequence ?? next
            guard seq >= next, seq < Int64.max else { throw Failure.corruptSequence }
            try db.execute(sql: "UPDATE meta SET value=? WHERE key='next_seq'", arguments: [String(seq + 1)])
            try db.execute(sql: "INSERT INTO change_group(group_seq,account,change,conversations,created_at,is_undo) VALUES(?,?,?,?,?,?)", arguments: [seq, groupAccount, encoded, conversations, at, isUndo])
            var replaced = Set<Int64>()
            for value in assertions {
                let account = value.account
                if let old = try Int64.fetchOne(db, sql: "SELECT group_seq FROM label_intent WHERE account=? AND gmail_msg_id=? AND label_ref=?", arguments: [account, value.messageID, value.labelRef]) { replaced.insert(old) }
                try db.execute(sql: """
                    INSERT INTO label_intent(account,gmail_msg_id,label_ref,want,seq,group_seq,origin,created_at)
                    VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(account,gmail_msg_id,label_ref) DO UPDATE SET
                    want=excluded.want,seq=excluded.seq,group_seq=excluded.group_seq,origin=excluded.origin,
                    state=0,sent_seq=NULL,attempts=0,next_attempt_at=NULL,failure=NULL,created_at=excluded.created_at
                    """, arguments: [account, value.messageID, value.labelRef, value.want, seq, seq, value.origin.rawValue, at])
            }
            for old in replaced where old != seq { try Self.removeEmptyGroup(old, db: db) }
            return seq
        }
    }

    struct StagedAssertion: Sendable {
        let thread: String
        let assertion: Assertion
        let previous: Bool
    }

    /// Staged rows cannot be delivered. Only the final atomic commit acknowledges intent.
    func appendStage(_ stage: String, values: [StagedAssertion]) async throws {
        guard !stage.isEmpty, !values.isEmpty, values.count <= 500,
              values.allSatisfy({ !$0.thread.isEmpty && !$0.assertion.account.isEmpty &&
                  $0.assertion.account == $0.assertion.account.lowercased() &&
                  !$0.assertion.messageID.isEmpty && !$0.assertion.labelRef.isEmpty }) else { throw Failure.invalidGroup }
        try await queue.write { db in
            for value in values {
                let item = value.assertion
                try db.execute(sql: """
                    INSERT INTO action_stage(stage,account,thread,gmail_msg_id,label_ref,want,previous,origin)
                    VALUES(?,?,?,?,?,?,?,?)
                    """, arguments: [stage, item.account, value.thread, item.messageID, item.labelRef,
                        item.want, value.previous, item.origin.rawValue])
            }
        }
    }

    /// Startup only, before the source accepts actions. These rows were never acknowledged.
    func discardUncommittedStages() async throws {
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM action_stage")
            try db.execute(sql: "DELETE FROM removal_review_item WHERE review IN (SELECT id FROM removal_review WHERE state=0)")
            try db.execute(sql: "DELETE FROM removal_review WHERE state=0")
        }
    }

    func discardStage(_ stage: String) async throws {
        try await queue.write { try $0.execute(sql: "DELETE FROM action_stage WHERE stage=?", arguments: [stage]) }
    }

    /// One full-fsync transaction imports the staged action and its inverse without materializing
    /// either history in Swift. Incomplete preparation never becomes pending provider work.
    func commitStage(_ stage: String, change: MailChange, sequence: Int64, at: Int64) async throws -> Int {
        let encoded = String(decoding: try JSONEncoder().encode(change), as: UTF8.self)
        return try await queue.write { db in
            let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM (SELECT account,thread FROM action_stage WHERE stage=? GROUP BY account,thread)", arguments: [stage]) ?? 0
            guard count > 0 else { return 0 }
            let next = try Self.nextSequence(in: db)
            guard sequence >= next, sequence < Int64.max else { throw Failure.corruptSequence }
            let account = try String.fetchOne(db, sql: "SELECT CASE WHEN count(DISTINCT account)=1 THEN min(account) ELSE '' END FROM action_stage WHERE stage=?", arguments: [stage]) ?? ""
            try db.execute(sql: "UPDATE meta SET value=? WHERE key='next_seq'", arguments: [String(sequence + 1)])
            try db.execute(sql: "INSERT INTO change_group(group_seq,account,change,conversations,created_at,is_undo) VALUES(?,?,?,?,?,0)", arguments: [sequence, account, encoded, count, at])
            try db.execute(sql: """
                UPDATE action_stage SET replaced=(SELECT group_seq FROM label_intent i
                    WHERE i.account=action_stage.account AND i.gmail_msg_id=action_stage.gmail_msg_id AND i.label_ref=action_stage.label_ref)
                WHERE stage=?;
                """, arguments: [stage])
            try db.execute(sql: """
                INSERT INTO label_intent(account,gmail_msg_id,label_ref,want,seq,group_seq,origin,created_at)
                SELECT account,gmail_msg_id,label_ref,want,?,?,origin,? FROM action_stage WHERE stage=?
                ON CONFLICT(account,gmail_msg_id,label_ref) DO UPDATE SET
                want=excluded.want,seq=excluded.seq,group_seq=excluded.group_seq,origin=excluded.origin,
                state=0,sent_seq=NULL,attempts=0,next_attempt_at=NULL,failure=NULL,created_at=excluded.created_at;
                """, arguments: [sequence, sequence, at, stage])
            try db.execute(sql: """
                INSERT INTO action_inverse(group_seq,account,thread,gmail_msg_id,label_ref,want)
                SELECT ?,account,thread,gmail_msg_id,label_ref,previous FROM action_stage WHERE stage=?;
                DELETE FROM change_group WHERE group_seq IN (SELECT replaced FROM action_stage WHERE stage=?)
                    AND NOT EXISTS(SELECT 1 FROM label_intent WHERE label_intent.group_seq=change_group.group_seq);
                DELETE FROM action_stage WHERE stage=?;
                DELETE FROM action_inverse WHERE group_seq NOT IN
                    (SELECT DISTINCT group_seq FROM action_inverse ORDER BY group_seq DESC LIMIT 50);
                """, arguments: [sequence, stage, stage, stage])
            return count
        }
    }

    /// Restoring an inverse is another atomic action. Keep it available if the save fails.
    func commitStoredInverse(_ group: Int64, change: MailChange, sequence: Int64, at: Int64) async throws -> Int {
        let encoded = String(decoding: try JSONEncoder().encode(change), as: UTF8.self)
        return try await queue.write { db in
            let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM (SELECT account,thread FROM action_inverse WHERE group_seq=? GROUP BY account,thread)", arguments: [group]) ?? 0
            guard count > 0 else { throw Failure.invalidGroup }
            let next = try Self.nextSequence(in: db)
            guard sequence >= next, sequence < Int64.max else { throw Failure.corruptSequence }
            let account = try String.fetchOne(db, sql: "SELECT CASE WHEN count(DISTINCT account)=1 THEN min(account) ELSE '' END FROM action_inverse WHERE group_seq=?", arguments: [group]) ?? ""
            try db.execute(sql: "UPDATE meta SET value=? WHERE key='next_seq'", arguments: [String(sequence + 1)])
            try db.execute(sql: "INSERT INTO change_group(group_seq,account,change,conversations,created_at,is_undo) VALUES(?,?,?,?,?,1)", arguments: [sequence, account, encoded, count, at])
            try db.execute(sql: """
                UPDATE action_inverse SET replaced=(SELECT i.group_seq FROM label_intent i
                    WHERE i.account=action_inverse.account AND i.gmail_msg_id=action_inverse.gmail_msg_id AND i.label_ref=action_inverse.label_ref)
                WHERE group_seq=?;
                INSERT INTO label_intent(account,gmail_msg_id,label_ref,want,seq,group_seq,origin,created_at)
                SELECT account,gmail_msg_id,label_ref,want,?,?,0,? FROM action_inverse WHERE group_seq=?
                ON CONFLICT(account,gmail_msg_id,label_ref) DO UPDATE SET
                want=excluded.want,seq=excluded.seq,group_seq=excluded.group_seq,origin=excluded.origin,
                state=0,sent_seq=NULL,attempts=0,next_attempt_at=NULL,failure=NULL,created_at=excluded.created_at;
                DELETE FROM change_group WHERE group_seq IN (SELECT replaced FROM action_inverse WHERE group_seq=?)
                    AND NOT EXISTS(SELECT 1 FROM label_intent WHERE label_intent.group_seq=change_group.group_seq);
                DELETE FROM action_inverse WHERE group_seq=?;
                """, arguments: [group, sequence, sequence, at, group, group, group])
            return count
        }
    }

    struct Cursor: Sendable {
        let sequence: Int64
        let account: String
        let message: String
        let label: String
        init(_ assertion: StoredAssertion) {
            sequence = assertion.seq; account = assertion.assertion.account
            message = assertion.assertion.messageID; label = assertion.assertion.labelRef
        }
    }

    /// Full tuple paging preserves groups larger than a page without loading all intent.
    func assertions(after cursor: Cursor? = nil, limit: Int = 500) async throws -> [StoredAssertion] {
        guard (1...500).contains(limit) else { throw Failure.invalidGroup }
        return try await queue.read { db in
            let predicate = cursor == nil ? "" : "WHERE (seq,account,gmail_msg_id,label_ref) > (?,?,?,?)"
            var arguments = StatementArguments()
            if let cursor { arguments += [cursor.sequence, cursor.account, cursor.message, cursor.label] }
            arguments += [limit]
            return try Row.fetchAll(db, sql: "SELECT * FROM label_intent \(predicate) ORDER BY seq,account,gmail_msg_id,label_ref LIMIT ?", arguments: arguments).map(Self.decode)
        }
    }

    func assertions(account: String, messages: [String]) async throws -> [StoredAssertion] {
        guard !messages.isEmpty, messages.count <= 100 else { throw Failure.invalidGroup }
        return try await queue.read { db in
            let slots = Array(repeating: "?", count: messages.count).joined(separator: ",")
            return try Row.fetchAll(db, sql: "SELECT * FROM label_intent WHERE account=? AND gmail_msg_id IN (\(slots)) ORDER BY gmail_msg_id,label_ref", arguments: StatementArguments([account] + messages)).map(Self.decode)
        }
    }

    func nextAttempt(account: String) async throws -> Int64? {
        try await queue.read {
            try Int64.fetchOne($0, sql: "SELECT min(coalesce(next_attempt_at,0)) FROM label_intent WHERE account=? AND state=0", arguments: [account])
        }
    }

    func assertions(group: Int64, after cursor: Cursor? = nil) async throws -> [StoredAssertion] {
        try await queue.read { db in
            var arguments: StatementArguments = [group]
            let after: String
            if let cursor {
                after = " AND (account,gmail_msg_id,label_ref) > (?,?,?)"
                arguments += [cursor.account, cursor.message, cursor.label]
            } else { after = "" }
            return try Row.fetchAll(db, sql: "SELECT * FROM label_intent WHERE group_seq=?\(after) ORDER BY account,gmail_msg_id,label_ref LIMIT 500", arguments: arguments).map(Self.decode)
        }
    }

    /// Bounded, durable failure pages; no in-memory event history is needed after restart.
    func refused(after sequence: Int64 = 0, limit: Int = 51) async throws -> [MailRefusedChange] {
        guard sequence >= 0, (1...100).contains(limit) else { throw Failure.invalidGroup }
        return try await queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT g.*, (SELECT failure FROM label_intent i WHERE i.group_seq=g.group_seq AND i.state=3 ORDER BY account,gmail_msg_id,label_ref LIMIT 1) AS refusal
                FROM change_group g WHERE group_seq>? AND EXISTS(SELECT 1 FROM label_intent i WHERE i.group_seq=g.group_seq AND i.state=3)
                ORDER BY group_seq LIMIT ?
                """, arguments: [sequence, limit]).map { row in
                    let seq: Int64 = row["group_seq"], count: Int = row["conversations"]
                    let encoded: String = row["change"], code: String = row["refusal"]
                    guard seq > 0, let failure = MailFailure(rawValue: code) else { throw Failure.invalidGroup }
                    return MailRefusedChange(receipt: MailReceipt(sequence: UInt64(seq), count: count),
                        change: try JSONDecoder().decode(MailChange.self, from: Data(encoded.utf8)), count: count,
                        failure: failure, account: row["account"], isUndo: row["is_undo"])
                }
        }
    }

    func hasPending(account: String, at: Int64) async throws -> Bool {
        try await queue.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM label_intent WHERE account=? AND state=0 AND (next_attempt_at IS NULL OR next_attempt_at<=?))", arguments: [account, at]) ?? false
        }
    }

    /// Claim one message atomically. At most 100 labels keeps one modify request bounded.
    func claim(account: String, at: Int64) async throws -> [StoredAssertion] {
        try await queue.write { db in
            guard let message = try String.fetchOne(db, sql: """
                SELECT gmail_msg_id FROM label_intent WHERE account=? AND state=0
                AND (next_attempt_at IS NULL OR next_attempt_at<=?) ORDER BY seq,gmail_msg_id LIMIT 1
                """, arguments: [account, at]) else { return [] }
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM label_intent WHERE account=? AND gmail_msg_id=? AND state=0
                AND (next_attempt_at IS NULL OR next_attempt_at<=?) ORDER BY seq,label_ref LIMIT 100
                """, arguments: [account, message, at]).map(Self.decode)
            for row in rows {
                try db.execute(sql: "UPDATE label_intent SET state=1,sent_seq=seq,attempts=attempts+1 WHERE account=? AND gmail_msg_id=? AND label_ref=? AND seq=? AND state=0",
                    arguments: [account, message, row.assertion.labelRef, row.seq])
            }
            return rows.map { var row = $0; row.state = .inFlight; row.sentSeq = row.seq; row.attempts += 1; return row }
        }
    }

    func reschedule(_ keys: [SentKey], at: Int64) async throws {
        try await queue.write { db in
            for key in keys {
                try db.execute(sql: """
                    UPDATE label_intent SET state=0,sent_seq=NULL,next_attempt_at=?
                    WHERE account=? AND gmail_msg_id=? AND label_ref=? AND seq=? AND sent_seq=?
                    """, arguments: [at, key.account, key.messageID, key.labelRef, key.sentSeq, key.sentSeq])
            }
        }
    }

    func markInFlight(_ keys: [SentKey]) async throws {
        try await queue.write { db in
            for key in keys {
                try db.execute(sql: """
                    UPDATE label_intent SET state=1,sent_seq=seq,attempts=attempts+1
                    WHERE account=? AND gmail_msg_id=? AND label_ref=? AND seq=? AND state=0
                    """, arguments: [key.account, key.messageID, key.labelRef, key.sentSeq])
            }
        }
    }

    /// Call only after a provider read confirms the requested labels, not merely a 2xx write.
    func confirmed(_ keys: [SentKey]) async throws {
        try await queue.write { db in
            for key in keys {
                let arguments: StatementArguments = [key.account, key.messageID, key.labelRef, key.sentSeq, key.sentSeq]
                let group = try Int64.fetchOne(db, sql: "SELECT group_seq FROM label_intent WHERE account=? AND gmail_msg_id=? AND label_ref=? AND seq=? AND sent_seq=?", arguments: arguments)
                try db.execute(sql: "DELETE FROM label_intent WHERE account=? AND gmail_msg_id=? AND label_ref=? AND seq=? AND sent_seq=?", arguments: arguments)
                if let group { try Self.removeEmptyGroup(group, db: db) }
            }
        }
    }

    /// Only for an index tombstone backed by positive provider deletion evidence.
    /// A deleted Gmail message cannot receive a label change; all its assertions
    /// are moot, including retries. Other messages in a mixed group stay durable.
    func discardForVerifiedRemoval(account: String, messages: [String]) async throws {
        guard MailAddressRules.isValid(account), account == account.lowercased(),
              (1...100).contains(messages.count), messages.allSatisfy({ !$0.isEmpty }) else {
            throw Failure.invalidGroup
        }
        try await queue.write { db in
            var groups = Set<Int64>()
            for message in Set(messages) {
                groups.formUnion(try Int64.fetchAll(db, sql: "SELECT DISTINCT group_seq FROM label_intent WHERE account=? AND gmail_msg_id=?", arguments: [account, message]))
                try db.execute(sql: "DELETE FROM label_intent WHERE account=? AND gmail_msg_id=?", arguments: [account, message])
                try db.execute(sql: "DELETE FROM action_inverse WHERE account=? AND gmail_msg_id=?", arguments: [account, message])
            }
            for group in groups { try Self.removeEmptyGroup(group, db: db) }
        }
    }

    func refused(_ keys: [SentKey], failure: MailFailure) async throws {
        try await queue.write { db in
            for key in keys {
                try db.execute(sql: "UPDATE label_intent SET state=3,failure=? WHERE account=? AND gmail_msg_id=? AND label_ref=? AND seq=? AND sent_seq=?",
                    arguments: [failure.rawValue, key.account, key.messageID, key.labelRef, key.sentSeq, key.sentSeq])
            }
        }
    }

    func retry(group: Int64) async throws {
        try await queue.write { db in
            try db.execute(sql: "UPDATE label_intent SET state=0,sent_seq=NULL,failure=NULL,next_attempt_at=NULL WHERE group_seq=? AND state=3", arguments: [group])
        }
    }

    func recoverInterruptedDelivery() async throws {
        try await queue.write { db in
            try db.execute(sql: "UPDATE label_intent SET state=0,sent_seq=NULL WHERE state IN (1,2)")
        }
    }

    private static func removeEmptyGroup(_ sequence: Int64, db: Database) throws {
        try db.execute(sql: "DELETE FROM change_group WHERE group_seq=? AND NOT EXISTS(SELECT 1 FROM label_intent WHERE group_seq=?)", arguments: [sequence, sequence])
    }
    private static func decode(_ row: Row) throws -> StoredAssertion {
        guard let origin = AssertionOrigin(rawValue: row["origin"]), let state = AssertionState(rawValue: row["state"]) else { throw Failure.invalidGroup }
        let failure: String? = row["failure"]
        return StoredAssertion(assertion: Assertion(account: row["account"], messageID: row["gmail_msg_id"], labelRef: row["label_ref"], want: row["want"], origin: origin),
            seq: row["seq"], sentSeq: row["sent_seq"], groupSeq: row["group_seq"], state: state,
            attempts: row["attempts"], nextAttemptAt: row["next_attempt_at"], failure: failure.flatMap(MailFailure.init(rawValue:)), createdAt: row["created_at"])
    }

    func beginRemovalReview(_ id: String, account: String, at: Int64) async throws {
        guard !id.isEmpty, MailAddressRules.isValid(account), account == account.lowercased(), at >= 0 else { throw Failure.invalidGroup }
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO removal_review(id,account,created_at) VALUES(?,?,?)", arguments: [id, account, at])
        }
    }
    func appendRemovalReview(_ id: String, messages: [String]) async throws {
        guard (1...100).contains(messages.count), messages.allSatisfy({ !$0.isEmpty }) else { throw Failure.invalidGroup }
        try await queue.write { db in
            guard try Int.fetchOne(db, sql: "SELECT state FROM removal_review WHERE id=?", arguments: [id]) == 0 else { throw Failure.invalidGroup }
            for message in messages {
                try db.execute(sql: "INSERT OR IGNORE INTO removal_review_item(review,gmail_id) VALUES(?,?)", arguments: [id, message])
            }
        }
    }
    func removalReview(_ id: String) async throws -> MailRemovalReview? {
        try await queue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT id,account,choice,CASE WHEN state=1 THEN total ELSE
                    (SELECT count(*) FROM removal_review_item WHERE review=id) END AS total
                FROM removal_review WHERE id=?
                """, arguments: [id]) else { return nil }
            let raw: String? = row[2]
            return MailRemovalReview(id: row[0], account: row[1], count: row[3], choice: raw.flatMap(MailChoice.init(rawValue:)))
        }
    }
    func removalReviewMessages(_ id: String, after: String?, limit: Int = 50) async throws -> [String] {
        guard (1...100).contains(limit) else { throw Failure.invalidGroup }
        return try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT gmail_id FROM removal_review_item WHERE review=? AND gmail_id>? ORDER BY gmail_id LIMIT ?",
                arguments: [id, after ?? "", limit])
        }
    }
    func commitRemovalReview(_ id: String, choice: MailChoice) async throws {
        guard choice == .remove || choice == .keepHere else { throw Failure.invalidGroup }
        try await queue.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT state,choice FROM removal_review WHERE id=?", arguments: [id]) else { throw Failure.invalidGroup }
            let state: Int = row[0], existing: String? = row[1]
            if state == 1 {
                guard existing == choice.rawValue else { throw Failure.invalidGroup }
                return // Retry a committed answer without replacing it.
            }
            let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM removal_review_item WHERE review=?", arguments: [id])!
            guard count > 0 else { throw Failure.invalidGroup }
            try db.execute(sql: "UPDATE removal_review SET state=1,choice=?,total=? WHERE id=?", arguments: [choice.rawValue, count, id])
        }
    }
    func pendingRemovalReviews() async throws -> [String] {
        try await queue.read { try String.fetchAll($0, sql: "SELECT id FROM removal_review WHERE state=1 ORDER BY created_at,id") }
    }
    func finishRemovalReviewMessages(_ id: String, messages: [String]) async throws {
        guard (1...100).contains(messages.count) else { throw Failure.invalidGroup }
        try await queue.write { db in
            guard try Int.fetchOne(db, sql: "SELECT state FROM removal_review WHERE id=?", arguments: [id]) == 1 else { throw Failure.invalidGroup }
            for message in messages {
                try db.execute(sql: "DELETE FROM removal_review_item WHERE review=? AND gmail_id=?", arguments: [id, message])
            }
            try db.execute(sql: "DELETE FROM removal_review WHERE id=? AND NOT EXISTS(SELECT 1 FROM removal_review_item WHERE review=?)", arguments: [id, id])
        }
    }
    func discardRemovalReview(_ id: String) async throws {
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM removal_review_item WHERE review=? AND EXISTS(SELECT 1 FROM removal_review WHERE id=? AND state=0)", arguments: [id, id])
            try db.execute(sql: "DELETE FROM removal_review WHERE id=? AND state=0", arguments: [id])
        }
    }
}

#endif
