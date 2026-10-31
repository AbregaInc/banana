import XCTest

/// Normal installed Beta startup: no fixture arguments or renderer opt-ins.
/// A launch pass is intentionally separate from account/workflow acceptance.
final class ReviewLaunchUITests: XCTestCase {
    /// Read-only navigation against the installed shipping variants. No fixture accounts,
    /// permission changes or calendar writes; traces collected separately are timing evidence.
    func testNormalMainPlanNavigationAndSearch() { checkPlan(bundle: "com.boris.banana") }
    func testNormalBetaPlanNavigationAndSearch() { checkPlan(bundle: "com.boris.banana.beta") }

    func testNormalMainCalendarScrollTrace() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.boris.banana")
        app.activate()
        let plan = app.buttons["Plan"].firstMatch
        XCTAssertTrue(plan.waitForExistence(timeout: 20))
        plan.tap()
        let day = app.segmentedControls.buttons["Day"]
        XCTAssertTrue(day.waitForExistence(timeout: 10)); day.tap()
        let viewport = app.collectionViews["calendar.nativeDay.viewport"]
        XCTAssertTrue(viewport.waitForExistence(timeout: 10), app.debugDescription)
        // The host attaches Instruments after the first observed swipe. Enough repeated
        // interaction remains for its bounded recording; gesture duration is not UI latency.
        for _ in 0..<16 { viewport.swipeUp(); viewport.swipeDown() }
    }

    private func checkPlan(bundle: String) {
        let app = XCUIApplication(bundleIdentifier: bundle)
        app.launchArguments = ["-onboardingCompleted", "YES"]
        app.launch()
        requireForeground(app)
        let plan = app.buttons["Plan"].firstMatch
        XCTAssertTrue(plan.waitForExistence(timeout: 20), app.debugDescription)
        plan.tap()
        for mode in ["Day", "Week", "Day"] {
            let choice = app.segmentedControls.buttons[mode]
            XCTAssertTrue(choice.waitForExistence(timeout: 10))
            choice.tap()
            let surface = app.otherElements["plan.surface." + mode.lowercased()]
            XCTAssertTrue(surface.waitForExistence(timeout: 10), app.debugDescription)
            let viewport = surface.collectionViews.firstMatch
            XCTAssertTrue(viewport.waitForExistence(timeout: 10), app.debugDescription)
            viewport.swipeUp(); viewport.swipeDown()
            let picture = XCTAttachment(screenshot: app.screenshot())
            picture.name = "installed-\(bundle)-\(mode.lowercased())"
            picture.lifetime = .keepAlways; add(picture)
        }
        app.buttons["calendar.search.open"].tap()
        let query = app.textFields["filters.plan.query"]
        XCTAssertTrue(query.waitForExistence(timeout: 5), app.debugDescription)
        query.tap(); query.typeText("meetings next week")
        XCTAssertTrue(app.buttons["Edit Date: Next week"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Edit Type: meeting"].exists)
        XCTAssertFalse(app.buttons["Interpret"].exists)
        XCTAssertFalse(app.buttons["Apply filters"].exists)
        app.buttons["Clear filters"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["calendar.search.open"].waitForExistence(timeout: 5))
        app.terminate(); app.launch(); requireForeground(app)
        XCTAssertTrue(app.buttons["calendar.search.open"].waitForExistence(timeout: 15))
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        // The retained first launch failure entered landscape StandBy. Establish an
        // awake portrait starting state without changing system Auto-Lock settings.
        XCUIDevice.shared.press(.home)
        XCUIDevice.shared.orientation = .portrait
    }

    private func requireForeground(_ app: XCUIApplication) {
        guard app.wait(for: .runningForeground, timeout: 20) else {
            let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let state = XCTAttachment(string: "Beta state: \(app.state.rawValue)\n" + system.debugDescription)
            state.name = "normal-beta-foreground-failure-system-state"
            state.lifetime = .keepAlways; add(state)
            let picture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            picture.name = "normal-beta-foreground-failure-screen"
            picture.lifetime = .keepAlways; add(picture)
            XCTFail("Normal Beta did not become foreground; system state retained")
            return
        }
    }
    func testNormalBetaLaunchAndRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.boris.banana.beta")
        for pass in 1...2 {
            app.launch()
            requireForeground(app)
            XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "normal-beta-launch-\(pass)-hierarchy"
            tree.lifetime = .keepAlways
            add(tree)
            let picture = XCTAttachment(screenshot: app.screenshot())
            picture.name = "normal-beta-launch-\(pass)"
            picture.lifetime = .keepAlways
            add(picture)
            app.terminate()
        }
        // Leave the regular app available for review after the second cold launch.
        app.launch()
        requireForeground(app)
    }

    func testNormalBetaPlanAndMailNavigation() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.boris.banana.beta")
        // Test the ordinary shell without completing onboarding or granting permissions.
        // This argument-domain override is not written into the user's preferences.
        app.launchArguments = ["-onboardingCompleted", "YES"]
        app.launch()
        let plan = app.buttons["Plan"].firstMatch
        XCTAssertTrue(plan.waitForExistence(timeout: 20))
        plan.tap()
        for mode in ["Day", "Week", "Day"] {
            let choice = app.segmentedControls.buttons[mode]
            XCTAssertTrue(choice.waitForExistence(timeout: 10))
            choice.tap()
            let viewport = app.collectionViews["plan.surface." + mode.lowercased()]
            XCTAssertTrue(viewport.waitForExistence(timeout: 10), "The replacement viewport must be mounted")
            let ready = app.descendants(matching: .any).matching(identifier: "calendar.preparedArtwork").count
            let direct = app.descendants(matching: .any).matching(identifier: "calendar.nativeArtwork.direct").count
            let pending = app.descendants(matching: .any).matching(identifier: "calendar.preparedArtwork.pending").count
            let failed = app.descendants(matching: .any).matching(identifier: "calendar.preparedArtwork.failed").count
            let evidence = XCTAttachment(string: "mode=\(mode) prepared=\(ready) direct=\(direct) pending=\(pending) failed=\(failed); zero prepared/direct events is NOT renderer acceptance")
            evidence.name = "normal-beta-\(mode.lowercased())-renderer-state"
            evidence.lifetime = .keepAlways; add(evidence)
            XCTAssertEqual(failed, 0, "The replacement must not hide an event preparation failure")
            let calendarPicture = XCTAttachment(screenshot: app.screenshot())
            calendarPicture.name = "normal-beta-\(mode.lowercased())"
            calendarPicture.lifetime = .keepAlways; add(calendarPicture)
        }
        app.buttons["calendar.search.open"].tap()
        let calendarQuery = app.searchFields["Search events"]
        XCTAssertTrue(calendarQuery.waitForExistence(timeout: 5))
        calendarQuery.tap()
        // No provider request: verify the actual installed search UI and keyboard routing.
        calendarQuery.typeText("   \n")
        XCTAssertTrue(calendarQuery.exists, "Return must not dismiss Calendar search")
        app.buttons["Clear text"].tap()
        XCTAssertFalse(app.buttons["Clear text"].exists)
        // Native search expands while focused. End that presentation before dismissing
        // its containing sheet; iOS 27 calls this control Close, earlier runtimes Cancel.
        if !app.buttons["Done"].exists {
            let close = app.buttons.matching(NSPredicate(format: "label IN %@", ["Close", "Cancel"])).firstMatch
            XCTAssertTrue(close.waitForExistence(timeout: 5))
            close.tap()
        }
        if app.searchFields["Search events"].exists {
            XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
            app.buttons["Done"].tap()
        }
        XCTAssertFalse(app.searchFields["Search events"].exists, "Calendar search is dismissed")
        XCTAssertTrue(app.buttons["calendar.search.open"].waitForExistence(timeout: 5))
        let mail = app.buttons["Mail"].firstMatch
        XCTAssertTrue(mail.waitForExistence(timeout: 10), "Mail must be reachable without a launch route")
        mail.tap()
        XCTAssertTrue(app.descendants(matching: .any)[MailID.list].firstMatch.waitForExistence(timeout: 10))
        let mailQuery = app.textFields["mail.search.query"]
        XCTAssertTrue(mailQuery.exists, "Mail search must be available in normal Beta")
        mailQuery.tap()
        // Local lookup only. No Gmail consent, mailbox write or expected account data.
        mailQuery.typeText("reviewsearchprobe\n")
        let coverage = app.staticTexts["Downloaded subjects, people and snippets · word prefixes · press Return to search"]
        XCTAssertTrue(coverage.waitForExistence(timeout: 5), "Return must enter local search")
        app.buttons["Clear mail search"].tap()
        XCTAssertTrue(coverage.waitForNonExistence(timeout: 5), "Clear must restore the mailbox")
        XCTAssertFalse(app.buttons["Clear mail search"].exists)
        let picture = XCTAttachment(screenshot: app.screenshot())
        picture.name = "normal-beta-mail-tab"; picture.lifetime = .keepAlways; add(picture)
        app.terminate()
        app.launchArguments = []
        app.launch()
        requireForeground(app)
    }

}
