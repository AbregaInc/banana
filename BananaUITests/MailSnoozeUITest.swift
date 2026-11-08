import XCTest

/// Snooze on the sample mail, in the app's own layout (the bottom-bar shell on a phone, the rail on
/// an iPad): from a row's leading swipe, and from the reader's "…". Either way the picker's times
/// are one tap, the conversation leaves the inbox with a toast that says until when, and it is
/// in Snoozed.
final class MailSnoozeUITest: MailUITestCase {

    private func launchShell() {
        app = XCUIApplication()
        app.launchArguments += ["--ui-preview", "--ui-audit", "--disable-icloud", "--dummy-health",
                                "-finishSetupDismissed", "YES", "-onboardingCompleted", "YES", "--modules", "everything",
                                "--tab", "mail", "--mail-fresh"]
        app.withoutSpaceSync()
        app.launch()
        XCTAssertTrue(element(MailID.list).waitForExistence(timeout: 30), "the list came up\n\(app.debugDescription)")
    }

    private func expectInSnoozed(_ key: String) {
        element(MailID.placeMenu).tap()
        let snoozed = menuItem("Snoozed")
        XCTAssertTrue(snoozed.waitForExistence(timeout: 5), "Snoozed is a place\n\(app.debugDescription)")
        snoozed.tap()
        XCTAssertTrue(row(key).waitForExistence(timeout: 5), "\(key) is in Snoozed\n\(app.debugDescription)")
        snap("in-snoozed")
    }

    func testSnoozeFromTheLeadingSwipe() {
        launchShell()
        XCTAssertTrue(scrollToRow("q3"))
        shortSwipeLeading(row("q3"))
        let snooze = app.buttons["Snooze"].firstMatch
        XCTAssertTrue(snooze.waitForExistence(timeout: 3), "the leading swipe offers Snooze first\n\(app.debugDescription)")
        snooze.tap()
        let tomorrow = element(MailID.timePickerRow("tomorrow"))
        XCTAssertTrue(tomorrow.waitForExistence(timeout: 5), "the picker lists its times\n\(app.debugDescription)")
        snap("picker")
        XCTAssertTrue(element(MailID.timePickerRow("weekend")).exists)
        XCTAssertTrue(element(MailID.timePickerRow("monday")).exists, "Next week")
        XCTAssertTrue(element(MailID.snoozeCustom).exists, "a date and time of his own")
        tomorrow.tap()
        XCTAssertTrue(waitForToast(containing: "Snoozed"), "the toast says it was snoozed\n\(app.debugDescription)")
        XCTAssertTrue(waitGone(row("q3"), timeout: 5), "it left the inbox")
        expectInSnoozed("q3")
    }

    func testSnoozeFromTheReadersMoreMenu() throws {
        try XCTSkipIf(isPad, "the iPad's \u{2026} lists the times itself; the phone's opens the sheet")
        launchShell()
        XCTAssertTrue(scrollToRow("receipt"))
        row("receipt").tap()
        let more = app.buttons["mail.reader.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5), "the reader's \u{2026}\n\(app.debugDescription)")
        more.tap()
        // A menu's items keep their words, not always their identifiers (Star shows none either).
        let item = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", MailID.snoozeMenu, "Snooze\u{2026}")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "\u{2026} \u{203A} Snooze\u{2026}\n\(app.debugDescription)")
        item.tap()
        let weekend = element(MailID.timePickerRow("weekend"))
        XCTAssertTrue(weekend.waitForExistence(timeout: 5), "the picker, as a sheet\n\(app.debugDescription)")
        weekend.tap()
        XCTAssertTrue(waitForToast(containing: "Snoozed"), "the toast says it was snoozed\n\(app.debugDescription)")
        // Disposing, as Done is: the reader moves on to the next conversation, or back to the list.
        if element(MailID.back).exists { element(MailID.back).tap() }
        XCTAssertTrue(waitGone(row("receipt"), timeout: 5), "it left the inbox")
        expectInSnoozed("receipt")
    }
}
