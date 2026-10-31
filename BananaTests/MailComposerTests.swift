#if DEBUG || MAIL_FIXTURES
import XCTest
import Combine

/// Writing mail, without the screen: the session around the real triage model, the real composer
/// model and the in-memory source, driven by the keys a person presses. What these hold is what
/// MAIL-UX 6.3 and K12 say: a reply opens addressed by the rules, a draft is kept when he leaves
/// and dropped when nothing was typed, a send is one undo entry and Send and Done is one for both,
/// and **a key typed before the caret is there is typing, never a command**.
@MainActor
final class MailComposerTests: XCTestCase {

    private let account = MailFixtureConversations.account

    private func id(_ key: String) -> MailConversationID {
        MailConversationID(account: account, thread: key)
    }

    /// A session on its own source, with timers that wait to be fired, a clock that is set by hand,
    /// and a toast that is recorded.
    @MainActor
    private final class Harness {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var source: MailFixtureSource!
        var toasts: [MailToast] = []
        var toastUndo: (@MainActor () -> Void)?
        var timers: [(delay: TimeInterval, work: @MainActor () -> Void, cancelled: Bool)] = []
        var session: MailSession!

        init() {
            source = MailFixtureSource(clock: { [unowned self] in self.now })
            session = MailSession(
                source: source, now: source.now, deviceName: "Mac",
                timers: MailTimers { [unowned self] delay, work in
                    self.timers.append((delay, work, false))
                    let index = self.timers.count - 1
                    return { self.timers[index].cancelled = true }
                },
                clock: { [unowned self] in self.now },
                present: { [unowned self] toast, undo in
                    self.toasts.append(toast)
                    self.toastUndo = undo
                })
            session.enter()
        }

        var shown: [String] { session.model.rows.map(\.id.thread) }
        var composer: MailComposerModel? { session.composer }

        /// A key as the Mac's monitor gives it to Mail: the unshifted letter, and what it typed.
        @discardableResult
        func press(_ key: Character, shift: Bool = false) -> Bool {
            session.handle(.character(Character(key.lowercased())), shift: shift,
                           typed: shift ? key.uppercased() : String(key))
        }

        func type(_ text: String) {
            for character in text { press(character, shift: character.isUppercase) }
        }

        func fire(after delay: TimeInterval) {
            guard let index = timers.firstIndex(where: { $0.delay == delay && !$0.cancelled }) else { return }
            timers[index].cancelled = true
            timers[index].work()
        }

        /// R on the cursor's conversation, and the draft has arrived.
        func reply() async -> MailComposerModel {
            press("r")
            let composer = self.composer!
            await composer.waitForDraft()
            return composer
        }

        func conversation(_ key: String) async -> MailConversation? {
            await source.conversation(MailConversationID(account: MailFixtureConversations.account, thread: key))
        }
    }

    func testRichEditKeepsLatestDraftWithoutReenteringEditorCallback() async throws {
        let h = Harness()
        let composer = await h.reply()
        // Drain setup's deferred notification before observing this editing transaction.
        await Task.yield()
        var insideEditorCallback = false
        var reentered = false
        let notified = expectation(description: "Deferred rich text notification")
        notified.assertForOverFulfill = false
        let observer = composer.objectWillChange.sink {
            if insideEditorCallback { reentered = true }
            notified.fulfill()
        }
        insideEditorCallback = true
        composer.rich = AttributedString("latest typed text")
        XCTAssertEqual(composer.body, "latest typed text")
        XCTAssertEqual(MailPlainText.string(try XCTUnwrap(composer.currentDraft()).body), "latest typed text")
        // Closing/saving before the next run-loop turn must already see the last keystroke.
        insideEditorCallback = false
        composer.flush()
        await fulfillment(of: [notified], timeout: 1)
        XCTAssertFalse(reentered)
        withExtendedLifetime(observer) {}
    }

    private func conversationOf(_ h: Harness, _ key: String) async throws -> MailConversation {
        let conversation = await h.conversation(key)
        return try XCTUnwrap(conversation)
    }

    private func lastMessage(_ h: Harness, _ key: String) async throws -> MailMessage {
        let conversation = try await conversationOf(h, key)
        return try XCTUnwrap(conversation.messages.last)
    }

    // MARK: Opening

    func testRInTheListOpensTheConversationWithAReplyAddressedToTheSender() async throws {
        let h = Harness()
        let composer = await h.reply()
        XCTAssertEqual(h.session.openConversation, id("q3"), "T38: it opens with the composer open")
        XCTAssertEqual(composer.host, id("q3"))
        XCTAssertEqual(composer.title, "Reply")
        XCTAssertEqual(composer.to.map(\.address), ["sam@lee.example"])
        XCTAssertEqual(composer.cc, [])
        XCTAssertEqual(composer.subject, "Re: Q3 numbers before Thursday")
        XCTAssertEqual(composer.body, "")
        XCTAssertTrue(composer.isReady)
        let quote = try XCTUnwrap(composer.quote)
        XCTAssertTrue(quote.attribution.hasPrefix("On "), quote.attribution)
        XCTAssertTrue(quote.attribution.hasSuffix("Sam Lee wrote:"), quote.attribution)
    }

    func testWithAPaneShowingRRepliesToTheConversationItShowsAndOpensNothing() async {
        let h = Harness()
        h.session.setPaneVisible(true)
        _ = h.press("j")                                  // the cursor is on the second row
        let cursor = h.session.model.cursor
        let composer = await h.reply()
        XCTAssertNil(h.session.openConversation, "the pane has it: there is nothing to open")
        XCTAssertEqual(composer.host, cursor)
    }

    func testReturnInAnOpenConversationRepliesToAllWithoutHimself() async {
        let h = Harness()
        h.session.open(id("q3"))
        XCTAssertTrue(h.session.handle(.returnKey))
        let composer = h.composer!
        await composer.waitForDraft()
        XCTAssertEqual(composer.title, "Reply to all")
        // Sam wrote it to Jane and him.
        XCTAssertEqual(composer.to.map(\.address), ["sam@lee.example", "jane@parkdesign.example"])
        XCTAssertFalse(composer.to.contains { $0.isMe })
        XCTAssertEqual(composer.subject, "Re: Q3 numbers before Thursday")
    }

