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

    /// `keepsRailState`: launch with the rail as it was left; otherwise it is shown, whatever an
    /// earlier run left (`ShellRailVisibility`).
    private func launch(_ extra: [String], keepsRailState: Bool = false) throws -> XCUIApplication {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad, "the rail is the iPad's (and the Mac's)")
        let app = XCUIApplication()
        app.launchArguments += ["--ui-preview", "--ui-audit", "--disable-icloud", "--dummy-health", "--store-capture",
                                "-finishSetupDismissed", "YES", "-onboardingCompleted", "YES", "--modules", "everything"]
            + (keepsRailState ? [] : ["-shellRailShown", "YES"]) + extra
        app.withoutSpaceSync()
        app.launch()
        let rail = app.descendants(matching: .any)["shell.rail"], switcher = app.buttons["shell.switcher"]
        let toggle = app.buttons["shell.railToggle"]
        XCTAssertTrue(waitUntil(timeout: 30) { rail.exists || switcher.exists || toggle.exists }, app.debugDescription)
        return app
    }

    private func shot(_ name: String) {
        guard let folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: folder.appendingPathComponent("\(name).png"))
    }

    func testSkipNoticeAndUndoClearTheWidePlayer() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = try launch(["--tab", "plan", "--plan", "--sample-episode", "--skip-notice-preview", "--toast-preview"])
        let notice = app.descendants(matching: .any)["adSkip.notice"].firstMatch
        let footer = app.descendants(matching: .any)["shell.playbackFooter"].firstMatch
        let toast = app.descendants(matching: .any)["toast"].firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(footer.exists)
        shot("wide-skip-notice")
        XCTAssertTrue(waitUntil { notice.frame.maxY < footer.frame.minY }, "skip covers player")
        XCTAssertTrue(waitUntil { toast.frame.maxY < notice.frame.minY }, "Undo covers skip notice")
        XCTAssertTrue(app.buttons["adSkip.undo"].isHittable)
    }

    func testTheBarUprightAndTheRailOnItsSide() throws {
        XCUIDevice.shared.orientation = .portrait
        // `--plan` loads the sample plan, so the week has its events and the weather to compare.
        let app = try launch(["--tab", "plan", "--plan", "-planMode", "week"])
        // Upright: the phone's layout, with the plan's title row at the top and the bar below.
        XCTAssertTrue(app.buttons["shell.switcher"].waitForExistence(timeout: 10), "the bar at the bottom upright")
        XCTAssertFalse(app.descendants(matching: .any)["shell.rail"].exists, "no rail upright")
        let title = app.descendants(matching: .any)["plan.mode"].firstMatch
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

    /// Badges: upright the switcher adds the pages' counts up; on its side each rail circle has
    /// its own, Plan's from the overdue reminders.
    func testBadgesOnTheSwitcherUprightAndTheRailOnItsSide() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = try launch(["--tab", "plan", "--plan", "--outstanding-reminders", "--mail-fresh"])
        let switcher = app.buttons["shell.switcher"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 15))
        XCTAssertTrue(waitUntil(timeout: 10) { switcher.label.contains("need") }, switcher.label)
        XCUIDevice.shared.orientation = .landscapeLeft
        let plan = app.buttons["shell.page.plan"]
        XCTAssertTrue(app.descendants(matching: .any)["shell.rail"].waitForExistence(timeout: 8))
        XCTAssertTrue(waitUntil(timeout: 5) { (plan.value as? String)?.contains("need") == true }, "\(plan.value ?? "")")
        XCTAssertEqual(app.buttons["shell.page.settings"].value as? String ?? "", "")
        let mail = app.buttons["shell.page.mail"]
        XCTAssertTrue(waitUntil(timeout: 5) { (mail.value as? String)?.contains("need") == true },
                      "Mail's rail circle carries the Inbox's unread")
        let unread = Int((mail.value as? String ?? "").split(separator: " ").first ?? "") ?? 0
        // The sample Inbox holds 40 conversations (its title's number); the badge is fewer.
        XCTAssertLessThan(unread, 40, "unread, not the title's every conversation")
        shot("pad-land-rail-badge")
    }

    /// Paging: the same rule upright (the top row) and on its side (the toolbar): "‹", the period
    /// picker, "›", and Today only away from the current period. One of each upright too.
    func testPagingUprightAndOnItsSide() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = try launch(["--tab", "plan", "--plan", "-planMode", "week"])
        let title = app.descendants(matching: .any)["plan.mode"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["shell.switcher"].waitForExistence(timeout: 10))
        let start = title.value as? String
        let previous = app.buttons["plan.previous"], next = app.buttons["plan.next"], today = app.buttons["plan.today"]
        XCTAssertTrue(previous.exists && next.exists)
        XCTAssertFalse(today.exists, "no Today on this week")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "plan.mode").count, 1, "one period picker")
        XCTAssertFalse(app.descendants(matching: .any)["plan.title"].exists, "no title menu beside it")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == 'Previous week'")).count, 1)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == 'Next week'")).count, 1)
        XCTAssertLessThanOrEqual(previous.frame.maxX, title.frame.minX + 1)
        XCTAssertLessThanOrEqual(title.frame.maxX, next.frame.minX + 1)
        XCTAssertEqual(title.value as? String ?? "", start ?? "")
        XCTAssertTrue((title.value as? String)?.contains("\u{2013}") == true, "the week's dates: \(title.value ?? "")")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show all'")).firstMatch.exists,
                       "no list icon beside the day numbers")
        shot("pad-portrait-plan-week")
        next.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { today.exists && (title.value as? String) != start })
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == 'Today' OR label BEGINSWITH 'Return to'")).count, 1)
        XCTAssertLessThanOrEqual(next.frame.maxX, today.frame.minX + 1)
        shot("pad-portrait-plan-next")
        today.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { (title.value as? String) == start && !today.exists && title.label.hasPrefix("Week") })

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.descendants(matching: .any)["shell.rail"].waitForExistence(timeout: 8))

        XCTAssertTrue(next.waitForExistence(timeout: 5) && app.buttons["plan.previous"].exists, "back and forward on its side")
        XCTAssertEqual(next.label, "Next week")
        XCTAssertFalse(today.exists, "no Today on this week")
        next.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { today.exists })
        today.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !today.exists })
    }

    /// On its side Plan's toolbar is the Mac's three groups (HIG, Toolbars): "‹", Today away from
    /// the current period, "›"; then the period picker and the forecast; then the field and "…".
    /// No second pair of arrows, no second Today, and no row under the toolbar naming the period
    /// again. "‹ ›" step a week in Week and a day in Day.
    /// The rail hides and shows like a system sidebar, from its button at the toolbar's leading
    /// edge, and stays hidden across a relaunch.
    func testTheRailHidesLikeASidebarAndStaysHidden() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        var app = try launch(["--tab", "plan", "--plan"], keepsRailState: true)
        let rail = app.descendants(matching: .any)["shell.rail"]
        let toggle = app.buttons["shell.railToggle"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "no sidebar button")
        // Start from a shown rail, whatever an earlier run left.
        if !rail.waitForExistence(timeout: 3) { toggle.tap() }
        XCTAssertTrue(rail.waitForExistence(timeout: 5))
        XCTAssertLessThan(toggle.frame.minX, app.buttons["plan.previous"].frame.minX, "the sidebar button leads the toolbar")
        toggle.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !rail.exists }, "the rail didn't hide")
        shot("pad-land-rail-hidden")
        app.terminate()
        app = try launch(["--tab", "plan", "--plan"], keepsRailState: true)
        XCTAssertTrue(app.buttons["shell.railToggle"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["shell.rail"].exists, "hidden is kept")
        app.buttons["shell.railToggle"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["shell.rail"].waitForExistence(timeout: 5), "the rail didn't come back")
    }

    func testOnItsSidePlanPagesFromOneToolbarGroup() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        // No `-planMode`: a launch argument pins the setting, and the picker has to change it.
        let app = try launch(["--tab", "plan", "--plan"])
        XCTAssertTrue(app.descendants(matching: .any)["shell.rail"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["plan.surface.day"].waitForExistence(timeout: 10))
        shot("pad-land-plan-day")
        try checkOneGroup(app, week: false)

        app.descendants(matching: .any)["plan.mode"].firstMatch.tap()
        let week = app.buttons["Week"].firstMatch
        XCTAssertTrue(week.waitForExistence(timeout: 5), app.debugDescription)
        week.tap()
        XCTAssertTrue(app.descendants(matching: .any)["plan.surface.week"].waitForExistence(timeout: 8))
        shot("pad-land-plan-week")
        try checkOneGroup(app, week: true)
    }

    private func checkOneGroup(_ app: XCUIApplication, week: Bool) throws {
        let unit = week ? "week" : "day"
        func count(_ predicate: String) -> Int {
            app.descendants(matching: .any).matching(NSPredicate(format: predicate)).count
        }
        let previous = app.buttons["plan.previous"], next = app.buttons["plan.next"], today = app.buttons["plan.today"]
        let period = app.descendants(matching: .any)["plan.mode"].firstMatch
        XCTAssertTrue(period.waitForExistence(timeout: 5), "the period picker")
        // One of each, counting the date line's unnamed ones too.
        XCTAssertEqual(count("identifier == 'plan.mode'"), 1, "one period picker")
        XCTAssertEqual(app.segmentedControls.count, 0, "no Day · Week switch")
        XCTAssertFalse(app.descendants(matching: .any)["plan.title"].exists, "no title menu beside the picker")
        XCTAssertFalse(app.descendants(matching: .any)["mobile.day.title"].exists, "no date line under the toolbar")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "Previous \(unit)")).count, 1, "one \u{2039}")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "Next \(unit)")).count, 1, "one \u{203A}")
        // In the order the Mac has: ‹ › then the picker, on one line; no Today on the current one.
        XCTAssertTrue(previous.exists && next.exists)
        XCTAssertFalse(today.exists, "no Today on the current \(unit)")
        XCTAssertLessThanOrEqual(previous.frame.maxX, next.frame.minX + 1)
        XCTAssertLessThanOrEqual(next.frame.maxX, period.frame.minX + 1)
        for control in [period, next] {
            XCTAssertEqual(control.frame.midY, previous.frame.midY, accuracy: 12, "on the toolbar's line")
        }

        // "›" steps one period and Today comes back to it; still one Today away from now.
        let key = { (days: Int) -> String in
            let date = Calendar.current.date(byAdding: .day, value: days, to: Date())!
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
            return f.string(from: date)
        }
        // Week: the day headers carry their dates. Day has none: the picker names the day.
        func shows(_ offset: Int) -> Bool {
            if week {
                return app.descendants(matching: .any).matching(NSPredicate(
                    format: "identifier BEGINSWITH 'calendar.day.' AND identifier ENDSWITH %@", key(offset))).count > 0
            }
            let date = Calendar.current.date(byAdding: .day, value: offset, to: Date())!
            return period.value as? String == date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        }
        let step = week ? 7 : 1
        XCTAssertTrue(waitUntil(timeout: 5) { shows(0) }, "today on screen to start")
        let start = period.value as? String
        next.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { shows(step) && !shows(0) }, "\u{203A} steps one \(unit)")
        XCTAssertTrue(waitUntil(timeout: 5) { today.exists })
        XCTAssertNotEqual(period.value as? String, start, "the picker names the dates on screen")
        XCTAssertEqual(count("label == 'Today' OR label BEGINSWITH 'Return to'"), 1, "one Today away from now")
        // ‹ Today › in one group.
        XCTAssertLessThanOrEqual(previous.frame.maxX, today.frame.minX + 1)
        XCTAssertLessThanOrEqual(today.frame.maxX, next.frame.minX + 1)
        previous.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { shows(0) && !today.exists }, "\u{2039} steps back")
        previous.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { shows(-step) && !shows(0) })
        today.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { shows(0) && !today.exists }, "Today returns")
        XCTAssertEqual(period.value as? String, start)
    }

    /// Details: on its side the column beside the reader ("…" › Details toggles it, a tap on the
    /// sender opens it); upright a sheet, as on a phone (`MailArrangement.detailsPlacement`).
    func testDetailsAreAColumnOnItsSideAndASheetUpright() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = try launch(["--tab", "mail", "--mail-fresh", "-mailShowsDetails", "NO"])
        let column = app.descendants(matching: .any)["mail.details"]
        let sender = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'mail.sender.'")).firstMatch
        XCTAssertTrue(sender.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(column.exists, "closed to start")
        app.buttons["mail.more"].tap()
        tapDetailsItem(app)
        XCTAssertTrue(column.waitForExistence(timeout: 5), "\u{2026} \u{203A} Details opens the column")
        shot("pad-land-details")
        app.buttons["mail.more"].tap()
        tapDetailsItem(app)
        XCTAssertTrue(column.waitForNonExistence(timeout: 5), "and closes it")
        sender.tap()
        XCTAssertTrue(column.waitForExistence(timeout: 5), "a tap on the sender opens it")

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["shell.switcher"].waitForExistence(timeout: 8))
        XCTAssertFalse(column.exists, "upright, no column")
        app.buttons["mail.pane.more"].firstMatch.tap()
        tapDetailsItem(app)
        let sheet = app.buttons["mail.details.close"].firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "upright, a sheet")
        shot("pad-portrait-details")
        sheet.tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        sender.tap()
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "the sender opens the sheet upright")
    }

    /// "Details" in an open "…" menu (a toolbar's menu on the iPad drops its items' identifiers).
    private func tapDetailsItem(_ app: XCUIApplication) {
        let item = app.buttons.matching(NSPredicate(format: "identifier == 'mail.more.details' OR label == 'Details'")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "\u{2026} \u{203A} Details: \(app.debugDescription)")
        item.tap()
    }

    func testMailHasItsPlaceMenuTheFieldAndMoreInOneRow() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = try launch(["--tab", "mail", "--mail-fresh", "-mailShowsDetails", "NO"])
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
