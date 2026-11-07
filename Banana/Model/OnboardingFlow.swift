import Foundation

/// The first run's pages, in order. Saved as each one shows (`OnboardingStore`), so a sign-in that
/// sends the person to another app, or a relaunch, comes back to the same page.
enum OnboardingStep: String, Equatable, CaseIterable {
    case welcome
    case modules
    case wake
    case windDown
    case connect
    case calendars
    case copies
    case done
}

/// The route through the first run, led by Banana (the mascot) on every page, since 6 Nov 2026.
///
/// Why it changed: a person's calendar filled with hundreds of "Busy" copies, because setup never
/// made clear what Banana would write. So the route now teaches the four things that are separate,
/// one page each, in the order they happen (`output/imagegen/onboarding-v1/README.md`):
/// connecting reads (`connect`); which calendars show and which count as busy (`calendars`,
/// shared calendars shown but not busy); copies to Google, only on a yes given in front of the
/// real plan's numbers (`copies`); and a receipt of what was chosen (`done`). Finishing without
/// copies is a success, not a skip.
///
/// Still one path for everyone: the welcome, what Banana looks after, the two day questions, the
/// calendar, then the calendar's three pages only when there is a calendar to set up.
enum OnboardingFlow {
    /// Whether the first run stands in front of the app. Only until it has been finished: no
    /// permission and no account is needed to get in, on any device.
    static func showsFirstRun(completed: Bool) -> Bool { !completed }

    /// What the next page depends on.
    struct Situation: Equatable {
        /// Connected Google accounts.
        var accounts = 0
        /// Copies already have an answer: given here before, or on another device.
        var copiesSettled = false
        /// The person owns a writable calendar, so there is somewhere a copy could go.
        var ownsWritableCalendar = false
    }

    /// Whether the copies page is asked: only with a calendar of the person's own to write to,
    /// and no answer yet from anywhere.
    static func asksAboutCopies(_ situation: Situation) -> Bool {
        situation.accounts > 0 && situation.ownsWritableCalendar && !situation.copiesSettled
    }

    /// What follows `step`, or nil when the first run is over and the app opens.
    static func next(after step: OnboardingStep, in situation: Situation) -> OnboardingStep? {
        switch step {
        case .welcome: return .modules
        case .modules: return .wake
        case .wake: return .windDown
        case .windDown: return .connect
        // No calendar: straight into the app. The receipt would only say there is nothing yet.
        case .connect: return situation.accounts > 0 ? .calendars : nil
        case .calendars: return asksAboutCopies(situation) ? .copies : .done
        case .copies: return .done
        case .done: return nil
        }
    }

    /// Where Back goes from `step`. Not from the receipt: what it lists has been applied.
    static func previous(before step: OnboardingStep) -> OnboardingStep? {
        switch step {
        case .welcome, .done: nil
        case .modules: .welcome
        case .wake: .modules
        case .windDown: .wake
        case .connect: .windDown
        case .calendars: .connect
        case .copies: .calendars
        }
    }

    /// The page to open on: the one last shown, unless what it needs has gone since (an account
    /// signed out elsewhere, copies answered on another device).
    static func resume(_ saved: OnboardingStep?, in situation: Situation) -> OnboardingStep {
        guard let saved else { return .welcome }
        switch saved {
        case .calendars, .done: return situation.accounts > 0 ? saved : .connect
        case .copies:
            if situation.accounts == 0 { return .connect }
            return asksAboutCopies(situation) ? .copies : .done
        default: return saved
        }
    }
}

/// One calendar on the calendars page: whether it shows in Banana, and whether its events make
/// the person busy. Two settings that already exist (`excludedCalendarIDs` by calendar info id,
/// `calendarBlockingOverrides` by raw id, absent = owned); this page only writes them.
struct CalendarChoice: Identifiable, Equatable {
    let id: String
    let title: String
    let account: String
    let isOwner: Bool
    let colorHex: String?
    var shown: Bool
    /// Busy as it takes effect: a hidden calendar blocks nothing.
    var busy: Bool

    var infoID: String { GoogleCalendarIDs.calendarInfoID(id) }
}

