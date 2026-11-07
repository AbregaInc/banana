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
    /// A named label now has Gmail's id (account, name, id, the messages whose intent was rewritten).
    let relabeled: @Sendable (String, String, String, [String]) async -> Void
    private var running = false

    init(store: MailIntentStore, api: any GmailAPI,
         token: @escaping @Sendable (String) async throws -> String,
         allowed: @escaping @Sendable (String) async -> Bool,
         accept: @escaping @Sendable (String, GmailMessage) async throws -> Void,
         settled: @escaping @Sendable (String, String, [SentKey], Outcome) async -> Void = { _, _, _, _ in },
         relabeled: @escaping @Sendable (String, String, String, [String]) async -> Void = { _, _, _, _ in }) {
        self.store = store; self.api = api; self.token = token; self.allowed = allowed; self.accept = accept; self.settled = settled
        self.relabeled = relabeled
    }

    /// 6.5 step 2: an assertion on `name:Banana/Snoozed/…` needs the label to exist. Look it up by name;
    /// if absent, create it hidden; on `conflict` (a lost answer, or another device got there first)
    /// read the labels again and take its id. Then every intent row naming it is rewritten to the id.
    /// A failure that will not change refuses the rows that name it; anything else is a retry.
    private func resolveNames(account: String, credential: String) async throws {
        let named = try await store.namedLabelRefs(account: account)
        guard !named.isEmpty else { return }
        var known: [String: String]?
        func list() async throws -> [String: String] {
            var ids: [String: String] = [:]
            for label in try await api.labels(token: credential) {
                if let id = label.id, let name = label.name { ids[name] = id }
            }
            return ids
        }
        for ref in named {
            try Task.checkCancellation()
            let name = String(ref.dropFirst(BananaLabelRules.namePrefix.count))
            guard name.hasPrefix(BananaLabelRules.prefix) else {
                try await store.refuseNamed(account: account, ref: ref, failure: .other); continue
            }
            if known == nil { known = try await list() }
            var id = known?[name]
            if id == nil {
                let dropped = try await store.discardNamedRemovals(account: account, ref: ref)
                if !dropped.messages.isEmpty { await settledRemovals(account, dropped.messages) }
                guard dropped.remaining else { continue }
                guard await allowed(account) else { throw Failure.disabled }
                do { id = try await api.createLabel(token: credential, name: name).id }
                catch GmailError.conflict { known = try await list(); id = known?[name] }
                catch {
                    if let failure = Self.permanent(error) {
                        try await store.refuseNamed(account: account, ref: ref, failure: failure); continue
                    }
                    throw error
                }
            }
            guard let id, !id.isEmpty else { throw GmailError.unknownOutcome }
            known?[name] = id
            let messages = try await store.rewriteLabelRef(account: account, from: ref, to: id)
            await relabeled(account, name, id, messages)
        }
    }

    /// Rows that were already true went: their messages' overlay is the delivery's to settle.
    private func settledRemovals(_ account: String, _ messages: [String]) async {
        for message in messages { await settled(account, message, [], .confirmed) }
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
        try await resolveNames(account: account, credential: credential)
        try Task.checkCancellation()
        let claimed = try await store.claim(account: account, at: at)
        guard let first = claimed.first else { return .idle }
        let keys = claimed.map { SentKey(account: account, messageID: $0.assertion.messageID, labelRef: $0.assertion.labelRef, sentSeq: $0.seq) }
        let message = first.assertion.messageID
        // Named after the names were resolved (a change committed meanwhile): resolved on the next pass.
        if claimed.contains(where: { $0.assertion.labelRef.hasPrefix(BananaLabelRules.namePrefix) }) {
            try await store.reschedule(keys, at: at)
            return .deferred
        }
        var mutationError: Error?
        do {
            try Task.checkCancellation()
            guard await allowed(account) else { throw Failure.disabled }
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
