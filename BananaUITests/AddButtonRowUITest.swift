import XCTest

/// On a phone adding is the bottom bar's field (docs/design/BOTTOM-BAR-SHELL.md): tapped with
/// nothing typed it lists everything that can be added, this page's first. Workouts and
/// Nutrition are one page, Body, with the others under its title.
final class AddButtonRowUITest: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// The field at the bottom lists what can be added, and a pick opens it. The + was in the top
    /// bar before; the tab bar's search slot before that stuttered (iOS took it for a page).
    func testTheFieldListsWhatCanBeAddedAndAPickOpensIt() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "the phone's shell")
        let app = launch()
        let add = app.plus("wellness.add")
        XCTAssertTrue(add.exists, app.debugDescription)
        XCTAssertFalse(app.buttons["wellness.add"].exists, "no + in the top bar any more")
        XCTAssertGreaterThan(add.frame.midY, app.windows.firstMatch.frame.height * 0.8, "the field is at the bottom")

        add.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "page.add.list").firstMatch.waitForExistence(timeout: 5))
        app.buttons["wellness.manualMeal"].tap()
        // A freshly erased simulator shows Apple's typing introduction on the first
        // focused field. Dismiss it before querying the editor underneath it.
        let typingIntroduction = app.staticTexts.matching(NSPredicate(format:
            "label BEGINSWITH %@", "Speed up your typing")).firstMatch
        if typingIntroduction.waitForExistence(timeout: 3) {
            app.buttons["Continue"].tap()
        }
        XCTAssertTrue(app.navigationBars["New meal"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "page.add.list").firstMatch.exists)
        XCTAssertTrue(app.textFields["foodText.name"].waitForExistence(timeout: 5), app.debugDescription)
    }

    func testDescribeOpensThePhraseEditor() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "the phone's global Add list")
        let app = launch()
        app.plus("wellness.add").tap()
        let describe = app.buttons["wellness.textMeal"]
        XCTAssertTrue(describe.waitForExistence(timeout: 5))
        describe.tap()
        XCTAssertTrue(app.descendants(matching: .any)["foodText.phrase"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["page.add.list"].exists)
        XCTAssertTrue(app.buttons["capture.recentMeals"].exists)
    }

    func testWorkoutsAndNutritionShareBody() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "the iPad has the rail")
        let app = launch()
        let switcher = app.buttons["shell.switcher"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 20), app.debugDescription)
        switcher.tap()
        XCTAssertTrue(app.buttons["shell.page.body"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["shell.page.body"].isSelected, "Food is under Body")
        for gone in ["workouts", "nutrition"] {
            XCTAssertFalse(app.buttons["shell.page.\(gone)"].exists, "\(gone) is not a page of its own")
        }
        switcher.tap()

        // The title names the page, with the others under its chevron.
        let title = app.descendants(matching: .any)["body.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(title.label.hasPrefix("Food"), title.label)
        title.tap()
        app.buttons["Workouts"].firstMatch.tap()
        wait("Workouts shows, under Body") { title.label.hasPrefix("Workouts") }

        // Body comes back to the page last looked at.
        switcher.tap()
        app.buttons["shell.page.notes"].tap()
        wait("Notes opens") { app.descendants(matching: .any)["page.title"].firstMatch.label == "Notes" }
        switcher.tap()
        app.buttons["shell.page.body"].tap()
        wait("Body is back on Workouts") { title.label.hasPrefix("Workouts") }
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--tab", "nutrition", "--store-capture", "--disable-icloud", "--no-space-sync",
                               "-onboardingCompleted", "YES"]
        app.withoutSpaceSync()
        app.launch()
        return app
    }

    private func wait(_ what: String, timeout: TimeInterval = 5, _ ready: @escaping () -> Bool,
                      file: StaticString = #filePath, line: UInt = #line) {
        let done = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in ready() }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [done], timeout: timeout), .completed, what, file: file, line: line)
    }
}
