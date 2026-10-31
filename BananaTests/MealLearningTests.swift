import XCTest

/// Estimates that learn (docs/design/MEAL-LEARNING.md): what the ledger reads off the meal log,
/// and what the portions learned from it do.
final class EstimateLedgerTests: XCTestCase {
    private let rice = FoodReference(id: "fndds:58163130", name: "Rice, white, cooked",
                                     per100g: .init(calories: 130, proteinGrams: 2.7, carbohydrateGrams: 28.2, fatGrams: 0.3))

    private func item(_ name: String, grams: Double, reference: FoodReference? = nil, id: UUID = UUID()) -> MealItem {
        let macros = reference?.macros(grams: grams) ?? NutritionMacros(calories: grams, proteinGrams: 0, carbohydrateGrams: 0, fatGrams: 0)
        return MealItem(id: id, name: name, serving: "\(Int(grams)) g", macros: macros, grams: grams, reference: reference)
    }

    func testEachFoodIsPairedWithWhatWasLogged() {
        let kept = item("Rice", grams: 150, reference: rice)
        let moved = item("Curry", grams: 200)
        let dropped = item("Naan", grams: 90)
        let estimate = MealEstimate(estimator: 3, from: .photo, foods: [
            EstimatedFood(kept, amount: .guess), EstimatedFood(moved, amount: .guess), EstimatedFood(dropped, amount: .guess),
        ])
        let added = item("Lassi", grams: 250)
        let meal = MealEntry(items: [kept, moved.withGrams(300), added], estimate: estimate)

        let rows = EstimateLedger.rows([meal])
        let outcomes = Dictionary(uniqueKeysWithValues: rows.map { ($0.estimated?.name ?? $0.logged!.name, $0.outcome) })
        XCTAssertEqual(outcomes["Rice"], .accepted)
        XCTAssertEqual(outcomes["Curry"], .edited)
        XCTAssertEqual(outcomes["Naan"], .removed)
        XCTAssertEqual(outcomes["Lassi"], .added)
        XCTAssertEqual(rows.filter(\.teaches).count, 1, "only what was changed teaches")
    }

    func testAScannedPackageIsAScanNotAnEdit() {
        let guess = item("Gnocchi", grams: 200)
        let mine = FoodReference(id: MyFoods.referencePrefix + UUID().uuidString, name: "Pumpkin gnocchi",
                                 per100g: .init(calories: 160, proteinGrams: 4, carbohydrateGrams: 33, fatGrams: 1))
        let scanned = MealItem(id: guess.id, name: "Pumpkin gnocchi", serving: "1 serving", macros: mine.macros(grams: 140),
                               grams: 140, reference: mine)
        let meal = MealEntry(items: [scanned], estimate: MealEstimate(estimator: 3, from: .photo,
                                                                       foods: [EstimatedFood(guess, amount: .guess)]))
        XCTAssertEqual(EstimateLedger.rows([meal]).first?.outcome, .scanned)
    }

    func testAMealWithoutAnEstimateTeachesNothing() {
        XCTAssertTrue(EstimateLedger.rows([MealEntry(items: [item("Toast", grams: 40)])]).isEmpty)
    }

    func testTheRatioIsAgainstTheModelsOwnGuessEvenAfterAFactor() {
        let proposed = item("Rice", grams: 195, reference: rice)
        let meal = MealEntry(items: [proposed.withGrams(260)], estimate: MealEstimate(estimator: 3, from: .photo, foods: [
            EstimatedFood(proposed, amount: .learned, factor: 1.3),
        ]))
        let row = EstimateLedger.rows([meal])[0]
        XCTAssertEqual(row.guessedGrams ?? 0, 150, accuracy: 0.01)
        XCTAssertEqual(row.guessRatio ?? 0, 260.0 / 150, accuracy: 0.001)
    }

    func testAnAmountTheyGaveIsNeverAGuess() {
        let said = item("Rice", grams: 158, reference: rice)
        let meal = MealEntry(items: [said.withGrams(200)], estimate: MealEstimate(estimator: 3, from: .words, foods: [
            EstimatedFood(said, amount: .words),
        ]))
        XCTAssertNil(EstimateLedger.rows([meal])[0].guessRatio)
    }

