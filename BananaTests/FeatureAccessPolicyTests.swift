import XCTest

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
