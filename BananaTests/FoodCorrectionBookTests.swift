import XCTest

/// `FoodCorrectionBook` is the pure promotion/tolerance logic behind "the app remembers, but only
/// after the second matching correction" (see `WellnessStore.lookupLearned`/`recordEdit`, which
/// are thin wrappers around this). It's tested directly here — not through `WellnessStore` — since
/// that store's `save()` unconditionally reaches `CloudBackup.shared`, which pulls in
/// `FitnessStore`/`ListenHistoryStore`'s CloudKit-backed dependency chain; `WellnessStore.swift`
/// is deliberately not part of the BananaTests target (see project.yml's comment by this file).
final class FoodCorrectionBookTests: XCTestCase {
    private func macros(_ calories: Double) -> NutritionMacros {
        .init(calories: calories, proteinGrams: 10, carbohydrateGrams: 5, fatGrams: 2)
    }

    func testOneEditDoesNotTeachAStandingCorrection() {
        var corrections: [String: FoodCorrection] = [:]
        FoodCorrectionBook.recordEdit(name: "egg", macros: macros(150), serving: "2 large", into: &corrections)

        XCTAssertNil(FoodCorrectionBook.lookup("egg", in: corrections))
        XCTAssertEqual(corrections["egg"]?.observedCount, 1)
    }

    func testTwoMatchingEditsPromoteToLearned() {
        var corrections: [String: FoodCorrection] = [:]
        FoodCorrectionBook.recordEdit(name: "egg", macros: macros(150), serving: "2 large", into: &corrections)
        FoodCorrectionBook.recordEdit(name: "egg", macros: macros(155), serving: "2 large", into: &corrections)

        let learned = FoodCorrectionBook.lookup("egg", in: corrections)
        XCTAssertEqual(learned?.macros.calories, 155)
        XCTAssertEqual(learned?.serving, "2 large")
    }

    /// A second edit that's a real change (not just noise around the same number) starts a fresh
    /// series instead of promoting a correction that no longer reflects what he actually eats.
    func testEditOutsideToleranceResetsInsteadOfPromoting() {
        var corrections: [String: FoodCorrection] = [:]
        FoodCorrectionBook.recordEdit(name: "egg", macros: macros(150), serving: "2 large", into: &corrections)
        FoodCorrectionBook.recordEdit(name: "egg", macros: macros(600), serving: "4 large", into: &corrections)

        XCTAssertEqual(corrections["egg"]?.observedCount, 1)
        XCTAssertEqual(corrections["egg"]?.macros.calories, 600)
        XCTAssertNil(FoodCorrectionBook.lookup("egg", in: corrections))
    }

    func testLookupNormalizesCaseAndWhitespace() {
        var corrections: [String: FoodCorrection] = [:]
        FoodCorrectionBook.recordEdit(name: "  Egg ", macros: macros(150), serving: "2 large", into: &corrections)
        FoodCorrectionBook.recordEdit(name: "egg", macros: macros(150), serving: "2 large", into: &corrections)

        XCTAssertNotNil(FoodCorrectionBook.lookup("EGG", in: corrections))
    }

    func testRecordEditIgnoresAnEmptyName() {
        var corrections: [String: FoodCorrection] = [:]
        FoodCorrectionBook.recordEdit(name: "   ", macros: macros(150), serving: "1", into: &corrections)
        XCTAssertTrue(corrections.isEmpty)
    }

    // MARK: - Backward-compatible decoding

    /// Mirrors `WellnessStore.Snapshot`'s field set and its `decodeIfPresent(...) ?? [:]` pattern
    /// for `foodCorrections` — that private type itself isn't reachable from BananaTests (see this
    /// file's header comment), so this stands in for it. Keep this struct's decode logic in sync
    /// with `WellnessStore.Snapshot.init(from:)` if that pattern ever changes.
    private struct SnapshotShape: Decodable {
        var meals: [MealEntry]
        var foodCorrections: [String: FoodCorrection]

        private enum CodingKeys: String, CodingKey { case meals, foodCorrections }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            meals = try container.decodeIfPresent([MealEntry].self, forKey: .meals) ?? []
            foodCorrections = try container.decodeIfPresent([String: FoodCorrection].self, forKey: .foodCorrections) ?? [:]
        }
    }

    func testSnapshotDecodesAFileWrittenBeforeCorrectionsExisted() throws {
        // No "foodCorrections" key at all — exactly what wellness.json looked like before this
        // feature shipped.
        let oldStyleJSON = """
        {"version":1,"meals":[{"id":"5C9C3B6E-2B1E-4C1A-8B1E-9C1A2B1E2B1E","date":0,
        "items":[{"id":"5C9C3B6E-2B1E-4C1A-8B1E-9C1A2B1E2B12","name":"Oatmeal","serving":"1 cup",
        "macros":{"calories":150,"proteinGrams":5,"carbohydrateGrams":27,"fatGrams":3}}],
        "note":"","source":"manual"}],"supplements":[],"supplementLogs":[],"workoutPlans":[],
        "workoutCompletions":[]}
        """
        let decoded = try JSONDecoder().decode(SnapshotShape.self, from: Data(oldStyleJSON.utf8))

        XCTAssertEqual(decoded.meals.count, 1)
        XCTAssertEqual(decoded.meals.first?.items.first?.name, "Oatmeal")
        XCTAssertTrue(decoded.foodCorrections.isEmpty)
    }

    func testSnapshotDecodesFoodCorrectionsWhenPresent() throws {
        let json = """
        {"meals":[],"foodCorrections":{"egg":{"macros":{"calories":150,"proteinGrams":12,
        "carbohydrateGrams":1,"fatGrams":10},"serving":"2 large","observedCount":2}}}
        """
        let decoded = try JSONDecoder().decode(SnapshotShape.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.foodCorrections["egg"]?.observedCount, 2)
        XCTAssertEqual(decoded.foodCorrections["egg"]?.macros.calories, 150)
    }
}
