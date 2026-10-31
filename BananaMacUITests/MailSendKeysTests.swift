import XCTest

/// Send, Undo, Send and Done, keeping a draft and discarding one (MAIL-UX 4.2.6, 6.3.7-6.3.8, T25,
/// T26, T38). Every message is the sample's: nothing is sent anywhere.
final class MailSendKeysTests: MacMailTestCase {

    private func writeAReply(_ text: String = "Thanks will do") {
        openReplyComposer()
        focus(MailID.composerBody)
        type(text)
        eventually("the text in the body") { self.bodyText() == text }
    }

    func testCmdReturnSendsAndTheToastsUndoReopensTheComposerWithItsText() {
        launchMail()
        writeAReply()
        press(.return, .command)
        eventually("the composer to close") { !self.hasComposer }
        waitForToast(containing: "Sending")
        shot("sending")
        XCTAssertTrue(el("toast.undo").waitForExistence(timeout: 3), "the toast offers Undo")
        el("toast.undo").click()
        XCTAssertTrue(el(MailID.composer).waitForExistence(timeout: 5), "Undo did not reopen the composer")
        XCTAssertEqual(bodyText(), "Thanks will do")
        shot("reopened")
    }

    func testZAfterASendReopensTheComposerWithItsText() {
        launchMail()
        writeAReply()
        press(.return, .command)
        waitForToast(containing: "Sending")
        press("z")
        XCTAssertTrue(el(MailID.composer).waitForExistence(timeout: 5), "Z did not reopen the composer")
        eventually("the text back") { self.bodyText() == "Thanks will do" }
    }

    func testShiftCmdReturnSendsAndMarksDoneAndOneUndoReversesBoth() {
        launchMail()
        writeAReply()
        press(.return, [.command, .shift])
        waitForToast(containing: "marked Done")
        XCTAssertEqual(placeCount("Inbox"), MacMailFixture.inboxCount - 1, "the conversation was not marked Done")
        shot("sent and done")
        press("z")
        XCTAssertTrue(el(MailID.composer).waitForExistence(timeout: 5), "one Undo did not reopen the composer")
        eventually("the conversation back in the inbox") { self.placeCount("Inbox") == MacMailFixture.inboxCount }
        XCTAssertEqual(bodyText(), "Thanks will do")
    }

    func testPlainCmdReturnDoesNotMarkTheConversationDone() {
        launchMail()
        writeAReply()
        press(.return, .command)
        waitForToast(containing: "Sending")
        XCTAssertNil(toast(containing: "marked Done"), "Cmd-Return sent AND marked Done: it took Send and Done's shortcut")
        XCTAssertEqual(placeCount("Inbox"), MacMailFixture.inboxCount)
    }

    func testEscKeepsADraftThatShowsInDraftsAndReopens() {
        launchMail()
        writeAReply("jkesuzrfc")
        press(.escape)
        eventually("Esc to close the composer") { !self.hasComposer }
        eventually("the Drafts count to be 1 (is \(String(describing: placeCount("Drafts"))))") { self.placeCount("Drafts") == 1 }
        shot("draft kept")
        place("Drafts").click()
        eventually("a row in Drafts") { !self.visibleRowKeys().isEmpty }
        shot("drafts")
        press(.return)
        XCTAssertTrue(el(MailID.composer).waitForExistence(timeout: 8), "Return in Drafts did not reopen the draft")
        eventually("the draft's text") { self.bodyText() == "jkesuzrfc" }
        shot("draft reopened")
    }

    func testShiftCmdCommaDiscardsWithUndo() {
        launchMail()
        writeAReply()
        press(",", [.command, .shift])
        eventually("the composer to go") { !self.hasComposer }
        waitForToast(containing: "Draft discarded")
        XCTAssertEqual(placeCount("Drafts"), 0)
        press("z")
        XCTAssertTrue(el(MailID.composer).waitForExistence(timeout: 5), "Undo did not bring the draft back")
        eventually("its text") { self.bodyText() == "Thanks will do" }
    }
}
