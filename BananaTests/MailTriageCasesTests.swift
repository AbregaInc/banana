import XCTest

/// The forty worked cases of MAIL-UX 3.10, one test each, named for the case.
///
/// A list of ten, A (newest) to J (oldest), direction *older* unless a case says otherwise. Every
/// case is run through the same loop as the rules (`TriageHarness`): keys go to the model, what
/// it asks for is carried out, the source answers, and what is asserted is what the screen would
/// show. The cases are the document's acceptance test for the model; where one is partly the
/// engine's or the screen's — a toast's pixels, the status line's words, a composer reopening —
/// the test says which part it holds the model to.
@MainActor
final class MailTriageCasesTests: XCTestCase {

    private func toast(_ text: String, _ action: MailToast.Action? = .undo) -> MailToast {
        MailToast(text: text, action: action)
    }

    private let quote = ("\u{201C}", "\u{201D}")

    private func marked(_ letter: String) -> String {
        "Marked \(quote.0)Subject \(letter)\(quote.1) Done"
    }

    // MARK: 1 to 6: where the cursor goes

    func testCase01_cursorOnCInASplit_E_nineRowsCursorOnDWhereCWasOnScreen() {
        let h = TriageHarness()
        h.send(.place(h.id("C")))
        let effects = h.press(.done)
        XCTAssertEqual(h.shown, "ABDEFGHIJ")
        XCTAssertEqual(h.cursor, "D")
        XCTAssertEqual(h.toasts.last, toast(marked("C")))
        // D is where C was on screen: the model asks for no jump, only that D be shown whole,
        // and the rows below close up under a host that keeps the visible ones still.
        XCTAssertTrue(effects.contains(.reveal(h.id("D"), beyond: .older)))
        XCTAssertFalse(effects.contains(.scrollToTop))
        XCTAssertFalse(effects.contains { if case .restoreViewport = $0 { return true } else { return false } })
    }

    func testCase02_cursorOnA_E_cursorOnBAtTheTop() {
        let h = TriageHarness()
        h.press(.done)
        XCTAssertEqual(h.cursor, "B")
        XCTAssertEqual(h.model.rows.first?.id.thread, "B", "B is the first row: at the top")
    }

    func testCase03_cursorOnJ_E_nothingOlderCursorOnI() {
        let h = TriageHarness()
        h.send(.place(h.id("J")))
        h.press(.done)
        XCTAssertEqual(h.cursor, "I")
        XCTAssertEqual(h.shown, "ABCDEFGHI")
    }

    func testCase04_aListOfOne_E_emptyStateNoCursor() {
        let h = TriageHarness(rows: 1)
        h.press(.done)
        XCTAssertEqual(h.shown, "")
        XCTAssertNil(h.cursor)
        let shown = h.model.list.shown
        XCTAssertTrue(shown.rows.isEmpty)
        XCTAssertTrue(shown.hasDelivered, "an empty list that has been read is the empty state, not a skeleton")
        XCTAssertEqual(shown.stillLoading, 0)
    }

    func testCase05_KKFromE_cursorOnCDirectionNewer_E_cursorOnB() {
        let h = TriageHarness()
        h.send(.place(h.id("E")))
        h.send(.move(.newer))
        h.send(.move(.newer))
        XCTAssertEqual(h.cursor, "C")
        XCTAssertEqual(h.model.direction, .newer)
        h.press(.done)
        XCTAssertEqual(h.cursor, "B")
    }

    func testCase06_cursorOnADirectionNewer_E_nothingNewerCursorOnB() {
        let h = TriageHarness()
        h.send(.move(.older))
        h.send(.move(.newer))
        XCTAssertEqual(h.cursor, "A")
        XCTAssertEqual(h.model.direction, .newer)
        h.press(.done)
        XCTAssertEqual(h.cursor, "B")
    }

    // MARK: 7 to 9: an open conversation

    func testCase07_cOpen_E_dIsOpen() {
        let h = TriageHarness()
        h.send(.open(h.id("C")))
        h.press(.done)
        XCTAssertEqual(h.openLetter, "D")
        XCTAssertEqual(h.cursor, "D")
    }

    func testCase08_jOpen_E_theListCursorOnI() {
        let h = TriageHarness()
        h.send(.open(h.id("J")))
        let effects = h.press(.done)
        XCTAssertNil(h.openLetter)
        XCTAssertTrue(effects.contains(.close))
        XCTAssertEqual(h.cursor, "I")
    }

    func testCase09_aOpenDirectionNewer_E_theListCursorOnB() {
        let h = TriageHarness()
        h.send(.open(h.id("B")))
        h.send(.step(.newer))
        XCTAssertEqual(h.openLetter, "A")
        XCTAssertEqual(h.model.direction, .newer)
        let effects = h.press(.done)
        XCTAssertNil(h.openLetter)
        XCTAssertTrue(effects.contains(.close))
        XCTAssertEqual(h.cursor, "B")
    }

    // MARK: 10 to 13: a selection

