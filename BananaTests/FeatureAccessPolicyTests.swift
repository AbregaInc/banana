import XCTest
import CryptoKit

final class FeatureAccessPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1000)
    private func cache(version: Int = 1, duration: Double = 900_000) -> FeatureAccessCache {
        .init(context: "beta-session", account: "account-1", policy: .init(version: version, issuedAt: 0,
              expiresAt: duration, enabled: ["email"]), receivedAt: now)
    }
    func testEligibilityIsBoundToSessionAndServiceAndExpiresOffline() {
        let c = cache()
        XCTAssertTrue(c.allows("email", context: "beta-session", now: now))
        XCTAssertFalse(c.allows("email", context: "stable-session", now: now))
        XCTAssertFalse(c.allows("email", context: nil, now: now))
        XCTAssertFalse(c.allows("calendarCloud", context: "beta-session", now: now))
        XCTAssertFalse(c.allows("email", context: "beta-session", now: now.addingTimeInterval(900)))
        XCTAssertFalse(c.allows("email", context: "beta-session", now: now.addingTimeInterval(-1)))
    }
    func testExpiredPolicyKeepsModuleOfferedButCannotAuthorizeRequests() {
        let c = cache()
        for age in [900.0, 901.0, 86_400.0] {
            XCTAssertFalse(c.allows("email", context: "beta-session", now: now.addingTimeInterval(age)))
            XCTAssertTrue(c.offers("email", context: "beta-session"))
        }
        let gate = FeatureAccessGate()
        gate.update(c, context: "beta-session")
        XCTAssertFalse(gate.allows("email", now: now.addingTimeInterval(901)))
    }

    func testModuleOfferCannotSurviveRevocationSessionChangeOrInvalidPolicy() {
        var revoked = cache()
        revoked.policy.enabled = []
        XCTAssertFalse(revoked.offers("email", context: "beta-session"))
        XCTAssertFalse(cache().offers("email", context: "another-session"))
        XCTAssertFalse(cache().offers("email", context: nil))
        XCTAssertFalse(cache().offers("unknown-feature", context: "beta-session"))
        for invalid in [cache(version: 2), cache(duration: -1), cache(duration: .infinity)] {
            XCTAssertFalse(invalid.offers("email", context: "beta-session"))
        }
        var anonymous = cache()
        anonymous.account = ""
        XCTAssertFalse(anonymous.offers("email", context: "beta-session"))
    }

    @MainActor
    func testRestoringAnExpiredOfferKeepsNavigationUntilRevokedOrSessionChanges() throws {
        let suite = "FeatureAccessPolicyTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let context = SHA256.hash(data: Data("https://beta.plan.example\nsession".utf8))
            .map { String(format: "%02x", $0) }.joined()
        var stored = cache()
        stored.context = context
        stored.receivedAt = Date().addingTimeInterval(-901)
        defaults.set(try JSONEncoder().encode(stored), forKey: "featureAccess.sessionPolicy.v1")
        let store = FeatureAccessStore(defaults: defaults)
        store.bind(session: "session", host: "https://beta.plan.example")
        XCTAssertTrue(store.policyLoaded)
        XCTAssertTrue(store.emailOffered)
        XCTAssertFalse(store.emailAvailable)
        XCTAssertNil(store.mailContext)
        XCTAssertFalse(FeatureAccessStore.network.allows("email"))

        var revoked = stored.policy
        revoked.issuedAt = 1
        revoked.enabled = []
        store.receive(account: stored.account, policy: revoked)
        XCTAssertFalse(store.emailOffered)
        store.receive(account: stored.account, policy: stored.policy)
        XCTAssertFalse(store.emailOffered, "An older grant cannot restore a revoked module")
        var restored = stored.policy
        restored.issuedAt = 2
        store.receive(account: stored.account, policy: restored)
        XCTAssertTrue(store.emailOffered)
        store.bind(session: "another-session", host: "https://beta.plan.example")
        XCTAssertFalse(store.emailOffered)
        XCTAssertFalse(store.emailAvailable)
        XCTAssertFalse(store.policyLoaded)
    }

    func testFuturePoliciesAndInvalidLifetimeFailClosed() {
        for c in [cache(version: 2), cache(duration: -1), cache(duration: .infinity)] {
            XCTAssertFalse(c.allows("email", context: "beta-session", now: now))
        }
        XCTAssertEqual(cache(duration: 86_400_000).policy.lifetime, 900)
    }
    func testNetworkBoundaryRejectsOldSessionRevocationAndExpiry() {
        let gate = FeatureAccessGate()
        gate.update(cache(), context: "beta-session")
        XCTAssertTrue(gate.allows("email", now: now))
        XCTAssertFalse(gate.allows("email", now: now.addingTimeInterval(901)))
        gate.update(cache(), context: "another-session")
        XCTAssertFalse(gate.allows("email", now: now))
        gate.update(nil, context: "beta-session")
        XCTAssertFalse(gate.allows("email", now: now))
    }
    func testAnOlderRefreshCannotReplaceANewerRevocation() {
        var revoked = cache()
        revoked.policy.issuedAt = 100
        revoked.policy.enabled = []
        XCTAssertFalse(revoked.accepts(account: revoked.account, policy: cache().policy))
        var fresh = cache().policy
        fresh.issuedAt = 101
        XCTAssertTrue(revoked.accepts(account: revoked.account, policy: fresh))
    }

    func testOldAccountResponsesDecodeWithoutInventingAccess() throws {
        let old = Data(#"{"id":"account-1","google":[{"email":"noor@plan.example","status":"ok","watching":0,"access":true}],"devices":1}"#.utf8)
        let account = try JSONDecoder().decode(BananaService.Account.self, from: old)
        XCTAssertNil(account.featureAccess)
        XCTAssertNil(account.google[0].capabilities)
        var updated = account
        updated.featureAccess = cache().policy
        XCTAssertEqual(try JSONDecoder().decode(BananaService.Account.self, from: JSONEncoder().encode(updated)), updated)
    }
}
