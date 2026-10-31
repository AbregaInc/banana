import Foundation

/// What Banana can be connected to, in the order the setup list shows it: the calendar that
/// fills the plan, then tasks and wake-ups, then the rest.
enum SetupItem: String, CaseIterable, Identifiable, Codable {
    case calendar, reminders, alarms, notifications, location, health, music

    var id: String { rawValue }

    /// The list for a device. Apple Health and the system's alarms are the phone's: an iPad and a
    /// Mac show what the phone reads, so they have nothing of their own to ask for.
    ///
    /// Apple Health only serves Workouts and sleep: with that module switched off it isn't asked
    /// for. Everything else is Plan's (music is what a wake-up plays) and stays.
    static func list(isHub: Bool, modules: ModuleChoice = .everything) -> [SetupItem] {
        let device = isHub ? allCases : allCases.filter { $0 != .health && $0 != .alarms }
        return device.filter { $0.module.map(modules.includes) ?? true }
    }

    /// The module an item serves, or nil for Plan's own.
    var module: AppModule? { self == .health ? .workouts : nil }
}

/// Where one item stands.
enum SetupState: Equatable {
    /// Never asked for. The only state that has a "Connect" button.
    case todo
    case done
    /// The system has said no and will not ask again: only its Settings can change that.
    case refused
    /// Asked, and the system won't say what was answered. Apple Health keeps what an app may
    /// read to itself, so after its sheet there is nothing Banana can know or ask again.
    case asked
}

/// The setup list: every item with its state, done ones included.
///
/// It replaced a card that listed three missing items at most, dropped the finished ones, only
/// appeared once a calendar was connected, and had a "Not now" that put it away for good with
/// no way back (review of 9 Oct 2026). The rules now:
///   - every item is always listed, in one order, ticked when done;
///   - the line above the plan is there while something has never been asked for, calendar or
///     no calendar, until the person hides it;
///   - hiding only hides the line: "Finish setup" stays in the plan's menu while anything is
///     still to do, and opens the same list.
struct SetupChecklist: Equatable {
    struct Row: Equatable, Identifiable {
        let item: SetupItem
        let state: SetupState
        var id: String { item.rawValue }
    }

    let rows: [Row]

    init(items: [SetupItem], state: (SetupItem) -> SetupState) {
        rows = items.map { Row(item: $0, state: state($0)) }
    }

    var total: Int { rows.count }
    var done: Int { rows.filter { $0.state == .done }.count }

    /// Something has never been asked for.
    var hasTodo: Bool { rows.contains { $0.state == .todo } }

    /// Whether anything but the calendar is still to do: the calendar card says so in its
    /// footer, since it stands where the line would.
    var hasTodoBesidesCalendar: Bool {
        rows.contains { $0.state == .todo && $0.item != .calendar }
    }

    func state(of item: SetupItem) -> SetupState? {
        rows.first { $0.item == item }?.state
    }

    /// "3 of 7 set up". Only what is really on counts: a refusal is not "set up", and neither
    /// is Health once asked, when Banana can't tell.
    var summary: String { "\(done) of \(total) set up" }

    /// The one line above the plan.
    func showsLine(hidden: Bool) -> Bool { hasTodo && !hidden }

    /// "Finish setup" in the plan's menu: the way back after hiding the line.
    var showsMenuItem: Bool { hasTodo }
}

/// What can be said about Apple Health.
enum HealthAccess {
    /// - Parameters:
    ///   - asked: Health's sheet has been shown on this device.
    ///   - hasData: something has been read from Health, which proves reading is allowed.
    ///   - canSave: Health says Banana may save workouts, the one answer it does give.
    ///
    /// It was "connected" as soon as the sheet had been shown, so tapping Don't Allow counted
    /// as a connection, on the setup card and in Settings ("Allowed").
    static func state(asked: Bool, hasData: Bool, canSave: Bool) -> SetupState {
        if hasData || canSave { return .done }
        return asked ? .asked : .todo
    }
}

/// Where Reminders stands. EventKit can go on reporting "not determined" after a no: seen in
/// the iOS 26 Simulator, where the system had recorded the refusal and would not ask again,
/// and the page went on offering "Connect Reminders", a button that then did nothing. Having
/// asked and not been allowed is therefore a refusal, whatever the status says.
enum RemindersAccess {
    enum Recorded { case notDetermined, refused, allowed }

    static func state(recorded: Recorded, askedAndNotAllowed: Bool) -> SetupState {
        switch recorded {
        case .allowed: .done
        case .refused: .refused
        case .notDetermined: askedAndNotAllowed ? .refused : .todo
        }
    }
}
