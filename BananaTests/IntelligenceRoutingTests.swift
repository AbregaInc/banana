import XCTest

/// The iOS 27 routing rule, exercised on a machine that has neither model.
///
/// This is deliberately the whole testable surface of the iOS 27 work. The models themselves
/// cannot run here — the cloud model needs a macOS 27 host and the device is on iOS 26 — so the
/// decision is a pure function of a snapshotted availability value, and every branch of it is
/// pinned here. What stays unverified until the OS lands is whether the models behave as Apple
/// documents; what is verified is that this app asks the right one and degrades correctly.
final class IntelligenceRoutingTests: XCTestCase {
    private typealias A = Intelligence.Availability

    private let everything = A(deviceAvailable: true, deviceSupportsVision: true,
                               cloudAvailable: true, cloudQuotaReached: false)
    private let quotaGone = A(deviceAvailable: true, deviceSupportsVision: true,
                              cloudAvailable: true, cloudQuotaReached: true)

    // MARK: - Spending the quota where it matters

    func testKnowledgeGoesToTheCloudModelWhenThereIsOne() {
        XCTAssertEqual(Intelligence.route(.knowledge, given: everything), .cloud)
    }

    /// The point of the whole file: splitting a phrase is mechanical, and quota spent on it is
    /// quota missing from the nutrition estimate that actually needed the better model.
    func testStructuringStaysOnDeviceEvenWithTheCloudModelSittingRightThere() {
        XCTAssertEqual(Intelligence.route(.structuring, given: everything), .device)
    }

    func testStructuringUsesTheCloudOnlyWhenThereIsNoDeviceModelAtAll() {
        let cloudOnly = A(deviceAvailable: false, cloudAvailable: true)
        XCTAssertEqual(Intelligence.route(.structuring, given: cloudOnly), .cloud)
    }

    // MARK: - Degrading

    /// iOS 26 today. Every route must land exactly where it lands now, or adopting iOS 27 support
    /// would have changed the behaviour of a device that never sees iOS 27.
    func testOnIOS26EverythingRoutesToTheDeviceExceptVision() {
        XCTAssertEqual(Intelligence.route(.knowledge, given: .deviceOnly), .device)
        XCTAssertEqual(Intelligence.route(.structuring, given: .deviceOnly), .device)
        XCTAssertEqual(Intelligence.route(.vision, given: .deviceOnly), .none,
                       "an iOS 26 on-device model cannot take an image; the caller falls back to Vision OCR")
    }

    func testAnExhaustedQuotaFallsBackToTheDeviceRatherThanFailing() {
        XCTAssertEqual(Intelligence.route(.knowledge, given: quotaGone), .device)
        XCTAssertEqual(Intelligence.route(.structuring, given: quotaGone), .device)
    }

    func testWithNoModelsAtAllEveryNeedIsUnservable() {
        for need: Intelligence.Need in [.structuring, .knowledge, .vision] {
            XCTAssertEqual(Intelligence.route(need, given: .nothing), .none)
        }
    }

    // MARK: - Vision is a capability gate, not a preference

    func testVisionFallsToTheDeviceOnlyWhenTheDeviceModelCanActuallySee() {
        let seeingDevice = A(deviceAvailable: true, deviceSupportsVision: true,
                             cloudAvailable: true, cloudQuotaReached: true)
        XCTAssertEqual(Intelligence.route(.vision, given: seeingDevice), .device)

        let blindDevice = A(deviceAvailable: true, deviceSupportsVision: false,
                            cloudAvailable: true, cloudQuotaReached: true)
        XCTAssertEqual(Intelligence.route(.vision, given: blindDevice), .none,
                       "no tier can serve an image to a model without vision")
    }

    // MARK: - Budgets

    func testABiggerWindowBuysAProportionallyBiggerPrompt() {
        let device = Intelligence.promptCharacterBudget(forContextTokens: 4_096)
        let cloud = Intelligence.promptCharacterBudget(forContextTokens: 32_768)
        XCTAssertGreaterThan(cloud, device * 7, "a 32K window is 8x a 4K one; the budget should track it")
        XCTAssertEqual(Intelligence.promptCharacterBudget(for: .none), 0)
    }

