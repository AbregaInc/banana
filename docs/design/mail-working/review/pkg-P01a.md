# Code review — package P01a, account types (uncommitted)

Worktree `~/orca/workspaces/gtfuwgth/stingray`, branch `google-email-functionality`,
on top of `17f9670`. Read-only review by reading the code: nothing was edited, built or run, so
the implementer's numbers (1,565 tests, Thread Sanitizer, 2,100 repeats, Release builds) are
not confirmed here, and every "this change would still pass the tests" below is by reading the
tests, not by running them.

Files: `Banana/Model/Mail/MailAccountAccess.swift` (128), `MailAccountRules.swift` (67),
`MailTokenFlight.swift` (159), `MailClock.swift` (20); `BananaTests/MailAccountRulesTests.swift`
(195), `MailScopesTests.swift` (74), `MailTokenFlightTests.swift` (462).

**The document moved during the review.** The architect's corrections to
`docs/design/MAIL-ENGINE.md` appeared in the working tree (uncommitted: 3.3's flight rules 1–5
and the new `MailGrantLedger`, 5.1's `MailAccessTokens`, 13.6, the P01a, P02, P23a and P01b
entries). This review is against that text; line numbers of the document are the working
tree's.

## Verdict

**Commit with the listed fixes.** No BLOCKER. Three MAJOR, nine MINOR.

The code is right in every interleaving I walked (list at the end). What is wrong is that four
behaviours the flight's comments and 3.3's rules promise are held by no test, and that one
consequence of rule 1 is written nowhere. MAJOR 1 and 2 are tests only, no source change.
MAJOR 3 is one sentence for the implementer and one ruling for the architect.

