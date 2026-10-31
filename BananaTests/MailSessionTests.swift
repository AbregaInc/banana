#if DEBUG || MAIL_FIXTURES
import XCTest

/// The first Mail screen, without the screen: the session around the real triage model and the
/// in-memory source, driven by the keys and taps a person makes. What it asks of the model, and
/// what the model decides, is `MailListModelTests`'; what these hold is that the loop carries it
/// out — the row leaves at once, the cursor moves by the model's rules, the toast says what the
/// table says, and Undo puts it back where it was.
@MainActor
final class MailSessionTests: XCTestCase {

    private let account = MailFixtureConversations.account

    private func id(_ key: String) -> MailConversationID {
        MailConversationID(account: account, thread: key)
    }

    /// A session on its own source, with timers that wait to be fired and a toast that is recorded.
    @MainActor
    private final class Harness {
        let source = MailFixtureSource()
        var toasts: [MailToast] = []
        var dismissals = 0
        var toastUndo: (@MainActor () -> Void)?
        var timers: [(delay: TimeInterval, work: @MainActor () -> Void, cancelled: Bool)] = []
        var session: MailSession!

        init() {
            session = MailSession(
                source: source, now: source.now, deviceName: "Mac",
                timers: MailTimers { [unowned self] delay, work in
                    self.timers.append((delay, work, false))
                    let index = self.timers.count - 1
                    return { self.timers[index].cancelled = true }
                },
                clock: { MailFixtureConversations.now },
                dismissToast: { [unowned self] in self.dismissals += 1 },
                present: { [unowned self] toast, undo in
                    self.toasts.append(toast)
                    self.toastUndo = undo
                })
            session.enter()
        }

        var model: MailListModel { session.model }
        var shown: [String] { model.rows.map(\.id.thread) }
        var cursor: String? { model.cursor?.thread }
        var open: String? { session.openConversation?.thread }

        func press(_ key: Character, shift: Bool = false, repeating: Bool = false) -> Bool {
            session.handle(.character(key), shift: shift, isRepeat: repeating)
        }

        /// Fires the oldest timer waiting with this delay, as the clock would.
        func fire(after delay: TimeInterval) {
            guard let index = timers.firstIndex(where: { $0.delay == delay && !$0.cancelled }) else { return }
            timers[index].cancelled = true
            timers[index].work()
        }
    }

    func testReadOnlyIntegrationNeverOptimisticallyChangesOrCreatesDraft() {
        let source = MailFixtureSource()
        var explanations = [MailToast]()
        let session = MailSession(source: source, now: source.now, deviceName: "Test",
            timers: MailTimers { _, _ in {} }, allowsChanges: false,
            present: { toast, _ in explanations.append(toast) })
        session.enter()
        let rows = session.model.rows
        XCTAssertFalse(rows.isEmpty)
        session.send(.act(.done, on: rows.first!.id))
        XCTAssertEqual(session.model.rows, rows)
        session.compose(requestFocus: false)
        XCTAssertNil(session.composer)
        XCTAssertEqual(explanations.count, 2)
        session.leave()
    }

    func testLiveCapabilitiesAllowTriageWithoutOpeningComposerOrSnoozing() {
        let source = MailFixtureSource()
        var explanations: [MailToast] = []
        let session = MailSession(source: source, now: source.now, deviceName: "Test",
            timers: MailTimers { _, _ in {} }, allowsChanges: true, allowsComposing: false,
            supportsAction: { $0.isIntegratedGmailAction },
            present: { toast, _ in explanations.append(toast) })
        session.enter()
        let first = session.model.rows[0]
        let before = first.isStarred
        session.act(.toggleStar, on: first.id)
        XCTAssertEqual(session.model.rows.first { $0.id == first.id }?.isStarred, !before)
        let rows = session.model.rows
        session.act(.snooze(until: source.now.addingTimeInterval(3600), ifNoReply: false), on: first.id)
        XCTAssertEqual(session.model.rows, rows)
        session.compose(requestFocus: false)
        session.reply(.reply)
        XCTAssertNil(session.composer)
        XCTAssertFalse(session.allowsComposing)
        XCTAssertFalse(session.canPerform(.mute))
        XCTAssertTrue(session.canPerform(.toggleRead, on: first.id))
        XCTAssertGreaterThanOrEqual(explanations.count, 3)
        session.leave()
    }

    func testAccountRestrictionPreventsOptimisticAndDelayedReadChanges() {
        let source = MailFixtureSource()
        var explanations: [MailToast] = []
        let session = MailSession(source: source, now: source.now, deviceName: "Test",
            timers: MailTimers { _, _ in {} }, allowsChanges: true, allowsComposing: false,
            allowsTarget: { _ in false }, targetRestriction: "Read only test account",
            present: { toast, _ in explanations.append(toast) })
        session.enter()
        let rows = session.model.rows
        let first = rows[0]
        session.act(.done, on: first.id)
        session.send(.readDelayElapsed(first.id))
        XCTAssertEqual(session.model.rows, rows)
        XCTAssertFalse(session.canPerform(.done, on: first.id))
        XCTAssertEqual(explanations.last?.text, "Read only test account")
        session.leave()
    }

