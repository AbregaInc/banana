import Combine
import Foundation
import SwiftUI

/// The modules switched on (`ModuleChoice`): one synced setting, the same on the phone, the iPad
/// and the Mac. Its own small store and key, apart from `AppSettings`, so the shell that reads it
/// isn't redrawn by every other preference.
///
/// Nothing stored means everything: every copy from before modules existed shows all it showed.
/// The first run stores a choice (`OnboardingView`), and a finished first run with nothing stored
/// stores "everything" (`settleForExistingInstall`), so a new device of someone who already uses
/// everything starts from that and not from Plan alone.
@MainActor
final class ModuleStore: ObservableObject {
    static let shared = ModuleStore()

    @Published private(set) var choice: ModuleChoice

    private static let key = "modules"
    /// `--disable-icloud` (tests, pictures): no key-value store either. It outlives deleting the
    /// app, so a test's "new install" would otherwise start from an earlier run's choice.
    private static let usesCloud = !ProcessInfo.processInfo.arguments.contains("--disable-icloud")
    private let cloud = LegacyKVS.shared
    #if DEBUG
    /// Set by `--modules`: shown, never saved.
    private var pinned = false
    #endif

    private init() {
        #if BANANA_UNRELEASED
        // Unreleased modules are built in. These words are what tools/check-release.sh looks for:
        // an archive that has them stops before it reaches Apple.
        LaunchClock.mark("banana-unreleased-modules-built-in")
        #endif
        choice = Self.stored() ?? .everything
        #if DEBUG
        // `--modules everything|plan|food,notes`: open with these on, for pictures and tests.
        let arguments = ProcessInfo.processInfo.arguments
        if let i = arguments.firstIndex(of: "--modules"), i + 1 < arguments.count {
            choice = Self.parse(arguments[i + 1])
            pinned = true
        }
        #endif
        LegacyKVS.observeExternalChanges(tier: .personal) { [weak self] in self?.applyFromCloud() }
    }

    /// Whether a choice has been made on any device: the first run starts from it when there is
    /// one, and from Plan alone when there isn't.
    var hasChoice: Bool {
        #if DEBUG
        if pinned { return true }
        #endif
        return Self.stored() != nil
    }

    func includes(_ module: AppModule) -> Bool { choice.includes(module) }

    func set(_ choice: ModuleChoice) {
        #if DEBUG
        if pinned { self.choice = choice; return }
        #endif
        guard choice != self.choice || !hasChoice else { return }
        // Persisting the existing default is a migration, not a module change. Publishing
        // the same choice clears the warm calendar cache through modulesDidChange().
        if choice != self.choice { self.choice = choice }
        guard let data = try? JSONEncoder().encode(choice) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
        if Self.usesCloud {
            cloud.set(data, forKey: Self.key)
            cloud.synchronize()
        }
        CloudBackup.shared.schedule()
        SyncReport.changed(Self.syncType, [Self.syncID])
    }

    // MARK: - The data platform (docs/design/DATA-PLATFORM.md, `SettingsAdapters`)

    static let syncType = "core.modules"
    static let syncID = "modules"

    /// Another account signed in on this device and the person said to clear it first
    /// (docs/design/DATA-PLATFORM.md §2): no choice stored, so everything shows, as on a new
    /// install. This device only: nothing is reported and iCloud's key-value store isn't written.
    func resetForAccountChange() {
        UserDefaults.standard.removeObject(forKey: Self.key)
        #if DEBUG
        if pinned { return }
        #endif
        if choice != .everything { choice = .everything }
    }

    /// Another device's choice, through the usual path.
    func applySynced(_ choice: ModuleChoice) {
        #if DEBUG
        if pinned { return }
        #endif
        guard choice != self.choice || !hasChoice else { return }
        set(choice)
    }

    func set(_ module: AppModule, on: Bool) { set(choice.setting(module, on: on)) }

    /// A copy that finished its first run before modules existed: it has been showing everything,
    /// so that is its choice, said out loud for the other devices.
    func settleForExistingInstall(onboardingCompleted: Bool) {
        if Self.usesCloud {
            cloud.synchronize()
            applyFromCloud()
        }
        guard onboardingCompleted, !hasChoice else { return }
        set(.everything)
    }

    private func applyFromCloud() {
        #if DEBUG
        if pinned { return }
        #endif
        guard Self.usesCloud, let data = cloud.data(forKey: Self.key),
              let remote = try? JSONDecoder().decode(ModuleChoice.self, from: data) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
        if remote != choice {
            choice = remote
            // Another device's choice, through iCloud: a late arrival for the data platform.
            LegacyCloud.applyingFromCloud { SyncReport.changed(Self.syncType, [Self.syncID]) }
        }
    }

    /// The choice saved here, or iCloud's copy when this device has none yet.
    private static func stored() -> ModuleChoice? {
        let data = UserDefaults.standard.data(forKey: key) ?? (usesCloud ? LegacyKVS.shared.data(forKey: key) : nil)
        return data.flatMap { try? JSONDecoder().decode(ModuleChoice.self, from: $0) }
    }

    #if DEBUG
    static func parse(_ text: String) -> ModuleChoice {
        if text == "everything" { return .everything }
        let modules = text.split(separator: ",").compactMap { AppModule(rawValue: String($0)) }
        return .choosing(Set(modules))
    }
    #endif
}

extension AppModule {
    /// One colour per module, the same on the welcome and in Settings › Modules: the brand's,
    /// as the welcome has always shown them.
    var tint: Color {
        switch self {
        case .workouts: DS.Palette.Brand.green
        case .food: DS.Palette.Brand.purple
        case .notes: DS.Palette.Brand.orange
        case .podcasts: DS.Palette.Brand.blue
        case .email: DS.Palette.Brand.blue
        }
    }
}
