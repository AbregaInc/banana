import XCTest

final class RoutineCompletionUITest: XCTestCase {
    /// A routine past its time is a chip in the day's row beside the reminders (no band, no entry
    /// under the period picker): its circle completes it, Undo restores it, and it stays done.
    func testDueCustomRoutineCanBeCompletedAndRestoredWithUndo() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--plan", "-planMode", "day", "--modules", "everything",
                               "--custom-routine-completion-preview", "--reset-routine-completion",
                               "--disable-icloud", "--no-space-sync", "-onboardingCompleted", "YES"]
        app.launch()
        let complete = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Mark Physical therapy completed")).firstMatch
        XCTAssertTrue(complete.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertFalse(app.buttons["plan.attention"].exists, "no separate way in")
        XCTAssertFalse(app.staticTexts["Needs attention"].exists, "no header of its own")
        // Cards above the row (a meeting's alert, the alerts question) arrive after launch and
        // push it down: tap once it has stopped moving.
        func settled() {
            var last = CGRect.null
            _ = waitUntil(timeout: 10) {
                let now = complete.frame
                defer { last = now }
                return now == last && !now.isEmpty
            }
        }
        settled()
        complete.tap()
        XCTAssertTrue(waitUntil { !complete.exists }, "completed routine leaves the row")
        let undo = app.buttons["Undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "Undo is offered")
        undo.tap()
        XCTAssertTrue(complete.waitForExistence(timeout: 5), "Undo restores the same occurrence")
        settled()
        complete.tap()
        XCTAssertTrue(waitUntil { !complete.exists }, "second completion is acknowledged before relaunch")
        app.terminate()
        app.launchArguments.removeAll { $0 == "--reset-routine-completion" }
        app.launch()
        XCTAssertTrue(app.buttons["mobile.week.more"].waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertFalse(complete.waitForExistence(timeout: 3), "therapy completion survives relaunch\n\(app.debugDescription)")
    }
}
