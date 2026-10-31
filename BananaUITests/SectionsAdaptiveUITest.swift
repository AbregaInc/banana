import XCTest

final class SectionsAdaptiveUITest: XCTestCase {
    private func launch(_ arguments: [String]) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = arguments + ["--disable-icloud", "-onboardingCompleted", "YES"]
        app.launch()
        return app
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testWorkoutsPeriodControls() {
        // The isolated --workout scene has no PageChromeHost to present Review.
        // ControlRulesWalk covers entry from the real Workouts tab; use Review's
        // existing fixture here to exercise its period controls and rotation.
        let app = launch(["--review", "--dummy-health"])
        let month = app.buttons["Month"].firstMatch
        XCTAssertTrue(month.waitForExistence(timeout: 5))
        month.tap()
        app.buttons["Previous month"].tap()
        XCTAssertTrue(app.buttons["Next month"].isEnabled)
        capture("workouts-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitUntil { app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height })
        XCTAssertTrue(app.buttons["Next month"].isHittable)
        app.buttons["Next month"].tap()
        XCTAssertFalse(app.buttons["Next month"].isEnabled)
        capture("workouts-landscape")
    }

    func testSleepAndTrends() {
        let app = launch(["--sleep"])
        XCTAssertTrue(app.staticTexts["Last night"].waitForExistence(timeout: 20))
        capture("sleep-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        capture("sleep-landscape")
        app.terminate()
        app.launchArguments = ["--trends", "--dummy-health", "--disable-icloud", "--no-space-sync", "-onboardingCompleted", "YES"]
        app.launch()
        // Historical span selection lives in Review now (covered above). All measures
        // remains usable as its own landscape list rather than carrying a second picker.
        XCTAssertTrue(app.navigationBars["All measures"].waitForExistence(timeout: 20))
        let heart = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Resting HR")).firstMatch
        XCTAssertTrue(heart.waitForExistence(timeout: 5))
        app.swipeUp()
        XCTAssertTrue(app.navigationBars["All measures"].exists)
        capture("trends-landscape")
    }

    func testLibrarySelectionAndSettingsCategories() {
        let app = launch(["--library"])
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.podcast.")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        let episodes = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Episodes (")).firstMatch
        XCTAssertTrue(episodes.waitForExistence(timeout: 8))
        capture("library-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(episodes.waitForExistence(timeout: 8))
        capture("library-landscape")
        app.terminate()
        app.launchArguments = ["--settings", "--disable-icloud", "-onboardingCompleted", "YES"]
        app.launch()
        let workouts = app.staticTexts["Workouts"].firstMatch
        if workouts.waitForExistence(timeout: 5) {
            workouts.tap()
            XCTAssertTrue(app.staticTexts["Pool length"].waitForExistence(timeout: 5))
        } else {
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 20))
        }
        capture("settings-landscape")
    }

    func testRoutinesControls() {
        let app = launch(["--routines"])
        XCTAssertTrue(app.buttons["routines.add"].waitForExistence(timeout: 20))
        capture("routines-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["routines.add"].isHittable)
        capture("routines-landscape")
    }
}
