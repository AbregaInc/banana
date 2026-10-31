import Combine
import Foundation
#if os(iOS)
import UIKit
#endif
import CryptoKit

/// Keeps a snapshot of everything you'd mourn in iCloud, so a reinstall doesn't cost you your
/// listening state.
///
/// iOS deletes an app's container when the app is deleted, and an iCloud *device* backup only
/// restores as part of a full device restore — so "delete the app and put it back" loses
/// everything unless the app writes its own copy somewhere. This is that copy.
///
/// What's in it: the podcast library (subscriptions, play positions, completed episodes, per-feed
/// settings), routines/cues, timeline exceptions, listen history, and the app's UserDefaults.
/// What isn't: downloaded audio and transcripts (large, and re-derivable from the feeds), and
/// workouts (they live in Apple Health, which is already backed up).
@MainActor
extension CloudBackup {
    /// Whose device wrote this snapshot — so a restore can say where it came from. The only thing
    /// this file ever wanted UIKit for.
    nonisolated static var deviceName: String {
        // `UIDevice.current.name` became main-actor isolated. Snapshot preparation also runs in
        // headless/background contexts, where a stable host label is sufficient and actor-free.
        ProcessInfo.processInfo.hostName
    }
}

final class CloudBackup: ObservableObject {
    static let shared = CloudBackup()

    static let containerID = AppCloud.containerID

    /// The backup's job has gone to the Banana service (docs/design/DATA-PLATFORM.md §6): with
    /// the data platform on (`SpaceSyncFlag`), once this device writes nothing more to iCloud (each tier flipped, held or
    /// off). Its Settings row goes and "Back up now" does nothing; the backup code stays until it
    /// is removed (Stage E). Backups themselves already stop with the modes (`performBackup`).
    static var isRetired: Bool {
        !LegacyCloud.mayWrite(.personal) || !LegacyCloud.mayWrite(.health)
    }
    private static let legacyContainerID = AppCloud.legacyContainerID
    #if BANANA_BETA
    private static let backupSource = "Banana Beta"
    #else
    private static let backupSource = "Banana"
    #endif
    private static let enabledKey = "cloudBackupEnabled"
    private static let lastHashKey = "cloudBackupHash"
    private static let lastDateKey = "cloudBackupDate"
    private static let initialRestoreOfferShownKey = "cloudBackupInitialRestoreOfferShown"

    /// A snapshot is just the files + defaults, plus enough of a summary to describe itself in the
    /// restore prompt without decoding the whole payload.
    struct Snapshot: Codable, Sendable {
        var version = 1
        var savedAt: Date
        var device: String
        var files: [String: Data]
        var defaults: Data
        var podcastCount: Int
        var inProgressCount: Int
        var routineCount: Int

        var summary: String {
            var parts: [String] = []
            if podcastCount > 0 { parts.append("\(podcastCount) show\(podcastCount == 1 ? "" : "s")") }
            if inProgressCount > 0 { parts.append("\(inProgressCount) episode\(inProgressCount == 1 ? "" : "s") in progress") }
            if routineCount > 0 { parts.append("\(routineCount) cue\(routineCount == 1 ? "" : "s")") }
            return parts.isEmpty ? "an empty backup" : parts.joined(separator: ", ")
        }