    func testFForwardsWithNobodyToAndAnotherSubject() async {
        let h = Harness()
        h.press("f")
        let composer = h.composer!
        await composer.waitForDraft()
        XCTAssertEqual(composer.title, "Forward")
        XCTAssertEqual(composer.to, [])
        XCTAssertEqual(composer.subject, "Fwd: Q3 numbers before Thursday")
        XCTAssertTrue(composer.quote?.attribution.contains("Forwarded message") == true)
        XCTAssertTrue(composer.canSendAndDone)
    }

    func testCOpensANewMessageWithNobodyAndNoSubject() async {
        let h = Harness()
        h.press("c")
        let composer = h.composer!
        await composer.waitForDraft()
        XCTAssertEqual(composer.title, "New message")
        XCTAssertNil(composer.host)
        XCTAssertEqual(composer.to, [])
        XCTAssertEqual(composer.subject, "")
        XCTAssertNil(composer.quote)
        XCTAssertFalse(composer.canSendAndDone, "there is no conversation for it to be Done in")
        XCTAssertEqual(composer.focusRequest?.field, .to, "a new message starts in To")
    }

    func testTheCardIsThereBeforeTheDraftIs() {
        let h = Harness()
        h.press("r")
        let composer = h.composer
        XCTAssertNotNil(composer, "drawn in the frame after the key")
        XCTAssertEqual(composer?.isReady, false, "the draft arrives a moment after")
        XCTAssertEqual(composer?.focusRequest?.field, .body)
    }

    func testAKeptReplyIsTheOneARComesBackTo() async {
        let h = Harness()
        let first = await h.reply()
        h.session.composer?.focusLanded(on: .body)
        first.body = "Half a thought"
        h.session.closeComposer()
        let again = await h.reply()
        XCTAssertEqual(again.draftID, first.draftID, "the draft he began, not a second one")
        XCTAssertEqual(again.body, "Half a thought", "he continues where he was")
    }

    /// Found on the phone: a composer reopened on a draft put the caret in front of its text, and
    /// what was typed next went before what was written. The caret the composer asks for goes
    /// after the text, whether the draft is there when the caret lands or arrives under it.
    func testAReopenedDraftPutsTheCaretAfterItsText() async throws {
        let h = Harness()
        let first = await h.reply()
        first.focusLanded(on: .body)
        first.body = "Half a thought"
        h.session.closeComposer()
        let draft = try XCTUnwrap(first.draftID)

        // The caret lands before the draft is here.
        h.session.begin(.continuing(draft))
        let again = try XCTUnwrap(h.composer)
        let landedEarly = again.caretToEnd
        again.focusLanded(on: .body)
        XCTAssertEqual(again.caretToEnd, landedEarly, "an empty body has nothing to go after yet")
        await again.waitForDraft()
        XCTAssertEqual(again.body, "Half a thought")
        XCTAssertGreaterThan(again.caretToEnd, landedEarly, "the text arrived under the caret: the caret goes after it")
        h.session.closeComposer()

        // The draft is here before the caret lands.
        h.session.begin(.continuing(draft))
        let third = try XCTUnwrap(h.composer)
        await third.waitForDraft()
        let landedLate = third.caretToEnd
        third.focusLanded(on: .body)
        XCTAssertGreaterThan(third.caretToEnd, landedLate, "the caret he asked for lands after the text")
        // A second landing, which is his own tap, moves nothing.
        let afterTap = third.caretToEnd
        third.focusLanded(on: .subject)
        third.focusLanded(on: .body)
        XCTAssertEqual(third.caretToEnd, afterTap, "a tap of his own is left where it fell")
        h.session.closeComposer()

        // A fresh reply has no text to go after: the caret is left alone.
        let fresh = await h.reply()
        _ = fresh
        let blank = Harness()
        blank.press("c")
        let new = try XCTUnwrap(blank.composer)
        await new.waitForDraft()
        let before = new.caretToEnd
        new.focusLanded(on: .to)
        XCTAssertEqual(new.caretToEnd, before)
    }

    // MARK: Leaving

    func testEscapeKeepsTheDraftAndTheConversationShowsItsMark() async throws {
        let h = Harness()
        let composer = await h.reply()
        composer.focusLanded(on: .body)
        composer.body = "Thanks \u{2014} I'll look at it tonight."
        XCTAssertTrue(h.session.handle(.escape), "Esc is taken")
        XCTAssertNil(h.composer, "and leaves the composer")
        let conversation = try await conversationOf(h, "q3")
        XCTAssertEqual(conversation.draft, composer.draftID, "the conversation shows a draft")
        let row = try XCTUnwrap(h.session.model.rows.first { $0.id == id("q3") })
        XCTAssertEqual(row.reason, .draft(firstLine: "Thanks \u{2014} I'll look at it tonight."))
        XCTAssertEqual(MailRowDisplay(row, now: h.session.now).draft, "Thanks \u{2014} I'll look at it tonight.")
        let kept = await h.source.draft(try XCTUnwrap(composer.draftID))
        XCTAssertEqual(MailPlainText.string(try XCTUnwrap(kept).body), "Thanks \u{2014} I'll look at it tonight.")
    }

    func testAComposerNothingWasTypedIntoLeavesNothingBehind() async throws {
        let h = Harness()
        let composer = await h.reply()
        let draft = try XCTUnwrap(composer.draftID)
        h.session.closeComposer()
        let found = await h.source.draft(draft)
        XCTAssertNil(found, "discarded as it closed")
        let conversation = try await conversationOf(h, "q3")
        XCTAssertNil(conversation.draft)
        XCTAssertNil(h.session.model.rows.first { $0.id == id("q3") }?.reason)
        XCTAssertTrue(h.session.undoStack.isEmpty, "no undo entry")
        XCTAssertTrue(h.toasts.isEmpty, "and no toast")
    }

    func testWhiteSpaceAloneIsNothing() async throws {
        let h = Harness()
        let composer = await h.reply()
        composer.body = " \n  \n"
        let draft = try XCTUnwrap(composer.draftID)
        h.session.closeComposer()
        let found = await h.source.draft(draft)
        XCTAssertNil(found)
    }

