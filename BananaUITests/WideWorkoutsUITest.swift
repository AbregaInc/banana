import XCTest

/// The wide Workouts page — an iPad's at full width, and the same view the Mac shows — opens what
/// the phone's list opens (a workout that's only in Apple Health) and keeps its place when the
/// app comes back.
final class WideWorkoutsUITest: XCTestCase {
    /// Stand the simulator back up: it stays on its side otherwise, and the store's iPad
    /// screenshots (tools/app-store) are taken in portrait.
    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    private func launch() throws -> XCUIApplication {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "the wide page is an iPad's")
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--tab", "workouts", "--dummy-health", "--disable-icloud", "--no-space-sync",
                               "--ui-audit", "-onboardingCompleted", "YES"]
        app.withoutSpaceSync()
        app.launch()
        return app
    }

    func testThePlaceIsKept() throws {
        let app = try launch()
        // The sample's yoga session: its detail is one screen down the stack.
        let row = app.staticTexts["A Very Long Third-Party App Name"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), app.debugDescription)
        row.tap()
        let detail = app.descendants(matching: .any)["workout.healthOnly"]
        XCTAssertTrue(detail.waitForExistence(timeout: 5), app.debugDescription)

        // Away and back: the page is rebuilt, and is where it was.
        XCUIDevice.shared.press(.home)
        waitUntil(timeout: 6) { app.state != .runningForeground }
        app.activate()
        XCTAssertTrue(detail.waitForExistence(timeout: 12), "the wide page forgot its place")
    }

    /// Guided plans are switched off (`Features.guidedPlans`): no row on the wide page either.
    func testGuidedPlansAreOff() throws {
        let app = try launch()
        XCTAssertTrue(app.staticTexts["A Very Long Third-Party App Name"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["workouts.guidedPlans"].exists)
    }

    func testAWorkoutThatIsOnlyInHealthOpens() throws {
        let app = try launch()
        // The sample's yoga session, from another app: Health has it and Banana recorded nothing.
        let row = app.staticTexts["A Very Long Third-Party App Name"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), app.debugDescription)
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["workout.healthOnly"].waitForExistence(timeout: 5)
                      || app.staticTexts["Recorded outside Banana — no route, charts, or motion data to show."].waitForExistence(timeout: 2),
                      app.debugDescription)
    }

    /// Deleting from the wide list is the phone's delete: gone at once, with Undo, and no
    /// question first. (The wide list asked; the Mac asked and warned.)
    func testDeletingAWorkoutCanBeUndone() throws {
        let app = try launch()
        // The list's rows: each reads its activity, then when it was.
        let rows = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", ", 2026 at "))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        let before = rows.count
        // A workout Banana recorded can be deleted; one that is only in Health, from another
        // app, offers Hide. Find the first of Banana's.
        let delete = app.buttons["Delete workout"]
        for index in 0..<before where !delete.exists {
            let row = rows.element(boundBy: index)
            guard row.isHittable else { continue }
            row.press(forDuration: 1.2)
            if !delete.waitForExistence(timeout: 2) {
                // Not Banana's: close its menu.
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.95)).tap()
                sleep(1)
            }
        }
        // The sample's workouts all come from other apps, which Banana can only hide: until it
        // has one of Banana's own, the removal itself is WorkoutEntryTests'.
        try XCTSkipUnless(delete.exists, "the sample has no workout Banana recorded")
        delete.tap()

        let undo = app.buttons["Undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "no question first: the toast is the way back")
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertEqual(rows.count, before - 1, "gone from the list at once")
        undo.tap()
        expectation(for: NSPredicate(format: "count == %d", before), evaluatedWith: rows)
        waitForExpectations(timeout: 5)
    }
}
