#if !BANANA_PUBLIC
import Foundation
import GRDB

/// One bounded account pass. History gets a turn between backfill batches, so
/// a large first sync cannot starve new arrivals or age its checkpoint out.
actor GmailMailboxSync {
    enum Failure: Error { case busy }
    struct Progress: Equatable, Sendable {
        var hasMore: Bool
        var checkpoint: UInt64?
    }
    private let stores: MailStores
    private let history: GmailHistorySync
    private let reconcile: GmailReconcileSync
    private let verification: GmailVerificationSync
    private let feed: MailCloudFeedSync?
    private var running = Set<String>()

    /// With `feed`, an account whose service offers Banana Cloud's shared mailbox syncs from it and
    /// nothing else (MAIL-CLOUD-SYNC §8); the Gmail path below stays for a service without one.
    init(stores: MailStores, writer: MailWriter, api: any GmailAPI,
         token: @escaping GmailPageLoader.Token, recovery: MailRemovalRecovery,
         feed source: (any MailCloudFeedSource)? = nil) {
        self.stores = stores
        let recover: GmailHistorySync.Recover = { account in _ = try await recovery.recover(account: account) }
        feed = source.map { MailCloudFeedSync(stores: stores, writer: writer, source: $0, recover: recover) }
        history = GmailHistorySync(stores: stores, writer: writer, api: api, token: token,
            recover: recover, committed: { account, value in
                if !value.deleted.isEmpty { try await recover(account) }
            })
        reconcile = GmailReconcileSync(stores: stores, writer: writer, api: api, token: token)
        verification = GmailVerificationSync(stores: stores, writer: writer, api: api, token: token,
            recover: recover, committed: { account, value in
                if !value.deleted.isEmpty { try await recover(account) }
            })
    }

    func pass(account: String, nowMS: Int64) async throws -> Progress {
        guard running.insert(account).inserted else { throw Failure.busy }
        defer { running.remove(account) }
        if let feed, let progress = try await feed.pass(account: account, nowMS: nowMS) { return progress }
        let result = try await history.poll(account: account, nowMS: nowMS, maximumPages: 2)
        var needsReconcile = false
        var moreHistory = false
        var checkpoint: UInt64?
        switch result {
        case .needsReconcile: needsReconcile = true
        case .current(let position, _, let hasMore): checkpoint = position; moreHistory = hasMore
        }
        let unfinished = try await stores.index.read { try MailReconcileIndex.state(account: account, in: $0) != nil }
        if needsReconcile || unfinished {
            switch try await reconcile.enumerate(account: account, nowMS: nowMS, maximumSteps: 2) {
            case .more:
                let pending = try await stores.index.read { db in
                    try Bool.fetchOne(db, sql: """
                        SELECT EXISTS(SELECT 1 FROM verify_queue q JOIN message m ON m.msg_pk=q.msg_pk
                        JOIN account a ON a.account_pk=m.account_pk
                        WHERE a.email=? AND q.generation=a.enum_generation AND q.outcome IS NULL AND m.vis!=4)
                        """, arguments: [account]) == true
                }
                if pending { _ = try await verification.verify(account: account, nowMS: nowMS, maximumBatches: 1) }
                return Progress(hasMore: true, checkpoint: checkpoint)
            case .needsVerification:
                let outcome = try await verification.verify(account: account, nowMS: nowMS, maximumBatches: 1)
                return Progress(hasMore: moreHistory || outcome == .more, checkpoint: checkpoint)
            }
        }
        return Progress(hasMore: moreHistory, checkpoint: checkpoint)
    }
}

#endif
