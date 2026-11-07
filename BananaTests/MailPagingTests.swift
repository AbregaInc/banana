import XCTest

/// Continuous scrolling (`MailPaging`): when the list asks for more, and what its last row says —
/// first the pure decision, then the model walking a long place by its screen and by its keys.
@MainActor
final class MailPagingTests: XCTestCase {

    // MARK: The decision

    private func state(first: Int = 0, last: Int, screen: Int = 12, loaded: Int = 100,
                       reading: Int? = nil, limit: Int = 100, inFlight: Bool = false,
                       hasMore: Bool = true, isSlid: Bool = false,
                       edge: MailPaging.Edge = .idle) -> MailPaging.State {
        MailPaging.State(firstVisible: first, lastVisible: last, screenRows: screen, loaded: loaded,
                         reading: reading ?? loaded, limit: limit, inFlight: inFlight,
                         hasMore: hasMore, isSlid: isSlid, edge: edge)
    }

    func testOlderMailIsAskedForWhileAboutAScreenIsStillToCome() {
        // 100 loaded, a 12-row screen: the lead is the minimum, 30 rows.
        XCTAssertEqual(MailPaging.decide(state(first: 57, last: 68)), .none, "31 rows to come: not yet")
        XCTAssertEqual(MailPaging.decide(state(first: 58, last: 69)), .grow(limit: 200), "30 to come: now")
        // A tall screen leads by a whole screen.
        XCTAssertEqual(MailPaging.decide(state(first: 0, last: 49, screen: 50)), .grow(limit: 200))
        XCTAssertEqual(MailPaging.decide(state(first: 0, last: 48, screen: 50)), .none)
        XCTAssertEqual(MailPaging.lead(screenRows: 0), MailPaging.minimumLead)
        XCTAssertEqual(MailPaging.lead(screenRows: 64), 64)
    }

    func testOneRequestIsOutAtATimeAndNothingIsAskedAtTheEnd() {
        XCTAssertEqual(MailPaging.decide(state(last: 99, inFlight: true)), .none)
        XCTAssertEqual(MailPaging.decide(state(last: 99, hasMore: false)), .none)
        XCTAssertEqual(MailPaging.decide(state(last: 0, loaded: 0, reading: 0)), .none)
    }

    func testAShortReadingWithMoreAsksTheEdgeOnceAndNotAfterAFailure() {
        XCTAssertEqual(MailPaging.decide(state(last: 70, loaded: 80, reading: 80)), .askEdge)
        XCTAssertEqual(MailPaging.decide(state(last: 70, loaded: 80, reading: 80, edge: .asked)), .none)
        XCTAssertEqual(MailPaging.decide(state(last: 70, loaded: 80, reading: 80, edge: .failed)), .none,
                       "after a failure only Retry asks")
    }

    func testAFullWindowSlidesOlderKeepingHalfAWindowAboveTheScreen() {
        let full = state(first: 1_960, last: 1_975, loaded: 2_000, limit: 2_000)
        XCTAssertEqual(MailPaging.decide(full), .slideOlder(keepingFrom: 960))
        XCTAssertEqual(MailPaging.decide(state(first: 990, last: 1_985, screen: 996, loaded: 2_000, limit: 2_000)),
                       .none, "a screen taller than half the window keeps every row above it")
    }

    func testASlidWindowSlidesNewerNearItsTopAndAWindowAtTheNewestDoesNot() {
        XCTAssertEqual(MailPaging.decide(state(first: 25, last: 36, loaded: 2_000, limit: 2_000, isSlid: true)),
                       .slideNewer)
        XCTAssertEqual(MailPaging.decide(state(first: 31, last: 42, loaded: 2_000, limit: 2_000, isSlid: true)),
                       .none)
        XCTAssertEqual(MailPaging.decide(state(first: 0, last: 11, loaded: 2_000, limit: 2_000)), .none)
    }

    func testTheLastRowSaysLoadingTheEndOrRetryWithTheFewestWords() {
        XCTAssertEqual(MailPaging.status(loaded: 0, hasMore: true, failed: false, hasPaged: true), .hidden)
        XCTAssertEqual(MailPaging.status(loaded: 40, hasMore: false, failed: false, hasPaged: false), .hidden,
                       "a list that never needed a second page has no last row to speak of")
        XCTAssertEqual(MailPaging.status(loaded: 40, hasMore: true, failed: false, hasPaged: false), .loading)
        XCTAssertEqual(MailPaging.status(loaded: 300, hasMore: false, failed: false, hasPaged: true), .end)
        XCTAssertEqual(MailPaging.status(loaded: 300, hasMore: true, failed: true, hasPaged: true), .failed)
    }

    // MARK: The model, by the screen

