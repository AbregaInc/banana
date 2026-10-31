import Foundation
import EventKit

/// One reminder as a schedulable task. `due` is the resolved due date (with a time when the
/// reminder has one); `hasTime` distinguishes a timed task from a day-level deadline.
struct TaskInfo: Identifiable, Hashable {
    var id: String            // EKReminder.calendarItemIdentifier
    var externalID: String? = nil   // Provider identifier; typically stable across synced devices
    var title: String
    var due: Date?
    var hasTime: Bool
    var isCompleted: Bool
    var priority: Int
    var recurrence: CalendarItemRecurrence = .never
    /// When it was ticked, for something due after it (`AnchoredTiming`).
    var completedAt: Date? = nil
}

enum ReminderCreationError: LocalizedError {
    case accessDenied
    case noDefaultList
    case emptyTitle
    case saveFailed(String)
    /// Beta, and the reminder isn't in Beta's own list.
    case betaReadOnly

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Banana needs Reminders access to create reminders. Enable it in Settings and try again."
        case .noDefaultList:
            return "Choose a default list in Apple Reminders, then try again."
        case .emptyTitle:
            return "Enter a name for the reminder."
        case .saveFailed(let detail):
            return "Apple Reminders couldn’t save this reminder: \(detail)"
        case .betaReadOnly:
            return "Banana Beta only changes reminders in its own \u{201C}Banana Beta\u{201D} list."
        }
    }
}

/// Reads Apple Reminders (EventKit) so tasks can live on the unified timeline. Separate
/// authorization from calendar; needs `NSRemindersFullAccessUsageDescription`.
final class RemindersService {
    let store = EKEventStore()

    struct ReminderListInfo: Identifiable, Hashable {
        let id: String
        let title: String
        let sourceID: String
        let sourceTitle: String
        let isDefault: Bool
    }

    struct CreatedTask {
        let id: String
        let externalID: String?
    }

    struct EditableTask {
        let id: String
        let title: String
        let notes: String
        let due: Date
        let hasTime: Bool
        let priority: Int
        let recurrence: CalendarItemRecurrence
        let listID: String
    }

    var authorized: Bool {
        if Self.isAuthorized { return true }
        #if os(macOS)
        // Same sandbox-entitlement path as CalendarService.authorized: a sandboxed Mac build
        // gets access from `com.apple.security.personal-information.reminders`, leaving TCC
        // with nothing to record and `authorizationStatus` stuck at `.notDetermined`.
        if EKEventStore.authorizationStatus(for: .reminder) == .notDetermined,
           !store.calendars(for: .reminder).isEmpty {
            return true
        }
        #endif
        return false
    }

