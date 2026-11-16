import XCTest

@MainActor
final class PermissionUpgradeTests: XCTestCase {
    private let account = "noor@plan.example"
    private let requirement = PermissionRequirement(id: "contacts", title: "Contacts", scopes: ["read-contacts", "read-other-contacts"])
    private func needs(granted: [String]? = []) -> [PermissionUpgradeNeed] {
        PermissionUpgradePolicy.missing(provider: "provider", account: account, granted: granted, requirements: [requirement])
    }
    private func model() -> PermissionUpgradePromptModel {
        let name = "PermissionUpgradeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return PermissionUpgradePromptModel(defaults: defaults)
    }

    func testUnknownMetadataDoesNotAssumeMissingAccess() {
        XCTAssertTrue(needs(granted: nil).isEmpty)
        XCTAssertTrue(needs(granted: ["read-contacts", "read-other-contacts"]).isEmpty)
        XCTAssertEqual(needs(granted: ["read-contacts"])[0].missing, ["read-other-contacts"])
    }

    func testDeferredRequirementSurvivesPartialGrantButNewRequirementsPrompt() {
        let prompt = model()
        prompt.offer(needs())
        prompt.deferUpgrade(prompt.presentation!)
        prompt.offer(needs(granted: ["read-contacts"]))
        XCTAssertNil(prompt.presentation)
        var expanded = requirement
        expanded.scopes.insert("new-permission")
        prompt.offer(PermissionUpgradePolicy.missing(provider: "provider", account: account, granted: [], requirements: [expanded]))
        XCTAssertNotNil(prompt.presentation)
    }

    func testDeferringOneAccountDoesNotSuppressAnother() {
        let prompt = model()
        prompt.offer(needs())
        prompt.deferUpgrade(prompt.presentation!)
        prompt.offer(PermissionUpgradePolicy.missing(provider: "provider", account: "team@plan.example", granted: [], requirements: [requirement]))
        XCTAssertEqual(prompt.presentation?.needs.first?.account, "team@plan.example")
    }

    func testFailedUpgradeRemainsRetryableAndSuccessDoesNotPromptAgain() async {
        let prompt = model(); prompt.offer(needs())
        await prompt.update(prompt.presentation!) { _ in .failed }
        XCTAssertEqual(prompt.presentation?.retry, true)
        await prompt.update(prompt.presentation!) { _ in .updated }
        XCTAssertNil(prompt.presentation)
    }

    func testCancelledUpgradeDefersWithoutClaimingNewGrants() async {
        let prompt = model(); prompt.offer(needs())
        await prompt.update(prompt.presentation!) { _ in .cancelled }
        prompt.offer(needs())
        XCTAssertNil(prompt.presentation)
    }

    func testQueuedUpgradeDoesNotReopenBeforeNativeDismissalCompletes() async {
        let prompt = model(); prompt.offer(needs())
        XCTAssertTrue(prompt.queue(prompt.presentation!))
        prompt.offer(needs())
        XCTAssertTrue(prompt.updating)
        XCTAssertNil(prompt.presentation)
        var called = false
        await prompt.completeDismissal { _ in called = true; return .updated }
        XCTAssertTrue(called)
        XCTAssertFalse(prompt.updating)
    }

    func testRemovedAccountIsNotReconnectedFromAStalePrompt() async {
        let prompt = model(); prompt.offer(needs())
        let presented = prompt.presentation!
        prompt.offer([])
        var called = false
        await prompt.update(presented) { _ in called = true; return .updated }
        XCTAssertFalse(called)
    }
}
