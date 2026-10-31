#if !BANANA_PUBLIC
import Foundation

/// Plain facts about one conversation, prepared once when the conversation arrives, for the
/// details column: who is in it, when, how many messages, what was attached. The column draws
/// these and works nothing out; this is where enrichment (the calendar, a contact's history)
/// will join later.
struct MailConversationFacts: Equatable, Sendable {

    struct Participant: Equatable, Identifiable, Sendable {
        /// The address, lower-cased.
        var id: String
        /// Nil when the engine withheld a name that looked like an address.
        var name: String?
        var address: String
        var isMe: Bool
        /// How many of the messages this person wrote.
        var wrote: Int
    }

    struct Attachment: Equatable, Identifiable, Sendable {
        var id: MailAttachmentID
        var name: String
        var bytes: Int
        /// "412 KB", for the row.
        var sizeText: String
    }

    /// In order of first appearance: the people who wrote, then the people written to.
    var participants: [Participant]
    var messageCount: Int
    var unreadCount: Int
    var first: Date?
    var last: Date?
    /// "3 messages, 1 unread", for the row.
    var messageLine: String
    /// The first and the latest message's dates, as a message header writes them.
    var firstText: String?
    var lastText: String?
    var attachments: [Attachment]
    var labels: [String]
    var isInvitation: Bool

    init(_ conversation: MailConversation) {
        var order: [String] = []
        var seen: [String: Participant] = [:]
        func note(_ person: MailPerson, wrote: Bool) {
            let key = person.address.lowercased()
            if var existing = seen[key] {
                if wrote { existing.wrote += 1 }
                if existing.name == nil, let name = person.name { existing.name = name }
                seen[key] = existing
            } else {
                order.append(key)
                seen[key] = Participant(id: key, name: person.name, address: person.address,
                                        isMe: person.isMe, wrote: wrote ? 1 : 0)
            }
        }
        for message in conversation.messages {
            note(message.from, wrote: true)
        }
        for message in conversation.messages {
            for person in message.to + message.cc { note(person, wrote: false) }
        }
        participants = order.compactMap { seen[$0] }
        messageCount = conversation.messages.count
        unreadCount = conversation.messages.filter(\.isUnread).count
        first = conversation.messages.map(\.date).min()
        last = conversation.messages.map(\.date).max()
        let count = conversation.messages.count == 1 ? "1 message" : "\(conversation.messages.count) messages"
        messageLine = unreadCount > 0 ? "\(count), \(unreadCount) unread" : count
        firstText = first.map { MailDateText.full($0) }
        lastText = last.map { MailDateText.full($0) }
        attachments = conversation.messages.flatMap(\.attachments).map {
            Attachment(id: $0.id, name: $0.name, bytes: $0.bytes,
                       sizeText: ByteCountFormatter.string(fromByteCount: Int64($0.bytes), countStyle: .file))
        }
        labels = conversation.labels.map(\.name)
        isInvitation = conversation.invite != nil
    }
}

#endif
