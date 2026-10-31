import XCTest

/// Estimates that learn, from the person's side (docs/design/MEAL-LEARNING.md): a food you usually
/// have around now is one tap, and the one portion question is answered with one.
final class MealLearningUITest: XCTestCase {
    func testAUsualFoodIsOneTap() {
        let app = XCUIApplication()
        app.launchArguments = ["--wellness", "--describe-preview", "--disable-icloud", "--no-space-sync", "-onboardingCompleted", "YES"]
        app.withoutSpaceSync()
        app.launch()

        // The chip, not the meal behind the sheet that has yogurt in it too.
        let chip = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@",
                                                    "foodText.usual", "Greek yogurt")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "offered around the time it's usually had\n\(app.debugDescription)")
        chip.tap()
        XCTAssertTrue(app.otherElements["foodText.total"].waitForExistence(timeout: 3), "it's in the meal, ready to check")
        let offered = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@",
                                                       "foodText.usual", "Greek yogurt"))
        XCTAssertEqual(offered.count, 0, "and isn't offered twice")
    }

    func testThePortionQuestionIsAnsweredWithOneTap() {
        let app = XCUIApplication()
        app.launchArguments = ["--wellness", "--meal-backlog", "--meal-review", "--disable-icloud", "--no-space-sync", "-onboardingCompleted", "YES"]
        app.withoutSpaceSync()
        app.launch()

        let answer = app.buttons["1\u{00BD} cups"]
        XCTAssertTrue(answer.waitForExistence(timeout: 10), "the rice was only a guess, so it asks\n\(app.debugDescription)")
        answer.tap()
        XCTAssertTrue(answer.waitForNonExistence(timeout: 3), "answered, it's not asked again")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "1\u{00BD} cups")).firstMatch
            .waitForExistence(timeout: 3), "the rice is that amount now\n\(app.debugDescription)")
    }
}
