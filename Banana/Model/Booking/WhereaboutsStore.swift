import Combine
import Foundation

/// The phone's `Whereabouts`, published for the booking service (docs/design/BOOKING.md §13):
/// the phone works it out from its own zone, home and the flights on the calendar, and publishes
/// it when it says something new (or a day has gone by). The iPad and the Mac keep the last copy
/// they were sent and publish nothing.
///
/// The calendar read is the shared one every screen uses (`GoogleCalendarService.windowFetch`
/// within its core window, which reaches 90 days ahead), not the Plan's own 8-day flight pass,
/// and the parsing runs off the main thread: nothing here touches the Plan's frames.
@MainActor
final class WhereaboutsStore {
    static let shared = WhereaboutsStore()

    static let syncType = "plan.whereabouts"
    static let syncID = "whereabouts"
    // No dots in keys: UserDefaults observation reads a dot as a key path.
    private static let key = "whereaboutsPublished"
    private static let debounce: Duration = .seconds(2)

    /// The phone's: what it last published. Elsewhere: the last copy the phone sent.
    private(set) var value: Whereabouts?
    /// How long the last build took off the main thread, for the log and the tests.
    private(set) var lastBuildMilliseconds: Double?

    private var pending: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        value = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Whereabouts.self, from: $0) }
    }

    /// At launch, on the phone: work it out again when the flights the Plan knows change, and when
    /// the phone changes zone. The app coming forward asks too (`RootView`).
    func start(flightLegs: Published<[SmartScheduleStore.FlightLeg]>.Publisher) {
        guard DeviceRole.current.isHub, cancellables.isEmpty else { return }
        flightLegs.removeDuplicates().dropFirst().sink { [weak self] _ in self?.schedule() }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)
            .sink { [weak self] _ in Task { @MainActor in self?.schedule() } }.store(in: &cancellables)
        schedule()
    }

    /// A refresh shortly, the requests of the next couple of seconds as one.
    func schedule() {
        guard DeviceRole.current.isHub else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    /// Reads the flights over the booking horizon and publishes what changed. A read that missed
    /// a calendar publishes nothing: the copy out there stays, rather than one missing a trip.
    func refresh(now: Date = Date()) async {
        guard DeviceRole.current.isHub else { return }
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) ?? now
        let end = calendar.date(byAdding: .day, value: WhereaboutsBuilder.horizonDays, to: start) ?? now
        let fetch = await GoogleCalendarService.shared.windowFetch(
            from: start, to: end, excluding: SmartScheduleStore.shared.settings.excludedCalendarIDs)
        guard fetch.isComplete else { return }
        let events = fetch.window.travelEvents.map {
            WhereaboutsBuilder.Event(title: $0.title, location: $0.location, notes: $0.notes, start: $0.start, end: $0.end)
        }
        let current = TimeZone.current, home = TripTimeZone.home
        let (next, ms) = await Task.detached(priority: .utility) {
            let began = ContinuousClock.now
            let built = WhereaboutsBuilder.build(flights: WhereaboutsBuilder.flights(from: events),
                                                 current: current, home: home, now: now)
            let took = ContinuousClock.now - began
            return (built, Double(took.components.attoseconds) / 1e15 + Double(took.components.seconds) * 1000)
        }.value
        lastBuildMilliseconds = ms
        publish(next)
    }

    /// Takes `next` when it is news (`WhereaboutsBuilder.shouldPublish`) and tells the data platform.
    func publish(_ next: Whereabouts) {
        guard DeviceRole.current.isHub, WhereaboutsBuilder.shouldPublish(next, over: value) else { return }
        value = next
        store()
        SyncReport.changed(Self.syncType, [Self.syncID])
    }

    /// The phone's copy, on an iPad or the Mac: kept when newer.
    func adoptSynced(_ remote: Whereabouts) {
        guard remote.updatedAt > (value?.updatedAt ?? .distantPast) else { return }
        value = remote
        store()
    }

    /// Another account signed in on this device (docs/design/DATA-PLATFORM.md §2): forgotten here.
    func resetForAccountChange() {
        pending?.cancel()
        value = nil
        UserDefaults.standard.removeObject(forKey: Self.key)
    }

    private func store() {
        guard let value, let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}

extension WhereaboutsStore: WhereaboutsSyncSource {
    var syncWhereabouts: Whereabouts? { value }
    func adoptSyncedWhereabouts(_ value: Whereabouts) { adoptSynced(value) }
}
