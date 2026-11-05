import XCTest

/// Modules a person switches on and off (17 Oct 2026): Plan is always there, a module that is off
/// has no tab, no + group and no part of Review, and choosing all of them is "everything".
final class AppModulesTests: XCTestCase {
    private let foodOnly = ModuleChoice.choosing([.food])

    // MARK: - The choice

    func testChoosingEveryModuleIsEverythingSoOneAddedLaterIsOnToo() {
        XCTAssertEqual(ModuleChoice.choosing(Set(AppModule.allCases)), .everything)
        XCTAssertEqual(AppModule.selectable.reduce(ModuleChoice.planOnly) { $0.setting($1, on: true) }, .everything)
        XCTAssertEqual(ModuleChoice.everything.setting(.notes, on: false),
                       .only(["workouts", "food", "podcasts", "email"]))
    }

    func testPlanAloneHasNoModules() {
        XCTAssertTrue(ModuleChoice.planOnly.enabled.isEmpty)
        XCTAssertFalse(ModuleChoice.planOnly.isEverything)
    }

    func testTheChoiceRoundTripsAndKeepsAModuleThisBuildDoesNotKnow() throws {
        for choice in [ModuleChoice.everything, .planOnly, .only(["food", "notes"])] {
            let data = try JSONEncoder().encode(choice)
            XCTAssertEqual(try JSONDecoder().decode(ModuleChoice.self, from: data), choice)
        }
        // Chosen on a newer copy: kept and passed on, not the reason the whole choice is dropped.
        let newer = try JSONDecoder().decode(ModuleChoice.self, from: Data(#"{"only":["food","mail"]}"#.utf8))
        XCTAssertTrue(newer.includes(.food))
        XCTAssertFalse(newer.includes(.notes))
        XCTAssertEqual(newer.setting(.notes, on: true), .only(["food", "mail", "notes"]))
    }

    func testEmailAvailabilityFollowsCompiledSupportRatherThanAppIdentity() throws {
        #if BANANA_UNRELEASED
        XCTAssertTrue(AppModule.email.isAvailable)
        XCTAssertEqual(AppModule.selectable, AppModule.allCases)
        XCTAssertTrue(ModuleChoice.planOnly.setting(.email, on: true).includes(.email))
        #else
        XCTAssertFalse(AppModule.email.isAvailable)
        XCTAssertEqual(AppModule.selectable, [.workouts, .food, .notes, .podcasts])
        #endif
        for module in AppModule.allCases where module != .email {
            XCTAssertTrue(module.isAvailable)
            XCTAssertNil(module.statusLabel(inBeta: false))
            XCTAssertEqual(module.statusLabel(inBeta: true), "Beta")
        }
        let synced = try JSONDecoder().decode(ModuleChoice.self, from: Data(#"{"only":["email","food"]}"#.utf8))
        XCTAssertEqual(synced.includes(.email), AppModule.email.isAvailable)
        XCTAssertTrue(synced.includes(.food))
        XCTAssertEqual(try JSONDecoder().decode(ModuleChoice.self, from: JSONEncoder().encode(synced)), synced)
        if !AppModule.email.isAvailable {
            XCTAssertEqual(synced.setting(.email, on: true), synced)
            XCTAssertFalse(AppSection.mail.isShown(with: .everything))
            XCTAssertNil(AppModule.email.statusLabel)
        }
    }

    // MARK: - What shows

    func testPlanAndItsOwnPlacesAreAlwaysThere() {
        for section in [AppSection.plan, .routines, .settings] {
            XCTAssertTrue(section.isShown(with: .planOnly), "\(section)")
        }
        #if BANANA_AI
        XCTAssertEqual(AppSection.sidebar(with: .planOnly), [.plan, .routines, .assistant, .settings])
        XCTAssertEqual(AppSection.macSidebar(with: .planOnly), [.plan, .routines, .assistant])
        #else
        XCTAssertEqual(AppSection.sidebar(with: .planOnly), [.plan, .routines, .settings])
        XCTAssertEqual(AppSection.macSidebar(with: .planOnly), [.plan, .routines])
        #endif
        XCTAssertEqual(AppSection.sidebar(with: .everything), AppSection.sidebar.filter { $0 != .mail || AppModule.email.isAvailable })
    }

    func testASectionSwitchedOffOpensPlan() {
        XCTAssertEqual(AppSection.notes.shown(with: foodOnly), .plan)
        XCTAssertEqual(AppSection.sleep.shown(with: foodOnly), .plan)
        XCTAssertEqual(AppSection.nutrition.shown(with: foodOnly), .nutrition)
        // Review stays while something it looks back on is on.
        XCTAssertEqual(AppSection.review.shown(with: foodOnly), .review)
        XCTAssertEqual(AppSection.review.shown(with: .planOnly), .plan)
        XCTAssertEqual(AppSection.review.shown(with: .choosing([.notes])), .plan)
    }

    func testReviewHasOnlyTheModulesThatAreOn() {
        XCTAssertEqual(ReviewSubject.ordered(for: .nutrition, with: foodOnly), [.food])
        XCTAssertEqual(ReviewSubject.ordered(for: .workouts, with: .choosing([.workouts, .podcasts])),
                       [.fitness, .sleep, .listening])
        XCTAssertEqual(ReviewSubject.ordered(for: .plan, with: .everything), ReviewSubject.allCases)
        XCTAssertTrue(ReviewSubject.shown(with: .planOnly).isEmpty)
    }

    func testThePlusListHasOnlyTheModulesThatAreOn() {
        let groups = AddKind.groups(for: .plan, with: foodOnly).map(\.section)
        XCTAssertEqual(groups, [.plan, .nutrition])
        XCTAssertEqual(AddKind.groups(for: .plan, with: .planOnly).map(\.section), [.plan])
        XCTAssertEqual(AddKind.groups(for: .notes, with: .everything).map(\.section),
                       AddKind.groups(for: .notes).map(\.section))
    }

    func testTheBodyTabFollowsWorkoutsAndFood() {
        XCTAssertEqual(BodyPage.choices(wide: false, with: .everything), BodyPage.allCases)
        XCTAssertEqual(BodyPage.choices(wide: false, with: foodOnly), [.food, .taken])
        // One left: no switch.
        XCTAssertEqual(BodyPage.choices(wide: false, with: .choosing([.workouts])), [.workouts])
        XCTAssertFalse(BodyPage.isShown(with: .choosing([.notes, .podcasts])))
        XCTAssertTrue(BodyPage.isShown(with: foodOnly))
    }

    func testEveryModuleOwnsAPlace() {
        for module in AppModule.allCases {
            XCTAssertTrue(AppSection.allCases.contains { $0.module == module }, "\(module)")
        }
    }
}