    func testCase10_cdeSelectedCursorOnE_E_sevenRowsCursorOnFNothingSelectedToast3MarkedDone() {
        let h = TriageHarness()
        for letter in ["C", "D", "E"] { h.send(.toggleSelected(h.id(letter))) }
        h.send(.place(h.id("E")))
        h.press(.done)
        XCTAssertEqual(h.shown, "ABFGHIJ")
        XCTAssertEqual(h.cursor, "F")
        XCTAssertEqual(h.model.selection, MailSelection.none)
        XCTAssertEqual(h.toasts.last, toast("3 marked Done"))
    }

    func testCase11_bcSelectedCursorOnH_E_eightRowsCursorStillOnH() {
        let h = TriageHarness()
        h.send(.toggleSelected(h.id("B")))
        h.send(.toggleSelected(h.id("C")))
        h.send(.place(h.id("H")))
        h.press(.done)
        XCTAssertEqual(h.shown, "ADEFGHIJ")
        XCTAssertEqual(h.cursor, "H")
    }

    func testCase12_hijSelectedCursorOnJ_E_cursorOnG() {
        let h = TriageHarness()
        for letter in ["H", "I", "J"] { h.send(.toggleSelected(h.id(letter))) }
        h.send(.place(h.id("J")))
        h.press(.done)
        XCTAssertEqual(h.shown, "ABCDEFG")
        XCTAssertEqual(h.cursor, "G")
    }

    func testCase13_everythingSelected_E_emptyStateOneUndoEntry() {
        let h = TriageHarness()
        h.send(.selectAll)
        h.press(.done)
        XCTAssertEqual(h.shown, "")
        XCTAssertNil(h.cursor)
        XCTAssertEqual(h.stack.count, 1)
    }

    // MARK: 14 to 16: undo

    func testCase14_case1_thenZ_tenRowsCursorOnCAtItsFormerScreenPositionUnreadIfItWas() {
        let h = TriageHarness()
        let viewport = h.viewport("A")
        h.send(.place(h.id("C")))
        h.send(.scrolled(viewport))
        h.press(.done)
        h.undoTop()
        XCTAssertEqual(h.shown, "ABCDEFGHIJ")
        XCTAssertEqual(h.cursor, "C")
        XCTAssertEqual(h.row("C")?.isUnread, true, "Done had marked it read; it is unread again")
        XCTAssertTrue(h.has(.restoreViewport(viewport)), "its former screen position")
        XCTAssertEqual(h.toasts.last, toast("Undone", nil))
    }

    func testCase15_cOpenScrolledToItsFourthMessage_E_Z_cIsOpenFourthMessageAtTheSameOffset() {
        let h = TriageHarness()
        h.send(.open(h.id("C")))
        let reading = MailReaderFacts(
            topMessage: MailMessageID(account: TriageHarness.account, message: "C-m4"), offset: 128,
            newestSeen: MailMessageID(account: TriageHarness.account, message: "C-m4"), hasUnseen: false)
        h.send(.reader(reading))
        h.press(.done)
        XCTAssertEqual(h.openLetter, "D")
        h.undoTop()
        XCTAssertEqual(h.openLetter, "C")
        XCTAssertEqual(h.model.open?.facts, reading)
        XCTAssertTrue(h.has(.open(h.id("C"), composer: nil, at: reading)))
    }

    func testCase16_eOnCInImportant_thenTab_Z_importantIsShowingCursorOnC() {
        let h = TriageHarness()
        for index in 5..<10 { h.mailbox[index].isImportant = false }
        h.deliver()
        h.send(.place(h.id("C")))
        h.press(.done)
        h.show(h.other)
        XCTAssertEqual(h.showing, h.other)
        h.undoTop()
        XCTAssertEqual(h.showing, h.important)
        XCTAssertEqual(h.cursor, "C")
        XCTAssertEqual(h.shown, "ABCDE")
    }

    // MARK: 17 to 20: filters and search

    func testCase17_unreadFilterOnCursorOnCUnread_U_cIsReadAndKeptAndDimmedFromTheFirstReadingThatOmitsIt() {
        let h = TriageHarness(scope: MailScope(place: .split(MailSplit.importantID), filters: [.unread]))
        h.send(.place(h.id("C")))
        let effects = h.model.handle(.act(.toggleRead, on: nil))
        XCTAssertEqual(h.row("C")?.isUnread, false)
        XCTAssertNotNil(h.row("C"), "kept")
        XCTAssertEqual(h.cursor, "C")
        XCTAssertFalse(h.model.isDimmed(h.id("C")), "drawn like any other until a reading omits it")
        XCTAssertFalse(h.model.list.shown.dimmed.contains(h.id("C")))

        // The first reading that omits it: the source has the change, and the filtered list does not.
        guard case .perform(let request)? = effects.first else { return XCTFail() }
        _ = h.apply(request.change, to: request.target)
        XCTAssertNotNil(h.row("C"))
        XCTAssertTrue(h.model.isDimmed(h.id("C")), "from that reading on it is dimmed")
        XCTAssertTrue(h.model.list.shown.dimmed.contains(h.id("C")))
        XCTAssertEqual(h.cursor, "C")
    }

