import Foundation

/// Service-issued eligibility; independent of module preferences and Google consent.
struct FeatureAccessPolicy: Codable, Equatable, Sendable {
    var version: Int
    var issuedAt: Double
    var expiresAt: Double
    var enabled: [String]

    var lifetime: TimeInterval {
        guard version == 1, issuedAt.isFinite, expiresAt.isFinite else { return 0 }
        return max(0, min(15 * 60, (expiresAt - issuedAt) / 1000))
    }
}

/// Bound to both service and authenticated session. A different login cannot inherit
/// cached eligibility. The receive time avoids assuming the device clock matches the server.
struct FeatureAccessCache: Codable, Equatable {
    var context: String
    var account: String
    var policy: FeatureAccessPolicy
    var receivedAt: Date

    func accepts(account nextAccount: String, policy nextPolicy: FeatureAccessPolicy) -> Bool {
        // Concurrent foreground/background refreshes may finish in reverse order.
        account != nextAccount || !policy.issuedAt.isFinite || nextPolicy.issuedAt >= policy.issuedAt
    }

    /// Local expiry of each last positive offer. Optional for caches written before grace.
    /// This never participates in live authorization.
    var lastOffers: [String: Date]? = nil
    static let visibilityGrace: TimeInterval = 24 * 60 * 60

    init(context: String, account: String, policy: FeatureAccessPolicy, receivedAt: Date,
         previous: FeatureAccessCache? = nil) {
        self.context = context; self.account = account; self.policy = policy; self.receivedAt = receivedAt
        var offers: [String: Date] = [:]
        let previous = previous.flatMap { $0.context == context && $0.account == account ? $0 : nil }
        for feature in ["email", "calendarCloud"] {
            if policy.lifetime > 0, policy.enabled.contains(feature) {
                offers[feature] = receivedAt.addingTimeInterval(policy.lifetime)
            } else if let end = previous?.lastOfferEnd(feature) {
                // A denial starts grace at once; repeated denials cannot slide its deadline.
                offers[feature] = min(end, receivedAt)
            }
        }
        lastOffers = offers.isEmpty ? nil : offers
    }

    private func matches(_ feature: String, context expected: String?) -> Bool {
        expected != nil && context == expected && !account.isEmpty && ["email", "calendarCloud"].contains(feature)
    }

    private func lastOfferEnd(_ feature: String) -> Date? {
        if let end = lastOffers?[feature], end.timeIntervalSince1970.isFinite { return end }
        // Migrate an older positive cache without inventing offers for an older denial.
        guard policy.lifetime > 0, policy.enabled.contains(feature) else { return nil }
        return receivedAt.addingTimeInterval(policy.lifetime)
    }

    func visibilityDeadline(_ feature: String, context expected: String?) -> Date? {
        guard matches(feature, context: expected), let end = lastOfferEnd(feature) else { return nil }
        return end.addingTimeInterval(Self.visibilityGrace)
    }

    func offers(_ feature: String, context expected: String?, now: Date) -> Bool {
        guard now.timeIntervalSince(receivedAt) >= 0, let deadline = visibilityDeadline(feature, context: expected) else { return false }
        return now.timeIntervalSince(deadline) < 0
    }

    func allows(_ feature: String, context expected: String?, now: Date) -> Bool {
        guard matches(feature, context: expected), policy.enabled.contains(feature) else { return false }
        let age = now.timeIntervalSince(receivedAt)
        return age >= 0 && age < policy.lifetime
    }

}

struct GoogleAccountCapabilities: Codable, Equatable, Hashable {
    var calendarRead: Bool
    var calendarWrite: Bool
    var calendarList: Bool
    var mailRead: Bool
    var mailModify: Bool
    var mailSend: Bool
}

/// Synchronous transport boundary: URLSession callers need no actor hop to reject
/// a revoked/expired grant. No UI, network or persistence runs while holding this lock.
final class FeatureAccessGate: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: FeatureAccessCache?
    private var context: String?
    func update(_ cached: FeatureAccessCache?, context: String?) {
        lock.lock(); defer { lock.unlock() }
        self.cached = cached; self.context = context
    }
    func allows(_ feature: String, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cached?.allows(feature, context: context, now: now) == true
    }
}
