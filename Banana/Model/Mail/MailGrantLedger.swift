#if !BANANA_PUBLIC
import Foundation

struct MailCredentialRefused: Error, Sendable {
    let reason: MailGrantRejection
}

/// Owns credential generations so an old in-flight refresh cannot resurrect a deleted grant
/// or reject a replacement. The flight owns token caching; this ledger owns credential state.
@MainActor
final class MailGrantLedger {
    typealias Stamp = UInt64
    typealias Mint = @MainActor @Sendable (String, Stamp) async throws -> MailTokenFlight.Minted
    private struct Entry {
        let stamp: Stamp
        var rejection: MailGrantRejection?
    }
    private var entries: [String: Entry] = [:]
    private var sequence: Stamp = 0
    private var owed: [String: (generation: UInt64, task: Task<Void, Never>)] = [:]
    private var operationSequence: UInt64 = 0
    private let mint: Mint
    private let clock: MailClock
    private lazy var flight = MailTokenFlight(clock: clock) { [weak self] account in
        guard let self else { throw CancellationError() }
        return try await self.performMint(account)
    }

    init(clock: MailClock, mint: @escaping Mint) { self.clock = clock; self.mint = mint }

    @discardableResult
    func stored(account: String, isEmpty: Bool) -> Stamp {
        sequence += 1
        entries[account] = Entry(stamp: sequence, rejection: isEmpty ? .emptyCredential : nil)
        enqueue(account) { await $0.forget(account: account) }
        return sequence
    }

    func deleted(account: String) {
        entries.removeValue(forKey: account)
        enqueue(account) { await $0.forget(account: account) }
    }

    func grant(for account: String) -> MailGrant {
        guard let entry = entries[account] else { return .none }
        return entry.rejection.map { .rejected(reason: $0) } ?? .granted
    }

    func dropToken(account: String) { enqueue(account) { await $0.drop(account: account) } }
    func cancelMints() {
        for account in entries.keys { enqueue(account) { await $0.cancelMint(account: account) } }
    }

    func token(for account: String) async throws -> MailAccessToken {
        while true {
            try Task.checkCancellation()
            // A credential can change while awaiting an earlier operation. Drain the current
            // chain, not just the task that was current before suspension.
            while let pending = owed[account] {
                await pending.task.value
                if owed[account]?.generation == pending.generation {
                    owed.removeValue(forKey: account)
                    break
                }
            }
            try Task.checkCancellation()
            guard let before = entries[account] else { throw MailAccessError.notGranted }
            guard before.rejection == nil else { throw MailAccessError.rejected }
            let answer: Result<MailAccessToken, Error>
            do { answer = .success(try await flight.token(for: account)) }
            catch { answer = .failure(error) }
            try Task.checkCancellation()
            guard entries[account]?.stamp == before.stamp else { continue }
            return try answer.get()
        }
    }

    private func performMint(_ account: String) async throws -> MailTokenFlight.Minted {
        guard let entry = entries[account] else { throw MailAccessError.notGranted }
        do { return try await mint(account, entry.stamp) }
        catch let refusal as MailCredentialRefused {
            if entries[account]?.stamp == entry.stamp { entries[account]?.rejection = refusal.reason }
            throw MailAccessError.rejected
        }
    }

    private func enqueue(_ account: String, _ operation: @escaping @Sendable (MailTokenFlight) async -> Void) {
        let previous = owed[account]?.task, flight = self.flight
        operationSequence += 1
        owed[account] = (operationSequence, Task { await previous?.value; await operation(flight) })
    }
}

#endif
