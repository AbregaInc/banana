import XCTest
#if os(iOS)
import UIKit
#endif

final class WellnessModelsTests: XCTestCase {
    func testMealTotalsClampNegativeInput() {
        let entry = MealEntry(items: [
            MealItem(name: "Meal", serving: "1 plate",
                     macros: .init(calories: 500, proteinGrams: 30,
                                   carbohydrateGrams: 55, fatGrams: 18)),
            MealItem(name: "Bad input", serving: "1",
                     macros: .init(calories: -100, proteinGrams: -4,
                                   carbohydrateGrams: -2, fatGrams: -1)),
        ])

        XCTAssertEqual(entry.totals.calories, 500)
        XCTAssertEqual(entry.totals.proteinGrams, 30)
        XCTAssertEqual(entry.totals.carbohydrateGrams, 55)
        XCTAssertEqual(entry.totals.fatGrams, 18)
    }

    func testMealTotalsRejectNonFiniteInput() {
        let entry = MealEntry(items: [
            MealItem(name: "Corrupt input", serving: "1",
                     macros: .init(calories: .nan, proteinGrams: .infinity,
                                   carbohydrateGrams: -.infinity, fatGrams: 12)),
        ])

        XCTAssertEqual(entry.totals.calories, 0)
        XCTAssertEqual(entry.totals.proteinGrams, 0)
        XCTAssertEqual(entry.totals.carbohydrateGrams, 0)
        XCTAssertEqual(entry.totals.fatGrams, 12)
    }

    // MARK: - Whole-meal aggregate confidence (natural-language food entry review summary, §2)

    private func item(_ name: String, confidence: Double?) -> MealItem {
        MealItem(name: name, serving: "1 serving", macros: .init(calories: 100), confidence: confidence)
    }

    func testMealIsConfidentWhenEveryItemIsAKnownValue() {
        XCTAssertTrue(MealEntry.isConfident([item("Egg", confidence: 1.0), item("Toast", confidence: nil)]))
    }

    func testMealIsNotConfidentWithASingleLowConfidenceItem() {
        XCTAssertFalse(MealEntry.isConfident([item("Egg", confidence: 1.0), item("Mystery soup", confidence: 0.35)]))
    }

    func testMealConfidenceBoundaryMatchesTheRowCutoff() {
        // Mirrors ResolvedFoodItem.isConfident's own >= 0.9 threshold exactly.
        XCTAssertTrue(MealEntry.isConfident([item("Egg", confidence: 0.9)]))
        XCTAssertFalse(MealEntry.isConfident([item("Egg", confidence: 0.899)]))
    }

    func testEmptyMealIsConfidentAndDoesNotCrash() {
        XCTAssertTrue(MealEntry.isConfident([]))
        XCTAssertEqual(MealEntry(items: []).totals, NutritionMacros())
    }

    // MARK: - Saved-meal editing (MealEntry.sanitizedItem / updating / applyingUpdate)

    func testSanitizedItemFillsFallbacksAndClampsOutOfRangeValues() {
        let dirty = MealItem(name: "   ", serving: "  ",
                             macros: .init(calories: -5, proteinGrams: .nan, carbohydrateGrams: 10, fatGrams: 5),
                             confidence: 5.0)

        let clean = MealEntry.sanitizedItem(dirty)

        XCTAssertEqual(clean.name, "Food")
        XCTAssertEqual(clean.serving, "1 serving")
        XCTAssertEqual(clean.macros.calories, 0)
        XCTAssertEqual(clean.macros.proteinGrams, 0)
        XCTAssertEqual(clean.confidence, 1)
    }

