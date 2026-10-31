#if os(iOS)
import AppIntents
import Foundation

/// Phase 2 of docs/design/CHAT-ASSISTANT-PLAN.md: **the single command layer.**
///
/// Every capability the assistant will eventually expose is modelled here once, as an
/// `AppIntent`. Siri, Shortcuts, and Spotlight get it immediately and for free; the chat
/// assistant, when it arrives, wraps these rather than re-implementing them. That is the
/// whole argument for option C — and the spike made it concrete: an iPhone 14 Pro reports
/// `deviceNotEligible` for Apple Intelligence, so on that phone this file *is* the feature.
///
/// Two rules carried over from what the spike caught (plan §2.2), because they are exactly
/// the failures this layer must not repeat:
///
/// 1. **Dates are resolved by the system, never by a model.** `@Parameter` of type `Date`
///    is handled by the OS's own date resolution, which knows what day it is. The
///    on-device LLM did not — it read "tomorrow" as seven months in the past. Typed
///    parameters are the structural fix, not a better prompt.
/// 2. **Every mutation confirms, and the confirmation quotes real state.** The dialog is
///    built from what the store actually returns, never from generated prose. The model
///    claimed "I have re-planned your day" over a tool that said "Not applied".

// MARK: - Read

struct WhatsNextIntent: AppIntent {
    static var title: LocalizedStringResource = "What's Next"
    static var description = IntentDescription("The next thing coming up on your Banana timeline.")
    /// Read-only and answerable out loud — no reason to drag the app forward.
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = OccurrenceStore.shared
        await store.recomputeIfStale()
        guard let next = store.next() else {
            return .result(dialog: "Nothing else on your schedule today.")
        }
        let when = next.start.formatted(.dateTime.hour().minute())
        return .result(dialog: "\(when) — \(next.title)")
    }
}

struct DaySummaryIntent: AppIntent {
    static var title: LocalizedStringResource = "What's On"
    static var description = IntentDescription("Everything scheduled on a given day.")
    static var openAppWhenRun = false

    /// A system-resolved date. Siri fills this from "tomorrow", "Thursday", "the 30th" using
    /// the OS's date handling — the capability the on-device model demonstrably lacks.
    @Parameter(title: "Day", kind: .date)
    var day: Date?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = OccurrenceStore.shared
        await store.recomputeIfStale()
        let target = day ?? Date()
        let items = store.occurrences(on: target)
        let dayName = target.formatted(.dateTime.weekday(.wide).month().day())

        guard !items.isEmpty else {
            return .result(dialog: "Nothing scheduled for \(dayName).")
        }
        // One line per item, in order — the airport-board rule from the Flighty audit. Siri
        // reads this aloud, so a long day is truncated rather than recited for a minute.
        let lines = items.prefix(8).map {
            "\($0.start.formatted(.dateTime.hour().minute())) \($0.title)"
        }.joined(separator: ", ")
        let more = items.count > 8 ? ", and \(items.count - 8) more" : ""
        return .result(dialog: "\(dayName): \(lines)\(more).")
    }
}

// MARK: - Write
//
// Each of these confirms before it acts, and the confirmation names exactly what will
// change. `requestConfirmation` throws if the person declines, which aborts `perform`.

struct CreateTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Task"
    static var description = IntentDescription("Add a task to Banana, optionally at a set time.")
    static var openAppWhenRun = false

    @Parameter(title: "Task")
    var taskTitle: String

    @Parameter(title: "When", kind: .dateTime)
    var due: Date?

    @Parameter(title: "Minutes to reserve", default: 30)
    var durationMinutes: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$taskTitle) at \(\.$due) for \(\.$durationMinutes) minutes")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = OccurrenceStore.shared
        // A due date is required by the store; "no time given" means today, all-day.
        let hasTime = due != nil
        let when = due ?? Calendar.current.startOfDay(for: Date())

        let spoken = hasTime
            ? "Add “\(taskTitle)” at \(when.formatted(.dateTime.weekday().hour().minute()))?"
            : "Add “\(taskTitle)” for today?"
        // Current API. The `result:` overload is deprecated, and `actionName` is what labels
        // the confirm button — "Add" reads better than a generic "Continue".
        try await requestConfirmation(actionName: .add, dialog: IntentDialog(stringLiteral: spoken))

        do {
            _ = try await store.createTask(
                title: taskTitle,
                due: when,
                hasTime: hasTime,
                durationMinutes: durationMinutes
            )
        } catch {
            // Say what actually failed. The usual cause is Reminders access never granted,
            // which is invisible from Siri and impossible to guess at.
            return .result(dialog: "Couldn't add that — \(error.localizedDescription)")
        }
        return .result(dialog: "Added “\(taskTitle)”.")
    }
}

