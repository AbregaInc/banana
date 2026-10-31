import XCTest
import UIKit

/// Hostile and awkward use: rapid repeated actions, acting while a toast is up, backgrounding with a
/// composer open, rotating an iPad, very long and very odd text, the largest and smallest text
/// sizes, the keyboard over the field, a sheet dismissed halfway, places that empty. Where the
/// design has a rule it is the oracle; where it does not, the test records what happened.
final class MailHostileUITest: MailUITestCase {

    // MARK: Rapid repeated actions

    func testTenDonesAsFastAsTheTestCanSwipe() {
        launch()
        let before = visibleRowKeys()
        XCTAssertGreaterThanOrEqual(before.count, 6)
        let start = Date()
        var swiped: [String] = []
        for _ in 0..<10 {
            guard let top = visibleRowKeys().first else { break }
            swiped.append(top)
            fullSwipeDone(row(top))
        }
        let took = Date().timeIntervalSince(start)
        Thread.sleep(forTimeInterval: 1.2)
        snap("00-after-ten-fast")
        let left = visibleRowKeys()
        note("ten fast Dones took \(took)s; swiped \(swiped); left on screen \(left)")
        // T18: ten presses, ten conversations, each on the row the last one left.
        XCTAssertEqual(Set(swiped).count, 10, "every swipe took a different row: \(swiped)")
        XCTAssertEqual(headerCount(), 30, "ten gone, no more and no fewer")
        for key in swiped { XCTAssertFalse(left.contains(key), "\(key) is still showing") }
        show(place: "Done")
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertEqual(headerCount(), 10)
        snap("01-done-place")
    }

    func testUndoPressedTwice() {
        launch()
        fullSwipeDone(row("q3"))
        XCTAssertTrue(waitGone(row("q3"), timeout: 3))
        fullSwipeDone(row("invite"))
        XCTAssertTrue(waitGone(row("invite"), timeout: 3))
        XCTAssertTrue(waitForToast(containing: "Invitation", timeout: 3))
        undoButton.tap()
        XCTAssertTrue(row("invite").waitForExistence(timeout: 3), "the first Undo puts invite back")
        snap("00-after-first-undo")
        // The toast now reads "Undone" with "Undo previous: Marked Done" (T26).
        let previous = app.buttons["toast.action"].firstMatch
        let offered = previous.waitForExistence(timeout: 2)
        note("after one Undo the toast offers: \(offered ? previous.label : "nothing")")
        XCTAssertTrue(offered, "Undo previous is offered when the stack has another entry (T26)")
        if offered { previous.tap() }
        XCTAssertTrue(row("q3").waitForExistence(timeout: 3), "the second press undoes the Done before it")
        snap("01-after-second-undo")
        XCTAssertEqual(visibleRowKeys().prefix(2), ["q3", "invite"], "both back in their places: \(visibleRowKeys())")
        XCTAssertEqual(headerCount(), 40)
        // A third press, with nothing left: nothing happens, and nothing is lost.
        if app.buttons["toast.action"].exists { app.buttons["toast.action"].tap() }
        if undoButton.exists { undoButton.tap() }
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(headerCount(), 40)
        snap("02-after-third")
    }

