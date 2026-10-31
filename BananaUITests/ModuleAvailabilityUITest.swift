import XCTest

final class ModuleAvailabilityUITest: XCTestCase {
    func testMainAppShowsOnlyReleasedModulesWithoutPreviewBadges() {
        let app = XCUIApplication()
        app.launchArguments = ["--settings", "--modules", "everything", "--disable-icloud", "--no-space-sync", "-onboardingCompleted", "YES"]
        app.launch()
        let modules = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Modules")).firstMatch
        XCTAssertTrue(modules.waitForExistence(timeout: 15))
        modules.tap()
        XCTAssertTrue(app.switches["settings.module.workouts"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.switches["settings.module.email"].exists)
        for name in ["workouts", "food", "notes", "podcasts"] {
            XCTAssertTrue(app.switches["settings.module.\(name)"].isEnabled)
            XCTAssertFalse(app.switches["settings.module.\(name)"].label.contains("Beta"))
            XCTAssertFalse(app.switches["settings.module.\(name)"].label.contains("Coming soon"))
        }
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Main app module availability"
        image.lifetime = .keepAlways
        add(image)
    }
}