    private func viewport(_ h: TriageHarness, at index: Int, screen: Int = 12) -> MailViewport {
        let row = h.model.rows[index]
        return MailViewport(firstRow: row.id, key: row.key, offset: 0, rowsOnScreen: screen)
    }

    /// Flings toward the end until the place's last row is in: every step reports the screen a
    /// dozen rows from the end, as the host does while scrolling.
    @discardableResult
    private func scrollToTheEnd(_ h: TriageHarness, slides: inout Int) -> [MailConversationID] {
        var seenOnScreen: [MailConversationID] = []
        for _ in 0..<1_000 {
            let at = max(0, h.model.rows.count - 12)
            let shown = viewport(h, at: at)
            seenOnScreen.append(shown.firstRow)
            let windowBefore = h.model.windowBefore
            h.send(.scrolled(shown))
            if h.model.windowBefore != windowBefore { slides += 1 }
            XCTAssertTrue(h.model.rows.contains { $0.id == shown.firstRow }, "the row on screen stays")
            XCTAssertLessThanOrEqual(h.model.rows.count, MailTuning.listCap, "the window is bounded")
            if h.model.rows.last?.id == h.mailbox.last?.id, !h.model.list.shown.hasMore { break }
        }
        return seenOnScreen
    }

    func testScrollingWalksAWholePlaceInABoundedWindowAndBack() {
        let h = TriageHarness(rows: 6_000, limit: 100)
        var slides = 0
        scrollToTheEnd(h, slides: &slides)
        XCTAssertEqual(h.model.rows.last?.id.thread, TriageHarness.letter(5_999), "the last conversation is reached")
        XCTAssertGreaterThanOrEqual(slides, 3)
        XCTAssertNotNil(h.model.windowBefore)
        XCTAssertEqual(h.model.list.shown.paging, .end)
        XCTAssertEqual(h.model.list.shown.windowBefore, h.model.windowBefore, "the host is told the window moved")

        // Back up: a dozen rows below the window's top, every time, until the newest is in.
        for _ in 0..<1_000 {
            let shown = viewport(h, at: min(12, h.model.rows.count - 1))
            h.send(.scrolled(shown))
            XCTAssertTrue(h.model.rows.contains { $0.id == shown.firstRow }, "the row on screen stays")
            XCTAssertLessThanOrEqual(h.model.rows.count, MailTuning.listCap)
            if h.model.windowBefore == nil { break }
        }
        XCTAssertNil(h.model.windowBefore)
        XCTAssertEqual(h.model.rows.first?.id.thread, "A", "the newest mail is back at the top")
        // Every row the window holds is in order and appears once.
        let ids = h.model.rows.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(h.model.rows.map(\.key), h.model.rows.map(\.key).sorted(by: >))
    }

    func testTheWindowNeverSlidesBackAndForthAroundOnePlace() {
        let h = TriageHarness(rows: 6_000, limit: 100)
        // Down to the cap, then one slide.
        while h.model.windowBefore == nil {
            h.send(.scrolled(viewport(h, at: max(0, h.model.rows.count - 12))))
        }
        let slidAt = h.model.windowBefore
        // The screen rests where that slide left it, which is half a window from either end:
        // nothing more is asked for, either way.
        let resting = h.model.viewport!.firstRow
        let index = h.model.rows.firstIndex { $0.id == resting }!
        XCTAssertGreaterThan(index, MailPaging.minimumLead)
        XCTAssertGreaterThan(h.model.rows.count - index, MailPaging.minimumLead + 12)
        for _ in 0..<10 {
            let effects = h.send(.scrolled(viewport(h, at: index)))
            XCTAssertTrue(effects.isEmpty, "asked for \(effects)")
        }
        XCTAssertEqual(h.model.windowBefore, slidAt)
    }

    // MARK: The model, by the keys

    func testAHeldJCrossesEveryWindowEdgeAndAHeldKComesBack() {
        let h = TriageHarness(rows: 5_000, limit: 100)
        for step in 0..<4_999 {
            h.send(.move(.older))
            XCTAssertNotNil(h.model.cursor, "the cursor is always on a shown row (step \(step))")
            XCTAssertLessThanOrEqual(h.model.rows.count, MailTuning.listCap)
        }
        XCTAssertEqual(h.cursor, TriageHarness.letter(4_999))
        XCTAssertNotNil(h.model.windowBefore)
        for step in 0..<4_999 {
            h.send(.move(.newer))
            XCTAssertNotNil(h.model.cursor, "the cursor is always on a shown row (step \(step))")
        }
        XCTAssertEqual(h.cursor, "A")
        XCTAssertNil(h.model.windowBefore)
    }

