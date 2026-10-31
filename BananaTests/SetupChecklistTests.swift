import XCTest

/// The setup list's rules (`SetupChecklist`). The card it replaced showed three missing items,
/// dropped the finished ones, needed a calendar before it appeared at all, and its "Not now"
/// hid it for good.
final class SetupChecklistTests: XCTestCase {
    private func list(_ states: [SetupItem: SetupState], isHub: Bool = true) -> SetupChecklist {
        SetupChecklist(items: SetupItem.list(isHub: isHub)) { states[$0] ?? .todo }
    }

    func testEveryItemIsListedInOneOrderWhateverItsState() {
        let all = list([.calendar: .done, .notifications: .refused, .health: .asked])
        XCTAssertEqual(all.rows.map(\.item), [.calendar, .reminders, .alarms, .notifications, .location, .health, .music])
        XCTAssertEqual(all.state(of: .calendar), .done)        // a finished row keeps its place
        XCTAssertEqual(all.state(of: .notifications), .refused)
        XCTAssertEqual(all.total, 7)
    }

    func testHealthAndAlarmsAreThePhonesAlone() {
        XCTAssertEqual(SetupItem.list(isHub: false), [.calendar, .reminders, .notifications, .location, .music])
    }

    func testHealthIsLeftOutWithWorkoutsOff() {
        XCTAssertFalse(SetupItem.list(isHub: true, modules: .planOnly).contains(.health))
        XCTAssertTrue(SetupItem.list(isHub: true, modules: .only(["workouts"])).contains(.health))
        XCTAssertEqual(SetupItem.list(isHub: true, modules: .everything), SetupItem.allCases)
    }

    func testOnlyWhatIsReallyOnCountsAsSetUp() {
        // A refusal isn't "set up", and neither is Health once asked, when Banana can't tell.
        let some = list([.calendar: .done, .reminders: .done, .notifications: .refused, .health: .asked])
        XCTAssertEqual(some.done, 2)
        XCTAssertEqual(some.summary, "2 of 7 set up")
    }

    func testTheLineIsThereWithNoCalendarAtAll() {
        // It used to wait for a calendar: skip the calendar and there was no setup anywhere.
        let fresh = list([:])
        XCTAssertTrue(fresh.showsLine(hidden: false))
        XCTAssertTrue(fresh.hasTodoBesidesCalendar)
    }

    func testHidingTheLineLeavesTheWayBackInTheMenu() {
        let fresh = list([.calendar: .done])
        XCTAssertFalse(fresh.showsLine(hidden: true))
        XCTAssertTrue(fresh.showsMenuItem, "hidden meant gone for good")
    }

    func testNothingLeftToAskForMeansNoLineAndNoMenuItem() {
        // Refused and asked rows can't be asked for again: they don't keep the line alive.
        let settled = SetupChecklist(items: SetupItem.list(isHub: true)) { item in
            switch item {
            case .notifications: .refused
            case .health: .asked
            default: .done
            }
        }
        XCTAssertFalse(settled.hasTodo)
        XCTAssertFalse(settled.showsLine(hidden: false))
        XCTAssertFalse(settled.showsMenuItem)
        XCTAssertEqual(settled.summary, "5 of 7 set up")
    }

    func testTheCalendarCardOnlyPointsAtTheRestWhenThereIsARest() {
        XCTAssertFalse(list([.reminders: .done, .alarms: .done, .notifications: .done, .location: .done,
                             .health: .done, .music: .done]).hasTodoBesidesCalendar)
        XCTAssertTrue(list([.reminders: .done]).hasTodoBesidesCalendar)
    }

    // MARK: - Apple Health

    func testHealthIsNotConnectedJustBecauseItsSheetWasShown() {
        // Don't Allow counted as a connection: 3 of 6 became 4 of 6, and Settings said "Allowed".
        XCTAssertEqual(HealthAccess.state(asked: true, hasData: false, canSave: false), .asked)
    }

    func testHealthIsConnectedOnceSomethingProvesIt() {
        XCTAssertEqual(HealthAccess.state(asked: true, hasData: true, canSave: false), .done)
        XCTAssertEqual(HealthAccess.state(asked: true, hasData: false, canSave: true), .done)
    }

    func testHealthNeverAskedIsStillToDo() {
        XCTAssertEqual(HealthAccess.state(asked: false, hasData: false, canSave: false), .todo)
    }

    // MARK: - Reminders

    func testARemindersNoIsARefusalEvenWhenTheSystemStillSaysUndetermined() {
        // In the iOS 26 Simulator the system recorded the no and would not ask again, while
        // EventKit went on saying "not determined": the page offered "Connect Reminders" forever.
        XCTAssertEqual(RemindersAccess.state(recorded: .notDetermined, askedAndNotAllowed: true), .refused)
        XCTAssertEqual(RemindersAccess.state(recorded: .notDetermined, askedAndNotAllowed: false), .todo)
    }

    func testWhatTheSystemRecordsForRemindersStillWins() {
        XCTAssertEqual(RemindersAccess.state(recorded: .refused, askedAndNotAllowed: false), .refused)
        // Allowed later in Settings: the old no is forgotten.
        XCTAssertEqual(RemindersAccess.state(recorded: .allowed, askedAndNotAllowed: true), .done)
    }
}
