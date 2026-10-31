import XCTest
import HealthKit

@MainActor
final class HealthAuthorizationTests: XCTestCase {
    func testBlockedHealthServiceLeavesTheMainActorAvailable() async {
        let began = expectation(description: "permission read started")
        let release = DispatchSemaphore(value: 0)
        let reading = Task { @MainActor in
            await HealthAuthorization.read {
                began.fulfill()
                let offMain = !Thread.isMainThread
                // Bound the fake service wait even if a regression blocks this test's actor.
                let released = release.wait(timeout: .now() + 2) == .success
                return offMain && released
            }
        }
        await fulfillment(of: [began], timeout: 1)
        // Only this actor can release the service; reaching here proves it stayed available.
        release.signal()
        let completedOffMain = await reading.value
        XCTAssertTrue(completedOffMain)
    }

    func testPermissionAnswerIsPreserved() async {
        for answer in [HKAuthorizationStatus.notDetermined, .sharingDenied, .sharingAuthorized] {
            let read = await HealthAuthorization.read { answer }
            XCTAssertEqual(read, answer)
        }
    }
}