    // Loading another page must travel through the session, not only emit a model effect.
    func testScrollingToLoadedBoundaryRequestsAndReceivesMoreRows() throws {
        let source = MailFixtureSource(samples: MailFixtureConversations.stress(days: 1), defaults: nil)
        let session = MailSession(source: source, now: source.now, deviceName: "Test",
                                  timers: MailTimers { _, _ in {} }, clock: { MailFixtureConversations.now },
                                  present: { _, _ in })
        session.enter()
        defer { session.leave() }
        let before = session.model.rows.count
        XCTAssertEqual(before, MailTuning.listStep)
        let anchor = try XCTUnwrap(session.model.rows.last)
        let viewport = MailViewport(firstRow: anchor.id, key: anchor.key, offset: 7)
        session.send(.scrolled(viewport))
        XCTAssertGreaterThan(session.model.limit, before, "The model requested another page")
        session.send(.idle)
        XCTAssertGreaterThan(session.model.rows.count, before,
                             "The session must carry the request to the source and receive older rows")
        XCTAssertEqual(session.model.viewport?.firstRow, anchor.id,
                       "Loading older mail must preserve the visible row")
        XCTAssertEqual(session.model.viewport?.offset, 7)
    }

    func testHistoryNavigationReachesBeyondCapWithoutRetainingOldModels() throws {
        let source = MailFixtureSource(samples: MailFixtureConversations.stress(days: 2), defaults: nil)
        let session = MailSession(source: source, now: source.now, deviceName: "Test",
            timers: MailTimers { _, _ in {} }, present: { _, _ in })
        session.enter(); session.show(.all)
        defer { session.leave() }
        var seen = Set<MailConversationID>()
        var firstIDs: [MailConversationID] = []
        for page in 0..<25 {
            let rows = session.model.rows
            XCTAssertEqual(rows.count, MailTuning.listStep)
            firstIDs.append(try XCTUnwrap(rows.first).id)
            for row in rows { XCTAssertTrue(seen.insert(row.id).inserted, "Paging duplicated a conversation") }
            if page < 24 {
                weak var previous = session.model
                session.showOlderHistory()
                XCTAssertNil(previous, "Paging must release the previous list model and its rows")
            }
        }
        XCTAssertGreaterThan(seen.count, MailTuning.listCap)
        session.showNewerHistory()
        XCTAssertEqual(session.model.rows.first?.id, firstIDs[23])
        session.show(.all)
        XCTAssertNil(session.scope.before)
        XCTAssertEqual(session.model.rows.first?.id, firstIDs[0])
    }

    func testHistorySearchAndFilterChangesResetTheWindow() throws {
        let source = MailFixtureSource(samples: MailFixtureConversations.stress(days: 2), defaults: nil)
        let session = MailSession(source: source, now: source.now, deviceName: "Test",
            timers: MailTimers { _, _ in {} }, present: { _, _ in })
        session.enter()
        defer { session.leave() }
        session.switchTo(MailScope(place: .search("Stress")))
        let first = try XCTUnwrap(session.model.rows.first)
        session.showOlderHistory()
        XCTAssertNotNil(session.scope.before)
        XCTAssertLessThan(try XCTUnwrap(session.model.rows.first).key, first.key)
        session.showNewerHistory()
        XCTAssertEqual(session.model.rows.first?.id, first.id)
        session.showOlderHistory()
        let filtered = MailListModel.scope(toggling: .unread, in: session.scope)
        XCTAssertNil(filtered.before)
        session.switchTo(filtered)
        XCTAssertTrue(session.model.rows.allSatisfy(\.isUnread))
        session.show(.inbox)
        XCTAssertNil(session.scope.before)
        XCTAssertEqual(session.historyBackTitle, "Newest")
    }

    /// Holds replacement delivery so the observation handoff is tested asynchronously.
    @MainActor
    private final class DelayedListSource: MailSource {
        let fixture = MailFixtureSource(samples: MailFixtureConversations.stress(days: 1), defaults: nil)
        var active: Set<Int> = []
        var pending: [() -> Void] = []
        func activate() {}
        func setVisible(_ visible: Bool) {}
        func observePlaces(_ onChange: @escaping @MainActor (MailPlaces) -> Void) -> MailObservation {
            fixture.observePlaces(onChange)
        }
        func observeList(_ scope: MailScope, limit: Int,
                         _ onChange: @escaping @MainActor (MailListSnapshot) -> Void) -> MailObservation {
            active.insert(limit)
            let token = fixture.observeList(scope, limit: limit) { [weak self] snapshot in
                guard let self else { return }
                if limit == MailTuning.listStep { onChange(snapshot) }
                else {
                    self.pending.append { [weak self] in
                        guard self?.active.contains(limit) == true else { return }
                        onChange(snapshot)
                    }
                }
            }
            return MailObservation { [weak self] in
                token.cancel()
                self?.active.remove(limit)
            }
        }
    }

