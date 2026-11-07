import XCTest

/// The navigation layer's decisions (docs/design/BOTTOM-BAR-SHELL.md): which pages the switcher
/// and the rail list, what the field shows, and where the podcast player sits.
final class ShellRulesTests: XCTestCase {
    func testOnlyTheModulesThatAreOnAreListedWithSettingsLast() {
        XCTAssertEqual(ShellPage.listed(.init()), [.plan, .settings])
        var on = ShellPage.Modules(mail: true, workouts: true, food: false, notes: true, library: true, review: true)
        XCTAssertEqual(ShellPage.listed(on), [.plan, .mail, .body, .notes, .library, .review, .settings])
        on.workouts = false
        XCTAssertEqual(ShellPage.listed(on), [.plan, .mail, .notes, .library, .review, .settings],
                       "Body goes with both of its pages switched off")
        on.food = true
        XCTAssertTrue(ShellPage.listed(on).contains(.body), "Food alone keeps Body")
    }

    func testReviewAndSettingsOpenOverThePage() {
        XCTAssertEqual(ShellPage.allCases.filter(\.opensOver), [.review, .settings])
    }

    func testTheFieldShowsAddWhenFocusedAndEmptyAndResultsOnceThereAreWords() {
        XCTAssertEqual(ShellFieldMode.of(text: "", focused: false), .idle)
        XCTAssertEqual(ShellFieldMode.of(text: "  ", focused: true), .add)
        XCTAssertEqual(ShellFieldMode.of(text: "lunch", focused: true), .results)
        XCTAssertEqual(ShellFieldMode.of(text: "lunch", focused: false), .results,
                       "putting the keyboard away keeps what was found on screen")
        XCTAssertFalse(ShellFieldMode.idle.hidesSideButtons)
        XCTAssertTrue(ShellFieldMode.add.hidesSideButtons)
        XCTAssertTrue(ShellFieldMode.results.hidesSideButtons)
    }

    func testSearchesWaitForTwoCharacters() {
        XCTAssertNil(ShellSearchRules.query(""))
        XCTAssertNil(ShellSearchRules.query(" l "))
        XCTAssertEqual(ShellSearchRules.query("  lu "), "lu")
    }

    func testAPlanTitleMatchesWhenEveryWordStartsOneOfItsWords() {
        XCTAssertTrue(ShellSearchRules.titleMatches("Lunch with Sam", query: "lunch sam"))
        XCTAssertTrue(ShellSearchRules.titleMatches("Lunch with Sam", query: "LUN"))
        XCTAssertTrue(ShellSearchRules.titleMatches("Café review", query: "cafe"))
        XCTAssertFalse(ShellSearchRules.titleMatches("Lunch with Sam", query: "unch"))
        XCTAssertFalse(ShellSearchRules.titleMatches("Lunch with Sam", query: "lunch tom"))
        XCTAssertFalse(ShellSearchRules.titleMatches("Lunch", query: ""))
    }

    func testThePlayerSitsAboveTheBarFoldsIntoTheFieldAndGivesWayToTyping() {
        XCTAssertEqual(ShellPlayerPlacement.of(loaded: false, hidden: false, fieldInUse: false), .none)
        XCTAssertEqual(ShellPlayerPlacement.of(loaded: true, hidden: false, fieldInUse: false), .capsule)
        XCTAssertEqual(ShellPlayerPlacement.of(loaded: true, hidden: true, fieldInUse: false), .chip)
        XCTAssertEqual(ShellPlayerPlacement.of(loaded: true, hidden: false, fieldInUse: true), .none)
    }

    func testANewEpisodeShowsTheCapsuleAgain() {
        XCTAssertTrue(ShellPlayerPlacement.hiddenAfterLoad(previous: "a", current: "a", hidden: true))
        XCTAssertFalse(ShellPlayerPlacement.hiddenAfterLoad(previous: "a", current: "b", hidden: true))
        XCTAssertFalse(ShellPlayerPlacement.hiddenAfterLoad(previous: "a", current: "a", hidden: false))
        XCTAssertTrue(ShellPlayerPlacement.hiddenAfterLoad(previous: nil, current: "a", hidden: true),
                      "the first episode seen keeps what is set")
    }

    func testResultGroupsKeepTheFieldsOrderAndSkipEmptyOnes() {
        struct Hit: Identifiable { let id: String }
        var groups = ShellSearchGroups<Hit>()
        XCTAssertTrue(groups.isEmpty)
        groups.notes = [Hit(id: "n")]
        groups.plan = [Hit(id: "p")]
        XCTAssertEqual(groups.nonEmpty, [.plan, .notes])
        XCTAssertEqual(groups.items(.plan).map(\.id), ["p"])
    }

    func testTheRailIsForALandscapeIPadsRoomAndEverythingNarrowerHasTheBar() {
        XCTAssertEqual(ShellLayout.of(width: 402), .bottomBar, "a phone")
        XCTAssertEqual(ShellLayout.of(width: 956), .bottomBar, "a phone on its side")
        XCTAssertEqual(ShellLayout.of(width: 744), .bottomBar, "an iPad mini upright")
        XCTAssertEqual(ShellLayout.of(width: 1_032), .bottomBar, "a 13-inch iPad upright")
        XCTAssertEqual(ShellLayout.of(width: 1_133), .rail, "an iPad mini on its side")
        XCTAssertEqual(ShellLayout.of(width: 1_376), .rail, "a 13-inch iPad on its side")
    }

    /// Plan's top row: Today shows away from now, and "‹ ›" say what they step.
    func testPlanTopRowOffersTodayAwayFromNowAndNamesTheStep() {
        XCTAssertTrue(PlanTopRow.showsToday(isCurrent: false))
        XCTAssertFalse(PlanTopRow.showsToday(isCurrent: true))
        XCTAssertEqual(PlanTopRow.stepLabels(days: 1).previous, "Previous day")
        XCTAssertEqual(PlanTopRow.stepLabels(days: 7).next, "Next week")
        XCTAssertEqual(PlanTopRow.stepLabels(days: 3).next, "Next 3 days")
    }
}
