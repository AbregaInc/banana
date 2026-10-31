import Foundation
import SwiftUI

/// An episode audio file that was transferred to the Watch for offline playback.
struct WatchEpisode: Codable, Identifiable, Hashable {
    var id: String        // episodeID from the phone
    var title: String
    var podcast: String
    var filename: String
}

/// A single lightweight crash-safety record for the episode currently playing. Persisting this
/// tiny value once a minute is much cheaper than republishing and rewriting every saved position.
private struct WatchPlayheadCheckpoint: Codable {
    var episodeID: String
    var position: Double
    var duration: Double
    var completed: Bool
    var at: Date
}

/// Holds the episodes downloaded to the Watch. `WatchSyncManager` adds to it as
/// files arrive from the phone.
@MainActor
final class WatchEpisodeStore: ObservableObject {
    static let shared = WatchEpisodeStore()

    @Published private(set) var episodes: [WatchEpisode] = []
    @Published var workoutPodcast: String?           // legacy single (kept for compat)
    @Published var workoutPodcasts: [String] = []    // Workout-cue pool in priority order
    /// Each show's playback speed, by title, as the phone has it (only the ones off 1×). Kept
    /// across launches: the Watch often plays with the phone out of reach.
    @Published private(set) var podcastSpeeds: [String: Double] =
        UserDefaults.standard.dictionary(forKey: WatchEpisodeStore.speedsKey) as? [String: Double] ?? [:]
    private static let speedsKey = "watchPodcastSpeeds"

    /// The speed a show plays at here (`PlaybackSpeeds.onWatch`: the Watch tops out at 2×).
    func speed(forPodcast title: String) -> Double {
        PlaybackSpeeds.onWatch(podcastSpeeds[title] ?? 1)
    }

    /// The phone's list, replacing this one.
    func adoptSpeeds(_ speeds: [String: Double]) {
        guard speeds != podcastSpeeds else { return }
        podcastSpeeds = speeds
        UserDefaults.standard.set(speeds, forKey: Self.speedsKey)
    }

    /// A speed chosen on the Watch: kept here, and told to the phone so it's the show's speed
    /// everywhere.
    func setSpeed(_ speed: Double, forPodcast title: String) {
        guard !title.isEmpty else { return }
        var speeds = podcastSpeeds
        speeds[title] = abs(speed - 1) < 0.001 ? nil : speed
        adoptSpeeds(speeds)
        WatchSyncManager.sendShowSpeed(speed, podcast: title)
    }
    @Published var useMiles: Bool = (Locale.current.measurementSystem != .metric)   // synced from the phone
    /// Pool length for swim workouts, set on the phone and pushed here. Defaults to long course
    /// until the first sync lands, so a swim started before the phone has ever connected still
    /// records something sensible rather than nothing.
    /// Until the phone's setting arrives. 25 yd, not 50 m: the 50 m default silently recorded
    /// months of 25-yard swims at more than twice their distance.
    @Published var poolLengthMeters: Double = 22.86

    @Published private(set) var positions: [String: Double] = [:]   // episodeID -> resume position
    @Published private(set) var durations: [String: Double] = [:]   // episodeID -> total seconds
    private var progressSyncedAt: [String: Date] = [:]
    private static let checkpointKey = "watchPlayheadCheckpoint"

    /// The episode this Watch would resume — the wrist half of the phone's per-feed
    /// `currentEpisodeID`.
    ///
    /// Until this existed the Watch had no notion of "current" at all: `WatchAudioPlayer.currentID`
    /// is runtime-only, set when you press play and gone at stop or relaunch. So the phone could
    /// never hand an episode over to the Watch — not as a policy decision, but because there was
    /// no field to write. The two sides could only ever drift in one direction.
    @Published private(set) var currentEpisodeID: String?
    /// LWW stamp for `currentEpisodeID`, on the same clock rules as `progressSyncedAt`.
    private var currentEpisodeAt: Date = .distantPast
    private static let currentIDKey = "watchCurrentEpisode"
    private static let currentAtKey = "watchCurrentEpisodeAt"

