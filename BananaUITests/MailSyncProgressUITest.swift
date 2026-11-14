import XCTest

final class MailSyncProgressUITest: MailUITestCase {
    private func launchProgress(_ mode: String, largeText: Bool = false) {
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--ui-audit", "--disable-icloud", "--dummy-health",
            "-finishSetupDismissed", "YES", "-onboardingCompleted", "YES", "--modules", "everything",
            "--mail-fixtures", "--mail-fresh", "--tab", "mail", "--mail-sync-progress-fixture", mode]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.withoutSpaceSync()
        app.launch()
        XCTAssertTrue(app.waitForShell(timeout: 30), app.debugDescription)
        app.openPage("mail")
    }

    func testKnownProgressIsBesideTheCount() {
        launchProgress("known")
        let progress = app.descendants(matching: .any)["mail.sync.progress"].firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(progress.value as? String, "25 loaded, 75 queued")
        let count = app.staticTexts["mail.list.count"].firstMatch
        XCTAssertTrue(count.exists)
        XCTAssertGreaterThanOrEqual(progress.frame.minX, count.frame.maxX)
        XCTAssertLessThanOrEqual(abs(progress.frame.midY - count.frame.midY), 2)
        snap("mail-header-known-progress")
    }
    func testUnknownTotalShowsCompletedWorkWithoutInventingAPercentage() {
        launchProgress("unknown")
        let progress = app.descendants(matching: .any)["mail.sync.progress"].firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 10))
        XCTAssertEqual(progress.value as? String, "25 loaded; total still being discovered")
        XCTAssertFalse(app.progressIndicators["mail.sync.fraction"].exists)
        snap("mail-header-unknown-progress")
    }
    func testLargeTextKeepsProgressAndComposeReachable() {
        launchProgress("known", largeText: true)
        let progress = app.descendants(matching: .any)["mail.sync.progress"].firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 10), app.debugDescription)
        let action = app.buttons[isPad ? "mail.more" : MailID.compose].firstMatch
        XCTAssertTrue(action.exists, app.debugDescription)
        XCTAssertTrue(action.isHittable)
        XCTAssertGreaterThanOrEqual(action.frame.width, 44)
        XCTAssertGreaterThanOrEqual(action.frame.height, 44)
        XCTAssertGreaterThan(progress.frame.width, 24)
        XCTAssertGreaterThanOrEqual(progress.frame.minX, 0)
        XCTAssertLessThanOrEqual(progress.frame.maxX, action.frame.minX)
        snap("mail-header-large-text-progress")
        if isPad {
            action.tap()
            XCTAssertTrue(app.buttons["New message"].firstMatch.waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["New message"].firstMatch.isHittable)
        }
    }
    func testPausedWorkSaysPausedAndFinishedWorkDisappears() {
        launchProgress("paused")
        let progress = app.descendants(matching: .any)["mail.sync.progress"].firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 10))
        XCTAssertEqual(progress.value as? String, "Paused; 25 loaded, 75 queued")
        app.terminate()
        launchProgress("done")
        XCTAssertTrue(waitUntil { !self.app.descendants(matching: .any)["mail.sync.progress"].firstMatch.exists }, app.debugDescription)
    }
}
