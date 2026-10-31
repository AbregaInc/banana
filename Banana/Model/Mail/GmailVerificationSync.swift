#if !BANANA_PUBLIC
import Foundation
import GRDB

/// Read-only provider verification. A list omission, proxy 404, authentication
/// failure or malformed message can never be promoted to a deletion outcome.
actor GmailVerificationSync {
    enum Failure: Error { case busy, invalidLimit, wrongAccount }
    enum Result: Equatable, Sendable { case finished, more }
    typealias Committed = @Sendable (String, MailVerificationIndex.Applied) async throws -> Void
    private let stores: MailStores
    private let writer: MailWriter
    private let api: any GmailAPI
    private let token: GmailPageLoader.Token
    private let recover: GmailHistorySync.Recover
    private let committed: Committed
    private var running = Set<String>()

    init(stores: MailStores, writer: MailWriter, api: any GmailAPI, token: @escaping GmailPageLoader.Token,
         recover: @escaping GmailHistorySync.Recover, committed: @escaping Committed) {
        self.stores = stores; self.writer = writer; self.api = api
        self.token = token; self.recover = recover; self.committed = committed
    }

    func verify(account rawAccount: String, nowMS: Int64, maximumBatches: Int = 10) async throws -> Result {
        guard (1...100).contains(maximumBatches), nowMS >= 0 else { throw Failure.invalidLimit }
        let account = rawAccount.lowercased()
        guard running.insert(account).inserted else { throw Failure.busy }
        defer { running.remove(account) }
        try Task.checkCancellation()
        let access = try await token(account)
        let profile = try await api.profile(token: access)
        guard profile.emailAddress?.lowercased() == account else { throw Failure.wrongAccount }
        try await recover(account)
        for _ in 0..<maximumBatches {
            try Task.checkCancellation()
            guard try await stores.index.read({ try MailReconcileIndex.state(account: account, in: $0) }) != nil else { return .finished }
            let requests = try await stores.index.read { try MailVerificationIndex.requests(account: account, in: $0) }
            if requests.isEmpty {
                let applied = try await writer.transactValue { db in
                    let result = try MailVerificationIndex.resolveBatch(account: account, nowMS: nowMS, in: db)
                    return (result, result.change)
                }
                try await committed(account, applied)
                if applied.finished { return .finished }
                continue
            }
            let api = self.api
            let answers = try await withThrowingTaskGroup(of: (MailVerificationIndex.Request, GmailMessage?).self) { group in
                func add(_ index: Int) {
                    let request = requests[index]
                    group.addTask {
                        try Task.checkCancellation()
                        do {
                            return (request, try await api.message(token: access, id: request.messageID, format: .minimal))
                        } catch GmailError.notFound { return (request, nil) }
                    }
                }
                var next = 0
                while next < min(4, requests.count) { add(next); next += 1 }
                var result: [(MailVerificationIndex.Request, GmailMessage?)] = []
                while let answer = try await group.next() {
                    result.append(answer)
                    if next < requests.count { add(next); next += 1 }
                }
                return result
            }
            // Keep index commits bounded independently of provider batch size.
            for offset in stride(from: 0, to: answers.count, by: 20) {
                try Task.checkCancellation()
                let batch = Array(answers[offset..<min(offset + 20, answers.count)])
                _ = try await writer.transact { db in
                    var change = MailStoreChange()
                    for (request, message) in batch {
                        if let message {
                            change.formUnion(try MailVerificationIndex.found(message, request: request, account: account, in: db))
                        } else { try MailVerificationIndex.gone(request, account: account, in: db) }
                    }
                    return change
                }
            }
        }
        return .more
    }
}

#endif
