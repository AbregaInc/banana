import Combine
import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Today's moments, gathered from what Banana already has — workouts (Health's and the Watch's), sleep, the meal
/// log, Taken, the timeline's reminders and events — for everything due around one
/// (`AnchoredTiming`, docs/design/ANCHORED-TIMING.md). Nothing is stored: the moments are read off
/// the stores each time, so they can't drift from them.
///
/// It also rings Taken's reminders, one day at a time (`ringTaken`): a fixed-time one at its
/// time, and one that follows a moment at its own time as the fallback, replaced by a reminder
/// at moment + offset when the moment comes. Not today's, once the dose is marked.
@MainActor
final class AnchoredTimingHub: ObservableObject {
    static let shared = AnchoredTimingHub()

    /// Bumped when the moments change, so what shows due times redraws.
    @Published private(set) var version = 0

    private var watches: Set<AnyCancellable> = []
    private var started = false
    /// The app's Health store: workouts and last night's sleep.
    private weak var health: HealthKitStore?
    private var pendingRefresh: Task<Void, Never>?

    func start(health: HealthKitStore) {
        guard !started else { return }
        started = true
        self.health = health
        health.$workouts.dropFirst().sink { [weak self] _ in self?.refreshSoon() }.store(in: &watches)
        FitnessStore.shared.$summaries.dropFirst().sink { [weak self] _ in self?.refreshSoon() }.store(in: &watches)
        WellnessStore.shared.$meals.dropFirst().sink { [weak self] _ in self?.refreshSoon() }.store(in: &watches)
        WellnessStore.shared.$supplementLogs.dropFirst().sink { [weak self] _ in self?.refreshSoon() }.store(in: &watches)
        WellnessStore.shared.$supplements.dropFirst().sink { [weak self] _ in self?.refreshSoon() }.store(in: &watches)
        OccurrenceStore.shared.$occurrences.dropFirst().sink { [weak self] _ in self?.refreshSoon() }.store(in: &watches)
        // Food switched off takes its dose reminders with it; back on, they are planned again.
        ModuleStore.shared.$choice.dropFirst().removeDuplicates().sink { [weak self] _ in self?.refreshSoon() }.store(in: &watches)
        refreshSoon()
    }

    /// Workouts the Watch said had just ended, before the workout itself arrived.
    private var announcedWorkouts: [(start: Date, end: Date)] = []

    /// A workout just ended on the Watch — its word (which wakes the phone), or the workout
    /// itself arriving. What's due after it rings now, even when the phone was woken in the
    /// background and the rest of the app hasn't started: the stores it reads are waited for.
    func workoutEnded(start: Date? = nil, end: Date? = nil) {
        if let start, let end, end > start { announcedWorkouts.append((start, end)) }
        Task { @MainActor [weak self] in
            await WellnessStore.shared.whenLoaded()
            await FitnessStore.shared.whenLoaded()
            self?.refresh()
        }
    }

