import Foundation
import Darwin

// MARK: - Generic snapshot persistence (decode-and-quarantine)
//
// The shared building block behind every "on-disk JSON snapshot" store in the app —
// `WellnessStore`, `ListenHistoryStore`, `PodcastLibrary`, `VoiceNoteStore`, `RoutineStore`,
// `CalendarWriteBack`, `ExceptionStore`. First built for the nutrition store (`WellnessStore`),
// then swept across the rest once the same bug turned up everywhere else:
//
//   guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return nil }
//
// treats ANY decode failure — one corrupt record buried in thousands of good ones, or simply a
// newly added field with a default value (Swift's synthesized `Decodable` throws `keyNotFound`
// for an absent key even when the property declares a default) — as "nothing here." The store
// then starts empty, and its very next `save()` writes that emptiness permanently over the real
// file. Fixed at the root here: individual records decode independently
// (`LossyArray`/`LossyDictionary`) so one bad one doesn't sink the whole file, and a file that
// fails to parse AT ALL is copied aside (`SnapshotLoader.quarantine`) before anything downstream
// gets the chance to overwrite it.
//
// Kept free of any one store's dependency chain (CloudBackup, CloudKit, EventKit, …) — Foundation
// only — so it, and every store's own `Snapshot` type built on it, stay testable against
// throwaway temp files without dragging in a singleton that touches the real data directory.

/// Decodes `Value`, swallowing (never rethrowing) any error from its own `init(from:)`. The
/// building block `LossyArray`/`LossyDictionary` use to drop one corrupt element without
/// depending on how a particular `Decoder` implementation positions its container after a throw.
struct FailableDecodable<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

/// Decodes an array of `Element`, dropping (and counting) any entry that fails to decode instead
/// of letting one corrupt or unrecognizable record fail the whole array. "One bad record costs
/// one record" instead of "one bad record costs the whole snapshot."
struct LossyArray<Element: Decodable & Sendable>: Decodable, Sendable {
    var elements: [Element]
    /// How many entries in the source array could not be decoded and were dropped.
    var droppedCount: Int

    init(from decoder: Decoder) throws {
        let wrapped = try [FailableDecodable<Element>](from: decoder)
        elements = wrapped.compactMap(\.value)
        droppedCount = wrapped.count - elements.count
    }
}

/// The dictionary equivalent of `LossyArray`, for snapshots keyed rather than listed — e.g.
/// `WellnessStore.foodCorrections` (by normalized food name) or `ExceptionStore.overrides` (by
/// occurrence key).
struct LossyDictionary<Value: Decodable & Sendable>: Decodable, Sendable {
    var elements: [String: Value]
    /// How many values in the source dictionary could not be decoded and were dropped.
    var droppedCount: Int

    init(from decoder: Decoder) throws {
        let wrapped = try [String: FailableDecodable<Value>](from: decoder)
        elements = wrapped.compactMapValues(\.value)
        droppedCount = wrapped.count - elements.count
    }
}

/// Outcome of attempting to load a JSON snapshot file at a known URL. Each store turns this into
/// a `Logger` call and a decision about whether it's still safe to save; kept as a plain generic
/// enum (rather than folding the logging/store-state side effects in here) so tests can assert on
/// it directly, independent of any one store's dependency chain.
enum SnapshotLoadResult<Snapshot: Sendable>: Sendable {
    /// Nothing at the URL (or it couldn't even be read as bytes) — a brand-new install, most
    /// commonly. Not an error: there is nothing to quarantine or warn about.
    case empty
    /// Decoded successfully. For a `Snapshot` that tracks its own dropped-record count (via
    /// `LossyArray`/`LossyDictionary`, or a hand-rolled equivalent like `WellnessSnapshot`), that
    /// count is normally 0 here — nonzero only when some individual records inside an otherwise-
    /// valid file failed to decode and were skipped.
    case loaded(Snapshot)
    /// The file exists but isn't valid `Snapshot` JSON at all — as opposed to one bad record
    /// inside an otherwise-good file, which is `.loaded` with a nonzero dropped-record count.
    /// `quarantinedTo` is where the original bytes were copied for recovery, or nil if even that
    /// copy failed, in which case the original is untouched at its original path (and the caller
    /// must not treat this as safely backed up).
    case corrupt(error: Error, quarantinedTo: URL?)
}