    func testCase18_case17_thenTabShiftTab_cIsNoLongerInTheFilteredList() {
        let filtered = MailScope(place: .split(MailSplit.importantID), filters: [.unread])
        let h = TriageHarness(scope: filtered)
        h.send(.place(h.id("C")))
        h.press(.toggleRead)
        h.show(h.other)
        h.show(filtered)
        XCTAssertNil(h.row("C"))
        XCTAssertEqual(h.shown, "ABDEFGHIJ")
    }

    func testCase19_searchResultsCursorOnCInTheInbox_E_cStaysWithoutItsInboxGlyphCursorOnD() {
        let h = TriageHarness(scope: MailScope(place: .search("subject")))
        h.send(.place(h.id("C")))
        h.press(.done)
        XCTAssertEqual(h.shown, "ABCDEFGHIJ")
        XCTAssertEqual(h.row("C")?.inInbox, false)
        XCTAssertEqual(h.cursor, "D")
    }

    func testCase20_searchResultsCursorOnJNotInTheInboxAndRead_E_nothingSentNoToastCursorOnI() {
        // "Changes nothing" is `MailRowRules`' answer for the row (T16). Done also marks read, so
        // a J that is out of the inbox and read is the case; one that is unread is not.
        let h = TriageHarness(scope: MailScope(place: .search("subject")))
        h.mailbox[9].inInbox = false
        h.mailbox[9].isUnread = false
        h.deliver()
        h.send(.place(h.id("J")))
        let effects = h.press(.done)
        XCTAssertFalse(effects.contains { if case .perform = $0 { return true } else { return false } })
        XCTAssertTrue(h.performed.isEmpty)
        XCTAssertTrue(h.toasts.isEmpty)
        XCTAssertTrue(h.stack.isEmpty)
        XCTAssertEqual(h.cursor, "I")
    }

    func testCase20_theSameForAJThatIsOutOfTheInboxButUnreadDoesChangeSomething() {
        let h = TriageHarness(scope: MailScope(place: .search("subject")))
        h.mailbox[9].inInbox = false
        h.deliver()
        h.send(.place(h.id("J")))
        h.press(.done)
        XCTAssertEqual(h.performed.count, 1, "Done would mark it read")
        XCTAssertEqual(h.cursor, "I")
    }

    // MARK: 21 to 27: what changes under the hand

    func testCase21_cursorOnC_dMarkedDoneOnThePhoneWhileJIsHeld_dStaysUntilTheListHasBeenIdleThenItIsGone() {
        let h = TriageHarness()
        h.send(.place(h.id("C")))
        h.send(.move(.older))                      // J is held: D, E, F
        h.send(.move(.older))
        h.send(.move(.older))
        h.outsideDone("D")
        XCTAssertNotNil(h.row("D"), "D stays")
        XCTAssertEqual(h.shown, "ABCDEFGHIJ")
        h.send(.idle)                               // three seconds
        XCTAssertNil(h.row("D"))
        XCTAssertEqual(h.cursor, "F")
    }

    func testCase22_cursorOnE_newMailArrivesInEsConversation_atOnceEIsWhereItWasNowUnreadWithTheNewSnippet() {
        let h = TriageHarness()
        h.mailbox[4].isUnread = false
        h.deliver()
        h.send(.place(h.id("E")))
        h.newMail(in: "E", snippet: "Are you there?")
        XCTAssertEqual(h.shown, "ABCDEFGHIJ")
        XCTAssertEqual(h.row("E")?.isUnread, true)
        XCTAssertEqual(h.row("E")?.snippet, "Are you there?")
        XCTAssertEqual(h.cursor, "E")
    }

    func testCase23_case22_thenJToF_thenIdle_esConversationIsFirstCursorOnF() {
        let h = TriageHarness()
        h.mailbox[4].isUnread = false
        h.deliver()
        h.send(.place(h.id("E")))
        h.newMail(in: "E")
        h.send(.move(.older))
        h.send(.idle)
        XCTAssertEqual(h.shown, "EABCDFGHIJ")
        XCTAssertEqual(h.cursor, "F")
    }

    func testCase24_listAtTheTopAndIdleCursorOnA_mailNArrives_nIsTheFirstRowCursorOnANowSecond() {
        let h = TriageHarness()
        h.send(.idle)                               // entering the place was an input
        h.arrive("N")
        XCTAssertEqual(h.model.rows.first?.id.thread, "N")
        XCTAssertEqual(h.cursor, "A")
        XCTAssertEqual(h.model.rows.firstIndex { $0.id.thread == "A" }, 1)
    }

