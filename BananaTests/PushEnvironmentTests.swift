import XCTest

final class PushEnvironmentTests: XCTestCase {
    func testDirectMacProfileDoesNotRouteProductionTokenToSandbox() {
        XCTAssertEqual(PushEnvironment.resolve(signedEntitlement: "production",
                                               isDevelopmentInstall: true), "production")
    }

    func testDevelopmentSignatureWinsOverInstallClassification() {
        XCTAssertEqual(PushEnvironment.resolve(signedEntitlement: "development",
                                               isDevelopmentInstall: false), "development")
    }

    func testMissingOrInvalidEntitlementPreservesInstalledIOSRouting() {
        for entitlement: String? in [nil, "", "unknown"] {
            XCTAssertEqual(PushEnvironment.resolve(signedEntitlement: entitlement,
                                                   isDevelopmentInstall: true), "development")
            XCTAssertEqual(PushEnvironment.resolve(signedEntitlement: entitlement,
                                                   isDevelopmentInstall: false), "production")
        }
    }
}
