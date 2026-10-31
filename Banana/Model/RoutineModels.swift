import Foundation
import SwiftUI

/// How firmly a routine fires — the honest expression of "autonomy where possible,
/// consent where necessary" given iOS's background limits.
enum Autonomy: String, Codable, Hashable {
    case auto      // hands-free (AlarmKit wake, watch workout-start)
    case nudge     // on the plan at its time; you press Start (iOS won't cold-start audio mid-day)
    case manual    // no time of its own; you press Start

    /// The words for it (`RoutineWording`).
    var level: RoutineWording.Level { RoutineWording.Level(rawValue: rawValue) ?? .manual }
    var label: String { RoutineWording.label(level) }
    var tint: Color { self == .auto ? .green : self == .nudge ? .blue : .purple }

    /// What iOS actually permits for a given trigger.
    static func `default`(for kind: RoutineTriggerKind) -> Autonomy {
        switch kind {
        case .earliestMeeting, .workoutStart: return .auto
        case .time, .calendarMatch, .wakeUp: return .nudge   // iOS won't cold-start audio mid-day
        case .manual: return .manual
        }
    }
}

enum RoutineTriggerKind: String, Codable, Hashable {
    case time             // at hour:minute on the given weekdays
    case earliestMeeting  // before your first calendar event (the smart wake)
    case workoutStart     // when a workout begins (watch)
    case wakeUp           // when you wake: the day's wake time, plus `leadMinutes` (`WakeFollowing`)
    case calendarMatch    // alongside calendar events whose title matches keywords
    case manual           // on demand
}

enum RoutineColor: String, Codable, Hashable, CaseIterable {
    case orange, blue, green, indigo, purple, pink, gray
    var color: Color {
        switch self {
        case .orange: return .orange; case .blue: return .blue; case .green: return .green
        case .indigo: return .indigo; case .purple: return .purple; case .pink: return .pink
        case .gray:  return Color(.systemGray)
        }
    }
}

enum RoutineGroup: String, Codable, Hashable, CaseIterable {
    case morning, day, evening
    var label: String { rawValue.capitalized }
}

/// What KIND of cue this is — the stable identity the app hooks into (wake alarm arming,
/// Watch workout audio, …), instead of guessing from the trigger kind. Built-in types
/// (everything but `.custom`) are **singletons** — one enabled cue each — and double as the
/// "templates" in the add-cue flow: picking a type instantiates a cue pre-wired for it, so a
/// deleted Wake/Workout can always be recreated. `.custom` cues have no special hook and may
/// exist in any number.
enum CueType: String, Codable, Hashable, CaseIterable {
    case wake, workout, windDown, sleep, custom

    var isBuiltIn: Bool { self != .custom }

    var title: String {
        switch self {
        case .wake:     return "Wake"
        case .workout:  return "Workout"
        case .windDown: return "Wind down"
        case .sleep:    return "Sleep"
        case .custom:   return "Custom"
        }
    }

    /// One-line description shown in the template picker.
    var blurb: String {
        switch self {
        case .wake:     return "Wakes you before your first meeting"
        case .workout:  return "Starts when a workout begins"
        case .windDown: return "An evening cue at a set time"
        case .sleep:    return "A manual wind-to-sleep with a fade timer"
        case .custom:   return "A cue you configure from scratch"
        }
    }

    var icon: String {
        switch self {
        case .wake:     return "sunrise.fill"
        case .workout:  return "figure.run"
        case .windDown: return "moon.fill"
        case .sleep:    return "moon.zzz.fill"
        case .custom:   return "circle.fill"
        }
    }

    var accent: RoutineColor {
        switch self {
        case .wake:     return .orange
        case .workout:  return .pink
        case .windDown: return .purple
        case .sleep:    return .indigo
        case .custom:   return .blue
        }
    }

