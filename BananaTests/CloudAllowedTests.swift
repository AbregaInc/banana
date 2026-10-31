import XCTest

/// A process uses iCloud only when it is entitled to the container and wasn't told not to
/// (`AppCloud.mayUseCloud`). The once-a-minute sync poll didn't ask: an unsigned Mac build, which
/// has no entitlement, made a CloudKit container a second after launch and CloudKit ended the
/// process (the crash of 6 October 2026, in `CloudChangeCheck.changedZones`).
final class CloudAllowedTests: XCTestCase {
    func testEntitledAndNotSwitchedOffMayUseIt() {
        XCTAssertTrue(AppCloud.mayUseCloud(arguments: ["Banana"], entitled: true))
    }

    func testAnUnsignedBuildMayNot() {
        XCTAssertFalse(AppCloud.mayUseCloud(arguments: ["Banana"], entitled: false))
        XCTAssertFalse(AppCloud.mayUseCloud(arguments: ["Banana", "--ui-audit"], entitled: false))
    }

    func testThePreviewSwitchTurnsItOffEvenWhenEntitled() {
        XCTAssertFalse(AppCloud.mayUseCloud(arguments: ["Banana", "--disable-icloud"], entitled: true))
    }

    // MARK: - What the build's config gave it

    func testABuildWithNoTeamOrNoContainerHasNoCloudOfItsOwn() {
        XCTAssertTrue(AppCloud.isSetUp(container: "iCloud.org.example.banana", team: "ABCDE12345"))
        XCTAssertFalse(AppCloud.isSetUp(container: "iCloud.org.example.banana", team: nil), "nobody signed for it")
        XCTAssertFalse(AppCloud.isSetUp(container: "iCloud.org.example.banana", team: ""))
        XCTAssertFalse(AppCloud.isSetUp(container: "", team: "ABCDE12345"))
    }

    func testASettingLeftEmptyReadsAsNone() {
        let info: [String: Any] = ["BananaCloudContainer": "iCloud.org.example.banana", "BananaLegacyCloudContainer": "",
                                   "BananaTeamID": "  "]
        XCTAssertEqual(BuildConfig.value("BananaCloudContainer", in: info), "iCloud.org.example.banana")
        XCTAssertNil(BuildConfig.value("BananaLegacyCloudContainer", in: info))
        XCTAssertNil(BuildConfig.value("BananaTeamID", in: info))
        XCTAssertNil(BuildConfig.value("Missing", in: info))
    }

    func testWithNoGoogleClientThereIsNoSignIn() {
        XCTAssertNil(BuildConfig.googleClientID(in: ["GIDClientID": ".apps.googleusercontent.com"]))
        XCTAssertNil(BuildConfig.googleClientID(in: [:]))
        XCTAssertEqual(BuildConfig.googleClientID(in: ["GIDClientID": "123-abc.apps.googleusercontent.com"]),
                       "123-abc.apps.googleusercontent.com")
    }

    func testTheWidgetsShareAKeychainGroupOnlyWhenATeamSigned() {
        XCTAssertEqual(WidgetAgenda.accessGroup(team: "ABCDE12345")[kSecAttrAccessGroup as String] as? String,
                       "ABCDE12345.com.boris.banana.widget.agenda")
        XCTAssertTrue(WidgetAgenda.accessGroup(team: nil).isEmpty)
        XCTAssertTrue(WidgetAgenda.accessGroup(team: "").isEmpty)
    }
}
