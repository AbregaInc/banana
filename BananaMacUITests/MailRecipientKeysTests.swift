import XCTest

/// The recipient rows' keys: Shift-Cmd-C and -B reveal Cc and Bcc with the caret in them, Tab goes
/// through the fields in order, and completion takes the arrow keys and Return (MAIL-UX 4.2.6, 6.3.3).
final class MailRecipientKeysTests: MacMailTestCase {

    private func newMessage() {
        press("c")
        XCTAssertTrue(el(MailID.composer).waitForExistence(timeout: 8), "C opened no composer")
    }

    func testShiftCmdCAndShiftCmdBRevealCcAndBccWithTheCaretInTheNewField() {
        launchMail()
        newMessage()
        focus(MailID.composerTo)
        press("c", [.command, .shift])
        XCTAssertTrue(el(MailID.composerCc).waitForExistence(timeout: 5), "Cc did not appear")
        eventually("the caret to be in Cc (is: \(MacAX.focusedDescription()))") { self.hasFocus(MailID.composerCc) }
        press("b", [.command, .shift])
        XCTAssertTrue(el(MailID.composerBcc).waitForExistence(timeout: 5), "Bcc did not appear")
        eventually("the caret to be in Bcc (is: \(MacAX.focusedDescription()))") { self.hasFocus(MailID.composerBcc) }
        expectOnlyTheMainWindow("by Shift-Cmd-C and Shift-Cmd-B (Shift-Cmd-C is also the Colors panel's key)")
        shot("cc and bcc")
    }

    func testTabGoesToCcBccSubjectAndBodyInOrder() {
        launchMail()
        newMessage()
        focus(MailID.composerTo)
        press("c", [.command, .shift]); _ = el(MailID.composerCc).waitForExistence(timeout: 5)
        press("b", [.command, .shift]); _ = el(MailID.composerBcc).waitForExistence(timeout: 5)
        press("o", [.command, .shift])
        eventually("the caret to be in To (is: \(MacAX.focusedDescription()))") { self.hasFocus(MailID.composerTo) }
        for next in [MailID.composerCc, MailID.composerBcc, MailID.composerSubject, MailID.composerBody] {
            press(.tab)
            eventually("Tab to reach \(next) (is: \(MacAX.focusedDescription()))") { self.hasFocus(next) }
        }
        shot("tab order")
    }

    func testCompletionTakesTheArrowKeysAndReturn() {
        launchMail()
        newMessage()
        focus(MailID.composerTo)
        type("t")
        let list = el(MailID.composerSuggestions)
        XCTAssertTrue(list.waitForExistence(timeout: 5), "no suggestions for 't'")
        shot("suggestions")
        let offered = elements(withPrefix: MailID.composerSuggestions + ".").allElementsBoundByIndex
            .filter { $0.exists }
            .sorted { $0.frame.minY < $1.frame.minY }
            .map { String($0.identifier.dropFirst((MailID.composerSuggestions + ".").count)) }
        XCTAssertGreaterThanOrEqual(offered.count, 2, "the cases need two suggestions: \(offered)")
        press(.downArrow)
        press(.return)
        guard offered.count >= 2 else { return }
        XCTAssertTrue(el(MailID.chip(offered[1])).waitForExistence(timeout: 5),
                      "Down then Return should take the second suggestion \(offered[1]); the chips are \(elements(withPrefix: "mail.composer.chip.").allElementsBoundByIndex.map(\.identifier))")
        shot("completed")
    }

    func testReturnAloneTakesTheFirstSuggestion() {
        launchMail()
        newMessage()
        focus(MailID.composerTo)
        type("sa")
        XCTAssertTrue(el(MailID.suggestion(MacMailFixture.sam)).waitForExistence(timeout: 5), "Sam is offered for 'sa'")
        press(.return)
        XCTAssertTrue(el(MailID.chip(MacMailFixture.sam)).waitForExistence(timeout: 5), "Return did not take Sam")
    }
}