    /// Build a fresh cue of this type with sensible defaults — this IS the template.
    func makeRoutine() -> Routine {
        switch self {
        case .wake:
            return Routine(name: "Wake", icon: icon, color: .orange, triggerKind: .earliestMeeting,
                           hour: 6, minute: 30, autonomy: .auto, sourceLabel: "Not set",
                           slot: .wake, group: .morning, cueType: .wake)
        case .workout:
            return Routine(name: "Workout", icon: icon, color: .pink, triggerKind: .workoutStart,
                           hour: 7, minute: 0, autonomy: .auto, sourceLabel: "Not set",
                           slot: .workout, group: .morning, cueType: .workout)
        case .windDown:
            return Routine(name: "Wind down", icon: icon, color: .purple, triggerKind: .time,
                           hour: 21, minute: 0, autonomy: .nudge, sourceLabel: "Not set",
                           group: .evening, cueType: .windDown)
        case .sleep:
            return Routine(name: "Sleep", icon: icon, color: .indigo, triggerKind: .manual,
                           hour: 22, minute: 30, autonomy: .manual, sourceLabel: "Not set",
                           slot: .sleep, sleepTimerMinutes: 45, group: .evening, cueType: .sleep)
        case .custom:
            return Routine(name: "New cue", icon: icon, color: .blue, triggerKind: .time,
                           hour: 12, minute: 0, autonomy: .nudge, sourceLabel: "Not set",
                           group: .day, cueType: .custom)
        }
    }

    /// Infer the type for a routine saved before `cueType` existed, so hooks + singletons
    /// keep working across the migration.
    static func inferred(trigger: RoutineTriggerKind, slot: SourceSlot?, name: String) -> CueType {
        if trigger == .earliestMeeting { return .wake }
        if trigger == .workoutStart { return .workout }
        if slot == .sleep || name.lowercased() == "sleep" { return .sleep }
        if name.lowercased() == "wind down" { return .windDown }
        return .custom
    }
}

/// An additional time-of-day slot for a `.time` cue, so one cue can fire at different times
/// on different days (e.g. Gym Tue 5pm AND Thu 6pm). The cue's primary slot stays on
/// `hour`/`minute`/`weekdays`; these are extras.
struct CueSlot: Codable, Hashable, Identifiable {
    var id: String = UUID().uuidString
    var weekdays: [Int] = []   // empty = every day
    var hour: Int
    var minute: Int
}

/// A rule that plays a source at a moment of the day. Reusable and editable — the
/// spine of the whole app. (Generalizes the old sleep/wake/workout slots.)
struct Routine: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var icon: String                 // SF Symbol
    var color: RoutineColor
    var triggerKind: RoutineTriggerKind
    var hour: Int = 7                // nominal time — resolves .time, and orders the day
    var minute: Int = 0
    var weekdays: [Int] = []         // empty = every day; 1=Sun … 7=Sat
    var autonomy: Autonomy
    var sourceLabel: String          // display: "Huberman Lab", "3 shows"…
    var podcastIDs: [UUID] = []      // pool → plays your next unfinished episode across them
    var musicItem: MusicWakeItem?    // Apple Music playlist/album/song (used when no podcasts)
    var slot: SourceSlot?            // else: wires play to a configured wake/sleep/workout source
    var sleepTimerMinutes: Int?
    var group: RoutineGroup = .day
    var enabled: Bool = true
    var matchKeywords: [String] = [] // .calendarMatch: fire alongside events whose title contains any of these
    var leadMinutes: Int = 0         // .calendarMatch: minutes BEFORE the event starts; .wakeUp: minutes AFTER you wake
    var extraSlots: [CueSlot] = []   // .time: additional time slots beyond the primary one
    var cueType: CueType = .custom   // stable identity the app hooks into (wake/workout/…)

    /// How long this cue actually takes, for cues Re-plan can book a slot for (the workout).
    /// Re-plan needs a real number to fit it around your day — and how long you train is yours to
    /// say, not the scheduler's to assume.
    var durationMinutes: Int = 45

    var nominalMinutes: Int { hour * 60 + minute }

    /// All time slots for a `.time` cue: the primary (`"main"`) plus any extras.
    var effectiveSlots: [(id: String, weekdays: [Int], hour: Int, minute: Int)] {
        [("main", weekdays, hour, minute)] + extraSlots.map { ($0.id, $0.weekdays, $0.hour, $0.minute) }
    }

    /// Human trigger description for Routines rows.
    var triggerDescription: String {
        switch triggerKind {
        case .time:
            let t = String(format: "%d:%02d", hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour), minute)
            let ampm = hour < 12 ? "AM" : "PM"
            let days = weekdays.isEmpty ? "every day" : Routine.weekdayLabel(weekdays)
            return "\(t) \(ampm) · \(days)"
        case .earliestMeeting: return "Before your first meeting"
        case .workoutStart:    return "When a workout starts"
        case .wakeUp:          return WakeFollowing.describe(minutesAfter: leadMinutes)
        case .calendarMatch:
            let kw = matchKeywords.isEmpty ? "matching events" : matchKeywords.joined(separator: ", ")
            return leadMinutes > 0 ? "\(leadMinutes)m before: \(kw)" : "With calendar: \(kw)"
        case .manual:          return "Manual"
        }
    }

    static func weekdayLabel(_ days: [Int]) -> String {
        let set = Set(days)
        if set == [2, 3, 4, 5, 6] { return "weekdays" }
        if set == [1, 7] { return "weekends" }
        let names = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return days.sorted().compactMap { names[safe: $0] }.joined(separator: " ")
    }
}