    func testCase25_listAtTheTopEPressedOneSecondAgo_mailNArrives_noRowMovesChipOneNewTwoSecondsLaterNJoins() {
        let h = TriageHarness()
        h.press(.done)                              // one second ago
        h.arrive("N")
        XCTAssertEqual(h.shown, "BCDEFGHIJ", "no row moves")
        XCTAssertEqual(h.model.list.shown.arrivals, 1, "the chip reads 1 new")
        h.send(.idle)                               // two seconds later: three in all
        XCTAssertEqual(h.shown, "NBCDEFGHIJ")
        XCTAssertEqual(h.model.list.shown.arrivals, 0)
    }

    func testCase26_listScrolledSoAIsOffScreen_mailNArrives_noRowMovesChipOneNewUntilTheTopIsReached() {
        let h = TriageHarness()
        h.send(.firstRowOnScreen(false))
        h.send(.idle)
        h.arrive("N")
        XCTAssertEqual(h.shown, "ABCDEFGHIJ")
        XCTAssertEqual(h.model.list.shown.arrivals, 1)
        h.send(.firstRowOnScreen(true))
        XCTAssertEqual(h.shown, "NABCDEFGHIJ")
        XCTAssertEqual(h.model.list.shown.arrivals, 0)
    }

    func testCase27_cOpen_cMarkedDoneOnThePhone_cStaysOpenClosingShowsTheListCursorOnD() {
        let h = TriageHarness()
        h.send(.open(h.id("C")))
        h.outsideDone("C")                          // covered, so at rest: applied at once
        XCTAssertEqual(h.openLetter, "C")
        XCTAssertEqual(h.shown, "ABDEFGHIJ")
        h.send(.close)
        XCTAssertEqual(h.cursor, "D")
        XCTAssertEqual(h.shown, "ABDEFGHIJ")
    }

    func testCase27_closingIsAKeyPressSoTheThreeSecondsStartAgainFromIt() {
        let h = TriageHarness()
        h.send(.open(h.id("C")))
        h.send(.close)
        h.outsideDone("D")
        XCTAssertNotNil(h.row("D"), "closing was an input: the list is not at rest")
        h.send(.idle)
        XCTAssertNil(h.row("D"))
    }

    func testCase27_whatWasWaitingIsAppliedAsTheConversationOpens() {
        let h = TriageHarness()
        h.send(.place(h.id("B")))
        h.outsideDone("E")                          // waits: the list is not at rest
        XCTAssertNotNil(h.row("E"))
        h.send(.open(nil))                          // covered: at rest
        XCTAssertNil(h.row("E"))
    }

    // MARK: 28 to 31: sending, offline, a held key

    private func sendEntry(_ h: TriageHarness, holdEnds: TimeInterval) -> MailUndoEntry {
        MailUndoEntry(kind: .send(MailDraftID(raw: "draft-1"), holdEnds: h.now.addingTimeInterval(holdEnds),
                                  doneSubject: nil),
                      receipt: MailReceipt(sequence: 40, count: nil), description: "Sent",
                      scope: h.important)
    }

    func testCase28_commandReturnOnAReply_thenWithinTheHold_Z_nothingWasSentAndTheComposerIsToReopen() {
        // The composer's reopening is U9a's; what the model and the stack hold is that Z within
        // the hold is `cancelSend`, never `undo`, and says "Undone".
        let h = TriageHarness()
        h.stack.push(sendEntry(h, holdEnds: 10), at: h.now)
        h.now = h.now.addingTimeInterval(4)
        guard case .undone(let toast)? = h.undoTop() else { return XCTFail() }
        XCTAssertEqual(toast, MailToast(text: "Undone", action: nil))
        XCTAssertTrue(h.performed.isEmpty)
        XCTAssertEqual(h.shown, "ABCDEFGHIJ")
    }

    func testCase29_commandReturn_holdEnded_Z_alreadySentNothingElseChanges() {
        let h = TriageHarness()
        h.stack.push(sendEntry(h, holdEnds: 10), at: h.now)
        h.now = h.now.addingTimeInterval(11)
        guard case .alreadySent(let toast)? = h.undoTop() else { return XCTFail() }
        XCTAssertEqual(toast, MailToast(text: "Already sent.", action: nil))
        XCTAssertEqual(h.shown, "ABCDEFGHIJ")
        XCTAssertTrue(h.stack.isEmpty)
    }

    func testCase30_offline_case1_identicalToCase1() {
        let online = TriageHarness()
        online.send(.place(online.id("C")))
        online.press(.done)

        let offline = TriageHarness()
        offline.offline = true
        offline.send(.place(offline.id("C")))
        offline.press(.done)

        // The model has no word for the network: the same keys give the same screen. ("Offline
        // · 1 change waiting" is the status line's, U15b's.)
        XCTAssertEqual(offline.shown, online.shown)
        XCTAssertEqual(offline.cursor, online.cursor)
        XCTAssertEqual(offline.toasts, online.toasts)
        XCTAssertEqual(offline.effects, online.effects)
    }