// MARK: - Routines

/// A routine, as Siri and Shortcuts see it.
struct RoutineEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Routine"
    static var defaultQuery = RoutineEntityQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct RoutineEntityQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [RoutineEntity] {
        RoutineStore.shared.routines
            .filter { identifiers.contains($0.id.uuidString) }
            .map { RoutineEntity(id: $0.id.uuidString, name: $0.name) }
    }

    @MainActor
    func suggestedEntities() async throws -> [RoutineEntity] {
        RoutineStore.shared.routines.filter(\.enabled).map { RoutineEntity(id: $0.id.uuidString, name: $0.name) }
    }
}

/// "Start Wind Down in Banana": a routine started by voice, from Shortcuts or the Action button,
/// without opening the app. It plays audio, which is what lets the system start it this way.
struct StartRoutineIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Start Routine"
    static var description = IntentDescription("Start one of your Banana routines now: it plays what the routine plays.")
    static var openAppWhenRun = false

    @Parameter(title: "Routine")
    var routine: RoutineEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Start \(\.$routine)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let found = RoutineStore.shared.routines.first(where: { $0.id.uuidString == routine.id }) else {
            return .result(dialog: "That routine isn\u{2019}t in Banana any more.")
        }
        let wake = WakeCoordinator.shared
        await wake.library.whenLoaded()   // the shows it picks from, read from disk first
        guard let summary = RoutineStart.summary(of: found, library: wake.library) else {
            return .result(dialog: "\(found.name) has nothing to play yet. Add a show or music to it in Banana.")
        }
        RoutineStart.start(found, library: wake.library, player: wake.player, music: wake.music)
        return .result(dialog: "Started \(found.name). \(summary).")
    }
}

struct CompleteTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Complete Task"
    static var description = IntentDescription("Tick a Banana task off.")
    static var openAppWhenRun = false

    /// An entity rather than a string, so Siri disambiguates against the person's real open
    /// tasks ("which one?") instead of us guessing at a title match.
    @Parameter(title: "Task")
    var task: BananaTaskEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Complete \(\.$task)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await requestConfirmation(
            actionName: .do,
            dialog: IntentDialog(stringLiteral: "Mark “\(task.title)” done?")
        )
        OccurrenceStore.shared.completeTask(reminderID: task.id)
        return .result(dialog: "Done — “\(task.title)”.")
    }
}

// MARK: - Task entity
//
// Backed by the same Reminders-derived occurrences the timeline shows, so Siri and the app
// can never disagree about what an open task is.

struct BananaTaskEntity: AppEntity {
    let id: String
    let title: String
    let due: Date?

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Task"
    static var defaultQuery = BananaTaskQuery()

    var displayRepresentation: DisplayRepresentation {
        guard let due else { return DisplayRepresentation(title: "\(title)") }
        return DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(due.formatted(.dateTime.weekday().hour().minute()))"
        )
    }
}

struct BananaTaskQuery: EntityStringQuery {
    /// Resolve the entities behind IDs Shortcuts already holds.
    @MainActor
    func entities(for identifiers: [String]) async throws -> [BananaTaskEntity] {
        await openTasks().filter { identifiers.contains($0.id) }
    }

    /// Spoken or typed matching — "mark call the dentist done".
    @MainActor
    func entities(matching string: String) async throws -> [BananaTaskEntity] {
        let needle = string.lowercased()
        return await openTasks().filter { $0.title.lowercased().contains(needle) }
    }

    @MainActor
    func suggestedEntities() async throws -> [BananaTaskEntity] {
        Array(await openTasks().prefix(10))
    }

    /// Open tasks across the planning horizon, soonest first. Completed ones are excluded:
    /// offering them would let "complete X" silently pick something already done.
    @MainActor
    private func openTasks() async -> [BananaTaskEntity] {
        let store = OccurrenceStore.shared
        await store.recomputeIfStale()
        return store.occurrences
            .filter { $0.behavior == .task && !$0.completed && $0.reminderID != nil }
            .sorted { $0.start < $1.start }
            .compactMap { occ in
                occ.reminderID.map {
                    BananaTaskEntity(id: $0, title: occ.title, due: occ.hasScheduledTime ? occ.start : nil)
                }
            }
    }
}
#endif