    /// Static so a store can seed its published mirror before any instance exists. Status-only:
    /// the sandbox fallback above needs a live store, and a seed just needs a safe starting point.
    static var isAuthorized: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }

    @discardableResult
    func requestAccess() async -> Bool {
        let before = EKEventStore.authorizationStatus(for: .reminder)
        Log.sync.notice("reminders authorization request started status=\(before.rawValue, privacy: .public)")

        // macOS can refuse to re-prompt once a status is terminal, exactly as it does for
        // calendar. Say so rather than silently returning false, which reads as a Connect button
        // that does nothing.
        if before == .denied || before == .restricted || before == .writeOnly {
            Log.sync.error("reminders authorization skipped terminalStatus=\(before.rawValue, privacy: .public)")
            return false
        }

        var systemSaidGranted = false
        do {
            systemSaidGranted = try await store.requestFullAccessToReminders()
        } catch {
            Log.sync.error("reminders authorization request failed error=\(error.localizedDescription, privacy: .public)")
        }
        let after = EKEventStore.authorizationStatus(for: .reminder)
        Log.sync.notice("reminders authorization finished systemSaidGranted=\(systemSaidGranted, privacy: .public) status=\(after.rawValue, privacy: .public)")
        // The partial-grant dead end, same as OnboardingStore.requestCalendar documents: the
        // system reports the request granted while recording something less, and never prompts
        // again. Nothing in-app can fix that state — only the privacy pane can.
        if systemSaidGranted && after != .fullAccess {
            Log.sync.error("reminders authorization partial grant status=\(after.rawValue, privacy: .public)")
        }
        // Return the RECORDED status, never the request's own return value. `try?` turned a throw
        // into `false` even when the grant landed, and the caller then skipped the refresh that
        // would have shown the newly-readable tasks. CalendarService.requestAccess had the same
        // bug; this one outlived it by a few hours.
        return after == .fullAccess
    }

    /// Incomplete reminders that carry a due date (the ones that belong on a timeline).
    ///
    /// Bounded to `within` days ahead: the nil/nil predicate fetched **every incomplete reminder
    /// ever**, then threw most of them away in Swift — on every recompute. No lower bound, so
    /// long-overdue tasks still come back; anything due beyond the horizon was filtered out
    /// downstream anyway (`OccurrenceProducers.tasks(horizonDays:)`), so the result is identical.
    func dueTasks(within days: Int = 14) async -> [TaskInfo] {
        guard authorized else { return [] }
        let horizonEnd = Calendar.current.date(byAdding: .day, value: days, to: Date())
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: horizonEnd, calendars: nil)
        return await fetchTasks(matching: predicate)
    }

    /// A bounded range for an explicitly opened week. This is intentionally separate from the
    /// rolling background horizon: moving through the calendar should load the selected week once,
    /// not make every normal recompute scan months of reminders.
    func dueTasks(from start: Date, to end: Date) async -> [TaskInfo] {
        guard authorized else { return [] }
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: start,
            ending: end,
            calendars: nil
        )
        return await fetchTasks(matching: predicate)
    }

    private func fetchTasks(matching predicate: NSPredicate) async -> [TaskInfo] {
        let reminders: [EKReminder] = await withCheckedContinuation { cont in
            store.fetchReminders(matching: predicate) { cont.resume(returning: $0 ?? []) }
        }
        return reminders.compactMap { r in
            guard let comps = r.dueDateComponents, let due = Calendar.current.date(from: comps) else { return nil }
            return TaskInfo(id: r.calendarItemIdentifier,
                            externalID: r.calendarItemExternalIdentifier,
                            title: r.title?.isEmpty == false ? r.title! : "Task",
                            due: due, hasTime: comps.hour != nil,
                            isCompleted: r.isCompleted, priority: r.priority,
                            recurrence: recurrence(for: r))
        }
    }

    /// Reminders completed today (so they stay on the timeline, checked off).
    func completedTodayTasks() async -> [TaskInfo] {
        guard authorized else { return [] }
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 1, to: start)
        let predicate = store.predicateForCompletedReminders(withCompletionDateStarting: start, ending: end, calendars: nil)
        let reminders: [EKReminder] = await withCheckedContinuation { cont in
            store.fetchReminders(matching: predicate) { cont.resume(returning: $0 ?? []) }
        }
        return reminders.compactMap { r in
            guard let comps = r.dueDateComponents, let due = cal.date(from: comps) else { return nil }
            return TaskInfo(id: r.calendarItemIdentifier,
                            externalID: r.calendarItemExternalIdentifier,
                            title: r.title?.isEmpty == false ? r.title! : "Task",
                            due: due, hasTime: comps.hour != nil, isCompleted: true, priority: r.priority,
                            completedAt: r.completionDate)
        }
    }

    /// Reminders ticked between two dates, each with when — the history an anchor is learned from
    /// (`AnchorSuggestions`) and a reminder's doses come from when it moves to Taken
    /// (`ReminderToTaken`). A repeating reminder's ticks are completed copies of it, under its
    /// title and often another id.
    func completedTasks(from start: Date, to end: Date) async -> [TaskInfo] {
        guard authorized else { return [] }
        let predicate = store.predicateForCompletedReminders(withCompletionDateStarting: start, ending: end, calendars: nil)
        let reminders: [EKReminder] = await withCheckedContinuation { cont in
            store.fetchReminders(matching: predicate) { cont.resume(returning: $0 ?? []) }
        }
        return reminders.compactMap { r in
            guard let completedAt = r.completionDate else { return nil }
            let comps = r.dueDateComponents
            return TaskInfo(id: r.calendarItemIdentifier,
                            externalID: r.calendarItemExternalIdentifier,
                            title: r.title?.isEmpty == false ? r.title! : "Task",
                            due: comps.flatMap { Calendar.current.date(from: $0) },
                            hasTime: comps?.hour != nil, isCompleted: true, priority: r.priority,
                            recurrence: recurrence(for: r), completedAt: completedAt)
        }
    }

    /// What ending a reminder's repeat changed, so `restoreRepeat` can put back exactly that.
    struct EndedRepeat {
        let id: String
        /// Copies of its repeat rules as they were — every field, not just the frequency.
        let rules: [EKRecurrenceRule]
        let due: DateComponents?
        let wasCompleted: Bool
    }

    /// Stops a repeating reminder coming back, for something that has moved to Taken: its repeat
    /// is removed and it's ticked. Nothing else changes and it isn't deleted — its earlier ticks
    /// stay in Reminders' history. Two commits, repeat first: ticking a reminder that still
    /// repeats would make Reminders file a completed copy and move the series on instead.
    func endRepeat(_ id: String) throws -> EndedRepeat {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw ReminderCreationError.saveFailed("The reminder no longer exists.")
        }
        let rules = (reminder.recurrenceRules ?? []).compactMap { $0.copy() as? EKRecurrenceRule }
        guard !rules.isEmpty else { throw ReminderCreationError.saveFailed("The reminder doesn\u{2019}t repeat.") }
        let ended = EndedRepeat(id: id, rules: rules, due: reminder.dueDateComponents,
                                wasCompleted: reminder.isCompleted)
        do {
            for rule in reminder.recurrenceRules ?? [] { reminder.removeRecurrenceRule(rule) }
            try save(reminder, commit: true)
        } catch {
            store.reset()
            throw ReminderCreationError.saveFailed(error.localizedDescription)
        }
        do {
            reminder.isCompleted = true
            try save(reminder, commit: true)
        } catch {
            store.reset()
            // Half done is the one state not to leave it in: put the repeat back.
            try? restoreRepeat(ended)
            throw ReminderCreationError.saveFailed(error.localizedDescription)
        }
        return ended
    }

    /// Undoes `endRepeat`: the same repeat rules, due date and done-or-not as before.
    func restoreRepeat(_ ended: EndedRepeat) throws {
        guard let reminder = store.calendarItem(withIdentifier: ended.id) as? EKReminder else {
            throw ReminderCreationError.saveFailed("The reminder no longer exists.")
        }
        reminder.isCompleted = ended.wasCompleted
        for rule in reminder.recurrenceRules ?? [] { reminder.removeRecurrenceRule(rule) }
        for rule in ended.rules { reminder.addRecurrenceRule(rule) }
        if reminder.dueDateComponents != ended.due { reminder.dueDateComponents = ended.due }
        do {
            try save(reminder, commit: true)
        } catch {
            store.reset()
            throw ReminderCreationError.saveFailed(error.localizedDescription)
        }
    }

    /// Create a task from Banana's New Task sheet. Apple Reminders remains the source of truth;
    /// timed reminders are picked up by OccurrenceStore and mirrored by calendar write-back.
    @discardableResult
    func createTask(
        title: String,
        due: Date,
        hasTime: Bool,
        listID: String? = nil,
        notes: String? = nil,
        priority: Int = 0,
        recurrence: CalendarItemRecurrence = .never
    ) async throws -> CreatedTask {
        let trace = Signpost.begin("taskAuthoringCommit")
        defer { Signpost.end(trace) }
        let diagnostic = DiagnosticJournal.shared.startSpan(
            "reminder.taskAuthoring",
            attributes: [
                "has_time": hasTime ? "true" : "false",
                "has_explicit_list": listID == nil ? "false" : "true",
                "recurrence": recurrence.rawValue,
            ])
        var diagnosticStatus = DiagnosticSpanStatus.failed
        var diagnosticReason = "task_creation_did_not_complete"
        defer {
            DiagnosticJournal.shared.finish(
                diagnostic,
                status: diagnosticStatus,
                reason: diagnosticReason)
        }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else {
            diagnosticReason = "empty_title"
            throw ReminderCreationError.emptyTitle
        }
        if !authorized {
            do {
                guard try await store.requestFullAccessToReminders() else {
                    diagnosticReason = "access_denied"
                    throw ReminderCreationError.accessDenied
                }
            } catch let error as ReminderCreationError {
                throw error
            } catch {
                diagnosticReason = "access_request_failed"
                throw ReminderCreationError.saveFailed(error.localizedDescription)
            }
        }
        let calendar: EKCalendar
        if let listID {
            guard let selected = store.calendar(withIdentifier: listID),
                  selected.allowsContentModifications,
                  selected.allowedEntityTypes.contains(.reminder) else {
                diagnosticReason = "selected_list_unavailable"
                throw ReminderCreationError.noDefaultList
            }
            calendar = selected
        } else {
            guard let defaultList = listForNewReminders() else {
                diagnosticReason = "default_list_unavailable"
                throw ReminderCreationError.noDefaultList
            }
            calendar = defaultList
        }

        let reminder = EKReminder(eventStore: store)
        reminder.calendar = calendar
        reminder.title = cleanTitle
        let cleanNotes = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        reminder.notes = cleanNotes?.isEmpty == false ? cleanNotes : nil
        reminder.priority = priority
        reminder.dueDateComponents = Calendar.current.dateComponents(
            hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day],
            from: due
        )
        if let frequency = recurrence.eventKitFrequency {
            reminder.addRecurrenceRule(EKRecurrenceRule(
                recurrenceWith: frequency,
                interval: 1,
                end: nil
            ))
        }
        do {
            try save(reminder, commit: true)
            diagnosticStatus = .succeeded
            diagnosticReason = "eventkit_save_committed"
            return CreatedTask(
                id: reminder.calendarItemIdentifier,
                externalID: reminder.calendarItemExternalIdentifier
            )
        } catch {
            diagnosticReason = "eventkit_save_failed"
            throw ReminderCreationError.saveFailed(error.localizedDescription)
        }
    }

    /// The one way a reminder is saved. Beta saves only into its own list (`AppVariant`).
    private func save(_ reminder: EKReminder, commit: Bool) throws {
        guard AppVariant.current.mayChangeReminder(inListTitled: reminder.calendar?.title) else {
            throw ReminderCreationError.betaReadOnly
        }
        try store.save(reminder, commit: commit)
    }

    /// Where a new reminder goes when no list was chosen. In Beta that is its own list, made the
    /// first time one is needed, beside the default list.
    private func listForNewReminders() -> EKCalendar? {
        let standard = store.defaultCalendarForNewReminders()
        guard AppVariant.current == .beta else { return standard }
        if let own = store.calendars(for: .reminder).first(where: {
            $0.title == AppVariant.betaRemindersList && $0.allowsContentModifications
        }) { return own }
        guard let source = standard?.source else { return nil }
        let list = EKCalendar(for: .reminder, eventStore: store)
        list.title = AppVariant.betaRemindersList
        list.source = source
        return (try? store.saveCalendar(list, commit: true)) != nil ? list : nil
    }

    func writableLists() -> [ReminderListInfo] {
        guard authorized else { return [] }
        let defaultID = listForNewReminders()?.calendarIdentifier
        return store.calendars(for: .reminder)
            .filter(\.allowsContentModifications)
            .filter { AppVariant.current.mayChangeReminder(inListTitled: $0.title) }
            .map {
                ReminderListInfo(
                    id: $0.calendarIdentifier,
                    title: $0.title,
                    sourceID: $0.source.sourceIdentifier,
                    sourceTitle: $0.source.title,
                    isDefault: $0.calendarIdentifier == defaultID
                )
            }
            .sorted {
                if $0.sourceTitle != $1.sourceTitle {
                    return $0.sourceTitle.localizedCaseInsensitiveCompare($1.sourceTitle) == .orderedAscending
                }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
    }

    func editableTask(_ id: String) -> EditableTask? {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder,
              let components = reminder.dueDateComponents,
              let due = Calendar.current.date(from: components) else { return nil }
        return EditableTask(
            id: reminder.calendarItemIdentifier,
            title: reminder.title ?? "",
            notes: reminder.notes ?? "",
            due: due,
            hasTime: components.hour != nil,
            priority: reminder.priority,
            recurrence: recurrence(for: reminder),
            listID: reminder.calendar.calendarIdentifier
        )
    }

    @discardableResult
    func updateTask(
        _ id: String,
        title: String,
        due: Date,
        hasTime: Bool,
        listID: String?,
        notes: String?,
        priority: Int,
        recurrence requestedRecurrence: CalendarItemRecurrence
    ) throws -> CreatedTask {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { throw ReminderCreationError.emptyTitle }
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw ReminderCreationError.saveFailed("The reminder no longer exists.")
        }
        // Checked before anything moves: saving only sees the list a reminder ends up in.
        guard AppVariant.current.mayChangeReminder(inListTitled: reminder.calendar?.title) else {
            throw ReminderCreationError.betaReadOnly
        }
        if let listID, listID != reminder.calendar.calendarIdentifier {
            guard let selected = store.calendar(withIdentifier: listID),
                  selected.allowsContentModifications,
                  selected.allowedEntityTypes.contains(.reminder) else {
                throw ReminderCreationError.noDefaultList
            }
            reminder.calendar = selected
        }

        reminder.title = cleanTitle
        let cleanNotes = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        reminder.notes = cleanNotes?.isEmpty == false ? cleanNotes : nil
        reminder.priority = priority
        reminder.dueDateComponents = Calendar.current.dateComponents(
            hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day],
            from: due
        )

        // Preserve richer provider rules (for example every two weeks) when the user only edits
        // the title or time. Replace recurrence only when the simple frequency actually changed.
        if recurrence(for: reminder) != requestedRecurrence {
            for rule in reminder.recurrenceRules ?? [] {
                reminder.removeRecurrenceRule(rule)
            }
            if let frequency = requestedRecurrence.eventKitFrequency {
                reminder.addRecurrenceRule(EKRecurrenceRule(
                    recurrenceWith: frequency,
                    interval: 1,
                    end: nil
                ))
            }
        }

        do {
            try save(reminder, commit: true)
            return CreatedTask(
                id: reminder.calendarItemIdentifier,
                externalID: reminder.calendarItemExternalIdentifier
            )
        } catch {
            throw ReminderCreationError.saveFailed(error.localizedDescription)
        }
    }

    private func recurrence(for reminder: EKReminder) -> CalendarItemRecurrence {
        CalendarItemRecurrence(eventKitFrequency: reminder.recurrenceRules?.first?.frequency)
    }

    /// Two-way completion sync.
    /// Create a reminder and return its identifier, so a note can be updated in place once its
    /// transcription lands. Uses the default reminders list; nil if access isn't granted or there
    /// is no default list.
    @discardableResult
    func create(
        title: String,
        notes: String?,
        parent: DiagnosticTraceContext? = nil
    ) -> String? {
        let diagnostic = DiagnosticJournal.shared.startSpan(
            "reminder.voiceNoteWriteBack",
            parent: parent)
        guard let calendar = listForNewReminders() else {
            DiagnosticJournal.shared.finish(
                diagnostic,
                status: .failed,
                reason: "default_list_unavailable")
            return nil
        }
        let r = EKReminder(eventStore: store)
        r.calendar = calendar
        r.title = title
        r.notes = notes
        do {
            try save(r, commit: true)
            DiagnosticJournal.shared.finish(
                diagnostic,
                status: .succeeded,
                reason: "eventkit_save_committed")
            return r.calendarItemIdentifier
        } catch {
            DiagnosticJournal.shared.finish(
                diagnostic,
                status: .failed,
                reason: "eventkit_save_failed",
                attributes: ["error": error.localizedDescription])
            return nil
        }
    }

    /// Idempotent note write-back. The stable URL survives a crash between EventKit save
    /// and the local outbox acknowledgement. Fetch completed reminders too, so retrying never
    /// resurrects a reminder the user already completed.
    @MainActor
    func writeNoteReminder(noteID: UUID, previousID: String?, title: String, notes: String,
                           stillCurrent: () -> Bool) async -> String? {
        guard authorized else { return nil }
        let marker = NoteReminderLink.url(noteID, beta: AppVariant.current == .beta)
        return await NoteReminderWriter.write(previousID: previousID, marker: marker,
            title: title, notes: notes, stillCurrent: stillCurrent,
            lookup: { self.store.calendarItem(withIdentifier: $0) as? EKReminder },
            fetch: {
                let calendars = self.store.calendars(for: .reminder)
                let predicate = self.store.predicateForReminders(in: calendars)
                return await withCheckedContinuation { continuation in
                    self.store.fetchReminders(matching: predicate) { continuation.resume(returning: $0) }
                }
            }, create: {
                guard let calendar = self.listForNewReminders() else { return nil }
                let reminder = EKReminder(eventStore: self.store)
                reminder.calendar = calendar
                return reminder
            }, save: { reminder in
                // Permission can be revoked while the fetch is suspended. Keep the outbox.
                guard self.authorized else { throw ReminderCreationError.accessDenied }
                try self.save(reminder, commit: true) // Also enforces Beta's list restriction.
                return reminder.calendarItemIdentifier
            })
    }

    /// Replace a reminder's title/notes in place (e.g. once a voice note is transcribed).
    func update(_ id: String, title: String?, notes: String?) {
        guard let r = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        if let title { r.title = title }
        if let notes { r.notes = notes }
        try? save(r, commit: true)
    }

    /// Persist a burst of completion changes in one EventKit transaction. Rapidly checking a
    /// sequence of tasks should not force one synchronous database commit per tap.
    func setCompleted(_ id: String, _ completed: Bool) {
        _ = setCompleted([id: completed])
    }

    @discardableResult
    func setCompleted(_ changes: [String: Bool]) -> Bool {
        do {
            var hasChanges = false
            for (id, completed) in changes {
                guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder,
                      reminder.isCompleted != completed else { continue }
                reminder.isCompleted = completed
                try save(reminder, commit: false)
                hasChanges = true
            }
            if hasChanges {
                try store.commit()
            }
            return true
        } catch {
            store.reset()
            return false
        }
    }

    /// Move a repeating reminder's outstanding instance to `target`'s day (keeping its time, or
    /// its lack of one). Unsaved until the next commit unless `commit` — so completing it then
    /// marks that day done and Reminders moves the series on from there.
    /// - Returns: whether it's on that day now.
    @discardableResult
    func moveDue(_ id: String, to target: Date, commit: Bool = false) -> Bool {
        guard let r = store.calendarItem(withIdentifier: id) as? EKReminder, let old = r.dueDateComponents else { return false }
        let calendar = Calendar.current
        var moved = calendar.dateComponents([.year, .month, .day], from: target)
        if old.hour != nil {
            moved.hour = calendar.component(.hour, from: target)
            moved.minute = calendar.component(.minute, from: target)
        }
        guard moved.year != old.year || moved.month != old.month || moved.day != old.day else { return true }
        r.dueDateComponents = moved
        do {
            try save(r, commit: commit)
            return true
        } catch {
            r.dueDateComponents = old
            return false
        }
    }

    /// One instance of a repeating reminder that won't be done: the reminder moves on to the next
    /// without completing anything, so no done copy says it was.
    /// - Returns: its due date before, for Undo (`restoreDue`), and the instance it's at now.
    func moveOn(_ id: String, past instanceDue: Date) -> (before: DateComponents, now: Date)? {
        guard let r = store.calendarItem(withIdentifier: id) as? EKReminder, let before = r.dueDateComponents,
              let next = ReminderRollover.next(after: instanceDue, recurrence: recurrence(for: r)),
              moveDue(id, to: next, commit: true) else { return nil }
        return (before, next)
    }

    /// Undoes `moveOn`: the due date exactly as it was.
    @discardableResult
    func restoreDue(_ id: String, to components: DateComponents) -> Bool {
        guard let r = store.calendarItem(withIdentifier: id) as? EKReminder else { return false }
        let current = r.dueDateComponents
        r.dueDateComponents = components
        do {
            try save(r, commit: true)
            return true
        } catch {
            r.dueDateComponents = current
            return false
        }
    }

    /// Change a reminder's due date/time (writes back to Reminders).
    func reschedule(_ id: String, to newDue: Date) {
        guard let r = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: newDue)
        try? save(r, commit: true)
    }
}

/// Reminders repeat through EventKit, which speaks its own frequency type.
extension CalendarItemRecurrence {
    var eventKitFrequency: EKRecurrenceFrequency? {
        switch self {
        case .never: return nil
        case .daily: return .daily
        case .weekly: return .weekly
        case .monthly: return .monthly
        case .yearly: return .yearly
        }
    }

    init(eventKitFrequency: EKRecurrenceFrequency?) {
        switch eventKitFrequency {
        case .daily: self = .daily
        case .weekly: self = .weekly
        case .monthly: self = .monthly
        case .yearly: self = .yearly
        default: self = .never
        }
    }
}
