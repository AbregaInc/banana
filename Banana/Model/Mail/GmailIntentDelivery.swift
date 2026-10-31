#if !BANANA_PUBLIC
import Foundation

/// One serialized delivery pass. All writes originate from the durable intent store.
/// Scheduling belongs to the source; this actor never busy-loops or sleeps on a retry.
actor GmailIntentDelivery {
    enum Failure: Error { case wrongAccount, malformedConfirmation, staleConfirmation, disabled, alreadyRunning }
    enum Outcome: Equatable, Sendable { case idle, confirmed, deferred, refused }
    let store: MailIntentStore
    let api: any GmailAPI
    let token: @Sendable (String) async throws -> String
    let allowed: @Sendable (String) async -> Bool
    let accept: @Sendable (String, GmailMessage) async throws -> Void
    let settled: @Sendable (String, String, [SentKey], Outcome) async -> Void
    private var running = false

    init(store: MailIntentStore, api: any GmailAPI,
         token: @escaping @Sendable (String) async throws -> String,
         allowed: @escaping @Sendable (String) async -> Bool,
         accept: @escaping @Sendable (String, GmailMessage) async throws -> Void,
         settled: @escaping @Sendable (String, String, [SentKey], Outcome) async -> Void = { _, _, _, _ in }) {
        self.store = store; self.api = api; self.token = token; self.allowed = allowed; self.accept = accept; self.settled = settled
    }

    func deliverNext(account: String, at: Int64) async throws -> Outcome {
        guard !running else { throw Failure.alreadyRunning }
        running = true; defer { running = false }
        guard await allowed(account) else { throw Failure.disabled }
        guard try await store.hasPending(account: account, at: at) else { return .idle }
        let credential = try await token(account)
        let profile = try await api.profile(token: credential)
        guard profile.emailAddress?.lowercased() == account.lowercased() else { throw Failure.wrongAccount }
        try Task.checkCancellation()
        let claimed = try await store.claim(account: account, at: at)
        guard let first = claimed.first else { return .idle }
        let keys = claimed.map { SentKey(account: account, messageID: $0.assertion.messageID, labelRef: $0.assertion.labelRef, sentSeq: $0.seq) }
        let message = first.assertion.messageID
        var mutationError: Error?
        do {
            try Task.checkCancellation()
            guard await allowed(account) else { throw Failure.disabled }
            guard claimed.allSatisfy({ !$0.assertion.labelRef.hasPrefix("name:") }) else { throw GmailError.refused(.invalidArgument) }
            if let trash = claimed.first(where: { $0.assertion.labelRef == "TRASH" }) {
                if trash.assertion.want { try await api.trash(token: credential, id: message) }
                else { try await api.untrash(token: credential, id: message) }
            }
            let changes = claimed.filter { $0.assertion.labelRef != "TRASH" }
            if !changes.isEmpty {
                try Task.checkCancellation()
                guard await allowed(account) else { throw Failure.disabled }
                try await api.modify(token: credential, id: message,
                    add: changes.filter { $0.assertion.want }.map { $0.assertion.labelRef },
                    remove: changes.filter { !$0.assertion.want }.map { $0.assertion.labelRef })
            }
        } catch { mutationError = error }

        // An interrupted mutation may have reached Gmail. Read it before retrying;
        // a successful HTTP write alone never clears durable intent.
        if !Task.isCancelled, !(mutationError is Failure) {
            do {
                let value = try await api.message(token: credential, id: message, format: .minimal)
                guard value.id == message, value.threadId != nil, value.historyId != nil, let labels = value.labelIds else { throw Failure.malformedConfirmation }
                let present = Set(labels)
                // Import partial outcomes too; a later explicit refusal must show what
                // Gmail actually kept, not the state from before a partly successful write.
                try await accept(account, value)
                if claimed.allSatisfy({ present.contains($0.assertion.labelRef) == $0.assertion.want }) {
                    try await store.confirmed(keys)
                    await settled(account, message, keys, .confirmed)
                    return .confirmed
                }
            } catch {
                // Preserve the mutation error when it carries an explicit refusal or retry hint.
                if mutationError == nil { mutationError = error }
            }
        }
        if Task.isCancelled {
            // Cleanup must be allowed to commit even though the network task was cancelled.
            let store = self.store
            try await Task.detached { try await store.reschedule(keys, at: at) }.value
            throw CancellationError()
        }
        if let failure = Self.permanent(mutationError) {
            try await store.refused(keys, failure: failure)
            await settled(account, message, keys, .refused)
            return .refused
        }
        let attempts = claimed.map(\.attempts).max() ?? 1
        var seconds = min(300.0, pow(2, Double(min(attempts, 8))))
        if let error = mutationError as? GmailError, case .limited(_, let hint) = error, let hint, hint.isFinite { seconds = max(seconds, hint) }
        let delay = Int64(min(seconds * 1000, Double(Int64.max / 2)))
        let next = at.addingReportingOverflow(delay)
        try await store.reschedule(keys, at: next.overflow ? Int64.max : next.partialValue)
        await settled(account, message, keys, .deferred)
        if let failure = mutationError as? Failure { throw failure }
        return .deferred
    }

    private static func permanent(_ error: Error?) -> MailFailure? {
        switch error as? GmailError {
        case .scopeMissing: return .accessMissing
        case .domainPolicy: return .notAllowedByAdmin
        case .unauthorized: return .signedOut
        case .notFound: return .other
        case .refused(.tooLarge): return .tooLarge
        case .refused(.labelLimit): return .limitReached
        case .refused: return .other
        default: return nil
        }
    }
}

#endif
