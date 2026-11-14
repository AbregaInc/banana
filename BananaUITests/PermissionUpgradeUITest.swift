import XCTest

final class PermissionUpgradeUITest: MailUITestCase {
    private let fixtureID = UUID().uuidString
    private func fixture(_ outcome: String) -> [String] {
        ["--permission-upgrade-fixture", outcome, "--permission-upgrade-fixture-id", fixtureID]
    }

    func testUpgradeDeferralKeepsMailVisibleAndSurvivesRelaunch() {
        launch(extra: fixture("success"), waitForList: false)
        let prompt = app.alerts["Update Google access?"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 10))
        prompt.buttons["Not now"].tap()
        XCTAssertTrue(element(MailID.list).waitForExistence(timeout: 10))
        app.terminate()
        launch(extra: fixture("success"))
        XCTAssertFalse(app.alerts["Update Google access?"].exists)
    }

    func testConfirmedUpgradeClosesPromptAndLeavesMailAvailable() {
        launch(extra: fixture("success"), waitForList: false)
        let prompt = app.alerts["Update Google access?"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 10))
        prompt.buttons["Reconnect"].tap()
        XCTAssertTrue(waitUntil { !prompt.exists })
        XCTAssertTrue(element(MailID.list).waitForExistence(timeout: 10))
        XCTAssertFalse(prompt.exists)
    }

    func testFailedUpgradeOffersRetryWithoutRemovingMail() {
        launch(extra: fixture("fail"), waitForList: false)
        let prompt = app.alerts["Update Google access?"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 10))
        prompt.buttons["Reconnect"].tap()
        let failure = app.alerts["Access wasn’t updated"]
        XCTAssertTrue(failure.waitForExistence(timeout: 10))
        XCTAssertTrue(failure.buttons["Retry"].exists)
        failure.buttons["Not now"].tap()
        XCTAssertTrue(element(MailID.list).waitForExistence(timeout: 10))
    }
}
