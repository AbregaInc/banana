import Foundation

/// A part of Banana a person can switch on or off (17 Oct 2026). Plan — the calendar, reminders,
/// routines and travel — is the app, and is always on.
///
/// The author: work and personal audiences want different first looks, and he wants all of it
/// himself ("I'm in that integrator category"). So nothing is cut: a new person picks what Banana
/// looks after on the way in, Settings › Modules changes it after, and turning a module off only
/// hides it. Its data stays and keeps syncing, so turning it back on loses nothing.
///
/// A build carries only the modules its BANANA_MODULES setting lists (Config/Base.xcconfig); one it
/// leaves out has no code in that build (`#if BANANA_MODULE_…`), and none of its entitlements,
/// background modes, usage strings or embedded targets (Config/Modules.json). Beta carries all
/// five, Stable all but Email, the App Store app those BANANA_APP_STORE_MODULES lists. ModuleStore
/// separately checks account eligibility before offering Email. Saved choices keep their names.
enum AppModule: String, CaseIterable, Identifiable, Sendable {
    case workouts, food, notes, podcasts, email
    var id: String { rawValue }

    var title: String {
        switch self {
        case .workouts: "Workouts and sleep"
        case .food: "Food"
        case .notes: "Notes"
        case .podcasts: "Podcasts"
        case .email: "Email"
        }
    }

    var symbol: String {
        switch self {
        case .workouts: AppSection.workouts.symbol
        case .food: AppSection.nutrition.symbol
        case .notes: AppSection.notes.symbol
        case .podcasts: "headphones"
        case .email: "envelope.fill"
        }
    }
    static var isBetaBuild: Bool {
        #if BANANA_BETA
        true
        #else
        false
        #endif
    }

    /// The modules this build carries, from its compile conditions.
    static let carried: Set<AppModule> = {
        var modules = Set<AppModule>()
        #if BANANA_MODULE_WORKOUTS
        modules.insert(.workouts)
        #endif
        #if BANANA_MODULE_FOOD
        modules.insert(.food)
        #endif
        #if BANANA_MODULE_NOTES
        modules.insert(.notes)
        #endif
        #if BANANA_MODULE_PODCASTS
        modules.insert(.podcasts)
        #endif
        #if BANANA_MODULE_EMAIL
        modules.insert(.email)
        #endif
        return modules
    }()

    /// The compile condition that carries this module (BANANA_MODULES lists these names).
    var compileCondition: String { "BANANA_MODULE_\(rawValue.uppercased())" }

    /// The modules a BANANA_MODULES value names, in `allCases` order; unknown names are ignored.
    static func named(inSetting setting: String) -> [AppModule] {
        let names = Set(setting.split(whereSeparator: \.isWhitespace).map(String.init))
        return allCases.filter { names.contains($0.compileCondition) }
    }

    var isAvailable: Bool { Self.carried.contains(self) }

    /// Things outside a module's own screens that only it feeds, so they go with it: in a build
    /// without the module, or with it switched off, they are neither listed nor offered.
    enum Dependent: CaseIterable {
        /// Settings › Apple Watch: the quality Podcasts sends episodes to the Watch at.
        case watchSettings
        /// A routine that waits for a workout to start, which Workouts and sleep sees.
        case workoutStartTrigger
    }

    static func owner(of dependent: Dependent) -> AppModule {
        switch dependent {
        case .watchSettings: .podcasts
        case .workoutStartTrigger: .workouts
        }
    }
    static var selectable: [AppModule] { allCases.filter(\.isAvailable) }
    func statusLabel(inBeta: Bool) -> String? { inBeta ? "Beta" : nil }
    var statusLabel: String? { statusLabel(inBeta: Self.isBetaBuild) }

}

/// Which modules are on: every one, including any added later, or a chosen few.
///
/// Stored by name, so a module this build doesn't know (chosen on a newer copy) is kept and
/// passed on, never a reason to drop the whole choice.
enum ModuleChoice: Equatable, Sendable {
    case everything
    case only(Set<String>)

    func includes(_ module: AppModule) -> Bool {
        guard module.isAvailable else { return false }
        switch self {
        case .everything: return true
        case .only(let names): return names.contains(module.rawValue)
        }
    }