    func testGrowthKeepsOldObservationUntilReplacementArrives() throws {
        let source = DelayedListSource()
        let session = MailSession(source: source, now: source.fixture.now, deviceName: "Test",
                                  timers: MailTimers { _, _ in {} }, present: { _, _ in })
        session.enter()
        let anchor = try XCTUnwrap(session.model.rows.last)
        session.send(.scrolled(MailViewport(firstRow: anchor.id, key: anchor.key, offset: 7)))
        XCTAssertEqual(source.active, [100, 200])
        XCTAssertEqual(session.model.rows.count, 100)
        source.pending.removeFirst()()
        XCTAssertEqual(source.active, [200])
        XCTAssertEqual(session.model.rows.count, 200)
        XCTAssertEqual(session.model.viewport?.firstRow, anchor.id)
        session.leave()
        XCTAssertTrue(source.active.isEmpty)
    }

    func testLeavingWhileGrowthIsPendingCancelsBothObservations() throws {
        let source = DelayedListSource()
        let session = MailSession(source: source, now: source.fixture.now, deviceName: "Test",
                                  timers: MailTimers { _, _ in {} }, present: { _, _ in })
        session.enter()
        let anchor = try XCTUnwrap(session.model.rows.last)
        session.send(.scrolled(MailViewport(firstRow: anchor.id, key: anchor.key, offset: 7)))
        session.leave()
        XCTAssertTrue(source.active.isEmpty)
        source.pending.removeFirst()()
        XCTAssertEqual(session.model.rows.count, 100)
    }

    // MARK: Entering

    func testEnteringShowsTheWholeInboxWithTheCursorOnTheFirstRow() {
        let h = Harness()
        XCTAssertEqual(h.shown.count, 40)
        XCTAssertEqual(h.shown.first, "q3")
        XCTAssertEqual(h.cursor, "q3")
        XCTAssertNil(h.open)
        XCTAssertTrue(h.model.list.shown.hasDelivered)
        XCTAssertEqual(h.model.list.shown.total, MailCount(value: 40, isAtLeast: false))
    }

    func testTheSessionIsMadeRightAndAskedForNothingElse() {
        let h = Harness()
        XCTAssertTrue(h.toasts.isEmpty)
        XCTAssertTrue(h.session.undoStack.isEmpty)
        XCTAssertEqual(h.session.now, MailFixtureConversations.now)
    }

    // MARK: Moving

    func testJAndKMoveTheCursorAndStopAtTheEnds() {
        let h = Harness()
        XCTAssertTrue(h.press("j"))
        XCTAssertEqual(h.cursor, h.shown[1])
        XCTAssertTrue(h.press("j"))
        XCTAssertEqual(h.cursor, h.shown[2])
        XCTAssertTrue(h.press("k"))
        XCTAssertEqual(h.cursor, h.shown[1])
        XCTAssertTrue(h.press("k"))
        XCTAssertTrue(h.press("k"), "at the top the key is still taken, and nothing happens: no wrap, no beep")
        XCTAssertEqual(h.cursor, "q3")
    }

    func testTheArrowsMoveItToo() {
        let h = Harness()
        XCTAssertTrue(h.session.handle(.down))
        XCTAssertEqual(h.cursor, h.shown[1])
        XCTAssertTrue(h.session.handle(.up))
        XCTAssertEqual(h.cursor, "q3")
    }

    func testAHeldJMovesOnEveryRepeat() {
        let h = Harness()
        for _ in 0..<5 { XCTAssertTrue(h.press("j", repeating: true)) }
        XCTAssertEqual(h.cursor, h.shown[5])
    }

    func testAMoveTellsTheHostToShowTheRowAndRepublishesNothing() {
        let h = Harness()
        var commands: [MailHostCommand] = []
        let watching = h.session.hostCommands.sink { commands.append($0) }
        let generation = h.model.list.shown.generation
        _ = h.press("j")
        XCTAssertEqual(commands, [.reveal(h.model.rows[1].id, beyond: .older)])
        XCTAssertEqual(h.model.list.shown.generation, generation,
                       "a cursor move changes nothing the list reads (MAIL-UX G2)")
        withExtendedLifetime(watching) {}
    }

    func testFailedUndoCanBeRetriedWithoutLosingOriginalEntry() {
        let h = Harness()
        XCTAssertTrue(h.press("e"))
        h.source.nextUndoFailure = .diskFull
        h.session.undoTop()
        XCTAssertFalse(h.shown.contains("q3"))
        XCTAssertEqual(h.session.undoStack.count, 1)
        XCTAssertEqual(h.toasts.last, MailToastText.notSaved(on: "Mac", problem: .diskFull))
        h.session.undoTop()
        XCTAssertTrue(h.shown.contains("q3"))
        XCTAssertTrue(h.session.undoStack.isEmpty)
    }

    func testNoOpWithdrawsItsToastAndCannotUndoPreviousAction() throws {
        let h = Harness()
        XCTAssertTrue(h.press("e"))
        let original = try XCTUnwrap(h.session.undoStack.top?.receipt)
        XCTAssertTrue(h.press("e"))
        let noOp = try XCTUnwrap(h.session.undoStack.top?.receipt)
        let staleButton = h.toastUndo
        h.source.emit(.applied(noOp, count: 0))
        XCTAssertEqual(h.dismissals, 1)
        staleButton?()
        XCTAssertEqual(h.session.undoStack.top?.receipt, original)
    }

