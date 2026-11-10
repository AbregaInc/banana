#if !BANANA_PUBLIC
import SwiftUI

/// Where an invitation's event is found and answered: the calendar's own lookup and reply path.
struct MailInviteCalendar {
    var find: @MainActor (_ account: String, _ uid: String) async -> MailInviteEvent?
    var answer: @MainActor (_ event: MailInviteEvent, _ response: GoogleCalendarRSVP) async throws -> Void
    var decline: @MainActor (_ event: MailInviteEvent) async -> Void

    /// The account's own calendar, looked up by the invitation's identifier; answered as the week
    /// view answers (`InvitationReply`): Yes and Maybe at once, No with the calendar's Undo.
    static let live = MailInviteCalendar(
        find: { account, uid in
            guard let events = try? await GoogleCalendarService.shared.events(calendarID: account, iCalUID: uid) else { return nil }
            return MailInviteEvent.pick(events, calendarID: account)
        },
        answer: { event, response in try await InvitationReply.send(response, to: meeting(event)) },
        decline: { event in await InvitationReply.decline(meeting(event)) })

    /// Sample mail: an event made up for the invitation, answered nowhere (mail's routes never
    /// touch a calendar).
    static let sample = MailInviteCalendar(
        find: { _, _ in
            let start = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date().addingTimeInterval(86_400)) ?? Date()
            return MailInviteEvent(calendarID: "sample", eventID: "sample", title: "Design review",
                                   start: start, end: start.addingTimeInterval(45 * 60), isAllDay: false, response: nil)
        },
        answer: { _, _ in },
        decline: { _ in })

    @MainActor private static func meeting(_ event: MailInviteEvent) -> MeetingInfo {
        MeetingInfo(start: event.start, end: event.end, coordinate: nil, address: nil, isVirtual: false,
                    title: event.title, eventID: event.infoID, calendarID: event.calendarID, isAllDay: event.isAllDay)
    }
}

/// An invitation answered in place (MAIL-UX 9.1): the calendar's event, when, and Yes · No · Maybe,
/// the current answer filled. It moves nothing in Mail. An invitation whose event the calendar
/// can't find shows no card; the message's own words are still there.
struct MailInviteCard: View {
    let account: String
    let invite: MailInvite
    let calendar: MailInviteCalendar
    @State private var event: MailInviteEvent?
    /// The answer as he chose it, shown at once; put back if the calendar refuses it.
    @State private var chosen: GoogleCalendarRSVP?

    var body: some View {
        // Something is always there, so the lookup runs: an empty group never appears.
        Group {
            if let event {
                card(event)
            } else {
                Color.clear.frame(height: 0)
            }
        }
        .task(id: invite.uid) {
            event = await calendar.find(account, invite.uid)
            chosen = event?.response
        }
    }

    private func card(_ event: MailInviteEvent) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(alignment: .top, spacing: DS.Space.s) {
                Image(systemName: "calendar")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: DS.Mail.face)
                VStack(alignment: .leading, spacing: DS.Space.hair) {
                    Text(event.title.isEmpty ? "Invitation" : event.title)
                        .font(.headline)
                        .lineLimit(2)
                    Text(when(event))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: DS.Space.s) {
                answer("Yes", .accepted, event)
                answer("No", .declined, event)
                answer("Maybe", .tentative, event)
            }
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(DS.Tint.wash),
                    in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mail.invite")
    }

    private func when(_ event: MailInviteEvent) -> String {
        let day = event.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        return event.isAllDay ? day : "\(day) \u{00B7} \(TimeRangeText.compact(event.start, event.end))"
    }

    @ViewBuilder
    private func answer(_ title: String, _ response: GoogleCalendarRSVP, _ event: MailInviteEvent) -> some View {
        let isChosen = chosen == response
        Button { send(response, event) } label: {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(isChosen ? .primarySmall : .secondarySmall)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
        .accessibilityIdentifier("mail.invite." + response.rawValue)
    }

    private func send(_ response: GoogleCalendarRSVP, _ event: MailInviteEvent) {
        guard chosen != response else { return }
        let before = chosen
        chosen = response
        Task {
            if response == .declined {
                await calendar.decline(event)
                return
            }
            do {
                try await calendar.answer(event, response)
                ToastCenter.shared.notify(response.confirmation(title: event.title))
            } catch {
                chosen = before
                ToastCenter.shared.notify("Couldn\u{2019}t reply: \(error.localizedDescription)")
            }
        }
    }
}

#endif
