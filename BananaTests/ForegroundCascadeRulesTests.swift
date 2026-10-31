import SwiftUI
import XCTest

/// A glance at Control Center is not a return from the background.
///
/// `inactive → active` is what the shade, Control Center, a permission alert and the app switcher
/// all go through, and each one used to run the whole return-to-foreground cascade: four or more
/// CloudKit round trips, a Google refresh, a feed sweep. What must hold is both halves of the
/// split — the network half waits for a real return, and the permission half never does, because
/// a permission alert is the one glance that changes something the app has to notice.
final class ForegroundCascadeRulesTests: XCTestCase {

    /// A rules value that has already run its first activation, the way an app that has been open
    /// for a while is.
    private func settled() -> ForegroundCascadeRules {
        var rules = ForegroundCascadeRules()
        _ = rules.phaseChanged(from: .inactive, to: .active)
        return rules
    }

    // MARK: - Launch

    /// First launch must behave exactly as before the split: everything runs.
    func testTheFirstActivationOfAProcessRunsEverything() {
        var rules = ForegroundCascadeRules()
        let plan = rules.phaseChanged(from: .inactive, to: .active)
        XCTAssertEqual(plan, .fullReturn)
        XCTAssertTrue(plan.runsNetworkAndSync)
        XCTAssertTrue(plan.rereadsPermissions)
    }

    func testAProcessLaunchedInTheBackgroundStillRunsEverythingWhenFirstShown() {
        var rules = ForegroundCascadeRules()
        _ = rules.phaseChanged(from: .inactive, to: .background)
        XCTAssertEqual(rules.phaseChanged(from: .background, to: .active), .fullReturn)
    }

    // MARK: - Glances

    func testAGlanceReReadsPermissionsButLeavesTheNetworkAlone() {
        var rules = settled()
        _ = rules.phaseChanged(from: .active, to: .inactive)   // Control Center pulled down
        let plan = rules.phaseChanged(from: .inactive, to: .active)
        XCTAssertEqual(plan, .glance)
        XCTAssertFalse(plan.runsNetworkAndSync, "Control Center must not spend CloudKit")
        XCTAssertTrue(plan.rereadsPermissions,
                      "a permission alert returns through inactive → active; the grant must be noticed")
    }

    func testEveryGlanceInARowIsStillAGlance() {
        var rules = settled()
        for _ in 0..<5 {
            _ = rules.phaseChanged(from: .active, to: .inactive)
            XCTAssertEqual(rules.phaseChanged(from: .inactive, to: .active), .glance)
        }
    }

    func testLeavingTheForegroundForAGlanceDoesNotCountAsLeavingTheApp() {
        var rules = settled()
        XCTAssertEqual(rules.phaseChanged(from: .active, to: .inactive), .none)
        XCTAssertFalse(rules.cameFromBackground)
    }

    // MARK: - Real returns

    func testReturningFromTheBackgroundRunsEverything() {
        var rules = settled()
        _ = rules.phaseChanged(from: .active, to: .inactive)
        _ = rules.phaseChanged(from: .inactive, to: .background)
        _ = rules.phaseChanged(from: .background, to: .inactive)   // the usual road back
        let plan = rules.phaseChanged(from: .inactive, to: .active)
        XCTAssertEqual(plan, .fullReturn)
        XCTAssertTrue(plan.runsNetworkAndSync)
        XCTAssertTrue(plan.rereadsPermissions)
    }

    /// The `inactive` step on the way back must not forget where the app came from.
    func testTheInactiveStepOnTheWayBackDoesNotForgetTheBackground() {
        var rules = settled()
        _ = rules.phaseChanged(from: .inactive, to: .background)
        XCTAssertTrue(rules.cameFromBackground)
        _ = rules.phaseChanged(from: .background, to: .inactive)
        XCTAssertTrue(rules.cameFromBackground)
    }

    func testAGlanceAfterARealReturnIsAGlanceAgain() {
        var rules = settled()
        _ = rules.phaseChanged(from: .inactive, to: .background)
        XCTAssertEqual(rules.phaseChanged(from: .inactive, to: .active), .fullReturn)
        _ = rules.phaseChanged(from: .active, to: .inactive)
        XCTAssertEqual(rules.phaseChanged(from: .inactive, to: .active), .glance,
                       "the return is paid for once, not on every activation after it")
    }

    func testEveryBackgroundTripIsItsOwnReturn() {
        var rules = settled()
        for _ in 0..<3 {
            _ = rules.phaseChanged(from: .inactive, to: .background)
            XCTAssertEqual(rules.phaseChanged(from: .inactive, to: .active), .fullReturn)
        }
    }

    /// If a `.background` change were ever coalesced away, coming back from it must still be
    /// taken for what it is.
    func testComingStraightFromTheBackgroundIsAReturnEvenIfTheDepartureWasNotSeen() {
        var rules = settled()
        XCTAssertEqual(rules.phaseChanged(from: .background, to: .active), .fullReturn)
    }

    // MARK: - Non-activations

    func testOnlyAnActivationRunsAnything() {
        var rules = settled()
        let inactive = rules.phaseChanged(from: .active, to: .inactive)
        let background = rules.phaseChanged(from: .inactive, to: .background)
        XCTAssertEqual(inactive, .none)
        XCTAssertEqual(background, .background)
        for plan in [inactive, background] {
            XCTAssertFalse(plan.rereadsPermissions)
            XCTAssertFalse(plan.runsNetworkAndSync)
        }
    }

    // MARK: - The change poll

    /// A backgrounded audio app keeps its process alive for hours; the Google change poll used to
    /// wake it every two minutes to skip its own work. Starting it again is not the rule's to say:
    /// the app resumes it on every activation, and `CalendarChangePollTests` covers that.
    func testTheBackgroundStopsThePollAndNothingElseDoes() {
        var rules = settled()
        XCTAssertFalse(rules.phaseChanged(from: .active, to: .inactive).stopsPolling,
                       "a glance is still on screen")
        XCTAssertTrue(rules.phaseChanged(from: .inactive, to: .background).stopsPolling)
        XCTAssertFalse(rules.phaseChanged(from: .background, to: .inactive).stopsPolling)
        XCTAssertFalse(rules.phaseChanged(from: .inactive, to: .active).stopsPolling)
        XCTAssertFalse(rules.phaseChanged(from: .active, to: .inactive).stopsPolling)
    }

    func testEveryBackgroundTripStopsThePoll() {
        var rules = ForegroundCascadeRules()
        _ = rules.phaseChanged(from: .inactive, to: .active)
        for _ in 0..<3 {
            XCTAssertTrue(rules.phaseChanged(from: .active, to: .background).stopsPolling)
            _ = rules.phaseChanged(from: .background, to: .active)
        }
    }
}
