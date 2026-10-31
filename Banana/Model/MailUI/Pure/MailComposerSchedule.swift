#if !BANANA_PUBLIC
import Foundation

/// The time he has chosen to send a message at, before he presses the button that now says Schedule
/// (MAIL-UX 6.3.6). It is the composer's and the draft's, so a view tree thrown away behind a
/// backgrounded phone does not forget it.
extension MailComposerModel {

    func chooseSchedule(_ date: Date) {
        schedule = date
        timePicker = nil
        edited()
    }

    /// The picker, open: ⇧⌘L, or the clock beside Send. Shut by the same.
    func toggleTimePicker() {
        timePicker = timePicker == nil ? MailTimePickerModel(now: clock, holder: .thisDevice(name: device)) : nil
    }

    func clearSchedule() {
        guard schedule != nil else { return }
        schedule = nil
        edited()
    }

    /// "Sends Thu 8:00 AM": under the footer once a time is chosen.
    var scheduleLine: String? {
        schedule.map { MailScheduleCopy.sendsAt($0, now: clock()) }
    }

    /// The time has gone by while he wrote: it is not one to send at.
    func schedulePassed(now: Date) -> Bool {
        guard let schedule else { return false }
        return schedule <= now
    }
}

#endif