extension Routine {
    private enum LegacyKeys: String, CodingKey { case podcastID }

    /// Tolerant decoder: defaults for missing keys + migrates the old single `podcastID`
    /// into `podcastIDs`, so saved routines survive the pool change.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Cue"
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "circle.fill"
        color = try c.decodeIfPresent(RoutineColor.self, forKey: .color) ?? .blue
        triggerKind = try c.decodeIfPresent(RoutineTriggerKind.self, forKey: .triggerKind) ?? .manual
        durationMinutes = try c.decodeIfPresent(Int.self, forKey: .durationMinutes) ?? 45
        hour = try c.decodeIfPresent(Int.self, forKey: .hour) ?? 7
        minute = try c.decodeIfPresent(Int.self, forKey: .minute) ?? 0
        weekdays = try c.decodeIfPresent([Int].self, forKey: .weekdays) ?? []
        autonomy = try c.decodeIfPresent(Autonomy.self, forKey: .autonomy) ?? .manual
        sourceLabel = try c.decodeIfPresent(String.self, forKey: .sourceLabel) ?? "Not set"
        podcastIDs = try c.decodeIfPresent([UUID].self, forKey: .podcastIDs) ?? []
        if podcastIDs.isEmpty,
           let legacy = try? decoder.container(keyedBy: LegacyKeys.self),
           let single = try? legacy.decodeIfPresent(UUID.self, forKey: .podcastID) {
            podcastIDs = [single]
        }
        musicItem = try c.decodeIfPresent(MusicWakeItem.self, forKey: .musicItem)
        slot = try c.decodeIfPresent(SourceSlot.self, forKey: .slot)
        sleepTimerMinutes = try c.decodeIfPresent(Int.self, forKey: .sleepTimerMinutes)
        group = try c.decodeIfPresent(RoutineGroup.self, forKey: .group) ?? .day
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        matchKeywords = try c.decodeIfPresent([String].self, forKey: .matchKeywords) ?? []
        leadMinutes = try c.decodeIfPresent(Int.self, forKey: .leadMinutes) ?? 0
        extraSlots = try c.decodeIfPresent([CueSlot].self, forKey: .extraSlots) ?? []
        // Migrate pre-cueType saves by inferring the type from the trigger/slot/name.
        cueType = try c.decodeIfPresent(CueType.self, forKey: .cueType)
            ?? CueType.inferred(trigger: triggerKind, slot: slot, name: name)
    }
}

/// A routine resolved onto today's timeline.
struct DayMoment: Identifiable {
    let routine: Routine
    let time: Date?
    let status: Status
    var id: UUID { routine.id }

    enum Status { case done, active, upcoming, manual }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
