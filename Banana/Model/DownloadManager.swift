import Foundation
import SwiftUI
import MultipeerConnectivity
import CryptoKit

/// Downloads episode audio to local files for offline playback, tracks per-episode
/// state, and (when a feed opts in) hands finished files to `PhoneConnectivity`
/// for transfer to the Watch.
@MainActor
final class DownloadManager: NSObject, ObservableObject {
    enum State: Equatable {
        case none
        case waitingForWiFi        // handed to the system; it will start it when Wi-Fi is back
        case downloading(Double)   // 0...1
        case downloaded
        case failed
    }

    @Published private(set) var states: [String: State] = [:]   // episodeID -> state

    /// The moving download fraction, on its own object — the PlaybackClock pattern.
    ///
    /// Percent updates used to mutate `states`, republishing the WHOLE manager up to 100 times
    /// per download: every podcast row's badge and every episode row re-rendered per tick.
    /// `states` now publishes only real transitions (start/held/done/failed); the ring that
    /// genuinely displays the moving number is a child view observing this instead.
    @MainActor
    final class ProgressTicker: ObservableObject {
        @Published fileprivate(set) var fractions: [String: Double] = [:]
    }
    let progressTicker = ProgressTicker()

    weak var connectivity: PhoneConnectivity?
    /// LAN settings sync bridge (see PodcastPeerTransfer): incoming peer snapshots land here.
    var onPeerSettings: ((Data) -> Void)? {
        didSet {
            PodcastPeerTransfer.shared.onSettingsReceived = { [weak self] data in
                self?.onPeerSettings?(data)
            }
        }
    }

    func broadcastPeerSettings(_ data: Data) {
        PodcastPeerTransfer.shared.broadcastSettings(data)
    }

    /// The LAN pairing code (group trust token) — shown in Settings so devices without
    /// iCloud entitlements can be paired by pasting it. Applies at next launch.
    static var peerPairingToken: String { PodcastPeerTransfer.loadGroupToken() }

    static func setPeerPairingToken(_ token: String) {
        let cleaned = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleaned.isEmpty else { return }
        UserDefaults.standard.set(cleaned, forKey: PodcastPeerTransfer.tokenOverrideKey)
    }
    weak var library: PodcastLibrary?
    weak var settings: AppSettings?
    /// Ad-skip plans. Downloads are where the best evidence in the whole feature arrives: the
    /// host's own response headers, which declare the byte range of every slot it stitched in.
    weak var skipPlans: SkipPlanService?

    @Published private(set) var catalogRevision = 0
    var downloadedEpisodeIDs: Set<String> { Set(index.keys) }
    private var index: [String: String] = [:] {
        didSet { if oldValue != index { catalogRevision &+= 1 } }
    }     // episodeID -> stored filename
    private var manualDownloads: Set<String> = []  // user-initiated (protected from rolling-window pruning)
    private var transferred: Set<String> = []      // episodeIDs confirmed delivered to the Watch
    private var taskEpisode: [Int: String] = [:]   // URLSession task id -> episodeID
    private var taskPodcast: [Int: UUID] = [:]     // task id -> podcast id
    private var activeTasks: [String: URLSessionDownloadTask] = [:]   // episodeID -> task (for cancel)
    private var peerTasks: [String: Task<Void, Never>] = [:]

    /// Compact state for the app-wide power rollup.
    var powerSummary: String {
        let held = states.values.filter {
            if case .waitingForWiFi = $0 { return true }
            return false
        }.count
        return "\(activeTasks.count + peerTasks.count)active/\(held)held"
    }

    /// Two BACKGROUND sessions — one that may use cellular, one that may not.
    ///
    /// Downloads used to run on a `.default` session, so iOS suspending the app killed every
    /// transfer in flight. That is not a nicety: a download that dies is an episode you don't have
    /// on the walk, which is exactly how you end up streaming — and streaming is what stalled and
    /// stopped the audio this morning. A background session hands the transfer to the system, which
    /// finishes it whether we're suspended, killed, or rebooted, and relaunches us to say so.
    ///
    /// Why two sessions rather than one plus `URLRequest.allowsCellularAccess`: for background
    /// transfers the *session's* policy is the one the daemon actually enforces, so the Wi-Fi-only
    /// rule has to live on a session, not on a request. Two sessions makes it deterministic instead
    /// of hoping a per-request flag is honoured out-of-process.
    private lazy var wifiSession: URLSession = Self.makeSession(id: Self.wifiSessionID,
                                                                cellular: false, delegate: self)
    private lazy var cellularSession: URLSession = Self.makeSession(id: Self.cellularSessionID,
                                                                    cellular: true, delegate: self)

    static let wifiSessionID = "com.boris.banana.downloads.wifi"
    static let cellularSessionID = "com.boris.banana.downloads.cellular"

    /// iOS can finish the Wi-Fi and cellular sessions independently. A single completion slot
    /// allowed one callback to overwrite the other, leaving the system waiting forever and
    /// reducing future background-download opportunities.
    private var backgroundCompletionHandlers: [String: () -> Void] = [:]
    private var reattachTask: Task<Void, Never>?
    #if os(iOS)
    /// A background URLSession completion can cold-launch the process without ever constructing
    /// an active scene. Default closed so that path cannot accidentally light up Bonjour; the
    /// iPhone root view opts in only while it is actually foreground-active.
    private var peerServingAllowed = false
    #else
    /// The Mac is the preferred always-available cache source.
    private var peerServingAllowed = true
    #endif

