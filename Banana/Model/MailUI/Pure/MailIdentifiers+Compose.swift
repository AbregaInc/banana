#if !BANANA_PUBLIC
import Foundation

/// The identifiers of the composer's controls, and of what writing leaves in a conversation.
/// Foundation only, like every `MailIdentifiers*.swift`: the UI tests compile these files too.
extension MailID {
    static let composer = "mail.composer"
    static let composerTo = "mail.composer.to"
    static let composerSubject = "mail.composer.subject"
    static let composerBody = "mail.composer.body"
    static let composerQuote = "mail.composer.quote"
    static let composerSuggestions = "mail.composer.suggestions"
    static let send = "mail.composer.send"
    static let sendAndDone = "mail.composer.sendAndDone"
    static let discard = "mail.composer.discard"
    /// The line that says nothing in the composer is really sent.
    static let composerSampleNote = "mail.composer.sampleNote"
    /// The list's pencil: a new message.
    static let compose = "mail.list.compose"
    /// The conversation header's and the pane's menu: reply, reply to all, forward.
    static let replyMenu = "mail.conversation.reply"
    /// What a kept draft leaves at the foot of its conversation, and the button that goes back to it.
    static let draftMarker = "mail.conversation.draft"
    static let continueDraft = "mail.conversation.draft.continue"

    /// One suggestion under the To field, by its address.
    static func suggestion(_ address: String) -> String {
        composerSuggestions + "." + address
    }
}

#endif
