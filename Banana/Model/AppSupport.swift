import Foundation
#if os(macOS)
import Security
#endif

/// The iCloud namespace for this build flavor. Beta uses its own container and KVS identity so
/// iPhone and Mac Beta can sync with each other without seeing or writing production data.
enum AppCloud {
    /// Named by the build's config (Config/Base.xcconfig, and your own Local.xcconfig), which
    /// gives Stable and Beta each their own. Empty when the build names none.
    static let containerID = BuildConfig.value("BananaCloudContainer") ?? ""
    /// A container an earlier app synced through, read once to carry its data over.
    static let legacyContainerID: String? = BuildConfig.value("BananaLegacyCloudContainer")

    /// Whether this build was given an iCloud database of its own: a container, and a team that
    /// signed for it. A build with neither (no Config/Local.xcconfig) must not open CloudKit,
    /// which ends the process rather than failing. Pure, for tests.
    static func isSetUp(container: String, team: String?) -> Bool {
        !container.isEmpty && !(team ?? "").isEmpty
    }

    /// The one rule for whether a process may use iCloud: it is entitled to the container and
    /// wasn't started with `--disable-icloud`. Pure, for tests.
    static func mayUseCloud(arguments: [String], entitled: Bool) -> Bool {
        entitled && !arguments.contains("--disable-icloud")
    }

    /// Never construct a CloudKit container in an unentitled local Mac build: CloudKit can
    /// terminate the process instead of returning an error. Device builds are provisioned against
    /// their requested container at signing time; Simulator callers skip CloudKit separately.
    static var hasContainerEntitlement: Bool {
        #if STRESS_DEVICE_AUDIT
        return false
        #elseif os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                task, "com.apple.developer.icloud-container-identifiers" as CFString, nil
              ) as? [String] else { return false }
        return value.contains(containerID)
        #else
        return isSetUp(container: containerID, team: BuildConfig.value("BananaTeamID"))
        #endif
    }
}

