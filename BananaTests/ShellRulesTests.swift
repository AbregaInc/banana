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

    /// One rule on the iPad and the Mac: the rail lights the section's own page, and a section
    /// without one (Routines) lights nothing, never Plan.
    func testTheRailLightsTheSectionsOwnPageOrNone() {
        XCTAssertEqual(ShellPage.showing(.plan), .plan)
        XCTAssertEqual(ShellPage.showing(.nutrition), .body)
        XCTAssertEqual(ShellPage.showing(.sleep), .review)
        XCTAssertEqual(ShellPage.showing(.settings), .settings)
        XCTAssertNil(ShellPage.showing(.routines))
        XCTAssertNil(ShellPage.showing(.assistant))
    }

    /// On an iPad the first rail button's centre is on the top bar's centre line.
    func testTheFirstRailButtonSitsOnTheTopBarsLine() {
        XCTAssertEqual(ShellLayout.railTopInset + ShellLayout.railButton / 2, ShellLayout.barControl / 2)
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

    /// "‹ ›" say what they step.
    func testPlanStepButtonsNameTheStep() {
        XCTAssertEqual(PlanTopRow.stepLabels(days: 1).previous, "Previous day")
        XCTAssertEqual(PlanTopRow.stepLabels(days: 7).next, "Next week")
        XCTAssertEqual(PlanTopRow.stepLabels(days: 3).next, "Next 3 days")
    }

    /// Plan pages from one place in each shell, the same group in both new ones: "‹", the period,
    /// "›", then Today (only away from the current period). A date line under the bar only
    /// outside both.
    func testPlanPagesFromOnePlacePerShell() {
        for shell in [PlanPaging.Shell.wide, .bottomBar] {
            XCTAssertEqual(PlanPaging.controls(shell, isCurrent: true), [.previous, .period, .next],
                           "\(shell): no Today on the current period")
            XCTAssertEqual(PlanPaging.controls(shell, isCurrent: false), [.previous, .period, .next, .today],
                           "\(shell): Today away from it")
            XCTAssertFalse(PlanPaging.drawsDateLine(shell), "no date line under \(shell)'s bar")
        }
        XCTAssertFalse(PlanPaging.showsToday(isCurrent: true))
        XCTAssertTrue(PlanPaging.showsToday(isCurrent: false))
        XCTAssertTrue(PlanPaging.drawsDateLine(.classic))
        XCTAssertEqual(PlanPaging.shell(bottomBar: false, wide: true), .wide)
        XCTAssertEqual(PlanPaging.shell(bottomBar: true, wide: false), .bottomBar)
        XCTAssertEqual(PlanPaging.shell(bottomBar: false, wide: false), .classic)
    }

    /// The dates beside the period's name.
    func testThePeriodPickerNamesTheDatesOnScreen() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_US")
        func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
            calendar.date(from: DateComponents(year: y, month: m, day: d))!
        }
        func dates(_ start: Date, _ days: Int) -> String {
            PlanPaging.dates(start: start, days: days, calendar: calendar, locale: locale)
        }
        XCTAssertEqual(dates(date(2026, 11, 4), 1), "Wed, Nov 4")
        XCTAssertEqual(dates(date(2026, 11, 2), 7), "Nov 2\u{2013}8")
        XCTAssertEqual(dates(date(2026, 11, 8), 3), "Nov 8\u{2013}10")
        XCTAssertEqual(dates(date(2026, 10, 30), 7), "Oct 30\u{2013}Nov 5")
        XCTAssertEqual(dates(date(2026, 12, 29), 7), "Dec 29, 2026\u{2013}Jan 4, 2027")
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
        XCTAssertEqual(ShellPage.plan.symbol, "calendar")
        XCTAssertEqual(ShellPage.notes.symbol, AppSection.notes.outlineSymbol)
        XCTAssertEqual(ShellPage.body.symbol, "heart")
        for page in ShellPage.allCases { XCTAssertFalse(page.symbol.contains(".fill"), page.rawValue) }
    }

    /// Today only away from the current period, on every device; the forecast is in the top row
    /// at every width on the current period and gives way to Today when paged away.
    func testTodayShowsOnlyAwayFromTheCurrentPeriod() {
        typealias Row = PlanPaging.TopRow
        let now = PlanPaging.topRowLayouts(isCurrent: true, hasForecast: true)
        XCTAssertTrue(now.allSatisfy { !$0.today }, "no Today on the current period")
        // The forecast in Today's place before the dates beside the name: they move under it and
        // go before the forecast does.
        XCTAssertEqual(Array(now.prefix(3)), [Row(dates: .beside, today: false, forecast: true),
                                              Row(dates: .under, today: false, forecast: true),
                                              Row(dates: .hidden, today: false, forecast: true)])
        for dates in [Row.Dates.beside, .under, .hidden] {
            let first = now.firstIndex { $0.dates == dates }!
            XCTAssertTrue(now[first].forecast, "\(dates): the forecast is not reachable")
        }
        let away = PlanPaging.topRowLayouts(isCurrent: false, hasForecast: true)
        XCTAssertTrue(away.allSatisfy(\.today), "Today, paged away")
        XCTAssertEqual(away.map(\.dates), [.beside, .beside, .under, .under, .hidden])
        XCTAssertTrue(PlanPaging.topRowLayouts(isCurrent: true, hasForecast: false).allSatisfy { !$0.today && !$0.forecast })
    }

    /// Attention chips: all where they fit; past the limit, one fewer and "+N more" for the rest.
    func testAttentionChipsFoldOnlyPastTheLimit() {
        XCTAssertTrue(PlanAttentionLine.shown(2, limit: 3) == (2, 0))
        XCTAssertTrue(PlanAttentionLine.shown(3, limit: 3) == (3, 0))
        XCTAssertTrue(PlanAttentionLine.shown(5, limit: 3) == (2, 3))
        XCTAssertTrue(PlanAttentionLine.shown(9, limit: nil) == (9, 0))
    }

    /// The grid observes only the attention count (`PlanAttention`): the stores behind the chips
    /// publish often, and the clock grid must not rebuild for them (ui-performance-contract.md).
    func testThePlanGridDoesNotObserveTheAttentionStores() throws {
        let source = try String(contentsOf: SourceTree.root.appendingPathComponent("Banana/Views/WeekView.swift"), encoding: .utf8)
        for store in ["MealInboxStore", "WellnessStore", "AnchoredTimingHub"] {
            XCTAssertFalse(source.contains("@ObservedObject private var") && source.contains("= \(store).shared"),
                           "WeekView observes \(store)")
        }
        XCTAssertFalse(source.contains("PlanAttentionBand"), "the attention band is gone")
    }

    /// The Mac's rail has no Settings (the app menu's ⌘, opens its window); an iPad's keeps it.
    func testTheMacsRailHasNoSettings() {
        let on = ShellPage.Modules()
        XCTAssertEqual(ShellPage.rail(on, mac: true), [.plan])
        XCTAssertEqual(ShellPage.rail(on, mac: false), [.plan, .settings])
    }
}