    // MARK: Done

    func testSynchronousFailureWaitsForReceiptBeforeRestoring() {
        let h = Harness()
        h.source.nextApplyFailure = .diskFull
        XCTAssertTrue(h.press("e"))
        XCTAssertTrue(h.shown.contains("q3"))
        XCTAssertTrue(h.session.undoStack.isEmpty)
        XCTAssertEqual(h.toasts.last, MailToastText.notSaved(on: "Mac", problem: .diskFull))
    }

    func testRefusalRetryDoesNotUndoAnEarlierAction() throws {
        let h = Harness()
        XCTAssertTrue(h.press("e"))
        let earlier = try XCTUnwrap(h.session.undoStack.top?.receipt)
        XCTAssertTrue(h.press("e"))
        let failed = try XCTUnwrap(h.session.undoStack.top?.receipt)
        h.source.emit(.refused(failed, .accessMissing))
        XCTAssertEqual(h.toasts.last?.action, .retry)
        h.toastUndo?()
        XCTAssertEqual(h.session.undoStack.top?.receipt, earlier)
        XCTAssertEqual(h.session.undoStack.count, 1)
    }

    func testUnsavedActionRestoresItsRowAndRemovesUndo() throws {
        let h = Harness()
        XCTAssertTrue(h.press("e"))
        let receipt = try XCTUnwrap(h.session.undoStack.top?.receipt)
        h.source.emit(.notSaved(receipt, .diskFull))
        XCTAssertTrue(h.shown.contains("q3"))
        XCTAssertTrue(h.session.undoStack.isEmpty)
        XCTAssertEqual(h.toasts.last, MailToastText.notSaved(on: "Mac", problem: .diskFull))
    }

    func testRefusalAfterChangingPlaceDoesNotNavigateBack() throws {
        let h = Harness()
        XCTAssertTrue(h.press("e"))
        let receipt = try XCTUnwrap(h.session.undoStack.top?.receipt)
        h.session.show(.done)
        let scope = h.session.scope
        h.source.emit(.refused(receipt, .accessMissing))
        XCTAssertEqual(h.session.scope, scope)
        XCTAssertTrue(h.session.undoStack.isEmpty)
        XCTAssertTrue(h.toasts.last?.text.contains("this account has to be allowed again.") == true)
    }

    func testLateActionCountUpdatesUndoAndZeroRemovesIt() throws {
        let h = Harness()
        XCTAssertTrue(h.press("e"))
        let receipt = try XCTUnwrap(h.session.undoStack.top?.receipt)
        h.source.emit(.applied(receipt, count: 3))
        XCTAssertEqual(h.session.undoStack.top?.count, 3)
        h.source.emit(.applied(receipt, count: 0))
        XCTAssertTrue(h.session.undoStack.isEmpty)
    }

    func testDoneTakesTheRowOutAtOnceMovesTheCursorOnAndSaysSo() {
        let h = Harness()
        XCTAssertTrue(h.press("e"))

        XCTAssertEqual(h.shown.count, 39, "gone in the same turn as the key")
        XCTAssertFalse(h.shown.contains("q3"))
        XCTAssertEqual(h.cursor, "invite", "the successor of its place, in the direction of travel")
        XCTAssertEqual(h.session.undoStack.count, 1)
        XCTAssertEqual(h.toasts, [MailToast(text: "Marked \u{201C}Q3 numbers before Thursday\u{201D} Done",
                                            action: .undo)])
        XCTAssertEqual(h.model.list.shown.total.value, 39)
    }

    func testTenDonesAreTenConversationsInListOrder() {
        let h = Harness()
        let first = Array(h.shown.prefix(10))
        for _ in 0..<10 { XCTAssertTrue(h.press("e")) }
        XCTAssertEqual(h.shown.count, 30)
        XCTAssertEqual(Set(h.shown).intersection(first), [], "each press acted on the cursor the one before left")
        XCTAssertEqual(h.session.undoStack.count, 10)
    }

    func testAHeldEActsOnceAndTheRepeatsAreTakenAndDoNothing() {
        let h = Harness()
        XCTAssertTrue(h.press("e"))
        XCTAssertTrue(h.press("e", repeating: true), "taken, so no responder beeps at it")
        XCTAssertTrue(h.press("e", repeating: true))
        XCTAssertEqual(h.shown.count, 39, "K7: one Done")
        XCTAssertEqual(h.session.undoStack.count, 1)
    }

    func testDoneOnEveryRowEmptiesTheInboxAndASpareDoneDoesNothing() {
        let h = Harness()
        for _ in 0..<40 { _ = h.press("e") }
        XCTAssertTrue(h.shown.isEmpty)
        XCTAssertNil(h.cursor)
        XCTAssertEqual(h.model.list.shown.total.value, 0)
        XCTAssertTrue(h.press("e"), "Done in an empty inbox is taken and does nothing")
        XCTAssertEqual(h.session.undoStack.count, 40)
    }

