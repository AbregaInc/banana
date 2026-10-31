import SwiftUI
import Foundation

/// A reference to an Apple Music item used as wake content. We persist just
/// enough (kind + id + labels) to re-queue it via MusicKit at wake time.
struct MusicWakeItem: Codable, Equatable, Hashable, Identifiable {
    enum Kind: String, Codable { case playlist, album, song }
    var kind: Kind
    var id: String        // MusicItemID raw value
    var title: String
    var subtitle: String?

    var systemImage: String {
        switch kind {
        case .playlist: return "music.note.list"
        case .album: return "square.stack"
        case .song: return "music.note"
        }
    }
}

extension MusicWakeItem {
    /// Tolerant decoder (see FitnessModels for the pattern) so a future field
    /// doesn't invalidate a saved wake selection.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Unknown"
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
    }
}

/// A podcast or Apple Music item that fills a source slot.
enum WakeSource: Codable, Equatable {
    case podcast(UUID)
    case appleMusic(MusicWakeItem)
}

/// The part of the day a source is for.
enum SourceSlot: String, Codable, CaseIterable, Identifiable {
    case sleep, wake, workout
    var id: String { rawValue }

    var label: String {
        switch self { case .sleep: return "Sleep"; case .wake: return "Wake"; case .workout: return "Workout" }
    }
    var icon: String {
        switch self { case .sleep: return "moon.zzz.fill"; case .wake: return "alarm.fill"; case .workout: return "figure.run" }
    }
    var blurb: String {
        switch self {
        case .sleep:   return "Plays when you tap Play to sleep (with a fade-out timer)."
        case .wake:    return "Plays after an alarm rings and you open the app."
        case .workout: return "Plays when you start a workout."
        }
    }
}

/// Source of truth for the per-slot audio sources (each a subscribed podcast OR
/// an Apple Music item). Persisted in UserDefaults.
@MainActor
final class WakeStore: ObservableObject {
    @Published private(set) var sources: [SourceSlot: WakeSource] = [:]

    /// Fired after any slot changes (used to re-sync the Workout source to the Watch).
    var onChange: (() -> Void)?

    private let defaults = UserDefaults.standard
    private let key = "audioSources"
    private let legacyKey = "wakeSource"

    init() {
        load()
        LaunchClock.mark("wake.init")
    }

    /// The wake slot (kept for existing call sites).
    var source: WakeSource? { sources[.wake] }

    func source(for slot: SourceSlot) -> WakeSource? { sources[slot] }

    func setPodcast(_ id: UUID, for slot: SourceSlot = .wake) { set(.podcast(id), for: slot) }
    func setAppleMusic(_ item: MusicWakeItem, for slot: SourceSlot = .wake) { set(.appleMusic(item), for: slot) }
    func clear(_ slot: SourceSlot = .wake) { set(nil, for: slot) }

    func isPodcast(_ id: UUID, for slot: SourceSlot) -> Bool {
        if case .podcast(let pid) = sources[slot] { return pid == id }
        return false
    }
    func isWakePodcast(_ id: UUID) -> Bool { isPodcast(id, for: .wake) }

    func appleMusicItem(for slot: SourceSlot = .wake) -> MusicWakeItem? {
        if case .appleMusic(let item) = sources[slot] { return item }
        return nil
    }

    /// Drop any slot that points at a podcast that was removed.
    func clearIfPodcast(_ id: UUID) {
        for slot in SourceSlot.allCases where isPodcast(id, for: slot) { clear(slot) }
    }

    /// Human-readable summary for a slot, resolving podcast titles.
    func summary(for slot: SourceSlot, using library: PodcastLibrary) -> (title: String, subtitle: String, systemImage: String)? {
        switch sources[slot] {
        case .podcast(let id):
            guard let p = library.podcast(id) else { return nil }
            return (p.title, "Podcast · next episode", "waveform")
        case .appleMusic(let item):
            return (item.title, "Apple Music · \(item.kind.rawValue)", item.systemImage)
        case nil:
            return nil
        }
    }
    func summary(using library: PodcastLibrary) -> (title: String, subtitle: String, systemImage: String)? {
        summary(for: .wake, using: library)
    }

    private func set(_ newValue: WakeSource?, for slot: SourceSlot) {
        guard sources[slot] != newValue else { return }
        sources[slot] = newValue
        persist()
        onChange?()
        if newValue == nil {
            ControlChangeReporter.deleted(.wake, slot.rawValue)
        } else {
            ControlChangeReporter.changed(.wake, slot.rawValue)
        }
    }

    private func persist() {
        let raw = Dictionary(uniqueKeysWithValues: sources.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(raw) { defaults.set(data, forKey: key) }
        // Wake-source selection lives in UserDefaults, which the iCloud snapshot digests —
        // dirty the backup flag so the next on-background pass carries it.
        CloudBackup.shared.schedule()
    }

    private func load() {
        if let data = defaults.data(forKey: key),
           let raw = try? JSONDecoder().decode([String: WakeSource].self, from: data) {
            sources = Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in SourceSlot(rawValue: k).map { ($0, v) } })
            return
        }
        // Migrate the old single wake source into the wake slot.
        if let data = defaults.data(forKey: legacyKey),
           let decoded = try? JSONDecoder().decode(WakeSource.self, from: data) {
            sources[.wake] = decoded
            persist()
            defaults.removeObject(forKey: legacyKey)   // migrated — don't read it again
        }
    }
}

// What each slot plays is the same on every device (CloudControlsSync), one record per slot.
extension WakeStore: CloudControlSource {
    func cloudItems(_ kind: ControlKind) -> [String: Data] {
        let encoder = JSONEncoder()
        var items: [String: Data] = [:]
        for (slot, source) in sources { items[slot.rawValue] = try? encoder.encode(source) }
        return items
    }

    func applyCloud(_ kind: ControlKind, id: String, item: Data?) -> Bool {
        guard let slot = SourceSlot(rawValue: id) else { return true }
        guard let item else {
            set(nil, for: slot)
            return true
        }
        guard let source = try? JSONDecoder().decode(WakeSource.self, from: item) else { return true }
        set(source, for: slot)
        return true
    }
}
