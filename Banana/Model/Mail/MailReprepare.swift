#if !BANANA_PUBLIC
import Foundation
import GRDB

/// Keeps every stored original prepared for the current preparer, so an open reads prepared
/// output and never waits on `MailHTMLPreparer` (MAIL-ENGINE 10.2: "prepared once, when the
/// message is fetched"). Two things leave an original without a current prepared body: a new
/// `MailHTMLPreparer.version` (every prepared body is stale at once), and an original stored while
/// preparing it failed or was stopped. This pass walks the stored originals newest first, a
/// piece at a time, and prepares what is stale, at the work pace of invariant 31. A conversation
/// being opened goes first (`stale(in:)` names its stale messages for the caller to prepare now).
actor MailReprepare {
    /// Originals read per piece of the walk.
    static let piece = 64
    struct Step: Equatable, Sendable {
        var prepared = 0
        /// More may remain; false once the walk reached the oldest, or the pace says stop.
        var more = false
    }
    private let stores: MailStores
    private let loader: GmailConversationLoader
    private let pace: @Sendable () -> MailWorkPace
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    /// The walk's position: the last original looked at, by (date, account, id), going down.
    private var after: (date: Int64, account: String, id: String)?
    private var finished = false

    init(stores: MailStores, loader: GmailConversationLoader, pace: @escaping @Sendable () -> MailWorkPace,
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.stores = stores; self.loader = loader; self.pace = pace; self.sleep = sleep
    }

    /// The messages of a conversation whose original is here and whose prepared body is not
    /// current: an open prepares these first.
    func stale(in conversation: MailConversationID) async throws -> [MailMessageID] {
        let account = conversation.account.lowercased()
        let ids = try await stores.index.read { db in
            try String.fetchAll(db, sql: """
                SELECT m.gmail_id FROM message m JOIN thread t ON t.thread_pk=m.thread_pk JOIN account a ON a.account_pk=t.account_pk
                WHERE a.email=? AND t.gmail_id=? AND m.fetch_state=2 AND m.vis!=4 ORDER BY m.internal_date DESC
                """, arguments: [account, conversation.thread])
        }
        guard !ids.isEmpty else { return [] }
        let version = MailHTMLPreparer.version
        return try await stores.blobs.read { db in
            try ids.filter { id in
                try Bool.fetchOne(db, sql: """
                    SELECT EXISTS(SELECT 1 FROM content c LEFT JOIN prepared p ON p.account=c.account AND p.gmail_id=c.gmail_id
                    WHERE c.account=? AND c.gmail_id=? AND c.level=2
                      AND (p.gmail_id IS NULL OR p.prep_version != ? OR p.source_rev != c.content_rev))
                    """, arguments: [account, id, version]) == true
            }.map { MailMessageID(account: account, message: $0) }
        }
    }

    /// Starts the walk again from the newest (a new launch, new mail stored raw).
    func restart() { after = nil; finished = false }

    /// One piece of the walk: up to `piece` originals looked at, the stale ones prepared one by
    /// one, each followed by the pace's pause.
    func step() async throws -> Step {
        guard !finished else { return Step() }
        guard pace().pause(afterWorking: 0) != nil else { return Step() }   // stopped: warm, Low Power, not on screen
        let version = MailHTMLPreparer.version, position = after
        let page = try await stores.blobs.read { db in try Self.page(after: position, limit: Self.piece, version: version, in: db) }
        guard let last = page.rows.last else { finished = true; return Step() }
        var step = Step(prepared: 0, more: true)
        for id in page.stale {
            try Task.checkCancellation()
            let start = ContinuousClock.now
            if try await loader.prepareStored(id) { step.prepared += 1 }
            let work = start.duration(to: .now)
            let seconds = Double(work.components.seconds) + Double(work.components.attoseconds) / 1e18
            guard let pause = pace().pause(afterWorking: seconds) else { return Step(prepared: step.prepared, more: true) }
            if pause > 0 { try await sleep(pause) }
        }
        after = last
        if page.rows.count < Self.piece { finished = true; step.more = false }
        return step
    }

    /// A page of the walk: the originals looked at, and which of them are stale — missing a
    /// prepared body, made by an older preparer, or made from an older revision of the original.
    static func page(after: (date: Int64, account: String, id: String)?, limit: Int, version: Int,
                     in db: Database) throws -> (rows: [(date: Int64, account: String, id: String)], stale: [MailMessageID]) {
        var arguments: StatementArguments = [version]
        var below = ""
        if let after {
            below = "AND (c.internal_date, c.account, c.gmail_id) < (?, ?, ?)"
            arguments += [after.date, after.account, after.id]
        }
        arguments += [limit]
        let rows = try Row.fetchAll(db, sql: """
            SELECT c.internal_date, c.account, c.gmail_id,
                   (p.gmail_id IS NULL OR p.prep_version != ? OR p.source_rev != c.content_rev) AS stale
            FROM content c INDEXED BY content_by_date
            LEFT JOIN prepared p ON p.account=c.account AND p.gmail_id=c.gmail_id
            WHERE c.level=2 \(below)
            ORDER BY c.internal_date DESC, c.account DESC, c.gmail_id DESC LIMIT ?
            """, arguments: arguments)
        var looked: [(date: Int64, account: String, id: String)] = [], stale: [MailMessageID] = []
        for row in rows {
            let date: Int64 = row[0], account: String = row[1], id: String = row[2], isStale: Bool = row[3]
            looked.append((date, account, id))
            if isStale { stale.append(MailMessageID(account: account, message: id)) }
        }
        return (looked, stale)
    }
}

#endif
