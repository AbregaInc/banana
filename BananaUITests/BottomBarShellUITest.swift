import XCTest

/// The phone's one navigation layer (docs/design/BOTTOM-BAR-SHELL.md): the page switcher, the
/// "Search or ask" field and its results, the podcast player above the bar, and Mail's reader.
/// Compact width only; an iPad full screen has the rail.
final class BottomBarShellUITest: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = []) throws -> XCUIApplication {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "the iPad has the rail")
        let app = XCUIApplication()
        app.launchArguments += ["--ui-preview", "--ui-audit", "--disable-icloud", "--dummy-health",
                                "-finishSetupDismissed", "YES", "-onboardingCompleted", "YES", "--modules", "everything"] + extra
        app.withoutSpaceSync()
        app.launch()
        XCTAssertTrue(app.buttons["shell.switcher"].waitForExistence(timeout: 30), app.debugDescription)
        return app
    }

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// `TEST_RUNNER_SHELL_SHOTS=<folder>` keeps a picture for the compare page.
    private func shot(_ name: String) {
        guard let path = ProcessInfo.processInfo.environment["SHELL_SHOTS"] else { return }
        let folder = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: folder.appendingPathComponent("\(name).png"))
    }

    // MARK: Details

    /// "…" › Details and a tap on a sender open the conversation's Details as a sheet on a phone
    /// (`MailArrangement.detailsPlacement`), half height, with Done.
    func testDetailsOpenAsASheetFromMoreAndFromTheSender() throws {
        let app = try launch(["--tab", "mail", "--mail-fresh"])
        let row = app.collectionViews.cells.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), app.debugDescription)
        row.tap()
        let more = app.buttons["mail.reader.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5), "the reader's \u{2026}")
        more.tap()
        let item = app.buttons["mail.more.details"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "\u{2026} \u{203A} Details: \(app.debugDescription)")
        item.tap()
        let close = app.buttons["mail.details.close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5), "the sheet: \(app.debugDescription)")
        let people = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH[c] 'People'")).firstMatch
        XCTAssertTrue(people.waitForExistence(timeout: 5), "the details: \(app.debugDescription)")
        XCTAssertGreaterThan(people.frame.minY, app.windows.firstMatch.frame.height * 0.3, "it opens at half height")
        shot("phone-details")
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5), "Done closes it")

        let sender = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'mail.sender.'")).firstMatch
        XCTAssertTrue(sender.waitForExistence(timeout: 5), "the sender is a button: \(app.debugDescription)")
        sender.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5), "a tap on the sender opens Details too")
    }

    // MARK: Switcher

    func testTheSwitcherOpensUpwardsClosesAndOpensEachPage() throws {
        let app = try launch(["--tab", "plan"])
        XCTAssertFalse(app.tabBars.firstMatch.exists, "the tab bar is gone")
        XCTAssertFalse(app.buttons["page.review"].exists, "Review moved into the switcher")

        let switcher = app.buttons["shell.switcher"]
        switcher.tap()
        let notes = app.buttons["shell.page.notes"]
        XCTAssertTrue(notes.waitForExistence(timeout: 3))
        // Rising from the button: each page sits above the switcher, Plan nearest.
        let plan = app.buttons["shell.page.plan"], settings = app.buttons["shell.page.settings"]
        XCTAssertLessThan(plan.frame.maxY, switcher.frame.minY + 1)
        XCTAssertLessThan(settings.frame.minY, plan.frame.minY, "Settings is the top of the column")
        XCTAssertTrue(plan.isSelected, "the page showing is marked")

        // The same button (now an X) closes it.
        switcher.tap()
        XCTAssertTrue(notes.waitForNonExistence(timeout: 3))

        // Tapping the dimmed page closes it too.
        switcher.tap()
        XCTAssertTrue(notes.waitForExistence(timeout: 3))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.3)).tap()
        XCTAssertTrue(notes.waitForNonExistence(timeout: 3))

        // A page opens, and its name is the top row.
        switcher.tap()
        notes.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { self.any(app, "page.title").label == "Notes" }, app.debugDescription)
        switcher.tap()
        app.buttons["shell.page.body"].tap()
        XCTAssertTrue(any(app, "body.title").waitForExistence(timeout: 5), app.debugDescription)

        // Settings and Review open over the page, as they did from "…" and the chart button.
        switcher.tap()
        app.buttons["shell.page.settings"].tap()
        let done = app.navigationBars.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5), "Settings didn't open")
        done.tap()
        switcher.tap()
        app.buttons["shell.page.review"].tap()
        XCTAssertTrue(app.navigationBars.buttons["Done"].firstMatch.waitForExistence(timeout: 5), "Review didn't open")
    }

    // MARK: Search or ask

    func testTheFieldListsWhatCanBeAddedThenWhatItFindsWithAskFirst() throws {
        let app = try launch(["--tab", "plan"])
        let field = app.textFields["shell.field"]
        field.tap()
        // Nothing typed: what can be added, this page's first.
        XCTAssertTrue(any(app, "page.add.list").waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Event"].firstMatch.waitForExistence(timeout: 3), app.debugDescription)
        // The switcher and the assistant step aside so the field is as wide as the bar.
        XCTAssertFalse(app.buttons["shell.switcher"].exists)
        XCTAssertFalse(app.buttons["shell.ai"].exists)

        field.typeText("lunch")
        let ask = app.buttons["shell.ask"]
        XCTAssertTrue(ask.waitForExistence(timeout: 3), "this Debug build has an assistant: Ask is the first row")
        XCTAssertTrue(ask.label.contains("lunch"), ask.label)
        XCTAssertTrue(any(app, "shell.calendarSearch").waitForExistence(timeout: 3))

        // Clearing puts the field away and brings the bar's buttons back.
        app.buttons["shell.field.clear"].tap()
        if app.buttons["shell.field.clear"].exists { app.buttons["shell.field.clear"].tap() }
        XCTAssertTrue(app.buttons["shell.switcher"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["shell.ai"].exists)
        XCTAssertFalse(any(app, "shell.results").exists || any(app, "page.add.list").exists)
    }

    func testAPickFromTheAddListOpensItOnItsPage() throws {
        let app = try launch(["--tab", "plan"])
        app.textFields["shell.field"].tap()
        let reminder = app.buttons["Reminder"].firstMatch
        XCTAssertTrue(reminder.waitForExistence(timeout: 3), app.debugDescription)
        reminder.tap()
        XCTAssertTrue(app.navigationBars.firstMatch.buttons["Cancel"].waitForExistence(timeout: 5)
                      || app.buttons["Cancel"].firstMatch.waitForExistence(timeout: 2),
                      "the reminder sheet didn't open")
    }

    // MARK: Player

    func testThePlayerHidesIntoTheFieldComesBackAndASwipeStopsIt() throws {
        let app = try launch(["--tab", "plan", "--sample-episode"])
        let capsule = any(app, "shell.player")
        XCTAssertTrue(capsule.waitForExistence(timeout: 10), app.debugDescription)
        // Directly above the bar.
        XCTAssertLessThan(capsule.frame.maxY, app.buttons["shell.switcher"].frame.minY + 1)

        app.buttons["shell.player.hide"].tap()
        let chip = any(app, "shell.player.chip")
        XCTAssertTrue(chip.waitForExistence(timeout: 3))
        XCTAssertTrue(capsule.waitForNonExistence(timeout: 3))
        // In the left end of the field: past the switcher, before the field's words.
        XCTAssertGreaterThan(chip.frame.minX, app.buttons["shell.switcher"].frame.maxX)
        XCTAssertLessThan(chip.frame.midX, app.windows.firstMatch.frame.width * 0.4)

        chip.tap()
        XCTAssertTrue(capsule.waitForExistence(timeout: 3), "a tap brings the player back")

        app.buttons["shell.player.hide"].tap()
        XCTAssertTrue(chip.waitForExistence(timeout: 3))
        let start = chip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -140, dy: 0)))
        XCTAssertTrue(chip.waitForNonExistence(timeout: 3), "a swipe away stops playback")
        XCTAssertFalse(capsule.exists)
    }

    /// The playhead ticks once a second: only the capsule's progress line redraws, never the bar,
    /// the shell or the plan (`RenderStats`, read through the probe).
    func testThePlaybackTickRedrawsOnlyTheProgressLine() throws {
        let app = try launch(["--tab", "plan", "--sample-episode", "--shell-tick", "--perf-trace"])
        XCTAssertTrue(any(app, "shell.player").waitForExistence(timeout: 10))
        func count(_ id: String) -> Int { Int(any(app, id).value as? String ?? "") ?? -1 }
        XCTAssertTrue(waitUntil(timeout: 10) { count("shell.performance.line") > 0 }, app.debugDescription)
        // Settled after launch, then four ticks.
        _ = waitUntil(timeout: 3) { false }
        let bar = count("shell.performance.bar"), root = count("shell.performance.root")
        let plan = count("day.performance.renderCount"), line = count("shell.performance.line")
        _ = waitUntil(timeout: 4.5) { false }
        XCTAssertGreaterThanOrEqual(count("shell.performance.line") - line, 3, "the line follows the playhead")
        XCTAssertEqual(count("shell.performance.bar"), bar, "the bar redrew on a tick")
        XCTAssertEqual(count("shell.performance.root"), root, "the shell redrew on a tick")
        XCTAssertEqual(count("day.performance.renderCount"), plan, "the plan redrew on a tick")
    }

    // MARK: Mail

    func testTheMailReaderHasBackMoreReplyAndArchive() throws {
        let app = try launch(["--tab", "mail", "--mail-fresh"])
        let row = app.collectionViews.cells.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), app.debugDescription)
        // No search row of Mail's own: the field searches.
        XCTAssertFalse(app.textFields["Search"].exists && app.textFields["Search"].frame.minY < 200)
        row.tap()
        let more = app.buttons["mail.reader.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(any(app, "mail.conversation.back").exists)
        XCTAssertTrue(app.buttons["shell.reply"].exists, "the field reads Reply or ask in a conversation")
        XCTAssertTrue(app.buttons["shell.archive"].exists, "Archive sits beside the field")

        more.tap()
        XCTAssertTrue(app.buttons["Star"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Mark unread"].exists)
        XCTAssertTrue(app.buttons["Older"].exists)
        app.buttons["Star"].tap()

        app.buttons["shell.reply"].tap()
        XCTAssertTrue(any(app, "mail.composer.body").waitForExistence(timeout: 5)
                      || app.textViews.firstMatch.waitForExistence(timeout: 3), "Reply opened no composer")
        app.swipeDown(velocity: .fast)

        XCTAssertTrue(app.buttons["shell.archive"].waitForExistence(timeout: 5))
        let title = any(app, "mail.conversation.title")
        let subject = title.label
        app.buttons["shell.archive"].tap()
        // Archived: the reader goes on to the next conversation, or back to the list.
        XCTAssertTrue(waitUntil(timeout: 5) { !title.exists || title.label != subject },
                      "Archive didn't take \(subject) away")
    }
}