**Why now:** P01b's *Must not* closes `MailTokenFlight.swift` and `MailAccountAccess.swift`,
and 18.1 closes `MailAccountRules.swift`, as soon as this is committed. Anything below that
changes one of those files (MAJOR 3's sentence; MINOR 1, 2, 7, 8) is cheap today and an
extension file afterwards.

---

## MAJOR

### MAJOR 1 — `forget` dropping a cached token is held by no test

`MailTokenFlight.swift:110`; `MailTokenFlightTests.swift:317-331, 416-461`.

Every test that calls `forget` does so with nothing in the cache: after rejections only (:327),
with the mint still in the air (:426, :443), or on an account never asked for (:457). Delete
line 110 (`cached[account] = nil`) and all 21 flight tests still pass. What that regression
does: "Forget Mail access on this device" deletes the credential and the flight goes on
handing out its token for up to an hour — the failure the comment at :105-107 gives as the
reason `forget` exists, in its commonest form (no mint in the air).

Smallest fix, tests only:
- mint `t1`; `forget`; `token` → `t2`, `calls == 2`.
- its pair: `forget(account)` leaves `other`'s cached token and `other`'s remembered rejection
  alone (`drop` has this test at :301; `forget` has none).

### MAJOR 2 — three in-flight interleavings that 3.3 and the comments promise have no test

Each is correct in the code today. Each can be broken without a test failing.

**(a) `drop` while a mint is in the air** — `MailTokenFlight.swift:93-98`. The comment says the
mint "is left to finish and be shared". No test calls `drop` with a mint in the air. Add
`flights[account] = nil` to `drop` and everything passes; the result is the burst the type
exists to prevent, on the path where `drop` is called most (several requests getting a 401
together): the next caller starts a second mint beside the first.
Test: cache a token, move the clock past it, caller A starts a gated mint, `drop`, caller B
arrives (`waitForCallers(2)`), release; both get `t2`, `calls == 1`, and a third call
afterwards is served from the cache (`calls` still 1).

**(b) a cancelled caller** — 3.3 rule 1 (MAIL-ENGINE :323-325); `MailTokenFlight.swift:78-80,
90`. Nothing in the test file cancels anything. Wrap line 90 in a cancellation handler that
cancels `flight.task` and everything passes; the result is one cancelled sync pass failing the
token for the screen's fetch. Tests: three gated callers, cancel one, release — the other two
get the token, the mint closure saw `Task.isCancelled == false`, `calls == 1`; and the same
with the cancelled caller being the one that started the mint. Pin also what the cancelled
caller itself receives (the token, not `CancellationError`): the session has to know to check
cancellation after `token(for:)`.

**(c) the old mint and the new one in the air together, after `forget`** — 3.3 rule 4;
`MailTokenFlight.swift:147, 155`. The two tests at :416 and :436 use one gate for every call
(`release()`, :116-123), so the old mint has always answered before the new one starts. The
flight-id comparison is what makes the overlap safe, and nothing holds it: replace
`flights[account]?.id == id` with `flights[account] != nil` and all tests pass. Then:

1. Mint F1 (old credential) in the air. `forget`. A caller starts F2 (new credential).
2. F1 answers `rejected` → `rejected.insert(account)` and F2's entry is cleared: the new
   credential is refused on the old one's word while its own mint is still running.
3. Or F1 answers a token → the forgotten credential's token is cached and served; F2's answer
   is then thrown away.

This is no corner: the ledger's `token(for:)` starts again after `stored` (3.3, step 4), which
puts a new mint beside the old one every time a credential is replaced during a mint.

Smallest fix: give `Mints` a gate per call (`release(call: n)`), and three tests — old answers
first with a rejection, old answers first with a token, new answers first — each asserting what
the next caller gets and `calls`.

### MAJOR 3 — nothing can stop a mint and nobody waiting for one can leave; the closure's time limit is the only one, and nothing says so

`MailTokenFlight.swift:36-38` (`Mint`), `:78-90`, `:129`; MAIL-ENGINE 3.3 rule 1 (:323-325) and
:425. The code does what its comment and rule 1 say; this is what follows from them.

The mint runs in an unstructured task whose handle is private, and callers wait on
`task.value`, which does not answer cancellation. So for as long as the closure runs: every
caller for that account, cancelled or not, stays suspended; no later caller can start another
mint (`flights[account]` stays set; only `forget` clears it); and the request behind the
closure stays alive. The flight has no timeout of its own, and neither 3.3 nor P01b's entry
gives mail's session one.

Sequence, iPhone playing a podcast: a sync pass asks for a token on a bad network → the app
goes to the background → `suspend()` cancels the pass → the pass cannot unwind until the mint
answers, and the token request is alive in the background outside any `BGTask` (invariant 15,
"including while a podcast keeps the process alive"). The same inside a `BGAppRefreshTask`
whose expiration handler waits for the pass to stop. How long is decided entirely by P01b's
`URLSession` (60 s between packets by default; days with `waitsForConnectivity`). No test with
a fake mint can see it — P23a's "after `suspend()` an hour makes no request" passes regardless.

Smallest fix in this package: one sentence on `Mint` — it must answer or throw in bounded time
by itself, because the flight cannot cancel it and its callers cannot stop waiting.
For the architect, before P23a: either accept one token request finishing in the background
and give P01b's session a short request timeout (and say P23a and P25 never wait for a pass to
unwind inside `suspend()` or an expiration handler), or add a way for `suspend()` to cancel
mints in the air. Either is fine; unstated is not.

---

## MINOR

1. **A late `drop` throws away a newer token.** `MailTokenFlight.swift:96-98`. `drop(account:)`
   cannot know which token got the 401. A and B both hold dead `T1`; A: `drop`, `token` → mint
   → `T2` cached; B's 401 lands: `drop` discards `T2`; B mints `T3`. With `messages(ids:)`'s
   four in flight that is up to four mints, and (invariant 2) a `users.getProfile` for each new
   token string. Bounded waste, never a wrong answer; the ledger's chain does not change it.
   The fix is the architect's, because `MailTokenSource.drop(account:)` (5.1),
   `dropMailAccessToken(accountID:)` and the ledger's `dropToken` have the same shape: pass the
   token that failed and drop only if it is still the cached one.
