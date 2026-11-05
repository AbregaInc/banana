import XCTest

/// A Taken item due around a moment: the editor shows its minutes picker, and switching back to
/// a time is one tap.
final class AnchoredTimingUITest: XCTestCase {
    func testTheEditorSaysWhenInWords() {
        let app = XCUIApplication()
        app.launchArguments = ["--wellness", "--wellness-taken", "--supplement-anchored-preview",
                               "--disable-icloud", "--no-space-sync", "-onboardingCompleted", "YES"]
        app.withoutSpaceSync()
        app.launch()

        // The sentence under the fields is gone (less copy); the minutes picker says it.
        let summary = app.descendants(matching: .any)["timing.minutes"]
        var swipes = 0
        while !(summary.exists && summary.isHittable), swipes < 6 { app.swipeUp(); swipes += 1 }
        XCTAssertTrue(summary.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.staticTexts["timing.summary"].exists)

        // The switch is above the summary; reaching the summary can scroll it under the top bar.
        let atATime = app.buttons["At a time"]
        var back = 0
        // (`isHittable` is true for a control under the top bar, so go by where it is.)
        let bar = app.navigationBars["Edit"]
        while atATime.frame.minY < bar.frame.maxY + 8, back < 6 {
            app.swipeDown(velocity: .slow); back += 1
        }
        atATime.tap()
        XCTAssertFalse(summary.waitForExistence(timeout: 1), "back to a plain time")
    }
}
