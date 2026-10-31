import Foundation

/// Learning what something is really done after (docs/design/ANCHORED-TIMING.md, "Learning it,
/// and moving to Taken"). Banana sees when things are ticked; an item done within the hour after
/// the same moment on most recent days is offered that moment: "Creatine usually follows your
/// workout — about 15 min after, on 6 of the last 8 days." Pure, for tests —
/// `AnchorSuggestionStore` gathers the weeks of history, this decides.
enum AnchorSuggestions {
    /// How many days back it looks: long enough that a habit is a habit, short enough that last
    /// month's routine doesn't speak for this one.
    static let days = 21
    /// Done at most this long after the moment, to count as following it.
    static let window: TimeInterval = 60 * 60
    /// It followed on at least this share of the days both happened...
    static let share = 0.6
    /// ...and on at least this many of them, so a lucky few days aren't a habit.
    static let minimumDays = 4
    /// Ticked this soon after another tick is one sitting — the morning pills ticked down the
    /// list — not one thing following another. Only for moments that are ticks; "right after your
    /// workout" is a real habit.
    static let sameSitting: TimeInterval = 3 * 60

    /// Something done each day that could be due around a moment instead of at a time.
    struct Item: Hashable, Sendable {
        enum Subject: Hashable, Sendable {
            /// A Taken item.
            case taken(UUID)
            /// A repeating Apple Reminder: its stable id, and its title (a completed copy of a
            /// repeating reminder can carry another id).
            case reminder(externalID: String?, title: String)

            var isTaken: Bool {
                if case .taken = self { return true }
                return false
            }
        }

        var subject: Subject
        var name: String
        /// When it was done over the last weeks.
        var done: [Date]
        /// Already due around something: never offered another.
        var anchored = false
    }

    /// A moment, and when it came over the same weeks.
    struct Moment: Sendable {
        var moment: TimingAnchor.Moment
        var times: [Date]
        /// What it's itself due around, when it's an item with an anchor — so two things are never
        /// tied to each other, where neither would come due until its own time.
        var anchoredTo: TimingAnchor.Moment?

        init(_ moment: TimingAnchor.Moment, times: [Date], anchoredTo: TimingAnchor.Moment? = nil) {
            self.moment = moment
            self.times = times
            self.anchoredTo = anchoredTo
        }
    }

    struct Suggestion: Hashable, Identifiable, Sendable {
        var subject: Item.Subject
        var name: String
        var anchor: TimingAnchor
        /// The days it followed the moment...
        var followed: Int
        /// ...of the days both happened.
        var together: Int
        /// How far the gap wanders from day to day, in minutes. A habit tied to a moment follows
        /// it by a steady gap; a moment that only happens to come before it wanders.
        var spread: Double

        /// The item and the moment: what a "No" is remembered by, so a different moment for the
        /// same item can still be offered later.
        var id: String { AnchorSuggestions.key(subject) + "|" + AnchorSuggestions.key(anchor.moment) }
        /// What the offer says: "Creatine after workouts?". The evidence is `sentence`, read aloud.
        var question: String { AnchorSuggestions.question(self) }
        var sentence: String { AnchorSuggestions.sentence(self) }
    }

    // MARK: - The rule

    /// The strongest suggestion for each item that has none yet, most supporting days first.
    static func suggestions(_ items: [Item], moments: [Moment], now: Date = Date(),
                            calendar: Calendar = .current) -> [Suggestion] {
        items.compactMap { best(for: $0, moments: moments, now: now, calendar: calendar) }
            .sorted { ($0.followed, -$0.spread) > ($1.followed, -$1.spread) }
    }

