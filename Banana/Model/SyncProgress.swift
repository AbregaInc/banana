import Combine
import Foundation

/// The kinds of data that sync between devices, as the person thinks of them.
enum SyncDomain: String, CaseIterable, Sendable {
    /// Workouts, their recordings, voice notes, and the phone's Health snapshot (steps, sleep).
    case fitness
    case wellness
    case progress
    case controls
    /// The meal backlog: photos and words waiting to be logged (`ControlChannel.meals`).
    case meals

    var title: String {
        switch self {
        case .fitness: "Workouts & Health"
        case .wellness: "Meals & supplements"
        case .progress: "Listening progress"
        case .controls: "Library, history & settings"
        case .meals: "Meals to log"
        }
    }

    /// For "Getting your … from iCloud".
    var noun: String {
        switch self {
        case .fitness: "workouts and Health data"
        case .wellness: "meals and supplements"
        case .progress: "listening progress"
        case .controls: "library, history and settings"
        case .meals: "meals to log"
        }
    }
}

/// What one kind of data is doing: downloading, how much has come so far, when it last finished.
///
/// A device that has never finished a first download says so, instead of showing an empty page
/// that looks like there's nothing — a new iPad's Workouts page sat blank for minutes while
/// hundreds of recordings came in. Pure, so the wording is tested (`SyncActivityTests`).
struct SyncActivity: Equatable, Sendable {
    /// Whether this sync runs on this device at all (not in the Simulator, not without iCloud).
    var running = false
    var fetching = false
    var receivedThisFetch = 0
    /// When a download last finished on this device; nil until the first one does.
    var lastFetched: Date?
    var error: String?

    var awaitingFirst: Bool { lastFetched == nil }

    mutating func willFetch() {
        fetching = true
        receivedThisFetch = 0
    }

    mutating func received(_ count: Int) {
        receivedThisFetch += count
    }

    mutating func didFetch(at now: Date) {
        fetching = false
        lastFetched = now
        error = nil
    }

    mutating func failed(_ message: String) {
        fetching = false
        error = message
    }

    /// The line at the top of a page whose data hasn't finished arriving yet; nil once it has.
    func waitingLine(_ domain: SyncDomain) -> String? {
        guard running, awaitingFirst else { return nil }
        if let error { return "Couldn\u{2019}t get your \(domain.noun) from iCloud \u{2014} \(error)" }
        guard receivedThisFetch > 0 else { return "Getting your \(domain.noun) from iCloud\u{2026}" }
        return "Getting your \(domain.noun) from iCloud\u{2026} \(receivedThisFetch) so far"
    }

    /// The value on its row in Settings › iCloud.
    func statusLine(now: Date = Date()) -> String {
        guard running else { return "Off on this device" }
        if let error { return "Couldn\u{2019}t sync \u{2014} \(error)" }
        if fetching {
            return receivedThisFetch > 0 ? "Downloading\u{2026} \(receivedThisFetch) so far" : "Checking\u{2026}"
        }
        guard let lastFetched else { return "Not synced yet" }
        if now.timeIntervalSince(lastFetched) < 60 { return "Up to date" }
        return "Up to date \u{00B7} \(lastFetched.formatted(.relative(presentation: .named)))"
    }
}

/// Every sync's activity, for the pages and Settings. Each CloudKit engine reports into it.
@MainActor
final class SyncProgress: ObservableObject {
    static let shared = SyncProgress()

    @Published private(set) var activity: [SyncDomain: SyncActivity] = [:]

    private static func key(_ domain: SyncDomain) -> String { "syncLastFetched_\(domain.rawValue)" }

    private init() {
        for domain in SyncDomain.allCases {
            var start = SyncActivity()
            start.lastFetched = UserDefaults.standard.object(forKey: Self.key(domain)) as? Date
            activity[domain] = start
        }
    }

    subscript(domain: SyncDomain) -> SyncActivity { activity[domain] ?? SyncActivity() }

    /// The sync has started on this device.
    func started(_ domain: SyncDomain) { update(domain) { $0.running = true } }

    func willFetch(_ domain: SyncDomain) { update(domain) { $0.willFetch() } }

    func received(_ domain: SyncDomain, count: Int) {
        guard count > 0 else { return }
        update(domain) { $0.received(count) }
    }

    func didFetch(_ domain: SyncDomain) {
        let now = Date()
        UserDefaults.standard.set(now, forKey: Self.key(domain))
        update(domain) { $0.didFetch(at: now) }
    }

    func failed(_ domain: SyncDomain, _ message: String) { update(domain) { $0.failed(message) } }

    private func update(_ domain: SyncDomain, _ change: (inout SyncActivity) -> Void) {
        var next = self[domain]
        change(&next)
        if next != activity[domain] { activity[domain] = next }
    }
}
