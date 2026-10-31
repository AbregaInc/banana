import XCTest

/// Writing mail through the touch interface: a reply kept as a draft, found in Drafts, finished,
/// sent, taken back inside the hold and sent again; reply to all and who it goes to; a forward with
/// its files; a new message with To, Cc, Bcc and a stranger; From and the signature; attachments;
/// formatting; and send later with presets and typed times. MAIL-UX 6.3 and 6.5 are the oracle.
final class MailComposeUITest: MailUITestCase {

    /// A reply written where a finger writes one: in the open conversation on a phone (a sheet),
    /// in the pane on an iPad (a card under the messages).
    private func beginReply(to key: String, _ style: String = "Reply") {
        if hasPane {
            row(key).tap()
            Thread.sleep(forTimeInterval: 0.6)
        } else {
            openConversation(key)
        }
        reply(style)
    }

    // MARK: Reply, draft, Drafts, send, undo, send

    func testReplyKeepDraftFindItFinishSendUndoAndSendAgain() {
        launch()
        beginReply(to: "q3")
        snap("00-composer")
        XCTAssertTrue(chip("sam@lee.example").waitForExistence(timeout: 5), "a reply goes to the sender\n\(app.debugDescription)")
        typeIntoBody("Thanks, tonight.")
        XCTAssertTrue(bodyText.contains("Thanks, tonight."), "typed: \(bodyText)")
        snap("01-typed")
        leaveComposerKeepingDraft()
        snap("02-left")
        XCTAssertFalse(body.exists, "the composer is gone")
        // On the phone the conversation is still open under where the sheet was: the draft's mark
        // is at its foot, and Back is the way to the places.
        if element(MailID.back).exists {
            app.swipeUp()
            XCTAssertTrue(element(MailID.draftMarker).waitForExistence(timeout: 5), "the conversation shows the kept draft (6.3.8)")
            snap("02b-draft-marker")
            element(MailID.back).tap()
        }

        // The draft is in Drafts, and the conversation's row says so.
        show(place: "Drafts")
        Thread.sleep(forTimeInterval: 0.6)
        snap("03-drafts")
        XCTAssertTrue(row("q3").waitForExistence(timeout: 5), "the reply's draft is listed in Drafts: \(visibleRowKeys())")
        XCTAssertEqual(headerCount(), 1)
        row("q3").tap()
        XCTAssertTrue(body.waitForExistence(timeout: 10), "choosing the draft opens its composer\n\(app.debugDescription)")
        Thread.sleep(forTimeInterval: 0.6)
        snap("04-reopened")
        XCTAssertTrue(bodyText.contains("Thanks, tonight."), "the draft's text is back: \(bodyText)")

        // Finish and send.
        body.tap()
        Thread.sleep(forTimeInterval: 0.3)
        body.typeText(" More tomorrow.")
        hideKeyboard()
        let send = button(MailID.send)
        XCTAssertTrue(send.waitForExistence(timeout: 3))
        if !send.isHittable { app.swipeUp() }
        send.tap()
        XCTAssertTrue(waitForToast(containing: "Sending", timeout: 5), "the toast reads Sending (6.3.6)")
        XCTAssertTrue(waitGone(body, timeout: 3), "the composer is gone after Send")
        snap("05-sending")
        // Undo inside the hold: the composer is open again as it was (6.3.7).
        XCTAssertTrue(undoButton.waitForExistence(timeout: 2), "Undo is on the toast")
        undoButton.tap()
        XCTAssertTrue(body.waitForExistence(timeout: 10), "Undo reopened the composer\n\(app.debugDescription)")
        Thread.sleep(forTimeInterval: 0.6)
        snap("06-undone-send")
        XCTAssertTrue(bodyText.contains("Thanks, tonight. More tomorrow."), "with its text: \(bodyText)")
        // Send again and let it go.
        hideKeyboard()
        let again = button(MailID.send)
        if !again.isHittable { app.swipeUp() }
        again.tap()
        XCTAssertTrue(waitForToast(containing: "Sending", timeout: 5))
        Thread.sleep(forTimeInterval: 11.5)
        snap("07-after-hold")
        XCTAssertNil(toastText, "the toast is gone with the hold; saw \(toastText ?? "")")
        // Sent from Drafts, the draft's row left that place; with a pane the place is empty and so
        // is the pane (T19, case 4), and the conversation is back in the inbox. Awkward in use —
        // the thread you just answered is gone from view — but the design's rule.
        if hasPane {
            show(place: "Inbox")
            Thread.sleep(forTimeInterval: 0.5)
            row("q3").tap()
            Thread.sleep(forTimeInterval: 0.8)
        }
        // The message is the last card of the conversation, marked as a sample.
        XCTAssertTrue(conversationShows("Thanks, tonight. More tomorrow.", timeout: 3)
                      || { app.swipeUp(); return conversationShows("Thanks, tonight. More tomorrow.", timeout: 3) }(),
                      "the sent message is in the conversation")
        XCTAssertTrue(conversationShows("nothing was really sent", timeout: 3), "marked as a sample")
        snap("08-sent-card")
    }

