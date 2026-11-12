import XCTest

final class MailReaderUITest: MailUITestCase {
    func testOriginalLayoutOpensAndReturnsToReader() {
        launch(open: "newsletter")
        let original = app.buttons["mail.body.original.newsletter~1"]
        XCTAssertTrue(original.waitForExistence(timeout: 10))
        original.tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.webViews.staticTexts["Dispatch"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.webViews.links["View event"].exists)
        snap("original-layout")
        app.buttons["sheet.close"].firstMatch.tap()
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        snap("reader-return")
    }

    private func openDisposalMenu() {
        let more = app.buttons.matching(NSPredicate(format: "identifier == %@ OR identifier == %@", "mail.pane.more", "mail.reader.more")).firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()
    }

    func testReaderExposesSpamAndSenderBlocking() {
        launch(open: "newsletter")
        openDisposalMenu()
        let spam = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "mail.action.spam", "Mark as spam")).firstMatch
        XCTAssertTrue(spam.waitForExistence(timeout: 5))
        let block = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "mail.sender.block", "Block sender")).firstMatch
        XCTAssertTrue(block.waitForExistence(timeout: 5))
        block.tap()
        let confirm = app.buttons["Block sender"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "will go to Spam")).firstMatch.exists)
        let dismiss = app.otherElements["PopoverDismissRegion"]
        if dismiss.exists { dismiss.tap() } else { app.buttons["Cancel"].firstMatch.tap() }
        openDisposalMenu()
        app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "mail.action.spam", "Mark as spam")).firstMatch.tap()
        XCTAssertTrue(waitForToast(containing: "spam"))
    }

    func testSenderCanBeUnblockedAndSpamCanReturnToInbox() {
        launch(open: "newsletter")
        openDisposalMenu()
        app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "mail.sender.block", "Block sender")).firstMatch.tap()
        let confirm = app.buttons["Block sender"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        show(place: "Spam")
        XCTAssertTrue(row("newsletter").waitForExistence(timeout: 5))
        guard row("newsletter").exists else { return }
        row("newsletter").tap()
        openDisposalMenu()
        let unblock = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "mail.sender.unblock", "Unblock sender")).firstMatch
        XCTAssertTrue(unblock.waitForExistence(timeout: 5))
        unblock.tap()
        openDisposalMenu()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "mail.sender.block", "Block sender")).firstMatch.waitForExistence(timeout: 5))
        let restore = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "mail.action.notSpam", "Not spam")).firstMatch
        XCTAssertTrue(restore.exists)
        restore.tap()
        XCTAssertTrue(waitForToast(containing: "back in the inbox"))
    }

    func testComplexTableUsesFormattedBodyAndRetainsActionLink() {
        launch(open: "receipt", extra: ["--mail-complex-html"])
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.webViews.links["Request refund"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.webViews.staticTexts["Notebook"].exists)
        XCTAssertTrue(app.webViews.staticTexts["$12"].exists)
        snap("formatted-complex-table")
        app.buttons["mail.body.simplify.receipt~1"].tap()
        XCTAssertTrue(waitUntil { self.app.webViews.count == 0 })
        let formatted = app.buttons["mail.body.format.receipt~1"]
        XCTAssertTrue(formatted.exists)
        formatted.tap()
        XCTAssertTrue(app.webViews.links["Request refund"].waitForExistence(timeout: 10))
    }

    func testFormattedBodyShrinksAndGrowsWhenRotated() {
        launch(open: "receipt", extra: ["--mail-wrap-html"])
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.links["Request refund"].waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil { web.frame.height > 320 })
        let portrait = web.frame
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitUntil(timeout: 10) { web.frame.width > portrait.width + 100 && web.frame.height < portrait.height - 30 })
        let landscape = web.frame
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(waitUntil(timeout: 10) { web.frame.width < landscape.width - 100 && web.frame.height > landscape.height + 30 })
        snap("formatted-body-rotation")
    }

    /// An open conversation reads newest first: the latest message at the top, older ones going
    /// down, and it opens at the top (the subject in view).
    func testAConversationReadsNewestFirst() {
        launch(open: "q3")
        let newest = app.buttons["mail.sender.q3~3"], oldest = app.buttons["mail.sender.q3~1"]
        XCTAssertTrue(newest.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(oldest.waitForExistence(timeout: 5))
        XCTAssertLessThan(newest.frame.minY, app.buttons["mail.sender.q3~2"].frame.minY)
        XCTAssertLessThan(app.buttons["mail.sender.q3~2"].frame.minY, oldest.frame.minY)
        let title = app.descendants(matching: .any)["mail.conversation.title"].firstMatch
        XCTAssertTrue(title.exists && title.frame.maxY < newest.frame.minY, "it opens at the top")
        XCTAssertTrue(newest.isHittable, "the newest is in view on opening")
        snap("newest-first")
    }

    /// Tapping a received attachment that is not on the device asks for it, shows it is coming and then opens
    /// it in the system viewer (Quick Look), with no "Couldn't download" on the chip.
    func testTappingAReceivedAttachmentFetchesItAndOpensTheSystemViewer() {
        launch(open: "q3")
        let chip = app.buttons["mail.conversation.attachment.Q3-revenue.xlsx"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10), app.debugDescription)
        chip.tap()
        // Quick Look's own view, titled with the file's name (without its extension).
        let viewer = app.otherElements["QLPreviewControllerView"]
        XCTAssertTrue(viewer.waitForExistence(timeout: 15), "Quick Look came up for the file: " + app.debugDescription)
        XCTAssertTrue(viewer.navigationBars.firstMatch.waitForExistence(timeout: 5), "with its own bar")
        XCTAssertFalse(app.staticTexts[MailID.attachmentFailure].exists)
        snap("attachment-opened")
    }
}
