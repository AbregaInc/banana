#if !BANANA_PUBLIC
import Foundation

/// Reasons to retain an entire conversation independently of its age (MAIL-ENGINE 5.4).
struct MailClaims: OptionSet, Sendable {
    let rawValue: Int
    static let starred = Self(rawValue: 1 << 0)
    static let draft = Self(rawValue: 1 << 1)
    static let bananaLabel = Self(rawValue: 1 << 2)
    static let unfinishedSend = Self(rawValue: 1 << 3)
    static let pendingChange = Self(rawValue: 1 << 4)
    static let question = Self(rawValue: 1 << 5)
    static let keptAfterRemoval = Self(rawValue: 1 << 6)
}

enum MailHoldReason: Equatable, Sendable {
    case recentMail, recentAttention, claim(MailClaims), everything
}

/// Pure retention policy. Releasing local cache never asserts deletion at Gmail.
/// Compute the shared edge once per pass, not once per conversation.
enum MailHoldRules {
    static func edge(for limit: MailSyncLimit, now: Date, calendar: Calendar) -> Date? {
        let months: Int
        switch limit {
        case .oneMonth: months = 1
        case .threeMonths: months = 3
        case .sixMonths: months = 6
        case .oneYear: months = 12
        case .everything: return nil
        }
        // Foundation handles month-end clamping and local calendar arithmetic.
        // If it cannot represent the edge, conservatively retain instead of releasing.
        guard let date = calendar.date(byAdding: .month, value: -months,
                                       to: calendar.startOfDay(for: now)) else { return nil }
        return calendar.startOfDay(for: date)
    }

    static func holds(newestMessage: Date, attendedAt: Date?, claims: MailClaims,
                      edge: Date?) -> MailHoldReason? {
        guard let edge else { return .everything }
        if newestMessage >= edge { return .recentMail }
        if let attendedAt, attendedAt >= edge { return .recentAttention }
        if !claims.isEmpty { return .claim(claims) }
        return nil
    }

    static func isClaim(labelID: String, bananaLabelIDs: Set<String>) -> Bool {
        labelID == "STARRED" || labelID == "DRAFT" || bananaLabelIDs.contains(labelID)
    }
}

#endif