    // MARK: Reply to all

    func testReplyToAllGoesToEveryoneButMe() {
        launch()
        beginReply(to: "q3", "Reply to all")
        Thread.sleep(forTimeInterval: 0.8)
        snap("00-reply-all")
        // The newest message is from Sam to Jane and me: the sender and the original's To stay in
        // To, its Cc (nobody) in Cc, and never himself (MailReplyRules, the engine's rule; 6.3.3).
        XCTAssertTrue(chip("sam@lee.example").waitForExistence(timeout: 5), "Sam in To")
        XCTAssertTrue(chip("jane@parkdesign.example").exists, "Jane carried along")
        XCTAssertFalse(chip("noor@plan.example").exists, "never to himself")
        let sam = chip("sam@lee.example").frame, jane = chip("jane@parkdesign.example").frame
        note("Reply to all chips: Sam at y=\(Int(sam.minY)), Jane at y=\(Int(jane.minY)); Cc row shown: \(app.textFields[MailID.composerCc].exists)")
        XCTAssertEqual(Int(sam.minY), Int(jane.minY), "both in the To row, as the rule says")
        XCTAssertFalse(app.textFields[MailID.composerCc].exists, "no Cc row: the original had no Cc")
    }

    // MARK: Forward

    func testForwardCarriesTheFilesAndRefusesOverTheLimit() {
        launch()
        XCTAssertTrue(scrollToRow("attachments"), "\(visibleRowKeys())")
        beginReply(to: "attachments", "Forward")
        Thread.sleep(forTimeInterval: 1.2)
        snap("00-forward")
        for name in ["Services-agreement-signed.pdf", "logo-mark.png", "brand-assets.zip"] {
            XCTAssertTrue(element(MailID.attachmentChip(name)).waitForExistence(timeout: 5), "\(name) came along\n\(app.debugDescription)")
        }
        let summary = element(MailID.attachmentsSummary)
        XCTAssertTrue(summary.exists)
        note("forward summary line: \(summary.label)")
        XCTAssertTrue(summary.label.contains("Gmail takes"), "a forward over the limit says so (6.3.5): \(summary.label)")
        typeIntoBody("FYI")
        toField.tap()
        toField.typeText("sam@lee.example,")
        hideKeyboard()
        XCTAssertTrue(chip("sam@lee.example").waitForExistence(timeout: 3))
        let send = button(MailID.send)
        if !send.isHittable { app.swipeUp() }
        send.tap()
        XCTAssertTrue(waitForToast(containing: "Too large", timeout: 3), "Send refuses a message over the limit")
        XCTAssertTrue(body.exists, "and the composer stays")
        snap("01-refused")
        element(MailID.attachmentRemove("brand-assets.zip")).tap()
        XCTAssertTrue(waitForToast(containing: "Removed", timeout: 3), "the chip's x says so with Undo")
        XCTAssertTrue(waitGone(element(MailID.attachmentChip("brand-assets.zip")), timeout: 3))
        XCTAssertFalse(element(MailID.attachmentsSummary).label.contains("Gmail takes"), "under the limit now")
        snap("02-under-limit")
        let send2 = button(MailID.send)
        if !send2.isHittable { app.swipeUp() }
        send2.tap()
        XCTAssertTrue(waitForToast(containing: "Sending", timeout: 3), "the forward goes")
        snap("03-forward-sent")
    }