    func testSendTappedTwiceSendsOnce() {
        launch(open: "q3", state: "reply")
        XCTAssertTrue(body.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)
        let send = button(MailID.send)
        XCTAssertTrue(send.waitForExistence(timeout: 10), "Send is in the footer\n\(app.debugDescription)")
        if !send.isHittable { app.swipeUp() }
        // A point on the screen, not on the button: the second tap lands where the first did,
        // after the button has gone with the composer.
        let frame = send.frame
        let where_ = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY))
        where_.tap()
        where_.tap()
        Thread.sleep(forTimeInterval: 1.5)
        snap("00-after-double-send")
        XCTAssertTrue(waitForToast(containing: "Sending", timeout: 3))
        // The second tap landed on whatever was under the sheet: nothing else must have happened.
        XCTAssertTrue(element(MailID.conversation).exists || element(MailID.pane).exists, "still on the conversation")
        XCTAssertFalse(body.exists, "no second composer")
        let sentCards = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'nothing is really sent' OR label CONTAINS 'nothing was really sent'"))
        app.swipeUp(); app.swipeUp()
        let count = sentCards.count
        note("sample-sent cards after a double tap on Send: \(count)")
        XCTAssertEqual(count, 1, "exactly one message was sent")
        snap("01-conversation-foot")
        if !hasPane {
            XCTAssertTrue(element(MailID.conversation).exists, "the second tap did not close or act on the conversation")
        }
    }

    func testActingWhileAToastIsUp() {
        launch()
        fullSwipeDone(row("q3"))
        XCTAssertTrue(waitForToast(containing: "Q3 numbers", timeout: 3))
        // Straight away, with that toast up: another Done.
        fullSwipeDone(row("invite"))
        XCTAssertTrue(waitForToast(containing: "Invitation", timeout: 3), "the toast shows the latest change (T27)")
        snap("00-second-toast")
        undoButton.tap()
        XCTAssertTrue(row("invite").waitForExistence(timeout: 3), "Undo undid the latest")
        XCTAssertFalse(row("q3").exists, "and not the one before it")
        XCTAssertEqual(headerCount(), 39)
        snap("01-after-undo")
    }

    // MARK: Backgrounding

    func testBackgroundingMidCompositionKeepsTheTextTheComposerAndThePlace() {
        launch()
        // Deep in the list, so the position is something to lose.
        XCTAssertTrue(scrollToRow("flight"), "\(visibleRowKeys())")
        Thread.sleep(forTimeInterval: 0.4)
        let keysBefore = visibleRowKeys()
        let key = "flight"
        if hasPane { row(key).tap(); Thread.sleep(forTimeInterval: 0.6) } else { openConversation(key) }
        reply("Reply")
        typeIntoBody("Half a thought")
        snap("00-before-background")
        background(for: 4)
        snap("01-after-return")
        XCTAssertTrue(body.waitForExistence(timeout: 10), "the composer is still open after 4 s in the background\n\(app.debugDescription)")
        XCTAssertTrue(bodyText.contains("Half a thought"), "the text survived: \(bodyText)")
        // The caret is where it was: typing lands at the end.
        body.tap()
        Thread.sleep(forTimeInterval: 0.3)
        body.typeText(" and the rest")
        XCTAssertTrue(bodyText.contains("Half a thought and the rest"), "the caret was at the end: \(bodyText)")
        snap("02-typed-after")
        if hasPane {
            // The keyboard covers the lower half of a landscape iPad, and the list column with it:
            // the row is looked for once the keyboard is down.
            hideKeyboard()
            Thread.sleep(forTimeInterval: 0.8)
            XCTAssertTrue(row(key).exists && row(key).isHittable, "the list is still around \(key): \(visibleRowKeys())")
        } else {
            XCTAssertTrue(element(MailID.conversation).exists, "the conversation is still open under the sheet")
            leaveComposerKeepingDraft()
            element(MailID.back).tap()
            Thread.sleep(forTimeInterval: 0.5)
            let keysAfter = visibleRowKeys()
            note("list after background and back: \(keysAfter) (was \(keysBefore))")
            // The slice restores the list by revealing the cursor row, not to the point (T46's
            // `restoreViewport` is not carried out yet): the row is on screen, whole or in part.
            XCTAssertTrue(row(key).exists && row(key).isHittable, "the list came back around \(key) (T46)")
        }
    }

    func testBackgroundingWithAnOpenConversationScrolledDown() {
        launch(open: "long")
        XCTAssertTrue(element(MailID.conversation).waitForExistence(timeout: 10))
        for _ in 0..<6 { app.swipeUp() }
        Thread.sleep(forTimeInterval: 0.5)
        let marker = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '1. This paragraph'")).firstMatch
        let wasScrolled = !marker.exists || marker.frame.maxY < 0
        snap("00-scrolled")
        background(for: 4)
        snap("01-after-return")
        XCTAssertTrue(element(MailID.conversation).waitForExistence(timeout: 10), "the conversation is still open")
        let stillScrolled = !marker.exists || marker.frame.maxY < 0
        note("scrolled before: \(wasScrolled), after return: \(stillScrolled)")
        XCTAssertEqual(wasScrolled, stillScrolled, "the reader's position survived the background (6.2.10)")
    }

    /// The path he really uses on an iPad: the sidebar's Mail, in the production shell, whose tree
    /// is discarded 2.5 s after backgrounding.
    func testBackgroundingOnTheProductionShellOnIPad() throws {
        try XCTSkipUnless(isPad, "the production shell's sidebar has Mail on an iPad only")
        MailTurn.ask(landscape: true)
        app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--dummy-health", "--disable-icloud", "--mail-fresh", "-onboardingCompleted", "YES"]
        app.launch()
        XCTAssertTrue(MailTurn.settle(app, landscape: true), "the production-shell journey requires landscape")
        // The shell is up when its first section is named; on its side the sidebar is open and
        // names it as a row, upright it is a button.
        let plan = app.descendants(matching: .any)["Plan"].firstMatch
        if !plan.waitForExistence(timeout: 8) {
            // A simulator that has just been erased puts the system's question about the location
            // over the production shell, and nothing under it can be reached until it is answered.
            let notNow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons
                .matching(NSPredicate(format: "label BEGINSWITH[c] 'Don'")).firstMatch
            if notNow.waitForExistence(timeout: 5) { notNow.tap() }
            if !plan.waitForExistence(timeout: 30) {
                snap("00-no-plan-button")
                XCTFail("the shell came up with its Plan button\n\(app.debugDescription)")
            }
        }
        // On its side the sidebar is already open; upright it is behind its button.
        var mail = app.buttons["Mail"].firstMatch.exists ? app.buttons["Mail"].firstMatch : app.staticTexts["Mail"].firstMatch
        if !mail.waitForExistence(timeout: 3) {
            let toggle = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'sidebar'")).firstMatch
            XCTAssertTrue(toggle.waitForExistence(timeout: 10))
            toggle.tap()
            mail = app.buttons["Mail"].firstMatch.exists ? app.buttons["Mail"].firstMatch : app.staticTexts["Mail"].firstMatch
        }
        XCTAssertTrue(mail.waitForExistence(timeout: 5), app.debugDescription)
        mail.tap()
        XCTAssertTrue(element(MailID.list).waitForExistence(timeout: 15), "Mail from the sidebar\n\(app.debugDescription)")
        snap("00-mail-in-shell")
        row("invite").tap()
        Thread.sleep(forTimeInterval: 0.6)
        reply("Reply")
        typeIntoBody("Kept through the dark")
        snap("01-composer")
        background(for: 4)
        snap("02-after-return")
        XCTAssertTrue(body.waitForExistence(timeout: 15), "the composer is back after the tree was discarded\n\(app.debugDescription)")
        XCTAssertTrue(bodyText.contains("Kept through the dark"), bodyText)
        XCTAssertTrue(conversationShows("Invitation: Design review", timeout: 5), "the pane shows the same conversation")
    }

    // MARK: Rotation

    func testRotatingTheIPadWithAComposerAConversationAndThePickerOpen() throws {
        try XCTSkipUnless(isPad, "rotation is the iPad's")
        launch()
        row("q3").tap()
        Thread.sleep(forTimeInterval: 0.6)
        reply("Reply")
        typeIntoBody("Turning")
        snap("00-portrait-composer")
        turn(toLandscape: true)
        snap("01-landscape-composer")
        XCTAssertTrue(body.waitForExistence(timeout: 5), "the composer survived the turn")
        XCTAssertTrue(bodyText.contains("Turning"), bodyText)
        XCTAssertTrue(element(MailID.details).exists, "landscape has room for the details column")
        // The picker open, then turn back.
        hideKeyboard()
        button(MailID.composerSendLater).tap()
        XCTAssertTrue(element(MailID.timePicker).waitForExistence(timeout: 5))
        let field = app.textFields[MailID.timePickerField].firstMatch
        field.tap()
        field.typeText("fri 9")
        XCTAssertTrue(element(MailID.timePickerRow("typed")).waitForExistence(timeout: 3))
        snap("02-landscape-picker")
        turn(toLandscape: false)
        snap("03-portrait-picker")
        XCTAssertTrue(element(MailID.timePicker).waitForExistence(timeout: 5), "the picker is still open")
        XCTAssertEqual(field.value as? String, "fri 9", "with what was typed")
        XCTAssertFalse(element(MailID.details).exists, "portrait has no details column")
        // A conversation open full width, turned both ways.
        element(MailID.timePicker).buttons["Close"].firstMatch.tap()
        element(MailID.expand).tap()
        XCTAssertTrue(element(MailID.conversation).waitForExistence(timeout: 5))
        turn(toLandscape: true)
        snap("04-landscape-conversation")
        XCTAssertTrue(element(MailID.conversation).exists, "still open after the turn")
        XCTAssertTrue(conversationShows("Q3 numbers before Thursday", timeout: 3))
        XCTAssertTrue(body.exists, "and the reply card is still in it: \(bodyText)")
    }

    // MARK: Odd text

    func testVeryLongSubjectEmptySubjectEmojiOnlyAndRightToLeft() {
        launch()
        // A 300-character subject on a new message.
        element(MailID.compose).tap()
        XCTAssertTrue(toField.waitForExistence(timeout: 10))
        toField.tap()
        toField.typeText("sam@lee.example,")
        subjectField.tap()
        let long = String(repeating: "A very long subject line that goes on and on. ", count: 7)
        UIPasteboard.general.string = String(long.prefix(300))
        subjectField.press(forDuration: 1.0)
        let paste = app.menuItems["Paste"]
        if paste.waitForExistence(timeout: 3) { paste.tap() } else { subjectField.typeText(String(long.prefix(120))) }
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow Paste"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
        typeIntoBody("\u{1F389}\u{1F389}\u{1F389}")
        hideKeyboard()
        snap("00-long-subject-emoji-body")
        let send = button(MailID.send)
        if !send.isHittable { app.swipeUp() }
        send.tap()
        XCTAssertTrue(waitForToast(containing: "Sending", timeout: 3), "a long subject and an emoji body send")
        snap("01-long-subject-sent")
        Thread.sleep(forTimeInterval: 0.5)
        // Its row, in Done (a sent new message is a conversation of its own, out of the inbox).
        show(place: "Done")
        Thread.sleep(forTimeInterval: 0.8)
        snap("02-done-with-long-subject")
        let keys = visibleRowKeys()
        note("Done after sending a new message: \(keys)")

        // No subject at all: sent without a question (6.3.3).
        show(place: "Inbox")
        Thread.sleep(forTimeInterval: 0.4)
        element(MailID.compose).tap()
        XCTAssertTrue(toField.waitForExistence(timeout: 10))
        toField.tap()
        toField.typeText("sam@lee.example,")
        typeIntoBody("No subject here.")
        hideKeyboard()
        let send2 = button(MailID.send)
        if !send2.isHittable { app.swipeUp() }
        send2.tap()
        XCTAssertTrue(waitForToast(containing: "Sending", timeout: 3), "an empty subject is sent without a question")
        XCTAssertFalse(app.alerts.firstMatch.exists, "no question was asked")
        snap("03-no-subject-sent")
        Thread.sleep(forTimeInterval: 0.5)

        // Right-to-left, in a reply to the Hebrew conversation.
        XCTAssertTrue(scrollToRow("rtl"), "\(visibleRowKeys())")
        if hasPane { row("rtl").tap(); Thread.sleep(forTimeInterval: 0.5) } else { openConversation("rtl") }
        reply("Reply")
        UIPasteboard.general.string = "תודה, נדבר ביום חמישי"
        body.tap()
        body.press(forDuration: 1.0)
        let paste2 = app.menuItems["Paste"]
        XCTAssertTrue(paste2.waitForExistence(timeout: 3), app.debugDescription)
        paste2.tap()
        if allow.waitForExistence(timeout: 2) { allow.tap() }
        Thread.sleep(forTimeInterval: 0.6)
        snap("04-rtl-typed")
        XCTAssertTrue(bodyText.contains("תודה"), bodyText)
        hideKeyboard()
        let send3 = button(MailID.send)
        if !send3.isHittable { app.swipeUp() }
        send3.tap()
        XCTAssertTrue(waitForToast(containing: "Sending", timeout: 3))
        app.swipeUp()
        snap("05-rtl-sent")
        XCTAssertTrue(conversationShows("תודה, נדבר ביום חמישי", timeout: 3), "the RTL reply is in the conversation")
    }

    func testAHundredRecipients() {
        launch()
        element(MailID.compose).tap()
        XCTAssertTrue(toField.waitForExistence(timeout: 10))
        let list = (1...100).map { "person\($0)@many.example" }.joined(separator: ", ")
        UIPasteboard.general.string = list
        toField.tap()
        toField.press(forDuration: 1.0)
        let paste = app.menuItems["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 3), app.debugDescription)
        paste.tap()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow Paste"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
        Thread.sleep(forTimeInterval: 0.8)
        // A trailing comma commits the lot to chips.
        toField.typeText(",")
        let start = Date()
        let hundredth = chip("person100@many.example")
        let made = hundredth.waitForExistence(timeout: 20)
        note("a hundred pasted addresses became chips in \(Date().timeIntervalSince(start))s: \(made)")
        snap("00-hundred-chips")
        XCTAssertTrue(made, "the hundredth chip\n\(app.debugDescription)")
        XCTAssertTrue(chip("person1@many.example").exists)
        typeIntoBody("To all of you")
        hideKeyboard()
        let send = button(MailID.send)
        if !send.isHittable { app.swipeUp(); app.swipeUp() }
        snap("01-footer-with-hundred")
        XCTAssertTrue(send.waitForExistence(timeout: 3) && send.isHittable, "Send is reachable under a hundred chips")
        send.tap()
        XCTAssertTrue(waitForToast(containing: "Sending", timeout: 5))
    }

    func testPastingALargeBlockOfText() {
        launch(open: "q3", state: "reply")
        XCTAssertTrue(body.waitForExistence(timeout: 10))
        let paragraph = "This is a long paragraph that is pasted in whole, to see what the editor does with a great deal of text at once. "
        let big = String(repeating: paragraph, count: 180)   // about 20,000 characters
        UIPasteboard.general.string = big
        // A point near the top of the editor, not its middle: on an iPad on its side the keyboard
        // covers the lower part of the editor, and a press at its centre is a press on a key.
        let top = body.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.05))
        top.tap()
        Thread.sleep(forTimeInterval: 0.3)
        top.press(forDuration: 1.0)
        let paste = app.menuItems["Paste"]
        if !paste.waitForExistence(timeout: 3) { snap("00-no-paste-menu") }
        XCTAssertTrue(paste.exists, app.debugDescription)
        let start = Date()
        paste.tap()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow Paste"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
        let landed = body.waitForExistence(timeout: 10) && (body.value as? String)?.count ?? 0 > 10_000
        let took = Date().timeIntervalSince(start)
        note("pasting \(big.count) characters took \(took)s; landed: \(landed)")
        snap("00-big-paste")
        XCTAssertTrue(landed, "the text is in the editor: \(bodyText.count) characters")
        // The clock includes the 2 s the test waits for an "Allow Paste" alert, which the system
        // shows only on the first paste, so a bound of 5 s sat inside the noise of that wait (4.99 s
        // on the phone, 5.27 s on the iPad, with nothing else different). A stalled editor is a
        // hang of many seconds; that is what this is here to catch.
        XCTAssertLessThan(took, 15, "the paste did not stall the editor")
        hideKeyboard()
        app.swipeUp()
        let send = button(MailID.send)
        XCTAssertTrue(send.waitForExistence(timeout: 3), "Send is still reachable after a big paste")
        snap("01-after-big-paste-footer")
        send.tap()
        XCTAssertTrue(waitForToast(containing: "Sending", timeout: 5))
    }

    // MARK: Text sizes

    func testTheLargestTextSizeKeepsRowsApart() {
        launch(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        snap("00-xxxl-inbox")
        let keys = visibleRowKeys()
        // At this size a row is near 250 points: one whole row on a phone's screen is the truth.
        XCTAssertGreaterThanOrEqual(keys.count, 1, "\(keys)")
        let traits = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        let callout = UIFont.preferredFont(forTextStyle: .callout, compatibleWith: traits).lineHeight
        let subheadline = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits).lineHeight
        let needed = callout + 2 * subheadline
        let first = row(keys[0]).frame
        note("XXXL row height \(first.height), three lines need at least \(needed)")
        XCTAssertGreaterThanOrEqual(first.height, needed, "a three-line row grows with the text size (MAIL-UX 6.1.3)")
        openConversation(keys[0])
        snap("01-xxxl-conversation")
        XCTAssertTrue(element(MailID.back).exists)
        reply("Reply")
        Thread.sleep(forTimeInterval: 0.8)
        snap("02-xxxl-composer")
        // The row labels keep to one line each (To, From, Subject).
        let subject = app.staticTexts["Subject"].firstMatch
        XCTAssertTrue(subject.waitForExistence(timeout: 3))
        XCTAssertLessThan(subject.frame.height, subheadline * 1.6, "the Subject label is one line, not one letter a line")
    }

    func testTheSmallestTextSize() {
        launch(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXS"])
        snap("00-xs-inbox")
        openConversation("q3")
        snap("01-xs-conversation")
        reply("Reply")
        Thread.sleep(forTimeInterval: 0.8)
        snap("02-xs-composer")
        XCTAssertTrue(body.exists)
    }

    // MARK: The keyboard and the sheet

    func testTheKeyboardAndWhereSendIs() throws {
        try XCTSkipIf(hasPane, "the sheet and the keyboard over it are the phone's")
        launch(open: "q3", state: "reply")
        XCTAssertTrue(body.waitForExistence(timeout: 10))
        body.tap()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3), "the keyboard came up")
        body.typeText("\nline two\nline three\nline four\nline five\nline six\nline seven\nline eight")
        snap("00-typing-with-keyboard")
        let send = button(MailID.send)
        let keyboard = app.keyboards.firstMatch.frame
        let sendVisible = send.exists && send.isHittable && send.frame.maxY < keyboard.minY
        note("with the keyboard up, Send is reachable without dismissing it: \(sendVisible); keyboard top \(keyboard.minY), send \(send.frame)")
        // The caret's line is above the keyboard: the editor keeps what is typed in view.
        let caretLine = app.staticTexts["line eight"].firstMatch
        if !sendVisible {
            // Can Send be reached by scrolling the sheet, with the keyboard still up?
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.5)
            snap("01-scrolled-with-keyboard")
            note("after scrolling with the keyboard up, Send hittable: \(send.isHittable), frame \(send.frame)")
        }
        _ = caretLine
        hideKeyboard()
        snap("02-keyboard-hidden")
        note("after hiding the keyboard, Send hittable: \(send.isHittable); keyboard still up: \(app.keyboards.firstMatch.exists)")
    }

    func testDismissingTheSheetHalfwayKeepsItAndFullyKeepsTheDraft() throws {
        try XCTSkipIf(hasPane, "the composer is a sheet on the phone only")
        launch(open: "q3", state: "reply")
        XCTAssertTrue(body.waitForExistence(timeout: 10))
        typeIntoBody(" Halfway.")
        hideKeyboard()
        let top = composer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02))
        top.press(forDuration: 0.1, thenDragTo: top.withOffset(CGVector(dx: 0, dy: 220)))
        Thread.sleep(forTimeInterval: 1)
        snap("00-after-half-drag")
        XCTAssertTrue(body.exists, "a half drag springs back: the composer is still there")
        XCTAssertTrue(bodyText.contains("Halfway."), bodyText)
        top.press(forDuration: 0.1, thenDragTo: top.withOffset(CGVector(dx: 0, dy: 900)))
        XCTAssertTrue(waitGone(body, timeout: 5), "a full drag closes it")
        snap("01-after-full-drag")
        XCTAssertNil(toastText.flatMap { $0.contains("discard") ? $0 : nil }, "nothing was discarded")
        app.swipeUp()
        XCTAssertTrue(element(MailID.draftMarker).waitForExistence(timeout: 5), "the draft is kept and marked in the conversation (6.3.8)")
        snap("02-draft-marker")
        element(MailID.continueDraft).tap()
        XCTAssertTrue(body.waitForExistence(timeout: 10))
        XCTAssertTrue(bodyText.contains("Halfway."), "Continue reopens it with its text: \(bodyText)")
    }

    // MARK: Places that empty

    func testEmptyingTheInboxWithDones() {
        launch()
        var count = 0
        let start = Date()
        var completed = Set<String>()
        while count < 45 {
            var keys: [String] = []
            XCTAssertTrue(waitUntil {
                keys = self.visibleRowKeys()
                return !keys.isEmpty || self.app.staticTexts["Inbox clear"].exists
            }, "the next row or empty state must be ready")
            guard let top = keys.first else { break }
            XCTAssertFalse(completed.contains(top), "each Done must remove a different conversation")
            let target = row(top)
            if !fullSwipeDone(target) {
                snap("stuck-at-\(count)")
                let doneButton = app.buttons["Done"].firstMatch
                note("Done on \(top) did not remove its row (Done button showing: \(doneButton.exists))")
                guard doneButton.exists else { break }
                doneButton.tap()
                guard waitGone(target, timeout: 3) else { break }
            }
            completed.insert(top)
            count += 1
        }
        note("emptied the inbox with \(count) Dones in \(Date().timeIntervalSince(start))s")
        XCTAssertEqual(count, 40, "forty Dones for forty conversations")
        XCTAssertTrue(app.staticTexts["Inbox clear"].waitForExistence(timeout: 3), "the empty state (T19, 7.8)\n\(app.debugDescription)")
        XCTAssertEqual(headerCount(), 0)
        snap("00-inbox-clear")
        if hasPane {
            XCTAssertTrue(app.staticTexts["No conversation selected"].exists, "the pane is empty")
        }
        undoButton.tap()
        XCTAssertTrue(row("intro").waitForExistence(timeout: 3) || !visibleRowKeys().isEmpty, "Undo brings the last one back")
        snap("01-after-undo")
        XCTAssertEqual(headerCount(), 1)
    }
}