    func testCase31_eHeldDownForTwoSeconds_oneConversationMarkedDone() {
        // A held key reaches the model once: the keymap's K7 lets only J, K, ⇧J, ⇧K and Space
        // repeat. The model holds its end: one input is one conversation, however long it took.
        let h = TriageHarness()
        h.press(.done)
        XCTAssertEqual(h.performed.count, 1)
        XCTAssertEqual(h.shown, "BCDEFGHIJ")
    }

    // MARK: 32 to 35: marking, Esc

    func testCase32_cursorOnC_S_cIsStarredCursorOnCNothingElseChanges() {
        let h = TriageHarness()
        h.send(.place(h.id("C")))
        h.press(.toggleStar)
        XCTAssertEqual(h.row("C")?.isStarred, true)
        XCTAssertEqual(h.cursor, "C")
        XCTAssertEqual(h.shown, "ABCDEFGHIJ")
        XCTAssertEqual(h.model.selection, MailSelection.none)
        XCTAssertNil(h.openLetter)
        XCTAssertTrue(h.toasts.isEmpty, "the row shows it")
        XCTAssertEqual(h.stack.count, 1, "and it is still an undo step")
    }

    func testCase33_cdeSelectedDOpen_Esc_theListWithCDEStillSelectedASecondEscClearsTheSelection() {
        let h = TriageHarness()
        for letter in ["C", "D", "E"] { h.send(.toggleSelected(h.id(letter))) }
        h.send(.open(h.id("D")))
        let first = h.send(.back)
        XCTAssertTrue(first.contains(.close))
        XCTAssertNil(h.openLetter)
        XCTAssertEqual(h.selected, "CDE")
        h.send(.back)
        XCTAssertEqual(h.selected, "")
    }

    func testCase34_cdeSelectedDOpen_E_dIsDoneTheNextOpensCAndEAreStillSelected() {
        let h = TriageHarness()
        for letter in ["C", "D", "E"] { h.send(.toggleSelected(h.id(letter))) }
        h.send(.open(h.id("D")))
        h.press(.done)
        XCTAssertEqual(h.performed.last?.target, .conversations([h.id("D")]))
        XCTAssertEqual(h.shown, "ABCEFGHIJ")
        XCTAssertEqual(h.openLetter, "E")
        XCTAssertEqual(h.selected, "CE")
    }

    func testCase35_searchWithTheUnreadFilterOn_Esc_searchIsLeftTheStartingPlaceShows() {
        let h = TriageHarness(scope: MailScope(place: .search("subject"), filters: [.unread]))
        let effects = h.send(.back)
        XCTAssertEqual(effects, [.leaveSearch], "not clearFilters: search is left first (K9)")
    }

    // MARK: 36 to 40: what was shown, and what could not stand

    func testCase36_commandShiftATwelveSelected_aMessageArrives_E_twelveAreDoneTheArrivalIsInTheInboxUnread() {
        let h = TriageHarness(rows: 12)
        h.send(.selectAll)
        guard case .scope(_, _, let count) = h.model.selection else { return XCTFail() }
        XCTAssertEqual(count, MailCount(value: 12, isAtLeast: false), "\"12 selected\"")
        h.arrive("N")
        h.press(.done)
        XCTAssertEqual(h.members(of: h.important).map(\.id.thread), ["N"])
        XCTAssertEqual(h.mailbox.filter { !$0.inInbox }.count, 12)
        XCTAssertEqual(h.mailbox.first { $0.id.thread == "N" }?.isUnread, true)
        XCTAssertEqual(h.mailbox.first { $0.id.thread == "N" }?.inInbox, true)
        XCTAssertEqual(h.stack.top?.count, 12)
        // Over the empty state, the chip says "1 new" until the list is at rest...
        XCTAssertEqual(h.shown, "")
        XCTAssertEqual(h.model.list.shown.arrivals, 1)
        XCTAssertTrue(h.model.list.shown.hasDelivered)
        XCTAssertNil(h.cursor)
        // ...and then it is the list.
        h.send(.idle)
        XCTAssertEqual(h.shown, "N")
        XCTAssertEqual(h.model.list.shown.arrivals, 0)
        XCTAssertEqual(h.cursor, "N")
    }

    func testCase37_cOpenAReplyArrivesBelowTheFoldUnseen_E_cEarlierMessagesAreDoneAndReadCIsInTheInboxUnreadWithTheReply() {
        let h = TriageHarness()
        h.send(.open(h.id("C")))
        let seen = MailMessageID(account: TriageHarness.account, message: "C-m3")
        h.send(.reader(MailReaderFacts(topMessage: nil, offset: 0, newestSeen: seen, hasUnseen: true)))
        h.unseenReply = ["C"]
        h.press(.done)
        XCTAssertEqual(h.performed.last?.target, .message(seen))
        XCTAssertEqual(h.performed.last?.change, .done)
        XCTAssertEqual(h.messageChanges.count, 1)
        XCTAssertEqual(h.row("C")?.inInbox, true)
        XCTAssertEqual(h.row("C")?.isUnread, true)
        XCTAssertEqual(h.openLetter, "D", "the run goes on")
    }

