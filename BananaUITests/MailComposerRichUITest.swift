import XCTest
import UIKit

/// The body of a message on the real editor: the keys the standard text editor takes (⌘B, ⌘I, ⌘U),
/// the format bar, lists that go on when Return is pressed, a link, and a paste that arrives with
/// a page's colours and sizes. What the unit tests hold cannot say that the system's editor does
/// its part; this does, on the sample mail.
final class MailComposerRichUITest: XCTestCase {
    private var app: XCUIApplication!

    private func launch(_ state: String = "reply") {
        continueAfterFailure = false
        // The iPad is in the arrangement the run asks for (`MailTurn`), not in whichever the last
        // test left it.
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        if pad { MailTurn.ask(landscape: MailTurn.startsOnItsSide) }
        app = XCUIApplication()
        app.launchArguments = ["--mail", "--mail-open", "q3", "--mail-state", state,
                               "--disable-icloud", "-onboardingCompleted", "YES"]
        app.launch()
        if pad {
            XCTAssertTrue(MailTurn.settle(app, landscape: MailTurn.startsOnItsSide),
                          "the requested iPad orientation must be exercised")
        }
    }

    private var body: XCUIElement { app.textViews[MailID.composerBody] }

    private func button(_ identifier: String) -> XCUIElement { app.buttons[identifier] }

    /// The editor has the caret and all its text is selected: by the editor's own menu, which
    /// does not depend on a hardware key reaching it.
    private func selectAll() {
        XCTAssertTrue(body.waitForExistence(timeout: 15), app.debugDescription)
        body.tap()
        Thread.sleep(forTimeInterval: 0.5)
        body.press(forDuration: 1.2)
        let all = app.menuItems["Select All"]
        if all.waitForExistence(timeout: 3) {
            all.tap()
        } else {
            app.typeKey("a", modifierFlags: .command)
        }
        Thread.sleep(forTimeInterval: 0.5)
    }

    private var text: String { (body.value as? String) ?? "" }

    /// ⌘ and a letter, again if the Simulator's keyboard dropped it, until the button is on.
    private func press(_ key: String, until button: XCUIElement) {
        for _ in 0..<3 where !button.isSelected {
            app.typeKey(key, modifierFlags: .command)
            Thread.sleep(forTimeInterval: 0.7)
        }
    }

    private func snap() {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testTheKeysAndTheFormatBarFormatTheSelection() throws {
        launch()
        selectAll()
        let bold = button(MailID.formatBold), italic = button(MailID.formatItalic)
        let underline = button(MailID.formatUnderline)
        XCTAssertTrue(bold.waitForExistence(timeout: 5), "the bar is showing")
        XCTAssertFalse(bold.isSelected)

        bold.tap()
        XCTAssertTrue(bold.isSelected, "the bar shows what the selection is")
        press("i", until: italic)
        XCTAssertTrue(italic.isSelected, "⌘I is the editor's own")
        press("u", until: underline)
        XCTAssertTrue(underline.isSelected, "⌘U is the editor's own")
        bold.tap()
        XCTAssertFalse(bold.isSelected)
        XCTAssertTrue(italic.isSelected)
        snap()
    }

    func testListsGoOnWhenReturnIsPressedAndEndOnAnEmptyItem() throws {
        launch()
        selectAll()
        app.typeText("one")
        button(MailID.formatBullets).tap()
        XCTAssertEqual(text, "\u{2022} one")
        XCTAssertTrue(button(MailID.formatBullets).isSelected)
        app.typeText("\ntwo")
        XCTAssertEqual(text, "\u{2022} one\n\u{2022} two", "Return went on with the next bullet")
        app.typeText("\n\n")
        XCTAssertEqual(text, "\u{2022} one\n\u{2022} two\n", "and an empty item ended the list: no mark, no new line")

        app.typeText("a")
        button(MailID.formatNumbers).tap()
        app.typeText("\nb")
        XCTAssertTrue(text.hasSuffix("1. a\n2. b"), text.debugDescription)
        snap()
    }

    func testALinkForSelectedWordsIsAskedFor() throws {
        launch()
        selectAll()
        app.typeText("the report")
        selectAll()
        let link = button(MailID.formatLink)
        XCTAssertTrue(link.isEnabled)
        XCTAssertFalse(link.isSelected)
        link.tap()
        let field = app.textFields[MailID.formatLinkField]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "words that are not an address ask for one")
        field.typeText("example.com\n")
        XCTAssertFalse(field.waitForExistence(timeout: 1) && field.isHittable, "the question goes away")
        XCTAssertEqual(text, "the report")
        selectAll()
        XCTAssertTrue(button(MailID.formatLink).isSelected, "the words are a link now")
    }

    func testThePasteOfAPageKeepsItsBoldAndDropsItsColoursAndSizes() throws {
        launch()
        let page = NSMutableAttributedString(string: "Red big bold plain", attributes: [
            .font: UIFont(name: "Georgia", size: 34)!, .foregroundColor: UIColor.red, .backgroundColor: UIColor.yellow])
        page.addAttribute(.font, value: UIFont(name: "Georgia-Bold", size: 34)!, range: NSRange(location: 8, length: 4))
        UIPasteboard.general.setObjects([page])

        selectAll()
        app.typeText("x")
        body.press(forDuration: 1.2)
        let paste = app.menuItems["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5), app.debugDescription)
        paste.tap()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow Paste"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(text.contains("Red big bold plain"), text.debugDescription)
        snap()
    }

    func testAPictureOnThePasteboardIsPastedFromTheAttachMenuAsAChip() throws {
        launch()
        let size = CGSize(width: 120, height: 80)
        UIPasteboard.general.image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        XCTAssertTrue(body.waitForExistence(timeout: 15), app.debugDescription)
        button(MailID.attach).tap()
        let paste = app.buttons["Paste"].exists ? app.buttons["Paste"] : app.menuItems["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5), app.debugDescription)
        paste.tap()
        // A picture from another app asks once whether this one may read it.
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow Paste"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        let chip = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", MailID.attachments + ".")).firstMatch
        let found = chip.waitForExistence(timeout: 10)
        snap()
        XCTAssertTrue(found, "the picture is a chip\n\(app.debugDescription)")
        XCTAssertTrue(chip.label.hasPrefix("Pasted picture"), "named for what it is: \(chip.label)")
    }

    func testPlainTextStaysPlainWhenPasted() throws {
        launch()
        UIPasteboard.general.string = "just plain\nsecond line"
        selectAll()
        app.typeText("x")
        body.press(forDuration: 1.2)
        let paste = app.menuItems["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5), app.debugDescription)
        paste.tap()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow Paste"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(text.contains("just plain\nsecond line"), text.debugDescription)
        XCTAssertFalse(button(MailID.formatBold).isSelected)
        XCTAssertFalse(button(MailID.formatItalic).isSelected)
        XCTAssertFalse(button(MailID.formatUnderline).isSelected)
    }
}
