import Foundation
import MapKit
import CoreLocation

extension TransitMode {
    var directionsType: MKDirectionsTransportType {
        switch self {
        case .drive: return .automobile
        case .transit: return .transit
        case .walk: return .walking
        }
    }
}

/// Estimates travel time to a meeting via MapKit (Apple's routing service — needs
/// network, not a third party). Resolves the destination from structured coords
/// or by geocoding the address, and caches results to respect rate limits.
@MainActor
final class TravelService {
    struct Estimate {
        let duration: TimeInterval
        let destination: CLLocationCoordinate2D
        /// The mode this trip was timed for, and what the block says about it.
        var detail: TravelLegDetail
    }

    /// Where a location text points, and how sure that is.
    struct ResolvedPlace {
        let coordinate: CLLocationCoordinate2D
        let name: String
        let confidence: PlaceConfidence
        /// The mode saved with the place, if you set one.
        let savedMode: TransitMode?
    }


    private var cache: [String: (time: TimeInterval, at: Date)] = [:]
    private static let maxRoutes = 128
    /// Location text → coordinate, remembered. A meeting's address doesn't move; resolve it once
    /// rather than hitting the network geocoder on every recompute. Keyed by the text alone, so
    /// the trip there and the trip home resolve a name to the same spot.
    private var geocodeCache: [String: (coordinate: CLLocationCoordinate2D, at: Date)] = [:]
    private static let maxGeocodes = 256

    /// Travel time (seconds) to arrive at `meeting` by its start, or nil if it
    /// can't be resolved (no usable location, offline, or routing failed).
    func travelTime(to meeting: MeetingInfo,
                    from home: CLLocationCoordinate2D,
                    settings: SmartScheduleSettings) async -> TimeInterval? {
        await estimate(to: meeting, from: home, settings: settings)?.duration
    }

    /// Where a meeting's location points: a place you confirmed first, then the event's own
    /// coordinates, then a street address, and only then a guess — flagged, so the block asks
    /// "Chelsea?" instead of quietly timing a trip to the wrong Chelsea.
    func resolvePlace(for meeting: MeetingInfo, near origin: CLLocationCoordinate2D,
                      saved: [SavedPlace]) async -> ResolvedPlace? {
        if let place = saved.place(for: meeting.address) {
            return ResolvedPlace(coordinate: place.coordinate, name: place.name,
                                 confidence: .saved, savedMode: place.mode)
        }
        if let coordinate = meeting.coordinate {
            return ResolvedPlace(coordinate: coordinate,
                                 name: meeting.address.map(PlaceQuery.shortName) ?? meeting.title,
                                 confidence: .exact, savedMode: nil)
        }
        guard let address = meeting.address, !address.isEmpty else { return nil }
        return await resolvePlace(address, near: origin, saved: saved)
    }

    /// The same, for bare location text (the start of a trip home).
    func resolvePlace(_ text: String, near origin: CLLocationCoordinate2D,
                      saved: [SavedPlace]) async -> ResolvedPlace? {
        if let place = saved.place(for: text) {
            return ResolvedPlace(coordinate: place.coordinate, name: place.name,
                                 confidence: .saved, savedMode: place.mode)
        }
        // Cached on the text alone (not `near`) — see `geocodeCache`'s doc comment.
        let coordinate: CLLocationCoordinate2D
        if let cached = geocodeCache[text] {
            coordinate = cached.coordinate
        } else if let resolved = await geocode(text, near: origin) {
            geocodeCache[text] = (resolved, Date())
            pruneGeocodes()
            coordinate = resolved
        } else {
            return nil
        }
        return ResolvedPlace(coordinate: coordinate, name: PlaceQuery.shortName(text),
                             confidence: PlaceQuery.looksLikeAddress(text) ? .address : .guessed,
                             savedMode: nil)
    }