    /// The modules on, of those this build knows.
    var enabled: [AppModule] { AppModule.allCases.filter(includes) }

    var isEverything: Bool { self == .everything }

    /// Choosing every module is "everything", so one added later is on too.
    static func choosing(_ modules: Set<AppModule>) -> ModuleChoice {
        Set(AppModule.allCases.filter(\.isAvailable)).isSubset(of: modules) ? .everything : .only(Set(modules.map(\.rawValue)))
    }

    /// The choice with one module switched.
    func setting(_ module: AppModule, on: Bool) -> ModuleChoice {
        guard module.isAvailable else { return self }
        var names: Set<String>
        switch self {
        case .everything: names = Set(AppModule.allCases.map(\.rawValue))
        case .only(let chosen): names = chosen
        }
        if on { names.insert(module.rawValue) } else { names.remove(module.rawValue) }
        let known = Set(AppModule.allCases.filter(\.isAvailable).map(\.rawValue))
        return known.isSubset(of: names) ? .everything : .only(names)
    }

    /// Plan alone: what a new person starts with until they tick more.
    static let planOnly = ModuleChoice.only([])
}

extension ModuleChoice: Codable {
    private enum CodingKeys: String, CodingKey { case everything, only }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        if try box.decodeIfPresent(Bool.self, forKey: .everything) == true {
            self = .everything
        } else {
            self = .only(Set(try box.decodeIfPresent([String].self, forKey: .only) ?? []))
        }
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .everything: try box.encode(true, forKey: .everything)
        case .only(let names): try box.encode(names.sorted(), forKey: .only)
        }
    }
}

// MARK: - What each module owns

extension AppSection {
    /// The module this section belongs to; nil for Plan's own (Plan, Routines, Settings) and for
    /// Review, which is there while anything it looks back on is.
    var module: AppModule? {
        switch self {
        case .workouts, .sleep, .trends: .workouts
        case .mail: .email
        case .nutrition: .food
        case .notes: .notes
        case .library: .podcasts
        case .plan, .routines, .settings, .review, .assistant: nil
        }
    }

    func isShown(with choice: ModuleChoice) -> Bool {
        #if !BANANA_AI
        if self == .assistant { return false }
        #endif
        if self == .review { return !ReviewSubject.shown(with: choice).isEmpty }
        return module.map(choice.includes) ?? true
    }

    /// Where this section opens with the modules chosen: itself, or Plan when its module is off.
    func shown(with choice: ModuleChoice) -> AppSection { isShown(with: choice) ? self : .plan }

    /// The sidebar (iPad and Mac) with the modules chosen.
    static func sidebar(with choice: ModuleChoice) -> [AppSection] {
        sidebar.filter { $0.isShown(with: choice) }
    }

    /// The Mac's sidebar with the modules chosen.
    static func macSidebar(with choice: ModuleChoice) -> [AppSection] {
        macSidebar.filter { $0.isShown(with: choice) }
    }
}

extension ReviewSubject {
    var module: AppModule {
        switch self {
        case .fitness, .sleep: .workouts
        case .food: .food
        case .listening: .podcasts
        }
    }

    /// Review's parts with the modules chosen, in `ordered(for:)`'s order.
    static func ordered(for section: AppSection, with choice: ModuleChoice) -> [ReviewSubject] {
        ordered(for: section).filter { choice.includes($0.module) }
    }

    static func shown(with choice: ModuleChoice) -> [ReviewSubject] {
        allCases.filter { choice.includes($0.module) }
    }
}

extension AddKind {
    /// The + list with the modules chosen: groups of modules that are off are left out.
    static func groups(for current: AppSection,
                       with choice: ModuleChoice) -> [(section: AppSection, kinds: [AddKind])] {
        groups(for: current).filter { $0.section.isShown(with: choice) }
    }
}

extension BodyPage {
    var module: AppModule { self == .workouts ? .workouts : .food }

    /// The Body switch's choices with the modules chosen. One left means no switch at all.
    static func choices(wide: Bool, with choice: ModuleChoice) -> [BodyPage] {
        choices(wide: wide).filter { choice.includes($0.module) }
    }

    /// Whether the phone's Body tab is there: Workouts, Food or both.
    static func isShown(with choice: ModuleChoice) -> Bool {
        choice.includes(.workouts) || choice.includes(.food)
    }
}
