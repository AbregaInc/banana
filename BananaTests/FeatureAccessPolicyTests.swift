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
            XCTAssertTrue(c.offers("email", context: "beta-session", now: now.addingTimeInterval(age)))
        }
        let gate = FeatureAccessGate()
        gate.update(c, context: "beta-session")
        XCTAssertFalse(gate.allows("email", now: now.addingTimeInterval(901)))
    }

    func testUnseenDeniedInvalidOrDifferentSessionPoliciesCannotOfferMail() {
        var denied = cache().policy
        denied.enabled = []
        let revoked = FeatureAccessCache(context: "beta-session", account: "account-1", policy: denied, receivedAt: now)
        XCTAssertFalse(revoked.offers("email", context: "beta-session", now: now))
        XCTAssertFalse(cache().offers("email", context: "another-session", now: now))
        XCTAssertFalse(cache().offers("email", context: nil, now: now))
        XCTAssertFalse(cache().offers("unknown-feature", context: "beta-session", now: now))
        for invalid in [cache(version: 2), cache(duration: -1), cache(duration: .infinity)] {
            XCTAssertFalse(invalid.offers("email", context: "beta-session", now: now))
        }
        var anonymous = cache()
        anonymous.account = ""
        XCTAssertFalse(anonymous.offers("email", context: "beta-session", now: now))
    }

    func testGraceExpiresAfter24HoursWithoutExtendingLiveAuthorization() {
        let c = cache()
        let deadline = now.addingTimeInterval(900 + FeatureAccessCache.visibilityGrace)
        XCTAssertTrue(c.offers("email", context: c.context, now: deadline.addingTimeInterval(-1)))
        XCTAssertFalse(c.offers("email", context: c.context, now: deadline))
        XCTAssertFalse(c.allows("email", context: c.context, now: deadline.addingTimeInterval(-1)))
    }

    func testDenialsDoNotSlideGraceAndRecoveryRenewsIt() throws {
        let positive = cache()
        var policy = positive.policy
        policy.enabled = []
        policy.issuedAt = 1
        let deniedAt = now.addingTimeInterval(100)
        let denied = FeatureAccessCache(context: positive.context, account: positive.account, policy: policy,
                                       receivedAt: deniedAt, previous: positive)
        let deadline = try XCTUnwrap(denied.visibilityDeadline("email", context: positive.context))
        XCTAssertEqual(deadline, deniedAt.addingTimeInterval(FeatureAccessCache.visibilityGrace))
        let later = deniedAt.addingTimeInterval(3_600)
        let repeated = FeatureAccessCache(context: positive.context, account: positive.account, policy: policy,
                                         receivedAt: later, previous: denied)
        XCTAssertEqual(repeated.visibilityDeadline("email", context: positive.context), deadline)
        XCTAssertFalse(repeated.allows("email", context: positive.context, now: later))
        XCTAssertFalse(repeated.offers("email", context: positive.context, now: deadline))
        let recovered = FeatureAccessCache(context: positive.context, account: positive.account, policy: positive.policy,
                                          receivedAt: later, previous: repeated)
        XCTAssertTrue(recovered.allows("email", context: positive.context, now: later))
        XCTAssertTrue(recovered.offers("email", context: positive.context, now: deadline))
        let another = FeatureAccessCache(context: "new-session", account: positive.account, policy: policy,
                                        receivedAt: later, previous: positive)
        XCTAssertFalse(another.offers("email", context: "new-session", now: later))
        let otherAccount = FeatureAccessCache(context: positive.context, account: "another-account", policy: policy,
                                             receivedAt: later, previous: positive)
        XCTAssertFalse(otherAccount.offers("email", context: positive.context, now: later))
    }

    func testOlderCachesMigrateWithoutInventingAnOffer() throws {
        let c = cache()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(c)) as? [String: Any])
        object.removeValue(forKey: "lastOffers")
        let migrated = try JSONDecoder().decode(FeatureAccessCache.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(migrated.offers("email", context: c.context, now: now.addingTimeInterval(901)))
        var denied = migrated
        denied.policy.enabled = []
        XCTAssertFalse(denied.offers("email", context: c.context, now: now))
    }

    @MainActor
    func testGracePersistsThroughDenialsRelaunchAndExpiryAndReportsTransitions() throws {
        let suite = "FeatureAccessPolicyTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let context = SHA256.hash(data: Data("https://beta.plan.example\nsession".utf8))
            .map { String(format: "%02x", $0) }.joined()
        var time = now
        var stored = cache()
        stored.context = context
        stored.receivedAt = time
        stored.lastOffers = nil // A cache from the previous app, before grace metadata.
        defaults.set(try JSONEncoder().encode(stored), forKey: "featureAccess.sessionPolicy.v1")
        let store = FeatureAccessStore(defaults: defaults, now: { time })
        var transitions: [String] = []
        store.reportTransition = { transitions.append($0) }
        store.bind(session: "session", host: "https://beta.plan.example")
        XCTAssertTrue(store.emailOffered)
        time = time.addingTimeInterval(901)
        store.bind(session: "session", host: "https://beta.plan.example")
        XCTAssertTrue(store.emailOffered)
        XCTAssertFalse(store.emailAvailable)
        XCTAssertNil(store.mailContext)
        XCTAssertFalse(FeatureAccessStore.network.allows("email", now: time))
        XCTAssertTrue(transitions.last?.contains("grace=true reason=expired") == true)

        var revoked = stored.policy
        revoked.issuedAt = 1
        revoked.enabled = []
        store.receive(account: stored.account, policy: revoked)
        XCTAssertTrue(store.emailOffered)
        XCTAssertFalse(store.emailAvailable)
        store.receive(account: stored.account, policy: stored.policy)
        XCTAssertFalse(store.emailAvailable, "An older grant cannot reverse a newer denial")
        store.receive(account: stored.account, policy: nil)
        XCTAssertTrue(store.emailOffered)
        XCTAssertFalse(store.emailAvailable)
        time = now.addingTimeInterval(3_600)
        store.receive(account: stored.account, policy: revoked)
        let relaunched = FeatureAccessStore(defaults: defaults, now: { time })
        relaunched.bind(session: "session", host: "https://beta.plan.example")
        XCTAssertTrue(relaunched.emailOffered)
        time = now.addingTimeInterval(900 + FeatureAccessCache.visibilityGrace)
        store.bind(session: "session", host: "https://beta.plan.example")
        relaunched.bind(session: "session", host: "https://beta.plan.example")
        XCTAssertFalse(store.emailOffered)
        XCTAssertFalse(relaunched.emailOffered)
        XCTAssertTrue(transitions.last?.contains("visible=false") == true)
        var restored = stored.policy
        restored.issuedAt = 2
        store.receive(account: stored.account, policy: restored)
        XCTAssertTrue(store.emailOffered)
        XCTAssertTrue(store.emailAvailable)
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