    /// Places a location text could mean, most likely first (`PlaceCandidate.ranked`):
    /// businesses and landmarks as well as addresses, searched around `near` so "Chelsea" offers
    /// the gym down the road rather than a town in England. The event's title adds a hint —
    /// "Lap Swim" searches "Chelsea pool" too — because a neighbourhood name on its own finds
    /// only the neighbourhood. Feeds the place picker.
    ///
    /// `useModel: false` answers at once from the keyword table (and any model answer already
    /// remembered); `true` waits for Apple Intelligence. The picker asks for the first, then the
    /// second, and shows each as it lands.
    func candidates(for text: String, eventTitle: String? = nil, useModel: Bool = true,
                    near: CLLocationCoordinate2D, limit: Int = 12) async -> [PlaceCandidate] {
        // What kind of place, from Apple Intelligence reading the event; the keyword table where
        // no model is available. "Lap Swim" → "swimming pool", "recreation center".
        let keywordHints = eventTitle.map(PlaceQuery.activityHints(forTitle:)) ?? []
        let modelHints: [String]?
        if let eventTitle {
            modelHints = useModel
                ? await PlaceHintModel.terms(title: eventTitle, location: text)
                : PlaceHintModel.cachedTerms(title: eventTitle, location: text)
        } else {
            modelHints = nil
        }
        let hints = PlaceSearchHints.merge(model: modelHints, keywords: keywordHints, location: text)
        if !hints.isEmpty {
            Log.travel.notice("[travel] searching \(text, privacy: .public) with \(hints.joined(separator: ", "), privacy: .public) (\(modelHints == nil ? "keywords" : "Apple Intelligence", privacy: .public))")
        }
        var queries = [text] + hints.map { "\(text) \($0)" }
        queries = queries.filter { !$0.isEmpty }
        let origin = CLLocation(latitude: near.latitude, longitude: near.longitude)
        var found: [PlaceCandidate] = []
        for query in queries {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            request.resultTypes = [.pointOfInterest, .address]
            request.region = MKCoordinateRegion(center: near, latitudinalMeters: 30_000, longitudinalMeters: 30_000)
            request.regionPriority = .required
            guard let response = try? await MKLocalSearch(request: request).start() else { continue }
            found += response.mapItems.map { item in
                let c = item.location.coordinate
                return PlaceCandidate(
                    name: item.name ?? PlaceQuery.shortName(text),
                    subtitle: item.address?.shortAddress,
                    latitude: c.latitude, longitude: c.longitude,
                    distanceMeters: origin.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude)),
                    isPointOfInterest: item.pointOfInterestCategory != nil)
            }
        }
        return Array(PlaceCandidate.ranked(found, for: text).prefix(limit))
    }

    /// The ETA to arrive at `meeting` by its start, the resolved destination (multi-stop
    /// blocking needs it so an address-only meeting becomes the next trip's origin without
    /// another geocode), and what the block should say. The mode is chosen per trip
    /// (`TravelModePolicy`): a saved place's mode, a walk for a short hop, else your default.
    func estimate(to meeting: MeetingInfo,
                  from origin: CLLocationCoordinate2D,
                  settings: SmartScheduleSettings) async -> Estimate? {
        guard meeting.hasPhysicalLocation,
              let place = await resolvePlace(for: meeting, near: origin, saved: settings.savedPlaces)
        else { return nil }
        let destination = place.coordinate
        let metres = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
            .distance(from: CLLocation(latitude: destination.latitude, longitude: destination.longitude))
        let mode = TravelModePolicy.mode(savedMode: place.savedMode, distanceMeters: metres, settings: settings)
        func estimate(_ mapSeconds: TimeInterval) -> Estimate {
            // What your own trips taught, when learning is on: your usual time to this place from
            // home, or Apple Maps' estimate at your pace. The summary syncs, so the Mac agrees.
            var seconds = mapSeconds
            var basis: String?
            if settings.learnFromTrips {
                let fromHome = settings.hasHome
                    && TripLearning.distance(origin, .init(latitude: settings.homeLatitude ?? 0,
                                                            longitude: settings.homeLongitude ?? 0)) < 300
                let key = fromHome ? TripLearning.nearestPlaceKey(to: destination, in: settings.learnedTravel) : nil
                let learned = TripLearning.adjusted(mapSeconds, mode: mode, placeKey: key, learned: settings.learnedTravel)
                seconds = learned.seconds
                switch learned.source {
                case .observed(let n): basis = "Usually \(Int((seconds / 60).rounded())) min, from \(n) trips"
                case .paced(let f): basis = "At your pace (\(String(format: "%.2g", f))\u{00D7} Apple Maps)"
                case .estimate: basis = nil
                }
            }
            var detail = TravelLegDetail(
                mode: mode, minutes: max(1, Int((seconds / 60).rounded(.up))),
                placeName: place.name,
                query: meeting.address,
                confidence: place.confidence,
                latitude: destination.latitude, longitude: destination.longitude)
            detail.basis = basis
            Self.log(meeting.title, at: meeting.start, detail, seconds: seconds, metres: metres)
            return Estimate(duration: seconds, destination: destination, detail: detail)
        }

        // Cache key: destination + arrival quarter-hour + mode.
        let key = "\(round(origin.latitude * 1e4)),\(round(origin.longitude * 1e4))->"
            + "\(round(destination.latitude * 1e4)),\(round(destination.longitude * 1e4))-"
            + "\(Int(meeting.start.timeIntervalSince1970 / 900))-\(mode.rawValue)"
        if let hit = cache[key], Date().timeIntervalSince(hit.at) < 3600 {
            return estimate(hit.time)
        }

        let request = MKDirections.Request()
        request.source = MKMapItem(location: CLLocation(latitude: origin.latitude, longitude: origin.longitude), address: nil)
        request.destination = MKMapItem(location: CLLocation(latitude: destination.latitude, longitude: destination.longitude), address: nil)
        request.transportType = mode.directionsType
        request.arrivalDate = meeting.start

        do {
            let eta = try await MKDirections(request: request).calculateETA()
            cache[key] = (eta.expectedTravelTime, Date())
            pruneRoutes()
            return estimate(eta.expectedTravelTime)
        } catch {
            Log.travel.notice("[travel] no route to \(meeting.title, privacy: .public) by \(mode.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil   // offline / no route / rate-limited → caller falls back to prep-only
        }
    }

    /// Every estimate, once per distinct answer, at a level the system keeps — so a wrong trip
    /// can be traced to its inputs (where it went, how sure, which mode) after the fact. The
    /// "Chelsea" trip could not be diagnosed from the phone because none of this was recorded.
    private static var lastLogged: [String: String] = [:]
    private static func log(_ title: String, at start: Date, _ detail: TravelLegDetail,
                            seconds: TimeInterval, metres: Double) {
        let line = "\(detail.mode.rawValue) \(Int(seconds))s \(Int(metres))m → \(detail.placeName ?? "?") (\(detail.confidence.rawValue))"
        let key = "\(title)|\(Int(start.timeIntervalSince1970))"   // one per event, so recurring ones don't alternate
        guard lastLogged[key] != line else { return }
        if lastLogged.count > 500 { lastLogged.removeAll() }
        lastLogged[key] = line
        Log.travel.notice("[travel] \(title, privacy: .public): \(line, privacy: .public)")
        DiagnosticJournal.shared.record(
            operation: "travel.estimate", name: title,
            attributes: ["mode": detail.mode.rawValue, "seconds": "\(Int(seconds))",
                         "metres": "\(Int(metres))", "place": detail.placeName ?? "",
                         "confidence": detail.confidence.rawValue, "query": detail.query ?? ""])
    }

    /// Ground travel time between two coordinates — for the flight legs (home → departure airport,
    /// arrival airport → hotel). `arriveBy` biases the estimate for traffic when known (the
    /// departure leg); the arrival leg leaves it nil (you go when you land). Same cache + rate-limit
    /// discipline as `travelTime`.
    ///
    /// `departAt` times a trip by when you leave (the way home after a meeting), which is when
    /// the traffic and the train timetable actually apply.
    func groundTime(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D,
                    arriveBy: Date?, departAt: Date? = nil, mode: TransitMode) async -> TimeInterval? {
        let arrivalBucket = arriveBy.map { Int($0.timeIntervalSince1970 / 900) } ?? 0
        let departureBucket = departAt.map { Int($0.timeIntervalSince1970 / 900) } ?? 0
        let key = "g:\(round(from.latitude * 1e3)),\(round(from.longitude * 1e3))->"
            + "\(round(to.latitude * 1e3)),\(round(to.longitude * 1e3))-"
            + "\(arrivalBucket)-\(departureBucket)-\(mode.rawValue)"
        if let hit = cache[key], Date().timeIntervalSince(hit.at) < 3600 { return hit.time }

        let request = MKDirections.Request()
        request.source = MKMapItem(location: CLLocation(latitude: from.latitude, longitude: from.longitude), address: nil)
        request.destination = MKMapItem(location: CLLocation(latitude: to.latitude, longitude: to.longitude), address: nil)
        request.transportType = mode.directionsType
        if let arriveBy {
            request.arrivalDate = arriveBy
        } else if let departAt {
            request.departureDate = departAt
        }
        do {
            let eta = try await MKDirections(request: request).calculateETA()
            cache[key] = (eta.expectedTravelTime, Date())
            pruneRoutes()
            return eta.expectedTravelTime
        } catch {
            return nil
        }
    }

    /// Resolve a calendar event's location text, biased to the area you actually live in.
    ///
    /// This used to call MKGeocodingRequest with nothing to anchor it, so a location that is a
    /// business name rather than a street address resolved against the whole planet: "Equinox"
    /// returns a mountain in Vermont, 4,157 km from Los Altos. A wrong-but-plausible match yields
    /// a wrong ETA with nothing in the UI to suggest the destination was ever in doubt.
    ///
    /// `near` is the trip's origin, so results are ranked around where the journey starts.
    func geocode(_ address: String, near: CLLocationCoordinate2D? = nil) async -> CLLocationCoordinate2D? {
        guard let request = MKGeocodingRequest(addressString: address) else { return nil }
        guard let items = try? await request.mapItems, !items.isEmpty else { return nil }
        guard let near else { return items.first?.location.coordinate }

        // Prefer the nearest plausible match, and refuse absurd ones outright: a calendar event
        // you are travelling to is not on another continent, and silently routing to one produces
        // either a nonsense ETA or no route at all.
        let origin = CLLocation(latitude: near.latitude, longitude: near.longitude)
        let ranked = items
            .map { ($0, origin.distance(from: CLLocation(latitude: $0.location.coordinate.latitude,
                                                         longitude: $0.location.coordinate.longitude))) }
            .sorted { $0.1 < $1.1 }
        guard let (best, metres) = ranked.first, metres < 300_000 else { return nil }
        return best.location.coordinate
    }

    private func pruneRoutes() {
        let cutoff = Date().addingTimeInterval(-3600)
        cache = cache.filter { $0.value.at >= cutoff }
        if cache.count > Self.maxRoutes {
            for key in cache.sorted(by: { $0.value.at < $1.value.at })
                .prefix(cache.count - Self.maxRoutes).map(\.key) {
                cache[key] = nil
            }
        }
    }

    private func pruneGeocodes() {
        if geocodeCache.count > Self.maxGeocodes {
            for key in geocodeCache.sorted(by: { $0.value.at < $1.value.at })
                .prefix(geocodeCache.count - Self.maxGeocodes).map(\.key) {
                geocodeCache[key] = nil
            }
        }
    }
}

/// One-shot current-location fetch, used to set "home".
@MainActor
final class OneShotLocation: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?

    func current(timeout seconds: Double = 15) async -> CLLocation? {
        manager.delegate = self
        return await withCheckedContinuation { cont in
            self.continuation = cont
            // Without a deadline this waits forever when the authorization prompt never
            // surfaces or a desktop Mac can't produce a Wi-Fi fix — the caller's spinner
            // then spins for good. Resume is idempotent, so a late fix is safely dropped.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                self?.resume(nil)   // same actor as the delegate resumes — no race
            }
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways: manager.requestLocation()
            case .notDetermined: manager.requestWhenInUseAuthorization()   // resumes via didChange
            default: resume(nil)
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways: manager.requestLocation()
            case .denied, .restricted: resume(nil)
            default: break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in resume(locations.first) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in resume(nil) }
    }

    private func resume(_ location: CLLocation?) {
        continuation?.resume(returning: location)
        continuation = nil
    }
}

