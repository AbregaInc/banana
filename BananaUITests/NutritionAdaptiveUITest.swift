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
        let add = app.buttons["nutrition.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        XCTAssertTrue(app.buttons["nutrition.search"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["nutrition.addPhotos"].exists)
        XCTAssertTrue(app.dismissNativeMenu(item: app.buttons["nutrition.search"]))
        XCTAssertFalse(app.navigationBars["Recent meals"].exists)
        XCTAssertTrue(app.buttons["nutrition.myFoods"].exists)
        capture("nutrition-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitUntil { app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height })
        XCTAssertEqual(date.value as? String, yesterday)
        capture("nutrition-landscape")
        add.tap()
        let search = app.buttons["nutrition.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
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
