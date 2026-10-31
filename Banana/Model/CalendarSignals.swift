import Combine
import Foundation

/// Two facts the calendar needs, published only when they change: which days you worked out (for
/// the workout cue) and which routine is playing. The calendar used to observe Health, your
/// workouts and the player whole — and Health alone publishes a dozen times while it refreshes at
/// launch (trends, nights, import state), each publish redrawing every day on the grid.
@MainActor
final class CalendarSignals: ObservableObject {
    static let shared = CalendarSignals()

    @Published private(set) var workoutDays: Set<Date> = []
    @Published private(set) var playingRoutineID: UUID?

    private var cancellables: Set<AnyCancellable> = []

    func start(health: HealthKitStore, fitness: FitnessStore, player: PlayerController) {
        guard cancellables.isEmpty else { return }
        health.$workouts.combineLatest(fitness.$summaries)
            .map { workouts, summaries in
                Self.days(workouts.map(\.start) + summaries.map(\.start))
            }
            .removeDuplicates()
            .sink { [weak self] in self?.workoutDays = $0 }
            .store(in: &cancellables)
        player.$isPlaying.combineLatest(player.$activeRoutineID)
            .map { playing, routine in playing ? routine : nil }
            .removeDuplicates()
            .sink { [weak self] in self?.playingRoutineID = $0 }
            .store(in: &cancellables)
    }

    func didWorkout(on day: Date) -> Bool {
        workoutDays.contains(Calendar.current.startOfDay(for: day))
    }

    nonisolated static func days(_ starts: [Date], calendar: Calendar = .current) -> Set<Date> {
        Set(starts.map { calendar.startOfDay(for: $0) })
    }
}
