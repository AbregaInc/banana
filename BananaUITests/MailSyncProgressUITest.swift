import XCTest

final class MailSyncProgressUITest: MailUITestCase {
    private func launchProgress(_ mode: String, largeText: Bool = false, paging: String? = nil) {
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--ui-audit", "--disable-icloud", "--dummy-health",
            "-finishSetupDismissed", "YES", "-onboardingCompleted", "YES", "--modules", "everything",
            "--mail-fixtures", "--mail-fresh", "--tab", "mail", "--mail-sync-progress-fixture", mode]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        if let paging { app.launchArguments += ["--mail-paging-fixture", paging] }
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

    private func reachFooter() {
        let list = app.collectionViews[MailID.list].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        for _ in 0..<12 { list.swipeUp() }
    }

    func testIdleFooterDoesNotSpinWhileTheHeaderShowsSyncProgress() {
        launchProgress("known", paging: "idle")
        reachFooter()
        let header = app.descendants(matching: .any)[MailID.syncProgress].firstMatch
        XCTAssertTrue(header.exists)
        XCTAssertEqual(header.value as? String, "25 loaded, 75 queued")
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Loading more mail")).firstMatch.exists,
                       "More mail being available must not leave a permanent footer spinner")
        snap("mail-footer-idle-header-working")
    }

    func testFooterStillShowsAnActualPendingPageRequest() {
        launchProgress("known", paging: "pending")
        reachFooter()
        let spinner = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Loading more mail")).firstMatch
        XCTAssertTrue(spinner.waitForExistence(timeout: 10), app.debugDescription)
        let bar = app.otherElements["shell.bar"].firstMatch
        XCTAssertLessThanOrEqual(spinner.frame.maxY, bar.frame.minY, "Loading feedback must be above the bar")
        snap("mail-footer-page-request-pending")
    }

    func testFailedFooterKeepsRetryAboveTheBottomBar() {
        launchProgress("known", paging: "failed")
        reachFooter()
        let retry = app.buttons[MailID.listRetry].firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(retry.isHittable, app.debugDescription)
        XCTAssertGreaterThanOrEqual(retry.frame.height + 0.001, 44)
        XCTAssertGreaterThanOrEqual(retry.frame.width + 0.001, 44)
        XCTAssertLessThanOrEqual(retry.frame.maxY, app.otherElements["shell.bar"].firstMatch.frame.minY)
        snap("mail-footer-retry-above-bar")
    }
    func testLargeTextKeepsProgressAndComposeReachable() {
        launchProgress("known", largeText: true)
        let progress = app.descendants(matching: .any)["mail.sync.progress"].firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 10), app.debugDescription)
        let action = app.buttons[isPad ? "mail.more" : MailID.compose].firstMatch
        XCTAssertTrue(action.exists, app.debugDescription)
        XCTAssertTrue(action.isHittable)
        // Accessibility coordinate conversion can return 43.999999999999986 for a 44pt target.
        XCTAssertGreaterThanOrEqual(action.frame.width + 0.001, 44)
        XCTAssertGreaterThanOrEqual(action.frame.height + 0.001, 44)
        XCTAssertGreaterThan(progress.frame.width, 24)
        XCTAssertGreaterThanOrEqual(progress.frame.minX, 0)
        XCTAssertLessThanOrEqual(progress.frame.maxX, action.frame.minX)
        if !isPad {
            let place = app.buttons[MailID.placeMenu].firstMatch
            let count = app.staticTexts[MailID.listCount].firstMatch
            XCTAssertLessThanOrEqual(place.frame.height, max(44, count.frame.height * 1.6),
                                     "The header title must stay on one line at accessibility sizes")
        }
        snap("mail-header-large-text-progress")
        if isPad {
            action.tap()
            let newMessage = app.buttons["New message"].firstMatch
            XCTAssertTrue(newMessage.waitForExistence(timeout: 5))
            // Native menus scroll at large text sizes; tap scrolls the item into view.
            newMessage.tap()
            XCTAssertTrue(app.descendants(matching: .any)[MailID.composerBody].firstMatch.waitForExistence(timeout: 10),
                          app.debugDescription)
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
