import XCTest

/// How fast local work may run (MAIL-ENGINE 4.12, invariant 31), one test per row of the table.
///
/// The failure this guards is a phone that is warm in a pocket because mail is preparing a
/// backlog at full speed, or — the opposite — a Mac on mains that crawls at a fifth of a core
/// for no reason. Every cell of the table is a plain fact about the device, so each is checked
/// directly; there is nothing to wait for and nothing to measure.
final class MailWorkPaceTests: XCTestCase {

    private let fifth = MailWorkPace.paced(share: 0.2)

    /// A device, described by what is true of it. Everything defaults to the calm case.
    private func pace(_ role: MailDeviceRole,
                      onMains: Bool = false,
                      lowPower: Bool = false,
                      hot: Bool = false,
                      overnight: Bool = false,
                      mailVisible: Bool = true,
                      appActive: Bool = true) -> MailWorkPace {
        MailWorkPace.current(
            role: role,
            power: MailPower(onMains: onMains, lowPowerMode: lowPower, thermalFairOrWorse: hot),
            insideOvernightTask: overnight, mailVisible: mailVisible, appActive: appActive)
    }

    // MARK: - Row 1: full

    func testInsideTheOvernightTaskAPhoneRunsFull() {
        // The task runs with the app in the background and Mail not on screen, which is exactly
        // when a phone would otherwise do nothing.
        XCTAssertEqual(pace(.phone, onMains: true, overnight: true, mailVisible: false, appActive: false), .full)
        XCTAssertEqual(pace(.pad, onMains: true, overnight: true, mailVisible: false, appActive: false), .full)
    }

    func testInsideTheOvernightTaskItRunsFullOnBatteryToo() {
        XCTAssertEqual(pace(.phone, onMains: false, overnight: true, mailVisible: false, appActive: false), .full)
    }

    func testAMacOnMainsRunsFull() {
        XCTAssertEqual(pace(.mac, onMains: true), .full)
        // Whatever it is showing: Mail on screen or not, the app in front or not.
        XCTAssertEqual(pace(.mac, onMains: true, mailVisible: false, appActive: false), .full)
    }

    // MARK: - Row 2: a fifth of a core

    func testAMacOnBatteryRunsAtAFifthOfACore() {
        XCTAssertEqual(pace(.mac, onMains: false), fifth)
        XCTAssertEqual(pace(.mac, onMains: false, mailVisible: false, appActive: false), fifth)
    }

    func testAPhoneOrPadWithMailOnScreenRunsAtAFifthOfACore() {
        for role in [MailDeviceRole.phone, .pad] {
            XCTAssertEqual(pace(role, onMains: false), fifth, "\(role) on battery")
            XCTAssertEqual(pace(role, onMains: true), fifth, "\(role) charging: only a Mac on mains runs full")
        }
    }

    // MARK: - Row 3: stopped

    func testAWarmDeviceDoesNoLocalWork() {
        for role in [MailDeviceRole.phone, .pad, .mac] {
            XCTAssertEqual(pace(role, onMains: true, hot: true), .stopped, "\(role) on mains")
            XCTAssertEqual(pace(role, onMains: false, hot: true), .stopped, "\(role) on battery")
        }
    }

    func testLowPowerModeDoesNoLocalWork() {
        for role in [MailDeviceRole.phone, .pad, .mac] {
            XCTAssertEqual(pace(role, onMains: true, lowPower: true), .stopped, "\(role) on mains")
            XCTAssertEqual(pace(role, onMains: false, lowPower: true), .stopped, "\(role) on battery")
        }
    }

    func testAPhoneOrPadWithMailNotOnScreenDoesNoLocalWork() {
        for role in [MailDeviceRole.phone, .pad] {
            XCTAssertEqual(pace(role, mailVisible: false), .stopped, "\(role)")
            XCTAssertEqual(pace(role, onMains: true, mailVisible: false), .stopped, "\(role) charging")
        }
    }

