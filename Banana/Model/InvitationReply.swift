import Foundation

/// Replying to an invitation, the same from the phone's event sheet and the Mac's inspector.
///
/// Yes and Maybe go to Google at once, and the day re-reads so the event's look follows. No takes
/// the event off your day at once — you're not going — with Undo for a few seconds, and the reply
/// is sent when that window closes (`ToastCenter.deferRemoval`): a mis-tap costs nothing, and the
/// event never sits there looking accepted while the calendar catches up.
@MainActor
enum InvitationReply {
    static func send(_ response: GoogleCalendarRSVP, to meeting: MeetingInfo) async throws {
        try await GoogleCalendarService.shared.respond(to: meeting, with: response)
        await SmartScheduleStore.shared.refreshAgenda()
        await OccurrenceStore.shared.recompute(reason: "replied to an invitation")
    }

    static func decline(_ meeting: MeetingInfo) async {
        guard let id = meeting.eventID else {
            try? await send(.declined, to: meeting)
            return
        }
        await ToastCenter.shared.deferRemoval(
            id: id,
            message: GoogleCalendarRSVP.declined.confirmation(title: meeting.title),
            failure: { "Couldn\u{2019}t decline: \($0)" }
        ) {
            do {
                // The day is rebuilt from the fresh read before the event is shown again, so it
                // doesn't flash back while the calendar catches up.
                try await send(.declined, to: meeting)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
    }
}