    // MARK: Undo

    func testUndoPutsTheRowBackWithTheCursorWhereItWas() {
        let h = Harness()
        _ = h.press("j")                       // the cursor is on the second row
        _ = h.press("j")                       // and the third
        let third = h.cursor
        _ = h.press("e")
        XCTAssertNotEqual(h.cursor, third)

        XCTAssertTrue(h.press("z"))

        XCTAssertEqual(h.shown.count, 40)
        XCTAssertEqual(h.cursor, third, "the cursor is where it was")
        XCTAssertEqual(h.shown[2], third)
        XCTAssertTrue(h.session.undoStack.isEmpty)
        XCTAssertEqual(h.toasts.last, MailToast(text: "Undone", action: nil))
    }

    func testTheToastsUndoButtonDoesTheSameAsZ() {
        let h = Harness()
        _ = h.press("e")
        h.toastUndo?()
        XCTAssertEqual(h.shown.first, "q3")
        XCTAssertEqual(h.cursor, "q3")
        XCTAssertEqual(h.shown.count, 40)
    }

    func testUndoWithTwoEntriesOffersTheOneBeforeIt() {
        let h = Harness()
        _ = h.press("e")
        _ = h.press("e")
        _ = h.press("z")
        XCTAssertEqual(h.shown.count, 39)
        XCTAssertEqual(h.toasts.last?.action, .undoPrevious("Marked Done"))
        XCTAssertEqual(h.session.undoStack.count, 1)
        h.toastUndo?()
        XCTAssertEqual(h.shown.count, 40)
        XCTAssertEqual(h.shown.first, "q3")
    }

    func testZWithNothingToUndoDoesNothing() {
        let h = Harness()
        XCTAssertTrue(h.press("z"))
        XCTAssertEqual(h.shown.count, 40)
        XCTAssertTrue(h.toasts.isEmpty)
    }

    // MARK: Star and unread

    func testStarMarksTheRowInPlaceWithNoToastAndIsAnUndoStep() {
        let h = Harness()
        _ = h.press("j")
        let target = h.model.rows[1].id
        let wasStarred = h.model.rows[1].isStarred
        XCTAssertTrue(h.press("s"))
        XCTAssertEqual(h.model.rows[1].isStarred, !wasStarred)
        XCTAssertEqual(h.shown.count, 40, "nothing moves")
        XCTAssertEqual(h.model.cursor, target)
        XCTAssertTrue(h.toasts.isEmpty, "a star shows on the row")
        XCTAssertEqual(h.session.undoStack.count, 1)
        _ = h.press("z")
        XCTAssertEqual(h.model.rows[1].isStarred, wasStarred)
    }

    func testUMarksTheCursorRowUnreadAndReadByToggling() {
        let h = Harness()
        _ = h.press("j")
        _ = h.press("j")                       // "receipt"? whichever it is, read it first
        let reading = h.model.rows[2].isUnread
        _ = h.press("u")
        XCTAssertEqual(h.model.rows[2].isUnread, !reading)
        _ = h.press("u")
        XCTAssertEqual(h.model.rows[2].isUnread, reading)
    }

    // MARK: Opening

    func testReturnOpensTheCursorsConversationAndEscapeClosesIt() {
        let h = Harness()
        _ = h.press("j")
        XCTAssertTrue(h.session.handle(.returnKey))
        XCTAssertEqual(h.open, h.shown[1])
        XCTAssertNotNil(h.session.navigation.reader)

        XCTAssertTrue(h.session.handle(.escape))
        XCTAssertNil(h.open)
        XCTAssertNil(h.session.navigation.reader)
        XCTAssertEqual(h.cursor, h.shown[1], "the cursor is where he was")
    }

    func testATapOpensARowAndPlacesTheCursorOnIt() {
        let h = Harness()
        let target = h.model.rows[4].id
        h.session.open(target)
        XCTAssertEqual(h.session.openConversation, target)
        XCTAssertEqual(h.model.cursor, target)
        h.session.close()
        XCTAssertNil(h.session.openConversation)
    }

    func testTheArrowsAndTheLeftArrowOpenAndClose() {
        let h = Harness()
        XCTAssertTrue(h.session.handle(.right))
        XCTAssertNotNil(h.open)
        XCTAssertTrue(h.session.handle(.left))
        XCTAssertNil(h.open)
        XCTAssertFalse(h.session.handle(.left), "← in the list is not Mail's")
    }

    func testJAndKStepThroughConversationsWhileOneIsOpen() {
        let h = Harness()
        h.session.open(h.model.rows[0].id)
        XCTAssertTrue(h.press("j"))
        XCTAssertEqual(h.open, h.shown[1])
        XCTAssertEqual(h.cursor, h.shown[1])
        XCTAssertTrue(h.press("k"))
        XCTAssertEqual(h.open, h.shown[0])
        XCTAssertTrue(h.model.canStep(.older))
        XCTAssertFalse(h.model.canStep(.newer), "the newest has nothing newer")
    }

