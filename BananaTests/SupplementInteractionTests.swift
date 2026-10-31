import XCTest

/// Timing conflicts between supplements, and between supplements and what you drink.
///
/// The governing rule is the one the ad-skipping work landed on: a warning that fires when it
/// shouldn't teaches you to dismiss the ones that matter. So these tests spend as much effort on
/// what must NOT be flagged as on what must.
final class SupplementInteractionTests: XCTestCase {

    private typealias SI = SupplementInteractions

    private func intake(_ name: String, at hour: Int, minute: Int = 0,
                        movable: Bool = true) -> SI.TimedIntake {
        SI.TimedIntake(name: name, minuteOfDay: hour * 60 + minute,
                       substances: SI.substances(in: name),
                       origin: movable ? .supplement : .food)
    }

    private func medication(_ name: String, at hour: Int, minute: Int = 0) -> SI.TimedIntake {
        SI.TimedIntake(name: name, minuteOfDay: hour * 60 + minute,
                       substances: SI.substances(in: name), origin: .medication)
    }

    // MARK: - Recognising what a bottle contains

    func testRecognisesPlainNames() {
        XCTAssertEqual(SI.substances(in: "Iron"), [.iron])
        XCTAssertEqual(SI.substances(in: "Calcium"), [.calcium])
    }

    /// Bottles are labelled by chemical form far more often than by the plain nutrient name.
    func testRecognisesChemicalForms() {
        XCTAssertTrue(SI.substances(in: "Ferrous Bisglycinate 25mg").contains(.iron))
        XCTAssertTrue(SI.substances(in: "Cholecalciferol 2000 IU").contains(.vitaminD))
        XCTAssertTrue(SI.substances(in: "Magnesium Glycinate").contains(.magnesium))
    }

    func testRecognisesCoffeeAsCaffeine() {
        XCTAssertTrue(SI.substances(in: "Flat white").isEmpty, "not every drink is coffee")
        XCTAssertTrue(SI.substances(in: "Coffee").contains(.caffeine))
        XCTAssertTrue(SI.substances(in: "Green tea").contains(.caffeine))
    }

    /// Word boundaries matter: a substring match would find nutrients inside unrelated words.
    func testDoesNotMatchInsideOtherWords() {
        XCTAssertFalse(SI.substances(in: "Ironwort tincture").contains(.iron))
        XCTAssertFalse(SI.substances(in: "Vitamin D30 blend").contains(.vitaminD))
    }

    // MARK: - The conflicts worth flagging

