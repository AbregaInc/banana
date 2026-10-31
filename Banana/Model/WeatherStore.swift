import Foundation
import Combine
import WeatherKit
import CoreLocation
import MapKit

/// One hour of forecast. The stripe only needs `hour`/`tempF`/`precip`; the rest is what the
/// detail page shows when you tap through to an hour.
struct HourlyWeather: Identifiable, Hashable, Codable, Sendable {
    let date: Date
    let hour: Int          // hour-of-day, local
    let tempF: Double
    let feelsF: Double
    let precip: Double     // chance of precipitation, 0…1
    let windMph: Double
    let humidity: Double   // 0…1
    let symbol: String     // SF Symbol name
    let condition: String  // human-readable
    var id: Date { date }
}

/// A day's forecast: its hours plus the summary the detail page leads with.
///
/// `timeZone` is the *forecast location's*, which is what the hours are stamped in. Normally it
/// matches the device's, but formatting in the device's zone regardless would mislabel every
/// time the moment they differ — 9am becomes "9 PM", and sunrise reads as an evening.
struct DayForecast: Identifiable, Hashable, Sendable {
    let date: Date         // start of day, in `timeZone`
    let hours: [HourlyWeather]
    let highF: Double
    let lowF: Double
    let sunrise: Date?
    let sunset: Date?
    let symbol: String
    let condition: String
    let timeZone: TimeZone
    var id: Date { date }

    var calendar: Calendar {
        var cal = Calendar.current
        cal.timeZone = timeZone
        return cal
    }

    /// The hour bucket containing `date` — what a tap on the stripe resolves to.
    func hour(at date: Date) -> HourlyWeather? {
        let target = calendar.component(.hour, from: date)
        return hours.first { $0.hour == target } ?? hours.first
    }
}

/// Codable for the first-paint snapshot. TimeZone round-trips as identifier + GMT offset
/// (identifier preferred; the offset covers a zone that has no identifier).
extension DayForecast: Codable {
    private enum CodingKeys: String, CodingKey {
        case date, hours, highF, lowF, sunrise, sunset, symbol, condition, tzIdentifier, tzSeconds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let identifier = try c.decodeIfPresent(String.self, forKey: .tzIdentifier)
        let seconds = try c.decodeIfPresent(Int.self, forKey: .tzSeconds)
        let zone = identifier.flatMap(TimeZone.init(identifier:))
            ?? seconds.flatMap(TimeZone.init(secondsFromGMT:))
            ?? .current
        self.init(date: try c.decode(Date.self, forKey: .date),
                  hours: try c.decode([HourlyWeather].self, forKey: .hours),
                  highF: try c.decode(Double.self, forKey: .highF),
                  lowF: try c.decode(Double.self, forKey: .lowF),
                  sunrise: try c.decodeIfPresent(Date.self, forKey: .sunrise),
                  sunset: try c.decodeIfPresent(Date.self, forKey: .sunset),
                  symbol: try c.decode(String.self, forKey: .symbol),
                  condition: try c.decode(String.self, forKey: .condition),
                  timeZone: zone)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(date, forKey: .date)
        try c.encode(hours, forKey: .hours)
        try c.encode(highF, forKey: .highF)
        try c.encode(lowF, forKey: .lowF)
        try c.encodeIfPresent(sunrise, forKey: .sunrise)
        try c.encodeIfPresent(sunset, forKey: .sunset)
        try c.encode(symbol, forKey: .symbol)
        try c.encode(condition, forKey: .condition)
        try c.encode(timeZone.identifier, forKey: .tzIdentifier)
        try c.encode(timeZone.secondsFromGMT(), forKey: .tzSeconds)
    }
}

/// Fetches the week's forecast for the current location.
///
/// Apple Weather (WeatherKit) is the one source. It never answers in the Simulator, so there the
/// forecast is the preview's sample or nothing.
@MainActor
final class WeatherStore: NSObject, ObservableObject {
    static let shared = WeatherStore()

