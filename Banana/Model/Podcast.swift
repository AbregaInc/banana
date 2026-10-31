import Foundation
import os

/// The order in which a feed's episodes are played across alarms.
enum PlayDirection: String, Codable, CaseIterable, Identifiable {
    case newestFirst  // latest episode first (news, daily shows)
    case oldestFirst  // start of the run first (serialized seasons)

    var id: String { rawValue }

    var label: String {
        switch self {
        case .newestFirst: return "Newest first"
        case .oldestFirst: return "Oldest first"
        }
    }

    var detail: String {
        switch self {
        case .newestFirst: return "Play the most recent episode, working backwards."
        case .oldestFirst: return "Start from the beginning, working forwards."
        }
    }
}

/// How many recent episodes of a feed to keep downloaded for offline play.
enum DownloadRule: Codable, Equatable, Hashable {
    case off
    case latest(Int)

    var label: String {
        switch self {
        case .off: return "Off"
        // "unplayed" is load-bearing: `nextUnplayed` skips finished episodes, so this downloads
        // the n most recent you have NOT finished, not the n most recent overall. The old label
        // read as the latter and misdescribed the behaviour.
        case .latest(let n): return "Latest \(n) unplayed"
        }
    }

    static let presets: [DownloadRule] = [.off, .latest(1), .latest(3), .latest(5)]

    /// How many newest episodes this rule wants downloaded.
    var count: Int {
        switch self {
        case .off: return 0
        case .latest(let n): return n
        }
    }
}

/// A single episode parsed from a feed.
struct EpisodeTranscriptSource: Codable, Hashable, Sendable {
    var url: URL
    /// Publisher-declared MIME type from `<podcast:transcript type="…">`.
    var type: String?
    var language: String?
}

struct Episode: Codable, Identifiable, Hashable {
    var id: String          // guid, or the audio URL if no guid
    var title: String
    var audioURL: URL
    var pubDate: Date?
    var duration: Double?   // seconds, if the feed reports it
    var season: Int?
    var episodeNumber: Int?
    var summary: String?
    /// Kept for backwards compatibility with saved catalogues from before Banana retained every
    /// publisher transcript. New feeds populate `transcriptSources` and mirror its first URL here.
    var transcriptURL: URL?
    var transcriptSources: [EpisodeTranscriptSource] = []

    var availableTranscriptSources: [EpisodeTranscriptSource] {
        if !transcriptSources.isEmpty { return transcriptSources }
        return transcriptURL.map { [EpisodeTranscriptSource(url: $0, type: nil, language: nil)] } ?? []
    }
}

extension Episode {
    /// Tolerant decoder (in an extension so the memberwise init is preserved):
    /// missing keys default, so adding a field later won't fail old saved data.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        audioURL = try c.decode(URL.self, forKey: .audioURL)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? audioURL.absoluteString
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled Episode"
        pubDate = try c.decodeIfPresent(Date.self, forKey: .pubDate)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        season = try c.decodeIfPresent(Int.self, forKey: .season)
        episodeNumber = try c.decodeIfPresent(Int.self, forKey: .episodeNumber)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        transcriptURL = try c.decodeIfPresent(URL.self, forKey: .transcriptURL)
        transcriptSources = try c.decodeIfPresent([EpisodeTranscriptSource].self, forKey: .transcriptSources) ?? []
    }
}

