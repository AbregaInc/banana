import Foundation
import SwiftUI
import os

/// The user's routines, persisted on-device, plus the derivation of today's timeline.
@MainActor
final class RoutineStore: ObservableObject {
    static let shared = RoutineStore()

    private static let log = Logger(subsystem: "com.boris.banana", category: "routines")
    /// Set when `routines.json` failed to decode AND could not even be quarantined (copied aside
    /// for safekeeping) — see `load()`. In that situation there is no backup anywhere, so
    /// `save()` refuses to run rather than risk being the thing that actually destroys the
    /// owner's customized cues. Stays true for the rest of this launch; a relaunch (after the
    /// underlying problem — e.g. a full disk — is resolved by hand) gets a fresh attempt.
    private var saveIsUnsafe = false

    @Published private(set) var routines: [Routine] = []

    /// The wake cue, if enabled — the source of truth for wake. Bound by `cueType` (the
    /// stable identity), not the trigger kind, so it survives editing.
    var wakeCue: Routine? { routines.first { $0.cueType == .wake && $0.enabled } }

    /// The workout cue — the source of truth for the Watch's workout audio.
    var workoutCue: Routine? { routines.first { $0.cueType == .workout && $0.enabled } }

    /// Built-in cue types the user is currently missing (deleted) — offered as re-addable
    /// templates. `.custom` is never "missing".
    var missingBuiltInTypes: [CueType] {
        CueType.allCases.filter { type in
            type.isBuiltIn && !routines.contains { $0.cueType == type }
        }
    }

    /// Fired after any change is persisted (e.g. to push the Workout cue to the Watch).
    var onChange: (() -> Void)?

    private let fileURL: URL = {
        let dir = AppSupport.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("routines.json")
    }()

    private static let seedVersion = 2   // bump to replace the seeded scaffold on existing installs
    private static let seedVersionKey = "routinesSeedVersion"

    init() {
        load()
        let stored = UserDefaults.standard.integer(forKey: Self.seedVersionKey)
        if routines.isEmpty || stored < Self.seedVersion {
            routines = Self.seed()
            UserDefaults.standard.set(Self.seedVersion, forKey: Self.seedVersionKey)
            save()
        }
    }

