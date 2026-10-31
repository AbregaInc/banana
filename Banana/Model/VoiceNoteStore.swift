import Foundation
import SwiftUI
import os

/// Owns the cross-device Notes workflow.
///
/// The phone remains the capture and transcription hub because it owns the microphone route,
/// Reminders write-back, and the Watch connection. Notes and their small AAC recordings are then
/// mirrored as individual files in the user's iCloud container so the Mac can be a first-class
/// review surface. There is no polling timer: writes happen after capture/transcription/deletion,
/// and reads happen at launch, foreground, or when Notes is opened.
@MainActor
final class VoiceNoteStore: ObservableObject {
    static let shared = VoiceNoteStore()

    private static let log = Logger(subsystem: "com.boris.banana", category: "voiceNotes")
    /// Block writes after an opening or migration failure; preserve the original files.
    private var saveIsUnsafe = false

    enum SyncState: Equatable {
        case idle
        case syncing
        case synced(Date)
        case unavailable
    }

    @Published private(set) var revision = 0
    @Published private(set) var noteCount = 0
    @Published private(set) var archivedCount = 0
    @Published private(set) var storageError: String?
    @Published private(set) var reminderWriteError: String?
    private var repository: NoteRepository?
    private var previewNotes: [VoiceNote]?
    private var noteCache: [UUID: VoiceNote] = [:]
    private let queryCache = NoteQueryCache()
    /// Compatibility for explicit cloud export only. Views use pages and identity lookups.
    var notes: [VoiceNote] { previewNotes ?? ((try? repository?.all()) ?? []) }

    func note(_ id: UUID) -> VoiceNote? {
        if let previewNotes { return previewNotes.first { $0.id == id } }
        if let cached = noteCache[id] { return cached }
        guard let value = try? repository?.note(id) else { return nil }
        if noteCache.count >= 32 { noteCache.removeAll(keepingCapacity: true) }
        noteCache[id] = value
        return value
    }
    func allNoteIDs() -> [UUID] { previewNotes?.map(\.id) ?? ((try? repository?.ids()) ?? []) }
    func page(search: String, archived: Bool, offset: Int = 0, filter: LiveFilter? = nil) async throws -> NoteRepository.Page {
        if let previewNotes {
            let matches = queryCache.matching(previewNotes, search: search, archived: archived, filter: filter)
            return NoteRepository.Page(rows: Array(matches.dropFirst(offset).prefix(100)), total: matches.count)
        }
        guard let repository else { throw NoteRepository.MigrationError.unreadableRecords }
        return try await Task.detached(priority: .userInitiated) {
            try repository.page(search: search, archived: archived, offset: offset, filter: filter)
        }.value
    }
    @Published private(set) var capturing: VoiceNote.Kind?
    @Published private(set) var syncState: SyncState = .idle
    private var transcribing: Set<UUID> = []

    #if os(iOS)
    let recorder = VoiceMemoRecorder()
    private let reminders = RemindersService()
    private var reminderWriteTask: Task<Void, Never>?
    weak var connectivity: PhoneConnectivity?

    /// Held while a Watch recording interrupts playback on the phone.
    private var remoteNoteContext: VoiceNote.Context?
    private var pendingFilename: String?
    private var pendingKind: VoiceNote.Kind = .general
    private var resumeAfter = false
    private var captureTrace: DiagnosticSpan?
    /// The transcript excerpt for the in-progress capture, fetched off the main actor so
    /// `beginCapture` doesn't block the record button on a full transcript decode. Awaited by
    /// `finishCapture` right before the note (and its Reminders entry, which quotes the excerpt)
    /// is built.
    private var pendingExcerpt: Task<String?, Never>?
    #endif

    weak var player: PlayerController?
    private(set) var liveContext: VoiceNote.Context?
    private var refreshTask: Task<Void, Never>?

