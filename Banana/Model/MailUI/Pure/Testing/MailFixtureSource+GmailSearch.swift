#if !BANANA_PUBLIC
#if DEBUG || MAIL_FIXTURES
import Foundation

/// The sample mailbox's Gmail (MAIL-ENGINE 9.4): a few older conversations this device does not
/// hold, found only by asking. A search answers at once from the device and, after `gmailDelay`,
/// adds what "Gmail" matched through the engine's own merge (`MailSearchMerge`). Off unless a
/// delay is set (`--mail-gmail-delay <seconds>`), so every other picture of the sample stays the
/// device's alone.
extension MailFixtureSource {
    nonisolated static func gmailOnlySamples() -> [MailFixtureConversations.Sample] {
        typealias C = MailFixtureConversations
        return [
            C.Sample(key: "gmail-invoice-2024", subject: "Invoice 2024-114 from Harbor Print", messages: [
                C.Message(from: C.stripe, day: -40, hour: 10, minute: 5,
                          body: ["Your invoice for the spring catalogue print run is attached."])
            ], important: false),
            C.Sample(key: "gmail-invoice-2023", subject: "Overdue invoice reminder", messages: [
                C.Message(from: C.stripe, day: -400, hour: 16, minute: 30,
                          body: ["A friendly reminder that last quarter's invoice is still open."])
            ], important: false),
        ]
    }

    /// What Gmail would add to this search: matches the device does not hold, as rows.
    func gmailMatches(_ scope: MailScope) -> [MailRow] {
        guard case .search(let text) = scope.place else { return [] }
        let words = (LiveFilter.fromSearchExpression(text, scope: "mail")?.text ?? text)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.map { $0.lowercased() }
        guard !words.isEmpty else { return [] }
        return gmailOnly.values.map(\.row).filter { row in
            if let account = scope.account, row.id.account != account.lowercased() { return false }
            if let before = scope.before, row.key >= before { return false }
            let haystack = ([row.subject, row.snippet] + row.people.flatMap { [$0.name ?? "", $0.address] })
                .joined(separator: " ").lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
            return words.allSatisfy { word in haystack.contains { $0.hasPrefix(word) } }
        }.map { var row = $0; row.isOnDevice = false; return row }
    }

    /// The device's snapshot of a search, joined by what Gmail found once it has answered.
    func withGmail(_ local: MailListSnapshot, limit: Int) -> MailListSnapshot {
        guard gmailDelay != nil, case .search = local.scope.place else { return local }
        let key = GmailSearchKey(local.scope)
        guard answered.contains(key) else {
            if asked.insert(key).inserted { answerLater(key) }
            var snapshot = local
            snapshot.remote = .pending
            return snapshot
        }
        let merged = MailSearchMerge.merge(local: local.rows, localMore: local.hasMore,
            remote: gmailMatches(local.scope), gmailMore: false, frontier: nil, limit: limit)
        var snapshot = local
        snapshot.rows = merged.rows
        snapshot.hasMore = merged.hasMore
        snapshot.total = MailCount(value: max(local.total.value, merged.rows.count), isAtLeast: merged.hasMore)
        snapshot.remote = .done(added: merged.added, more: false)
        return snapshot
    }

    private func answerLater(_ key: GmailSearchKey) {
        guard let delay = gmailDelay else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self else { return }
            self.answered.insert(key)
            self.publish()
        }
    }
}

/// One search, whatever window of it is read.
struct GmailSearchKey: Hashable {
    var text: String
    var account: String?
    var filters: Set<MailFilter>
    init(_ scope: MailScope) {
        if case .search(let text) = scope.place { self.text = text } else { text = "" }
        account = scope.account; filters = scope.filters
    }
}

#endif
#endif
