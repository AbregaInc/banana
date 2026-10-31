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
    private var running = Set<String>()

    init(stores: MailStores, writer: MailWriter, api: any GmailAPI,
         token: @escaping GmailPageLoader.Token, recovery: MailRemovalRecovery) {
        self.stores = stores
        let recover: GmailHistorySync.Recover = { account in _ = try await recovery.recover(account: account) }
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
            case .more: return Progress(hasMore: true, checkpoint: checkpoint)
            case .needsVerification:
                let outcome = try await verification.verify(account: account, nowMS: nowMS, maximumBatches: 1)
                return Progress(hasMore: moreHistory || outcome == .more, checkpoint: checkpoint)
            }
        }
        return Progress(hasMore: moreHistory, checkpoint: checkpoint)
    }
}

#endif
