import XCTest

/// Controls VoiceOver can name and use (HIG, Accessibility): a switch says what it switches, and
/// a choice that is tapped is a button with a label.
final class HIGAccessibilityUITest: XCTestCase {

    private func launch(_ arguments: [String]) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["--ui-audit", "--disable-icloud", "-finishSetupDismissed", "YES",
                                "-onboardingCompleted", "YES"] + arguments
        app.withoutSpaceSync()
        app.launch()
        return app
    }

    /// Each routine's switch is its own element, named for the routine, and turning it does not
    /// open the routine: it used to sit inside the row's button, unnamed.
    func testARoutinesSwitchIsNamedAndTurnsWithoutOpeningIt() throws {
        let app = launch(["--routines"])
        let toggle = app.switches["Wake"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 25), "no switch named for the Wake routine")
        let before = toggle.value as? String
        toggle.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { (toggle.value as? String) != before }, "the switch didn't turn")
        XCTAssertFalse(app.navigationBars["Wake"].exists, "turning the switch opened the routine")
        // The name still opens it.
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Wake,'")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Wake"].waitForExistence(timeout: 5), "the row's name didn't open the routine")
    }
}
