import Combine
import Foundation

/// Where a guided workout is: which exercise, which set, resting or working, and when the
/// current timed phase ends.
///
/// This used to be `@State` on the coach screen, counting down one `Task.sleep` at a time. Two
/// things broke that. The iOS tree is thrown away a moment after the app backgrounds
/// (`AppVisibility`), so locking the phone between sets lost the whole session. And a countdown
/// that only moves while its view is on screen stops whenever the phone is locked. Here the
/// timed phases are deadlines on the wall clock, so time spent away still counts, and `tick`
/// catches up on whatever finished meanwhile.
struct GuidedSession: Codable, Equatable {
    enum Outcome: Equatable { case running, finished }

    let planID: UUID
    let startedAt: Date
    var index = 0
    var setNumber = 1
    var resting = false
    /// What comes after the rest that's running.
    var pendingIndex = 0
    var pendingSet = 1
    var completed: [String] = []
    /// When the running timed phase (a rest, or a timed exercise) ends. nil for rep-based work,
    /// which waits for "Complete set".
    var phaseEndsAt: Date?
    var paused = false
    /// Seconds left in a timed phase that was paused.
    var remainingWhenPaused: Int?
    /// When the last set ended — earlier than "now" if it ran out while the phone was locked.
    var finishedAt: Date?

    init(plan: WorkoutPlan, now: Date) {
        planID = plan.id
        startedAt = now
        phaseEndsAt = plan.exercises.first?.durationSeconds.map { now.addingTimeInterval(TimeInterval($0)) }
    }

    func item(in plan: WorkoutPlan) -> ExercisePrescription {
        plan.exercises[min(index, plan.exercises.count - 1)]
    }

    /// Whole seconds left in the timed phase, rounded up so "1" shows until it's really over.
    func remaining(at now: Date) -> Int {
        if let frozen = remainingWhenPaused { return frozen }
        guard let end = phaseEndsAt else { return 0 }
        return max(0, Int(end.timeIntervalSince(now).rounded(.up)))
    }

    /// "Complete set", or a timed exercise running out at `t`.
    @discardableResult
    mutating func completeSet(in plan: WorkoutPlan, at t: Date) -> Outcome {
        let item = item(in: plan)
        if setNumber < item.sets {
            pendingIndex = index
            pendingSet = setNumber + 1
        } else {
            if !completed.contains(item.exerciseID) { completed.append(item.exerciseID) }
            guard index + 1 < plan.exercises.count else {
                phaseEndsAt = nil
                finishedAt = t
                return .finished
            }
            pendingIndex = index + 1
            pendingSet = 1
        }
        resting = true
        phaseEndsAt = t.addingTimeInterval(TimeInterval(item.restSeconds))
        freezeIfPaused(at: t)
        return .running
    }

    /// A phase started while paused starts paused: its full length waits for Resume.
    private mutating func freezeIfPaused(at t: Date) {
        guard paused else { return }
        remainingWhenPaused = phaseEndsAt.map { max(0, Int($0.timeIntervalSince(t).rounded(.up))) }
        phaseEndsAt = nil
    }

    /// "Skip rest", or the rest running out at `t`. A timed exercise starts at once.
    mutating func endRest(in plan: WorkoutPlan, at t: Date) {
        index = min(pendingIndex, plan.exercises.count - 1)
        setNumber = pendingSet
        resting = false
        phaseEndsAt = plan.exercises[index].durationSeconds.map { t.addingTimeInterval(TimeInterval($0)) }
        freezeIfPaused(at: t)
    }

    mutating func togglePause(at now: Date) {
        if paused {
            if let left = remainingWhenPaused { phaseEndsAt = now.addingTimeInterval(TimeInterval(left)) }
            remainingWhenPaused = nil
            paused = false
        } else {
            if phaseEndsAt != nil {
                remainingWhenPaused = remaining(at: now)
                phaseEndsAt = nil
            }
            paused = true
        }
    }

    /// Applies every timed phase that ended by `now`, each starting the next at the moment the
    /// last one ended — so ten minutes away plays out as the workout would have, not as one
    /// late step. Stops at a rep-based exercise, a pause, or the end of the workout.
    mutating func tick(in plan: WorkoutPlan, now: Date) -> Outcome {
        var guardSteps = plan.exercises.reduce(0) { $0 + $1.sets } * 2 + 2
        while !paused, let end = phaseEndsAt, end <= now, guardSteps > 0 {
            guardSteps -= 1
            if resting {
                endRest(in: plan, at: end)
            } else if completeSet(in: plan, at: end) == .finished {
                return .finished
            }
        }
        return .running
    }
}

/// The one guided workout in progress, kept outside the view tree and on disk so neither the
/// background blank nor iOS reclaiming the app ends it.
@MainActor
final class GuidedSessionStore: ObservableObject {
    static let shared = GuidedSessionStore()
    static let defaultsKey = "guidedSession"
    /// A session untouched for longer than this was abandoned, not paused.
    static let abandonAfter: TimeInterval = 6 * 60 * 60

    @Published private(set) var session: GuidedSession? {
        didSet { if session != oldValue { save() } }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, now: Date = Date()) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode(GuidedSession.self, from: data),
           now.timeIntervalSince(saved.startedAt) < Self.abandonAfter {
            session = saved
        }
    }

    /// The running session for `plan`, starting one if there's none (or one for another plan).
    @discardableResult
    func begin(_ plan: WorkoutPlan, now: Date = Date()) -> GuidedSession {
        if let session, session.planID == plan.id { return session }
        let fresh = GuidedSession(plan: plan, now: now)
        session = fresh
        return fresh
    }

    func session(for planID: UUID) -> GuidedSession? {
        session?.planID == planID ? session : nil
    }

    func update(_ change: (inout GuidedSession) -> Void) {
        guard var s = session else { return }
        change(&s)
        session = s
    }

    func end() { session = nil }

    private func save() {
        if let session, let data = try? JSONEncoder().encode(session) {
            defaults.set(data, forKey: Self.defaultsKey)
        } else {
            defaults.removeObject(forKey: Self.defaultsKey)
        }
    }
}
