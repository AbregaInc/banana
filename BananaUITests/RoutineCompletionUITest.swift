import XCTest

final class RoutineCompletionUITest: XCTestCase {
    func testDueCustomRoutineCanBeCompletedAndRestoredWithUndo() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--plan", "-planMode", "day", "--modules", "everything",
                               "--custom-routine-completion-preview", "--reset-routine-completion",
                               "--disable-icloud", "--no-space-sync", "-onboardingCompleted", "YES"]
        app.launch()
        let attention = app.buttons["plan.attention"]
        XCTAssertTrue(attention.waitForExistence(timeout: 20), app.debugDescription)
        attention.tap()
        // SwiftUI can expose the restored row as PopUpButton after List reconciliation.
        let complete = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Mark Physical therapy completed")).firstMatch
        XCTAssertTrue(complete.waitForExistence(timeout: 5), app.debugDescription)
        complete.tap()
        XCTAssertTrue(waitUntil { !complete.exists }, "completed routine leaves the due list")
        let undo = app.buttons["Undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "Undo is reachable inside the attention sheet")
        undo.tap()
        XCTAssertTrue(complete.waitForExistence(timeout: 5), "Undo restores the same occurrence")
        complete.tap()
        XCTAssertTrue(waitUntil { !complete.exists }, "second completion is acknowledged before relaunch")
        app.terminate()
        app.launchArguments.removeAll { $0 == "--reset-routine-completion" }
        app.launch()
        XCTAssertTrue(app.buttons["mobile.week.more"].waitForExistence(timeout: 20), app.debugDescription)
        // Other walks can leave due reminders/routines. Their attention row must remain;
        // check this occurrence rather than assuming the entire attention list is empty.
        if attention.waitForExistence(timeout: 3) {
            attention.tap()
            XCTAssertFalse(complete.waitForExistence(timeout: 3),
                           "therapy completion survives relaunch\n\(app.debugDescription)")
        }
    }
}
