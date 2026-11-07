#if !BANANA_PUBLIC
import Foundation

/// One search list from two answers (MAIL-ENGINE 9.4): what the device's own index matched, and
/// what Gmail matched that it did not. Pure, so every rule is a test that hands it rows.
///
/// - **One list, newest first.** A conversation counts once; the device's row wins, and a row
///   only Gmail found is marked `fromGmailSearch`.
/// - **Nothing is promised below what is known.** While the device has more matches below its
///   last row, or Gmail may still add conversations below the oldest it has added, the rows
///   past that point wait: a row shown there now could have others belong above it later.
/// - **Nothing already shown goes away for that.** Rows at or above `frontier` — the oldest row
///   this search has delivered — are kept whatever waits. What joins above them is the list's
///   to place (MailListModel's rest rules keep rows still under a hand).
enum MailSearchMerge {
    struct Result: Equatable {
        var rows: [MailRow]
        var hasMore: Bool
        /// Rows in `rows` that only Gmail found.
        var added: Int
    }

    static func merge(local: [MailRow], localMore: Bool, remote: [MailRow], gmailMore: Bool,
                      frontier: MailOrderKey?, limit: Int) -> Result {
        var seen = Set<MailConversationID>()
        var all: [MailRow] = []
        all.reserveCapacity(local.count + remote.count)
        for row in local where seen.insert(row.id).inserted { all.append(row) }
        var oldestRemote: MailOrderKey?
        for var row in remote where seen.insert(row.id).inserted {
            row.fromGmailSearch = true
            oldestRemote = oldestRemote.map { min($0, row.key) } ?? row.key
            all.append(row)
        }
        all.sort { $0.key > $1.key }
        var bound: MailOrderKey?
        if localMore, let last = local.last { bound = last.key }
        if gmailMore, let oldestRemote { bound = bound.map { max($0, oldestRemote) } ?? oldestRemote }
        var held = false
        if let bound {
            let keepFrom = frontier.map { min($0, bound) } ?? bound
            let before = all.count
            all.removeAll { $0.key < keepFrom }
            held = all.count < before
        }
        let rows = Array(all.prefix(limit))
        return Result(rows: rows, hasMore: held || all.count > limit || localMore || gmailMore,
                      added: rows.reduce(0) { $0 + ($1.fromGmailSearch ? 1 : 0) })
    }
}

#endif
