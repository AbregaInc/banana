import Foundation

/// When something tied to a moment is due today (docs/design/ANCHORED-TIMING.md). One rule for
/// every moment: due at the moment plus (or minus) its minutes; waiting until then; at its own
/// time — or skipped — when the moment doesn't come. Pure, for tests.
enum AnchoredTiming {
    /// The day's moments, as they've happened or are expected (`AnchoredTimingHub` gathers them).
    /// Today's finished workouts from every place one is known — Health, the Watch's own
    /// record, the Watch's word that one just ended, a "Workout" reminder ticked — each once (two within two minutes of
    /// starting are one), oldest first. Banana's Watch workouts reach Health only once the phone
    /// has saved them, which can be after the moment they're the moment for.
    static func todaysWorkouts(_ spans: [(start: Date, end: Date)], now: Date,
                               calendar: Calendar = .current) -> [(start: Date, end: Date)] {
        var out: [(start: Date, end: Date)] = []
        for span in spans.sorted(by: { $0.start < $1.start })
        where calendar.isDate(span.end, inSameDayAs: now) && span.end <= now && span.end > span.start {
            if let last = out.last, abs(last.start.timeIntervalSince(span.start)) < 120 {
                out[out.count - 1].end = max(last.end, span.end)
            } else {
                out.append(span)
            }
        }
        return out
    }

    /// Ticking the reminder that is your workout ("Workout", "Gym") is the workout ending, at the
    /// tick — a workout done without recording it is still done. It began at its time when it had
    /// one before then.
    static func tickedWorkouts(_ ticks: [(start: Date?, done: Date)]) -> [(start: Date, end: Date)] {
        ticks.map { tick in
            let start = tick.start.flatMap { $0 < tick.done ? $0 : nil } ?? tick.done.addingTimeInterval(-60)
            return (start, tick.done)
        }
    }

    struct Signals: Sendable {
        /// Workouts done today.
        var workouts: [(start: Date, end: Date)] = []
        /// A workout under way now (Watch), not yet in Health.
        var workoutStarted: Date?
        /// When today's workout is expected to start: the Workout cue's or reminder's time, a
        /// calendar event like "Gym".
        var plannedWorkout: Date?
        var wake: Date?
        /// Meals logged today: when, and which part of the day they were.
        var meals: [(date: Date, part: MealTextPart?)] = []
        /// When each meal usually is, in minutes after midnight — for "before breakfast".
        var usualMeals: [MealTextPart: Int] = [:]
        /// Reminders ticked today, by stable id and by lowercased title.
        var ticked: [String: Date] = [:]
        /// Reminders' times today, by stable id and by lowercased title — for "before".
        var reminderTimes: [String: Date] = [:]
        /// Taken items marked taken today.
        var taken: [UUID: Date] = [:]
        /// Taken items' times today — for "before".
        var doseTimes: [UUID: Date] = [:]
        /// Today's calendar events.
        var events: [(title: String, start: Date, end: Date)] = []

        init() {}
    }

    enum Due: Equatable, Sendable {
        /// Due at this time (it may be later today).
        case at(Date)
        /// Its moment hasn't come: not due, not late. What it's waiting for, in words.
        case waiting(String)
        /// The moment didn't come and it skips such days.
        case skipped
    }

