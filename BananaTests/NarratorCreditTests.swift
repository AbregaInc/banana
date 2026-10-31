import XCTest

/// Reading the narrator from what the publisher already wrote.
///
/// Every case here came from a real feed of 799 episodes. The decoration is the whole difficulty:
/// flags, a writing hand trailing the writer credit, non-breaking spaces, and short forms mixed in
/// beside full names. Get any of it wrong and one narrator reads as two, so muting one leaves the
/// other still arriving.
final class NarratorCreditTests: XCTestCase {

    func testReadsAPlainCredit() {
        XCTAssertEqual(NarratorCredit.name(in: "Narrator: Thomas Jones 🇬🇧"), "Thomas Jones")
    }

    func testStopsAtTheNextCredit() {
        XCTAssertEqual(
            NarratorCredit.name(in: "Narrator: Vanessa Labrie 🇨🇦 Writer: Chase Doan ✍️"),
            "Vanessa Labrie")
    }

    /// The case that broke the roster: U+FE0F is a nonspacing mark, and `CharacterSet.letters`
    /// spans Unicode categories L* AND M*, so the variation selector counted as a letter and
    /// survived — leaving "Thomas Jones ✍️" as a second spelling of the same person.
    func testStripsTheWritingHandAndItsVariationSelector() {
        XCTAssertEqual(NarratorCredit.name(in: "Narrator: Thomas Jones ✍️🇬🇧 \nIncludes mentions of: Gratitude"),
                       "Thomas Jones")
    }

    func testHandlesNonBreakingSpaceBothWays() {
        XCTAssertEqual(NarratorCredit.name(in: "Narrator: Arif Hodzic 🇺🇸&nbsp;"), "Arif Hodzic")
        XCTAssertEqual(NarratorCredit.name(in: "Narrator: Arif\u{00A0}Hodzic 🇺🇸"), "Arif Hodzic")
    }

    func testKeepsRealAccents() {
        XCTAssertEqual(NarratorCredit.name(in: "Narrator: Jessika Downes-Gössl 🇬🇧"),
                       "Jessika Downes-Gössl")
    }

    func testNoCreditIsNotAGuess() {
        XCTAssertNil(NarratorCredit.name(in: "A gentle story about a lighthouse."))
        XCTAssertNil(NarratorCredit.name(in: nil))
        XCTAssertNil(NarratorCredit.name(in: ""))
    }

    // MARK: - Resolving short forms

    func testAShortFormResolvesOntoItsFullName() {
        XCTAssertEqual(NarratorCredit.canonical("Thomas", among: ["Thomas Jones", "Nadine Brown"]),
                       "Thomas Jones")
    }

    /// An ambiguous short form must stay as written: silently picking one of two people would mute
    /// episodes the listener never chose to mute.
    func testAnAmbiguousShortFormIsLeftAlone() {
        XCTAssertEqual(NarratorCredit.canonical("Chris", among: ["Chris Adams", "Chris Bell"]),
                       "Chris")
    }

    func testAFullNameIsUnchanged() {
        XCTAssertEqual(NarratorCredit.canonical("Nadine Brown", among: ["Nadine Brown"]), "Nadine Brown")
    }

    // MARK: - The roster

    func testTheRosterMergesSpellingsAndShortForms() {
        let summaries: [String?] = [
            "Narrator: Thomas Jones 🇬🇧", "Narrator: Thomas 🇬🇧", "Narrator: Thomas Jones ✍️🇬🇧",
            "Narrator: Chloe De Burgh 🇬🇧", "Narrator: Chloe de Burgh 🇬🇧",
            "no narrator here",
        ]
        let roster = NarratorCredit.roster(for: summaries)
        XCTAssertEqual(roster.count, 2, "three spellings of Thomas and two of Chloe are two people")
        XCTAssertEqual(roster[0].name, "Thomas Jones")
        XCTAssertEqual(roster[0].episodes, 3)
        XCTAssertEqual(roster[1].name, "Chloe De Burgh")
        XCTAssertEqual(roster[1].episodes, 2)
    }

    func testTheRosterIsOrderedByHowMuchTheyNarrate() {
        let roster = NarratorCredit.roster(for: [
            "Narrator: Quiet One 🇬🇧",
            "Narrator: Busy One 🇬🇧", "Narrator: Busy One 🇬🇧",
        ] as [String?])
        XCTAssertEqual(roster.map(\.name), ["Busy One", "Quiet One"])
    }
}