    func testAPhoneOrPadWhoseAppIsNotActiveDoesNoLocalWork() {
        for role in [MailDeviceRole.phone, .pad] {
            XCTAssertEqual(pace(role, appActive: false), .stopped, "\(role)")
            // Mail was on screen when it went to the background; it is still not running.
            XCTAssertEqual(pace(role, mailVisible: true, appActive: false), .stopped)
        }
    }

    func testAMacIsNotStoppedByAnInactiveAppOrMailBeingOffScreen() {
        // Those two rows are for iOS: a Mac keeps working behind other windows.
        XCTAssertNotEqual(pace(.mac, mailVisible: false, appActive: false), .stopped)
        XCTAssertNotEqual(pace(.mac, onMains: true, mailVisible: false, appActive: false), .stopped)
    }

    // MARK: - Where two rows meet

    func testInvariant31StopsTheOvernightTaskToo_WhenTheDeviceIsWarmOrInLowPowerMode() {
        // A task can be both inside the overnight task and warm. The first row of the table that
        // applies decides, and the warm row is the first: invariant 31 says "not at all when the
        // device is warm or in Low Power Mode", with no exception (4.12; ruled as built).
        XCTAssertEqual(pace(.phone, onMains: true, hot: true, overnight: true, mailVisible: false, appActive: false), .stopped)
        XCTAssertEqual(pace(.phone, onMains: true, lowPower: true, overnight: true, mailVisible: false, appActive: false), .stopped)
    }

    // MARK: - The pause that makes a pace

    func testAPacedPassSleepsFourTimesAsLongAsItWorked() {
        XCTAssertEqual(try XCTUnwrap(fifth.pause(afterWorking: 0.05)), 0.2, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(fifth.pause(afterWorking: 0.01)), 0.04, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(fifth.pause(afterWorking: 0)), 0, accuracy: 1e-9)
    }

    func testThePauseLeavesWorkAsTheShareOfTheTimeElapsed() {
        for share in [0.1, 0.2, 0.25, 0.5] {
            let work = 0.05
            let pause = MailWorkPace.paced(share: share).pause(afterWorking: work)
            XCTAssertEqual(work / (work + (pause ?? 0)), share, accuracy: 1e-9, "share \(share)")
        }
    }

    func testAFullPassNeverPausesAndAStoppedOneDoesNoWork() {
        XCTAssertEqual(MailWorkPace.full.pause(afterWorking: 10), 0)
        XCTAssertNil(MailWorkPace.stopped.pause(afterWorking: 0.05))
    }

    func testAPaceThatIsNotASensibleShareIsReadSafely() {
        XCTAssertNil(MailWorkPace.paced(share: 0).pause(afterWorking: 0.05), "a share of nothing does no work")
        XCTAssertNil(MailWorkPace.paced(share: -1).pause(afterWorking: 0.05))
        XCTAssertEqual(MailWorkPace.paced(share: 1).pause(afterWorking: 0.05), 0)
        XCTAssertEqual(MailWorkPace.paced(share: 2).pause(afterWorking: 0.05), 0)
    }

    // MARK: - The numbers are the document's

    func testTheNumbersOf4_12AreTheDocuments() {
        // 4.2 and 4.12. A change to any of them is a design decision, so it fails here.
        XCTAssertEqual(MailKnobs.syncBatchMessages, 20)
        XCTAssertEqual(MailKnobs.groupCommitChanges, 50)
        XCTAssertEqual(MailKnobs.checkpointOverBytes, 8 * 1_048_576)
        XCTAssertEqual(MailKnobs.backgroundReadRows, 500)
        XCTAssertEqual(MailKnobs.indexerBatchMessages, 50)
        XCTAssertEqual(MailKnobs.deliveryDebounce, 1.5)
        XCTAssertEqual(MailKnobs.deliveryDebounceCeiling, 5)
        XCTAssertEqual(MailKnobs.pollInterval, 60)
        XCTAssertEqual(MailKnobs.verifyBatchMessages, 50)
        XCTAssertEqual(MailKnobs.maxInFlight, 4)
        XCTAssertEqual(MailKnobs.pacedShare, 0.2)
        XCTAssertEqual(MailKnobs.pacedPiece, 0.050)
    }
}
