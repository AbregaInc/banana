#if os(macOS)
import AppKit

/// The Mac's pushes: the Banana service says a Google calendar changed (`BananaAccount`). macOS
/// delivers push registration and pushes only to an application delegate. Without push on the
/// Mac's App ID registration fails quietly, and the calendar poll carries on as before.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard BananaService.isAvailable else { return }
        NSApplication.shared.registerForRemoteNotifications()
        // At launch too, not only when the Mac is switched to: a Mac opened in the background, or
        // left running for days without a click, still joins the account and keeps its watches.
        MainActor.assumeIsolated {
            BananaAccount.shared.start()
            // The data platform's engine, unless `--no-space-sync` (`SpaceSyncFlag`).
            SpaceSyncLaunch.startIfAsked()
        }
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        MainActor.assumeIsolated { BananaAccount.shared.pushTokenArrived(deviceToken) }
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        MainActor.assumeIsolated { PlaybackDiagnostics.shared.log("☁️ push", "not available: \(error.localizedDescription)") }
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        if BananaService.isSyncPush(userInfo) {
            Task { @MainActor in _ = await SpaceSyncLaunch.handlePush() }
            return
        }
        if let id = BananaService.alertClearID(userInfo) {
            Task { @MainActor in EventAlerts.cleared(id, tellService: false) }
            return
        }
        guard BananaService.isCalendarPush(userInfo) else { return }
        Task { @MainActor in
            PlaybackDiagnostics.shared.log("☁️ push", "calendar changed (\(NSApplication.shared.isActive ? "in front" : "behind"))")
            await SmartScheduleStore.shared.calendarChangedElsewhere()
        }
    }
}
#endif