    func testChangingWhoItGoesToIsSomethingTypedIntoIt() async throws {
        let h = Harness()
        let composer = await h.reply()
        composer.remove(try XCTUnwrap(composer.to.first))
        XCTAssertTrue(composer.hasContent)
        let draft = try XCTUnwrap(composer.draftID)
        h.session.closeComposer()
        let found = await h.source.draft(draft)
        XCTAssertNotNil(found)
    }

    func testANewMessageSetAsideIsKeptAndCComesBackToIt() async throws {
        let h = Harness()
        h.press("c")
        let composer = h.composer!
        await composer.waitForDraft()
        composer.focusLanded(on: .subject)
        composer.subject = "Lunch"
        h.session.closeComposer()
        XCTAssertEqual(h.toasts.last, MailToastText.draftKept)
        XCTAssertEqual(h.session.keptNewDraft, composer.draftID)
        h.press("c")
        let again = h.composer!
        await again.waitForDraft()
        XCTAssertEqual(again.draftID, composer.draftID)
        XCTAssertEqual(again.subject, "Lunch")
    }

    func testANewMessageNothingWasTypedIntoIsNotKept() async throws {
        let h = Harness()
        h.press("c")
        let composer = h.composer!
        await composer.waitForDraft()
        let draft = try XCTUnwrap(composer.draftID)
        h.session.closeComposer()
        let found = await h.source.draft(draft)
        XCTAssertNil(found)
        XCTAssertNil(h.session.keptNewDraft)
        XCTAssertTrue(h.toasts.isEmpty)
    }

    func testBackLeavesTheComposerAndKeepsTheDraft() async throws {
        let h = Harness()
        let composer = await h.reply()
        composer.body = "Not yet"
        h.session.close()
        XCTAssertNil(h.composer)
        XCTAssertNil(h.session.openConversation)
        let kept = await h.source.draft(try XCTUnwrap(composer.draftID))
        XCTAssertNotNil(kept)
    }

    func testDiscardingIsExplicitAndHasUndoAndAsksNothing() async throws {
        let h = Harness()
        let composer = await h.reply()
        composer.body = "Never mind"
        let draft = try XCTUnwrap(composer.draftID)
        h.session.discardComposer()
        XCTAssertNil(h.composer)
        let gone = await h.source.draft(draft)
        XCTAssertNil(gone)
        XCTAssertEqual(h.toasts.last, MailToastText.draftDiscarded)
        XCTAssertEqual(h.toasts.last?.action, .undo)
        XCTAssertEqual(h.session.undoStack.count, 1)

        h.session.undoTop()
        let back = h.composer
        await back?.waitForDraft()
        XCTAssertEqual(back?.draftID, draft, "Undo brings the draft back, and he is writing it again")
        XCTAssertEqual(back?.body, "Never mind")
        XCTAssertEqual(h.toasts.last, MailToast(text: "Undone", action: nil))
    }

    func testAKeptDraftIsDiscardedFromItsMarkWithTheSameUndo() async throws {
        let h = Harness()
        let composer = await h.reply()
        composer.body = "Maybe"
        h.session.closeComposer()
        let draft = try XCTUnwrap(composer.draftID)
        h.session.discardKept(draft)
        let conversation = try await conversationOf(h, "q3")
        XCTAssertNil(conversation.draft)
        XCTAssertEqual(h.toasts.last, MailToastText.draftDiscarded)
        h.toastUndo?()
        let restored = try await conversationOf(h, "q3")
        XCTAssertEqual(restored.draft, draft, "the mark is back with the draft")
    }

    // MARK: Saving

    func testTheDraftIsHandedToTheSourceThreeHundredMillisecondsAfterTheLastEdit() async throws {
        let h = Harness()
        let composer = await h.reply()
        let draft = try XCTUnwrap(composer.draftID)
        composer.body = "One"
        composer.body = "One two"
        let before = await h.source.draft(draft)
        XCTAssertEqual(MailPlainText.string(try XCTUnwrap(before).body), "", "not on every keystroke")
        h.fire(after: MailComposerModel.saveAfter)
        let after = await h.source.draft(draft)
        XCTAssertEqual(MailPlainText.string(try XCTUnwrap(after).body), "One two")
        XCTAssertEqual(MailComposerModel.saveAfter, 0.3)
    }

    func testBackgroundingWritesWhatIsWrittenDownAtOnce() async throws {
        let h = Harness()
        let composer = await h.reply()
        composer.body = "Typed a second ago"
        h.session.flushComposer()
        let saved = await h.source.draft(try XCTUnwrap(composer.draftID))
        XCTAssertEqual(MailPlainText.string(try XCTUnwrap(saved).body), "Typed a second ago")
    }

    func testWhatHeTypedIsInTheSessionAndStillOpenWhenTheViewsAreGone() async {
        // The views are made and thrown away by the tree; the composer is the session's.
        let h = Harness()
        let composer = await h.reply()
        composer.body = "Still here"
        XCTAssertTrue(h.composer === composer)
        XCTAssertEqual(h.composer?.body, "Still here")
        h.session.leave()
        h.session.enter()
        XCTAssertTrue(h.composer === composer, "leaving and entering Mail does not close it")
    }

    // MARK: Typing is never taken as commands, and commands never as typing (K12)

    func testLettersTypedBetweenRAndTheCaretLandInTheReplyAndMarkNothingDone() async {
        let h = Harness()
        h.press("r")
        let composer = h.composer!
        XCTAssertTrue(composer.awaitingFocus, "asked for, not here yet")
        // "Each", at the speed of a hand, before the caret has appeared.
        h.type("Each")
        XCTAssertEqual(h.shown.count, 40, "E did not mark the conversation Done")
        XCTAssertEqual(h.shown.first, "q3")
        XCTAssertTrue(h.session.undoStack.isEmpty)
        XCTAssertTrue(h.toasts.isEmpty)
        XCTAssertEqual(composer.typedAhead, "Each", "queued, in order")
        XCTAssertEqual(composer.body, "")

        await composer.waitForDraft()
        composer.focusLanded(on: .body)
        XCTAssertEqual(composer.body, "Each", "and put into the reply when the caret lands")
        XCTAssertEqual(composer.typedAhead, "")
        XCTAssertFalse(composer.awaitingFocus)
        XCTAssertEqual(h.shown.count, 40)
        XCTAssertTrue(h.session.undoStack.isEmpty)
    }

