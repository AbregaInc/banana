import XCTest

/// The control column's five places, and the two keys that hide a column (`\` the reading pane,
/// `]` the details column). Both toggles are written to the Beta's preferences by the app; every case
/// here puts back what it changes, and `tools/mac-mail-uitest.sh` restores the keys afterwards.
final class MailPlacesAndColumnsTests: MacMailTestCase {

    func testEachPlaceInTheControlColumnShowsItsList() {
        launchMail()
        place("Starred").click()
        eventually("Starred to list its two") { self.row("q3").exists && self.placeCount("Starred") == 2 }
        shot("Starred")
        place("Drafts").click()
        eventually("Drafts to say it is empty") { self.app.staticTexts["Nothing in Drafts"].exists }
        shot("Drafts")
        place("Scheduled").click()
        eventually("Scheduled to say it is empty") { self.app.staticTexts["Nothing in Scheduled"].exists }
        place("Done").click()
        eventually("Done to say it is empty") { self.app.staticTexts["Nothing in Done"].exists }
        place("Inbox").click()
        eventually("the Inbox rows") { self.row("q3").exists }
        XCTAssertEqual(placeCount("Inbox"), 40)
        shot("Inbox again")
    }

    func testBackslashHidesAndShowsTheReadingPane() {
        launchMail()
        XCTAssertTrue(paneIsShowing, "the pane is showing at this width")
        press("\\")
        eventually("the pane to go") { !self.paneIsShowing }
        shot("pane hidden")
        press("\\")
        eventually("the pane to come back") { self.paneIsShowing }
        expectShown("q3", "after the pane returns")
    }

    func testBracketHidesAndShowsTheDetailsColumn() throws {
        launchMail(size: CGSize(width: 1500, height: 780))
        guard let width = mailWidth(), width >= MailArrangement.detailsAt else {
            throw XCTSkip("The screen is too small for four columns (Mail is \(String(describing: mailWidth())) wide; it needs \(MailArrangement.detailsAt)).")
        }
        XCTAssertTrue(has(MailID.details), "all four columns at this width")
        press("]")
        eventually("the details column to go") { !self.has(MailID.details) }
        shot("details hidden")
        press("]")
        eventually("the details column to come back") { self.has(MailID.details) }
    }
}
