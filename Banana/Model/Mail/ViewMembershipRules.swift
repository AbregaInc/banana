#if !BANANA_PUBLIC
import Foundation

/// Membership is prepared in the writer transaction, never joined with pending intent in a list read.
enum ViewMembershipRules {
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
        func append(_ view: MailViewKey, _ subset: [MessageFacts]) {
            guard !subset.isEmpty else { return }
            let fetched = subset.filter { $0.fetchState > 0 }
            // A source without local row IDs uses -1 for unknown ordering. Stubs never
            // enter dated page queries; the stable conversation tie disambiguates them.
            let key = fetched.map(\.internalDate).max() ?? -max(1, subset.map(\.rowID).max() ?? 0)
            result.append(ViewMembership(view: view, sortKey: key, unread: unread))
        }
        let labels = Set(visible.flatMap(\.labels)).union(
            confirmed.flatMap { $0.labels.intersection(["TRASH", "SPAM"]) })
        for label in labels.sorted() {
            let source = label == "TRASH" || label == "SPAM" ? confirmed : visible
            let carrying = source.filter { $0.labels.contains(label) }
            append(.label(account: account, labelID: label), carrying)
            if let system = SystemLabel(rawValue: label) { append(.unified(system), carrying) }
        }
        append(.allMail(account: account), visible)
        append(.allMail(account: nil), visible)
        let inbox = visible.filter { $0.labels.contains("INBOX") }
        if inbox.isEmpty {
            append(.done(account: account), visible)
            append(.done(account: nil), visible)
        } else if let split = MailBuiltInSplits.matching(visible, splits: splits, matches: matches) {
            append(.split(id: split), inbox)
        }
        if visible.contains(where: { $0.bananaLabels.contains("Banana/Muted") }) {
            append(.muted, visible)
        }
        // Timed memberships wait for BananaLabelRules/P19a, as specified by P05.
        return result
    }
}

#endif