    func testEveryKeyIsTakenForTheComposerAndNoneRunsAMailCommand() async {
        let h = Harness()
        h.press("r")
        let composer = h.composer!
        let cursor = h.session.model.cursor
        for key: Character in ["j", "k", "e", "s", "u", "z", "c", "f", "r", "\\", "]"] {
            XCTAssertTrue(h.press(key), "\(key) is taken, so nothing else sees it")
        }
        for key in [MailKey.up, .down, .left, .right] {
            XCTAssertTrue(h.session.handle(key))
        }
        XCTAssertEqual(h.shown.count, 40)
        XCTAssertEqual(h.session.model.cursor, cursor, "J and K did not move the cursor")
        XCTAssertTrue(h.session.undoStack.isEmpty, "E did not mark anything Done, Z undid nothing")
        XCTAssertTrue(h.composer === composer, "R and C did not open a second composer")
        XCTAssertEqual(composer.typedAhead, "jkesuzcfr\\]", "they are all typing, in order")
    }

    func testWhileTheComposerHasTheCaretJKAndEAreLettersToo() async {
        let h = Harness()
        let composer = await h.reply()
        composer.focusLanded(on: .body)
        // The caret is in the text: the monitor never offers Mail a key. Were one offered anyway,
        // by a click that took the caret away, it is queued and the caret asked for again.
        XCTAssertFalse(composer.awaitingFocus)
        h.type("jke")
        XCTAssertTrue(composer.awaitingFocus, "the caret is asked for again")
        XCTAssertEqual(composer.typedAhead, "jke")
        XCTAssertEqual(h.shown.count, 40, "none of them was a command")
        composer.focusLanded(on: .body)
        XCTAssertEqual(composer.body, "jke")
    }

    func testBackspaceAndReturnAreTypingToo() async {
        let h = Harness()
        h.press("r")
        let composer = h.composer!
        h.type("Hix")
        XCTAssertTrue(h.session.handle(.delete))
        XCTAssertTrue(h.session.handle(.returnKey))
        h.type("ok")
        await composer.waitForDraft()
        composer.focusLanded(on: .body)
        XCTAssertEqual(composer.body, "Hi\nok")
        XCTAssertEqual(h.shown.count, 40)
    }

    func testTypedAheadTextGoesAfterWhatTheDraftAlreadyHas() async {
        let h = Harness()
        let first = await h.reply()
        first.body = "Began"
        h.session.closeComposer()
        h.press("r")                                      // back to the draft, before it has arrived
        let composer = h.composer!
        h.type("ing")
        composer.focusLanded(on: .body)                   // the caret before the draft
        await composer.waitForDraft()
        XCTAssertEqual(composer.body, "Beganing", "after the text the draft has")
    }

    func testEscapeBeforeTheCaretCancelsTheComposerAndThrowsTheQueueAway() {
        let h = Harness()
        h.press("r")
        let composer = h.composer!
        h.type("Eac")
        XCTAssertTrue(h.session.handle(.escape))
        XCTAssertNil(h.composer)
        XCTAssertEqual(composer.typedAhead, "", "the queue went with it")
        XCTAssertEqual(h.shown.count, 40)
    }

    func testCommandsAreCommandsAgainOnceTheComposerIsClosed() async {
        let h = Harness()
        let composer = await h.reply()
        _ = composer
        h.session.closeComposer()
        h.session.close()
        XCTAssertNil(h.session.openConversation)
        h.press("e")
        XCTAssertEqual(h.shown.count, 39, "E is Done again, and Mail's")
        XCTAssertEqual(h.session.undoStack.count, 1)
    }

    func testAQueueForACaretThatNeverComesIsThrownAwayAfterOneSecond() {
        let h = Harness()
        h.press("r")
        let composer = h.composer!
        h.type("lost")
        XCTAssertEqual(composer.typedAhead, "lost")
        h.fire(after: MailComposerModel.caretWithin)
        XCTAssertEqual(composer.typedAhead, "")
        XCTAssertFalse(composer.awaitingFocus)
        XCTAssertEqual(MailComposerModel.caretWithin, 1)
    }

    // MARK: The caret is asked for until it lands (`MailCaretChase`)

    func testTheCaretIsAskedForUntilItLandsAndNoLonger() {
        let h = Harness()
        h.press("r")
        let composer = h.composer!
        let request = composer.focusRequest!
        XCTAssertTrue(composer.isAsking(for: request), "the screen still has to put the caret in the reply")
        composer.focusLanded(on: .body)
        XCTAssertFalse(composer.isAsking(for: request), "it has landed")
    }

    func testARequestIsNotAskedForOnceANewerOneIsMade() {
        let h = Harness()
        h.press("r")
        let composer = h.composer!
        let first = composer.focusRequest!
        composer.askForFocus(.subject)
        let second = composer.focusRequest!
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(composer.isAsking(for: first))
        XCTAssertTrue(composer.isAsking(for: second))
    }

    func testACaretHeTappedIntoAnotherFieldAnswersTheRequestAndIsNotMovedBack() {
        let h = Harness()
        h.press("r")
        let composer = h.composer!
        let request = composer.focusRequest!
        XCTAssertEqual(request.field, .body)
        composer.focusLanded(on: .subject)                 // he clicked into Subject first
        XCTAssertFalse(composer.isAsking(for: request), "the caret is where he put it")
    }

    func testAskingAgainForTheFieldTheCaretIsInIsAskedForUntilTold() {
        let h = Harness()
        h.press("r")
        let composer = h.composer!
        composer.focusLanded(on: .body)
        composer.askForFocus(.body)
        let again = composer.focusRequest!
        XCTAssertTrue(composer.isAsking(for: again), "the caret is there, but the request has not been told")
        composer.focusLanded(on: .body)
        XCTAssertFalse(composer.isAsking(for: again))
    }

    func testAClosedComposerAsksForNothing() {
        let h = Harness()
        h.press("r")
        let composer = h.composer!
        let request = composer.focusRequest!
        h.session.closeComposer()
        XCTAssertFalse(composer.isAsking(for: request))
    }