enum CalendarChoices {
    /// The page's rows: every calendar that is listed, yours first, then shared with you.
    static func rows(_ calendars: [GoogleCalendar], settings: SmartScheduleSettings) -> [CalendarChoice] {
        calendars.filter { !$0.isDeleted && !$0.isHidden }
            .map { calendar in
                let shown = !settings.excludedCalendarIDs.contains(GoogleCalendarIDs.calendarInfoID(calendar.id))
                let blocks = settings.calendarBlockingOverrides[calendar.id] ?? calendar.isOwnedByAccount
                return CalendarChoice(id: calendar.id, title: calendar.displayTitle, account: calendar.accountEmail,
                                      isOwner: calendar.isOwnedByAccount, colorHex: calendar.backgroundColor,
                                      shown: shown, busy: shown && blocks)
            }
            .sorted {
                if $0.isOwner != $1.isOwner { return $0.isOwner }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
    }

    static func setShown(_ shown: Bool, for choice: CalendarChoice, in settings: inout SmartScheduleSettings) {
        if shown { settings.excludedCalendarIDs.remove(choice.infoID) } else { settings.excludedCalendarIDs.insert(choice.infoID) }
    }

    /// Busy on a hidden calendar would mean nothing: turning it on shows the calendar too.
    static func setBusy(_ busy: Bool, for choice: CalendarChoice, in settings: inout SmartScheduleSettings) {
        if busy { setShown(true, for: choice, in: &settings) }
        settings.calendarBlockingOverrides[choice.id] = busy
    }
}

/// The last page: what the first run set up, as three lines.
struct OnboardingReceipt: Equatable {
    enum Copies: Equatable {
        case off
        /// On, with how many the yes was given for and where they go; nil when the answer came
        /// from another device.
        case on(count: Int?, to: [String])
    }

    var shown: [String]
    var busy: [String]
    var copies: Copies

    init(choices: [CalendarChoice], copies: Copies) {
        shown = choices.filter(\.shown).map(\.title)
        busy = choices.filter(\.busy).map(\.title)
        self.copies = copies
    }

    /// A list of names as one line ("Work, Personal"), or "None".
    static func line(_ names: [String]) -> String {
        names.isEmpty ? "None" : names.joined(separator: ", ")
    }

    var copiesLine: String {
        switch copies {
        case .off: "Off"
        case .on(let count?, let to) where !to.isEmpty: "\(count) on \(Self.line(to))"
        case .on: "On"
        }
    }
}

/// The ticks under the big time on the two day questions: the chosen time and two either side,
/// a quarter of an hour apart, kept inside the question's range. (The artwork draws half-hours;
/// a quarter is what a wake time needs, and still fits five to a phone.)
enum TimeTicks {
    static let step = 15

    static func around(_ minutes: Int, in range: ClosedRange<Int>) -> [Int] {
        let snapped = (minutes / step) * step
        let lowest = range.lowerBound + ((range.lowerBound % step == 0) ? 0 : step - range.lowerBound % step)
        let highest = range.upperBound - range.upperBound % step
        let first = min(max(snapped - 2 * step, lowest), max(lowest, highest - 4 * step))
        return stride(from: first, through: min(first + 4 * step, highest), by: step).map { $0 }
    }
}

/// The two ends of a day, as the first run asks for them: minutes after midnight.
///
/// They are asked because they are two of the few answers that change the plan at once: each is
/// a starter routine's time (Wake, Wind down), so the block is on the plan when the app opens,
/// calendar or no calendar. A podcast, supplements or a home address would change nothing the
/// person could see there yet.
struct DayAnchors: Equatable {
    var wakeMinutes = 6 * 60 + 30
    var windDownMinutes = 21 * 60

    /// What the pickers allow. A wake time in the evening or a wind-down at breakfast would draw
    /// a day upside down.
    static let wakeRange = 3 * 60 ... 12 * 60
    static let windDownRange = 17 * 60 ... 23 * 60 + 59

    /// The time a routine of `kind` should keep, or nil to leave it as it is.
    enum Kind { case wake, windDown, other }
    func time(for kind: Kind) -> (hour: Int, minute: Int)? {
        switch kind {
        case .wake: (wakeMinutes / 60, wakeMinutes % 60)
        case .windDown: (windDownMinutes / 60, windDownMinutes % 60)
        case .other: nil
        }
    }

    /// Kept inside the ranges, whatever was handed in.
    var clamped: DayAnchors {
        DayAnchors(wakeMinutes: min(max(wakeMinutes, Self.wakeRange.lowerBound), Self.wakeRange.upperBound),
                   windDownMinutes: min(max(windDownMinutes, Self.windDownRange.lowerBound), Self.windDownRange.upperBound))
    }
}
