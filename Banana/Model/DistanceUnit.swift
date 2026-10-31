import Foundation

/// User-selectable distance unit for fitness readouts.
///
/// Split out from AppSettings.swift so it can be sourced into BananaTests (needed transitively by
/// WorkoutComparison.swift's formatters) without also pulling in AppSettings' LaunchClock/
/// CloudBackup singleton dependencies, which have their own dependency chains the test target
/// doesn't otherwise need.
enum DistanceUnit: String, Codable, CaseIterable, Identifiable {
    case kilometers, miles

    var id: String { rawValue }
    var label: String { self == .kilometers ? "Kilometers" : "Miles" }

    func format(meters: Double) -> String {
        switch self {
        case .kilometers:
            return meters >= 1000 ? String(format: "%.2f km", meters / 1000) : "\(Int(meters)) m"
        case .miles:
            let miles = meters / 1609.344
            return miles >= 0.1 ? String(format: "%.2f mi", miles) : "\(Int(meters * 3.28084)) ft"
        }
    }
}