    func testCase38_cOpen_JJJWithinASecond_fIsOpenDAndEWereNotMarkedRead() {
        let h = TriageHarness()
        h.send(.open(h.id("C")))
        h.send(.step(.older))
        h.send(.step(.older))
        h.send(.step(.older))
        XCTAssertEqual(h.openLetter, "F")
        // The timers of D and E run out later and find a conversation that is not open.
        h.send(.readDelayElapsed(h.id("D")))
        h.send(.readDelayElapsed(h.id("E")))
        XCTAssertEqual(h.row("D")?.isUnread, true)
        XCTAssertEqual(h.row("E")?.isUnread, true)
        XCTAssertTrue(h.performed.isEmpty)
    }

    func testCase39_cOpen_JHeldDown_dIsOpen() {
        // As case 31: K7 lets a held J in an open conversation act once, so one step arrives.
        let h = TriageHarness()
        h.send(.open(h.id("C")))
        h.send(.step(.older))
        XCTAssertEqual(h.openLetter, "D")
    }

    func testCase40_aMoveThatGmailRefusesForGood_theConversationIsBackWithTheReasonToastWithRetry() {
        let h = TriageHarness()
        let invoices = MailLabelRef(id: "Label_12", name: "Invoices", colorHex: nil)
        h.send(.place(h.id("C")))
        h.press(.move(account: TriageHarness.account, to: invoices))
        XCTAssertEqual(h.shown, "ABDEFGHIJ")
        XCTAssertEqual(h.toasts.last, toast("Moved \(quote.0)Subject C\(quote.1) to Invoices"))

        h.refuse(h.stack.top!.receipt, .labelMissing)
        XCTAssertEqual(h.shown, "ABCDEFGHIJ", "back in the list")
        // The row draws "Couldn't apply · label gone" from this reason (6.1.1). Listing it in
        // Outbox is `status.value.refused`, the engine's.
        XCTAssertEqual(h.row("C")?.reason, .changeRefused(.labelMissing))
        XCTAssertEqual(h.toasts.last, toast(
            "Couldn't move \(quote.0)Subject C\(quote.1): that label no longer exists.", .retry))
    }

    // MARK: 41 to 51: what the review added

    func testCase41_cursorOnC_shiftJ_cAndDAreSelectedCursorOnD() {
        let h = TriageHarness()
        h.send(.place(h.id("C")))
        h.send(.extendSelection(.older))
        XCTAssertEqual(h.selected, "CD")
        XCTAssertEqual(h.cursor, "D")
        // At the end of the list the cursor cannot move, and the press selects its conversation alone.
        let end = TriageHarness()
        end.send(.place(end.id("J")))
        end.send(.extendSelection(.older))
        XCTAssertEqual(end.selected, "J")
        XCTAssertEqual(end.cursor, "J")
    }

    func testCase42_cursorOnC_E_EnterDIsOpen_Z_theListTenRowsCursorOnCDIsNotOpen() {
        let h = TriageHarness()
        h.send(.place(h.id("C")))
        h.press(.done)
        h.send(.open(nil))
        XCTAssertEqual(h.openLetter, "D")
        let before = h.effects.count
        h.undoTop()
        XCTAssertEqual(h.shown, "ABCDEFGHIJ")
        XCTAssertEqual(h.cursor, "C")
        XCTAssertNil(h.openLetter, "an open conversation is always the cursor, and the cursor is on C")
        XCTAssertEqual(h.model.cursorID, h.id("C"))
        XCTAssertTrue(h.effects.suffix(from: before).contains(.close))
    }

    func testCase43_eOnCInImportant_Tab_nothingHasBeenReadForImportantSince_Z_cIsBackInThatTurn() {
        let h = TriageHarness()
        for index in 5..<10 { h.mailbox[index].isImportant = false }
        h.deliver()
        h.observesWhileAway = false                 // Important is not observed while Other is in front
        h.deliversOnUndo = false                    // and the undo reaches it no reading
        h.send(.place(h.id("C")))
        h.press(.done)
        let doneSequence = h.sequence
        h.show(h.other)
        h.undoTop()
        XCTAssertEqual(h.showing, h.important)
        XCTAssertEqual(h.shown, "ABCDE", "C is in its place, in that turn")
        XCTAssertEqual(h.cursor, "C")
        // A reading older than the undo cannot take it away again.
        var stale = h.snapshot(for: h.important, appliedThrough: doneSequence)
        stale.rows.removeAll { $0.id.thread == "C" }
        h.model.handle(.snapshot(stale))
        XCTAssertNotNil(h.row("C"))
    }

