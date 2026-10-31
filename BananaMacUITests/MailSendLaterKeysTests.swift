import XCTest

/// Send later: Shift-Cmd-L opens the time picker, a typed time ("tomorrow 8am") is read back and
/// taken, the message waits in Scheduled (MAIL-UX 6.3.6, 6.5).
final class MailSendLaterKeysTests: MacMailTestCase {

    func testShiftCmdLOpensThePickerAndATypedTimeSchedulesTheMessage() {
        launchMail()
        openReplyComposer()
        focus(MailID.composerBody)
        type("See you then")
        eventually("the text") { self.bodyText() == "See you then" }
        press("l", [.command, .shift])
        XCTAssertTrue(el(MailID.timePicker).waitForExistence(timeout: 5), "Shift-Cmd-L opened no picker")
        eventually("the caret to be in the picker's field (is: \(MacAX.focusedDescription()))", timeout: 3) {
            self.hasFocus(MailID.timePickerField)
        }
        shot("picker")
        type("tomorrow 8am")
        eventually("the typed time in the field") { self.fieldText(MailID.timePickerField) == "tomorrow 8am" }
        press(.return)
        XCTAssertTrue(el(MailID.composerSchedule).waitForExistence(timeout: 5), "no 'Sends …' line after Return")
        shot("scheduled line")
        XCTAssertEqual(bodyText(), "See you then", "the typed time went into the body")
    }

    func testAScheduledMessageIsInTheScheduledPlace() {
        launchMail()
        openReplyComposer()
        focus(MailID.composerBody)
        type("See you then")
        press("l", [.command, .shift])
        XCTAssertTrue(el(MailID.timePicker).waitForExistence(timeout: 5))
        focus(MailID.timePickerField)
        type("tomorrow 8am")
        press(.return)
        XCTAssertTrue(el(MailID.composerSchedule).waitForExistence(timeout: 5))
        press(.return, .command)
        waitForToast(containing: "Scheduled for")
        XCTAssertNil(toast(containing: "marked Done"), "Cmd-Return took Send and Done's shortcut")
        eventually("Scheduled to count one (is \(String(describing: placeCount("Scheduled"))))") { self.placeCount("Scheduled") == 1 }
        place("Scheduled").click()
        eventually("a row in Scheduled") { !self.visibleRowKeys().isEmpty }
        shot("scheduled place")
    }
}
