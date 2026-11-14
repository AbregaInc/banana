import XCTest

final class PermissionUpgradeUITest: MailUITestCase {
    private let fixtureID = UUID().uuidString
    private func fixture(_ outcome: String) -> [String] {
        ["--permission-upgrade-fixture", outcome, "--permission-upgrade-fixture-id", fixtureID]
    }

    func testUpgradeDeferralKeepsMailVisibleAndSurvivesRelaunch() {
        launch(extra: fixture("success"), waitForList: false)
        let prompt = app.descendants(matching: .any)["permission-upgrade.prompt"].firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 10))
        prompt.buttons["Not now"].tap()
        XCTAssertTrue(element(MailID.list).waitForExistence(timeout: 10))
        app.terminate()
        launch(extra: fixture("success"))
        XCTAssertFalse(app.descendants(matching: .any)["permission-upgrade.prompt"].firstMatch.exists)
    }

    func testConfirmedUpgradeClosesPromptAndLeavesMailAvailable() {
        launch(extra: fixture("success"), waitForList: false)
        let prompt = app.descendants(matching: .any)["permission-upgrade.prompt"].firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 10))
        prompt.buttons["Reconnect"].tap()
        XCTAssertTrue(waitUntil { !prompt.exists })
        XCTAssertTrue(element(MailID.list).waitForExistence(timeout: 10))
        XCTAssertFalse(prompt.exists)
    }

    func testFailedUpgradeOffersRetryWithoutRemovingMail() {
        launch(extra: fixture("fail"), waitForList: false)
        let prompt = app.descendants(matching: .any)["permission-upgrade.prompt"].firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 10))
        prompt.buttons["Reconnect"].tap()
        let failure = app.staticTexts["Access wasn’t updated"]
        XCTAssertTrue(failure.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Retry"].exists)
        app.buttons["Not now"].tap()
        XCTAssertTrue(element(MailID.list).waitForExistence(timeout: 10))
    }
}
