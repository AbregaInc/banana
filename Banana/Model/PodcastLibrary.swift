import SwiftUI
import Foundation
import os

/// Owns the user's subscribed podcasts, their play direction, and listening
/// progress. Episodes live in SQLite; progress remains portable JSON. (Wake-source selection
/// lives in `WakeStore`.)
@MainActor
final class PodcastLibrary: ObservableObject {
    // `nonisolated` — `Logger` is inherently thread-safe, and this needs to be usable from both
    // MainActor call sites and the background decode task below.
    private nonisolated static let log = Logger(subsystem: "com.boris.banana", category: "podcastLibrary")

    @Published private(set) var podcasts: [Podcast] = []
    private var catalog: PodcastCatalog?
    @Published var isWorking = false
    @Published var errorMessage: String?

    private var fileURL: URL {
        let dir = AppSupport.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("podcasts.json")
    }

    init() {
        // Open metadata and migrate legacy JSON off the main thread. Episode bodies remain
        // on disk. A failed migration preserves the original and blocks unsafe writes.
        let fileURL = fileURL
        let progressURL = progressURL
        let checkpointURL = checkpointURL
        Task.detached(priority: .userInitiated) { [weak self] in
            let catalogResult: Result<(PodcastCatalog, [Podcast]), Error> = Result {
                let catalog = try PodcastCatalog.open(at: fileURL.deletingLastPathComponent().appendingPathComponent("podcast-catalog.sqlite"))
                return (catalog, try catalog.load(legacyURL: fileURL))
            }
            let stored = (try? Data(contentsOf: progressURL))
                .flatMap { try? JSONDecoder().decode(StoredProgress.self, from: $0) }
            let checkpoint = (try? Data(contentsOf: checkpointURL))
                .flatMap { try? JSONDecoder().decode(PlayheadCheckpoint.self, from: $0) }
            await MainActor.run { [weak self] in self?.finishLoad(catalogResult, stored, checkpoint) }
        }
        LaunchClock.mark("library.init")
    }

    /// True once the catalogue decode has landed (empty library counts as loaded).
    private(set) var isLoaded = false
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    /// A failed catalog load must not replace independently valid progress with emptiness.
    private var catalogLoadFailed = false
    /// Preserve existing storage after any catalog opening or migration failure.
    private var catalogSaveIsUnsafe = false
    #if PERFORMANCE_TESTING
    private var usesPerformanceCatalogue = false
    #endif
    #if DEBUG
    private var usesPreviewCatalogue = false
    #endif

    private func finishLoad(_ catalogOutcome: Result<(PodcastCatalog, [Podcast]), Error>, _ stored: StoredProgress?,
                            _ checkpoint: PlayheadCheckpoint?) {
        #if DEBUG
        if usesPreviewCatalogue {
            isLoaded = true
            for waiter in loadWaiters { waiter.resume() }
            loadWaiters.removeAll()
            return
        }
        #endif
        let decoded: [Podcast]
        switch catalogOutcome {
        case let .success((catalog, values)):
            self.catalog = catalog
            decoded = values
        case let .failure(error):
            decoded = []
            catalogLoadFailed = true
            catalogSaveIsUnsafe = true
            errorMessage = "The podcast library could not be opened. Your stored library has been preserved. \(error.localizedDescription)"
            Self.log.error("Catalog load failed: \(error.localizedDescription, privacy: .public)")
        }
        if podcasts.isEmpty {
            podcasts = decoded
        } else if !decoded.isEmpty {
            // Something mutated the library before the decode landed (a pre-load subscribe).
            // A wholesale assignment here would silently revert that action — and its save()
            // already wrote the reduced list to disk, so union the two and re-persist.
            let existing = Set(podcasts.map(\.id))
            podcasts.append(contentsOf: decoded.filter { !existing.contains($0.id) })
        }
        applyStoredProgress(stored)
        adoptSyncStamps(stored)
        if let checkpoint { applyCheckpoint(checkpoint) }
        isLoaded = true
        LaunchClock.mark("library.loaded")
        for waiter in loadWaiters { waiter.resume() }
        loadWaiters.removeAll()
        if !podcasts.isEmpty && !decoded.isEmpty && podcasts.count != decoded.count {
            save()   // persist the merged union so disk matches memory again
        }
    }

    /// Await the initial decode. The wake intent, Watch progress ingest, and CloudKit seeding all
    /// read the library at moments that can precede the async load — without this gate they'd see
    /// an empty library and silently drop real data (progress, the wake source).
    func whenLoaded() async {
        if isLoaded { return }
        await withCheckedContinuation { loadWaiters.append($0) }
    }

    #if DEBUG && (targetEnvironment(simulator) || os(macOS) || STRESS_DEVICE_AUDIT)
    func injectStress(_ values: [Podcast]) {
        usesPreviewCatalogue = true
        podcasts = values
    }
    #endif

    func podcast(_ id: UUID) -> Podcast? { podcasts.first { $0.id == id } }

    // MARK: - Subscribing