    func testUpdatingReplacesItemsAndNameButKeepsIdentityAndDate() {
        let originalDate = Date(timeIntervalSince1970: 1_000)
        let original = MealEntry(date: originalDate, items: [item("Egg", confidence: 1.0)], source: .text)
        let replacement = [item("Oatmeal", confidence: 1.0), item("Berries", confidence: 1.0)]

        let updated = original.updating(items: replacement, name: "Breakfast")

        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(updated.date, originalDate)
        XCTAssertEqual(updated.name, "Breakfast")
        XCTAssertEqual(updated.items.map(\.name), ["Oatmeal", "Berries"])
        XCTAssertEqual(updated.totals.calories, 200) // totals recompute from the new items
    }

    func testCorrectingMealTimeMovesDayWithoutLosingIdentityOrPhoto() throws {
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        let corrected = oldDate.addingTimeInterval(-86_400)
        let original = MealEntry(date: oldDate, items: [item("Egg", confidence: 1)],
                                 note: "Original note", source: .photo, photoIDs: [UUID()])
        let other = MealEntry(date: oldDate, items: [item("Soup", confidence: 1)])
        let meals = MealEntry.applyingUpdate(id: original.id, items: original.items,
                                             name: original.name, date: corrected, to: [original, other])
        let updated = try XCTUnwrap(meals.first { $0.id == original.id })
        var expected = original
        expected.date = corrected
        XCTAssertEqual(updated, expected)
        XCTAssertEqual(meals[1], other)
        XCTAssertTrue(NutritionDays.meals([updated], on: oldDate).isEmpty)
        XCTAssertEqual(NutritionDays.meals([updated], on: corrected).map(\.id), [original.id])
        XCTAssertEqual(try JSONDecoder().decode(MealEntry.self, from: JSONEncoder().encode(updated)), expected)
        XCTAssertEqual(MealEntry.applyingUpdate(id: UUID(), items: [], name: "", date: corrected,
                                               to: meals), meals)
    }

