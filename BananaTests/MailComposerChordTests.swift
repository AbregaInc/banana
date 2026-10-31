import XCTest

/// The composer's chords on the Mac (`MailComposerChord`), told from the key's own modifiers.
/// SwiftUI's shortcut match does not count Shift, so every chord that has a twin one Shift away
/// was taken for it: plain ⌘A opened the file panel, ⌘C revealed Cc, ⌘, discarded the draft, and
/// ⇧⌘↩ sent without Done. Pure: the event's facts come in as arguments.
@MainActor
final class MailComposerChordTests: XCTestCase {

    private func resolve(_ characters: String = "", isReturn: Bool = false, command: Bool = true,
                         shift: Bool = false, option: Bool = false, control: Bool = false) -> MailComposerChord? {
        MailComposerChord.resolve(isReturn: isReturn, characters: characters, command: command, shift: shift,
                                  option: option, control: control)
    }

    // MARK: Send

    func testCommandReturnSendsAndShiftCommandReturnSendsAndMarksDone() {
        XCTAssertEqual(resolve(isReturn: true), .send)
        XCTAssertEqual(resolve(isReturn: true, shift: true), .sendAndDone)
    }

    func testReturnIsNotSendUnlessItIsExactlyOneOfThoseTwo() {
        for bits in 0..<16 {
            let command = bits & 1 != 0, shift = bits & 2 != 0, option = bits & 4 != 0, control = bits & 8 != 0
            let chord = resolve(isReturn: true, command: command, shift: shift, option: option, control: control)
            switch (command, shift, option, control) {
            case (true, false, false, false): XCTAssertEqual(chord, .send)
            case (true, true, false, false): XCTAssertEqual(chord, .sendAndDone)
            default: XCTAssertNil(chord, "command \(command) shift \(shift) option \(option) control \(control)")
            }
        }
    }

    // MARK: The table, held against the document (MAIL-UX 4.2.6)

    func testEachChordIsExactlyItsOwnAndItsShiftTwinIsAnother() {
        let plain: [String: MailComposerChord] = [
            "b": .format(.bold), "i": .format(.italic), "u": .format(.underline),
        ]
        let shifted: [String: MailComposerChord] = [
            "7": .paragraph(.number), "8": .paragraph(.bullet), "9": .paragraph(.quote),
            "v": .pastePlain, "a": .attach, "l": .sendLater, ",": .discard,
            "o": .recipient(.to), "c": .recipient(.cc), "b": .recipient(.bcc),
        ]
        for (key, chord) in plain { XCTAssertEqual(resolve(key), chord, "⌘\(key)") }
        for (key, chord) in shifted { XCTAssertEqual(resolve(key, shift: true), chord, "⇧⌘\(key)") }
        // The twin of each, one Shift away, is not the composer's: it is the system's or a section's.
        for key in shifted.keys where plain[key] == nil {
            XCTAssertNil(resolve(key), "plain ⌘\(key) is not the composer's (Copy, Paste, Select All, Settings, a section)")
        }
        for key in plain.keys where shifted[key] == nil {
            XCTAssertNil(resolve(key, shift: true), "⇧⌘\(key) is not a chord")
        }
        // ⌘B is bold and ⇧⌘B is Bcc, and neither takes the other.
        XCTAssertEqual(resolve("b"), .format(.bold))
        XCTAssertEqual(resolve("b", shift: true), .recipient(.bcc))
    }

    func testTheKeyIsReadWhateverShiftMadeOfIt() {
        // The event's characters are the key's own letter, or the symbol Shift makes of it.
        XCTAssertEqual(resolve("&", shift: true), .paragraph(.number))
        XCTAssertEqual(resolve("*", shift: true), .paragraph(.bullet))
        XCTAssertEqual(resolve("(", shift: true), .paragraph(.quote))
        XCTAssertEqual(resolve("<", shift: true), .discard)
        XCTAssertEqual(resolve("C", shift: true), .recipient(.cc))
        XCTAssertEqual(resolve("B"), .format(.bold))
    }

    func testOptionAndControlAreNeverTheComposers() {
        XCTAssertNil(resolve("b", option: true))
        XCTAssertNil(resolve("b", control: true))
        XCTAssertNil(resolve("c", shift: true, option: true))
        XCTAssertNil(resolve("c", shift: true, control: true))
    }

    func testWithoutCommandNothingIsAChord() {
        XCTAssertNil(resolve("b", command: false))
        XCTAssertNil(resolve("c", command: false, shift: true))
        XCTAssertNil(resolve(isReturn: true, command: false))
    }

    func testKeysTheComposerDoesNotOwnAreNotChords() {
        for key in ["z", "x", "k", "n", "r", "1", "2", "9", "/", "q"] {
            XCTAssertNil(resolve(key), "⌘\(key)")
        }
        for key in ["z", "x", "k", "n", "1", "m", "q"] {
            XCTAssertNil(resolve(key, shift: true), "⇧⌘\(key)")
        }
    }

    // MARK: When the composer is offered a chord

    func testTheComposerIsNotOfferedAChordUnderTheCommandMenuOrInTheFilePanel() {
        XCTAssertTrue(MailComposerChord.isOffered(commandMenuShown: false, inFilePanel: false))
        XCTAssertFalse(MailComposerChord.isOffered(commandMenuShown: true, inFilePanel: false))
        XCTAssertFalse(MailComposerChord.isOffered(commandMenuShown: false, inFilePanel: true))
        XCTAssertFalse(MailComposerChord.isOffered(commandMenuShown: true, inFilePanel: true))
    }

    // MARK: What views registered

    func testAChordRunsWhatItsViewRegisteredAndOnlyThat() {
        let chords = MailComposerChords()
        var ran: [String] = []
        let owner = UUID()
        XCTAssertFalse(chords.perform(.format(.bold)), "nothing registered")
        chords.register(.format(.bold), owner: owner) { ran.append("bold") }
        chords.register(.paragraph(.bullet), owner: owner) { ran.append("bullet") }
        XCTAssertTrue(chords.perform(.format(.bold)))
        XCTAssertFalse(chords.perform(.format(.italic)))
        XCTAssertTrue(chords.perform(.paragraph(.bullet)))
        XCTAssertEqual(ran, ["bold", "bullet"])
    }

    func testAViewThatGoesAwayTakesBackItsOwnChordsAndNotTheNewOnes() {
        // A view made again registers before the old one is gone: the old one must not wipe it.
        let chords = MailComposerChords()
        var ran: [String] = []
        let old = UUID(), new = UUID()
        chords.register(.format(.bold), owner: old) { ran.append("old") }
        chords.register(.format(.bold), owner: new) { ran.append("new") }
        chords.register(.format(.italic), owner: old) { ran.append("old italic") }
        chords.unregister(owner: old)
        XCTAssertTrue(chords.perform(.format(.bold)))
        XCTAssertFalse(chords.perform(.format(.italic)))
        XCTAssertEqual(ran, ["new"])
        chords.unregister(owner: new)
        XCTAssertFalse(chords.perform(.format(.bold)))
    }
}
