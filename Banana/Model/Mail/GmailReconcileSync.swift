#if !BANANA_PUBLIC
import Foundation
import GRDB

/// Bounded, restartable enumeration. Its result deliberately stops at verification:
/// completing a listing is not evidence that an absent message has been deleted.
actor GmailReconcileSync {
    enum Failure: Error { case busy, invalidLimit, wrongAccount, missingCheckpoint }
    enum Result: Equatable, Sendable {
        case more(MailReconcileIndex.State)
        case needsVerification(MailReconcileIndex.State)
    }
    private let stores: MailStores
    private let writer: MailWriter
    private let api: any GmailAPI
    private let token: GmailPageLoader.Token
    private var running = Set<String>()

    init(stores: MailStores, writer: MailWriter, api: any GmailAPI, token: @escaping GmailPageLoader.Token) {
        self.stores = stores; self.writer = writer; self.api = api; self.token = token
    }

    func enumerate(account rawAccount: String, nowMS: Int64, maximumSteps: Int = 10) async throws -> Result {
        guard (1...100).contains(maximumSteps), nowMS >= 0 else { throw Failure.invalidLimit }
        let account = rawAccount.lowercased()
        guard running.insert(account).inserted else { throw Failure.busy }
        defer { running.remove(account) }
        try Task.checkCancellation()
        let access = try await token(account)
        let profile = try await api.profile(token: access)
        guard profile.emailAddress?.lowercased() == account else { throw Failure.wrongAccount }
        var state: MailReconcileIndex.State
        if let saved = try await stores.index.read({ try MailReconcileIndex.state(account: account, in: $0) }) {
            state = saved
        } else {
            let labels = try await api.labels(token: access)
            try Task.checkCancellation()
            state = try await writer.transactValue { db in
                let value = try MailReconcileIndex.begin(profile: profile, labels: labels, account: account, in: db)
                return (value, MailStoreChange(labelsChanged: true))
            }
        }
        for _ in 0..<maximumSteps {
            try Task.checkCancellation()
            let expected = state
            switch state.phase {
            case .verifying: return .needsVerification(state)
            case .closing:
                state = try await writer.transactValue { db in
                    (try MailReconcileIndex.closeBatch(account: account, expected: expected, nowMS: nowMS, in: db), MailStoreChange())
                }
            case .listing:
                let position = try await stores.index.read { db in
                    try String.fetchOne(db, sql: "SELECT checkpoint FROM account WHERE email=?", arguments: [account])
                }
                guard let floor = position.flatMap(GmailNumber.unsigned), floor > 0 else { throw Failure.missingCheckpoint }
                // A 500-message transaction currently exceeds 100 ms in the retained
                // disk benchmark. Request 100 while preserving the full mailbox scan.
                let page: GmailIDPage
                do {
                    page = try await api.listMessages(token: access, labelIDs: state.label.map { [$0] } ?? [],
                        query: nil, includeSpamTrash: true, pageToken: state.pageToken, maxResults: 100)
                } catch GmailError.refused(.invalidArgument) where state.pageToken != nil {
                    try Task.checkCancellation()
                    state = try await writer.transactValue { db in
                        (try MailReconcileIndex.restartListing(account: account, expected: expected, in: db), MailStoreChange())
                    }
                    // Yield after durable repair. A rejected first page propagates
                    // normally, and repeated resets cannot spin within one call.
                    return .more(state)
                }
                try Task.checkCancellation()
                guard (page.messages?.count ?? 0) <= 100 else { throw MailReconcileIndex.Failure.invalidPage }
                state = try await writer.transactValue { db in
                    try MailReconcileIndex.apply(page, account: account, expected: expected, floor: floor, nowMS: nowMS, in: db)
                }
            }
        }
        return state.phase == .verifying ? .needsVerification(state) : .more(state)
    }
}

#endif
