import Foundation
#if canImport(UserNotifications)
import UserNotifications

/// A Taken reminder can be answered from the notification: "Taken" marks the dose without
/// opening Banana, and tapping it opens Nutrition on the Taken list. It did neither; a tap
/// opened the app wherever it was last.
enum DoseReminders {
    static let category = NotificationRoute.doseCategory
    static let takenAction = NotificationRoute.doseTakenAction

    /// Call once at launch, on every device: each rings its own reminders.
    static func register() {
        let center = UNUserNotificationCenter.current()
        // Added to whatever categories exist: setting categories replaces the app's whole set.
        center.getNotificationCategories { existing in
            var categories = existing.filter { $0.identifier != category }
            categories.insert(UNNotificationCategory(
                identifier: category,
                actions: [UNNotificationAction(identifier: takenAction, title: "Taken", options: [])],
                intentIdentifiers: [], options: []))
            center.setNotificationCategories(categories)
        }
        #if os(macOS)
        // The Mac's one notification delegate: doses, event alerts and bookings.
        center.delegate = MacNotificationDelegate.shared
        #endif
    }

    static func isDose(_ response: UNNotificationResponse) -> Bool {
        SupplementSchedule.isReminder(notificationID: response.notification.request.identifier)
    }

    /// "Taken" marks today's dose; a tap opens the Taken list.
    @MainActor
    static func handle(_ response: UNNotificationResponse) async {
        let id = response.notification.request.identifier
        if response.actionIdentifier == takenAction {
            guard let supplement = DoseReminderPlan.supplementID(notificationID: id,
                                                                 prefix: SupplementSchedule.notificationPrefix) else { return }
            await WellnessStore.shared.whenLoaded()
            // The dose the reminder was for: the day it rang, not the day it was answered.
            WellnessStore.shared.logSupplement(supplement, status: .taken, at: response.notification.date)
        } else if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            ShellNavigation.shared.state.tab = .nutrition
            ShellNavigation.shared.state.nutritionSection = "Taken"
            #if os(macOS)
            MacNavigator.shared.section = .nutrition
            #endif
        }
    }
}

#endif