/// A subscribed podcast: feed metadata, its episodes, playback direction, and
/// per-episode listening progress.
struct Podcast: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var feedURL: URL
    var title: String
    var author: String?
    var artworkURL: URL?
    var direction: PlayDirection = .newestFirst
    var speed: Double = 1.0          // playback rate for this feed
    var autoSkipSeconds: Int = 0     // skip publisher pre-roll on a never-started episode
    var downloadRule: DownloadRule = .off
    var syncToWatch: Bool = false    // push downloaded episodes to the Watch
    var watchAudioQuality: WatchAudioQuality?   // nil = use the global default
    /// Per-show override for automatic ad skipping. nil = follow the global setting.
    ///
    /// Separate from the automatic retirement the correction book does. That says "this detector
    /// got it wrong on this show"; this says "leave this show alone", which is a decision only the
    /// listener can make — a show whose ads you actually want to hear is not a detector failure.
    var skipsAdsAutomatically: Bool?
    /// Narrators whose episodes this show should stop offering.
    ///
    /// A rotating-cast show is really several shows sharing a feed, and a narrator you do not get
    /// on with makes those episodes worthless to you while the rest stay wanted. Stored by the
    /// canonical name so a credit written "Thomas" and one written "Thomas Jones" mute together.
    var mutedNarrators: Set<String> = []
    /// Voices to stop being offered on this show, judged from the audio.
    ///
    /// The point of doing this by sound rather than by name: a show that adds a narrator every few
    /// weeks would otherwise need a new switch flipped every few weeks. This decides for itself,
    /// including for someone it has never heard.
    var mutedVoiceGenders: Set<VoiceGender> = []

    /// Whether ads are skipped on this show: its own choice if it has made one, otherwise the
    /// global setting. A show turned off individually stays off even with the master switch on,
    /// which is the entire point of having both.
    func skipsAds(defaultingTo globalDefault: Bool) -> Bool {
        skipsAdsAutomatically ?? globalDefault
    }
    private var memoryEpisodes: [Episode] = []
    var episodeSnapshot: EpisodeSnapshot?
    /// Compatibility for explicit bulk operations. Screens use episodePage/episodeCount.
    var episodes: [Episode] {
        get {
            guard let episodeSnapshot else { return memoryEpisodes }
            do { return try episodeSnapshot.all() }
            catch { Self.catalogLog.error("Episode read failed: \(error.localizedDescription, privacy: .public)"); return [] }
        }
        set { memoryEpisodes = newValue; episodeSnapshot = nil }
    }
    mutating func adoptEpisodes(from other: Podcast) {
        memoryEpisodes = other.memoryEpisodes
        episodeSnapshot = other.episodeSnapshot
    }
    private static let catalogLog = Logger(subsystem: "com.boris.banana", category: "episodeCatalog")
    var episodeCount: Int { episodeSnapshot?.count ?? memoryEpisodes.count }
    var latestEpisodeDate: Date? { episodeSnapshot?.latest ?? memoryEpisodes.compactMap(\.pubDate).max() }
    var episodeRevision: String { episodeSnapshot?.id ?? "memory-\(memoryEpisodes.hashValue)" }
    func episode(_ id: String) -> Episode? {
        if let episodeSnapshot { return try? episodeSnapshot.episode(id) }
        return memoryEpisodes.first { $0.id == id }
    }
    func episodeIDs() -> Set<String> {
        if let episodeSnapshot { return (try? episodeSnapshot.ids()) ?? [] }
        return Set(memoryEpisodes.map(\.id))
    }
    func orderedEpisodeIDs() -> [String] {
        if let episodeSnapshot { return (try? episodeSnapshot.orderedIDs(newest: direction == .newestFirst)) ?? [] }
        return ordered().map(\.id)
    }
    func episodePage(offset: Int = 0, limit: Int = 100) throws -> [Episode] {
        if let episodeSnapshot {
            return try episodeSnapshot.page(newest: direction == .newestFirst,
                                            reverseTies: direction == .newestFirst, offset: offset, limit: limit)
        }
        return Array(ordered().dropFirst(max(0, offset)).prefix(max(0, limit)))
    }

    // HTTP validators from the last feed fetch — refresh sends them back so an unchanged feed
    // costs a 304 instead of a full download + parse + catalogue rewrite.
    var etag: String?
    var lastModified: String?

    // Progress tracking
    var currentEpisodeID: String?          // episode in progress
    var positions: [String: Double] = [:]  // episodeID -> resume position (seconds)
    var completed: Set<String> = []        // finished episode IDs
    var lastPlayedAt: Date?                // when this feed was last played (for resume rewind)

    init(id: UUID = UUID(), feedURL: URL, title: String, author: String? = nil,
         artworkURL: URL? = nil, direction: PlayDirection = .newestFirst, speed: Double = 1.0,
         autoSkipSeconds: Int = 0, downloadRule: DownloadRule = .off,
         syncToWatch: Bool = false, episodes: [Episode] = []) {
        self.id = id
        self.feedURL = feedURL
        self.title = title
        self.author = author
        self.artworkURL = artworkURL
        self.direction = direction
        self.speed = speed
        self.autoSkipSeconds = autoSkipSeconds
        self.downloadRule = downloadRule
        self.syncToWatch = syncToWatch
        self.episodes = episodes
    }

    /// Tolerant decoder: missing keys fall back to defaults so adding a field in a
    /// later version doesn't wipe podcasts saved by an earlier version.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        feedURL = try c.decode(URL.self, forKey: .feedURL)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled Podcast"
        author = try c.decodeIfPresent(String.self, forKey: .author)
        artworkURL = try c.decodeIfPresent(URL.self, forKey: .artworkURL)
        direction = try c.decodeIfPresent(PlayDirection.self, forKey: .direction) ?? .newestFirst
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1.0
        autoSkipSeconds = try c.decodeIfPresent(Int.self, forKey: .autoSkipSeconds) ?? 0
        downloadRule = try c.decodeIfPresent(DownloadRule.self, forKey: .downloadRule) ?? .off
        syncToWatch = try c.decodeIfPresent(Bool.self, forKey: .syncToWatch) ?? false
        watchAudioQuality = try c.decodeIfPresent(WatchAudioQuality.self, forKey: .watchAudioQuality)
        // Absent in catalogues saved before per-show ad skipping existed, which is exactly the
        // "follow the global setting" case, so the missing key needs no migration.
        skipsAdsAutomatically = try c.decodeIfPresent(Bool.self, forKey: .skipsAdsAutomatically)
        mutedNarrators = try c.decodeIfPresent(Set<String>.self, forKey: .mutedNarrators) ?? []
        mutedVoiceGenders = try c.decodeIfPresent(Set<VoiceGender>.self, forKey: .mutedVoiceGenders) ?? []
        episodes = try c.decodeIfPresent([Episode].self, forKey: .episodes) ?? []
        etag = try c.decodeIfPresent(String.self, forKey: .etag)
        lastModified = try c.decodeIfPresent(String.self, forKey: .lastModified)
        currentEpisodeID = try c.decodeIfPresent(String.self, forKey: .currentEpisodeID)
        positions = try c.decodeIfPresent([String: Double].self, forKey: .positions) ?? [:]
        completed = try c.decodeIfPresent(Set<String>.self, forKey: .completed) ?? []
        lastPlayedAt = try c.decodeIfPresent(Date.self, forKey: .lastPlayedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case id, feedURL, title, author, artworkURL, direction, speed, autoSkipSeconds, downloadRule, syncToWatch, watchAudioQuality, skipsAdsAutomatically, mutedNarrators, mutedVoiceGenders, episodes, etag, lastModified, currentEpisodeID, positions, completed, lastPlayedAt
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(feedURL, forKey: .feedURL)
        try c.encode(title, forKey: .title)
        try c.encode(author, forKey: .author)
        try c.encode(artworkURL, forKey: .artworkURL)
        try c.encode(direction, forKey: .direction)
        try c.encode(speed, forKey: .speed)
        try c.encode(autoSkipSeconds, forKey: .autoSkipSeconds)
        try c.encode(downloadRule, forKey: .downloadRule)
        try c.encode(syncToWatch, forKey: .syncToWatch)
        try c.encode(watchAudioQuality, forKey: .watchAudioQuality)
        try c.encode(skipsAdsAutomatically, forKey: .skipsAdsAutomatically)
        try c.encode(mutedNarrators, forKey: .mutedNarrators)
        try c.encode(mutedVoiceGenders, forKey: .mutedVoiceGenders)
        if encoder.userInfo[.podcastMetadataOnly] as? Bool != true {
            try c.encode(episodeSnapshot.map { try $0.all() } ?? memoryEpisodes, forKey: .episodes)
        }
        try c.encode(etag, forKey: .etag)
        try c.encode(lastModified, forKey: .lastModified)
        try c.encode(currentEpisodeID, forKey: .currentEpisodeID)
        try c.encode(positions, forKey: .positions)
        try c.encode(completed, forKey: .completed)
        try c.encode(lastPlayedAt, forKey: .lastPlayedAt)
    }

    /// Episodes sorted into play order for this feed's direction.
    /// Sorting is by publish date (falling back to feed order), which naturally
    /// keeps serialized seasons in sequence for `.oldestFirst`.
    func ordered() -> [Episode] {
        if let episodeSnapshot {
            return (try? episodeSnapshot.page(newest: direction == .newestFirst,
                                               reverseTies: direction == .newestFirst, limit: episodeCount)) ?? []
        }
        let chronological = memoryEpisodes.sorted { lhs, rhs in
            (lhs.pubDate ?? .distantPast) < (rhs.pubDate ?? .distantPast)
        }
        return direction == .oldestFirst ? chronological : chronological.reversed()
    }

    /// The episode to play next — for the alarm, "Play next episode", a routine and auto-advance:
    /// resume the current one if it isn't finished, otherwise the first not-yet-completed episode
    /// in play order. Episodes the voice filter skips are passed over; only an episode tapped in
    /// the list plays regardless, because that's a choice.
    /// - Parameter voiceOf: `NarratorVoiceStore.lookup()`. Without it only name mutes apply.
    func nextEpisode(voiceOf: (_ episodeID: String, _ narrator: String?) -> VoiceGender? = { _, _ in nil }) -> Episode? {
        let roster = hasVoiceFilter ? narratorRoster : []
        func skipped(_ episode: Episode) -> Bool { isSkipped(episode, roster: roster, voiceOf: voiceOf) }
        if let current = currentEpisodeID,
           let episode = episode(current),
           !completed.contains(current), !skipped(episode) {
            return episode
        }
        return selectedEpisodes(1, newest: direction == .newestFirst, reverseTies: direction == .newestFirst) {
            !completed.contains($0.id) && !skipped($0)
        }.first ?? selectedEpisodes(1, newest: direction == .newestFirst, reverseTies: direction == .newestFirst) {
            !skipped($0)
        }.first ?? selectedEpisodes(1, newest: direction == .newestFirst, reverseTies: direction == .newestFirst) { _ in true }.first
    }

    /// Small download/play queues need only their best few entries. Keep a bounded ordered
    /// buffer instead of sorting and allocating an entire feed. Larger requests retain the
    /// existing stable full sort. Tie direction matches ordered()'s ascending-then-reverse rule.
    private func selectedEpisodes(_ limit: Int, newest: Bool, reverseTies: Bool,
                                  where include: (Episode) -> Bool) -> [Episode] {
        guard limit > 0 else { return [] }
        if let episodeSnapshot {
            var result: [Episode] = []
            var offset = 0
            do {
                while offset < episodeCount && result.count < limit {
                    let page = try episodeSnapshot.page(newest: newest, reverseTies: reverseTies,
                                                        offset: offset, limit: completed.isEmpty && !hasVoiceFilter ? min(64, limit - result.count) : 64)
                    guard !page.isEmpty else { break }
                    for episode in page where include(episode) {
                        result.append(episode)
                        if result.count == limit { break }
                    }
                    offset += page.count
                }
            } catch { Self.catalogLog.error("Episode selection failed: \(error.localizedDescription, privacy: .public)"); return [] }
            return result
        }
        let episodes = memoryEpisodes
        func precedes(_ lhs: Int, _ rhs: Int) -> Bool {
            let left = episodes[lhs].pubDate ?? .distantPast
            let right = episodes[rhs].pubDate ?? .distantPast
            if left == right { return reverseTies ? lhs > rhs : lhs < rhs }
            return newest ? left > right : left < right
        }
        if limit > 32 {
            return episodes.indices.filter { include(episodes[$0]) }
                .sorted(by: precedes).prefix(limit).map { episodes[$0] }
        }
        // Keep indices, not Episode copies: the latter retain/release every title, summary,
        // URL and metadata field even for the thousands of candidates immediately discarded.
        var best: [Int] = []
        best.reserveCapacity(limit)
        for index in episodes.indices {
            if best.count == limit, let last = best.last, !precedes(index, last) { continue }
            guard include(episodes[index]) else { continue }
            let position = best.firstIndex { precedes(index, $0) } ?? best.endIndex
            best.insert(index, at: position)
            if best.count > limit { best.removeLast() }
        }
        return best.map { episodes[$0] }
    }

    /// Whether any narrator or voice is muted for this show.
    var hasVoiceFilter: Bool { !(mutedNarrators.isEmpty && mutedVoiceGenders.isEmpty) }

    /// Whether the voice filter skips this episode: `isMuted`, with the credited narrator resolved
    /// to the roster's spelling and its voice looked up.
    /// - Parameter roster: `narratorRoster`, built once by the caller for a whole list.
    func isSkipped(_ episode: Episode, roster: Set<String>,
                   voiceOf: (_ episodeID: String, _ narrator: String?) -> VoiceGender?) -> Bool {
        guard hasVoiceFilter else { return false }
        let narrator = NarratorCredit.name(in: episode.summary)
            .map { NarratorCredit.canonical($0, among: roster) }
        return isMuted(episode, voice: voiceOf(episode.id, narrator), roster: roster)
    }

    func resumePosition(for episodeID: String) -> Double {
        positions[episodeID] ?? 0
    }

    /// Choose the first playhead for this episode: preserve an existing resume (including the
    /// long-gap rewind), otherwise apply the show's pre-roll preference. If a publisher reports a
    /// clip shorter than the preset, start at zero rather than ending it.
    func startPosition(for episode: Episode, at now: Date = Date()) -> Double {
        let saved = resumePosition(for: episode.id)
        if saved > 1 {
            if let lastPlayedAt, now.timeIntervalSince(lastPlayedAt) > 12 * 3_600 {
                return max(0, saved - 30)
            }
            return saved
        }
        guard saved <= 1, autoSkipSeconds > 0 else { return saved }
        let skipped = Double(autoSkipSeconds)
        guard episode.duration.map({ skipped < $0 }) ?? true else { return saved }
        return skipped
    }

    /// The newest `n` episodes by publish date — the set the download rule keeps offline.
    func newestEpisodes(_ n: Int) -> [Episode] {
        selectedEpisodes(n, newest: true, reverseTies: false) { _ in true }
    }

    /// The next `n` *unplayed* episodes in play order — what the download rule keeps
    /// ready (so already-played episodes never occupy a slot).
    /// - Parameter voiceOf: resolves a voice for an episode. Receives the canonical narrator name
    ///   when the episode credits one, because a verdict is reached per NARRATOR and reused across
    ///   everything they read — that reuse is the whole reason the gender filter exists rather
    ///   than muting twenty names by hand.
    func nextUnplayed(
        _ n: Int,
        voiceOf: (_ episodeID: String, _ narrator: String?) -> VoiceGender? = { _, _ in nil }
    ) -> [Episode] {
        // Build the roster ONCE. It walks every episode and runs a regex over each summary, and
        // `isMuted` used to rebuild it per episode — 799 episodes squared, measured at 64 SECONDS
        // on a real feed against 146 ms this way. Nothing about the roster changes mid-filter.
        //
        // Needed for a GENDER mute too, not just a name mute: a credited episode has to be
        // canonicalised before its narrator's verdict can be looked up.
        let roster = hasVoiceFilter ? narratorRoster : []
        return selectedEpisodes(n, newest: direction == .newestFirst, reverseTies: direction == .newestFirst) {
            !completed.contains($0.id) && !isSkipped($0, roster: roster, voiceOf: voiceOf)
        }
    }

    /// Whether this episode's narrator has been muted for this show.
    ///
    /// Episodes whose notes name nobody are never muted: silence about the narrator is not
    /// evidence about who it is, and guessing here would hide episodes the listener wanted.
    /// - Parameter roster: pass the show's roster when filtering several episodes, so it is built
    ///   once rather than per episode. Omitted, it is computed on demand — fine for one episode,
    ///   ruinous in a loop.
    func isMuted(_ episode: Episode, voice: VoiceGender? = nil, roster: Set<String>? = nil) -> Bool {
        // Nothing muted means nothing to check, and the roster is never needed. This is the
        // overwhelmingly common case and it now costs one set lookup rather than a full parse.
        if mutedNarrators.isEmpty && mutedVoiceGenders.isEmpty { return false }
        // The credited name wins when there is one: it is exact, and the listener chose it
        // explicitly. Only fall through to the voice when the feed says nothing.
        if let credit = NarratorCredit.name(in: episode.summary) {
            let name = NarratorCredit.canonical(credit, among: roster ?? narratorRoster)
            // An explicit name mute is the listener's own decision and still wins outright. Any
            // capitalisation: "Chloe De Burgh" muted covers an episode credited "Chloe de Burgh".
            if mutedNarrators.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return true }
            // Then the gender, which is the whole point of having one: muting "female" has to
            // cover every episode a female narrator reads, or a show that credits its narrators
            // can only be filtered by muting all twenty of them by hand. `voice` is the reading
            // for this narrator when one has been reached, and nil means not yet judged — in
            // which case nothing is muted rather than guessed.
            guard let voice else { return false }
            return mutedVoiceGenders.contains(voice)
        }
        guard let voice else { return false }
        return mutedVoiceGenders.contains(voice)
    }

    /// Canonical narrator names this show has credited, for resolving short forms and for the
    /// settings list.
    var narratorRoster: Set<String> {
        guard let episodeSnapshot else { return Set(memoryEpisodes.compactMap { NarratorCredit.name(in: $0.summary) }) }
        var names: Set<String> = []
        for offset in stride(from: 0, to: episodeCount, by: 100) {
            guard let page = try? episodeSnapshot.page(offset: offset, limit: 100) else { return names }
            for episode in page {
                if let name = NarratorCredit.name(in: episode.summary) { names.insert(name) }
            }
        }
        return names
    }
}

