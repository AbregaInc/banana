import XCTest

/// Stable and Beta sit side by side on every device, and Beta changes nothing Stable can see
/// unless it was marked as Beta's (`AppVariant`; the author, 10 Oct 2026: "no intermingling of any
/// data").
final class AppVariantTests: XCTestCase {
    func testTheTwoNeverShareANameOutsideTheirOwnStorage() {
        XCTAssertNotEqual(AppVariant.beta.peerServiceType, AppVariant.production.peerServiceType)
        XCTAssertNotEqual(AppVariant.beta.googleKeychainService, AppVariant.production.googleKeychainService)
        XCTAssertNotEqual(CalendarWriteBackVariant.beta.markerScheme, CalendarWriteBackVariant.production.markerScheme)
    }

    func testStableKeepsTheNamesItHasAlwaysUsed() {
        // Changing either would sign Stable out or hide its other devices from it.
        XCTAssertEqual(AppVariant.production.peerServiceType, "banana-audio")
        XCTAssertEqual(AppVariant.production.googleKeychainService, "com.boris.banana.google-accounts")
    }

    func testTheMacCarriesSettingsOverFromTheIdItUsedBefore() {
        // The Mac apps took the iPhone's bundle ids: Stable in July 2026, Beta on 18 Oct 2026.
        XCTAssertEqual(AppVariant.legacyMacBundleID("com.boris.banana"), "com.boris.banana.mac")
        XCTAssertEqual(AppVariant.legacyMacBundleID("com.boris.banana.beta"), "com.boris.banana.mac.beta")
        XCTAssertNil(AppVariant.legacyMacBundleID(nil))
        XCTAssertNil(AppVariant.legacyMacBundleID(""))
    }

    func testAPeerServiceNameIsOneMultipeerAccepts() {
        for variant in [AppVariant.production, .beta] {
            let name = variant.peerServiceType
            XCTAssertTrue((1...15).contains(name.count), name)
            XCTAssertTrue(name.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" }, name)
        }
    }

    func testBetaChangesRemindersOnlyInItsOwnList() {
        XCTAssertTrue(AppVariant.beta.mayChangeReminder(inListTitled: "Banana Beta"))
        XCTAssertFalse(AppVariant.beta.mayChangeReminder(inListTitled: "Reminders"))
        XCTAssertFalse(AppVariant.beta.mayChangeReminder(inListTitled: nil))
        XCTAssertTrue(AppVariant.production.mayChangeReminder(inListTitled: "Reminders"))
        XCTAssertTrue(AppVariant.production.mayChangeReminder(inListTitled: nil))
    }

    func testBetaSavesNothingToHealth() {
        XCTAssertFalse(AppVariant.beta.mayWriteHealth)
        XCTAssertTrue(AppVariant.production.mayWriteHealth)
    }

    func testBetaReadsAnyGoogleAccountAndChangesOnlyTestAccounts() {
        let tests: Set<String> = ["sam@test.example"]
        XCTAssertTrue(AppVariant.beta.mayCallGoogle(method: "GET", account: "sam@work.example", testAccounts: tests))
        XCTAssertTrue(AppVariant.beta.mayCallGoogle(method: "GET", account: nil, testAccounts: tests))
        for method in ["POST", "PATCH", "PUT", "DELETE", "patch"] {
            XCTAssertFalse(AppVariant.beta.mayCallGoogle(method: method, account: "sam@work.example", testAccounts: tests), method)
            XCTAssertTrue(AppVariant.beta.mayCallGoogle(method: method, account: "Sam@Test.example", testAccounts: tests), method)
            // An account that can't be told is not a test account.
            XCTAssertFalse(AppVariant.beta.mayCallGoogle(method: method, account: nil, testAccounts: tests), method)
            XCTAssertTrue(AppVariant.production.mayCallGoogle(method: method, account: "sam@work.example", testAccounts: []), method)
        }
    }

    func testThisBuildIsStable() {
        // The tests run in the Stable app. A Beta flag leaking into it would turn its writes off.
        XCTAssertEqual(AppVariant.current, .production)
    }

    // MARK: - What each app is built with

    func testBetaIsBuiltWithNothingOfStables() throws {
        let project = try Self.text("project.yml")
        for name in ["BananaBeta", "BananaMacBeta"] {
            let target = try XCTUnwrap(Self.target(name, in: project), name)
            XCTAssertTrue(target.contains("BANANA_BETA"), name)
            XCTAssertTrue(target.contains("[$(BANANA_ICLOUD_CONTAINER_BETA)]"), name)
            XCTAssertFalse(target.contains("$(BANANA_ICLOUD_CONTAINER)"), "\(name) is entitled to Stable's iCloud")
            XCTAssertFalse(target.contains("_banana-audio._tcp"), "\(name) announces Stable's network service")
            XCTAssertTrue(target.contains("_banana-beta._tcp"), name)
            XCTAssertFalse(target.contains("$(BANANA_GOOGLE_CLIENT)"), "\(name) signs in with Stable's Google client")
        }
        for name in ["Banana", "BananaMac"] {
            let target = try XCTUnwrap(Self.target(name, in: project), name)
            XCTAssertFalse(target.contains("BANANA_BETA"), name)
            XCTAssertFalse(target.contains("banana.beta"), "\(name) names something of Beta's")
            XCTAssertTrue(target.contains("_banana-audio._tcp"), name)
        }
    }

    func testThePlistsOnDiskMatch() throws {
        for path in ["Banana/InfoBeta.plist", "BananaMac/InfoBeta.plist"] {
            let plist = try Self.text(path)
            XCTAssertTrue(plist.contains("_banana-beta._tcp"), path)
            XCTAssertFalse(plist.contains("_banana-audio._tcp"), path)
        }
        for path in ["Banana/BananaBeta.entitlements", "BananaMac/BananaMacBeta.entitlements"] {
            XCTAssertFalse(try Self.text(path).contains("<string>$(BANANA_ICLOUD_CONTAINER)</string>"), path)
        }
    }

    private static func text(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// One target's block under the second `targets:`-level heading of that name: from its
    /// two-space heading to the next one.
    private static func target(_ name: String, in project: String) -> String? {
        let lines = project.components(separatedBy: "\n")
        guard let start = lines.lastIndex(of: "  \(name):") else { return nil }
        let rest = lines[(start + 1)...]
        let end = rest.firstIndex { $0.hasPrefix("  ") && !$0.hasPrefix("   ") && !$0.hasPrefix("  #") && $0.hasSuffix(":") } ?? lines.endIndex
        // Comments name the other app freely; only what is built counts.
        return lines[start..<end].filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")
    }
}