    static var audioDirectory: URL {
        let directory = AppSupport.directory
            .appendingPathComponent("VoiceNotes", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        return directory
    }

    private var storeURL: URL {
        Self.audioDirectory.appendingPathComponent("notes.json")
    }

    private init() {
        load()
        Task { [weak self] in
            await self?.resumePendingTranscriptions()
            await self?.refreshFromCloud()
        }
    }

    func matchingNotes(search: String, archived: Bool) -> [VoiceNote] {
        if let previewNotes { return Array(queryCache.matching(previewNotes, search: search, archived: archived).prefix(100)) }
        return (try? repository?.page(search: search, archived: archived).rows) ?? []
    }

    #if DEBUG && (targetEnvironment(simulator) || os(macOS) || STRESS_DEVICE_AUDIT)
    func injectStress(_ values: [VoiceNote]) {
        previewNotes = nil
        _ = storeBatch(values)
    }
    #endif

    var isRecording: Bool { capturing != nil }

    #if os(iOS)
    /// A note an interruption ended still owes the podcast its resume; the player takes it when
    /// the interruption ends.
    private var resumeWhenInterruptionEnds = false
    /// When an interruption last ended a note. Siri's "stop" arrives after Siri has already taken
    /// the audio — and so after the note already ended — and used to start a new note instead.
    private(set) var lastInterruptedFinish: Date?

    func takeResumeWhenInterruptionEnds() -> Bool {
        defer { resumeWhenInterruptionEnds = false }
        return resumeWhenInterruptionEnds
    }

    /// The podcast should come back when the current note ends.
    func resumePlaybackWhenDone() { resumeAfter = true }

    /// Whether a start/stop toggle arriving now is the "stop" for a note an interruption already
    /// ended, rather than a request for a new one.
    var justEndedByInterruption: Bool {
        lastInterruptedFinish.map { Date().timeIntervalSince($0) < 8 } ?? false
    }
    #endif

    // MARK: - Capture hub (iPhone)

    #if os(iOS)
    /// Snapshot podcast context before pausing, then use one button as start/stop.
    func beginCapture(
        kind: VoiceNote.Kind = .podcastCapture,
        parent: DiagnosticTraceContext? = nil
    ) {
        guard capturing == nil else { finishCapture(); return }
        let trace = DiagnosticJournal.shared.startSpan(
            "voiceNote.capture",
            parent: parent,
            attributes: [
                "source": "iPhone",
                "kind": kind.rawValue,
                "remote_trigger": parent == nil ? "false" : "true",
            ])
        captureTrace = trace

        if kind == .podcastCapture {
            liveContext = snapshotPodcastContextFast()
        } else {
            liveContext = nil
            pendingExcerpt = nil
        }
        pendingKind = kind
        if let player, player.isPlaying {
            resumeAfter = true
            player.setPlaying(false, reason: "voice note")
        } else {
            // Started during an interruption (Siri's "Record a note"): the podcast was playing a
            // moment ago and the interruption paused it. Take over its resume, so it comes back
            // when this note ends — not under the note when the interruption ends.
            resumeAfter = player?.takePendingInterruptionResume() ?? false
        }

        guard let filename = recorder.start(parent: trace.context) else {
            if resumeAfter { player?.setPlaying(true, reason: "voice note aborted") }
            liveContext = nil
            pendingExcerpt = nil
            DiagnosticJournal.shared.finish(
                trace,
                status: .failed,
                reason: "recorder_start_failed")
            captureTrace = nil
            return
        }
        connectivity?.sendNoteStart(parent: trace.context)
        pendingFilename = filename
        capturing = kind
    }

    /// Kept fully synchronous — `VoiceMemoRecorder`'s AVAudioSession-interruption handler calls
    /// this from inside `MainActor.assumeIsolated` specifically so `recorder.stop()` reads
    /// `recorder.currentTime` before it zeroes (a documented prior bug: deferring that read let
    /// an interrupted note's duration read back as 0 and get silently deleted), AND so the note
    /// itself is inserted/saved/uploaded before this call returns — the same interruption (e.g. an
    /// incoming call) that triggered this can background or kill the app immediately after. Only
    /// the transcript-excerpt *patch* — which `pendingExcerpt` may not have resolved yet — is
    /// deferred, via the same backfill-after-the-fact pattern `backfillContext(using:)` already
    /// uses for a transcript that arrives from another device later.
    /// - Parameter interrupted: the audio session was taken (a call, Siri). The podcast then
    ///   resumes when the interruption ends, not now — resuming mid-interruption made the player
    ///   note itself as "was playing" and come back under whatever followed.
    func finishCapture(interrupted: Bool = false) {
        guard capturing != nil, let filename = pendingFilename else { return }
        let result = recorder.stop()
        let trace = captureTrace
        capturing = nil
        if interrupted { lastInterruptedFinish = Date() }

        connectivity?.sendNoteStop(parent: trace?.context)
        if resumeAfter {
            if interrupted {
                resumeWhenInterruptionEnds = true
            } else {
                player?.setPlaying(true, reason: "voice note done")
            }
        }

        guard result.containsPlayableAudio else {
            let now = Date()
            let kind = pendingKind
            let context = liveContext
            let excerptTask = pendingExcerpt
            let diagnosticAttributes = result.diagnosticAttributes
            pendingFilename = nil
            liveContext = nil
            pendingExcerpt = nil
            captureTrace = nil
            let failedNote = VoiceNote(
                createdAt: now,
                updatedAt: now,
                audioFilename: filename,
                kind: kind,
                source: .iPhone,
                context: context,
                status: .failed,
                traceparent: trace?.context.traceparent)

            let noteID = failedNote.id
            persist(failedNote)
            if let trace {
                DiagnosticJournal.shared.finish(
                    trace,
                    status: .failed,
                    reason: "captured_file_has_no_playable_audio",
                    attributes: diagnosticAttributes)
            }
            applyExcerptWhenReady(excerptTask, toNoteID: noteID)
            return
        }

        guard result.playableDuration >= 0.6 else {
            try? FileManager.default.removeItem(
                at: Self.audioDirectory.appendingPathComponent(filename))
            if let trace {
                DiagnosticJournal.shared.finish(
                    trace,
                    status: .cancelled,
                    reason: "capture_too_short",
                    attributes: result.diagnosticAttributes)
            }
            pendingFilename = nil
            liveContext = nil
            pendingExcerpt = nil
            captureTrace = nil
            return
        }

        let now = Date()
        let kind = pendingKind
        let context = liveContext
        let excerptTask = pendingExcerpt
        let diagnosticAttributes = result.diagnosticAttributes
        pendingFilename = nil
        liveContext = nil
        pendingExcerpt = nil
        captureTrace = nil

        let note = VoiceNote(
            createdAt: now,
            updatedAt: now,
            audioFilename: filename,
            kind: kind,
            source: .iPhone,
            context: context,
            traceparent: trace?.context.traceparent)

        let noteID = note.id
        persist(note)
        if let trace {
            DiagnosticJournal.shared.finish(
                trace,
                status: .succeeded,
                reason: "audio_validated_and_note_persisted",
                attributes: diagnosticAttributes)
        }
        Task { await self.transcribe(noteID) }
        applyExcerptWhenReady(excerptTask, toNoteID: noteID)
    }

    /// Patches in the transcript excerpt once `excerptTask` resolves, mirroring
    /// `backfillContext(using:)` — the note itself is already durably saved by the time this
    /// runs, so losing this step (background/terminate before it completes) only means the
    /// Reminders body misses the quoted excerpt, never that the note or reminder is lost.
    private func applyExcerptWhenReady(_ excerptTask: Task<String?, Never>?, toNoteID noteID: UUID) {
        guard let excerptTask else { return }
        Task { @MainActor [weak self] in
            guard let self,
                  let excerpt = await excerptTask.value, !excerpt.isEmpty,
                  var edited = self.note(noteID) else { return }
            edited.context?.transcriptExcerpt = excerpt
            edited.updatedAt = Date()
            self.persist(edited)
        }
    }

    /// Synchronous — used by the Watch-note "noteStart" handoff path
    /// (`snapshotContextForRemoteNote()`), which isn't the record-button gesture and doesn't
    /// need the latency shortcut below.
    private func snapshotPodcastContext() -> VoiceNote.Context? {
        guard let player, let episode = player.currentEpisode else { return nil }
        let timestamp = player.preciseTime()
        let excerpt = TranscriptStore.shared.transcript(for: episode.id)?.excerpt(around: timestamp)
        return VoiceNote.Context(
            episodeID: episode.id,
            episodeTitle: episode.title,
            podcastTitle: player.currentPodcastTitle,
            timestamp: timestamp,
            transcriptExcerpt: excerpt?.isEmpty == false ? excerpt : nil)
    }

    /// Same fields as `snapshotPodcastContext()`, but returns immediately with
    /// `transcriptExcerpt: nil` and kicks off `pendingExcerpt` to fetch it off the main actor —
    /// so `beginCapture` doesn't block the record button on a full transcript decode.
    /// `finishCapture` awaits `pendingExcerpt` before the note (and its Reminders entry) is built.
    private func snapshotPodcastContextFast() -> VoiceNote.Context? {
        guard let player, let episode = player.currentEpisode else { return nil }
        let timestamp = player.preciseTime()
        let episodeID = episode.id
        pendingExcerpt = Task {
            let excerpt = await TranscriptStore.shared.localTranscriptAsync(for: episodeID)?
                .excerpt(around: timestamp)
            return excerpt?.isEmpty == false ? excerpt : nil
        }
        return VoiceNote.Context(
            episodeID: episodeID,
            episodeTitle: episode.title,
            podcastTitle: player.currentPodcastTitle,
            timestamp: timestamp,
            transcriptExcerpt: nil)
    }
    #endif

    private func transcribe(_ id: UUID) async {
        guard !transcribing.contains(id),
              var initial = note(id) else { return }
        transcribing.insert(id)
        defer { transcribing.remove(id) }
        let parent = initial.traceparent
            .flatMap(DiagnosticTraceContext.init(traceparent:))
        let trace = DiagnosticJournal.shared.startSpan(
            "voiceNote.transcription",
            parent: parent,
            attributes: [
                "note_id": id.uuidString.lowercased(),
                "engine": LocalTranscriptionEngine.selected.rawValue,
            ])

        guard let url = audioURL(for: initial), FileManager.default.fileExists(atPath: url.path) else {
            initial.status = .failed
            initial.updatedAt = Date()
            persist(initial)
            DiagnosticJournal.shared.finish(
                trace,
                status: .failed,
                reason: "audio_file_missing")
            return
        }

        do {
            let words: [TranscriptWord]
            if LocalTranscriptionEngine.selected == .parakeet {
                words = try await TranscriptionService.transcribeParakeet(fileURL: url)
            } else {
                words = try await TranscriptionService.transcribeOnDevice(fileURL: url)
            }
            let text = words.map(\.text).joined(separator: " ")
            guard var current = note(id) else {
                DiagnosticJournal.shared.finish(
                    trace,
                    status: .cancelled,
                    reason: "note_deleted_during_transcription")
                return
            }
            current.transcript = text
            current.status = text.isEmpty ? .failed : .transcribed
            current.updatedAt = Date()
            persist(current)
            DiagnosticJournal.shared.finish(
                trace,
                status: text.isEmpty ? .failed : .succeeded,
                reason: text.isEmpty ? "transcript_empty" : "transcription_persisted",
                attributes: [
                    "word_count": String(words.count),
                    "character_count": String(text.count),
                ])
        } catch {
            guard var current = note(id) else {
                DiagnosticJournal.shared.finish(
                    trace,
                    status: .cancelled,
                    reason: "note_deleted_during_transcription")
                return
            }
            current.status = .failed
            current.updatedAt = Date()
            persist(current)
            PlaybackDiagnostics.shared.log("voice note: transcription failed", "\(error)")
            DiagnosticJournal.shared.finish(
                trace,
                status: .failed,
                reason: "transcription_failed",
                attributes: ["error": error.localizedDescription])
        }
    }

    private func resumePendingTranscriptions() async {
        let pending = previewNotes?.filter { $0.status == .pendingTranscription }.map(\.id)
            ?? ((try? repository?.ids(pending: true)) ?? [])
        for id in pending { await transcribe(id) }
    }

    // MARK: - Written notes and edits

    /// Where a podcast is playing, so a written note is anchored the same way a spoken one is.
    /// Nothing is paused: typing doesn't need the audio.
    func currentPodcastContext() -> VoiceNote.Context? {
        #if os(iOS)
        return snapshotPodcastContext()
        #else
        return nil
        #endif
    }

    /// A note typed instead of spoken. It has no recording, so it's finished the moment it's
    /// saved — no transcription — and goes to Reminders the way a transcribed voice note does.
    @discardableResult
    func addWrittenNote(_ text: String, context: VoiceNote.Context?) -> UUID? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let now = Date()
        #if os(iOS)
        let source: VoiceNote.Source? = .iPhone
        #else
        let source: VoiceNote.Source? = nil
        #endif
        let note = VoiceNote(
            createdAt: now,
            updatedAt: now,
            audioFilename: "",
            transcript: trimmed,
            kind: .general,
            source: source,
            context: context,
            status: .transcribed)
        return persist(note) ? note.id : nil
    }