    func testOpeningAnUnreadConversationReadsItAfterFourHundredMillisecondsAndIsNotAnUndoStep() {
        let h = Harness()
        let target = h.model.rows[0].id
        XCTAssertTrue(h.model.rows[0].isUnread)
        h.session.open(target)
        XCTAssertTrue(h.model.rows[0].isUnread, "not yet: a conversation passed through is not read")
        XCTAssertTrue(h.timers.contains { $0.delay == MailListModel.readDelay })

        h.fire(after: MailListModel.readDelay)

        XCTAssertFalse(h.model.rows[0].isUnread)
        XCTAssertTrue(h.session.undoStack.isEmpty, "being marked read by opening is not an undo step")
        XCTAssertTrue(h.toasts.isEmpty)
    }

    func testDoneInsideAnOpenConversationOpensTheNextOneAndTheDoneOneIsGone() {
        let h = Harness()
        h.session.open(h.model.rows[0].id)
        XCTAssertTrue(h.press("e"))
        XCTAssertFalse(h.shown.contains("q3"))
        XCTAssertEqual(h.open, "invite", "the run goes on to the next, under a header that has not moved")
        XCTAssertEqual(h.toasts.last?.action, .undo)

        XCTAssertTrue(h.press("z"))
        XCTAssertEqual(h.open, "q3", "undo reopens what was open, at the place it was")
        XCTAssertEqual(h.shown.first, "q3")
    }

    func testTheReaderHasTheConversationAndItsBodies() async throws {
        let h = Harness()
        h.session.open(id("q3"))
        let reader = try XCTUnwrap(h.session.navigation.reader)
        XCTAssertEqual(reader.id, id("q3"))
        await reader.waitForBodies()
        XCTAssertEqual(reader.conversation?.messages.count, 3)
        XCTAssertEqual(reader.bodies.count, 3)
        XCTAssertFalse(reader.isLoading)
    }

    func testAConversationThatIsGoneIsReportedAsNotHere() {
        let h = Harness()
        let reader = MailReaderModel(id: id("nope"), source: h.source)
        XCTAssertNil(reader.conversation)
        XCTAssertFalse(reader.isLoading, "the source said it holds none")
    }

    // MARK: A swipe

    func testASwipeActsOnItsRowAndTheCursorStaysWhereItIs() {
        let h = Harness()
        _ = h.press("j")
        let cursor = h.cursor
        let target = h.model.rows[5].id
        h.session.act(.done, on: target)
        XCTAssertFalse(h.shown.contains(target.thread))
        XCTAssertEqual(h.cursor, cursor, "a cursor that was not a target is its own successor")
        XCTAssertEqual(h.session.undoStack.count, 1)
        XCTAssertEqual(h.toasts.count, 1)
    }

    func testAnActionFromTheOpenConversationsHeaderActsOnTheOpenConversation() {
        let h = Harness()
        h.session.open(h.model.rows[2].id)
        let opened = h.open
        let wasStarred = h.model.rows[2].isStarred
        h.session.act(.toggleStar)
        XCTAssertEqual(h.model.rows[2].isStarred, !wasStarred)
        XCTAssertEqual(h.open, opened, "a star leaves it open")
    }

    // MARK: Rest, keys that are not Mail's, leaving

    func testTheListRestsThreeSecondsAfterTheLastInput() {
        let h = Harness()
        _ = h.press("j")
        XCTAssertFalse(h.model.isIdle)
        XCTAssertTrue(h.timers.contains { $0.delay == MailSession.idleAfter })
        h.fire(after: MailSession.idleAfter)
        XCTAssertTrue(h.model.isIdle)
    }

    func testEachInputStartsTheThreeSecondsAgain() {
        let h = Harness()
        _ = h.press("j")
        _ = h.press("j")
        let waiting = h.timers.filter { $0.delay == MailSession.idleAfter && !$0.cancelled }
        XCTAssertEqual(waiting.count, 1, "the first was cancelled by the second")
    }

    func testAKeyThatIsNotMailsIsNotTaken() {
        let h = Harness()
        // (C is Mail's now: it opens a new message, which MailComposerTests holds.)
        for key in ["t", "d", "w", "n", "b", "1", "?"] {
            XCTAssertFalse(h.press(Character(key)), key)
        }
        XCTAssertFalse(h.press("j", shift: true))
        XCTAssertEqual(h.shown.count, 40)
        XCTAssertEqual(h.cursor, "q3")
    }

    func testLeavingAndComingBackKeepsTheCursorAndTheOpenConversation() {
        let h = Harness()
        _ = h.press("j")
        _ = h.press("j")
        let cursor = h.cursor
        h.session.leave()
        h.session.enter()
        XCTAssertEqual(h.cursor, cursor)
        XCTAssertEqual(h.shown.count, 40)

        h.session.open(h.model.rows[3].id)
        let open = h.open
        h.session.leave()                      // the iOS tree is thrown away in the background
        XCTAssertEqual(h.open, open, "it lives in the session, not in the view tree")
        h.session.enter()
        XCTAssertEqual(h.open, open)
        XCTAssertNotNil(h.session.navigation.reader)
    }

