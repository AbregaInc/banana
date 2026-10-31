#if !BANANA_PUBLIC
import Foundation

/// The identifiers of the recipient rows, From, the signature, send later and what a scheduled
/// message shows. Foundation only, like every `MailIdentifiers*.swift`: the UI tests compile these
/// files too.
extension MailID {
    static let composerCc = "mail.composer.cc"
    static let composerBcc = "mail.composer.bcc"
    static let composerFrom = "mail.composer.from"
    static let composerSignature = "mail.composer.signature"
    static let composerSignatureRemove = "mail.composer.signature.remove"
    static let composerSignaturePutBack = "mail.composer.signature.putBack"
    static let composerSendLater = "mail.composer.sendLater"
    static let composerSchedule = "mail.composer.schedule"
    static let composerScheduleClear = "mail.composer.schedule.clear"

    /// "Cc" and "Bcc" at the end of the To row, by name.
    static func composerReveal(_ name: String) -> String {
        "mail.composer.reveal." + name.lowercased()
    }

    /// One address he can send as, by the address.
    static func composerFromChoice(_ address: String) -> String {
        composerFrom + "." + address
    }

    /// A chip, by the address it is for.
    static func chip(_ address: String) -> String {
        "mail.composer.chip." + address
    }

    // The time picker.
    static let timePicker = "mail.timePicker"
    static let timePickerField = "mail.timePicker.field"
    static let timePickerPast = "mail.timePicker.past"
    static func timePickerRow(_ id: String) -> String { "mail.timePicker.row." + id }

    // What a scheduled message shows in its conversation.
    static let scheduledBanner = "mail.conversation.scheduled"
    static let scheduledEdit = "mail.conversation.scheduled.edit"
    static let scheduledReschedule = "mail.conversation.scheduled.reschedule"
    static let scheduledSendNow = "mail.conversation.scheduled.sendNow"
    static let scheduledCancel = "mail.conversation.scheduled.cancel"
    static let scheduledKeep = "mail.conversation.scheduled.keep"
}

#endif
