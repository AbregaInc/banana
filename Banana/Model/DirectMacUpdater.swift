#if os(macOS) && BANANA_DIRECT
import SwiftUI
import Sparkle

/// Sparkle owns downloading, signature validation, installation and recovery.
/// The direct target alone links it; App Store/TestFlight builds have no updater.
@MainActor
final class DirectMacUpdater: ObservableObject {
    static let shared = DirectMacUpdater()
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyDownloadsUpdates = false
    private let controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    private var started = false

    private init() {
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .assign(to: &$automaticallyChecksForUpdates)
        controller.updater.publisher(for: \.automaticallyDownloadsUpdates)
            .assign(to: &$automaticallyDownloadsUpdates)
    }

    func start() {
        guard !started else { return }
        started = true
        controller.startUpdater()
        // Sparkle schedules subsequent checks. On launch, pick up a new release promptly
        // without overriding a saved opt-out or forcing the app to quit mid-session.
        if controller.updater.automaticallyChecksForUpdates {
            controller.updater.checkForUpdatesInBackground()
        }
    }

    func check() { controller.checkForUpdates(nil) }
    func setAutomaticChecks(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
    }
    func setAutomaticDownloads(_ enabled: Bool) {
        controller.updater.automaticallyDownloadsUpdates = enabled
    }
}

struct DirectMacUpdateButton: View {
    @ObservedObject private var updater = DirectMacUpdater.shared
    var body: some View {
        Button("Check for Updates…") { updater.check() }
            .disabled(!updater.canCheckForUpdates)
    }
}
struct DirectMacUpdateSettings: View {
    @ObservedObject private var updater = DirectMacUpdater.shared
    var body: some View {
        Section("Updates") {
            Toggle("Check for updates automatically", isOn: Binding(
                get: { updater.automaticallyChecksForUpdates },
                set: { updater.setAutomaticChecks($0) }))
            Toggle("Install updates automatically", isOn: Binding(
                get: { updater.automaticallyDownloadsUpdates },
                set: { updater.setAutomaticDownloads($0) }))
                .disabled(!updater.automaticallyChecksForUpdates)
            DirectMacUpdateButton()
        }
    }
}
#endif