    /// Downloaded episodes sorted by the Workout-cue priority order (pool shows first,
    /// in order), then everything else by recency — matching what plays.
    var orderedEpisodes: [WatchEpisode] {
        let rank = Dictionary(workoutPodcasts.enumerated().map { ($0.element, $0.offset) },
                              uniquingKeysWith: { first, _ in first })
        return episodes.enumerated().sorted { a, b in
            let ra = rank[a.element.podcast] ?? Int.max
            let rb = rank[b.element.podcast] ?? Int.max
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    /// Fractional playback progress (0…1) for the ring, or nil if unknown / unstarted.
    func progress(for episodeID: String) -> Double? {
        guard let pos = positions[episodeID], let dur = durations[episodeID], dur > 0 else { return nil }
        return min(1, max(0, pos / dur))
    }

    private var dir: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Episodes", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private var indexURL: URL { dir.appendingPathComponent("index.json") }

    init() {
        load()
        positions = UserDefaults.standard.dictionary(forKey: "watchPositions") as? [String: Double] ?? [:]
        durations = UserDefaults.standard.dictionary(forKey: "watchDurations") as? [String: Double] ?? [:]
        progressSyncedAt = (UserDefaults.standard.dictionary(forKey: "watchProgressAt") as? [String: Double] ?? [:])
            .mapValues { Date(timeIntervalSince1970: $0) }
        currentEpisodeID = UserDefaults.standard.string(forKey: Self.currentIDKey)
        currentEpisodeAt = UserDefaults.standard.object(forKey: Self.currentAtKey)
            .flatMap { ($0 as? Double).map(Date.init(timeIntervalSince1970:)) } ?? .distantPast
        restoreCheckpoint()
        pruneStaleProgress()
    }

    /// The phone relays progress for EVERY episode it plays — including ones never downloaded
    /// here — and nothing ever removed entries, so all three dictionaries grew forever and were
    /// re-serialized on every progress event. Keep entries for episodes on the watch, and recent
    /// ones for episodes that might still arrive; age the rest out.
    private func pruneStaleProgress() {
        let known = Set(episodes.map(\.id))
        let cutoff = Date().addingTimeInterval(-90 * 24 * 3600)
        var dirty = false
        for (id, at) in progressSyncedAt where !known.contains(id) && at < cutoff {
            progressSyncedAt[id] = nil
            positions[id] = nil
            durations[id] = nil
            dirty = true
        }
        if dirty { persistProgress(); persistDurations() }
    }

    func localURL(for episode: WatchEpisode) -> URL {
        dir.appendingPathComponent(episode.filename)
    }

    // MARK: - Cross-device progress

    func position(for episodeID: String) -> Double { positions[episodeID] ?? 0 }

    /// Record local playback progress (and stamp it as newest) before it's sent to the phone.
    func setLocalProgress(_ episodeID: String, position: Double, duration: Double, completed: Bool) {
        let now = Date()
        progressSyncedAt[episodeID] = now
        positions[episodeID] = completed ? nil : position
        // Only ever called for the episode actually playing here, so it doubles as this Watch
        // renewing its claim on `current`. Without the renewal the claim would keep the timestamp
        // from when playback STARTED, and a phone claim made mid-session — while the Watch guard
        // was busy protecting playback — would win the moment playback stopped.
        if completed {
            if currentEpisodeID == episodeID {
                currentEpisodeAt = now
                currentEpisodeID = nil
                persistCurrent()
            }
        } else {
            setLocalCurrent(episodeID)
        }
        if duration > 0, durations[episodeID] != duration {
            durations[episodeID] = duration
            persistDurations()
        }
        persistProgress()
        clearCheckpoint(for: episodeID, through: now)
    }

    // MARK: - Current episode (which one this Watch would resume)

    /// This Watch just started an episode, so it owns "current" as of now.
    func setLocalCurrent(_ episodeID: String) {
        currentEpisodeAt = Date()
        currentEpisodeID = episodeID
        persistCurrent()
    }

    /// The phone says this is the current episode. Last-write-wins by `at`, exactly as progress
    /// merges do. The caller is responsible for the other half of the rule — never move current
    /// out from under a device that is actively playing something else — because that needs
    /// player state this store deliberately doesn't know about. `PhoneConnectivity` applies the
    /// mirror-image guard to our reports.
    func applyRemoteCurrent(_ episodeID: String?, at rawAt: Date) {
        let at = PlaybackSyncClock.received(rawAt)
        guard at > currentEpisodeAt else { return }
        currentEpisodeAt = at
        currentEpisodeID = episodeID
        persistCurrent()
    }

    private func persistCurrent() {
        UserDefaults.standard.set(currentEpisodeID, forKey: Self.currentIDKey)
        UserDefaults.standard.set(currentEpisodeAt.timeIntervalSince1970, forKey: Self.currentAtKey)
    }

    /// Save the active playhead without mutating an `@Published` collection. This is used by the
    /// minute-level background heartbeat; a normal pause, stop, switch, or finish still commits the
    /// full progress dictionaries and syncs the phone.
    func saveLocalCheckpoint(_ episodeID: String, position: Double, duration: Double, completed: Bool) {
        let checkpoint = WatchPlayheadCheckpoint(
            episodeID: episodeID,
            position: position,
            duration: duration,
            completed: completed,
            at: Date())
        guard let data = try? JSONEncoder().encode(checkpoint) else { return }
        UserDefaults.standard.set(data, forKey: Self.checkpointKey)
    }

    /// Apply progress that came from the phone. Strictly last-write-wins by `at` — completion
    /// included, which is the same rule the phone applies to our reports.
    func applyRemoteProgress(episodeID: String, position: Double, duration: Double, completed: Bool, at rawAt: Date) {
        if duration > 0, durations[episodeID] != duration {
            durations[episodeID] = duration
            persistDurations()
        }
        // The phone's clock is not ours. Bound it — see PlaybackSyncClock.
        let at = PlaybackSyncClock.received(rawAt)
        // This read `prev >= at, !completed`, so ANY completion applied however old it was, and
        // completion clears the position. A completion queued while this Watch was out of range
        // could therefore land after you had restarted the episode here and wipe a live playhead.
        // Ordering alone is enough: an older report loses, a newer one wins whatever it says.
        if let prev = progressSyncedAt[episodeID], prev >= at { return }
        progressSyncedAt[episodeID] = at
        positions[episodeID] = completed ? nil : position
        // Finishing it elsewhere means it is no longer what we'd resume — mirrors the phone
        // clearing its own `currentEpisodeID` on completion.
        if completed, currentEpisodeID == episodeID {
            currentEpisodeAt = at
            currentEpisodeID = nil
            persistCurrent()
        }
        persistProgress()
        clearCheckpoint(for: episodeID, through: at)
    }

    /// Fold a newer checkpoint into memory before playback can resume. It intentionally remains
    /// as the durable record until a normal transition or a newer remote update commits the full
    /// dictionaries, so a second termination during launch cannot lose it.
    private func restoreCheckpoint() {
        guard let data = UserDefaults.standard.data(forKey: Self.checkpointKey),
              let checkpoint = try? JSONDecoder().decode(WatchPlayheadCheckpoint.self, from: data),
              progressSyncedAt[checkpoint.episodeID, default: .distantPast] < checkpoint.at else {
            return
        }
        progressSyncedAt[checkpoint.episodeID] = checkpoint.at
        positions[checkpoint.episodeID] = checkpoint.completed ? nil : checkpoint.position
        if checkpoint.duration > 0 {
            durations[checkpoint.episodeID] = checkpoint.duration
        }
    }

    private func clearCheckpoint(for episodeID: String, through date: Date = .distantFuture) {
        guard let data = UserDefaults.standard.data(forKey: Self.checkpointKey),
              let checkpoint = try? JSONDecoder().decode(WatchPlayheadCheckpoint.self, from: data),
              checkpoint.episodeID == episodeID,
              checkpoint.at <= date else { return }
        UserDefaults.standard.removeObject(forKey: Self.checkpointKey)
    }

    // Persist only what changed: writing all three dictionaries on every progress event
    // re-serialized the whole (formerly unbounded) set each time. Durations barely ever change;
    // they get their own write.
    private func persistProgress() {
        UserDefaults.standard.set(positions, forKey: "watchPositions")
        UserDefaults.standard.set(progressSyncedAt.mapValues(\.timeIntervalSince1970), forKey: "watchProgressAt")
    }
    private func persistDurations() {
        UserDefaults.standard.set(durations, forKey: "watchDurations")
    }

    /// Move a received temp file into permanent storage and record it.
    @discardableResult
    func add(episodeID: String, title: String, podcast: String, from tempURL: URL, ext: String) -> Bool {
        let filename = "\(UUID().uuidString).\(ext)"
        let dest = dir.appendingPathComponent(filename)
        do {
            try FileManager.default.moveItem(at: tempURL, to: dest)
        } catch { return false }

        let replaced = episodes.filter { $0.id == episodeID }
        episodes.removeAll { $0.id == episodeID }
        episodes.insert(WatchEpisode(id: episodeID, title: title, podcast: podcast, filename: filename), at: 0)
        for old in replaced { try? FileManager.default.removeItem(at: localURL(for: old)) }
        save()
        return true
    }

    func delete(_ episode: WatchEpisode) {
        try? FileManager.default.removeItem(at: localURL(for: episode))
        episodes.removeAll { $0.id == episode.id }
        // Take the progress bookkeeping with it — these dictionaries had no other pruning path.
        if positions[episode.id] != nil || progressSyncedAt[episode.id] != nil {
            positions[episode.id] = nil
            progressSyncedAt[episode.id] = nil
            persistProgress()
        }
        if durations[episode.id] != nil {
            durations[episode.id] = nil
            persistDurations()
        }
        // Stamp the clearing as a local event, so a phone claim predating the delete can't
        // resurrect an episode whose file is gone.
        if currentEpisodeID == episode.id {
            currentEpisodeAt = Date()
            currentEpisodeID = nil
            persistCurrent()
        }
        clearCheckpoint(for: episode.id)
        // The markers describe this file; without it they describe nothing.
        WatchSkipPlanStore.shared.forget(episode.id)
        save()
    }

    func delete(episodeID: String) {
        guard let episode = episodes.first(where: { $0.id == episodeID }) else { return }
        delete(episode)
    }

    /// Remove any downloaded episode not in the phone's authoritative set (self-heal
    /// stale/played episodes whose per-episode delete was missed). Ignores an empty
    /// manifest as a safety guard against a premature wipe.
    func pruneNotIn(_ keep: Set<String>) {
        guard !keep.isEmpty else { return }
        for episode in episodes where !keep.contains(episode.id) { delete(episode) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([WatchEpisode].self, from: data) else { return }
        episodes = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(episodes) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
