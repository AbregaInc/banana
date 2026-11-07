import XCTest

/// An iPad's two layouts (docs/design/BOTTOM-BAR-SHELL.md): upright, the phone's bar at the bottom
/// with wider pages; on its side, the rail of pages and one toolbar with "Search or ask".
/// `TEST_RUNNER_SHELL_SHOTS=<folder>` keeps a picture of each screen.
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
        let rail = app.descendants(matching: .any)["shell.rail"], switcher = app.buttons["shell.switcher"]
        XCTAssertTrue(waitUntil(timeout: 30) { rail.exists || switcher.exists }, app.debugDescription)
        return app
    }

    private func shot(_ name: String) {
        guard let folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: folder.appendingPathComponent("\(name).png"))
    }

    func testTheBarUprightAndTheRailOnItsSide() throws {
        XCUIDevice.shared.orientation = .portrait
        // `--plan` loads the sample plan, so the week has its events and the weather to compare.
        let app = try launch(["--tab", "plan", "--plan", "-planMode", "week"])
        // Upright: the phone's layout, with the plan's title row at the top and the bar below.
        XCTAssertTrue(app.buttons["shell.switcher"].waitForExistence(timeout: 10), "the bar at the bottom upright")
        XCTAssertFalse(app.descendants(matching: .any)["shell.rail"].exists, "no rail upright")
        let title = app.descendants(matching: .any)["plan.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(app.textFields["shell.field"].frame.midY, app.windows.firstMatch.frame.height * 0.8)
        shot("pad-portrait-plan")

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitUntil(timeout: 5) { app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height })
        XCTAssertTrue(app.descendants(matching: .any)["shell.rail"].waitForExistence(timeout: 5),
                      "on its side the rail")
        XCTAssertTrue(waitUntil(timeout: 5) { !app.buttons["shell.switcher"].exists })
        XCTAssertTrue(app.buttons["shell.page.plan"].isSelected)
        // And no sidebar comes back with the turn (it lists Routines, which the rail doesn't).
        XCTAssertTrue(waitUntil(timeout: 3) { !app.staticTexts["Routines"].firstMatch.exists },
                      "the sidebar came back on turning")
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
        // Rail, list, reader: the places are the title's menu, and the details start closed.
        XCTAssertFalse(app.descendants(matching: .any)["mail.control"].exists, "no column of places")
        XCTAssertFalse(app.descendants(matching: .any)["mail.details"].exists, "no details column until asked")
        shot("pad-land-mail")
        XCUIDevice.shared.orientation = .portrait
        // Upright: the bar, one top row over the list and the reader, and the subject with one "…".
        XCTAssertTrue(app.buttons["shell.switcher"].waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["shell.rail"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["mail.list.placeMenu"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["mail.pane"].firstMatch.exists, "list and reader side by side")
        XCTAssertFalse(app.buttons["mail.done"].exists && app.buttons["mail.done"].isHittable,
                       "the reader's row of icons is under its \u{2026}")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Sample mail'")).firstMatch.exists)
        shot("pad-portrait-mail")
    }
}
