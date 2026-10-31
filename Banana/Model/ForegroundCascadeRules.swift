import SwiftUI

/// What coming to `.active` should run, so a glance at Control Center is not a return from the
/// background.
///
/// `inactive → active` happens for the notification shade, Control Center, a permission alert and
/// the app switcher as well as for coming back from another app — and the process never left
/// memory for the first four. The return-to-foreground cascade (a CloudKit poll and flush, the
/// Google refresh, the synced account store, a plan recompute, the feed sweep) answers "what did I
/// miss while I was away", which only a trip through `.background` can have made a question. Run
/// on every glance it cost four or more CloudKit round trips each, and a volume change from
/// Control Center in the middle of an episode spent CloudKit it had no reason to.
///
/// Two halves, split by what they protect:
/// - Every activation: re-reading what the person can change outside the app — permissions and
///   onboarding state. A permission alert returns through `inactive → active` and nothing else
///   says the grant moved, so "permission granted but the card still says not connected" is what
///   skipping this brings back.
/// - Only after `.background`: everything that talks to CloudKit, Google, the synced account store
///   or a feed, or recomputes in order to fetch. Nothing in it stopped while the app was merely
///   inactive, and the poll and the change notifications cover the glance.
///
/// A launch counts as a return: the first activation of a process runs everything, as it always
/// has.
struct ForegroundCascadeRules: Equatable {
    /// Whether the next activation is a real return rather than a glance. True until the first
    /// activation has run, and again after every `.background`.
    private(set) var cameFromBackground = true

    enum Plan: Equatable {
        /// `.inactive`: still on screen, so there is nothing to stop and nothing to run.
        case none
        /// `.background`: nobody can see the app. The change poll stops here (below).
        case background
        /// Back to `.active` without having left: only the every-activation half.
        case glance
        /// Back to `.active` from the background, or the first activation of the process: both halves.
        case fullReturn

        /// Permission and onboarding re-reads — every activation, never skipped.
        var rereadsPermissions: Bool { self == .glance || self == .fullReturn }
        /// CloudKit, Google, the account store, feeds, the fetching recompute — only a real return.
        var runsNetworkAndSync: Bool { self == .fullReturn }

        /// The Google change poll stops when the app goes to the background: background audio keeps
        /// this process alive for hours, and the poll woke it every two minutes to skip its own
        /// work. It starts again on every activation (a no-op unless it was stopped), so it is
        /// never left off. The badge recount is deliberately not stopped with it: it is the only
        /// writer of the icon badge, whose count moves with the clock and with data it reads
        /// without observing.
        var stopsPolling: Bool { self == .background }
    }

    /// Feed it each scene-phase change, in order; it says what that change runs.
    ///
    /// `previous == .background` counts too, though the flag normally already says so: if a
    /// `.background` change were ever coalesced away, a real return must still not be taken for a
    /// glance.
    mutating func phaseChanged(from previous: ScenePhase, to phase: ScenePhase) -> Plan {
        switch phase {
        case .background:
            cameFromBackground = true
            return .background
        case .active:
            let returning = cameFromBackground || previous == .background
            cameFromBackground = false
            return returning ? .fullReturn : .glance
        case .inactive:
            return .none   // neither a return nor a departure: remembers what it was
        @unknown default:
            return .none
        }
    }
}