    /// The old hand-guessed constant was 4,000 characters against an assumed 4,096-token window,
    /// which left nothing for instructions, schema and the answer — all of which share it. Half
    /// the window, at ~3.5 chars a token, is ~7,100 characters; the old number was eating the lot.
    func testTheDeviceBudgetLeavesHalfTheWindowForEverythingElse() {
        let budget = Intelligence.promptCharacterBudget(forContextTokens: 4_096)
        XCTAssertEqual(budget, 7_168)
        XCTAssertLessThan(budget, 4_096 * 4, "must not exceed what the window can hold at all")
    }

    /// A model that reports a tiny window must still get a usable floor rather than a budget of
    /// nothing, which would silently turn every prompt into an empty string.
    func testATinyReportedWindowStillYieldsAUsableFloor() {
        XCTAssertEqual(Intelligence.promptCharacterBudget(forContextTokens: 0), 1_000)
        XCTAssertEqual(Intelligence.promptCharacterBudget(forContextTokens: 128), 1_000)
    }

    // MARK: - Not promising privacy the routing does not deliver

    /// The screens that say this are the food-entry sheet and the supplement label reader. On
    /// iOS 26 the claim is true. Routing a request to Private Cloud Compute makes it false, and a
    /// privacy promise that quietly stops holding is worse than one never made.
    func testTheOnDeviceOnlyPromiseIsOnlyMadeWhenItIsTrue() {
        XCTAssertEqual(Intelligence.privacyNote(for: .deviceOnly, device: "iPhone"), "Nothing leaves this iPhone.")
        XCTAssertEqual(Intelligence.privacyNote(for: .nothing, device: "iPhone"), "Nothing leaves this iPhone.")

        let note = Intelligence.privacyNote(for: everything)
        XCTAssertFalse(note.contains("Nothing leaves"), "the cloud model is reached over the network")
        XCTAssertTrue(note.contains("Private Cloud Compute"), "say where it actually goes")
    }

    /// An exhausted quota means everything runs locally again — so the stricter promise becomes
    /// true again, and should be made again.
    func testTheStricterPromiseReturnsWhenTheQuotaIsGone() {
        XCTAssertEqual(Intelligence.privacyNote(for: quotaGone, device: "iPhone"), "Nothing leaves this iPhone.")
    }

    func testTheSpinnerSaysWhichModelIsWorking() {
        XCTAssertTrue(Intelligence.progressNote(for: .device, device: "iPhone").contains("this iPhone"))
        XCTAssertFalse(Intelligence.progressNote(for: .cloud, device: "iPhone").contains("this iPhone"))
    }
}

final class CloudModelGuardTests: XCTestCase {
    func testTheCloudModelNeedsItsEntitlementFlag() {
        XCTAssertTrue(CloudModelGuard.isEntitled(flag: true))
        XCTAssertFalse(CloudModelGuard.isEntitled(flag: false))
        XCTAssertFalse(CloudModelGuard.isEntitled(flag: nil), "no flag: built without the entitlement")
        XCTAssertFalse(CloudModelGuard.isEntitled(flag: "YES"), "only a real Boolean")
    }

    func testWithoutTheCloudModelEverythingRoutesToTheDevice() {
        // What `Intelligence.current` reports without the entitlement: no cloud model.
        let availability = Intelligence.Availability(deviceAvailable: true, deviceSupportsVision: true,
                                                     cloudAvailable: false)
        XCTAssertEqual(Intelligence.route(.knowledge, given: availability), .device)
        XCTAssertEqual(Intelligence.route(.vision, given: availability), .device)
    }

    func testTheNoteNamesTheDeviceItIsOn() {
        // It said "this iPhone" on an iPad and on the Mac.
        XCTAssertEqual(Intelligence.privacyNote(for: .deviceOnly, device: "Mac"), "Nothing leaves this Mac.")
        XCTAssertTrue(Intelligence.progressNote(for: .device, device: "iPad").hasSuffix("on this iPad…"))
    }
}
