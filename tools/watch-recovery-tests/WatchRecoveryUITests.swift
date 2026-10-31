import XCTest

/// Attaches to the installed Watch app. The default smoke test never starts a workout.
/// Live recording/recovery is a separate, explicitly selected phase with host-side diagnostics.
final class WatchRecoveryUITests: XCTestCase {
    func testInstalledWorkoutPicker() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.boris.banana.watchkitapp")
        app.activate()
        let start = app.buttons["Start Strength workout"]
        XCTAssertTrue(start.waitForExistence(timeout: 20), app.debugDescription)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "watch-installed-picker"
        screenshot.lifetime = .keepAlways; add(screenshot)
    }

    func testRecoveredStrengthControls() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.boris.banana.watchkitapp")
        // Do not launch/terminate: HealthKit may just have relaunched the active workout.
        app.activate()
        XCTAssertTrue(app.buttons["Start 30 second rest"].waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(app.buttons["Start 1 minute rest"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "watch-recovered-strength"
        screenshot.lifetime = .keepAlways; add(screenshot)
    }
}
