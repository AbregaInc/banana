import Foundation
import os

/// What each episode's narrator was judged to sound like, remembered so it is decided once.
///
/// Keyed by episode, not by show: a rotating-cast show gives a different answer per episode, which
/// is the entire reason this exists. Readings are a cache — losing the file costs a re-listen at
/// the next download, not anything the listener chose — so a corrupt one is quarantined and the
/// store starts empty rather than refusing to work.
@MainActor
final class NarratorVoiceStore: ObservableObject {
    static let shared = NarratorVoiceStore()

    struct Reading: Codable, Sendable {
        var gender: VoiceGender
        var confidence: Double
        var windowsUsed: Int
        var decidedAt: Date
    }

    @Published private(set) var readings: [String: Reading] = [:]

    /// What each NAMED narrator sounds like, keyed by canonical name.
    ///
    /// The point of the whole feature: decide a narrator once and have it apply to every episode
    /// they read. Without this, a show that credits its narrators — Get Sleepy credits all twenty
    /// of them — could only ever be filtered by muting each name by hand, which is exactly the
    /// chore the gender filter was asked for to avoid.
    @Published private(set) var narratorGenders: [String: Reading] = [:]

    /// Corrections made by hand, which always beat the classifier.
    ///
    /// The model gets roughly one narrator in ten wrong and sounds equally certain when it does.
    /// Without a way to say so, a wrong verdict silently hides everything that narrator reads and
    /// there is no way to find out why. A correction is also permanent: re-listening and
    /// overwriting it would just reproduce the same mistake.
    @Published private(set) var narratorOverrides: [String: VoiceGender] = [:]

    private let log = Logger(subsystem: "com.boris.banana", category: "voice")
    private let url: URL
    private var saveTask: Task<Void, Never>?

    init(directory: URL = AppSupport.directory) {
        self.url = directory.appendingPathComponent("narrator-voices.json")
        // The file used to be a bare `[String: Reading]`. Decoding that as `Stored` fails, and a
        // failure here quarantines the file and starts empty — so without this every verdict this
        // device had already reached would be thrown away and re-listened to. Try the new shape,
        // fall back to the old one, and the next save writes it forward.
        switch SnapshotLoader.load(from: url, as: Stored.self) {
        case .empty:
            readings = [:]
        case .loaded(let stored):
            readings = stored.readings
            narratorGenders = stored.narratorGenders ?? [:]
            narratorOverrides = stored.narratorOverrides ?? [:]
        case .corrupt(let error, let quarantinedTo):
            if let legacy = Self.legacyReadings(at: url) {
                readings = legacy
                log.notice("[voice] migrated \(legacy.count, privacy: .public) episode verdict(s) from the old format")
                break
            }
            readings = [:]
            log.error("""
                [voice] could not decode \(self.url.lastPathComponent, privacy: .public) \
                (\(String(describing: error), privacy: .public)); preserved at \
                \(quarantinedTo?.lastPathComponent ?? "nowhere", privacy: .public)
                """)
        }
    }

    func reading(for episodeID: String) -> Reading? { readings[episodeID] }

    func gender(for episodeID: String) -> VoiceGender? { readings[episodeID]?.gender }

    func reading(forNarrator name: String) -> Reading? { narratorGenders[Self.key(name)] }

    /// What was decided by hand for this narrator, if anything.
    func override(forNarrator name: String) -> VoiceGender? { narratorOverrides[Self.key(name)] }

    /// Correct a narrator by hand, or clear the correction with nil.
    func setOverride(_ gender: VoiceGender?, forNarrator name: String) {
        let key = Self.key(name)
        guard !key.isEmpty else { return }
        if let gender { narratorOverrides[key] = gender } else { narratorOverrides[key] = nil }
        revision &+= 1
        saveSoon()
        if gender == nil { ControlChangeReporter.deleted(.narratorOverride, key) }
        else { ControlChangeReporter.changed(.narratorOverride, key) }
    }

    /// The verdict that should govern one episode: the narrator's when it credits someone, since
    /// that is decided once and applies to their whole catalogue; otherwise this episode's own.
    func voice(episodeID: String, narrator: String?) -> VoiceGender? {
        if let narrator, let byName = gender(forNarrator: narrator) { return byName }
        return gender(for: episodeID)
    }

    /// A hand correction first, then whatever was judged.
    func gender(forNarrator name: String) -> VoiceGender? {
        narratorOverrides[Self.key(name)] ?? narratorGenders[Self.key(name)]?.gender
    }

