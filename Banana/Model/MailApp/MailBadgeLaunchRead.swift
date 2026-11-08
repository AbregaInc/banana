#if !BANANA_PUBLIC
import Foundation

/// The shell's Mail badge at launch, before Mail has started: the launch mirror at once (12.4,
/// two integers in the defaults), then one read-only count of the unified Inbox's unread on a
/// background queue. No network, no sync, no delivery, no migration: the account list is the
/// cached one, and the index is opened read only (`MailStores.openIndexForCounting`) and let go.
enum MailBadgeLaunchRead {
    /// What the engine last wrote, for the first frame.
    @MainActor static func mirrored() -> Int? {
        MailBadgeCounts.mirrored(in: .standard)?.unreadInFirstSplit
    }

    /// The unified Inbox's unread conversations, read off the main thread; nil when there is
    /// nothing to read (no account, no store yet, a store older than the code).
    @MainActor static func read() async -> Int? {
        let accounts = Set(MailCloudAccess().connectedAccountIDs)
        guard !accounts.isEmpty else { return nil }
        let index = MailDirectories.indexDatabase(under: AppSupport.directory.appendingPathComponent("BananaMail", isDirectory: true))
        return try? await Task.detached(priority: .utility) {
            let queue = try MailStores.openIndexForCounting(at: index)
            let request = PageRequest(view: .unified(.inbox), account: nil, filters: [], before: nil, limit: 1,
                                      allowedAccounts: accounts)
            let counts = try queue.read { try MailIndexReader.counts(request, in: $0) }
            return MailInboxCount.place(unread: counts.unread, total: counts.total).unread.value
        }.value
    }
}

#endif
