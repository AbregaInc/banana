#if !BANANA_PUBLIC
import Foundation

/// Matching order differs from display order: custom splits, Calendar, Important, Other.
/// A custom query has no match until the query engine supplies one (MAIL-ENGINE 9.3).
enum MailBuiltInSplits {
    static func matching(_ messages: [MessageFacts], splits: [MailSplit],
                         matches: (MailSplit, [MessageFacts]) -> Bool = { _, _ in false }) -> String? {
        let visible = messages.filter {
            ($0.vis == 0 || $0.vis == 4) &&
                !$0.labels.contains("TRASH") && !$0.labels.contains("SPAM")
        }
        guard visible.contains(where: { $0.labels.contains("INBOX") }) else { return nil }
        let builtIns: Set<String> = [MailSplit.calendarID, MailSplit.importantID, MailSplit.otherID]
        for split in splits where !builtIns.contains(split.id) {
            if matches(split, visible) { return split.id }
        }
        if visible.contains(where: \.hasInvite) { return MailSplit.calendarID }
        if visible.contains(where: { $0.labels.contains("IMPORTANT") }) { return MailSplit.importantID }
        return MailSplit.otherID
    }
}

#endif
