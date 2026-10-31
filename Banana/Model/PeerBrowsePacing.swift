import Foundation

/// How the nearby-device search (`PodcastPeerTransfer`'s Bonjour browse) is paced.
///
/// Stopping and restarting it in quick succession crashed the Mac (1 Oct 2026): a burst of
/// downloads after a sync started and stopped the browse once per request, and a start landing
/// before Bonjour had finished tearing the last one down made CFNetwork cancel a browser that was
/// already gone (`_BrowserCancel` → `CFRunLoopSourceInvalidate`, mismatched type). So the browse
/// lingers after the last request instead of stopping at once, and never restarts right after a
/// stop. Pure, for tests.
enum PeerBrowsePacing {
    /// How long the browse keeps running after nothing needs it — a burst of requests shares one.
    static let linger: TimeInterval = 20
    /// The least time between a stop and the next start.
    static let restartGap: TimeInterval = 2

    /// How long to wait before starting again: none, or what's left of the gap after the last stop.
    static func startDelay(now: Date, lastStopped: Date?) -> TimeInterval {
        guard let lastStopped else { return 0 }
        return max(0, restartGap - now.timeIntervalSince(lastStopped))
    }
}