    func testAColdLaunchReopensTheConversationThatWasOpenIfTheListStillHasIt() {
        let h = Harness()
        h.session.restoreOpen(id("forty"))
        XCTAssertEqual(h.open, "forty")
        XCTAssertEqual(h.cursor, "forty")

        let gone = Harness()
        gone.session.restoreOpen(id("no-such-conversation"))
        XCTAssertNil(gone.open, "a restored conversation that no longer exists is dropped")
    }

    // MARK: The reading pane

    func testThePaneShowsTheCursorsConversationAtOnceWhenItComesOnScreen() {
        let h = Harness()
        XCTAssertNil(h.session.pane.reader, "no pane on screen, no reader")
        h.session.setPaneVisible(true)
        XCTAssertEqual(h.session.pane.reader?.id, id("q3"))
        h.session.setPaneVisible(false)
        XCTAssertNil(h.session.pane.reader, "a hidden pane holds nothing")
    }

    func testAHeldJMakesOneReaderForTheConversationItStopsOn() {
        let h = Harness()
        h.session.setPaneVisible(true)
        let first = h.session.pane.reader
        for _ in 0..<30 { _ = h.press("j", repeating: true) }

        XCTAssertEqual(h.cursor, h.shown[30], "the cursor moved at once, thirty rows")
        XCTAssertTrue(h.session.pane.reader === first, "the pane has not been rebuilt for any of them")
        let waiting = h.timers.filter { $0.delay == MailPaneModel.rest && !$0.cancelled }
        XCTAssertEqual(waiting.count, 1, "each move cancelled the rest before it")

        h.fire(after: MailPaneModel.rest)
        XCTAssertEqual(h.session.pane.reader?.id, h.model.cursor)
        XCTAssertEqual(h.session.pane.reader?.id.thread, h.shown[30])
        XCTAssertFalse(h.session.pane.reader === first)
    }

    func testTheRestIsAboutOneHundredAndFiftyMilliseconds() {
        XCTAssertEqual(MailPaneModel.rest, 0.15, accuracy: 0.0001)
    }

    func testAMoveOffScreenForThePaneCostsItNothing() {
        let h = Harness()
        _ = h.press("j")
        XCTAssertFalse(h.timers.contains { $0.delay == MailPaneModel.rest }, "no pane: nothing is scheduled")
    }

    func testTheCursorsHighlightMovesAtOnceWhateverThePaneIsDoing() {
        let h = Harness()
        h.session.setPaneVisible(true)
        let marks = h.session.marks
        let second = h.model.rows[1].id
        _ = h.press("j")
        XCTAssertTrue(marks.mark(for: second).hasCursor, "the mark moved in the turn of the key")
        XCTAssertEqual(h.session.pane.reader?.id, id("q3"), "and the pane has not followed yet")
    }

    func testDoneMovesThePaneOnToTheConversationTheModelPicks() {
        let h = Harness()
        h.session.setPaneVisible(true)
        _ = h.press("e")
        h.fire(after: MailPaneModel.rest)
        XCTAssertEqual(h.session.pane.reader?.id, id("invite"))
        XCTAssertEqual(h.cursor, "invite")
    }

    func testAnEmptiedListLeavesThePaneWithNothing() {
        let h = Harness()
        h.session.setPaneVisible(true)
        for _ in 0..<40 { _ = h.press("e") }
        h.fire(after: MailPaneModel.rest)
        XCTAssertNil(h.session.pane.reader)
    }

    func testPaneDelayedReadCarriesTheDisplayedArrivalBoundary() throws {
        let h = Harness()
        var reading: MailListSnapshot?
        let observation = h.source.observeList(MailSession.inbox, limit: 50) { reading = $0 }
        var snapshot = try XCTUnwrap(reading)
        snapshot.rows[0].actionBoundary = 77
        _ = h.model.handle(.snapshot(snapshot, answersEntry: true))
        let row = try XCTUnwrap(h.model.rows.first)
        XCTAssertEqual(row.actionBoundary, 77)
        var targets: [MailTarget] = []
        var timers: [(TimeInterval, @MainActor () -> Void)] = []
        let pane = MailPaneModel(source: h.source, timers: MailTimers { delay, work in
            timers.append((delay, work)); return {}
        }, markRead: { targets.append($0) })
        pane.follow(h.model)
        pane.setActive(true)
        let dwell = try XCTUnwrap(timers.first { $0.0 == MailListModel.readDelay })
        dwell.1()
        XCTAssertEqual(targets, [.asShown([row])])
        pane.setActive(false)
        observation.cancel()
    }

    func testAConversationShownInThePaneIsReadAfterTheReadDelayAndIsNoUndoStep() {
        let h = Harness()
        XCTAssertTrue(h.model.rows[0].isUnread)
        h.session.setPaneVisible(true)
        XCTAssertTrue(h.model.rows[0].isUnread, "shown, not yet read")

        h.fire(after: MailListModel.readDelay)

        XCTAssertFalse(h.model.rows[0].isUnread)
        XCTAssertTrue(h.session.undoStack.isEmpty)
        XCTAssertTrue(h.toasts.isEmpty)
    }