    func testTheCaretIsStillAskedForAfterTheQueueWasThrownAway() {
        let h = Harness()
        h.press("r")
        let composer = h.composer!
        let request = composer.focusRequest!
        h.type("lost")
        h.fire(after: MailComposerModel.caretWithin)
        XCTAssertEqual(composer.typedAhead, "", "the keys typed meanwhile are gone (K12)")
        XCTAssertFalse(composer.awaitingFocus)
        XCTAssertTrue(composer.isAsking(for: request), "a slow machine still gets its caret, only late")
    }

    func testTheKeysTypedAheadFollowTheCaretToWhicheverFieldItLandsIn() async {
        let h = Harness()
        h.press("c")
        let composer = h.composer!
        h.type("sa")
        await composer.waitForDraft()
        composer.focusLanded(on: .to)
        XCTAssertEqual(composer.toText, "sa", "a new message starts in To")
        XCTAssertEqual(composer.body, "")
    }

    // MARK: Typing re-evaluates the composer and nothing else

    func testTypingChangesNothingTheListThePaneOrTheConversationReads() async {
        let h = Harness()
        h.session.setPaneVisible(true)
        let composer = await h.reply()
        let reader = h.session.pane.reader
        var publications: [String] = []
        var watching: [AnyCancellable] = []
        watching.append(h.session.feed.objectWillChange.sink { publications.append("list") })
        watching.append(h.session.pane.objectWillChange.sink { publications.append("pane") })
        watching.append(h.session.navigation.objectWillChange.sink { publications.append("navigation") })
        if let reader { watching.append(reader.objectWillChange.sink { publications.append("reader") }) }
        var observed = 0
        watching.append(composer.objectWillChange.sink { observed += 1 })

        composer.focusLanded(on: .body)
        for character in "A line long enough to be typed over a second" {
            composer.body += String(character)
        }
        composer.subject = "Re: changed"
        XCTAssertEqual(publications, [], "a keystroke is the composer's alone")
        // Rich edits are coalesced until the native editor callback returns. Requiring one
        // synchronous publication per character would reinstate the macOS reentrancy crash.
        await Task.yield()
        XCTAssertEqual(publications, [], "deferred rich edits must also leave other views alone")
        XCTAssertGreaterThan(observed, 0, "the composer still publishes its changed content")
        withExtendedLifetime(watching) {}
    }

    // MARK: Recipients

    func testToCompletesAgainstThePeopleInTheSampleMailKnownOnesFirst() async throws {
        let h = Harness()
        let found = await h.source.people(matching: "s", limit: 6)
        XCTAssertTrue(found.count <= 6)
        XCTAssertEqual(found.first?.address, "sam@lee.example", "someone he has written to comes first")
        XCTAssertFalse(found.contains { $0.isMe }, "never himself")
        let known = found.prefix { $0.isKnown }
        XCTAssertTrue(found.dropFirst(known.count).allSatisfy { $0.fromTheirMail && !$0.isKnown },
                      "the people who only wrote to him come last, and are marked")
        let none = await h.source.people(matching: "zzzz", limit: 6)
        XCTAssertEqual(none, [])
    }

    func testTypingInToOffersTheNamesAndTakingOneMakesAChip() async throws {
        let h = Harness()
        h.press("c")
        let composer = h.composer!
        await composer.waitForDraft()
        composer.toText = "sa"
        await composer.waitForSuggestions()
        XCTAssertEqual(composer.suggestions.first?.address, "sam@lee.example")
        XCTAssertEqual(composer.highlighted, 0)
        composer.acceptHighlightedOrCommit()
        XCTAssertEqual(composer.to.map(\.address), ["sam@lee.example"])
        XCTAssertEqual(composer.toText, "")
        XCTAssertEqual(composer.suggestions, [])
        XCTAssertEqual(composer.to.first?.chipLabel, "Sam Lee", "a name for someone he has written to")
    }

    func testAnAddressTypedCompleteBecomesAChipAndOneNotCompleteDoesNot() async {
        let h = Harness()
        h.press("c")
        let composer = h.composer!
        await composer.waitForDraft()
        composer.toText = "new@person.example,"
        XCTAssertEqual(composer.to.map(\.address), ["new@person.example"])
        XCTAssertEqual(composer.to.first?.chipLabel, "new@person.example", "an address for someone he has not")
        XCTAssertEqual(composer.toText, "")
        composer.toText = "sam@"
        composer.commitTyped()
        XCTAssertEqual(composer.toText, "sam@", "what is not an address stays as typed")
        XCTAssertEqual(composer.to.count, 1)
        composer.toText = "a@b.example; c@d.example"
        composer.commitTyped()
        XCTAssertEqual(composer.to.map(\.address), ["new@person.example", "a@b.example", "c@d.example"],
                       "a pasted list makes several")
    }

    func testAnAddressAlreadyAChipIsNotAddedTwiceAndBackspaceTakesTheLastOff() async {
        let h = Harness()
        let composer = await h.reply()
        composer.toText = "SAM@lee.example,"
        XCTAssertEqual(composer.to.map(\.address), ["sam@lee.example"])
        composer.removeLastRecipient()
        XCTAssertEqual(composer.to, [])
    }

    // MARK: Sending

