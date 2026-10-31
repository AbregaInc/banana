import Foundation
import CryptoKit

/// Stores episode transcripts as small JSON files, loaded on demand. Keeps memory flat
/// (a 1-hour episode is a few thousand words) and survives relaunches.
@MainActor
final class TranscriptStore: ObservableObject {
    static let shared = TranscriptStore()

    /// The transcript for the episode currently open in the transcript view.
    @Published private(set) var current: Transcript?

    /// Created once. As a computed property this ran `createDirectory` on EVERY access — and
    /// `has()` sits under status reads that fire at 1 Hz from TranscriptView and 5 Hz from the
    /// continued-processing ticker, for hours.
    private let dir: URL = {
        let d = AppSupport.directory
            .appendingPathComponent("Transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private func sanitized(_ episodeID: String) -> String {
        episodeID.replacingOccurrences(of: "/", with: "_")
    }
    private func url(_ episodeID: String) -> URL {
        dir.appendingPathComponent("\(sanitized(episodeID)).json")
    }

    /// Sanitized ids with a transcript on disk — one directory listing, then pure memory.
    /// `has()` used to stat the filesystem per call, at the tick rates above.
    /// (partial-*.json checkpoints share this directory; they are not finished transcripts.)
    private lazy var knownIDs: Set<String> = {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return Set(names.filter { $0.hasSuffix(".json") && !$0.hasPrefix("partial-") }
            .map { String($0.dropLast(".json".count)) })
    }()

    func has(_ episodeID: String) -> Bool { knownIDs.contains(sanitized(episodeID)) }

    func transcript(for episodeID: String) -> Transcript? {
        guard let data = try? Data(contentsOf: url(episodeID)) else { return nil }
        return try? JSONDecoder().decode(Transcript.self, from: data)
    }

    /// Same decode as `transcript(for:)` but off the main actor, with no iCloud round-trip.
    /// For callers that only need whatever is already on local disk (voice-note excerpt capture,
    /// Watch note ingest) and would rather skip a transcript than block on a cloud fetch.
    func localTranscriptAsync(for episodeID: String) async -> Transcript? {
        let fileURL = url(episodeID)
        return await Task.detached(priority: .userInitiated, operation: { () -> Transcript? in
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            return try? JSONDecoder().decode(Transcript.self, from: data)
        }).value
    }

    /// Large transcripts can contain tens of thousands of words. Reading and decoding one on the
    /// main actor is exactly the "tap Transcript → app freezes/crashes" path; views and background
    /// orchestration use this async version.
    func transcriptAsync(for episodeID: String) async -> Transcript? {
        let fileURL = url(episodeID)
        let local: Transcript? = await Task.detached(priority: .userInitiated, operation: { () -> Transcript? in
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            return try? JSONDecoder().decode(Transcript.self, from: data)
        }).value
        // A publisher transcript is already the highest-quality tier; no remote read can improve it.
        if local?.source == .feed { return local }

        // The data platform's copy, when another device has a better one (its text comes down on
        // first use, `TranscriptAdapter`).
        if await SpaceSyncLaunch.ensureBlob(type: TranscriptAdapter.type, id: episodeID, field: TranscriptAdapter.bodyField) {
            await spaceWrites[episodeID]?.value
            if let better = await Task.detached(priority: .userInitiated, operation: { () -> Transcript? in
                guard let data = try? Data(contentsOf: fileURL) else { return nil }
                return try? JSONDecoder().decode(Transcript.self, from: data)
            }).value, better.source.qualityRank > (local?.source.qualityRank ?? 0) {
                if better.source == .feed { return better }
                return await remoteOrLocal(better, episodeID: episodeID)
            }
        }
        return await remoteOrLocal(local, episodeID: episodeID)
    }

    /// iCloud Drive's copy when it's better than `local`.
    private func remoteOrLocal(_ local: Transcript?, episodeID: String) async -> Transcript? {
        // Completed transcripts are tiny relative to audio. Checking only when an episode or a
        // contextual note needs one gives cross-device upgrades without a polling daemon.
        let remote = await Task.detached(priority: .utility, operation: {
            TranscriptCloudFiles.read(episodeID: episodeID)
        }).value
        if let remote {
            if let local, remote.source.qualityRank <= local.source.qualityRank { return local }
            await persist(remote, origin: .icloud)
            return remote
        }
        return local
    }

    func save(_ transcript: Transcript) {
        if let existing = self.transcript(for: transcript.episodeID),
           existing.source.qualityRank > transcript.source.qualityRank { return }
        if let data = try? JSONEncoder().encode(transcript) {
            try? data.write(to: url(transcript.episodeID), options: .atomic)
            knownIDs.insert(sanitized(transcript.episodeID))
            noteSynced(transcript, origin: .local)
        }
        if current?.episodeID == transcript.episodeID { current = transcript }
        Task.detached(priority: .utility) { TranscriptCloudFiles.write(transcript) }
        VoiceNoteStore.shared.backfillContext(using: transcript)
    }

    /// Persists `transcript` unless a higher-quality transcript already exists (locally or in
    /// iCloud), in which case that existing transcript wins and is returned instead — callers
    /// that want "whatever is now current for this episode" should use the return value rather
    /// than assuming their input was the one that got saved.
    @discardableResult
    func saveAsync(_ transcript: Transcript) async -> Transcript {
        if let existing = await transcriptAsync(for: transcript.episodeID),
           existing.source.qualityRank > transcript.source.qualityRank { return existing }
        await persist(transcript, origin: .local)
        return transcript
    }

    /// Where a transcript being kept came from: made here (it goes everywhere), iCloud Drive's
    /// copy, or the data platform's.
    private enum Origin { case local, icloud, space }

    private func persist(_ transcript: Transcript, origin: Origin) async {
        let upload = origin == .local
        let fileURL = url(transcript.episodeID)
        let saved = await Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(transcript) else { return false }
            do {
                try data.write(to: fileURL, options: .atomic)
                return true
            } catch {
                return false
            }
        }.value
        guard saved else { return }
        knownIDs.insert(sanitized(transcript.episodeID))
        noteSynced(transcript, origin: origin)
        if current?.episodeID == transcript.episodeID { current = transcript }
        if upload {
            Task.detached(priority: .utility) { TranscriptCloudFiles.write(transcript) }
        }
        VoiceNoteStore.shared.backfillContext(using: transcript)
    }

