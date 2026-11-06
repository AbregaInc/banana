import XCTest

final class MailReaderUITest: MailUITestCase {
    func testOriginalLayoutOpensAndReturnsToReader() {
        launch(open: "newsletter")
        let original = app.buttons["mail.body.original.newsletter~1"]
        XCTAssertTrue(original.waitForExistence(timeout: 10))
        original.tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.webViews.staticTexts["Dispatch"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.webViews.links["View event"].exists)
        snap("original-layout")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        snap("reader-return")
    }
}
