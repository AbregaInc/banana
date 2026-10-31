#if os(iOS)
// Catches what iOS delivers only to an app delegate: background-URLSession completion, and the
// silent pushes that wake the app for the meal backlog. macOS has no such relaunch.

import UIKit

/// Background downloads, the meal backlog's pushes (`MealBacklogWake`), and the Banana service's
/// pushes when a Google calendar changes (`BananaAccount`).
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
            TripLearningService.shared.startIfEnabled()
            // The data platform's engine, unless `--no-space-sync` (`SpaceSyncFlag`).
            SpaceSyncLaunch.startIfAsked()
            // The meal backlog's pushes (`MealBacklogWake`): asked for here, with launch done, and
            // again on each return to the front (a scene app's delegate hears no "became active").
            MealBacklogWake.registerForPush()
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                   object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { MealBacklogWake.registerForPush() }
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
        MainActor.assumeIsolated {
            WakeCoordinator.shared.downloads.handleBackgroundEvents(
                identifier: identifier,
                completion: completionHandler)
        }
    }

    // MARK: - Pushes for the meal backlog

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        MainActor.assumeIsolated {
            MealBacklogWake.registered()
            BananaAccount.shared.pushTokenArrived(deviceToken)
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        MainActor.assumeIsolated {
            MealBacklogWake.registrationFailed(error)
            PlaybackDiagnostics.shared.log("☁️ push", "not available: \(error.localizedDescription)")
        }
    }

    /// iCloud woke the app: the Mac (or the iPad) changed the meal backlog. A few seconds to fetch
    /// it and ask about anything new, then back to sleep.
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
        guard MealBacklogWake.isMealsPush(userInfo) else { return completionHandler(.noData) }
        let done = UncheckedSendableBox(completionHandler)
        Task { @MainActor in
            let changed = await MealBacklogWake.catchUp(reason: "push")
            done.value(changed ? .newData : .noData)
        }
    }
}

/// Carries iOS's completion handler into the task that calls it, once, on the main actor.
private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
#endif
