import Foundation

/// Which copy of a workout to believe, when several apps wrote the same session to Apple Health.
///
/// Apple Health is a shared inbox: the recorder writes the workout, and then WHOOP, Strava and
/// others each write their own copy of it back. On 26 Sep 2026 about 30% of the records Banana
/// imported were such copies. `WorkoutEntry.merge` collapses them into one row; this decides
/// which record that row shows, so its distance and heart rate come from the device that
/// actually measured them rather than from whichever copy happened to arrive first (often
/// WHOOP's, which carries no distance).
enum WorkoutSourcePreference {
    /// Higher is better. Recorders first, then apps that import and re-export.
    static func rank(_ workout: HealthWorkout, ownBundleID: String?) -> Int {
        if let ownBundleID, workout.sourceBundleID == ownBundleID { return 100 }
        let source = workout.source.lowercased()
        if source == "banana" { return 95 }
        if source.contains("apple watch") || source.contains("apple\u{00A0}watch") { return 90 }
        if source.contains("workoutdoors") { return 80 }
        if source.contains("nike") || source.contains("slopes") || source.contains("daypart") { return 70 }
        if source.contains("strava") { return 40 }
        if source.contains("whoop") { return 20 }
        return 50
    }

    /// Completeness breaks ties within a rank: distance, then heart rate, then energy.
    static func completeness(_ workout: HealthWorkout) -> Int {
        ((workout.distanceMeters ?? 0) > 0 ? 4 : 0)
            + (workout.avgHeartRate != nil ? 2 : 0)
            + ((workout.energyKcal ?? 0) > 0 ? 1 : 0)
    }

    static func prefers(_ a: HealthWorkout, over b: HealthWorkout, ownBundleID: String?) -> Bool {
        let ra = rank(a, ownBundleID: ownBundleID), rb = rank(b, ownBundleID: ownBundleID)
        if ra != rb { return ra > rb }
        let ca = completeness(a), cb = completeness(b)
        if ca != cb { return ca > cb }
        return a.id.uuidString < b.id.uuidString   // stable, so every device picks the same one
    }
}

/// Banana's own duplicate saves: the same session written to Apple Health more than once. These
/// are the only duplicates Banana may delete — HealthKit lets an app delete only what it wrote.
enum OwnWorkoutDuplicates {
    struct Group: Equatable {
        let keep: HealthWorkout
        let remove: [HealthWorkout]
    }

    /// Copies of one session start and end together: Banana writes the session's own start and
    /// end, so two saves of it agree to the second.
    static let tolerance: TimeInterval = 2

    static func groups(in workouts: [HealthWorkout], ownBundleID: String) -> [Group] {
        let own = workouts.filter { $0.sourceBundleID == ownBundleID }
            .sorted { $0.start < $1.start }
        var result: [Group] = []
        var used = Set<UUID>()
        for (index, workout) in own.enumerated() where !used.contains(workout.id) {
            var copies = [workout]
            for other in own[(index + 1)...] {
                if other.start.timeIntervalSince(workout.start) > tolerance { break }
                guard !used.contains(other.id),
                      abs(other.end.timeIntervalSince(workout.end)) <= tolerance,
                      other.activity == workout.activity else { continue }
                copies.append(other)
            }
            guard copies.count > 1 else { continue }
            copies.forEach { used.insert($0.id) }
            let keep = copies.max { !WorkoutSourcePreference.prefers($0, over: $1, ownBundleID: ownBundleID) }!
            result.append(Group(keep: keep, remove: copies.filter { $0.id != keep.id }))
        }
        return result
    }
}

/// Swims recorded with the wrong pool length.
///
/// The Watch uses the phone's pool-length setting, which defaulted to 50 m until it was changed.
/// Distance is lengths × pool length, so a 25-yard swim recorded as 50 m reads 2.19× too far and
/// correspondingly too fast. Lap *count* and lap times were measured and stay as they are.
enum PoolLengthCorrection {
    static let twentyFiveYards = 22.86

    struct Candidate: Identifiable, Equatable {
        let id: UUID
        let start: Date
        /// Nil for swims from builds that did not store the pool length.
        let recordedLength: Double?
        let lapCount: Int
        let medianLap: TimeInterval?
        let distance: Double
        /// Distance if the pool was 25 yd.
        let correctedDistance: Double
    }

    static func isPoolSwim(_ activity: String) -> Bool {
        let a = activity.lowercased()
        return a.contains("pool") || a == "swimming"
    }

    /// Pool swims recorded at 50 m, plus older pool swims with no stored length whose distance
    /// is a whole number of 50 m lengths (what the 50 m default produced).
    static func candidates(_ summaries: [FitnessSessionSummary]) -> [Candidate] {
        summaries.compactMap { summary in
            guard isPoolSwim(summary.activity), let distance = summary.totalDistance, distance > 0 else { return nil }
            let recorded = summary.poolLengthMeters
            if let recorded {
                guard abs(recorded - 50) < 0.01 else { return nil }
            } else {
                let lengths = distance / 50
                guard abs(lengths - lengths.rounded()) < 0.01 else { return nil }
            }
            let laps = summary.laps.map(\.duration).sorted()
            return Candidate(
                id: summary.id, start: summary.start, recordedLength: recorded,
                lapCount: laps.count, medianLap: laps.isEmpty ? nil : laps[laps.count / 2],
                distance: distance,
                correctedDistance: distance * twentyFiveYards / 50)
        }
        .sorted { $0.start < $1.start }
    }

    /// The same swim re-measured in a `newLength` pool: every distance scales, laps stay.
    static func corrected(_ session: FitnessSession, from oldLength: Double = 50,
                          to newLength: Double = twentyFiveYards) -> FitnessSession {
        let factor = newLength / oldLength
        var fixed = session
        fixed.poolLengthMeters = newLength
        fixed.totalDistance = session.totalDistance.map { $0 * factor }
        fixed.samples = session.samples.map { sample in
            guard sample.kind == .distance else { return sample }
            var scaled = sample
            scaled.v1 = sample.v1 * factor
            return scaled
        }
        return fixed
    }
}

/// Laps that survive a trim: those that lie wholly inside the kept window, renumbered from 1.
/// Lap times are cumulative from the session start (the Watch records them back to back).
enum TrimmedLaps {
    static func kept(_ laps: [FitnessLap], startOffset: TimeInterval, endOffset: TimeInterval) -> [FitnessLap] {
        var elapsed: TimeInterval = 0
        var result: [FitnessLap] = []
        for lap in laps {
            let lapStart = elapsed
            elapsed += lap.duration
            guard lapStart >= startOffset - 1, elapsed <= endOffset + 1 else { continue }
            result.append(FitnessLap(number: result.count + 1, duration: lap.duration))
        }
        return result
    }
}
