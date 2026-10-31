import Foundation

/// A spoken note captured in the moment — the anchor of the notes platform.
///
/// The point that makes this more than a voice memo is `context`: a note taken mid-podcast carries
/// where you were (episode, timestamp) AND what was being said (a slice of the transcript). So when
/// the note is processed later, "remind me to look into that" isn't orphaned — it knows you were
/// 34 minutes into the Data Centers episode, listening to a passage about cooling, when you said it.
///
/// The same shell serves journaling (context = a wind-down prompt) and post-workout feedback
/// (context = the session) — only the context and the entry point change; capture, transcription,
/// storage and the Reminders write are shared.
struct VoiceNote: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    /// Last content change, used to merge the phone's local copy with the iCloud review copy.
    /// Optional so notes captured before cross-device review was added still decode unchanged.
    var updatedAt: Date?
    /// Archived notes stay out of the main list but remain searchable and recoverable.
    /// Optional (nil = active) so pre-archive notes decode unchanged.
    var archivedAt: Date?
    var audioFilename: String            // relative to the notes audio dir
    var transcript: String?              // filled in after on-device transcription
    var kind: Kind = .general
    var source: Source?
    var context: Context?
    var reminderID: String?              // the EKReminder this note was written to
    var status: Status = .pendingTranscription
    /// Correlates capture, Watch transfer, and transcription without exposing note contents.
    var traceparent: String?

    enum Kind: String, Codable, Sendable {
        case podcastCapture              // interrupted a podcast to say something
        case journal                     // wind-down journaling
        case workoutFeedback             // how did that session feel
        case general
    }

    enum Source: String, Codable, Sendable {
        case iPhone
        case watch

        var title: String {
            switch self {
            case .iPhone: "iPhone"
            case .watch: "Apple Watch"
            }
        }
    }

    enum Status: String, Codable, Sendable {
        case pendingTranscription
        case transcribed
        case failed
    }

    /// What the note is *about* — the thing that gives a later reader the "why".
    struct Context: Codable, Hashable, Sendable {
        var episodeID: String?
        var episodeTitle: String?
        var podcastTitle: String?
        var timestamp: TimeInterval?     // playback position when the note was taken
        var transcriptExcerpt: String?   // ~what you'd just heard

        /// A one-line human anchor for the Reminders body.
        var anchorLine: String? {
            guard let episodeTitle else { return nil }
            let at = timestamp.map { " @ \(Self.clock($0))" } ?? ""
            let show = podcastTitle.map { "\($0) — " } ?? ""
            return "🎧 \(show)\(episodeTitle)\(at)"
        }

        static func clock(_ s: TimeInterval) -> String {
            let h = Int(s) / 3600, m = (Int(s) % 3600) / 60, sec = Int(s) % 60
            return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
        }
    }

    var displayTitle: String {
        if let t = transcript, !t.isEmpty { return t }
        switch status {
        case .pendingTranscription: return "Transcribing…"
        case .failed:               return "Voice note (couldn't transcribe)"
        case .transcribed:          return "Voice note"
        }
    }

    var syncDate: Date { updatedAt ?? createdAt }

    /// The sync protocol carries dates as rounded integer milliseconds. Comparing the local
    /// sub-millisecond timestamp to its own wire echo must not start a kept-own/upload loop.
    func isNewerForSync(than other: VoiceNote) -> Bool {
        (syncDate.timeIntervalSince1970 * 1000).rounded()
            > (other.syncDate.timeIntervalSince1970 * 1000).rounded()
    }

    /// A note typed rather than spoken: no recording, and the text is the note.
    var isWritten: Bool { audioFilename.isEmpty }
}

extension VoiceNote {
    private enum CodingKeys: String, CodingKey {
        case id, createdAt, updatedAt, archivedAt, audioFilename, transcript, kind, source, context,
             reminderID, status, traceparent
    }

    /// Tolerant decoder (in an extension so the memberwise init is preserved, same as
    /// `Episode`/`Podcast` in `Podcast.swift`): hand-written so a future field can't throw
    /// `keyNotFound` — Swift's synthesized `Decodable` does that for an absent key even when the
    /// property declares a default (`kind`, `status`) — and take the whole `notes.json` snapshot
    /// down with it on the next save (see `VoiceNoteStore.load`/`save`). `audioFilename` alone
    /// stays required: a note with no audio reference is orphaned, nothing to play or transcribe,
    /// the same "the record's whole point" reasoning `MealItem.name`/`WorkoutPlan.exercises` use
    /// in `WellnessModels.swift`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
        audioFilename = try c.decode(String.self, forKey: .audioFilename)
        transcript = try c.decodeIfPresent(String.self, forKey: .transcript)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .general
        source = try c.decodeIfPresent(Source.self, forKey: .source)
        context = try c.decodeIfPresent(Context.self, forKey: .context)
        reminderID = try c.decodeIfPresent(String.self, forKey: .reminderID)
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .pendingTranscription
        traceparent = try c.decodeIfPresent(String.self, forKey: .traceparent)
    }
}


/// A stable, actionable EventKit marker. Main and Beta have separate URL schemes.
enum NoteReminderLink {
    static func scheme(beta: Bool) -> String { beta ? "banananotebeta" : "banananote" }
    static func url(_ id: UUID, beta: Bool) -> URL {
        URL(string: "\(scheme(beta: beta))://note/\(id.uuidString)")!
    }
    static func noteID(_ url: URL, beta: Bool) -> UUID? {
        guard url.scheme == scheme(beta: beta), url.host == "note", url.query == nil,
              url.fragment == nil, url.pathComponents.count == 2 else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }
}
