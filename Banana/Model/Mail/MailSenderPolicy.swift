#if !BANANA_PUBLIC
import Foundation
protocol MailSenderPolicyAPI: Sendable {
    func read(account: String, sender: String) async throws -> MailSenderPolicyRemote
    func write(account: String, sender: String, blocked: Bool, revision: Int, operation: String) async throws -> MailSenderPolicyRemote
}

struct MailSenderPolicyRecord: Codable, Equatable, Sendable {
    var account: String
    var sender: String
    var want: Bool
    var operation: String
    var remote: MailSenderPolicyRemote?
    var expectedRevision: Int?
    var pending: Bool
    var failed: Bool
    var retryAt: Date
}

extension MailSenderPolicyRecord {
    /// A matching value at the old revision can still be changed by a delayed older request.
    func confirmsEffect(_ value: MailSenderPolicyRemote) -> Bool {
        guard value.blocked == want else { return false }
        if value.operation == operation { return true }
        guard let boundary = expectedRevision ?? remote?.revision else { return false }
        return value.revision > boundary
    }
}

extension MailSenderPolicyStatus {
    func update(_ record: MailSenderPolicyRecord?) {
        blocked = record?.remote?.blocked ?? false
        pending = record?.pending ?? false
        desiredBlocked = record?.want ?? blocked
        failed = record?.failed ?? false
        loading = false
    }
}

/// SQL is committed before acknowledging an intent. A retry first reconciles the
/// provider's revision so a lost response cannot overwrite a later unblock.
actor MailSenderPolicyDriver {
    let store: MailIntentStore
    let api: any MailSenderPolicyAPI
    let allowed: @Sendable (String) async -> Bool
    let settled: @Sendable (String, String) async -> Void
    private var running = false
    init(store: MailIntentStore, api: any MailSenderPolicyAPI,
         allowed: @escaping @Sendable (String) async -> Bool,
         settled: @escaping @Sendable (String, String) async -> Void = { _, _ in }) {
        self.store = store; self.api = api; self.allowed = allowed; self.settled = settled
    }
    func queue(account: String, sender: String, blocked: Bool) async throws {
        guard MailAddressRules.isValid(account), MailAddressRules.isValid(sender),
              account.lowercased() != sender.lowercased(), await allowed(account) else { throw MailSenderPolicyError.unavailable }
        try await store.queueSenderPolicy(account: account.lowercased(), sender: sender.lowercased(), blocked: blocked)
    }
    @discardableResult func deliverNext(account: String, at: Date) async throws -> Bool {
        guard !running, await allowed(account), let record = try await store.nextSenderPolicy(account: account, at: at) else { return false }
        running = true; defer { running = false }
        var attemptedRevision = record.expectedRevision
        do {
            let remote = try await api.read(account: account, sender: record.sender)
            guard let current = try await store.senderPolicy(account: account, sender: record.sender),
                  current.operation == record.operation else { return true }
            if record.confirmsEffect(remote) {
                try await store.settleSenderPolicy(record, remote: remote)
            } else if let attempted = record.expectedRevision, remote.revision != attempted {
                throw MailSenderPolicyError.conflict(remote)
            } else {
                guard await allowed(account) else { throw MailSenderPolicyError.unavailable }
                guard try await store.attemptSenderPolicy(record, remote: remote) else { return true }
                attemptedRevision = remote.revision
                let answer = try await api.write(account: account, sender: record.sender, blocked: record.want,
                    revision: remote.revision, operation: record.operation)
                guard answer.blocked == record.want, answer.revision == remote.revision + 1, answer.operation == record.operation else { throw GmailError.malformed }
                try await store.settleSenderPolicy(record, remote: answer)
            }
        } catch MailSenderPolicyError.conflict(let remote) {
            let confirmed = remote.blocked == record.want && attemptedRevision.map { remote.revision > $0 } == true
            try await store.settleSenderPolicy(record, remote: remote, failed: !confirmed)
        } catch {
            let permanent: Bool
            switch error {
            case MailSenderPolicyError.unavailable, GmailError.unauthorized, GmailError.scopeMissing,
                 GmailError.domainPolicy, GmailError.refused: permanent = true
            default: permanent = false
            }
            try await store.failSenderPolicy(record, permanent: permanent, retryAt: at.addingTimeInterval(30))
        }
        await settled(account, record.sender)
        return true
    }
}
#endif
