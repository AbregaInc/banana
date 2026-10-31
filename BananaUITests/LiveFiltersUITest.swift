import XCTest

final class LiveFiltersUITest: XCTestCase {
    func testNotesUpdateFromTypingAndChipRemovalWithoutSubmission() {
        let app = XCUIApplication()
        app.launchArguments = ["--notes", "--disable-icloud", "--no-space-sync", "-onboardingCompleted", "YES"]
        app.withoutSpaceSync(); app.launch()
        let query = app.textFields["filters.notes.query"]
        XCTAssertTrue(query.waitForExistence(timeout: 20))
        query.tap(); query.typeText("archived notes about standup")
        let archived = app.descendants(matching: .any)["notes.row.99A5F6E1-9D7D-4D98-A8EA-610EF6E13B03"].firstMatch
        XCTAssertTrue(archived.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Edit Archive: Archived"].exists)
        XCTAssertFalse(app.buttons["Apply filters"].exists)
        XCTAssertFalse(app.buttons["Interpret"].exists)
        app.buttons["Remove Archive: Archived"].tap()
        XCTAssertTrue(archived.exists)
        app.buttons["Clear filters"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["notes.row.99A5F6E1-9D7D-4D98-A8EA-610EF6E13B01"].firstMatch.waitForExistence(timeout: 5))
    }

    func testWorkoutsUpdateWithoutReturnOrApply() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--tab", "workouts", "--dummy-health", "--disable-icloud", "--no-space-sync", "-onboardingCompleted", "YES"]
        app.withoutSpaceSync(); app.launch()
        let query = app.textFields["filters.workouts.query"]
        XCTAssertTrue(query.waitForExistence(timeout: 20))
        query.tap(); query.typeText("workouts under 0 minutes")
        XCTAssertTrue(app.buttons["Edit Minutes: Under 0"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No matching workouts."].waitForExistence(timeout: 5) || app.staticTexts["No matching workouts"].exists)
        XCTAssertFalse(app.buttons["Apply filters"].exists)
        app.buttons["Remove Minutes: Under 0"].tap()
        XCTAssertFalse(app.buttons["Edit Minutes: Under 0"].exists)
    }
}
