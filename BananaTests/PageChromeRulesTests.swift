import XCTest

/// One control for each job, and doing kept apart from looking back (10 Oct 2026).
final class PageChromeRulesTests: XCTestCase {
    // MARK: - Review

    func testATabsChartButtonOpensReviewOnItsOwnSubject() {
        XCTAssertEqual(ReviewSubject.ordered(for: .workouts).first, .fitness)
        XCTAssertEqual(ReviewSubject.ordered(for: .nutrition).first, .food)
        XCTAssertEqual(ReviewSubject.ordered(for: .library).first, .listening)
        // Plan and Notes have nothing of their own to look back on.
        XCTAssertEqual(ReviewSubject.ordered(for: .plan), ReviewSubject.allCases)
        XCTAssertEqual(ReviewSubject.ordered(for: .notes), ReviewSubject.allCases)
    }

    func testEveryPartIsThereOnceWhateverLeads() {
        for section in AppSection.allCases {
            let parts = ReviewSubject.ordered(for: section)
            XCTAssertEqual(parts.count, ReviewSubject.allCases.count, "\(section)")
            XCTAssertEqual(Set(parts), Set(ReviewSubject.allCases), "\(section)")
        }
    }

    func testReviewIsNotATabAndIsTheSidebarsOnePlaceForThePast() {
        XCTAssertFalse(AppSection.iOSTabs.contains(.review))
        XCTAssertTrue(AppSection.sidebar.contains(.review))
        // Sleep and Trends had rows of their own.
        XCTAssertFalse(AppSection.sidebar.contains(.sleep))
        XCTAssertFalse(AppSection.sidebar.contains(.trends))
        // The Mac's Settings is its own window, not a sidebar row.
        XCTAssertEqual(AppSection.macSidebar, AppSection.sidebar.filter { $0 != .settings })
        // A place kept from before opens Review, not nothing.
        XCTAssertEqual(AppSection.sleep.sidebarHome, .review)
        XCTAssertEqual(AppSection.trends.sidebarHome, .review)
        XCTAssertEqual(AppSection.plan.sidebarHome, .plan)
        for section in AppSection.allCases {
            XCTAssertTrue(AppSection.sidebar.contains(section.sidebarHome), "\(section)")
            XCTAssertTrue(AppSection.iOSTabs.contains(section.tabBarHome), "\(section)")
        }
    }

    func testTheOneSpanSwitchHasThreeWords() {
        XCTAssertEqual(ReviewSpan.allCases.map(\.title), ["Week", "Month", "Year"])
        XCTAssertEqual(ReviewSpan.week.trendWindow, .week)
        XCTAssertEqual(ReviewSpan.month.trendWindow, .month)
        XCTAssertEqual(ReviewSpan.year.trendWindow, .year)
    }

    // MARK: - The date line

    func testTheDateLineNamesNowAndShowsOnlyDatesWhenAway() {
        let now = DateLineWording.parts(current: "Today", dates: "Sat, Oct 10", isCurrent: true)
        XCTAssertEqual(now.name, "Today")
        XCTAssertEqual(now.dates, "Sat, Oct 10")
        let away = DateLineWording.parts(current: "Today", dates: "Fri, Oct 9", isCurrent: false)
        XCTAssertEqual(away.name, "Fri, Oct 9")
        XCTAssertNil(away.dates)
    }

    func testSwipingLeftGoesForwardOnEveryPage() {
        XCTAssertEqual(DateLineWording.step(forSwipe: -80), 1)
        XCTAssertEqual(DateLineWording.step(forSwipe: 80), -1)
    }

