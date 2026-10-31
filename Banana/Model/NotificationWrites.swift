import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Every change to the notifications that are pending or shown, in the order it was asked for
/// and never on the main thread.
///
/// The system's "remove" waits for its daemon to answer. When the daemon was slow the caller
/// waited with it, and the caller was the main thread: the Nutrition page froze for as long as
/// it took (11 Oct 2026). An add goes through the same line so that it can't overtake the
/// remove that was asked for before it and be removed by it.
enum NotificationWrites {
    private static let line = DispatchQueue(label: "banana.notification-writes", qos: .utility)

    /// Runs `work` after everything asked for before it.
    static func perform(_ work: @escaping () -> Void) {
        line.async(execute: work)
    }

    #if canImport(UserNotifications)
    static func removePending(_ identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        perform { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers) }
    }

    static func removeDelivered(_ identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        perform { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers) }
    }

    static func add(_ request: UNNotificationRequest) {
        perform { UNUserNotificationCenter.current().add(request) }
    }
    #endif
}
