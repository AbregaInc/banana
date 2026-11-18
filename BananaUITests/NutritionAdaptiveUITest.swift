import XCTest

final class NutritionAdaptiveUITest: XCTestCase {
    func testDayAndLoggingControlsSurviveRotation() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--wellness", "--wide-nutrition", "--nutrition-week", "--disable-icloud", "-onboardingCompleted", "YES"]
        app.launch()
        let field = app.textFields["nutrition.phrase"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        let home = app.buttons["dateLine.home"]
        if home.exists { home.tap() }
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
            .formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        let date = app.descendants(matching: .any)["nutrition.day"].firstMatch
        app.buttons["Previous day"].tap()
        XCTAssertTrue(waitUntil { date.value as? String == yesterday })
        let add = app.plus("nutrition.add")
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        openAddForms(app, add)
        let firstSearch = menuItem(app, shared: "wellness.searchFood", local: "nutrition.search", label: "Search")
        XCTAssertTrue(menuItem(app, shared: "wellness.photoMeal", local: "nutrition.addPhotos", label: "Photos").exists)
        firstSearch.tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
        app.navigationBars["Add food"].buttons["Cancel"].tap()
        XCTAssertFalse(app.navigationBars["Recent meals"].exists)
        XCTAssertTrue(app.buttons["nutrition.myFoods"].exists)
        capture("nutrition-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitUntil { app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height })
        XCTAssertEqual(date.value as? String, yesterday)
        capture("nutrition-landscape")
        openAddForms(app, add)
        let search = menuItem(app, shared: "wellness.searchFood", local: "nutrition.search", label: "Search")
        search.tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
        app.navigationBars["Add food"].buttons["Cancel"].tap()
        XCTAssertEqual(date.value as? String, yesterday)
    }

    private func openAddForms(_ app: XCUIApplication, _ add: XCUIElement) {
        add.tap()
        if app.navigationBars["Ask or add"].exists {
            app.buttons["assistant.panel.addForm"].tap()
        }
    }

    private func menuItem(_ app: XCUIApplication, shared: String, local: String, label: String) -> XCUIElement {
        let item = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ OR identifier == %@ OR label == %@", shared, local, label
        )).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), app.debugDescription)
        return item
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
