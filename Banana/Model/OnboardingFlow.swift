import CoreGraphics
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
        /// This build carries a module to choose (BANANA_MODULES). Without one there is nothing to
        /// ask on the modules page, so it isn't shown.
        var offersModules = true
    }

    /// Whether the copies page is asked: only with a calendar of the person's own to write to,
    /// and no answer yet from anywhere.
    static func asksAboutCopies(_ situation: Situation) -> Bool {
        situation.accounts > 0 && situation.ownsWritableCalendar && !situation.copiesSettled
    }

    /// What follows `step`, or nil when the first run is over and the app opens.
    static func next(after step: OnboardingStep, in situation: Situation) -> OnboardingStep? {
        switch step {
        case .welcome: return situation.offersModules ? .modules : .wake
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
    static func previous(before step: OnboardingStep, in situation: Situation = Situation()) -> OnboardingStep? {
        switch step {
        case .welcome, .done: nil
        case .modules: .welcome
        case .wake: situation.offersModules ? .modules : .welcome
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
        case .modules: return situation.offersModules ? saved : .wake
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
                let blocks = calendar.blocksTime(overrides: settings.calendarBlockingOverrides)
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

    /// The Google accounts whose calendars came in.
    var calendar: [String]
    /// Email on or off; nil in a build without Email, where the line isn't shown.
    var email: Bool?
    var shown: [String]
    var busy: [String]
    var copies: Copies

    init(choices: [CalendarChoice], copies: Copies, accounts: [String] = [], email: Bool? = nil) {
        calendar = accounts
        self.email = email
        shown = choices.filter(\.shown).map(\.title)
        busy = choices.filter(\.busy).map(\.title)
        self.copies = copies
    }

    var calendarLine: String { Self.line(calendar) }
    var emailLine: String? { email.map { $0 ? "On" : "Off" } }

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

// MARK: - Calendar and email in one consent

/// The calendar page brings in Calendar and, where the build has Email, Email too: one Google
/// screen for both (6 Nov 2026, the owner: "calendar + Email should be a single onboarding").
/// Whether Email then starts is the account's eligibility, which is known only after sign-in.
enum EmailSetup {
    #if BANANA_PUBLIC
    /// Stable has no Email, so it carries no Gmail scope (tools/check-release.sh refuses one).
    static let gmailScope = ""
    #else
    /// What Mail reads and acts with (`MailScopes.gmailModify`).
    static let gmailScope = "https://www.googleapis.com/auth/gmail.modify"
    #endif

    /// What the one consent asks for beyond the calendar's own scopes.
    static func extraScopes(inBuild: Bool, wanted: Bool) -> [String] {
        inBuild && wanted && !gmailScope.isEmpty ? [gmailScope] : []
    }

    enum Outcome: Equatable {
        case on
        case off(Reason)
    }

    enum Reason: Equatable {
        /// A build without Email (Stable): nothing about it is shown.
        case notInBuild
        /// Turned off on the calendar page.
        case notWanted
        /// Gmail unticked on Google's screen: Calendar alone, a success.
        case notGranted
        /// The account isn't offered Email. Never shown as an error.
        case notEligible
        /// Eligibility didn't arrive in time: Email stays off and stays offered in Settings.
        case eligibilityUnknown
    }

    /// `eligible`: nil while feature access hasn't loaded.
    static func outcome(inBuild: Bool, wanted: Bool, gmailGranted: Bool, eligible: Bool?) -> Outcome {
        guard inBuild else { return .off(.notInBuild) }
        guard wanted else { return .off(.notWanted) }
        guard gmailGranted else { return .off(.notGranted) }
        switch eligible {
        case true?: return .on
        case false?: return .off(.notEligible)
        case nil: return .off(.eligibilityUnknown)
        }
    }

    /// A Gmail grant that will not be used is handed back (the service forgets its Mail grant).
    /// Not while eligibility is unknown: the account may yet be offered Email.
    static func releasesGrant(_ outcome: Outcome, gmailGranted: Bool) -> Bool {
        gmailGranted && outcome == .off(.notEligible)
    }
}

/// How a "Continue with Google" ended, and what the page then says. Closing Google's page needs
/// no message; anything else stays on the page, with the button to try again, until it works.
enum ConnectAttempt: Equatable {
    case connected
    case cancelled
    case failed(String)

    var problem: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

// MARK: - Where the pictures sit

/// Each page's picture in the artwork's own pixels (1024 wide): the stretch of art its canvas
/// shows, Banana's frame, and the frames drawn after Banana. Since 7 Nov 2026 nothing is drawn
/// in front of Banana on any page (the owner: "the mascot has something over him"), so every
/// `drawnAbove` is empty and every scene draws Banana last; `FirstRunArtTests` holds both to
/// that, and keeps Banana inside its canvas, so the page's words and controls, laid out above and
/// below the canvas, can never cover him at any width or text size.
enum FirstRunArt {
    struct Scene: Equatable {
        let top: CGFloat
        let bottom: CGFloat
        let mascot: CGRect
        var drawnAbove: [CGRect] = []

        /// The part of Banana covered by what is drawn after him, in art pixels squared.
        var coveredArea: CGFloat {
            drawnAbove.reduce(0) { total, frame in
                let overlap = frame.intersection(mascot)
                return total + (overlap.isNull ? 0 : overlap.width * overlap.height)
            }
        }

        /// Banana stays within the canvas, so nothing outside the picture overlaps him.
        var mascotInsideCanvas: Bool {
            mascot.minX >= 0 && mascot.maxX <= 1024 && mascot.minY >= top && mascot.maxY <= bottom
        }
    }

    static func rect(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> CGRect {
        CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    static let welcome = Scene(top: 400, bottom: 990, mascot: rect(597, 490, 991, 950))
    static let modules = Scene(top: 270, bottom: 530, mascot: rect(800, 285, 1015, 510))
    static let wake = Scene(top: 790, bottom: 1200, mascot: rect(127, 810, 482, 1185))
    static let windDown = Scene(top: 760, bottom: 1240, mascot: rect(612, 820, 912, 1145))
    static let connect = Scene(top: 440, bottom: 1000, mascot: rect(733, 672, 1008, 985))
    static let calendars = Scene(top: 400, bottom: 960, mascot: rect(50, 620, 365, 945))
    static let copies = Scene(top: 230, bottom: 1000, mascot: rect(667, 240, 975, 525))
    static let done = Scene(top: 230, bottom: 880, mascot: rect(537, 449, 902, 821))

    static let all: [(String, Scene)] = [("welcome", welcome), ("modules", modules), ("wake", wake),
                                         ("windDown", windDown), ("connect", connect), ("calendars", calendars),
                                         ("copies", copies), ("done", done)]
}
