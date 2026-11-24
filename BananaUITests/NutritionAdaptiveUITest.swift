import XCTest

final class NutritionAdaptiveUITest: XCTestCase {
    func testDayAndLoggingControlsSurviveRotation() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--tab", "nutrition", "--wellness", "--store-capture",
                               "--nutrition-week", "--disable-icloud", "-onboardingCompleted", "YES",
                               "-finishSetupDismissed", "YES"]
        app.withoutSpaceSync()
        app.launch()
        let field = app.textFields["shell.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        let home = app.buttons["dateLine.home"]
        if home.exists { home.tap() }
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
            .formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        let date = app.descendants(matching: .any)["nutrition.day"].firstMatch
        app.buttons["Previous day"].tap()
        XCTAssertTrue(waitUntil { date.value as? String == yesterday })
        let addList = app.descendants(matching: .any)["page.add.list"].firstMatch
        let search = app.buttons["wellness.searchFood"]
        field.tap()
        XCTAssertTrue(addList.waitForExistence(timeout: 5))
        XCTAssertTrue(search.exists)
        XCTAssertTrue(app.buttons["wellness.photoMeal"].exists)
        app.buttons["shell.field.clear"].tap()
        XCTAssertTrue(addList.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Recent meals"].exists)
        let myFoods = app.buttons.matching(NSPredicate(
            format: "identifier == %@ OR identifier == %@", "wellness.myFoods", "nutrition.myFoods")).firstMatch
        for _ in 0..<5 where !myFoods.exists { app.swipeUp() }
        XCTAssertTrue(myFoods.exists, "My foods must be reachable in the Food page\n\(app.debugDescription)")
        capture("nutrition-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitUntil { app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height })
        XCTAssertEqual(date.value as? String, yesterday)
        capture("nutrition-landscape")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
        app.navigationBars["Add food"].buttons["Cancel"].tap()
        XCTAssertEqual(date.value as? String, yesterday)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
