import XCTest

/// A search answers from the device at once and then gains what Gmail found (MAIL-ENGINE 9.4),
/// on the sample mailbox and its sample Gmail (`--mail-gmail-delay`).
final class MailSearchUITest: MailUITestCase {

    func testGmailsMatchesJoinBelowTheDevicesOwnWithoutMovingThem() {
        // Long enough that the device's answer is on screen well before Gmail's, on a busy Mac.
        launch(extra: ["--mail-gmail-delay", "8", "--mail-search", "invoice"])
        let local = row("reply-to")
        XCTAssertTrue(local.waitForExistence(timeout: 10), "the device's own match is shown at once\n\(app.debugDescription)")
        let gmail = row("gmail-invoice-2024")
        XCTAssertFalse(gmail.exists, "Gmail has not answered yet")
        let before = local.frame

        XCTAssertTrue(gmail.waitForExistence(timeout: 30), "Gmail's match joins the list\n\(app.debugDescription)")
        XCTAssertGreaterThan(gmail.frame.minY, local.frame.minY, "older, so below the device's newer match")
        XCTAssertEqual(local.frame.minY, before.minY, accuracy: 1, "the row already shown did not move")
        snap("search-with-gmail")
    }
}
