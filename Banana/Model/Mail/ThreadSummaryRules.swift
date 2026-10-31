#if !BANANA_PUBLIC
import Foundation

/// Shared summary policy for the index writer and fixture source (MAIL-ENGINE 4.5).
/// Facts already contain the effective labels and the single validated sender.
/// This does no parsing, I/O, observation, or mutation of provider state.
enum ThreadSummaryRules {
    static func summarise(_ messages: [MessageFacts], myAddresses: Set<String>) -> ThreadSummary {
        let confirmed = messages.filter { $0.vis != 3 }
        let ordinary = confirmed.filter {
            ($0.vis == 0 || $0.vis == 4) &&
                !$0.labels.contains("TRASH") && !$0.labels.contains("SPAM")
        }
        let visible = (ordinary.isEmpty ? confirmed : ordinary).sorted {
            if $0.internalDate != $1.internalDate { return $0.internalDate < $1.internalDate }
            return $0.gmailID < $1.gmailID
        }
        let fetched = visible.filter { $0.fetchState > 0 }
        let authors = people(fetched, recipients: false, myAddresses: myAddresses)
        let recipients = people(fetched, recipients: true, myAddresses: myAddresses)
        var flags: MailThreadFlags = []
        var labels = Set<String>()
        var unread = 0
        var pending = 0
        for message in visible {
            labels.formUnion(message.labels)
            if message.labels.contains("UNREAD") { unread += 1 }
            if message.labels.contains("STARRED") { flags.insert(.starred) }
            if message.labels.contains("IMPORTANT") { flags.insert(.important) }
            if message.labels.contains("DRAFT") { flags.insert(.hasDraft) }
            if message.labels.contains("INBOX") { flags.insert(.inInbox) }
            if message.hasAttachment { flags.insert(.hasAttachment) }
            if message.hasInvite { flags.insert(.hasInvite) }
            if message.listID != nil { flags.insert(.isList) }
            if message.bananaLabels.contains("Banana/Muted") { flags.insert(.muted) }
            if message.vis == 4 { flags.insert(.keptAfterRemoval) }
        }
        if let latest = fetched.last, !latest.fromAddress.isEmpty,
           latest.isFromMe || myAddresses.contains(latest.fromAddress) { flags.insert(.lastIsMine) }

        // Retention must see claims even on a message not chosen for the display summary.
        // An unconfirmed cache row may still carry a durable intent that must not be lost.
        var claims: MailClaims = []
        for message in messages {
            if message.hasRefusedIntent { pending = 2 }
            else if message.hasUndeliveredIntent { pending = max(pending, 1) }
            if message.labels.contains("STARRED") { claims.insert(.starred) }
            if message.labels.contains("DRAFT") { claims.insert(.draft) }
            if !message.bananaLabels.isEmpty { claims.insert(.bananaLabel) }
            if message.hasUndeliveredIntent || message.hasRefusedIntent { claims.insert(.pendingChange) }
            if message.vis == 4 { claims.insert(.keptAfterRemoval) }
        }
        return ThreadSummary(lastDate: fetched.last?.internalDate ?? 0,
            messageCount: visible.count, fetchedCount: fetched.count, unreadCount: unread,
            flags: flags, subject: fetched.first?.subject ?? "", snippet: fetched.last?.snippet ?? "",
            people: authors.values, peopleTotal: authors.total, labels: labels,
            wakeAt: nil, returnedAt: nil, waitingUntil: nil, pending: pending,
            recipients: recipients.values, recipientsTotal: recipients.total, claims: claims)
    }

    private static func people(_ messages: [MessageFacts], recipients: Bool,
                               myAddresses: Set<String>) -> (values: [SummaryPerson], total: Int) {
        enum Identity: Hashable { case own, address(String) }
        var positions: [Identity: Int] = [:]
        var values: [SummaryPerson] = []
        for message in messages {
            let addresses = recipients ? message.toAddresses + message.ccAddresses : [message.fromAddress]
            for address in addresses {
                let isMe = !address.isEmpty &&
                    (myAddresses.contains(address) || (!recipients && message.isFromMe))
                let identity: Identity = isMe ? .own : .address(address)
                let unread = message.labels.contains("UNREAD")
                if let index = positions[identity] {
                    if index < values.count { values[index].u = values[index].u || unread }
                    continue
                }
                positions[identity] = positions.count
                if values.count < 6 {
                    values.append(SummaryPerson(n: isMe ? "me" :
                        (recipients || address.isEmpty ? nil : message.fromName),
                                                a: address, u: unread, isMe: isMe))
                }
            }
        }
        return (values, positions.count)
    }
}

#endif
