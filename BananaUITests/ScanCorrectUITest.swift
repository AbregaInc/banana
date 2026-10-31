import XCTest

/// Correcting a meal with a package (`ScanCorrectionSheet`), driven for real but without a camera:
/// `--scan-correct-preview` opens a meal whose estimate said "Gnocchi", with Trader Joe's Pumpkin
/// Gnocchi already one of your foods (`MyFoodsStore.injectPreview`) — what a barcode or label
/// scan leaves behind. Picking it goes down the same path a scan does.
final class ScanCorrectUITest: XCTestCase {
    override func setUp() {
        super.setUp()
        // These correction forms use the upright phone layout; rotation has its own tests.
        if UIDevice.current.userInterfaceIdiom == .phone { XCUIDevice.shared.orientation = .portrait }
    }

    private func launch(_ routes: String...) -> XCUIApplication {
        let app = XCUIApplication()
        // `--disable-icloud`: an unsigned Simulator app reaching CloudKit is how these go flaky.
        app.launchArguments = (routes.isEmpty ? ["--scan-correct-preview"] : routes)
            + ["--disable-icloud", "--no-space-sync", "--ui-audit", "-onboardingCompleted", "YES"]
        app.withoutSpaceSync()
        app.launch()
        return app
    }

    /// A Form is lazy: a row scrolled past is absent, not just off screen. Scroll until it's there.
    @discardableResult
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, up: Bool = false) -> XCUIElement {
        var swipes = 0
        while !(element.exists && element.isHittable), swipes < 8 {
            if up { app.swipeDown() } else { app.swipeUp() }
            swipes += 1
        }
        return element
    }

    /// The open editor of one item, among however many are open.
    private func editor(of name: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "foodText.editor")
            .matching(NSPredicate(format: "label == %@", name)).firstMatch
    }

    private func scanTheGnocchi(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["Gnocchi"].waitForExistence(timeout: 10))
        reveal(app.buttons["foodText.scan"], in: app).tap()
        let mine = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "scan.myFood", "Trader Joe's Pumpkin Gnocchi")).firstMatch
        XCTAssertTrue(mine.waitForExistence(timeout: 5), "your foods are a tap away when correcting a meal")
        mine.tap()
    }

    func testAScanReplacesTheItemItIsTheAmountStepsAndUndoPutsItBack() {
        let app = launch()
        scanTheGnocchi(app)

        // Replaced in place without asking which item: of gnocchi, side salad and parmesan, only
        // one is gnocchi.
        let replaced = app.staticTexts["Trader Joe's Pumpkin Gnocchi"]
        XCTAssertTrue(replaced.waitForExistence(timeout: 5), "the editor scrolls to the row it changed")
        XCTAssertFalse(app.staticTexts["Gnocchi"].exists)
        XCTAssertFalse(app.buttons["scan.choose"].exists, "a clear item isn't asked about")

        // Exercise Undo while its offer is live, then scan again for the amount controls.
        let undo = app.buttons.matching(identifier: "toast.undo").allElementsBoundByIndex.first { $0.isHittable }
            ?? app.buttons["toast.undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 3))
        undo.tap()
        XCTAssertTrue(reveal(app.staticTexts["Gnocchi"], in: app, up: true).waitForExistence(timeout: 3))
        XCTAssertFalse(replaced.exists)
        // Undo also dismisses this correction editor. Reopen the deterministic fixture.
        app.terminate()
        app.launch()
        scanTheGnocchi(app)
        XCTAssertTrue(replaced.waitForExistence(timeout: 5))

        // The estimate's 180 g, in the same amount control as every other food: a step at a
        // tap, any number typed, and its own cup and package among the measures.
        let editor = self.editor(of: "Trader Joe's Pumpkin Gnocchi", in: app)
        let amount = editor.staticTexts["foodText.servingText"]
        XCTAssertTrue(amount.waitForExistence(timeout: 3))
        XCTAssertEqual(amount.label, "180 g")
        editor.buttons["foodAmount.stepper-Increment"].tap()
        XCTAssertEqual(amount.label, "190 g")
        let count = editor.textFields["foodAmount.count"]
        count.tap()
        // Selected on a tap, so the number typed replaces the one there.
        count.typeText("140")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertEqual(amount.label, "140 g", "what you typed, in place of what was there")


    }

    /// A package that says no serving (a pack of seaweed): the amount is asked for, not guessed
    /// at a whole pack, and the meal can't be saved at nothing.
    func testAFoodWhosePackageSaysNoServingAsksHowMuch() {
        let app = XCUIApplication()
        app.launchArguments = ["--wellness", "--meal-amount-scanned", "--disable-icloud", "--no-space-sync", "-onboardingCompleted", "YES"]
        app.withoutSpaceSync()
        app.launch()
        let editor = self.editor(of: "Sushi Nori Roasted Seaweed", in: app)
        XCTAssertTrue(editor.staticTexts["foodText.needsAmount"].waitForExistence(timeout: 10), app.debugDescription)
        let save = app.navigationBars["Edit meal"].buttons["Save"]
        XCTAssertFalse(save.isEnabled, "nothing says how much yet")

        let count = editor.textFields["foodAmount.count"]
        count.tap()
        count.typeText("5")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertEqual(editor.staticTexts["foodText.servingText"].label, "5 g")
        XCTAssertFalse(editor.staticTexts["foodText.needsAmount"].exists)
        XCTAssertTrue(save.isEnabled)
        app.navigationBars["Edit meal"].buttons["Cancel"].tap()   // nothing logged by a test
    }

    /// Screens of the flow, kept with the result for review.
    func testCaptureTheFlow() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Gnocchi"].waitForExistence(timeout: 10))
        keep(app, "1-estimate")
        reveal(app.buttons["foodText.scan"], in: app).tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "scan.myFood", "Trader Joe's Pumpkin Gnocchi")).firstMatch.waitForExistence(timeout: 5))
        keep(app, "2-scan-sheet")
        app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "scan.myFood", "Trader Joe's Pumpkin Gnocchi")).firstMatch.tap()
        let editor = self.editor(of: "Trader Joe's Pumpkin Gnocchi", in: app)
        XCTAssertTrue(editor.staticTexts["foodText.servingText"].waitForExistence(timeout: 5))
        keep(app, "3-replaced-with-undo")
        editor.buttons["foodAmount.stepper-Increment"].tap()
        keep(app, "4-a-step-more")
    }

    /// Your foods, most had first; a delete is undone from the toast.
    func testMyFoodsListsWhatYouScannedAndADeleteUndoes() {
        let app = launch("--my-foods")
        // The gnocchi's own row: other tests leave groceries among the Simulator's foods, so "the
        // first row" is still there after this one is deleted.
        let row = app.descendants(matching: .any).matching(identifier: "myFoods.row")
            .matching(NSPredicate(format: "label CONTAINS %@", "Trader Joe's Pumpkin Gnocchi")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.label.contains("1 cup \u{00B7} 140 g"), row.label)
        XCTAssertTrue(row.label.contains("210"), row.label)
        keep(app, "5-my-foods")
        row.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(app.buttons["toast.undo"].firstMatch.waitForExistence(timeout: 3))
        usleep(500_000)   // sliding up
        // On an iPad the page under the sheet shows the toast too; the finger's is the sheet's.
        let undo = app.buttons.matching(identifier: "toast.undo").allElementsBoundByIndex.first { $0.isHittable }
            ?? app.buttons["toast.undo"].firstMatch
        XCTAssertFalse(row.exists)
        undo.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 3), "Undo brings the food back")
    }

    /// A label just read: every number on it shown and yours to correct, then named and saved.
    func testALabelReadShowsEveryNumberToCorrect() {
        let app = launch("--my-foods", "--label-read")
        let save = app.buttons["scan.saveLabel"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        for value in ["5.5", "2/3 cup", "80", "60", "0", "11", "4"] {
            XCTAssertTrue(app.textFields.matching(NSPredicate(format: "value == %@", value)).firstMatch.exists,
                          "\(value) is on the panel\n\(app.debugDescription)")
        }
        XCTAssertFalse(app.descendants(matching: .any)["scan.labelOff"].exists, "60 kcal adds up")
        keep(app, "label-read")
        // Named, it can be saved. (Not saved here: a food saved under a preview stays among the
        // Simulator's foods for every later test.)
        let name = app.textFields["scan.labelName"]
        name.tap()
        name.typeText("Petite Peas")
        XCTAssertTrue(save.isEnabled)
    }

    /// Calories with nothing behind them: said, not saved quietly as zeros.
    func testALabelWhoseMacrosWerentReadSaysSo() {
        let app = launch("--my-foods", "--label-read-missed")
        XCTAssertTrue(app.buttons["scan.saveLabel"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["scan.labelOff"].exists)
    }

    private func keep(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
