import Foundation
import UserNotifications

/// Event alerts shared with the Banana service (docs/design/EVENT-ALERTS.md).
///
/// The service rings for calendar changes it hears of from Google; this device keeps its own
/// local alerts as the fallback, under the same ids (`calendarId|eventId|lead`), and tells the
/// service which ones it holds, so nothing rings twice here. Dismissing or opening an alert on
/// any device clears it on the others.
@MainActor
enum EventAlerts {
    static let alertCategory = NotificationRoute.eventAlertCategory
    static let inviteCategory = NotificationRoute.eventInviteCategory
    static let acceptAction = "EVENT_ACCEPT"
    static let declineAction = "EVENT_DECLINE"
    /// Local alerts are `banana.event.<shared id>`; the prefix is what `NotificationService` sweeps.
    static let localPrefix = NotificationRoute.eventLocalPrefix

    /// The shared id of one alert of an event: the calendar and event ids out of the event's info
    /// id, and the lead (minutes, or "now"). Nil for an event that isn't Google's.
    static func sharedID(infoID: String, lead: String) -> String? {
        let id = BananaService.alertID(planItemID: "\(infoID)#\(lead)")
        return id.contains("|") ? id : nil
    }

    /// The calendar and event of a shared id.
    static func route(of id: String) -> (calendarID: String, eventID: String)? { BananaService.alertRoute(of: id) }

    // MARK: - Categories and delegate work

    /// Call once at launch, on every device: the alert's dismissal is heard (`customDismissAction`),
    /// and an invitation offers Accept / Decline.
    static func register() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationCategories { existing in
            var categories = existing.filter { $0.identifier != alertCategory && $0.identifier != inviteCategory }
            categories.insert(UNNotificationCategory(identifier: alertCategory, actions: [], intentIdentifiers: [],
                                                     options: [.customDismissAction]))
            categories.insert(UNNotificationCategory(
                identifier: inviteCategory,
                actions: [UNNotificationAction(identifier: acceptAction, title: "Accept", options: []),
                          UNNotificationAction(identifier: declineAction, title: "Decline", options: [.destructive])],
                intentIdentifiers: [], options: [.customDismissAction]))
            center.setNotificationCategories(categories)
        }
    }

    static func isAlert(_ notification: UNNotification) -> Bool {
        let content = notification.request.content
        return content.categoryIdentifier == alertCategory || content.categoryIdentifier == inviteCategory
            || notification.request.identifier.hasPrefix(localPrefix)
    }

    /// The shared id a notification is about: the service's (`b.id`) or this device's own.
    static func id(of notification: UNNotification) -> String? {
        if let id = (notification.request.content.userInfo["b"] as? [AnyHashable: Any])?["id"] as? String { return id }
        let identifier = notification.request.identifier
        return identifier.hasPrefix(localPrefix) ? String(identifier.dropFirst(localPrefix.count)) : nil
    }

    /// Dismissed, opened, accepted or declined here: the other devices stop showing it too.
    static func handle(_ response: UNNotificationResponse) async {
        guard let id = id(of: response.notification) else { return }
        let userInfo = response.notification.request.content.userInfo["b"] as? [AnyHashable: Any]
        switch response.actionIdentifier {
        case acceptAction, declineAction:
            let reply: GoogleCalendarRSVP = response.actionIdentifier == acceptAction ? .accepted : .declined
            if let route = route(of: id) {
                do {
                    try await GoogleCalendarService.shared.respondToInvite(calendarID: route.calendarID, eventID: route.eventID, with: reply)
                    PlaybackDiagnostics.shared.log("🔔 alert", "replied \(reply.rawValue) from the notification")
                } catch {
                    PlaybackDiagnostics.shared.log("🔔 alert", "reply failed: \(error.localizedDescription)")
                }
            }
        case UNNotificationDefaultActionIdentifier:
            PlaybackDiagnostics.shared.log("🔔 alert", "opened (\(userInfo == nil ? "this device's" : "the service's"))")
        default:
            PlaybackDiagnostics.shared.log("🔔 alert", "dismissed (\(userInfo == nil ? "this device's" : "the service's"))")
        }
        cleared(id, tellService: true)
    }

    /// An alert is done, here or elsewhere: whatever this device shows or holds for it goes. The
    /// service is told only when it happened here (`tellService`).
    static func cleared(_ id: String, tellService: Bool) {
        let center = UNUserNotificationCenter.current()
        NotificationWrites.removePending([localPrefix + id])
        center.getDeliveredNotifications { delivered in
            let gone = delivered.filter { note in
                note.request.identifier == localPrefix + id
                    || ((note.request.content.userInfo["b"] as? [AnyHashable: Any])?["id"] as? String) == id
            }.map(\.request.identifier)
            if !gone.isEmpty { NotificationWrites.removeDelivered(gone) }
        }
        if tellService { Task { await BananaAccount.shared.clearAlert(id) } }
        else { PlaybackDiagnostics.shared.log("🔔 alert", "cleared from another device") }
    }

    /// The alert ids already showing on this device (the service's pushes and this device's own):
    /// a local alert isn't scheduled for one of these.
    static func deliveredIDs() async -> Set<String> {
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        return Set(delivered.compactMap { id(of: $0) })
    }

    /// The alert ids this device holds as pending local notifications.
    static func heldIDs() async -> [String] {
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        return pending.map(\.identifier).filter { $0.hasPrefix(localPrefix) }.map { String($0.dropFirst(localPrefix.count)) }
    }
}
