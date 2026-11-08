#if !BANANA_PUBLIC
import Foundation

/// Membership is prepared in the writer transaction, never joined with pending intent in a list read.
enum ViewMembershipRules {
    /// Year 10000 in ms: no `Snoozed/<yyyy…>` label can name a time after it.
    static let snoozedKeyCeiling: Int64 = 253_402_300_800_000
    static func memberships(_ messages: [MessageFacts], account: String,
                            splits: [MailSplit], matches: (MailSplit, [MessageFacts]) -> Bool,
                            myAddresses: Set<String>) -> [ViewMembership] {
        let confirmed = messages.filter { $0.vis != 3 }
        let visible = confirmed.filter {
            ($0.vis == 0 || $0.vis == 4) &&
                !$0.labels.contains("TRASH") && !$0.labels.contains("SPAM")
        }
        let display = visible.isEmpty ? confirmed : visible
        let unread = display.contains { $0.labels.contains("UNREAD") }
        var result: [ViewMembership] = []
        let banana = BananaLabelRules.state(messages)
        func append(_ view: MailViewKey, _ subset: [MessageFacts], backAt: Int64? = nil) {
            guard !subset.isEmpty else { return }
            let fetched = subset.filter { $0.fetchState > 0 }
            // A source without local row IDs uses -1 for unknown ordering. Stubs never
            // enter dated page queries; the stable conversation tie disambiguates them.
            var key = fetched.map(\.internalDate).max() ?? -max(1, subset.map(\.rowID).max() ?? 0)
            // Back from snooze: at the top of the place it left, as of the time it was due (8.3).
            if let backAt, !fetched.isEmpty { key = max(key, backAt) }
            result.append(ViewMembership(view: view, sortKey: key, unread: unread))
        }
        let backAt = banana.isBack ? banana.returnedAt : nil
        let labels = Set(visible.flatMap(\.labels)).union(
            confirmed.flatMap { $0.labels.intersection(["TRASH", "SPAM"]) })
        for label in labels.sorted() {
            let source = label == "TRASH" || label == "SPAM" ? confirmed : visible
            let carrying = source.filter { $0.labels.contains(label) }
            let back = label == "INBOX" ? backAt : nil
            append(.label(account: account, labelID: label), carrying, backAt: back)
            if let system = SystemLabel(rawValue: label) { append(.unified(system), carrying, backAt: back) }
        }
        append(.allMail(account: account), visible)
        append(.allMail(account: nil), visible)
        let inbox = visible.filter { $0.labels.contains("INBOX") }
        if inbox.isEmpty {
            append(.done(account: account), visible)
            append(.done(account: nil), visible)
        } else if let split = MailBuiltInSplits.matching(visible, splits: splits, matches: matches) {
            append(.split(id: split), inbox, backAt: backAt)
        }
        // Snoozed: soonest back first. Lists read the largest key first and only keys above zero, so
        // the key is the time reversed against a day after any time a label can name.
        if banana.isSnoozed, let wake = banana.wakeAt, !visible.isEmpty {
            result.append(ViewMembership(view: .snoozed, sortKey: snoozedKeyCeiling - wake, unread: unread))
        }
        if visible.contains(where: { $0.bananaLabels.contains("Banana/Muted") }) {
            append(.muted, visible)
        }
        return result
    }
}

#endif
