import XCTest

/// The queue a sideways swipe in the open conversation moves through (`MailConversationPager`):
/// the list it was opened from, as shown, with `MailListModel.neighbourID(of:_:)` naming the pages
/// beside the open one and a swipe that settles opening the neighbour as `J` or `K` does (T12).
@MainActor
final class MailSwipeQueueTests: XCTestCase {

    /// The pages beside the open one, by letter: (newer, older).
    private func pages(_ h: TriageHarness) -> (newer: String?, older: String?) {
        guard let open = h.model.open?.id else { return (nil, nil) }
        return (h.model.neighbourID(of: open, .newer)?.thread, h.model.neighbourID(of: open, .older)?.thread)
    }

    func testTheNeighboursAreTheRowsBesideTheOpenOneInTheListItWasOpenedFrom() {
        let h = TriageHarness()
        h.send(.open(h.id("D")))
        XCTAssertEqual(pages(h).newer, "C")
        XCTAssertEqual(pages(h).older, "E")
        // The page beside a neighbour, for a page that is not the open one.
        XCTAssertEqual(h.model.neighbourID(of: h.id("E"), .older)?.thread, "F")
        XCTAssertEqual(h.model.neighbourID(of: h.id("C"), .newer)?.thread, "B")
    }

    func testAFilteredListIsItsOwnQueue() {
        let h = TriageHarness()
        for letter in ["C", "E", "H"] {
            if let index = h.mailbox.firstIndex(where: { $0.id.thread == letter }) { h.mailbox[index].isImportant = false }
        }
        h.show(h.other)
        XCTAssertEqual(h.shown, "CEH")
        h.send(.open(h.id("E")))
        XCTAssertEqual(pages(h).newer, "C")
        XCTAssertEqual(pages(h).older, "H", "F and G are not in this list")
        h.send(.step(.older))
        XCTAssertEqual(h.openLetter, "H")
        XCTAssertNil(pages(h).older)
    }

    func testAtEitherEndThereIsNoPageAndNoWrap() {
        let h = TriageHarness()
        h.send(.open(h.id("A")))
        XCTAssertNil(pages(h).newer)
        XCTAssertEqual(h.send(.step(.newer)), [])
        XCTAssertEqual(h.openLetter, "A")
        h.send(.open(h.id("J")))
        XCTAssertNil(pages(h).older)
        XCTAssertEqual(h.send(.step(.older)), [])
        XCTAssertEqual(h.openLetter, "J")
    }

    func testSwipingThroughLoadsTheNextPagesOfTheListAhead() {
        let h = TriageHarness(rows: 300, limit: 100)
        XCTAssertEqual(h.model.rows.count, 100)
        h.send(.open(h.id("A")))
        for _ in 0..<150 {
            XCTAssertNotNil(pages(h).older, "a page beyond is always there before the swipe reaches it")
            h.send(.step(.older))
        }
        XCTAssertEqual(h.openLetter, TriageHarness.letter(150))
        XCTAssertGreaterThan(h.model.rows.count, 151)
        XCTAssertFalse(h.growths.isEmpty, "the list asked for more ahead of the open conversation")
    }

    func testTheCursorFollowsEachSwipeAndCloseLeavesTheListThere() {
        let h = TriageHarness()
        h.send(.open(h.id("C")))
        let older = h.send(.step(.older))
        XCTAssertEqual(h.cursor, "D")
        XCTAssertTrue(older.contains(.reveal(h.id("D"), beyond: .older)))
        XCTAssertTrue(older.contains(.markReadAfter(h.id("D"), delay: 0.4)), "landing on it reads it, after the delay")
        h.send(.step(.older))
        h.send(.step(.newer))
        XCTAssertEqual(h.openLetter, "D")
        let closing = h.send(.close)
        XCTAssertEqual(h.cursor, "D")
        XCTAssertTrue(closing.contains(.reveal(h.id("D"), beyond: nil)), "back shows the list at that row")
    }

    func testDoneAdvancesTheWayHeWasSwiping() {
        let h = TriageHarness()
        h.send(.open(h.id("E")))
        h.send(.step(.newer))                    // D, travelling newer
        h.press(.done)
        XCTAssertEqual(h.openLetter, "C", "the next page in the direction of the swipe")
        h.send(.step(.older))                    // E, travelling older
        h.press(.done)
        XCTAssertEqual(h.openLetter, "F")
        XCTAssertEqual(pages(h).newer, "C", "D and E have left the list")
    }

    func testAnOpenConversationThatLeftTheListStillHasItsNeighbours() {
        let h = TriageHarness()
        h.send(.open(h.id("C")))
        h.outsideDone("C")
        XCTAssertEqual(h.shown, "ABDEFGHIJ")
        XCTAssertEqual(pages(h).newer, "B")
        XCTAssertEqual(pages(h).older, "D")
    }
}
