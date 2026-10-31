#if !BANANA_PUBLIC
import Foundation
import GRDB

/// Serializes intent commit and its index projection across suspension points.
/// A failed index projection leaves durable intent available for recovery.
actor MailActionCoordinator {
    enum Failure: Error {
        case missingConversation
        // The caller must retain optimistic intent: only its disposable projection failed.
        case projectionAfterCommit(sequence: Int64, underlying: any Error)
    }
    let stores: MailStores
    let intent: MailIntentStore
    let writer: MailWriter
    private var tail: Task<Void, Never>?
    init(stores: MailStores, intent: MailIntentStore, writer: MailWriter) {
        self.stores = stores; self.intent = intent; self.writer = writer
        writer.keep(intent)
    }
    struct Target: Sendable {
        let id: MailConversationID
        let asOf: Int64
        // Snapshot boundary excludes later imports even when their dates are identical.
        var messageArrivalCeiling: Int64 = .max
    }
    struct Applied: Sendable {
        let sequence: Int64?
        let count: Int
        let before: [Assertion]
        let projectionError: (any Error)?
        var inverseGroup: Int64? = nil
    }
    func apply(_ change: MailChange, to id: MailConversationID, asOf: Int64, at: Int64) async throws -> Int64? {
        let result = try await apply(change, to: [Target(id: id, asOf: asOf)], at: at)
        if let sequence = result.sequence, let error = result.projectionError {
            throw Failure.projectionAfterCommit(sequence: sequence, underlying: error)
        }
        return result.sequence
    }

    /// One user action, one durable receipt, including unified multi-account selection.
    func apply(_ change: MailChange, to targets: [Target], sequence: Int64? = nil, at: Int64) async throws -> Applied {
        let prior = tail
        let stores = stores, intent = intent, writer = writer
        let work = Task<Applied, Error> {
            await prior?.value
            let prepared = try await stores.index.read { db -> ([Assertion], [Assertion], Int) in
                var desired: [Assertion] = [], before: [Assertion] = [], count = 0
                var seen = Set<MailConversationID>()
                for target in targets where seen.insert(target.id).inserted {
                    let id = target.id
                    guard let pk = try Int64.fetchOne(db, sql: "SELECT t.thread_pk FROM thread t JOIN account a ON a.account_pk=t.account_pk WHERE a.email=? AND t.gmail_id=?", arguments: [id.account, id.thread]) else { throw Failure.missingConversation }
                    let facts = try MailMessageImporter.facts(threadPK: pk, in: db).filter { $0.arrivalSequence <= target.messageArrivalCeiling }
                    let assertions = try OutboxRules.assertions(for: change, account: id.account, messages: facts, asOf: target.asOf)
                    if !assertions.isEmpty { count += 1 }
                    let labels = Dictionary(uniqueKeysWithValues: facts.map { ($0.gmailID, $0.labels) })
                    desired += assertions
                    before += assertions.map { value in
                        Assertion(account: value.account, messageID: value.messageID, labelRef: value.labelRef,
                                  want: labels[value.messageID]?.contains(value.labelRef) == true, origin: .person)
                    }
                }
                return (desired, before, count)
            }
            guard !prepared.0.isEmpty else {
                return Applied(sequence: nil, count: 0, before: [], projectionError: nil)
            }
            let committed = try await intent.record(change, assertions: prepared.0, conversations: prepared.2, at: at, sequence: sequence)
            do {
                for (account, assertions) in Dictionary(grouping: prepared.0, by: \.account) {
                    try await Self.project(account: account, messages: Array(Set(assertions.map(\.messageID))).sorted(), through: 0, intent: intent, writer: writer)
                }
                // Only acknowledge after every account's projection is complete.
                _ = try await writer.transact { _ in MailStoreChange(through: UInt64(committed)) }
                return Applied(sequence: committed, count: prepared.2, before: prepared.1, projectionError: nil)
            } catch {
                // The inverse remains available even if the cache fails after fsync.
                return Applied(sequence: committed, count: prepared.2, before: prepared.1, projectionError: error)
            }
        }
        tail = Task { _ = try? await work.value }
        return try await work.value
    }
    enum Selection: Sendable {
        case list(view: MailViewKey, account: String?, filters: Set<MailFilter>, from: MailOrderKey?)
        case search(MailLocalSearchQuery)
    }

    /// Retained-history selection is read from one SQLite snapshot and staged in bounded pieces.
    /// Nothing is sent or acknowledged until the final intent transaction commits.
    func apply(_ change: MailChange, selection: Selection, sequence: Int64, at: Int64) async throws -> Applied {
        let prior = tail, stores = stores, intent = intent, writer = writer
        let work = Task<Applied, Error> {
            await prior?.value
            let snapshot = try await Task.detached { try stores.index.makeSnapshot() }.value
            let stage = UUID().uuidString
            do {
                var cursor: MailOrderKey?, first = true
                var buffered: [MailIntentStore.StagedAssertion] = []
                buffered.reserveCapacity(500)
                while true {
                    try Task.checkCancellation()
                    let boundary = cursor, inclusive = first
                    let rows = try await snapshot.read { db in
                        switch selection {
                        case .list(let view, let account, let filters, let from):
                            return try MailIndexReader.page(PageRequest(view: view, account: account, filters: filters,
                                before: boundary ?? from, limit: 100), in: db, includingBoundary: inclusive)
                        case .search(var query):
                            query.before = boundary ?? query.before; query.limit = 100
                            return try MailIndexReader.search(query, in: db, includingBoundary: inclusive)
                        }
                    }
                    guard let last = rows.last else { break }
                    for row in rows {
                        let prepared = try await snapshot.read { db -> [MailIntentStore.StagedAssertion] in
                            let facts = try MailMessageImporter.facts(threadPK: row.threadPK, in: db)
                            let labels = Dictionary(uniqueKeysWithValues: facts.map { ($0.gmailID, $0.labels) })
                            return try OutboxRules.assertions(for: change, account: row.account, messages: facts, asOf: row.lastDate).map {
                                MailIntentStore.StagedAssertion(thread: row.thread, assertion: $0,
                                    previous: labels[$0.messageID]?.contains($0.labelRef) == true)
                            }
                        }
                        for value in prepared {
                            buffered.append(value)
                            if buffered.count == 500 {
                                try await intent.appendStage(stage, values: buffered)
                                buffered.removeAll(keepingCapacity: true)
                            }
                        }
                    }
                    cursor = MailOrderKey(group: 0, sortKey: last.sortKey, tie: last.tie)
                    first = false
                }
                if !buffered.isEmpty { try await intent.appendStage(stage, values: buffered) }
                // Preparation is complete; release the WAL read transaction before projection.
                try snapshot.close()
                let count = try await intent.commitStage(stage, change: change, sequence: sequence, at: at)
                guard count > 0 else { return Applied(sequence: nil, count: 0, before: [], projectionError: nil) }
                do {
                    try await Self.projectGroup(sequence, intent: intent, writer: writer)
                    _ = try await writer.transact { _ in MailStoreChange(through: UInt64(sequence)) }
                    return Applied(sequence: sequence, count: count, before: [], projectionError: nil, inverseGroup: sequence)
                } catch {
                    return Applied(sequence: sequence, count: count, before: [], projectionError: error, inverseGroup: sequence)
                }
            } catch {
                // Cancellation must not strand temporary preparation; startup also cleans it.
                try? await Task.detached { try await intent.discardStage(stage) }.value
                throw error
            }
        }
        tail = Task { _ = try? await work.value }
        return try await work.value
    }

    private static func projectGroup(_ group: Int64, intent: MailIntentStore, writer: MailWriter) async throws {
        var cursor: MailIntentStore.Cursor?
        while true {
            let page = try await intent.assertions(group: group, after: cursor)
            guard let last = page.last else { break }
            for (account, assertions) in Dictionary(grouping: page, by: { $0.assertion.account }) {
                try await project(account: account, messages: Array(Set(assertions.map { $0.assertion.messageID })).sorted(), through: 0, intent: intent, writer: writer)
            }
            cursor = MailIntentStore.Cursor(last)
        }
    }

    /// Undo asserts the saved effective labels as new durable intent; it is not redoable.
    func undo(_ applied: Applied, change: MailChange, sequence: Int64, at: Int64) async throws -> Applied {
        let prior = tail, intent = intent, writer = writer
        let work = Task<Applied, Error> {
            await prior?.value
            guard (!applied.before.isEmpty || applied.inverseGroup != nil), applied.count > 0 else {
                return Applied(sequence: nil, count: 0, before: [], projectionError: nil)
            }
            let committed: Int64
            if let group = applied.inverseGroup {
                _ = try await intent.commitStoredInverse(group, change: change, sequence: sequence, at: at)
                committed = sequence
            } else {
                committed = try await intent.recordInverse(of: change, assertions: applied.before,
                    conversations: applied.count, at: at, sequence: sequence)
            }
            do {
                if applied.inverseGroup != nil { try await Self.projectGroup(committed, intent: intent, writer: writer) }
                for (account, assertions) in Dictionary(grouping: applied.before, by: \.account) {
                    try await Self.project(account: account, messages: Array(Set(assertions.map(\.messageID))).sorted(), through: 0, intent: intent, writer: writer)
                }
                _ = try await writer.transact { _ in MailStoreChange(through: UInt64(committed)) }
                return Applied(sequence: committed, count: applied.count, before: [], projectionError: nil)
            } catch {
                return Applied(sequence: committed, count: applied.count, before: [], projectionError: error)
            }
        }
        tail = Task { _ = try? await work.value }
        return try await work.value
    }

    func retry(group: Int64) async throws {
        let prior = tail, intent = intent, writer = writer
        let work = Task {
            await prior?.value
            try await intent.retry(group: group)
            do {
                var cursor: MailIntentStore.Cursor?
                while true {
                    let page = try await intent.assertions(group: group, after: cursor)
                    guard let last = page.last else { break }
                    for (account, assertions) in Dictionary(grouping: page, by: { $0.assertion.account }) {
                        try await Self.project(account: account, messages: Array(Set(assertions.map { $0.assertion.messageID })).sorted(), through: 0, intent: intent, writer: writer)
                    }
                    cursor = MailIntentStore.Cursor(last)
                }
            } catch { throw Failure.projectionAfterCommit(sequence: group, underlying: error) }
        }
        tail = Task { _ = try? await work.value }
        try await work.value
    }

    func refresh(account: String, messages: [String]) async throws {
        let prior = tail, intent = intent, writer = writer
        let work = Task {
            await prior?.value
            try await Self.project(account: account, messages: Array(Set(messages)).sorted(), through: 0, intent: intent, writer: writer)
        }
        tail = Task { _ = try? await work.value }
        try await work.value
    }
    /// Run before exposing the source or starting delivery. Both directions matter:
    /// absent overlays need replay; overlays of already-confirmed intent need removal.
    func recover(resetDelivery: Bool = true) async throws {
        let prior = tail, stores = stores, intent = intent, writer = writer
        let work = Task {
            await prior?.value
            if resetDelivery { try await intent.recoverInterruptedDelivery() }
            var after: Int64 = 0
            while true {
                let cursor = after
                let rows = try await stores.index.read { db in
                    try Row.fetchAll(db, sql: """
                        SELECT m.msg_pk,a.email,m.gmail_id FROM message m
                        JOIN account a ON a.account_pk=m.account_pk
                        WHERE m.msg_pk>? AND EXISTS(SELECT 1 FROM overlay o WHERE o.msg_pk=m.msg_pk)
                        ORDER BY m.msg_pk LIMIT 100
                        """, arguments: [cursor]).map { row -> (Int64, String, String) in
                            (row[0], row[1], row[2])
                        }
                }
                guard let last = rows.last else { break }
                for (account, values) in Dictionary(grouping: rows, by: { $0.1 }) {
                    try await Self.project(account: account, messages: values.map { $0.2 }, through: 0, intent: intent, writer: writer)
                }
                after = last.0
            }
            var cursor: MailIntentStore.Cursor?
            while true {
                let page = try await intent.assertions(after: cursor)
                guard let last = page.last else { break }
                for (account, values) in Dictionary(grouping: page, by: { $0.assertion.account }) {
                    try await Self.project(account: account, messages: Array(Set(values.map { $0.assertion.messageID })).sorted(), through: 0, intent: intent, writer: writer)
                }
                cursor = MailIntentStore.Cursor(last)
            }
        }
        tail = Task { _ = try? await work.value }
        try await work.value
    }
    private static func project(account: String, messages: [String], through: UInt64, intent: MailIntentStore, writer: MailWriter) async throws {
        for offset in stride(from: 0, to: messages.count, by: 20) {
            let batch = Array(messages[offset..<min(offset + 20, messages.count)])
            let values = try await intent.assertions(account: account, messages: batch)
            _ = try await writer.transact { db in
                try MailActionIndex.replace(account: account, messages: batch, assertions: values, through: messages.count <= 20 ? through : 0, rebuild: messages.count <= 20, in: db)
            }
        }
        if messages.count > 20 {
            _ = try await writer.transact { db in
                try MailActionIndex.rebuild(account: account, messages: messages, through: through, in: db)
            }
        }
    }
}

#endif
