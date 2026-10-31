import Foundation
import os

private let dlLog = Logger(subsystem: "com.boris.banana", category: "sync")

/// Downloads episode audio **directly on the Watch** from its source URL (over the
/// Watch's own Wi-Fi/cellular), instead of receiving the file over the slow
/// WatchConnectivity link. Falls back to asking the phone to transfer the file if
/// the direct download fails (e.g. no network).
@MainActor
final class WatchDownloadManager: NSObject, ObservableObject {
    static let shared = WatchDownloadManager()

    struct ActiveDownload: Identifiable { let id: String; let title: String; var fraction: Double }
    /// In-flight direct downloads, for the UI.
    @Published private(set) var active: [ActiveDownload] = []

    static let sessionIdentifier = "com.boris.banana.watchdl"
    private var backgroundCompletion: (() -> Void)?
    private var tasks: [Int: Meta] = [:]   // task id → episode meta
    private var restoringTasks = true
    private var pendingDownloads: [(Meta, URL)] = []
    /// When each direct download was enqueued in THIS process. Tasks adopted from a previous
    /// process get `.distantPast` — surviving a relaunch already proves they're not moving.
    private var enqueuedAt: [String: Date] = [:]
    /// Last published 5%-bucket per task id, checked from `didWriteData` (called on the
    /// session's delegate queue, off the main actor) before paying for a decode + Task hop.
    /// Missing entries default to bucket 0 to mirror the `fraction: 0` already seeded by
    /// `enqueue`/`adoptBackgroundTasks`, so the very first chunk of a download doesn't
    /// spuriously look "changed".
    nonisolated private static let lastBucket = OSAllocatedUnfairLock<[Int: Int]>(initialState: [:])

    private struct Meta: Codable, Sendable {
        let id: String
        let title: String
        let podcast: String
        let ext: String
    }

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false   // we want it promptly, not "whenever convenient"
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
        // Background URLSession tasks outlive this process. Rehydrate their metadata before
        // accepting new instructions so a relaunch neither loses a completed episode nor starts
        // a duplicate download for one already owned by the daemon.
        adoptBackgroundTasks()
    }

    /// Start a direct download (skips ones already present).
    func download(episodeID: String, title: String, podcast: String, url: URL) {
        if WatchEpisodeStore.shared.episodes.contains(where: { $0.id == episodeID }) {
            // Already here — and the phone clearly doesn't know, or it wouldn't have instructed
            // us again. Silently dropping the instruction left the phone re-sending it on every
            // cold launch forever; re-ack so the sets converge.
            WatchSyncManager.shared.confirmEpisodeOnWatch(episodeID)
            return
        }
        let ext = url.pathExtension.isEmpty ? "mp3" : url.pathExtension
        let meta = Meta(id: episodeID, title: title, podcast: podcast, ext: ext)
        if restoringTasks {
            if !pendingDownloads.contains(where: { $0.0.id == episodeID }) {
                pendingDownloads.append((meta, url))
            }
            return
        }
        enqueue(meta, from: url)
    }

    private func enqueue(_ meta: Meta, from url: URL) {
        guard tasks.values.allSatisfy({ $0.id != meta.id }) else { return }
        let task = session.downloadTask(with: url)
        task.taskDescription = Self.encode(meta)
        tasks[task.taskIdentifier] = meta
        enqueuedAt[meta.id] = Date()
        active.append(ActiveDownload(id: meta.id, title: meta.title, fraction: 0))
        dlLog.notice("watch: direct-download start \(meta.id)")
        task.resume()
    }

    /// watchOS defers background downloads indefinitely without failing them, which starves
    /// the file-transfer fallback forever. Called whenever the app comes to the foreground:
    /// cancel anything that clearly isn't moving so the failure path (→ phone sends the
    /// file over WatchConnectivity) actually runs.
    func escalateStalled() {
        guard !restoringTasks else { return }
        let now = Date()
        let stalled = Set(active.compactMap { download -> String? in
            let age = now.timeIntervalSince(enqueuedAt[download.id] ?? .distantPast)
            let neverStarted = download.fraction < 0.05 && age > 180
            let crawling = age > 3600
            return (neverStarted || crawling) ? download.id : nil
        })
        guard !stalled.isEmpty else { return }
        session.getAllTasks { sessionTasks in
            for task in sessionTasks {
                guard let meta = Self.decode(task.taskDescription), stalled.contains(meta.id) else { continue }
                dlLog.notice("watch: direct-download stalled \(meta.id) — cancelling to trigger file fallback")
                task.cancel()   // didCompleteWithError(.cancelled) requests the fallback
            }
        }
    }

    private func adoptBackgroundTasks() {
        restoringTasks = true
        session.getAllTasks { [weak self] sessionTasks in
            // Extract only small Sendable values before crossing onto the main actor.
            let recovered: [(Int, Meta)] = sessionTasks.compactMap { task in
                Self.decode(task.taskDescription).map { (task.taskIdentifier, $0) }
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                for (taskID, meta) in recovered {
                    self.tasks[taskID] = meta
                    if !self.active.contains(where: { $0.id == meta.id }) {
                        self.active.append(ActiveDownload(id: meta.id, title: meta.title, fraction: 0))
                    }
                }
                self.restoringTasks = false
                let pending = self.pendingDownloads
                self.pendingDownloads.removeAll(keepingCapacity: false)
                for (meta, url) in pending {
                    self.enqueue(meta, from: url)
                }
                // The foreground escalation check fires before restore finishes on a cold
                // start; re-run it once adopted tasks have had a beat to show progress.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(10))
                    self?.escalateStalled()
                }
            }
        }
    }

    nonisolated private static func encode(_ meta: Meta) -> String? {
        try? JSONEncoder().encode(meta).base64EncodedString()
    }

    nonisolated private static func decode(_ description: String?) -> Meta? {
        guard let description,
              let data = Data(base64Encoded: description) else { return nil }
        return try? JSONDecoder().decode(Meta.self, from: data)
    }

    /// Awaited from the SwiftUI `.backgroundTask(.urlSession)` handler: recreates the
    /// session and stays alive until it finishes delivering completions after a
    /// background relaunch.
    func awaitBackgroundEvents() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            backgroundCompletion = { continuation.resume() }
            adoptBackgroundTasks()   // creates the session and restores task identity
        }
    }
}

