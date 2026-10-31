import XCTest

/// Opening a composer from the keyboard: R, Return in an open conversation, F, C and Cmd-N, and the
/// rule that everything typed after one of them is the composer's (MAIL-UX K12), however fast.
final class MailReplyKeysTests: MacMailTestCase {

    private func expectNothingWasDone(_ context: String) {
        XCTAssertEqual(placeCount("Inbox"), MacMailFixture.inboxCount, "A conversation was marked Done \(context)")
        XCTAssertNil(toast(containing: "Done"), "A Done toast came up \(context)")
    }

    func testRThenEachTypedAtOnceLandsInTheReplyAndMarksNothingDone() {
        launchMail()
        type("rEach") // R, then E a, c, h, with nothing between them but the typist's few milliseconds
        XCTAssertTrue(el(MailID.composer).waitForExistence(timeout: 8), "R opened no composer")
        settle(1.5)
        shot("after R then Each")
        XCTAssertEqual(bodyText().trimmingCharacters(in: .whitespacesAndNewlines), "Each",
                       "the letters typed straight after R were lost; the caret is on: \(MacAX.focusedDescription())")
        expectNothingWasDone("by the E of \"Each\"")
    }

    func testRThenEachWithTheKeysSentOneAfterTheOtherToo() {
        launchMail()
        press("r")
        type("Each")
        XCTAssertTrue(el(MailID.composer).waitForExistence(timeout: 8))
        settle(1.5)
        XCTAssertEqual(bodyText().trimmingCharacters(in: .whitespacesAndNewlines), "Each",
                       "the caret is on: \(MacAX.focusedDescription())")
        expectNothingWasDone("by the E of \"Each\"")
    }

    func testAfterRTheCaretIsInTheBodyWithNoKeyPressedMeanwhile() {
        launchMail()
        press("r")
        XCTAssertTrue(el(MailID.composer).waitForExistence(timeout: 8))
        eventually("the caret to be in the body (it is: \(MacAX.focusedDescription()))", timeout: 3) { self.hasFocus(MailID.composerBody) }
    }

    func testReturnInAnOpenConversationIsReplyToAll() {
        launchMail()
        press(.return)
        eventually("open") { isOpen }
        press(.return)
        XCTAssertTrue(el(MailID.composer).waitForExistence(timeout: 8))
        XCTAssertTrue(el(MailID.chip(MacMailFixture.sam)).waitForExistence(timeout: 5), "Sam is addressed")
        XCTAssertTrue(el(MailID.chip(MacMailFixture.jane)).exists, "reply to all adds Jane (he leaves himself out)")
        shot("reply to all")
    }

    func testFForwardsWithNobodyAddressed() {
        launchMail()
        press("f")
        XCTAssertTrue(el(MailID.composer).waitForExistence(timeout: 8))
        XCTAssertFalse(el(MailID.chip(MacMailFixture.sam)).exists, "a forward goes to nobody yet")
        XCTAssertTrue(fieldText(MailID.composerSubject).hasPrefix("Fwd:"), "subject: \(fieldText(MailID.composerSubject))")
        shot("forward")
    }

    func testCAndCmdNOpenANewMessage() {
        launchMail()
        press("c")
        XCTAssertTrue(el(MailID.composer).waitForExistence(timeout: 8), "C opened no composer")
        shot("new message by C")
        press(.escape)
        eventually("Esc to close it") { !self.hasComposer }
        press("n", .command)
        XCTAssertTrue(el(MailID.composer).waitForExistence(timeout: 8), "Cmd-N opened no composer")
        shot("new message by Cmd-N")
    }

    func testEveryTriageLetterTypedInTheBodyIsText() {
        launchMail()
        openReplyComposer()
        focus(MailID.composerBody)
        type("jkesuzrfc")
        eventually("the letters in the body (is \(bodyText().debugDescription))") { self.bodyText() == "jkesuzrfc" }
        expectNothingWasDone("by a letter typed in the body")
        XCTAssertEqual(placeCount("Starred"), MacMailFixture.starredCount, "S starred while typing")
        shot("letters typed as text")
    }

    func testEveryTriageLetterTypedInTheSubjectAndTheToFieldIsText() {
        launchMail()
        press("c")
        XCTAssertTrue(el(MailID.composer).waitForExistence(timeout: 8))
        focus(MailID.composerSubject)
        type("jkesuzrfc")
        eventually("the letters in the subject") { self.fieldText(MailID.composerSubject) == "jkesuzrfc" }
        focus(MailID.composerTo)
        type("jkesuzrfc")
        eventually("the letters in To (is \(fieldText(MailID.composerTo).debugDescription))") { self.fieldText(MailID.composerTo).hasPrefix("jkesuzrfc") }
        expectNothingWasDone("by a letter typed in a field")
    }
}
