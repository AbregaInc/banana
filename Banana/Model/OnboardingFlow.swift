import Foundation

enum OnboardingStep: Equatable, CaseIterable {
    case welcome
    case wake
    case windDown
    case calendar
    case otherCalendar
}

/// The route through the first run: the welcome (which asks what Banana should look after, since
/// 17 Oct 2026; the answer only decides what is shown, not the route), two questions that build a day (when it starts,
/// when it winds down), the calendar, the other calendar, then the app. One path for everyone.
///
/// How it got here (9 Oct 2026). A welcome that asked where to start and sent people down
/// different routes: the author, "There should only be one path." Then two screens that asked nothing.
/// Then the research he asked for (DESIGN-SYSTEM.md, "First run"): a question earns its place when
/// its answer changes the next screen. So the two questions come before Google and each moves a
/// block on a day in front of the person.
///
/// 10 Oct 2026, the author: the calendar step is to show what Banana does between calendars (a
/// meeting on one is busy time on the other, before and after) and get a second account
/// connected, "personal work is the main driver". So one more step follows the first sign-in:
/// the other calendar. It is also where busy blocks get their yes, once there are two accounts.
enum OnboardingFlow {
    /// Whether the first run stands in front of the app. Only until it has been finished: no
    /// permission and no account is needed to get in, on any device. The Mac used to ask for a
    /// connected Google calendar as well, and showed a sign-in screen until there was one.
    static func showsFirstRun(completed: Bool) -> Bool { !completed }

    /// What follows `step`, or nil when the first run is over and the app opens.
    ///
    /// `accounts` is how many Google accounts are connected; `busySettled` is whether busy
    /// blocks already have an answer (given here before, or on another device). The first
    /// calendar is not asked for when one is already here, and the other calendar is not asked
    /// for when there is no first one or the answer it leads to has been given.
    static func next(after step: OnboardingStep, accounts: Int, busySettled: Bool) -> OnboardingStep? {
        let other: OnboardingStep? = accounts > 0 && !busySettled ? .otherCalendar : nil
        switch step {
        case .welcome: return .wake
        case .wake: return .windDown
        case .windDown: return accounts == 0 ? .calendar : other
        case .calendar: return other
        case .otherCalendar: return nil
        }
    }

    /// Where Back goes from `step`. Not from the other calendar: the sign-in before it is done.
    static func previous(before step: OnboardingStep) -> OnboardingStep? {
        switch step {
        case .welcome, .otherCalendar: nil
        case .wake: .welcome
        case .windDown: .wake
        case .calendar: .windDown
        }
    }

    /// What the other-calendar step's main button does: add an account while there is one,
    /// start busy blocks once there are two to keep in step.
    enum OtherCalendarAction: Equatable { case addAccount, blockBusyTime }
    static func otherCalendarAction(accounts: Int) -> OtherCalendarAction {
        accounts >= 2 ? .blockBusyTime : .addAccount
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
