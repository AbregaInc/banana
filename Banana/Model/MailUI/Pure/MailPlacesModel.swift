#if !BANANA_PUBLIC
import Foundation
import Combine

extension MailScope {
    /// The mailbox this place is, when it is one.
    var mailbox: MailMailbox? {
        if case .mailbox(let mailbox) = place { return mailbox }
        return nil
    }

    /// Drafts, or Scheduled: a place of what he is writing, whose rows are messages of his own, so
    /// none of the triage keys (Done, star, read) means anything there.
    var isWriting: Bool { mailbox == .drafts || mailbox == .outbox }
    var isDrafts: Bool { mailbox == .drafts }
}

/// The places Mail's control column lists, and how many conversations each holds, kept current.
/// Its own observable: a count moving re-draws the control column and nothing else.
@MainActor
final class MailPlacesModel: ObservableObject {

    /// The places the first screen has, in the order shown.
    struct Place: Equatable, Identifiable, Sendable {
        var mailbox: MailMailbox
        var title: String
        var symbol: String
        var id: MailMailbox { mailbox }
    }

    /// Drafts and Scheduled are places of what he is writing (`MailScope.isWriting`): Drafts is the
    /// contract's `.drafts`, and Scheduled is its Outbox, which the sample source fills with
    /// scheduled messages only.
    static let all: [Place] = [
        Place(mailbox: .inbox, title: "Inbox", symbol: "tray"),
        Place(mailbox: .starred, title: "Starred", symbol: "star"),
        Place(mailbox: .drafts, title: "Drafts", symbol: "square.and.pencil"),
        // Snoozed, soonest back first (MAIL-ENGINE 8): what is away, and when it comes back.
        Place(mailbox: .snoozed, title: "Snoozed", symbol: "alarm"),
        Place(mailbox: .outbox, title: "Scheduled", symbol: "clock"),
        Place(mailbox: .done, title: "Done", symbol: "checkmark.circle"),
        Place(mailbox: .sent, title: "Sent", symbol: "paperplane"),
        Place(mailbox: .all, title: "All mail", symbol: "tray.full"),
        Place(mailbox: .spam, title: "Spam", symbol: "exclamationmark.shield"),
        Place(mailbox: .trash, title: "Trash", symbol: "trash"),
    ]

    static func title(of scope: MailScope) -> String {
        if case .search(let expression) = scope.place { return searchTitle(expression) }
        if case .mailbox(let mailbox) = scope.place, let place = all.first(where: { $0.mailbox == mailbox }) {
            return place.title
        }
        return "Mail"
    }

    /// A search names what it looks for: the words in quotes, then what the sentence turned into
    /// ("“lease” · From: mei"). "Search results" only when it holds nothing to show.
    static func searchTitle(_ expression: String) -> String {
        guard let filter = LiveFilter.fromSearchExpression(expression, scope: "mail") else {
            let words = expression.trimmingCharacters(in: .whitespacesAndNewlines)
            return words.isEmpty ? "Search results" : "“" + words + "”"
        }
        guard filter.issues.isEmpty else { return "Search results" }
        var parts = filter.text.isEmpty ? [] : ["“" + filter.text + "”"]
        parts += filter.terms.filter { $0.field != "text" }.map(\.title)
        return parts.isEmpty ? "Search results" : parts.joined(separator: " · ")
    }

    @Published private(set) var counts: [MailMailbox: MailPlaceCount] = [:]
    private var observation: MailObservation?

    init(source: MailSource) {
        observation = source.observePlaces { [weak self] places in
            guard let self, self.counts != places.mailboxCounts else { return }
            self.counts = places.mailboxCounts
        }
    }

    /// The conversations a place holds, or nil before the source has said.
    func total(of mailbox: MailMailbox) -> Int? {
        counts[mailbox]?.total.value
    }
}

#endif
