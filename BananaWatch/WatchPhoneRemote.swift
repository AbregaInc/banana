import Foundation
import WatchConnectivity

/// Mirrors the iPhone's now-playing state and sends transport commands back, so the
/// Watch can control audio that's playing ON THE PHONE (e.g. during a run) — kept in
/// sync via applicationContext (state) + sendMessage (commands).
@MainActor
final class WatchPhoneRemote: ObservableObject {
    static let shared = WatchPhoneRemote()

    @Published private(set) var isActive = false
    @Published private(set) var title = ""
    @Published private(set) var podcast = ""
    @Published private(set) var isPlaying = false
    /// The speed the phone is playing at.
    @Published private(set) var speed: Double = 1
    @Published private(set) var isRecordingNote = false   // a note being recorded ON THE PHONE

    /// Apply the phone's latest state from an applicationContext push.
    func update(from context: [String: Any]) {
        // Guarded on change, like WatchEpisodeStore's fields in the same apply(context:) —
        // every phone play/pause/episode-switch/settings/plan/calendar push otherwise
        // republishes objectWillChange to the now-playing remote UI for no actual change.
        if let rec = context["noteRecording"] as? Bool, rec != isRecordingNote {
            isRecordingNote = rec   // may arrive alone
        }
        guard let active = context["npActive"] as? Bool else { return }   // ignore workout-only pushes
        if active != isActive { isActive = active }
        let newTitle = context["npTitle"] as? String ?? ""
        if newTitle != title { title = newTitle }
        let newPodcast = context["npPodcast"] as? String ?? ""
        if newPodcast != podcast { podcast = newPodcast }
        let newPlaying = context["npPlaying"] as? Bool ?? false
        if newPlaying != isPlaying { isPlaying = newPlaying }
        let newSpeed = context["npSpeed"] as? Double ?? 1
        if newSpeed != speed { speed = newSpeed }
    }

    /// The next speed up for what the phone is playing (every speed the phone offers: it is
    /// the phone that plays). Shown at once; the phone's next push confirms it.
    func cycleSpeed() {
        let next = PlaybackSpeeds.next(after: speed)
        guard WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(["cmd": "speed", "speed": next], replyHandler: nil, errorHandler: nil)
        speed = next
    }

    #if DEBUG
    func debugSeedNowPlaying() {
        isActive = true
        title = "How to Build a Better Week Without Burning Out"
        podcast = "The Knowledge Project"
        isPlaying = true
    }
    #endif

    /// Send a transport command to the phone (immediate; needs the phone reachable).
    @discardableResult
    func send(_ command: String, parent: DiagnosticTraceContext? = nil) -> Bool {
        guard WCSession.default.isReachable else { return false }
        var message: [String: Any] = ["cmd": command]
        if let parent { message["traceparent"] = parent.traceparent }
        WCSession.default.sendMessage(message, replyHandler: nil, errorHandler: nil)
        return true
    }
}