    func delete(_ episodeID: String) {
        try? FileManager.default.removeItem(at: url(episodeID))
        knownIDs.remove(sanitized(episodeID))
        if current?.episodeID == episodeID { current = nil }
        // Only this device's copy goes: a transcript is worked out, not a person's to delete
        // everywhere (`TranscriptAdapter`).
        if syncIndex?.removeValue(forKey: episodeID) != nil { saveSyncIndex() }
    }

    /// Another account signed in on this device and the person said to clear it first
    /// (docs/design/DATA-PLATFORM.md §2): every transcript here goes, with its index and packed
    /// copies. This device only: nothing is reported and iCloud Drive isn't touched.
    func clearForAccountChange() {
        for task in spaceWrites.values { task.cancel() }
        spaceWrites = [:]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
        knownIDs = []
        current = nil
        if syncIndex != nil { syncIndex = [:] }
        try? FileManager.default.removeItem(at: Self.syncIndexURL)
        try? FileManager.default.removeItem(at: Self.syncBlobDirectory)
    }

    // MARK: - The data platform (docs/design/DATA-PLATFORM.md, `TranscriptAdapter`)

    /// Every finished transcript here by episode id, with its source: the adapter lists them
    /// without reading one. Built once, off the main actor, then kept up as transcripts are kept.
    private var syncIndex: [String: Transcript.Source]?
    private nonisolated static var syncIndexURL: URL {
        AppSupport.directory.appendingPathComponent("transcripts-sync-index.json")
    }
    /// The packed copies that go up (`TranscriptAdapter.packed`).
    nonisolated static var syncBlobDirectory: URL {
        AppSupport.directory.appendingPathComponent("TranscriptBlobs", isDirectory: true)
    }
    /// Transcripts that came down from the space, still being read and kept.
    private var spaceWrites: [String: Task<Void, Never>] = [:]

    /// Reads (or, the first time, builds) the index, before the adapter registers.
    func prepareSyncIndex() async {
        guard syncIndex == nil else { return }
        let directory = dir
        let index = await Task.detached(priority: .utility) { () -> [String: Transcript.Source] in
            if let data = try? Data(contentsOf: Self.syncIndexURL),
               let index = try? JSONDecoder().decode([String: Transcript.Source].self, from: data) {
                return index
            }
            struct Head: Decodable { var episodeID: String; var source: Transcript.Source }
            var index: [String: Transcript.Source] = [:]
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names where name.hasSuffix(".json") && !name.hasPrefix("partial-") {
                guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                      let head = try? JSONDecoder().decode(Head.self, from: data) else { continue }
                index[head.episodeID] = head.source
            }
            if let data = try? JSONEncoder().encode(index) { try? data.write(to: Self.syncIndexURL, options: .atomic) }
            return index
        }.value
        guard syncIndex == nil else { return }
        syncIndex = index
        // Built after the adapter joined: a seed under way enters these with their seed clocks
        // (before one, the seed reads them itself).
        SyncReport.arrived(TranscriptAdapter.type, Array(index.keys))
    }