/// Reads and decodes a JSON snapshot file without ever risking the original: never mutates or
/// deletes anything at `url`, and on a whole-file decode failure copies the original bytes aside
/// to a timestamped neighbour before returning — so by the time anything downstream might save an
/// empty-until-repopulated snapshot back over `url`, the original is already safe under a name
/// nothing will ever save over again.
enum SnapshotLoader {
    static func load<Snapshot: Decodable & Sendable>(
        from url: URL, as type: Snapshot.Type = Snapshot.self, now: Date = Date()
    ) -> SnapshotLoadResult<Snapshot> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        guard let data = try? Data(contentsOf: url) else {
            return .corrupt(error: CocoaError(.fileReadUnknown), quarantinedTo: quarantine(fileAt: url, now: now))
        }
        do {
            return .loaded(try JSONDecoder().decode(Snapshot.self, from: data))
        } catch {
            return .corrupt(error: error, quarantinedTo: quarantine(fileAt: url, now: now))
        }
    }

    /// Copy, not move: `url` must still exist afterward so ordinary saves keep writing to the
    /// same path they always have — the copy is the safety net, not a replacement for the
    /// original. Returns the quarantine location, or nil if the copy itself failed (e.g. a full
    /// disk), in which case the original is still sitting at `url`, unmodified and un-backed-up.
    @discardableResult
    static func quarantine(fileAt url: URL, now: Date = Date()) -> URL? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        // Colons in the formatted timestamp aren't safe across every filesystem/tool — sanitize.
        let stamp = formatter.string(from: now).replacingOccurrences(of: ":", with: "-")
        let base = url.deletingPathExtension().lastPathComponent
        let quarantineURL = url.deletingLastPathComponent().appendingPathComponent("\(base).corrupt-\(stamp).json")
        guard (try? FileManager.default.copyItem(at: url, to: quarantineURL)) != nil else { return nil }
        return quarantineURL
    }
}


/// Local health snapshots must stay out of system/iCloud device backups. Apply the
/// resource value to the replacement inode BEFORE publishing it; Data.write(.atomic)
/// can otherwise replace an excluded file with a new, backed-up inode.
enum HealthFileProtection {
    static func exclude(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    static func protectExisting(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? exclude(url)
    }

    /// Some health requests and legacy copies live in UserDefaults. Exclude the containing
    /// preference directory so CFPreferences' own atomic replacements stay excluded too.
    /// Never mark the Mac user's shared Library/Preferences directory.
    static func protectApplicationPreferences() {
        #if os(macOS)
        guard ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil else { return }
        #endif
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return }
        do { try protectPreferences(in: library) }
        catch { NSLog("Banana: device-backup exclusion for application preferences failed: %@", error.localizedDescription) }
    }

    static func protectPreferences(in library: URL) throws {
        let preferences = library.appendingPathComponent("Preferences", isDirectory: true)
        try FileManager.default.createDirectory(at: preferences, withIntermediateDirectories: true)
        try exclude(preferences)
    }

    static func stagingDirectory(beside url: URL) throws -> URL {
        let parent = url.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CocoaError(.fileNoSuchFile)
        }
        let directory = parent.appendingPathComponent("HealthStaging", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try exclude(directory) // Before any health bytes land in it.
        return directory
    }

    static func write(_ data: Data, to url: URL) throws {
        let staged = try stagingDirectory(beside: url).appendingPathComponent(UUID().uuidString + ".tmp")
        defer { try? FileManager.default.removeItem(at: staged) }
        try data.write(to: staged, options: .atomic)
        try exclude(staged)
        try replace(staged, destination: url)
    }

    static func replace(_ staged: URL, destination: URL) throws {
        try exclude(staged)
        let result = staged.path.withCString { source in
            destination.path.withCString { target in Darwin.rename(source, target) }
        }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    /// Fixed paths only, plus their quarantine copies. No recursive history scan at startup.
    static func protectLegacyFiles(in directory: URL) {
        let names: Set<String> = ["health.json", "wellness.json", "night-motion.json",
            "meal-inbox.json", "my-foods.json", "meal-photo-found.json", "meal-photo-scan.json",
            "meal-estimate-in-flight", "Fitness", "MealPhotos", "MealPhotoPrints", "cloud-health", "SpaceSync", "HealthStaging"]
        for name in names { protectExisting(directory.appendingPathComponent(name)) }
        let bases = names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) + ".corrupt-" }
        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            if bases.contains(where: { file.lastPathComponent.hasPrefix($0) }) { protectExisting(file) }
        }
    }
}