    // MARK: A new message

    func testNewMessageWithToCcBccFromCompletionAndATypedStranger() {
        launch()
        element(MailID.compose).tap()
        XCTAssertTrue(toField.waitForExistence(timeout: 10), "a new message\n\(app.debugDescription)")
        snap("00-new")
        toField.tap()
        toField.typeText("sa")
        let sam = element(MailID.suggestion("sam@lee.example"))
        XCTAssertTrue(sam.waitForExistence(timeout: 5), "completion offers Sam\n\(app.debugDescription)")
        snap("01-suggestions")
        sam.tap()
        XCTAssertTrue(chip("sam@lee.example").waitForExistence(timeout: 3))
        element(MailID.composerReveal("Cc")).tap()
        let cc = app.textFields[MailID.composerCc].firstMatch
        XCTAssertTrue(cc.waitForExistence(timeout: 3), "the Cc row appears")
        cc.tap()
        cc.typeText("ja")
        let jane = element(MailID.suggestion("jane@parkdesign.example"))
        XCTAssertTrue(jane.waitForExistence(timeout: 5), "completion in Cc")
        jane.tap()
        XCTAssertTrue(chip("jane@parkdesign.example").waitForExistence(timeout: 3))
        element(MailID.composerReveal("Bcc")).tap()
        let bcc = app.textFields[MailID.composerBcc].firstMatch
        XCTAssertTrue(bcc.waitForExistence(timeout: 3), "the Bcc row appears")
        bcc.tap()
        bcc.typeText("an")
        let ana = element(MailID.suggestion("ana@northwind.example"))
        XCTAssertTrue(ana.waitForExistence(timeout: 5), "completion in Bcc")
        ana.tap()
        XCTAssertTrue(chip("ana@northwind.example").waitForExistence(timeout: 3))
        // A typed address nobody matches: a chip by its address, outlined.
        toField.tap()
        toField.typeText("nobody@nowhere.example,")
        XCTAssertTrue(chip("nobody@nowhere.example").waitForExistence(timeout: 3), "a stranger's address becomes a chip on the comma")
        snap("02-four-chips")
        subjectField.tap()
        subjectField.typeText("Lunch")
        typeIntoBody("Thursday?")
        hideKeyboard()
        snap("03-ready")
        let send = button(MailID.send)
        if !send.isHittable { app.swipeUp() }
        send.tap()
        XCTAssertTrue(waitForToast(containing: "Sending", timeout: 3))
        snap("04-sent")
    }

    // MARK: From and the signature

