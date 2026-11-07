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

    /// An open conversation reads newest first: the latest message at the top, older ones going
    /// down, and it opens at the top (the subject in view).
    func testAConversationReadsNewestFirst() {
        launch(open: "q3")
        let newest = app.buttons["mail.sender.q3~3"], oldest = app.buttons["mail.sender.q3~1"]
        XCTAssertTrue(newest.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(oldest.waitForExistence(timeout: 5))
        XCTAssertLessThan(newest.frame.minY, app.buttons["mail.sender.q3~2"].frame.minY)
        XCTAssertLessThan(app.buttons["mail.sender.q3~2"].frame.minY, oldest.frame.minY)
        let title = app.descendants(matching: .any)["mail.conversation.title"].firstMatch
        XCTAssertTrue(title.exists && title.frame.maxY < newest.frame.minY, "it opens at the top")
        XCTAssertTrue(newest.isHittable, "the newest is in view on opening")
        snap("newest-first")
    }
}