    private func saveSyncIndex() {
        guard let syncIndex, let data = try? JSONEncoder().encode(syncIndex) else { return }
        let url = Self.syncIndexURL
        Task.detached(priority: .utility) { try? data.write(to: url, options: .atomic) }
    }

    /// A transcript was kept here: into the index, and reported to the move off iCloud (made
    /// here: an edit; from iCloud Drive: a late arrival; from the space: neither).
    private func noteSynced(_ transcript: Transcript, origin: Origin) {
        if syncIndex != nil {
            syncIndex?[transcript.episodeID] = transcript.source
            saveSyncIndex()
        }
        switch origin {
        case .local: SyncReport.changed(TranscriptAdapter.type, [transcript.episodeID])
        case .icloud: LegacyCloud.applyingFromCloud { SyncReport.changed(TranscriptAdapter.type, [transcript.episodeID]) }
        case .space: break
        }
    }

    /// Load a transcript into `current` for the transcript view (nil if none yet).
    func open(_ episodeID: String) { current = transcript(for: episodeID) }
    func closeCurrent() { current = nil }
}

extension TranscriptStore: TranscriptSyncSource {
    var syncTranscripts: [String: Transcript.Source] { syncIndex ?? [:] }
    func syncTranscriptFile(_ episodeID: String) -> URL { url(episodeID) }
    var syncBlobDirectory: URL { Self.syncBlobDirectory }

    func storeSyncedTranscript(_ episodeID: String, packed file: URL) {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-\(UUID().uuidString).lzfse")
        guard (try? FileManager.default.copyItem(at: file, to: copy)) != nil else { return }
        let previous = spaceWrites[episodeID]
        spaceWrites[episodeID] = Task { @MainActor [weak self] in
            await previous?.value
            let transcript = await Task.detached(priority: .utility) { () -> Transcript? in
                defer { try? FileManager.default.removeItem(at: copy) }
                return TranscriptAdapter.unpack(copy)
            }.value
            guard let self, let transcript, transcript.episodeID == episodeID, let index = self.syncIndex else { return }
            if transcript.source.qualityRank > (index[episodeID]?.qualityRank ?? 0) {
                await self.persist(transcript, origin: .space)
            }
        }
    }
}

/// File-per-episode iCloud transport for finished transcript text only. Audio and partial ASR
/// checkpoints remain local; syncing either would multiply network, disk and conflict states for no
/// product benefit. Files are LZFSE-compressed because word-level JSON is highly repetitive.
private enum TranscriptCloudFiles {
    /// Nil once transcripts no longer come from iCloud (`LegacyCloud`, off).
    private static var root: URL? {
        guard LegacyCloud.mayRead(.personal), let container = FileManager.default.url(
            forUbiquityContainerIdentifier: CloudBackup.containerID) else { return nil }
        let directory = container
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Transcripts", isDirectory: true)
        if LegacyCloud.mayWrite(.personal) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    private static func url(_ episodeID: String) -> URL? {
        let digest = SHA256.hash(data: Data(episodeID.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return root?.appendingPathComponent(digest).appendingPathExtension("lzfse")
    }

    static func read(episodeID: String) -> Transcript? {
        guard let file = url(episodeID), FileManager.default.fileExists(atPath: file.path) else { return nil }
        try? FileManager.default.startDownloadingUbiquitousItem(at: file)
        guard let compressed = try? Data(contentsOf: file),
              let data = try? (compressed as NSData).decompressed(using: .lzfse) as Data,
              let transcript = try? JSONDecoder().decode(Transcript.self, from: data),
              transcript.episodeID == episodeID else { return nil }
        return transcript
    }

    static func write(_ transcript: Transcript) {
        guard LegacyCloud.mayWrite(.personal), let file = url(transcript.episodeID) else { return }
        if let existing = read(episodeID: transcript.episodeID),
           existing.source.qualityRank > transcript.source.qualityRank { return }
        guard let json = try? JSONEncoder().encode(transcript),
              let compressed = try? (json as NSData).compressed(using: .lzfse) as Data else { return }
        do {
            try compressed.write(to: file, options: .atomic)
        } catch {
            PlaybackDiagnostics.shared.log("transcript: iCloud write failed", "\(error)")
        }
    }
}