    func testTheSummarySaysWhichWayEstimatesRan() {
        let meals = (0..<6).map { day -> MealEntry in
            let proposed = item("Rice", grams: 100, reference: rice)
            return MealEntry(date: Date(timeIntervalSince1970: Double(day) * 86_400), items: [proposed.withGrams(125)],
                             estimate: MealEstimate(estimator: 3, from: .photo, foods: [EstimatedFood(proposed, amount: .guess)]))
        }
        let summary = EstimateLedger.summary(EstimateLedger.rows(meals))
        XCTAssertEqual(summary.meals, 6)
        XCTAssertEqual(summary.changedMeals, 6)
        XCTAssertEqual(summary.medianChange ?? 0, 0.2, accuracy: 0.001)
        XCTAssertLessThan(summary.medianBias ?? 0, 0, "they ate more than it said: estimates ran low")
        let line = EstimateLedger.line(summary) ?? ""
        XCTAssertTrue(line.contains("ran 20% low"), line)
    }

    func testAnEstimateFromANewerBuildStillDecodes() throws {
        let json = #"{"from":"somethingNew","foods":[{"itemID":"\#(UUID().uuidString)","amount":"later","calories":120}],"extra":1}"#
        let decoded = try JSONDecoder().decode(MealEstimate.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.from, .words)
        XCTAssertEqual(decoded.foods.first?.amount, .guess)
        let meal = try JSONDecoder().decode(MealEntry.self, from: Data(#"{"items":[{"name":"Toast"}]}"#.utf8))
        XCTAssertNil(meal.estimate)
    }
}

final class LearnedPortionsTests: XCTestCase {
    private func row(_ name: String, guess: Double, logged: Double, reference: String? = nil, day: Int,
                     outcome: EstimateLedger.Outcome = .edited) -> EstimateLedger.Row {
        let id = UUID()
        let estimated = EstimatedFood(itemID: id, name: name, grams: guess, calories: guess, referenceID: reference, amount: .guess)
        let item = MealItem(id: id, name: name, serving: "", macros: .init(calories: logged), grams: logged)
        return EstimateLedger.Row(mealID: UUID(), date: Date(timeIntervalSince1970: Double(day) * 86_400), from: .photo,
                                  estimator: 3, measured: false, estimated: estimated, logged: item, outcome: outcome)
    }

    func testAFoodNeedsThreeCorrectionsBeforeItsFactorIsUsed() {
        let two = [row("Rice", guess: 100, logged: 130, day: 1), row("Rice", guess: 100, logged: 130, day: 2)]
        XCTAssertNil(LearnedPortions.book(two, category: { _ in nil }).factor(name: "rice", referenceID: nil, category: nil))
        let three = two + [row("Rice", guess: 100, logged: 140, day: 3)]
        let factor = LearnedPortions.book(three, category: { _ in nil }).factor(name: "rice", referenceID: nil, category: nil)
        XCTAssertEqual(factor?.ratio ?? 0, 1.3, accuracy: 0.001)
        XCTAssertEqual(factor?.samples, 3)
    }

    func testOnlyWhatWasChangedTeaches() {
        let accepted = (1...5).map { row("Rice", guess: 100, logged: 100, day: $0, outcome: .accepted) }
        XCTAssertTrue(LearnedPortions.book(accepted, category: { _ in nil }).isEmpty)
    }

    func testAWildCorrectionIsADifferentPortionNotAHabit() {
        let rows = [row("Rice", guess: 100, logged: 130, day: 1), row("Rice", guess: 100, logged: 130, day: 2),
                    row("Rice", guess: 100, logged: 400, day: 3)]
        XCTAssertNil(LearnedPortions.book(rows, category: { _ in nil }).factor(name: "Rice", referenceID: nil, category: nil),
                     "×4 is left out, leaving two")
    }

    func testAFactorNearOneIsLeftAlone() {
        let rows = (1...4).map { row("Rice", guess: 100, logged: 105, day: $0) }
        XCTAssertTrue(LearnedPortions.book(rows, category: { _ in nil }).isEmpty)
    }

    func testTheSameDatabaseFoodBeatsTheNameAndACategoryNeedsMore() {
        var rows = (1...3).map { row("White rice", guess: 100, logged: 150, reference: "sr:1", day: $0) }
        rows += (4...6).map { row("Steamed rice", guess: 100, logged: 120, reference: "sr:2", day: $0) }
        let book = LearnedPortions.book(rows, category: { _ in "Rice" })
        XCTAssertEqual(book.factor(name: "anything", referenceID: "sr:1", category: "Rice")?.ratio ?? 0, 1.5, accuracy: 0.001)
        let category = book.factor(name: "Jasmine rice", referenceID: "sr:9", category: "Rice")
        XCTAssertEqual(category?.isCategory, true)
        XCTAssertEqual(category?.samples, 6)
        XCTAssertNil(LearnedPortions.book(Array(rows.prefix(4)), category: { _ in "Rice" })
            .factor(name: "Jasmine rice", referenceID: "sr:9", category: "Rice"), "four aren't enough for a category")
    }

    func testTheNewestTwentyCount() {
        let old = (1...20).map { row("Rice", guess: 100, logged: 200, day: $0) }
        let recent = (21...40).map { row("Rice", guess: 100, logged: 120, day: $0) }
        let factor = LearnedPortions.book(old + recent, category: { _ in nil }).factor(name: "Rice", referenceID: nil, category: nil)
        XCTAssertEqual(factor?.ratio ?? 0, 1.2, accuracy: 0.001, "a habit that changed is followed")
    }

    func testTheBacktestUsesOnlyWhatCameBefore() {
        let steady = (1...8).map { row("Rice", guess: 100, logged: 130, day: $0) }
        let test = LearnedPortions.backtest(steady, category: { _ in nil })
        XCTAssertEqual(test.tried, 5, "the first three teach; the rest are tried")
        XCTAssertEqual(test.errorAfter ?? 1, 0, accuracy: 0.001)
        XCTAssertTrue(test.keepsFactors)

        // Three meals taught ×1.3, then the habit flipped: the old factor makes five of them worse.
        let flipped = [130.0, 130, 130, 70, 70, 70, 70, 70, 70]
        let noise = flipped.enumerated().map { row("Rice", guess: 100, logged: $1, day: $0) }
        XCTAssertFalse(LearnedPortions.backtest(noise, category: { _ in nil }).keepsFactors,
                       "a factor that makes it worse is turned off")
    }
}

final class LearnedResolveTests: XCTestCase {
    private let rice = FoodMatch(reference: FoodReference(id: "sr:1", name: "Rice, white, cooked",
                                                          per100g: .init(calories: 130, proteinGrams: 2.7, carbohydrateGrams: 28.2, fatGrams: 0.3)),
                                 category: "Rice", portions: [FoodPortion(label: "1 cup", grams: 158)])

    private func part(_ portion: String, grams: Double, amount: EstimatedFood.Amount? = nil) -> GroundedFoodEstimate.ModelPart {
        GroundedFoodEstimate.ModelPart(name: "rice", foodID: "sr:1", grams: grams, portion: portion,
                                       ownEstimate: .init(), confidence: 1, amount: amount)
    }

    func testAGuessIsScaledByWhatWasLearned() {
        let resolved = GroundedFoodEstimate.resolved([part("", grams: 150)], lookup: { _ in self.rice },
                                                      portionFactor: { _, _ in 1.3 })
        XCTAssertEqual(resolved[0].item.grams ?? 0, 195, accuracy: 0.01)
        XCTAssertEqual(resolved[0].amount, .learned)
        XCTAssertEqual(resolved[0].factor, 1.3)
    }

    func testAnAmountTheySaidIsNeverScaled() {
        let parts = GroundedFoodEstimate.markingSaidAmounts([part("1 cup", grams: 150)], note: "1 cup rice and dal")
        let resolved = GroundedFoodEstimate.resolved(parts, lookup: { _ in self.rice }, portionFactor: { _, _ in 1.3 })
        XCTAssertEqual(resolved[0].item.grams ?? 0, 158, accuracy: 0.01)
        XCTAssertEqual(resolved[0].amount, .words)
    }

    func testAPortionTheModelMadeUpIsStillAGuess() {
        let parts = GroundedFoodEstimate.markingSaidAmounts([part("1 cup", grams: 150)], note: "rice and dal")
        XCTAssertNil(parts[0].amount)
    }

    func testTheEstimateKeepsWhereEachAmountCameFrom() {
        let resolved = GroundedFoodEstimate.resolved([part("1 bowl", grams: 150)], lookup: { _ in self.rice },
                                                      portionFactor: { _, _ in 1.3 })
        let estimate = GroundedFoodEstimate.estimate(resolved, from: .photo, measured: true)
        XCTAssertEqual(estimate.foods.first?.itemID, resolved[0].item.id)
        XCTAssertEqual(estimate.foods.first?.amount, .learned)
        XCTAssertEqual(estimate.estimator, GroundedFoodEstimate.version)
        XCTAssertTrue(estimate.measured)
    }
}

final class UsualFoodsTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/New_York")!; return c }

    private func meal(day: Int, hour: Int, _ names: [(String, Double)]) -> MealEntry {
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour))!
        return MealEntry(date: date, items: names.map { MealItem(name: $0.0, serving: "", macros: .init(calories: $0.1), grams: $0.1) })
    }

    func testWhatYouHaveAroundNowComesFirst() {
        let meals = [meal(day: 20, hour: 8, [("Oatmeal", 250), ("Coffee", 240)]),
                     meal(day: 21, hour: 8, [("Oatmeal", 260), ("Coffee", 240)]),
                     meal(day: 22, hour: 8, [("Oatmeal", 250)]),
                     meal(day: 20, hour: 19, [("Pasta", 300)]), meal(day: 21, hour: 19, [("Pasta", 320)]),
                     meal(day: 22, hour: 19, [("Pasta", 300)]), meal(day: 23, hour: 19, [("Pasta", 300)])]
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 8, minute: 30))!
        let morning = UsualFoods.foods(at: now, meals: meals, now: now, calendar: calendar).map(\.name)
        XCTAssertEqual(morning, ["Oatmeal", "Coffee"], "pasta is an evening thing")
        let evening = calendar.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 19, minute: 15))!
        XCTAssertEqual(UsualFoods.foods(at: evening, meals: meals, now: now, calendar: calendar).first?.name, "Pasta")
    }

    func testOnceIsAMealNotAHabit() {
        let meals = [meal(day: 20, hour: 8, [("Croissant", 60)])]
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 8))!
        XCTAssertTrue(UsualFoods.foods(at: now, meals: meals, now: now, calendar: calendar).isEmpty)
    }

    func testItComesBackAtYourUsualAmountAsANewItem() {
        let meals = [meal(day: 20, hour: 8, [("Oatmeal", 200)]), meal(day: 21, hour: 8, [("Oatmeal", 250)]),
                     meal(day: 22, hour: 8, [("Oatmeal", 250)])]
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 8))!
        let food = UsualFoods.foods(at: now, meals: meals, now: now, calendar: calendar)[0]
        XCTAssertEqual(food.usualGrams, 250)
        XCTAssertNotEqual(food.item.id, meals[2].items[0].id)
        XCTAssertEqual(food.item.grams, 250)
    }

    func testTheModelGetsYourUsualFoodsThenYourPackages() {
        let meals = [meal(day: 20, hour: 8, [("Oatmeal", 250)]), meal(day: 21, hour: 8, [("oatmeal", 250)])]
        let gnocchi = MyFood(name: "Pumpkin Gnocchi", per100g: .init(calories: 160), servingLabel: "1 cup", servingGrams: 140,
                             source: .label, uses: [.init(at: meals[0].date, grams: 140)])
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 8))!
        XCTAssertEqual(UsualFoods.names(at: now, meals: meals, myFoods: [gnocchi], now: now, calendar: calendar),
                       ["oatmeal", "Pumpkin Gnocchi"])
    }

    func testTimeOfDayWrapsPastMidnight() {
        XCTAssertEqual(UsualFoods.timeWeight(23.5 * 3_600), 1, "11:30 PM is half an hour from midnight")
        XCTAssertEqual(UsualFoods.timeWeight(5 * 3_600), 0)
        XCTAssertEqual(UsualFoods.timeWeight(2.25 * 3_600), 0.5, accuracy: 0.001)
    }
}