    private static func makeSession(id: String, cellular: Bool, delegate: URLSessionDelegate) -> URLSession {
        let config = URLSessionConfiguration.background(withIdentifier: id)
        config.allowsCellularAccess = cellular
        // Low Data Mode is the person telling the OS to stop spending their data. An in-app check
        // can't enforce that on a transfer the daemon resumes while we're dead, so the rule goes on
        // the session: automatic downloads wait for an unconstrained link. A download you asked for
        // and confirmed is yours to have.
        config.allowsConstrainedNetworkAccess = cellular
        config.allowsExpensiveNetworkAccess = cellular
        config.sessionSendsLaunchEvents = true      // wake us when a transfer finishes
        config.isDiscretionary = false              // the person asked for this episode; don't sit on it
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    private var downloadsDir: URL {
        let dir = AppSupport.directory
            .appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    /// Last published whole-percent per episode, so chunk callbacks don't flood the main actor.
    private var lastPercent: [String: Int] = [:]
    /// Resume data from failed transfers, so a retry continues instead of re-pulling a
    /// 50–150 MB file from byte zero. In-memory: the background daemon already survives our
    /// process for the common cases; this covers the in-session retry.
    private var resumeData: [String: Data] = [:]
    private var resumeDataOrder: [String] = []
    private static let maxResumeCheckpoints = 6
    private var persistenceDeferralDepth = 0
    private var indexDirty = false
    private var manualDirty = false

    private var indexURL: URL { downloadsDir.appendingPathComponent("index.json") }
    private var transferredURL: URL { downloadsDir.appendingPathComponent("transferred.json") }
    private var manualURL: URL { downloadsDir.appendingPathComponent("manual.json") }
    private var instructedURL: URL { downloadsDir.appendingPathComponent("watch-instructed.json") }

    /// When each episode was last told to the Watch (direct-download instruction or file
    /// transfer), so backfill can escalate instead of re-whispering into a dead channel.
    private var watchInstructedAt: [String: Date] = [:]

    override init() {
        super.init()
        #if PERFORMANCE_TESTING && os(iOS)
        // The shipping iPhone default is closed. A/B runs opt in explicitly so future peer-on
        // controls remain reproducible without weakening the production lifecycle invariant.
        if ProcessInfo.processInfo.arguments.contains("--perf-enable-peer-serving") {
            peerServingAllowed = true
        }
        #endif
        loadIndex()   // stays synchronous: the wake path reads localURL(for:) right after launch
        if let data = try? Data(contentsOf: transferredURL),
           let decoded = try? JSONDecoder().decode(Set<String>.self, from: data) {
            transferred = decoded
        }
        if let data = try? Data(contentsOf: manualURL),
           let decoded = try? JSONDecoder().decode(Set<String>.self, from: data) {
            manualDownloads = decoded
        }
        if let data = try? Data(contentsOf: instructedURL),
           let decoded = try? JSONDecoder().decode([String: Date].self, from: data) {
            watchInstructedAt = decoded
        }
        // Deferred: reattaching touches BOTH lazy background URLSessions, and constructing a
        // background session is daemon XPC — it was most of this init's first-frame cost. One
        // beat later is indistinguishable for adopting in-flight transfers, and a launch-for-
        // background-events still gets its session created here long before the system's
        // completion delivery needs it.
        reattachTask = Task { @MainActor [weak self] in
            // Keep URLSession daemon XPC out of first paint. A launch specifically caused by a
            // finished transfer bypasses this delay through handleBackgroundEvents below.
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.reattachBackgroundTasks()
            self?.reattachTask = nil
        }
        if !index.isEmpty {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                self.startPeerSharing()
            }
        }
        LaunchClock.mark("downloads.init")
    }

    /// AppDelegate entry point for a launch caused by one background session. Instantiate exactly
    /// that session immediately instead of eagerly touching both session daemons.
    func handleBackgroundEvents(identifier: String, completion: @escaping () -> Void) {
        guard identifier == Self.wifiSessionID || identifier == Self.cellularSessionID else {
            completion()
            return
        }
        reattachTask?.cancel()
        reattachTask = nil
        backgroundCompletionHandlers[identifier] = completion
        adoptTasks(in: identifier == Self.wifiSessionID ? wifiSession : cellularSession)
    }

    /// After a relaunch the system may still be carrying our transfers. The in-memory task maps are
    /// gone, so adopt whatever is still running rather than showing it as idle (or, worse, starting
    /// it again).
    private func reattachBackgroundTasks() {
        adoptTasks(in: wifiSession)
        adoptTasks(in: cellularSession)
    }

    private func adoptTasks(in session: URLSession) {
        session.getAllTasks { [weak self] tasks in
            Task { @MainActor in
                guard let self else { return }
                for task in tasks {
                    guard let download = task as? URLSessionDownloadTask,
                          let (episodeID, podcastID) = Self.identity(of: task) else { continue }
                    self.taskEpisode[task.taskIdentifier] = episodeID
                    self.taskPodcast[task.taskIdentifier] = podcastID
                    self.activeTasks[episodeID] = download
                    if self.index[episodeID] == nil { self.states[episodeID] = .downloading(0) }
                }
            }
        }
    }

    /// The episode a task belongs to, carried ON the task, because a background download can outlive
    /// the process that started it — including finishing after we've been killed and relaunched.
    /// An in-memory dictionary cannot survive that; `taskDescription` can.
    ///
    /// Podcast UUID first (fixed 36 chars) because an episode ID is an RSS guid and may contain
    /// anything at all, separators included.
    nonisolated private static func identity(of task: URLSessionTask) -> (episodeID: String, podcastID: UUID?)? {
        guard let desc = task.taskDescription, desc.count > 36 else { return nil }
        let podcastID = UUID(uuidString: String(desc.prefix(36)))
        let episodeID = String(desc.dropFirst(37))
        return episodeID.isEmpty ? nil : (episodeID, podcastID)
    }

    private func saveManual() {
        guard persistenceDeferralDepth == 0 else {
            manualDirty = true
            return
        }
        if let data = try? JSONEncoder().encode(manualDownloads) {
            try? data.write(to: manualURL, options: .atomic)
        }
    }

    private func withDeferredPersistence(_ work: () -> Void) {
        persistenceDeferralDepth += 1
        work()
        persistenceDeferralDepth -= 1
        guard persistenceDeferralDepth == 0 else { return }
        if indexDirty {
            indexDirty = false
            saveIndex()
        }
        if manualDirty {
            manualDirty = false
            saveManual()
        }
    }

    // MARK: - Watch backfill

    /// Record that an episode file has been delivered to the Watch (so backfill skips it).
    func markTransferred(_ episodeID: String) {
        transferred.insert(episodeID)
        if let data = try? JSONEncoder().encode(transferred) {
            try? data.write(to: transferredURL, options: .atomic)
        }
        if watchInstructedAt.removeValue(forKey: episodeID) != nil {
            saveWatchInstructed()
        }
    }

    /// Trust the Watch's account of what it holds over our own record of what we sent.
    ///
    /// `transferred` is the phone's belief about past deliveries, and backfill skips everything
    /// in it. Nothing ever contradicted that belief, so anything that emptied the Watch — a
    /// reinstall, or the app removed with its container — stranded those episodes permanently:
    /// gone from the Watch, still marked delivered here, skipped by every future backfill. It
    /// took deleting the phone app during a debugging session to notice, and the recovery was a
    /// Settings button you had to know existed.
    ///
    /// Anything the Watch doesn't list is forgotten, so the next backfill re-sends it. An empty
    /// inventory is meaningful, not a signal to ignore — a wiped Watch is precisely the case
    /// this exists for. The Watch only reports after its store has loaded, so empty means empty.
    func reconcileWatchInventory(_ present: Set<String>) {
        let stale = transferred.subtracting(present)
        guard !stale.isEmpty else { return }
        Log.sync.notice("phone: forgetting \(stale.count, privacy: .public) transfer(s) the Watch no longer has")
        transferred.subtract(stale)
        if let data = try? JSONEncoder().encode(transferred) {
            try? data.write(to: transferredURL, options: .atomic)
        }
        for id in stale { watchInstructedAt.removeValue(forKey: id) }
        saveWatchInstructed()
        backfillWatch()
    }

    /// Send any downloaded-but-not-yet-transferred episodes of Watch-synced feeds.
    /// Covers: "Sync to Watch" toggled on after downloading, or an earlier transfer
    /// that never completed. The Watch de-dupes by episode id, so re-sends are safe.
    ///
    /// Escalation: a direct-download instruction that the Watch hasn't confirmed after an
    /// hour is treated as lost — watchOS defers background downloads indefinitely without
    /// ever *failing* them, so waiting for the Watch's own fallback request can wait
    /// forever. Ship the file over WatchConnectivity instead; the daemon delivers it even
    /// while both apps are closed.
    func backfillWatch() {
        guard let library, connectivity != nil else { return }
        for podcast in library.podcasts where podcast.syncToWatch {
            for episode in podcast.episodes {
                guard isDownloaded(episode.id), !transferred.contains(episode.id) else { continue }
                if let instructed = watchInstructedAt[episode.id] {
                    guard Date().timeIntervalSince(instructed) > 3600 else { continue }
                    markWatchInstructed(episode.id)
                    if let fileURL = localURL(for: episode.id) {
                        sendFile(episodeID: episode.id, title: episode.title, podcast: podcast, fileURL: fileURL)
                    }
                } else {
                    sendToWatch(episode: episode, podcast: podcast)
                }
            }
        }
    }

    /// The one entry point for "keep the catalogue and downloads moving": refresh stale
    /// feeds, then apply every feed's auto-download rule. Launch, foreground, overnight
    /// task, and pull-to-refresh all funnel here; the library throttles and de-dupes.
    func refreshFeedsAndReconcile(
        staleAfter: TimeInterval = 4 * 3600,
        force: Bool = false,
        allowBackgroundExecution: Bool = false
    ) async {
        guard let library else { return }
        await library.refreshAllStale(
            staleAfter: staleAfter,
            force: force,
            allowBackgroundExecution: allowBackgroundExecution
        )
        #if os(iOS)
        guard allowBackgroundExecution || AppVisibility.shared.isActive else { return }
        #endif
        // Each reconcile(_:) ends with a manifest push, so looping the default call over every
        // podcast fired one WatchConnectivity applicationContext transfer per qualifying podcast
        // in a row — every one but the last was superseded (latest-wins) before it could matter.
        // Defer the push out of the loop and send it once, but only when the sweep touched at
        // least one podcast with an active download rule — matching reconcile(_:)'s own guard, so
        // a sweep with nothing to reconcile still sends zero transfers, exactly as today.
        var shouldPushManifest = false
        for podcast in library.podcasts {
            if podcast.downloadRule.count > 0 { shouldPushManifest = true }
            reconcile(podcast, pushManifest: false)
        }
        if shouldPushManifest { pushWatchManifest() }
    }

    private func markWatchInstructed(_ episodeID: String) {
        watchInstructedAt[episodeID] = Date()
        saveWatchInstructed()
    }

    private func saveWatchInstructed() {
        if let data = try? JSONEncoder().encode(watchInstructedAt) {
            try? data.write(to: instructedURL, options: .atomic)
        }
    }

    // MARK: - Narrator voice

    /// Work out what this episode's narrator sounds like, for shows filtering by voice.
    ///
    /// Runs at download time, on a file already on disk, which is also when transcription is
    /// queued — never while someone is listening. Skipped entirely for episodes whose notes name a
    /// narrator: that answer is exact and free, and asking a model to second-guess it would only
    /// introduce a way to be wrong.
    private func classifyNarratorVoiceIfNeeded(episode: Episode, podcast: Podcast) {
        guard !podcast.mutedVoiceGenders.isEmpty else { return }
        let credit = NarratorCredit.name(in: episode.summary)
        // A credited narrator used to skip classification entirely, on the reasoning that the name
        // is exact and free. It is — but a NAME is not a GENDER, so on a show that credits every
        // episode the gender filter had nothing to work with and silently matched nothing. The
        // classifier exists to classify; the credit decides what the verdict gets filed under, not
        // whether to reach one.
        let narrator = credit.map { NarratorCredit.canonical($0, among: podcast.narratorRoster) }
        if let narrator, NarratorVoiceStore.shared.reading(forNarrator: narrator) != nil { return }
        guard NarratorVoiceStore.shared.reading(for: episode.id) == nil else { return }
        guard let url = localURL(for: episode.id) else { return }
        Task { @MainActor in
            guard let reading = await NarratorVoiceDetector.read(fileURL: url) else { return }
            NarratorVoiceStore.shared.record(
                .init(gender: reading.gender, confidence: reading.confidence,
                      windowsUsed: reading.windowsUsed, decidedAt: Date()),
                for: episode.id, narrator: narrator)
        }
    }

    // MARK: - Queries

    func isDownloaded(_ episodeID: String) -> Bool { index[episodeID] != nil }

    #if DEBUG
    /// Preview routes only: show these episodes as downloaded without touching the saved index.
    func markDownloadedForPreview(_ episodeIDs: [String]) {
        for id in episodeIDs { index[id] = "preview-\(id)" }
        objectWillChange.send()
    }
    #endif

    func localURL(for episodeID: String) -> URL? {
        guard let name = index[episodeID] else { return nil }
        let url = downloadsDir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func state(_ episodeID: String) -> State {
        states[episodeID] ?? (index[episodeID] == nil ? .none : .downloaded)
    }

    /// Advertise already-downloaded episodes to this user's other Banana devices. Discovery uses
    /// an iCloud-synced random group token and encrypted Multipeer sessions; episode bytes remain on
    /// the LAN. Browsing only runs while a download is actively looking for a peer.
    func startPeerSharing() {
        guard peerServingAllowed,
              !ProcessInfo.processInfo.arguments.contains("--perf-disable-peer-serving")
        else { return }
        PodcastPeerTransfer.shared.startServing(from: self)
    }

    /// iPhone discovery is useful while the person is in Banana, but an always-on advertiser
    /// after the screen locks is pure background radio drag. Stop advertising in background while
    /// leaving any already-connected resource transfer alone; the Mac remains the usual always-on
    /// source, and foregrounding the phone resumes discovery immediately.
    func setPeerServingAllowed(_ allowed: Bool) {
        guard peerServingAllowed != allowed else { return }
        peerServingAllowed = allowed
        if allowed {
            if !index.isEmpty { startPeerSharing() }
        } else {
            PodcastPeerTransfer.shared.stopServing()
        }
    }

    // MARK: - Commands

    /// The Wi-Fi-only queue is the SYSTEM's, not ours.
    ///
    /// It used to be an in-memory array of parked episodes — so killing the app (or iOS jetsamming
    /// it, which happens) silently discarded everything you'd queued, and you'd come back to a
    /// podcast you thought was downloading and wasn't. A background session on a Wi-Fi-only
    /// configuration does the same job properly: hand the transfer to the daemon, which holds it
    /// until an allowed network appears and starts it whether we're running, suspended, killed, or
    /// freshly rebooted.
    ///
    /// So both paths now simply enqueue. The policy is enforced by the session, and the person is
    /// told the truth in the meantime — "Waiting for Wi-Fi", not a lie about progress.
    ///
    /// `allowCellular` is only ever true when the person tapped Download and confirmed the warning.
    func download(_ episode: Episode, podcast: Podcast, allowCellular: Bool = false) {
        guard index[episode.id] == nil else { return }        // already downloaded

        if isInFlight(episode.id) {
            // Overriding a transfer the system is holding for Wi-Fi: the existing task lives on the
            // Wi-Fi-only session and can NEVER use cellular, whatever we do to it. It has to be
            // replaced, not nudged. Without this the "Download Now" override would silently do
            // nothing — the worst possible outcome for a button whose whole job is to override.
            guard allowCellular, case .waitingForWiFi = state(episode.id) else { return }
            cancel(episode.id)
        }

        manualDownloads.insert(episode.id)                    // tapped by the user → keep it
        saveManual()
        startDownload(episode, podcast: podcast, allowCellular: allowCellular)
    }

    /// Rule-driven download: Wi-Fi only. On cellular the system holds it rather than spending data.
    private func autoDownload(_ episode: Episode, podcast: Podcast) {
        guard index[episode.id] == nil else { return }
        if isInFlight(episode.id) { return }
        startDownload(episode, podcast: podcast, allowCellular: false)
    }

    /// Fetch an episode the overnight batch wants to transcribe.
    ///
    /// Deliberately the *auto* path, not the manual one: an episode pulled down so a machine can
    /// read it is not an episode the owner asked to keep, and marking it manual would exempt it
    /// from the rolling-window pruning forever. Wi-Fi only, and the system decides when.
    func downloadForTranscription(_ episode: Episode, podcast: Podcast) {
        autoDownload(episode, podcast: podcast)
    }

    private func isInFlight(_ episodeID: String) -> Bool {
        switch state(episodeID) {
        case .downloading, .waitingForWiFi: return true
        default: return false
        }
    }

    /// Kept so a Wi-Fi arrival refreshes the rows the system is about to start. The transfers
    /// themselves need no prompting — the daemon has been holding them.
    func startWaitingForWiFi() {
        objectWillChange.send()
    }

    private func startDownload(_ episode: Episode, podcast: Podcast, allowCellular: Bool) {
        startPeerSharing()
        if NetworkMonitor.shared.isCheap, resumeData[episode.id] == nil {
            states[episode.id] = .downloading(0)
            let episodeID = episode.id
            peerTasks[episodeID] = Task { @MainActor [weak self] in
                guard let self else { return }
                let staged = await PodcastPeerTransfer.shared.fetch(
                    episodeID: episodeID,
                    sourceURL: episode.audioURL
                )
                guard !Task.isCancelled else {
                    if let staged { try? FileManager.default.removeItem(at: staged) }
                    return
                }
                self.peerTasks[episodeID] = nil
                if let staged {
                    PlaybackDiagnostics.shared.log("peer audio: cache hit", episode.title)
                    let ext = episode.audioURL.pathExtension.isEmpty
                        ? "mp3" : episode.audioURL.pathExtension
                    self.finishDownload(
                        episodeID: episodeID,
                        podcastID: podcast.id,
                        tempURL: staged,
                        ext: ext
                    )
                } else {
                    PlaybackDiagnostics.shared.log("peer audio: web fallback", episode.title)
                    self.startNetworkDownload(
                        episode,
                        podcast: podcast,
                        allowCellular: allowCellular
                    )
                }
            }
            return
        }
        startNetworkDownload(episode, podcast: podcast, allowCellular: allowCellular)
    }

    private func startNetworkDownload(_ episode: Episode, podcast: Podcast, allowCellular: Bool) {
        // The session carries the cellular policy — the background daemon enforces the session's
        // rule, not a per-request flag, so the Wi-Fi-only promise has to be made at this level.
        let session = allowCellular ? cellularSession : wifiSession
        let task: URLSessionDownloadTask
        if let data = resumeData.removeValue(forKey: episode.id) {
            resumeDataOrder.removeAll { $0 == episode.id }
            task = session.downloadTask(withResumeData: data)   // continue, don't restart
        } else {
            task = session.downloadTask(with: URLRequest(url: episode.audioURL))
        }
        task.taskDescription = "\(podcast.id.uuidString)|\(episode.id)"   // survives our process dying
        taskEpisode[task.taskIdentifier] = episode.id
        taskPodcast[task.taskIdentifier] = podcast.id
        activeTasks[episode.id] = task

        // On a link this session isn't allowed to use, the daemon will hold the transfer. Say so,
        // rather than showing 0% forever and letting you think it's stuck.
        let held = !allowCellular && !NetworkMonitor.shared.isCheap
        states[episode.id] = held ? .waitingForWiFi : .downloading(0)
        task.resume()
    }

    /// Download a batch (e.g. all episodes before/after one). De-dupes automatically.
    func downloadAll(_ episodes: [Episode], podcast: Podcast, allowCellular: Bool = false) {
        withDeferredPersistence {
            for episode in episodes {
                download(episode, podcast: podcast, allowCellular: allowCellular)
            }
        }
    }

    /// Cancel an in-flight download and clear its state (no "failed" flash).
    func cancel(_ episodeID: String) {
        if let peerTask = peerTasks.removeValue(forKey: episodeID) {
            peerTask.cancel()
            PodcastPeerTransfer.shared.cancel(episodeID: episodeID)
            states[episodeID] = nil
            progressTicker.fractions[episodeID] = nil
            manualDownloads.remove(episodeID)
            saveManual()
            return
        }
        guard let task = activeTasks[episodeID] else { return }
        taskEpisode[task.taskIdentifier] = nil
        taskPodcast[task.taskIdentifier] = nil
        activeTasks[episodeID] = nil
        task.cancel()
        states[episodeID] = nil
        progressTicker.fractions[episodeID] = nil
        lastPercent[episodeID] = nil
        resumeData[episodeID] = nil
        resumeDataOrder.removeAll { $0 == episodeID }
        manualDownloads.remove(episodeID)
        saveManual()
    }

    func delete(_ episodeID: String) {
        if let name = index[episodeID] {
            try? FileManager.default.removeItem(at: downloadsDir.appendingPathComponent(name))
        }
        index[episodeID] = nil
        manualDownloads.remove(episodeID)
        states[episodeID] = nil
        resumeData[episodeID] = nil
        resumeDataOrder.removeAll { $0 == episodeID }
        saveIndex()
        saveManual()
        // A resume checkpoint can only continue against the file it was cut from — without the
        // download it's dead weight (up to ~2 MB each, and they used to accumulate forever).
        // The finished transcript stays: it still powers karaoke for streamed playback.
        TranscriptCoordinator.shared.discardPartial(episodeID)
        // The skip plan goes, for the same reason the resume checkpoint does: it describes the
        // exact copy of the audio that just stopped existing. A re-download is a different stitch.
        skipPlans?.forget(episodeID: episodeID)
        NarratorVoiceStore.shared.forget(episodeID: episodeID)

        // Keep the Watch in sync — delete its copy too, and forget the transfer so a
        // future re-download re-syncs.
        if transferred.remove(episodeID) != nil {
            if let data = try? JSONEncoder().encode(transferred) {
                try? data.write(to: transferredURL, options: .atomic)
            }
        }
        if watchInstructedAt.removeValue(forKey: episodeID) != nil {
            saveWatchInstructed()
        }
        connectivity?.deleteEpisode(episodeID)
    }

    /// Listen for episodes being marked finished, so their files go — once the Undo that marking
    /// one played offers has closed. `deleteIfPlayed` looks again then, so an episode marked
    /// unplayed in the meantime keeps its download.
    func observeCompletions() {
        NotificationCenter.default.addObserver(
            forName: .podcastEpisodesCompleted, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let podcastID = note.userInfo?["podcastID"] as? UUID,
                      let episodeIDs = note.userInfo?["episodeIDs"] as? [String] else { return }
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: ToastCenter.window + .seconds(1))
                    guard let self, let podcast = self.library?.podcast(podcastID) else { return }
                    for id in episodeIDs { self.deleteIfPlayed(id, podcast: podcast) }
                }
            }
        }
    }

    /// Reclaim the disk an episode was using, now that it has been played.
    ///
    /// Called the moment an episode is marked complete rather than waiting for the next feed
    /// refresh to notice. The old behaviour was invisible and the delay was real: a finished
    /// episode kept its file — hundreds of megabytes for a long one — until something else
    /// happened to trigger a reconcile.
    ///
    /// The episode still has to be OUT of the keep-window: a show set to "latest 3 unplayed" can
    /// legitimately still want a played episode downloaded if the feed has nothing newer, and
    /// deleting it would only make the next reconcile fetch it again.
    func deleteIfPlayed(_ episodeID: String, podcast: Podcast, pushManifest: Bool = true) {
        guard index[episodeID] != nil, podcast.completed.contains(episodeID) else { return }
        let keep = Set(podcast.nextUnplayed(podcast.downloadRule.count) {
            NarratorVoiceStore.shared.voice(episodeID: $0, narrator: $1)
        }.map(\.id))
        guard !keep.contains(episodeID) else { return }
        delete(episodeID)
        if pushManifest { pushWatchManifest() }
    }

    /// Free every played episode's download that's out of its show's keep-window — whichever
    /// device it was finished on, and for shows with automatic downloads off too, which
    /// `reconcile` never looks at. Run once the library has loaded, so finishes that arrived
    /// before this device cleaned up after them don't keep their files for good.
    func removePlayedDownloads() {
        guard let library else { return }
        withDeferredPersistence {
            for podcast in library.podcasts {
                for episode in podcast.episodes where index[episode.id] != nil && podcast.completed.contains(episode.id) {
                    deleteIfPlayed(episode.id, podcast: podcast, pushManifest: false)
                }
            }
        }
        pushWatchManifest()
    }

    /// Remove every download for a podcast (e.g. when it's unsubscribed).
    func removeAllDownloads(for podcast: Podcast) {
        withDeferredPersistence {
            for episode in podcast.episodes where index[episode.id] != nil {
                delete(episode.id)
            }
        }
    }

    /// Apply a feed's download rule: keep the newest-N *unplayed* episodes downloaded —
    /// fetch missing ones, and prune this feed's auto-downloads that have aged out of the
    /// window OR have since been played. (Manually-downloaded episodes are protected.)
    /// - Parameter pushManifest: pass `false` when the caller is looping over several podcasts
    ///   and will push the Watch manifest once itself afterward — the manifest is always
    ///   recomputed fresh from the full library, so a single trailing push after the loop
    ///   delivers exactly what the last per-podcast push would have.
    func reconcile(_ podcast: Podcast, pushManifest: Bool = true) {
        guard podcast.downloadRule.count > 0 else { return }
        // Keep the next-N *unplayed* episodes ready (reach back past played ones).
        let wanted = podcast.nextUnplayed(podcast.downloadRule.count) {
            NarratorVoiceStore.shared.voice(episodeID: $0, narrator: $1)
        }
        let keep = Set(wanted.map(\.id))

        for episode in wanted where index[episode.id] == nil {
            if case .downloading = state(episode.id) { continue }
            autoDownload(episode, podcast: podcast)   // Wi-Fi only; parked on cellular
        }
        // Prune this feed's downloads no longer in the window (aged out or played).
        //
        // A manual download is protected from AGEING OUT — you asked for it, so a rolling window
        // moving past it is not a reason to bin it. Finishing it is: a played episode is the one
        // case where the file has certainly done its job, whoever fetched it, and these run to
        // hundreds of megabytes each.
        withDeferredPersistence {
            for episode in podcast.episodes where index[episode.id] != nil && !keep.contains(episode.id) {
                let played = podcast.completed.contains(episode.id)
                guard played || !manualDownloads.contains(episode.id) else { continue }
                delete(episode.id)
            }
        }
        if pushManifest { pushWatchManifest() }
    }

    /// Force-resend every downloaded episode of Watch-synced feeds, ignoring the
    /// "already transferred" set. Use when the Watch is missing files.
    ///
    /// This is the person explicitly saying "the Watch is missing episodes" — so skip the
    /// fire-and-forget instruction path entirely and transfer the files. File transfers
    /// are what the Settings progress row counts, so tapping the button visibly does
    /// something, and delivery is the WC daemon's job rather than the Watch's deferred
    /// background downloader.
    func resyncWatch() {
        guard let library, connectivity != nil else { return }
        for podcast in library.podcasts where podcast.syncToWatch {
            for episode in podcast.episodes {
                guard isDownloaded(episode.id), let fileURL = localURL(for: episode.id) else { continue }
                markWatchInstructed(episode.id)
                sendFile(episodeID: episode.id, title: episode.title, podcast: podcast, fileURL: fileURL)
            }
        }
        pushWatchManifest()
    }

    /// Downloaded episodes of Watch-synced feeds the Watch hasn't confirmed yet — the
    /// Settings row shows this so a silently stuck sync is visible instead of a mystery.
    var watchPendingCount: Int {
        guard let library else { return 0 }
        var count = 0
        for podcast in library.podcasts where podcast.syncToWatch {
            for episode in podcast.episodes
            where isDownloaded(episode.id) && !transferred.contains(episode.id) {
                count += 1
            }
        }
        return count
    }

    /// Tell the Watch exactly which episodes it should have, so it can prune stale ones
    /// (played/aged-out downloads whose per-episode delete was missed).
    func pushWatchManifest() {
        guard let library, let connectivity else { return }
        var ids: [String] = []
        for podcast in library.podcasts where podcast.syncToWatch {
            for episode in podcast.episodes where isDownloaded(episode.id) { ids.append(episode.id) }
        }
        connectivity.syncWatchManifest(ids)
    }

    // MARK: - Persistence

    #if DEBUG
    /// Pretend an episode is downloaded, pointing at a local file — so a CPU measurement exercises
    /// the real playback path without needing the network.
    func debugRegisterDownload(episodeID: String, file: URL) -> URL? {
        let name = "cpu-probe.\(file.pathExtension)"
        let dest = downloadsDir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.copyItem(at: file, to: dest) } catch { return nil }
        index[episodeID] = name
        // Removing the transient state publishes the downloading→downloaded transition; state()
        // now derives the durable result from `index`, so hundreds of completed episodes do not
        // also occupy the hot-state dictionary forever.
        states[episodeID] = nil
        saveIndex()
        return dest
    }
    #endif

    #if PERFORMANCE_TESTING
    /// Register one canonical local fixture for every synthetic episode. The fixture is moved into
    /// the real download store once, then all episode IDs point at that one inode/filename. A long
    /// auto-advance run therefore measures production playback without multiplying fixture disk
    /// usage by the number of synthetic episodes.
    func performanceRegisterDownloads(episodeIDs: [String], fixture: URL) throws -> URL {
        let ext = fixture.pathExtension.isEmpty ? "m4a" : fixture.pathExtension
        let name = "performance-fixture.\(ext)"
        let destination = downloadsDir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: fixture, to: destination)
        } catch {
            try FileManager.default.copyItem(at: fixture, to: destination)
            try? FileManager.default.removeItem(at: fixture)
        }
        for episodeID in episodeIDs {
            index[episodeID] = name
            states[episodeID] = nil
        }
        saveIndex()
        return destination
    }
    #endif

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        index = decoded
    }

    private func saveIndex() {
        guard persistenceDeferralDepth == 0 else {
            indexDirty = true
            return
        }
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    fileprivate func finishDownload(episodeID: String, podcastID: UUID?, tempURL: URL, ext: String,
                                    declaredSlots: DeclaredAdSlots? = nil) {
        progressTicker.fractions[episodeID] = nil
        lastPercent[episodeID] = nil
        resumeData[episodeID] = nil
        resumeDataOrder.removeAll { $0 == episodeID }
        let name = "\(UUID().uuidString).\(ext)"
        let dest = downloadsDir.appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: tempURL, to: dest)
        } catch {
            states[episodeID] = .failed
            return
        }
        index[episodeID] = name
        // Durable completion is derived from `index`; keep only transient states in memory.
        // Otherwise this dictionary grows by one entry for every episode ever downloaded.
        states[episodeID] = nil
        saveIndex()

        let owner = podcastID.flatMap { library?.podcast($0) }
        let downloaded = owner?.episodes.first(where: { $0.id == episodeID })
        // These bytes are a fresh stitch, so anything learned about a previous copy describes a
        // different file. Hand over the headers this download carried and ask for a new plan.
        if let declaredSlots {
            skipPlans?.adopt(declaredSlots, episode: downloaded, podcast: owner)
        } else if let downloaded, let owner {
            skipPlans?.forget(episodeID: episodeID)
        NarratorVoiceStore.shared.forget(episodeID: episodeID)
            skipPlans?.requestBuild(episode: downloaded, podcast: owner, reason: "download")
            classifyNarratorVoiceIfNeeded(episode: downloaded, podcast: owner)
        }

        // If the feed syncs to the Watch, tell it to download this episode directly.
        if let owner, owner.syncToWatch, let downloaded {
            sendToWatch(episode: downloaded, podcast: owner)
        }
    }

    fileprivate func peerFile(episodeID: String, sourceURL: String) -> URL? {
        guard let local = localURL(for: episodeID) else { return nil }
        #if DEBUG
        if episodeID == "verify-peer-episode" { return local }
        #endif
        guard let library else { return local }
        let knownSource = library.podcasts.lazy
            .compactMap { $0.episode(episodeID) }.first?
            .audioURL.absoluteString
        return knownSource == sourceURL ? local : nil
    }

    /// Primary path: tell the Watch to download the episode DIRECTLY from its URL
    /// (fast, over the Watch's own network) rather than pushing the file over the slow
    /// WatchConnectivity link. The Watch falls back to requesting the file if it can't.
    private func sendToWatch(episode: Episode, podcast: Podcast) {
        guard !transferred.contains(episode.id) else { return }   // already on the Watch
        markWatchInstructed(episode.id)
        connectivity?.sendDownloadInstruction(episodeID: episode.id, title: episode.title,
                                              podcast: podcast.title, url: episode.audioURL,
                                              skipPlan: skipPlans?.watchPayload(for: episode.id))
    }

    /// A plan arrived (or improved) for an episode the Watch already holds. A few hundred bytes
    /// on the queue, so it lands whether or not the Watch is awake.
    func pushSkipPlanToWatch(_ episodeID: String) {
        guard transferred.contains(episodeID) || watchInstructedAt[episodeID] != nil,
              let payload = skipPlans?.watchPayload(for: episodeID) else { return }
        connectivity?.sendSkipPlan(episodeID: episodeID, payload: payload)
    }

    /// Fallback (invoked when the Watch's direct download fails): find the episode and
    /// transfer the (transcoded) file over WatchConnectivity.
    func sendFileFallback(_ episodeID: String) {
        guard let library, let fileURL = localURL(for: episodeID) else { return }
        for podcast in library.podcasts {
            if let episode = podcast.episode(episodeID) {
                markWatchInstructed(episodeID)   // reset the escalation clock — a file is on its way
                sendFile(episodeID: episodeID, title: episode.title, podcast: podcast, fileURL: fileURL)
                return
            }
        }
    }

    /// Transfer an episode file to the Watch, transcoding to the configured quality
    /// first (per-podcast override, else global). Original = no transcode.
    private func sendFile(episodeID: String, title: String, podcast: Podcast, fileURL: URL) {
        let quality = podcast.watchAudioQuality ?? settings?.watchAudioQuality ?? .original
        // Ride the plan along with the file it describes, so the Watch never has an episode
        // whose markers are still in a queue somewhere. Transcoding changes the bytes but not
        // the timings, which is all a plan needs to stay true.
        let plan = skipPlans?.watchPayload(for: episodeID)
        guard let bitrate = quality.bitrate else {
            connectivity?.sendEpisode(fileURL: fileURL, episodeID: episodeID, title: title,
                                      podcast: podcast.title, skipPlan: plan)
            return
        }
        let podcastTitle = podcast.title
        Task { [weak self] in
            let out = Self.outboxURL(episodeID)
            if await AudioTranscoder.transcode(fileURL, to: out, bitrate: bitrate, sampleRate: quality.sampleRate) {
                self?.connectivity?.sendEpisode(fileURL: out, episodeID: episodeID, title: title, podcast: podcastTitle, cleanup: true, skipPlan: plan)
            } else {
                self?.connectivity?.sendEpisode(fileURL: fileURL, episodeID: episodeID, title: title, podcast: podcastTitle, skipPlan: plan)
            }
        }
    }

    private static func outboxURL(_ episodeID: String) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WatchOutbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The id is the publisher's string (a guid, or a URL): named by its digest, it cannot carry a path.
        let digest = SHA256.hash(data: Data(episodeID.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent("\(digest).m4a")
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        let id = downloadTask.taskIdentifier
        let fraction = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        let carried = Self.identity(of: downloadTask)?.episodeID
        Task { @MainActor in
            guard let episodeID = self.taskEpisode[id] ?? carried else { return }
            // URLSession calls this per received chunk — tens of times a second, per task.
            // Whole-percent granularity caps it at 100 updates per download, and those go to the
            // ticker, not `states`: the manager itself publishes only the held→downloading
            // transition (a Wi-Fi-parked task starting is something the row DOES display).
            let percent = Int(fraction * 100)
            guard percent != self.lastPercent[episodeID] else { return }
            self.lastPercent[episodeID] = percent
            if case .downloading = self.state(episodeID) {} else {
                self.states[episodeID] = .downloading(0)
            }
            self.progressTicker.fractions[episodeID] = fraction
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        let id = downloadTask.taskIdentifier
        let ext = downloadTask.originalRequest?.url?.pathExtension.isEmpty == false
            ? downloadTask.originalRequest!.url!.pathExtension : "mp3"
        // The temp file is deleted when this method returns — move it to a stable temp now.
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.moveItem(at: location, to: staged)

        // The whole point of a background session is that this can fire in a process that was
        // launched *just* to receive it — one where taskEpisode was never populated. Read the
        // identity off the task itself.
        let carried = Self.identity(of: downloadTask)
        // The ad server declares, in its own response headers, exactly which byte ranges it
        // stitched an ad into. That has been arriving on every download since the day this class
        // was written and going straight in the bin. Reading it costs nothing and is the only
        // evidence in this feature that cannot be wrong.
        let declaredSlots: DeclaredAdSlots? = {
            // `identity(of:)` is the same nonisolated read the rest of this callback relies on:
            // the episode id travels on the task itself, because the process that receives this
            // may never have had the in-memory maps at all.
            guard let episodeID = carried?.episodeID,
                  let response = downloadTask.response as? HTTPURLResponse else { return nil }
            let length = response.expectedContentLength
            let slots = DeclaredAdSlots.capture(episodeID: episodeID, headers: response.allHeaderFields,
                                                byteCount: length > 0 ? Int64(length) : nil)
            return slots.isEmpty ? nil : slots
        }()
        Task { @MainActor in
            guard let episodeID = self.taskEpisode[id] ?? carried?.episodeID else {
                // No owner means the staged file is unreachable. Leaving one behind on each old
                // pre-identity background task made tmp storage grow forever across relaunches.
                try? FileManager.default.removeItem(at: staged)
                return
            }
            let podcastID = self.taskPodcast[id] ?? carried?.podcastID
            self.taskEpisode[id] = nil; self.taskPodcast[id] = nil
            self.activeTasks[episodeID] = nil
            self.finishDownload(episodeID: episodeID, podcastID: podcastID, tempURL: staged, ext: ext,
                                declaredSlots: declaredSlots)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        // A user cancel is not a failure: without this, the late delegate callback resurrected
        // the episode (via taskDescription) and overwrote cancel()'s clean .none with .failed.
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled,
           nsError.userInfo[NSURLSessionDownloadTaskResumeData] == nil {
            return
        }
        let id = task.taskIdentifier
        let carried = Self.identity(of: task)?.episodeID
        // The bytes already transferred, when the failure left any behind. Discarding this meant
        // a retry re-downloaded a 50–150 MB episode from byte zero.
        let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        Task { @MainActor in
            if let episodeID = self.taskEpisode[id] ?? carried {
                self.states[episodeID] = .failed
                self.progressTicker.fractions[episodeID] = nil
                self.lastPercent[episodeID] = nil
                if let resume {
                    self.resumeData[episodeID] = resume
                    self.resumeDataOrder.removeAll { $0 == episodeID }
                    self.resumeDataOrder.append(episodeID)
                    while self.resumeDataOrder.count > Self.maxResumeCheckpoints {
                        let evicted = self.resumeDataOrder.removeFirst()
                        self.resumeData[evicted] = nil
                    }
                }
                self.taskEpisode[id] = nil; self.taskPodcast[id] = nil
                self.activeTasks[episodeID] = nil
            }
        }
    }

    /// iOS relaunched us in the background purely to hear about finished transfers, and it wants the
    /// completion handler called once we've digested them. Fail to call it and the system decides
    /// we're badly behaved and hands out less background time in future.
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            guard let identifier = session.configuration.identifier else { return }
            let handler = self.backgroundCompletionHandlers.removeValue(forKey: identifier)
            handler?()
        }
    }
}

