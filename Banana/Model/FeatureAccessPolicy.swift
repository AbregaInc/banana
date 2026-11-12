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

    /// Navigation remembers an offered module through a failed refresh. This is not a live
    /// access grant: requests and new consent still use `allows`, including its expiry.
    /// A new policy that removes the feature, or a different session, withdraws the offer.
    func offers(_ feature: String, context expected: String?) -> Bool {
        guard let expected, context == expected, !account.isEmpty,
              ["email", "calendarCloud"].contains(feature), policy.lifetime > 0 else { return false }
        return policy.enabled.contains(feature)
    }

    func allows(_ feature: String, context expected: String?, now: Date) -> Bool {
        guard offers(feature, context: expected) else { return false }
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