    func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard let i = routines.firstIndex(where: { $0.id == id }) else { return }
        routines[i].enabled = enabled
        save()
        ControlChangeReporter.changed(.routine, id.uuidString)
    }

    func upsert(_ routine: Routine) {
        if let i = routines.firstIndex(where: { $0.id == routine.id }) {
            guard routines[i] != routine else { return }
            routines[i] = routine
        } else {
            routines.append(routine)
        }
        save()
        ControlChangeReporter.changed(.routine, routine.id.uuidString)
    }

    /// - Returns: what was taken out and where from, for `restore` (Undo).
    @discardableResult
    func delete(_ id: UUID) -> Removed<Routine>? {
        guard let removed = routines.take(where: { $0.id == id }) else { return nil }
        save()
        ControlChangeReporter.deleted(.routine, id.uuidString)
        return removed
    }

    /// Brings back a deleted routine where it was (Undo). A newer edit than the delete, so it
    /// comes back on every device too.
    func restore(_ removed: Removed<Routine>) {
        routines.putBack(removed)
        save()
        ControlChangeReporter.changed(.routine, removed.item.id.uuidString)
    }

    func newRoutine() -> Routine {
        Routine(name: "New cue", icon: "circle.fill", color: .blue, triggerKind: .time,
                hour: 12, minute: 0, autonomy: .nudge, sourceLabel: "Not set", group: .day)
    }

    var manualRoutines: [Routine] { routines.filter { $0.enabled && $0.triggerKind == .manual } }

    func grouped() -> [(group: RoutineGroup, items: [Routine])] {
        RoutineGroup.allCases.compactMap { g in
            let items = routines.filter { $0.group == g }.sorted { $0.nominalMinutes < $1.nominalMinutes }
            return items.isEmpty ? nil : (g, items)
        }
    }

    /// Resolve today's moments. `wakeTime` comes from the smart schedule for the
    /// earliest-meeting (wake) routine.
    func moments(now: Date, wakeTime: Date?, activePodcastID: UUID? = nil) -> [DayMoment] {
        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: now)

        var resolved: [(Routine, Date?)] = []
        for r in routines where r.enabled {
            if r.triggerKind == .time || r.triggerKind == .wakeUp, !r.weekdays.isEmpty, !r.weekdays.contains(weekday) { continue }
            let time: Date?
            switch r.triggerKind {
            case .time:
                time = cal.date(bySettingHour: r.hour, minute: r.minute, second: 0, of: now)
            case .earliestMeeting:
                time = wakeTime ?? cal.date(bySettingHour: r.hour, minute: r.minute, second: 0, of: now)
            case .wakeUp:
                let wake = routines.first { $0.enabled && $0.cueType == .wake && $0.id != r.id }
                time = WakeFollowing.start(on: now, plannedWake: wakeTime, wakeRoutine: wake.map { ($0.hour, $0.minute) },
                                           own: (r.hour, r.minute), minutesAfter: r.leadMinutes, calendar: cal)
            case .workoutStart, .manual, .calendarMatch:
                time = nil
            }
            resolved.append((r, time))
        }

        func order(_ pair: (Routine, Date?)) -> Int {
            if let t = pair.1 { return cal.component(.hour, from: t) * 60 + cal.component(.minute, from: t) }
            return pair.0.nominalMinutes
        }
        resolved.sort { order($0) < order($1) }

        return resolved.map { r, t in
            let status: DayMoment.Status
            if let activePodcastID, r.podcastIDs.contains(activePodcastID) {
                status = .active                    // "Now" = the cue whose source is playing
            } else if r.triggerKind == .manual {
                status = .manual
            } else if let t {
                status = t <= now ? .done : .upcoming   // a fired cue is done, not perpetually "now"
            } else {
                status = .upcoming                  // workout-start, not yet fired
            }
            return DayMoment(routine: r, time: t, status: status)
        }
    }

    // MARK: - Persistence

    private func save() {
        // See `load()`/`saveIsUnsafe`: only set when routines.json failed to decode AND couldn't
        // be quarantined, i.e. there is no backup of the original anywhere. Writing here would
        // risk being the actual data-loss event rather than just reflecting an earlier one.
        guard !saveIsUnsafe else {
            Self.log.fault("save() refused: no backup of a previously-corrupt routines.json exists yet, so writing now would risk destroying the only copy. Resolve by hand and relaunch.")
            return
        }
        if let data = try? JSONEncoder().encode(routines) { try? data.write(to: fileURL, options: .atomic) }
        CloudBackup.shared.schedule()
        onChange?()
    }
    /// Re-read from disk (an iCloud restore rewrites the file underneath us).
    func reloadFromDisk() { load() }

    /// `try? JSONDecoder().decode([Routine].self, ...) else { return }` used to treat ANY decode
    /// failure — one corrupt routine among a customized day of cues, or a future field added
    /// without a migration — as "nothing here," leaving `routines` empty. `init()` then treats an
    /// empty `routines` as a fresh install and immediately reseeds + saves, permanently
    /// overwriting `routines.json` with the generic template — on the very next launch, no
    /// mutation required. `SnapshotLoader`/`LossyArray` (shared with the rest of this sweep — see
    /// `Shared/SnapshotPersistence.swift`) fix that: one bad cue costs one cue, and a wholly
    /// unparseable file is quarantined before anything (including that reseed) can overwrite it.
    private func load() {
        var decoded: [Routine]
        switch SnapshotLoader.load(from: fileURL, as: LossyArray<Routine>.self) {
        case .empty:
            return
        case let .loaded(lossy):
            if lossy.droppedCount > 0 {
                Self.log.error("routines.json: dropped \(lossy.droppedCount, privacy: .public) corrupt routine(s) on load; everything else loaded normally")
            }
            decoded = lossy.elements
        case let .corrupt(error, quarantinedTo):
            if let quarantinedTo {
                Self.log.error("routines.json failed to decode (\(String(describing: error), privacy: .public)); original preserved at \(quarantinedTo.lastPathComponent, privacy: .public). Starting empty (the next launch step reseeds the default cues) — customization is recoverable from the quarantine copy.")
            } else {
                saveIsUnsafe = true
                Self.log.fault("routines.json failed to decode (\(String(describing: error), privacy: .public)) AND could not be quarantined — no backup exists. Refusing to save until this is resolved by hand; the original is still at routines.json, untouched.")
            }
            return
        }
        routines = decoded
        // Write the decoded shape straight back. The decoder fills in fields that predate the
        // current model (cueType is inferred from the trigger/slot for routines saved before it
        // existed) — but inferring on every load isn't a migration, it's a permanent crutch: the
        // file on disk keeps the old shape forever, so the day we drop the inference every cue
        // silently becomes .custom and the wake/workout hooks stop matching. Persisting here is
        // what actually migrates, and what lets the fallback be deleted.
        //
        // But only when the shape actually changed: re-encoding to compare is pennies, while the
        // unconditional version rewrote the file (and, once wired, pushed to the Watch) on every
        // cold launch forever after the migration had long finished.
        if let original = try? Data(contentsOf: fileURL),
           let reencoded = try? JSONEncoder().encode(routines), reencoded != original {
            save()
        }
    }

    // MARK: - Defaults (mirrors the concept: a full day of cues)

    /// A neutral day scaffold — real triggers, but NO source bound. Tap a cue to
    /// choose what it plays. (No fake podcast names.)
    static func seed() -> [Routine] {
        // Built-in types come from their templates so seed + re-add + the "+" flow all agree.
        // Commute/Focus are plain `.custom` starters (just time cues with nice defaults).
        [
            CueType.wake.makeRoutine(),
            CueType.workout.makeRoutine(),
            Routine(name: "Commute", icon: "car.fill", color: .blue, triggerKind: .time,
                    hour: 8, minute: 15, weekdays: [2, 3, 4, 5, 6], autonomy: .nudge,
                    sourceLabel: "Not set", group: .day),
            Routine(name: "Focus", icon: "scope", color: .indigo, triggerKind: .time,
                    hour: 9, minute: 30, weekdays: [2, 3, 4, 5, 6], autonomy: .nudge,
                    sourceLabel: "Not set", group: .day),
            CueType.windDown.makeRoutine(),
            CueType.sleep.makeRoutine(),
        ]
    }

    #if DEBUG
    /// A process-local catalogue for screenshots. Never persist it: visual audits must not inherit
    /// or alter the developer's real enabled/disabled cue choices.
    /// `--routine-start-sample`: a Manual routine with a show to play, for the Start button.
    func injectStartableSample(podcastID: UUID) {
        guard !routines.contains(where: { $0.name == "Wind down walk" }) else { return }
        var routine = Routine(name: "Wind down walk", icon: "figure.walk", color: .indigo, triggerKind: .manual,
                              hour: 18, minute: 0, autonomy: .manual, sourceLabel: "Next from your shows", group: .evening)
        routine.podcastIDs = [podcastID]
        routines.append(routine)
    }

    func injectSampleForPreview() {
        routines = Self.seed()
        // `--wake-following-sample`: a routine that follows the Wake one, fifteen minutes after.
        if ProcessInfo.processInfo.arguments.contains("--wake-following-sample") {
            routines.append(Routine(name: "Stretch", icon: "figure.cooldown", color: .green, triggerKind: .wakeUp,
                                    hour: 7, minute: 0, autonomy: .nudge, sourceLabel: "Not set",
                                    group: .morning, leadMinutes: 15))
        }
    }
    #endif
}

// Routines are the same on every device (CloudControlsSync); the phone arms their alarms.
extension RoutineStore: CloudControlSource {
    func cloudItems(_ kind: ControlKind) -> [String: Data] {
        let encoder = JSONEncoder()
        var items: [String: Data] = [:]
        for routine in routines { items[routine.id.uuidString] = try? encoder.encode(routine) }
        return items
    }

    func applyCloud(_ kind: ControlKind, id: String, item: Data?) -> Bool {
        guard let uuid = UUID(uuidString: id) else { return true }
        guard let item else {
            delete(uuid)
            return true
        }
        guard let routine = try? JSONDecoder().decode(Routine.self, from: item), routine.id == uuid else {
            Self.log.error("a routine from another device didn't decode: \(id, privacy: .public)")
            return true
        }
        upsert(routine)
        return true
    }
}