    func testSendLeavesTheComposerAddsTheMessageMarkedAsSampleAndOffersUndoForTenSeconds() async throws {
        let h = Harness()
        let composer = await h.reply()
        composer.focusLanded(on: .body)
        composer.body = "Looks right. Send it."
        h.session.sendComposer()

        XCTAssertNil(h.composer, "the composer is gone")
        let conversation = try await conversationOf(h, "q3")
        let sent = try XCTUnwrap(conversation.messages.last)
        XCTAssertEqual(conversation.messages.count, 4)
        XCTAssertTrue(sent.isMine)
        XCTAssertEqual(sent.to.map(\.address), ["sam@lee.example"])
        XCTAssertEqual(sent.firstLine, "Looks right. Send it.")
        let body = await h.source.body(sent.id)
        guard case .text(let text, _, _) = body else { return XCTFail("the body is there to be read: \(body)") }
        XCTAssertEqual(MailPlainText.string(text), "Looks right. Send it.")
        guard case .held(let until)? = sent.delivery else { return XCTFail("inside the undo hold") }
        XCTAssertEqual(until, h.now.addingTimeInterval(MailSession.undoHold))
        XCTAssertNil(conversation.draft)
        XCTAssertTrue(h.source.hasUnfinishedSends)

        let display = MailMessageDisplay(sent)
        XCTAssertNotNil(display.sampleNote, "it says it is a sample")
        XCTAssertTrue(display.sampleNote?.contains("sample") == true, display.sampleNote ?? "")
        let row = try XCTUnwrap(h.session.model.rows.first { $0.id == id("q3") })
        XCTAssertTrue(MailRowDisplay(row, now: h.session.now).isSending)

        XCTAssertEqual(h.toasts.last?.text, "Sending")
        XCTAssertEqual(h.toasts.last?.action, .undo)
        XCTAssertEqual(h.toasts.last?.lasts, 10, "for the length of the hold")
        XCTAssertEqual(h.session.undoStack.count, 1)
        XCTAssertEqual(h.session.undoStack.top?.description, "Sent")
        XCTAssertEqual(h.shown.count, 40, "a plain send marks nothing Done")
    }

    func testTheSourceHoldsAndTheSessionPromisesTheSameTenSeconds() {
        XCTAssertEqual(MailSession.undoHold, MailFixtureSource.defaultHold)
        XCTAssertEqual(MailSession.undoHold, 10)
    }

    func testUndoInsideTheHoldTakesTheMessageBackAndReopensTheComposerAsItWas() async throws {
        let h = Harness()
        let composer = await h.reply()
        composer.body = "Looks right.\nSend it."
        composer.remove(try XCTUnwrap(composer.to.first))
        composer.toText = "jane@parkdesign.example,"
        let draft = try XCTUnwrap(composer.draftID)
        h.session.sendComposer()
        h.now = h.now.addingTimeInterval(3)

        XCTAssertTrue(h.press("z"))
        await h.session.settle()

        let conversation = try await conversationOf(h, "q3")
        XCTAssertEqual(conversation.messages.count, 3, "nothing was sent")
        XCTAssertEqual(conversation.draft, draft, "it is a draft again")
        XCTAssertFalse(h.source.hasUnfinishedSends)
        let back = try XCTUnwrap(h.composer, "the composer is open again")
        await back.waitForDraft()
        XCTAssertEqual(back.draftID, draft)
        XCTAssertEqual(back.body, "Looks right.\nSend it.", "the text as it was")
        XCTAssertEqual(back.to.map(\.address), ["jane@parkdesign.example"], "and the recipients")
        XCTAssertEqual(back.subject, "Re: Q3 numbers before Thursday")
        XCTAssertEqual(h.toasts.last, MailToast(text: "Undone", action: nil))
        XCTAssertTrue(h.session.undoStack.isEmpty)
    }

    func testTheToastsUndoDoesTheSameAsZ() async throws {
        let h = Harness()
        let composer = await h.reply()
        composer.body = "Hello"
        h.session.sendComposer()
        h.toastUndo?()
        await h.session.settle()
        XCTAssertNotNil(h.composer)
        XCTAssertEqual(h.composer?.body, "Hello")
    }

    func testUndoAfterTheHoldSaysAlreadySentAndUnsendsNothing() async throws {
        let h = Harness()
        let composer = await h.reply()
        composer.body = "Gone"
        h.session.sendComposer()
        h.now = h.now.addingTimeInterval(MailSession.undoHold + 1)
        await h.source.finishSends(within: 0)             // the hold's own timer, which a test does not wait for

        XCTAssertTrue(h.press("z"))
        await h.session.settle()

        XCTAssertEqual(h.toasts.last, MailToast(text: "Already sent.", action: nil))
        XCTAssertNil(h.composer)
        let conversation = try await conversationOf(h, "q3")
        XCTAssertEqual(conversation.messages.count, 4, "the message stays")
        XCTAssertNil(conversation.messages.last?.delivery, "and it has left")
        XCTAssertTrue(h.session.undoStack.isEmpty)
    }

    func testSendRefusesWhatCannotBeSentAndSaysWhyAndStaysOpen() async throws {
        let h = Harness()
        let composer = await h.reply()
        composer.remove(try XCTUnwrap(composer.to.first))

        // Nothing written and nobody addressed.
        h.session.sendComposer()
        XCTAssertEqual(h.toasts.last, MailToastText.nothingToSend)
        XCTAssertNotNil(h.composer)

        // Something written, nobody to send it to.
        composer.body = "Hello"
        h.session.sendComposer()
        XCTAssertEqual(h.toasts.last, MailToastText.addSomeone)
        XCTAssertEqual(composer.focusRequest?.field, .to, "focus goes to To")

        // Text in To that is not an address.
        composer.toText = "sam@"
        h.session.sendComposer()
        XCTAssertEqual(h.toasts.last?.text, "\u{201C}sam@\u{201D} isn't an address.")
        XCTAssertNotNil(h.composer, "nothing was sent and nothing was lost")
        XCTAssertTrue(h.session.undoStack.isEmpty)
        let conversation = try await conversationOf(h, "q3")
        XCTAssertEqual(conversation.messages.count, 3)
    }

    func testAnAddressTypedAndNotYetAChipIsSentTo() async throws {
        let h = Harness()
        h.press("c")
        let composer = h.composer!
        await composer.waitForDraft()
        composer.toText = "new@person.example"
        composer.subject = "Hello"
        composer.body = "Hi"
        h.session.sendComposer()
        XCTAssertNil(h.composer)
        XCTAssertEqual(h.session.undoStack.count, 1)
        // It is a conversation of its own, in Done: not the inbox, and not nowhere.
        h.session.show(.done)
        XCTAssertTrue(h.shown.contains { $0.hasPrefix("local:") }, "\(h.shown.prefix(3))")
    }