/// A show's settings — everything you choose for it, and nothing it tracks (episodes, progress,
/// feed caches). What syncs between devices for a podcast (CloudControlsSync), so listening
/// progress, which has its own sync, can never be touched by a settings change.
///
/// Fields a newer build adds must be optional: an older build ignores keys it doesn't know, but
/// fails a record with a required one missing.
struct PodcastSettings: Codable, Equatable {
    var direction: PlayDirection
    var speed: Double
    var autoSkipSeconds: Int
    var downloadRule: DownloadRule
    var syncToWatch: Bool
    var watchAudioQuality: WatchAudioQuality?
    var skipsAdsAutomatically: Bool?
    var mutedNarrators: Set<String>
    var mutedVoiceGenders: Set<VoiceGender>

    init(_ podcast: Podcast) {
        direction = podcast.direction
        speed = podcast.speed
        autoSkipSeconds = podcast.autoSkipSeconds
        downloadRule = podcast.downloadRule
        syncToWatch = podcast.syncToWatch
        watchAudioQuality = podcast.watchAudioQuality
        skipsAdsAutomatically = podcast.skipsAdsAutomatically
        mutedNarrators = podcast.mutedNarrators
        mutedVoiceGenders = podcast.mutedVoiceGenders
    }

    /// `podcast` with these settings, and everything else as it was.
    func applied(to podcast: Podcast) -> Podcast {
        var podcast = podcast
        podcast.direction = direction
        podcast.speed = speed
        podcast.autoSkipSeconds = autoSkipSeconds
        podcast.downloadRule = downloadRule
        podcast.syncToWatch = syncToWatch
        podcast.watchAudioQuality = watchAudioQuality
        podcast.skipsAdsAutomatically = skipsAdsAutomatically
        podcast.mutedNarrators = mutedNarrators
        podcast.mutedVoiceGenders = mutedVoiceGenders
        return podcast
    }
}

/// A show you subscribe to, as it travels between devices: enough to subscribe again elsewhere.
/// Its episodes come from its feed on each device; its settings (`PodcastSettings`) and progress
/// sync separately.
struct PodcastSubscription: Codable, Equatable {
    var feedURL: URL
    var title: String
    var author: String?
    var artworkURL: URL?

    init(_ podcast: Podcast) {
        feedURL = podcast.feedURL
        title = podcast.title
        author = podcast.author
        artworkURL = podcast.artworkURL
    }

    /// The show on a device that hasn't read its feed yet: same id as everywhere else, so its
    /// progress and settings find it.
    func podcast(id: UUID) -> Podcast {
        Podcast(id: id, feedURL: feedURL, title: title, author: author, artworkURL: artworkURL)
    }
}