        /// Onboarding completion used to live only in the predecessor app's UserDefaults domain.
        /// The snapshot already carries that domain, so it is the authoritative migration signal.
        var completedOnboarding: Bool {
            guard let plist = try? PropertyListSerialization.propertyList(
                from: defaults, options: [], format: nil
            ) as? [String: Any] else {
                return false
            }
            return plist["onboardingCompleted"] as? Bool == true
        }
    }

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            if enabled { schedule() }
            let value = enabled
            Task { @MainActor [weak self] in
                if let settings = self?.settings, settings.backupEnabled != value { settings.backupEnabled = value }
            }
        }
    }

    private weak var settings: AppSettings?
    private var settingsObserver: AnyCancellable?

    /// "Back up to iCloud" is one synced setting (`AppSettings.backupEnabled`), the same switch on
    /// every device. The phone seeds it from its own when nobody has; everyone follows it after.
    @MainActor func bind(to settings: AppSettings) {
        self.settings = settings
        if settings.backupEnabled == nil, DeviceRole.current.isHub {
            settings.backupEnabled = enabled
        }
        settingsObserver = settings.$backupEnabled
            .compactMap { $0 }
            .removeDuplicates()
            .sink { [weak self] synced in
                guard let self, self.enabled != synced else { return }
                self.enabled = synced
            }
    }
    @Published private(set) var status = "Not backed up yet"
    @Published private(set) var lastBackup: Date?
    @Published private(set) var busy = false
    @Published private(set) var initialRestoreCheckFinished = false

    /// A snapshot found on a fresh install, awaiting your yes/no. Never applied on its own.
    @Published var pendingRestore: Snapshot?
    @Published private(set) var pendingRestoreSource: String?
    /// Whether the restore on offer was asked for in Settings (so not taking it is "Cancel"), or
    /// found on a fresh install (where not taking it is "Start fresh").
    @Published private(set) var pendingRestoreWasAskedFor = false

    /// Reload the stores from disk after a restore rewrites their files.
    var onRestore: (() -> Void)?
    /// Called as soon as a backup proves this is a returning user, before they decide whether to
    /// restore its data. This prevents the permission tour from replaying ahead of the prompt.
    var onReturningUserDetected: (() -> Void)?

    /// The files worth carrying. Downloads/transcripts/fitness samples are deliberately absent.
    private let files = [
        "podcasts.json",              // subscriptions + the episode catalogue
        "progress.json",              // play positions and completed episodes — the crown jewels
        "live-progress.json",         // latest crash-safe playhead between full progress commits
        "routines.json",
        "listen_history.json",
        "timeline-exceptions.json",
        "wellness.json",             // meals, supplements, and generated workout plans
        "Fitness/summaries.json",     // workout overview rows, so a Mac (no Watch) can show Rhythm
    ]
    private let directories = [
        "ListenRoutes",               // append-only GPS sidecars for mapped listening sessions
    ]

    private var backupTask: Task<Void, Never>?
    private var backupAgainUserInitiated = false
    private enum WriteOutcome { case saved, protectedExistingBackup, unavailable }
    private struct PreparedBackup: Sendable {
        var snapshot: Snapshot
        var payload: Data
        var hash: String
    }

    private init() {
        let defaults = UserDefaults.standard
        // On by default — the whole point is that you don't have to remember to turn it on.
        #if DEBUG
        // Screenshot and verification processes must not upload their fixtures. This is a
        // process-local override: persisting it poisoned the real desktop profile after every
        // App Store capture, silently leaving backup/sync off in later interactive launches.
        let disabledForThisProcess = ProcessInfo.processInfo.arguments.contains("--disable-icloud")
        #else
        let disabledForThisProcess = false
        #endif
        if !disabledForThisProcess, defaults.object(forKey: Self.enabledKey) == nil {
            defaults.set(true, forKey: Self.enabledKey)
        }
        enabled = disabledForThisProcess ? false : defaults.bool(forKey: Self.enabledKey)
        lastBackup = defaults.object(forKey: Self.lastDateKey) as? Date
        status = BackupRules.restingStatus(lastBackup: lastBackup)
        retired = Self.isRetired
        // The Settings row leaves as the modes change, not at some later redraw.
        modesObserver = NotificationCenter.default.addObserver(forName: LegacyCloudModeStore.didChange, object: nil,
                                                               queue: .main) { [weak self] _ in
            guard let self, self.retired != Self.isRetired else { return }
            self.retired = Self.isRetired
        }
    }

    /// `isRetired`, published: what views read.
    @Published private(set) var retired = false
    private var modesObserver: NSObjectProtocol?

    // MARK: - Locations

    private var supportDir: URL {
        AppSupport.directory
    }

    /// `url(forUbiquityContainerIdentifier:)` hits the disk and can block — never call it on the
    /// main thread.
    private nonisolated static func documentsURL(containerID: String) -> URL? {
        guard AppCloud.hasContainerEntitlement else { return nil }
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: containerID) else {
            return nil
        }
        let docs = container.appendingPathComponent("Documents", isDirectory: true)
        // Made only while backups are still written: a restore check after the move (and the
        // purge) doesn't put the folder back.
        if LegacyCloud.mayWrite(.personal), LegacyCloud.mayWrite(.health) {
            try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        }
        return docs
    }

    private nonisolated static func backupFileURL(containerID: String = CloudBackup.containerID) -> URL? {
        documentsURL(containerID: containerID)?.appendingPathComponent("backup.plist")
    }

    private nonisolated static func previousBackupFileURL(containerID: String = CloudBackup.containerID) -> URL? {
        documentsURL(containerID: containerID)?.appendingPathComponent("previous-backup.plist")
    }

    // MARK: - Backing up

    /// Automatic backup uses a dirty bit: callers invoke `schedule()` on data changes, and the
    /// on-background pass consults it. The writer separately refuses to replace a snapshot that has
    /// shows with one that has none and retains the previous generation. Without the dirty bit,
    /// EVERY backgrounding re-read all six payload
    /// files (the multi-MB catalogue included) plus the whole UserDefaults domain and SHA-256'd
    /// them — usually to conclude "unchanged, skip". Persisted so a kill can't lose the fact that
    /// something changed.
    private static let needsBackupKey = "cloudBackupNeeded"
    func schedule() {
        if !(UserDefaults.standard.object(forKey: Self.needsBackupKey) as? Bool ?? false) {
            UserDefaults.standard.set(true, forKey: Self.needsBackupKey)
        }
    }

    func backUpNow(userInitiated: Bool) async {
        // There is one backup file, and it's the phone's: an iPad's or a Mac's snapshot (its own
        // settings, its own copy of the library) would replace the phone's recovery point. They
        // ask the phone instead (`HubRequests.backUpNow`).
        guard DeviceRole.current.isHub, !Self.isRetired else { return }
        if let backupTask {
            // Background + Settings can request a backup at the same moment. Never run two full
            // snapshot reads/hashes/iCloud writes concurrently. Preserve a manual request as one
            // trailing pass so its status accurately reflects the button the person tapped.
            if userInitiated { backupAgainUserInitiated = true }
            await backupTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.backupTask = nil }
            var manual = userInitiated
            repeat {
                self.backupAgainUserInitiated = false
                await self.performBackup(userInitiated: manual)
                manual = self.backupAgainUserInitiated
            } while manual
        }
        backupTask = task
        await task.value
    }

    private func performBackup(userInitiated: Bool) async {
        guard enabled || userInitiated else { return }
        // Moved to the Banana service (docs/design/DATA-PLATFORM.md §8): the backup holds personal
        // and health data, so it's written only while both still go to iCloud.
        guard LegacyCloud.mayWrite(.personal), LegacyCloud.mayWrite(.health) else {
            PlaybackDiagnostics.shared.log("☁️ backup", "not written: this device no longer writes iCloud")
            return
        }
        // Clean → free. The dirty bit is set by every store's save path (see `schedule()`), so a
        // backgrounding with nothing changed skips the read+encode+hash pass entirely. Absent key
        // (first run after this change) counts as dirty so one pass re-establishes the baseline.
        if !userInitiated,
           !(UserDefaults.standard.object(forKey: Self.needsBackupKey) as? Bool ?? true) {
            return
        }
        let sp = Signpost.begin("backup")
        defer { Signpost.end(sp) }
        busy = true
        defer { busy = false }

        // These stores intentionally persist on serial utility lanes. Cross their barriers before
        // reading the snapshot so the backup cannot lag the final route point or workout summary
        // merely because the app backgrounded immediately after the mutation.
        async let historyFlushed: Void = ListenHistoryStore.flushPendingWrites()
        async let fitnessFlushed: Void = FitnessStore.shared.flushPendingWrites()
        _ = await (historyFlushed, fitnessFlushed)

        let root = supportDir
        let fileNames = files
        let directoryNames = directories
        let bundleID = Bundle.main.bundleIdentifier
        let device = Self.deviceName
        guard let prepared = await Task.detached(priority: .utility, operation: {
            Self.prepareSnapshot(supportDir: root, files: fileNames,
                                 directories: directoryNames, bundleID: bundleID,
                                 device: device)
        }).value else {
            status = "Nothing to back up"
            return
        }
        let snapshot = prepared.snapshot
        let payload = prepared.payload

        // Hash the CONTENT only. Hashing the encoded Snapshot was useless: it carries `savedAt:
        // Date()`, so the digest differed on every call and the guard below could never fire —
        // every save uploaded the whole library. Measured: two hashes of identical data, 1.1s
        // apart, were completely different.
        let hash = prepared.hash
        if !userInitiated, hash == UserDefaults.standard.string(forKey: Self.lastHashKey) {
            UserDefaults.standard.set(false, forKey: Self.needsBackupKey)   // verified current
            return
        }

        let outcome = await Task.detached(priority: .utility) { [payload] () -> WriteOutcome in
            guard let url = CloudBackup.backupFileURL() else { return .unavailable }
            do {
                // Never let an empty/new device destroy the only useful recovery point. This was
                // the exact failure mode of the old shared file: a Mac or fresh install with no
                // catalogue replaced a multi-megabyte phone backup with a routines-only snapshot.
                if let oldData = try? Data(contentsOf: url),
                   let old = try? PropertyListDecoder().decode(Snapshot.self, from: oldData),
                   old.podcastCount > 0, snapshot.podcastCount == 0 {
                    return .protectedExistingBackup
                }
                // Keep one known-good generation. A bad release can no longer make the previous
                // snapshot disappear in the same write that creates its replacement.
                if FileManager.default.fileExists(atPath: url.path),
                   let previous = CloudBackup.previousBackupFileURL() {
                    try? FileManager.default.removeItem(at: previous)
                    try FileManager.default.copyItem(at: url, to: previous)
                }
                try payload.write(to: url, options: .atomic)
                return .saved
            } catch {
                return .unavailable
            }
        }.value

        switch outcome {
        case .saved:
            let now = Date()
            lastBackup = now
            Task { @MainActor in HubStatusStore.shared.update { $0.lastBackup = now } }
            UserDefaults.standard.set(now, forKey: Self.lastDateKey)
            UserDefaults.standard.set(hash, forKey: Self.lastHashKey)
            UserDefaults.standard.set(false, forKey: Self.needsBackupKey)
            status = "Backed up \(snapshot.summary)"
        case .protectedExistingBackup:
            status = "Backup protected — this device has no podcasts, so it did not replace your existing copy"
        case .unavailable:
            status = "iCloud unavailable — sign in to iCloud Drive to back up"
        }
    }

    /// Device/process-local state is not user data and must never move to another installation
    /// (`BackupRules.isOperational`).
    private nonisolated static func userDefaultsOnly(_ domain: [String: Any]) -> [String: Any] {
        BackupRules.portable(domain)
    }

    /// Digest of what's actually backed up.
    ///
    /// Two things had to be excluded to make this stable, both verified by measurement:
    ///  • `savedAt`/`device` — hashing the encoded Snapshot meant the digest changed on every call,
    ///    so the guard could never fire and every save uploaded the whole library.
    ///  • the serialized defaults blob — `PropertyListSerialization` does not produce byte-stable
    ///    output for the same dictionary, so the bytes differed run to run even with identical
    ///    content. The defaults are digested key by key, in sorted order, instead.
    private nonisolated static func contentHash(_ snapshot: Snapshot,
                                                defaultsDomain: [String: Any]) -> String {
        var hasher = SHA256()
        for name in snapshot.files.keys.sorted() {
            hasher.update(data: Data(name.utf8))
            hasher.update(data: snapshot.files[name] ?? Data())
        }
        hasher.update(data: defaultsDigest(defaultsDomain))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func defaultsDigest(_ domain: [String: Any]) -> Data {
        var hasher = SHA256()
        for key in domain.keys.sorted() {
            hasher.update(data: Data(key.utf8))
            if let value = domain[key],
               let bytes = try? PropertyListSerialization.data(fromPropertyList: [value],
                                                               format: .binary, options: 0) {
                hasher.update(data: bytes)
            }
        }
        return Data(hasher.finalize())
    }

    #if DEBUG
    /// The exact hash `backUpNow` compares against, so the dedup is testable without an iCloud account.
    func debugPayloadHash() -> String? {
        debugPrepared()?.hash
    }
    /// Isolate which half is unstable.
    func debugFilesHash() -> String? {
        guard let snapshot = debugPrepared()?.snapshot else { return nil }
        var hasher = SHA256()
        for name in snapshot.files.keys.sorted() {
            hasher.update(data: Data(name.utf8))
            hasher.update(data: snapshot.files[name] ?? Data())
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func debugDefaultsHash() -> String? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let domain = UserDefaults.standard.persistentDomain(forName: bundleID) ?? [:]
        return Self.defaultsDigest(domain).map { String(format: "%02x", $0) }.joined()
    }
    private func debugPrepared() -> PreparedBackup? {
        Self.prepareSnapshot(
            supportDir: supportDir,
            files: files,
            directories: directories,
            bundleID: Bundle.main.bundleIdentifier,
            device: Self.deviceName)
    }
    #endif

    /// Read, summarize, encode, and hash the potentially multi-megabyte snapshot away from the
    /// main actor. Backgrounding used to synchronously read the full podcast catalogue, every
    /// route sidecar, JSON-summarize them, encode a plist, and SHA-256 the result before the UI
    /// could finish transitioning.
    private nonisolated static func prepareSnapshot(
        supportDir: URL,
        files: [String],
        directories: [String],
        bundleID: String?,
        device: String
    ) -> PreparedBackup? {
        var payload: [String: Data] = [:]
        for name in files {
            let url = supportDir.appendingPathComponent(name)
            let catalogURL = supportDir.appendingPathComponent("podcast-catalog.sqlite")
            if name == "podcasts.json", FileManager.default.fileExists(atPath: catalogURL.path) {
                // Export a consistent portable catalog, never back up an open SQLite/WAL pair
                // or silently fall back to the now-historical pre-migration JSON.
                guard let data = try? PodcastCatalog.open(at: catalogURL).backupJSON(legacyURL: url) else { return nil }
                payload[name] = data
                continue
            }
            if let data = try? Data(contentsOf: url) { payload[name] = data }
        }
        for directory in directories {
            let root = supportDir.appendingPathComponent(directory, isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                      let data = try? Data(contentsOf: url) else { continue }
                let relative = url.path.replacingOccurrences(of: supportDir.path + "/", with: "")
                payload[relative] = data
            }
        }
        guard !payload.isEmpty else { return nil }

        let completeDomain = bundleID.flatMap {
            UserDefaults.standard.persistentDomain(forName: $0)
        } ?? [:]
        let domain = userDefaultsOnly(completeDomain)
        let defaults = (try? PropertyListSerialization.data(fromPropertyList: domain,
                                                            format: .binary, options: 0)) ?? Data()

        let counts = counts(from: payload["podcasts.json"], routines: payload["routines.json"])
        let snapshot = Snapshot(savedAt: Date(),
                                device: device,
                                files: payload,
                                defaults: defaults,
                                podcastCount: counts.shows,
                                inProgressCount: counts.inProgress,
                                routineCount: counts.routines)
        guard let encoded = try? PropertyListEncoder().encode(snapshot) else { return nil }
        return PreparedBackup(snapshot: snapshot, payload: encoded,
                              hash: contentHash(snapshot, defaultsDomain: domain))
    }

    /// Summarise without depending on the model types — the snapshot has to stay readable even if
    /// Podcast/Routine change shape later.
    private struct PodcastBackupSummary: Decodable {
        private enum CodingKeys: String, CodingKey { case positions }
        private struct Ignored: Decodable { init(from decoder: Decoder) {} }
        let positionCount: Int
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            positionCount = (try? container.decode([String: Ignored].self, forKey: .positions))?.count ?? 0
        }
    }

    private nonisolated static func counts(
        from podcasts: Data?, routines: Data?
    ) -> (shows: Int, inProgress: Int, routines: Int) {
        var shows = 0, inProgress = 0, cues = 0
        if let podcasts, let list = try? JSONDecoder().decode([PodcastBackupSummary].self, from: podcasts) {
            shows = list.count
            for show in list {
                inProgress += show.positionCount
            }
        }
        if let routines, let list = try? JSONSerialization.jsonObject(with: routines) as? [[String: Any]] {
            cues = list.count
        }
        return (shows, inProgress, cues)
    }

    // MARK: - Restoring

    private struct Candidate {
        var snapshot: Snapshot
        var source: String
    }

    /// Decode only internally consistent snapshots. The summary is metadata, not proof: accepting
    /// “6 shows” with no decodable podcasts.json would present a successful restore that restores
    /// nothing—the behavior this migration is fixing.
    private nonisolated static func validatedCandidate(data: Data, source: String) -> Candidate? {
        guard let snapshot = try? PropertyListDecoder().decode(Snapshot.self, from: data) else {
            return nil
        }
        if snapshot.podcastCount > 0 {
            guard let catalogue = snapshot.files["podcasts.json"],
                  let shows = try? JSONDecoder().decode([PodcastBackupSummary].self, from: catalogue),
                  shows.count == snapshot.podcastCount else {
                return nil
            }
        }
        return Candidate(snapshot: snapshot, source: source)
    }

    /// Search both Banana generations and the legacy Quarters container. Prefer the snapshot with
    /// the most subscribed shows, then the most in-progress episodes, then recency. A newer empty
    /// snapshot must never beat an older useful migration snapshot.
    private nonisolated static func bestRestoreCandidate() async -> Candidate? {
        async let current = downloadPrimaryCandidate(
            containerID: Self.containerID, source: Self.backupSource)
        async let legacy = downloadLegacyCandidate()
        var candidates: [Candidate] = []
        if let candidate = await current { candidates.append(candidate) }
        if let candidate = await legacy { candidates.append(candidate) }

        // Previous generations normally exist locally whenever their primary does. Do not wait
        // ten seconds for a filename that legitimately does not exist.
        var previousContainers = [(Self.containerID, "previous \(Self.backupSource)")]
        if let legacyContainerID = Self.legacyContainerID {
            previousContainers.append((legacyContainerID, "previous Quarters migration"))
        }
        for (containerID, label) in previousContainers {
            if let url = previousBackupFileURL(containerID: containerID),
               let data = try? Data(contentsOf: url),
               let candidate = validatedCandidate(data: data, source: label) {
                candidates.append(candidate)
            }
        }
        return candidates.max {
            let left = ($0.snapshot.podcastCount, $0.snapshot.inProgressCount,
                        $0.snapshot.routineCount, $0.snapshot.savedAt)
            let right = ($1.snapshot.podcastCount, $1.snapshot.inProgressCount,
                         $1.snapshot.routineCount, $1.snapshot.savedAt)
            return left < right
        }
    }

    private nonisolated static func downloadLegacyCandidate() async -> Candidate? {
        guard let legacyContainerID else { return nil }
        return await downloadPrimaryCandidate(
            containerID: legacyContainerID, source: "Quarters migration")
    }

    private nonisolated static func downloadPrimaryCandidate(containerID: String,
                                                             source: String) async -> Candidate? {
        guard let url = backupFileURL(containerID: containerID) else { return nil }
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        } catch {
            // A genuinely absent item used to cost the full ten-second retry window, making a
            // first-time user stare at the iCloud check before onboarding could begin.
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        }
        for _ in 0..<20 {
            if let data = try? Data(contentsOf: url),
               let candidate = validatedCandidate(data: data, source: source) {
                return candidate
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return nil
    }

    private func stage(_ candidate: Candidate) {
        pendingRestore = candidate.snapshot
        pendingRestoreSource = candidate.source
        status = "Found \(candidate.snapshot.summary) in \(BackupRules.sourceName(candidate.source))"
        if candidate.snapshot.completedOnboarding {
            onReturningUserDetected?()
        }
    }

    func discardPendingRestore() {
        UserDefaults.standard.set(true, forKey: Self.initialRestoreOfferShownKey)
        pendingRestore = nil
        pendingRestoreSource = nil
        pendingRestoreWasAskedFor = false
    }

    /// The restore question, the same on every device: what the backup holds and what taking it
    /// replaces. It named three counts and asked "Restore it?", while a restore also replaces
    /// the listening history, the routines' settings and the app's own.
    var restoreQuestion: String {
        guard let snapshot = pendingRestore else { return "" }
        let saved = snapshot.savedAt.formatted(.dateTime.month().day().hour().minute())
        return "The \(BackupRules.sourceName(pendingRestoreSource)) backup from \(snapshot.device), saved \(saved), holds \(snapshot.summary). "
            + "Restoring replaces this \(DeviceRole.current.name)\u{2019}s podcast library, listening history, routines and settings with the backup\u{2019}s."
    }

    /// Not taking it: "Start fresh" on a new install, "Cancel" when it was asked for in Settings.
    var restoreDeclineTitle: String { pendingRestoreWasAskedFor ? "Cancel" : "Start fresh" }

    /// Called at launch. Offers recovery at most once when this install has no library of its own
    /// — a fresh install or a reinstall — and never applies one without asking.
    func checkForRestore() async {
        // A first launch shows a "checking iCloud" screen until this finishes. A slow or stuck
        // iCloud must not hold it there: after a while onboarding goes ahead, and a backup found
        // after that is still offered.
        let patience = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled else { return }
            self?.initialRestoreCheckFinished = true
        }
        defer {
            patience.cancel()
            initialRestoreCheckFinished = true
        }
        guard enabled, LegacyCloud.mayRead(.personal) else { return }
        guard !UserDefaults.standard.bool(forKey: Self.initialRestoreOfferShownKey) else { return }
        let catalogURL = supportDir.appendingPathComponent("podcast-catalog.sqlite")
        let legacyURL = supportDir.appendingPathComponent("podcasts.json")
        if FileManager.default.fileExists(atPath: catalogURL.path) {
            let hasShows = await Task.detached(priority: .utility) {
                // Failure is not evidence of an empty install; preserve it for explicit repair.
                guard let catalog = try? PodcastCatalog.open(at: catalogURL),
                      let shows = try? catalog.load(legacyURL: legacyURL) else { return true }
                return !shows.isEmpty
            }.value
            if hasShows {
                UserDefaults.standard.set(true, forKey: Self.initialRestoreOfferShownKey)
                return
            }
        }
        let localCatalogue = try? Data(contentsOf: supportDir.appendingPathComponent("podcasts.json"))
        let localShows = localCatalogue
            .flatMap { try? JSONDecoder().decode([PodcastBackupSummary].self, from: $0) } ?? []
        guard localShows.isEmpty else {
            // This is already an established install. Remember that fact so deleting the final
            // subscription later cannot make a recovery prompt suddenly appear.
            UserDefaults.standard.set(true, forKey: Self.initialRestoreOfferShownKey)
            return
        }

        if let candidate = await Self.bestRestoreCandidate(),
           candidate.snapshot.podcastCount + candidate.snapshot.routineCount > 0 {
            // An automatic restore is a one-time first-run offer. Persist this before presenting
            // it so killing the app at the alert cannot make the same offer recur every launch.
            // Settings can still call offerRestore() explicitly at any time.
            UserDefaults.standard.set(true, forKey: Self.initialRestoreOfferShownKey)
            stage(candidate)
        }
    }

    /// User-initiated restore. The automatic `checkForRestore` bails when the device already has
    /// local data (so it can't clobber a device you've been using) — but that also means a Mac that
    /// has been opened once will never be offered the phone's backup. This loads the latest snapshot
    /// regardless and offers it; the actual apply is still gated behind the confirmation prompt.
    func offerRestore() async {
        pendingRestoreWasAskedFor = true
        busy = true
        defer { busy = false }
        let candidate = await Self.bestRestoreCandidate()
        if let candidate { stage(candidate) }
        else { status = "No iCloud backup found to restore" }
    }

    /// Write the snapshot's files and defaults back, then reload the stores.
    func restore(_ snapshot: Snapshot) {
        guard snapshot.podcastCount == 0 || snapshot.files["podcasts.json"] != nil else {
            status = "Restore stopped — this backup says it has podcasts but its catalogue is missing"
            return
        }
        var failed: [String] = []
        for (name, data) in snapshot.files {
            let dest = supportDir.appendingPathComponent(name)
            do {
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try data.write(to: dest, options: .atomic)
            } catch {
                failed.append(name)
            }
        }
        guard failed.isEmpty else {
            status = "Restore failed while writing \(failed.joined(separator: ", "))"
            return
        }
        if let plist = try? PropertyListSerialization.propertyList(from: snapshot.defaults,
                                                                   options: [], format: nil) as? [String: Any],
           let bundleID = Bundle.main.bundleIdentifier {
            // The backup's settings, with this installation's own bookkeeping left as it is: its
            // sync engines' state, its alarms, and onboarding done here staying done.
            let current = UserDefaults.standard.persistentDomain(forName: bundleID) ?? [:]
            UserDefaults.standard.setPersistentDomain(BackupRules.restored(from: plist, over: current),
                                                      forName: bundleID)
        }
        pendingRestore = nil
        pendingRestoreWasAskedFor = false
        let source = pendingRestoreSource
        pendingRestoreSource = nil
        UserDefaults.standard.set(true, forKey: Self.initialRestoreOfferShownKey)
        onRestore?()
        status = "Restored \(snapshot.summary)\(source.map { " from \(BackupRules.sourceName($0))" } ?? "")"
        // A legacy restore immediately establishes a Banana recovery point. The TestFlight build
        // can then restore from the Banana container even after the old Quarters entitlement is
        // removed in some future release.
        Task { await backUpNow(userInitiated: true) }
    }
}
