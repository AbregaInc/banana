import XCTest
import Combine

/// The keys of the first Mail screen, held against the table of MAIL-UX T14 and 4.2, and the
/// cursor marks that a key moves.
@MainActor
final class MailKeymapTests: XCTestCase {

    private func command(_ key: MailKey, shift: Bool = false, open: Bool = false,
                         repeating: Bool = false) -> MailKeyCommand? {
        MailKeymap.command(for: key, shift: shift, isOpen: open, isRepeat: repeating)
    }

    func testJAndKAndTheArrowsMoveTheCursor() {
        XCTAssertEqual(command(.character("j")), .move(.older))
        XCTAssertEqual(command(.down), .move(.older))
        XCTAssertEqual(command(.character("k")), .move(.newer))
        XCTAssertEqual(command(.up), .move(.newer))
        // With a conversation open they are the same keys: the model steps to the next one.
        XCTAssertEqual(command(.character("j"), open: true), .move(.older))
    }

    func testReturnAndRightOpenAndOnlyFromTheList() {
        XCTAssertEqual(command(.returnKey), .open)
        XCTAssertEqual(command(.right), .open)
        XCTAssertEqual(command(.returnKey, open: true), .replyAll,
                       "in an open conversation it replies to all, which is what 4.2.3 says of it")
        XCTAssertNil(command(.right, open: true), "→ would open what is already open")
    }

    func testTheWritingKeysAreTheTableOf423() {
        XCTAssertEqual(command(.character("r")), .reply)
        XCTAssertEqual(command(.character("r"), open: true), .reply)
        XCTAssertEqual(command(.character("f")), .forward)
        XCTAssertEqual(command(.character("f"), open: true), .forward)
        XCTAssertEqual(command(.character("c")), .compose)
        XCTAssertEqual(command(.character("c"), open: true), .compose)
        // A shifted key is another key, and a held one acts once.
        for key in ["r", "f", "c"] {
            XCTAssertNil(command(.character(Character(key)), shift: true), "⇧\(key)")
            XCTAssertNil(command(.character(Character(key)), repeating: true), "\(key) held down")
        }
        // Reply to all is the one key the design gives it; A is Add to plan's, which comes later.
        XCTAssertNil(command(.character("a")))
        XCTAssertNil(command(.delete), "Backspace is only ever typing")
    }

    func testEscapeGoesBackAndLeftClosesAnOpenConversation() {
        XCTAssertEqual(command(.escape), .back)
        XCTAssertEqual(command(.escape, open: true), .back)
        XCTAssertEqual(command(.left, open: true), .close)
        XCTAssertNil(command(.left), "← in the list is not Mail's yet")
    }

    func testTheActionKeysAreTheTableOfT14() {
        XCTAssertEqual(command(.character("e")), .act(.done))
        XCTAssertEqual(command(.character("s")), .act(.toggleStar))
        XCTAssertEqual(command(.character("u")), .act(.toggleRead))
        XCTAssertEqual(command(.character("z")), .undo)
        // The key each action is documented under is the key that does it.
        XCTAssertEqual(MailAction.done.key, "E")
        XCTAssertEqual(MailAction.toggleStar.key, "S")
        XCTAssertEqual(MailAction.toggleRead.key, "U")
    }

    func testAShiftedKeyIsAnotherKeyAndNotMailsYetExceptShiftE() {
        for key in ["j", "k", "s", "u", "z"] {
            XCTAssertNil(command(.character(Character(key)), shift: true), "⇧\(key)")
        }
        XCTAssertEqual(command(.character("e"), shift: true), .notDone, "⇧E: Not done, named for the place")
        XCTAssertNil(command(.character("e"), shift: true, repeating: true), "and it acts once")
        XCTAssertEqual(MailAction.notDone(in: .mailbox(.done)), .backToInbox)
        XCTAssertEqual(MailAction.notDone(in: .mailbox(.inbox)), .notDone)
    }

    func testTheTwoFreeKeysToggleTheColumnsAndActOnce() {
        XCTAssertEqual(command(.character("\\")), .togglePane)
        XCTAssertEqual(command(.character("]")), .toggleDetails)
        XCTAssertEqual(command(.character("\\"), open: true), .togglePane, "with a conversation open too")
        XCTAssertNil(command(.character("\\"), repeating: true))
        XCTAssertNil(command(.character("]"), repeating: true))
    }

    func testAKeyMailDoesNotKnowIsNotTaken() {
        for key in ["t", "d", "w", "n", "b", "1", "?", "/"] {
            XCTAssertNil(command(.character(Character(key))), key)
        }
    }

    func testAHeldKeyMovesOnEveryRepeatAndEveryOtherKeyActsOnce() {
        XCTAssertEqual(command(.character("j"), repeating: true), .move(.older))
        XCTAssertEqual(command(.down, repeating: true), .move(.older))
        XCTAssertEqual(command(.character("k"), repeating: true), .move(.newer))
        for key in [MailKey.character("e"), .character("s"), .character("u"), .character("z"),
                    .returnKey, .escape] {
            XCTAssertNil(command(key, repeating: true), "\(key) held down acts once (K7)")
        }
    }

    // MARK: The marks

    func testMovingTheCursorFlipsTwoMarksAndNothingElse() {
        let h = TriageHarness()
        let marks = MailRowMarks(model: h.model)
        let ids = ["A", "B", "C", "D"].map { h.id($0) }
        let made = ids.map { marks.mark(for: $0) }
        XCTAssertEqual(made.map(\.hasCursor), [true, false, false, false], "a mark is made right")
        XCTAssertTrue(marks.mark(for: ids[0]) === made[0], "one mark for each row")

        var flips = [Int](repeating: 0, count: made.count)
        let watching = made.enumerated().map { index, mark in
            mark.objectWillChange.sink { flips[index] += 1 }
        }
        h.send(.move(.older))
        XCTAssertEqual(made.map(\.hasCursor), [false, true, false, false])
        XCTAssertEqual(flips, [1, 1, 0, 0], "the row it left and the row it reached, and no other")

        h.send(.move(.older))
        XCTAssertEqual(made.map(\.hasCursor), [false, false, true, false])
        XCTAssertEqual(flips, [1, 2, 1, 0])
        withExtendedLifetime(watching) {}
    }

    func testARowDrawnForTheFirstTimeAfterTheCursorMovedIsAlreadyRight() {
        let h = TriageHarness()
        let marks = MailRowMarks(model: h.model)
        h.send(.move(.older))
        h.send(.move(.older))
        XCTAssertTrue(marks.mark(for: h.id("C")).hasCursor)
        XCTAssertFalse(marks.mark(for: h.id("A")).hasCursor)
    }
}
