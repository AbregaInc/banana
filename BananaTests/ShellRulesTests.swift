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
}
