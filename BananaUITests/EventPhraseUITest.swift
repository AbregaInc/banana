import XCTest

/// A new event typed the way you'd say it: the form shows what it read, Fill in sets it, Undo
/// puts the form back.
final class EventPhraseUITest: XCTestCase {
    func testTypingItFillsInTheForm() {
        let app = XCUIApplication()
        app.launchArguments = ["--new-calendar-event", "--guest-fixtures", "--disable-icloud", "--no-space-sync", "-onboardingCompleted", "YES"]
        app.withoutSpaceSync()
        app.launch()

        let title = app.textFields["event.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 15), app.debugDescription)
        title.tap()
        title.typeText("Lunch with Sam tomorrow at 1pm at Balthazar")

        let fill = app.buttons["event.fillIn"]
        XCTAssertTrue(fill.waitForExistence(timeout: 3), "what it read is offered\n\(app.debugDescription)")
        XCTAssertTrue(fill.label.contains("Balthazar"), fill.label)
        fill.tap()

        XCTAssertTrue(app.buttons["event.fillIn.undo"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(title.value as? String, "Lunch with Sam")
        XCTAssertTrue(app.textFields.matching(NSPredicate(format: "value == %@", "Balthazar")).firstMatch.exists
                      || app.staticTexts["Balthazar"].exists, "the place went to Where\n\(app.debugDescription)")

        app.buttons["event.fillIn.undo"].tap()
        XCTAssertEqual(title.value as? String, "Lunch with Sam tomorrow at 1pm at Balthazar")
    }
}