// MARK: - Same-network episode transfer

private struct PodcastPeerMessage: Codable {
    enum Kind: String, Codable { case request, settings, hello, proof }

    let kind: Kind
    let requestID: UUID
    let episodeID: String
    let sourceURL: String
    /// Settings snapshot (kind == .settings) — opaque to this layer; SmartScheduleStore's
    /// last-writer-wins logic decides adoption. For `.hello` the challenger's nonce, for `.proof`
    /// the HMAC answering it. Optional so old peers' messages still decode; old builds receiving
    /// an unknown kind fail to decode it and ignore it.
    var payload: Data?
}

/// A deliberately narrow peer protocol: authenticated devices can request only an episode whose
/// ID and canonical feed URL both match the serving library, and receive only its finished local
/// audio file. The browser is off except during an active request; the inexpensive advertiser lets
/// another device discover the cache without polling or cloud-uploading large audio files.
@MainActor
private final class PodcastPeerTransfer: NSObject {
    static let shared = PodcastPeerTransfer()

    private struct Pending {
        let episodeID: String
        let sourceURL: URL
        let continuation: CheckedContinuation<URL?, Never>
        var timeout: Task<Void, Never>
    }

    private static let serviceType = AppVariant.current.peerServiceType
    private static let tokenKey = "podcastPeerGroupToken.v1"
    private let groupToken: String
    private let groupDigest: String
    private let peerID: MCPeerID
    private lazy var session = MCSession(
        peer: peerID,
        securityIdentity: nil,
        encryptionPreference: .required
    )
    private lazy var advertiser = MCNearbyServiceAdvertiser(
        peer: peerID,
        discoveryInfo: ["group": groupDigest],
        serviceType: Self.serviceType
    )
    private lazy var browser = MCNearbyServiceBrowser(
        peer: peerID,
        serviceType: Self.serviceType
    )