final class PortionQuestionTests: XCTestCase {
    private let rice = FoodReference(id: "sr:1", name: "Rice, white, cooked",
                                     per100g: .init(calories: 130, proteinGrams: 2.7, carbohydrateGrams: 28.2, fatGrams: 0.3))
    private let portions = [FoodPortion(label: "1 cup", grams: 158), FoodPortion(label: "1 oz", grams: 28)]

    private func meal(riceGrams: Double, amount: EstimatedFood.Amount = .guess, sideCalories: Double = 100) -> MealInboxItem {
        let riceItem = MealItem(name: "Rice", serving: "", macros: rice.macros(grams: riceGrams), grams: riceGrams, reference: rice)
        let side = MealItem(name: "Salad", serving: "", macros: .init(calories: sideCalories), grams: 100)
        let estimate = MealEstimate(estimator: 3, from: .photo, foods: [EstimatedFood(riceItem, amount: amount), EstimatedFood(side, amount: .guess)])
        return MealInboxItem(eatenAt: Date(), state: .proposed, origin: .scanned,
                             proposal: MealProposal(name: "Rice", items: [riceItem, side], estimate: estimate))
    }

    func testABigGuessIsAskedInItsOwnMeasure() {
        let questions = PortionQuestion.questions([meal(riceGrams: 240)], portions: { _ in self.portions })
        XCTAssertEqual(questions.count, 1, "the salad is too small a part of the meal to ask about")
        XCTAssertEqual(questions[0].name, "Rice")
        XCTAssertEqual(questions[0].choices.map(\.label), ["1 cup", "1½ cups", "2 cups"])
    }

