import Foundation

/// Stable, app-owned identity for a single occurrence. It is stamped into any calendar
/// event we write (as `banana://occ/<id>`) so we recognize our own writes on read-back
/// and can update/delete them in place. Never reused across distinct occurrences.
typealias AppItemID = String

/// Groups a recurring set of occurrences (one cue's schedule, one calendar series, …).
typealias SeriesID = String

/// Where an occurrence came from.
/// Whether an occurrence has actually reached a calendar yet.
///
/// Drawn events are normally things a calendar already holds, so this is absent for almost all of
/// them. It exists so an event can be shown the instant it is created — before the write, the
/// debounce and the recompute have finished — without pretending it is saved when it is not.
enum OccurrenceSyncState: String, Codable, Hashable, Sendable {
    /// On its way to a calendar, or written and awaiting read-back.
    case syncing
    /// The write did not succeed. Still shown, because what the user typed lives only in the
    /// pending store until it does; retryable, and never removed on its own.
    case failed

    var symbolName: String {
        switch self {
        case .syncing: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
}

enum OccurrenceSource: String, Codable, Hashable {
    case external   // read from the calendar (EventKit) — never written by us
    case derived    // computed from other occurrences (wake, wind-down, commute)
    case authored   // the user's own cues / tasks / events
}

/// What an occurrence *does*.
enum OccurrenceBehavior: String, Codable, Hashable {
    case event   // an appointment you attend (external calendar events)
    case cue     // arms/plays a routine (podcast pool, music, sleep timer)
    case task    // a to-do (Apple Reminders)
    case block   // protected time the system reserves
    case alarm   // a one-off alarm the user set for a moment (AlarmKit one-shot)
    case allDay  // an all-day calendar event, one day of it: in the day's "No time" row; blocks
                 // the day when it's marked Busy (`AllDayEvents`)
}

/// How an occurrence got its time.
enum ScheduleMode: String, Codable, Hashable {
    case fixed      // pinned (meetings, hard commitments)
    case derived    // computed from other occurrences (recomputes automatically)
    case flexible   // placed by the scheduler into open time (L4)
}

/// Whether a written calendar event marks you busy. Default is `.busy` (defend the time),
/// but only calendars whose source supports availability honor it — verified on-device.
enum WritePolicy: String, Codable, Hashable {
    case busy   // shows busy to others (default)
    case free   // for your own view only
    case none   // don't write this occurrence to the calendar at all
}

struct TimeWindow: Codable, Hashable {
    var start: Date
    var end: Date
}

/// Placement constraints for a `.flexible` occurrence (used by the L4 scheduler).
struct OccurrenceConstraints: Codable, Hashable {
    var duration: TimeInterval
    var window: TimeWindow?      // allowed placement range
    var deadline: Date?          // must finish by
    var priority: Int = 3        // lower = scheduled first
    var frequencyPerWeek: Int?   // for habits spread across days
}

struct OccurrenceSchedule: Codable, Hashable {
    var mode: ScheduleMode
    /// Sticky by default; opt-in. Only `.flexible` occurrences may be relocated by Re-plan.
    var moveable: Bool = false
    var constraints: OccurrenceConstraints?
}

/// One thing on the unified timeline: `Source × Behavior × Schedule × Time`. Tabs become
/// filters over occurrences rather than separate features.
///
/// Codable, but ONLY for the first-paint snapshot (see OccurrenceStore): the timeline is still
/// always recomputed — the snapshot is a display-only stale cache that a fresh recompute
/// replaces within seconds, and nothing downstream (alarm arming, calendar write-back) ever
/// consumes it.
struct Occurrence: Identifiable {
    var id: AppItemID
    var seriesID: SeriesID?
    var slotID: String?          // durable slot identity within a series (for L2 exceptions)

    var source: OccurrenceSource
    var behavior: OccurrenceBehavior
    var schedule: OccurrenceSchedule
    var writePolicy: WritePolicy = .busy

    var title: String
    var icon: String             // SF Symbol
    var tint: RoutineColor       // reuse the cue palette

    var start: Date
    var end: Date?
    /// False for cues with no clock time (manual / workout-start) — they show "On start"
    /// and are placed at their nominal time only for ordering.
    var hasScheduledTime: Bool = true
    /// A skipped occurrence (L2) stays on the timeline dimmed with a Restore action, but is
    /// not written to the calendar or armed.
    var skipped: Bool = false
    /// A completed task — stays visible, checked off, until the day rolls over.
    var completed: Bool = false
    /// When a task was ticked, for what's due after it (`AnchoredTiming`).
    var completedAt: Date?
    /// The authored day stays stable when a one-off move crosses midnight.
    var overrideDayKey: String?
    /// A task past its due date, pulled forward onto today (like the Reminders app).
    var overdue: Bool = false

    /// A reminder past its time and not done — today's 8 AM creatine at 9 too. What the Plan badge
    /// counts and what List leads with: one rule, so the count and the list can't disagree.
    var isOverdueReminder: Bool { behavior == .task && overdue && !completed }

    /// A routine moment with no time of its own: a workout "on start", a manual one. It sits with
    /// the day's all-day events, above the hours.
    var isUntimedCue: Bool { behavior == .cue && !hasScheduledTime }

    /// An instance of a repeating reminder: `OccurrenceProducers.tasks` ids those
    /// "task:<reminder>:<due>", and a one-off "task:<reminder>".
    var isRepeatingTask: Bool { behavior == .task && id.split(separator: ":").count == 3 }

    /// Which instance of a repeating reminder this is: its own due, from its id.
    var instanceDue: Date? { behavior == .task ? ReminderRollover.instanceDue(occurrenceID: id) : nil }

    /// An overdue instance of a repeating reminder: "Missed it" moves the reminder on to the next
    /// without saying this one was done.
    var canBeMarkedMissed: Bool { isOverdueReminder && instanceDue != nil }

    // Links back to the owning domain object — for tap-through, arming, and write-back.
    var routineID: UUID?         // the cue this came from (behavior == .cue)
    var externalEventID: String? // EKEvent identifier (source == .external)
    var reminderID: String?      // EKReminder id (behavior == .task)
    /// The reminder's provider identifier, which — unlike `reminderID` — is the same on every
    /// synced device. Names the task's busy block, so the phone and the Mac write the same one.
    var reminderExternalID: String?
    var meeting: MeetingInfo?    // full external meeting (leave-by, address, RSVP)
    /// For a travel block: mode, minutes and where it goes ("🚶 24 min · Chelsea Piers"). Display
    /// only; the calendar write-back never reads it.
    var travel: TravelLegDetail?
    /// Set only on an event the user has created that has not yet been confirmed on a calendar.
    /// Nil for everything read back from a calendar, which is the overwhelming majority.
    var syncState: OccurrenceSyncState?
    /// The pending write this occurrence stands in for, so a retry or a discard from the grid
    /// knows which one it is acting on.
    var pendingWriteID: UUID?
    /// A repeating reminder's earlier instances that went undone before this one
    /// (`ReminderRollover`, `MissedRepeats`): "Missed yesterday". Nil when none were.
    var missed: ReminderMissed?
    /// A reminder tied to a moment that hasn't come yet: what it's waiting for ("After your
    /// workout"). Not due and not late; shown in words instead of a time (`AnchoredTiming`).
    var waitingFor: String?

    /// Marked "Show As: Free" on its source calendar — on your day, but not holding the slot.
    /// Drives the hollow treatment in the UI and suppresses write-back entirely.
    var showsAsFree: Bool { meeting?.showsAsFree == true }

    /// An all-day event marked Busy: the whole day is taken — Re-plan places nothing in it,
    /// availability offers none of it, and it's covered on your other calendars.
    var blocksWholeDay: Bool { behavior == .allDay && !showsAsFree && !skipped }

    /// A concrete end for layout/write-back (defaults to a short block for non-events).
    var resolvedEnd: Date { end ?? start.addingTimeInterval(behavior == .event ? 1800 : 600) }

    /// Do we write this to the calendar? Scheduled flexible work and derived busy blocks such as
    /// travel qualify. Routine cues, alarms, informational derived markers, day-level backlog,
    /// and external events stay read-only.
    var isWritable: Bool {
        let isFlexibleWork = (behavior == .task || behavior == .block)
            && schedule.mode == .flexible
        let isDerivedBusyBlock = source == .derived
            && behavior == .block
            && schedule.mode == .derived
        return source != .external
            && (isFlexibleWork || isDerivedBusyBlock)
            && writePolicy != .none
            && hasScheduledTime
            && !skipped
            && !completed
    }

    /// The exception key this occurrence resolves against (L2).
    var occurrenceKey: String? {
        guard let seriesID, let slotID else { return nil }
        return "\(seriesID)|\(slotID)|\(overrideDayKey ?? Occurrence.dayKey(start))"
    }

    static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static func dayKey(_ date: Date) -> String { dayKeyFormatter.string(from: date) }

    /// Deterministic id for an authored/derived occurrence so write-back updates in place.
    static func makeID(series: SeriesID, slot: String, day: Date) -> AppItemID {
        "\(series):\(slot):\(dayKey(day))"
    }
}

extension Occurrence: Codable {}   // synthesized — every stored property is Codable

/// Synthesized — every stored property is Hashable once `MeetingInfo` is (see MeetingLink.swift/
/// CalendarService.swift). Used only as a cheap change-detection token (WeekView's day content
/// hash); not persisted or compared across launches.
extension Occurrence: Hashable {}
