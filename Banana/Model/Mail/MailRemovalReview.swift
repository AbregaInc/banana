#if !BANANA_PUBLIC
import Foundation
import GRDB

struct MailRemovalReview: Equatable, Sendable {
    let id: String
    let account: String
    let count: Int
    var choice: MailChoice?
}

struct MailRemovalReviewRow: Identifiable, Equatable, Sendable {
    let id: String
    var conversation: MailConversationID?
    var subject: String
    var sender: String
    var date: Date?
}
struct MailRemovalReviewPage: Sendable {
    var rows: [MailRemovalReviewRow]
    var next: String?
}

/// A review captures exact message ids into the intent store. Its short-lived index
/// snapshot closes before the user sees the review, so an open sheet cannot pin WAL
/// history indefinitely. Only an explicitly committed choice is replayed at startup.
actor MailRemovalCoordinator {
    enum Failure: Error { case invalidReview, invalidChoice }
    let stores: MailStores
    let intent: MailIntentStore
    let writer: MailWriter
    private var active = Set<String>()

    init(stores: MailStores, intent: MailIntentStore, writer: MailWriter) {
        self.stores = stores; self.intent = intent; self.writer = writer
        writer.keep(intent)
    }

    func review(account: String, at: Int64) async throws -> MailRemovalReview {
        let id = UUID().uuidString
        try await intent.beginRemovalReview(id, account: account, at: at)
        let stores = self.stores
        let snapshot: DatabaseSnapshot
        do { snapshot = try await Task.detached { try stores.index.makeSnapshot() }.value }
        catch { try? await intent.discardRemovalReview(id); throw error }
        do {
            var after: Int64 = 0
            while true {
                try Task.checkCancellation()
                let boundary = after
                let rows = try await snapshot.read { db -> [(key: Int64, id: String)] in
                    try Row.fetchAll(db, sql: """
                        SELECT m.msg_pk,m.gmail_id FROM held_removal h JOIN message m ON m.msg_pk=h.msg_pk
                        JOIN account a ON a.account_pk=m.account_pk WHERE a.email=? AND h.kept=0 AND m.msg_pk>?
                        ORDER BY m.msg_pk LIMIT 100
                        """, arguments: [account, boundary]).map { (key: $0[0], id: $0[1]) }
                }
                guard let last = rows.last else { break }
                try await intent.appendRemovalReview(id, messages: rows.map(\.id))
                after = last.key
            }
            try snapshot.close()
            guard let review = try await intent.removalReview(id) else { throw Failure.invalidReview }
            return review
        } catch {
            try? snapshot.close()
            try? await intent.discardRemovalReview(id)
            throw error
        }
    }

    func answer(_ id: String, choice: MailChoice, at: Int64) async throws {
        guard choice == .keepHere || choice == .remove else { throw Failure.invalidChoice }
        try await intent.commitRemovalReview(id, choice: choice)
        try await resume(id, at: at)
    }

    func recover(at: Int64) async throws {
        for id in try await intent.pendingRemovalReviews() { try await resume(id, at: at) }
    }

    func resume(_ id: String, at: Int64) async throws {
        guard active.insert(id).inserted else { return }
        defer { active.remove(id) }
        guard let review = try await intent.removalReview(id), let choice = review.choice else { throw Failure.invalidReview }
        while true {
            try Task.checkCancellation()
            let messages = try await intent.removalReviewMessages(id, after: nil, limit: 50)
            guard !messages.isEmpty else { return }
            // This intent is moot even if its disposable index projection fails.
            try await intent.discardForVerifiedRemoval(account: review.account, messages: messages)
            _ = try await writer.transact { db in
                try Self.apply(account: review.account, messages: messages, choice: choice, at: at, in: db)
            }
            if choice == .remove {
                _ = try await MailRemovalRecovery(stores: stores, intents: intent).recover(account: review.account)
            }
            try await intent.finishRemovalReviewMessages(id, messages: messages)
        }
    }

    private static func apply(account: String, messages: [String], choice: MailChoice, at: Int64, in db: Database) throws -> MailStoreChange {
        var threads = Set<Int64>()
        for id in messages {
            guard let row = try Row.fetchOne(db, sql: """
                SELECT m.msg_pk,m.thread_pk,m.account_pk FROM held_removal h JOIN message m ON m.msg_pk=h.msg_pk
                JOIN account a ON a.account_pk=m.account_pk WHERE a.email=? AND m.gmail_id=?
                """, arguments: [account, id]) else { continue }
            let message: Int64 = row[0], thread: Int64 = row[1], owner: Int64 = row[2]
            threads.insert(thread)
            if choice == .keepHere {
                // Freeze the displayed effective labels before clearing moot intent.
                try db.execute(sql: "DELETE FROM message_label WHERE msg_pk=? AND label_pk IN (SELECT label_pk FROM overlay WHERE msg_pk=? AND want=0 AND refused=0)", arguments: [message, message])
                try db.execute(sql: "INSERT OR IGNORE INTO message_label(msg_pk,label_pk) SELECT msg_pk,label_pk FROM overlay WHERE msg_pk=? AND want=1 AND refused=0", arguments: [message])
                try db.execute(sql: "DELETE FROM overlay WHERE msg_pk=?", arguments: [message])
                try db.execute(sql: "DELETE FROM verify_queue WHERE msg_pk=?", arguments: [message])
                try db.execute(sql: "UPDATE held_removal SET kept=1 WHERE msg_pk=?", arguments: [message])
                try db.execute(sql: "UPDATE message SET vis=4 WHERE msg_pk=?", arguments: [message])
            } else {
                try db.execute(sql: "INSERT OR REPLACE INTO tombstone(account_pk,gmail_id,at) VALUES(?,?,?)", arguments: [owner, id, at])
                for table in ["message_label", "overlay", "verify_queue", "enum_mark", "held_removal"] {
                    try db.execute(sql: "DELETE FROM \(table) WHERE msg_pk=?", arguments: [message])
                }
                try db.execute(sql: "DELETE FROM message WHERE msg_pk=?", arguments: [message])
            }
        }
        var change = MailStoreChange()
        for thread in threads {
            change.formUnion(try MailIndexWriter.rebuildThread(thread,
                facts: MailMessageImporter.facts(threadPK: thread, in: db), myAddresses: [account], in: db))
        }
        return change
    }
}

#endif
