import XCTest

/// Mail's undo history: MAIL-UX T25 to T30, and T44's button.
///
/// The stack has no clock and no source, so every rule here sets what time it is and what the
/// source answered, and reads one answer. What undo does to the screen — rows back, cursor,
/// selection, open conversation, scroll — is the model's `restore`, and is tested here too,
/// through the same loop as the cases, because T26 is a statement about what the person sees.
@MainActor
final class MailUndoStackTests: XCTestCase {

    private let now = TriageHarness.now

    private func entry(_ sequence: UInt64, _ text: String = "Marked Done", count: Int? = 1,
                       kind: MailUndoEntry.Kind? = nil) -> MailUndoEntry {
        MailUndoEntry(kind: kind ?? .change(.done, .done),
                      receipt: MailReceipt(sequence: sequence, count: count), description: text,
                      scope: MailScope(place: .mailbox(.inbox)))
    }

    private func send(_ sequence: UInt64, holdEnds: TimeInterval, doneSubject: String? = nil) -> MailUndoEntry {
        entry(sequence, "Sent", kind: .send(MailDraftID(raw: "d\(sequence)"),
                                            holdEnds: now.addingTimeInterval(holdEnds),
                                            doneSubject: doneSubject))
    }

    // MARK: T25: what is remembered

    func testFailedUndoRestoresOriginalPositionBehindNewActions() {
        var stack = MailUndoStack()
        stack.push(entry(1), at: now)
        stack.push(entry(2), at: now.addingTimeInterval(1))
        guard case .reverse(let failed) = stack.beginUndo(now: now.addingTimeInterval(2)) else { return XCTFail() }
        stack.push(entry(3), at: now.addingTimeInterval(3))
        stack.restoreFailedUndo(failed)
        stack.restoreFailedUndo(failed)
        XCTAssertEqual(stack.entries.map { $0.receipt.sequence }, [1, 2, 3])
    }

    func testT25_everyDisposingActionRemembersWhatWasShowing() {
        let h = TriageHarness()
        let reading = MailReaderFacts(topMessage: MailMessageID(account: TriageHarness.account, message: "C-m2"),
                                      offset: 64, newestSeen: nil, hasUnseen: false)
        let viewport = h.viewport("B", offset: 9)
        h.send(.toggleSelected(h.id("F")))
        h.send(.open(h.id("C")))
        h.send(.reader(reading))
        h.send(.scrolled(viewport))
        h.press(.done)

        let entry = h.stack.top!
        XCTAssertEqual(entry.kind, .change(.done, .done))
        XCTAssertEqual(entry.description, "Marked Done")
        XCTAssertEqual(entry.scope, h.important)
        XCTAssertEqual(entry.cursor, h.id("C"))
        XCTAssertEqual(entry.cursorKey, TriageHarness.row("C", rank: 2).key)
        XCTAssertEqual(entry.direction, .older)
        XCTAssertEqual(entry.selection, .rows([h.id("F")]))
        XCTAssertEqual(entry.open, MailOpenConversation(id: h.id("C"), facts: reading))
        XCTAssertEqual(entry.viewport, viewport)
        XCTAssertEqual(entry.rowsBefore, [TriageHarness.row("C", rank: 2)], "the row of what left, as it was")
        XCTAssertEqual(entry.receipt.count, 1)
        XCTAssertEqual(entry.pushedAt, h.now)
    }

    func testT25_everyMarkingActionIsRemembered() {
        let h = TriageHarness()
        h.press(.toggleStar)
        h.press(.toggleRead)
        XCTAssertEqual(h.stack.entries.map(\.description), ["Starred", "Marked read"])
    }

    func testT25_notPushedBeingMarkedReadByOpeningAnotherFeaturesActionOrAnActionThatChangedNothing() {
        let h = TriageHarness()
        h.send(.open(nil))
        h.send(.readDelayElapsed(h.id("A")))
        h.press(.answerInvitation)
        XCTAssertTrue(h.stack.isEmpty)

        let search = TriageHarness(scope: MailScope(place: .search("subject")))
        search.mailbox[0].inInbox = false
        search.mailbox[0].isUnread = false      // nothing left for Done to change
        search.deliver()
        search.press(.done)
        XCTAssertTrue(search.stack.isEmpty)
    }

    func testT25_aSendAndADiscardAreEntriesToo() {
        var stack = MailUndoStack()
        stack.push(send(1, holdEnds: 10), at: now)
        stack.push(entry(2, "Draft discarded", kind: .discard(MailDraftID(raw: "d"))), at: now)
        XCTAssertEqual(stack.count, 2)
    }

    // MARK: T26: what Z does

