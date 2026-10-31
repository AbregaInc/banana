import Foundation
import os

/// L2 — per-occurrence exceptions to the recurring cue pattern. Lets you change a single
/// day without touching the series: **skip** one, **move** one, or **add** an extra —
/// exactly the "move Thursday's gym this week / skip Saturday / add a Wednesday workout"
/// scenario. Keyed by the occurrence's stable `seriesID|slotID|day` key so an override
/// survives edits to the base cue.
@MainActor
final class ExceptionStore: ObservableObject {
    static let shared = ExceptionStore()

    typealias Kind = RoutineOccurrenceOverride

    /// A one-off added occurrence of a cue (iCal RDATE) — "add an extra gym Wednesday".
    struct Extra: Codable, Identifiable, Hashable, Sendable {
        var id: String = UUID().uuidString
        var seriesID: String      // routine id (uuid string)
        var start: Date

        private enum CodingKeys: String, CodingKey { case id, seriesID, start }

        init(id: String = UUID().uuidString, seriesID: String, start: Date) {
            self.id = id
            self.seriesID = seriesID
            self.start = start
        }

        /// Hand-written so a future field can't throw `keyNotFound` and take the whole
        /// `timeline-exceptions.json` snapshot down with it (see `ExceptionStore.load`/`save`).
        /// `seriesID`/`start` stay required: an extra with no cue to add or no date to add it on
        /// is orphaned, nothing to show it against — the same "the record's whole point"
        /// reasoning `WorkoutCompletion.planID`/`startedAt`/`endedAt` use in `WellnessModels.swift`.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
            seriesID = try c.decode(String.self, forKey: .seriesID)
            start = try c.decode(Date.self, forKey: .start)
        }
    }

    private static let log = Logger(subsystem: "com.boris.banana", category: "exceptions")
    /// Set when `timeline-exceptions.json` failed to decode AND could not even be quarantined
    /// (copied aside for safekeeping) — see `load()`. In that situation there is no backup
    /// anywhere, so `save()` refuses to run rather than risk being the thing that actually
    /// destroys the owner's skip/reschedule/extra overrides. Stays true for the rest of this
    /// launch; a relaunch (after the underlying problem is resolved by hand) gets a fresh attempt.
    private var saveIsUnsafe = false

    @Published private(set) var overrides: [String: Kind] = [:]   // occurrenceKey → override
    @Published private(set) var extras: [Extra] = []

    init() { load(); prune() }

    // MARK: - Mutations

    // Each change is the same on every device (CloudControlsSync): skipping Saturday's run on the
    // Mac skips it on the phone, which then doesn't wake you for it.
    func skip(_ key: String) {
        overrides[key] = .skip; save()
        ControlChangeReporter.changed(.timelineOverride, key)
    }
    func reschedule(_ key: String, to newStart: Date) {
        overrides[key] = .reschedule(newStart); save()
        ControlChangeReporter.changed(.timelineOverride, key)
    }
    /// A Watch start completes today's workout cues, without changing their series or tomorrow.
    /// Duplicate immediate/queued deliveries preserve the first completion and any booked time.
    func completeWorkoutRoutines(startedAt: Date, routines: [Routine]) {
        for (key, completion) in WorkoutRoutineCompletion.updates(startedAt: startedAt, day: Occurrence.dayKey(startedAt), routineIDs: routines.filter { $0.enabled && $0.triggerKind == .workoutStart }.map(\.id), overrides: overrides) {
            setOverride(key, completion)
        }
    }

    func clearOverride(_ key: String) {
        overrides[key] = nil; save()
        ControlChangeReporter.deleted(.timelineOverride, key)
    }
    /// Puts back what an occurrence had before (Undo): its skip, its move, or nothing.
    func setOverride(_ key: String, _ kind: Kind?) {
        guard let kind else { return clearOverride(key) }
        overrides[key] = kind; save()
        ControlChangeReporter.changed(.timelineOverride, key)
    }
    func addExtra(seriesID: String, start: Date) {
        let extra = Extra(seriesID: seriesID, start: start)
        extras.append(extra); save()
        ControlChangeReporter.changed(.timelineExtra, extra.id)
    }
    /// - Returns: what was taken out and where from, for `restoreExtra` (Undo).
    @discardableResult
    func removeExtra(_ id: String) -> Removed<Extra>? {
        let removed = extras.take { $0.id == id }; save()
        ControlChangeReporter.deleted(.timelineExtra, id)
        return removed
    }
    /// Brings back a removed extra (Undo).
    func restoreExtra(_ removed: Removed<Extra>) {
        extras.putBack(removed); save()
        ControlChangeReporter.changed(.timelineExtra, removed.item.id)
    }

    /// A change from another device reached the timeline; it needs recomputing.
    var onCloudChange: (() -> Void)?

    func override(for key: String?) -> Kind? { key.flatMap { overrides[$0] } }

    // MARK: - Resolution (applied during OccurrenceStore.recompute)

    /// Apply skip/reschedule overrides to a set of authored occurrences.
    func apply(to occurrences: [Occurrence]) -> [Occurrence] {
        occurrences.compactMap { occ in
            guard let key = occ.occurrenceKey, let ov = overrides[key] else { return occ }
            switch ov {
            case .skip:
                var s = occ; s.skipped = true; return s   // keep it (dimmed + restorable), don't write/arm
            case .completed(let at, let scheduledStart):
                var done = occ
                done.overrideDayKey = occ.overrideDayKey ?? Occurrence.dayKey(occ.start)
                done.completed = true
                done.completedAt = at
                if let scheduledStart { done.start = scheduledStart; done.hasScheduledTime = true }
                return done
            case .reschedule(let newStart):
                var moved = occ
                moved.overrideDayKey = occ.overrideDayKey ?? Occurrence.dayKey(occ.start)
                moved.start = newStart
                moved.hasScheduledTime = true
                return moved
            }
        }
    }

    /// Build occurrences for the added one-offs, looking up their cue for title/icon/tint.
    func extraOccurrences(routines: [Routine]) -> [Occurrence] {
        extras.compactMap { extra in
            guard let r = routines.first(where: { $0.id.uuidString == extra.seriesID }) else { return nil }
            return Occurrence(
                id: "extra:\(extra.id)",
                seriesID: extra.seriesID, slotID: "extra:\(extra.id)",
                source: .authored, behavior: .cue,
                schedule: OccurrenceSchedule(mode: .fixed, moveable: false),
                writePolicy: .busy,
                title: r.name, icon: r.icon, tint: r.color,
                start: extra.start, end: nil, hasScheduledTime: true,
                routineID: r.id)
        }
    }

    // MARK: - Housekeeping

    /// Keep completion history; only expired scheduling exceptions are disposable.
    func prune(before day: Date = Calendar.current.startOfDay(for: Date())) {
        let cutoff = Occurrence.dayKey(day)
        overrides = overrides.filter { key, value in
            if case .completed = value { return true }
            return (key.split(separator: "|").last.map(String.init) ?? "") >= cutoff
        }
        extras.removeAll { extra in
            guard extra.start < day else { return false }
            let key = "\(extra.seriesID)|extra:\(extra.id)|\(Occurrence.dayKey(extra.start))"
            if case .completed? = overrides[key] { return false }
            return true
        }
    }

    // MARK: - Persistence

    /// The full on-disk shape of `timeline-exceptions.json`.
    /// `fileprivate`, not `private`: the `Codable` conformance lives in a top-level extension at
    /// the bottom of this file so the lossy element-wise decoding can be read on its own, and a
    /// `private` nested type is not nameable as `ExceptionStore.Persisted` from there.
    fileprivate struct Persisted: Sendable {
        var overrides: [String: Kind] = [:]
        var extras: [Extra] = []
        /// How many individual overrides/extras failed to decode and were dropped — diagnostic
        /// only, deliberately excluded from `CodingKeys` below so it is never written to disk.
        var droppedCount = 0
    }

    private var url: URL {
        let d = AppSupport.directory
        return d.appendingPathComponent("timeline-exceptions.json")
    }
    /// Re-read from disk (an iCloud restore rewrites the file underneath us).
    func reloadFromDisk() { load() }

    private func save() {
        // See `load()`/`saveIsUnsafe`: only set when timeline-exceptions.json failed to decode
        // AND couldn't be quarantined, i.e. there is no backup of the original anywhere. Writing
        // here would risk being the actual data-loss event rather than just reflecting one.
        guard !saveIsUnsafe else {
            Self.log.fault("save() refused: no backup of a previously-corrupt timeline-exceptions.json exists yet, so writing now would risk destroying the only copy. Resolve by hand and relaunch.")
            return
        }
        if let data = try? JSONEncoder().encode(Persisted(overrides: overrides, extras: extras)) {
            try? data.write(to: url, options: .atomic)
        }
        CloudBackup.shared.schedule()
    }

    /// `try? JSONDecoder().decode(Persisted.self, ...) else { return }` used to treat ANY decode
    /// failure — one corrupt override/extra, or a future field added without a migration — as
    /// "nothing here," leaving `overrides`/`extras` empty. The next `save()` (any skip,
    /// reschedule, or extra the person adds) would then permanently overwrite
    /// `timeline-exceptions.json` with that emptiness — silently reviving every previously
    /// skipped/moved occurrence and dropping every added extra. `SnapshotLoader`/
    /// `LossyDictionary`/`LossyArray` (shared with the rest of this sweep — see
    /// `Shared/SnapshotPersistence.swift`) fix that: one bad entry costs one entry, and a wholly
    /// unparseable file is quarantined before anything can overwrite it.
    private func load() {
        switch SnapshotLoader.load(from: url, as: Persisted.self) {
        case .empty:
            return
        case let .loaded(p):
            if p.droppedCount > 0 {
                Self.log.error("timeline-exceptions.json: dropped \(p.droppedCount, privacy: .public) corrupt entry/entries on load; everything else loaded normally")
            }
            overrides = p.overrides
            extras = p.extras
        case let .corrupt(error, quarantinedTo):
            if let quarantinedTo {
                Self.log.error("timeline-exceptions.json failed to decode (\(String(describing: error), privacy: .public)); original preserved at \(quarantinedTo.lastPathComponent, privacy: .public). Starting empty — recoverable from the quarantine copy.")
            } else {
                saveIsUnsafe = true
                Self.log.fault("timeline-exceptions.json failed to decode (\(String(describing: error), privacy: .public)) AND could not be quarantined — no backup exists. Refusing to save until this is resolved by hand; the original is still at timeline-exceptions.json, untouched.")
            }
        }
    }
}