extension WatchDownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        let fraction = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        let id = downloadTask.taskIdentifier
        // Five-percent buckets: URLSession calls this per network chunk (hundreds to a few
        // thousand times per episode), and only a bucket change ever results in a published
        // write. Precheck the bucket here, off the main actor and before paying for the
        // taskDescription decode, so unchanged chunks are dropped without a decode or a Task
        // hop. Missing entries default to 0 to match the `fraction: 0` already seeded by
        // `enqueue`/`adoptBackgroundTasks`, so this mirrors today's post-hop
        // `Int(self.active[idx].fraction * 20) != bucket` guard exactly — including staying
        // silent through the initial bucket-0 chunks.
        let bucket = Int(fraction * 20)
        let changed = Self.lastBucket.withLock { table in
            let prev = table[id] ?? 0
            if prev == bucket { return false }
            table[id] = bucket
            return true
        }
        guard changed else { return }
        let desc = downloadTask.taskDescription
        Task { @MainActor in
            guard let meta = self.tasks[id] ?? Self.decode(desc) else { return }
            self.tasks[id] = meta
            if !self.active.contains(where: { $0.id == meta.id }) {
                self.active.append(ActiveDownload(id: meta.id, title: meta.title, fraction: 0))
            }
            guard let idx = self.active.firstIndex(where: { $0.id == meta.id }) else { return }
            // Belt-and-suspenders: the off-actor precheck above already gates on the bucket,
            // but this keeps `active[idx].fraction` monotonic under the same rule it always
            // used, in case a lower bucket somehow reaches the main actor after a higher one.
            guard Int(self.active[idx].fraction * 20) != bucket else { return }
            self.active[idx].fraction = fraction
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // location is valid only during this call — stage it immediately.
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.moveItem(at: location, to: staged)
        let id = downloadTask.taskIdentifier
        Self.lastBucket.withLock { $0[id] = nil }   // task id may be reused by a later download
        let carried = Self.decode(downloadTask.taskDescription)
        Task { @MainActor in
            guard let meta = self.tasks[id] ?? carried else {
                try? FileManager.default.removeItem(at: staged)
                dlLog.error("watch: completed background download had no recoverable metadata")
                return
            }
            self.tasks[id] = nil
            self.active.removeAll { $0.id == meta.id }
            self.enqueuedAt[meta.id] = nil
            guard WatchEpisodeStore.shared.add(
                episodeID: meta.id,
                title: meta.title,
                podcast: meta.podcast,
                from: staged,
                ext: meta.ext
            ) else {
                try? FileManager.default.removeItem(at: staged)
                dlLog.error("watch: direct-download staging failed \(meta.id) — requesting file fallback")
                WatchSyncManager.shared.requestFileFallback(meta.id)
                return
            }
            dlLog.notice("watch: direct-download finished \(meta.id)")
            WatchSyncManager.shared.confirmEpisodeOnWatch(meta.id)   // tell phone to stop trying
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let id = task.taskIdentifier
        Self.lastBucket.withLock { $0[id] = nil }   // task id may be reused by a later download
        let carried = Self.decode(task.taskDescription)
        Task { @MainActor in
            guard let meta = self.tasks[id] ?? carried else {
                dlLog.error("watch: failed background download had no recoverable metadata")
                return
            }
            self.tasks[id] = nil
            self.active.removeAll { $0.id == meta.id }
            self.enqueuedAt[meta.id] = nil
            dlLog.error("watch: direct-download failed \(meta.id) — requesting file fallback (\(error.localizedDescription))")
            WatchSyncManager.shared.requestFileFallback(meta.id)     // ask phone to WC-transfer it
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.backgroundCompletion?()
            self.backgroundCompletion = nil
        }
    }
}
