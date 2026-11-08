import XCTest

/// Report a problem (docs/design/PROBLEM-REPORTS.md): "…" opens the sheet over the page, it
/// names what goes with the report, and Send and Cancel close it. Phone only: the iPad's "…"
/// sits elsewhere and the sheet is the same.
final class ProblemReportUITest: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String]) throws -> XCUIApplication {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "the phone's bar")
        let app = XCUIApplication()
        app.launchArguments = ["--disable-icloud", "--no-space-sync", "--ui-audit", "-onboardingCompleted", "YES",
                               "-finishSetupDismissed", "YES", "-planMode", "day"] + extra
        app.withoutSpaceSync()
        app.launch()
        return app
    }

    /// `TEST_RUNNER_REPORT_SHOTS=<folder>` keeps a picture of the sheet.
    private func shot(_ name: String) {
        guard let path = ProcessInfo.processInfo.environment["REPORT_SHOTS"] else { return }
        let folder = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: folder.appendingPathComponent("\(name).png"))
    }

    func testPlanMoreOpensTheSheetAndSendCloses() throws {
        let app = try launch(["--tab", "plan"])
        XCTAssertTrue(app.descendants(matching: .any)["plan.today"].firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        let more = app.buttons.matching(NSPredicate(format: "label == 'More'")).firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5), "Plan has no \u{2026}")
        more.tap()
        let item = app.buttons["report.problem"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 4), "\u{2026} has no Report a Problem: \(app.debugDescription)")
        item.tap()

        let note = app.descendants(matching: .any)["report.note"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 6), "the sheet didn't open: \(app.debugDescription)")
        XCTAssertTrue(app.switches["report.screenshot"].exists, "the screenshot isn't offered")
        XCTAssertTrue(app.staticTexts["Log"].exists, "the log isn't named")
        XCTAssertTrue(app.staticTexts["Days shown"].exists, "the calendar's context isn't named")
        note.tap()
        note.typeText("The day starts an hour late")
        shot("plan-sheet")
        app.buttons["report.send"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !note.exists }, "Send didn't close the sheet")
        XCTAssertTrue(app.staticTexts["Report sent"].waitForExistence(timeout: 4), "no confirmation")
    }

    /// The mail reader's "…": the sheet offers the email, on in the Beta, off in Stable.
    func testTheMailReaderOffersTheEmail() throws {
        let app = try launch(["--ui-preview", "--dummy-health", "--modules", "everything", "--tab", "mail", "--mail-fresh"])
        let row = app.collectionViews.cells.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), app.debugDescription)
        row.tap()
        let more = app.buttons["mail.reader.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 6), "the reader's \u{2026}")
        more.tap()
        let item = app.buttons["report.problem"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 4), "\u{2026} has no Report a Problem: \(app.debugDescription)")
        item.tap()
        let email = app.switches["report.page"]
        XCTAssertTrue(email.waitForExistence(timeout: 6), "the email isn't offered: \(app.debugDescription)")
        XCTAssertTrue(app.switches["report.screenshot"].exists)
        shot("mail-sheet")
        app.buttons["report.cancel"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !email.exists }, "Cancel didn't close the sheet")
    }

    func testTheLaunchRouteOpensTheSheetAndCancelCloses() throws {
        let app = try launch(["--tab", "plan", "--report-problem"])
        let note = app.descendants(matching: .any)["report.note"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 20), "the sheet didn't open: \(app.debugDescription)")
        app.buttons["report.cancel"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !note.exists }, "Cancel didn't close the sheet")
    }
}
