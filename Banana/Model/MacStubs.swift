#if os(macOS)
import Foundation
import SwiftUI
import AppKit

/// Mac-side stand-ins for the two stores that are pure phone hardware.
///
/// The alternative was to fork the views — `#if os(iOS)` scattered through `TodayView` wherever it
/// touches an alarm or the Watch — and that is how one codebase quietly becomes two: the scheduler
/// changes on the phone and doesn't on the Mac, and nobody notices for a month. Instead the *shape*
/// of the app is the same on both platforms and the platform difference is confined to here.
///
/// These are honest no-ops, not fake features. A Mac cannot ring you awake through silent mode, and
/// it has no Watch to hand playback to. Both of those are the phone's job, and the Mac's job is
/// showing you your day — which is the part that was worth porting.

// MARK: - Alarms (AlarmKit is iPhone-only)

/// A Mac can't ring you awake, but the one-off alarm list is the same on every device
/// (CloudControlsSync): an alarm added here is armed by the phone, and the phone's show here.
@MainActor
final class AlarmStore: ObservableObject {
    @Published var isAuthorized = false        // a Mac can't be granted alarm authority; it has none
    @Published var isAlerting = false
    @Published private(set) var oneOffAlarms: [OneOffAlarm] = []
    @Published var errorMessage: String?

    var onOneOffChange: (() -> Void)?

    private static let oneOffKey = "oneOffAlarms"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.oneOffKey),
           let decoded = try? JSONDecoder().decode([OneOffAlarm].self, from: data) {
            oneOffAlarms = decoded.filter { $0.fire > Date() }
        }
    }

    func requestAuthorization() async {}
    func consumeRecentAlarm() -> Bool { false }

    /// Drop the ones whose time has passed. Every device does this for itself; it isn't synced.
    func pruneExpiredOneOffs() {
        let now = Date()
        guard oneOffAlarms.contains(where: { $0.fire <= now }) else { return }
        oneOffAlarms.removeAll { $0.fire <= now }
        saveOneOffs()
        onOneOffChange?()
    }

    @discardableResult
    func addOneOff(at fire: Date, label: String) async -> Bool {
        pruneExpiredOneOffs()
        guard fire > Date() else { errorMessage = "Pick a time in the future."; return false }
        let alarm = OneOffAlarm(fire: fire, label: label)
        oneOffAlarms = OneOffAlarmList.adding(alarm, to: oneOffAlarms)
        saveOneOffs()
        onOneOffChange?()
        ControlChangeReporter.changed(.alarm, alarm.id.uuidString)
        return true
    }

    @discardableResult
    func cancelOneOff(_ id: UUID) -> OneOffAlarm? {
        guard let alarm = oneOffAlarms.first(where: { $0.id == id }) else { return nil }
        oneOffAlarms.removeAll { $0.id == id }
        saveOneOffs()
        onOneOffChange?()
        ControlChangeReporter.deleted(.alarm, id.uuidString)
        return alarm
    }

    /// Brings back a cancelled alarm (Undo); the phone arms it again when it syncs.
    func restoreOneOff(_ alarm: OneOffAlarm) async -> String? {
        guard alarm.fire > Date() else { return "its time has passed" }
        oneOffAlarms = OneOffAlarmList.adding(alarm, to: oneOffAlarms)
        saveOneOffs()
        onOneOffChange?()
        ControlChangeReporter.changed(.alarm, alarm.id.uuidString)
        return nil
    }

    func cancelSmartWakes() {}
    func scheduleWakeOccurrences(_ dates: [Date]) async {}
    func suspendManual() {}
    func resumeManual() async {}

    private func saveOneOffs() {
        if let data = try? JSONEncoder().encode(oneOffAlarms) {
            UserDefaults.standard.set(data, forKey: Self.oneOffKey)
        }
    }
}

extension AlarmStore: CloudControlSource {
    func cloudItems(_ kind: ControlKind) -> [String: Data] {
        OneOffAlarmList.cloudItems(oneOffAlarms)
    }

    func applyCloud(_ kind: ControlKind, id: String, item: Data?) -> Bool {
        guard let uuid = UUID(uuidString: id) else { return true }
        let alarm = item.flatMap { try? JSONDecoder().decode(OneOffAlarm.self, from: $0) }
        if item != nil, alarm == nil { return true }
        let next = OneOffAlarmList.applying(alarm, id: uuid, to: oneOffAlarms, now: Date())
        guard next != oneOffAlarms else { return true }
        oneOffAlarms = next
        saveOneOffs()
        onOneOffChange?()
        return true
    }
}

// MARK: - The Watch link (WatchConnectivity is iPhone-only)

@MainActor
final class PhoneConnectivity: NSObject, ObservableObject {
    static let shared = PhoneConnectivity()

    @Published private(set) var episodesInFlight = 0

    weak var fitnessStore: FitnessStore?
    weak var downloads: DownloadManager?
    weak var wake: WakeStore?
    weak var library: PodcastLibrary?
    weak var player: PlayerController?
    weak var settings: AppSettings?
    weak var skipPlans: SkipPlanService?

    var isActivated: Bool { false }

    func activate() {}
    func refreshTransferCount() {}
    func syncSettings() {}
    func syncWorkoutSource() {}
    func syncWatchManifest(_ episodeIDs: [String]) {}
    func sendNowPlaying() {}
    func syncCurrentEpisode() {}
    func stopWatchPlayback() {}
    func sendListenProgress(episodeID: String, position: Double, duration: Double, completed: Bool) {}
    func sendDownloadInstruction(episodeID: String, title: String, podcast: String, url: URL,
                                 skipPlan: Data? = nil) {}
    func sendSkipPlan(episodeID: String, payload: Data) {}
    func deleteEpisode(_ episodeID: String) {}
    func sendEpisode(fileURL: URL, episodeID: String, title: String, podcast: String,
                     cleanup: Bool = false, skipPlan: Data? = nil) {}
    func sendFileFallback(_ episodeID: String) {}
}

#endif
