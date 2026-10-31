import Foundation

/// Apple Health's copy of a workout follows the workout. The phone owns Health
/// (`DeviceRole.isHub`), so it is the phone that rewrites its copy whenever the recording it
/// holds is replaced: by a trim or a revert made on it, or by one that arrived from an iPad or
/// the Mac. (A trim made there changed Banana and left Health as it was, and a revert never
/// reached Health from anywhere.)
///
/// What's still to do is kept across launches: Health can't be written while the phone is
/// locked, and an edit made on the Mac arrives whenever the phone next syncs.
@MainActor
final class WorkoutHealthFollow {
    static let shared = WorkoutHealthFollow()

    private static let key = "workoutHealthFollow.pending.v1"
    private weak var fitness: FitnessStore?
    private weak var health: HealthKitStore?
    private var settling = false
    private var askedAgain = false

    private init() {}

    func attach(fitness: FitnessStore, health: HealthKitStore) {
        guard DeviceRole.current.isHub else { return }
        self.fitness = fitness
        self.health = health
        fitness.onRecordingChanged = { [weak self] id, start, end in
            self?.note(id, was: .init(start: start, end: end))
        }
        Task { await settle() }
    }

    private var pending: [String: WorkoutEdits.Span] {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.key) else { return [:] }
            return (try? JSONDecoder().decode([String: WorkoutEdits.Span].self, from: data)) ?? [:]
        }
        set {
            if newValue.isEmpty {
                UserDefaults.standard.removeObject(forKey: Self.key)
            } else if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: Self.key)
            }
        }
    }

    private func note(_ id: UUID, was span: WorkoutEdits.Span) {
        pending = WorkoutEdits.noting(span, for: id, in: pending)
        Task { await settle() }
    }

    /// Rewrite what's waiting. Called when a recording changes, at launch, and when the app
    /// comes forward.
    func settle() async {
        guard DeviceRole.current.isHub, let fitness, let health else { return }
        guard !settling else { askedAgain = true; return }
        settling = true
        defer { settling = false }
        repeat {
            askedAgain = false
            for (key, span) in pending {
                guard let id = UUID(uuidString: key), let session = await fitness.session(for: id) else {
                    pending[key] = nil   // the workout is gone: removing it from Health is a delete's job
                    continue
                }
                // Never write a workout without its recording: Health would get a bare span.
                guard !session.samples.isEmpty else { continue }
                let done = await health.follow(session, previousStart: span.start, previousEnd: span.end)
                Log.sync.info("health: followed an edit of \(key, privacy: .public): \(done, privacy: .public)")
                if done { pending[key] = nil }
            }
        } while askedAgain
    }
}
