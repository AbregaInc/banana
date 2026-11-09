import XCTest

/// What needs attention must not rebuild the plan grid (docs/performance/ui-performance-contract.md):
/// the grid observes only the attention count (`PlanAttention`), which publishes only when it
/// changes. Counts the plan's renders (`day.performance.renderCount`) while the attention clock
/// ticks with nothing changing, and prints them for the record.
final class PlanAttentionRenderUITest: XCTestCase {
    func testTheAttentionClockDoesNotRedrawThePlan() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--plan", "-planMode", "day", "--modules", "everything",
                               "--custom-routine-completion-preview", "--reset-routine-completion",
                               "--calendar-move-render-probe", "--disable-icloud", "--no-space-sync",
                               "-onboardingCompleted", "YES", "-finishSetupDismissed", "YES"]
        app.withoutSpaceSync()
        app.launch()
        let probe = app.descendants(matching: .any)["day.performance.renderCount"]
        XCTAssertTrue(probe.waitForExistence(timeout: 25), app.debugDescription)
        func renders() -> Int { Int(probe.value as? String ?? "") ?? -1 }
        // Settle: launch-time publishes finish.
        var last = renders()
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 1)   // the subject is a quiet stretch of time
            let now = renders()
            if now == last { break }
            last = now
        }
        let start = renders()
        // Past two of the attention clock's minute ticks, touching nothing.
        Thread.sleep(forTimeInterval: 130)
        let idle = renders() - start
        print("PLAN-ATTENTION-RENDERS idle130s=\(idle) start=\(start)")
        XCTAssertLessThanOrEqual(idle, 2, "the plan redrew \(idle) times in a quiet two minutes")
    }
}
