import XCTest

/// The screens only a tap reaches, photographed for the screen atlas (tools/atlas): each tab's +
/// and "…" menus, the weather sheet, Settings and its pages, the Set up list and an explainer,
/// Routines' template list and editor, the Repeat picker, and a delete's Undo toast.
/// `TEST_RUNNER_ATLAS_SHOTS=<folder>` names where the pictures go, as `<area>/<name>.png`; the
/// rest of the atlas comes from launch arguments (tools/atlas/capture.py).
///
/// A screen that can't be reached is recorded and skipped, never a stop: the walk is a camera,
/// not a check. What it does check is that every step it names was reached.
final class ScreenAtlasUITest: XCTestCase {
    private let folder = ProcessInfo.processInfo.environment["ATLAS_SHOTS"].map { URL(fileURLWithPath: $0) }
    private var missed: [String] = []

    override func setUpWithError() throws {
        continueAfterFailure = true
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "the phone's tabs and sheets")
        // A camera for tools/atlas, not one of the everyday checks: it runs when asked for pictures.
        try XCTSkipIf(folder == nil, "set TEST_RUNNER_ATLAS_SHOTS to a folder to photograph the atlas")
    }

    override func tearDown() {
        XCTAssertTrue(missed.isEmpty, "not reached: \(missed.joined(separator: ", "))")
    }

    // MARK: - Helpers

    private func keep(_ id: String) {
        usleep(900_000)   // a sheet or a menu still settling
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = id
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let folder else { return }
        let file = folder.appendingPathComponent("\(id).png")
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: file)
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-audit", "--disable-icloud", "--no-space-sync", "--store-capture", "-onboardingCompleted", "YES"] + arguments
        app.withoutSpaceSync()
        app.launch()
        return app
    }

    private func shell(tab: String, _ extra: [String] = []) -> XCUIApplication {
        launch(["-finishSetupDismissed", "YES", "--ui-preview", "--plan", "-planMode", "day", "--dummy-health",
                "--library", "--notes", "--wellness", "--wake-following-sample", "--tab", tab] + extra)
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Taps the element with this identifier (or, failing that, this label) once it's there.
    @discardableResult
    private func tap(_ app: XCUIApplication, _ id: String, label: String? = nil, timeout: TimeInterval = 10,
                     step: String) -> Bool {
        var target = element(app, id)
        if !target.waitForExistence(timeout: timeout), let label {
            target = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label))
                .allElementsBoundByIndex.first { $0.isHittable } ?? target
        }
        guard target.exists else { missed.append(step); return false }
        if target.isHittable { target.tap() } else { target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        return true
    }

    private func more(_ app: XCUIApplication) -> XCUIElement {
        let plan = element(app, "mobile.week.more")
        if plan.waitForExistence(timeout: 3) { return plan }
        return app.buttons.matching(NSPredicate(format: "label == 'More'")).firstMatch
    }

    /// The first note in the list, not the search field's cell above it.
    private func noteRow(_ app: XCUIApplication) -> XCUIElement {
        app.cells.containing(NSPredicate(format: "label BEGINSWITH 'The useful distinction'")).firstMatch
    }

    private func closeMenu(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.24, dy: 0.095)).tap()
        usleep(600_000)
    }

    private func dismissSheet(_ app: XCUIApplication) {
        for label in ["Done", "Close", "Cancel"] {
            let button = app.navigationBars.buttons[label].firstMatch
            if button.exists && button.isHittable { button.tap(); usleep(800_000); return }
        }
        app.swipeDown(velocity: .fast)
        usleep(800_000)
    }

    // MARK: - The walk

    func testMenus() throws {
        // Each tab's + and "…".
        let tabs: [(tab: String, area: String, plus: String)] = [
            ("plan", "plan", "mobile.week.newEvent"), ("nutrition", "food", "wellness.add"),
            ("notes", "notes", "notes.add"), ("library", "library", "library.add"),
        ]
        for (tab, area, plus) in tabs {
            let app = shell(tab: tab)
            let add = app.plus(plus)
            if add.exists { add.tap(); keep("\(area)/add-menu"); closeMenu(app) } else { missed.append("\(tab) +") }
            let menu = more(app)
            if menu.waitForExistence(timeout: 10) { menu.tap(); keep("\(area)/more-menu"); closeMenu(app) } else { missed.append("\(tab) …") }
        }

    }

    func testWeatherAndSettings() throws {
        // Plan: the weather sheet.
        do {
            let app = shell(tab: "plan")
            if tap(app, "plan.weather", step: "weather") { keep("plan/weather") }
        }

        // Settings and its pages.
        do {
            let app = shell(tab: "plan")
            more(app).tap()
            if tap(app, "page.more.settings", label: "Settings", step: "Settings") {
                keep("settings/settings")
                for page in ["Accounts & calendars", "Modules", "Calendar", "Travel", "Wake & bedtime", "Podcasts",
                             "Workouts", "Apple Watch", "iCloud", "Permissions", "About"] {
                    // The account row is labelled with the account. A row low on the page can sit
                    // under the floating search field: scroll until it's clear of it.
                    let byID = element(app, "settings.accounts")
                    func find(clearOf share: CGFloat = 0.8) -> XCUIElement? {
                        if page == "Accounts & calendars" && byID.exists { return byID }
                        return app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", page))
                            .allElementsBoundByIndex.first { $0.isHittable && $0.frame.maxY < app.frame.height * share }
                    }
                    var row = find()
                    for _ in 0..<6 where row == nil { app.swipeUp(); usleep(600_000); row = find() }
                    // The last row, scrolled as far as it goes, can sit lower than that and still be clear.
                    if row == nil { row = find(clearOf: 0.92) }
                    guard let row else { missed.append("Settings › \(page)"); continue }
                    row.tap()
                    let name = page.lowercased().replacingOccurrences(of: " & ", with: "-").replacingOccurrences(of: " ", with: "-")
                    keep("settings/settings-\(name)")
                    // Back to the list, never Done (which closes Settings).
                    let back = app.navigationBars.buttons.element(boundBy: 0)
                    if back.exists && back.label != "Done" { back.tap(); usleep(700_000) }
                }
            }
        }

    }

    func testSetupAndRoutines() throws {
        // The Set up list, on a real launch with nothing connected.
        do {
            let app = launch(["--tab", "plan", "-planMode", "day"])
            if tap(app, "plan.setup.rest", label: "Set up", timeout: 20, step: "Set up list")
                || tap(app, "plan.setup.open", step: "Set up list (line)") {
                keep("settings/setup")
                if tap(app, "setup.row.calendar", step: "Set up › Calendar") { keep("settings/setup-calendar") }
            }
        }

        // Routines: the list, a new routine's templates, the editor.
        do {
            let app = shell(tab: "library")
            more(app).tap()
            if tap(app, "page.more.routines", label: "Routines", step: "Routines") {
                keep("routines/routines-sheet")
                // "Add routine" ends the sheet's list.
                app.swipeUp(); usleep(600_000)
                if tap(app, "routines.add", label: "Add routine", step: "Routines +") {
                    keep("routines/templates")
                    dismissSheet(app)
                }
                let first = app.cells.firstMatch
                if first.waitForExistence(timeout: 5) { first.tap(); keep("routines/editor") } else { missed.append("routine editor") }
            }
        }

    }

    func testSheetsAndUndo() throws {
        // The event editor's Repeat picker.
        do {
            let app = launch(["--event-editor"])
            let repeatRow = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Repeat'"))
                .allElementsBoundByIndex.first { $0.isHittable }
            if let repeatRow { repeatRow.tap(); keep("events/repeat") } else { missed.append("Repeat") }
        }

        // A delete and its Undo: a note, swiped away.
        do {
            let app = shell(tab: "notes")
            let row = noteRow(app)
            if row.waitForExistence(timeout: 15) {
                row.swipeLeft()
                keep("notes/swipe-actions")
                if tap(app, "Delete", label: "Delete", timeout: 4, step: "note Delete") { keep("notes/undo-toast") }
            } else { missed.append("a note to delete") }
        }

        // Review › Food, with a weight trend to set the meals against.
        do {
            let app = shell(tab: "nutrition", ["--nutrition-week", "--energy-balance", "measured"])
            if tap(app, "page.review", step: "Review"), tap(app, "review.food", step: "Review › Food") {
                keep("review/energy")
            }
        }

        // A note opened, and the Body switch.
        do {
            let app = shell(tab: "notes")
            let row = noteRow(app)
            if row.waitForExistence(timeout: 15) { row.tap(); keep("notes/detail") } else { missed.append("note detail") }
        }
        do {
            let app = shell(tab: "workouts")
            if tap(app, "body.switch", step: "Body switch") { keep("workouts/body-switch") }
        }
    }
}
