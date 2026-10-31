import XCTest

/// Where the caret is, and whether a keyboard is up, on touch: the composer asks for the caret
/// and looks again, a frame at a time, until the field has it (`MailCaretChase`). The ask must end
/// when the caret has landed or when he has put it somewhere himself — a tap elsewhere must stay
/// where it was tapped — and must not raise a keyboard where none was asked for. The send-later
/// picker takes the caret on a wide screen only, and the link field takes it wherever it opens.
///
/// The caret is read from the accessibility tree (`hasKeyboardFocus`), which is the field that
/// has the first responder, with a software keyboard or without one.
final class MailCaretTouchUITest: MailUITestCase {

    /// The identifier of the text field or text view that has the caret, if one has.
    private var focusedIdentifier: String? {
        let focused = NSPredicate(format: "hasKeyboardFocus == 1")
        for query in [app.textViews, app.textFields] {
            let hit = query.matching(focused).firstMatch
            if hit.exists { return hit.identifier }
        }
        return nil
    }

    /// True when the caret comes to the field within the time.
    private func waitForCaret(in identifier: String, timeout: TimeInterval = 6) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if focusedIdentifier == identifier { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    /// Longer than the chase can run (sixty frames), so a caret that is going to be taken back
    /// has been taken back by the time this is over.
    private func outlastTheChase() { Thread.sleep(forTimeInterval: 2.5) }

    private func beginReply(to key: String) {
        if hasPane {
            row(key).tap()
            Thread.sleep(forTimeInterval: 0.6)
        } else {
            openConversation(key)
        }
        reply("Reply")
    }

    /// A phone's software keyboard is down. (An iPad with a hardware keyboard has none to show,
    /// so only the first responder says anything there.)
    private var keyboardIsDown: Bool { isPad || app.keyboards.count == 0 }

    func testAReplyTakesTheCaretAndATapElsewhereAfterItKeepsTheCaretThere() {
        launch()
        beginReply(to: "q3")
        XCTAssertTrue(waitForCaret(in: MailID.composerBody), "the reply's caret is in its body, not \(focusedIdentifier ?? "nowhere")")
        subjectField.tap()
        XCTAssertTrue(waitForCaret(in: MailID.composerSubject), "the tap put the caret in Subject, not \(focusedIdentifier ?? "nowhere")")
        outlastTheChase()
        snap("00-subject-after-tap")
        XCTAssertEqual(focusedIdentifier, MailID.composerSubject, "the caret was not asked back into the body")
        app.typeText("Z")
        XCTAssertTrue(((subjectField.value as? String) ?? "").contains("Z"), "what was typed went where the tap put the caret")
        XCTAssertFalse(bodyText.contains("Z"), "and not into the body: \(bodyText)")
    }

    func testATapOnAnotherFieldRightAsTheComposerOpensStaysWhereItWasTapped() {
        launch()
        if hasPane {
            row("q3").tap()
            Thread.sleep(forTimeInterval: 0.6)
        } else {
            openConversation("q3")
        }
        // The reply menu, and the very next thing is a tap on Subject: no wait for the caret.
        let menu = element(MailID.replyMenu)
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        menuItem("Reply").tap()
        XCTAssertTrue(subjectField.waitForExistence(timeout: 10), "the composer came up")
        subjectField.tap()
        XCTAssertTrue(waitForCaret(in: MailID.composerSubject), "the caret is in Subject, not \(focusedIdentifier ?? "nowhere")")
        outlastTheChase()
        snap("00-subject-after-early-tap")
        XCTAssertEqual(focusedIdentifier, MailID.composerSubject, "the early tap was not undone by the ask for the body")
    }

    func testOpeningAndLeavingAConversationRaisesNoKeyboardAndTakesNoCaret() {
        launch()
        outlastTheChase()
        XCTAssertNil(focusedIdentifier, "a list takes no caret")
        XCTAssertTrue(keyboardIsDown, "and raises no keyboard")
        openConversation("q3")
        outlastTheChase()
        snap("00-conversation-open")
        XCTAssertNil(focusedIdentifier, "a conversation takes no caret: \(focusedIdentifier ?? "")")
        XCTAssertTrue(keyboardIsDown, "and raises no keyboard")
        if element(MailID.back).exists {
            element(MailID.back).tap()
            outlastTheChase()
            XCTAssertNil(focusedIdentifier, "going back takes no caret")
            XCTAssertTrue(keyboardIsDown)
        }
    }

    func testTheSendLaterPickerTakesTheCaretOnAWideScreenOnlyAndATapAfterItKeepsTheCaretThere() {
        launch()
        beginReply(to: "q3")
        XCTAssertTrue(waitForCaret(in: MailID.composerBody))
        hideKeyboard()
        let later = button(MailID.composerSendLater)
        if !later.isHittable { app.swipeUp() }
        later.tap()
        XCTAssertTrue(element(MailID.timePicker).waitForExistence(timeout: 5), "the picker\n\(app.debugDescription)")
        if isPad {
            XCTAssertTrue(waitForCaret(in: MailID.timePickerField), "on a wide screen the picker's field has the caret, not \(focusedIdentifier ?? "nowhere")")
            body.tap()
            XCTAssertTrue(waitForCaret(in: MailID.composerBody), "a tap on the body puts the caret there, not \(focusedIdentifier ?? "nowhere")")
            outlastTheChase()
            snap("00-body-after-picker")
            XCTAssertEqual(focusedIdentifier, MailID.composerBody, "the picker did not take the caret back")
        } else {
            // A phone's keyboard has no key that hides it (`hideKeyboard` finds nothing there), so
            // the caret is still in the body when the picker opens: it stays there, and the
            // picker's field does not take it.
            outlastTheChase()
            snap("00-picker-on-phone")
            XCTAssertEqual(focusedIdentifier, MailID.composerBody,
                           "on a phone the picker leaves the caret in the body: \(focusedIdentifier ?? "nowhere")")
        }
    }

    func testTheLinkFieldTakesTheCaretAndATapOnTheBodyAfterItKeepsTheCaretThere() {
        launch()
        beginReply(to: "q3")
        typeIntoBody("the report")
        body.press(forDuration: 1.2)
        let all = app.menuItems["Select All"]
        XCTAssertTrue(all.waitForExistence(timeout: 3), "the editor's Select All")
        all.tap()
        Thread.sleep(forTimeInterval: 0.4)
        button(MailID.formatLink).tap()
        XCTAssertTrue(app.textFields[MailID.formatLinkField].waitForExistence(timeout: 5), "words that are not an address ask for one")
        XCTAssertTrue(waitForCaret(in: MailID.formatLinkField), "the link field has the caret, not \(focusedIdentifier ?? "nowhere")")
        body.tap()
        XCTAssertTrue(waitForCaret(in: MailID.composerBody), "a tap on the body puts the caret there, not \(focusedIdentifier ?? "nowhere")")
        outlastTheChase()
        snap("00-body-after-link-field")
        XCTAssertEqual(focusedIdentifier, MailID.composerBody, "the link field did not take the caret back")
    }
}