    // MARK: - Review's sums

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func day(_ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    func testOneTotalPerDayWithEmptyDaysKept() {
        let days = ReviewMath.perDay([(day(5, hour: 8), 400), (day(5, hour: 19), 600), (day(7), 900), (day(12), 50)],
                                     from: day(5, hour: 0), to: day(8, hour: 0), calendar: calendar)
        XCTAssertEqual(days.map(\.value), [1000, 0, 900])
        XCTAssertEqual(days.first?.day, day(5, hour: 0))
    }

    func testAnAverageLeavesOutDaysNothingWasLoggedOn() {
        XCTAssertEqual(ReviewMath.averageOfLoggedDays([2000, 0, 2400, 0]), 2200)
        XCTAssertNil(ReviewMath.averageOfLoggedDays([0, 0]))
        XCTAssertNil(ReviewMath.averageOfLoggedDays([]))
    }

    func testAYearIsABarAMonth() {
        let days: [(day: Date, value: Double)] = [
            (day(1, hour: 0), 2000), (day(2, hour: 0), 0), (day(3, hour: 0), 2400),
            (calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!, 1800),
        ]
        let months = ReviewMath.monthlyAverages(days, calendar: calendar)
        XCTAssertEqual(months.map(\.value), [2200, 1800])
    }

    func testDurationsReadTheSameEverywhere() {
        XCTAssertEqual(ReviewMath.clock(minutes: 425), "7h 5m")
        XCTAssertEqual(ReviewMath.clock(minutes: 45), "45m")
        XCTAssertEqual(ReviewMath.clock(minutes: -3), "0m")
        // The one duration format, shared by sleep, Review and the morning briefing.
        XCTAssertEqual(DS.duration(minutes: 410), "6h 50m")
        XCTAssertEqual(DS.duration(minutes: 360), "6h")
        XCTAssertEqual(DS.duration(minutes: 4), "4m")
        XCTAssertEqual(DS.duration(minutes: 179.6), "3h")
    }

    // MARK: - The + on the tab bar's row

    func testTheAddListLeadsWithTheTabBeingLookedAt() {
        XCTAssertEqual(AddKind.groups(for: .nutrition).map(\.section), [.nutrition, .plan, .notes, .library])
        XCTAssertEqual(AddKind.groups(for: .library).first?.section, .library)
        // Workouts adds nothing of its own, nor does a page with no tab: the bar's order.
        XCTAssertEqual(AddKind.groups(for: .workouts).map(\.section), [.plan, .nutrition, .notes, .library])
        XCTAssertEqual(AddKind.groups(for: .settings).map(\.section), [.plan, .nutrition, .notes, .library])
    }

    func testEveryKindIsInTheListOnceWhateverLeads() {
        for section in AppSection.allCases {
            let kinds = AddKind.groups(for: section).flatMap(\.kinds)
            XCTAssertEqual(kinds.count, AddKind.allCases.count, "\(section)")
            XCTAssertEqual(Set(kinds), Set(AddKind.allCases), "\(section)")
        }
    }

    func testAKindsPageIsATabAndItsNameIsItsOwn() {
        for kind in AddKind.allCases {
            XCTAssertTrue(AppSection.iOSTabs.contains(kind.section), "\(kind)")
            XCTAssertEqual(kind.nutritionSection != nil, kind.section == .nutrition, "\(kind)")
        }
        XCTAssertEqual(Set(AddKind.allCases.map(\.identifier)).count, AddKind.allCases.count)
        XCTAssertEqual(AddKind.supplement.nutritionSection, "Taken")
        XCTAssertEqual(AddKind.searchFood.nutritionSection, "Food")
        XCTAssertEqual(AddKind.recentMeal.nutritionSection, "Food")
    }

    // MARK: - Body: Workouts and Nutrition under one tab

    func testBodyShowsOneSwitchAcrossBothPages() {
        XCTAssertEqual(BodyPage.choices(wide: false), [.workouts, .food, .taken])
        XCTAssertEqual(BodyPage(section: .workouts, nutritionSection: "Taken"), .workouts)
        XCTAssertEqual(BodyPage(section: .nutrition, nutritionSection: nil), .food)
        XCTAssertEqual(BodyPage(section: .nutrition, nutritionSection: "Taken"), .taken)
        // Review falls back to Workouts where there is only a tab bar.
        XCTAssertEqual(BodyPage(section: .review, nutritionSection: nil), .workouts)
    }

    func testEachBodyPageOpensItsSectionAndItsHalfOfNutrition() {
        XCTAssertEqual(BodyPage.allCases.map(\.section), [.workouts, .nutrition, .nutrition])
        XCTAssertEqual(BodyPage.allCases.map(\.nutritionSection), [nil, "Food", "Taken"])
        for page in BodyPage.allCases {
            XCTAssertEqual(BodyPage(section: page.section, nutritionSection: page.nutritionSection), page)
            XCTAssertTrue(BodyPage.holds(page.section))
        }
        XCTAssertFalse(BodyPage.holds(.notes))
        XCTAssertFalse(BodyPage.holds(.library))
    }

    func testAWideBodyPageHasTwoChoicesBecauseFoodAndTakenShowTogether() {
        XCTAssertEqual(BodyPage.choices(wide: true), [.workouts, .food])
        XCTAssertEqual(BodyPage(section: .nutrition, nutritionSection: "Taken", wide: true), .food)
        XCTAssertEqual(BodyPage.food.title(wide: true), "Food")
        XCTAssertEqual(BodyPage.food.title(wide: false), "Food")
    }
}
