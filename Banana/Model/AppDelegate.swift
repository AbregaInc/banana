#if os(iOS)
// Catches what iOS delivers only to an app delegate: background-URLSession completion, and the
// silent pushes that wake the app for Banana data. macOS has no such relaunch.

import UIKit

/// Background downloads and silent pushes from the Banana service.
///
/// When a transfer finishes while the app is suspended — or after it has been killed outright —
/// iOS relaunches the process and delivers the news here, and nowhere else. A SwiftUI `App` has no
/// hook for it, so it needs a delegate. Without this, a download that completed in the background
/// is never moved into place and never appears; with it, the episode is simply there when you open
/// the app, which is the entire promise of downloading in the first place.
final class AppDelegate: NSObject, UIApplicationDelegate {

    /// iOS relaunches the app in the background to deliver a visit; the location manager has to
    /// exist, with its delegate, before launch finishes for that visit to arrive.
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        #if STRESS_DEVICE_AUDIT
        // The dedicated fixture app must not register pushes or start location
        // learning before its guarded visual route is installed.
        PhysicalStressReview.requireValidLaunch()
        return true
        #else
        MainActor.assumeIsolated {
            #if BANANA_FEATURE_TRIP_LEARNING
            TripLearningService.shared.startIfEnabled()
            #endif
            // The data platform's engine, unless `--no-space-sync` (`SpaceSyncFlag`).
            SpaceSyncLaunch.startIfAsked()
            // Register for Banana service pushes once launch finishes,
            // and again on each return to the front (a scene app's delegate hears no "became active").
            UIApplication.shared.registerForRemoteNotifications()
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                   object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { UIApplication.shared.registerForRemoteNotifications() }
            }
        }
        return true
        #endif
    }

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        // Hold the handler; DownloadManager calls it once the session has finished delivering its
        // events. Dropping it on the floor gets the app marked as misbehaving, and iOS answers by
        // being stingy with background time — which would break the very thing we're fixing.
        #if BANANA_MODULE_PODCASTS
        MainActor.assumeIsolated {
            WakeCoordinator.shared.downloads.handleBackgroundEvents(
                identifier: identifier,
                completion: completionHandler)
        }
        #else
        completionHandler()
        #endif
    }

    // MARK: - Push notifications

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        MainActor.assumeIsolated {
            BananaAccount.shared.pushTokenArrived(deviceToken)
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        MainActor.assumeIsolated {
            PlaybackDiagnostics.shared.log("☁️ push", "not available: \(error.localizedDescription)")
        }
    }

    /// Dispatch a silent push to the corresponding Banana service handler.
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        // Read here, where the dictionary arrives; only the answer crosses into the fetch.
        if BananaService.isSyncPush(userInfo) {
            // The Banana service: the account's data changed on another device. The completion
            // goes when the pass ends or after 25 s; the pass goes on under a background task.
            let done = UncheckedSendableBox(completionHandler)
            MainActor.assumeIsolated { SpaceSyncLaunch.handlePush { done.value($0) } }
            return
        }
        if let id = BananaService.alertClearID(userInfo) {
            // An alert dismissed on another device: take it down here.
            let done = UncheckedSendableBox(completionHandler)
            Task { @MainActor in
                EventAlerts.cleared(id, tellService: false)
                done.value(.newData)
            }
            return
        }
        if BananaService.isMailPush(userInfo) {
            // A cloud mailbox stored new mail: one feed pull and its text, under a background task.
            let done = UncheckedSendableBox(completionHandler)
            MainActor.assumeIsolated { MailPushWake.handle { done.value($0) } }
            return
        }
        if BananaService.isCalendarPush(userInfo) {
            // The Banana service: a Google calendar changed.
            let inFront = application.applicationState == .active
            let done = UncheckedSendableBox(completionHandler)
            Task { @MainActor in
                PlaybackDiagnostics.shared.log("☁️ push", "calendar changed (\(inFront ? "in front" : "in the background"))")
                await SmartScheduleStore.shared.calendarChangedElsewhere()
                done.value(.newData)
            }
            return
        }
        completionHandler(.noData)
    }
}

/// Carries iOS's completion handler into the task that calls it, once, on the main actor.
private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
#endif