    @Published private(set) var days: [DayForecast] = []
    @Published private(set) var placeName: String?
    @Published private(set) var source: String = ""
    /// Apple Weather's mark and legal page, which Apple requires wherever its forecast shows
    /// (developer.apple.com/weatherkit/get-started). Asked for once, after a forecast arrives.
    @Published private(set) var attribution: Attribution?

    struct Attribution: Equatable {
        let markLight: URL
        let markDark: URL
        let legalPage: URL
        let serviceName: String
    }
    @Published private(set) var lastError: String?
    @Published private(set) var debugStatus: String = "not run"

    /// Today's hours — what the Today stripe draws.
    var hourly: [HourlyWeather] { forecast(for: Date())?.hours ?? [] }

    func forecast(for day: Date) -> DayForecast? {
        days.first { Calendar.current.isDate($0.date, inSameDayAs: day) }
    }

    // MARK: - Travel-aware, per-location cache
    //
    // `days`/`hourly`/`forecast(for:)` above stay the CURRENT-location forecast (Week + detail
    // read them, unchanged). On top, a cache keyed by a coarse grid cell holds a forecast per
    // place you'll be that week, so the Today stripe can show NYC weather this morning and Miami
    // weather this afternoon on the day you fly. A whole metro collapses to one cell → one fetch;
    // the no-travel day is exactly one cell, identical cost to before.

    /// ~0.25° cell (≈20–28 km) — dedups a metro to one fetch, keeps distinct cities apart.
    struct GridKey: Hashable, Sendable {
        let lat: Int, lon: Int
        init(_ c: CLLocationCoordinate2D) { lat = Int((c.latitude * 4).rounded()); lon = Int((c.longitude * 4).rounded()) }
    }
    private struct Cell: Sendable {
        var days: [DayForecast]
        var fetchedAt: Date
        var placeName: String?
        var lat: Double
        var lon: Double
        /// O(1) absolute-time lookup for the stripe. The old path flattened and linearly searched
        /// every hour in the multi-day forecast for every displayed hour on every body pass.
        var hoursByEpochHour: [Int64: HourlyWeather]

        init(days: [DayForecast], fetchedAt: Date, placeName: String?, lat: Double, lon: Double) {
            self.days = days
            self.fetchedAt = fetchedAt
            self.placeName = placeName
            self.lat = lat
            self.lon = lon
            hoursByEpochHour = days.flatMap(\.hours).reduce(into: [:]) { index, hour in
                // A provider can overlap the final/first hour of adjacent daily forecasts.
                // Last value wins rather than letting Dictionary(uniqueKeys...) trap the process.
                index[Int64((hour.date.timeIntervalSince1970 / 3600).rounded())] = hour
            }
        }
    }
    /// Internal cache mutations must not publish one invalidation per fetched city.
    private var cache: [GridKey: Cell] = [:]
    private static let maxCells = 8

    weak var smart: SmartScheduleStore?   // source of the excluded-calendar set (same as OccurrenceStore)
    private var travelEvents: [TravelEvent] = []
    private var travelEventsLoaded = false   // not persisted → a fresh launch must load them once

    /// The day's location segments (calendar-derived). Empty when there's no travel signal.
    /// Memoised per day: the flight parse (regex per event) must NOT re-run on every scroll frame —
    /// the stripe reads this from `body`. The memo clears whenever the travel events change.
    private struct SegKey: Hashable { let day: Date; let startHour: Int; let endHour: Int }
    private var segmentMemo: [SegKey: [LocationSegment]] = [:]
    func segments(for day: Date, startHour: Int = 6, endHour: Int = 22) -> [LocationSegment] {
        let key = SegKey(day: Calendar.current.startOfDay(for: day), startHour: startHour, endHour: endHour)
        if let cached = segmentMemo[key] { return cached }
        let segs = LocationTimeline.segments(for: day, travelEvents: travelEvents,
                                             currentLocation: lastCoordinate, startHour: startHour, endHour: endHour)
        segmentMemo[key] = segs
        return segs
    }