    /// When `anchor`'s item is due today. `usual`: the item's own time today, the fallback.
    static func due(_ anchor: TimingAnchor, usual: Date, signals: Signals, now: Date = Date(),
                    calendar: Calendar = .current) -> Due {
        if let moment = momentTime(anchor, signals: signals, now: now, calendar: calendar) {
            let offset = TimeInterval(anchor.minutes * 60)
            return .at(anchor.relation == .before ? moment.addingTimeInterval(-offset) : moment.addingTimeInterval(offset))
        }
        switch anchor.fallback {
        case .usualTime:
            return now >= usual ? .at(usual) : .waiting(label(anchor))
        case .skip:
            let endOfDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: usual)) ?? usual
            return now >= endOfDay ? .skipped : .waiting(label(anchor))
        }
    }

    /// The moment it's measured from, when it's known: what happened for "after", what's
    /// expected (else what's begun) for "before".
    static func momentTime(_ anchor: TimingAnchor, signals: Signals, now: Date, calendar: Calendar) -> Date? {
        let before = anchor.relation == .before
        switch anchor.moment {
        case .workout:
            if before {
                return signals.plannedWorkout ?? signals.workoutStarted ?? signals.workouts.map(\.start).min()
            }
            return signals.workouts.map(\.end).min()
        case .wake:
            return signals.wake
        case .meal(let raw):
            let part = raw.flatMap(MealTextPart.init(rawValue:))
            if before {
                if let part {
                    let minutes = signals.usualMeals[part] ?? (part.clock.hour * 60 + part.clock.minute)
                    return calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: now)
                }
                return signals.meals.map(\.date).min()
            }
            let meals = signals.meals.filter { part == nil || $0.part == part }
            return meals.map(\.date).min()
        case .reminder(let id, let title):
            let keys = [id, title.lowercased()]
            if before { return keys.lazy.compactMap { signals.reminderTimes[$0] }.first }
            return keys.lazy.compactMap { signals.ticked[$0] }.first
        case .dose(let id, _):
            return before ? signals.doseTimes[id] : signals.taken[id]
        case .event(let words):
            let wanted = words.map { $0.lowercased() }.filter { !$0.isEmpty }
            let matching = signals.events.filter { event in wanted.contains { event.title.lowercased().contains($0) } }
            guard let first = matching.min(by: { $0.start < $1.start }) else { return nil }
            if before { return first.start }
            return first.end <= now ? first.end : nil
        }
    }

    // MARK: - A reminder's day

    /// Where a reminder's instance sits on the day.
    struct TaskTiming: Equatable, Sendable {
        var start: Date
        /// When it's due: its own time, or its moment's.
        var deadline: Date
        var hasScheduledTime: Bool
        var overdue: Bool
        /// What it's waiting for, while it waits ("After your workout"): not due, not late.
        var waitingFor: String?
        /// Its moment didn't come and it skips such days.
        var skipped = false
    }

    /// One instance of a reminder on the timeline. Its own due time, unless it's tied to a moment
    /// (`anchored`, today's instance only): then due at the moment, waiting — untimed, never
    /// overdue — until it comes, or skipped. Past due and not done, it's pulled up to now.
    static func taskTiming(due: Date, hasTime: Bool, completed: Bool, anchored: Due?, now: Date,
                           calendar: Calendar = .current) -> TaskTiming {
        var deadline = due
        var waitingFor: String?
        var skipped = false
        switch anchored {
        case .at(let date)?: deadline = date
        case .waiting(let label)?: waitingFor = label
        case .skipped?: skipped = true
        case nil: break
        }
        let timed = hasTime || anchored.map { if case .at = $0 { return true } else { return false } } == true
        var start = timed ? deadline : (calendar.date(bySettingHour: 9, minute: 0, second: 0, of: deadline) ?? deadline)
        if waitingFor != nil || skipped {
            return TaskTiming(start: max(start, now), deadline: deadline, hasScheduledTime: false, overdue: false,
                              waitingFor: waitingFor, skipped: skipped)
        }
        let pastDue = !completed && start < now
        if pastDue { start = now }
        return TaskTiming(start: start, deadline: deadline, hasScheduledTime: timed && !pastDue, overdue: pastDue)
    }

    /// Where a tied reminder's due time should be in Reminders, when it isn't there: today's at its
    /// moment once that has come; any other day's — and today's while it waits — at its own time
    /// (a repeating reminder moved takes the whole series with it, so the next day comes back
    /// moved). Nil when it's right, or it has no time to move.
    static func reminderMove(storedDue: Date, hasTime: Bool, usualMinutes: Int?, today: Due?, now: Date,
                             calendar: Calendar = .current) -> Date? {
        guard hasTime else { return nil }
        if calendar.isDate(storedDue, inSameDayAs: now), case .at(let moment)? = today {
            return abs(moment.timeIntervalSince(storedDue)) >= 60 ? moment : nil
        }
        guard let usualMinutes,
              let back = calendar.date(bySettingHour: usualMinutes / 60, minute: usualMinutes % 60, second: 0,
                                       of: storedDue) else { return nil }
        return abs(back.timeIntervalSince(storedDue)) >= 60 ? back : nil
    }

    // MARK: - Words

    /// "After your workout", "15 min after waking", "30 min before breakfast", "After Workout".
    static func label(_ anchor: TimingAnchor) -> String {
        let what: String
        switch anchor.moment {
        case .workout: what = "your workout"
        case .wake: what = "waking"
        case .meal(let raw):
            what = raw.flatMap(MealTextPart.init(rawValue:)).map { $0.title.lowercased() } ?? "your first meal"
        case .reminder(_, let title): what = title
        case .dose(_, let name): what = name
        case .event(let words): what = words.first.map { "\u{201C}\($0)\u{201D}" } ?? "the event"
        }
        let side = anchor.relation == .before ? "before" : "after"
        guard anchor.minutes > 0 else {
            return anchor.relation == .before ? "Just before \(what)" : "After \(what)"
        }
        return "\(duration(anchor.minutes)) \(side) \(what)"
    }

    /// "15m", "1h", "1h 30m": the app's one duration style.
    static func duration(_ minutes: Int) -> String {
        DS.duration(minutes: Double(minutes))
    }

    /// "Otherwise at 8:00 PM" / "Otherwise not that day".
    static func fallbackText(_ anchor: TimingAnchor, usual: Date) -> String {
        switch anchor.fallback {
        case .usualTime: return "Otherwise at \(usual.formatted(date: .omitted, time: .shortened))"
        case .skip: return "Otherwise not that day"
        }
    }

    /// Which meal a logged meal was, by when it was eaten.
    static func mealPart(at date: Date, calendar: Calendar = .current) -> MealTextPart {
        let minutes = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        switch minutes {
        case ..<(10 * 60 + 30): return .breakfast
        case ..<(15 * 60): return .lunch
        case ..<(17 * 60): return .snack
        case ..<(21 * 60 + 30): return .dinner
        default: return .lateNight
        }
    }
}