    func testBundledRiceHasAHouseholdMeasureForItsPortionQuestion() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Foods", withExtension: "sqlite"))
        let food = try XCTUnwrap(FoodDatabase.food(id: "fndds:2708403", databaseURL: url, productsURL: nil))
        let questions = PortionQuestion.questions([meal(riceGrams: 240)], portions: { _ in food.portions })
        XCTAssertEqual(questions.first?.choices.map(\.label), ["1 cup", "1½ cups", "2 cups"])
    }

    func testWhatTheySaidOrUsuallyHaveIsNeverAsked() {
        XCTAssertTrue(PortionQuestion.questions([meal(riceGrams: 240, amount: .words)], portions: { _ in self.portions }).isEmpty)
        XCTAssertTrue(PortionQuestion.questions([meal(riceGrams: 240, amount: .usual)], portions: { _ in self.portions }).isEmpty)
    }

    func testSomethingThatComesWholeIsAskedInWholeOnesNotCups() {
        let cucumber = [FoodPortion(label: "1 piece/slice", grams: 10), FoodPortion(label: "1 regular", grams: 200),
                        FoodPortion(label: "1 miniature", grams: 65), FoodPortion(label: "1 cup", grams: 120),
                        FoodPortion(label: "typical portion", grams: 60)]
        let labels = PortionQuestion.choices(grams: 60, portions: cucumber)?.map(\.label)
        XCTAssertEqual(labels, ["\u{00BE} miniature", "1 miniature", "1\u{00BD} miniature"])
        XCTAssertEqual(PortionQuestion.choices(grams: 400, portions: cucumber)?.map(\.label),
                       ["1\u{00BD} regular", "2 regular", "2\u{00BD} regular"])
        // Rice has no sizes: still cups.
        XCTAssertEqual(PortionQuestion.choices(grams: 240, portions: portions)?.map(\.label).contains("1\u{00BD} cups"), true)
    }

    func testAtMostTwoADay() {
        let meals = (0..<4).map { _ in meal(riceGrams: 240) }
        XCTAssertEqual(PortionQuestion.questions(meals, portions: { _ in self.portions }).count, 2)
    }

    func testWeightsAreNoMeasureToAskIn() {
        XCTAssertNil(PortionQuestion.unit("1 oz"))
        XCTAssertNil(PortionQuestion.unit("1 cubic inch"))
        XCTAssertNil(PortionQuestion.unit("typical portion"))
        XCTAssertEqual(PortionQuestion.unit("1 cup, cooked"), "cup")
        XCTAssertEqual(PortionQuestion.unit("1 medium"), "medium")
        XCTAssertEqual(PortionQuestion.label(0.5, unit: "cup"), "½ cup")
        XCTAssertEqual(PortionQuestion.label(2, unit: "medium"), "2 medium")
    }

    func testAnAnswerTeachesEvenWhenItAgrees() {
        let item = meal(riceGrams: 240)
        var estimate = item.proposal!.estimate!
        estimate.confirmed = [item.proposal!.items[0].id]
        let logged = MealEntry(items: item.proposal!.items, estimate: estimate)
        let row = EstimateLedger.rows([logged]).first { $0.estimated?.name == "Rice" }
        XCTAssertEqual(row?.outcome, .answered)
        XCTAssertEqual(row?.teaches, true)
    }
}

