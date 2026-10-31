import CoreGraphics
import Foundation
import ImageIO
#if os(iOS)
import UIKit
#endif

/// Running the bench on a device (`EstimatorBench`, `--estimator-bench`).
extension EstimatorBench {
    struct Dish: Decodable {
        var id: String
        var image: String
        var calories: Double
        var grams: Double
    }

    private struct Manifest: Decodable { var dishes: [Dish] }

    // MARK: - Running it

    private static let startedKey = "estimatorBench.started"

    @MainActor
    static func runIfRequested(wellness: WellnessStore) {
        guard ProcessInfo.processInfo.arguments.contains("--estimator-bench") else { return }
        Task { await run(wellness: wellness) }
    }

    private static func log(_ text: String) { PlaybackDiagnostics.shared.log("🔬 bench", text) }

    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("bench")
    }

    @MainActor
    private static func run(wellness: WellnessStore) async {
        try? await Task.sleep(for: .seconds(8))   // after launch has settled
        #if os(iOS)
        // The model runs only while Banana is in front, and a locked screen sends it to the
        // background: keep the screen on until the bench is done. Locking it by hand still stops
        // it — the next launch with the argument carries on from the last finished case.
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        #endif
        log("availability \(Intelligence.current)")
        reportLearning(wellness.meals)

        // A case that took the app down last time is skipped, not tried at every launch.
        var results = loadResults()
        if let crashed = UserDefaults.standard.string(forKey: startedKey), results[crashed] == nil {
            log("\(crashed) never finished last time (the app went down in it); skipping it")
            results[crashed] = Case(id: crashed, predictedCalories: -1, trueCalories: 0)
            save(results)
        }

        let dishes = (try? Data(contentsOf: folder.appendingPathComponent("nutrition5k/manifest.json")))
            .flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }?.dishes ?? []
        if dishes.isEmpty { log("no Nutrition5k dishes in Documents/bench (tools/bench/push.sh)") }
        for dish in dishes where results["n5k:" + dish.id] == nil {
            guard let image = image(folder.appendingPathComponent("nutrition5k/" + dish.image)) else { continue }
            let id = "n5k:" + dish.id
            let estimated = await estimate(id: id, images: [image], note: "", eatenAt: Date(), context: .init())
            guard let estimated else { continue }
            let found = Case(id: id, predictedCalories: estimated.totals.calories, trueCalories: dish.calories,
                             predictedGrams: grams(estimated.items), trueGrams: dish.grams)
            results[id] = found
            log("\(dish.id): \(Int(found.predictedCalories)) kcal vs \(Int(dish.calories)), "
                + "\(Int(found.predictedGrams ?? 0)) g vs \(Int(dish.grams)) — \(estimated.items.map(\.name).joined(separator: ", "))")
            save(results)
        }

        // Your own meals you corrected: the truth is what you logged.
        let corrected = wellness.meals
            .filter { meal in !meal.photoIDs.isEmpty && EstimateLedger.rows([meal]).contains(where: \.teaches) }
            .sorted { $0.date > $1.date }.prefix(30)
        for meal in corrected where results["mine:" + meal.id.uuidString] == nil {
            let images = meal.photoIDs.prefix(MealBacklogProcessor.maxPhotos).compactMap { MealPhotoStore.shared.image($0) }
            guard !images.isEmpty else { continue }
            let id = "mine:" + meal.id.uuidString
            let before = wellness.meals.filter { $0.date < meal.date }
            let context = GroundedFoodEstimate.Context(
                usualNames: UsualFoods.names(at: meal.date, meals: before, myFoods: MyFoodsStore.shared.foods, now: meal.date),
                portionFactor: LearnedPortions.lookup(before, category: { FoodDatabase.food(id: $0)?.category }))
            guard let estimated = await estimate(id: id, images: images, note: meal.note, eatenAt: meal.date, context: context)
            else { continue }
            let found = Case(id: id, predictedCalories: estimated.totals.calories, trueCalories: meal.totals.calories,
                             predictedGrams: grams(estimated.items), trueGrams: grams(meal.items))
            results[id] = found
            log("\(meal.date.formatted(date: .abbreviated, time: .shortened)) \(meal.name.isEmpty ? meal.note : meal.name): "
                + "\(Int(found.predictedCalories)) kcal vs \(Int(found.trueCalories)) logged")
            save(results)
        }

        let all = Array(results.values)
        log(line("Nutrition5k", score(all.filter { $0.id.hasPrefix("n5k:") })))
        log(line("Your corrected meals", score(all.filter { $0.id.hasPrefix("mine:") })))
        log("done; results in Documents/bench/\(resultsName)")
    }

    @MainActor
    private static func estimate(id: String, images: [CGImage], note: String, eatenAt: Date,
                                 context: GroundedFoodEstimate.Context) async -> MealProposal? {
        UserDefaults.standard.set(id, forKey: startedKey)
        UserDefaults.standard.synchronize()
        defer { UserDefaults.standard.removeObject(forKey: startedKey) }
        switch await GroundedFoodEstimate.meal(images: images, note: note, eatenAt: eatenAt,
                                                myFoods: MyFoodsStore.shared.foods, context: context) {
        case .proposal(let proposal):
            return proposal
        case .failed(let message, let detail):
            log("\(id): failed — \(message) \(detail)")
        case .unavailable(let message):
            log("\(id): unavailable — \(message)")
        }
        return nil
    }

    /// What the meal log has taught so far: how estimates were changed, whether the learned
    /// portions help, and what they are.
    static func reportLearning(_ meals: [MealEntry]) {
        let rows = EstimateLedger.rows(meals)
        log("ledger: \(rows.count) foods in \(Set(rows.map(\.mealID)).count) estimated meals, "
            + "\(rows.filter(\.teaches).count) changed")
        if let line = EstimateLedger.line(EstimateLedger.summary(rows)) { log(line) }
        let category: (String) -> String? = { FoodDatabase.food(id: $0)?.category }
        let test = LearnedPortions.backtest(rows, category: category)
        if let before = test.errorBefore, let after = test.errorAfter {
            log("learned portions, replayed on \(test.tried): guesses \(EstimateLedger.percent(before)) off without, "
                + "\(EstimateLedger.percent(after)) with — \(test.keepsFactors ? "kept on" : "turned off")")
        } else {
            log("learned portions: too few corrections to replay yet (\(test.tried))")
        }
        let book = LearnedPortions.book(rows, category: category)
        let factors = (Array(book.byName.values) + Array(book.byCategory.values))
            .sorted { $0.samples > $1.samples }.prefix(10)
            .map { "\($0.basis) ×\(String(format: "%.2f", $0.ratio)) (\($0.samples))" }
        log(factors.isEmpty ? "nothing learned yet" : "learned: " + factors.joined(separator: ", "))
    }

    private static func grams(_ items: [MealItem]) -> Double? {
        let weights = items.compactMap(\.grams)
        return weights.count == items.count && !weights.isEmpty ? weights.reduce(0, +) : nil
    }

    private static func image(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // MARK: - Results, kept per estimator version so a crash or a relaunch picks up where it was

    private static var resultsName: String { "results-v\(GroundedFoodEstimate.version).json" }

    private static func loadResults() -> [String: Case] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(resultsName)),
              let cases = try? JSONDecoder().decode([Case].self, from: data) else { return [:] }
        return Dictionary(cases.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private static func save(_ results: [String: Case]) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let cases = results.values.sorted { $0.id < $1.id }
        try? JSONEncoder().encode(cases).write(to: folder.appendingPathComponent(resultsName), options: .atomic)
    }
}