2. **An empty scope set withdraws a working account, and no test says whether it should.**
   `MailAccountRules.swift:61-63`. `parse` never produces `[]`, but the rule is the last line
   of defence and takes `[]` as "known, lacks Gmail". The only test that passes `[]` is the
   Mail-off grid (`MailAccountRulesTests.swift:44`). Any other producer of the set (a fake,
   P01b's record with `decodeIfPresent ?? []`) reaches it. Recommend
   `if let tokenScopes, !tokenScopes.isEmpty, …` and a test — no real token has no scopes, and
   the wrong answer in the other direction heals through the 403 row. If the architect prefers
   it as written, pin that instead.
3. **A 403 against a scope list that names Gmail is not pinned.**
   `MailAccountRulesTests.swift:86-88` tests `serverRefused` with unknown scopes only. Add
   `state(scopes: [gmail], serverRefused: true) == .needsAccess(.withdrawn)`: the server's
   refusal outranks what the token response claimed.
4. **`waitForCalls` hangs where the file promises a failure.** `MailTokenFlightTests.swift:102-113`,
   used at :222, :425, :442. If the second account ever joined the first's mint, :222 never
   returns and the test run hangs instead of failing — the header (:130-132) promises the
   opposite for `waitForCallers`. Give it the same bounded poll.
5. **The two-account test cannot tell whose token is whose.** `MailTokenFlightTests.swift:215-230`
   discards both values, and the script hands out `t1`/`t2` in call order, which is not fixed.
   Nothing pins "each account is given its own token" under concurrency. Let a scripted outcome
   name the token after the account it was minted for, and assert both.
6. **An unused scripted outcome.** `MailTokenFlightTests.swift:164`: `.token("t2")` is never
   reached. Either use it — an eleventh caller after the shared failure gets `t2`, `calls == 2`,
   which pins that a failed mint is cleared while its waiters are still being answered — or
   remove it. Likewise a caller arriving after the ten are answered (`calls` still 1).
7. **`waitingCallers(for:)` counts by account, not by mint.** `MailTokenFlight.swift:115-121`.
   After `forget`, callers on the old mint and on the new are added together, which is not what
   the comment (or 3.3's block) says, and the tests of MAJOR 2(c) will lean on it. Reword, or
   count per flight. It is otherwise safe to leave in the app: an isolated read of an integer,
   no token, no effect; the zero entries it leaves behind are one integer per account.
8. **Three comments.** `MailTokenFlight.swift:24` says the closure is "`GoogleTokenMinter`, in
   `MailApp/`": the minter is `Banana/Model/GoogleTokenMinter.swift`, and by the corrected 3.3
   the closure the flight is given is the ledger's. `MailAccountAccess.swift:10` (`P01b`) and
   `MailClock.swift:16` (`P02`) name packages; the committed mail files cite sections only.
   `MailTokenFlight.swift:43-46` states a fact about `GoogleTokenMinter.swift:77-80` — P01b's
   *Must not* now protects it; nothing in the tests does.
9. **A mint that answers with a token already inside the margin.** With both minutes, a
   response with `expires_in ≤ 120` gives a token that is handed to the waiters and cached but
   never served from the cache: every later call mints, one at a time. No loop and no failure;
   unpinned and unsaid. One test or one sentence.

---

## Where the code and the document disagree

After the corrections, on no name: 3.3's block (`Minted`, `Mint`, `renewalMargin`,
`init(clock:mint:)`, `token(for:)`, `drop(account:)`, `forget(account:)`,
`waitingCallers(for:)`) is the code's, `MailClock.swift` is the protocol and nothing else, the
rejection-kind tests are where the entry puts them, and every test the P01a entry lists exists.
What remains:

- `MailTokenFlight.swift:24` against 3.3: who the closure is (MINOR 8).
- 3.3's block and the code both say `waitingCallers` counts the callers on "the account's
  mint"; the code counts the account's callers on any mint (MINOR 7).
- 3.3 rule 1 has no test (MAJOR 2b); rule 4 is tested only without overlap (MAJOR 2c).

## For the next packages

- **P02.** `now` is read synchronously inside the flight's isolation, so `ManualMailClock` in
  `M/MailClocks.swift` must be a locked class, not an actor.
- **P10a.** Its fake token source stands in for a flight that hands a *cancelled* caller a
  token, not an error: `GmailSession.call` should check cancellation after `token(for:)`. And
  5.1 takes the token before `governor.take`: the margin covers the moment of return, not a
  minute's wait for quota — take quota first, or expect the 401 and the retry.
- **P01b (the ledger).** (i) The mint must end by itself (MAJOR 3). (ii) Step 4 of
  `token(for:)` speaks of a *token* from a replaced credential; the old mint can as well
  *throw* (`.rejected`, `.transport`) to a caller whose credential was replaced meanwhile, and
  the entry's own test ("the caller that was waiting is given the new credential's token")
  needs that caught and started again too. (iii) The ledger "makes its own `MailTokenFlight`"
  whose closure reads the ledger's stamps: the closure cannot capture a ledger that is not yet
  initialised — keep the stamps in a small object of their own, made first.
- **P23a.** `MailAccessTokens` crosses the main actor for every Gmail call, cache hit or not,
  and the ledger then crosses to the flight and back. Keep that path free of keychain reads
  and of anything published; watch it in gate A's numbers during a fill.

## Checked and correct

- **3.4, row by row** (`MailAccountRules.swift:44-66`): off first and hiding everything; a
  grant of none is `notAllowedHere` before any later row, so declining never reads as broken;
  rejected, 403, and known-scopes-lacking-Gmail are `withdrawn`; nil scopes prove nothing;
  waiting before connected. Nothing from the contract is redeclared.
- **`MailScopes.parse`** (`:123-127`): nil, empty and all-blank are nil; never the empty set.
- **`MailGrantRejection(oauthSummary:)`** (`:64-75`): reads only the text before the first
  colon, trimmed, the whole summary when there is none; matches
  `GoogleTokenMinter.OAuthError.summary` in both its forms.
- **3.3's first block** is declared member for member; `MailClock` is 13.6's two lines.
- **The flight, interleaving by interleaving:**
  - Ten callers, one mint: check, join-or-start and the count are one synchronous turn (:82-89).
  - A caller arriving as the mint answers: the task body is isolated to the actor, so
    `finished`/`failed` run before the task completes; the arrival finds the cache or the
    rejection, never an empty slot.
  - A mint that throws: every waiter gets the error; nothing is cached; the entry is cleared,
    so the next caller retries; only `.rejected` is remembered.
  - `drop` clears the token only; `forget` clears token, rejection and the mint's claim.
  - `forget` or `drop` during a mint, and old and new mints overlapping in either order: right
    (the id check) — untested, MAJOR 2.
  - Two accounts: every table is keyed by account; ids are unique across accounts; the mint is
    given, and its answer stored under, the same string. No path crosses accounts.
  - A token expiring between check and use: one minute here, one in the minter, then 401 → `drop`.
  - Cancelling a waiter or the starter does not cancel the mint, and priority is escalated by
    the waiters — right, untested (MAJOR 2).
  - No waiter is left unresumed unless the closure itself never returns (MAJOR 3). No state is
    read after the one `await`. No stale mint can overwrite newer state.
- **Structure:** all four files import Foundation only; no task group, no `async let`; no
  logging; the clock is the only source of time and the flight never sleeps (the test clock
  fails if it does). No file outside the entry's list; nothing on the list missing.
- **Tests:** deterministic — gates and counts, no sleep, no timer; the poll in `waitForCallers`
  is bounded by turns, not time. Apart from the gaps above, each fails if its behaviour
  regresses: the margin on both sides of the edge, rejection remembered and per account,
  `drop` not clearing a rejection, transport and missing-client-id not remembered, a token or
  a rejection arriving after `forget`, the stored form of `MailGrantRejection`.
- **Voice:** the comments say why, in the house's plain sentences.