    private weak var provider: DownloadManager?
    private var isServing = false
    private var isBrowsing = false
    /// The browse is paced (`PeerBrowsePacing`): it lingers after the last request, and never
    /// restarts right after a stop — doing either too quickly crashed CFNetwork on the Mac.
    private var lastStopped: Date?
    private var stopTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var pending: [UUID: Pending] = [:]
    /// Peers that answered this device's token challenge (`challenge`/`admit`); only they are served,
    /// asked, or listened to. Connected but unproven peers are nobody yet.
    private var authenticated: Set<MCPeerID> = []
    private var challenges: [MCPeerID: Data] = [:]
    /// The largest file a peer may hand over: an episode, not a disk.
    private static let mostResourceBytes = 2 * 1024 * 1024 * 1024

    // Fast settings sync: the LAN is instant and needs no iCloud entitlements, so settings
    // snapshots ride the same encrypted, token-gated session as audio. Delivery is
    // opportunistic — on change (with a short browse window) and to every peer that connects.
    var onSettingsReceived: ((Data) -> Void)?
    private var latestSettingsPayload: Data?
    private var settingsDeliveryUntil: Date?

    func broadcastSettings(_ data: Data) {
        latestSettingsPayload = data
        sendSettings(to: Array(authenticated))
        settingsDeliveryUntil = Date().addingTimeInterval(8)
        startBrowsingIfNeeded()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(9))
            self?.stopBrowsingIfIdle()
        }
    }

    private func sendSettings(to peers: [MCPeerID]) {
        let peers = peers.filter(authenticated.contains)
        guard !peers.isEmpty,
              let payload = latestSettingsPayload,
              let data = try? JSONEncoder().encode(PodcastPeerMessage(
                kind: .settings,
                requestID: UUID(),
                episodeID: "",
                sourceURL: "",
                payload: payload))
        else { return }
        try? session.send(data, toPeers: peers, with: .reliable)
    }

    private override init() {
        let token = Self.loadGroupToken()
        groupToken = token
        groupDigest = Self.digest(token)
        let device = ProcessInfo.processInfo.hostName
        peerID = MCPeerID(displayName: "\(String(device.prefix(38)))-\(UUID().uuidString.prefix(8))")
        super.init()
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
    }

    func startServing(from provider: DownloadManager) {
        self.provider = provider
        guard !isServing else { return }
        isServing = true
        advertiser.startAdvertisingPeer()
    }

    func stopServing() {
        guard isServing else { return }
        isServing = false
        advertiser.stopAdvertisingPeer()
    }

    func fetch(episodeID: String, sourceURL: URL) async -> URL? {
        guard NetworkMonitor.shared.isCheap else { return nil }
        let requestID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let timeout = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(750))
                    guard !Task.isCancelled else { return }
                    self?.resolve(requestID: requestID, file: nil)
                }
                pending[requestID] = Pending(
                    episodeID: episodeID,
                    sourceURL: sourceURL,
                    continuation: continuation,
                    timeout: timeout
                )
                startBrowsingIfNeeded()
                sendRequest(requestID: requestID)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolve(requestID: requestID, file: nil)
            }
        }
    }

    func cancel(episodeID: String) {
        let matches = pending.filter { $0.value.episodeID == episodeID }.map(\.key)
        for requestID in matches { resolve(requestID: requestID, file: nil) }
    }

    private func startBrowsingIfNeeded() {
        // Wanted again: the stop waiting out its linger doesn't happen.
        stopTask?.cancel()
        stopTask = nil
        guard !isBrowsing, startTask == nil else { return }
        let wait = PeerBrowsePacing.startDelay(now: Date(), lastStopped: lastStopped)
        guard wait > 0 else {
            isBrowsing = true
            browser.startBrowsingForPeers()
            return
        }
        // Just stopped: Bonjour may still be tearing that browse down. Start once it's had time.
        startTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self else { return }
            self.startTask = nil
            self.startBrowsingIfNeeded()
        }
    }

    /// Stops the browse once nothing has needed it for `PeerBrowsePacing.linger`.
    private func stopBrowsingIfIdle() {
        guard pending.isEmpty, isBrowsing, stopTask == nil else { return }
        stopTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(PeerBrowsePacing.linger))
            guard !Task.isCancelled, let self else { return }
            self.stopTask = nil
            guard self.pending.isEmpty, self.isBrowsing else { return }
            if let until = self.settingsDeliveryUntil, until > Date() { return self.stopBrowsingIfIdle() }   // still delivering settings
            self.isBrowsing = false
            self.lastStopped = Date()
            self.browser.stopBrowsingForPeers()
        }
    }

    private func sendRequest(requestID: UUID, to peers: [MCPeerID]? = nil) {
        guard let value = pending[requestID],
              let data = try? JSONEncoder().encode(PodcastPeerMessage(
                kind: .request,
                requestID: requestID,
                episodeID: value.episodeID,
                sourceURL: value.sourceURL.absoluteString
              )) else { return }
        let destinations = (peers ?? Array(authenticated)).filter(authenticated.contains)
        guard !destinations.isEmpty else { return }
        try? session.send(data, toPeers: destinations, with: .reliable)
    }

    private func sendAllRequests(to peer: MCPeerID) {
        for requestID in pending.keys { sendRequest(requestID: requestID, to: [peer]) }
    }

    private func serve(_ message: PodcastPeerMessage, to peer: MCPeerID) {
        switch message.kind {
        case .hello: return answer(message, from: peer)
        case .proof: return admit(message, from: peer)
        case .request, .settings: break
        }
        guard authenticated.contains(peer) else { return }
        if message.kind == .settings {
            if let payload = message.payload { onSettingsReceived?(payload) }
            return
        }
        guard message.kind == .request,
              let file = provider?.peerFile(
                episodeID: message.episodeID,
                sourceURL: message.sourceURL
              ) else { return }
        session.sendResource(
            at: file,
            withName: message.requestID.uuidString.lowercased(),
            toPeer: peer
        ) { error in
            if let error {
                PlaybackDiagnostics.shared.log("peer audio: send failed", error.localizedDescription)
            }
        }
    }

    private func receiveResource(named name: String, from peer: MCPeerID, at temporaryURL: URL?, error: Error?) {
        guard error == nil,
              authenticated.contains(peer),
              let requestID = UUID(uuidString: name),
              pending[requestID] != nil,
              let temporaryURL,
              let size = (try? FileManager.default.attributesOfItem(atPath: temporaryURL.path)[.size] as? NSNumber)?.intValue,
              size > 0, size <= Self.mostResourceBytes else { return }
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("peer-\(UUID().uuidString)")
        do {
            try FileManager.default.copyItem(at: temporaryURL, to: staged)
            resolve(requestID: requestID, file: staged)
        } catch {
            resolve(requestID: requestID, file: nil)
        }
    }

    private func resourceStarted(named name: String, from peer: MCPeerID) {
        guard authenticated.contains(peer), let requestID = UUID(uuidString: name) else { return }
        // The short timeout is for discovery and first byte only. A full episode may take minutes
        // to cross the LAN; once Multipeer has begun the resource, its completion callback owns the
        // lifecycle and the normal DownloadManager cancel action can still stop the request.
        pending[requestID]?.timeout.cancel()
        pending[requestID]?.timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30 * 60))
            guard !Task.isCancelled else { return }
            self?.resolve(requestID: requestID, file: nil)
        }
    }

    private func peerDiscovered() {
        // Do not make a no-peer download sit behind a long LAN probe: the initial 750 ms still
        // falls through quickly. Once Bonjour has actually found one of this user's devices,
        // however, give Multipeer enough time to finish its encrypted invitation handshake.
        // On real Wi-Fi that is normally sub-second, but cold radios and simulator/host routing
        // can take a few seconds. Without this extension we found the right Mac, invited it, and
        // then abandoned the request before the authenticated session could connect.
        #if DEBUG
        // CoreSimulator tunnels Multipeer through the host and has repeatedly taken ~23 seconds
        // to finish an invitation that real devices complete promptly. Keep that test quirk out
        // of the shipping latency policy while still exercising the complete cold-peer protocol.
        let grace: Duration = ProcessInfo.processInfo.arguments.contains("--verify-peer-client")
            ? .seconds(30) : .seconds(6)
        #else
        let grace: Duration = .seconds(6)
        #endif
        for requestID in pending.keys {
            pending[requestID]?.timeout.cancel()
            pending[requestID]?.timeout = Task { @MainActor [weak self] in
                try? await Task.sleep(for: grace)
                guard !Task.isCancelled else { return }
                self?.resolve(requestID: requestID, file: nil)
            }
        }
    }

    private func resolve(requestID: UUID, file: URL?) {
        guard let value = pending.removeValue(forKey: requestID) else {
            if let file { try? FileManager.default.removeItem(at: file) }
            return
        }
        value.timeout.cancel()
        value.continuation.resume(returning: file)
        stopBrowsingIfIdle()
    }

    static let tokenOverrideKey = "podcastPeerGroupToken.manual"
    private static let tokenCacheKey = "podcastPeerGroupToken.cache"

    /// The group trust token, resolved WITHOUT requiring iCloud: a manual pairing code wins,
    /// then KVS (entitled builds), then the locally cached copy — so an entitlement-less local
    /// Mac build keeps a stable identity and can be paired by pasting the phone's code.
    static func loadGroupToken() -> String {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--peer-token"), index + 1 < arguments.count {
            return arguments[index + 1]
        }
        #endif
        if let manual = UserDefaults.standard.string(forKey: tokenOverrideKey), !manual.isEmpty {
            return manual
        }
        let store = NSUbiquitousKeyValueStore.default
        store.synchronize()
        if let existing = store.string(forKey: tokenKey), !existing.isEmpty {
            UserDefaults.standard.set(existing, forKey: tokenCacheKey)
            return existing
        }
        if let cached = UserDefaults.standard.string(forKey: tokenCacheKey), !cached.isEmpty {
            return cached
        }
        let created = UUID().uuidString.lowercased()
        store.set(created, forKey: tokenKey)
        store.synchronize()
        UserDefaults.standard.set(created, forKey: tokenCacheKey)
        return created
    }

    private static func digest(_ value: String) -> String {
        let hash = SHA256.hash(data: Data(value.utf8))
        return hash.prefix(9).map { String(format: "%02x", $0) }.joined()
    }

    private var groupKey: SymmetricKey { SymmetricKey(data: Data(groupToken.utf8)) }

    fileprivate func invitationProof(for peer: MCPeerID) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(peer.displayName.utf8), using: groupKey))
    }

    fileprivate func invitationValid(_ context: Data?, for peer: MCPeerID) -> Bool {
        guard let context else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(context, authenticating: Data(peer.displayName.utf8), using: groupKey)
    }

    // MARK: Mutual proof after connecting

    // The discovery digest and the invitation proof both cross the LAN in the clear and are the
    // same every time, so anyone on the network can advertise the digest or replay the proof. After
    // connecting, each side therefore challenges the other with a fresh nonce; the answer is an HMAC
    // of the group token over the nonce and both names. Until a peer's answer verifies, nothing it
    // sends is served, adopted or received, and nothing is asked of it.

    private func challenge(_ peer: MCPeerID) {
        var rng = SystemRandomNumberGenerator()   // the system's cryptographic generator
        let nonce = Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &rng) })
        challenges[peer] = nonce
        send(PodcastPeerMessage(kind: .hello, requestID: UUID(), episodeID: "", sourceURL: "", payload: nonce), to: [peer])
    }

    private func answer(_ message: PodcastPeerMessage, from peer: MCPeerID) {
        guard let nonce = message.payload, nonce.count == 16 else { return }
        let proof = Data(HMAC<SHA256>.authenticationCode(for: Self.proofMessage(nonce: nonce, challenger: peer, responder: peerID), using: groupKey))
        send(PodcastPeerMessage(kind: .proof, requestID: message.requestID, episodeID: "", sourceURL: "", payload: proof), to: [peer])
    }

    private func admit(_ message: PodcastPeerMessage, from peer: MCPeerID) {
        guard let nonce = challenges.removeValue(forKey: peer), let proof = message.payload,
              HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: Self.proofMessage(nonce: nonce, challenger: peerID, responder: peer), using: groupKey)
        else {
            PlaybackDiagnostics.shared.log("peer audio: peer failed the token check", peer.displayName)
            session.cancelConnectPeer(peer)
            return
        }
        authenticated.insert(peer)
        sendAllRequests(to: peer)
        // Converge settings on every connect: both sides push their snapshot once and
        // last-writer-wins adoption sorts it out. No reply-on-receive, so no ping-pong.
        sendSettings(to: [peer])
    }

    private static func proofMessage(nonce: Data, challenger: MCPeerID, responder: MCPeerID) -> Data {
        var message = Data("banana-peer-proof-v2|".utf8)
        message.append(nonce)
        message.append(Data("|\(challenger.displayName)|\(responder.displayName)".utf8))
        return message
    }

    private func send(_ message: PodcastPeerMessage, to peers: [MCPeerID]) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        try? session.send(data, toPeers: peers, with: .reliable)
    }
}