final class PerGramCorrectionTests: XCTestCase {
    private func part(_ portion: String, grams: Double, amount: EstimatedFood.Amount? = nil) -> GroundedFoodEstimate.ModelPart {
        GroundedFoodEstimate.ModelPart(name: "rice", foodID: "", grams: grams, portion: portion,
                                       ownEstimate: .init(), confidence: 1, amount: amount)
    }

    func testACorrectedFoodScalesWithTheAmountTheySaid() {
        let fix = FoodCorrection(macros: .init(calories: 260), serving: "1 bowl", observedCount: 2, grams: 200)
        let usual = GroundedFoodEstimate.resolved([part("1 bowl", grams: 230)], learned: { _ in fix })[0]
        XCTAssertEqual(usual.item.macros.calories, 260, accuracy: 0.01, "a guess near their usual is their usual")
        XCTAssertEqual(usual.amount, .usual)
        let said = GroundedFoodEstimate.resolved([part("2 bowls", grams: 400, amount: .words)], learned: { _ in fix })[0]
        XCTAssertEqual(said.item.macros.calories, 520, accuracy: 0.01)
        XCTAssertEqual(said.amount, .words)
    }

    func testACorrectionFromBeforeWeightsStaysFixed() {
        let fix = FoodCorrection(macros: .init(calories: 260), serving: "1 bowl", observedCount: 2)
        let item = GroundedFoodEstimate.resolved([part("2 bowls", grams: 400, amount: .words)], learned: { _ in fix })[0].item
        XCTAssertEqual(item.macros.calories, 260)
    }