    /// Sample a cell's forecast at an absolute instant — tz-agnostic by design: each HourlyWeather
    /// carries an absolute date, so "nearest hour to this instant" is correct across time zones
    /// without any hour-of-day arithmetic. nil if that cell isn't cached or the instant is off the
    /// end of its forecast.
    private func sample(_ coord: CLLocationCoordinate2D, at instant: Date) -> HourlyWeather? {
        guard let cell = cache[GridKey(coord)] else { return nil }
        let hour = Int64((instant.timeIntervalSince1970 / 3600).rounded())
        let candidates = [hour, hour - 1, hour + 1].compactMap { cell.hoursByEpochHour[$0] }
        guard let nearest = candidates.min(by: {
            abs($0.date.timeIntervalSince(instant)) < abs($1.date.timeIntervalSince(instant))
        }) else { return nil }
        return abs(nearest.date.timeIntervalSince(instant)) < 5400 ? nearest : nil
    }

    /// The forecast set + place name for the location you're in at `instant` (travel-aware). The
    /// detail sheet uses this so tapping the post-landing stretch of the stripe opens Miami's
    /// forecast, not home's. Falls back to the home forecast when there's no travel (or mid-transit).
    func located(at instant: Date) -> (days: [DayForecast], placeName: String?) {
        let day = Calendar.current.startOfDay(for: instant)
        if let seg = segments(for: day).first(where: { instant >= $0.start && instant < $0.end }),
           let place = seg.place, let cell = cache[GridKey(place.coordinate)] {
            return (cell.days, place.placeName)
        }
        return (days, placeName)
    }

    /// Temperature (°F, rounded) at a coordinate and instant — for "88° on landing". nil if that
    /// cell isn't cached or the instant is off the end of the forecast.
    func tempF(lat: Double, lon: Double, at instant: Date) -> Int? {
        sample(CLLocationCoordinate2D(latitude: lat, longitude: lon), at: instant).map { Int($0.tempF.rounded()) }
    }

    func outdoorConditions(lat: Double, lon: Double, at instant: Date) -> OutdoorConditions? {
        guard let hour = sample(CLLocationCoordinate2D(latitude: lat, longitude: lon), at: instant) else { return nil }
        return OutdoorConditions(temperatureF: hour.tempF, humidity: hour.humidity, condition: hour.condition)
    }

    /// The first meaningful wet hour in a window, at the current-location forecast.
    ///
    /// This exists for the departure nudge, where the useful fact is not "it is raining now" but
    /// "it will rain before you're back, so take the coat with you". Reports the first hour over
    /// the threshold plus the window's peak, because the peak is what decides coat vs umbrella.
    struct RainOutlook: Equatable {
        let startsAt: Date
        let peakChance: Int      // percent, 0…100
        let condition: String    // the provider's own wording for the wettest hour
    }

    /// 40% is the point where a forecast is worth acting on; below it the nudge would cry wolf
    /// daily in any maritime climate and get ignored — including on the day it mattered.
    func rainOutlook(from start: Date, to end: Date, minimumChance: Double = 0.4) -> RainOutlook? {
        guard end > start else { return nil }
        let wet = hourly.filter { $0.date >= start && $0.date <= end && $0.precip >= minimumChance }
        guard let first = wet.min(by: { $0.date < $1.date }),
              let peak = wet.max(by: { $0.precip < $1.precip }) else { return nil }
        return RainOutlook(startsAt: first.date,
                           peakChance: Int((peak.precip * 100).rounded()),
                           condition: peak.condition)
    }