    /// Add a podcast from a feed URL string (accepts bare host, adds https).
    /// Returns the new podcast's id on success, or nil on failure.
    @discardableResult
    func addPodcast(from urlString: String) async -> UUID? {
        await whenLoaded()   // a pre-load append + save would race the async decode (see finishLoad)
        guard !catalogSaveIsUnsafe else { return nil }
        let cleaned = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let normalized = cleaned.contains("://") ? cleaned : "https://\(cleaned)"
        guard let url = URL(string: normalized) else {
            errorMessage = "That doesn't look like a valid URL."
            return nil
        }
        if podcasts.contains(where: { $0.feedURL == url }) {
            errorMessage = "You're already subscribed to that feed."
            return nil
        }

        isWorking = true
        defer { isWorking = false }
        do {
            guard case .fresh(let feed, let etag, let lastModified) = try await FeedParser.load(url) else {
                return nil   // 304 can't happen without validators; guard anyway
            }
            let owned = EpisodeOwnership.unclaimed(feed.episodes, feedURL: url, among: podcasts)
            if owned.dropped > 0 { Self.log.notice("subscribe: \(owned.dropped) episode ids already belong to another show, left out") }
            var podcast = Podcast(
                feedURL: url,
                title: feed.title,
                author: feed.author,
                artworkURL: feed.artworkURL,
                episodes: owned.kept
            )
            podcast.etag = etag
            podcast.lastModified = lastModified
            if let catalog {
                let incoming = podcast
                podcast = try await Task.detached(priority: .utility) { try catalog.stage(incoming) }.value
            }
            if let existing = podcasts.first(where: { $0.feedURL == url }) { return existing.id }
            podcasts.append(podcast)
            save()
            episodesArrived()
            ControlChangeReporter.changed(.show, podcast.id.uuidString)
            return podcast.id
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    private static let lastFullRefreshKey = "podcastFeedsRefreshedAt"
    private var refreshingAll = false
    /// Background sweeps must not pop the error alert over whatever the person is doing —
    /// a feed that's down at 3 AM is not their problem. Explicit gestures still surface errors.
    private var suppressFeedErrors = false

    /// Refresh every subscribed feed, at most once per `staleAfter` (pass `force` for an
    /// explicit user gesture like pull-to-refresh). Conditional GETs make unchanged feeds
    /// cost headers only, so the throttle is radio/battery courtesy.
    ///
    /// The stamp is only advanced when at least one feed answered — a launch in a tunnel
    /// must not burn the window and leave the catalogue stale for hours after Wi-Fi returns.
    ///
    /// This exists because feeds previously refreshed ONLY from a podcast's detail-page
    /// button — the catalogue silently froze for anyone who didn't visit each podcast and
    /// tap refresh, and everything downstream (auto-downloads, Watch sync) starved with it.
    func refreshAllStale(
        staleAfter: TimeInterval = 4 * 3600,
        force: Bool = false,
        allowBackgroundExecution: Bool = false
    ) async {
        guard !refreshingAll else { return }   // launch + foreground both fire at startup
        let last = UserDefaults.standard.object(forKey: Self.lastFullRefreshKey) as? Date ?? .distantPast
        guard force || Date().timeIntervalSince(last) > staleAfter else { return }
        refreshingAll = true
        suppressFeedErrors = !force   // a pull-to-refresh should still show what went wrong
        isWorking = true
        defer {
            isWorking = false
            refreshingAll = false
            suppressFeedErrors = false
        }
        var anySucceeded = false
        var pendingUpdates: [FeedUpdate] = []
        var completedSweep = true
        for id in podcasts.map(\.id) {
            #if os(iOS)
            // A refresh requested by the visible app must not keep parsing feeds and rewriting
            // its catalogue after the person leaves. The scheduled overnight BGProcessing task
            // opts in explicitly and still gets its full sweep.
            guard allowBackgroundExecution || AppVisibility.shared.isActive else {
                completedSweep = false
                break
            }
            #endif
            switch await refreshOutcome(id, managesWorkingState: false) {
            case .failed:
                break
            case .unchanged:
                anySucceeded = true
            case .changed(let update):
                anySucceeded = true
                pendingUpdates.append(update)
            }
        }
        // Publish and persist the completed batch once. Applying each parsed feed through the
        // @Published array subscript made a 24-feed launch sweep redraw catalogue observers 24
        // times even though all of the network and XML work had already happened off-main.
        if applyFeedUpdates(pendingUpdates) { save() }
        // A partial foreground sweep (the person left mid-refresh) must not suppress the remaining
        // feeds for four hours. Its changed data is still saved, but only a complete pass advances
        // the staleness window.
        if anySucceeded && completedSweep {
            UserDefaults.standard.set(Date(), forKey: Self.lastFullRefreshKey)
        }
    }

    /// Re-fetch a feed and merge in new episodes, preserving progress. Conditional: an unchanged
    /// feed (304) costs headers only — no parse, no episode replace, no catalogue rewrite.
    /// Returns whether the feed answered (a 304 counts — the catalogue is confirmed current).
    @discardableResult
    func refresh(_ id: UUID) async -> Bool {
        switch await refreshOutcome(id, managesWorkingState: true) {
        case .failed:
            return false
        case .unchanged:
            return true
        case .changed(let update):
            if applyFeedUpdates([update]) { save() }
            return true
        }
    }

    private struct FeedUpdate {
        let id: UUID
        let feed: Podcast
        let etag: String?
        let lastModified: String?
    }

    private enum RefreshOutcome {
        case failed, unchanged, changed(FeedUpdate)
    }

    private func refreshOutcome(
        _ id: UUID,
        managesWorkingState: Bool
    ) async -> RefreshOutcome {
        guard let requested = podcasts.first(where: { $0.id == id }) else { return .failed }
        if managesWorkingState { isWorking = true }
        defer { if managesWorkingState { isWorking = false } }
        do {
            let result = try await FeedParser.load(requested.feedURL,
                                                   etag: requested.etag,
                                                   lastModified: requested.lastModified)
            guard case .fresh(let feed, let etag, let lastModified) = result else {
                return .unchanged
            }
            let owned = EpisodeOwnership.unclaimed(feed.episodes, feedURL: requested.feedURL, among: podcasts)
            if owned.dropped > 0 { Self.log.notice("refresh: \(owned.dropped) episode ids already belong to another show, left out") }
            let incoming = Podcast(id: id, feedURL: requested.feedURL, title: feed.title,
                                   author: feed.author, artworkURL: feed.artworkURL, episodes: owned.kept)
            let stored: Podcast
            if let catalog {
                stored = try await Task.detached(priority: .utility) { try catalog.stage(incoming) }.value
            } else { stored = incoming }
            return .changed(FeedUpdate(
                id: id,
                feed: stored,
                etag: etag,
                lastModified: lastModified
            ))
        } catch {
            if !suppressFeedErrors {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            return .failed
        }
    }

    /// Merge feed results against the latest catalogue snapshot. Re-resolving each identity here
    /// preserves an unsubscribe that happened while URLSession was suspended, and assigning the
    /// finished array once emits one coherent publication for the whole sweep.
    @discardableResult
    private func applyFeedUpdates(_ updates: [FeedUpdate]) -> Bool {
        guard !updates.isEmpty else { return false }
        var updatedPodcasts = podcasts
        var changed = false
        for update in updates {
            guard let idx = updatedPodcasts.firstIndex(where: { $0.id == update.id }) else { continue }
            updatedPodcasts[idx].title = update.feed.title
            updatedPodcasts[idx].author = update.feed.author
            updatedPodcasts[idx].artworkURL = update.feed.artworkURL
            updatedPodcasts[idx].adoptEpisodes(from: update.feed)
            updatedPodcasts[idx].etag = update.etag
            updatedPodcasts[idx].lastModified = update.lastModified
            changed = true
        }
        if changed {
            podcasts = updatedPodcasts
            episodesArrived()
        }
        return changed
    }

    func remove(_ id: UUID) {
        guard isLoaded else { return }   // removeAll+save on a not-yet-loaded (empty) list would wipe the catalogue file
        // Unsubscribing is the moment an episode's derived artifacts stop being reachable from
        // any UI — clean up transcripts and resume checkpoints, or they orphan forever
        // (~200 MB after a few hundred transcribed episodes, in non-purgeable Application Support).
        if let podcast = podcasts.first(where: { $0.id == id }) {
            for episode in podcast.episodes {
                TranscriptStore.shared.delete(episode.id)
                TranscriptCoordinator.shared.discardPartial(episode.id)
            }
        }
        if live?.podcastID == id { live = nil }   // don't persist a playhead for a feed that's gone
        let wasSubscribed = podcasts.contains { $0.id == id }
        podcasts.removeAll { $0.id == id }
        save()
        if wasSubscribed { ControlChangeReporter.deleted(.show, id.uuidString) }
    }

    // MARK: - Settings

    /// Every device shows a show's settings the same (CloudControlsSync).
    private func settingsChanged(_ id: UUID) {
        ControlChangeReporter.changed(.podcast, id.uuidString)
    }

    /// A show's settings changed on another device; the old and new copies, so what they drive
    /// here (downloads, the Watch) can follow.
    var onCloudSettingsApplied: ((_ old: Podcast, _ new: Podcast) -> Void)?
    /// Shows subscribed on another device have arrived here, still without episodes — so their
    /// feeds can be read, and their progress and settings applied.
    var onShowsArrivedFromCloud: ((Set<UUID>) -> Void)?
    /// Episodes came in — a feed loaded or refreshed, a show was added. Progress from another
    /// device that was waiting for them applies now (`CloudProgressSync`, `ParkedProgress`).
    var onEpisodesArrived: (() -> Void)?

    /// Episodes came in: what waited for them (iCloud's parked progress, and the data platform's
    /// progress and show settings, held in its mirror) is offered again.
    private func episodesArrived() {
        onEpisodesArrived?()
        SpaceSyncLaunch.replay(types: [PodcastProgressAdapter.type, "podcast.settings"])
    }
    /// A show unsubscribed on another device has gone from here — so its downloads can go too.
    var onShowRemovedFromCloud: ((Podcast) -> Void)?
    fileprivate var showsArrived: Set<UUID> = []
    fileprivate var showsArrivedFlush: Task<Void, Never>?

    func setDirection(_ direction: PlayDirection, for id: UUID) {
        guard let idx = podcasts.firstIndex(where: { $0.id == id }), podcasts[idx].direction != direction else { return }
        podcasts[idx].direction = direction
        save()
        settingsChanged(id)
    }

    func setSpeed(_ speed: Double, for id: UUID) {
        guard let idx = podcasts.firstIndex(where: { $0.id == id }), podcasts[idx].speed != speed else { return }
        podcasts[idx].speed = speed
        save()
        settingsChanged(id)
    }

    func setAutoSkipSeconds(_ seconds: Int, for id: UUID) {
        guard let idx = podcasts.firstIndex(where: { $0.id == id }), podcasts[idx].autoSkipSeconds != max(0, seconds) else { return }
        podcasts[idx].autoSkipSeconds = max(0, seconds)
        save()
        settingsChanged(id)
    }

    func setDownloadRule(_ rule: DownloadRule, for id: UUID) {
        guard let idx = podcasts.firstIndex(where: { $0.id == id }), podcasts[idx].downloadRule != rule else { return }
        podcasts[idx].downloadRule = rule
        save()
        settingsChanged(id)
    }

    func setSyncToWatch(_ on: Bool, for id: UUID) {
        guard let idx = podcasts.firstIndex(where: { $0.id == id }), podcasts[idx].syncToWatch != on else { return }
        podcasts[idx].syncToWatch = on
        save()
        settingsChanged(id)
    }

    /// nil restores "follow the global setting".
    func setVoiceGenderMuted(_ muted: Bool, gender: VoiceGender, for id: UUID) {
        guard let idx = podcasts.firstIndex(where: { $0.id == id }),
              podcasts[idx].mutedVoiceGenders.contains(gender) != muted else { return }
        if muted { podcasts[idx].mutedVoiceGenders.insert(gender) }
        else { podcasts[idx].mutedVoiceGenders.remove(gender) }
        save()
        settingsChanged(id)
    }

    func setNarratorMuted(_ muted: Bool, narrator: String, for id: UUID) {
        guard let idx = podcasts.firstIndex(where: { $0.id == id }),
              podcasts[idx].mutedNarrators.contains(narrator) != muted else { return }
        if muted { podcasts[idx].mutedNarrators.insert(narrator) }
        else { podcasts[idx].mutedNarrators.remove(narrator) }
        save()
        settingsChanged(id)
    }

    func setAutomaticAdSkip(_ enabled: Bool?, for id: UUID) {
        guard let idx = podcasts.firstIndex(where: { $0.id == id }), podcasts[idx].skipsAdsAutomatically != enabled else { return }
        podcasts[idx].skipsAdsAutomatically = enabled
        save()
        settingsChanged(id)
    }

    func setWatchAudioQuality(_ quality: WatchAudioQuality?, for id: UUID) {
        guard let idx = podcasts.firstIndex(where: { $0.id == id }), podcasts[idx].watchAudioQuality != quality else { return }
        podcasts[idx].watchAudioQuality = quality
        save()
        settingsChanged(id)
    }

    // MARK: - Progress (called by the player)

    /// The moving playhead, held OUTSIDE the published array.
    ///
    /// Mutating `podcasts` fires objectWillChange for every observer of the library — and the
    /// player commits progress every 30 s of playback, so the whole library republished (and
    /// half the app re-rendered) twice a minute for the entire session. Exactly one episode
    /// plays at a time, so the live state is a single value; it folds into `podcasts` — ONE
    /// publish — at moments a list could actually show something new (pause, stop, episode
    /// switch, completion, a remote merge). `saveProgress` merges it too, so what's on disk is
    /// always current regardless of fold timing.
    private struct LiveProgress {
        var podcastID: UUID
        var episodeID: String
        var position: Double
        var at: Date
    }
    private var live: LiveProgress?

    /// Nesting depth of `applyingRemoteBatch`. >0 while a CloudKit fetched-changes batch is being
    /// applied record-by-record, so the per-record disk write and Watch-resume relay can be
    /// deferred to batch end instead of firing once per record.
    private var remoteBatchDepth = 0
    private var deferredProgressSave = false
    private var deferredCurrentChanged = false
    /// Episodes a remote batch finished, by show — announced once when the batch ends.
    private var deferredCompletions: [UUID: [String]] = [:]
    /// episodeID -> podcasts index, snapshotted once at the start of a remote batch (after the
    /// live playhead is folded — see `applyingRemoteBatch`) so `applyRemoteProgress` doesn't
    /// re-scan every episode of every podcast for each record in the batch. Catalogue membership
    /// (`episodes`) never changes mid-batch (progress-only records don't touch it), so the
    /// snapshot stays valid for the whole batch.
    private var remoteBatchOwnerIndex: [String: Int]?

    /// Wrap a run of CloudKit-origin progress applications (one `.fetchedRecordZoneChanges`
    /// event) so `saveProgress()` and `onCurrentEpisodeChanged?()` each fire once at the end of
    /// the batch instead of once per record. In-memory `podcasts`/`progressSyncedAt` mutation
    /// still happens per record inside `applyRemoteProgress` — UI freshness is unaffected; only
    /// the disk write and the WatchConnectivity relay move to batch-end. Re-entrant safe (nests).
    func applyingRemoteBatch(_ body: () -> Void) {
        remoteBatchDepth += 1
        if remoteBatchDepth == 1 {
            // Fold the live playhead ONCE, up front, before snapshotting the owner index — not
            // per record as `applyRemoteProgress` does outside a batch. This closes the race
            // where a podcast refresh has pruned the currently-playing episode out of `episodes`
            // (it can still be tracked live) and a same-batch remote record for that episode
            // would otherwise miss it: folding first makes it discoverable via `positions`.
            commitLiveProgress()
            var owner: [String: Int] = [:]
            for (i, p) in podcasts.enumerated() {
                for e in p.episodes { owner[e.id] = i }
                for id in p.positions.keys { owner[id] = i }
                for id in p.completed { owner[id] = i }
            }
            remoteBatchOwnerIndex = owner
        }
        body()
        remoteBatchDepth -= 1
        if remoteBatchDepth == 0 {
            remoteBatchOwnerIndex = nil
            if deferredProgressSave { deferredProgressSave = false; saveProgress() }
            if deferredCurrentChanged { deferredCurrentChanged = false; onCurrentEpisodeChanged?() }
            let completions = deferredCompletions
            deferredCompletions = [:]
            for (podcastID, episodeIDs) in completions { announceCompleted(podcastID: podcastID, episodeIDs: episodeIDs) }
        }
    }

    /// Played is played wherever it happened: a finish from the Watch or another device frees
    /// this device's download too, the same as one finished here (`DownloadManager.observeCompletions`).
    private func announceCompleted(podcastID: UUID, episodeIDs: [String]) {
        NotificationCenter.default.post(
            name: .podcastEpisodesCompleted,
            object: nil,
            userInfo: ["podcastID": podcastID, "episodeIDs": episodeIDs])
    }

    /// Record the playhead quietly (no publish). The hot path — every 30 s tick lands here.
    func updateProgress(podcastID: UUID, episodeID: String, position: Double) {
        let now = Date()
        live = LiveProgress(podcastID: podcastID, episodeID: episodeID, position: position, at: now)
        // The checkpoint and the LWW stamp are one logical update. Stamping later (after a full
        // save) left a tiny kill window where progress.json contained the new position but the old
        // conflict timestamp, allowing a delayed Watch/Cloud value to win after relaunch.
        stampProgress(episodeID, now)
        pendingCloudPush.insert(episodeID)
        // Persist opportunistically; not on every tick. The push flushes when saveProgress runs.
    }

    /// Fold the live playhead into the published structs — one objectWillChange, at a moment
    /// that matters. Safe to call redundantly; no-op when nothing is pending.
    func commitLiveProgress() {
        guard let live else { return }
        guard let idx = podcasts.firstIndex(where: { $0.id == live.podcastID }) else {
            self.live = nil
            return
        }
        podcasts[idx].currentEpisodeID = live.episodeID
        podcasts[idx].positions[live.episodeID] = live.position
        podcasts[idx].lastPlayedAt = live.at
        self.live = nil
    }

    func markCompleted(podcastID: UUID, episodeID: String) {
        markCompleted(podcastID: podcastID, episodeIDs: [episodeID])
    }

    func markCompleted(podcastID: UUID, episodeIDs: [String]) {
        commitLiveProgress()   // fold the playhead first — this mutation publishes anyway
        guard let idx = podcasts.firstIndex(where: { $0.id == podcastID }) else { return }
        for id in episodeIDs {
            podcasts[idx].completed.insert(id)
            podcasts[idx].positions[id] = nil
            noteLocalProgress(id)           // stamp so a stale remote can't un-complete it
            pendingCloudPush.insert(id)
        }
        saveProgress()   // progress-only: no need to rewrite the catalogue
        // Announce rather than call: DownloadManager already holds a reference to the library, so
        // reaching back the other way would close a retain cycle between the two.
        announceCompleted(podcastID: podcastID, episodeIDs: episodeIDs)
    }

    func markUnplayed(podcastID: UUID, episodeID: String) {
        markUnplayed(podcastID: podcastID, episodeIDs: [episodeID])
    }

    /// - Parameter positions: where each episode had got to, for the Undo after "Mark as
    ///   Played" (which clears them) — so undoing puts you back where you were.
    func markUnplayed(podcastID: UUID, episodeIDs: [String], restoring positions: [String: Double] = [:]) {
        commitLiveProgress()   // fold the playhead first — this mutation publishes anyway
        guard let idx = podcasts.firstIndex(where: { $0.id == podcastID }) else { return }
        for id in episodeIDs {
            podcasts[idx].completed.remove(id)
            if let position = positions[id] { podcasts[idx].positions[id] = position }
            noteLocalProgress(id)
            pendingCloudPush.insert(id)
        }
        saveProgress()
    }

    // MARK: - Cross-device progress sync

    /// Per-episode timestamp of the last progress we applied (from either device), so a
    /// stale update can't regress a newer one. Persisted inside progress.json (pruned to
    /// episodes that still carry progress) — it used to be an UNBOUNDED UserDefaults dictionary
    /// rewritten wholesale on every single stamp, i.e. on every pause, forever.
    private var progressSyncedAt: [String: Date] = [:]

    /// When this episode's progress was last stamped, local or remote. Used to decide who owns
    /// "current" when another device reports in while this one is paused.
    func progressStamp(for episodeID: String) -> Date? { progressSyncedAt[episodeID] }

    /// What this device currently has loaded, so a merge can tell whether it is actively
    /// listening to something else. Weak — `PlayerController` owns the library, not the reverse.
    weak var player: PlayerController?

    /// Fired when "current episode" moved, so the Watch can be told.
    ///
    /// A CloudKit merge moves current with no local playback at all, and nothing was watching for
    /// that: the push to the Watch hung off player state changes, so a handoff from the Mac
    /// updated the phone and stopped dead there. The phone is the Watch's only route to the rest
    /// of the world; it has to relay a change it didn't cause.
    var onCurrentEpisodeChanged: (() -> Void)?

    /// The episode this device would resume, and when that feed was last listened to.
    ///
    /// Mirrors the election `PlayerController.restorePaused` makes, exposed because "what the
    /// player currently holds" and "what we would resume" are different things — and only the
    /// second one is worth handing to another device. They diverge exactly when current moved
    /// without playback, which is the case that was broken.
    func resumeTarget() -> (episodeID: String, at: Date)? {
        podcasts
            .compactMap { podcast -> (String, Date)? in
                guard let id = podcast.currentEpisodeID,
                      podcast.episode(id) != nil,
                      !podcast.completed.contains(id),
                      let at = podcast.lastPlayedAt else { return nil }
                return (id, at)
            }
            .max { $0.1 < $1.1 }
            .map { (episodeID: $0.0, at: $0.1) }
    }

    /// Whether a report from another device should take over "current episode", not just position.
    ///
    /// ONE rule, every remote origin. It used to live inline in `PhoneConnectivity`, reachable
    /// only from the Watch relay — which is exactly why the CloudKit path gave up and passed
    /// `makeCurrent: false`, and why the Mac could never hand an episode over at all despite
    /// being a full player. A rule that only one caller can reach isn't a rule, it's a special
    /// case.
    ///
    /// Two parts, both load-bearing:
    ///  - Never take over while this device is actively playing something else. Pressing play
    ///    here has to outrank a report from a device sitting in a pocket.
    ///  - Otherwise recency decides. Pausing must not surrender what is loaded — that was the
    ///    original bug, where a paused phone lost its episode to any Watch report at all — but a
    ///    device that genuinely listened more recently has to win, or handoff never happens.
    func remoteReportShouldTakeCurrent(episodeID: String, at: Date) -> Bool {
        let loaded = player?.currentEpisode?.id
        let playingSomethingElse = (player?.isPlaying ?? false) && loaded != episodeID
        guard !playingSomethingElse else { return false }
        guard let loaded, loaded != episodeID else { return true }
        return at > (progressStamp(for: loaded) ?? .distantPast)
    }

    private func stampProgress(_ episodeID: String, _ at: Date) {
        progressSyncedAt[episodeID] = at
        // Persisted by the next saveProgress — every stamping path saves within the same beat.
    }

    /// Mark that WE just advanced this episode locally, so a late/stale Watch update
    /// can't regress it (last-write-wins baseline).
    func noteLocalProgress(_ episodeID: String) { stampProgress(episodeID, Date()) }

    /// Episodes whose progress changed locally and hasn't been handed to CloudKit yet. Flushed to
    /// `CloudProgressSync` when progress is next persisted, so we push per-episode (not the whole set).
    private var pendingCloudPush: Set<String> = []

    /// Apply a resume position / completion that came from the Watch or from CloudKit. Strictly
    /// last-write-wins by `at` — completion included, see the guard below.
    ///
    /// `makeCurrent` also promotes the episode to the feed's "current" one, so hitting play
    /// on the phone resumes what the Watch was listening to instead of jumping to the newest
    /// unplayed episode. The caller passes `false` when the phone is already playing something
    /// else, so a late-arriving Watch report can't yank the feed out from under it.
    ///
    /// `pushToCloud` is true for genuinely-local origins (the Watch relay counts — the phone is the
    /// hub that carries Watch progress up to iCloud). It's false when the change CAME from CloudKit,
    /// so applying it doesn't echo straight back and ping-pong the record.
    @discardableResult
    func applyRemoteProgress(episodeID: String, position: Double, completed: Bool,
                             at rawAt: Date, makeCurrent: Bool = true, pushToCloud: Bool = true) -> Bool {
        // A remote batch already folded the live playhead once, up front, before snapshotting
        // remoteBatchOwnerIndex — see applyingRemoteBatch. Outside a batch (the Watch relay path)
        // this still folds per call, exactly as before.
        if remoteBatchDepth == 0 { commitLiveProgress() }
        let idx: Int?
        if let remoteBatchOwnerIndex {
            idx = remoteBatchOwnerIndex[episodeID]
        } else {
            idx = podcasts.firstIndex(where: {
                $0.episode(episodeID) != nil || $0.positions[episodeID] != nil || $0.completed.contains(episodeID)
            })
        }
        guard let idx else { return false }
        // Every remote origin — the Watch relay and CloudKit — funnels through here, so this is
        // the single place a foreign clock has to be bounded. See PlaybackSyncClock.
        if PlaybackSyncClock.isSkewed(rawAt) {
            Log.sync.notice("phone: remote stamp for \(episodeID, privacy: .public) is in the future — clock skew, clamping")
        }
        let at = PlaybackSyncClock.received(rawAt)
        // Strictly last-write-wins, completion included.
        //
        // This read `prev >= at, !completed`, which meant ANY completion applied no matter how
        // old. Completion is destructive — it clears the saved position — so a completion queued
        // on an offline Watch could land after you had restarted the episode on the phone and
        // wipe a live playhead mid-listen. The intent was "completion is monotonic"; what it
        // actually said was "completion is unconditional".
        //
        // Ordering alone gives the intended behaviour. An older in-progress report can't
        // un-complete anything, because it loses on the timestamp. A NEWER one should, because
        // restarting a finished episode is precisely what that means.
        if let prev = progressSyncedAt[episodeID] {
            if ProgressTie.isTie(prev, at) {
                // Stamped alike: the tie rule, not whichever copy a device happened to have.
                let local = ProgressTie.Copy(completed: podcasts[idx].completed.contains(episodeID),
                                             position: podcasts[idx].positions[episodeID])
                guard ProgressTie.beats(.init(completed: completed, position: position), local) else { return false }
            } else if prev > at {
                return false
            }
        }
        stampProgress(episodeID, at)
        if completed {
            let newlyFinished = podcasts[idx].completed.insert(episodeID).inserted
            podcasts[idx].positions[episodeID] = nil
            if podcasts[idx].currentEpisodeID == episodeID { podcasts[idx].currentEpisodeID = nil }
            if newlyFinished {
                let podcastID = podcasts[idx].id
                if remoteBatchDepth > 0 { deferredCompletions[podcastID, default: []].append(episodeID) }
                else { announceCompleted(podcastID: podcastID, episodeIDs: [episodeID]) }
            }
        } else {
            // This update is newer than whatever marked the episode finished, so un-complete it.
            // Without this the episode kept a position AND stayed in `completed` — it reads as
            // finished everywhere while quietly holding a playhead nothing will ever resume.
            podcasts[idx].completed.remove(episodeID)
            podcasts[idx].positions[episodeID] = position
            // These two are halves of ONE fact — "this feed was last listened to at `at`, on this
            // episode" — so they have to move together. They didn't: `currentEpisodeID` was set
            // unconditionally while `lastPlayedAt` only ever moved forward. A late or
            // out-of-order report could therefore point the feed at an OLD episode while leaving
            // its recency claim high, and the resume election would pick the feed and then play
            // the wrong thing. Harmless while only the Watch could get here (it reports what it
            // just played); not harmless once CloudKit can, because a re-sync replays arbitrarily
            // old records in arbitrary order.
            if makeCurrent, (podcasts[idx].lastPlayedAt ?? .distantPast) < at {
                podcasts[idx].currentEpisodeID = episodeID
                podcasts[idx].lastPlayedAt = at
            }
        }
        if pushToCloud { pendingCloudPush.insert(episodeID) }
        if remoteBatchDepth > 0 { deferredProgressSave = true } else { saveProgress() }
        // Relay onward. Fired for any accepted merge rather than only when the episode id
        // changed, because the *stamp* moving matters too — it is what the Watch's own
        // last-write-wins compares against. The listener de-dupes, so a cloud batch that replays
        // fifty records still results in at most one push (now exactly one, deferred to batch end
        // when running inside applyingRemoteBatch).
        if remoteBatchDepth > 0 { deferredCurrentChanged = true } else { onCurrentEpisodeChanged?() }
        return true
    }

    // MARK: - CloudKit progress (per-episode records; the operational sync layer)

    /// One episode's current progress, for building a CloudKit record. `updatedAt` is the LWW stamp
    /// so the same rule governs cloud merges as Watch merges.
    struct ProgressValue { var position: Double; var completed: Bool; var updatedAt: Date }

    func progressValue(episodeID: String) -> ProgressValue? {
        // The un-folded playhead is the freshest truth for the playing episode.
        if let live, live.episodeID == episodeID {
            return ProgressValue(position: live.position, completed: false, updatedAt: live.at)
        }
        for p in podcasts {
            if p.completed.contains(episodeID) {
                return ProgressValue(position: 0, completed: true,
                                     updatedAt: progressSyncedAt[episodeID] ?? p.lastPlayedAt ?? Date())
            }
            if let pos = p.positions[episodeID] {
                return ProgressValue(position: pos, completed: false,
                                     updatedAt: progressSyncedAt[episodeID] ?? p.lastPlayedAt ?? Date())
            }
        }
        return nil
    }

    /// Whether this device has the episode: in a feed, or with progress of its own. Within a remote
    /// batch this is the batch's index, not a scan.
    func knowsEpisode(_ id: String) -> Bool {
        if let remoteBatchOwnerIndex { return remoteBatchOwnerIndex[id] != nil }
        return podcasts.contains { $0.episode(id) != nil || $0.positions[id] != nil || $0.completed.contains(id) }
    }

    /// Every episode this device has, for checking many at once.
    func knownEpisodeIDs() -> Set<String> {
        var ids = Set<String>()
        for p in podcasts {
            for e in p.episodes { ids.insert(e.id) }
            ids.formUnion(p.positions.keys)
            ids.formUnion(p.completed)
        }
        return ids
    }

    /// Every episode that carries progress — used to seed CloudKit on first run.
    func allProgressEpisodeIDs() -> [String] {
        var ids = Set<String>()
        for p in podcasts { ids.formUnion(p.positions.keys); ids.formUnion(p.completed) }
        if let live { ids.insert(live.episodeID) }
        return Array(ids)
    }

    /// Whether this device's copy beats one from CloudKit stamped at the same moment — then
    /// CloudKit holds the losing copy, and ours has to go up again for the others to settle.
    func localWinsTie(episodeID: String, position: Double, completed: Bool, at rawAt: Date) -> Bool {
        guard let prev = progressSyncedAt[episodeID],
              ProgressTie.isTie(prev, PlaybackSyncClock.received(rawAt)),
              let podcast = podcasts.first(where: {
                  $0.episode(episodeID) != nil || $0.positions[episodeID] != nil || $0.completed.contains(episodeID)
              }) else { return false }
        let local = ProgressTie.Copy(completed: podcast.completed.contains(episodeID),
                                     position: podcast.positions[episodeID])
        return ProgressTie.beats(local, .init(completed: completed, position: position))
    }

    /// Apply a progress record that arrived FROM CloudKit. Same LWW merge as the Watch path, but
    /// never re-queued for upload (pushToCloud: false), so it can't echo back to the cloud.
    /// Returns whether it actually changed anything (so the caller can avoid a needless UI churn).
    ///
    /// This passed `makeCurrent: false` — CloudKit could move a position but never "which episode
    /// you are on". So listening on the Mac and then picking up the phone resumed something else:
    /// the Mac is a full player, but the only channel that could hand an episode over was the
    /// Watch's. It now goes through the same ownership rule as every other remote origin.
    ///
    /// Nothing echoes: taking current writes locally only, and no device ever pushes a current
    /// claim to CloudKit — the claim is *derived* from which progress record is most recent.
    @discardableResult
    func applyCloudProgress(episodeID: String, position: Double, completed: Bool, at: Date) -> Bool {
        applyRemoteProgress(
            episodeID: episodeID, position: position, completed: completed, at: at,
            makeCurrent: remoteReportShouldTakeCurrent(episodeID: episodeID, at: at),
            pushToCloud: false)
    }

    /// Hand the accumulated local changes to CloudKit and clear the queue. No-op if sync is off.
    private func flushCloudPush() {
        guard !pendingCloudPush.isEmpty else { return }
        let ids = Array(pendingCloudPush)
        pendingCloudPush.removeAll()
        CloudProgressSync.shared.enqueue(ids)
        // And to the data platform (docs/design/DATA-PLATFORM.md): the legacy sync's mode
        // decides whether iCloud still gets it.
        SyncReport.changed(PodcastProgressAdapter.type, ids)
    }

    /// For a cue's pool of shows, in PRIORITY order: the first show that still has an
    /// unfinished episode (its in-progress one, else its next unplayed) wins. Drops to
    /// the next show when the current one is caught up. Nil if everything's played.
    func nextInPool(_ ids: [UUID]) -> (episode: Episode, podcast: Podcast)? {
        for id in ids {
            guard let p = podcast(id), let ep = p.nextEpisode(voiceOf: NarratorVoiceStore.shared.lookup()),
                  !p.completed.contains(ep.id) else { continue }
            return (ep, p)
        }
        return nil
    }

    /// Persist the playhead. Called every 30s of playback — so it writes ONLY the small progress
    /// checkpoint. The lifetime progress snapshot is written at pause/stop/switch/background,
    /// while this tiny record limits crash loss to at most one heartbeat without repeatedly
    /// scanning and encoding every episode ever played.
    func saveLiveProgressCheckpoint(enqueueCloud: Bool = false) {
        #if PERFORMANCE_TESTING
        guard !usesPerformanceCatalogue else { return }
        #endif
        guard let live else { return }
        let checkpoint = PlayheadCheckpoint(
            podcastID: live.podcastID,
            episodeID: live.episodeID,
            position: live.position,
            at: live.at)
        guard let data = try? JSONEncoder().encode(checkpoint) else { return }
        try? data.write(to: checkpointURL, options: .atomic)
        // Starting/switching playback is already a CloudKit commit point. The 30-second crash
        // heartbeat is not: feeding CKSyncEngine twice a minute still makes it persist engine
        // bookkeeping even though its radio cadence is manual.
        if enqueueCloud { flushCloudPush() }
        CloudBackup.shared.schedule()   // dirty-mark only
    }

    /// Full durable snapshot for real state transitions, not the periodic heartbeat.
    func saveProgressSnapshot() { saveProgress() }

    #if DEBUG
    /// A deterministic catalogue of real shows for screenshots. It never writes to disk and
    /// prevents the in-flight production catalogue load from merging personal subscriptions.
    /// Artwork ships as bundled fixtures (`PreviewArtwork/`) seeded straight into `ImageCache`,
    /// so rows render original synthetic sample covers without a network fetch.
    func injectSampleForPreview() {
        usesPreviewCatalogue = true
        struct PreviewShow {
            let title: String
            let author: String
            let artworkAsset: String
            let episodes: [String]
            let unplayed: Int
        }
        let shows = [
            PreviewShow(
                title: "Acquired",
                author: "Ben Gilbert and David Rosenthal",
                artworkAsset: "acquired",
                episodes: [
                    "The Complete History & Strategy of Costco",
                    "Microsoft Volume II",
                    "Rolex: Timeless Excellence",
                    "The Mars Inc. Story",
                ],
                unplayed: 1),
            PreviewShow(
                title: "ACQ2",
                author: "Ben Gilbert and David Rosenthal",
                artworkAsset: "acq2",
                episodes: [
                    "Building an Enduring Franchise",
                    "The Business of Winning",
                    "Scaling Past the First Product",
                ],
                unplayed: 2),
            PreviewShow(
                title: "Complex Systems",
                author: "Patrick McKenzie (patio11)",
                artworkAsset: "complex-systems",
                episodes: [
                    "How money actually moves between banks",
                    "The infrastructure behind boring magic",
                    "Reading the fine print, professionally",
                ],
                unplayed: 1),
            PreviewShow(
                title: "Gamecraft",
                author: "Mitch Lasky and Blake Robbins",
                artworkAsset: "gamecraft",
                episodes: [
                    "The Rise of Live Services",
                    "Distribution Is Destiny",
                    "Platforms, Stores, and Power",
                ],
                unplayed: 2),
            PreviewShow(
                title: "Stepchange",
                author: "Ben Shwab Eidelson and Anay Shah",
                artworkAsset: "step-change",
                episodes: [
                    "Solar's Exponential Decade",
                    "Batteries: The Grid's New Backbone",
                ],
                unplayed: 1),
            PreviewShow(
                title: "Get Sleepy",
                author: "Slumber Studios",
                artworkAsset: "get-sleepy",
                episodes: [
                    "The Lighthouse by the Bay",
                    "A Slow Train Through the Alps",
                    "The Night Gardener",
                ],
                unplayed: 1),
        ]
        podcasts = shows.enumerated().map { index, show in
            let artworkURL = URL(
                string: "https://preview.banana.invalid/artwork/\(show.artworkAsset).jpg")!
            if let asset = Bundle.main.url(
                    forResource: show.artworkAsset, withExtension: "jpg"),
               let data = try? Data(contentsOf: asset) {
                ImageCache.shared.injectPreviewOriginal(data, for: artworkURL)
            }
            let episodes = show.episodes.enumerated().map { episodeIndex, episodeTitle in
                var episode = Episode(
                    id: "preview-\(index)-\(episodeIndex)",
                    title: episodeTitle,
                    audioURL: URL(
                        string: "https://preview.banana.invalid/audio/\(index)-\(episodeIndex).m4a")!,
                    pubDate: Date().addingTimeInterval(
                        Double(-(episodeIndex * 6 + index + 1)) * 86_400),
                    duration: [3_900, 2_400, 5_100, 1_800][episodeIndex % 4]
                )
                // Show notes in the shape feeds send them, for the player's notes panel and the
                // Episode info sheet.
                episode.summary = "<p>\(episodeTitle) — the full story, from the founding to today.</p>"
                    + "<p>Sponsored by <a href=\"https://example.com/offer\">Example</a>.</p>"
                    + "<ul><li>00:00 Intro</li><li>12:30 The early years</li><li>41:05 What came next</li></ul>"
                return episode
            }
            var podcast = Podcast(
                feedURL: URL(
                    string: "https://preview.banana.invalid/feed/\(show.artworkAsset).xml")!,
                title: show.title,
                author: show.author,
                artworkURL: artworkURL,
                episodes: episodes
            )
            podcast.completed = Set(episodes.dropFirst(show.unplayed).map(\.id))
            return podcast
        }
        isLoaded = true
    }

    /// Seed a library without the network, so the progress split can be proven in the Simulator.
    func debugSeed(_ seeded: [Podcast]) {
        podcasts = seeded
        save()
    }
    func debugCatalogueURL() -> URL { fileURL }
    func debugProgressURL() -> URL { progressURL }
    #endif

    #if PERFORMANCE_TESTING
    /// Replace the in-memory catalogue for an isolated performance run without touching the
    /// person's persisted subscriptions or progress. The host still uses a dedicated test
    /// container, but this prevents an interrupted run from contaminating normal app state.
    func installPerformanceFixture(_ seeded: [Podcast]) {
        usesPerformanceCatalogue = true
        live = nil
        podcasts = seeded
    }
    #endif

    // MARK: - Persistence
    //
    // Progress lives in its own small file, separate from the catalogue.
    //
    // `podcasts.json` holds every episode of every feed — titles, URLs, full show notes — which is
    // megabytes for a real library. It used to be re-encoded and rewritten on the main thread every
    // 30 seconds of listening, because the playhead was stored inside it.
    //
    // The catalogue file is deliberately UNCHANGED in shape: it still carries its own copy of the
    // progress fields. `progress.json` simply overlays it on load. That means there is no schema
    // migration, and if the progress file is missing (first run after this change, or a restore from
    // an older backup) the embedded values are used exactly as before. There is no way for this to
    // lose a play position.

    private var progressURL: URL {
        let dir = AppSupport.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("progress.json")
    }

    private var checkpointURL: URL {
        let dir = AppSupport.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("live-progress.json")
    }

    private struct PlayheadCheckpoint: Codable, Sendable {
        var podcastID: UUID
        var episodeID: String
        var position: Double
        var at: Date
    }

    /// Just the listening state: a few KB, regardless of how big the catalogue is.
    private struct StoredProgress: Codable {
        var positions: [String: [String: Double]] = [:]     // podcastID → episodeID → seconds
        var completed: [String: [String]] = [:]
        var currentEpisodeID: [String: String] = [:]
        var lastPlayedAt: [String: Date] = [:]
        var syncedAt: [String: Date]?                        // episodeID → LWW stamp (nil in old files)
    }

    /// Re-read from disk, synchronously (an iCloud restore rewrites the files underneath us —
    /// rare, user-initiated, and the caller wants the result now). Same transactional import
    /// treatment as `init()`'s background load, so a corrupt file encountered mid-session (e.g.
    /// mid-restore) is preserved rather than risking getting overwritten by the very next save().
    func reloadFromDisk() {
        do {
            // A valid restore can also recover a catalog whose first import failed.
            let opened = try catalog ?? PodcastCatalog.open(at: fileURL.deletingLastPathComponent().appendingPathComponent("podcast-catalog.sqlite"))
            let restored = try opened.load(legacyURL: fileURL, forceImport: true)
            catalog = opened
            podcasts = restored
            catalogLoadFailed = false
            catalogSaveIsUnsafe = false
        } catch {
            errorMessage = "The restored podcast library could not be opened. Existing data was preserved. \(error.localizedDescription)"
            return
        }
        let stored = (try? Data(contentsOf: progressURL))
            .flatMap { try? JSONDecoder().decode(StoredProgress.self, from: $0) }
        applyStoredProgress(stored)
        let checkpoint = (try? Data(contentsOf: checkpointURL))
            .flatMap { try? JSONDecoder().decode(PlayheadCheckpoint.self, from: $0) }
        if let checkpoint { applyCheckpoint(checkpoint) }
    }

    /// Overlay the progress file onto the catalogue. Absent file → keep whatever the catalogue had.
    private func applyStoredProgress(_ stored: StoredProgress?) {
        guard let stored else { return }
        for i in podcasts.indices {
            let key = podcasts[i].id.uuidString
            if let positions = stored.positions[key] { podcasts[i].positions = positions }
            if let completed = stored.completed[key] { podcasts[i].completed = Set(completed) }
            if let current = stored.currentEpisodeID[key] { podcasts[i].currentEpisodeID = current }
            if let played = stored.lastPlayedAt[key] { podcasts[i].lastPlayedAt = played }
        }
    }

    /// Overlay the latest tiny crash checkpoint after the full snapshot. It is intentionally
    /// promoted into normal progress rather than kept as `live`: after a relaunch playback is
    /// paused, and every caller should see the recovered position through the ordinary model.
    private func applyCheckpoint(_ checkpoint: PlayheadCheckpoint) {
        guard let idx = podcasts.firstIndex(where: {
            $0.id == checkpoint.podcastID
                && $0.episode(checkpoint.episodeID) != nil
        }) else { return }
        let fullStamp = progressSyncedAt[checkpoint.episodeID] ?? .distantPast
        guard checkpoint.at > fullStamp else { return }
        podcasts[idx].positions[checkpoint.episodeID] = checkpoint.position
        podcasts[idx].currentEpisodeID = checkpoint.episodeID
        if (podcasts[idx].lastPlayedAt ?? .distantPast) < checkpoint.at {
            podcasts[idx].lastPlayedAt = checkpoint.at
        }
        progressSyncedAt[checkpoint.episodeID] = checkpoint.at
        pendingCloudPush.insert(checkpoint.episodeID)
    }

    /// Adopt LWW stamps from the progress file, or migrate them from the old UserDefaults home.
    /// Runs unconditionally at load (even with an empty catalogue or missing progress file) —
    /// gating it on catalogue content left the stamps behind on exactly the launches that most
    /// need them (fresh progress file + old defaults).
    ///
    /// The old key is NOT removed here: deleting it before the stamps land in progress.json means
    /// a kill in between loses them for good (and with them the guard against stale remote
    /// progress). `saveProgress` clears it after the first successful persist.
    private var stampMigrationPendingCleanup = false

    private func adoptSyncStamps(_ stored: StoredProgress?) {
        if let synced = stored?.syncedAt {
            progressSyncedAt = synced
        } else {
            progressSyncedAt = (UserDefaults.standard.dictionary(forKey: "progressSyncedAt") as? [String: Double] ?? [:])
                .mapValues { Date(timeIntervalSince1970: $0) }
            stampMigrationPendingCleanup = !progressSyncedAt.isEmpty
        }
    }

    /// Another account signed in on this device and the person said to clear it first
    /// (docs/design/DATA-PLATFORM.md §2): the other account's listening state leaves this device —
    /// positions, finishes, which episode each show is on, and their stamps. This device only:
    /// nothing is reported to any sync, nothing waiting for CloudKit goes, and no backup is
    /// scheduled. Only the account-change clear calls this.
    func clearProgressForAccountChange() {
        live = nil
        for index in podcasts.indices {
            podcasts[index].positions = [:]
            podcasts[index].completed = []
            podcasts[index].currentEpisodeID = nil
            podcasts[index].lastPlayedAt = nil
        }
        progressSyncedAt = [:]
        pendingCloudPush.removeAll()
        saveProgress(reporting: false)
    }

    /// Write ONLY the progress file. This is the hot path. `reporting: false` (the account-change
    /// clear only): nothing is handed to CloudKit and no backup is scheduled.
    private func saveProgress(reporting: Bool = true) {
        #if PERFORMANCE_TESTING
        guard !usesPerformanceCatalogue else { return }
        #endif
        // `podcasts` being empty is only a trustworthy "zero progress" when the catalogue
        // actually decoded that way. When podcasts.json failed to decode this launch instead,
        // `podcasts` is empty for a reason that has nothing to do with progress.json — a
        // perfectly valid, independent file — and writing here would silently wipe every
        // playback position and completed-episode mark it holds. See `catalogLoadFailed`.
        guard !catalogLoadFailed else {
            Self.log.fault("saveProgress() refused: podcasts.json failed to decode this launch, so an empty catalogue isn't trustworthy — writing now would overwrite a perfectly valid progress.json with emptiness derived from the broken catalogue. The original catalog files have been preserved.")
            return
        }
        let sp = Signpost.begin("saveProgress")
        defer { Signpost.end(sp) }
        var stored = StoredProgress()
        for podcast in podcasts {
            let key = podcast.id.uuidString
            stored.positions[key] = podcast.positions
            stored.completed[key] = Array(podcast.completed)
            if let current = podcast.currentEpisodeID { stored.currentEpisodeID[key] = current }
            if let played = podcast.lastPlayedAt { stored.lastPlayedAt[key] = played }
        }
        // Merge the un-folded playhead so the file is always current — the fold only defers the
        // UI publish, never what's on disk. A kill between folds loses nothing.
        if let live {
            let key = live.podcastID.uuidString
            stored.positions[key, default: [:]][live.episodeID] = live.position
            stored.currentEpisodeID[key] = live.episodeID
            stored.lastPlayedAt[key] = live.at
        }
        // LWW stamps ride along, pruned to episodes that still carry progress — a stamp with no
        // progress guards nothing, and unpruned this dictionary only ever grew.
        var known = Set<String>()
        for podcast in podcasts { known.formUnion(podcast.positions.keys); known.formUnion(podcast.completed) }
        if let live { known.insert(live.episodeID) }
        stored.syncedAt = progressSyncedAt.filter { known.contains($0.key) }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        do {
            try data.write(to: progressURL, options: .atomic)
            // The full file now contains this playhead (including the un-folded `live` value).
            // Delete only after the atomic write succeeds; a kill before then leaves recovery.
            try? FileManager.default.removeItem(at: checkpointURL)
            if stampMigrationPendingCleanup {
                // The stamps are safely in the file now — the legacy UserDefaults copy can go.
                UserDefaults.standard.removeObject(forKey: "progressSyncedAt")
                stampMigrationPendingCleanup = false
            }
        } catch {}
        guard reporting else { return }
        flushCloudPush()
        CloudBackup.shared.schedule()   // dirty-mark only — the snapshot itself runs on background
    }

    /// Persist metadata and newly staged feeds, reusing unchanged episode snapshots.
    /// Progress is saved separately after the catalog transaction succeeds.
    private func save() {
        #if PERFORMANCE_TESTING
        guard !usesPerformanceCatalogue else { return }
        #endif
        // Do not replace a catalog that failed to open or migrate.
        guard !catalogSaveIsUnsafe else {
            Self.log.fault("save() refused: the catalog failed to open or migrate. Existing files were preserved.")
            return
        }
        #if DEBUG
        guard !usesPreviewCatalogue else { return }
        #endif
        guard let catalog else { return }
        do {
            let persisted = try catalog.save(podcasts)
            // One publication only when in-memory feed bodies became disk handles. A settings
            // write or progress flush must not feed another identical catalog back into SwiftUI.
            if podcasts != persisted { podcasts = persisted }
            Task.detached(priority: .utility) { try? catalog.reclaimRetiredSnapshots() }
            saveProgress()
        } catch {
            errorMessage = "The podcast library could not be saved. \(error.localizedDescription)"
        }
    }
}

extension Notification.Name {
    /// Episodes were marked finished. `DownloadManager` listens so the disk they were using can be
    /// reclaimed immediately rather than at whatever feed refresh happens to come next.
    static let podcastEpisodesCompleted = Notification.Name("banana.podcast.episodesCompleted")
}

// The library is the same on every device (CloudControlsSync): which shows you subscribe to, and
// each one's settings. Never episodes or progress — episodes come from each show's feed, progress
// has its own sync.
extension PodcastLibrary: CloudControlSource {
    func cloudItems(_ kind: ControlKind) -> [String: Data] {
        guard isLoaded else { return [:] }
        let encoder = JSONEncoder()
        var items: [String: Data] = [:]
        for podcast in podcasts {
            switch kind {
            case .show: items[podcast.id.uuidString] = try? encoder.encode(PodcastSubscription(podcast))
            case .podcast: items[podcast.id.uuidString] = try? encoder.encode(PodcastSettings(podcast))
            default: break
            }
        }
        return items
    }

    func applyCloud(_ kind: ControlKind, id: String, item: Data?) -> Bool {
        // Before the catalogue has loaded nothing can be matched: not seen yet, so read again later.
        guard isLoaded, let uuid = UUID(uuidString: id) else { return isLoaded }
        switch kind {
        case .show: return applyCloudShow(uuid, item: item)
        case .podcast: return applyCloudSettings(uuid, item: item)
        default: return true
        }
    }

    /// Subscribed or unsubscribed on another device.
    private func applyCloudShow(_ id: UUID, item: Data?) -> Bool {
        guard let item else {
            guard let podcast = podcasts.first(where: { $0.id == id }) else { return true }
            remove(id)
            onShowRemovedFromCloud?(podcast)
            return true
        }
        guard let subscription = try? JSONDecoder().decode(PodcastSubscription.self, from: item) else { return true }
        if podcasts.contains(where: { $0.id == id }) { return true }
        // Subscribed to the same feed on two devices before either had synced: keep this one's.
        if podcasts.contains(where: { $0.feedURL == subscription.feedURL }) { return true }
        podcasts.append(subscription.podcast(id: id))
        save()
        noteShowArrived(id)
        return true
    }

    /// A show's settings changed on another device. For a show that isn't here yet, false: they
    /// apply once it arrives (`CloudControlsSync.refetchAll`).
    private func applyCloudSettings(_ id: UUID, item: Data?) -> Bool {
        guard let item else { return true }   // settings are never deleted, only their show
        guard let index = podcasts.firstIndex(where: { $0.id == id }) else { return false }
        guard let settings = try? JSONDecoder().decode(PodcastSettings.self, from: item) else { return true }
        let old = podcasts[index]
        let new = settings.applied(to: old)
        guard new != old else { return true }
        podcasts[index] = new
        save()
        onCloudSettingsApplied?(old, new)
        return true
    }

    /// Shows arriving from another device come in a batch; they're handed on together, once.
    private func noteShowArrived(_ id: UUID) {
        showsArrived.insert(id)
        showsArrivedFlush?.cancel()
        showsArrivedFlush = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            let ids = self.showsArrived
            self.showsArrived.removeAll()
            self.onShowsArrivedFromCloud?(ids)
        }
    }
}

// The data platform (docs/design/DATA-PLATFORM.md): `PodcastProgressAdapter`, through the same
// last-write-wins merge CloudKit's progress goes through.
extension PodcastLibrary: ProgressSyncSource {
    func syncProgressEpisodeIDs() -> [String] { allProgressEpisodeIDs() }

    /// The progress with its real stamp: the last-write-wins stamp, else the show's last play,
    /// else none. Never "now" (`progressValue` makes one up for CloudKit's records): progress of
    /// unknown age must not pose as new.
    func syncProgress(_ episodeID: String) -> EpisodeProgressRecord? {
        guard let value = progressValue(episodeID: episodeID) else { return nil }
        let stamp: Date?
        if let live, live.episodeID == episodeID {
            stamp = live.at
        } else {
            stamp = progressSyncedAt[episodeID]
                ?? podcasts.first(where: { $0.positions[episodeID] != nil || $0.completed.contains(episodeID) })?.lastPlayedAt
        }
        return EpisodeProgressRecord(position: value.completed ? 0 : value.position, completed: value.completed, updatedAt: stamp)
    }

    func applySyncedProgress(_ episodeID: String, _ progress: EpisodeProgressRecord) -> Bool {
        applyCloudProgress(episodeID: episodeID, position: progress.position, completed: progress.completed,
                           at: progress.updatedAt ?? .distantPast)
    }

    func applyingSyncedBatch(_ body: () -> Void) { applyingRemoteBatch(body) }
}