    func testChangingFromSwapsTheSignatureAndItCanBeRemovedAndPutBack() {
        launch()
        element(MailID.compose).tap()
        XCTAssertTrue(toField.waitForExistence(timeout: 10))
        let from = element(MailID.composerFrom)
        XCTAssertTrue(from.waitForExistence(timeout: 5), "From shows: there are three addresses to send as")
        XCTAssertTrue(element(MailID.composerSignature).exists, "the default address signs")
        XCTAssertTrue(app.staticTexts["Abrega Inc. \u{00B7} plan.example"].exists, "with its own words")
        snap("00-default-signature")
        from.tap()
        let alias = element(MailID.composerFromChoice("hello@plan.example"))
        XCTAssertTrue(alias.waitForExistence(timeout: 3), "the list of addresses")
        snap("01-from-open")
        alias.tap()
        XCTAssertTrue(app.staticTexts["I read this address every morning."].waitForExistence(timeout: 5), "the signature changed with From")
        snap("02-alias-signature")
        from.tap()
        element(MailID.composerFromChoice("noor@work.example")).tap()
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertFalse(element(MailID.composerSignature).exists, "an address with no signature signs nothing")
        XCTAssertFalse(element(MailID.composerSignaturePutBack).exists, "and offers nothing to put back")
        snap("03-no-signature")
        from.tap()
        element(MailID.composerFromChoice("noor@plan.example")).tap()
        XCTAssertTrue(app.staticTexts["Abrega Inc. \u{00B7} plan.example"].waitForExistence(timeout: 5), "back to the first")
        // Off this message, and back.
        element(MailID.composerSignatureRemove).tap()
        XCTAssertTrue(waitGone(element(MailID.composerSignature), timeout: 3), "removed")
        let putBack = element(MailID.composerSignaturePutBack)
        XCTAssertTrue(putBack.waitForExistence(timeout: 3), "the way back")
        snap("04-removed")
        putBack.tap()
        XCTAssertTrue(element(MailID.composerSignature).waitForExistence(timeout: 5), "put back")
        snap("05-put-back")
    }

    // MARK: Attachments

    func testThreeAttachmentsRemoveOneUndoAndOneOverTheLimit() {
        launch(open: "q3", state: "attach")
        for name in ["agreement.pdf", "logo-mark.png", "q3-numbers.csv"] {
            XCTAssertTrue(element(MailID.attachmentChip(name)).waitForExistence(timeout: 10), "\(name)\n\(app.debugDescription)")
        }
        snap("00-three")
        XCTAssertTrue(element(MailID.attachmentsSummary).label.hasPrefix("3 attachments"), element(MailID.attachmentsSummary).label)
        element(MailID.attachmentRemove("logo-mark.png")).tap()
        XCTAssertTrue(waitGone(element(MailID.attachmentChip("logo-mark.png")), timeout: 3), "off at once")
        XCTAssertTrue(waitForToast(containing: "Removed \u{201C}logo-mark.png\u{201D}", timeout: 3), "the toast names it")
        snap("01-removed")
        // The toast and its Undo must be in front of the composer, sheet or card: found hidden
        // under the phone's sheet, where Undo could not be tapped.
        XCTAssertTrue(undoButton.isHittable, "the toast's Undo is in front of the composer")
        undoButton.tap()
        XCTAssertTrue(element(MailID.attachmentChip("logo-mark.png")).waitForExistence(timeout: 5), "Undo put it back")
        let order = ["agreement.pdf", "logo-mark.png", "q3-numbers.csv"].map { element(MailID.attachmentChip($0)).frame }
        note("chips after undo, x: \(order.map { Int($0.minX) }), y: \(order.map { Int($0.minY) })")
        snap("02-undone")
        // A look at one: Quick Look.
        element(MailID.attachmentChip("agreement.pdf")).tap()
        let quickLook = app.navigationBars.firstMatch
        let shown = quickLook.waitForExistence(timeout: 5)
        snap("03-quick-look")
        note("Quick Look came up for agreement.pdf: \(shown)")
        if shown {
            let done = app.buttons["Done"].firstMatch
            if done.waitForExistence(timeout: 3) { done.tap() } else { app.swipeDown() }
        }
        app.terminate()

        launch(open: "q3", state: "attach-over")
        let notice = element(MailID.attachmentsNotice)
        XCTAssertTrue(notice.waitForExistence(timeout: 15), "a file over the limit is refused in words\n\(app.debugDescription)")
        note("over-limit notice: \(notice.label)")
        XCTAssertTrue(notice.label.contains("recording.mov"), notice.label)
        XCTAssertFalse(element(MailID.attachmentChip("recording.mov")).exists, "and is not a chip")
        snap("04-over-limit")
    }

