import XCTest

/// The triage keys of the list on the sample Inbox: moving, opening, Done and Undo, star, unread
/// (MAIL-UX 3 and 4.2.2-4.2.4; `MailKeymap`). The cursor is not drawn in the accessibility tree, so
/// where it is is read from the reading pane, which shows the conversation under it.
final class MailTriageKeysTests: MacMailTestCase {

    func testJAndKMoveTheCursorAndThePaneFollows() {
        launchMail()
        expectShown("q3", "at launch")
        press("j"); shot("after J")
        expectShown("invite", "after J")
        press("j"); expectShown("plain-chain", "after a second J")
        press("k"); expectShown("invite", "after K")
        expectNothingHappenedToTheList("by moving")
    }

    func testTheArrowKeysMoveTheCursorToo() {
        launchMail()
        press(.downArrow); expectShown("invite", "after Down")
        press(.downArrow); expectShown("plain-chain", "after Down again")
        press(.upArrow); expectShown("invite", "after Up")
        shot("after the arrows")
    }

    func testAtEitherEndNothingHappensAndThereIsNoWrap() {
        launchMail()
        press("k"); expectShown("q3", "K at the top")
        press("j", times: 39)
        expectShown("intro", "after 39 J")
        press("j")
        expectShown("intro", "J at the bottom does not wrap")
        shot("at the bottom")
    }

    func testThirtyQuickJsEndOnTheRightRow() {
        launchMail()
        type(String(repeating: "j", count: 30))
        expectShown("three-newsletters", "after thirty J typed as fast as a typist")
        let shown = row("three-newsletters")
        XCTAssertTrue(shown.waitForExistence(timeout: 5), "the cursor row was not scrolled into view: \(visibleRowKeys())")
        shot("after thirty J")
        // A key held down repeats; the keyboard's own auto-repeat cannot be sent by XCUITest, so that
        // one is pressed by hand: hold J for two seconds and the cursor ends where it ends, one row each repeat.
    }

    func testReturnOpensFullWidthAndEscReturns() {
        launchMail()
        press(.return)
        eventually("the conversation to open full width") { isOpen }
        expectShown("q3", "when open")
        shot("open")
        XCTAssertFalse(has(MailID.list) && !visibleRowKeys().isEmpty, "the list is still in the accessibility tree under an open conversation")
        press(.escape)
        eventually("Esc to close it") { !isOpen && !visibleRowKeys().isEmpty }
        expectShown("q3", "after closing: the cursor is where it was")
    }

    func testRightOpensAndLeftCloses() {
        launchMail()
        press(.rightArrow)
        eventually("Right to open") { isOpen }
        press(.leftArrow)
        eventually("Left to close") { !isOpen }
    }

    func testEMarksDoneMovesTheCursorToTheNextRowAndShowsTheToast() {
        launchMail()
        press("e")
        waitForToast(containing: "Q3 numbers before Thursday", "Done")
        XCTAssertNotNil(toast(containing: "Done"))
        expectShown("invite", "the cursor moves on")
        eventually("the row to leave the list") { !row("q3").exists }
        XCTAssertEqual(placeCount("Inbox"), 39)
        XCTAssertTrue(el("toast.undo").exists, "the toast offers Undo")
        shot("after E")
    }

    func testZRestoresTheConversationAndTheCursor() {
        launchMail()
        press("e")
        waitForToast(containing: "Done")
        press("z")
        waitForToast(containing: "Undone")
        expectShown("q3", "after Z")
        eventually("the row back") { row("q3").exists }
        XCTAssertEqual(placeCount("Inbox"), 40)
        shot("after Z")
    }

    func testCmdZUndoesWhileAToastIsUp() {
        launchMail()
        press("e")
        waitForToast(containing: "Done")
        press("z", .command)
        waitForToast(containing: "Undone")
        expectShown("q3", "after Cmd-Z")
        XCTAssertEqual(placeCount("Inbox"), 40)
    }

    func testEOnTheLastRowGoesBackAndSaysSo() {
        launchMail()
        press("j", times: 39)
        expectShown("intro", "at the last row")
        press("e")
        waitForToast(containing: "Intro: Noor and Dewey", "Done")
        expectShown("hiring", "the cursor goes the other way: nothing is beyond the last row")
        XCTAssertEqual(placeCount("Inbox"), 39)
        shot("Done on the last row")
    }

    func testSStarsAndSAgainUnstars() {
        launchMail()
        XCTAssertEqual(placeCount("Starred"), MacMailFixture.starredCount)
        press("j"); press("s")
        eventually("the Starred count to be 3 (is \(String(describing: placeCount("Starred"))))") { placeCount("Starred") == 3 }
        press("s")
        eventually("the Starred count to be 2 again") { placeCount("Starred") == 2 }
        expectShown("invite", "starring moves nothing")
    }

    func testUTogglesReadAndIsAnUndoStep() {
        launchMail()
        settle(2.6) // the pane has had it for two seconds: read (T51)
        press("u")
        settle(0.3)
        XCTAssertFalse(anyToastIsUp, "marking has no toast")
        press("z")
        waitForToast(containing: "Undone")
        expectShown("q3", "reading does not move the cursor")
    }

    func testUInAnOpenConversationLeavesItUnreadAndGoesBack() {
        launchMail()
        press(.return)
        eventually("open") { isOpen }
        press("u")
        eventually("U to go back to the list") { !isOpen }
        expectShown("q3", "after U")
    }

    func testShiftEInDoneBringsOneBackToTheInbox() {
        launchMail()
        press("e")
        waitForToast(containing: "Done")
        place("Done").click()
        eventually("the Done place to hold one") { self.row("q3").exists }
        press("e", .shift)
        waitForToast(containing: "back in the inbox")
        place("Inbox").click()
        eventually("the Inbox to hold forty again") { self.placeCount("Inbox") == 40 }
        shot("back in the inbox")
    }
}
