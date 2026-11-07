import XCTest

/// The five places under the window's "Inbox ⌄" title menu (the control column went with the rail
/// and one toolbar, docs/design/BOTTOM-BAR-SHELL.md), and the two keys that toggle a column (`\`
/// the reading pane, `]` the details column, which starts closed). Both toggles are written to the Beta's preferences by the app; every case
/// here puts back what it changes, and `tools/mac-mail-uitest.sh` restores the keys afterwards.
final class MailPlacesAndColumnsTests: MacMailTestCase {

    func testEachPlaceInTheTitleMenuShowsItsList() {
        launchMail()
        XCTAssertFalse(has(MailID.control), "no control column beside the list")
        func show(_ title: String) {
            app.descendants(matching: .any)[MailID.placeMenu].firstMatch.click()
            app.menuItems[title].firstMatch.click()
        }
        show("Starred")
        eventually("Starred to list q3") { self.row("q3").exists }
        shot("Starred")
        show("Drafts")
        eventually("Drafts to say it is empty") { self.app.staticTexts["Nothing in Drafts"].exists }
        shot("Drafts")
        show("Scheduled")
        eventually("Scheduled to say it is empty") { self.app.staticTexts["Nothing in Scheduled"].exists }
        show("Done")
        eventually("Done to say it is empty") { self.app.staticTexts["Nothing in Done"].exists }
        show("Inbox")
        eventually("the Inbox rows") { self.row("q3").exists }
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
        let needed = MailArrangement.detailsAt - MailArrangement.controlWidth
        guard let width = mailWidth(), width >= needed else {
            throw XCTSkip("The screen is too small for the details column (Mail is \(String(describing: mailWidth())) wide; it needs \(needed)).")
        }
        XCTAssertFalse(has(MailID.details), "the details start closed")
        press("]")
        eventually("the details column to open") { self.has(MailID.details) }
        shot("details shown")
        press("]")
        eventually("the details column to close") { !self.has(MailID.details) }
    }
}
