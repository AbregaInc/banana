import Foundation
import UserNotifications

/// What a notification is, and what a response to it does: the one rule both of the app's
/// notification delegates follow (the iPhone's `MealPhotoNotificationDelegate`, the Mac's
/// `MacNotificationDelegate`), so a kind added on one device can't go missing on the other. Pure,
/// over the request's identifier, category and payload, for tests.
enum NotificationRoute: Equatable, Sendable {
    /// An event alert or invitation, the service's or this device's own (`EventAlerts`).
    case eventAlert
    /// A Taken reminder (`SupplementSchedule`, `DoseReminders`).
    case dose
    /// A guest booked, moved or cancelled (`BookingPushes`).
    case booking
    /// "What did you eat?" (`MealPhotoNotifications`, the iPhone's).
    case mealPhoto
    case other

    static let eventAlertCategory = "EVENT_ALERT"
    static let eventInviteCategory = "EVENT_INVITE"
    /// This device's own event alerts are `banana.event.<shared id>`.
    static let eventLocalPrefix = "banana.event."
    static let doseCategory = "TAKEN_DOSE"
    static let doseTakenAction = "TAKEN_DOSE_TAKEN"
    static let mealPhotoCategory = "MEAL_PHOTO"
    /// A tap on the notification itself.
    static let tap = UNNotificationDefaultActionIdentifier

    static func of(identifier: String, category: String, userInfo: [AnyHashable: Any]) -> NotificationRoute {
        if category == eventAlertCategory || category == eventInviteCategory || identifier.hasPrefix(eventLocalPrefix) {
            return .eventAlert
        }
        if SupplementSchedule.isReminder(notificationID: identifier) { return .dose }
        if BananaService.isBookingPush(userInfo) { return .booking }
        if category == mealPhotoCategory { return .mealPhoto }
        return .other
    }

    /// Shown while Banana is in front: a meeting starting, a dose due (ticking "Workout" makes
    /// Creatine due right then) and a booking are worth a banner wherever you are.
    var showsInFront: Bool { [.eventAlert, .dose, .booking].contains(self) }

    /// What answering it does.
    enum Action: Equatable, Sendable {
        /// `EventAlerts.handle`: Accept, Decline, opened or dismissed, cleared everywhere.
        case eventAlert
        case markDoseTaken
        case openTakenList
        case openBooking
        case mealPhoto
        case nothing
    }

    func action(_ identifier: String) -> Action {
        switch self {
        case .eventAlert: .eventAlert
        case .dose: identifier == Self.doseTakenAction ? .markDoseTaken : identifier == Self.tap ? .openTakenList : .nothing
        case .booking: identifier == Self.tap ? .openBooking : .nothing
        case .mealPhoto: .mealPhoto
        case .other: .nothing
        }
    }
}
