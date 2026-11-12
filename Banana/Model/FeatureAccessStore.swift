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

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    private var context: String?
    private var cached: FeatureAccessCache?
    private var expiry: Task<Void, Never>?

    func bind(session: String?, host: String?) {
        let next = session.flatMap { session in host.map { host in
            SHA256.hash(data: Data((host + "\n" + session).utf8)).map { String(format: "%02x", $0) }.joined()
        } }
        guard next != context else { return }
        context = next
        cached = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(FeatureAccessCache.self, from: $0) }
        if cached?.context != next { cached = nil; defaults.removeObject(forKey: key) }
        publish()
    }

    func receive(account: String, policy: FeatureAccessPolicy?) {
        if let context, let policy {
            guard cached?.accepts(account: account, policy: policy) != false else { return }
            cached = FeatureAccessCache(context: context, account: account, policy: policy, receivedAt: Date())
            if let data = try? JSONEncoder().encode(cached) { defaults.set(data, forKey: key) }
        } else { cached = nil; defaults.removeObject(forKey: key) }
        publish()
    }

    func allows(_ feature: String) -> Bool {
        cached?.allows(feature, context: context, now: Date()) == true
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
        let offered = cached?.offers("email", context: context) == true
        if emailOffered != offered { emailOffered = offered }
        let available = allows("email")
        if emailAvailable != available { emailAvailable = available }
        let loaded = cached != nil
        if policyLoaded != loaded { policyLoaded = loaded }
        guard let cached else { return }
        let remaining = cached.policy.lifetime - Date().timeIntervalSince(cached.receivedAt)
        guard remaining > 0, remaining <= 15 * 60 else { return }
        expiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            self?.publish()
        }
    }
}
