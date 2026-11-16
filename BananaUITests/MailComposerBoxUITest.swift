import XCTest

/// The composer's box (direction A, 7 Nov 2026) in the app's own layout on the sample mail: the
/// bottom-bar shell on a phone, an upright iPad's bar beside the switcher. Reply opens a box docked
/// over the keyboard that grows as he types; ⤢ opens it to full height and back; pulling the thread
/// down folds it into the field, and a tap resumes; one "Cc" brings Cc and Bcc; the word Send sends
/// and its chevron opens send later; pulled all the way down it goes away and the draft is kept.
final class MailComposerBoxUITest: MailUITestCase {

    private func launchShell(booking: Bool? = nil, largeText: Bool = false, providerDraftCopy: Bool = false) {
        if isPad { MailTurn.ask(landscape: false) }
        app = XCUIApplication()
        app.launchArguments += ["--ui-preview", "--ui-audit", "--disable-icloud", "--dummy-health",
                                "-finishSetupDismissed", "YES", "-onboardingCompleted", "YES", "--modules", "everything",
                                "--tab", "mail", "--mail-fresh", isPad ? "--mail-cursor" : "--mail-open", "q3"]
        if providerDraftCopy { app.launchArguments += ["--mail-provider-draft-copy"] }
        if let booking {
            app.launchArguments += ["--booking-fixture"]
            if booking { app.launchArguments += ["--booking-linked"] }
        }
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"] }
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

    /// The newest message's text: the message the reply answers, at the thread's top.
    private var answered: XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Good catch, Jane")).firstMatch
    }

    /// The message answered reads above the box: its text on screen, under the reader's top row and
    /// clear of the box's top edge, and reachable by a finger.
    private func assertAnsweredReads(above handle: XCUIElement, _ moment: String,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let text = answered
        XCTAssertTrue(text.waitForExistence(timeout: 5), "the answered message's text (\(moment))\n\(app.debugDescription)",
                      file: file, line: line)
        let window = app.windows.firstMatch.frame
        let reads = waitUntil(timeout: 5) {
            text.isHittable && text.frame.minY >= window.minY && text.frame.maxY <= handle.frame.minY + 1
        }
        XCTAssertTrue(reads, "\(moment): the answered text \(text.frame) must show above the box's top \(handle.frame.minY)",
                      file: file, line: line)
    }

    private func type(_ text: String) {
        let body = element(MailID.composerBody)
        if (body.value(forKey: "hasKeyboardFocus") as? Bool) != true { body.tap() }
        body.typeText(text)
    }

    func testContinuingADraftDoesNotDuplicateItAboveTheComposer() {
        launchShell(providerDraftCopy: true)
        let handle = openReply()
        let writing = "Reply still being written, not sent."
        type(writing)
        let body = element(MailID.composerBody)
        let grip = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        grip.press(forDuration: 0.05, thenDragTo: grip.withOffset(CGVector(dx: 0, dy: 700)), withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(waitGone(body, timeout: 5))
        XCTAssertTrue(element(MailID.draftMarker).waitForExistence(timeout: 5))
        element(MailID.continueDraft).tap()
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil { (body.value as? String)?.contains(writing) == true })
        assertAnsweredReads(above: element(MailID.composerHandle), "continuing a saved draft")
        // The iPad list legitimately previews the saved draft beside the reader. Scope this
        // check to the thread's scroll view, not the list or the composer.
        let thread = app.scrollViews.containing(.staticText, identifier: answered.label).firstMatch
        XCTAssertTrue(thread.exists)
        XCTAssertFalse(thread.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", writing)).firstMatch.exists,
                       "The unsent reply belongs only in the editor, not a message card")
        snap("draft-only-in-composer")
    }

    func testSchedulingLinkInsertsWhileTypingAndSurvivesClosingTheDraft() {
        launchShell(booking: true)
        let handle = openReply()
        type("Choose a time:")
        let insert = element(MailID.composerSchedulingLink)
        XCTAssertTrue(insert.isHittable, "Scheduling is reachable with the keyboard open")
        insert.tap()
        let body = element(MailID.composerBody)
        XCTAssertTrue(waitUntil(timeout: 5) { (body.value as? String)?.contains("https://book.bananatheapp.com/noor") == true })
        XCTAssertTrue(element(MailID.send).isHittable, "Inserting a link keeps Send reachable")
        body.typeText("Thanks")
        XCTAssertTrue((body.value as? String)?.contains("Choose a time:") == true)
        snap("scheduling-link-keyboard")
        let grip = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        grip.press(forDuration: 0.05, thenDragTo: grip.withOffset(CGVector(dx: 0, dy: 700)), withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(waitGone(body, timeout: 5))
        XCTAssertTrue(element(MailID.draftMarker).waitForExistence(timeout: 5))
        element(MailID.continueDraft).tap()
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        XCTAssertTrue((body.value as? String)?.contains("https://book.bananatheapp.com/noor") == true)
        XCTAssertTrue((body.value as? String)?.contains("Thanks") == true)
        XCTAssertEqual((body.value as? String)?.components(separatedBy: "https://book.bananatheapp.com/noor").count, 2,
                       "Reopening must not replay the insertion")
    }

    func testSchedulingLinkInANewMessageWithoutAnExistingBodyCaret() {
        launchShell(booking: true)
        if isPad {
            element("mail.more").tap()
            let new = app.buttons["New message"].firstMatch
            XCTAssertTrue(new.waitForExistence(timeout: 5))
            new.tap()
        } else {
            app.buttons["mail.conversation.back"].tap()
            app.buttons["mail.list.compose"].tap()
        }
        let body = element(MailID.composerBody)
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        let insert = element(MailID.composerSchedulingLink)
        XCTAssertTrue(insert.isHittable)
        insert.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { (body.value as? String)?.contains("https://book.bananatheapp.com/noor") == true })
        snap("scheduling-link-new-message")
    }