    /// Change a note's text — a written note, or a voice note whose transcription got words
    /// wrong. The recording, if any, stays as it was.
    @discardableResult func updateText(_ id: UUID, to text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var edited = note(id) else { return false }
        guard edited.transcript != trimmed else { return true }
        edited.transcript = trimmed
        edited.status = .transcribed
        edited.updatedAt = Date()
        guard persist(edited) else { return false }
        return true
    }

    func setArchived(_ id: UUID, _ archived: Bool) {
        guard var edited = note(id) else { return }
        edited.archivedAt = archived ? Date() : nil
        edited.updatedAt = Date()
        persist(edited)
    }

    func retry(_ id: UUID) {
        guard var edited = note(id),
              edited.status == .failed else { return }
        edited.status = .pendingTranscription
        edited.updatedAt = Date()
        persist(edited)
        Task { await transcribe(id) }
    }

    func retryReminderWrites() {
        #if os(iOS)
        scheduleReminderWrites()
        #endif
    }

    #if os(iOS)
    private func scheduleReminderWrites() {
        guard previewNotes == nil, reminderWriteTask == nil else { return }
        reminderWriteTask = Task { [weak self] in
            guard let self else { return }
            defer { self.reminderWriteTask = nil }
            do {
                // Bounded batches; yield between side effects. No polling or full-history scan.
                while let batch = try self.repository?.pendingReminders(), !batch.isEmpty {
                    var progressed = false
                    for note in batch {
                        guard let id = await self.reminders.writeNoteReminder(
                            noteID: note.id, previousID: note.reminderID,
                            title: self.reminderTitle(note), notes: self.reminderBody(note),
                            stillCurrent: { self.note(note.id) == note }) else {
                            self.reminderWriteError = "Your notes are saved. Apple Reminders write-back is pending."
                            continue
                        }
                        if let saved = try self.repository?.acknowledgeReminder(for: note, identifier: id) {
                            self.noteCache[note.id] = saved
                            self.upload(saved)
                            progressed = true
                        }
                        await Task.yield()
                    }
                    guard progressed else { break } // Offline/denied: retry at the next save/foreground.
                }
                if try self.repository?.pendingReminders(limit: 1).isEmpty == true { self.reminderWriteError = nil }
            } catch {
                self.reminderWriteError = "Your note is saved. Reminders write-back is pending and will retry. \(error.localizedDescription)"
            }
        }
    }

