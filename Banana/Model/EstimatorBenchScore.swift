import Foundation

/// `--estimator-bench`: how close the estimator gets, measured, so a change can be shown to help
/// before `GroundedFoodEstimate.version` goes up and every waiting meal is estimated again
/// (docs/design/MEAL-LEARNING.md §7). Runs on a device, where the model is; writes "🔬 bench" lines
/// to playback.log and a results file to Documents/bench. Changes nothing.
///
/// Three parts: what the meal log has taught (no model needed, so the Mac can run it too); the
/// Nutrition5k dishes copied into Documents/bench/nutrition5k (tools/bench), each a weighed plate;
/// and your own meals whose estimates you corrected, estimated again with only what was learned
/// before each. Nutrition5k is a Google cafeteria — a check for regressions, not a claim of accuracy.
enum EstimatorBench {
    struct Case: Codable, Hashable, Sendable {
        var id: String
        var predictedCalories: Double
        var trueCalories: Double
        var predictedGrams: Double?
        var trueGrams: Double?
    }

    struct Score: Equatable, Sendable {
        var cases = 0
        /// The middle of how far off the calories were, as a fraction of the truth.
        var calorieError: Double?
        /// The middle of the signed error: above zero, it said more than there was.
        var calorieBias: Double?
        var gramsError: Double?
    }

    static func score(_ cases: [Case]) -> Score {
        // A case that took the app down is kept (so it isn't tried again) at -1, and not scored.
        let counted = cases.filter { $0.trueCalories > 0 && $0.predictedCalories >= 0 }
        let errors = counted.map { ($0.predictedCalories - $0.trueCalories) / $0.trueCalories }
        let grams = counted.compactMap { c -> Double? in
            guard let predicted = c.predictedGrams, let truth = c.trueGrams, truth > 0 else { return nil }
            return abs(predicted - truth) / truth
        }
        return Score(cases: counted.count, calorieError: EstimateLedger.median(errors.map(abs)),
                     calorieBias: EstimateLedger.median(errors), gramsError: EstimateLedger.median(grams))
    }

    /// "Nutrition5k, estimator 3: 58 meals, calories 34% off in the middle, 12% low; weight 29% off."
    static func line(_ name: String, _ score: Score, estimator: Int = GroundedFoodEstimate.version) -> String {
        guard score.cases > 0, let error = score.calorieError else { return "\(name), estimator \(estimator): nothing to score" }
        var text = "\(name), estimator \(estimator): \(score.cases) meals, calories \(EstimateLedger.percent(error)) off in the middle"
        if let bias = score.calorieBias, abs(bias) >= 0.03 {
            text += ", \(EstimateLedger.percent(abs(bias))) \(bias < 0 ? "low" : "high")"
        }
        if let grams = score.gramsError { text += "; weight \(EstimateLedger.percent(grams)) off" }
        return text + "."
    }
}
