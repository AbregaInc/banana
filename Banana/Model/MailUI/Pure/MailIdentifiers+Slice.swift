#if !BANANA_PUBLIC
import Foundation

/// The identifiers of the first screens' controls beyond the list's own: the columns, the open
/// conversation and its header. Foundation only, like every `MailIdentifiers*.swift`: the UI tests
/// compile these files too.
extension MailID {
    static let conversation = "mail.conversation"
    /// The subject at the top of a conversation, in the reading pane and open full width alike: what a
    /// UI test reads to know which conversation the cursor is on.
    static let conversationTitle = "mail.conversation.title"
    static let back = "mail.conversation.back"
    static let newer = "mail.conversation.newer"
    static let older = "mail.conversation.older"
    static let done = "mail.conversation.done"
    static let star = "mail.conversation.star"
    static let unread = "mail.conversation.unread"
    /// The line that says this is sample mail.
    static let sampleNote = "mail.list.sampleNote"

    // The columns.
    static let control = "mail.control"
    static let pane = "mail.pane"
    static let details = "mail.details"
    static let togglePane = "mail.list.togglePane"
    static let toggleDetails = "mail.pane.toggleDetails"
    static let expand = "mail.pane.expand"
    /// The header's menu of places, where there is no control column.
    static let placeMenu = "mail.list.placeMenu"

    /// One place in the control column, by its title: `mail.control.place.Inbox`.
    static func place(_ title: String) -> String {
        control + ".place." + title
    }
}

#endif
