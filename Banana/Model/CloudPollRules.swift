import Foundation

/// The rules that keep a change made on another device from being skipped. Pure, for tests.
///
/// Each minute one request asks iCloud which zones changed (`CloudChangeCheck`), and the answer
/// names a zone once: in the first answer after it changed. So a zone that is named and then not
/// fetched — its sync hadn't started, the fetch failed, the app left the front mid-read — would
/// stay unfetched until it changed again. On 8 Oct 2026 a workout trimmed on the iPad was skipped
/// by the Mac that way: the first question after launch was asked two seconds before the workout
/// sync started, and nothing else changed in that zone for hours.
///
/// The invariant: a zone named in an answer stays owed until a fetch of it reads to the end.
enum CloudPollRules {
    /// Whether the question may be asked now. Not before every sync that acts on the answer has
    /// started: asking uses the answer up.
    static func mayAsk(allowed: Bool, syncsStarted: Bool, checking: Bool) -> Bool {
        allowed && syncsStarted && !checking
    }

    /// How a fetch of a zone ended.
    enum Outcome { case readToTheEnd, moreToCome, failed, notRun }

    /// Whether the zone is caught up after it. Anything else is owed: the next check fetches it
    /// whether or not the zone is named again (`fetches`).
    static func caughtUp(after outcome: Outcome) -> Bool { outcome == .readToTheEnd }

    /// Whether a zone's sync fetches after an answer: the zone was named (a nil answer, when the
    /// question couldn't be asked, names every zone), or a fetch of it is still owed.
    static func fetches(zone: String, changed: Set<String>?, caughtUp: Bool) -> Bool {
        (changed.map { $0.contains(zone) } ?? true) || !caughtUp
    }
}
