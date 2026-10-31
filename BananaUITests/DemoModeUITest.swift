import XCTest
import UIKit

final class DemoModeUITest: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .landscapeLeft }
    }
    override func tearDown() { XCUIDevice.shared.orientation = .portrait }
    private func app(session: String = UUID().uuidString, fault: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--disable-icloud", "--no-space-sync", "-onboardingCompleted", "NO",
            "--demo-test-session", session, "--demo-test-clock", "2026-10-26T12:00:00Z"]
        if fault { app.launchArguments.append("--demo-save-failure") }
        app.withoutSpaceSync()
        return app
    }

    private func enter(_ app: XCUIApplication) {
        let open = app.buttons["demo.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 20))
        open.tap()
        XCTAssertTrue(app.otherElements["demo.banner"].waitForExistence(timeout: 10)
            || app.staticTexts["demo.banner"].exists)
        XCTAssertTrue(app.buttons["Add sample event"].waitForExistence(timeout: 10))
    }

    private func addEvent(_ title: String, app: XCUIApplication) {
        app.buttons["Add sample event"].tap()
        let field = app.textFields["demo.event.title"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(title)
        app.buttons["demo.event.save"].tap()
    }

    func testPublicEntryCalendarEditAndExitPreserveOnboarding() throws {
        let app = app(); app.launch()
        let food = app.buttons["onboarding.module.food"]
        XCTAssertTrue(food.waitForExistence(timeout: 20))
        // The full suite shares a personal profile between classes. A previous flow may
        // already have enabled Food; entering sample data must preserve either state.
        let foodWasSelected = food.isSelected
        enter(app)
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertTrue(waitUntil { app.frame.width > app.frame.height })
        }
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Demo Plan — fictional data"; shot.lifetime = .keepAlways; add(shot)
        addEvent("Demo appointment", app: app)
        let event = try revealCalendarButton("Demo appointment,", in: app, referenceLabelPattern: "1\\s*PM")
        event.tap()
        XCTAssertTrue(app.textFields["demo.event.title"].waitForExistence(timeout: 5))
        app.buttons["demo.event.delete"].tap()
        XCTAssertTrue(waitUntil { !app.textFields["demo.event.title"].exists })
        app.buttons["demo.exit"].tap()
        XCTAssertTrue(app.buttons["onboarding.continue"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["onboarding.module.food"].isSelected, foodWasSelected,
            "A demo must preserve the personal profile's module selection")
    }

    func testNotesAndMealsPersistAcrossRelaunchInTheirOwnProfile() throws {
        let app = app(); app.launch(); enter(app)
        app.buttons["demo.tab.notes"].tap()
        app.buttons["demo.note.add"].tap()
        let editor = app.textViews["demo.note.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap(); editor.typeText("My sample idea")
        app.buttons["demo.note.save"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "My sample idea")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["demo.tab.body"].tap()
        app.segmentedControls.buttons["Food"].tap()
        app.buttons["demo.meal.add"].tap()
        let name = app.textFields["demo.meal.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Late lunch")
        let food = app.textFields["demo.meal.food"]; food.tap(); food.typeText("Rice bowl")
        app.buttons["demo.meal.save"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Late lunch")).firstMatch.waitForExistence(timeout: 5))
        app.terminate(); app.launch(); enter(app)
        app.buttons["demo.tab.notes"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "My sample idea")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["demo.tab.body"].tap(); app.segmentedControls.buttons["Food"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Late lunch")).firstMatch.waitForExistence(timeout: 5))
    }

    func testReadOnlyCalendarAndResetAreExplicit() throws {
        let app = app(); app.launch(); enter(app)
        let busy = try revealCalendarButton("Busy,", in: app, referenceLabelPattern: "3\\s*PM")
        busy.tap()
        XCTAssertTrue(app.staticTexts["This calendar shares availability only."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["demo.event.save"].exists)
        app.buttons["Done"].tap()
        let task = app.buttons["demo.task.D3A00000-0000-4000-8000-000000000010"]
        XCTAssertTrue(task.exists); task.tap()
        XCTAssertTrue(waitUntil { task.value as? String == "Completed" })
        app.buttons["Demo options"].tap(); app.buttons["Reset sample data"].tap()
        app.buttons["Reset sample data"].tap()
        XCTAssertTrue(waitUntil { task.value as? String == "Not completed" })
    }

    func testExistingUserCanEnterFromSettingsAboutAndExit() {
        let app = app()
        app.launchArguments += ["--settings", "--modules", "plan", "-onboardingCompleted", "YES"]
        app.launch()
        let about = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "About")).firstMatch
        XCTAssertTrue(about.waitForExistence(timeout: 20))
        for _ in 0..<8 {
            if about.isHittable && about.frame.maxY < app.frame.maxY - 140 { break }
            app.swipeUp()
        }
        about.tap(); enter(app)
        app.buttons["demo.exit"].tap()
        XCTAssertTrue(app.buttons["demo.open"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["onboarding.continue"].exists)
    }

    func testFailedSaveRetainsTheEditorAndCanBeRetried() throws {
        let app = app(fault: true); app.launch(); enter(app)
        addEvent("Retry appointment", app: app)
        XCTAssertTrue(app.staticTexts["demo.editor.error"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["demo.event.title"].value as? String, "Retry appointment")
        app.buttons["demo.event.save"].tap()
        _ = try revealCalendarButton("Retry appointment,", in: app, referenceLabelPattern: "1\\s*PM")
        app.terminate(); app.launch(); enter(app)
        _ = try revealCalendarButton("Retry appointment,", in: app, referenceLabelPattern: "1\\s*PM")
    }
}
