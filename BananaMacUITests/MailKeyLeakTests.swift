import XCTest

/// Single keys must not leak between Mail and the calendar (MAIL-UX K3, K4, 4.3; the calendar's
/// are in `MacKeyMonitor`: T today, J/K period, D/W views, 1-7 days, N/B event, C new, S share,
/// ? and / shortcuts). Mail in front: only Mail's. Plan in front: only the calendar's, exactly as before.
final class MailKeyLeakTests: MacMailTestCase {

    func testTheCalendarsOwnKeysDoNothingUnexpectedInMail() {
        launchMail()
        for key in ["t", "d", "w", "1", "2", "3", "4", "5", "6", "7", "n", "b", "/"] {
            press(key)
            XCTAssertTrue(has(MailID.list), "'\(key)' took Mail out of the front")
            XCTAssertEqual(app.sheets.count, 0, "'\(key)' put a sheet up")
        }
        press("/", .shift) // ?
        XCTAssertEqual(app.sheets.count, 0, "? put the calendar's shortcut sheet up over Mail")
        expectNothingHappenedToTheList("after the calendar's keys")
        expectShown("q3", "after the calendar's keys")
        shot("after the calendar's keys")
        press(.escape)
        expectShown("q3", "Esc with nothing open")
    }

    func testAfterGoingToPlanAndBackTheCalendarsKeysWorkThereAndMailsDoNot() {
        launchMail()
        press("1", .command)
        eventually("Plan to be in front") { !self.has(MailID.list) }
        shot("Plan")
        press("/", .shift) // ?: the calendar's shortcut sheet
        eventually("the calendar's shortcut sheet") { self.app.sheets.count > 0 }
        shot("shortcut sheet")
        app.sheets.buttons["Done"].click()
        eventually("the sheet to close") { self.app.sheets.count == 0 }
        // Mail's keys, with Plan in front: nothing of Mail's fires
        for key in ["e", "z", "u", "r", "f", "\\", "]"] { press(key) }
        press("2", .command)
        eventually("Mail to be back") { self.has(MailID.list) }
        expectShown("q3", "the cursor is where he left it")
        XCTAssertEqual(placeCount("Inbox"), MacMailFixture.inboxCount, "E in Plan marked something Done")
        XCTAssertFalse(hasComposer, "R or F in Plan opened a composer")
        XCTAssertTrue(paneIsShowing, "\\ in Plan hid Mail's pane")
        XCTAssertFalse(anyToastIsUp)
        // and Mail's work again
        press("j"); expectShown("invite", "J works in Mail again")
        press("/", .shift)
        XCTAssertEqual(app.sheets.count, 0, "? is not Mail's")
    }

    func testFileNewFollowsTheSectionInFront() {
        launchMail()
        press("n", .command)
        XCTAssertTrue(el(MailID.composer).waitForExistence(timeout: 8), "Cmd-N in Mail is a new message")
        XCTAssertTrue(has(MailID.list) || has(MailID.control), "Cmd-N jumped away from Mail")
        shot("new message by Cmd-N")
    }
}
