#if os(macOS)
import Foundation
import UserNotifications

/// The Mac's one notification delegate (set by `DoseReminders.register`), as the iPhone's is
/// `MealPhotoNotificationDelegate`; both follow `NotificationRoute`. Taken's reminders, event
/// alerts and bookings show while Banana is in front; "Taken" marks the dose, a reminder's tap
/// opens the Taken list, an event alert's answer clears it everywhere, and a booking's tap opens
/// its event on the Plan.
final class MacNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MacNotificationDelegate()

    static func route(_ notification: UNNotification) -> NotificationRoute {
        let request = notification.request
        return NotificationRoute.of(identifier: request.identifier, category: request.content.categoryIdentifier,
                                    userInfo: request.content.userInfo)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(Self.route(notification).showsInFront ? [.banner, .list, .sound] : [])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = Self.route(response.notification).action(response.actionIdentifier)
        Task { @MainActor in
            switch action {
            case .eventAlert: await EventAlerts.handle(response)
            case .markDoseTaken, .openTakenList: await DoseReminders.handle(response)
            case .openBooking: BookingPushes.opened(response.notification)
            case .mealPhoto, .nothing: break   // meal photos are the iPhone's
            }
            completionHandler()
        }
    }
}
#endif
