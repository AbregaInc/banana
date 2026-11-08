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

    /// One rail width for the iPad and the Mac: the circles with room either side, clear of the
    /// Mac window's buttons, and slim (the Mac's first build drew a ~200 pt sidebar).
    func testTheRailIsSlimHoldsItsCirclesAndClearsTheWindowButtons() {
        XCTAssertGreaterThanOrEqual(ShellLayout.railColumn, ShellLayout.railButton + 2 * 12)
        XCTAssertGreaterThanOrEqual(ShellLayout.railColumn, ShellLayout.macWindowButtonsEnd)
        XCTAssertLessThanOrEqual(ShellLayout.railColumn, 88)
    }

    /// The switcher's badge adds up the pages' own counts, for the pages that are on: the old tab
    /// bar's, and Mail's unread in the Inbox.
    func testBadgesAreTheOldTabCountsAddedUpOnTheSwitcher() {
        var counts = ActionItems.Counts()
        counts.plan = 2; counts.food = 1; counts.taken = 3
        XCTAssertEqual(ShellBadge.count(.plan, counts), 2)
        XCTAssertEqual(ShellBadge.count(.body, counts), 4)
        XCTAssertEqual(ShellBadge.count(.mail, counts), 0)
        XCTAssertEqual(ShellBadge.count(.mail, counts, mail: 12), 12, "Mail: the Inbox\u{2019}s unread")
        XCTAssertEqual(ShellBadge.total([.plan, .mail, .body], counts, mail: 12), 18)
        XCTAssertEqual(ShellBadge.total([.plan, .body], counts, mail: 12), 6, "Mail off: not added")
        XCTAssertEqual(ShellBadge.total([.plan, .mail, .body, .settings], counts), 6)
        XCTAssertEqual(ShellBadge.total([.plan, .mail, .settings], counts), 2, "Body off: its count is not added")
        XCTAssertNil(ShellBadge.text(0))
        XCTAssertEqual(ShellBadge.text(7), "7")
        XCTAssertEqual(ShellBadge.text(99), "99")
        XCTAssertEqual(ShellBadge.text(100), "99+")
        XCTAssertEqual(ShellBadge.spoken(1), "1 needs attention")
        XCTAssertEqual(ShellBadge.spoken(3), "3 need attention")
        XCTAssertNil(ShellBadge.spoken(0))
    }

    /// A toast clears the bar on a page while the bar is there; in a sheet, or with the bar away
    /// for a keyboard, it keeps its own place.
    func testAToastStandsAboveTheBarOnlyWhereTheBarIs() {
        XCTAssertEqual(ShellToastInset.bottom(barHeight: 120, barShown: true, onPage: true), 120)
        XCTAssertEqual(ShellToastInset.bottom(barHeight: 120, barShown: false, onPage: true), 0, "keyboard up for a note")
        XCTAssertEqual(ShellToastInset.bottom(barHeight: 120, barShown: true, onPage: false), 0, "in a sheet")
    }

    /// The shell's symbols are the sections' own, without their fill: Library is headphones.
    func testPageSymbolsComeFromTheSectionsTable() {
        XCTAssertEqual(ShellPage.library.symbol, "headphones")
        XCTAssertEqual(ShellPage.plan.symbol, "sun.max")
        XCTAssertEqual(ShellPage.notes.symbol, AppSection.notes.outlineSymbol)
        XCTAssertEqual(ShellPage.body.symbol, "heart")
        for page in ShellPage.allCases { XCTAssertFalse(page.symbol.contains(".fill"), page.rawValue) }
    }
}