    func testApplyingUpdateReplacesTheMatchingMealOnly() {
        let target = MealEntry(items: [item("Egg", confidence: 1.0)])
        let other = MealEntry(items: [item("Soup", confidence: 1.0)])
        let meals = [target, other]

        let result = MealEntry.applyingUpdate(id: target.id, items: [item("Pancakes", confidence: 1.0)], name: "Brunch", to: meals)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.first { $0.id == target.id }?.items.map(\.name), ["Pancakes"])
        XCTAssertEqual(result.first { $0.id == other.id }?.items.map(\.name), ["Soup"])
    }

    func testApplyingUpdateToAMissingMealIsANoOp() {
        let meals = [MealEntry(items: [item("Egg", confidence: 1.0)])]

        let result = MealEntry.applyingUpdate(id: UUID(), items: [item("Pancakes", confidence: 1.0)], name: "Brunch", to: meals)

        XCTAssertEqual(result, meals)
    }

    // MARK: - MealEntry.name backward compatibility

    func testMealEntryDecodesAnAbsentNameAsEmpty() throws {
        // No "name" key — exactly what wellness.json looked like before meal naming shipped.
        let json = """
        {"id":"5C9C3B6E-2B1E-4C1A-8B1E-9C1A2B1E2B1E","date":0,
        "items":[{"id":"5C9C3B6E-2B1E-4C1A-8B1E-9C1A2B1E2B12","name":"Oatmeal","serving":"1 cup",
        "macros":{"calories":150,"proteinGrams":5,"carbohydrateGrams":27,"fatGrams":3}}],
        "note":"","source":"manual"}
        """
        let decoded = try JSONDecoder().decode(MealEntry.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.name, "")
        XCTAssertEqual(decoded.items.first?.name, "Oatmeal")
    }

    func testBundledBarcodeCatalogFindsUPCPaddedToGTIN() throws {
        let database = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "BarcodeProducts", withExtension: "sqlite"))
        let product = try XCTUnwrap(BarcodeProductLookup.lookup("016000125414", databaseURL: database))

        XCTAssertEqual(product.barcode, "00016000125414")
        XCTAssertTrue(product.name.localizedCaseInsensitiveContains("Cheerios"))
        XCTAssertFalse(product.name.contains("GENERAL MILLS"))
        XCTAssertEqual(product.serving, "1 1/2 cup (39 g)")
        let macros = try XCTUnwrap(product.macros, "a bundled grocery-catalog row always carries Nutrition Facts")
        XCTAssertEqual(macros.calories, 140, accuracy: 0.001)
        XCTAssertGreaterThan(macros.proteinGrams, 0)
    }

    func testBundledBarcodeCatalogReturnsNilForUnknownCode() throws {
        let database = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "BarcodeProducts", withExtension: "sqlite"))
        XCTAssertNil(try BarcodeProductLookup.lookup("99999999999999", databaseURL: database))
    }

    func testBarcodeProductRejectsInvalidCode() throws {
        XCTAssertThrowsError(try BarcodeProductLookup.normalizedBarcode("not-a-barcode"))
    }

    func testValidatorRejectsUnknownExcludedAndUnavailableExercises() {
        let preferences = WorkoutPreferences(
            focus: .strength,
            experience: .beginner,
            durationMinutes: 30,
            equipment: [.bodyweight],
            avoidExerciseIDs: ["pushup"])
        let proposed = WorkoutPlan(
            title: "  Safe plan  ", focus: .strength, targetMinutes: 999,
            exercises: [
                .init(exerciseID: "unknown", sets: 3, reps: 10, restSeconds: 60),
                .init(exerciseID: "pushup", sets: 3, reps: 10, restSeconds: 60),
                .init(exerciseID: "dumbbell-curl", sets: 3, reps: 10, restSeconds: 60),
                .init(exerciseID: "bodyweight-squat", sets: 20, reps: 100, restSeconds: 1),
            ])

        let result = WorkoutPlanValidator.validate(proposed, preferences: preferences)

        XCTAssertEqual(result?.title, "Safe plan")
        XCTAssertEqual(result?.targetMinutes, 30)
        XCTAssertEqual(result?.exercises.map(\.exerciseID), ["bodyweight-squat"])
        XCTAssertEqual(result?.exercises.first?.sets, 6)
        XCTAssertEqual(result?.exercises.first?.reps, 30)
        XCTAssertEqual(result?.exercises.first?.restSeconds, 10)
    }

    func testValidatorBoundsGeneratedText() throws {
        let preferences = WorkoutPreferences(focus: .strength)
        let proposed = WorkoutPlan(
            title: String(repeating: "T", count: 200),
            focus: .strength,
            targetMinutes: 30,
            exercises: [.init(exerciseID: "bodyweight-squat", sets: 2, reps: 10, restSeconds: 45)],
            rationale: String(repeating: "R", count: 800))

        let result = try XCTUnwrap(WorkoutPlanValidator.validate(proposed, preferences: preferences))

        XCTAssertEqual(result.title.count, 80)
        XCTAssertEqual(result.rationale.count, 500)
    }

    func testDeterministicBuilderHonorsFocusEquipmentAndAvoidList() throws {
        let preferences = WorkoutPreferences(
            focus: .mixed,
            experience: .beginner,
            durationMinutes: 35,
            equipment: [.bodyweight],
            avoidExerciseIDs: ["reverse-lunge"])

        let plan = DeterministicWorkoutBuilder.build(preferences: preferences, date: .distantPast)
        let validated = try XCTUnwrap(WorkoutPlanValidator.validate(plan, preferences: preferences))
        let definitions = try validated.exercises.map {
            try XCTUnwrap(ExerciseCatalog.exercise($0.exerciseID))
        }

        XCTAssertFalse(validated.exercises.contains { $0.exerciseID == "reverse-lunge" })
        XCTAssertTrue(definitions.contains { $0.category == .strength })
        XCTAssertTrue(definitions.contains { $0.category == .mobility })
        XCTAssertTrue(definitions.allSatisfy { $0.equipment.isSubset(of: [.bodyweight]) })
    }

    /// Every supplement already on disk was written before medications existed and before the
    /// ingredient panel was captured. Both new fields have to be additive or adding drug tracking
    /// silently drops someone's whole schedule on first launch.
    func testASupplementWrittenBeforeMedicationsExistedStillDecodes() throws {
        let legacy = """
        {"id":"44444444-4444-4444-4444-444444444444","name":"Vitamin D","dose":"1 capsule",
         "hour":8,"minute":0,"enabled":true,"note":""}
        """
        let decoded = try JSONDecoder().decode(SupplementSchedule.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.name, "Vitamin D")
        XCTAssertEqual(decoded.kind, .supplement, "anything written before the distinction was a supplement")
        XCTAssertEqual(decoded.ingredients, [])
        XCTAssertEqual(decoded.safeHour, 8)
    }

    func testMedicationAndIngredientsSurviveARoundTrip() throws {
        let original = SupplementSchedule(name: "Levothyroxine", kind: .medication, dose: "100 mcg",
                                          hour: 7, minute: 0, ingredients: ["Levothyroxine Sodium"])
        let decoded = try JSONDecoder().decode(
            SupplementSchedule.self, from: try JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    func testSupplementTimeIsClampedForScheduling() {
        let supplement = SupplementSchedule(name: "Example", dose: "1", hour: 99, minute: -3)
        XCTAssertEqual(supplement.safeHour, 23)
        XCTAssertEqual(supplement.safeMinute, 0)
    }

    func testBuilderReturnsNoExercisesWhenEveryEligibleMovementIsExcluded() {
        let allStrength = Set(ExerciseCatalog.all.filter { $0.category == .strength }.map(\.id))
        let preferences = WorkoutPreferences(
            focus: .strength,
            durationMinutes: 30,
            equipment: [.bodyweight, .dumbbells, .bench, .resistanceBand],
            avoidExerciseIDs: allStrength)

        XCTAssertTrue(DeterministicWorkoutBuilder.build(preferences: preferences).exercises.isEmpty)
    }

    // MARK: - wellness.json decode-and-quarantine (WellnessSnapshotLoader / WellnessSnapshot)
    //
    // `WellnessStore` itself pulls in `CloudBackup` → `FitnessStore` → CloudKit, and its
    // singleton would read/write the owner's real Application Support directory on first touch —
    // so these exercise `WellnessSnapshotLoader`/`WellnessSnapshot` directly, the pure decode
    // and quarantine logic `WellnessStore.decodeAndSort` delegates to, entirely against temp
    // files. Never touches the real `wellness.json`.

    private func makeTempWellnessDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WellnessSnapshotLoaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testOneMealMissingARequiredKeyStillLoadsEveryOtherMeal() throws {
        // "items" is MealEntry's one required field (see its init(from:) doc comment) — a meal
        // missing it looks exactly like a corrupt record. The other two meals, and the rest of
        // the snapshot, must still load.
        let json = """
        {"meals":[
            {"id":"11111111-1111-1111-1111-111111111111","date":0,
             "items":[{"name":"Eggs","serving":"2 large","macros":{"calories":140}}]},
            {"id":"22222222-2222-2222-2222-222222222222","date":0},
            {"id":"33333333-3333-3333-3333-333333333333","date":0,
             "items":[{"name":"Toast","serving":"1 slice","macros":{"calories":80}}]}
        ]}
        """

        let snapshot = try JSONDecoder().decode(WellnessSnapshot.self, from: Data(json.utf8))

        XCTAssertEqual(snapshot.meals.compactMap { $0.items.first?.name }, ["Eggs", "Toast"])
        XCTAssertEqual(snapshot.droppedRecordCount, 1)
    }

    func testCompletelyUnparseableFileIsQuarantinedAndLeftIntact() throws {
        let dir = try makeTempWellnessDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("wellness.json")
        let garbage = Data("not json at all { [ ".utf8)
        try garbage.write(to: url)

        let result = WellnessSnapshotLoader.load(from: url)

        guard case let .corrupt(_, quarantinedTo) = result else {
            return XCTFail("expected .corrupt, got \(result)")
        }
        let quarantineURL = try XCTUnwrap(quarantinedTo, "a writable temp dir must produce a quarantine copy")
        XCTAssertNotEqual(quarantineURL, url)
        XCTAssertEqual(try Data(contentsOf: url), garbage, "the original file must be left untouched")
        XCTAssertEqual(try Data(contentsOf: quarantineURL), garbage, "the quarantine copy must match byte-for-byte")
    }

    func testOneCorruptElementAmongSeveralLoadsTheGoodOnesAndReportsTheDroppedCount() throws {
        let dir = try makeTempWellnessDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("wellness.json")
        // The first supplement is missing "name" — SupplementSchedule's one required field.
        let json = """
        {"supplements":[
            {"id":"11111111-1111-1111-1111-111111111111","hour":8,"minute":0},
            {"id":"22222222-2222-2222-2222-222222222222","name":"Vitamin D","hour":8,"minute":0},
            {"id":"33333333-3333-3333-3333-333333333333","name":"Magnesium","hour":21,"minute":30}
        ]}
        """
        try Data(json.utf8).write(to: url)

        let result = WellnessSnapshotLoader.load(from: url)

        guard case let .loaded(snapshot) = result else {
            return XCTFail("expected .loaded, got \(result)")
        }
        XCTAssertEqual(snapshot.supplements.map(\.name).sorted(), ["Magnesium", "Vitamin D"])
        XCTAssertEqual(snapshot.droppedRecordCount, 1)
    }

    func testLoadingAMissingFileIsEmptyNotAnError() throws {
        let dir = try makeTempWellnessDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = WellnessSnapshotLoader.load(from: dir.appendingPathComponent("wellness.json"))

        guard case .empty = result else {
            return XCTFail("expected .empty for a brand-new install, got \(result)")
        }
    }

    func testRoundTrippingAnOrdinarySnapshotIsUnchanged() throws {
        var snapshot = WellnessSnapshot()
        snapshot.meals = [MealEntry(items: [item("Eggs", confidence: 1.0)], source: .text)]
        snapshot.supplements = [SupplementSchedule(name: "Vitamin D", dose: "1 capsule", hour: 8, minute: 0)]
        snapshot.supplementLogs = [.init(supplementID: snapshot.supplements[0].id, status: .taken)]
        snapshot.workoutPlans = [WorkoutPlan(title: "Strength", focus: .strength, targetMinutes: 30,
            exercises: [.init(exerciseID: "bodyweight-squat", sets: 3, reps: 10, restSeconds: 60)])]
        snapshot.workoutCompletions = [.init(planID: snapshot.workoutPlans[0].id,
            startedAt: Date(timeIntervalSince1970: 0), endedAt: Date(timeIntervalSince1970: 1_800),
            completedExerciseIDs: ["bodyweight-squat"])]
        snapshot.foodCorrections = ["egg": FoodCorrection(macros: .init(calories: 70), serving: "1 large", observedCount: 2)]

        let decoded = try JSONDecoder().decode(WellnessSnapshot.self, from: JSONEncoder().encode(snapshot))

        XCTAssertEqual(decoded.meals, snapshot.meals)
        XCTAssertEqual(decoded.supplements, snapshot.supplements)
        XCTAssertEqual(decoded.supplementLogs, snapshot.supplementLogs)
        XCTAssertEqual(decoded.workoutPlans, snapshot.workoutPlans)
        XCTAssertEqual(decoded.workoutCompletions, snapshot.workoutCompletions)
        XCTAssertEqual(decoded.foodCorrections, snapshot.foodCorrections)
        XCTAssertEqual(decoded.droppedRecordCount, 0)
    }
}
