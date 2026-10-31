import Foundation

/// `--photo-repeat-probe`: how the photos of meals already logged compare on a real device — for
/// each of the last 40 logged meals with photos, the logged meal nearest it, the distance, and
/// whether a new photo like it would be proposed as that meal — written to playback.log
/// ("🔬 repeat"). For checking `RepeatPhotoMeal.threshold` on more photos than the replay that
/// set it had. Changes nothing but the prints, which matching would make anyway.
@MainActor
enum MealPhotoRepeatProbe {
    /// How many of the latest logged meals are looked up.
    static let latest = 40

    static func runIfRequested(wellness: WellnessStore) {
        guard ProcessInfo.processInfo.arguments.contains("--photo-repeat-probe") else { return }
        Task { await run(wellness: wellness) }
    }

    private static func log(_ text: String) { PlaybackDiagnostics.shared.log("🔬 repeat", text) }

    private static func label(_ meal: MealEntry) -> String {
        let name = meal.name.isEmpty ? GroundedFoodEstimate.mealName("", items: meal.items) : meal.name
        return "\(meal.date.formatted(.dateTime.weekday(.abbreviated).month().day().hour().minute())) \"\(name.prefix(40))\""
    }

    private static func run(wellness: WellnessStore) async {
        try? await Task.sleep(for: .seconds(8))   // after launch has settled
        // Every logged meal with photos, however old: the more pairs, the better the threshold.
        let logged = wellness.meals.filter { !$0.items.isEmpty && !$0.photoIDs.isEmpty }.sorted { $0.date > $1.date }
        let ids = logged.flatMap(\.photoIDs)
        let files = Dictionary(ids.map { ($0, MealPhotoStore.shared.url($0)) }, uniquingKeysWith: { first, _ in first })
        let started = Date()
        let prints = await MealPhotoPrints.shared.prints(files)
        log("\(logged.count) logged meals with photos; "
            + "\(prints.count) of \(files.count) photos printed in \(String(format: "%.1f", Date().timeIntervalSince(started)))s; "
            + "threshold \(RepeatPhotoMeal.threshold), ratio \(RepeatPhotoMeal.ratio)")
        // Only meals with every photo printed are compared, as in matching.
        let candidates = logged
            .map { (meal: $0, prints: $0.photoIDs.compactMap { prints[$0] }) }
            .filter { $0.prints.count == $0.meal.photoIDs.count }
        var nearestSame: [Float] = [], nearestDifferent: [Float] = []
        for (meal, own) in candidates.prefix(latest) {
            let others = candidates.filter { $0.meal.id != meal.id }
            guard let near = RepeatPhotoMeal.nearest(own, among: others) else { continue }
            let same = RepeatPhotoMeal.sameMeal(meal, near.meal)
            if same { nearestSame.append(near.distance) } else { nearestDifferent.append(near.distance) }
            // As if its photos were new on the day it was eaten.
            let would = RepeatPhotoMeal.match(own, candidates: others, now: meal.date)
            log("\(label(meal)) (\(own.count) photo\(own.count == 1 ? "" : "s")) → \(label(near.meal)) "
                + "\(String(format: "%.3f", near.distance)), \(same ? "same meal" : "different meal"); next different "
                + (near.nextDifferent.map { String(format: "%.3f", $0) } ?? "none")
                + "; would propose: \(would == nil ? "no" : "yes")")
        }
        func spread(_ values: [Float]) -> String {
            let sorted = values.sorted()
            guard let low = sorted.first, let high = sorted.last else { return "none" }
            return "\(sorted.count), \(String(format: "%.3f", low))–\(String(format: "%.3f", high)), median \(String(format: "%.3f", sorted[sorted.count / 2]))"
        }
        log("nearest is the same meal: \(spread(nearestSame)); nearest is a different meal: \(spread(nearestDifferent))")
        log("done")
    }
}