extension PodcastPeerTransfer: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        Task { @MainActor in
            let valid = self.invitationValid(context, for: peerID)
            invitationHandler(valid, valid ? self.session : nil)
        }
    }

    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didNotStartAdvertisingPeer error: Error
    ) {
        PlaybackDiagnostics.shared.log("peer audio: advertise failed", error.localizedDescription)
    }
}

extension PodcastPeerTransfer: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser,
        foundPeer peerID: MCPeerID,
        withDiscoveryInfo info: [String: String]?
    ) {
        Task { @MainActor in
            guard peerID != self.peerID, info?["group"] == self.groupDigest else { return }
            self.peerDiscovered()
            browser.invitePeer(
                peerID,
                to: self.session,
                withContext: self.invitationProof(for: self.peerID),
                timeout: 5
            )
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}

    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser,
        didNotStartBrowsingForPeers error: Error
    ) {
        PlaybackDiagnostics.shared.log("peer audio: browse failed", error.localizedDescription)
    }
}

extension PodcastPeerTransfer: MCSessionDelegate {
    nonisolated func session(
        _ session: MCSession,
        peer peerID: MCPeerID,
        didChange state: MCSessionState
    ) {
        Task { @MainActor in
            guard state == .connected else {
                self.authenticated.remove(peerID)
                self.challenges[peerID] = nil
                return
            }
            self.challenge(peerID)
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let message = try? JSONDecoder().decode(PodcastPeerMessage.self, from: data) else { return }
        Task { @MainActor in self.serve(message, to: peerID) }
    }

    nonisolated func session(
        _ session: MCSession,
        didReceive stream: InputStream,
        withName streamName: String,
        fromPeer peerID: MCPeerID
    ) {}

    nonisolated func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {
        Task { @MainActor in self.resourceStarted(named: resourceName, from: peerID) }
    }

    nonisolated func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: Error?
    ) {
        Task { @MainActor in
            self.receiveResource(named: resourceName, from: peerID, at: localURL, error: error)
        }
    }
}
