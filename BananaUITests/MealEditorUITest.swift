import XCTest

/// The meal row editor and the supplement timing section, driven for real.
///
/// Both were rebuilt in one pass and both depend on interactions a compile cannot check: a row
/// that only opens on tap is worthless if the tap does not land, and a "Move it to 11:00 AM"
/// button that does not actually move anything is worse than no suggestion at all.
final class MealEditorUITest: XCTestCase {

    func testSavedMealTimeCanBeCorrectedAndSurvivesRelaunch() throws {
        let hour = Calendar.current.component(.hour, from: Date())
        let displayHour = hour % 12 == 0 ? 12 : hour % 12
        let expected = "\(displayHour):00"
        let app = launch(["--wellness", "--meal-editor-preview"])
        let picker = app.datePickers["foodText.eatenAt"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10), app.debugDescription)
        let time = picker.buttons.allElementsBoundByIndex.last!
        time.tap()
        XCTAssertTrue(app.pickerWheels.firstMatch.waitForExistence(timeout: 3), app.debugDescription)
        let wheels = app.pickerWheels
        // The start of this hour is always in the past, without crossing noon/midnight.
        if wheels.count > 2 { wheels.element(boundBy: 2).adjust(toPickerWheelValue: hour < 12 ? "AM" : "PM") }
        wheels.element(boundBy: 0).adjust(toPickerWheelValue: String(displayHour))
        wheels.element(boundBy: 1).adjust(toPickerWheelValue: "00")
        // Close the native time popover using the sheet's own heading.
        app.navigationBars["Edit meal"].tap()
        app.buttons["Save"].tap()
        let meal = app.buttons.matching(NSPredicate(format: "identifier == 'nutrition.meal' AND label CONTAINS %@", expected)).firstMatch
        // Pending photo estimates can put the saved meal below the lazy list viewport.
        XCTAssertTrue(scrolledTo(meal, in: app), app.debugDescription)
        app.terminate()
        // The isolated --wellness route reseeds its sample on every launch. Reopen the actual
        // nutrition page without that fixture, so this checks the persisted correction.
        let reopened = launch(["--ui-preview", "--tab", "nutrition", "--modules", "food"])
        let saved = reopened.buttons.matching(NSPredicate(format: "identifier == 'nutrition.meal' AND label CONTAINS %@", expected)).firstMatch
        XCTAssertTrue(scrolledTo(saved, in: reopened), reopened.debugDescription)
    }

    /// A `List` is lazy, so a row below the fold is genuinely absent from the hierarchy rather
    /// than merely off-screen — `exists` is false and no timeout will save you. Scroll until it
    /// materialises. (Times carry a narrow no-break space before AM/PM, so match on the digits.)
    private func scrollToSupplement(_ app: XCUIApplication, dose: String, time: String) -> XCUIElement {
        let row = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", dose, time)).firstMatch
        for _ in 0..<6 where !row.exists { app.swipeUp() }
        return row
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        // `--disable-icloud` matters here: `WellnessStore.save()` ends in
        // `CloudBackup.shared.schedule()`, and an unsigned Simulator app reaching CloudKit is the
        // documented way these tests go flaky. Accepting the suggested time writes, so the one
        // test that mutates state is exactly the one that hit it.
        app.launchArguments = arguments + ["--disable-icloud", "--no-space-sync", "--ui-audit", "-onboardingCompleted", "YES"]
        app.withoutSpaceSync()
        app.launch()
        return app
    }

    /// Counted, not just existence-checked: the seeded meal's OTHER row is an unconfirmed
    /// estimate and opens itself, so "is there a Calories field on screen" is true before any tap
    /// and proves nothing. One open row means one Calories label; two means two.
    private func openRowCount(_ app: XCUIApplication) -> Int {
        app.staticTexts.matching(NSPredicate(format: "label == %@", "Calories")).count
    }

    func testAMealRowOpensOnTapAndClosesAgain() {
        let app = launch(["--wellness", "--meal-editor-preview"])

        let yogurt = app.staticTexts["Greek yogurt"]
        XCTAssertTrue(scrolledTo(yogurt, in: app), app.debugDescription)
        XCTAssertEqual(openRowCount(app), 1, "only the estimated row starts open")

        yogurt.tap()
        XCTAssertTrue(app.buttons["Delete item"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertEqual(openRowCount(app), 2, "tapping a row must open its editor")

        yogurt.tap()
        let closed = NSPredicate(format: "count == 1")
        expectation(for: closed, evaluatedWith: app.staticTexts.matching(
            NSPredicate(format: "label == %@", "Calories")))
        waitForExpectations(timeout: 3, handler: nil)
    }

    /// The amber row is the one the model guessed at, and the one someone reopens a saved meal to
    /// fix — so it is already open, without a tap.
    func testTheUnconfirmedRowIsAlreadyOpen() {
        let app = launch(["--wellness", "--meal-editor-preview"])
        XCTAssertTrue(app.staticTexts["Chicken grain bowl"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Calories"].exists,
                      "the estimated row opens itself; the confident one does not")
    }

    /// Add item searches first (`FoodSearchView`); "Enter it by hand" is the blank row, open and
    /// focused.
    func testAddingAnItemByHandOpensItAndFocusesItsName() {
        let app = launch(["--wellness", "--meal-editor-preview"])
        XCTAssertTrue(scrolledTo(app.staticTexts["Greek yogurt"], in: app), app.debugDescription)
        let add = app.buttons["foodText.addItem"]
        // A List is lazy — with a row open, Add item can still be below the fold.
        if !add.waitForExistence(timeout: 2) { app.swipeUp() }
        XCTAssertTrue(add.waitForExistence(timeout: 3))
        add.tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 3), "Add item opens the search")
        app.buttons["foodSearch.manual"].tap()
        XCTAssertTrue(app.staticTexts["New item"].waitForExistence(timeout: 3))
        // Focused, so the keyboard is up and its bar is available without hunting for a field.
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 3),
                      "a new row should be ready to type into")
    }

    /// A decimal pad has no return key. Without this bar there is no way off a calorie field.
    func testTheKeyboardBarCanDismissADecimalPad() {
        let app = launch(["--wellness", "--meal-editor-preview"])
        XCTAssertTrue(app.staticTexts["Calories"].waitForExistence(timeout: 8))
        // The editor's own fields: a meal waiting in "To log" behind the sheet (left by another
        // test's fixture) has a note field too.
        app.textFields.matching(NSPredicate(format: "identifier != %@", "mealInbox.note")).element(boundBy: 1).tap()
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 3))
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 3), "a decimal pad needs a way out")
        done.tap()
        XCTAssertFalse(app.keyboards.element.waitForExistence(timeout: 2))
    }

    func testMedicationTimingIsInformationalAndDoesNotOfferAutomaticMoves() {
        let app = launch(["--wellness", "--wellness-taken"])
        XCTAssertTrue(app.staticTexts["Check timing with your doctor or pharmacist"].firstMatch.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Move Calcium Citrate")).firstMatch.exists)
        XCTAssertTrue(scrollToSupplement(app, dose: "500 mg", time: "7:30").exists,
                      "the prescribed schedule must stay unchanged")
    }

    /// The app must never answer a prescription clash by rescheduling the prescription.
    func testNoSuggestionEverProposesMovingThePrescription() {
        let app = launch(["--wellness", "--wellness-taken"])
        XCTAssertTrue(app.staticTexts["Levothyroxine"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Move Levothyroxine'"))
            .firstMatch.exists)
    }

    /// The list is lazy and the estimated row opens itself above: a row can start below the fold.
    private func scrolledTo(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        if element.waitForExistence(timeout: 8) { return true }
        app.swipeUp(velocity: .slow)
        return element.waitForExistence(timeout: 3)
    }
}
