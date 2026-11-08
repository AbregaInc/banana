import XCTest

/// The composer's box (direction A, 7 Nov 2026) in the app's own layout on the sample mail: the
/// bottom-bar shell on a phone, an upright iPad's bar beside the switcher. Reply opens a box docked
/// over the keyboard that grows as he types; ⤢ opens it to full height and back; pulling the thread
/// down folds it into the field, and a tap resumes; one "Cc" brings Cc and Bcc; the word Send sends
/// and its chevron opens send later; pulled all the way down it goes away and the draft is kept.
final class MailComposerBoxUITest: MailUITestCase {

    private func launchShell() {
        if isPad { MailTurn.ask(landscape: false) }
        app = XCUIApplication()
        app.launchArguments += ["--ui-preview", "--ui-audit", "--disable-icloud", "--dummy-health",
                                "-finishSetupDismissed", "YES", "-onboardingCompleted", "YES", "--modules", "everything",
                                "--tab", "mail", "--mail-fresh", isPad ? "--mail-cursor" : "--mail-open", "q3"]
        app.withoutSpaceSync()
        app.launch()
        if isPad { XCTAssertTrue(MailTurn.settle(app, landscape: false), "the iPad must be upright") }
        XCTAssertTrue(element(MailID.list).waitForExistence(timeout: 30), "the list came up\n\(app.debugDescription)")
    }