    func testCase44_aListOfOne_E_mailNArrivesOneSecondLater_theChipOverTheEmptyStateThenNIsTheList() {
        let h = TriageHarness(rows: 1)
        h.press(.done)
        h.arrive("N")
        XCTAssertEqual(h.shown, "", "the last E of a run must not mark unseen mail Done")
        XCTAssertEqual(h.model.list.shown.arrivals, 1)
        XCTAssertTrue(h.model.list.shown.rows.isEmpty)
        h.send(.idle)
        XCTAssertEqual(h.shown, "N")
        XCTAssertEqual(h.model.list.shown.arrivals, 0)
        XCTAssertEqual(h.cursor, "N")
    }

    func testCase45_thePlaceWasEnteredOneSecondAgo_mailNArrives_noRowMovesChipThenNJoins() {
        let h = TriageHarness()                     // entered just now, with the list at its top
        h.arrive("N")
        XCTAssertEqual(h.shown, "ABCDEFGHIJ", "no row moves as a thumb comes in")
        XCTAssertEqual(h.model.list.shown.arrivals, 1)
        h.send(.idle)
        XCTAssertEqual(h.shown, "NABCDEFGHIJ")
        XCTAssertEqual(h.model.list.shown.arrivals, 0)
    }

    func testCase46_aPlaceOf1000With100RowsLoaded_JHeldToTheHundredthRowAndOn_theNextRowsAreTakenInAsTheyCome() {
        let h = TriageHarness(rows: 1_000, limit: 100)
        XCTAssertEqual(h.model.rows.count, 100)
        XCTAssertTrue(h.model.list.shown.hasMore)
        for _ in 0..<130 { h.send(.move(.older)) }
        XCTAssertEqual(h.cursor, "R130", "the cursor went on past the hundredth row")
        XCTAssertEqual(h.model.rows.count, 200, "the next rows were taken in as they came, not three seconds later")
        XCTAssertEqual(h.growths, [200], "and asked for once")
    }

    func testCase47_dIsTheFirstRowOnScreen_EOnD_TabShiftTab_eIsFirstOnScreenAtOffsetZero() {
        let h = TriageHarness()
        h.send(.place(h.id("D")))
        h.send(.scrolled(h.viewport("D", offset: 12)))
        h.press(.done)
        let before = h.effects.count
        h.show(h.other)
        h.show(h.important)
        let expected = MailViewport(firstRow: h.id("E"), key: TriageHarness.row("E", rank: 4).key, offset: 0)
        XCTAssertTrue(h.effects.suffix(from: before).contains(.restoreViewport(expected)),
                      "the first row at or after D's place stands in for it, at offset 0")
    }

    func testCase48_cursorOnTheFortiethRow_shiftU_theUnreadListCursorOnTheSameConversationAndOnScreen() {
        let h = TriageHarness(rows: 60)
        for index in [5, 6, 20] { h.mailbox[index].isUnread = false }
        h.deliver()
        h.send(.place(h.id("R39")))
        let hint = h.model.cursorHint
        let before = h.effects.count
        h.show(MailListModel.scope(toggling: .unread, in: h.important), carrying: hint)
        XCTAssertEqual(h.cursor, "R39")
        let shown = h.effects.suffix(from: before)
        XCTAssertTrue(shown.contains(.reveal(h.id("R39"), beyond: nil)), "the cursor row is shown")
        XCTAssertFalse(shown.contains(.scrollToTop), "not at the top")
    }

    func testCase49_enterOnCUnread_UWithin400ms_theListCIsStillUnreadNothingWasSent() {
        let h = TriageHarness()
        h.send(.place(h.id("C")))
        h.send(.open(nil))
        let effects = h.press(.toggleRead)
        XCTAssertTrue(effects.contains(.close))
        XCTAssertNil(h.openLetter)
        XCTAssertEqual(h.row("C")?.isUnread, true)
        XCTAssertTrue(h.performed.isEmpty)
        XCTAssertTrue(h.stack.isEmpty)
    }

    func testCase50_unreadFilterOnInImportant_Tab_calendarWithTheUnreadFilterStillOn() {
        let splits = [MailSplit(id: MailSplit.importantID, name: "Important", query: nil),
                      MailSplit(id: MailSplit.calendarID, name: "Calendar", query: nil),
                      MailSplit(id: MailSplit.otherID, name: "Other", query: nil)]
        var scope = MailScope(place: .split(MailSplit.importantID), filters: [.unread])
        scope.account = TriageHarness.account
        let next = MailListModel.scopeAfterTab(from: scope, in: splits, backwards: false)
        XCTAssertEqual(next?.place, .split(MailSplit.calendarID))
        XCTAssertEqual(next?.filters, [.unread])
        XCTAssertEqual(next?.account, TriageHarness.account, "the account carries too")
        let back = MailListModel.scopeAfterTab(from: scope, in: splits, backwards: true)
        XCTAssertEqual(back?.place, .split(MailSplit.otherID))
        XCTAssertEqual(back?.filters, [.unread])
    }