extension ExceptionStore.Persisted: Codable {
    private enum CodingKeys: String, CodingKey { case overrides, extras }

    /// Decodes `overrides`/`extras` element-by-element via `LossyDictionary`/`LossyArray` — one
    /// unparseable override or extra is dropped (and tallied into `droppedCount`) rather than
    /// sinking the entire snapshot the way synthesized `Decodable` on `[String: Kind]`/`[Extra]`
    /// would (one throwing element fails the whole collection).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let overridesLossy = try c.decodeIfPresent(LossyDictionary<ExceptionStore.Kind>.self, forKey: .overrides)
        let extrasLossy = try c.decodeIfPresent(LossyArray<ExceptionStore.Extra>.self, forKey: .extras)
        overrides = overridesLossy?.elements ?? [:]
        extras = extrasLossy?.elements ?? []
        droppedCount = (overridesLossy?.droppedCount ?? 0) + (extrasLossy?.droppedCount ?? 0)
    }

    /// Written explicitly (rather than relying on synthesis alongside the hand-written
    /// `init(from:)` above) so there is no ambiguity about `droppedCount` — a derived,
    /// in-memory-only signal — ever being written to disk.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(overrides, forKey: .overrides)
        try c.encode(extras, forKey: .extras)
    }
}

extension ExceptionStore: CloudControlSource {
    func cloudItems(_ kind: ControlKind) -> [String: Data] {
        let encoder = JSONEncoder()
        var items: [String: Data] = [:]
        switch kind {
        case .timelineOverride:
            for (key, override) in overrides { items[key] = try? encoder.encode(override) }
        case .timelineExtra:
            for extra in extras { items[extra.id] = try? encoder.encode(extra) }
        default:
            break
        }
        return items
    }

    func applyCloud(_ kind: ControlKind, id: String, item: Data?) -> Bool {
        switch kind {
        case .timelineOverride:
            let override = item.flatMap { try? JSONDecoder().decode(Kind.self, from: $0) }
            if item != nil, override == nil { return true }
            guard overrides[id] != override else { return true }
            overrides[id] = override
        case .timelineExtra:
            let extra = item.flatMap { try? JSONDecoder().decode(Extra.self, from: $0) }
            if item != nil, extra == nil { return true }
            extras.removeAll { $0.id == id }
            if let extra { extras.append(extra) }
        default:
            return true
        }
        save()
        onCloudChange?()
        return true
    }
}

