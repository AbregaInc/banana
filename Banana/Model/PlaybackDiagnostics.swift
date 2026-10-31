import Foundation
import AVFoundation

/// A persistent, bounded journal of everything that starts or stops audio.
///
/// Playback dying mid-walk is only ever reported after the fact, from memory, with the phone
/// back in a pocket — and the interesting moment (a stall, an interruption, a route change, a
/// message from the Watch) happens while the screen is off and no debugger is attached. So every
/// event that can move the player is written to a file that survives the app being suspended,
/// killed or relaunched. When playback stops unexpectedly, the last few lines say why instead of
/// leaving us to guess. Ships in release builds: it's a few hundred bytes and it's the only
/// evidence we get.
final class PlaybackDiagnostics: @unchecked Sendable {
    static let shared = PlaybackDiagnostics()

    private let queue = DispatchQueue(label: "com.boris.banana.playbacklog", qos: .utility)
    // A minute-level power line plus playback heartbeats is still only hundreds of bytes per
    // minute. 512 KB retains many hours of evidence while remaining trivial next to one episode.
    private let maxBytes = 512 * 1024

    static var logURL: URL? {
        // On macOS `.documentDirectory` is the person's real ~/Documents folder, which triggers
        // TCC every time this always-on journal records a launch/background/playback event. This
        // is app-private diagnostic state, so it belongs beside the rest of Banana's local data.
        AppSupport.directory.appendingPathComponent("playback.log")
    }

    private lazy var stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// Record one event. `detail` should carry the numbers that make the line self-explanatory
    /// a week later (positions, error codes, route names) — not just a category.
    func log(_ event: String, _ detail: String = "") {
        let at = Date()
        // DateFormatter is not Sendable/thread-safe. It and the file now remain on the same serial
        // utility lane, and callers no longer pay timestamp-formatting work on the audio/main path.
        queue.async { [weak self] in
            guard let self else { return }
            let line = "\(self.stamp.string(from: at))  \(event)\(detail.isEmpty ? "" : "  \(detail)")\n"
            self.append(line)
        }
        Log.wake.notice("playback: \(event, privacy: .public) \(detail, privacy: .public)")
    }

    private func append(_ line: String) {
        guard let url = Self.logURL, let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
        trimIfNeeded(url)
    }

    /// Bound the file: once it passes the cap, keep the most recent half.
    private func trimIfNeeded(_ url: URL) {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
              size > maxBytes,
              let data = try? Data(contentsOf: url) else { return }
        let tail = data.suffix(maxBytes / 2)
        // Don't start the kept tail mid-line.
        let start = tail.firstIndex(of: 0x0A).map { tail.index(after: $0) } ?? tail.startIndex
        try? Data(tail[start...]).write(to: url)
    }

    /// The whole journal, for the diagnostics screen / a bug report.
    func read() -> String {
        guard let url = Self.logURL, let data = try? Data(contentsOf: url) else { return "(no playback log yet)" }
        return String(data: data, encoding: .utf8) ?? "(unreadable)"
    }

    struct LogSnapshot: Sendable {
        let recentLines: [String]
        let totalLineCount: Int
        let fullText: String
    }

    /// Read and split the journal on the same utility queue that writes it. The diagnostics screen
    /// used to synchronously read the file on the main actor and render the whole 512 KB journal as
    /// one selectable Text value. That made opening it stall on iPhone, Watch, and Mac. Keep the
    /// full text available for Copy, but only hand the latest bounded set of lines to SwiftUI.
    func snapshot(maxVisibleLines: Int = 250) async -> LogSnapshot {
        await withCheckedContinuation { continuation in
            queue.async {
                let text: String
                if let url = Self.logURL,
                   let data = try? Data(contentsOf: url),
                   let decoded = String(data: data, encoding: .utf8) {
                    text = decoded
                } else {
                    text = ""
                }
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                    .map(String.init)
                continuation.resume(returning: LogSnapshot(
                    recentLines: Array(lines.suffix(maxVisibleLines)),
                    totalLineCount: lines.count,
                    fullText: text))
            }
        }
    }