    func testCase51_aReplyToCSentWithCommandShiftReturn_theHoldHasEnded_Z_alreadySentCIsBackAndOpenAsItWas() {
        let h = TriageHarness()
        h.send(.open(h.id("C")))
        let reading = MailReaderFacts(
            topMessage: MailMessageID(account: TriageHarness.account, message: "C-m2"), offset: 48,
            newestSeen: MailMessageID(account: TriageHarness.account, message: "C-m2"), hasUnseen: false)
        h.send(.reader(reading))
        h.press(.sendAndDone)                       // C is Done, D is open
        XCTAssertEqual(h.openLetter, "D")
        guard let screenHalf = h.settled.first else { return XCTFail("no screen half") }
        h.completeSend(screenHalf, holdEnds: 10)    // the composer pushes the one entry
        XCTAssertEqual(h.stack.count, 1)
        h.now = h.now.addingTimeInterval(11)        // the hold has ended
        let outcome = h.undoTop()
        XCTAssertEqual(outcome, .alreadySent(MailToast(
            text: "Already sent. \u{201C}Subject C\u{201D} is back in the inbox.", action: nil)))
        XCTAssertEqual(h.shown, "ABCDEFGHIJ", "C is back in its place")
        XCTAssertEqual(h.openLetter, "C", "and open again as it was")
        XCTAssertEqual(h.model.open?.facts, reading)
        XCTAssertEqual(h.cursor, "C")
        XCTAssertFalse(h.effects.contains { if case .open(_, let composer, _) = $0 { return composer != nil } else { return false } },
                       "without the composer")
    }

    // MARK: 52 to 54: which readings he asked for

    func testCase52_200RowsLoadedScrolledToThe150th_mailArrives_JHeld_theListGoesOnGrowingPastItsThreeHundredthRow() {
        let h = TriageHarness(rows: 1_000, limit: 100)
        for _ in 0..<75 { h.send(.move(.older)) }       // 200 rows loaded
        XCTAssertEqual(h.model.rows.count, 200)
        h.send(.firstRowOnScreen(false))
        h.send(.place(h.id("R150")))                     // scrolled to the 150th
        h.arrive("N")                                    // the chip says "1 new"
        XCTAssertEqual(h.model.list.shown.arrivals, 1)
        for _ in 0..<130 { h.send(.move(.older)) }       // J held
        XCTAssertGreaterThan(h.model.rows.count, 300, "the list goes on growing past its 300th row")
        XCTAssertEqual(h.cursor, "R280")
        XCTAssertEqual(h.model.list.shown.arrivals, 1, "the chip still says \"1 new\"")
        XCTAssertEqual(h.model.rows.first?.id.thread, "A", "and nothing was put above the list")
    }

    func testCase53_aPullFindsNothingNew_heKeepsScrolling_mailNArrivesFourSecondsLater_noRowMovesChip() {
        let h = TriageHarness()
        h.send(.refresh)                                 // the pull
        h.finishCheck()                                  // nothing new: the session says so at once
        h.send(.scrolled(h.viewport("B", offset: 4)))    // the scroll that ends a pull, and more
        h.send(.move(.older))
        h.send(.move(.older))
        h.arrive("N")                                    // four seconds later; he has not paused
        XCTAssertEqual(h.shown, "ABCDEFGHIJ", "no row moves")
        XCTAssertEqual(h.model.list.shown.arrivals, 1, "chip \"1 new\"")
    }

    func testCase54_aColdLaunchIntoMail_theCachedPageShows_theFirstRealReadingHasOneMore_noChipNoWait() {
        let h = TriageHarness()
        let cached = h.snapshot(for: h.important)        // what was stored: A to J
        h.arrive("N")                                    // by the time Mail is opened there is one more
        let real = h.snapshot(for: h.important)
        let model = MailListModel(scope: h.important, deviceName: "iPhone", timePhrase: { _ in "" })
        model.handle(.snapshot(cached))                  // `cachedFirstPage`: a first reading, not marked
        model.handle(.enter)
        XCTAssertEqual(model.rows.map(\.id.thread).joined(), "ABCDEFGHIJ", "the cached page shows")
        model.handle(.snapshot(real, answersEntry: true))   // the observation's first value, marked
        XCTAssertEqual(model.rows.map(\.id.thread).joined(), "NABCDEFGHIJ", "the list is the real reading")
        XCTAssertEqual(model.arrivals, 0, "no chip")
        XCTAssertFalse(model.hasWaitingReading, "and nothing waiting three seconds")
    }

    func testCase54_withoutTheMarkTheRealReadingWouldWaitForTheListToRest() {
        let h = TriageHarness()
        let cached = h.snapshot(for: h.important)
        h.arrive("N")
        let real = h.snapshot(for: h.important)
        let model = MailListModel(scope: h.important, deviceName: "iPhone", timePhrase: { _ in "" })
        model.handle(.snapshot(cached))
        model.handle(.enter)
        model.handle(.snapshot(real))                    // unmarked
        XCTAssertEqual(model.rows.map(\.id.thread).joined(), "ABCDEFGHIJ")
        XCTAssertEqual(model.arrivals, 1)
    }
}
