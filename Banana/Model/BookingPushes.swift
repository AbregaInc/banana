import Foundation
import UserNotifications
#if os(macOS)
import AppKit
#endif

/// The service's pushes about bookings (`pushHost` in `Service/src/booking/book.js`): a guest
/// booked, moved or cancelled. They show over the app as well as behind it. A tap opens the event
/// on the Plan (iPhone, iPad, Mac); a cancelled booking opens the Plan on its day; a push that
/// names neither, or an event that can't be found, opens the Plan.
@MainActor
enum BookingPushes {
    /// Opened: the Plan, then what the push points at (`PlanOpenRequests`).
    static func opened(_ notification: UNNotification) {
        let target = BananaService.bookingTarget(notification.request.content.userInfo)
        PlaybackDiagnostics.shared.log("🔔 booking", "opened (\(target?.eventID == nil ? "no event" : "an event")\(target?.cancelled == true ? ", cancelled" : ""))")
        #if os(macOS)
        MacNavigator.shared.section = .plan
        NSApp.activate(ignoringOtherApps: true)
        #else
        ShellNavigation.shared.state.tab = .plan
        #endif
        PlanOpenRequests.shared.pending = target
    }

    /// The meeting a push names, among what the Plan has.
    static func meeting(for target: BananaService.BookingPushTarget, in occurrences: [Occurrence]? = nil) -> MeetingInfo? {
        guard let calendarID = target.calendarID, let eventID = target.eventID else { return nil }
        return (occurrences ?? OccurrenceStore.shared.occurrences).lazy.compactMap(\.meeting).first { meeting in
            guard let id = meeting.eventID, let route = GoogleCalendarIDs.rawEventRoute(from: id) else { return false }
            return route.calendarID == calendarID && route.eventID == eventID
        }
    }
}