    func testSchedulingAndSendRemainReachableWithLargerText() {
        launchShell(booking: true, largeText: true)
        _ = openReply()
        type("Choose a time")
        let insert = element(MailID.composerSchedulingLink)
        let send = element(MailID.send)
        XCTAssertTrue(insert.isHittable)
        XCTAssertTrue(send.isHittable)
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(window.contains(insert.frame))
        XCTAssertTrue(window.contains(send.frame))
        XCTAssertFalse(insert.frame.intersects(send.frame))
        insert.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { (self.element(MailID.composerBody).value as? String)?.contains("https://book.bananatheapp.com/noor") == true })
        snap("scheduling-large-text")
    }

    func testUnconfiguredSchedulingOpensExistingSettingsAndPreservesDraft() {
        launchShell(booking: false)
        _ = openReply()
        type("Keep this draft")
        element(MailID.composerSchedulingLink).tap()
        XCTAssertTrue(app.navigationBars["Booking"].waitForExistence(timeout: 5))
        element("sheet.close").tap()
        let body = element(MailID.composerBody)
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        XCTAssertEqual(body.value as? String, "Keep this draft")
    }

    func testContinuedReplySendRestoresTheReaderAndBottomBar() {
        launchShell()
        let handle = openReply()
        type("Resumed reply test")
        let grip = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        grip.press(forDuration: 0.05, thenDragTo: grip.withOffset(CGVector(dx: 0, dy: 700)), withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(waitGone(element(MailID.composerBody), timeout: 5))
        element(MailID.continueDraft).tap()
        let body = element(MailID.composerBody)
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        XCTAssertTrue((body.value as? String)?.contains("Resumed reply test") == true)
        element(MailID.send).tap()
        XCTAssertTrue(waitGone(body, timeout: 5))
        XCTAssertFalse(element(MailID.composerFolded).exists)
        XCTAssertTrue(waitUntil(timeout: 5) { self.app.buttons["shell.switcher"].firstMatch.isHittable })
        if !isPad { XCTAssertTrue(app.buttons["shell.reply"].firstMatch.isHittable) }
        XCTAssertFalse(element(MailID.continueDraft).exists)
        XCTAssertTrue(app.staticTexts["Resumed reply test"].firstMatch.waitForExistence(timeout: 5))
        snap("continued-reply-after-send")
    }

    func testNewMessageContinuedFromDraftsSendsAndLeavesUsableNavigation() {
        launchShell()
        if !isPad { app.buttons["mail.conversation.back"].tap() }
        if isPad {
            element("mail.more").tap()
            app.buttons["New message"].firstMatch.tap()
        } else { element(MailID.compose).tap() }
        let to = app.textFields[MailID.composerTo].firstMatch
        XCTAssertTrue(to.waitForExistence(timeout: 5))
        to.tap(); to.typeText("sam@lee.example,")
        let subject = app.textFields[MailID.composerSubject].firstMatch
        subject.tap(); subject.typeText("Resumed new message")
        type("Keep and send this test draft")
        let handle = element(MailID.composerHandle)
        let grip = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        grip.press(forDuration: 0.05, thenDragTo: grip.withOffset(CGVector(dx: 0, dy: 700)), withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(waitGone(element(MailID.composerBody), timeout: 5))
        show(place: "Drafts")
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", MailID.list + ".row.")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let body = element(MailID.composerBody)
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        XCTAssertTrue((body.value as? String)?.contains("Keep and send this test draft") == true)
        element(MailID.send).tap()
        XCTAssertTrue(waitGone(body, timeout: 5))
        XCTAssertFalse(element(MailID.composerFolded).exists)
        XCTAssertTrue(waitUntil(timeout: 5) { self.app.buttons["shell.switcher"].firstMatch.isHittable })
        XCTAssertTrue(element(MailID.placeMenu).isHittable)
        XCTAssertFalse(element(MailID.continueDraft).exists)
        snap("continued-new-message-after-send")
        show(place: "Inbox")
        XCTAssertTrue(element(MailID.list).waitForExistence(timeout: 5))
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
        // One line: the body starts right under the people, with no empty line between.
        let gap = element(MailID.composerBody).frame.minY - style.frame.maxY
        XCTAssertLessThan(gap, 36, "the text starts under the To line, \(gap) pt below Reply all")
        assertAnsweredReads(above: top, "one line, keyboard up")
        snap("box-one-line")
        type("\nSecond line\nThird line")
        let three = top.frame.minY
        XCTAssertGreaterThan(one - three, 20, "the box grows upward as he types (\(one) → \(three))")
        type("\nFourth\nFifth\nSixth\nSeventh")
        let capped = top.frame.minY
        XCTAssertLessThan(three - capped, 60, "four lines at most, then the text scrolls (\(three) → \(capped))")
        assertAnsweredReads(above: top, "four lines, keyboard up")
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
        // The thread above the box shows the message answered: the finger pulls it down from there.
        XCTAssertTrue(answered.waitForExistence(timeout: 5))
        let start = answered.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
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
