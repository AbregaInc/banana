import XCTest

/// The mouse: a click on a row places the cursor and the pane follows (it does not open, where there
/// is a pane to show it), a double click opens full width, a click on a place changes place.
final class MailMouseTests: MacMailTestCase {

    func testAClickOnARowPlacesTheCursorAndShowsItWithoutOpening() {
        launchMail()
        let target = row("receipt")
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        target.click()
        expectShown("receipt", "after a click")
        XCTAssertFalse(isOpen, "a click opened the conversation: with a pane it only places the cursor")
        shot("clicked")
    }

    func testADoubleClickOnARowOpensItFullWidth() {
        launchMail()
        let target = row("plain-chain")
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        target.doubleClick()
        eventually("the conversation to open full width") { self.isOpen }
        expectShown("plain-chain", "when opened by a double click")
        shot("double clicked")
        press(.escape)
        eventually("Esc to close it") { !self.isOpen }
    }

    func testAClickOnAPlaceChangesPlaceAndAClickOnInboxComesBack() {
        launchMail()
        place("Starred").click()
        eventually("Starred's rows") { self.row("flight").exists }
        place("Inbox").click()
        eventually("the Inbox's rows") { self.row("q3").exists }
    }

    func testAKeyAfterAClickIsStillMails() {
        launchMail()
        row("receipt").click()
        expectShown("receipt", "after a click")
        press("j")
        expectShown("me-newest", "J after a click on a row")
    }
}
