#if !BANANA_PUBLIC
import Foundation
import GRDB

/// Disposable projection of durable intent. Provider labels are never overwritten here.
enum MailActionIndex {
    enum Failure: Error { case transactionRequired, invalidProjection }
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v3-overlay-refusal") { db in
            try db.execute(sql: "ALTER TABLE overlay ADD COLUMN refused INTEGER NOT NULL DEFAULT 0")
            try db.execute(sql: "UPDATE overlay SET refused=1 WHERE msg_pk IN (SELECT m.msg_pk FROM message m JOIN thread t ON t.thread_pk=m.thread_pk WHERE t.pending=2)")
        }
        migrator.registerMigration("v4-message-arrival-boundary") { db in
            try db.execute(sql: """
                ALTER TABLE message ADD COLUMN arrival_seq INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE thread ADD COLUMN arrival_seq INTEGER NOT NULL DEFAULT 0;
                UPDATE message SET arrival_seq=msg_pk;
                UPDATE thread SET arrival_seq=coalesce((SELECT max(arrival_seq) FROM message WHERE message.thread_pk=thread.thread_pk),0);
                INSERT INTO meta(key,value) SELECT 'message_arrival_sequence',coalesce(max(arrival_seq),0) FROM message;
                CREATE TRIGGER message_arrival_insert AFTER INSERT ON message BEGIN
                    UPDATE meta SET value=CAST(value AS INTEGER)+1 WHERE key='message_arrival_sequence';
                    UPDATE message SET arrival_seq=(SELECT CAST(value AS INTEGER) FROM meta WHERE key='message_arrival_sequence') WHERE msg_pk=new.msg_pk;
                    UPDATE thread SET arrival_seq=(SELECT CAST(value AS INTEGER) FROM meta WHERE key='message_arrival_sequence') WHERE thread_pk=new.thread_pk;
                END;
                CREATE TRIGGER message_arrival_move AFTER UPDATE OF thread_pk ON message WHEN old.thread_pk != new.thread_pk BEGIN
                    UPDATE meta SET value=CAST(value AS INTEGER)+1 WHERE key='message_arrival_sequence';
                    UPDATE message SET arrival_seq=(SELECT CAST(value AS INTEGER) FROM meta WHERE key='message_arrival_sequence') WHERE msg_pk=new.msg_pk;
                    UPDATE thread SET arrival_seq=(SELECT CAST(value AS INTEGER) FROM meta WHERE key='message_arrival_sequence') WHERE thread_pk=new.thread_pk;
                END;
                """)
        }
    }
    static func replace(account: String, messages: [String], assertions: [StoredAssertion], through: UInt64 = 0, rebuild: Bool = true, in db: Database) throws -> MailStoreChange {
        guard db.isInsideTransaction else { throw Failure.transactionRequired }
        let ids = Set(messages)
        guard !messages.isEmpty, messages.count <= 100,
              assertions.allSatisfy({ $0.assertion.account == account && ids.contains($0.assertion.messageID) }) else { throw Failure.invalidProjection }
        let slots = Array(repeating: "?", count: messages.count).joined(separator: ",")
        let rows = try Row.fetchAll(db, sql: "SELECT m.gmail_id,m.msg_pk,m.thread_pk,m.account_pk FROM message m JOIN account a ON a.account_pk=m.account_pk WHERE a.email=? AND m.gmail_id IN (\(slots))", arguments: StatementArguments([account] + messages))
        var found: [String: (Int64, Int64)] = [:], threads = Set<Int64>()
        for row in rows {
            let id: String = row[0], message: Int64 = row[1], thread: Int64 = row[2], account: Int64 = row[3]
            found[id] = (message, account); threads.insert(thread)
            try db.execute(sql: "DELETE FROM overlay WHERE msg_pk=?", arguments: [message])
        }
        var labelsChanged = false
        for stored in assertions {
            let value = stored.assertion
            // A deleted/rebuilding cache may not yet contain this durable message.
            guard let (message, owner) = found[value.messageID] else { continue }
            let kind = SystemLabel(rawValue: value.labelRef) == nil ? 1 : 0
            try db.execute(sql: "INSERT OR IGNORE INTO label(account_pk,gmail_id,name,kind) VALUES(?,?,?,?)", arguments: [owner, value.labelRef, value.labelRef, kind])
            labelsChanged = labelsChanged || db.changesCount > 0
            try db.execute(sql: """
                INSERT INTO overlay(msg_pk,label_pk,want,derived,refused)
                SELECT ?,label_pk,?,?,? FROM label WHERE account_pk=? AND gmail_id=?
                """, arguments: [message, value.want, value.origin == .rule, stored.state == .refused, owner, value.labelRef])
        }
        var change = MailStoreChange(labelsChanged: labelsChanged, through: through)
        for thread in threads where rebuild {
            let facts = try MailMessageImporter.facts(threadPK: thread, in: db)
            change.formUnion(try MailIndexWriter.rebuildThread(thread, facts: facts, myAddresses: [account], in: db))
        }
        return change
    }
    static func rebuild(account: String, messages: [String], through: UInt64, in db: Database) throws -> MailStoreChange {
        guard db.isInsideTransaction else { throw Failure.transactionRequired }
        var threads = Set<Int64>()
        for offset in stride(from: 0, to: messages.count, by: 100) {
            let batch = Array(messages[offset..<min(offset + 100, messages.count)])
            let slots = Array(repeating: "?", count: batch.count).joined(separator: ",")
            threads.formUnion(try Int64.fetchAll(db, sql: "SELECT DISTINCT m.thread_pk FROM message m JOIN account a ON a.account_pk=m.account_pk WHERE a.email=? AND m.gmail_id IN (\(slots))", arguments: StatementArguments([account] + batch)))
        }
        var change = MailStoreChange(through: through)
        for thread in threads {
            let facts = try MailMessageImporter.facts(threadPK: thread, in: db)
            change.formUnion(try MailIndexWriter.rebuildThread(thread, facts: facts, myAddresses: [account], in: db))
        }
        return change
    }

}

#endif
