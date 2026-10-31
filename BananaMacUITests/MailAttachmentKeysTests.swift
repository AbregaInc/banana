import XCTest
import AppKit

/// Files: Shift-Cmd-A opens the file panel (and the case stops there: it cancels), a chip in the
/// composer and one on a received message each open Quick Look, a file on the pasteboard is pasted
/// from the Attach menu. Nothing is ever chosen in the panel and nothing leaves the Mac.
final class MailAttachmentKeysTests: MacMailTestCase {

    /// Quick Look's panel is a window of the app besides the main one.
    private func quickLookIsUp() -> Bool { app.windows.count > 1 }

    private func closeQuickLook() {
        press(.escape)
        if !eventually("Quick Look to close", timeout: 3, report: false, { !self.quickLookIsUp() }) {
            for window in app.windows.allElementsBoundByIndex where window.exists && window != mainWindow {
                window.buttons[XCUIIdentifierCloseWindow].click()
            }
        }
        eventually("Quick Look to be gone", timeout: 4) { !self.quickLookIsUp() }
    }

    func testShiftCmdAOpensTheFilePanelAndCancelAttachesNothing() {
        launchMail()
        openReplyComposer()
        focus(MailID.composerBody)
        press("a", [.command, .shift])
        eventually("the file panel (windows: \(app.windows.count), sheets: \(app.sheets.count))", timeout: 8) {
            self.app.sheets.count > 0 || self.app.windows.count > 1
        }
        shot("file panel")
        // Stop here: Escape cancels. Never Open.
        press(.escape)
        eventually("the panel to close") { self.app.sheets.count == 0 && self.app.windows.count == 1 }
        XCTAssertFalse(has(MailID.attachments), "a file was attached")
        shot("panel cancelled")
    }

    func testAChipInTheComposerOpensQuickLookAndEscClosesIt() {
        launchMail(state: "attach")
        let chip = elements(withPrefix: MailID.attachments + ".").matching(NSPredicate(format: "NOT identifier ENDSWITH '.remove' AND NOT identifier ENDSWITH '.summary' AND NOT identifier ENDSWITH '.notice'")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 15), "no attachment chip in the composer the route opened\n\(app.debugDescription)")
        chip.click()
        eventually("Quick Look to open (windows: \(app.windows.count))", timeout: 10) { self.quickLookIsUp() }
        shot("quick look")
        closeQuickLook()
        XCTAssertTrue(hasComposer, "the composer is still there")
    }

    func testAChipOnAReceivedMessageOpensQuickLookAndEscClosesIt() {
        launchMail()
        let chip = el(MailID.receivedAttachment("churn-chart.png"))
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "the first message of q3 has its chips")
        chip.click()
        eventually("Quick Look to open (windows: \(app.windows.count))", timeout: 12) { self.quickLookIsUp() }
        shot("quick look")
        closeQuickLook()
    }

    func testAFileOnThePasteboardIsPastedFromTheAttachMenuAsAChip() throws {
        borrowPasteboard()
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pasted-by-the-test.txt")
        try "from the clipboard".write(to: file, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([file as NSURL])
        launchMail()
        openReplyComposer()
        el(MailID.attach).click()
        let paste = app.menuItems["Paste File or Picture"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "the Attach menu has no paste item\n\(app.debugDescription)")
        paste.click()
        XCTAssertTrue(el(MailID.attachmentChip("pasted-by-the-test.txt")).waitForExistence(timeout: 10), "no chip for the pasted file")
        shot("pasted file")
    }

    func testDroppingAFileFromAnotherAppCannotBeDrivenFromHere() throws {
        throw XCTSkip("A drop needs a drag session that starts in another app (Finder) with the file under the pointer. XCUITest can drag only between elements of one app, and opening Finder would put a window on the owner's desktop. Drag a file from a folder onto the composer by hand.")
    }
}
