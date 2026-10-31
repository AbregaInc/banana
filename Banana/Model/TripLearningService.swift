#if os(iOS)
import Combine
import CoreLocation
import CoreMotion
import Foundation

/// Learns how long your trips really take, from iOS's visit service (where you arrived and
/// left) and the motion sensor (on foot or in a vehicle). Off until "Learn from my trips" is
/// turned on in Settings › Travel, which is when iOS asks for "Always" location and Motion.
///
/// The visits stay in a file on this iPhone (last 60 days). What's learned from them — your pace
/// per mode, your usual time to each place — goes into `SmartScheduleSettings.learnedTravel`,
/// which syncs, so the Mac times trips (and writes busy blocks) the same way the phone does.
@MainActor
final class TripLearningService: NSObject, CLLocationManagerDelegate {
    static let shared = TripLearningService()

    private let manager = CLLocationManager()
    private let motion = CMMotionActivityManager()
    private let travel = TravelService()
    private var store = Stored()
    private var enableContinuation: CheckedContinuation<Bool, Never>?
    private var settingsObserver: AnyCancellable?
    /// Turned on from another device while iOS hadn't allowed "Always" location: ask the next
    /// time the app is in front, where iOS can show the question.
    private var askWhenActive = false

    private struct Stored: Codable {
        var visits: [VisitRecord] = []
        /// Recent observed ÷ estimated ratios per mode, the inputs to the synced medians.
        var ratios: [String: [Double]] = [:]
        /// Trips already learned from, by departure, so a re-delivered visit isn't counted twice.
        var learnedDepartures: [Date] = []
    }

    private var fileURL: URL { AppSupport.directory.appendingPathComponent("trip-learning.json") }
    private var settings: SmartScheduleSettings { SmartScheduleStore.shared.settings }

    private override init() {
        super.init()
        manager.delegate = self
        load()
    }

