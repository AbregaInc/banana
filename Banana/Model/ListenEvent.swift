import Foundation
import CoreLocation

/// Split out from ListenHistory.swift — same reasoning as `Podcast.swift`/`VoiceNote.swift`: the
/// pure, storage-shaped model lives separately from its store (`ListenHistoryStore`, which pulls
/// in `CloudBackup`'s CloudKit/`FitnessStore` dependency chain via `save()`'s
/// `CloudBackup.shared.schedule()`), so BananaTests can exercise the decode-and-quarantine
/// behavior of `listen_history.json` — every listen ever recorded, unbounded, feeding the Listen
/// Map's GPS routes — without dragging that chain in.
struct ListenRoutePoint: Codable, Hashable, Sendable {
    var lat: Double
    var lon: Double
    var date: Date

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

/// One continuous play interval. `date`/`endedAt` bound the session, while `route`
/// describes where that interval happened when the user opted into location history.
struct ListenEvent: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var date: Date = .distantPast
    var endedAt: Date?
    var podcastID: UUID?
    var episodeID: String?
    var podcastTitle: String = ""
    var episodeTitle: String = ""
    var artworkURL: URL?
    var lat: Double?
    var lon: Double?
    var place: String?
    var route: [ListenRoutePoint] = []
    /// Number of points retained in the sidecar. Routes are loaded only when a map asks for
    /// them; this keeps years of GPS traces off the first-launch and ordinary list path.
    var routePointCount: Int = 0

    var coordinate: CLLocationCoordinate2D? {
        if let first = route.first { return first.coordinate }
        guard let lat, let lon else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    var duration: TimeInterval {
        max(0, (endedAt ?? date).timeIntervalSince(date))
    }
}

extension ListenEvent {
    /// Tolerant decoder so saved history survives added fields. Nothing here is required: even a
    /// listen with no podcast/episode identity still marks a moment someone was listening to
    /// *something*, which the Listen Map/list already render gracefully as blank titles — dropping
    /// the whole record over one bad field would lose the date and (if present) the location too.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? .distantPast
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        podcastID = try c.decodeIfPresent(UUID.self, forKey: .podcastID)
        episodeID = try c.decodeIfPresent(String.self, forKey: .episodeID)
        podcastTitle = try c.decodeIfPresent(String.self, forKey: .podcastTitle) ?? ""
        episodeTitle = try c.decodeIfPresent(String.self, forKey: .episodeTitle) ?? ""
        artworkURL = try c.decodeIfPresent(URL.self, forKey: .artworkURL)
        lat = try c.decodeIfPresent(Double.self, forKey: .lat)
        lon = try c.decodeIfPresent(Double.self, forKey: .lon)
        place = try c.decodeIfPresent(String.self, forKey: .place)
        route = try c.decodeIfPresent([ListenRoutePoint].self, forKey: .route) ?? []
        routePointCount = try c.decodeIfPresent(Int.self, forKey: .routePointCount) ?? route.count
    }
}