    func clear() {
        guard let url = Self.logURL else { return }
        queue.async { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Did we die?

    private static let aliveKey = "playbackAlive"          // set while playing, cleared on a clean stop
    private static let aliveDetailKey = "playbackAliveAt"
    private static let alivePodcastKey = "playbackAlivePodcastID"
    private static let aliveEpisodeKey = "playbackAliveEpisodeID"
    private static let alivePositionKey = "playbackAlivePosition"
    private static let aliveRecordKey = "playbackAliveRecordV2"

    private struct AliveRecord: Codable {
        var podcastID: UUID?
        var episodeID: String?
        var position: Double
        var episode: String
        var updatedAt: Date
    }

    struct InterruptedPlayback {
        let podcastID: UUID?
        let episodeID: String?
        let position: Double
    }

    /// Called from the playback heartbeat. Leaves a breadcrumb outside our own process state, so
    /// it survives the process not existing any more.
    func noteAlive(playing: Bool, at position: Double, episode: String,
                   podcastID: UUID? = nil, episodeID: String? = nil) {
        let d = UserDefaults.standard
        if playing {
            // This heartbeat runs every 30 seconds. Five separate UserDefaults mutations here
            // caused five preference-daemon messages per beat; one tiny record has identical
            // recovery semantics with one mutation.
            let record = AliveRecord(
                podcastID: podcastID,
                episodeID: episodeID,
                position: position,
                episode: episode,
                updatedAt: Date())
            if let data = try? JSONEncoder().encode(record) {
                d.set(data, forKey: Self.aliveRecordKey)
            }
            if d.object(forKey: Self.aliveKey) != nil { Self.clearLegacyAliveRecord(d) }
        } else {
            d.removeObject(forKey: Self.aliveRecordKey)
            Self.clearLegacyAliveRecord(d)
        }
    }

    /// Consume the crash/install breadcrumb once the library has loaded. Consumption is deliberate:
    /// if the referenced feed or episode was deleted, repeatedly trying on every launch cannot help.
    func takeInterruptedPlayback() -> InterruptedPlayback? {
        let d = UserDefaults.standard
        defer {
            d.removeObject(forKey: Self.aliveRecordKey)
            Self.clearLegacyAliveRecord(d)
        }
        if let record = Self.aliveRecord(d) {
            return InterruptedPlayback(
                podcastID: record.podcastID,
                episodeID: record.episodeID,
                position: record.position)
        }
        guard d.bool(forKey: Self.aliveKey) else { return nil }
        let podcastID = d.string(forKey: Self.alivePodcastKey).flatMap(UUID.init(uuidString:))
        return InterruptedPlayback(
            podcastID: podcastID,
            episodeID: d.string(forKey: Self.aliveEpisodeKey),
            position: d.double(forKey: Self.alivePositionKey))
    }

    /// Called once at launch. If the last run was still playing when the process ended — and never
    /// recorded a pause or a stop — then it did not stop, it *was stopped*: a crash, or iOS killing
    /// us for memory. That is the single most likely cause of "it played for a few minutes and then
    /// stopped", and it is precisely the one a log of our own actions can never show, because the
    /// whole point is that we never got to act.
    func noteLaunch() {
        let d = UserDefaults.standard
        let record = Self.aliveRecord(d)
        let diedPlaying = record != nil || d.bool(forKey: Self.aliveKey)
        let detail = record.map { "\"\($0.episode)\" at \(Int($0.position))s" }
            ?? d.string(forKey: Self.aliveDetailKey)
            ?? "?"

        if diedPlaying {
            log("⚠️ PREVIOUS RUN DIED WHILE PLAYING", "\(detail) — no pause/stop was recorded, so the app was killed (crash or out of memory), not paused")
        }
        log("launch", "app started")
    }

    private static func aliveRecord(_ defaults: UserDefaults) -> AliveRecord? {
        guard let data = defaults.data(forKey: aliveRecordKey) else { return nil }
        return try? JSONDecoder().decode(AliveRecord.self, from: data)
    }

    private static func clearLegacyAliveRecord(_ defaults: UserDefaults) {
        guard defaults.object(forKey: aliveKey) != nil
                || defaults.object(forKey: aliveDetailKey) != nil
                || defaults.object(forKey: alivePodcastKey) != nil
                || defaults.object(forKey: aliveEpisodeKey) != nil
                || defaults.object(forKey: alivePositionKey) != nil else { return }
        defaults.removeObject(forKey: aliveKey)
        defaults.removeObject(forKey: aliveDetailKey)
        defaults.removeObject(forKey: alivePodcastKey)
        defaults.removeObject(forKey: aliveEpisodeKey)
        defaults.removeObject(forKey: alivePositionKey)
    }

    // MARK: - Session state, rendered for a human

    /// A one-line snapshot of the audio session, so a stop line carries the context that
    /// explains it (was the session even active? what were we routed to?).
    static func sessionSummary() -> String {
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        let route = s.currentRoute.outputs.map { "\($0.portType.rawValue)" }.joined(separator: ",")
        return "route=[\(route.isEmpty ? "none" : route)] other=\(s.isOtherAudioPlaying)"
        #else
        // macOS has no AVAudioSession: routing, interruptions and ducking are the system's problem,
        // not the app's. There is nothing to summarise.
        return "route=[system]"
        #endif
    }
}
