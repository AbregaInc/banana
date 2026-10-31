import Foundation

/// "Block this day": your copy of an all-day event marked Busy — or Free again — so the day is
/// blocked here, in what Calendly and anyone else sees of your calendars, and on your other
/// calendars (write-back copies a Busy all-day event; docs/design/ALL-DAY-EVENTS.md). Shown at
/// once, written to Google, put back if Google says no; Undo after.
@MainActor
enum AllDayBlocking {
    static func set(_ meeting: MeetingInfo, busy: Bool) {
        apply(meeting, busy: busy, offeringUndo: true)
    }

    private static func apply(_ meeting: MeetingInfo, busy: Bool, offeringUndo: Bool) {
        guard let eventID = meeting.eventID else { return }
        OccurrenceStore.shared.showAvailability(eventID: eventID, busy: busy)
        Task { @MainActor in
            do {
                try await GoogleCalendarService.shared.setAvailability(of: meeting, busy: busy)
                OccurrenceStore.shared.requestRecompute(reason: busy ? "all-day event blocks its day" : "all-day event no longer blocks")
                guard offeringUndo else { return }
                await ToastCenter.shared.offerUndo(message(meeting, busy: busy)) { @MainActor in
                    apply(meeting, busy: !busy, offeringUndo: false)
                    return nil
                }
            } catch {
                OccurrenceStore.shared.showAvailability(eventID: eventID, busy: !busy)
                ToastCenter.shared.notify("Couldn\u{2019}t change \u{201C}\(meeting.title)\u{201D}: \(error.localizedDescription)")
            }
        }
    }

    /// "Saturday blocked for Sam & Ana Fun Day Trip" / "… no longer blocks Saturday".
    static func message(_ meeting: MeetingInfo, busy: Bool, calendar: Calendar = .current) -> String {
        let days = AllDayEvents.days(from: meeting.start, to: meeting.end ?? meeting.start.addingTimeInterval(86_400),
                                     calendar: calendar)
        let when = days.count > 1
            ? "\(days.count) days"
            : meeting.start.formatted(.dateTime.weekday(.wide))
        return busy
            ? "\(when) blocked for \u{201C}\(meeting.title)\u{201D}"
            : "\u{201C}\(meeting.title)\u{201D} no longer blocks \(when)"
    }
}

/// "Hide in Banana": an all-day event off Banana's calendar by title — so a birthday stays hidden
/// every year. Google won't let an app delete a birthday (they come from Google Contacts), so
/// hiding is how one goes. Synced; Settings › All-day events lists what's hidden. Undo after.
@MainActor
enum AllDayHiding {
    static func hide(_ meeting: MeetingInfo) {
        let key = AllDayEvents.titleKey(meeting.title)
        let store = SmartScheduleStore.shared
        guard !store.settings.allDayHiddenTitles.contains(key) else { return }
        OccurrenceStore.shared.hideAllDay(titleKey: key)
        store.settings.allDayHiddenTitles.insert(key)
        Task { @MainActor in
            await ToastCenter.shared.offerUndo("Hidden \u{201C}\(meeting.title)\u{201D}") { @MainActor in
                SmartScheduleStore.shared.settings.allDayHiddenTitles.remove(key)
                return nil
            }
        }
    }
}

