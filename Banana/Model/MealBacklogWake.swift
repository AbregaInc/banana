import CloudKit
import Foundation
#if os(iOS)
import UIKit
#endif

/// How the meal backlog moves between devices without anyone opening anything.
///
/// The backlog syncs through its own zone (`CloudControlsSync.meals`), started at launch — its
/// stores need no window — so a background launch can fetch it. Two things wake the iPhone for it:
/// - **A push for that zone only** (`CKRecordZoneSubscription`, silent): the Mac finds a meal photo,
///   saves the meal, and iCloud wakes the iPhone for a few seconds to fetch it and ask "What did you
///   eat at 12:40?". Nothing else in iCloud wakes it — listening progress, workouts and the rest
///   still wait for the app to open. This needs push for the app (the `aps-environment`
///   entitlement); until then registration fails quietly and the next point carries it.
/// - **The scanner's background task** (`MealPhotoScanner`), which starts with the same catch-up.
///
/// Either way it ends the same: fetch the zone, ask about anything new (`MealPhotoNotifications`),
/// and let the estimating pick up anything answered elsewhere (`MealBacklogProcessor`).
@MainActor
enum MealBacklogWake {
    static let subscriptionID = "meals-zone-changes"
    private static let subscribedKey = "mealsPush.subscribed.v1"
    private static let registeredKey = "mealsPush.registeredAt"

    /// Starts the backlog's sync. At launch, before any window.
    static func startSync() {
        let meals = CloudControlsSync.meals
        meals.register(MealInboxStore.shared, for: .mealInbox)
        meals.register(MealPhotoStore.shared, for: .mealPhoto)
        meals.register(MealPhotoLedger.shared, for: .mealPhotoFound)
        meals.start()
    }

    #if os(iOS)
    /// Asks iOS for this launch's push token — once launch has finished, and again each time the app
    /// comes to the front (cheap, and what Apple asks for: a token can change). Asked for during the
    /// app's own init, the iPhone never answered.
    static func registerForPush() {
        UIApplication.shared.registerForRemoteNotifications()
    }
    #endif

    // MARK: - Push

    /// Whether this device can be woken by a push: it registered, at some point, successfully.
    static var pushReady: Bool { UserDefaults.standard.object(forKey: registeredKey) != nil }

    static func registered() {
        UserDefaults.standard.set(Date(), forKey: registeredKey)
        Task { await subscribe() }
    }

    static func registrationFailed(_ error: Error) {
        UserDefaults.standard.removeObject(forKey: registeredKey)
        PlaybackDiagnostics.shared.log("🍽 push", "not available: \(error.localizedDescription)")
    }

    /// The backlog zone's subscription: a silent push to this device's other devices when anything
    /// in it changes. Saved once; saving it again is harmless (same id).
    private static var subscribing = false

    private static func subscribe() async {
        // Moved off iCloud (`LegacyCloud`): no subscription is saved any more.
        guard CloudSyncPoll.isAllowed, LegacyCloud.mayWrite(.health),
              !UserDefaults.standard.bool(forKey: subscribedKey), !subscribing else { return }
        subscribing = true
        defer { subscribing = false }
        let subscription = CKRecordZoneSubscription(zoneID: CloudControlsSync.meals.zoneID,
                                                    subscriptionID: subscriptionID)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true   // silent: a fetch, never a banner of its own
        subscription.notificationInfo = info
        do {
            _ = try await CKContainer(identifier: AppCloud.containerID).privateCloudDatabase
                .modifySubscriptions(saving: [subscription], deleting: [])
            UserDefaults.standard.set(true, forKey: subscribedKey)
            PlaybackDiagnostics.shared.log("🍽 push", "subscribed to the meals zone")
        } catch {
            // The zone may not exist yet on a first launch: tried again next launch.
            PlaybackDiagnostics.shared.log("🍽 push", "subscription deferred: \(error.localizedDescription)")
        }
    }

    /// Whether a remote notification is the backlog zone's.
    nonisolated static func isMealsPush(_ userInfo: [AnyHashable: Any]) -> Bool {
        CKNotification(fromRemoteNotificationDictionary: userInfo)?.subscriptionID == subscriptionID
    }

    // MARK: - Catching up

    /// Fetches the backlog zone, then asks about anything new and lets estimating start. True when
    /// something arrived. For a push or a background task: returns once done.
    @discardableResult
    static func catchUp(reason: String) async -> Bool {
        let before = Set(MealInboxStore.shared.items.map { "\($0.id)\($0.state)" })
        await CloudControlsSync.meals.fetchNow()
        let changed = Set(MealInboxStore.shared.items.map { "\($0.id)\($0.state)" }) != before
        #if os(iOS)
        await MealPhotoNotifications.askAboutNew()
        #endif
        if changed { MealBacklogProcessor.shared.kick() }
        PlaybackDiagnostics.shared.log("🍽 catch-up", "\(reason): \(changed ? "backlog changed" : "nothing new")")
        return changed
    }
}