    func testTheCursorStaysOnItsConversationWhenTheWindowSlidesPastItAndAKeyBringsItBack() {
        let h = TriageHarness(rows: 6_000, limit: 100)
        XCTAssertEqual(h.cursor, "A")
        var moves: [MailMarkChange] = []
        let watching = h.model.markChanges.sink { moves.append($0) }
        var slides = 0
        scrollToTheEnd(h, slides: &slides)
        XCTAssertNil(h.model.cursor, "its row has left the window")
        XCTAssertEqual(h.model.cursorConversation?.thread, "A", "the pane goes on showing it")
        XCTAssertTrue(moves.isEmpty, "the cursor did not move while he scrolled")
        let onScreen = h.model.viewport!.firstRow
        h.send(.move(.older))
        XCTAssertEqual(h.model.cursor, onScreen, "a key puts it on the first row on screen")
        withExtendedLifetime(watching) {}
    }

    func testCommandUpInASlidWindowGoesBackToTheNewest() {
        let h = TriageHarness(rows: 6_000, limit: 100)
        var slides = 0
        scrollToTheEnd(h, slides: &slides)
        XCTAssertNotNil(h.model.windowBefore)
        h.send(.jumpToNewest)
        XCTAssertNil(h.model.windowBefore)
        XCTAssertEqual(h.model.rows.first?.id.thread, "A")
        XCTAssertEqual(h.cursor, "A")
        XCTAssertLessThanOrEqual(h.model.rows.count, MailTuning.listCap)
    }

    // MARK: The model, at the edge

    private func reading(_ count: Int, scope: MailScope, hasMore: Bool = true,
                         remote: MailRemoteSearch? = nil) -> MailListSnapshot {
        MailListSnapshot(scope: scope, rows: (0..<count).map { TriageHarness.row("R\($0)", rank: $0) },
                         total: MailCount(value: count, isAtLeast: hasMore), hasMore: hasMore,
                         stillLoading: 0, isRebuilding: false, remote: remote, coverage: nil, appliedThrough: 0)
    }

    private func asks(_ effects: [MailListEffect]) -> Int {
        effects.filter { $0 == .askGmail }.count
    }

    func testTheEdgeIsAskedOncePerAnswerAndRetryFollowsAFailure() throws {
        let scope = MailScope(place: .mailbox(.inbox))
        let model = MailListModel(scope: scope, deviceName: "iPhone", timePhrase: { _ in "" })
        model.handle(.snapshot(reading(80, scope: scope)))
        func scrolledToEnd() -> [MailListEffect] {
            let row = model.rows[model.rows.count - 10]
            return model.handle(.scrolled(MailViewport(firstRow: row.id, key: row.key, offset: 0, rowsOnScreen: 10)))
        }
        XCTAssertEqual(asks(scrolledToEnd()), 1, "the device has given all it holds: the edge is asked")
        XCTAssertEqual(model.list.shown.paging, .loading)
        XCTAssertEqual(asks(scrolledToEnd()), 0, "asked once")
        model.handle(.snapshot(reading(80, scope: scope, remote: .pending)))
        XCTAssertEqual(asks(scrolledToEnd()), 0, "still out")
        // The answer: more rows, and the screen is still near their end, so the edge is asked
        // again at once.
        let answered = model.handle(.snapshot(reading(95, scope: scope), answersRequest: true))
        XCTAssertEqual(model.rows.count, 95)
        XCTAssertEqual(asks(answered), 1)
        XCTAssertEqual(asks(scrolledToEnd()), 0)
        // A failure stops asking and puts Retry on the last row.
        model.handle(.snapshot(reading(95, scope: scope, remote: .failed)))
        XCTAssertEqual(model.list.shown.paging, .failed)
        XCTAssertEqual(asks(scrolledToEnd()), 0)
        let retried = model.handle(.retryPaging)
        XCTAssertEqual(asks(retried), 1)
        XCTAssertTrue(retried.contains(.growTo(limit: model.limit)), "the window is read again")
        model.handle(.snapshot(reading(95, scope: scope, hasMore: false), answersRequest: true))
        XCTAssertEqual(model.list.shown.paging, .end)
    }

    func testASearchKeepsGoingWhileGmailSaysItHasMore() {
        let scope = MailScope(place: .search("invoice"))
        let model = MailListModel(scope: scope, deviceName: "iPhone", timePhrase: { _ in "" })
        model.handle(.snapshot(reading(40, scope: scope, hasMore: false, remote: .done(added: 10, more: true))))
        let row = model.rows[35]
        let effects = model.handle(.scrolled(MailViewport(firstRow: row.id, key: row.key, offset: 0, rowsOnScreen: 5)))
        XCTAssertEqual(asks(effects), 1, "Gmail's next page is asked for without a button")
        XCTAssertEqual(model.list.shown.paging, .loading)
    }

    func testAShortListSaysNothingAtItsEnd() {
        let h = TriageHarness(rows: 40)
        XCTAssertEqual(h.model.list.shown.paging, .hidden)
    }
}
