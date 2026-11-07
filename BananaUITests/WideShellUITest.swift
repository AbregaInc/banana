import XCTest

/// The wide shell on an iPad (docs/design/BOTTOM-BAR-SHELL.md, Wide): the rail of pages at the
/// left edge and one toolbar with "Search or ask", in both orientations — rotation never swaps it
/// for the phone's bar. `TEST_RUNNER_SHELL_SHOTS=<folder>` keeps a picture of each screen.
final class WideShellUITest: XCTestCase {
    private let folder = ProcessInfo.processInfo.environment["SHELL_SHOTS"].map { URL(fileURLWithPath: $0) }

    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    private func launch(_ extra: [String]) throws -> XCUIApplication {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad, "the rail is the iPad's (and the Mac's)")
        let app = XCUIApplication()
        app.launchArguments += ["--ui-preview", "--ui-audit", "--disable-icloud", "--dummy-health", "--store-capture",
                                "-finishSetupDismissed", "YES", "-onboardingCompleted", "YES", "--modules", "everything"] + extra
        app.withoutSpaceSync()
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["shell.rail"].waitForExistence(timeout: 30), app.debugDescription)
        return app
    }

    private func shot(_ name: String) {
        guard let folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: folder.appendingPathComponent("\(name).png"))
    }

    func testTheRailAndTheToolbarFieldInBothOrientations() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = try launch(["--tab", "plan", "-planMode", "week"])
        XCTAssertFalse(app.buttons["shell.switcher"].exists, "no bottom bar on a wide screen")
        XCTAssertTrue(app.buttons["shell.page.plan"].isSelected)
        XCTAssertTrue(app.textFields["shell.field"].waitForExistence(timeout: 10), "the field is in the toolbar")
        shot("pad-portrait-plan")

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitUntil(timeout: 5) { app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height })
        XCTAssertTrue(app.descendants(matching: .any)["shell.rail"].waitForExistence(timeout: 5),
                      "turning the iPad keeps the rail")
        XCTAssertFalse(app.buttons["shell.switcher"].exists)
        shot("pad-land-plan")

        // Typing in the toolbar's field hangs what it finds under it.
        app.textFields["shell.field"].tap()
        app.textFields["shell.field"].typeText("lunch")
        XCTAssertTrue(app.descendants(matching: .any)["shell.results"].waitForExistence(timeout: 5))
        shot("pad-land-search")
        app.buttons["shell.field.clear"].tap()

        // The rail opens a page.
        app.buttons["shell.page.notes"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { app.buttons["shell.page.notes"].isSelected })
    }

    /// Notes is a split view on an iPad: the field sits on the note's bar, and focused with
    /// nothing typed it offers what Notes can add.
    func testNotesFieldIsOnTheNotesBarAndOffersItsKinds() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = try launch(["--tab", "notes", "--notes"])
        let field = app.textFields["shell.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 15), app.debugDescription)
        shot("pad-portrait-notes")
        field.tap()
        let found = app.buttons["notes.write"].waitForExistence(timeout: 5)
        shot("pad-portrait-notes-add")
        XCTAssertTrue(found, app.debugDescription)
    }

    func testMailHasItsPlaceMenuTheFieldAndMoreInOneRow() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = try launch(["--tab", "mail", "--mail-fresh"])
        XCTAssertTrue(app.buttons["shell.page.mail"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["mail.list.placeMenu"].firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.textFields["shell.field"].exists)
        XCTAssertTrue(app.buttons["mail.more"].exists)
        shot("pad-land-mail")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.descendants(matching: .any)["shell.rail"].waitForExistence(timeout: 5))
        shot("pad-portrait-mail")
    }
}
