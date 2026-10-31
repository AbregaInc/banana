import XCTest

/// Which reminders read as something taken, by the bundled names (`TakenVocabulary`).
final class TakenVocabularyTests: XCTestCase {
    private let lists = TakenVocabulary.Lists(
        medications: ["levothyroxine", "synthroid", "sertraline", "fish oil"],
        supplements: ["creatine", "l-theanine", "lmnt", "vitamin d", "ashwagandha", "magnesium glycinate"])

    func testNamesAreFoundInsideATitle() {
        XCTAssertEqual(TakenVocabulary.kind(of: "Synthroid", in: lists), .medication)
        XCTAssertEqual(TakenVocabulary.kind(of: "Take my L-theanine", in: lists), .supplement)
        XCTAssertEqual(TakenVocabulary.kind(of: "LMNT after run", in: lists), .supplement)
        XCTAssertEqual(TakenVocabulary.kind(of: "Magnesium glycinate before bed", in: lists), .supplement, "a run of words")
        XCTAssertEqual(TakenVocabulary.kind(of: "Vitamins D", in: lists), nil)
        XCTAssertEqual(TakenVocabulary.kind(of: "Workout", in: lists), nil)
    }

    func testAMedicationWinsOverASupplement() {
        XCTAssertEqual(TakenVocabulary.kind(of: "Creatine and sertraline", in: lists), .medication)
    }

    func testThePluralIsTheSame() {
        let plural = TakenVocabulary.Lists(supplements: ["probiotic"])
        XCTAssertEqual(TakenVocabulary.kind(of: "Probiotics", in: plural), .supplement)
    }

    func testTheTakeableCheckUsesTheVocabulary() {
        XCTAssertTrue(ReminderToTaken.readsAsTaken("Synthroid", vocabulary: lists))
        XCTAssertEqual(ReminderToTaken.kind("Synthroid", vocabulary: lists), .medication)
        XCTAssertFalse(ReminderToTaken.readsAsTaken("Buy LMNT", vocabulary: lists), "about it, not taking it")
    }

    /// The bundled file, as built: real names in, household chores out.
    func testTheBundledVocabulary() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "TakenVocabulary", withExtension: "json"))
        let real = TakenVocabulary.load(url)
        XCTAssertGreaterThan(real.medications.count, 5_000)
        XCTAssertGreaterThan(real.supplements.count, 500)
        for taken in ["Synthroid", "Levothyroxine", "Zoloft", "Lexapro", "Creatine", "Ashwagandha", "L-Theanine", "Melatonin", "Fish oil"] {
            XCTAssertTrue(ReminderToTaken.readsAsTaken(taken, vocabulary: real), taken)
        }
        XCTAssertEqual(ReminderToTaken.kind("Synthroid", vocabulary: real), .medication)
        for chore in ["Workout", "Call Grandma", "Water the plants", "Weigh myself", "Take out the trash", "Walk the dog",
                      "Stretch", "Meditate", "Read", "Journal", "Drink water", "Laundry", "Pay rent", "Floss"] {
            XCTAssertFalse(ReminderToTaken.readsAsTaken(chore, vocabulary: real), chore)
        }
    }
}