    func testAConversationPassedThroughIsNotRead() {
        let h = Harness()
        h.session.setPaneVisible(true)                       // q3, unread
        _ = h.press("j")                                     // gone again before the delay
        h.fire(after: MailPaneModel.rest)                    // the pane moves on: its dwell on q3 is dropped
        let q3 = h.model.rows[0]
        XCTAssertTrue(q3.isUnread, "he did not stay on it")
    }

    // MARK: Places

    func testChoosingAPlaceShowsItsList() {
        let h = Harness()
        h.session.show(.starred)
        XCTAssertEqual(h.session.scope, MailScope(place: .mailbox(.starred)))
        XCTAssertEqual(h.session.navigation.scope, h.session.scope)
        XCTAssertFalse(h.shown.isEmpty)
        XCTAssertTrue(h.model.rows.allSatisfy(\.isStarred), "only what is starred")
        XCTAssertEqual(h.cursor, h.shown.first, "a first visit has the cursor on the first row")

        h.session.show(.done)
        XCTAssertTrue(h.shown.isEmpty, "nothing is Done yet")
        XCTAssertNil(h.cursor)
    }

    func testEachPlaceKeepsItsOwnCursor() {
        let h = Harness()
        _ = h.press("j")
        _ = h.press("j")
        let inboxCursor = h.cursor
        h.session.show(.starred)
        _ = h.press("j")
        h.session.show(.inbox)
        XCTAssertEqual(h.cursor, inboxCursor, "where he left it")
        XCTAssertEqual(h.shown.count, 40)
    }

    func testDoneInTheInboxAppearsInDoneAndShiftEBringsItBack() {
        let h = Harness()
        _ = h.press("e")
        h.session.show(.done)
        XCTAssertEqual(h.shown, ["q3"])
        XCTAssertEqual(h.session.places.total(of: .done), 1)

        XCTAssertTrue(h.press("e", shift: true), "⇧E in Done is Back to the inbox")
        XCTAssertTrue(h.shown.isEmpty)
        XCTAssertEqual(h.toasts.last?.text, "\u{201C}Q3 numbers before Thursday\u{201D} is back in the inbox")
        h.session.show(.inbox)
        XCTAssertEqual(h.shown.count, 40)
        XCTAssertEqual(h.shown.first, "q3")
    }

    func testUndoFromAnotherPlaceShowsThePlaceTheChangeWasMadeIn() {
        let h = Harness()
        _ = h.press("e")
        h.session.show(.starred)
        _ = h.press("z")
        XCTAssertEqual(h.session.scope, MailSession.inbox, "undo shows where it is putting things back")
        XCTAssertEqual(h.shown.count, 40)
        XCTAssertEqual(h.cursor, "q3")
    }

    func testAConversationOpenFullWidthIsClosedWhenAnotherPlaceIsChosen() {
        let h = Harness()
        h.session.open(h.model.rows[0].id)
        h.session.show(.starred)
        XCTAssertNil(h.session.openConversation)
        XCTAssertNil(h.session.navigation.reader)
        h.session.show(.inbox)
        XCTAssertNil(h.open, "and it is closed in the place he left too")
    }

    func testThePlacesCountsAreTheMailboxsAndPlacingChangesNothingInThem() {
        let h = Harness()
        XCTAssertEqual(h.session.places.total(of: .inbox), 40)
        _ = h.press("e")
        XCTAssertEqual(h.session.places.total(of: .inbox), 39)
        h.session.show(.starred)
        XCTAssertEqual(h.session.places.total(of: .inbox), 39)
    }

    // MARK: The columns' keys

    func testBackslashTogglesThePaneAndTheBracketTheDetails() {
        let h = Harness()
        XCTAssertTrue(h.session.navigation.showsPane)
        XCTAssertTrue(h.press("\\"))
        XCTAssertFalse(h.session.navigation.showsPane)
        XCTAssertTrue(h.press("\\"))
        XCTAssertTrue(h.session.navigation.showsPane)

        XCTAssertTrue(h.session.navigation.showsDetails)
        XCTAssertTrue(h.press("]"))
        XCTAssertFalse(h.session.navigation.showsDetails)
        XCTAssertTrue(h.press("]", repeating: true), "held down it acts once")
        XCTAssertFalse(h.session.navigation.showsDetails)
    }

    func testTheTogglesWorkWithAConversationOpen() {
        let h = Harness()
        h.session.open(h.model.rows[0].id)
        XCTAssertTrue(h.press("\\"))
        XCTAssertFalse(h.session.navigation.showsPane)
        XCTAssertNotNil(h.open, "toggling a column does not close what is open")
    }

    func testTheOpenConversationIsAnIdThatCanBeKeptInShellState() {
        let h = Harness()
        h.session.open(id("q3"))
        let text = h.session.openConversation?.text
        XCTAssertEqual(text, "noor@plan.example|q3")
        XCTAssertEqual(text.flatMap(MailConversationID.init(text:)), id("q3"))
    }
}
#endif