    func testUndoingTheSendOfANewMessageTakesItOutOfDoneAndReopensIt() async throws {
        let h = Harness()
        h.press("c")
        let composer = h.composer!
        await composer.waitForDraft()
        composer.toText = "new@person.example,"
        composer.subject = "Hello"
        composer.body = "Hi"
        let draft = try XCTUnwrap(composer.draftID)
        h.session.sendComposer()
        h.press("z")
        await h.session.settle()
        XCTAssertNil(h.source.threads[MailConversationID(account: account, thread: "local:" + draft.raw)])
        let back = try XCTUnwrap(h.composer)
        await back.waitForDraft()
        XCTAssertEqual(back.subject, "Hello")
        XCTAssertEqual(back.body, "Hi")
        XCTAssertEqual(back.to.map(\.address), ["new@person.example"])
    }

    // MARK: The Mac's chords (`MailComposerChord`)

    func testTheSendChordSendsAndLeavesTheConversationInTheInbox() async throws {
        let h = Harness()
        let composer = await h.reply()
        composer.body = "On it."
        XCTAssertTrue(h.session.perform(.send))
        XCTAssertNil(h.composer)
        XCTAssertTrue(h.shown.contains("q3"), "a plain send does not mark it Done")
        XCTAssertEqual(h.shown.count, 40)
        XCTAssertEqual(h.toasts.last?.text, "Sending")
        let conversation = try await conversationOf(h, "q3")
        XCTAssertTrue(conversation.inInbox)
        XCTAssertEqual(conversation.messages.count, 4)
    }

    func testTheSendAndDoneChordMarksItDoneAndOneUndoTakesBackBoth() async throws {
        let h = Harness()
        let composer = await h.reply()
        composer.body = "On it."
        XCTAssertTrue(h.session.perform(.sendAndDone))
        XCTAssertFalse(h.shown.contains("q3"))
        XCTAssertEqual(h.shown.count, 39, "the Inbox count drops by one")
        XCTAssertEqual(h.toasts.last?.text, "Sending \u{00B7} marked Done")
        h.now = h.now.addingTimeInterval(4)
        XCTAssertTrue(h.press("z"))
        await h.session.settle()
        XCTAssertEqual(h.shown.count, 40)
        await h.composer?.waitForDraft()
        XCTAssertEqual(h.composer?.body, "On it.")
    }

    func testTheTwoSendChordsInEitherOrderWithAnUndoBetween() async throws {
        let h = Harness()
        let composer = await h.reply()
        composer.body = "On it."
        XCTAssertTrue(h.session.perform(.sendAndDone))
        h.now = h.now.addingTimeInterval(2)
        XCTAssertTrue(h.press("z"))
        await h.session.settle()
        XCTAssertEqual(h.shown.count, 40)
        await h.composer?.waitForDraft()
        XCTAssertTrue(h.session.perform(.send))
        XCTAssertEqual(h.shown.count, 40, "plain Send after a Send and Done that was undone is still plain")
        XCTAssertEqual(h.toasts.last?.text, "Sending")
    }

    func testAChordIsTheComposersOnlyWhileOneIsOpen() async {
        let h = Harness()
        XCTAssertFalse(h.session.perform(.send), "nothing open: not the composer's, so the key goes on")
        XCTAssertFalse(h.session.perform(.recipient(.cc)))
        let composer = await h.reply()
        XCTAssertTrue(h.session.perform(.recipient(.cc)))
        XCTAssertTrue(composer.shows(.cc), "the Cc row appears")
        XCTAssertEqual(composer.focusRequest?.field, .cc, "with the caret asked for in it")
        XCTAssertTrue(h.session.perform(.recipient(.bcc)))
        XCTAssertEqual(composer.focusRequest?.field, .bcc)
        XCTAssertTrue(composer.shows(.bcc))
    }

    func testTheSendLaterChordOpensAndShutsThePickerAndDiscardDiscards() async {
        let h = Harness()
        let composer = await h.reply()
        composer.body = "Later."
        XCTAssertNil(composer.timePicker)
        XCTAssertTrue(h.session.perform(.sendLater))
        XCTAssertNotNil(composer.timePicker)
        XCTAssertTrue(h.session.perform(.sendLater))
        XCTAssertNil(composer.timePicker)
        XCTAssertTrue(h.session.perform(.discard))
        XCTAssertNil(h.composer)
        XCTAssertEqual(h.toasts.last?.text, "Draft discarded")
    }

    func testTheBodysChordsRunWhatTheBodyRegisteredAndAreTakenEvenWhenNothingIs() async {
        let h = Harness()
        let composer = await h.reply()
        var ran: [String] = []
        let owner = UUID()
        XCTAssertTrue(h.session.perform(.format(.bold)), "taken: the caret may be in To, and it is not passed to a menu")
        composer.chords.register(.format(.bold), owner: owner) { ran.append("bold") }
        composer.chords.register(.attach, owner: owner) { ran.append("attach") }
        XCTAssertTrue(h.session.perform(.format(.bold)))
        XCTAssertTrue(h.session.perform(.attach))
        XCTAssertTrue(h.session.perform(.paragraph(.quote)))
        XCTAssertEqual(ran, ["bold", "attach"])
    }

    // MARK: Send and Done

    func testSendAndDoneSendsAndMarksDoneAsOneActionWithOneUndoEntry() async throws {
        let h = Harness()
        let composer = await h.reply()
        composer.body = "On it."
        h.session.sendComposer(thenDone: true)

        XCTAssertNil(h.composer)
        XCTAssertFalse(h.shown.contains("q3"), "the conversation is Done: out of the inbox in the same turn")
        let conversation = try await conversationOf(h, "q3")
        XCTAssertFalse(conversation.inInbox)
        XCTAssertEqual(conversation.messages.count, 4, "and the message is in it")
        XCTAssertEqual(h.session.undoStack.count, 1, "one entry for both")
        guard case .send(_, let holdEnds, let doneSubject)? = h.session.undoStack.top?.kind else {
            return XCTFail("the entry is the send")
        }
        XCTAssertEqual(holdEnds, h.now.addingTimeInterval(10))
        XCTAssertEqual(doneSubject, "Q3 numbers before Thursday")
        XCTAssertEqual(h.session.undoStack.top?.description, "Sent and marked Done")
        XCTAssertGreaterThan(h.session.undoStack.top?.receipt.sequence ?? 0, 0, "completed with the send's receipt")
        XCTAssertEqual(h.toasts.last?.text, "Sending \u{00B7} marked Done")
        XCTAssertEqual(h.toasts.last?.action, .undo)
        XCTAssertEqual(h.toasts.last?.lasts, 10)
    }