    /// Reply all, from the bar's "Reply or ask" on a phone and the reader's "…" on an upright iPad.
    private func openReply() -> XCUIElement {
        if isPad {
            let more = app.buttons["mail.pane.more"].firstMatch
            XCTAssertTrue(more.waitForExistence(timeout: 10), "the pane's \u{2026}\n\(app.debugDescription)")
            more.tap()
            let item = app.buttons["Reply to all"].firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 5))
            item.tap()
        } else {
            let field = app.buttons["shell.reply"].firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 10), "Reply or ask\n\(app.debugDescription)")
            field.tap()
        }
        // The box's top edge is its grab handle: where it is says how tall the box is.
        let handle = element(MailID.composerHandle)
        XCTAssertTrue(element(MailID.composerBody).waitForExistence(timeout: 5), "the box opened\n\(app.debugDescription)")
        XCTAssertTrue(handle.exists)
        return handle
    }

    private func type(_ text: String) {
        let body = element(MailID.composerBody)
        if (body.value(forKey: "hasKeyboardFocus") as? Bool) != true { body.tap() }
        body.typeText(text)
    }

    func testReplyOpensTheBoxAsReplyAllAndItGrowsToFourLines() {
        launchShell()
        let top = openReply()
        let style = element(MailID.composerReplyStyle)
        XCTAssertTrue(style.waitForExistence(timeout: 5))
        XCTAssertEqual(style.label, "Reply all", "Reply all is the default")
        XCTAssertFalse(element(MailID.composerSubject).exists, "a reply has no Subject row")
        XCTAssertFalse(element(MailID.composerCc).exists, "only To until Cc is asked for")
        XCTAssertTrue(element(MailID.composerExpand).exists, "\u{2924} at the box's top right")
        XCTAssertTrue(element(MailID.composerHandle).exists, "the grab handle")
        if !isPad {
            XCTAssertFalse(app.buttons["shell.switcher"].exists, "on a phone the switcher steps away")
        } else {
            let switcher = app.buttons["shell.switcher"].firstMatch
            XCTAssertTrue(switcher.isHittable, "an upright iPad keeps the switcher")
            XCTAssertGreaterThan(top.frame.minX, switcher.frame.maxX - 1, "the box starts right after the switcher")
        }
        XCTAssertFalse(app.buttons["shell.ai"].exists, "the sparkle steps away while writing")
        let one = top.frame.minY
        type("Thanks \u{2014} I'll look at it tonight.")
        snap("box-one-line")
        type("\nSecond line\nThird line")
        let three = top.frame.minY
        XCTAssertGreaterThan(one - three, 20, "the box grows upward as he types (\(one) → \(three))")
        type("\nFourth\nFifth\nSixth\nSeventh")
        let capped = top.frame.minY
        XCTAssertLessThan(three - capped, 60, "four lines at most, then the text scrolls (\(three) → \(capped))")
        snap("box-four-lines")
    }

    func testExpandAndCollapse() {
        launchShell()
        let handle = openReply()
        let docked = handle.frame.minY
        element(MailID.composerExpand).tap()
        XCTAssertTrue(waitUntil(timeout: 5) { handle.frame.minY < docked - 120 }, "\u{2924} opens a full-height editor (\(docked) → \(handle.frame.minY))")
        snap("box-full")
        element(MailID.composerExpand).tap()
        XCTAssertTrue(waitUntil(timeout: 5) { abs(handle.frame.minY - docked) < 40 }, "\u{2921} brings it back")
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)))
        XCTAssertTrue(waitUntil(timeout: 5) { handle.frame.minY < docked - 120 }, "dragging the handle up opens it too")
    }

    func testPullingTheThreadDownFoldsTheBoxAndATapResumes() {
        launchShell()
        _ = openReply()
        type("Thanks \u{2014} I'll look at it tonight.")
        let title = element(MailID.conversationTitle)
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let start = title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 220)))
        let folded = element(MailID.composerFolded)
        XCTAssertTrue(folded.waitForExistence(timeout: 5), "the box folded into the field\n\(app.debugDescription)")
        XCTAssertTrue(folded.label.contains("I'll look at it tonight"), "the field shows the draft: \(folded.label)")
        XCTAssertTrue(app.buttons["shell.switcher"].firstMatch.isHittable, "the switcher is back")
        XCTAssertTrue(element(MailID.composerFoldedSend).exists, "Send is in the field")
        snap("folded")
        folded.tap()
        XCTAssertTrue(element(MailID.composerBody).waitForExistence(timeout: 5), "a tap resumes")
        XCTAssertTrue(waitGone(folded, timeout: 5))
    }

    func testCcBringsCcAndBccAndSendSends() {
        launchShell()
        _ = openReply()
        let cc = element(MailID.composerReveal("Cc"))
        XCTAssertTrue(cc.waitForExistence(timeout: 5))
        cc.tap()
        XCTAssertTrue(element(MailID.composerCc).waitForExistence(timeout: 5), "Cc")
        XCTAssertTrue(element(MailID.composerBcc).exists, "and Bcc")
        type("Thanks \u{2014} I'll look at it tonight.")
        let send = element(MailID.send)
        XCTAssertEqual(send.label, "Send", "the word Send, never a round arrow")
        send.tap()
        XCTAssertTrue(waitForToast(containing: "Sending"), "sent, with Undo\n\(app.debugDescription)")
        XCTAssertTrue(waitGone(element(MailID.composerBody), timeout: 5))
    }

    func testTheSendChevronOpensSendLater() {
        launchShell()
        _ = openReply()
        type("Later")
        let later = element(MailID.composerSendLater)
        XCTAssertTrue(later.waitForExistence(timeout: 5))
        later.tap()
        XCTAssertTrue(element(MailID.timePicker).waitForExistence(timeout: 5), "the send-later times\n\(app.debugDescription)")
        snap("send-later")
    }

    func testSwipingTheBoxAwayKeepsTheDraft() {
        launchShell()
        let handle = openReply()
        type("Kept for later")
        let grip = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        grip.press(forDuration: 0.05, thenDragTo: grip.withOffset(CGVector(dx: 0, dy: 700)), withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(waitGone(element(MailID.composerBody), timeout: 5), "put away\n\(app.debugDescription)")
        XCTAssertTrue(element(MailID.draftMarker).waitForExistence(timeout: 5), "the draft is kept and marked in the conversation")
    }
}