    /// The moment `item` follows, if one does: done 0–60 min after it on at least 60% of the days
    /// both happened, and on at least four. With two, the one it followed on more days; then the
    /// steadier gap; then the first in `moments`.
    static func best(for item: Item, moments: [Moment], now: Date = Date(),
                     calendar: Calendar = .current) -> Suggestion? {
        guard !item.anchored else { return nil }
        let since = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now)) ?? now
        let done = firstEachDay(item.done, since: since, now: now, calendar: calendar)
        guard done.count >= minimumDays else { return nil }
        var best: Suggestion?
        for candidate in moments {
            guard !isItself(candidate.moment, item) else { continue }
            if let follows = candidate.anchoredTo, isItself(follows, item) { continue }
            let came = firstEachDay(candidate.times, since: since, now: now, calendar: calendar)
            let earliest = candidate.moment.isTick ? sameSitting : 0
            var together = 0
            var gaps: [Double] = []
            for (day, at) in done {
                guard let moment = came[day] else { continue }
                together += 1
                let gap = at.timeIntervalSince(moment)
                if gap >= earliest, gap <= window { gaps.append(gap / 60) }
            }
            guard gaps.count >= minimumDays, Double(gaps.count) >= share * Double(together) else { continue }
            let typical = median(gaps)
            let suggestion = Suggestion(
                subject: item.subject, name: item.name,
                anchor: TimingAnchor(moment: candidate.moment, relation: .after, minutes: rounded(typical),
                                     fallback: .usualTime),
                followed: gaps.count, together: together,
                spread: median(gaps.map { abs($0 - typical) }))
            if let current = best {
                if (suggestion.followed, -suggestion.spread) > (current.followed, -current.spread) { best = suggestion }
            } else {
                best = suggestion
            }
        }
        return best
    }

    /// The first time on each day since `since`, by the start of its day — measured the way an
    /// anchor fires: after the day's first workout, first meal, first tick.
    static func firstEachDay(_ times: [Date], since: Date, now: Date, calendar: Calendar) -> [Date: Date] {
        var first: [Date: Date] = [:]
        for time in times where time >= since && time <= now {
            let day = calendar.startOfDay(for: time)
            if first[day].map({ time < $0 }) ?? true { first[day] = time }
        }
        return first
    }

    /// The nearest of the gaps the editor offers (`TimingAnchor.minuteChoices`); halfway between
    /// two, the shorter — reminded a little early beats a little late.
    static func rounded(_ minutes: Double) -> Int {
        TimingAnchor.minuteChoices.min { abs(Double($0) - minutes) < abs(Double($1) - minutes) } ?? 0
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// Whether `moment` is the item itself: its own dose or tick, or — for a reminder — the very
    /// thing its title names. A reminder called "Workout" is ticked after the workout because it
    /// IS the workout; "Post-workout protein" is something taken after one.
    static func isItself(_ moment: TimingAnchor.Moment, _ item: Item) -> Bool {
        switch (moment, item.subject) {
        case (.dose(let id, _), .taken(let own)):
            return id == own
        case (.reminder(let id, let title), .reminder(let externalID, let own)):
            return id == externalID || normalized(title) == normalized(own)
        case (.workout, .reminder(_, let title)):
            return isWorkout(title)
        case (.meal, .reminder(_, let title)):
            let meals = MealTextPart.allCases.flatMap(\.words)
            return names(meals, in: title) && !ReminderToTaken.readsAsTaken(title)
        case (.wake, .reminder(_, let title)):
            return names(wakeWords, in: title)
        default:
            return false
        }
    }

    /// What a workout is called in a reminder's or event's title.
    static let workoutWords = ["workout", "gym", "training", "run", "yoga", "lift", "swim", "spin", "pilates", "crossfit"]

    /// A reminder or event that IS your workout — "Workout", "Gym", "Morning run" — not something
    /// done around one ("Post-workout protein" is taken). Ticking it is the workout ending; its time
    /// is when it's planned (`AnchoredTimingHub`).
    static func isWorkout(_ title: String) -> Bool {
        names(workoutWords, in: title) && !ReminderToTaken.readsAsTaken(title)
    }
    static let wakeWords = ["wake", "get up", "out of bed"]

    private static func names(_ words: [String], in title: String) -> Bool {
        let text = normalized(title)
        return words.contains { text.range(of: "\\b\($0)", options: .regularExpression) != nil }
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - Words

    /// "Creatine after workouts?": the offer, short. The evidence goes to VoiceOver.
    static func question(_ suggestion: Suggestion) -> String {
        let moment: String
        switch suggestion.anchor.moment {
        case .workout: moment = "workouts"
        default: moment = phrase(suggestion.anchor.moment)
        }
        return "\(suggestion.name) after \(moment)?"
    }

    /// "Creatine usually follows your workout — about 15m after, on 6 of the last 8 days."
    static func sentence(_ suggestion: Suggestion) -> String {
        let gap = suggestion.anchor.minutes == 0
            ? "right after"
            : "about \(AnchoredTiming.duration(suggestion.anchor.minutes)) after"
        return "\(suggestion.name) usually follows \(phrase(suggestion.anchor.moment)) \u{2014} \(gap), "
            + "on \(suggestion.followed) of the last \(suggestion.together) days."
    }

    /// The moment as the sentence names it: "your workout", "waking up", "breakfast".
    static func phrase(_ moment: TimingAnchor.Moment) -> String {
        switch moment {
        case .workout: return "your workout"
        case .wake: return "waking up"
        case .meal(let raw): return raw.flatMap(MealTextPart.init(rawValue:)).map { $0.title.lowercased() } ?? "your first meal"
        case .reminder(_, let title): return title
        case .dose(_, let name): return name
        case .event(let words): return words.first.map { "\u{201C}\($0)\u{201D}" } ?? "the event"
        }
    }

    // MARK: - Keys

    /// An item, the same on every device: a Taken item by its id, a reminder by its stable id
    /// (else its title).
    static func key(_ subject: Item.Subject) -> String {
        switch subject {
        case .taken(let id): return "taken:" + id.uuidString
        case .reminder(let externalID, let title): return "reminder:" + (externalID ?? "title:" + normalized(title))
        }
    }

    static func key(_ moment: TimingAnchor.Moment) -> String {
        switch moment {
        case .workout: return "workout"
        case .wake: return "wake"
        case .meal(let raw): return "meal:" + (raw ?? "first")
        case .reminder(_, let title): return "reminder:" + normalized(title)
        case .dose(let id, _): return "dose:" + id.uuidString
        case .event(let words): return "event:" + words.map(normalized).joined(separator: ",")
        }
    }

    // MARK: - Taken's history

    /// When a Taken item was actually taken: its `.taken` doses, less those ticked off for a day
    /// already past — those are filed at its scheduled time to the second
    /// (`NutritionDays.doseDate`), which says nothing about when it was taken.
    static func observed(_ logs: [SupplementLog], for supplement: SupplementSchedule,
                         calendar: Calendar = .current) -> [Date] {
        logs.filter { log in
            guard log.supplementID == supplement.id, log.status == .taken else { return false }
            let scheduled = calendar.date(bySettingHour: supplement.safeHour, minute: supplement.safeMinute,
                                          second: 0, of: log.date)
            return log.date != scheduled
        }.map(\.date)
    }
}

extension TimingAnchor {
    /// The gaps an anchor is offered with: in the editor (`TimingFields`), and what a learned one
    /// is rounded to.
    static let minuteChoices = [0, 5, 10, 15, 30, 45, 60, 90, 120]
}

extension TimingAnchor.Moment {
    /// Something ticked — another reminder, another dose — rather than something that happens.
    var isTick: Bool {
        switch self {
        case .reminder, .dose: return true
        default: return false
        }
    }
}