    func testOneUndoReversesBothTheSendAndTheDone() async throws {
        let h = Harness()
        let composer = await h.reply()
        composer.body = "On it."
        let draft = try XCTUnwrap(composer.draftID)
        h.session.sendComposer(thenDone: true)
        h.now = h.now.addingTimeInterval(4)

        XCTAssertTrue(h.press("z"))
        await h.session.settle()

        XCTAssertTrue(h.session.undoStack.isEmpty, "one press, and nothing is left to undo")
        XCTAssertTrue(h.shown.contains("q3"), "the row is back in the inbox")
        let conversation = try await conversationOf(h, "q3")
        XCTAssertTrue(conversation.inInbox)
        XCTAssertEqual(conversation.messages.count, 3, "nothing was sent")
        let back = try XCTUnwrap(h.composer, "the composer is open again")
        await back.waitForDraft()
        XCTAssertEqual(back.draftID, draft)
        XCTAssertEqual(back.body, "On it.")
        XCTAssertEqual(h.session.openConversation, id("q3"), "and so is the conversation, as it was")
        XCTAssertEqual(h.toasts.last, MailToast(text: "Undone", action: nil))
    }

    func testUndoingSendAndDoneAfterTheHoldUnsendsNothingAndPutsTheConversationBackInTheInbox() async throws {
        let h = Harness()
        let composer = await h.reply()
        composer.body = "On it."
        h.session.sendComposer(thenDone: true)
        h.now = h.now.addingTimeInterval(MailSession.undoHold + 5)

        XCTAssertTrue(h.press("z"))
        await h.session.settle()

        XCTAssertEqual(h.toasts.last,
                       MailToast(text: "Already sent. \u{201C}Q3 numbers before Thursday\u{201D} is back in the inbox.",
                                 action: nil))
        XCTAssertNil(h.composer)
        XCTAssertTrue(h.shown.contains("q3"))
        let conversation = try await conversationOf(h, "q3")
        XCTAssertTrue(conversation.inInbox, "the Done is undone")
        XCTAssertEqual(conversation.messages.count, 4, "and the message stays sent")
        XCTAssertNil(conversation.messages.last?.delivery)
    }

    func testSendAndDoneWithAPaneMovesTheCursorOnAsDoneDoes() async throws {
        let h = Harness()
        h.session.setPaneVisible(true)
        let composer = await h.reply()
        composer.body = "On it."
        h.session.sendComposer(thenDone: true)
        XCTAssertEqual(h.session.model.cursor, id("invite"), "the successor of its place, as for Done")
        XCTAssertFalse(h.shown.contains("q3"))
        XCTAssertEqual(h.session.undoStack.count, 1)
    }

    func testSendAndDoneOnANewMessageIsAPlainSendBecauseThereIsNothingToMarkDone() async throws {
        let h = Harness()
        h.press("c")
        let composer = h.composer!
        await composer.waitForDraft()
        composer.toText = "new@person.example,"
        composer.body = "Hi"
        h.session.sendComposer(thenDone: true)
        XCTAssertEqual(h.shown.count, 40, "nothing was marked Done")
        XCTAssertEqual(h.toasts.last?.text, "Sending")
        XCTAssertEqual(h.session.undoStack.count, 1)
    }

    // MARK: The source

    func testSendingNeverLeavesTheSource() async throws {
        // The hold ends, the draft is gone, and the message is in its conversation as a sample.
        let h = Harness()
        let composer = await h.reply()
        composer.body = "x"
        let draft = try XCTUnwrap(composer.draftID)
        h.session.sendComposer()
        XCTAssertTrue(h.source.hasUnfinishedSends)
        await h.source.finishSends(within: 0)
        XCTAssertFalse(h.source.hasUnfinishedSends)
        let gone = await h.source.draft(draft)
        XCTAssertNil(gone)
        let cancelled = await h.source.cancelSend(draft)
        XCTAssertFalse(cancelled, "it has left")
        let sent = try await lastMessage(h, "q3")
        XCTAssertTrue(sent.id.message.contains(MailMessageDisplay.sampleMark))
        XCTAssertEqual(MailMessageDisplay(sent).sampleNote, "Sample \u{00B7} nothing was really sent")
    }

    func testSaveOfADraftThatIsGoneIsIgnored() async throws {
        let source = MailFixtureSource()
        var draft = await source.newDraft(.new(account: nil))
        source.discard(draft.id)
        draft.subject = "late"
        source.save(draft)
        let found = await source.draft(draft.id)
        XCTAssertNil(found)
    }

    func testTheRowOfAConversationWithAKeptDraftSaysSoAndOnlyWhileItIs() async throws {
        let source = MailFixtureSource()
        var draft = await source.newDraft(.reply(to: MailMessageID(account: account, message: "q3~3")))
        draft.body = MailPlainText.text("First line\nSecond")
        source.save(draft)
        var rows: [MailRow] = []
        let watching = source.observeList(MailScope(place: .mailbox(.inbox)), limit: 100) { rows = $0.rows }
        XCTAssertEqual(rows.first { $0.id == id("q3") }?.reason, .draft(firstLine: "First line"))
        source.discard(draft.id)
        XCTAssertNil(rows.first { $0.id == id("q3") }?.reason)
        withExtendedLifetime(watching) {}
    }

    func testASaveThatSaysNothingNewPublishesNothing() async throws {
        let source = MailFixtureSource()
        var draft = await source.newDraft(.reply(to: MailMessageID(account: account, message: "q3~3")))
        draft.body = MailPlainText.text("Same words")
        source.save(draft)
        var heard = 0
        let watching = source.observeConversation(id("q3")) { _ in heard += 1 }
        XCTAssertEqual(heard, 1, "the first reading")
        source.save(draft)
        draft.editedAt = Date()
        source.save(draft)
        XCTAssertEqual(heard, 1, "nothing a screen shows changed")
        draft.body = MailPlainText.text("Other words")
        source.save(draft)
        XCTAssertEqual(heard, 2)
        withExtendedLifetime(watching) {}
    }
}
#endif
