import XCTest

/// One mint in the air per account, and what is remembered afterwards.
///
/// The failure these exist for is a burst: when a token expires, every task that wants one finds
/// the cache empty at the same moment, and without a single flight each asks Google for its own.
/// So the headline test starts ten callers and holds the mint open until all ten are really
/// waiting on it — and then counts mints. It does that without a sleep or a guess about timing:
/// the flight says how many callers are waiting on it (`waitingCallers`), and the test waits for
/// that number, not for a time.
///
/// The harder half is what happens when the credential or the callers change while a mint is in
/// the air: a caller cancelled, a `drop` landing, mail leaving the foreground, a credential
/// replaced so that two mints — the old one's and the new one's — are in the air together. Each
/// of those has a way to go wrong that no test of a single mint can see, so every mint here has
/// a gate of its own (`release(call:)`): a test can let the old one answer before, after or
/// without the new one.
final class MailTokenFlightTests: XCTestCase {

    private let account = "me@example.com"
    private let other = "other@example.com"
    private let third = "third@example.com"
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - The test's end of the flight

    /// A clock that stands where the test puts it. The flight never sleeps, so a sleep is a bug.
    private final class StillClock: MailClock, @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date
        init(_ date: Date) { current = date }

        var now: Date { lock.lock(); defer { lock.unlock() }; return current }
        func set(_ date: Date) { lock.lock(); current = date; lock.unlock() }
        func sleep(until deadline: Date) async throws {
            XCTFail("the token flight must never sleep")
            throw CancellationError()
        }
    }

    /// What one call to the minting closure does.
    private enum Outcome {
        /// A token whose value is `token`, good until `lasting` seconds after the clock's time
        /// when the mint was called.
        case token(String, lasting: TimeInterval = 3_600, scopes: Set<String>? = nil)
        /// A token named for the account it was minted for, so a test can tell whose is whose.
        case tokenNamedForAccount
        case fail(MailAccessError)
    }

    /// What a gated closure does when its own task is cancelled while it waits.
    private enum OnCancel {
        /// Carries on waiting for its gate, as a closure that ignored cancellation would.
        case ignore
        /// Ends at once, throwing this: `CancellationError` from a plain closure, `.transport`
        /// from the app's.
        case end(throwing: Error)
    }

    /// The minting closure, as the test controls it. It counts its calls and the accounts they
    /// were for, answers from a script by call number (the last outcome repeats), and — if gated
    /// — makes **each call wait for its own gate**: `release(call: n)` lets call *n* answer, and
    /// `release()` lets every call, now and later, answer. It also records, for each call,
    /// whether its task was cancelled while it waited and whether it still was when it ended.
    private final class Mints: @unchecked Sendable {
        private let lock = NSLock()
        private let clock: StillClock
        private let gated: Bool
        private let onCancel: OnCancel
        private let script: [Outcome]
        private var accounts: [String] = []
        private var releasedAll = false
        private var released: Set<Int> = []
        private var held: [Int: CheckedContinuation<Void, Never>] = [:]
        private var cancelledWhileWaiting: Set<Int> = []
        private var cancelledAtEnd: [Int: Bool] = [:]

        init(clock: StillClock, gated: Bool = false, onCancel: OnCancel = .ignore, _ script: [Outcome]) {
            self.clock = clock
            self.gated = gated
            self.onCancel = onCancel
            self.script = script
        }

        var calls: Int { lock.lock(); defer { lock.unlock() }; return accounts.count }
        var accountsMinted: [String] { lock.lock(); defer { lock.unlock() }; return accounts }

        /// Whether call `n`'s task was cancelled while it waited for its gate (only a closure
        /// that ends on cancellation can see this while it waits).
        func sawCancellationWhileWaiting(call n: Int) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelledWhileWaiting.contains(n)
        }

        /// Whether call `n`'s task was cancelled at the moment its wait ended; nil if it has
        /// not ended its wait.
        func wasCancelledWhenItEnded(call n: Int) -> Bool? {
            lock.lock(); defer { lock.unlock() }
            return cancelledAtEnd[n]
        }

        /// Whether call `n` is parked at its gate right now — which, for a closure that ends on
        /// cancellation, means its cancellation handler is installed too.
        func isParked(call n: Int) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return held[n] != nil
        }

        var closure: MailTokenFlight.Mint {
            { [self] account in
                let call = enter(account)
                if gated {
                    switch onCancel {
                    case .ignore:
                        await hold(call)
                    case .end:
                        await withTaskCancellationHandler(
                            operation: { await hold(call) },
                            onCancel: { sawCancellation(call); release(call: call) })
                    }
                }
                let cancelled = Task.isCancelled
                ended(call, cancelled: cancelled)
                if cancelled, case .end(let error) = onCancel { throw error }
                switch outcome(for: call) {
                case .token(let value, let lasting, let scopes):
                    return (value, clock.now.addingTimeInterval(lasting), scopes)
                case .tokenNamedForAccount:
                    return ("token-" + account, clock.now.addingTimeInterval(3_600), nil)
                case .fail(let error):
                    throw error
                }
            }
        }

        /// Records the call and returns its number, from 1.
        private func enter(_ account: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            accounts.append(account)
            return accounts.count
        }

        private func outcome(for call: Int) -> Outcome {
            script[min(call, script.count) - 1]
        }

        private func sawCancellation(_ call: Int) {
            lock.lock(); cancelledWhileWaiting.insert(call); lock.unlock()
        }

        private func ended(_ call: Int, cancelled: Bool) {
            lock.lock(); cancelledAtEnd[call] = cancelled; lock.unlock()
        }

        private func hold(_ call: Int) async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if releasedAll || released.contains(call) {
                    lock.unlock()
                    continuation.resume()
                } else {
                    held[call] = continuation
                    lock.unlock()
                }
            }
        }

        /// Lets call `n` answer — now if it is waiting, or the moment it arrives.
        func release(call n: Int) {
            lock.lock()
            released.insert(n)
            let waiting = held.removeValue(forKey: n)
            lock.unlock()
            waiting?.resume()
        }

        /// Lets every call that is waiting, and every later one, answer.
        func release() {
            lock.lock()
            releasedAll = true
            let waiting = Array(held.values)
            held = [:]
            lock.unlock()
            waiting.forEach { $0.resume() }
        }
    }

    /// What a caller of `token(for:)` was told, in the terms the tests care about.
    private enum Answer: Equatable {
        case token(String)
        case rejected
        case transport
        case cancelled
        case other
    }

    private func makeFlight(clock: StillClock, _ mints: Mints) -> MailTokenFlight {
        MailTokenFlight(clock: clock, mint: mints.closure)
    }

    /// Starts one caller and returns what it will be told.
    private func ask(_ flight: MailTokenFlight, _ account: String? = nil) -> Task<Answer, Never> {
        let account = account ?? self.account
        return Task {
            do {
                return .token(try await flight.token(for: account).value)
            } catch let error as MailAccessError {
                switch error {
                case .rejected: return .rejected
                case .transport: return .transport
                default: return .other
                }
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .other
            }
        }
    }

    /// Waits, without a timer, until the flight says `count` callers are suspended on the
    /// account's mints. Each turn asks the flight and then yields; nothing here depends on how
    /// long anything takes, and a count that never arrives fails the test instead of hanging it.
    private func waitForCallers(_ count: Int, on flight: MailTokenFlight, account: String? = nil,
                                file: StaticString = #filePath, line: UInt = #line) async {
        let account = account ?? self.account
        for _ in 0..<500_000 {
            if await flight.waitingCallers(for: account) >= count { return }
            await Task.yield()
        }
        XCTFail("only \(await flight.waitingCallers(for: account)) of \(count) callers joined",
                file: file, line: line)
    }

    /// The same, for the minting closure having been called `count` times in all.
    private func waitForCalls(_ count: Int, on mints: Mints,
                              file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500_000 {
            if mints.calls >= count { return }
            await Task.yield()
        }
        XCTFail("the mint was called \(mints.calls) times, not \(count)", file: file, line: line)
    }

    /// The same, for call `n` of the closure having reached its gate and parked there. A test
    /// that is about to cancel must wait for this, not just for the call: before it, the
    /// closure has not yet installed the handler that sees the cancellation.
    private func waitForGate(_ call: Int, on mints: Mints,
                             file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500_000 {
            if mints.isParked(call: call) { return }
            await Task.yield()
        }
        XCTFail("call \(call) never reached its gate", file: file, line: line)
    }

    // MARK: - One mint for many callers

    func testTenCallersAtOnceCauseOneMint() async throws {
        let clock = StillClock(start)
        let mints = Mints(clock: clock, gated: true, [.token("t1"), .token("t2")])
        let flight = makeFlight(clock: clock, mints)

        let callers = (0..<10).map { _ in ask(flight) }
        await waitForCallers(10, on: flight)
        mints.release()

        for caller in callers {
            let answer = await caller.value
            XCTAssertEqual(answer, .token("t1"), "every caller is given the one token")
        }
        XCTAssertEqual(mints.calls, 1, "ten callers waiting on a mint share it; they do not each ask Google")

        let late = await ask(flight).value
        XCTAssertEqual(late, .token("t1"), "a caller after the answer is served from the cache")
        XCTAssertEqual(mints.calls, 1)
    }

    func testTenCallersAtOnceShareAFailureToo() async throws {
        let clock = StillClock(start)
        let mints = Mints(clock: clock, gated: true, [.fail(.transport), .token("t2")])
        let flight = makeFlight(clock: clock, mints)

        let callers = (0..<10).map { _ in ask(flight) }
        await waitForCallers(10, on: flight)
        mints.release()

        for caller in callers {
            let answer = await caller.value
            XCTAssertEqual(answer, .transport, "every caller is told what the one mint was told")
        }
        XCTAssertEqual(mints.calls, 1)

        let eleventh = await ask(flight).value
        XCTAssertEqual(eleventh, .token("t2"), "the failed mint is cleared; the next caller tries again")
        XCTAssertEqual(mints.calls, 2)
    }

    func testACachedTokenIsReturnedWithoutMintingAgain() async throws {
        let clock = StillClock(start)
        let mints = Mints(clock: clock, [.token("t1")])
        let flight = makeFlight(clock: clock, mints)

        let first = try await flight.token(for: account)
        let second = try await flight.token(for: account)

        XCTAssertEqual(first, second)
        XCTAssertEqual(mints.calls, 1)
    }

    func testTheMintIsGivenTheAccountItWasAskedFor() async throws {
        let clock = StillClock(start)
        let mints = Mints(clock: clock, [.token("t1")])
        let flight = makeFlight(clock: clock, mints)

        _ = try await flight.token(for: account)

        XCTAssertEqual(mints.accountsMinted, [account])
    }

    func testTheTokenCarriesTheScopesGoogleSaidAndNilWhenItDidNot() async throws {
        let clock = StillClock(start)
        let said = Mints(clock: clock, [.token("t1", scopes: [MailScopes.gmailModify])])
        let saidNothing = Mints(clock: clock, [.token("t2", scopes: nil)])

        let withScopes = try await makeFlight(clock: clock, said).token(for: account)
        let without = try await makeFlight(clock: clock, saidNothing).token(for: account)

        XCTAssertEqual(withScopes.scopes, [MailScopes.gmailModify])
        XCTAssertNil(without.scopes, "unknown stays unknown; it does not become the empty set")
    }

    func testTwoAccountsMintSeparatelyAndAtTheSameTime() async throws {
        let clock = StillClock(start)
        let mints = Mints(clock: clock, gated: true, [.tokenNamedForAccount])
        let flight = makeFlight(clock: clock, mints)

        let first = ask(flight, account)
        let second = ask(flight, other)
        await waitForCalls(2, on: mints)
        mints.release()

        let firstAnswer = await first.value
        let secondAnswer = await second.value
        XCTAssertEqual(firstAnswer, .token("token-" + account),
                       "each account is given the token minted for it")
        XCTAssertEqual(secondAnswer, .token("token-" + other))
        XCTAssertEqual(Set(mints.accountsMinted), [account, other],
                       "one account's mint in the air must not stand in for another's")
        XCTAssertEqual(mints.calls, 2)
    }

    // MARK: - Cancelled callers

    /// The mint is not the caller's to cancel and the others share it. A caller that is
    /// cancelled while it waits stays, and is handed the token — not `CancellationError`.
    func testACancelledWaiterStaysAndIsGivenTheToken() async throws {
        let clock = StillClock(start)
        let mints = Mints(clock: clock, gated: true, [.token("t1")])
        let flight = makeFlight(clock: clock, mints)

        let first = ask(flight)
        let second = ask(flight)
        let third = ask(flight)
        await waitForCallers(3, on: flight)
        second.cancel()
        mints.release()

        let answers = [await first.value, await second.value, await third.value]
        XCTAssertEqual(answers, [.token("t1"), .token("t1"), .token("t1")],
                       "the cancelled caller is handed the token, not CancellationError")
        XCTAssertEqual(mints.calls, 1)
        XCTAssertEqual(mints.wasCancelledWhenItEnded(call: 1), false,
                       "a caller's cancellation must not reach the mint the others share")
    }

    func testCancellingTheCallerThatStartedTheMintLeavesItRunning() async throws {
        let clock = StillClock(start)
        let mints = Mints(clock: clock, gated: true, [.token("t1")])
        let flight = makeFlight(clock: clock, mints)

        let starter = ask(flight)
        await waitForCalls(1, on: mints)
        await waitForCallers(1, on: flight)
        let second = ask(flight)
        let third = ask(flight)
        await waitForCallers(3, on: flight)
        starter.cancel()
        mints.release()

        let answers = [await starter.value, await second.value, await third.value]
        XCTAssertEqual(answers, [.token("t1"), .token("t1"), .token("t1")],
                       "the caller that started the mint does not own it")
        XCTAssertEqual(mints.calls, 1)
        XCTAssertEqual(mints.wasCancelledWhenItEnded(call: 1), false)
    }

    // MARK: - Mail leaving the foreground

    /// Leaving the foreground must stop a token request, not wait for it: the closure, while it
    /// waits, is told to end — and ends at once. The test never releases it.
    func testCancelMintCancelsTheMintInTheAir() async throws {
        let clock = StillClock(start)
        let mints = Mints(clock: clock, gated: true, onCancel: .end(throwing: CancellationError()),
                          [.token("t1")])
        let flight = makeFlight(clock: clock, mints)

        let caller = ask(flight)
        await waitForGate(1, on: mints)
        await waitForCallers(1, on: flight)
        await flight.cancelMint(account: account)

        XCTAssertTrue(mints.sawCancellationWhileWaiting(call: 1),
                      "cancelMint must cancel the task the mint is running in")
        mints.release()    // a safety net only: with the cancellation delivered this changes nothing
        let answer = await caller.value
        XCTAssertEqual(answer, .cancelled)
    }

    func testWaitersOfACancelledMintAreToldWhatItThrew() async throws {
        let ways: [(throwing: Error, expected: Answer)] = [
            (CancellationError(), .cancelled),
            (MailAccessError.transport, .transport),
        ]
        for way in ways {
            let clock = StillClock(start)
            let mints = Mints(clock: clock, gated: true, onCancel: .end(throwing: way.throwing),
                              [.token("t1")])
            let flight = makeFlight(clock: clock, mints)

            let waiters = (0..<3).map { _ in ask(flight) }
            await waitForGate(1, on: mints)
            await waitForCallers(3, on: flight)
            await flight.cancelMint(account: account)
            mints.release()

            for waiter in waiters {
                let answer = await waiter.value
                XCTAssertEqual(answer, way.expected,
                               "every waiter is told what the closure itself threw")
            }
            XCTAssertEqual(mints.calls, 1)
        }
    }

    func testACancelledMintIsNotRememberedAndTheNextCallMintsAgain() async throws {
        let clock = StillClock(start)
        let mints = Mints(clock: clock, gated: true, onCancel: .end(throwing: CancellationError()),
                          [.token("t1"), .token("t2")])
        let flight = makeFlight(clock: clock, mints)

        let cancelled = ask(flight)
        await waitForGate(1, on: mints)
        await waitForCallers(1, on: flight)
        await flight.cancelMint(account: account)
        XCTAssertTrue(mints.sawCancellationWhileWaiting(call: 1))
        mints.release(call: 1)    // a safety net only: with the cancellation delivered this changes nothing
        let firstAnswer = await cancelled.value
        XCTAssertEqual(firstAnswer, .cancelled)

        mints.release(call: 2)
        mints.release(call: 3)    // never reached when the cache holds call 2's token; a fail-not-hang net
        let next = try await flight.token(for: account)
        XCTAssertEqual(next.value, "t2", "being cancelled is not a verdict on the account")
        XCTAssertEqual(mints.calls, 2)

        let again = try await flight.token(for: account)
        XCTAssertEqual(again, next, "and the token the new mint brought is cached as usual")
        XCTAssertEqual(mints.calls, 2)
    }

    func testCancelMintLeavesACachedTokenAndOtherAccountsAlone() async throws {
        let clock = StillClock(start)
        let mints = Mints(clock: clock, gated: true, onCancel: .end(throwing: CancellationError()),
                          [.token("t1"), .token("t2")])
        let flight = makeFlight(clock: clock, mints)

        mints.release(call: 1)
        mints.release(call: 3)    // never reached unless cancelMint wrongly emptied the cache: then it must fail, not hang
        let cached = try await flight.token(for: account)
        let others = ask(flight, other)
        await waitForGate(2, on: mints)
        await waitForCallers(1, on: flight, account: other)

        await flight.cancelMint(account: account)

        XCTAssertFalse(mints.sawCancellationWhileWaiting(call: 2),
                       "cancelling one account's mint must not touch another account's")
        let stillCached = try await flight.token(for: account)
        XCTAssertEqual(stillCached, cached, "with nothing in the air, a cached token is served as before")
        XCTAssertEqual(mints.calls, 2, "and nothing was minted to serve it")
        mints.release(call: 2)
        let othersAnswer = await others.value
        XCTAssertEqual(othersAnswer, .token("t2"))
    }

    /// A closure that ignores the cancellation finishes in its own time limit and its token is
    /// cached as usual: cancelling asks, it does not take anything away.
    func testAMintThatIgnoresCancellationIsCachedAsUsual() async throws {
        let clock = StillClock(start)
        let mints = Mints(clock: clock, gated: true, onCancel: .ignore, [.token("t1"), .token("t2")])
        let flight = makeFlight(clock: clock, mints)

        let first = ask(flight)
        let second = ask(flight)
        await waitForCallers(2, on: flight)
        await flight.cancelMint(account: account)
        mints.release()

        let answers = [await first.value, await second.value]
        XCTAssertEqual(answers, [.token("t1"), .token("t1")])
        XCTAssertEqual(mints.wasCancelledWhenItEnded(call: 1), true,
                       "the cancellation did reach the task; the closure chose to ignore it")
        let next = await ask(flight).value
        XCTAssertEqual(next, .token("t1"), "and its token is cached, so the next call is served from the cache")
        XCTAssertEqual(mints.calls, 1)
    }

    // MARK: - Expiry

    func testATokenWithMoreThanAMinuteLeftIsStillUsed() async throws {
        let clock = StillClock(start)
        let mints = Mints(clock: clock, [.token("t1", lasting: 3_600), .token("t2")])
        let flight = makeFlight(clock: clock, mints)

        _ = try await flight.token(for: account)
        clock.set(start.addingTimeInterval(3_600 - 61))
        let again = try await flight.token(for: account)

        XCTAssertEqual(again.value, "t1")
        XCTAssertEqual(mints.calls, 1)
    }

    func testATokenWithinAMinuteOfExpiryIsMintedAgain() async throws {
        let clock = StillClock(start)
        let mints = Mints(clock: clock, [.token("t1", lasting: 3_600), .token("t2")])
        let flight = makeFlight(clock: clock, mints)

        _ = try await flight.token(for: account)
        clock.set(start.addingTimeInterval(3_600 - 59))
        let again = try await flight.token(for: account)

        XCTAssertEqual(again.value, "t2", "a token about to expire is not worth the 401")
        XCTAssertEqual(mints.calls, 2)
    }

    /// The edge is a choice: with exactly a minute left the token is already renewed, so a
    /// token is never used with a minute or less to run.
    func testATokenWithExactlyAMinuteLeftIsMintedAgain() async throws {
        let clock = StillClock(start)
        let mints = Mints(clock: clock, [.token("t1", lasting: 3_600), .token("t2")])
        let flight = makeFlight(clock: clock, mints)

        _ = try await flight.token(for: account)
        clock.set(start.addingTimeInterval(3_600 - 60))
        let again = try await flight.token(for: account)

        XCTAssertEqual(again.value, "t2")
    }

    func testATokenThatIsAlreadyExpiredIsMintedAgain() async throws {
        let clock = StillClock(start)
        let mints = Mints(clock: clock, [.token("t1", lasting: 3_600), .token("t2")])
        let flight = makeFlight(clock: clock, mints)

        _ = try await flight.token(for: account)
        clock.set(start.addingTimeInterval(7_200))

        let again = try await flight.token(for: account)
        XCTAssertEqual(again.value, "t2")
    }

    /// With the minter's own minute taken off already, a short-lived token can arrive inside
    /// the margin. Its caller is given it; it is never served again.
    func testATokenMintedInsideTheMarginIsHandedOutAndMintedAgainNextTime() async throws {
        let clock = StillClock(start)
        let mints = Mints(clock: clock, [.token("short", lasting: 30), .token("long", lasting: 3_600)])
        let flight = makeFlight(clock: clock, mints)

        let first = try await flight.token(for: account)
        XCTAssertEqual(first.value, "short", "the caller who asked is given what the mint brought")

        let second = try await flight.token(for: account)
        XCTAssertEqual(second.value, "long", "a token inside the margin is never served from the cache")
        XCTAssertEqual(mints.calls, 2)

        let third = try await flight.token(for: account)
        XCTAssertEqual(third, second)
        XCTAssertEqual(mints.calls, 2, "a token with time to run is cached as usual")
    }

    // MARK: - Dropping

    func testADroppedTokenIsMintedAgainOnTheNextCall() async throws {
        let clock = StillClock(start)
        let mints = Mints(clock: clock, [.token("t1"), .token("t2")])
        let flight = makeFlight(clock: clock, mints)

        _ = try await flight.token(for: account)
        await flight.drop(account: account)
        let again = try await flight.token(for: account)

        XCTAssertEqual(again.value, "t2", "after a 401 the next call must not be handed the same token")
        XCTAssertEqual(mints.calls, 2)
    }

    func testDroppingOneAccountsTokenLeavesAnothersAlone() async throws {
        let clock = StillClock(start)
        let mints = Mints(clock: clock, [.token("t1"), .token("t2"), .token("t3")])
        let flight = makeFlight(clock: clock, mints)

        _ = try await flight.token(for: account)
        let others = try await flight.token(for: other)
        await flight.drop(account: account)
        let stillCached = try await flight.token(for: other)

        XCTAssertEqual(stillCached, others)
        XCTAssertEqual(mints.calls, 2)
    }

    /// Several requests get a 401 together and each drops: the one mint they start between them
    /// is shared, not repeated.
    func testADropWhileAMintIsInTheAirDoesNotStartASecondMint() async throws {
        let clock = StillClock(start)
        let mints = Mints(clock: clock, gated: true, [.token("t1", lasting: 3_600), .token("t2")])
        let flight = makeFlight(clock: clock, mints)

        mints.release(call: 1)
        _ = try await flight.token(for: account)
        clock.set(start.addingTimeInterval(7_200))

        let first = ask(flight)
        await waitForCalls(2, on: mints)
        await waitForCallers(1, on: flight)
        await flight.drop(account: account)
        let second = ask(flight)
        await waitForCallers(2, on: flight)
        mints.release()    // every call: were a second mint started, it must answer, not hang the test

        let answers = [await first.value, await second.value]
        XCTAssertEqual(answers, [.token("t2"), .token("t2")],
                       "the caller after the drop joins the mint already in the air")
        XCTAssertEqual(mints.calls, 2, "a drop must not start a second mint beside the first")

        let third = await ask(flight).value
        XCTAssertEqual(third, .token("t2"))
        XCTAssertEqual(mints.calls, 2, "the shared mint's token is cached")
    }

    /// `drop` cannot know which token got the 401, so a late one throws a newer token away.
    /// Accepted (3.3, rule 8): it costs one mint and is never a wrong answer. This pins it, so
    /// that changing it is a decision.
    func testALateDropDiscardsANewerTokenAtTheCostOfOneMint() async throws {
        let clock = StillClock(start)
        let mints = Mints(clock: clock, [.token("t1"), .token("t2"), .token("t3")])
        let flight = makeFlight(clock: clock, mints)

        let dead = try await flight.token(for: account)
        XCTAssertEqual(dead.value, "t1")
        await flight.drop(account: account)
        let newer = try await flight.token(for: account)
        XCTAssertEqual(newer.value, "t2")

        await flight.drop(account: account)       // the second request's 401 for the same dead token
        let again = try await flight.token(for: account)

        XCTAssertEqual(again.value, "t3", "the late drop discarded t2, which was perfectly good")
        XCTAssertEqual(mints.calls, 3, "one extra mint, and no error")
    }

    // MARK: - Rejection

    func testARejectionIsRememberedUntilForget() async throws {
        let clock = StillClock(start)
        let mints = Mints(clock: clock, [.fail(.rejected), .token("t2")])
        let flight = makeFlight(clock: clock, mints)

        await assertRejected(flight)
        await assertRejected(flight)
        await assertRejected(flight)
        XCTAssertEqual(mints.calls, 1, "Google is not asked again about a credential it refused")

        await flight.forget(account: account)
        let after = try await flight.token(for: account)
        XCTAssertEqual(after.value, "t2", "once the credential is replaced the account mints again")
        XCTAssertEqual(mints.calls, 2)
    }

    func testARejectionIsRememberedForThatAccountOnly() async throws {
        let clock = StillClock(start)
        let mints = Mints(clock: clock, [.fail(.rejected), .token("t2")])
        let flight = makeFlight(clock: clock, mints)

        await assertRejected(flight)
        let fine = try await flight.token(for: other)

        XCTAssertEqual(fine.value, "t2")
    }

    func testADropDoesNotClearARejection() async throws {
        let clock = StillClock(start)
        let mints = Mints(clock: clock, [.fail(.rejected), .token("t2")])
        let flight = makeFlight(clock: clock, mints)

        await assertRejected(flight)
        await flight.drop(account: account)
        await assertRejected(flight)

        XCTAssertEqual(mints.calls, 1)
    }

    func testEveryCallerOfARejectedMintIsToldItWasRejected() async throws {
        let clock = StillClock(start)
        let mints = Mints(clock: clock, gated: true, [.fail(.rejected)])
        let flight = makeFlight(clock: clock, mints)

        let callers = (0..<5).map { _ in ask(flight) }
        await waitForCallers(5, on: flight)
        mints.release()

        for caller in callers { let answer = await caller.value; XCTAssertEqual(answer, .rejected) }
        XCTAssertEqual(mints.calls, 1)
    }

    private func assertRejected(_ flight: MailTokenFlight,
                                file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await flight.token(for: account)
            XCTFail("expected the account to be rejected", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? MailAccessError, .rejected, file: file, line: line)
        }
    }

    // MARK: - Failures that are not remembered

    func testATransportFailureIsNotRememberedSoTheNextCallTriesAgain() async throws {
        let clock = StillClock(start)
        let mints = Mints(clock: clock, [.fail(.transport), .token("t2")])
        let flight = makeFlight(clock: clock, mints)

        do {
            _ = try await flight.token(for: account)
            XCTFail("the first mint fails")
        } catch {
            XCTAssertEqual(error as? MailAccessError, .transport)
        }
        let second = try await flight.token(for: account)

        XCTAssertEqual(second.value, "t2", "no network is a moment, not a verdict on the account")
        XCTAssertEqual(mints.calls, 2)
    }

    func testAMissingClientIdIsNotRemembered() async throws {
        let clock = StillClock(start)
        let mints = Mints(clock: clock, [.fail(.notConfigured), .token("t2")])
        let flight = makeFlight(clock: clock, mints)

        do { _ = try await flight.token(for: account); XCTFail("the first mint fails") }
        catch { XCTAssertEqual(error as? MailAccessError, .notConfigured) }

        let second = try await flight.token(for: account)
        XCTAssertEqual(second.value, "t2")
    }

    // MARK: - Forgetting

    /// Without a mint in the air: a deleted credential's token must not be served again.
    func testForgetDropsACachedToken() async throws {
        let clock = StillClock(start)
        let mints = Mints(clock: clock, [.token("t1"), .token("t2")])
        let flight = makeFlight(clock: clock, mints)

        let before = try await flight.token(for: account)
        XCTAssertEqual(before.value, "t1")
        await flight.forget(account: account)
        let after = try await flight.token(for: account)

        XCTAssertEqual(after.value, "t2", "a forgotten credential's token must not be served for an hour")
        XCTAssertEqual(mints.calls, 2)
    }

    func testForgetLeavesAnotherAccountsTokenAndRejectionAlone() async throws {
        let clock = StillClock(start)
        let mints = Mints(clock: clock, [.token("t1"), .fail(.rejected), .token("t3")])
        let flight = makeFlight(clock: clock, mints)

        let cachedForOther = try await flight.token(for: other)          // call 1: t1
        do { _ = try await flight.token(for: third); XCTFail("refused") } // call 2: rejected
        catch { XCTAssertEqual(error as? MailAccessError, .rejected) }
        _ = try await flight.token(for: account)                          // call 3: t3

        await flight.forget(account: account)

        let stillCached = try await flight.token(for: other)
        XCTAssertEqual(stillCached, cachedForOther, "another account's cached token survives")
        do {
            _ = try await flight.token(for: third)
            XCTFail("another account's remembered rejection must survive")
        } catch {
            XCTAssertEqual(error as? MailAccessError, .rejected)
        }
        XCTAssertEqual(mints.calls, 3, "and neither was asked of Google again")
    }

    func testForgettingAnAccountThatWasNeverAskedForIsHarmless() async throws {
        let clock = StillClock(start)
        let mints = Mints(clock: clock, [.token("t1")])
        let flight = makeFlight(clock: clock, mints)

        await flight.forget(account: account)
        let token = try await flight.token(for: account)

        XCTAssertEqual(token.value, "t1")
    }

    // MARK: - Forgetting while a mint is in the air

    /// The mint that was asked of the old credential must not decide what the new one is.
    func testARejectionThatArrivesAfterForgetBelongsToTheOldCredential() async throws {
        let clock = StillClock(start)
        let mints = Mints(clock: clock, gated: true, [.fail(.rejected), .token("t2")])
        let flight = makeFlight(clock: clock, mints)

        let old = ask(flight)
        await waitForCalls(1, on: mints)
        await flight.forget(account: account)
        mints.release()

        let oldAnswer = await old.value
        XCTAssertEqual(oldAnswer, .rejected, "whoever was already waiting is still answered")
        let new = try await flight.token(for: account)
        XCTAssertEqual(new.value, "t2", "the new credential is not called rejected on the old one's word")
        XCTAssertEqual(mints.calls, 2)
    }

    func testATokenThatArrivesAfterForgetIsNotKept() async throws {
        let clock = StillClock(start)
        let mints = Mints(clock: clock, gated: true, [.token("old"), .token("new")])
        let flight = makeFlight(clock: clock, mints)

        let old = ask(flight)
        await waitForCalls(1, on: mints)
        await flight.forget(account: account)
        mints.release()

        let oldAnswer = await old.value
        XCTAssertEqual(oldAnswer, .token("old"), "whoever was already waiting is still answered")
        let new = try await flight.token(for: account)
        XCTAssertEqual(new.value, "new", "a forgotten credential's token is not served again")
    }

    // MARK: - Two mints in the air together

    /// After a credential is replaced during a mint the old mint and the new one are in the air
    /// together. Each is told apart by its own number, not by whether the account has a mint at
    /// all: the old one's answer must not clear the new one's claim or speak for the new
    /// credential, and the new one's answer must not be overwritten by the old one's.

    func testAnOldMintRefusedAfterForgetDoesNotRefuseTheNewCredential() async throws {
        let clock = StillClock(start)
        let mints = Mints(clock: clock, gated: true, [.fail(.rejected), .token("t2")])
        let flight = makeFlight(clock: clock, mints)

        let oldWaiter = ask(flight)
        await waitForCalls(1, on: mints)
        await waitForCallers(1, on: flight)
        await flight.forget(account: account)
        let newCaller = ask(flight)
        await waitForCalls(2, on: mints)
        await waitForCallers(2, on: flight)

        mints.release(call: 1)
        let oldAnswer = await oldWaiter.value
        XCTAssertEqual(oldAnswer, .rejected, "the old mint's waiter is told what the old mint was told")

        // The new mint is still in the air. Nothing was remembered, and its claim is intact: a
        // caller now joins it rather than being refused or starting a third mint.
        let joiner = ask(flight)
        mints.release()    // the new mint answers (call 1 is done); were a third started, it must not hang the test
        let newAnswer = await newCaller.value
        let joinerAnswer = await joiner.value
        XCTAssertEqual(newAnswer, .token("t2"), "the new credential's caller is given its own token")
        XCTAssertEqual(joinerAnswer, .token("t2"), "and so is a caller that came after the old answer")
        XCTAssertEqual(mints.calls, 2, "no third mint: the new mint's claim survived the old one's failure")

        let next = await ask(flight).value
        XCTAssertEqual(next, .token("t2"), "the next call is served from the cache")
        XCTAssertEqual(mints.calls, 2)
    }

    func testAnOldMintsTokenAfterForgetIsNotCachedOverTheNewOne() async throws {
        let clock = StillClock(start)
        let mints = Mints(clock: clock, gated: true, [.token("old"), .token("new")])
        let flight = makeFlight(clock: clock, mints)

        let oldWaiter = ask(flight)
        await waitForCalls(1, on: mints)
        await waitForCallers(1, on: flight)
        await flight.forget(account: account)
        let newCaller = ask(flight)
        await waitForCalls(2, on: mints)
        await waitForCallers(2, on: flight)

        mints.release(call: 1)
        let oldAnswer = await oldWaiter.value
        XCTAssertEqual(oldAnswer, .token("old"), "the old mint's waiter is given the old token")

        let joiner = ask(flight)
        mints.release()    // the new mint answers (call 1 is done); were a third started, it must not hang the test
        let newAnswer = await newCaller.value
        let joinerAnswer = await joiner.value
        XCTAssertEqual(newAnswer, .token("new"))
        XCTAssertEqual(joinerAnswer, .token("new"),
                       "the forgotten credential's token must not be served in the new one's place")
        XCTAssertEqual(mints.calls, 2)

        let next = await ask(flight).value
        XCTAssertEqual(next, .token("new"), "after the new mint answers, the cache holds its token")
        XCTAssertEqual(mints.calls, 2)
    }

    func testANewMintThatAnswersFirstIsKeptWhenTheOldOneAnswers() async throws {
        let ways: [(old: Outcome, answer: Answer)] = [
            (.token("old"), .token("old")),
            (.fail(.rejected), .rejected),
        ]
        for way in ways {
            let clock = StillClock(start)
            let mints = Mints(clock: clock, gated: true, [way.old, .token("new")])
            mints.release(call: 3)    // never reached when the cache holds the new token; a fail-not-hang net
            let flight = makeFlight(clock: clock, mints)

            let oldWaiter = ask(flight)
            await waitForCalls(1, on: mints)
            await waitForCallers(1, on: flight)
            await flight.forget(account: account)
            let newCaller = ask(flight)
            await waitForCalls(2, on: mints)
            await waitForCallers(2, on: flight)

            mints.release(call: 2)
            let newAnswer = await newCaller.value
            XCTAssertEqual(newAnswer, .token("new"))

            mints.release(call: 1)
            let oldAnswer = await oldWaiter.value
            XCTAssertEqual(oldAnswer, way.answer, "the old mint's waiter is still answered, late")

            let next = await ask(flight).value
            XCTAssertEqual(next, .token("new"),
                           "the late answer from the old mint changes neither the cache nor what is remembered")
            XCTAssertEqual(mints.calls, 2)
        }
    }
}