    /// Record a reading against the episode, and — when the episode credits someone — against that
    /// narrator too.
    ///
    /// The narrator entry is only written once. A later episode by the same narrator is not
    /// re-listened to, and a single odd window on one episode cannot overwrite a verdict that has
    /// already been applied to their whole back catalogue.
    func record(_ reading: Reading, for episodeID: String, narrator: String? = nil) {
        readings[episodeID] = reading
        revision &+= 1
        ControlChangeReporter.changed(.narratorReading, episodeID)
        if let narrator {
            let key = Self.key(narrator)
            if !key.isEmpty, narratorGenders[key] == nil {
                narratorGenders[key] = reading
                ControlChangeReporter.changed(.narratorGender, key)
            }
        }
        saveSoon()
    }

    /// Narrators this device has not yet judged, from a show's roster.
    func narratorsNeedingAVerdict(from roster: Set<String>) -> Set<String> {
        roster.filter { narratorGenders[Self.key($0)] == nil }
    }

    /// The pre-per-narrator file: a bare episode→reading map, possibly already quarantined by the
    /// loader, so both locations are tried.
    private static func legacyReadings(at url: URL) -> [String: Reading]? {
        let candidates = [url] + ((try? FileManager.default.contentsOfDirectory(
            at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("narrator-voices") }
        for candidate in candidates {
            guard let data = try? Data(contentsOf: candidate),
                  let decoded = try? JSONDecoder().decode([String: Reading].self, from: data),
                  !decoded.isEmpty
            else { continue }
            return decoded
        }
        return nil
    }

    /// A frozen copy of `voice(episodeID:narrator:)`, for filtering a whole feed at once — also
    /// off the main thread. Same order: your correction, then the narrator's verdict, then the
    /// episode's own.
    func lookup() -> @Sendable (_ episodeID: String, _ narrator: String?) -> VoiceGender? {
        let episodes = readings.mapValues(\.gender)
        let narrators = narratorGenders.mapValues(\.gender)
        let overrides = narratorOverrides
        return { episodeID, narrator in
            if let narrator {
                let key = Self.key(narrator)
                if let gender = overrides[key] ?? narrators[key] { return gender }
            }
            return episodes[episodeID]
        }
    }

    /// Bumped whenever a verdict or correction changes, so a list that caches what it skips knows
    /// to look again.
    private(set) var revision = 0

    private nonisolated static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Forget an episode's reading, so a re-download listens again rather than trusting a verdict
    /// reached on bytes that are no longer there.
    func forget(episodeID: String) {
        guard readings.removeValue(forKey: episodeID) != nil else { return }
        revision &+= 1
        saveSoon()
    }

    /// On-disk shape. `narratorGenders` is optional so a file written before per-narrator verdicts
    /// existed still loads, costing one re-listen rather than the whole cache.
    private struct Stored: Codable {
        var readings: [String: Reading]
        var narratorGenders: [String: Reading]?
        var narratorOverrides: [String: VoiceGender]?
    }

    private func saveSoon() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            let snapshot = Stored(readings: self.readings,
                                  narratorGenders: self.narratorGenders,
                                  narratorOverrides: self.narratorOverrides)
            do { try JSONEncoder().encode(snapshot).write(to: self.url, options: .atomic) }
            catch { self.log.error("[voice] save failed: \(error.localizedDescription, privacy: .public)") }
        }
    }
}

// Voices are judged once, on whichever device heard the episode, and known everywhere
// (CloudControlsSync) — a new device doesn't re-listen to a whole catalogue, and a correction made
// on the Mac holds on the phone.
extension NarratorVoiceStore: CloudControlSource {
    func cloudItems(_ kind: ControlKind) -> [String: Data] {
        let encoder = JSONEncoder()
        var items: [String: Data] = [:]
        switch kind {
        case .narratorReading: for (id, reading) in readings { items[id] = try? encoder.encode(reading) }
        case .narratorGender: for (id, reading) in narratorGenders { items[id] = try? encoder.encode(reading) }
        case .narratorOverride: for (id, gender) in narratorOverrides { items[id] = try? encoder.encode(gender) }
        default: break
        }
        return items
    }

    func applyCloud(_ kind: ControlKind, id: String, item: Data?) -> Bool {
        let decoder = JSONDecoder()
        switch kind {
        case .narratorReading:
            let reading = item.flatMap { try? decoder.decode(Reading.self, from: $0) }
            if item != nil, reading == nil { return true }
            readings[id] = reading
        case .narratorGender:
            let reading = item.flatMap { try? decoder.decode(Reading.self, from: $0) }
            if item != nil, reading == nil { return true }
            narratorGenders[id] = reading
        case .narratorOverride:
            let gender = item.flatMap { try? decoder.decode(VoiceGender.self, from: $0) }
            if item != nil, gender == nil { return true }
            narratorOverrides[id] = gender
        default:
            return true
        }
        revision &+= 1
        saveSoon()
        return true
    }
}