    func testT26_undoPutsEverythingBackInOneTurn() {
        let h = TriageHarness()
        for index in 5..<10 { h.mailbox[index].isImportant = false }
        h.deliver()
        let viewport = h.viewport("A", offset: 3)
        h.send(.toggleSelected(h.id("A")))
        h.send(.open(h.id("C")))
        h.send(.scrolled(viewport))
        h.press(.done)
        h.send(.close)
        h.show(h.other)
        h.undoTop()
        XCTAssertEqual(h.showing, h.important, "the entry's scope is shown")
        XCTAssertEqual(h.shown, "ABCDE")
        XCTAssertEqual(h.cursor, "C")
        XCTAssertEqual(h.selected, "A", "the selection is as recorded")
        XCTAssertEqual(h.row("C")?.isUnread, true, "each conversation gets back what it had")
        XCTAssertTrue(h.has(.restoreViewport(viewport)))
    }

    func testT26_oneUndoUndoesOneActionWhetherItTouchedOneConversationOrFiveHundred() {
        let h = TriageHarness(rows: 500)
        h.send(.selectAll)
        h.press(.done)
        XCTAssertEqual(h.shown, "")
        XCTAssertEqual(h.stack.count, 1)
        h.undoTop()
        XCTAssertEqual(h.model.rows.count, 500)
        XCTAssertTrue(h.stack.isEmpty)
        XCTAssertEqual(h.mailbox.filter(\.inInbox).count, 500)
    }

    func testT26_theToastReadsUndoneWithUndoPreviousWhenTheStackHasAnotherEntry() {
        let h = TriageHarness()
        h.press(.done)
        h.press(.toggleStar)
        h.undoTop()
        XCTAssertEqual(h.toasts.last, MailToast(text: "Undone", action: .undoPrevious("Marked Done")))
        h.undoTop()
        XCTAssertEqual(h.toasts.last, MailToast(text: "Undone", action: nil), "nothing more to undo")
    }

    func testT26_undoingASendWithinItsHoldIsTheOneUndoThatWaits() {
        var stack = MailUndoStack()
        stack.push(send(1, holdEnds: 10), at: now)
        guard case .cancelSend(let entry) = stack.beginUndo(now: now.addingTimeInterval(3)) else {
            return XCTFail("a send within its hold is cancelled, not reversed")
        }
        XCTAssertEqual(stack.outcome(cancelling: entry, succeeded: true).toast.text, "Undone")
    }

    func testT26_undoWithAnEmptyStackDoesNothing() {
        var stack = MailUndoStack()
        XCTAssertEqual(stack.beginUndo(now: now), .nothingToUndo)
    }

    // MARK: T27: how deep

    func testT27_fiftyEntriesTheOldestGoesFirst() {
        var stack = MailUndoStack()
        for sequence in 1...60 { stack.push(entry(UInt64(sequence)), at: now) }
        XCTAssertEqual(MailUndoStack.depth, 50)
        XCTAssertEqual(stack.count, 50)
        XCTAssertEqual(stack.entries.first?.receipt.sequence, 11)
        XCTAssertEqual(stack.top?.receipt.sequence, 60)
    }

    func testT27_theToastShowsTheTopEntryForSixSecondsAndTheEntryOutlivesIt() {
        XCTAssertEqual(MailToast.duration, 6)
        var stack = MailUndoStack()
        stack.push(entry(1), at: now)
        XCTAssertNotNil(stack.top, "nothing about the toast takes the entry off")
    }

    // MARK: T28: what cannot be undone

    func testT28_aSendWhoseHoldHasEndedIsNotUnsentTheEntryIsDroppedAndTheToastSaysSo() {
        var stack = MailUndoStack()
        stack.push(send(1, holdEnds: 10), at: now)
        guard case .alreadySent(let entry) = stack.beginUndo(now: now.addingTimeInterval(10)) else {
            return XCTFail()
        }
        XCTAssertTrue(stack.isEmpty)
        XCTAssertEqual(stack.outcome(forAlreadySent: entry).toast, MailToast(text: "Already sent.", action: nil))
    }

    func testT28_ifItWasSendAndDoneTheDoneIsUndoneAndTheToastSaysWhereTheConversationIs() {
        var stack = MailUndoStack()
        stack.push(send(1, holdEnds: 10, doneSubject: "Re: Q3 numbers"), at: now)
        guard case .alreadySent(let entry) = stack.beginUndo(now: now.addingTimeInterval(30)) else {
            return XCTFail()
        }
        XCTAssertEqual(stack.outcome(forAlreadySent: entry).toast.text,
                       "Already sent. \u{201C}Q3 numbers\u{201D} is back in the inbox.")
    }

    func testT28_theEngineHavingTheLastWordTheSameLineIsSaidWhenCancelSendAnswersFalse() {
        var stack = MailUndoStack()
        stack.push(send(1, holdEnds: 10), at: now)
        guard case .cancelSend(let entry) = stack.beginUndo(now: now) else { return XCTFail() }
        XCTAssertEqual(stack.outcome(cancelling: entry, succeeded: false).toast.text, "Already sent.")
    }

