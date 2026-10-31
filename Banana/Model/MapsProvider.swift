import Foundation

/// The user's preferred maps app for the "Directions" button.
///
/// Split into its own file (rather than living inside MeetingLink.swift, where it originated)
/// because `AppSettings.Snapshot` needs this type to be `Codable`, and `AppSettings.swift` is
/// sourced individually into `BananaTests` — pulling in `MeetingLink.swift` there would drag its
/// `MeetingInfo`-typed `directionsURL(for:)` method along, which in turn needs
/// `CalendarService.swift`'s 1200-line EventKit-backed `MeetingInfo` type and its own dependency
/// chain. The `directionsURL(for:)` method itself stays behind in `MeetingLink.swift` as an
/// extension, where `MeetingInfo` is already in scope.
enum MapsProvider: String, Codable, CaseIterable, Identifiable {
    case apple, google
    var id: String { rawValue }
    var label: String { self == .apple ? "Apple Maps" : "Google Maps" }
}
