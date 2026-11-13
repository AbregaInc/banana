import Combine
import CryptoKit
import Foundation

@MainActor
final class FeatureAccessStore: ObservableObject {
    static let shared = FeatureAccessStore()
    nonisolated static let network = FeatureAccessGate()
    @Published private(set) var emailAvailable = false
    /// A module already offered to this session remains navigable during a failed refresh.
    @Published private(set) var emailOffered = false
    /// A policy for this session has arrived, so `emailAvailable` is an answer, not a default.
    @Published private(set) var policyLoaded = false
    private let key = "featureAccess.sessionPolicy.v1"
    private let defaults: UserDefaults
    private let now: () -> Date
    /// Content-free transitions are included in the app journal, so a report can explain hiding.
    var reportTransition: ((String) -> Void)?
    private var lastTransition: String?

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults; self.now = now
    }
    private var context: String?
    private var cached: FeatureAccessCache?
    private var expiry: Task<Void, Never>?

    func bind(session: String?, host: String?) {
        let next = session.flatMap { session in host.map { host in
            SHA256.hash(data: Data((host + "\n" + session).utf8)).map { String(format: "%02x", $0) }.joined()
        } }
        guard next != context else { publish(); return }
        context = next
        cached = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(FeatureAccessCache.self, from: $0) }
        reportTransition?("binding signedIn=\(next != nil) cachedPolicy=\(cached != nil) cacheMatches=\(cached?.context == next)")
        if cached?.context != next { cached = nil; defaults.removeObject(forKey: key) }
        publish()
    }

    func receive(account: String, policy: FeatureAccessPolicy?) {
        if let context {
            if let policy, cached?.accepts(account: account, policy: policy) == false { return }
            // Missing policy denies live requests, retaining only the bounded presentation grace.
            let floor = cached?.policy.issuedAt ?? 0
            let policy = policy ?? FeatureAccessPolicy(version: 0, issuedAt: floor, expiresAt: floor, enabled: [])
            cached = FeatureAccessCache(context: context, account: account, policy: policy,
                                        receivedAt: now(), previous: cached)
            if let data = try? JSONEncoder().encode(cached) { defaults.set(data, forKey: key) }
        } else { cached = nil; defaults.removeObject(forKey: key) }
        publish()
    }

    func allows(_ feature: String) -> Bool {
        cached?.allows(feature, context: context, now: now()) == true
    }

    /// Opaque session/account binding for reads that may span several provider pages.
    var calendarReadContext: String? { featureContext("calendarCloud") }
    var mailContext: String? { featureContext("email") }
    private func featureContext(_ feature: String) -> String? {
        guard allows(feature), let cached else { return nil }
        return cached.context + ":" + cached.account
    }

    private func publish() {
        Self.network.update(cached, context: context)
        expiry?.cancel()
        let time = now()
        let offered = cached?.offers("email", context: context, now: time) == true
        if emailOffered != offered { emailOffered = offered }
        let available = allows("email")
        if emailAvailable != available { emailAvailable = available }
        let loaded = cached != nil
        if policyLoaded != loaded { policyLoaded = loaded }
        let reason = cached == nil ? "no-policy" : cached?.policy.lifetime == 0 ? "invalid-policy"
            : cached?.policy.enabled.contains("email") == false ? "not-enabled" : available ? "fresh" : "expired"
        let transition = "email live=\(available) visible=\(offered) grace=\(offered && !available) reason=\(reason)"
        if transition != lastTransition {
            lastTransition = transition
            reportTransition?(transition)
        }
        guard let cached else { return }
        // Wake at both authorization expiry and presentation expiry. No polling or extension
        // on failed refreshes; foreground entry also reevaluates the persisted deadline.
        let deadlines = [cached.receivedAt.addingTimeInterval(cached.policy.lifetime),
                         cached.visibilityDeadline("email", context: context)].compactMap { $0 }
        guard let remaining = deadlines.map({ $0.timeIntervalSince(time) }).filter({ $0 > 0 }).min(),
              remaining.isFinite else { return }
        expiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            self?.publish()
        }
    }
}