    private let service = WeatherService.shared
    private let locationManager = CLLocationManager()
    private var locationCont: CheckedContinuation<CLLocation?, Never>?
    private var coordinate: CLLocationCoordinate2D?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyReduced
        loadSnapshot()
        locationWatch = LocationAccess.shared.$standing.sink { [weak self] standing in
            Task { @MainActor in self?.locationStanding(became: standing) }
        }
    }

    private var locationWatch: AnyCancellable?
    private var lastStanding: LocationUse.Standing = .unknown

    /// Location has just been allowed (the setup list, Settings): fetch the forecast the plan has
    /// been going without. Hearing "allowed" for the first time in a launch is not that: the
    /// ordinary refresh, which honours the snapshot's age, covers it.
    private func locationStanding(became standing: LocationUse.Standing) {
        let before = lastStanding
        lastStanding = standing
        guard standing == .allowed, before == .notAsked || before == .refused else { return }
        Task { await refresh() }
    }

    // MARK: - First-paint snapshot (stale-while-revalidate)
    //
    // The forecast used to start empty every launch: a location fix + a network fetch (1–3 s)
    // before the stripe appeared — and when it did, the whole Today timeline reflowed around it.
    // The last forecast persists in Caches and paints instantly; `refreshIfStale` still refreshes
    // on its own TTL (the restored lastFetch honors it, so a relaunch within 15 min costs zero
    // network — and a stale one updates in place with no layout shift).

    private struct CellSnap: Codable { var lat: Double; var lon: Double; var days: [DayForecast]; var fetchedAt: Date; var placeName: String? }
    private struct Snapshot: Codable {
        var cells: [CellSnap]
        var homeLat: Double?
        var homeLon: Double?
        var placeName: String?
        var fetchedAt: Date
    }
    /// The old single-location snapshot shape — decoded once so the first launch after this update
    /// still paints home weather instead of popping in.
    private struct LegacySnapshot: Codable {
        var days: [DayForecast]; var fetchedAt: Date; var latitude: Double?; var longitude: Double?; var placeName: String?
    }

    private static let snapshotURL: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("weather-snapshot.json")
    }()

    private func loadSnapshot() {
        // Synchronous, like the occurrence snapshot: a few cells of hourly forecast is low hundreds
        // of KB, and having it in place for the FIRST body means the stripe never pops in and
        // reflows the timeline around itself.
        guard days.isEmpty, let data = try? Data(contentsOf: Self.snapshotURL) else { return }
        if let snap = try? JSONDecoder().decode(Snapshot.self, from: data) {
            for c in snap.cells.sorted(by: { $0.fetchedAt > $1.fetchedAt }).prefix(Self.maxCells) {
                let coord = CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon)
                cache[GridKey(coord)] = Cell(days: c.days, fetchedAt: c.fetchedAt, placeName: c.placeName, lat: c.lat, lon: c.lon)
            }
            lastFetch = snap.fetchedAt
            placeName = placeName ?? snap.placeName
            if let lat = snap.homeLat, let lon = snap.homeLon {
                lastCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                days = cache[GridKey(lastCoordinate!)]?.days ?? cache.values.first?.days ?? []
            } else {
                days = cache.values.first?.days ?? []
            }
        } else if let legacy = try? JSONDecoder().decode(LegacySnapshot.self, from: data) {
            days = legacy.days
            lastFetch = legacy.fetchedAt
            placeName = placeName ?? legacy.placeName
            if let lat = legacy.latitude, let lon = legacy.longitude {
                let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                lastCoordinate = coord
                cache[GridKey(coord)] = Cell(days: legacy.days, fetchedAt: legacy.fetchedAt, placeName: legacy.placeName, lat: lat, lon: lon)
            }
        }
        LaunchClock.mark("weather.snapshot")
    }

    private func saveSnapshot() {
        let cells = cache.values.sorted(by: { $0.fetchedAt > $1.fetchedAt }).prefix(Self.maxCells)
            .map { CellSnap(lat: $0.lat, lon: $0.lon, days: $0.days, fetchedAt: $0.fetchedAt, placeName: $0.placeName) }
        let snap = Snapshot(cells: cells, homeLat: lastCoordinate?.latitude, homeLon: lastCoordinate?.longitude,
                            placeName: placeName, fetchedAt: lastFetch ?? Date())
        let url = Self.snapshotURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snap) { try? data.write(to: url, options: .atomic) }
        }
    }

    /// A forecast is good for a while. refresh() is called from Today's and Week's `.task`, and
    /// PlannerTab swaps view identity on the Day/Week toggle — so without this, every flick of that
    /// segmented control cost a location fix plus a network forecast fetch.
    private var lastFetch: Date?
    private var lastCoordinate: CLLocationCoordinate2D?
    private static let ttl: TimeInterval = 15 * 60
    private var refreshTask: Task<Void, Never>?

    func refreshIfStale() async {
        // Also refresh when the travel events haven't loaded THIS session: segments (and the travel
        // stripe on future days) depend on them, and they aren't in the snapshot. Without this, a
        // fresh launch with an in-TTL snapshot skipped refresh and the travel stripe never appeared.
        if let lastFetch, !days.isEmpty, travelEventsLoaded, Date().timeIntervalSince(lastFetch) < Self.ttl {
            return
        }
        await refresh()
    }

    func refresh() async {
        if let refreshTask {
            await refreshTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRefresh()
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh() async {
        guard let location = await currentLocation() else {
            let status = "no location · auth=\(authName)"
            if debugStatus != status { debugStatus = status }
            return
        }
        coordinate = location.coordinate
        lastFetch = Date()
        // Gates the snapshot rewrite in saveSnapshot() below: a refresh where every needed cell is
        // still fresh, nothing was pruned, the place name was already resolved, and the home grid
        // cell didn't move writes back content identical to what's already on disk — skip it.
        var changed = false
        let previousHomeKey = lastCoordinate.map(GridKey.init)
        lastCoordinate = location.coordinate

        // Travel events for the week window. This is what tells us which OTHER places to forecast.
        let excluded = smart?.settings.excludedCalendarIDs ?? []
        let cal = Calendar.current
        let winStart = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date())) ?? Date()
        let winEnd = cal.date(byAdding: .day, value: 8, to: cal.startOfDay(for: Date())) ?? Date()
        travelEvents = await GoogleCalendarService.shared.windowFetch(
            from: winStart, to: winEnd, excluding: excluded).window.travelEvents
        travelEventsLoaded = true
        segmentMemo.removeAll()   // itinerary may have changed → recompute segments on next read

        // Places to forecast: current location + every distinct segment place over the next few
        // days. Deduped by cell, capped so a wild itinerary can't fan out to dozens of fetches.
        let homeKey = GridKey(location.coordinate)
        // A live-location move into a different (already-cached-and-fresh) cell wouldn't otherwise
        // trip any of the triggers below, leaving the persisted homeLat/homeLon stale relative to
        // what's actually being shown.
        if homeKey != previousHomeKey { changed = true }
        var needed: [(key: GridKey, coord: CLLocationCoordinate2D, zone: TimeZone, name: String?)] =
            [(homeKey, location.coordinate, .current, placeName)]
        for offset in 0..<8 {   // the visible week, so every Week-view day's places get a cell
            guard let day = cal.date(byAdding: .day, value: offset, to: Date()) else { continue }
            for seg in segments(for: day) {
                guard let p = seg.place else { continue }
                let k = GridKey(p.coordinate)
                if !needed.contains(where: { $0.key == k }) { needed.append((k, p.coordinate, p.timeZone, p.placeName)) }
            }
        }
        if needed.count > Self.maxCells {
            PlaybackDiagnostics.shared.log("weather cells capped", "kept \(Self.maxCells) of \(needed.count)")
            needed = Array(needed.prefix(Self.maxCells))
        }

        // Home first (the common case), then travel cells in a bounded parallel pool; skip cells
        // still within TTL. Sequentially trying WeatherKit and then its fallback for up to eight
        // cities made one refresh take the SUM of every network timeout.
        var resolvedSource = source
        var resolvedError: String?
        let missing = needed.filter {
            guard let cell = cache[$0.key] else { return true }
            return Date().timeIntervalSince(cell.fetchedAt) >= Self.ttl
        }
        var remaining = missing
        if let homeIndex = remaining.firstIndex(where: { $0.key == homeKey }) {
            let item = remaining.remove(at: homeIndex)
            let result = await fetchCell(item.coord, zone: item.zone, name: item.name)
            if let cell = result.cell { cache[item.key] = cell; changed = true }
            if let fetchedSource = result.source { resolvedSource = fetchedSource }
            if let error = result.error { resolvedError = error }
        }
        await withTaskGroup(of: (GridKey, Cell?, String?, String?).self) { group in
            var next = remaining.makeIterator()
            func enqueueNext() {
                guard let item = next.next() else { return }
                group.addTask { [self] in
                    let result = await fetchCell(item.coord, zone: item.zone, name: item.name)
                    return (item.key, result.cell, result.source, result.error)
                }
            }
            for _ in 0..<min(3, remaining.count) { enqueueNext() }
            while let (key, cell, fetchedSource, error) = await group.next() {
                if let cell { cache[key] = cell; changed = true }
                if let fetchedSource { resolvedSource = fetchedSource }
                if let error { resolvedError = error }
                enqueueNext()
            }
        }
        if pruneCache(preferred: Set(needed.map(\.key))) { changed = true }

        // Back-compat: `days` mirrors the home cell so Week + detail are unchanged.
        if let home = cache[homeKey] {
            if days != home.days { days = home.days }
            let status = "OK · \(resolvedSource) · \(cache.count) cell(s) · home \(home.days.count)d @ \(coordLabel(location))"
            if debugStatus != status { debugStatus = status }
        }
        if source != resolvedSource { source = resolvedSource }
        if lastError != resolvedError { lastError = resolvedError }
        let placeNameWasNil = placeName == nil
        await resolvePlaceName(location)
        if placeNameWasNil && placeName != nil { changed = true }
        if changed { saveSnapshot() }
    }

    /// Fetch one location's week from Apple Weather, stamped with the location's OWN zone —
    /// `.current` mislabels every remote cell by the tz delta (sampling is by absolute instant so
    /// it's unaffected, but the detail view isn't).
    private func fetchCell(_ coord: CLLocationCoordinate2D, zone: TimeZone, name: String?)
        async -> (cell: Cell?, source: String?, error: String?) {
        #if targetEnvironment(simulator)
        return (nil, nil, "Apple Weather doesn't answer in the Simulator")
        #else
        let loc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        do {
            let days = try await weatherKitForecast(for: loc, zone: zone)
            return (Cell(days: days, fetchedAt: Date(), placeName: name,
                         lat: coord.latitude, lon: coord.longitude), "Apple Weather", nil)
        } catch {
            return (nil, nil, error.localizedDescription)
        }
        #endif
    }

    /// Returns whether any cell was actually evicted — the caller uses this to gate the snapshot
    /// rewrite, since a call that doesn't touch the cache shouldn't dirty the persisted state.
    @discardableResult
    private func pruneCache(preferred: Set<GridKey>) -> Bool {
        guard cache.count > Self.maxCells else { return false }
        let victims = cache.keys.sorted {
            let leftPreferred = preferred.contains($0), rightPreferred = preferred.contains($1)
            if leftPreferred != rightPreferred { return !leftPreferred }
            return (cache[$0]?.fetchedAt ?? .distantPast) < (cache[$1]?.fetchedAt ?? .distantPast)
        }
        for key in victims.prefix(cache.count - Self.maxCells) { cache[key] = nil }
        return true
    }

    // MARK: - WeatherKit

    private func weatherKitForecast(for location: CLLocation, zone: TimeZone) async throws -> [DayForecast] {
        let weather = try await service.weather(for: location)
        if attribution == nil, let a = try? await service.attribution {
            attribution = Attribution(markLight: a.combinedMarkLightURL, markDark: a.combinedMarkDarkURL,
                                      legalPage: a.legalPageURL, serviceName: a.serviceName)
        }
        var cal = Calendar.current
        cal.timeZone = zone

        var byDay: [Date: [HourlyWeather]] = [:]
        for h in weather.hourlyForecast.forecast {
            let day = cal.startOfDay(for: h.date)
            byDay[day, default: []].append(
                HourlyWeather(date: h.date,
                              hour: cal.component(.hour, from: h.date),
                              tempF: h.temperature.converted(to: .fahrenheit).value,
                              feelsF: h.apparentTemperature.converted(to: .fahrenheit).value,
                              precip: max(0, min(1, h.precipitationChance)),
                              windMph: h.wind.speed.converted(to: .milesPerHour).value,
                              humidity: max(0, min(1, h.humidity)),
                              symbol: h.symbolName,
                              condition: h.condition.description)
            )
        }

        return weather.dailyForecast.forecast.compactMap { day -> DayForecast? in
            let start = cal.startOfDay(for: day.date)
            guard let hours = byDay[start], !hours.isEmpty else { return nil }
            return DayForecast(date: start,
                               hours: hours.sorted { $0.date < $1.date },
                               highF: day.highTemperature.converted(to: .fahrenheit).value,
                               lowF: day.lowTemperature.converted(to: .fahrenheit).value,
                               sunrise: day.sun.sunrise,
                               sunset: day.sun.sunset,
                               symbol: day.symbolName,
                               condition: day.condition.description,
                               timeZone: zone)   // the cell's own zone (see fetchCell), not .current
        }
    }

    // MARK: - Place name

    /// Reverse-geocode once per location so the detail page can name where it's forecasting for.
    private func resolvePlaceName(_ location: CLLocation) async {
        guard placeName == nil else { return }
        guard let request = MKReverseGeocodingRequest(location: location),
              let item = try? await request.mapItems.first else { return }
        placeName = item.name
    }

    private var authName: String {
        switch LocationAccess.shared.status {
        case .authorizedAlways: return "always"
        case .authorizedWhenInUse: return "whenInUse"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    private func coordLabel(_ location: CLLocation) -> String {
        String(format: "%.2f,%.2f", location.coordinate.latitude, location.coordinate.longitude)
    }

    // MARK: - Location (one-shot)

    private func currentLocation() async -> CLLocation? {
        // A forecast is something Banana fetches by itself, so it never shows the system's
        // location question (`LocationUse`): not asked yet means no weather yet. Asked through
        // `LocationAccess`, which hears the standing from the system instead of reading it here.
        guard LocationUse.unprompted(await LocationAccess.shared.settled()) == .fetch else { return nil }
        if let cached = locationManager.location { return cached }
        return await withCheckedContinuation { cont in
            locationCont = cont
            locationManager.requestLocation()
        }
    }

    private func finishLocation(_ location: CLLocation?) {
        locationCont?.resume(returning: location)
        locationCont = nil
    }

    #if DEBUG
    /// Stable, permission-free weather for visual verification routes.
    func injectSampleForPreview() {
        let calendar = Calendar.current
        let zone = TimeZone.current
        let today = calendar.startOfDay(for: Date())
        days = (0..<7).compactMap { dayOffset in
            guard let start = calendar.date(byAdding: .day, value: dayOffset, to: today) else { return nil }
            let hours = (0..<24).compactMap { hour -> HourlyWeather? in
                guard let date = calendar.date(byAdding: .hour, value: hour, to: start) else { return nil }
                let wave = sin((Double(hour) - 7) / 24 * .pi * 2)
                let temp = 67 + wave * 13 + Double(dayOffset)
                return HourlyWeather(
                    date: date, hour: hour, tempF: temp, feelsF: temp - 1,
                    precip: hour == 15 || hour == 16 ? 0.55 : 0.08,
                    windMph: 7, humidity: 0.58,
                    symbol: hour == 15 || hour == 16 ? "cloud.rain.fill" : "sun.max.fill",
                    condition: hour == 15 || hour == 16 ? "Rain" : "Clear"
                )
            }
            return DayForecast(
                date: start, hours: hours,
                highF: hours.map(\.tempF).max() ?? 80,
                lowF: hours.map(\.tempF).min() ?? 54,
                sunrise: calendar.date(bySettingHour: 5, minute: 42, second: 0, of: start),
                sunset: calendar.date(bySettingHour: 20, minute: 24, second: 0, of: start),
                symbol: "sun.max.fill", condition: "Mostly Clear", timeZone: zone
            )
        }
        placeName = "New York"
        source = "Preview"
        lastError = nil
    }
    #endif
}

extension WeatherStore: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                if self.locationCont != nil { manager.requestLocation() }
            case .denied, .restricted:
                self.finishLocation(nil)
            default:
                break
            }
        }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let loc = locations.last
        Task { @MainActor in self.finishLocation(loc) }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finishLocation(nil) }
    }
}
