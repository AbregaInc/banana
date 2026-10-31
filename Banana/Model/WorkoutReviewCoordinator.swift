import Foundation
import Combine

/// One finished workout, from whichever record knew about it: the Watch-recorded summary (with
/// route, heart-rate series, splits) and/or the Apple Health copy (with max heart rate). The
/// two are matched by start time the same way FitnessView pairs them.
struct WorkoutReviewSubject: Identifiable, Equatable {
    var summary: FitnessSessionSummary?
    var health: HealthWorkout?

    var id: String { summary.map { "s-\($0.id)" } ?? health.map { "h-\($0.id)" } ?? "none" }
    var activity: String { summary?.activity ?? health?.activity ?? "Workout" }
    var start: Date { summary?.start ?? health?.start ?? .distantPast }
    var end: Date { summary?.end ?? health?.end ?? start }
    var duration: TimeInterval {
        if let summary { return summary.activeDuration }   // pauses left out
        if let health { return health.duration > 0 ? health.duration : health.end.timeIntervalSince(health.start) }
        return 0
    }
    var distanceMeters: Double? {
        if let d = summary?.totalDistance, d > 0 { return d }
        if let d = health?.distanceMeters, d > 0 { return d }
        return nil
    }
    var avgHeartRate: Double? {
        if let hr = summary?.avgHeartRate, hr > 0 { return hr }
        if let hr = health?.avgHeartRate, hr > 0 { return hr }
        return nil
    }
    var maxHeartRate: Double? {
        if let hr = health?.maxHeartRate, hr > 0 { return hr }
        if let peak = summary?.heartRateSeries.map(\.bpm).max(), peak > 0 { return peak }
        return nil
    }
    var energyKcal: Double? {
        if let e = summary?.totalEnergy, e > 0 { return e }
        if let e = health?.energyKcal, e > 0 { return e }
        return nil
    }
}

/// Shows the post-workout review the first time the app is used after a workout lands on this
/// device: once per workout, newest wins, and never for anything that was already history when
/// the feature first ran. Mirrors the morning briefing: the trigger is "you came back", the
/// screen is the payoff.
///
/// Each device keeps its own high-water mark, so the phone and the Mac each get to show the
/// review once — which is what "the first time I reopen the iOS or desktop app" asks for.
@MainActor
final class WorkoutReviewCoordinator: ObservableObject {
    static let shared = WorkoutReviewCoordinator()

    /// The workout to present. Set by `check`, cleared by the sheet's dismissal.
    @Published var pending: WorkoutReviewSubject?

    /// A workout older than this when the app comes back is history, not news.
    nonisolated static let freshness: TimeInterval = 36 * 60 * 60
    /// Two records this close in start time are one workout (the Watch summary and its
    /// HealthKit copy); same tolerance FitnessView uses when it pairs them.
    nonisolated static let matchTolerance: TimeInterval = 90