    /// After the stores have settled — `@Published` announces before it stores, and a burst of
    /// changes (a sync) is one refresh.
    func refreshSoon() {
        pendingRefresh?.cancel()
        pendingRefresh = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    func refresh(now: Date = Date()) {
        version &+= 1
        ringTaken(now: now)
    }

    // MARK: - The moments

    func signals(now: Date = Date(), calendar: Calendar = .current) -> AnchoredTiming.Signals {
        var signals = AnchoredTiming.Signals()
        let today = calendar.startOfDay(for: now)
        let isToday: (Date) -> Bool = { calendar.isDate($0, inSameDayAs: now) }

        let fromHealth = (health?.workouts ?? []).map { (start: $0.start, end: $0.end) }
        let fromWatch = FitnessStore.shared.summaries.compactMap { summary in
            summary.end.map { (start: summary.start, end: $0) }
        }
        // A "Workout" reminder ticked is a workout done, recorded or not.
        let ticked = AnchoredTiming.tickedWorkouts(OccurrenceStore.shared.occurrences.compactMap { task in
            guard task.behavior == .task, task.completed, let done = task.completedAt,
                  AnchorSuggestions.isWorkout(task.title) else { return nil }
            return (start: task.hasScheduledTime ? task.start : nil, done: done)
        })
        signals.workouts = AnchoredTiming.todaysWorkouts(fromHealth + fromWatch + announcedWorkouts + ticked,
                                                         now: now, calendar: calendar)
        signals.wake = health?.trends.nights.last { isToday($0.wake) && $0.wake <= now }?.wake

        let wellness = WellnessStore.shared
        signals.meals = wellness.meals.filter { isToday($0.date) && $0.date <= now }
            .map { ($0.date, AnchoredTiming.mealPart(at: $0.date, calendar: calendar)) }
        signals.usualMeals = Self.usualMealMinutes(wellness.meals, now: now, calendar: calendar)
        for log in wellness.supplementLogs where log.status == .taken && isToday(log.date) {
            signals.taken[log.supplementID] = min(signals.taken[log.supplementID] ?? log.date, log.date)
        }
        for supplement in wellness.supplements {
            signals.doseTimes[supplement.id] = calendar.date(bySettingHour: supplement.safeHour,
                                                             minute: supplement.safeMinute, second: 0, of: today)
        }

        let occurrences = OccurrenceStore.shared.occurrences.filter { isToday($0.start) }
        for task in occurrences where task.behavior == .task {
            let keys = [task.reminderExternalID, task.title.lowercased()].compactMap { $0 }
            if task.completed, let at = task.completedAt {
                for key in keys where signals.ticked[key] == nil { signals.ticked[key] = at }
            }
            if let due = task.schedule.constraints?.deadline, task.hasScheduledTime || due > today {
                for key in keys where signals.reminderTimes[key] == nil { signals.reminderTimes[key] = due }
            }
        }
        signals.events = occurrences.filter { $0.behavior == .event && $0.hasScheduledTime }
            .map { ($0.title, $0.start, $0.end ?? $0.start) }
        signals.plannedWorkout = Self.plannedWorkout(occurrences, routines: RoutineStore.shared.routines, now: now)
        return signals
    }

    /// When today's workout is expected: the Workout cue, a reminder or event that says workout,
    /// gym or the like — whichever comes first that hasn't finished.
    static func plannedWorkout(_ occurrences: [Occurrence], routines: [Routine], now: Date) -> Date? {
        let workoutCues = Set(routines.filter { $0.cueType == .workout }.map(\.id))
        return occurrences.filter { occurrence in
            guard occurrence.hasScheduledTime, !occurrence.completed, !occurrence.skipped else { return false }
            if let routine = occurrence.routineID, workoutCues.contains(routine) { return true }
            return (occurrence.behavior == .task || occurrence.behavior == .event)
                && AnchorSuggestions.isWorkout(occurrence.title)
        }.map(\.start).min()
    }

    /// The middle of when each meal was had over the last month, in minutes after midnight.
    static func usualMealMinutes(_ meals: [MealEntry], now: Date, calendar: Calendar) -> [MealTextPart: Int] {
        let since = calendar.date(byAdding: .day, value: -30, to: now) ?? now
        var byPart: [MealTextPart: [Int]] = [:]
        for meal in meals where meal.date >= since && meal.date < calendar.startOfDay(for: now) {
            let minutes = calendar.component(.hour, from: meal.date) * 60 + calendar.component(.minute, from: meal.date)
            byPart[AnchoredTiming.mealPart(at: meal.date, calendar: calendar), default: []].append(minutes)
        }
        return byPart.compactMapValues { values in
            guard values.count >= 3 else { return nil }
            return values.sorted()[values.count / 2]
        }
    }

    // MARK: - Taken

    /// A Taken item's due today: its time, or around its moment.
    func due(_ supplement: SupplementSchedule, now: Date = Date(), calendar: Calendar = .current) -> AnchoredTiming.Due {
        let usual = calendar.date(bySettingHour: supplement.safeHour, minute: supplement.safeMinute, second: 0,
                                  of: now) ?? now
        guard let anchor = supplement.anchor else { return .at(usual) }
        return AnchoredTiming.due(anchor, usual: usual, signals: signals(now: now, calendar: calendar), now: now,
                                  calendar: calendar)
    }

    /// When it's due today, if it's due at all yet: nil while it waits, or on a day it skips.
    func dueDate(_ supplement: SupplementSchedule, now: Date = Date()) -> Date? {
        if case .at(let date) = due(supplement, now: now) { return date }
        return nil
    }

    // MARK: - Ringing

    private func notificationID(_ id: UUID, _ day: Date) -> String { SupplementSchedule.reminderID(id, on: day) }
    private static let rungKey = "anchoredTiming.rungAt"

    /// Taken items, rung one day at a time. One that follows a moment: today at its moment +
    /// offset once that's known (or now, if it passed while Banana wasn't running), else at its
    /// own time; the next days at their own time, replaced on the day. One with a fixed time: at
    /// that time each day (`DoseReminderPlan`). Today's is left out once the dose is marked,
    /// which a single repeating notification couldn't do. What today's was set for is
    /// remembered, so a reminder that has gone off isn't rung again on the next refresh.
    private func ringTaken(now: Date) {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        let calendar = Calendar.current
        let wellness = WellnessStore.shared
        var rungAt = (UserDefaults.standard.dictionary(forKey: Self.rungKey) as? [String: Double]) ?? [:]
        let ahead = DoseReminderPlan.daysAhead(reminders: wellness.supplements.filter(\.enabled).count)
        // Doses are Food's: with it switched off none are planned, and those pending go below.
        let foodOn = ModuleStore.shared.includes(.food)
        for supplement in wellness.supplements {
            // Whatever an earlier pass set, and the one that repeated daily from before fixed
            // times were rung by the day.
            NotificationWrites.removePending(SupplementSchedule.reminderIDs(supplement.id, from: now))
            guard supplement.enabled, foodOn else { continue }
            let marked = wellness.supplementStatus(supplement.id, on: now) != nil
            for offset in 0...ahead {
                guard let day = calendar.date(byAdding: .day, value: offset, to: now) else { continue }
                let id = notificationID(supplement.id, day)
                let usual = calendar.date(bySettingHour: supplement.safeHour, minute: supplement.safeMinute,
                                          second: 0, of: day) ?? day
                var when: Date?
                var body = supplement.dose.isEmpty ? "Supplement reminder" : "Scheduled dose: \(supplement.dose)"
                guard let anchor = supplement.anchor else {
                    // A fixed time.
                    if let at = DoseReminderPlan.fixedTime(usual: usual, isToday: offset == 0, marked: marked, now: now) {
                        ring(id, supplement.name, body, at: at, center: center, calendar: calendar)
                    }
                    continue
                }
                if offset == 0 {
                    guard !marked else { continue }
                    let rang = rungAt[id].map { Date(timeIntervalSince1970: $0) <= now } ?? false
                    switch due(supplement, now: now) {
                    case .at(let date):
                        if date > now { when = date } else if !rang { when = now.addingTimeInterval(2) }
                        // Due because its moment came: say so.
                        if date != usual { body = AnchoredTiming.label(anchor) + body.prefixedDot }
                    case .waiting:
                        when = anchor.fallback == .usualTime && usual > now ? usual : nil
                    case .skipped:
                        when = nil
                    }
                    if let when { rungAt[id] = when.timeIntervalSince1970 }
                } else if anchor.fallback == .usualTime {
                    when = usual
                }
                guard let when else { continue }
                ring(id, supplement.name, body, at: when, center: center, calendar: calendar)
            }
        }
        // Only today's are worth remembering.
        let today = calendar.startOfDay(for: now).timeIntervalSince1970
        rungAt = rungAt.filter { $0.value >= today }
        UserDefaults.standard.set(rungAt, forKey: Self.rungKey)
        #endif
    }
}

#if canImport(UserNotifications)
private extension AnchoredTimingHub {
    /// One Taken reminder, once, at `when`: through a Focus like the other reminders, and with
    /// "Taken" on it (`DoseReminders`).
    func ring(_ id: String, _ title: String, _ body: String, at when: Date,
              center: UNUserNotificationCenter, calendar: Calendar) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.categoryIdentifier = DoseReminders.category
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: when)
        NotificationWrites.add(UNNotificationRequest(identifier: id, content: content,
                                                     trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
    }
}
#endif

private extension String {
    /// " · 5 g" after a label, or nothing for an empty dose.
    var prefixedDot: String { isEmpty ? "" : " \u{00B7} " + self }
}
