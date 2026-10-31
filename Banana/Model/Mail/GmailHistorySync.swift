#if !BANANA_PUBLIC
import Foundation
import GRDB

/// Resumes only an established checkpoint. Bootstrap/reconciliation and durable
/// post-commit recovery are explicit dependencies, never replaced by a first-page read.
actor GmailHistorySync {
    enum Failure: Error { case busy, wrongAccount, malformed, invalidLimit }
    enum Result: Equatable, Sendable {
        case needsReconcile
        case current(checkpoint: UInt64, committedPages: Int, hasMore: Bool)
    }
    typealias Recover = @Sendable (String) async throws -> Void
    typealias Committed = @Sendable (String, MailHistoryIndex.Applied) async throws -> Void
    private let stores: MailStores
    private let writer: MailWriter
    private let api: any GmailAPI
    private let token: GmailPageLoader.Token
    private let recover: Recover
    private let committed: Committed
    private var running = Set<String>()

    init(stores: MailStores, writer: MailWriter, api: any GmailAPI,
         token: @escaping GmailPageLoader.Token, recover: @escaping Recover,
         committed: @escaping Committed) {
        self.stores = stores; self.writer = writer; self.api = api
        self.token = token; self.recover = recover; self.committed = committed
    }

    func poll(account rawAccount: String, nowMS: Int64, maximumPages: Int = 10) async throws -> Result {
        guard (1...100).contains(maximumPages), nowMS >= 0 else { throw Failure.invalidLimit }
        let account = rawAccount.lowercased()
        guard running.insert(account).inserted else { throw Failure.busy }
        defer { running.remove(account) }
        try Task.checkCancellation()
        let bearer = try await token(account)
        let profile = try await api.profile(token: bearer)
        guard profile.emailAddress?.lowercased() == account else { throw Failure.wrongAccount }
        try Task.checkCancellation()
        // Tombstones and stubs survive a crash after checkpoint commit but before
        // follow-up cleanup/fetch work; recovery must drain/reschedule them first.
        try await recover(account)
        let position = try await stores.index.read { db -> (String?, Int64?) in
            guard let row = try Row.fetchOne(db, sql: "SELECT checkpoint,last_sync_at FROM account WHERE email=?", arguments: [account]) else { return (nil, nil) }
            return (row["checkpoint"], row["last_sync_at"])
        }
        guard var rawPosition = position.0, var checkpoint = GmailNumber.unsigned(rawPosition), checkpoint > 0 else {
            return .needsReconcile
        }
        // Gmail page tokens belong to this fixed start position, even as each
        // committed page advances the restart checkpoint stored on disk.
        let requestStart = checkpoint
        var cursor: String?
        var seenTokens = Set<String>()
        var pages = 0
        while pages < maximumPages {
            try Task.checkCancellation()
            let page: GmailHistoryPage
            do {
                page = try await api.history(token: bearer, start: String(requestStart), pageToken: cursor, maxResults: 100)
            } catch GmailError.notFound {
                let expected = rawPosition
                _ = try await writer.transact { db in
                    try MailSyncCheckpoint.expire(account: account, expected: expected, in: db)
                    return MailStoreChange()
                }
                return .needsReconcile
            }
            try Task.checkCancellation()
            if let next = page.nextPageToken {
                guard !next.isEmpty, seenTokens.insert(next).inserted else { throw Failure.malformed }
            }
            guard let latest = page.historyId, latest >= checkpoint else { throw Failure.malformed }
            if (page.history ?? []).isEmpty, page.nextPageToken == nil, pages == 0,
               let synced = position.1, synced >= 0, nowMS >= synced, nowMS - synced < 3_600_000 {
                return .current(checkpoint: checkpoint, committedPages: 0, hasMore: false)
            }
            let expected = checkpoint
            let finishesNonemptyPass = pages > 0
            let applied = try await writer.transactValue { db in
                let value = try MailHistoryIndex.apply(page, account: account, after: expected,
                    nowMS: nowMS, finishesNonemptyPass: finishesNonemptyPass, in: db)
                return (value, value.change)
            }
            checkpoint = applied.checkpoint; rawPosition = String(checkpoint); pages += 1
            try await committed(account, applied)
            cursor = page.nextPageToken
            if cursor == nil { return .current(checkpoint: checkpoint, committedPages: pages, hasMore: false) }
        }
        return .current(checkpoint: checkpoint, committedPages: pages, hasMore: true)
    }
}

#endif