/// What the build's config put in the Info.plist. A setting left empty there reads as none.
enum BuildConfig {
    static func value(_ key: String, in info: [String: Any]? = Bundle.main.infoDictionary) -> String? {
        let text = (info?[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    /// The Google sign-in client, or none: with no client configured the Info.plist holds only
    /// the fixed ending, ".apps.googleusercontent.com".
    static func googleClientID(in info: [String: Any]? = Bundle.main.infoDictionary) -> String? {
        value("GIDClientID", in: info).flatMap { $0.hasPrefix(".") ? nil : $0 }
    }
}

/// The root for all locally persisted app state.
///
/// Prod resolves to the same directory the app has always used, byte-for-byte — no migration.
/// The Beta variant (compiled with `BANANA_BETA`) diverts everything into its own subfolder so
/// a test build on the same machine can never read or clobber daily-driver data. This matters
/// on the Mac in particular: the app is not sandboxed there, so both variants would otherwise
/// share `~/Library/Application Support` (caches and per-bundle UserDefaults are already
/// naturally separated; this covers the JSON stores, downloads, and recordings).
enum AppSupport {
    static let directory: URL = {
        HealthFileProtection.protectApplicationPreferences()
        #if STRESS_DEVICE_AUDIT
        PhysicalStressReview.requireValidLaunch()
        #endif
        #if DEBUG && (targetEnvironment(simulator) || os(macOS) || STRESS_DEVICE_AUDIT)
        // Stress fixtures must never land in a normal Simulator or native Mac store.
        if ProcessInfo.processInfo.arguments.contains("--stress-days") {
            return ScaleStressFixtureDirectory.make(in: FileManager.default.temporaryDirectory)
        }
        #endif
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #if BANANA_BETA
        let dir = base.appendingPathComponent("Banana Beta", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        HealthFileProtection.protectLegacyFiles(in: dir)
        return dir
        #else
        HealthFileProtection.protectLegacyFiles(in: base)
        return base
        #endif
    }()
}

/// The stress fixture's isolated store: a fresh folder per launch under the temporary directory,
/// after the previous launches' folders are removed. Nothing else ever removed them: on
/// 30 Oct 2026 the iPad's review app held 1.1 GB of them, 11–12 MB per launch.
enum ScaleStressFixtureDirectory {
    static let prefix = "ScaleStress-"

    static func make(in temporary: URL, fileManager: FileManager = .default) -> URL {
        removeStale(in: temporary, fileManager: fileManager)
        let isolated = temporary.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        try? fileManager.createDirectory(at: isolated, withIntermediateDirectories: true)
        return isolated
    }

    /// Removes every `ScaleStress-*` entry directly under `temporary`; returns what went.
    @discardableResult
    static func removeStale(in temporary: URL, fileManager: FileManager = .default) -> [URL] {
        let entries = (try? fileManager.contentsOfDirectory(
            at: temporary, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return entries.filter { $0.lastPathComponent.hasPrefix(prefix) }
            .filter { (try? fileManager.removeItem(at: $0)) != nil }
    }
}

/// Which of the two apps this is, and what the Beta may change outside itself.
///
/// The rule (10 Oct 2026, the author: stable and beta side by side on every device with "no
/// intermingling of any data"): **Beta changes nothing that Stable can see unless it was marked
/// as Beta's.** Its files, iCloud and settings were already its own. This covers what lives
/// outside both apps: Google accounts, Apple Reminders, Apple Health, and the local network.
/// Reading is not mixing, so Beta still reads the real calendar, reminders and Health.
enum AppVariant: Equatable {
    case production
    case beta

    static let current: AppVariant = {
        #if BANANA_BETA
        .beta
        #else
        .production
        #endif
    }()

    /// The nearby-devices service each app announces and looks for (1 to 15 characters). With
    /// one name for both, a Stable phone listed a Beta Mac as a peer.
    var peerServiceType: String {
        self == .beta ? "banana-beta" : "banana-audio"
    }

    /// The keychain item holding Google sign-ins. A different name, because where the keychain
    /// doesn't separate apps by access group (a Mac build signed without one) the name is all
    /// that keeps Beta's "Disconnect" from deleting Stable's accounts.
    var googleKeychainService: String {
        self == .beta ? "com.boris.banana.beta.google-accounts" : "com.boris.banana.google-accounts"
    }

    /// The Mac's earlier bundle id for `bundleID`, whose saved settings are carried over once:
    /// `<id>.mac` before Stable took the iPhone's id (July 2026), `<id>.mac.beta` before Beta did
    /// (18 Oct 2026).
    static func legacyMacBundleID(_ bundleID: String?) -> String? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        if bundleID.hasSuffix(".beta") { return bundleID.dropLast(".beta".count) + ".mac.beta" }
        return bundleID + ".mac"
    }

    var mailKeychainService: String {
        self == .beta ? "com.boris.banana.beta.google-mail" : "com.boris.banana.google-mail"
    }

    /// The one Reminders list Beta writes to, made the first time it needs one.
    static let betaRemindersList = "Banana Beta"

    /// Whether a reminder in the list titled `list` may be saved or removed.
    func mayChangeReminder(inListTitled list: String?) -> Bool {
        self == .production || list == Self.betaRemindersList
    }

    /// Whether workouts may be saved to Apple Health. Beta's stay in Beta.
    var mayWriteHealth: Bool { self == .production }

    /// Whether a Google Calendar call may be made. Reads always; changes from Beta only in an
    /// account marked as a test account in Beta's Settings.
    func mayCallGoogle(method: String, account: String?, testAccounts: Set<String>) -> Bool {
        if self == .production || method.uppercased() == "GET" { return true }
        guard let account else { return false }
        return testAccounts.contains(account.lowercased())
    }
}

/// The Google accounts Beta may change, by lowercased email. Kept in Beta's own settings.
enum BetaTestAccounts {
    private static let key = "betaTestGoogleAccounts"

    static var all: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func set(_ email: String, isTest: Bool) {
        var accounts = all
        if isTest { accounts.insert(email.lowercased()) } else { accounts.remove(email.lowercased()) }
        UserDefaults.standard.set(accounts.sorted(), forKey: key)
    }
}