    /// The case the owner asked about first.
    func testIronAndCalciumTogetherIsFlagged() {
        let found = SI.conflicts(among: [intake("Iron", at: 8), intake("Calcium", at: 8)])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.rule.severity, .notable)
    }

    /// The coffee question, answered specifically: it is about iron.
    func testIronWithCoffeeIsFlagged() {
        let found = SI.conflicts(among: [
            intake("Iron", at: 8), intake("Coffee", at: 8, minute: 15, movable: false),
        ])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.rule.severity, .notable)
    }

    /// And the folklore corrected: coffee does not conflict with supplements in general.
    func testCoffeeWithMostSupplementsIsNotFlagged() {
        for supplement in ["Vitamin D", "Vitamin C", "Magnesium Glycinate", "Vitamin K2"] {
            let found = SI.conflicts(among: [
                intake(supplement, at: 8), intake("Coffee", at: 8, movable: false),
            ])
            XCTAssertTrue(found.isEmpty, "\(supplement) with coffee should not be flagged")
        }
    }

    func testThingsAlreadyFarApartAreNotFlagged() {
        let found = SI.conflicts(among: [intake("Iron", at: 8), intake("Calcium", at: 14)])
        XCTAssertTrue(found.isEmpty, "six hours apart is the rule already being followed")
    }

    /// A multivitamin contains several of these; telling someone it conflicts with itself is noise.
    func testAMultivitaminDoesNotConflictWithItself() {
        let multi = intake("Multivitamin with Iron and Calcium", at: 8)
        XCTAssertTrue(multi.substances.isSuperset(of: [.iron, .calcium]))
        XCTAssertTrue(SI.conflicts(among: [multi]).isEmpty)
    }

    func testSynergiesAreRecorded() {
        XCTAssertTrue(SI.synergies.contains { $0.a == .iron && $0.b == .vitaminC })
    }

    // MARK: - Rescheduling

    func testSuggestsATimeThatActuallyClearsTheConflict() {
        let intakes = [intake("Iron", at: 8), intake("Calcium", at: 8)]
        let suggestion = SI.suggestion(movingSupplementNamed: "Iron", among: intakes)
        let moved = try? XCTUnwrap(suggestion)
        XCTAssertNotNil(moved)
        guard let moved else { return }
        var rescheduled = intakes
        rescheduled[0].minuteOfDay = moved.toMinuteOfDay
        XCTAssertTrue(SI.conflicts(among: rescheduled).isEmpty,
                      "the suggested time must leave no conflict behind")
    }

    /// The smallest change that works — not the first slot of the day. 6am and 10am are both
    /// exactly two hours from 8am, and the tie goes to the later one deliberately: moving
    /// something earlier can push it before you are up, which resolves the rule on paper only.
    func testSuggestsTheNearestWorkableTimePreferringLater() {
        let intakes = [intake("Iron", at: 8), intake("Calcium", at: 8)]
        let moved = SI.suggestion(movingSupplementNamed: "Iron", among: intakes)
        XCTAssertEqual(moved?.toMinuteOfDay, 10 * 60)
    }

    /// A suggestion at 3am resolves the constraint and solves nothing.
    func testSuggestionsStayWithinWakingHours() {
        let intakes = [intake("Iron", at: 8), intake("Calcium", at: 8)]
        let moved = SI.suggestion(movingSupplementNamed: "Iron", among: intakes)
        XCTAssertGreaterThanOrEqual(moved?.toMinuteOfDay ?? 0, SI.earliestMinute)
        XCTAssertLessThanOrEqual(moved?.toMinuteOfDay ?? .max, SI.latestMinute)
    }

    func testNothingIsSuggestedWhenThereIsNoConflict() {
        let intakes = [intake("Iron", at: 8), intake("Calcium", at: 14)]
        XCTAssertNil(SI.suggestion(movingSupplementNamed: "Iron", among: intakes))
    }

    /// A meal is a fact about the day, not something to be rescheduled.
    func testMealsAreNeverProposedForMoving() {
        let intakes = [intake("Iron", at: 8), intake("Coffee", at: 8, movable: false)]
        XCTAssertNil(SI.suggestion(movingSupplementNamed: "Coffee", among: intakes))
        XCTAssertEqual(SI.suggestions(among: intakes).map(\.supplementName), ["Iron"])
    }

    /// Every rule must carry its remedy — an interaction with no separation has no place in a
    /// timing feature, and every rule must explain itself rather than assert a prohibition.
    func testEveryRuleIsActionableAndExplained() {
        for rule in SI.rules {
            XCTAssertGreaterThan(rule.separation, 0, "\(rule.a)-\(rule.b) has no remedy")
            XCTAssertGreaterThan(rule.because.count, 40, "\(rule.a)-\(rule.b) does not explain itself")
            XCTAssertNotEqual(rule.a, rule.b)
        }
    }

    // MARK: - Medications

    func testRecognisesMedicationsByGenericAndBrandName() {
        XCTAssertTrue(SI.substances(in: "Levothyroxine 100mcg").contains(.levothyroxine))
        XCTAssertTrue(SI.substances(in: "Synthroid").contains(.levothyroxine))
        XCTAssertTrue(SI.substances(in: "Doxycycline 100mg").contains(.tetracycline))
        XCTAssertTrue(SI.substances(in: "Cipro").contains(.fluoroquinolone))
        XCTAssertTrue(SI.substances(in: "Fosamax weekly").contains(.bisphosphonate))
    }

    func testChelationFamilyCoversEveryClassAgainstCalciumAndIron() {
        for drug in [SI.Substance.levothyroxine, .tetracycline, .fluoroquinolone, .bisphosphonate] {
            for mineral in [SI.Substance.calcium, .iron] {
                XCTAssertTrue(SI.rules.contains { rule in
                    (rule.a == drug && rule.b == mineral) || (rule.a == mineral && rule.b == drug)
                }, "\(drug.rawValue) vs \(mineral.rawValue) is missing")
            }
        }
    }

    func testLevothyroxineAndCalciumTakenTogetherIsAConflict() {
        let conflicts = SI.conflicts(among: [
            medication("Levothyroxine 100mcg", at: 7),
            intake("Calcium Citrate", at: 7, minute: 30),
        ])
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts.first?.rule.separation, 4 * 3600)
    }

    func testMorningCoffeeClashesWithLevothyroxineButNotWithMostThings() {
        let coffee = intake("Coffee", at: 7, minute: 15, movable: false)
        XCTAssertEqual(SI.conflicts(among: [medication("Levothyroxine", at: 7), coffee]).count, 1)
        XCTAssertTrue(SI.conflicts(among: [intake("Vitamin D", at: 7), coffee]).isEmpty)
    }

    /// The point of `Origin`: the app must never answer "your thyroid tablet clashes with your
    /// calcium" by proposing a new time for the thyroid tablet.
    func testAPrescriptionIsNeverTheThingProposedToMove() {
        let intakes = [
            medication("Levothyroxine 100mcg", at: 7),
            intake("Calcium Citrate", at: 8),
        ]
        XCTAssertNil(SI.suggestion(movingSupplementNamed: "Levothyroxine 100mcg", among: intakes))
        let suggestions = SI.suggestions(among: intakes)
        XCTAssertTrue(suggestions.isEmpty, "moving a supplement also changes its relationship to a prescription")
    }

    func testEvenAnUnrecognizedMedicationPreventsAutomaticSupplementRescheduling() {
        let intakes = [medication("A prescription not in the table", at: 20),
                       intake("Iron", at: 8), intake("Calcium", at: 8)]
        XCTAssertTrue(SI.suggestions(among: intakes).isEmpty)
        XCTAssertFalse(SI.conflicts(among: intakes).isEmpty, "informational findings remain visible")
    }

    func testAntibioticCourseAndAMineralAreFlaggedTwoHoursApartNotFour() {
        let conflicts = SI.conflicts(among: [
            medication("Doxycycline 100mg", at: 9),
            intake("Zinc Picolinate", at: 10),
        ])
        XCTAssertEqual(conflicts.first?.rule.separation, 2 * 3600)
        XCTAssertTrue(SI.conflicts(among: [
            medication("Doxycycline 100mg", at: 9),
            intake("Zinc Picolinate", at: 12),
        ]).isEmpty, "two hours apart is the rule being followed, not a conflict")
    }
}
