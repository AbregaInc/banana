import Foundation

#if STRESS_DEVICE_AUDIT && !DEBUG
#error("STRESS_DEVICE_AUDIT requires DEBUG fixture and provider-write guards")
#endif

/// Launch validation for the separately signed physical-device workload app.
/// This does not select a Calendar renderer or affect ordinary app builds.
enum PhysicalStressReview {
    static let bundleIdentifier = "com.boris.banana.stressreview"

    static func permits(arguments: [String], bundleID: String?) -> Bool {
        guard bundleID == bundleIdentifier,
              arguments.contains("--disable-icloud"),
              arguments.contains("--plan") != arguments.contains("--mail"),
              arguments.contains("--stress-actionable-calendar"),
              let index = arguments.firstIndex(of: "--stress-days"),
              arguments.indices.contains(index + 1),
              let days = Int(arguments[index + 1]), (1...365).contains(days) else { return false }
        // Other audit routes must not bypass the guarded fixture startup path.
        return !arguments.contains("--day-real-calendar")
            && !arguments.contains("--verify-timeline")
            && !arguments.contains("--occurrences")
    }

    static func requireValidLaunch() {
        precondition(permits(arguments: ProcessInfo.processInfo.arguments,
                             bundleID: Bundle.main.bundleIdentifier),
                     "Physical stress review requires its isolated app identity and guarded fixture launch")
    }
}
