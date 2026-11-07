#if !BANANA_PUBLIC
import Foundation
import GRDB

/// One bounded pass over Banana Cloud's mailbox feed for an account (MAIL-CLOUD-SYNC §4): the
/// changes since the saved cursor, or everything from zero, then — once a catch-up from zero has
/// reached the head of a complete mailbox — the rows this device held that the feed never named,
/// handed to the cloud to check. Nothing here talks to Google. `nil` means the service has no
/// feed for this account, and the caller keeps its Gmail path.
actor MailCloudFeedSync {
    enum Failure: Error { case busy, invalidLimit }
    static let pageSize = 500
    /// Entries per index transaction: a long page is applied in slices (MAIL-ENGINE 4.12).
    static let sliceSize = 100
    private let stores: MailStores
    private let writer: MailWriter
    private let source: any MailCloudFeedSource
    private let recover: GmailHistorySync.Recover
    private var running = Set<String>()
    private var unavailableUntil: [String: Int64] = [:]

    init(stores: MailStores, writer: MailWriter, source: any MailCloudFeedSource,
         recover: @escaping GmailHistorySync.Recover) {
        self.stores = stores; self.writer = writer; self.source = source; self.recover = recover
    }

    func pass(account rawAccount: String, nowMS: Int64, maximumPages: Int = 4) async throws -> GmailMailboxSync.Progress? {
        guard (1...100).contains(maximumPages), nowMS >= 0 else { throw Failure.invalidLimit }
        let account = rawAccount.lowercased()
        if let until = unavailableUntil[account], until > nowMS { return nil }
        guard running.insert(account).inserted else { throw Failure.busy }
        defer { running.remove(account) }
        var state = try await stores.index.read { try MailCloudFeedIndex.state(account: account, in: $0) }
        var fresh = true
        for _ in 0..<maximumPages {
            try Task.checkCancellation()
            let page: MailCloudFeedPage
            do {
                page = try await source.page(account: account, after: state?.cursor, limit: Self.pageSize, fresh: fresh)
            } catch MailCloudFeedError.unavailable {
                // Asked again in ten minutes; until then this account syncs as it did before.
                unavailableUntil[account] = nowMS + 600_000
                return nil
            } catch MailCloudFeedError.expired {
                let epoch = state?.epoch ?? ""
                state = try await writer.transactValue { db in
                    (try MailCloudFeedIndex.begin(account: account, epoch: epoch, in: db), MailStoreChange())
                }
                continue
            }
            unavailableUntil[account] = nil
            fresh = false
            if state?.epoch != page.epoch {
                // A new cloud mailbox (first use, or one made again after Mail was turned back on):
                // its sequence starts over, so a page read from an old cursor is not used.
                let readFromZero = state?.cursor == nil
                state = try await writer.transactValue { db in
                    (try MailCloudFeedIndex.begin(account: account, epoch: page.epoch, in: db), MailStoreChange())
                }
                if !readFromZero { continue }
            }
            state = try await apply(page, account: account, expected: state!, nowMS: nowMS)
            if !page.more {
                // A catch-up closes only against a complete cloud mailbox: before that, absence
                // from the feed says nothing at all.
                var catchingUp = state?.catchUpMaxPK != nil
                if catchingUp && page.complete { catchingUp = try await check(account: account, nowMS: nowMS) }
                return GmailMailboxSync.Progress(hasMore: catchingUp, checkpoint: nil)
            }
        }
        return GmailMailboxSync.Progress(hasMore: true, checkpoint: nil)
    }

    private func apply(_ page: MailCloudFeedPage, account: String, expected: MailCloudFeedIndex.State,
                       nowMS: Int64) async throws -> MailCloudFeedIndex.State {
        var state = expected
        let slices = stride(from: 0, to: max(page.entries.count, 1), by: Self.sliceSize).map {
            Array(page.entries[min($0, page.entries.count)..<min($0 + Self.sliceSize, page.entries.count)])
        }
        for (index, slice) in slices.enumerated() {
            try Task.checkCancellation()
            var part = page
            part.entries = slice
            let last = index == slices.count - 1, current = state
            let applied = try await writer.transactValue { db in
                let value = try MailCloudFeedIndex.apply(part, account: account, expected: current, nowMS: nowMS,
                                                         finishesPage: last, in: db)
                return (value, value.change)
            }
            state = applied.state
            if !applied.deleted.isEmpty { try await recover(account) }
        }
        return state
    }

    /// The catch-up's end: up to five checks of 100 ids a pass. True while some remain.
    private func check(account: String, nowMS: Int64) async throws -> Bool {
        for _ in 0..<5 {
            try Task.checkCancellation()
            guard let state = try await stores.index.read({ try MailCloudFeedIndex.state(account: account, in: $0) }) else { return false }
            let ids = try await stores.index.read { try MailCloudFeedIndex.unseen(account: account, state: state, limit: 100, in: $0) }
            if ids.isEmpty {
                _ = try await writer.transactValue { db in
                    (try MailCloudFeedIndex.finishCatchUp(account: account, expected: state, in: db), MailStoreChange())
                }
                return false
            }
            try await source.check(account: account, ids: ids)
            _ = try await writer.transact { db in
                try MailCloudFeedIndex.checked(account: account, ids: ids, in: db)
                return MailStoreChange()
            }
        }
        return true
    }
}

#endif
