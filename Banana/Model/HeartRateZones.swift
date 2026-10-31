import Foundation

/// Five heart-rate zones as shares of your maximum, and how long a workout spent in each.
///
/// The maximum comes from your own data — the highest reading across recent workouts — rather
/// than an age formula, which is off by 10–20 bpm for many people and needs a birthday Banana
/// doesn't ask for. It's floored so a run of easy weeks can't make every effort look like a
/// sprint.
enum HeartRateZones {
    /// Lower bounds as a share of max; zone 1 also takes everything below it.
    static let lowerBounds: [Double] = [0.5, 0.6, 0.7, 0.8, 0.9]
    static let names = ["Easy", "Aerobic", "Tempo", "Threshold", "Max"]
    /// The lowest max this will assume.
    static let floorMax: Double = 170

    static func estimatedMax(peaks: [Double]) -> Double {
        max(floorMax, peaks.filter { $0.isFinite && $0 < 230 }.max() ?? 0)
    }

    /// Zone index 0...4 for a reading.
    static func zone(of bpm: Double, max maxHR: Double) -> Int {
        let share = bpm / maxHR
        return lowerBounds.lastIndex(where: { share >= $0 }) ?? 0
    }

    /// The bpm range each zone covers, for labels: "134–152".
    static func ranges(max maxHR: Double) -> [(lower: Int, upper: Int?)] {
        lowerBounds.enumerated().map { index, share in
            let lower = Int((share * maxHR).rounded())
            let upper = index + 1 < lowerBounds.count ? Int((lowerBounds[index + 1] * maxHR).rounded()) - 1 : nil
            return (lower, upper)
        }
    }

    /// Seconds in each zone. Each reading counts until the next one; a gap longer than
    /// `maxGap` (the watch lost contact, a pause) counts only `maxGap`, so a dropout doesn't pile
    /// minutes onto whatever zone came before it.
    static func timeInZones(_ samples: [HRPoint], max maxHR: Double, maxGap: TimeInterval = 30) -> [TimeInterval] {
        var totals = [TimeInterval](repeating: 0, count: lowerBounds.count)
        let sorted = samples.sorted { $0.t < $1.t }
        for (current, next) in zip(sorted, sorted.dropFirst()) {
            let dt = min(maxGap, max(0, next.t - current.t))
            totals[zone(of: current.bpm, max: maxHR)] += dt
        }
        return totals
    }
}