    /// At launch — including a background relaunch iOS makes to deliver a visit — and from then
    /// on whenever "Learn from my trips" changes, here or on another device. The phone learns; an
    /// iPad's visits would write the synced model a second time.
    func startIfEnabled() {
        guard DeviceRole.current.isHub else { return }
        Task { await apply(prompting: false) }
        settingsObserver = SmartScheduleStore.shared.$settings
            .map(\.learnFromTrips)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in await self?.apply(prompting: AppVisibility.shared.isActive) }
            }
    }

    /// The app came to the front: if learning was turned on elsewhere and iOS hasn't allowed it
    /// yet, this is where iOS can ask.
    func appBecameActive() {
        guard askWhenActive else { return }
        askWhenActive = false
        Task { await apply(prompting: true) }
    }

    /// Act on the synced "Learn from my trips": learn when it's on and iOS allows it, stop when
    /// it's off — and report which on the phone's status, so every device's control can say.
    /// The setting stays what you chose; missing permission is a status, not a reason to switch
    /// it off (which, synced, turned it off everywhere).
    func apply(prompting: Bool) async {
        guard DeviceRole.current.isHub else { return }
        guard settings.learnFromTrips else {
            askWhenActive = false
            disable()
            HubStatusStore.shared.update { $0.tripLearning = .off }
            return
        }
        var allowed = manager.authorizationStatus == .authorizedAlways
        if !allowed, prompting, !needsSettingsToEnable {
            allowed = await enable()
        }
        if allowed { manager.startMonitoringVisits() }
        askWhenActive = !allowed && !prompting
        HubStatusStore.shared.update { $0.tripLearning = allowed ? .running : .needsAlwaysLocation }
    }

    /// Turn learning on: ask for "Always" location (after "While using", as iOS requires) and
    /// Motion, then start listening for visits. Returns whether it's running.
    func enable() async -> Bool {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
            _ = await waitForAuthorizationChange()
            guard manager.authorizationStatus == .authorizedWhenInUse else { break }
            manager.requestAlwaysAuthorization()
            _ = await waitForAuthorizationChange()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
            _ = await waitForAuthorizationChange()
        default:
            break
        }
        // Touching the motion history is what makes iOS ask for Motion & Fitness.
        _ = await motionSeconds(from: Date().addingTimeInterval(-300), to: Date())
        let running = manager.authorizationStatus == .authorizedAlways
        if running { manager.startMonitoringVisits() }
        Log.travel.notice("[travel] learning \(running ? "on" : "not allowed", privacy: .public)")
        return running
    }

    /// Turn learning off and forget the visits. What was learned stays until you reset it.
    func disable() {
        manager.stopMonitoringVisits()
        store.visits = []
        save()
    }

    var needsSettingsToEnable: Bool {
        [.denied, .restricted].contains(manager.authorizationStatus)
    }

    private func waitForAuthorizationChange() async -> Bool {
        await withCheckedContinuation { continuation in
            enableContinuation = continuation
            // iOS may not call back if nothing changes (e.g. the prompt was suppressed).
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(60))
                if let pending = enableContinuation { enableContinuation = nil; pending.resume(returning: false) }
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            if let pending = enableContinuation {
                enableContinuation = nil
                pending.resume(returning: true)
            } else if DeviceRole.current.isHub, self.settings.learnFromTrips {
                // Allowed (or taken away) in iOS Settings: learn or stop, and say so everywhere.
                await self.apply(prompting: false)
            }
        }
    }

    // MARK: - Visits

    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        let record = VisitRecord(
            latitude: visit.coordinate.latitude, longitude: visit.coordinate.longitude,
            arrival: visit.arrivalDate == .distantPast ? Date() : visit.arrivalDate,
            departure: visit.departureDate == .distantFuture ? nil : visit.departureDate)
        Task { @MainActor in await self.record(record) }
    }

    private func record(_ visit: VisitRecord) async {
        // The same stay is reported twice: on arrival, then again with its departure.
        if let index = store.visits.firstIndex(where: {
            abs($0.arrival.timeIntervalSince(visit.arrival)) < 60
                && TripLearning.distance($0.coordinate, visit.coordinate) < TripLearning.placeRadius
        }) {
            store.visits[index].departure = visit.departure ?? store.visits[index].departure
        } else {
            store.visits.append(visit)
        }
        let cutoff = Date().addingTimeInterval(-60 * 86_400)
        store.visits.removeAll { $0.arrival < cutoff }
        store.learnedDepartures.removeAll { $0 < cutoff }
        save()
        await learnFromNewTrips()
    }

    private func learnFromNewTrips() async {
        let visits = store.visits.sorted { $0.arrival < $1.arrival }
        var modes: [Date: TransitMode] = [:]
        // Motion is looked up per candidate trip (async), then the pure pairing runs over it.
        for (a, b) in zip(visits, visits.dropFirst()) {
            guard let left = a.departure, !store.learnedDepartures.contains(left),
                  b.arrival > left, b.arrival.timeIntervalSince(left) <= TripLearning.maximumDuration else { continue }
            let seconds = await motionSeconds(from: left, to: b.arrival)
            modes[left] = TripLearning.mode(from: seconds, defaultMode: settings.transitMode)
        }
        let trips = TripLearning.trips(from: visits) { departure, _ in modes[departure] }
        guard !trips.isEmpty else { return }

        var learned = settings.learnedTravel
        let home = settings.hasHome
            ? CLLocationCoordinate2D(latitude: settings.homeLatitude ?? 0, longitude: settings.homeLongitude ?? 0) : nil
        for trip in trips where !store.learnedDepartures.contains(trip.departure) {
            let estimate = await travel.groundTime(from: trip.from, to: trip.to, arriveBy: nil,
                                                   departAt: trip.departure, mode: trip.mode)
            let fromHome = home.map { TripLearning.distance($0, trip.from) < 300 } ?? false
            let key = fromHome
                ? (TripLearning.nearestPlaceKey(to: trip.to, in: learned) ?? TripLearning.placeKey(trip.to))
                : nil
            TripLearning.learn(trip, estimate: estimate, destinationKey: key,
                               into: &learned, recentRatios: &store.ratios)
            store.learnedDepartures.append(trip.departure)
            Log.travel.notice("[travel] learned trip \(trip.mode.rawValue, privacy: .public) \(Int(trip.seconds))s vs estimate \(Int(estimate ?? -1))s")
        }
        save()
        if learned != settings.learnedTravel {
            SmartScheduleStore.shared.settings.learnedTravel = learned
        }
    }

    // MARK: - Motion

    private func motionSeconds(from start: Date, to end: Date) async -> [TripLearning.MotionKind: TimeInterval] {
        guard CMMotionActivityManager.isActivityAvailable() else { return [:] }
        let activities: [CMMotionActivity] = await withCheckedContinuation { continuation in
            motion.queryActivityStarting(from: start, to: end, to: .main) { list, _ in
                continuation.resume(returning: list ?? [])
            }
        }
        var totals: [TripLearning.MotionKind: TimeInterval] = [:]
        let following: [CMMotionActivity?] = activities.dropFirst().map { Optional($0) } + [nil]
        for (current, next) in zip(activities, following) {
            guard current.confidence != .low else { continue }
            let until = next?.startDate ?? end
            let duration = max(0, min(until, end).timeIntervalSince(max(current.startDate, start)))
            let kind: TripLearning.MotionKind? = current.automotive ? .automotive
                : current.cycling ? .cycling
                : current.running ? .running
                : current.walking ? .walking : nil
            if let kind { totals[kind, default: 0] += duration }
        }
        return totals
    }

    // MARK: - Storage (this iPhone only)

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        store = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(store) else { return }
        // Readable after the first unlock: visits arrive in the background, often while locked.
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
#endif
