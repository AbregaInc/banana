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
        XCTAssertFalse(AppModule.selectable.contains(.email))
        #endif
        for module in AppModule.allCases where module != .email {
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

    // MARK: - What a build carries

    /// Each module is there exactly when its compile condition is (BANANA_MODULES).
    func testAModuleIsAvailableExactlyWhenItsCompileConditionIsSet() {
        var conditions = Set<String>()
        #if BANANA_MODULE_WORKOUTS
        conditions.insert("BANANA_MODULE_WORKOUTS")
        #endif
        #if BANANA_MODULE_FOOD
        conditions.insert("BANANA_MODULE_FOOD")
        #endif
        #if BANANA_MODULE_NOTES
        conditions.insert("BANANA_MODULE_NOTES")
        #endif
        #if BANANA_MODULE_PODCASTS
        conditions.insert("BANANA_MODULE_PODCASTS")
        #endif
        #if BANANA_MODULE_EMAIL
        conditions.insert("BANANA_MODULE_EMAIL")
        #endif
        for module in AppModule.allCases {
            XCTAssertEqual(module.isAvailable, conditions.contains(module.compileCondition), "\(module)")
        }
        XCTAssertEqual(AppModule.selectable, AppModule.allCases.filter { conditions.contains($0.compileCondition) })
    }

    /// Email's code is fenced by its older switch (`BANANA_UNRELEASED`, from BANANA_LOCAL_EMAIL);
    /// the module and that switch must agree, or Settings would offer an Email with no code.
    func testTheEmailModuleAndTheEmailCodeAgree() {
        #if BANANA_UNRELEASED
        let emailCode = true
        #else
        let emailCode = false
        #endif
        XCTAssertEqual(AppModule.email.isAvailable, emailCode)
    }

    func testASettingNamesModulesByTheirConditions() {
        XCTAssertEqual(AppModule.named(inSetting: ""), [])
        XCTAssertEqual(AppModule.named(inSetting: "  BANANA_MODULE_PODCASTS\tBANANA_MODULE_WORKOUTS BANANA_MODULE_UNKNOWN "),
                       [.workouts, .podcasts])
        XCTAssertEqual(AppModule.named(inSetting: AppModule.allCases.map(\.compileCondition).joined(separator: " ")),
                       AppModule.allCases)
    }

    /// The build configuration names every module, and the App Store's list only known ones.
    func testTheBuildSettingsNameEveryModule() throws {
        let settings = try ModuleSettings.read()
        let all = try XCTUnwrap(settings["BANANA_ALL_MODULES"])
        for module in AppModule.allCases where module != .email {
            XCTAssertTrue(all.split(separator: " ").contains(Substring(module.compileCondition)), "\(module)")
        }
        XCTAssertTrue(all.contains("$(BANANA_MODULE_EMAIL_$(BANANA_LOCAL_EMAIL))"), "Email follows its switch")
        XCTAssertEqual(settings["BANANA_MODULE_EMAIL_YES"], AppModule.email.compileCondition)
        let appStore = try XCTUnwrap(settings["BANANA_APP_STORE_MODULES"])
        for word in appStore.split(whereSeparator: \.isWhitespace) {
            XCTAssertTrue(AppModule.allCases.map(\.compileCondition).contains(String(word)), "unknown module \(word)")
        }
        XCTAssertFalse(AppModule.named(inSetting: appStore).contains(.email), "the App Store app has no Email")
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

    func testWhatOnlyAModuleFeedsGoesWithIt() {
        // Settings › Apple Watch was still listed in the App Store app, which has no Podcasts,
        // and opened an empty page; its Routines listed one that waits for a workout to start,
        // which nothing in that build can see. Each now follows its module.
        XCTAssertEqual(AppModule.owner(of: .watchSettings), .podcasts)
        XCTAssertEqual(AppModule.owner(of: .workoutStartTrigger), .workouts)
        for dependent in AppModule.Dependent.allCases {
            let owner = AppModule.owner(of: dependent)
            XCTAssertFalse(ModuleChoice.planOnly.includes(owner), "\(dependent) shows with Plan alone")
            XCTAssertEqual(ModuleChoice.everything.includes(owner), owner.isAvailable, "\(dependent)")
        }
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

/// The plain `NAME = value` lines of Config/Base.xcconfig (conditional `NAME[config=…]` lines are
/// left out), for tests that hold the code to the build settings.
enum ModuleSettings {
    static func read() throws -> [String: String] {
        let file = SourceTree.root.appendingPathComponent("Config/Base.xcconfig")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: file.path), "the source tree is not on this machine")
        var settings: [String: String] = [:]
        for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !line.hasPrefix("//") else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            guard !name.contains("["), !name.isEmpty else { continue }
            settings[name] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        return settings
    }

    /// The modules the App Store listing that describes `setting` names.
    static func modules(_ setting: String) throws -> [AppModule] {
        AppModule.named(inSetting: try read()[setting] ?? "")
    }
}
