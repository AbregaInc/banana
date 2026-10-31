#if !BANANA_PUBLIC
import Foundation

/// One access token per account, and at most one request for it in the air.
///
/// Mail asks for a token before every Gmail call, from several tasks at once — a sync pass, the
/// outbox, a fetch for the screen. Without this, the first moment the cached token has expired
/// every one of them would ask Google for a new one: a burst of identical refresh requests, each
/// minting a token the others then discard. So the first caller to find no usable token starts
/// the mint and every caller that arrives while it runs **waits for that one** and shares its
/// answer — success or failure. (MAIL-ENGINE 3.3.)
///
/// What it does, per account:
///
/// - **A cached token is returned** unless it is within a minute of expiry. A token used in its
///   last seconds can die between the request leaving and Gmail reading it, and the 401 that
///   follows costs more than a mint.
/// - **A rejection is remembered.** When the mint says Google refused the credential
///   (`MailAccessError.rejected`), later callers get that answer at once without asking Google
///   again, until the credential is replaced or forgotten (`forget`). Asking again would change
///   nothing, and retrying forever is how an account that needs him looks like one that merely
///   does not work. Any other failure — no network, a 5xx — is not remembered: the next caller
///   tries again, because the next call may well succeed.
/// - **Nothing here knows how a token is minted.** The closure it is given does that (in the
///   app, the grant ledger's, over `GoogleTokenMinter`; MAIL-ENGINE 3.3), which is what lets
///   this be tested without a network, and what keeps Google's words out of it: the flight
///   never sees an error's text.
///
/// It is an actor, so its bookkeeping needs no lock. The mint runs in a task of its own, and
/// its answer is recorded before any waiter is let go, so a caller arriving a moment after the
/// answer finds the token in the cache instead of starting another mint.
actor MailTokenFlight {

    /// What a mint answers with: the token, when it stops being good, and the scopes Google
    /// said it carries (nil: it did not say).
    typealias Minted = (value: String, expiresAt: Date, scopes: Set<String>?)

    /// Mints a token for one account (lower-cased address). Throws `MailAccessError.rejected`
    /// for a credential Google refused, which is the one error this remembers.
    ///
    /// **It must end by itself, within 20 seconds, and must end at once when its task is
    /// cancelled.** The flight has no clock to time it out with, and its callers — a cancelled
    /// one included — cannot stop waiting for it, so a closure that never returned would hold
    /// every caller for the account until `forget`. (MAIL-ENGINE 3.3, rules 1, 6 and 7.)
    typealias Mint = @Sendable (String) async throws -> Minted

    /// A token with this long or less to run is minted again rather than used — exactly a
    /// minute left already renews.
    ///
    /// This is a second minute, not the only one: `GoogleTokenMinter` already subtracts a minute
    /// from the lifetime Google reports before it hands back `expiresAt`, so in the app the
    /// effective margin is two, and a token is first minted again about two minutes before it
    /// really expires (MAIL-ENGINE 3.3, rule 2). A mint that answers with a token already
    /// inside the margin hands it to its waiters and caches it, and it is never served from the
    /// cache: every later call mints.
    static let renewalMargin: TimeInterval = 60

    private struct Cached {
        var token: MailAccessToken
        var expiresAt: Date
    }

    private struct Flight {
        /// Which request this is, so that one that finishes after `forget` can tell it is no
        /// longer the account's.
        let id: Int
        let task: Task<MailAccessToken, Error>
    }

    private let mint: Mint
    private let clock: MailClock

    private var cached: [String: Cached] = [:]
    private var flights: [String: Flight] = [:]
    private var rejected: Set<String> = []
    private var waiting: [String: Int] = [:]
    private var flightsStarted = 0

    init(clock: MailClock, mint: @escaping Mint) {
        self.clock = clock
        self.mint = mint
    }

    /// A usable token for the account: the cached one, or the answer of the mint already in the
    /// air, or the answer of a mint this call starts.
    ///
    /// A caller that is cancelled while it waits still waits for the answer, and is then given
    /// what the mint brought — the token, not `CancellationError`: the mint is not the caller's
    /// to cancel, other callers share it, and a token that arrives is cached for the next one.
    /// Whoever calls this must check for cancellation afterwards if it matters to them.
    func token(for account: String) async throws -> MailAccessToken {
        if rejected.contains(account) { throw MailAccessError.rejected }
        if let hit = cached[account], hit.expiresAt.timeIntervalSince(clock.now) > Self.renewalMargin {
            return hit.token
        }

        let flight = flights[account] ?? startFlight(for: account)
        waiting[account, default: 0] += 1
        defer { waiting[account, default: 0] -= 1 }
        return try await flight.task.value
    }

    /// After a 401: the cached token is no good, so the next call mints. A remembered rejection
    /// is not touched — a 401 says nothing about whether Google has since taken the credential
    /// back or given it again — and a mint already in the air is left to finish and be shared.
    ///
    /// This cannot know which token got the 401, so a drop that arrives late, after a newer
    /// token was minted, throws that newer token away too, and the next call mints once more.
    /// That is accepted: it costs one mint, never a wrong answer (MAIL-ENGINE 3.3, rule 8).
    func drop(account: String) {
        cached[account] = nil
    }

    /// The credential was replaced or deleted: everything remembered about the account goes —
    /// the cached token, the remembered rejection, and the claim of any mint still in the air.
    ///
    /// **A mint already in the air when this is called is not cancelled, and everyone who was
    /// waiting for it is still answered — but what it brings back, a token or a rejection,
    /// belongs to the old credential and is neither cached nor remembered.** Otherwise a
    /// rejection of the credential just deleted would be held against the one that replaced it,
    /// and a token minted from it would go on being served after it was forgotten. The next
    /// caller starts a mint of its own.
    func forget(account: String) {
        cached[account] = nil
        rejected.remove(account)
        flights[account] = nil
    }

    /// Mail is leaving the foreground: cancels the task of the account's mint in the air, if
    /// there is one, and changes nothing else.
    ///
    /// The mint ends through the ordinary failure path. Its waiters are told whatever the
    /// closure threw (`CancellationError` from a plain one, `.transport` from the app's);
    /// nothing is remembered, because only `.rejected` ever is, so the next caller mints again;
    /// a cached token is untouched, and so is every other account. A closure that ignored the
    /// cancellation would finish within its own time limit and be cached as usual.
    func cancelMint(account: String) {
        flights[account]?.task.cancel()
    }

    /// How many callers are suspended for the account right now, the one that started a mint
    /// included — on any of its mints, an old one and its replacement together after `forget`.
    /// **It exists only for tests**: it lets a test know that the callers it started have
    /// really joined before it lets the mint answer, without a sleep or a guess about timing.
    /// Nothing in the app reads it.
    func waitingCallers(for account: String) -> Int {
        waiting[account] ?? 0
    }

    // MARK: - The mint

    private func startFlight(for account: String) -> Flight {
        flightsStarted += 1
        let id = flightsStarted
        let mint = self.mint
        let task = Task<MailAccessToken, Error> {
            do {
                let minted = try await mint(account)
                return self.finished(account, flight: id, minted)
            } catch {
                self.failed(account, flight: id, error)
                throw error
            }
        }
        let flight = Flight(id: id, task: task)
        flights[account] = flight
        return flight
    }

    /// Records a mint's answer before any waiter sees it, unless `forget` has since taken the
    /// account's claim on this flight.
    private func finished(_ account: String, flight id: Int, _ minted: Minted) -> MailAccessToken {
        let token = MailAccessToken(value: minted.value, scopes: minted.scopes)
        if flights[account]?.id == id {
            flights[account] = nil
            cached[account] = Cached(token: token, expiresAt: minted.expiresAt)
        }
        return token
    }

    private func failed(_ account: String, flight id: Int, _ error: Error) {
        guard flights[account]?.id == id else { return }
        flights[account] = nil
        if (error as? MailAccessError) == .rejected { rejected.insert(account) }
    }
}

#endif