    private func reminderTitle(_ note: VoiceNote) -> String {
        if let transcript = note.transcript, !transcript.isEmpty {
            return String(transcript.prefix(120))
        }
        return note.status == .failed
            ? "🎙️ Voice note — couldn’t transcribe"
            : "🎙️ Voice note — transcribing…"
    }

    private func reminderBody(_ note: VoiceNote) -> String {
        var lines: [String] = []
        if let anchor = note.context?.anchorLine { lines.append(anchor) }
        if let excerpt = note.context?.transcriptExcerpt, !excerpt.isEmpty {
            lines.append("“…\(excerpt)…”")
        }
        lines.append("— captured with Banana")
        return lines.joined(separator: "\n\n")
    }

    // MARK: Watch ingest

    func snapshotContextForRemoteNote() {
        remoteNoteContext = snapshotPodcastContext()
    }

    func ingestWatchNote(audio staged: URL, meta: [String: Any]) {
        let parent = (meta["traceparent"] as? String)
            .flatMap(DiagnosticTraceContext.init(traceparent:))
        let trace = DiagnosticJournal.shared.startSpan(
            "voiceNote.ingest",
            parent: parent,
            attributes: ["source": "watchOS"])
        let inspection = VoiceCaptureResult.inspect(
            url: staged,
            reportedDuration: meta["reportedDuration"] as? TimeInterval ?? 0)
        let filename = "\(UUID().uuidString).m4a"
        let destination = Self.audioDirectory.appendingPathComponent(filename)
        do { try FileManager.default.moveItem(at: staged, to: destination) }
        catch {
            DiagnosticJournal.shared.finish(
                trace,
                status: .failed,
                reason: "staging_move_failed",
                attributes: ["error": error.localizedDescription])
            return
        }

        // The synchronous `TranscriptStore.transcript(for:)` decode used to run right here, on the
        // main actor, in a process that may have just been launched in the background solely to
        // receive this file. Kept `ingestWatchNote` itself synchronous (its only caller,
        // PhoneConnectivity.swift, already fire-and-forgets it inside `Task { @MainActor in ... }`
        // with no `await`, so changing this function's signature would require editing that file
        // too) by moving the note construction — the only part that actually needs the transcript
        // excerpt — into an async continuation below, using the off-main-actor
        // `localTranscriptAsync` instead.
        var context: VoiceNote.Context?
        var excerptTask: Task<String?, Never>?
        if let episodeID = meta["episodeID"] as? String, !episodeID.isEmpty {
            let timestamp = meta["timestamp"] as? TimeInterval
            context = VoiceNote.Context(
                episodeID: episodeID,
                episodeTitle: (meta["episodeTitle"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                podcastTitle: nil,
                timestamp: timestamp,
                transcriptExcerpt: nil)
            if let timestamp {
                excerptTask = Task {
                    let excerpt = await TranscriptStore.shared.localTranscriptAsync(for: episodeID)?
                        .excerpt(around: timestamp)
                    return excerpt?.isEmpty == false ? excerpt : nil
                }
            }
        } else {
            // Already synchronous today (`snapshotContextForRemoteNote()`, the "noteStart"
            // WCSession handler, keeps using the plain sync path) — nothing to defer here.
            context = remoteNoteContext
        }
        remoteNoteContext = nil

        let createdAt = (meta["recordedAt"] as? TimeInterval)
            .map { Date(timeIntervalSince1970: $0) } ?? Date()
        let playable = inspection.containsPlayableAudio
        let diagnosticAttributes = inspection.diagnosticAttributes

        // Persisted synchronously, right here (transcriptExcerpt possibly nil, same as other
        // callers tolerate) — this can be running in a process launched in the background solely
        // to receive this file, the tightest execution-time budget in the app before iOS suspends
        // it, so the note must be durably saved before any further suspension point rather than
        // behind an extra deferred Task. Only the excerpt patch is deferred, via
        // `applyExcerptWhenReady`, mirroring `finishCapture()`'s phone-capture path.
        let note = VoiceNote(
            createdAt: createdAt,
            updatedAt: Date(),
            audioFilename: filename,
            kind: .podcastCapture,
            source: .watch,
            context: context,
            status: playable ? .pendingTranscription : .failed,
            traceparent: trace.context.traceparent)

        let noteID = note.id
        persist(note)
        if playable {
            Task { await self.transcribe(noteID) }
        }
        PlaybackDiagnostics.shared.log(
            "voice note: ingested from Watch",
            note.context?.anchorLine ?? "no context")
        DiagnosticJournal.shared.finish(
            trace,
            status: playable ? .succeeded : .failed,
            reason: playable
                ? "audio_validated_and_note_persisted"
                : "received_file_has_no_playable_audio",
            attributes: diagnosticAttributes)
        applyExcerptWhenReady(excerptTask, toNoteID: noteID)
    }
    #endif

    // MARK: - Local and iCloud persistence

    func delete(_ id: UUID) {
        guard let note = note(id), storeBatch([], removing: [id]) else { return }
        removeAudio(of: note)
        // A linked reminder may have been completed independently in Apple Reminders.
        // Removing its note must not turn that completed task back into outstanding work.
        CloudFitnessSync.shared.deleteNote(id)
        SyncReport.deleted(VoiceNoteAdapter.type, [id.uuidString])
        let deletedAt = Date()
        Task.detached(priority: .utility) {
            VoiceNoteCloudFiles.delete(id: id, at: deletedAt)
        }
    }

    /// nil for a written note, which has no recording. An empty (or path-like) filename would
    /// resolve to the notes folder itself, and deleting the note would delete every recording.
    func audioURL(for note: VoiceNote) -> URL? {
        let name = note.audioFilename
        guard !name.isEmpty, (name as NSString).lastPathComponent == name, name != "..", name != "." else { return nil }
        return Self.audioDirectory.appendingPathComponent(name)
    }

    /// The note's recording, fetched from the data platform first when it isn't here yet (its
    /// audio comes down on first use; with the data platform on, `SpaceSyncFlag`). Nil when there's none.
    func ensureAudio(for note: VoiceNote) async -> URL? {
        guard let url = audioURL(for: note) else { return nil }
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard SpaceSyncFlag.isOn,
              await SpaceSyncLaunch.ensureBlob(type: VoiceNoteAdapter.type, id: note.id.uuidString,
                                               field: VoiceNoteAdapter.audioField) else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func hasAudio(for note: VoiceNote) -> Bool {
        audioURL(for: note).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    private func removeAudio(of note: VoiceNote) {
        guard let url = audioURL(for: note) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Fetch only at meaningful interaction points. This keeps Notes current without a radio- or
    /// filesystem-waking timer running while someone listens with the screen off.
    func refreshFromCloud(force: Bool = false) async {
        #if os(iOS)
        scheduleReminderWrites()
        #endif
        if !force, case .synced(let date) = syncState,
           Date().timeIntervalSince(date) < 30 {
            return
        }
        if let refreshTask {
            await refreshTask.value
            return
        }

        syncState = .syncing
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let localAudioDirectory = Self.audioDirectory
            let mayDownloadAudio = NetworkMonitor.shared.isCheap
            let snapshot = await Task.detached(priority: .utility) {
                VoiceNoteCloudFiles.readSnapshot(localAudioDirectory: localAudioDirectory,
                                                 includeAudio: mayDownloadAudio)
            }.value
            guard let snapshot else {
                self.syncState = .unavailable
                return
            }
            LegacyCloud.applyingFromCloud { self.apply(snapshot) }
            await self.resumePendingTranscriptions()
            // A note captured on the Watch/phone may beat the Mac-generated episode transcript to
            // iCloud. Revisit only the episode IDs whose context is incomplete; TranscriptStore's
            // on-demand cloud read supplies the excerpt and calls `backfillContext` below.
            let missingEpisodeIDs = (try? self.repository?.missingEpisodeIDs()) ?? []
            for episodeID in missingEpisodeIDs {
                _ = await TranscriptStore.shared.transcriptAsync(for: episodeID)
            }
            self.syncState = .synced(Date())

            #if os(iOS)
            // Retry uploads that were captured offline. A tombstone wins over an older local copy.
            // Not once notes have moved off iCloud.
            let remoteIDs = Set(snapshot.notes.map(\.id))
            for id in self.allNoteIDs() where !remoteIDs.contains(id) && LegacyCloud.mayWrite(.personal) {
                guard let note = self.note(id) else { continue }
                let deletedAt = snapshot.tombstones[note.id]
                if deletedAt == nil || note.syncDate > deletedAt! {
                    self.upload(note)
                }
            }
            #endif
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func apply(_ snapshot: VoiceNoteCloudFiles.Snapshot) {
        let deleted = snapshot.tombstones.compactMap { id, date -> VoiceNote? in
            guard let local = note(id), local.syncDate <= date else { return nil }
            return local
        }
        let incoming = snapshot.notes.filter { remote in
            snapshot.tombstones[remote.id].map { remote.syncDate > $0 } ?? true
        }
        guard storeBatch(incoming, removing: deleted.map(\.id)) else { return }
        for note in deleted { removeAudio(of: note) }
        SyncReport.changed(VoiceNoteAdapter.type, incoming.map { $0.id.uuidString })
    }

    @discardableResult private func persist(_ note: VoiceNote) -> Bool {
        #if os(iOS)
        guard storeBatch([note], enqueueReminders: true) else { return false }
        scheduleReminderWrites()
        #else
        guard storeBatch([note]) else { return false }
        #endif
        upload(note)
        return true
    }

    /// Add the surrounding spoken passage after a transcript arrives on this or another device.
    /// This is the important Mac-first product path: a Watch note can be captured instantly with an
    /// episode timestamp, then become fully contextual once the Mac finishes better ASR later.
    func backfillContext(using transcript: Transcript) {
        let ids = previewNotes?.filter { $0.context?.episodeID == transcript.episodeID }.map(\.id)
            ?? ((try? repository?.ids(missingExcerptFor: transcript.episodeID)) ?? [])
        for id in ids {
            guard var note = note(id), var context = note.context,
                  context.transcriptExcerpt?.isEmpty != false, let timestamp = context.timestamp else { continue }
            let excerpt = transcript.excerpt(around: timestamp)
            guard !excerpt.isEmpty else { continue }
            context.transcriptExcerpt = excerpt
            note.context = context
            note.updatedAt = Date()
            persist(note)
            }
    }

    private func upload(_ note: VoiceNote) {
        // Metadata and deletion state travel through the live CloudKit engine. iCloud Drive is
        // attachment-only, so a missing/parked recording can never hide or resurrect a note.
        CloudFitnessSync.shared.upsert(note)
        // The data platform (docs/design/DATA-PLATFORM.md): the legacy paths' modes decide whether
        // iCloud still gets it.
        SyncReport.changed(VoiceNoteAdapter.type, [note.id.uuidString])
        let audio = audioURL(for: note)
        // A note's state must be usable everywhere, but its recording is an optional attachment:
        // never spend cellular or Low Data Mode bandwidth moving AAC automatically.
        let mayTransferAudio = NetworkMonitor.shared.isCheap
        Task.detached(priority: .utility) {
            VoiceNoteCloudFiles.write(note: note, localAudioURL: audio,
                                      includeAudio: mayTransferAudio)
        }
    }

    /// Import legacy JSON transactionally once. A malformed record rolls back the import.
    private func load() {
        do {
            repository = try NoteRepository(url: Self.audioDirectory.appendingPathComponent("notes.sqlite"), legacyURL: storeURL)
            refreshCounts()
        } catch {
            saveIsUnsafe = true
            storageError = "Notes could not be opened. Existing data was preserved. \(error.localizedDescription)"
        }
    }

    private func refreshCounts() {
        let count = previewNotes?.count ?? ((try? repository?.count()) ?? 0)
        let archived = previewNotes?.filter { $0.archivedAt != nil }.count ?? ((try? repository?.count(archived: true)) ?? 0)
        if noteCount != count { noteCount = count }
        if archivedCount != archived { archivedCount = archived }
    }

    @discardableResult private func storeBatch(_ values: [VoiceNote], removing: [UUID] = [], enqueueReminders: Bool = false) -> Bool {
        guard !saveIsUnsafe else { return false }
        do {
            let changed: Bool
            if var preview = previewNotes {
                let before = preview
                preview.removeAll { removing.contains($0.id) }
                for value in values {
                    if let i = preview.firstIndex(where: { $0.id == value.id }) {
                        if !preview[i].isNewerForSync(than: value) { preview[i] = value }
                    } else { preview.append(value) }
                }
                preview.sort { $0.createdAt > $1.createdAt }
                changed = preview != before
                previewNotes = preview
            } else {
                guard let repository else { return false }
                changed = try repository.apply(values, removing: removing, enqueueReminders: enqueueReminders)
            }
            if changed {
                noteCache.removeAll(keepingCapacity: true)
                queryCache.invalidate()
                refreshCounts()
                revision &+= 1
            }
            if storageError != nil { storageError = nil }
            return true
        } catch {
            storageError = "Notes could not be saved. \(error.localizedDescription)"
            return false
        }
    }

    /// Explicit legacy cloud seed contract. Screens never materialize this export.
    func cloudNotesSnapshot() -> [VoiceNote] { notes }

    func adoptCloudNote(_ remote: VoiceNote) {
        guard takeNote(remote) else { return }
        SyncReport.changed(VoiceNoteAdapter.type, [remote.id.uuidString])
    }

    @discardableResult
    private func takeNote(_ remote: VoiceNote) -> Bool {
        if let local = note(remote.id) {
            guard !local.isNewerForSync(than: remote) else { return false }
            if local == remote { return true }
        }
        return storeBatch([remote])
    }

    func removeCloudNote(_ id: UUID) {
        guard let note = note(id), storeBatch([], removing: [id]) else { return }
        removeAudio(of: note)
    }

    func pruneLegacyNotes(notIn cloudIDs: Set<UUID>) {
        let stale = allNoteIDs().filter { !cloudIDs.contains($0) }
        for id in stale { removeCloudNote(id) }
    }

    #if DEBUG
    /// Stable content for phone/Mac visual verification. It never touches disk or iCloud.
    func injectSampleForPreview() {
        let now = Date()
        previewNotes = [
            VoiceNote(
                id: UUID(uuidString: "99A5F6E1-9D7D-4D98-A8EA-610EF6E13B01")!,
                createdAt: now.addingTimeInterval(-1_800),
                updatedAt: now.addingTimeInterval(-1_790),
                audioFilename: "preview-watch.m4a",
                transcript: "The useful distinction is between making a decision reversible and pretending it has no cost.",
                kind: .podcastCapture,
                source: .watch,
                context: VoiceNote.Context(
                    episodeID: "preview-decision",
                    episodeTitle: "How leaders make reversible decisions",
                    podcastTitle: "The Knowledge Project",
                    timestamp: 2_147,
                    transcriptExcerpt: "A reversible decision should be made quickly, but somebody still has to own what happens next."),
                status: .transcribed),
            VoiceNote(
                id: UUID(uuidString: "99A5F6E1-9D7D-4D98-A8EA-610EF6E13B02")!,
                createdAt: now.addingTimeInterval(-86_400),
                updatedAt: now.addingTimeInterval(-86_390),
                audioFilename: "preview-phone.m4a",
                transcript: "Ask the team whether we can apply this to the calendar conflict model.",
                kind: .podcastCapture,
                source: .iPhone,
                context: VoiceNote.Context(
                    episodeID: "preview-calendar",
                    episodeTitle: "Coordination without more meetings",
                    podcastTitle: "Acquired",
                    timestamp: 3_905,
                    transcriptExcerpt: "The system should communicate constraints before it asks people to negotiate them."),
                status: .transcribed),
            VoiceNote(
                id: UUID(uuidString: "99A5F6E1-9D7D-4D98-A8EA-610EF6E13B03")!,
                createdAt: now.addingTimeInterval(-172_800),
                updatedAt: now.addingTimeInterval(-3_600),
                archivedAt: now.addingTimeInterval(-3_600),
                audioFilename: "preview-archived.m4a",
                transcript: "Done: moved the standup to Tuesdays like we discussed.",
                kind: .podcastCapture,
                source: .iPhone,
                status: .transcribed),
        ]
        noteCache.removeAll()
        queryCache.invalidate()
        refreshCounts()
        revision &+= 1
    }
    #endif
}

/// File-per-note iCloud transport. Individual records avoid rewriting one large archive and make a
/// phone capture cheap: one small AAC file, followed by tiny metadata updates after transcription.
private enum VoiceNoteCloudFiles {
    struct Snapshot {
        var notes: [VoiceNote]
        var tombstones: [UUID: Date]
    }

    /// Nil once notes no longer come from iCloud (`LegacyCloud`, off).
    private static var root: URL? {
        #if DEBUG && (targetEnvironment(simulator) || os(macOS) || STRESS_DEVICE_AUDIT)
        guard !ProcessInfo.processInfo.arguments.contains("--stress-days") else { return nil }
        #endif
        guard LegacyCloud.mayRead(.personal), let container = FileManager.default.url(
            forUbiquityContainerIdentifier: CloudBackup.containerID) else { return nil }
        let directory = container
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("VoiceNotes", isDirectory: true)
        if LegacyCloud.mayWrite(.personal) {
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true)
        }
        return directory
    }

    static func write(note: VoiceNote, localAudioURL: URL?, includeAudio: Bool) {
        guard LegacyCloud.mayWrite(.personal), let root else { return }
        let stem = note.id.uuidString.lowercased()
        let audioURL = root.appendingPathComponent(stem).appendingPathExtension("m4a")
        let metadataURL = root.appendingPathComponent(stem).appendingPathExtension("json")
        let tombstoneURL = root.appendingPathComponent(stem).appendingPathExtension("deleted")

        do {
            if includeAudio, let localAudioURL,
               !FileManager.default.fileExists(atPath: audioURL.path),
               let audio = try? Data(contentsOf: localAudioURL) {
                try audio.write(to: audioURL, options: .atomic)
            }
            var portable = note
            portable.reminderID = nil
            let metadata = try JSONEncoder().encode(portable)
            try metadata.write(to: metadataURL, options: .atomic)
            try? FileManager.default.removeItem(at: tombstoneURL)
        } catch {
            PlaybackDiagnostics.shared.log("voice note: iCloud write failed", "\(error)")
        }
    }

    static func delete(id: UUID, at date: Date) {
        guard LegacyCloud.mayWrite(.personal), let root else { return }
        let stem = id.uuidString.lowercased()
        let tombstoneURL = root.appendingPathComponent(stem).appendingPathExtension("deleted")
        let metadataURL = root.appendingPathComponent(stem).appendingPathExtension("json")
        let audioURL = root.appendingPathComponent(stem).appendingPathExtension("m4a")
        do {
            try Data(String(date.timeIntervalSince1970).utf8)
                .write(to: tombstoneURL, options: .atomic)
            try? FileManager.default.removeItem(at: metadataURL)
            try? FileManager.default.removeItem(at: audioURL)
        } catch {
            PlaybackDiagnostics.shared.log("voice note: iCloud delete failed", "\(error)")
        }
    }

    static func readSnapshot(localAudioDirectory: URL, includeAudio: Bool) -> Snapshot? {
        guard let root else { return nil }
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]) else {
            return Snapshot(notes: [], tombstones: [:])
        }

        var tombstones: [UUID: Date] = [:]
        for file in files where file.pathExtension == "deleted" {
            try? FileManager.default.startDownloadingUbiquitousItem(at: file)
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  let data = try? Data(contentsOf: file),
                  let raw = String(data: data, encoding: .utf8),
                  let stamp = TimeInterval(raw) else { continue }
            tombstones[id] = Date(timeIntervalSince1970: stamp)
        }

        var notes: [VoiceNote] = []
        for file in files where file.pathExtension == "json" {
            try? FileManager.default.startDownloadingUbiquitousItem(at: file)
            guard let data = try? Data(contentsOf: file),
                  let note = try? JSONDecoder().decode(VoiceNote.self, from: data) else { continue }
            notes.append(note)

            guard includeAudio, !note.isWritten else { continue }
            let localAudio = localAudioDirectory.appendingPathComponent(note.audioFilename)
            guard !FileManager.default.fileExists(atPath: localAudio.path) else { continue }
            let cloudAudio = root
                .appendingPathComponent(note.id.uuidString.lowercased())
                .appendingPathExtension("m4a")
            try? FileManager.default.startDownloadingUbiquitousItem(at: cloudAudio)
            if let audio = try? Data(contentsOf: cloudAudio) {
                try? audio.write(to: localAudio, options: .atomic)
            }
        }
        return Snapshot(notes: notes, tombstones: tombstones)
    }
}

// The data platform (docs/design/DATA-PLATFORM.md): `VoiceNoteAdapter`. Like the CloudKit paths
// above, these persist only; nothing they do goes back out through the legacy transports.
extension VoiceNoteStore: VoiceNoteSyncSource {
    var syncNotes: [VoiceNote] { notes }

    func syncAudioFile(_ note: VoiceNote) -> URL? {
        guard let url = audioURL(for: note), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func applySyncedNote(_ note: VoiceNote) -> Bool { takeNote(note) }

    func storeSyncedAudio(_ id: UUID, file: URL) {
        guard let note = notes.first(where: { $0.id == id }), let url = audioURL(for: note) else { return }
        try? FileManager.default.createDirectory(at: Self.audioDirectory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.copyItem(at: file, to: url)
    }

    func removeSyncedNotes(_ ids: [UUID]) {
        for id in ids { removeCloudNote(id) }
    }
}
