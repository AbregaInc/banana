import XCTest

/// Photographs every state of the Pi workspace for the design climb (tools/design-climb).
/// `TEST_RUNNER_DESIGN_SHOTS=<folder>` names where the pictures go, as `<device>-<name>.png`.
/// Uses the fixture model, so every run shows the same states with the same words.
///
/// A camera, not a check: a state it can't reach is recorded and the walk goes on. It does
/// fail at the end, naming each state it missed, so a capture never silently shows the wrong screen.
final class PiDesignTourUITest: XCTestCase {
    private let folder = ProcessInfo.processInfo.environment["DESIGN_SHOTS"].map { URL(fileURLWithPath: $0) }
    private var missed: [String] = []
    private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "pad" : "phone" }

    override func setUpWithError() throws {
        continueAfterFailure = true
        try XCTSkipIf(folder == nil, "set TEST_RUNNER_DESIGN_SHOTS to a folder to photograph the Pi workspace")
    }

    override func tearDown() {
        XCTAssertTrue(missed.isEmpty, "not reached: \(missed.joined(separator: ", "))")
    }

    // MARK: - Walks

    func testAdd() {
        let app = launch()
        keep("01-plan", app)
        guard openAdd(app) else { return }
        keep("02-add-sheet", app)
        let input = element(app, "agent.input")
        guard input.waitForExistence(timeout: 10) else { missed.append("agent input"); return }
        input.tap(); input.typeText("Lunch with Sam at noon tomorrow")
        keep("03-add-typing", app)
    }

    func testMeal() {
        let app = launch()
        guard openAdd(app) else { return }
        send("Make a meal with 2 eggs and 1 banana", in: app)
        guard wait(app, "foodText.mealName", step: "meal draft") else { return }
        keep("04-meal-draft", app)
        let save = app.buttons["assistant.workspace.saveMeal"]
        guard save.waitForExistence(timeout: 10) else { missed.append("approve button"); return }
        if !save.isHittable { app.swipeUp() }
        keep("05-meal-draft-lower", app)
        save.tap()
        if app.buttons["toast.undo"].waitForExistence(timeout: 10) { keep("06-meal-saved", app) }
        else { missed.append("meal saved on its page") }
    }

    func testEvent() {
        let app = launch()
        guard openAdd(app) else { return }
        send("Create Pi UI Lunch tomorrow at 13:00 for 30 minutes", in: app)
        guard wait(app, "event.title", step: "event draft") else { return }
        keep("07-event-draft", app)
    }

    func testAsk() {
        let app = launch()
        guard tap(app, "page.review", step: "review") else { return }
        guard wait(app, "agent.input", step: "ask row") else { return }
        keep("08-review", app)
        send("Show my protein this month", in: app)
        guard wait(app, "assistant.nutrition.chart", timeout: 20, step: "nutrition answer") else { return }
        keep("09-answer-nutrition", app)
    }

    func testSearch() {
        let app = launch()
        guard tap(app, "page.review", step: "review") else { return }
        send("Search Banana for yogurt", in: app)
        let result = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "assistant.workspace.result.")).firstMatch
        if !result.waitForExistence(timeout: 15) { missed.append("search answer"); return }
        keep("10-answer-search", app)
        result.tap()
        guard wait(app, "assistant.workspace.searchDetail", step: "search detail") else { return }
        keep("11-answer-search-detail", app)
        app.navigationBars.buttons.element(boundBy: 0).tap()   // Back to Review
        if wait(app, "agent.input", step: "back to review") { keep("14-review-recent", app) }
    }

    func testWorking() {
        let app = launch()
        guard tap(app, "page.review", step: "review") else { return }
        send("Wait", in: app)
        guard wait(app, "agent.stop", step: "working state") else { return }
        keep("12-working", app)
        app.buttons["agent.stop"].tap()
    }

    func testPages() {
        let app = launch()
        if tap(app, label: "Notes", step: "notes tab") { keep("13-notes", app) }
    }

    // MARK: - Helpers

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--assistant-test-navigation", "--assistant-reset", "--design-capture",
                               "--disable-icloud", "-onboardingCompleted", "YES"]
        app.launch()
        if !app.buttons["Add"].firstMatch.waitForExistence(timeout: 25) { missed.append("fixed app") }
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func wait(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 15, step: String) -> Bool {
        if element(app, id).waitForExistence(timeout: timeout) { return true }
        missed.append(step); return false
    }

    @discardableResult
    private func tap(_ app: XCUIApplication, _ id: String? = nil, label: String? = nil, step: String) -> Bool {
        let target = id.map { element(app, $0) } ?? app.buttons[label ?? ""].firstMatch
        guard target.waitForExistence(timeout: 10) else { missed.append(step); return false }
        target.tap(); return true
    }

    /// The + sheet, on every device.
    private func openAdd(_ app: XCUIApplication) -> Bool {
        tap(app, label: "Add", step: "add button")
    }

    private func send(_ text: String, in app: XCUIApplication) {
        let input = element(app, "agent.input")
        guard input.waitForExistence(timeout: 10) else { missed.append("input for \(text)"); return }
        input.tap(); input.typeText(text)
        let button = app.buttons["agent.send"]
        guard waitUntil(timeout: 15, { button.isEnabled }) else { missed.append("send for \(text)"); return }
        button.tap()
    }

    private func keep(_ name: String, _ app: XCUIApplication) {
        // Let animations and lazy layout settle on the screen being photographed.
        _ = waitUntil(timeout: 3) { app.state == .runningForeground }
        usleep(700_000)
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        guard let folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: folder.appendingPathComponent("\(device)-\(name).png"))
    }
}
