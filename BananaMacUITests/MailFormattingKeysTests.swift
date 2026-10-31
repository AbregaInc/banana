import XCTest
import AppKit

/// The formatting keys act on the selection in the body and on nothing else (MAIL-UX 4.2.6): Cmd-B,
/// -I, -U, Cmd-K with words selected, the list and quote keys (Shift-Cmd-8, -7, -9), and a plain paste
/// (Shift-Cmd-V). The format bar marks a button `isSelected` when the selection has what it does.
final class MailFormattingKeysTests: MacMailTestCase {

    private func selectedWords(_ text: String = "the report") {
        launchMail()
        openReplyComposer()
        focus(MailID.composerBody)
        type(text)
        eventually("the text") { self.bodyText() == text }
        press("a", .command)
        settle(0.4)
        shot("selected")
    }

    private func expectNothingElseHappened(_ context: String) {
        XCTAssertTrue(hasComposer, "the composer went away \(context)")
        XCTAssertFalse(commandMenuIsUp, "the command menu opened \(context)")
        expectOnlyTheMainWindow(context)
    }

    func testCmdBCmdICmdUFormatTheSelectionAndDoNothingElse() {
        selectedWords()
        XCTAssertFalse(isOn(MailID.formatBold))
        press("b", .command)
        eventually("the Bold button to be on: Cmd-B must reach the editor (the Mac's main menu has no Format menu)") { self.isOn(MailID.formatBold) }
        press("i", .command)
        eventually("Italic on") { self.isOn(MailID.formatItalic) }
        press("u", .command)
        eventually("Underline on") { self.isOn(MailID.formatUnderline) }
        expectNothingElseHappened("by Cmd-B, Cmd-I, Cmd-U")
        shot("bold italic underline")
    }

    func testCmdKWithWordsSelectedIsALinkAndNotTheCommandMenu() {
        selectedWords()
        press("k", .command)
        XCTAssertTrue(el(MailID.formatLinkField).waitForExistence(timeout: 5), "Cmd-K with words selected asks for an address")
        XCTAssertFalse(commandMenuIsUp, "Cmd-K opened the command menu as well")
        shot("link")
        press(.escape)
        eventually("Escape to close only the link field") { !self.has(MailID.formatLinkField) }
        XCTAssertTrue(hasComposer, "cancelling a link keeps the composer open")
        XCTAssertEqual(bodyText(), "the report")
    }

    func testCmdKWithNothingSelectedIsTheCommandMenu() {
        launchMail()
        openReplyComposer()
        focus(MailID.composerBody)
        press("k", .command)
        eventually("the command menu") { self.commandMenuIsUp }
        shot("command menu")
        press(.escape)
        eventually("the command menu to close") { !self.commandMenuIsUp }
    }

    func testBulletsNumbersAndQuoteKeys() {
        selectedWords("one")
        press("8", [.command, .shift])
        eventually("a bullet (body \(bodyText().debugDescription))") { self.bodyText().hasPrefix("\u{2022}") }
        XCTAssertTrue(isOn(MailID.formatBullets))
        press("7", [.command, .shift])
        eventually("the numbered list button on") { self.isOn(MailID.formatNumbers) }
        press("9", [.command, .shift])
        eventually("the quote button on") { self.isOn(MailID.formatQuote) }
        expectNothingElseHappened("by Shift-Cmd-8, -7, -9 (Shift-Cmd-9 must not be Cmd-9: Library)")
        XCTAssertTrue(has(MailID.control) || has(MailID.list), "Mail is not in front: Shift-Cmd-9 went to the menu's Library")
    }

    func testShiftCmdVPastesPlainTextWithoutItsFormatting() {
        borrowPasteboard()
        let rich = NSMutableAttributedString(string: "plain words", attributes: [
            .font: NSFont(name: "Georgia-Bold", size: 30) ?? NSFont.boldSystemFont(ofSize: 30), .foregroundColor: NSColor.red])
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([rich])
        launchMail()
        openReplyComposer()
        focus(MailID.composerBody)
        press("v", [.command, .shift])
        eventually("the words in the body (is \(bodyText().debugDescription))") { self.bodyText().contains("plain words") }
        XCTAssertFalse(isOn(MailID.formatBold), "the paste kept the page's bold")
        shot("pasted plain")
    }
}