    func testThePaperclipOffersPhotosFilesAndPaste() {
        launch(open: "q3", state: "reply")
        XCTAssertTrue(body.waitForExistence(timeout: 10))
        let attach = button(MailID.attach)
        XCTAssertTrue(attach.waitForExistence(timeout: 5))
        attach.tap()
        snap("00-attach-menu")
        for item in ["Photos", "Files", "Paste"] {
            XCTAssertTrue(menuItem(item).waitForExistence(timeout: 3), "\(item) in the paperclip's menu")
        }
        menuItem("Photos").tap()
        Thread.sleep(forTimeInterval: 3)
        snap("01-photo-picker")
        let pickerUp = app.navigationBars.firstMatch.exists || app.otherElements["PXGGridLayout-Index:0"].exists
        note("The photo picker came up: \(pickerUp)")
        // The picker is the system's: a tap on its first picture, if the test can see one.
        let firstPhoto = app.images.firstMatch
        if firstPhoto.waitForExistence(timeout: 5), firstPhoto.isHittable {
            firstPhoto.tap()
            let add = app.buttons["Add"].firstMatch
            if add.waitForExistence(timeout: 3) { add.tap() }
            let chip = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", MailID.attachments + ".")).firstMatch
            let got = chip.waitForExistence(timeout: 10)
            note("A picture chosen in the photo picker became a chip: \(got)")
            snap("02-after-photo")
        } else {
            note("No picture was reachable in the photo picker from the test; stopped here.")
            let cancel = app.buttons["Cancel"].firstMatch
            if cancel.waitForExistence(timeout: 3) { cancel.tap() }
        }
        attach.tap()
        menuItem("Files").tap()
        Thread.sleep(forTimeInterval: 3)
        snap("03-file-picker")
        note("The document picker came up: \(app.navigationBars.firstMatch.exists)")
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.waitForExistence(timeout: 3) { cancel.tap() }
    }

    // MARK: Formatting