    func testT28_anUnsubscribeAndAnInvitationsAnswerAreNotMailsToUndo() {
        XCTAssertFalse(MailAction.unsubscribe.isUndoable)
        XCTAssertFalse(MailAction.answerInvitation.isUndoable)
        for action in [MailAction.done, .trash, .spam, .toggleRead, .toggleStar, .notDone] {
            XCTAssertTrue(action.isUndoable, "\(action)")
        }
    }

    // MARK: T29: no redo

    func testT29_thereIsNoRedoAnUndoneEntryIsGoneAndTheNextUndoIsTheOneBeforeIt() {
        var stack = MailUndoStack()
        stack.push(entry(1, "Marked Done"), at: now)
        stack.push(entry(2, "Starred"), at: now)
        guard case .reverse(let first) = stack.beginUndo(now: now) else { return XCTFail() }
        XCTAssertEqual(first.receipt.sequence, 2)
        guard case .reverse(let second) = stack.beginUndo(now: now) else { return XCTFail() }
        XCTAssertEqual(second.receipt.sequence, 1, "not the one just undone")
        XCTAssertEqual(stack.beginUndo(now: now), .nothingToUndo)
    }

    // MARK: T30: undo meets a changed world

    func testT30_aCountOfZeroChangesNothingDropsTheEntryAndSaysThatItCanNoLongerBeUndone() {
        let h = TriageHarness()
        h.send(.place(h.id("C")))
        h.press(.done)
        let before = h.shown
        guard case .reverse(let entry) = h.stack.beginUndo(now: h.now) else { return XCTFail() }
        let outcome = h.stack.outcome(reversing: entry, answer: MailReceipt(sequence: 9, count: 0))
        XCTAssertEqual(outcome, .cannotBeUndone(MailToast(text: "That can no longer be undone.", action: nil)))
        XCTAssertTrue(h.stack.isEmpty, "the entry is dropped")
        XCTAssertEqual(h.shown, before, "and the screen is not touched: restore is not called")
    }

    func testT30_aReceiptOfNoSequenceIsTheSameAnswer() {
        let stack = MailUndoStack()
        XCTAssertEqual(stack.outcome(reversing: entry(1), answer: MailReceipt(sequence: 0, count: 0)).toast.text,
                       "That can no longer be undone.")
    }

    func testT30_aTargetThatNoLongerExistsIsSkippedTheRestAreUndone() {
        let h = TriageHarness()
        h.send(.toggleSelected(h.id("C")))
        h.send(.toggleSelected(h.id("D")))
        h.press(.done)
        // D is deleted at Gmail before Undo: the source undoes one conversation, not two.
        h.mailbox.removeAll { $0.id.thread == "D" }
        h.undoTop()
        XCTAssertEqual(h.toasts.last?.text, "Undone")
        XCTAssertEqual(h.shown, "ABCEFGHIJ")
    }

    // MARK: T36's, T44's, and the count of a scope

    func testT36_aRefusedEntryIsTakenOffByItsReceipt() {
        var stack = MailUndoStack()
        stack.push(entry(1), at: now)
        stack.push(entry(2), at: now)
        XCTAssertEqual(stack.remove(receipt: MailReceipt(sequence: 1, count: nil))?.receipt.sequence, 1)
        XCTAssertEqual(stack.count, 1)
        XCTAssertNil(stack.remove(receipt: MailReceipt(sequence: 1, count: nil)))
    }

    func testAScopesCountArrivingLaterUpdatesTheEntryAndAZeroTakesItOff() {
        var stack = MailUndoStack()
        stack.push(entry(1, count: nil), at: now)
        XCTAssertNil(stack.setCount(12, for: MailReceipt(sequence: 1, count: nil)))
        XCTAssertEqual(stack.top?.count, 12)
        XCTAssertEqual(stack.top?.description, "12 marked Done")
        XCTAssertEqual(stack.setCount(0, for: MailReceipt(sequence: 1, count: nil))?.receipt.sequence, 1)
        XCTAssertTrue(stack.isEmpty)
    }

    func testT44_theBottomSlotShowsAnUndoButtonForTwoMinutesAfterTheNewestEntry() {
        var stack = MailUndoStack()
        XCTAssertFalse(stack.showsUndoButton(now: now))
        stack.push(entry(1), at: now)
        XCTAssertTrue(stack.showsUndoButton(now: now.addingTimeInterval(1)))
        XCTAssertTrue(stack.showsUndoButton(now: now.addingTimeInterval(120)))
        XCTAssertFalse(stack.showsUndoButton(now: now.addingTimeInterval(121)))
        stack.push(entry(2), at: now.addingTimeInterval(200))
        XCTAssertTrue(stack.showsUndoButton(now: now.addingTimeInterval(250)), "from the newest")
    }
}