    private static let lastSeenKey = "workoutReview.lastSeenEnd"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// End time of the newest workout this device has already reviewed (or, on first run, the
    /// moment the feature started watching — so old workouts never pop up out of the blue).
    private(set) var lastSeenEnd: Date? {
        get {
            if let date = defaults.object(forKey: Self.lastSeenKey) as? Date { return date }
            let t = defaults.double(forKey: Self.lastSeenKey)
            return t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
        // NSDate persists reference-date precision. Converting to Unix seconds and back can
        // round down by a fraction of a microsecond and make the same workout look new.
        set { defaults.set(newValue, forKey: Self.lastSeenKey) }
    }

    /// Call when the app becomes active, and when a workout arrives while it already is.
    /// Returns the subject it decided to present, if any (also stored in `pending`).
    @discardableResult
    func check(summaries: [FitnessSessionSummary], healthWorkouts: [HealthWorkout],
               now: Date = Date()) -> WorkoutReviewSubject? {
        guard pending == nil else { return nil }
        guard let baseline = lastSeenEnd else {
            lastSeenEnd = now   // first run: start counting from here
            return nil
        }
        guard let newest = Self.newestWorkout(summaries: summaries, healthWorkouts: healthWorkouts,
                                              after: baseline, now: now) else { return nil }
        lastSeenEnd = newest.end
        pending = newest
        return newest
    }

    /// Pure selection so it can be reasoned about (and tested) without a store: the newest
    /// finished workout that ended after `after`, no later than `now`, and recently enough to
    /// still be news. Summaries take precedence; a Health record within `matchTolerance` of a
    /// summary is folded into it rather than counted twice.
    nonisolated static func newestWorkout(summaries: [FitnessSessionSummary], healthWorkouts: [HealthWorkout],
                                          after: Date, now: Date) -> WorkoutReviewSubject? {
        let oldest = now.addingTimeInterval(-freshness)
        // Also tolerate the rounding in watermarks saved by older versions. A sub-millisecond
        // representation difference is not a newly finished workout.
        func isNews(_ end: Date) -> Bool {
            end.timeIntervalSince(after) > 0.001 && end <= now && end >= oldest
        }

        var subjects: [WorkoutReviewSubject] = []
        for summary in summaries {
            guard let end = summary.end, isNews(end) else { continue }
            subjects.append(WorkoutReviewSubject(summary: summary, health: nil))
        }
        for workout in healthWorkouts {
            if let i = subjects.firstIndex(where: { abs($0.start.timeIntervalSince(workout.start)) < matchTolerance }) {
                if subjects[i].health == nil { subjects[i].health = workout }
                continue
            }
            // Summaries that are not news may still own this Health record — do not resurface
            // an old workout just because its Health copy arrived late.
            if summaries.contains(where: { abs($0.start.timeIntervalSince(workout.start)) < matchTolerance }) { continue }
            guard isNews(workout.end) else { continue }
            subjects.append(WorkoutReviewSubject(summary: nil, health: workout))
        }
        return subjects.max { $0.end < $1.end }
    }

    /// Earlier workouts of the same activity within `window` of `subject.start`, deduplicated the
    /// same way — the "compared with your last 90 days" baseline.
    nonisolated static func recentPeers(of subject: WorkoutReviewSubject, summaries: [FitnessSessionSummary],
                                        healthWorkouts: [HealthWorkout],
                                        window: TimeInterval = 90 * 24 * 60 * 60) -> [WorkoutReviewSubject] {
        let from = subject.start.addingTimeInterval(-window)
        let activity = subject.activity.lowercased()
        func matches(_ a: String) -> Bool { a.lowercased() == activity }

        var peers: [WorkoutReviewSubject] = []
        for summary in summaries where matches(summary.activity) {
            guard summary.start >= from, summary.start < subject.start,
                  abs(summary.start.timeIntervalSince(subject.start)) >= matchTolerance else { continue }
            peers.append(WorkoutReviewSubject(summary: summary, health: nil))
        }
        for workout in healthWorkouts where matches(workout.activity) {
            guard workout.start >= from, workout.start < subject.start,
                  abs(workout.start.timeIntervalSince(subject.start)) >= matchTolerance else { continue }
            if let i = peers.firstIndex(where: { abs($0.start.timeIntervalSince(workout.start)) < matchTolerance }) {
                if peers[i].health == nil { peers[i].health = workout }
            } else if !summaries.contains(where: { abs($0.start.timeIntervalSince(workout.start)) < matchTolerance }) {
                peers.append(WorkoutReviewSubject(summary: nil, health: workout))
            }
        }
        return peers.sorted { $0.start > $1.start }
    }

    #if DEBUG
    /// Layout-verification launches must never pop a review over the screen under test, and a
    /// fresh Simulator's dummy Health data would otherwise count as "new". Any `--flag` launch
    /// argument other than the review's own is a harness run.
    nonisolated static var isSuppressedByLaunchArguments: Bool {
        ProcessInfo.processInfo.arguments.dropFirst().contains { $0.hasPrefix("--") && $0 != "--workout-review" }
    }
    #endif
}
