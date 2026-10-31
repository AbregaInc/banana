#if !BANANA_PUBLIC
import Foundation
import GRDB

/// Index-side replay only. The worker must verify the token's account before calling,
/// publish `change` after commit, then process fetches, tombstone cleanup and intent echoes.
enum MailHistoryIndex {
    enum Failure: Error { case transactionRequired, invalidPage, changedCheckpoint }
    struct Applied: Sendable {
        var change = MailStoreChange()
        var fetch: [String] = []
        var deleted: [String] = []
        var held: [String] = []
        var echoes: [EchoedIntent] = []
        var checkpoint: UInt64
    }

    static func apply(_ page: GmailHistoryPage, account: String, after start: UInt64,
                      nowMS: Int64, finishesNonemptyPass: Bool = false, in db: Database) throws -> Applied {
        guard db.isInsideTransaction else { throw Failure.transactionRequired }
        let records = page.history ?? []
        guard let end = page.historyId, end >= start, start > 0, nowMS >= 0,
              page.nextPageToken != "", page.nextPageToken == nil || !records.isEmpty,
              records.allSatisfy({ ($0.id ?? 0) > start && ($0.id ?? UInt64.max) <= end }) else {
            throw Failure.invalidPage
        }
        guard let owner = try Row.fetchOne(db, sql: "SELECT account_pk,checkpoint,last_sync_at,removals FROM account WHERE email=?", arguments: [account]),
              let position: String = owner["checkpoint"], GmailNumber.unsigned(position) == start else {
            throw Failure.changedCheckpoint
        }
        let accountPK: Int64 = owner["account_pk"]
        let next = page.nextPageToken == nil ? end : records.last!.id!
        var result = Applied(checkpoint: start)
        if !finishesNonemptyPass, records.isEmpty, let synced: Int64 = owner["last_sync_at"], synced >= 0, nowMS >= synced, nowMS - synced < 3_600_000 {
            return result
        }
        var changes: [GmailHistoryChange] = []
        for record in records {
            changes.append(contentsOf: record.messagesAdded ?? [])
            changes.append(contentsOf: record.messagesDeleted ?? [])
            changes.append(contentsOf: record.labelsAdded ?? [])
            changes.append(contentsOf: record.labelsRemoved ?? [])
        }
        let ids = Array(Set(changes.compactMap { $0.message?.id })).sorted()
        var rows: [String: Row] = [:], states: [String: StoredMessageState] = [:]
        var tombstones = Set<String>()
        for offset in stride(from: 0, to: ids.count, by: 100) {
            let batch = Array(ids[offset..<min(offset + 100, ids.count)])
            let slots = Array(repeating: "?", count: batch.count).joined(separator: ",")
            let values: [DatabaseValue] = [accountPK.databaseValue] + batch.map { $0.databaseValue }
            let args = StatementArguments(values)
            for row in try Row.fetchAll(db, sql: "SELECT * FROM message WHERE account_pk=? AND gmail_id IN (\(slots))", arguments: args) {
                let id: String = row["gmail_id"], version: String? = row["history_id"]
                rows[id] = row
                states[id] = StoredMessageState(msgPK: row["msg_pk"], fetchState: row["fetch_state"], vis: row["vis"], labels: [],
                    labelsKnown: MailMessageFlags(rawValue: row["flags"]).contains(.labelsKnown), historyID: version.flatMap(GmailNumber.unsigned))
            }
            tombstones.formUnion(try String.fetchAll(db, sql: "SELECT gmail_id FROM tombstone WHERE account_pk=? AND gmail_id IN (\(slots))", arguments: args))
        }
        let plan = try MailHistoryRules.plan(records, account: account, known: { states[$0] },
            knownLabel: { _ in true }, tombstoned: { tombstones.contains($0) })
        var threads = Set<Int64>()
        for stub in plan.createStubs {
            try db.execute(sql: "INSERT OR IGNORE INTO thread(account_pk,gmail_id,tie) VALUES(?,?,?)",
                arguments: [accountPK, stub.threadID, MailMessageImporter.tie(account: account, thread: stub.threadID)])
            let thread = try Int64.fetchOne(db, sql: "SELECT thread_pk FROM thread WHERE account_pk=? AND gmail_id=?", arguments: [accountPK, stub.threadID])!
            try db.execute(sql: "INSERT INTO message(account_pk,gmail_id,thread_pk,history_id,fetch_class,list_rank) VALUES(?,?,?,?,?,?)",
                arguments: [accountPK, stub.gmailID, thread, String(stub.historyID), stub.fetchClass, stub.listRank])
            threads.insert(thread)
        }
        for delta in plan.setLabels {
            guard let row = rows[delta.messageID] else { throw Failure.invalidPage }
            let message: Int64 = row["msg_pk"]
            for label in delta.add.union(delta.remove).sorted() {
                try db.execute(sql: "INSERT OR IGNORE INTO label(account_pk,gmail_id,name,kind) VALUES(?,?,?,?)",
                    arguments: [accountPK, label, label, SystemLabel(rawValue: label) == nil ? 1 : 0])
                result.change.labelsChanged = result.change.labelsChanged || db.changesCount > 0
                let pk = try Int64.fetchOne(db, sql: "SELECT label_pk FROM label WHERE account_pk=? AND gmail_id=?", arguments: [accountPK, label])!
                if delta.add.contains(label) {
                    try db.execute(sql: "INSERT OR IGNORE INTO message_label(msg_pk,label_pk) VALUES(?,?)", arguments: [message, pk])
                } else {
                    try db.execute(sql: "DELETE FROM message_label WHERE msg_pk=? AND label_pk=?", arguments: [message, pk])
                }
            }
            try db.execute(sql: "UPDATE message SET history_id=? WHERE msg_pk=?", arguments: [String(delta.recordID), message])
            threads.insert(row["thread_pk"])
        }
        if !plan.delete.isEmpty {
            let cached = try Int.fetchOne(db, sql: "SELECT count(*) FROM message WHERE account_pk=? AND vis != 4", arguments: [accountPK])!
            let unresolved = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM held_removal h JOIN message m ON m.msg_pk=h.msg_pk WHERE m.account_pk=? AND h.kept=0)", arguments: [accountPK])!
            let saved: String? = owner["removals"]
            let history = try saved.map { try JSONDecoder().decode([MailRemovalRules.Hour].self, from: Data($0.utf8)) } ?? []
            let decision = try MailRemovalRules.decide(removals: plan.delete.count, cachedMessages: cached,
                previous: history, hasUnresolvedHold: unresolved, nowMS: nowMS)
            for id in plan.delete {
                guard let row = rows[id] else { throw Failure.invalidPage }
                let message: Int64 = row["msg_pk"]
                threads.insert(row["thread_pk"])
                if decision.hold {
                    try db.execute(sql: "INSERT OR IGNORE INTO held_removal(msg_pk,evidence,found_at) VALUES(?,1,?)", arguments: [message, nowMS])
                    result.held.append(id)
                } else {
                    try db.execute(sql: "INSERT OR REPLACE INTO tombstone(account_pk,gmail_id,at) VALUES(?,?,?)", arguments: [accountPK, id, nowMS])
                    for table in ["message_label", "overlay", "enum_mark", "verify_queue", "held_removal"] {
                        try db.execute(sql: "DELETE FROM \(table) WHERE msg_pk=?", arguments: [message])
                    }
                    try db.execute(sql: "DELETE FROM message WHERE msg_pk=?", arguments: [message])
                    result.deleted.append(id)
                }
            }
            let encoded = String(decoding: try JSONEncoder().encode(decision.history), as: UTF8.self)
            try db.execute(sql: "UPDATE account SET removals=? WHERE account_pk=?", arguments: [encoded, accountPK])
        }
        for thread in threads {
            result.change.formUnion(try MailIndexWriter.rebuildThread(thread,
                facts: MailMessageImporter.facts(threadPK: thread, in: db), myAddresses: [account], in: db))
        }
        try db.execute(sql: "UPDATE account SET checkpoint=?,last_sync_at=? WHERE account_pk=?", arguments: [String(next), nowMS, accountPK])
        result.checkpoint = next; result.fetch = plan.fetch; result.echoes = plan.echoes
        return result
    }
}

#endif