    func testABiggerBowlOfTheSameRiceRepeatsTheCorrection() {
        var book: [String: FoodCorrection] = [:]
        FoodCorrectionBook.recordEdit(name: "Rice", macros: .init(calories: 260), serving: "1 bowl", grams: 200, into: &book)
        FoodCorrectionBook.recordEdit(name: "Rice", macros: .init(calories: 390), serving: "1 big bowl", grams: 300, into: &book)
        XCTAssertEqual(book["rice"]?.observedCount, 2, "same calories per gram")
        XCTAssertEqual(book["rice"]?.grams, 300)
    }
}

final class EstimatorBenchTests: XCTestCase {
    func testTheScoreIsTheMiddleAndSaysWhichWay() {
        let cases = [
            EstimatorBench.Case(id: "a", predictedCalories: 80, trueCalories: 100, predictedGrams: 90, trueGrams: 100),
            EstimatorBench.Case(id: "b", predictedCalories: 300, trueCalories: 400, predictedGrams: 150, trueGrams: 200),
            EstimatorBench.Case(id: "c", predictedCalories: 220, trueCalories: 200),
            EstimatorBench.Case(id: "d", predictedCalories: -1, trueCalories: 0),
        ]
        let score = EstimatorBench.score(cases)
        XCTAssertEqual(score.cases, 3, "a case that crashed isn't scored")
        XCTAssertEqual(score.calorieError ?? 0, 0.2, accuracy: 0.001)
        XCTAssertEqual(score.calorieBias ?? 0, -0.2, accuracy: 0.001)
        XCTAssertEqual(score.gramsError ?? 0, 0.175, accuracy: 0.001)
        XCTAssertEqual(EstimatorBench.line("Nutrition5k", score, estimator: 3),
                       "Nutrition5k, estimator 3: 3 meals, calories 20% off in the middle, 20% low; weight 18% off.")
    }
}