    func testFormatsFromTheBarThenSendShowsThem() {
        launch(open: "q3", state: "reply")
        XCTAssertTrue(body.waitForExistence(timeout: 10))
        // The caret at the end of the line the route typed; then a word in each style, a list,
        // numbers and a quote, the way the bar is used: the style on, the words, the style off.
        body.tap()
        Thread.sleep(forTimeInterval: 0.5)
        app.typeText("\n")
        button(MailID.formatBold).tap()
        XCTAssertTrue(button(MailID.formatBold).isSelected, "bold is on for what is typed next")
        app.typeText("strong")
        button(MailID.formatBold).tap()
        app.typeText(" ")
        button(MailID.formatItalic).tap()
        app.typeText("slanted")
        button(MailID.formatItalic).tap()
        app.typeText(" ")
        button(MailID.formatUnderline).tap()
        app.typeText("underlined")
        button(MailID.formatUnderline).tap()
        snap("00-three-styles")
        app.typeText("\nfirst")
        button(MailID.formatBullets).tap()
        XCTAssertTrue(bodyText.contains("\u{2022} first"), bodyText)
        app.typeText("\n")
        Thread.sleep(forTimeInterval: 0.3)
        app.typeText("second")
        app.typeText("\n")
        Thread.sleep(forTimeInterval: 0.3)
        app.typeText("\n")
        app.typeText("one")
        button(MailID.formatNumbers).tap()
        app.typeText("\n")
        Thread.sleep(forTimeInterval: 0.3)
        app.typeText("two")
        app.typeText("\n")
        Thread.sleep(forTimeInterval: 0.3)
        app.typeText("\n")
        button(MailID.formatQuote).tap()
        app.typeText("quoted words")
        snap("01-all-formats")
        let text = bodyText
        note("body after the formats: \(text.debugDescription)")
        XCTAssertTrue(text.contains("\u{2022} first\n\u{2022} second"), "Return goes on with the next bullet: \(text)")
        XCTAssertTrue(text.contains("1. one\n2. two"), "and the next number: \(text)")
        hideKeyboard()
        let send = button(MailID.send)
        if !send.isHittable { app.swipeUp() }
        send.tap()
        XCTAssertTrue(waitForToast(containing: "Sending", timeout: 3))
        Thread.sleep(forTimeInterval: 1)
        if !conversationShows("quoted words", timeout: 2) { app.swipeUp() }
        snap("02-sent-formatted")
        XCTAssertTrue(conversationShows("quoted words", timeout: 3), "the quote is in the sent message")
        XCTAssertTrue(conversationShows("slanted", timeout: 3))
        XCTAssertTrue(app.staticTexts["first"].exists || app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'first'")).firstMatch.exists, "the list items")
    }

    // MARK: Send later

    func testScheduleWithAPresetThenReschedulesCancelsUndoesAndSendsNow() {
        launch()
        beginReply(to: "q3")
        typeIntoBody("Later, then.")
        hideKeyboard()
        let later = button(MailID.composerSendLater)
        if !later.isHittable { app.swipeUp() }
        later.tap()
        XCTAssertTrue(element(MailID.timePicker).waitForExistence(timeout: 5), "the picker\n\(app.debugDescription)")
        snap("00-picker")
        let tomorrow = element(MailID.timePickerRow("tomorrow"))
        XCTAssertTrue(tomorrow.waitForExistence(timeout: 3))
        note("tomorrow row: \(tomorrow.label)")
        tomorrow.tap()
        XCTAssertTrue(waitGone(element(MailID.timePicker), timeout: 3), "choosing closes the picker in the same frame (6.5.4)")
        let line = element(MailID.composerSchedule)
        XCTAssertTrue(line.waitForExistence(timeout: 3), "the read-back line")
        note("schedule line: \(line.label)")
        let schedule = button(MailID.send)
        XCTAssertEqual(schedule.label, "Schedule", "the button now says Schedule (6.3.6)")
        snap("01-scheduled-line")
        if !schedule.isHittable { app.swipeUp() }
        schedule.tap()
        XCTAssertTrue(waitForToast(containing: "Scheduled for", timeout: 5), "the toast")
        XCTAssertTrue(waitGone(body, timeout: 3))
        snap("02-after-schedule")
        XCTAssertTrue(revealScheduledBanner(), "the message's card says it is scheduled\n\(app.debugDescription)")
        snap("03-banner")

        show(place: "Scheduled")
        Thread.sleep(forTimeInterval: 0.6)
        snap("04-scheduled-place")
        XCTAssertTrue(row("q3").waitForExistence(timeout: 5), "it is listed in Scheduled: \(visibleRowKeys())")
        row("q3").tap()
        Thread.sleep(forTimeInterval: 0.8)
        snap("05-scheduled-opened")
        XCTAssertTrue(revealScheduledBanner(), "the conversation with its scheduled card\n\(app.debugDescription)")

        // Reschedule by a typed time.
        element(MailID.scheduledReschedule).tap()
        let field = app.textFields[MailID.timePickerField].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the picker in the card")
        field.tap()
        field.typeText("fri 9")
        let typed = element(MailID.timePickerRow("typed"))
        XCTAssertTrue(typed.waitForExistence(timeout: 3), "the typed time is read: \(app.debugDescription)")
        note("typed 'fri 9' reads as: \(typed.label)")
        snap("06-typed-fri-9")
        typed.tap()
        XCTAssertTrue(waitForToast(containing: "Rescheduled for", timeout: 5), "rescheduled")
        snap("07-rescheduled")
        // Cancel, Undo, then send now.
        XCTAssertTrue(revealScheduledBanner())
        // At the end of the conversation there is no more content to scroll. Dismiss the
        // reschedule confirmation before tapping the Cancel row underneath its overlay.
        let confirmation = app.buttons["Dismiss"].firstMatch
        if confirmation.exists { confirmation.tap() }
        XCTAssertTrue(element(MailID.scheduledCancel).isHittable)
        element(MailID.scheduledCancel).tap()
        XCTAssertTrue(waitForToast(containing: "Back to a draft", timeout: 5))
        // In the Scheduled place the row leaves and, with a pane, the pane empties (T19); over a
        // phone's list the conversation stays open with its draft's mark. Undo is tapped inside
        // the toast's six seconds; the pictures come after.
        let marked = hasPane || element(MailID.draftMarker).waitForExistence(timeout: 2) || body.exists
        XCTAssertTrue(undoButton.waitForExistence(timeout: 2), "Undo is on the toast")
        undoButton.tap()
        snap("08-cancelled-then-undo")
        XCTAssertTrue(marked, "a draft again")
        if hasPane {
            XCTAssertTrue(row("q3").waitForExistence(timeout: 8), "Undo schedules it again: \(visibleRowKeys())")
            row("q3").tap()
            Thread.sleep(forTimeInterval: 0.8)
        }
        XCTAssertTrue(revealScheduledBanner(), "Undo schedules it again\n\(app.debugDescription)")
        snap("09-undo-cancel")
        element(MailID.scheduledSendNow).tap()
        XCTAssertTrue(waitForToast(containing: "Sending", timeout: 5), "Send now goes through the ordinary hold")
        snap("10-send-now")
    }

    func testTypedTimesAreReadBack() {
        launch(open: "q3", state: "picker")
        let field = app.textFields[MailID.timePickerField].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), app.debugDescription)
        var readings: [String: String] = [:]
        for phrase in ["tomorrow 8am", "fri 9", "in 2 hours", "nonsense words", "8am", "yesterday"] {
            field.tap()
            field.press(forDuration: 1.0)
            let all = app.menuItems["Select All"]
            if all.waitForExistence(timeout: 2) { all.tap() } else { app.typeKey("a", modifierFlags: .command) }
            field.typeText(phrase)
            Thread.sleep(forTimeInterval: 0.5)
            let typed = element(MailID.timePickerRow("typed"))
            let past = element(MailID.timePickerPast)
            readings[phrase] = typed.exists ? typed.label : (past.exists ? "PAST" : "not a time")
            snap("typed-\(phrase.replacingOccurrences(of: " ", with: "-"))")
        }
        note("typed times: \(readings)")
        XCTAssertNotEqual(readings["tomorrow 8am"], "not a time")
        XCTAssertNotEqual(readings["fri 9"], "not a time")
        XCTAssertNotEqual(readings["in 2 hours"], "not a time")
        XCTAssertEqual(readings["nonsense words"], "not a time", "words that are not a time show nothing (6.5.2)")
    }

    func testTheLateState() {
        launch(open: "q3", state: "late")
        XCTAssertTrue(element(MailID.scheduledBanner).waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(revealScheduledBanner(), "the late card is reachable\n\(app.debugDescription)")
        snap("00-late")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Not sent yet'")).firstMatch.exists, "the late words (7.7)")
        for id in [MailID.scheduledSendNow, MailID.scheduledKeep, MailID.scheduledReschedule, MailID.scheduledEdit] {
            XCTAssertTrue(element(id).exists, "\(id) offered")
        }
        element(MailID.scheduledKeep).tap()
        XCTAssertTrue(waitForToast(containing: "Kept as a draft", timeout: 5))
        snap("01-kept")
        show(place: "Drafts")
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertTrue(row("q3").waitForExistence(timeout: 5), "the draft is in Drafts, whole: \(visibleRowKeys())")
        snap("02-drafts")
    }
}
