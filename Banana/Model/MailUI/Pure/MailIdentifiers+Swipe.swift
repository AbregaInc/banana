#if !BANANA_PUBLIC
import Foundation

/// The open conversation's pager: the conversation among its neighbours in the list, swiped
/// sideways (`MailConversationPager`).
extension MailID {
    static let pager = "mail.conversation.pager"
    /// A data table in a message, which scrolls sideways on its own (`MailTableView`).
    static let bodyTable = "mail.body.table"
}

#endif
