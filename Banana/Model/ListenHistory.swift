import Foundation
import MapKit
import CoreLocation
import os

/// A log of bounded podcast listening sessions, persisted on-device. Location is
/// opt-in and sampled only while audio is actively playing.
///
/// `ListenEvent`/`ListenRoutePoint` (the storage-shaped model) live in `ListenEvent.swift`.
@MainActor
final class ListenHistoryStore: ObservableObject {
    // `nonisolated` — `Logger` is inherently thread-safe, and this needs to be usable from both
    // MainActor call sites and the background decode task below.
    private nonisolated static let log = Logger(subsystem: "com.boris.banana", category: "listenHistory")
    @Published private(set) var events: [ListenEvent] = []
    weak var settings: AppSettings?

    private let fileURL: URL = {
        let dir = AppSupport.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("listen_history.json")
    }()
    private let routesDirectory: URL = {
        let dir = AppSupport.directory
            .appendingPathComponent("ListenRoutes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    /// Metadata snapshots and append-only route writes share one lane. This preserves ordering
    /// without doing JSON encoding or file IO on the main actor.
    private nonisolated static let persistence = DispatchQueue(
        label: "com.boris.banana.listen-history",
        qos: .utility)

    /// Barrier for snapshot backup: route appends and metadata writes are asynchronous, so reading
    /// the backup payload immediately on background could otherwise capture the previous point.
    nonisolated static func flushPendingWrites() async {
        await withCheckedContinuation { continuation in
            persistence.async { continuation.resume() }
        }
    }

    init() {
        // Decode off the main thread: this file holds every listen ever (unbounded by design —
        // it feeds the Listen Map) and its init sat in the first-frame path. A listen recorded
        // before the decode lands is merged, not clobbered.
        //
        // `try? JSONDecoder().decode([ListenEvent].self, ...) ?? []` used to treat ANY decode
        // failure — one corrupt event among years of history, or a future field added without a
        // migration — as "nothing here," and the very next save() would write that emptiness
        // permanently over listen_history.json. `SnapshotLoader`/`LossyArray` (shared with the
        // rest of this sweep — see `Shared/SnapshotPersistence.swift`) fix that: one bad event
        // costs one event, and a wholly unparseable file is quarantined before anything can
        // overwrite it.
        let url = fileURL
        let routes = routesDirectory
        Task.detached(priority: .userInitiated) { [weak self] in
            var decoded: [ListenEvent] = []
            var mustRefuseSaves = false
            switch SnapshotLoader.load(from: url, as: LossyArray<ListenEvent>.self) {
            case .empty:
                break
            case let .loaded(lossy):
                if lossy.droppedCount > 0 {
                    Self.log.error("listen_history.json: dropped \(lossy.droppedCount, privacy: .public) corrupt listen(s) on load; everything else loaded normally")
                }
                decoded = lossy.elements
            case let .corrupt(error, quarantinedTo):
                if let quarantinedTo {
                    Self.log.error("listen_history.json failed to decode (\(String(describing: error), privacy: .public)); original preserved at \(quarantinedTo.lastPathComponent, privacy: .public). Starting empty — history is recoverable from the quarantine copy, and normal saves will only ever touch listen_history.json from here on.")
                } else {
                    mustRefuseSaves = true
                    Self.log.fault("listen_history.json failed to decode (\(String(describing: error), privacy: .public)) AND could not be quarantined — no backup exists. Refusing to save until this is resolved by hand; the original is still at listen_history.json, untouched.")
                }
            }
            var needsMigration = false
            for index in decoded.indices {
                let routeURL = routes.appendingPathComponent("\(decoded[index].id.uuidString).route")
                if let count = Self.routePointCount(at: routeURL), count > 0 {
                    decoded[index].routePointCount = count
                    decoded[index].route = []
                } else if !decoded[index].route.isEmpty {
                    // Legacy history embedded every point in the JSON file. Preserve it and move
                    // it into the append-only sidecar after the first successful load.
                    decoded[index].routePointCount = decoded[index].route.count
                    needsMigration = true
                }
            }
            let loadedEvents = decoded
            let shouldMigrate = needsMigration
            await MainActor.run { [weak self] in
                guard let self else { return }
                if mustRefuseSaves { self.saveIsUnsafe = true }
                self.finishLoad(loadedEvents, migrateRoutes: shouldMigrate)
            }
        }
        LaunchClock.mark("history.init")
    }

    /// True once the initial decode has landed; saves are gated on it (see save()).
    private var loaded = false
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []

    /// Await the initial decode — before offering history to other devices, which would otherwise
    /// see only what was recorded in the first seconds of this launch.
    func whenLoaded() async {
        guard !loaded else { return }
        await withCheckedContinuation { loadWaiters.append($0) }
    }
    private var pendingSave = false
    /// Set when `listen_history.json` failed to decode AND could not even be quarantined (copied
    /// aside for safekeeping) — see `init()`/`load()`. In that situation there is no backup
    /// anywhere, so `save()` refuses to run rather than risk being the thing that actually
    /// destroys the owner's only copy of years of listening history. Stays true for the rest of
    /// this launch; a relaunch (after the underlying problem — e.g. a full disk — is resolved by
    /// hand) gets a fresh attempt.
    private var saveIsUnsafe = false
    private var activeSessionID: UUID?
    private var routesLoading: Set<UUID> = []
    private lazy var routeRecorder = ListenRouteRecorder { [weak self] location in
        self?.append(location)
    }

    private func finishLoad(_ decoded: [ListenEvent], migrateRoutes: Bool = false) {
        if events.isEmpty {
            events = decoded
        } else if !decoded.isEmpty {
            // Something recorded before the decode landed — keep it, append history behind it.
            let existing = Set(events.map(\.id))
            events.append(contentsOf: decoded.filter { !existing.contains($0.id) })
        }
        loaded = true
        let waiters = loadWaiters
        loadWaiters = []
        for waiter in waiters { waiter.resume() }
        if migrateRoutes {
            persistAllRoutes()
            var metadataOnly = events
            for index in metadataOnly.indices where metadataOnly[index].id != activeSessionID {
                metadataOnly[index].routePointCount = metadataOnly[index].route.count
                metadataOnly[index].route = []
            }
            events = metadataOnly
            pendingSave = false
            save()
        } else if pendingSave {
            pendingSave = false
            save()
        }
    }

    /// Begin one continuous play interval. Pause, stop, episode switch, and finish
    /// close it; resuming starts another session instead of silently inflating a counter.
    func beginSession(podcastID: UUID?, episodeID: String?, podcastTitle: String,
                      episodeTitle: String, artworkURL: URL?) {
        endSession()
        let event = ListenEvent(date: Date(), podcastID: podcastID, episodeID: episodeID,
                                podcastTitle: podcastTitle, episodeTitle: episodeTitle,
                                artworkURL: artworkURL)
        events.insert(event, at: 0)
        activeSessionID = event.id
        save()
        ControlChangeReporter.changed(.listen, event.id.uuidString)

        if settings?.recordListenLocation == true {
            routeRecorder.start()
        }
    }

    func endSession() {
        routeRecorder.stop()
        guard let id = activeSessionID,
              let idx = events.firstIndex(where: { $0.id == id }) else {
            activeSessionID = nil
            return
        }
        events[idx].endedAt = Date()
        activeSessionID = nil
        save()
        ControlChangeReporter.changed(.listen, id.uuidString)
        if events[idx].routePointCount > 0 {
            // After the last point's write lands on the persistence lane.
            Self.persistence.async {
                Task { @MainActor in ControlChangeReporter.changed(.listenRoute, id.uuidString) }
            }
        }
    }

    func clear() {
        routeRecorder.stop()
        activeSessionID = nil
        // Cleared here, cleared everywhere.
        for event in events {
            ControlChangeReporter.deleted(.listen, event.id.uuidString)
            if event.routePointCount > 0 { ControlChangeReporter.deleted(.listenRoute, event.id.uuidString) }
        }
        events = []
        let routes = routesDirectory
        Self.persistence.async {
            try? FileManager.default.removeItem(at: routes)
            try? FileManager.default.createDirectory(at: routes, withIntermediateDirectories: true)
        }
        save()
    }

    private func append(_ location: CLLocation) {
        guard let id = activeSessionID,
              let idx = events.firstIndex(where: { $0.id == id }) else { return }
        let point = ListenRoutePoint(lat: location.coordinate.latitude,
                                     lon: location.coordinate.longitude,
                                     date: location.timestamp)
        if let last = events[idx].route.last {
            let prior = CLLocation(latitude: last.lat, longitude: last.lon)
            guard location.distance(from: prior) >= 20 else { return }
        }
        events[idx].route.append(point)
        events[idx].routePointCount = events[idx].route.count
        events[idx].lat = events[idx].lat ?? point.lat
        events[idx].lon = events[idx].lon ?? point.lon
        appendRoute(point, eventID: id)
        // The first coordinate belongs in the small metadata index. Later points are sidecar-only:
        // each point adds exactly 24 bytes instead of re-encoding every listen ever recorded.
        if events[idx].routePointCount == 1 { save() }
        if events[idx].place == nil && events[idx].routePointCount == 1 {
            Task { await nameFirstLocation(id, location: location) }
        }
    }

    private func nameFirstLocation(_ id: UUID, location: CLLocation) async {
        var place: String?
        if let request = MKReverseGeocodingRequest(location: location),
           let items = try? await request.mapItems {
            place = items.first?.name
        }
        guard let idx = events.firstIndex(where: { $0.id == id }) else { return }
        events[idx].place = place
        save()
        ControlChangeReporter.changed(.listen, id.uuidString)
    }

    /// Re-read from disk (an iCloud restore rewrites the file underneath us).
    func reloadFromDisk() { load() }

    private func save() {
        // Never write before the initial decode lands: `events` would hold ONLY the pre-load
        // additions and the atomic write would TRUNCATE the whole history on disk (a wake-intent
        // play can record within the decode window). finishLoad merges, then flushes this.
        guard loaded else { pendingSave = true; return }
        // See `init()`/`saveIsUnsafe`: only set when listen_history.json failed to decode AND
        // couldn't be quarantined, i.e. there is no backup of the original anywhere. Writing here
        // would risk being the actual data-loss event rather than just reflecting an earlier one.
        guard !saveIsUnsafe else {
            Self.log.fault("save() refused: no backup of a previously-corrupt listen_history.json exists yet, so writing now would risk destroying the only copy. Resolve by hand and relaunch.")
            return
        }
        let snapshot = events.map { event -> ListenEvent in
            var metadata = event
            metadata.route = []
            return metadata
        }
        let url = fileURL
        Self.persistence.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
        CloudBackup.shared.schedule()
    }

    /// Synchronous — used only by `reloadFromDisk()` (an iCloud restore, which must complete
    /// before its other side effects run). Same decode-and-quarantine treatment as `init()`'s
    /// background load, so a corrupt file encountered mid-session is preserved rather than risking
    /// getting overwritten by the very next save() the same way a launch-time corruption would.
    private func load() {
        var decoded: [ListenEvent]
        switch SnapshotLoader.load(from: fileURL, as: LossyArray<ListenEvent>.self) {
        case .empty:
            return
        case let .loaded(lossy):
            if lossy.droppedCount > 0 {
                Self.log.error("listen_history.json: dropped \(lossy.droppedCount, privacy: .public) corrupt listen(s) on load; everything else loaded normally")
            }
            decoded = lossy.elements
        case let .corrupt(error, quarantinedTo):
            if let quarantinedTo {
                Self.log.error("listen_history.json failed to decode (\(String(describing: error), privacy: .public)); original preserved at \(quarantinedTo.lastPathComponent, privacy: .public).")
            } else {
                saveIsUnsafe = true
                Self.log.fault("listen_history.json failed to decode (\(String(describing: error), privacy: .public)) AND could not be quarantined — no backup exists. Refusing to save until this is resolved by hand.")
            }
            return
        }
        for index in decoded.indices {
            decoded[index].routePointCount =
                Self.routePointCount(at: routeURL(decoded[index].id)) ?? decoded[index].route.count
            decoded[index].route = []
        }
        events = decoded
    }

    /// Load only the route sidecars a visible map needs. Metadata, dates, places, and first
    /// coordinates remain available for every event without retaining all historical GPS points.
    func loadRoutes(for ids: Set<UUID>) async {
        let targets = events.compactMap { event -> UUID? in
            guard ids.contains(event.id), event.route.isEmpty, event.routePointCount > 0,
                  !routesLoading.contains(event.id) else { return nil }
            return event.id
        }
        guard !targets.isEmpty else { return }
        routesLoading.formUnion(targets)
        let directory = routesDirectory
        let decoded = await Task.detached(priority: .utility) {
            var result: [UUID: [ListenRoutePoint]] = [:]
            for id in targets {
                let url = directory.appendingPathComponent("\(id.uuidString).route")
                if let route = Self.decodeRoute(at: url), !route.isEmpty { result[id] = route }
            }
            return result
        }.value
        var updated = events
        for index in updated.indices {
            if let route = decoded[updated[index].id] {
                updated[index].route = route
                updated[index].routePointCount = route.count
            }
        }
        routesLoading.subtract(targets)
        if !decoded.isEmpty { events = updated }
    }

    /// Release route arrays when a map's time range changes. Original points stay untouched on
    /// disk and can be loaded again; the current recording is never unloaded.
    func unloadRoutes(except retained: Set<UUID> = []) {
        var updated = events
        var changed = false
        for index in updated.indices
            where updated[index].id != activeSessionID
                && !retained.contains(updated[index].id)
                && !updated[index].route.isEmpty {
            updated[index].route = []
            changed = true
        }
        if changed { events = updated }
    }

    private func routeURL(_ id: UUID) -> URL {
        routesDirectory.appendingPathComponent("\(id.uuidString).route")
    }

    private func appendRoute(_ point: ListenRoutePoint, eventID: UUID) {
        let url = routeURL(eventID)
        let data = Self.encodeRoutePoint(point)
        Self.persistence.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
        CloudBackup.shared.schedule()
    }

    private func persistAllRoutes() {
        let routes = events.map { ($0.id, $0.route) }.filter { !$0.1.isEmpty }
        let directory = routesDirectory
        Self.persistence.async {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (id, points) in routes {
                var data = Data(capacity: points.count * 24)
                for point in points { data.append(Self.encodeRoutePoint(point)) }
                try? data.write(to: directory.appendingPathComponent("\(id.uuidString).route"),
                                options: .atomic)
            }
        }
    }

    private nonisolated static func encodeRoutePoint(_ point: ListenRoutePoint) -> Data {
        var data = Data(capacity: 24)
        for value in [point.lat, point.lon, point.date.timeIntervalSince1970] {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    private nonisolated static func decodeRoute(at url: URL) -> [ListenRoutePoint]? {
        guard let data = try? Data(contentsOf: url), data.count >= 24 else { return nil }
        let completeBytes = data.count - data.count % 24
        var points: [ListenRoutePoint] = []
        points.reserveCapacity(completeBytes / 24)
        data.withUnsafeBytes { raw in
            for offset in stride(from: 0, to: completeBytes, by: 24) {
                func value(_ relative: Int) -> Double {
                    let bits = raw.loadUnaligned(fromByteOffset: offset + relative, as: UInt64.self)
                    return Double(bitPattern: UInt64(littleEndian: bits))
                }
                points.append(ListenRoutePoint(
                    lat: value(0), lon: value(8),
                    date: Date(timeIntervalSince1970: value(16))))
            }
        }
        return points
    }

    private nonisolated static func routePointCount(at url: URL) -> Int? {
        guard let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              bytes >= 24 else { return nil }
        return bytes / 24
    }

    #if DEBUG
    /// Seed a spread of located listens across a few shows/places for map verification.
    func injectSampleForPreview() {
        let now = Date()
        let places: [(name: String, lat: Double, lon: Double)] = [
            ("Home", 37.7649, -122.4294), ("Equinox Gym", 37.7799, -122.4094),
            ("Caltrain", 37.7899, -122.3994), ("Blue Bottle", 37.7719, -122.4144),
        ]
        let shows = ["Acquired", "Complex Systems", "Gamecraft"]
        events = (0..<18).map { i in
            let place = places[i % places.count]
            let show = shows[i % shows.count]
            return ListenEvent(date: now.addingTimeInterval(Double(-i) * 36_000),
                               podcastTitle: show, episodeTitle: "\(show) — Episode \(40 - i)",
                               lat: place.lat + Double(i % 3) * 0.0008,
                               lon: place.lon + Double(i % 2) * 0.0008, place: place.name)
        }
    }

    /// Listens that switch shows partway through the debug workout, anchored to its
    /// start, for verifying the podcast-colored route.
    func injectRunListens(around start: Date) {
        events = [("Acquired", 0.0), ("Complex Systems", 1200.0), ("Gamecraft", 2400.0)].map {
            ListenEvent(date: start.addingTimeInterval($0.1), podcastTitle: $0.0, episodeTitle: "\($0.0) episode")
        }
    }
    #endif
}

/// Low-frequency route sampling for the explicit "Record where I listen" opt-in.
/// It exists only for the life of active playback and stops immediately on pause.
@MainActor
private final class ListenRouteRecorder: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let onLocation: (CLLocation) -> Void
    private var wantsUpdates = false

    init(onLocation: @escaping (CLLocation) -> Void) {
        self.onLocation = onLocation
        super.init()
        manager.delegate = self
        manager.activityType = .otherNavigation
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 50
        manager.pausesLocationUpdatesAutomatically = true
        #if os(iOS)
        manager.showsBackgroundLocationIndicator = true
        manager.allowsBackgroundLocationUpdates = true
        #endif
    }

    func start() {
        wantsUpdates = true
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            wantsUpdates = false
        @unknown default:
            wantsUpdates = false
        }
    }

    func stop() {
        wantsUpdates = false
        manager.stopUpdatingLocation()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self, wantsUpdates else { return }
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                manager.startUpdatingLocation()
            default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let newest = locations.last, newest.horizontalAccuracy >= 0,
              newest.horizontalAccuracy <= 150 else { return }
        Task { @MainActor [weak self] in self?.onLocation(newest) }
    }
}

// Every listening session is on every device (CloudControlsSync): the event (no route points — a
// session's route is its own record, packed), so the Listen Map and history are the same anywhere.
extension ListenHistoryStore: CloudControlSource {
    func cloudItemIDs(_ kind: ControlKind) -> [String] {
        switch kind {
        case .listen:
            return events.map(\.id.uuidString)
        case .listenRoute:
            return events.filter { $0.routePointCount > 0 && $0.id != activeSessionID }.map(\.id.uuidString)
        default:
            return []
        }
    }

    func cloudItem(_ kind: ControlKind, id: String) -> Data? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        switch kind {
        case .listen:
            guard var event = events.first(where: { $0.id == uuid }) else { return nil }
            event.route = []
            return try? JSONEncoder().encode(event)
        case .listenRoute:
            return try? Data(contentsOf: routeURL(uuid))
        default:
            return nil
        }
    }

    func applyCloud(_ kind: ControlKind, id: String, item: Data?) -> Bool {
        guard let uuid = UUID(uuidString: id) else { return true }
        switch kind {
        case .listen:
            guard let item else {
                events.removeAll { $0.id == uuid }
                save()
                return true
            }
            guard var event = try? JSONDecoder().decode(ListenEvent.self, from: item) else { return true }
            if let index = events.firstIndex(where: { $0.id == uuid }) {
                event.route = events[index].route   // points already loaded here stay
                events[index] = event
            } else {
                // Newest first, as the list shows them.
                let at = events.firstIndex { $0.date < event.date } ?? events.endIndex
                events.insert(event, at: at)
            }
            save()
        case .listenRoute:
            let url = routeURL(uuid)
            Self.persistence.async {
                if let item { try? item.write(to: url, options: .atomic) }
                else { try? FileManager.default.removeItem(at: url) }
            }
        default:
            break
        }
        return true
    }
}


// The data platform (docs/design/DATA-PLATFORM.md): `ListenAdapter`, through the same paths as
// the Controls sync above.
extension ListenHistoryStore: ListenSyncSource {
    var syncListens: [ListenEvent] { events }

    func syncRouteFile(_ event: ListenEvent) -> URL? {
        guard event.id != activeSessionID, event.routePointCount > 0 else { return nil }
        return routeURL(event.id)
    }

    func applySyncedListen(_ event: ListenEvent) {
        guard let item = try? JSONEncoder().encode(event) else { return }
        _ = ControlChangeReporter.fromSpace { applyCloud(.listen, id: event.id.uuidString, item: item) }
    }

    func storeSyncedRoute(_ id: UUID, data: Data) {
        _ = ControlChangeReporter.fromSpace { applyCloud(.listenRoute, id: id.uuidString, item: data) }
    }

    func removeSyncedListens(_ ids: [UUID]) {
        ControlChangeReporter.fromSpace {
            for id in ids {
                _ = applyCloud(.listen, id: id.uuidString, item: nil)
                _ = applyCloud(.listenRoute, id: id.uuidString, item: nil)
            }
        }
    }

    func syncEditedAt(_ id: UUID) -> Date? { CloudControlsSync.editedAt(.listen, id: id.uuidString) }
}
