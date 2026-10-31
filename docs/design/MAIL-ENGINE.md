# Mail: the engine

Status: design, revised 5 Oct 2026 after six independent reviews. Nothing is built. This is the
engine half of mail — accounts, the local store, sync with Gmail, the outbox, compose and send,
search, attachments, HTML, background work, and the one contract the screens stand on. The
screens are `docs/design/MAIL-UX.md`; the build order for both halves is
`docs/design/MAIL-PLAN.md`. Implementers build from this document one package at a time
(section 18) and should need nothing else.

Owner's brief: Google only, like the calendar; offline first, like the calendar; good enough to
replace Superhuman; fast everywhere; every email cached locally; and — added during review —
standard components wherever one exists, not parsers of our own.

Every claim a design choice rests on carries one of four labels:

| Label | Meaning |
|---|---|
| MEASURED | Measured on this Mac (M1 Max, macOS 26.6, system SQLite 3.51.0). Section 21 gives the command, the output file and the machine's load for each number. Synthetic data; device numbers will be slower and are checked later. |
| DOCUMENTED | Stated by Google or Apple; the source is the research dossier `mail-working/research/gmail-api.md` (section given) unless another is named. |
| ASSUMED | A judgement or an estimate. Named so it can be challenged. |
| UNVERIFIED | Could not be confirmed without a live mailbox. The design works whichever way it turns out; section 19 lists the probe that settles it, and the fake Gmail can be switched to behave either way (17.2). |

Working papers — the reviews, the research, every spike and its raw output — are under
`docs/design/mail-working/`.

## 1. Summary

- **Gmail is the truth and the sync.** Each device keeps its own copy of the mail inside its
  **sync limit** — six months unless he chooses otherwise — and talks to Gmail directly; what
  is older stays in Gmail and is reached by search, which asks the device and Gmail together
  (5.4, 9.4). Read state, labels, archive, drafts and sent mail reach other devices through Gmail
  and nothing else. Banana's own per-conversation state — snoozed until, waiting for a reply,
  muted — is carried by Gmail too, as hidden labels (section 8).
- **Four files, three tiers.** `intent.sqlite` holds what the person did and wrote that Gmail
  does not have yet: small, precious, never deleted by code. `blobs.sqlite` holds each message's
  content as received and as prepared for display: disposable, but costly to fetch again.
  `index.sqlite` and `search.sqlite` are derived and can be rebuilt without downloading a body
  (section 4). All four are opened through GRDB.
- **One sync routine.** First sync, catching up after Gmail's history has expired, repairing
  drift and rebuilding a lost index are the same routine — *reconcile* — started from caches in
  different states (5.3). Only a positive statement from Gmail removes anything, and what the
  engine does not know it never treats as absent.
- **One outbox, desired end state.** Every change is an assertion ("this message has no
  `INBOX`"). It is shown at once, durable within the commit that follows, delivered in batches,
  replayed safely, and undone by asserting the opposite (section 6).
- **A send happens at most once.** A message goes out through `drafts.create` then
  `drafts.send`. An ambiguous result is never retried: the engine looks for the message in Sent
  by its `Message-ID`, and if it cannot find it, asks (section 7).
- **HTML is prepared once, when a message is fetched**, by a real parser, on a paced queue.
  Opening a conversation reads prepared output (section 10).
- **One contract.** The screens touch the engine through one file, `MailContract.swift`
  (section 13). The real engine and an in-memory fixture source both implement it and pass the
  same tests, and the real engine is connected to the screens at every milestone.
- **Nothing runs until Mail is opened on a device, nothing runs in the iOS background outside a
  background task, and nothing CPU-bound runs at full speed off mains power.**

What a device honestly has: **every conversation whose newest message is inside the sync
limit, whole, with its text, searchable offline** — plus every conversation he has a claim
on, however old: starred, drafted in, snoozed, waiting for a reply, scheduled, changed and
not yet delivered, or looked at within the limit (5.4). What is older is **not held**: it is
in Gmail, it is found by search, and it is never spoken of as missing. The limit is his
(decision D3, answered): one month, three, six, a year, or everything. Getting there is
bounded by Google, not by Banana: six months of mail — about 20,000 messages, ASSUMED — is
about an hour and a half of Google's per-user quota and about 500 MB, one day's allowance on
any device; everything, for a 100,000-message mailbox, is four to seven hours of quota and
about five days of allowance (5.4).

## 2. Invariants

Numbered so a review can check code against them. Each names the failure it prevents.

**Never lose or corrupt his mail or his intent**

1. **A failed or incomplete read is never evidence of absence.** A message, a label membership
   or a label is removed only on a positive statement: a `messagesDeleted` history record; a
   `labelsRemoved` record; a per-message read that returns that message's label set; or a 404
   that is the status of a single request naming exactly that message id, with Google's JSON
   error body parsed and its reason `notFound`, made with a token verified as that account's.
   A 404 from anything else — a mutation, a transport, a proxy, an unparsed body — removes
   nothing; it queues a per-message read. Absence from a listing only queues a per-message read.
   *Prevents: the calendar's 291 deleted busy blocks, in mail's shape.*
2. **Every access token is tied to its account before anything is derived from it.** The
   transport layer remembers, per token string, whether `users.getProfile` has answered with the
   account's own address; the first request with an unverified token is that call, whoever
   minted the token. A mismatch stops that account's sync. *Prevents: one account's 404s
   deleting another's mail.*
3. **Removals in bulk are held, and sync continues.** If one reconcile's verify outcome, or the
   last 24 hours of incremental passes, would remove at least 20 messages *and* more than a third
   of an account's cached messages, the removals are recorded and not applied; everything else in
   the pass is applied and the checkpoint moves. The person resolves the hold (5.7). The same
   threshold holds a `labels` read that would remove a third of an account's memberships.
4. **Shown, then durable — exactly.** An action is applied to what is on screen in the same turn
   as the key press. It is committed to `intent.sqlite`, with a full fsync, in the commit that
   follows: each commit carries everything accepted during the previous one. Nothing is
   delivered to Gmail, written to the index, or written to the first-frame file unless it is in
   `intent.sqlite`. If that commit fails — a full disk included — the change is put back on
   screen and the person is told. *Prevents: a change that shows, then silently never reaches
   Gmail.*
5. **`intent.sqlite` is never deleted, reset or migrated destructively by code.** No API removes
   the file, a table, or rows by anything but their key. Resetting the cache, a schema change, a
   full resync and "remove downloaded mail" leave it alone.
6. **An intent leaves the outbox only by being delivered, by being proved moot by a positive
   read, or by the person discarding it.** Never by a timeout, and never because a row is
   missing (invariant 22).
7. **A message is sent through `drafts.send`, never `messages.send`, and a send whose result is
   unknown is never sent again by the engine.** It is looked for in Sent by its `Message-ID`; if
   it is not found it becomes a question for the person. "The draft is still there" is not "not
   sent".
8. **Only the device that owns a scheduled send sends it, and every device says when one is
   late.** No device takes over on its own.
9. **Unsent text never lives only in memory without his knowing.** The composer saves to
   `intent.sqlite`; if that save fails — a full disk, a store that cannot save — the composer
   says so while the text is still on screen (13.3), and keeps trying.
22. **Unknown is not absent.** No rule may treat a missing index row, a stub, a rebuilt row, or a
    label set that no read has established as a statement about Gmail. This is invariant 1
    applied to the outbox's moot check, the labels table, the label janitor and every rebuild.
23. **A stale read never overwrites newer state.** A fetched message's labels replace the stored
    ones only when the fetch is not older than what is stored (5.6).
24. **Derived assertions are derived again before they leave, and leave only from a cache known
    to be fresh.** Anything the engine asserts on the person's behalf because a time came or a
    reply arrived (section 8) is recomputed immediately before delivery, and what the fresh
    computation no longer produces is dropped. None is delivered unless both hold: the pass
    just made succeeded and Google's clock is known; and the account has no enumeration
    unfinished (8.3). "A pass succeeded" is not "the cache is fresh".
25. **Delivery marks only what it sent.** A request records the sequence number of each
    assertion it carries; its answer changes only rows still at that number.
26. **The fill may not exhaust the disk.** The fill, prefetch, preparation and the indexer stop
    under a free-space floor (11.3), long before `intent.sqlite` could fail to commit.
27. **A held send survives leaving, on every platform.** Leaving the app ends the undo hold and
    sends; on the Mac, quit and sleep are delayed until held sends are handed to Gmail (7.5).
28. **A reply's identity lives in its draft row.** `In-Reply-To`, `References` and the thread are
    captured when the draft is made; building it never needs the original again.
29. **A deleted id is a tombstone for a day.** The writer refuses to store a message Gmail
    deleted in the last 24 hours. *Prevents: a fetch in flight bringing deleted mail back.*
30. **Receiving, listing, preparing or warming a message fetches nothing from its sender.**
    A remote picture is fetched only for a message on screen, and only when allowed (10.6).
34. **Not held is not deleted, and held is held whole.** A device keeps the conversations
    inside its sync limit and the ones he has a claim on (5.4), each of them whole. A
    conversation it does not keep has no row here of any kind — not a stub, not a tombstone —
    and that absence is a fact about this device, never about Gmail: nothing may read it as
    "deleted", "empty" or "gone". Letting a conversation go because the limit moved is
    *release*: it follows from the device's own rule and from nothing Gmail said; it is never
    counted, held, announced or drawn as a removal; and it never takes a conversation he has
    a claim on.

**Performance**

10. **The main thread does no SQLite, no JSON decoding of mail, no HTML work and no MIME work.**
    Its only mail I/O is one small snapshot file, read once, only when Mail is the tab being
    restored, and two integers for the badge.
11. **A reader never holds a transaction across a suspension point.** GRDB's read closures are
    synchronous, so this is a compile error rather than a convention. *Prevents: an
    uncheckpointable log; 486 MB in five seconds (MEASURED).*
12. **No checkpoint runs inside a person's action.** Auto-checkpoint is off; each store's
    writer checkpoints between pieces of work, never inside one, and does not wait to be idle
    (4.2).
13. **Publishing is at the rate of meaning.** `MailStatus` and `MailBadges` change at most once a
    second and only when a value changed. A list observation delivers once per command the
    person gave and at most once a second from sync; a search delivers at most twice per query
    (the device's answer, then Gmail's); an open conversation once per change to it. A sync
    pass that changed nothing delivers nothing.
14. **A held movement key never reaches published state that re-evaluates a list container.**
    The cursor is a leaf (13.5). (An action key legitimately changes the list once per press.)
15. **On iOS, mail has no timer, no poll and no request alive in the background** except inside
    a `BGTask` or the send-finishing background assertion — including while a podcast keeps the
    process alive. A token request is a request: `suspend()` ends it (3.3, rule 7).
16. **Nothing about mail runs before Mail is first opened on that device** beyond registering
    two background task identifiers.
31. **Local CPU-bound passes are paced.** Preparation, indexing, rebuilds and seeding run at
    full speed only on a Mac on mains power or inside the overnight task; otherwise at a fifth
    of one core, and not at all when the device is warm or in Low Power Mode (4.12).

**Structure**

17. **Everything in `Banana/Model/Mail/` compiles into `BananaTests`.** It may import
    Foundation, Combine, CryptoKit, `os`, UniformTypeIdentifiers and GRDB; one file may import
    SwiftSoup. No GoogleSignIn, UIKit, AppKit, WebKit, BackgroundTasks or UserNotifications, and
    no type from outside the folder except those listed in 17.3. Only Swift files live there.
    GRDB and SwiftSoup are package dependencies of the test target as of the app targets.
18. **Every rule that decides what is kept, sent, removed or shown is a pure function** in its
    own file with its own test class, in the style of `GoogleEventSync`.
19. **No engine code names `GoogleCalendarService`.** Mail reaches accounts through
    `MailAccountAccess`; the calendar code paths that mail can affect are the ones listed in
    3.3 and no others.
20. **No `withTaskGroup` and no `async let` in engine code.** Concurrent requests are separate
    tasks whose `.value` is awaited (owner note `banana-swift-taskgroup-trap`).
21. **Nothing mail writes to a log carries content.** Journal lines carry counts, timings and
    salted hashes of ids; never a subject, a sender, a recipient, a snippet, a file name, a
    query, a label's name, an address, a token, or Google's own error text. The rule covers the
    UI's folders too, and tests enforce it (section 16).
32. **One contract.** No view and no UI model names any engine type that is not declared in
    `MailContract.swift`. Every source of that contract passes the same test suite (13.6). The
    one exception is the in-memory source itself, `MailUI/Pure/Testing/MailFixtureSource*.swift`,
    which also names the engine's pure rules and wire models so that both sources run the same
    rules.
33. **One door to the network.** Every mail request passes one transport object, which refuses
    all of them in an audit-route launch or under `--disable-mail-network` (12.5).

## 3. Accounts and scopes

### 3.1 What exists

`GoogleCalendarService` (2,281 lines, `@MainActor`, imports GoogleSignIn, so not in
`BananaTests`) owns the connected accounts (`accounts`, read from `GoogleAccountStore`'s synced
keychain item), the set of accounts Google has signed out (`accountsNeedingReconnect`), one
access token per account (`tokenCache`), the consent flow (`interactiveSignIn`, `accept`) and an
authorised `send`. All of it is private to that file. `GoogleTokenMinter` is pure and in the
test target.

Mail needs: the list of connected accounts; a `gmail.modify` credential per account; access
tokens minted from it; and a way to ask for that scope.

### 3.2 Three ways to get them

**A. Share the calendar's credential.** Consent replaces the account's one synced refresh token
with one that also carries Gmail; mail calls the calendar service's own token method through a
protocol. This was the first draft's recommendation.

**B. Extract an account type** from `GoogleCalendarService` and have both use it.

**C. Mail holds its own credential, on each device.** Consent for Mail returns a second refresh
token for the same account; mail keeps it in its own keychain item that does not sync, mints
from it with `GoogleTokenMinter`, and never reads or writes the calendar's credential, token
cache or needs-sign-in set.

The first draft chose A because "every existing call compiles to the same code". The
engineering review (E-10) showed that is the wrong test: A shares mutable, published state with
a daily driver, and six calendar behaviours change as soon as anything calls the seam. The
security review (P-9) showed what A puts in iCloud Keychain. Side by side:

| | A: shared credential | C: mail's own credential |
|---|---|---|
| A Google password change | Revokes any refresh token that carries Gmail scopes (DOCUMENTED §12.4). The account's one token is that token: **the calendar is signed out on every device.** | Revokes mail's token on each device. The calendar's token carries calendar scopes only and is ASSUMED untouched (UNVERIFIED; probe W6). |
| "Allow Mail" | Runs the calendar's reconnect: `isWorking`, `lastError` cleared, the synced credential replaced, the account hint republished, every calendar list reloaded, the event cache pruned | Shows Google's sheet and stores one keychain item. No calendar state is read or written. |
| Cancelling Google's sheet | Writes an error into the calendar's Settings (GoogleSignIn's cancel is not a `CancellationError`) | Returns `.cancelled` to mail |
| Minting at mail's pace | `accountsNeedingReconnect.remove` on every mint publishes the calendar service; a Gmail 401 discards the calendar's token; a rejection sets the calendar's `lastError` | Mail's own cache, one mint in flight per account, its own state |
| Another running device | Must swap a refresh token under running calendar code | Nothing to adopt: each device consents for itself |
| Where the Gmail grant lives | One synced item: on every device signed into his Apple ID, whether or not Banana runs there, and in keychain escrow | On the devices where he allowed Mail, `AfterFirstUnlockThisDeviceOnly` |
| Consents | One per account | One per account per device |
| Lines of the calendar's file that change | 5, plus a 60-line extension that calls private methods | 3, plus a 20-line extension that stores nothing |

B has A's sharing and moves several hundred lines of the calendar as well; it stays a later,
separate package (P32) for when a Connected Accounts screen is built.

**Recommendation: C** (decision D15 puts it to the author, with A as the alternative). It is the
only option under which the calendar cannot be signed out, republished or slowed by mail. Its
cost is one more tap-through per device, three devices, once. It gives up the earlier
requirement of "one token cache and one needs-sign-in set": that requirement was meant to keep
the two from disagreeing about one credential, and with two credentials there is nothing to
disagree about — the calendar says whether the account's calendar works, mail says whether its
mail does.

### 3.3 The seam, exactly

`Banana/Model/Mail/MailAccountAccess.swift` (pure; P01a creates it; no existing file changes):

```swift
/// What the engine needs from whoever holds mail's credentials. The engine never sees a
/// refresh token.
@MainActor
protocol MailAccountAccess: AnyObject {
    /// Every account connected to Banana (lower-cased addresses), in the calendar's order.
    var connectedAccountIDs: [String] { get }
    /// What this device holds for an account's mail.
    func mailGrant(accountID: String) -> MailGrant
    /// From mail's own cache, minting if needed; one mint in flight per account.
    func mailAccessToken(accountID: String) async throws -> MailAccessToken
    /// After a 401: forget the cached token so the next call mints.
    func dropMailAccessToken(accountID: String)
    /// Google's consent for Gmail, for this account, on this device. Needs a window in front.
    func requestMailAccess(accountID: String) async -> MailAccessOutcome
    /// Delete this device's mail credential. Revokes nothing at Google.
    func forgetMailAccess(accountID: String)
    /// Mail is leaving the foreground: end every token request in the air. Nothing is
    /// remembered of them; the next call mints again. (Added after P01a's review; rule 7 below.)
    func cancelMailTokenRequests()
}

enum MailGrant: Equatable, Sendable {
    case none                                  // never allowed on this device
    case granted                               // a credential is stored
    case rejected(reason: MailGrantRejection)  // Google refused it: revoked, password changed, expired
}
enum MailGrantRejection: String, Codable, Sendable { case invalidGrant, clientRejected, emptyCredential }
struct MailAccessToken: Equatable, Sendable {
    var value: String
    /// Scopes Google says the token carries, when the token response said. Nil: unknown.
    var scopes: Set<String>?
}
enum MailAccessError: Error, Equatable {
    case unknownAccount        // not in connectedAccountIDs
    case notGranted            // MailGrant.none
    case rejected              // MailGrant.rejected
    case notConfigured         // this build has no OAuth client id
    case transport             // the token endpoint could not be reached or answered 5xx
}
enum MailAccessOutcome: Equatable, Sendable {
    case granted
    case declined              // consent finished without the Gmail scope ticked
    case cancelled             // the sheet was closed
    case differentAccount      // Google signed in another address
    case noWindow              // nothing to present from
    case failed(MailAccessError)
}
enum MailScopes {
    static let gmailModify = "https://www.googleapis.com/auth/gmail.modify"
    /// The scopes in a token response's space-separated `scope` field.
    static func parse(_ scopeField: String?) -> Set<String>?
}
```

The engine re-reads `connectedAccountIDs` and each `mailGrant` at the start of every pass and
on `resume()`; there is no change signal to miss.

**The token flight** — `M/MailTokenFlight.swift`, a pure actor (P01a), tested without a
network because it is built over a closure that mints. As built:

```swift
actor MailTokenFlight {
    /// The token, when it stops being good, and the scopes Google said it carries (nil: it did not say).
    typealias Minted = (value: String, expiresAt: Date, scopes: Set<String>?)
    /// Mints for one account (lower-cased address). Throws `MailAccessError.rejected` for a
    /// credential Google refused — the one failure the flight remembers. **It must end by
    /// itself, within 20 seconds, and must end at once when its task is cancelled**: the
    /// flight has no clock for it, and its callers cannot stop waiting (rules 1, 6, 7).
    typealias Mint = @Sendable (String) async throws -> Minted
    static let renewalMargin: TimeInterval = 60

    init(clock: MailClock, mint: @escaping Mint)
    /// The cached token, or the answer of the mint in the air, or of one this call starts.
    func token(for account: String) async throws -> MailAccessToken
    /// After a 401: the cached token goes; the next call mints. A remembered rejection stays.
    func drop(account: String)
    /// The credential was replaced or deleted: the cached token, the remembered rejection and
    /// the claim of any mint in the air all go.
    func forget(account: String)
    /// Cancels the task of the account's mint in the air, if there is one, and changes
    /// nothing else. (Added after P01a's review; rule 7.)
    func cancelMint(account: String)
    /// For tests only: how many callers are suspended for the account right now — on any of
    /// its mints, an old one and its replacement together after `forget`.
    func waitingCallers(for account: String) -> Int
}
```

1. **One mint per account is in the air**, and every caller that arrives while it runs awaits
   it and shares its answer, a failure too. **A caller that is cancelled does not leave the
   wait and does not end the mint**: it stays until the mint answers, and is then handed what
   the mint brought — the token, not `CancellationError`. The mint is not its to cancel; the
   others share it. Staying is safe because the wait is short (rule 6) and ends at once when
   mail leaves the foreground (rule 7); and no cancelled caller *uses* what it was handed,
   because the one way to the flight is the ledger, which checks (below). Leaving early would
   mean a waiter of its own for every caller, in the code that guards his accounts, to save at
   most twenty seconds of a suspended task.
2. **The margin.** A cached token is used only while *more than* `renewalMargin` — 60 seconds
   — remains before its `expiresAt`; with exactly 60 seconds left it is minted again.
   `expiresAt` is whatever the minting closure reports, and `GoogleTokenMinter` reports
   Google's expiry less a minute, so in the app a token is first renewed **two minutes**
   before Google would refuse it. Both minutes are intended. The minter's is the calendar's
   and mail does not change it (P01b must not); the flight's is its own guarantee and holds
   for any minter, the tests' included. Two minutes in sixty cost nothing. A mint whose token
   is *already* inside the margin is handed to its waiters and cached, and never served from
   the cache: every later call mints, one at a time. No loop and no failure.
3. **`MailAccessError.rejected` is remembered**: later callers are refused at once, with no
   mint, until `forget`. Nothing else is: `.transport` and `.notConfigured` are tried again by
   the next caller. `drop` does not clear a rejection — a 401 says nothing about the
   credential.
4. **`forget` while a mint is in the air.** The mint is not cancelled, and every caller already
   waiting on it is answered with what it brings. But that answer belongs to the old
   credential and is **neither cached nor remembered** — not a token, not a rejection — and
   the next caller starts a mint of its own. Otherwise a rejection of the credential just
   deleted would be held against the one that replaced it.
5. **There is no `replace`.** A replaced credential is `forget`; the next call mints from the
   new one.
6. **The minting closure owns the time limit: a mint ends by itself within 20 seconds.** The
   flight cannot time a mint out — it never sleeps, and the test clock fails if it does — and
   a deadline of its own would still leave the request alive behind it. So the limit is the
   request's: mail's token session (P01b) is ephemeral, with
   `timeoutIntervalForRequest = 15`, `timeoutIntervalForResource = 20` and
   `waitsForConnectivity = false`. A closure that never returned would hold every caller for
   that account, cancelled or not, until `forget`; with this bound the worst case is twenty
   seconds, after which the mint throws, nothing is remembered, and the next caller tries
   again.
7. **Leaving the foreground ends every mint in the air.** `cancelMint(account:)` cancels the
   mint's task and changes nothing else: the mint ends through the ordinary failure path, its
   waiters are told what the closure threw (`.transport` from P01b's closure;
   `CancellationError` from a plain one), nothing is remembered — only `.rejected` ever is —
   and the next caller mints again. A cached token is untouched, and so is every other
   account. A closure that ignored the cancellation would finish within rule 6's bound and be
   cached as usual. `suspend()` reaches it through `cancelMailTokenRequests()`, so
   **invariant 15 holds for token requests too, with no exception**; a background task's
   expiration goes the same way.
8. **A late `drop` may discard a newer token. Accepted.** `drop(account:)` cannot know which
   token got the 401: two requests hold the dead `T1`; the first drops and mints `T2`; the
   second's 401 arrives and its drop discards `T2`; it mints `T3`. The cost is bounded — one
   extra mint, and one `users.getProfile` for the new string (invariant 2), for each request
   that was in the air with the dead token, so at most `maxInFlight` (4) per account per
   event — it is never a wrong answer, and the event is rare, since the margin keeps ordinary
   expiry from reaching Gmail at all. Closing it would thread the failed token through four
   signatures (`MailTokenSource`, `MailAccountAccess`, the ledger, the flight) to save three
   requests on a rare day. A test pins the behaviour, so that changing it is a decision.

**The ledger: who holds the grant** — `M/MailGrantLedger.swift`, pure and `@MainActor` (P01b).
The flight cannot be what `mailGrant` reads: it is an actor, `mailGrant` is synchronous on the
main actor, and the flight is told only *that* a credential was refused, never why. So:

```swift
/// What this device holds for each account's mail, as the main actor reads it — and the one
/// way to a token, so that nothing reaches the flight out of order.
@MainActor final class MailGrantLedger {
    /// A mint from the credential that has this stamp. Throws `MailCredentialRefused` when
    /// Google refuses it; `MailAccessError.transport` or `.notConfigured` otherwise;
    /// `.notGranted` if the account no longer holds a credential with that stamp.
    typealias Mint = @Sendable (_ account: String, _ stamp: Int) async throws -> MailTokenFlight.Minted
    init(clock: MailClock, mint: @escaping Mint)        // makes its own MailTokenFlight

    /// A credential was stored: the first, or a replacement. Returns its stamp.
    @discardableResult func stored(account: String, isEmpty: Bool) -> Int
    /// The credential was deleted.
    func deleted(account: String)
    /// After a 401.
    func dropToken(account: String)
    /// Mail is leaving the foreground: the mint in the air of every account it holds is cancelled.
    func cancelMints()

    func grant(for account: String) -> MailGrant        // synchronous: what `mailGrant` answers
    func token(for account: String) async throws -> MailAccessToken
}
/// What a mint throws for a credential Google refused: the kind, and none of Google's words.
struct MailCredentialRefused: Error, Equatable { let reason: MailGrantRejection }
```

- **One cache, one record.** Mail has one token cache, the flight, and one record of which
  accounts need access, the ledger — and no second copy of either. (This is the earlier
  requirement of "one token cache and one needs-sign-in set", kept where it still means
  something: within mail. Between mail and the calendar it was given up with option C, 3.2 —
  two credentials, nothing to disagree about.) The flight's own memory of a rejection is never
  read for the state; it only refuses, without a mint, callers already past the ledger.
- **`grant`**: no credential, `.none`; one stored with `isEmpty`, `.rejected(.emptyCredential)`;
  a recorded refusal, `.rejected(reason:)`; otherwise `.granted`. A refusal is kept in memory
  for the life of the process, as the calendar keeps its own set: after a relaunch the first
  mint is refused again and the ledger learns it again. Nothing is added to the keychain item.
- **How the reason travels.** Not in `MailAccessError`, which stays as P01a built it, and not
  through the flight. The closure the flight is given is the ledger's own, wrapped round the
  `Mint` it was made with: it reads the account's stamp, calls the mint with it, and when the
  mint throws `MailCredentialRefused(reason:)` it records the reason — **only if the account's
  credential still has that stamp** — and then throws `MailAccessError.rejected` to the flight.
  So `grant` already answers `.rejected(reason:)` when the first caller is told, and a refusal
  of a credential that has since been replaced is recorded against nothing.
- **`token(for:)`**, in order: (1) throws `CancellationError` if its caller has been
  cancelled, then awaits everything the flight is owed, below; (2) reads the grant — `.none`
  throws `.notGranted`, `.rejected` throws `.rejected`, and the flight is not asked; (3) asks
  the flight; (4) **believes the flight's answer — a token or an error, alike — only if the
  account's credential still has the stamp it had at (2)**. If the credential was replaced
  meanwhile, the answer is the old credential's and is dropped, whatever it was, and the
  request starts again at (1); if it was deleted, the request throws `.notGranted`. (5) With
  the stamp unchanged: an error is thrown as it is; a token is returned unless the caller has
  been cancelled, in which case `CancellationError` is thrown instead.
  So no caller is ever handed a token minted from a credential the account no longer holds,
  **and none is told `.rejected` or `.transport` on the word of one** — which matters because
  a replacement during a mint is routine here: `stored` chains `forget`, the request starts
  again, and the new mint runs beside the old one (rule 4 above). And a cancelled caller,
  which the flight answers like any other (rule 1), is told it was cancelled and given no
  token to use; it does not start again.
- **What the flight is owed.** `stored`, `deleted` and `dropToken` are synchronous, because
  the calls that reach them are (`forgetMailAccess`, `dropMailAccessToken`), and the flight is
  an actor. Each writes the ledger at once and appends the flight's call — `forget`, `forget`,
  `drop` — to one chain of tasks per account; `token(for:)` awaits the end of that chain
  first. A call the flight is owed is therefore never overtaken by a request made after it:
  the retry after a 401 cannot be answered with the token just dropped, and a new credential
  cannot meet the old one's cache. Nothing the flight must be told is sent from a task nobody
  awaits.
- **Replaced is `stored`** — a new stamp, the refusal cleared, `forget` chained — and deleted
  is `deleted`. Nothing else clears a refusal.
- **`cancelMints()`** appends `cancelMint(account:)` to the chain of every account the ledger
  holds a credential for, like every other call the flight is owed — so a request made after
  the next `resume()` cannot have its new mint cancelled by a cancel that was still on its
  way.

The implementation, `Banana/Model/MailApp/MailGoogleAccess.swift` (P01b), is a small
`@MainActor` class — the ledger, the keychain item and two calls into the calendar service:

- `connectedAccountIDs` is `GoogleCalendarService.shared.accounts.map(\.id)`.
- Credentials live in `MailCredentialStore`: one generic-password item, service
  `com.boris.banana.google-mail`, `kSecAttrSynchronizable = false`,
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (a background refresh must mint while the
  phone is locked), holding `[{email, refreshToken, scopes, grantedAt}]` as JSON decoded with
  `decodeIfPresent` for every field but the first two. It is read once, when the access object
  is made; each credential found is told to the ledger (`stored(account:isEmpty:)`, `isEmpty`
  for one with no refresh token) and kept in memory beside the stamp the ledger gave it.
- `mailGrant` is `ledger.grant(for:)`. `mailAccessToken` throws `.unknownAccount` for an
  account not in `connectedAccountIDs`, and otherwise is `ledger.token(for:)`.
  `dropMailAccessToken` is `ledger.dropToken`. `forgetMailAccess` deletes the credential from
  the keychain item and calls `ledger.deleted`. `cancelMailTokenRequests` is
  `ledger.cancelMints()`.
- The `Mint` it gives the ledger looks up the refresh token of the credential with that stamp
  (`.notGranted` if the account no longer holds it) and calls
  `GoogleTokenMinter.mint(refreshToken:clientID:session:)` with mail's own token session:
  ephemeral, `timeoutIntervalForRequest = 15`, `timeoutIntervalForResource = 20`,
  `waitsForConnectivity = false` — rule 6's twenty seconds, and `URLSession`'s async call ends
  when its task is cancelled, which is rule 7's other half.
  `MintError.credentialRejected(reason:)` becomes
  `MailCredentialRefused(reason: MailGrantRejection(oauthSummary: reason))`; `.transport`
  becomes `MailAccessError.transport`; a missing client id, `.notConfigured`.
- **The rejection kind** is read by `MailGrantRejection(oauthSummary:)` from the minter's
  summary, which is Google's error code, a colon and its sentence, or the code alone: **the
  code is the text before the first colon, trimmed — the whole summary when it has no colon.**
  `invalid_grant` is `.invalidGrant`; `invalid_client` and `unauthorized_client` are
  `.clientRejected`; anything else, and no summary at all, is `.invalidGrant`.
  `.emptyCredential` is never read from a summary. **Only the enum is kept; Google's words are
  not stored, shown or logged.**
- `requestMailAccess`: calls `GoogleCalendarService.shared.googleConsent(hint:scopes:)` with
  `[MailScopes.gmailModify]`; maps `GoogleConsentError.cancelled` to `.cancelled` and
  `.noWindow` to `.noWindow` (no text is matched: the calendar's own error type is private to
  its file, so the extension below translates it); compares the returned address with the
  account (`.differentAccount`); checks the granted scopes include Gmail (`.declined`); writes
  the credential to the keychain item and calls `ledger.stored` — which is what "replaced"
  means when the account already had one.

**Changes to existing files — the whole list (P01b):**

1. `GoogleCalendarService.interactiveSignIn(hint:)` becomes
   `interactiveSignIn(hint:scopes: [String] = GoogleCalendarService.requiredScopes)`, and its two
   `additionalScopes: Self.requiredScopes` arguments, both inside that function, become
   `additionalScopes: scopes`. Three lines change. `connect` and `reconnect` pass nothing.
2. An extension appended to the same file:
   ```swift
   extension GoogleCalendarService {
       /// Google's consent sheet for one address and a scope list. Stores nothing and changes no
       /// calendar state. Signs the SDK's own session out afterwards (locally; nothing is revoked).
       func googleConsent(hint: String, scopes: [String]) async throws -> GoogleConsentResult   // throws GoogleConsentError
   }
   struct GoogleConsentResult { var email: String; var refreshToken: String; var grantedScopes: [String] }
   enum GoogleConsentError: Error { case noWindow, cancelled, failed }
   ```
   Being in the same file, it can see the private `GoogleCalendarError`: it maps
   `.noPresentationContext` to `.noWindow`, GoogleSignIn's cancel code to `.cancelled`, and
   everything else to `.failed`.
   It calls `interactiveSignIn(hint: hint, scopes: scopes)`, reads the three values from the
   returned user, calls `GIDSignIn.sharedInstance.signOut()`, and returns. It does not call
   `accept`, does not assign `accounts`, and does not touch `tokenCache`, `isWorking`,
   `lastError`, `accountsNeedingReconnect` or the account hint.
3. `GoogleTokenMinter`: `mint` gains `session: URLSession = .shared`; `RefreshResponse` also
   decodes `scope: String?`; `MintedToken` gains `var scopes: Set<String>? = nil`; and the
   response decoding moves into `static func token(from data: Data, now: Date) -> MintedToken?`
   so it can be tested without a network.
4. `BananaApp`'s `.onOpenURL` dispatches by scheme: the Google reverse-client-id
   scheme to `GIDSignIn.handle`, everything else ignored (P-7; `banana://` is not registered
   in the first release).

**Every calendar code path whose behaviour could change, and what holds it:**

| Path | Could change how | Held by |
|---|---|---|
| `connect()`, `reconnect()` → `interactiveSignIn` | They now call a function with a defaulted parameter | The default is today's value; the diff shows it |
| The SDK's `currentUser` after a mail consent | `disconnect()` (all accounts) calls `GIDSignIn.disconnect`, which revokes the *current user's* grant at Google — for every device | `googleConsent` signs the SDK out locally before returning, leaving the state every relaunch already leaves |
| The presenter lookup | A consent started from Mail's settings uses the same window search | Unchanged code |
| The return from Google's sign-in on iOS | `.onOpenURL` today hands every URL to `GoogleCalendarService.handleOpenURL`; after change 4 only URLs with the Google reverse-client-id scheme reach it | That scheme is the only one registered for the app, so the same URLs arrive; P01b's acceptance includes a calendar sign-in completing on iOS, by the owner |
| Google's side | Granting Gmail to the same OAuth client may change how Google treats the calendar's older token on a password change | UNVERIFIED; probe W6 and decision D15 |

Nothing else in the calendar is reachable from mail. The before-and-after check is in P01b.

What must not be done, and why (integration map, "Traps"):

- No field is added to `GoogleAccountCredential`, and mail's credentials do not go in
  `GoogleAccountStore`.
- The Gmail scope is never added to `requiredScopes`.
- `GIDGoogleUser.addScopes` is not used.
- Mail never calls `disconnect`, `GIDSignIn.disconnect` or the revoke endpoint. Revoking
  removes the grant for every device (DOCUMENTED §12.3).
- Mail never removes an account whose Gmail call fails. Mark, never remove.

**If the author chooses A instead (D15):** `MailGoogleAccess` asks the calendar service for the token
instead of minting, through a second small extension; consent calls `interactiveSignIn` and
`accept` directly (not `reconnect`), returns its outcome from the errors thrown, and does not
touch `isWorking` or `lastError`; `accessToken(for:)` gains a single flight per account and its
`accountsNeedingReconnect.remove` is guarded by `contains`; a running device adopts a changed
credential on a real return from the background. The protocol above is unchanged, so nothing
in the engine differs. The password-change coupling stays, and is his to accept.

**The seam, whichever he chooses.** Everything from "The token flight" to here is behind
`MailAccountAccess` and inside P01b: the flight, the ledger, the rules above and the keychain
item are how option C answers the protocol, and no engine file names any of them. Under A,
`MailGoogleAccess` answers the same seven members from the calendar's credential — its
`mailGrant` from the calendar's needs-sign-in set, its `cancelMailTokenRequests` doing what the
calendar's minting allows — and P01b's entry is the only one that changes. "One token cache
and one needs-access record" then means the calendar's, shared; under C it means mail's own.

### 3.4 One account's state

Pure: `MailAccountRules.state` in `Banana/Model/Mail/MailAccountRules.swift`. The two types it
answers in, `MailAccountState` (`off`, `waitingForFirstOpen`, `needsAccess(MailAccessGap)`,
`connected`) and `MailAccessGap` (`notAllowedHere`, `withdrawn`), are declared in the contract
file (13.2), because the screens name them; this file declares the rule only.

```swift
enum MailAccountRules {
    static func state(wantsMail: Bool, activatedOnThisDevice: Bool, grant: MailGrant,
                      tokenScopes: Set<String>?, serverRefusedScope: Bool) -> MailAccountState
}
```

In order: `off` if not turned on; `needsAccess(.notAllowedHere)` if the grant is `.none`;
`needsAccess(.withdrawn)` if the grant is `.rejected`, or Gmail has answered 403 for a missing
scope since the grant, or the token's own scope list is known and lacks Gmail;
`waitingForFirstOpen` if this device has not opened Mail; otherwise `connected`.

The brief's four states: *connected* is `connected`; *needs sign-in* is
`needsAccess(.withdrawn)`; *connected without Mail* is a connected calendar account whose mail
state is `off` or `needsAccess(.notAllowedHere)`; *Mail off* is `off`. An account the calendar
shows as "Sign in again" can still have working mail, and the reverse; each says so about itself.

Two facts decide the state, and they come from different places on purpose:

- **Mail on for this account** is a setting, synced like every other (`AppSettings.Snapshot`
  gains an optional `mailAccounts: [String: Bool]`). Default off for every account (D6).
- **Activated on this device** is device-local (a dot-free `UserDefaults` key,
  `mailActivatedAt`). The phone starts the first time Mail is opened on it.

### 3.5 Consent

"Allow Mail on this iPhone" calls `requestMailAccess(accountID:)`.

- **iOS and iPadOS:** GoogleSignIn's sheet from the foreground-active key window; no window in
  front returns `.noWindow`.
- **macOS:** the same call with `NSApp.keyWindow ?? mainWindow ?? windows.first`; with only the
  menu-bar item showing it returns `.noWindow`, and the screen says to open Banana's window.
- **An unticked box:** the outcome is `.declined`; mail shows the button again; nothing else
  happened.
- **The app and Google Cloud:** both OAuth projects (production `411369831522…`, beta
  `439702026992…`) need the Gmail API enabled and the scope on their consent screens. Until
  then every Gmail call answers 403 `accessNotConfigured`, reported as `apiDisabled`
  (section 14). `gmail.modify` is a restricted scope; D1 covers the consent screen's publishing
  status, which also decides whether refresh tokens die every seven days.
- **Each device asks once per account.** Beta devices always did (other OAuth clients).

### 3.6 Turning Mail off, disconnecting, and what is not revoked

- **Mail off for an account:** its sync stops and it disappears from Mail's lists at once. Its
  cache stays unless "Remove downloaded mail from this device" is chosen, which deletes that
  account's rows from the cache files, withdraws its notifications, and touches nothing in
  `intent.sqlite`. If changes or unsent messages for it are still in the outbox, the person is
  told how many; they stay queued, and turning Mail on again delivers them.
- **Account disconnected** (the calendar's `disconnect(email:)`): the account disappears from
  `connectedAccountIDs`. Mail marks it detached and stops. Its cache is deleted after it has
  been absent for seven days running — not sooner, because the synced keychain can bring an
  account back moments later. Its unsent messages and undelivered changes are never deleted;
  they are listed as "From an account no longer connected", each with Discard.
- **Nothing here revokes anything at Google.** Disconnect removes the account from Banana;
  "Forget Mail access on this device" deletes this device's mail credential. Banana's access at
  Google ends only when he removes it at myaccount.google.com › Security › Third-party access,
  or changes his password. The screens say so, with a button that opens that page (D16).
- The existing "Disconnect all accounts" calls `GIDSignIn.disconnect`, which revokes — for
  every device — the grant of whichever account the SDK signed in during that run, and nothing
  for the others. `googleConsent` signs the SDK out locally before it returns, so a mail
  consent never becomes that account (3.3). What the button should say or do is D16.

## 4. The store

SQLite, through **GRDB** (7.11.1, exact pin). The first draft used the C API behind a wrapper
of its own; the owner's ruling — standard components, not our own — and the reuse review
replaced that wrapper with the library that already is one. GRDB brings statement caching,
typed binds, serial queues per connection, WAL pools, migrations and interruption, and it is
used for those and nothing more: no `ValueObservation`, no record types on the list path, no
`erase` (13.7, 4.8). It has three behaviours the design depends on knowing, each pinned by a
test in P02:

- **GRDB sets `synchronous=NORMAL` on a WAL database after `prepareDatabase` has run.**
  MEASURED: a store opened with any configuration reads back `synchronous = 1`. GRDB leaves
  `fullfsync` alone: set in `prepareDatabase`, it survives and reads back 1 (MEASURED by P02;
  this line once said 0, which was only the default of a store that had not set it). Intent's
  `synchronous = FULL` is therefore set again *after* opening, both are read back, and a
  connection that does not answer FULL with full fsync is not handed out.
- `interrupt()` on a pool interrupts every connection of that pool — so search gets a
  connection of its own.
- The file-protection open flag is not exposed — so protection is set on the directories and
  on each file after it is created.

### 4.1 Files

```
<AppSupport.directory>/BananaMail/                 ← `MailDirectories(root:)`; tests pass a temporary folder
├── Intent/                                        precious — invariants 4–6, 9
│   ├── intent.sqlite (+ -wal, -shm)               what was done and written, not yet in Gmail
│   └── Attachments/<localDraftID>/<attachmentID>  files attached to unsent messages
└── Cache/                                         disposable — may be deleted whole at any time
    ├── index.sqlite                               messages, threads, labels, views; sync state
    ├── search.sqlite                              the full-text index (derived)
    ├── blobs.sqlite                               each message's content, as received and as prepared
    ├── Attachments.noindex/<aa>/<sha256>.<ext>    downloaded attachment bytes
    ├── Remote.noindex/<sha256>                    remote pictures, once loaded
    └── first-page.json                            the last list page drawn, for the first frame
```

Named `BananaMail`, not `Mail`: on the Mac `AppSupport.directory` is the root of
`~/Library/Application Support`. Everything is in Application Support and nothing in `Caches`
(11.3).

| Tier | Files | If lost | Enforced by |
|---|---|---|---|
| Intent | `Intent/` | Undelivered changes, unsent messages and their attachments are gone. Nothing rebuilds it. | A separate directory and a separate type, `MailIntentStore`, which keeps its GRDB handle private and has no delete, reset, `erase` or `VACUUM INTO` method. `MailCache.reset()` takes `Cache/`'s URL and nothing else; a test resets the cache with pending intents and asserts they survive and re-apply. |
| Content | `blobs.sqlite`, `Attachments.noindex`, `Remote.noindex` | Bodies are fetched again: 20 units each (DOCUMENTED §0) and Google's bandwidth. Headers, labels and search are unaffected for as long as the index holds them. | Keyed by account address and Gmail ids — never by a local row id — so it survives an index rebuild. |
| Derived | `index.sqlite`, `search.sqlite`, `first-page.json` | `index.sqlite` is rebuilt from `blobs.sqlite` plus one cheap reconcile; `search.sqlite` is rebuilt from `blobs.sqlite` with no network at all. | Each records the version of the code that derived it (`derived_version`); a mismatch triggers the rebuild. |

**Why the full-text index has its own file** — the first spike's comparison, at 200,000
messages (MEASURED), which the re-measurement did not change:

| | FTS in `index.sqlite` | FTS in its own file |
|---|---|---|
| File holding lists and threads | 1,249.5 MB | 141.3 MB then; 172.7 MB with today's schema |
| List page anywhere in All Mail, p50 / p99 | 0.204 ms / 0.906 ms | 0.041 ms / 0.060 ms |
| Sync transaction of 50 messages, p50 / p95 | 43.2 ms / 84.2 ms | 5.4 ms / 25.4 ms |
| `PRAGMA quick_check` | 8.77 s | 0.38 s |

The re-measurement adds two more reasons: writing the same 50 messages' search entries takes
41 ms p50 and 118 ms p95, and deleting 50 messages' entries 88 ms p50 and 375 ms p95 — work
that, in its own file, never touches the queue a person's action waits on.

**Backup, protection, and what is readable by whom.**

- `BananaMail/` is created with `isExcludedFromBackup = true` on both `Intent/` and `Cache/`,
  and nothing in it is added to `CloudBackup`'s allowlist. Excluding the cache is the brief.
  Excluding intent is a choice: a device restored from last week's backup would otherwise
  replay last week's "archive this" over whatever was done since.
- No mail state goes in `UserDefaults` (it is copied whole into the iCloud backup snapshot),
  with three exceptions, none of them mail's content: `mailActivatedAt`, the shell's position
  (13.8), and the two badge numbers of 12.4.
- **Protection classes.** The four databases and `Intent/Attachments` are
  `completeUntilFirstUserAuthentication`: a background refresh must read and write them while
  the phone is locked. On a locked phone that has been unlocked once since it started, they are
  therefore readable to anything that can run code on it — the ordinary class for third-party
  apps, and weaker than Apple Mail's. `Attachments.noindex`, `Remote.noindex` and
  `first-page.json` are `complete`: unreadable while locked; the engine treats them as absent
  then (P-17). The classes are made true in two places, because neither is inherited the way
  it reads (N-3): `MailDirectories` sets each directory's class **before any store is
  opened**, so SQLite's `-wal` and `-shm` files are born with it; and `MailFiles` sets a
  file's class **after** its atomic move (11.2). **What is tested where.** The Simulator does
  not enforce protection classes and reports none (MEASURED by P02: there is nothing there to
  assert), so the unit test watches the *calls* and their order, through `MailFileAttributes`:
  each directory's class before the first store is opened, a file's class after its move.
  The classes themselves are read back **on a device**, by the `protection` check of
  `--verify-mail-bench` (P09a) in the owner's first device run (D18): from
  `index.sqlite-wal`, from `first-page.json`, and from a file installed through `MailFiles`
  in `Attachments.noindex`.
- **On the Mac the whole store is readable by any program he runs.** It is under Application
  Support, not behind the system's Mail privacy prompt. FileVault protects it from someone
  with the disk, not from software on the Mac. Encrypting bodies and attachments under a
  keychain key is possible and is not built; D17 puts it to him.
- Nothing mail holds is on the pasteboard unless he copies it; the app-switcher snapshot and
  state restoration are the app's existing blank-on-background and `ShellState` (13.8).

### 4.2 Connections and where they run

| Store | GRDB object | Connections | Page cache each | QoS | Does |
|---|---|---|---|---|---|
| `index.sqlite` | `DatabasePool` | 1 writer, 2 readers | 4 MB | userInitiated | Every index write: sync batches, overlay, summaries, views. Reads: list pages, counts, a conversation's rows, background scans. |
| `intent.sqlite` | `DatabaseQueue`, private to `MailIntentStore` | 1 | 1 MB | userInitiated | Every intent write and read |
| `blobs.sqlite` | `DatabasePool` | 1 writer, 2 readers | 2 MB | utility (reads for an open conversation: userInitiated) | Content writes, prepared output, eviction; bodies for the reader |
| `search.sqlite`, writing | `DatabaseQueue` | 1 | 4 MB | utility | Full-text indexing |
| `search.sqlite`, reading | a second, read-only `DatabaseQueue` with `index.sqlite` attached as `idx` and `blobs.sqlite` as `blobs` | 1 | 8 MB | userInitiated | Search and autocomplete; `interrupt()` cancels a superseded query (MEASURED: it ends in 1.5 ms p50, 2.6 ms at most) and cannot touch a list read |

At most 31 MB of page cache in all, usually far less.

Rules:

- **GRDB's `read` and `write` closures are synchronous**, so no transaction can be held across
  a suspension point (invariant 11) — it does not compile. From `async` code the engine uses
  GRDB's `async` variants, which run the closure on the connection's own queue; nothing calls a
  blocking GRDB method from Swift's cooperative pool or from the main thread, and
  `dispatchPrecondition(condition: .notOnQueue(.main))` in `MailStores` proves it in tests
  (`MailMainQueueGuard`). **Opening the stores is a blocking call with no `async` variant**:
  it runs on a `DispatchQueue` of the engine's own, never in a detached task — a detached
  task runs on the cooperative pool (12.1, `activate()`).
- **One writer queue for what a person's action touches.** `MailWriter` is a serial
  `DispatchQueue` (`mail.writer`) of the engine's own. Work submitted to it calls
  `intent.write` and then `index.write`, in that order, each synchronously. Sync's index
  batches are submitted to the same queue, so an action waits behind at most one.
- **A sync batch is at most 20 messages.** MEASURED with a list reader running, through GRDB,
  on the design's schema (machine heavily loaded; 21): a transaction of 50 messages holds the
  writer 5.1 ms p50, 23.7 ms p95, 41.7 ms p99; of 20 messages, 1.6 ms p50, 6.2 ms p95, 18.4 ms
  p99. The first design's 50 was at its own 30 ms budget on a desktop SSD; 20 leaves room for
  a phone's flash (R-11).
- **Group commit takes what arrived** (6.2): there is no window. MEASURED: one intent commit
  carrying 1, 5, 20 or 50 actions costs 0.8, 0.3, 0.6 and 1.1 ms p50 — the cost is per commit,
  not per action — so a burst is absorbed at whatever rate the disk allows.
- **Background reads are short.** A scan (reconcile's close, a split rebuild, eviction
  planning) reads at most 500 rows per `read` and gives the connection back, so with two
  readers a list read never waits behind more than one of them.
- **Pragmas** (`Configuration.prepareDatabase`), for every connection: `journal_mode=WAL`,
  `temp_store=MEMORY`, `foreign_keys=OFF` (relations are kept in code and checked by the
  repair pass), `busy_timeout=2000`, the cache size above. The busy timeout is said for every
  connection because GRDB gives a pool's readers ten seconds of its own (MEASURED by P02).
  Every connection that can write adds `wal_autocheckpoint=0` and
  `journal_size_limit=8388608` (the checkpoint rule, below). **A read-only connection — a
  pool's readers, the search reader — keeps SQLite's default `wal_autocheckpoint` of 1000,
  and it can never fire**: an automatic checkpoint is run by the connection that has just
  committed to the log, after its own commit, and a read-only connection commits nothing
  (DOCUMENTED: sqlite.org/wal.html, "Automatic checkpoint"; the log's commit hook is called
  only on the connection that wrote). Invariant 12 does not rest on that number.
  `index`, `search` and `blobs` stay at GRDB's `synchronous=NORMAL` (a power cut may lose the
  last commits, which sync replays; it cannot corrupt). **`intent` executes `PRAGMA
  synchronous=FULL; PRAGMA fullfsync=ON` after it is opened**, and P02's test reads both back.
  Both are settings of a *connection*, not of the file: they are set in `prepareDatabase` and
  again after opening (GRDB's own pragma runs between the two: it resets `synchronous` and
  leaves `fullfsync`, which is set twice only so that nothing rests on that), on every
  connection that ever writes the file — which is one, because the intent store is a
  `DatabaseQueue` and must never be opened as a pool; the salvage path of 4.10 sets them on
  its fresh file before the first row (`MailStores.openIntentQueue(at:)` is that one way, for
  both). **The second setting is made outside a transaction**: inside one, SQLite refuses to
  change `synchronous` — it throws; it is not silently ignored (MEASURED by P02). P14a's test
  reads them back from a newly opened `MailIntentStore` on an existing file and again after
  `releaseMemory()` (S-N7).
  As read back by P02's test: every connection `journal_mode` wal, `temp_store` 2,
  `busy_timeout` 2000; the index writer `synchronous` 1, `wal_autocheckpoint` 0; intent
  `synchronous` 2, `fullfsync` 1; pool readers `synchronous` 1, `wal_autocheckpoint` 1000.
  MEASURED through GRDB, interleaved on one file: `NORMAL` 0.04 ms a commit, `FULL` 0.10 ms,
  `FULL` with `fullfsync` 0.38 ms p50, 0.70 ms p95 — the full fsync is real and is what is
  paid. `blobs.sqlite` is created with `auto_vacuum=INCREMENTAL` so eviction can give pages
  back.
- **Checkpoints never run inside a person's action** (invariant 12), and never wait for idle
  either: after any piece of work — a sync batch or an action group — that leaves a log
  **holding more than 8 MiB**, that store's writer runs a `PASSIVE` checkpoint before taking
  the next piece, and a `TRUNCATE` on backgrounding and quit (`truncateCheckpoint()`, called
  by `MailRuntime.suspend`).
  **How "holding more than 8 MiB" is measured.** By the length of the `-wal` file, which
  needs nothing from SQLite — once one pragma has made that length mean what it should. A
  `PASSIVE` checkpoint copies the log back and does not shorten the file: SQLite starts
  writing again from the file's beginning and leaves it as long as it was. A file once over
  the limit would stay over it, and a test of length alone would checkpoint after every later
  piece, at two fsyncs each (found by P02). So every connection that can write sets
  **`PRAGMA journal_size_limit = 8388608`**: when the log is restarted after a checkpoint,
  SQLite cuts the file back to that length (DOCUMENTED: sqlite.org/pragma.html,
  `journal_size_limit`), and from then on the file is longer than 8 MiB exactly when the log
  holds more than 8 MiB. The rule is `MailCheckpointRule.isDue(logBytes:limit:standing:)` =
  `logBytes > max(limit, standing)`, where `standing` is the length the file was left at by
  the last checkpoint that copied everything back — **and is never more than the file's
  present length**: when the file is cut, the mark comes down with it. `standing` covers the
  pieces between a checkpoint and the restart that cuts the file, and a reader that holds the
  restart off. Without the pragma and that clamp it could only rise: one long reader during a
  fill would leave every later checkpoint at a hundred megabytes and tens of milliseconds,
  until the next quit — which on a Mac may be weeks away.
  **Who checkpoints which log.** One object holds the rule for one log
  (`MailLogCheckpointer`, P02), and each store's one writer has one. `MailWriter` has the
  index's. **`intent.sqlite`'s is `MailIntentStore`'s own** (P14a): the intent queue is
  private to it, so the writer cannot reach that log — but intent is written on the writer's
  queue, inside a piece, so its checkpoint belongs there too, after the piece and never
  inside it. `MailWriter` therefore keeps other logs it is handed
  (`keep(_ log: MailWriterLog)`): after every piece it asks each to checkpoint if due, and
  `truncateCheckpoint()` empties each after the index's. **Each of the other two stores is
  checkpointed by its own one writer**, on its own queue, with the same object —
  `MailBlobStore` for `blobs.sqlite`, `MailSearchIndexer` for `search.sqlite` — so no store
  with auto-checkpoint off is left without anyone. MEASURED: 1,000 actions grow the index's log to 37.8 MB and intent's to 14.3 MB,
  checkpointed in 10.9 ms and 2.1 ms; eight seconds of continuous sync with no checkpoint at
  all grew the log to 348 MB and its checkpoint took 175 ms — which is why "when idle" was not
  enough. With auto-checkpoint on, one action in a hundred paid for a checkpoint inside its
  own commit (p99 18.6 ms against 0.96 ms; first spike).
- **Migrations** are GRDB's `DatabaseMigrator`, one registered migration per schema step, each
  one transaction, additive only. `eraseDatabaseOnSchemaChange` is never set, and a test greps
  for it. A store newer than the code is detected with `hasBeenSuperseded` (4.9).
- **Change notices** come from the writer itself (13.7): when `index.write` has returned, the
  transaction has committed — a rolled-back one throws — and the writer tells its
  `MailChangeSink`, on its own queue, before it takes the next piece. Not from GRDB's
  `afterNextTransaction(onCommit:)`, as this line once said: that callback runs inside the
  database's own serialised access, where a sink could neither read a store nor submit work
  without re-entering it. A write made through `perform` is not a piece and is not announced:
  whatever a screen could show is written by a piece.
- No SQL in the engine uses `ORDER BY rank` (9.2), which with `temp_store=MEMORY` would build
  a temporary table of every match in memory.

### 4.3 `index.sqlite`

Local integer keys (`account_pk`, `label_pk`, `thread_pk`, `msg_pk`, `view_pk`) exist only
inside this file. They are renumbered by a rebuild and never appear in `intent.sqlite`,
`blobs.sqlite`, `ShellState`, a `MailOrderKey`, or anything the UI keeps. Outside this file a
message is `(account address, Gmail message id)`.

```sql
CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
-- 'derived_version', 'created_at', 'unclean' (set while the engine runs)

CREATE TABLE account(
  account_pk        INTEGER PRIMARY KEY,
  email             TEXT NOT NULL UNIQUE,   -- lower-cased
  checkpoint        TEXT,     -- Gmail historyId the cache is current to; NULL = no usable position
  profile_total     INTEGER,  -- users.getProfile messagesTotal at the last handshake
  enum_generation   INTEGER NOT NULL DEFAULT 0,
  enum_checkpoint   TEXT,     -- the position when the running enumeration began
  enum_state        TEXT,     -- JSON {listing, pageToken, done, maxPKAtStart}; NULL = none running
  enum_completed_at INTEGER,  -- ms
  headers_through   INTEGER,  -- ms; every listed message newer than this has its header
  bodies_through    INTEGER,  -- ms; every listed message newer than this has its body
  quota_state       TEXT,     -- JSON: rate, pauses, {day, bytes}
  last_sync_at      INTEGER,
  last_sync_result  TEXT,     -- MailSyncHealth, encoded
  send_as           TEXT,     -- JSON: identities from settings.sendAs.list
  send_as_at        INTEGER,
  labels_at         INTEGER,  -- ms; when a complete labels response was last applied
  removals          TEXT      -- JSON: deletions applied per hour, last 24 (invariant 3)
);

CREATE TABLE label(
  label_pk   INTEGER PRIMARY KEY,
  account_pk INTEGER NOT NULL,
  gmail_id   TEXT NOT NULL,   -- 'INBOX', 'Label_12'; 'local:<name>' until Gmail has created it
  name       TEXT NOT NULL,
  kind       INTEGER NOT NULL,  -- 0 system, 1 user, 2 Banana's own (name begins 'Banana/')
  list_visibility TEXT, message_visibility TEXT, text_color TEXT, background_color TEXT,
  UNIQUE(account_pk, gmail_id)
);
CREATE INDEX label_by_name ON label(account_pk, name);

CREATE TABLE thread(
  thread_pk     INTEGER PRIMARY KEY,
  account_pk    INTEGER NOT NULL,
  gmail_id      TEXT NOT NULL,
  tie           INTEGER NOT NULL,             -- MailOrderKey.tie: a stable hash of (account, thread id)
  -- everything below is derived by ThreadSummaryRules, overlay applied
  last_date     INTEGER NOT NULL DEFAULT 0,
  message_count INTEGER NOT NULL DEFAULT 0,
  fetched_count INTEGER NOT NULL DEFAULT 0,
  unread_count  INTEGER NOT NULL DEFAULT 0,
  flags         INTEGER NOT NULL DEFAULT 0,   -- MailThreadFlags (appendix A)
  subject TEXT, snippet TEXT,
  people  TEXT,                 -- JSON [{n: name, a: address, u: unread}], six at most
  people_total INTEGER NOT NULL DEFAULT 0,
  labels  TEXT,                 -- ',12,45,' label_pks, effective
  wake_at INTEGER, returned_at INTEGER, waiting_until INTEGER,   -- section 8
  pending INTEGER NOT NULL DEFAULT 0,          -- 0 none, 1 undelivered change, 2 a change was refused
  UNIQUE(account_pk, gmail_id)
);

CREATE TABLE message(
  msg_pk        INTEGER PRIMARY KEY,
  account_pk    INTEGER NOT NULL,
  gmail_id      TEXT NOT NULL,
  thread_pk     INTEGER NOT NULL,
  internal_date INTEGER NOT NULL DEFAULT 0,   -- ms; 0 while only the id is known
  fetch_state   INTEGER NOT NULL DEFAULT 0,   -- 0 stub (id only), 1 header, 2 full
  fetch_class   INTEGER NOT NULL DEFAULT 5,   -- FetchPlanRules.fetchClass: 0 first … 9 last
  list_rank     INTEGER NOT NULL DEFAULT 0,   -- order in the listing that found it; smaller = newer
  history_id    TEXT,                         -- the newest history record or read reflected in its labels
  size_estimate INTEGER,
  flags         INTEGER NOT NULL DEFAULT 0,   -- MailMessageFlags: fromMe, hasAttachment, hasInvite, labelsKnown (6.1), …
  vis           INTEGER NOT NULL DEFAULT 0,   -- 0 normal, 1 in Trash, 2 in Spam (effective),
                                              -- 3 rebuilt and not yet confirmed by Gmail, 4 kept though Gmail says gone
  body_kind     INTEGER NOT NULL DEFAULT 0,   -- MailBodyKind once prepared
  prep_state    INTEGER NOT NULL DEFAULT 0,   -- 0 not prepared, 1 being parsed, 2 prepared, 3 shown as text (10.3)
  fts_rowid     INTEGER,                      -- its row id in search.sqlite (4.6)
  fts_state     INTEGER NOT NULL DEFAULT 0,   -- 0 not indexed, 1 header indexed, 2 body indexed
  fts_dirty     INTEGER NOT NULL DEFAULT 0,
  from_addr TEXT, from_name TEXT, subject TEXT, snippet TEXT,   -- cleaned (10.8)
  recipients    TEXT,                         -- JSON {to:[…], cc:[…], bcc:[…]}, addresses
  rfc_message_id TEXT, list_id TEXT,
  auth_domain   TEXT,                         -- MailAuthRules.authenticatedDomain, or NULL
  UNIQUE(account_pk, gmail_id)
);
CREATE INDEX message_by_thread ON message(thread_pk, internal_date);
CREATE UNIQUE INDEX message_by_fts ON message(fts_rowid) WHERE fts_rowid IS NOT NULL;
CREATE INDEX message_stub_queue ON message(account_pk, fetch_class, list_rank) WHERE fetch_state = 0;
CREATE INDEX message_body_queue ON message(account_pk, fetch_class, internal_date DESC) WHERE fetch_state = 1;
CREATE INDEX message_prep_queue ON message(internal_date DESC) WHERE fetch_state = 2 AND prep_state = 0;
CREATE INDEX message_fts_queue  ON message(internal_date DESC) WHERE fts_dirty = 1;
CREATE INDEX message_by_rfc_id  ON message(rfc_message_id) WHERE rfc_message_id IS NOT NULL;

-- Gmail's label state, as last told. Never includes the overlay.
CREATE TABLE message_label(
  msg_pk INTEGER NOT NULL, label_pk INTEGER NOT NULL,
  PRIMARY KEY(msg_pk, label_pk)) WITHOUT ROWID;
CREATE INDEX message_label_by_label ON message_label(label_pk, msg_pk);

-- A copy of intent.sqlite's undelivered assertions, keyed locally. Rebuilt at launch.
CREATE TABLE overlay(
  msg_pk INTEGER NOT NULL, label_pk INTEGER NOT NULL, want INTEGER NOT NULL,
  derived INTEGER NOT NULL DEFAULT 0,          -- 1: made by a rule, not by him (8.3)
  PRIMARY KEY(msg_pk, label_pk)) WITHOUT ROWID;

-- What a running enumeration has seen, so it can be compared with what is stored.
CREATE TABLE enum_mark(
  account_pk INTEGER NOT NULL, generation INTEGER NOT NULL,
  label_pk INTEGER NOT NULL,     -- 0 = the listing of every message
  msg_pk INTEGER NOT NULL,
  PRIMARY KEY(account_pk, generation, label_pk, msg_pk)) WITHOUT ROWID;

-- Messages whose state must be read back one by one before anything is removed (invariant 1).
CREATE TABLE verify_queue(
  msg_pk INTEGER PRIMARY KEY, reason INTEGER NOT NULL, generation INTEGER NOT NULL,
  queued_at INTEGER NOT NULL,
  outcome INTEGER);              -- NULL not read yet, 1 gone (5.3 step 5)

-- Deletions Gmail has stated that invariant 3 is holding back (5.7).
CREATE TABLE held_removal(
  msg_pk INTEGER PRIMARY KEY, evidence INTEGER NOT NULL,   -- 1 messagesDeleted, 2 a read's notFound
  found_at INTEGER NOT NULL, kept INTEGER NOT NULL DEFAULT 0);

-- Ids Gmail deleted in the last day; the writer will not store them (invariant 29).
CREATE TABLE tombstone(
  account_pk INTEGER NOT NULL, gmail_id TEXT NOT NULL, at INTEGER NOT NULL,
  PRIMARY KEY(account_pk, gmail_id)) WITHOUT ROWID;

CREATE TABLE view(
  view_pk INTEGER PRIMARY KEY,
  key     TEXT NOT NULL UNIQUE,   -- MailViewKey as JSON with sorted keys
  kind    INTEGER NOT NULL,       -- 0 label, 1 unified label, 2 all mail, 3 split, 4 special
  account_pk INTEGER, label_pk INTEGER,
  definition TEXT,                -- a split's query
  definition_rev INTEGER NOT NULL DEFAULT 0,
  built_rev INTEGER NOT NULL DEFAULT 0     -- < definition_rev: membership is being rebuilt
);
CREATE TABLE view_thread(
  view_pk INTEGER NOT NULL, sort_key INTEGER NOT NULL, tie INTEGER NOT NULL,
  thread_pk INTEGER NOT NULL, unread INTEGER NOT NULL,
  PRIMARY KEY(view_pk, sort_key, tie)) WITHOUT ROWID;
CREATE INDEX view_thread_unread    ON view_thread(view_pk) WHERE unread = 1;
CREATE INDEX view_thread_by_thread ON view_thread(thread_pk, view_pk);

CREATE TABLE correspondent(
  addr TEXT PRIMARY KEY, name TEXT,
  sent INTEGER NOT NULL DEFAULT 0, received INTEGER NOT NULL DEFAULT 0,
  last_date INTEGER NOT NULL DEFAULT 0) WITHOUT ROWID;
CREATE TABLE correspondent_key(      -- name words, the address, its domain; all lower-cased
  key TEXT NOT NULL, addr TEXT NOT NULL, PRIMARY KEY(key, addr)) WITHOUT ROWID;
```

History ids are kept as text. They are unsigned 64-bit; SQLite's integers are signed. They are
compared as `UInt64` in Swift and never subtracted (DOCUMENTED §1.3: they are not contiguous).

At 200,011 messages in 69,608 conversations with 313,767 view rows this file is 172.7 MB
(MEASURED, this schema, through GRDB): `message` 81.2 MB, `thread` 24.7 MB, `view_thread` and
its two indexes 23.6 MB.

### 4.4 Every list is a view

The one rule that makes lists fast: **a list is a view key; which conversations belong to it is
worked out when something changes, not when the list is read; every list reads the same
index.** The inbox, a label, a split, Snoozed, All Mail and the unified versions of each are
rows of `view_thread` under different `view_pk`s. There is no per-list SQL.

```swift
enum MailViewKey: Hashable, Codable, Sendable {
    case label(account: String, labelID: String)   // one account's Gmail label, system or user
    case unified(SystemLabel)                       // the same system label across every account
    case allMail(account: String?)                  // nil: every account
    case done(account: String?)                     // everything not in the inbox, Spam or Trash
    case split(id: String)                          // a saved query over the inbox (9.3)
    case snoozed, muted                             // section 8
}
```

How a `MailScope` (13.2) becomes a read:

| Scope | Read |
|---|---|
| `.mailbox(.inbox | .starred | .important | .sent | .spam | .trash)`, no account | `unified(label)` |
| the same, narrowed to an account | `label(account, label)` — each account's system labels have their own views |
| `.mailbox(.all)` / `.mailbox(.done)` | `allMail(account)` / `done(account)`, a real view per account and one for all |
| `.label(account, id)` | `label(account, id)` |
| `.split(id)`, `.mailbox(.snoozed | .muted)` | that view; narrowed to an account by a condition on `thread.account_pk` in the same scan (these views are inbox-sized) |
| filter `.unread` | the same view, `AND v.unread = 1` — served in order by the partial index |
| filters `.starred`, `.important`, `.noReply` | the same scan with a condition on `thread.flags` |
| `.mailbox(.drafts | .outbox)` | composed from `intent.sqlite` and the `DRAFT` view (13.7) |
| `.search(text)` | section 9 |
| `.heldRemoval(account)` | the conversations with a message in `held_removal` not yet answered, newest first — a join and a sort of at most the held rows, off the main thread; the one list read allowed a sort, because it is rare and bounded by the hold |

**A unified view is a real view**, with its own rows, not a merge at read time. MEASURED (first
spike): the unified inbox read as an `IN` list over four accounts' inbox views needs a sort —
0.67 ms for an inbox of 1,442 conversations, but 49 ms p50 and 100 ms p95 for All Mail. As its
own view it costs what any view costs. The price is one more row of about 30 bytes per
conversation per unified view it is in.

**The page query** — the only one a list runs:

```sql
SELECT t.thread_pk, t.account_pk, t.gmail_id, v.sort_key, v.tie, v.unread, t.message_count, t.flags,
       t.subject, t.snippet, t.people, t.people_total, t.labels,
       t.wake_at, t.returned_at, t.waiting_until, t.pending
FROM view_thread v JOIN thread t ON t.thread_pk = v.thread_pk
WHERE v.view_pk = ?1 AND v.sort_key > 0 AND (v.sort_key, v.tie) < (?2, ?3)
ORDER BY v.sort_key DESC, v.tie DESC
LIMIT ?4;
```

Plan (MEASURED): `SEARCH v USING PRIMARY KEY (view_pk=? AND sort_key>? AND
(sort_key,tie)<(?,?))`, then `SEARCH t USING INTEGER PRIMARY KEY (rowid=?)`. No sort, no scan.
The key is `(sort_key, tie)`, where `tie` is a hash of the conversation's id — nothing local to
this store — so a `MailOrderKey` means the same after a rebuild and on another device.

**Every place reads in descending key order.** Where the natural order is soonest first
(Snoozed), the stored `sort_key` is `MailOrderKey.far - wakeTimeMs` (`far` = 2^42), so the same
query serves it; the date a row shows comes from the thread row, not from the key.

**A list is its first `limit` rows**, not a window (13.3): the UI asks for 100, then 200, up to
`MailTuning.listCap` (2,000). One read of *n* rows replaces the first draft's sliding window,
its cursor type and its "show around" call (E-32). MEASURED, through `DatabasePool.read`, at
200,000 messages, on a machine with a load average near 600 — upper bounds:

| | p50 | p95 | p99 |
|---|---|---|---|
| First 50 rows, any view | 0.11 ms | 0.18 ms | 2.9 ms |
| Any page of 50 while walking all 69,040 conversations by keyset (1,381 pages, cold) | 0.85 ms | 3.6 ms | 10.5 ms |
| The newest 400 rows in one read | 0.37 ms | 0.70 ms | 1.8 ms |
| The newest 2,000 rows in one read | 1.8 ms | 7.0 ms | 11.1 ms |
| The first 50 rows while sync writes batches of 20 | 0.33 ms | 1.5 ms | 3.8 ms |

Five times the rows cost 4.8 times the time: the cap is a choice about the UI's list, not
about the store, and prototype P1 decides whether it can rise.

**Unread counts need no counter.** `SELECT count(*) FROM view_thread WHERE view_pk = ?1 AND
unread = 1` runs on the partial index (plan: `SEARCH … USING COVERING INDEX
view_thread_unread`). MEASURED: 0.35 ms p50 for 10,323 unread; all twelve counts a sidebar
shows, 0.41 ms p50, 1.3 ms p95. A maintained counter was rejected: a counter can drift from
the rows it counts, and a count over an index cannot.

**Totals are bounded.** A list's `total` counts the view's dated rows, and that is a scan of
the view: 2.5 ms p50, 11.4 ms p95 for All Mail's 69,040 (MEASURED). So it is counted with
`LIMIT 10001`, at most once a second per list and only after a commit that touched the view;
past ten thousand it is `MailCount(value: 10_000, isAtLeast: true)`.

**Rows for conversations not fetched yet.** A conversation known only from a listing has no
date to sort by. It gets a membership row with a negative `sort_key` (`-msg_pk` of its newest
stub). The page query's `sort_key > 0` leaves it out; the unread count includes it, because a
listing of `INBOX` and `UNREAD` together says it is unread; and `count(*) … AND sort_key < 0`
is `MailListSnapshot.stillLoading`. Counts are therefore exact seconds after the label
listings finish, long before bodies arrive.

### 4.5 What a conversation's row says: the two summary rules

Both are pure, in their own files, and run inside the writer's transaction for every
conversation a batch touched. `MessageFacts` and the other types they use are in appendix A.

```swift
enum ThreadSummaryRules {
    static func summarise(_ messages: [MessageFacts], myAddresses: Set<String>) -> ThreadSummary
}
enum ViewMembershipRules {
    static func memberships(_ messages: [MessageFacts], account: String,
                            splits: [MailSplit], matches: (MailSplit, [MessageFacts]) -> Bool,
                            myAddresses: Set<String>) -> [ViewMembership]   // (MailViewKey, sortKey, unread)
}
```

`ThreadSummaryRules`:

1. *Visible* messages are confirmed messages without `TRASH` or `SPAM`, with `vis` 0
   or 4 (the latter remains readable under 5.7). If none qualifies, the confirmed
   messages form the summary (the conversation lives only in Trash or Spam).
   `vis = 3` (rebuilt, unconfirmed) is excluded even from this fallback.
2. `lastDate` is the newest `internalDate` among visible fetched messages; `messageCount`
   counts visible messages, stubs included; `unreadCount` counts visible messages with
   `UNREAD`.
3. `subject` is the earliest visible fetched message's; `snippet` the latest's.
4. `people` lists up to six authors of fetched visible messages in order of first
   appearance, his own addresses shown once as "me", each marked unread if any of
   their visible messages is; `peopleTotal` counts all. Explicit `SummaryPerson.isMe`
   distinguishes an own alias from another person named "me". `recipients` and
   `recipientsTotal` retain the corresponding deduplicated To/Cc summary for Sent,
   Drafts and Outbox; stubs invent neither senders nor dates.
5. Flags: starred, important, has attachment, has invite, has draft, last message is mine, is
   a list, muted, kept after removal.
6. `labels` is the union of visible messages' labels.
7. `wakeAt`, `returnedAt`, `waitingUntil` come from `BananaLabelRules.state` (section 8).
8. `pending` is 2 if any message has a refused intent, 1 if any has an undelivered one,
   else 0, including messages excluded from the display summary. Retention claims
   likewise inspect the whole conversation. The writer additionally merges durable
   local draft/send/question claims and preserves `attended_at`; resummarising must
   never clear attention merely because it is not derivable from message facts.

`ViewMembershipRules` — a conversation belongs to:

- `label(account, L)` and, for a system label, `unified(L)`: when a visible message has `L`
  (for `TRASH` and `SPAM`: when any message has it). Sort key: the newest date among the
  messages that have `L`. This is Gmail's own ordering — a new reply lifts a conversation in
  the inbox; the other side replying does not lift it in Sent.
- `allMail(account)` and `allMail(nil)`: when it has a visible message. Sort key: `lastDate`.
- `split(id)`: the first split, in matching order, whose query it satisfies (9.3). Sort key:
  as the inbox's.
- `done(account)` and `done(nil)`: when it has a visible message and none has `INBOX`.
- `snoozed`, `muted`: per section 8. Snoozed holds conversations with a snooze or an
  if-no-reply label and no `Returned`; its sort key is the reversed wake time.
- In the inbox and split views, a conversation back from a snooze sorts by
  `max(newest inbox date, returnedAt)`.
- `unread` is true when any visible message has `UNREAD`.
- With no fetched message to date it, the sort key is negative (4.4).

When either rule's output for a conversation differs from what is stored, the writer rewrites
the `thread` row and replaces its `view_thread` rows (found through `view_thread_by_thread`).
The overlay is already in the facts, so **the list never joins pending state**.

### 4.6 `search.sqlite`

```sql
CREATE VIRTUAL TABLE msg_fts USING fts5(
  subject, sender, recipients, body, attachments,
  content='', contentless_delete=1,
  tokenize='unicode61 remove_diacritics 2',
  prefix='2 3',
  detail=full
);
CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
```

- **Contentless, with delete.** The text lives in `blobs.sqlite`; storing it again here would
  double it. `contentless_delete=1` needs SQLite 3.43 (this Mac has 3.51.0; ASSUMED for iOS
  26.1 — P02's first test asserts it on the Simulator).
- **What is indexed:** the subject; the sender's name and address; recipients' addresses; the
  message's *own* text — `PreparedBody.ownText`, quotes stripped, at most 16,000 characters —
  and attachment file names. A header-only message indexes its snippet as the body until the
  body is prepared. Quoted text is another message's text: indexing it makes every reply a hit
  for the original and multiplies the index.
- **The row id is the date, and it is stored with the content.**
  `MailRowID.make(internalDateMs:account:gmailID:)` is `(internalDateMs << 20) | (FNV-1a of
  "account|gmailID" & 0xFFFFF)`; on the rare collision the low bits are bumped. Because a
  bump depends on what was inserted first, the assigned id is written into `content.fts_rowid`
  when the content is stored, and a rebuilt index copies it from there — it is never computed
  twice (E-36). FTS5 returns matches in row-id order without sorting, so "newest first, stop
  after 50 conversations" is a short streaming scan whatever the number of hits. Plan
  (MEASURED): `SCAN f VIRTUAL TABLE INDEX …` then `SEARCH m USING INDEX message_by_fts`.
- **`unicode61 remove_diacritics 2`**, no stemming: his mail is not all in one language. An
  address is several tokens; searching a whole address is a phrase, which is why
  `detail=full`. Known limit: unicode61 does not segment Chinese or Japanese.
- **`prefix='2 3'`** makes the word being typed match from its second letter.

What search costs — MEASURED at 200,000 messages through the read-only connection, newest 50
conversations, **forty different words at each length, three times each**, on a machine with a
load average over 600:

| Query | p50 | p95 | p99 |
|---|---|---|---|
| 2 letters | 0.35 ms | 29.8 ms | 40.8 ms |
| 3 letters | 0.46 ms | 46.3 ms | 78.3 ms |
| 4 letters (no prefix index for it) | 4.3 ms | 51.5 ms | 93.0 ms |
| 5 letters | 0.88 ms | 5.8 ms | 7.0 ms |
| 6 letters | 0.36 ms | 3.6 ms | 4.1 ms |
| A very common whole word | 0.25 ms | 0.57 ms | 2.7 ms |
| A middling whole word | 0.14 ms | 2.6 ms | 16.0 ms |
| Two common words | 0.35 ms | 1.6 ms | 3.7 ms |
| A phrase | 0.38 ms | 3.8 ms | 5.4 ms |
| A finished word, then two letters | 0.28 ms | 1.5 ms | 4.3 ms |
| The common word ordered by relevance (`ORDER BY rank`) | 764 ms | 1,426 ms | — |

The first spike timed one word over and over and reported 0.2 ms for two and three letters and
18 ms p95 for four. Across forty words the medians hold, and the tails are the first time each
prefix is touched: tens of milliseconds, on a busy machine, from a 1.1 GB file through an 8 MB
cache. So:

- results are always newest first and relevance is not offered — three thousand times the cost;
- the budget for search as you type is stated as a median here and a p95 **to be measured on
  the phone** (owner run 1); it is not claimed met;
- the four-letter case is the worst median, as the performance review predicted (R-5). The
  cure is `prefix='2 3 4'`, MEASURED at 30,000 messages: four letters 0.58 ms → 0.12 ms p50,
  3.9 ms → 0.36 ms p95, and the file 133 % → 187 % of the indexed text. **It is not adopted
  yet**: 40 % more search index on a phone is a real cost, the Mac's median is inside the
  budget, and it is a local rebuild whenever the phone's number says otherwise.

**Size.** With this configuration the synthetic store's index is 1,118 MB for 763 MB of text
(146 %, before `optimize`) — but that text averages 3.8 KB a message and has no quotes to
strip. ASSUMED for real mail: 1.5–2.5 KB a message, so 0.4–0.75 GB at 200,000. The first Mac
fill measures the real figure (owner run 3).

**Indexing is a queue, not part of sync.** A message is marked `fts_dirty` when its header is
stored and again when its body is prepared. `MailSearchIndexer` takes dirty rows newest first,
50 at a time, at the pace of 4.12, writes one `search.sqlite` transaction (MEASURED: 41 ms p50,
118 ms p95 for 50), then asks the writer to clear the flags. A crash between the two leaves
rows dirty and they are indexed again; `INSERT OR REPLACE` makes that harmless. Deleting
entries is queued the same way (88 ms p50 for 50). Search can therefore trail the list during
a first sync; the lag is a number and is shown with results (`MailCoverage`).

### 4.7 `blobs.sqlite`

```sql
CREATE TABLE content(
  account TEXT NOT NULL, gmail_id TEXT NOT NULL,
  thread_id TEXT NOT NULL, internal_date INTEGER NOT NULL,
  size_estimate INTEGER, snippet TEXT,
  fts_rowid INTEGER NOT NULL,  -- assigned once (4.6)
  headers   BLOB NOT NULL,     -- zlib: JSON [[name, value], …], every header, in order
  structure BLOB NOT NULL,     -- zlib: JSON MIME tree without data (MIMEStructure)
  html      BLOB,              -- zlib: the HTML part as received, decoded to UTF-8; NULL if none
  plain     BLOB,              -- zlib: the text/plain part as received; NULL if none
  level     INTEGER NOT NULL,  -- 1 header only, 2 with bodies
  bytes     INTEGER NOT NULL,  -- stored size, for eviction accounting
  stored_at INTEGER NOT NULL, opened_at INTEGER,
  PRIMARY KEY(account, gmail_id)) WITHOUT ROWID;

CREATE TABLE prepared(         -- section 10: made once, when the body arrives
  account TEXT NOT NULL, gmail_id TEXT NOT NULL, prep_version INTEGER NOT NULL,
  body  BLOB NOT NULL,         -- zlib: PreparedBody as JSON (fragment, native text, pictures, …)
  text  BLOB NOT NULL,         -- zlib: PreparedBody.ownText, for the indexer and excerpts
  bytes INTEGER NOT NULL, made_at INTEGER NOT NULL,
  PRIMARY KEY(account, gmail_id)) WITHOUT ROWID;

CREATE TABLE attachment(
  account TEXT NOT NULL, gmail_id TEXT NOT NULL, part_id TEXT NOT NULL,
  filename TEXT, declared_mime TEXT, sniffed_mime TEXT, size INTEGER,
  content_id TEXT, inline INTEGER NOT NULL DEFAULT 0,
  attachment_id TEXT,          -- Gmail's; may change between reads — never a key
  state INTEGER NOT NULL DEFAULT 0,   -- 0 not downloaded, 1 downloaded
  path TEXT, bytes INTEGER, used_at INTEGER, keep INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(account, gmail_id, part_id)) WITHOUT ROWID;

CREATE TABLE remote_image(
  url_hash TEXT PRIMARY KEY, bytes INTEGER NOT NULL, mime TEXT, fetched_at INTEGER NOT NULL,
  used_at INTEGER NOT NULL) WITHOUT ROWID;
CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
```

A message's id never changes (DOCUMENTED §2.2). That its content never changes under that id
is ASSUMED — a draft's does, and each draft revision has a new id — and the probe checks it;
if content can change, a `full` re-read simply replaces the row. This file holds what Gmail
sent, unsanitised, and what preparation made of it. Keeping the first is what lets a new
sanitiser be applied to mail already on the device without fetching it again; keeping the
second for **every** body within the ceiling — not a recent few hundred — is what makes
opening a read. Compression is Foundation's (`NSData.compressed(using: .zlib)`); a 261 KB
document inflates in 0.05 ms (MEASURED, first spike). Size per message is ASSUMED at 8–20 KB
for the content and about as much again for the prepared form; the first fill measures both.

When a message is deleted, its `content`, `prepared` and `attachment` rows are deleted too,
after the index row (S-34): a blob never outlives the knowledge that its message is gone.

### 4.8 `intent.sqlite`

Keyed by account address and Gmail ids throughout, so it means the same thing after the cache
has been rebuilt. `MailIntentStore` is the only code that opens it, keeps its `DatabaseQueue`
private, and has no operation that removes the file, a table, or rows by anything but their
key (invariant 5): delivered assertions are deleted by key; `send_log` rows by id older than 90
days; nothing else is ever removed.

```sql
CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
-- 'device_id' (a UUID made once), 'next_seq', 'journal_salt'

-- One desired end state per (message, label). Section 6.
CREATE TABLE label_intent(
  account TEXT NOT NULL, gmail_msg_id TEXT NOT NULL,
  label_ref TEXT NOT NULL,          -- a Gmail label id, or 'name:<label name>' until it exists
  want INTEGER NOT NULL,            -- 1 present, 0 absent
  seq INTEGER NOT NULL,             -- order of asking, device-wide; rises when the row is replaced
  sent_seq INTEGER,                 -- seq when the request carrying it left (invariant 25)
  group_seq INTEGER NOT NULL,       -- the receipt's sequence (13.2)
  origin INTEGER NOT NULL DEFAULT 0,-- 0 him, 1 a rule (8.3)
  state INTEGER NOT NULL DEFAULT 0, -- 0 pending, 1 in flight, 2 settling, 3 refused
  attempts INTEGER NOT NULL DEFAULT 0,
  next_attempt_at INTEGER, failure TEXT,   -- MailFailure
  created_at INTEGER NOT NULL, delivered_at INTEGER,
  PRIMARY KEY(account, gmail_msg_id, label_ref)) WITHOUT ROWID;
CREATE INDEX label_intent_by_state ON label_intent(state, account, seq);

-- A message being written or waiting to go. Section 7.
CREATE TABLE draft(
  local_id TEXT PRIMARY KEY,
  account TEXT NOT NULL, from_alias TEXT,
  kind TEXT NOT NULL,               -- new, reply, replyAll, forward
  to_json TEXT NOT NULL, cc_json TEXT NOT NULL, bcc_json TEXT NOT NULL,
  subject TEXT NOT NULL,
  body_json TEXT NOT NULL,          -- MailText
  signature_html TEXT, quote_html TEXT,   -- fragments, already sanitised
  format TEXT NOT NULL DEFAULT 'banana',  -- or 'foreign' (7.1)
  -- identity: made once, never changed (invariant 28)
  rfc_message_id TEXT NOT NULL,
  mime_date INTEGER NOT NULL,
  source_msg_id TEXT, thread_id TEXT, in_reply_to TEXT, references_hdr TEXT,
  -- Gmail's copy
  content_rev INTEGER NOT NULL DEFAULT 0,
  upload_started INTEGER NOT NULL DEFAULT 0,   -- a createDraft may have reached Gmail (7.3)
  gmail_draft_id TEXT, uploaded_rev INTEGER, uploaded_hash TEXT, uploaded_msg_id TEXT,
  gone_once INTEGER NOT NULL DEFAULT 0,        -- its Gmail draft has answered notFound before
  -- sending
  state TEXT NOT NULL,              -- SendRules.State, encoded
  hold_until INTEGER, send_at INTEGER, owner_device TEXT, then_done INTEGER NOT NULL DEFAULT 0,
  remind_at INTEGER,
  attempts INTEGER NOT NULL DEFAULT 0, next_attempt_at INTEGER,
  sending_since INTEGER, checks INTEGER NOT NULL DEFAULT 0, sent_msg_id TEXT, failure TEXT,
  discarded_at INTEGER,             -- discard is undoable; the row goes a day later
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
CREATE TABLE draft_attachment(
  local_id TEXT NOT NULL, att_id TEXT NOT NULL,
  filename TEXT NOT NULL, mime TEXT NOT NULL, size INTEGER NOT NULL,
  content_id TEXT, source TEXT,     -- NULL: a file in Intent/Attachments; else 'forward:<msg>:<part>'
  PRIMARY KEY(local_id, att_id)) WITHOUT ROWID;

-- Every send attempt and how it ended; kept 90 days. Evidence when something looks wrong.
CREATE TABLE send_log(
  id INTEGER PRIMARY KEY AUTOINCREMENT, local_id TEXT NOT NULL, gmail_draft_id TEXT,
  at INTEGER NOT NULL, step TEXT NOT NULL, outcome TEXT NOT NULL);

-- What this device has already notified about, so a rebuilt cache does not notify again.
CREATE TABLE notify_mark(account TEXT PRIMARY KEY, baseline_at INTEGER NOT NULL, notified_through INTEGER NOT NULL);

-- Questions he has not answered yet (13.2), so they survive a relaunch.
CREATE TABLE question(id TEXT PRIMARY KEY, kind TEXT NOT NULL, payload TEXT NOT NULL, asked_at INTEGER NOT NULL);
```

```sql
-- One row per change of his that still has an undelivered or refused assertion: what he asked,
-- so a refused one can be named after a relaunch (MailRefusedChange, 13.2). Deleted by key
-- when its last assertion is delivered or discarded.
CREATE TABLE change_group(
  group_seq INTEGER PRIMARY KEY, account TEXT NOT NULL,
  change TEXT NOT NULL,             -- MailChange, as JSON
  conversations INTEGER NOT NULL, created_at INTEGER NOT NULL);
```

What an action changed, for undo — each key's state beforehand — is kept in memory, not here
(6.7).

### 4.9 Versions, migration, rebuild

Two numbers per cache file, because there are two kinds of change:

- **The schema**: `DatabaseMigrator` migrations, additive only (`ADD COLUMN`, new table, new
  index). A cache file whose migrations are newer than the code knows is not opened: it is
  rebuilt.
- **`derived_version`** (in `meta`): the code that computed derived rows — the two summary
  rules, the row-id scheme, the FTS configuration. Raising it for `index.sqlite` re-runs the
  summary rules over every conversation; raising it for `search.sqlite` re-indexes from
  `prepared.text`. Both are local, both are **paced** (4.12), and old rows keep serving reads
  meanwhile. `MailHTMLPreparer.version` re-prepares lazily (10.2).

`intent.sqlite` has migrations only, and they may only add. A column is never dropped or
repurposed. If its schema is newer than the code, the engine does not open it and reports
`store = .unavailable(.newerVersion)`; mail is read-only until the app is updated. It is never
reset.

**Rebuilding `index.sqlite` from nothing** (deleted, corrupt, or an unreadable schema): create
it empty; insert a `message` and `thread` row for every row of `blobs.sqlite` — ids, dates,
headers, `fts_rowid`, **`vis = 3` and no labels** — and set each account's `checkpoint` to
`NULL`; run reconcile (5.3), which lists labels for about 4,000 units per 100,000 messages
instead of the 2,000,000 a re-download would cost; rebuild the overlay from intent. A rebuilt
row is in no view until a listing or a read confirms it exists (then `vis` becomes 0);
`labelsKnown` is set only when a read describes it (6.1); and it is removed only on the
positive evidence of 5.7 — so a rebuild
can neither resurrect deleted mail into a list nor lose mail that still exists. Pending
intents for its messages are not moot while its labels are unknown (invariant 22). Search
keeps working throughout: its row ids come from the content.

### 4.10 Corruption, and a disk that is full

Detected three ways: opening fails (`SQLITE_NOTADB`, `SQLITE_CORRUPT`); a statement returns
`SQLITE_CORRUPT` at run time; or `PRAGMA quick_check` fails. `quick_check` runs after a launch
that follows an unclean exit (`meta.unclean`), and otherwise at most once a day — on a Mac
when idle, on a phone only in the overnight task. MEASURED: 0.69 s for `index.sqlite` at
200,000 messages on the loaded machine (0.38 s when quieter). `search.sqlite` is checked with
FTS5's `integrity-check` only overnight (8–20 s, MEASURED).

| File | On corruption |
|---|---|
| `index.sqlite` | Close it; rename the file and its `-wal`/`-shm` to `index.corrupt-<stamp>` (one kept); rebuild as in 4.9. Mail shows what it can and fills back in. |
| `search.sqlite` | Delete and re-index from prepared text. Search says so, with a count. |
| `blobs.sqlite` | Rename aside; every message drops to `fetch_state = 1` or `0` according to what the index still has; bodies are fetched again by the normal queue, newest first. |
| `intent.sqlite` | Never deleted or renamed. Copy it (and `-wal`) to `intent.corrupt-<stamp>.sqlite`; salvage row by row into a fresh file at a new name (opened with the same full-fsync settings, 4.2); if anything was salvaged, swap by rename and raise the question `changesLost(recovered:)`. If the copy cannot be made, refuse all writes — the rule `WellnessStore`'s `mustRefuseSaves` follows — and report `store = .unavailable(.damaged)`. |

**A full disk** is not corruption and is handled where it bites: a cache write that fails with
`SQLITE_FULL` stops the fill and reports `heldBy = .diskNearlyFull`; an intent commit that
fails is 6.2's "not saved". The floor of 11.3 is what keeps either from being ordinary.

### 4.11 The first frame

When Mail is the tab being restored, the first frame must have rows without the main thread
opening a database: opening a WAL database can mean replaying its log, and that cost is not
bounded. So the list feed writes `Cache/first-page.json` — the scope, its first 50 rows, the
counts and a time — two seconds after the first page last changed and on backgrounding, off
the main thread, atomically. At launch `MailFirstPaint.load()` reads it synchronously **only
if** `ShellNavigation`'s restored tab is Mail and the restored scope is the one in the file;
any other launch does not touch it. MEASURED: 50 rows of this schema are 24.9 KB; read and
decode take 0.27 ms p50, 0.45 ms p95. Opening the four stores, by contrast, took 16 ms p50 and
39 ms p95 on the loaded machine, which is the case that cannot be relied on.

The snapshot is for drawing only. It is written from the index, so every change in it is
already in `intent.sqlite` (6.2) and is still true after a relaunch. The first real page
replaces it; rows are `Equatable`, so if nothing changed nothing redraws.

### 4.12 Writes, measured, and how local work is paced

At 200,000 messages, through GRDB, on the design's schema (MEASURED; load average 600–830, so
these are upper bounds — 21):

| | p50 | p95 | p99 | max |
|---|---|---|---|---|
| Intent commit of one change (1–60 assertions), full fsync | 0.84 ms | 2.1 ms | 3.8 ms | 6.6 ms |
| Index write-through: overlay rows, thread row, five view rows | 0.21 ms | 0.78 ms | 2.4 ms | 21.8 ms |
| Both — accepted to durable and in the index | 1.1 ms | 2.8 ms | 5.2 ms | 22.6 ms |
| Sync transaction of 20 messages, a list reader running | 1.6 ms | 6.2 ms | 18.4 ms | 44 ms |
| Sync transaction of 50 messages, a list reader running (rejected) | 5.1 ms | 23.7 ms | 41.7 ms | 93 ms |
| Delete 50 messages from the index | 4.6 ms | 12.1 ms | — | 12.1 ms |
| Delete their 50 entries from `search.sqlite` (its own queue) | 88 ms | 375 ms | — | 375 ms |
| Open the four stores, rebuild 30 overlay rows, read the first page | 45 ms | 73 ms | — | 73 ms |

The full-fsync commit has now been measured at 3.0 ms p50 (first spike, raw API) and at 0.4
and 0.8 ms (this one, through GRDB): the same disk, different days. A phone's is ASSUMED at
5–40 ms and is the first number the owner's device run settles (R-4); the take-what-arrived
group commit is what makes the design indifferent to it within that range.

A reader holding one transaction through five seconds of ingest grew the log to 486 MB (first
spike) — invariant 11.

**The pace (invariant 31).** Preparation, indexing, derived-version rebuilds, the index
rebuild's local half and split rebuilds are CPU-bound, can run for hours, and were unbounded
in the first design; the app's own watchdog would have reported them as a runaway (R-3).

```swift
enum MailWorkPace: Equatable, Sendable {
    case full                      // no pauses
    case paced(share: Double)      // work, then sleep so that work is `share` of elapsed time
    case stopped
    static func current(role: MailDeviceRole, power: MailPower, insideOvernightTask: Bool,
                        mailVisible: Bool, appActive: Bool) -> MailWorkPace
}
```

**The first row that applies decides**, top to bottom:

| | Situation | Pace |
|---|---|---|
| 1 | Thermal state fair or worse, or Low Power Mode — on any device, **inside the overnight task too** | `stopped` |
| 2 | Inside the overnight task; a Mac on mains | `full` |
| 3 | A Mac on battery; an iPhone or iPad with Banana active and Mail on screen | `paced(0.2)` — a fifth of one core |
| 4 | An iPhone or iPad otherwise: Mail not on screen, or the app not active | `stopped` |

Row 1 is first because invariant 31 says "not at all when the device is warm or in Low Power
Mode" and makes no exception: a phone that warms while it charges stops its overnight work
until it has cooled, which is what a battery on a charger wants. Row 2 is ahead of row 4
because the overnight task is the one time an iPhone or iPad works with the app in the
background. (An earlier form of this table listed the overnight task first, and 12.1's listed
it after the warm row; P02 followed the invariant, and both tables now say so.) A `stopped`
pace inside the overnight task is not slept through: the task finishes the item in hand,
completes, and schedules its next run (12.2).

A paced pass works in pieces of at most 50 ms and then sleeps four times as long as the piece
took, on the clock. Something he is waiting for — the message he just opened — is never
paced. At a fifth of a core, preparation handles about 0.8 MB of HTML a second on this Mac
(3.9 MB/s, MEASURED, times 0.2): roughly fifteen messages a second at an ASSUMED 50 KB each,
against the four a second the fill can fetch.

`MailKnobs` holds every number above and these, in one file: sync batch 20; group commit at
most 50 changes; checkpoint over 8 MiB; background read 500 rows; indexer batch 50; delivery
debounce 1.5 s and 5 s; poll 60 s; verify batch 50; `maxInFlight` 4. **The fifty is kept by
the pieces of work, not by the writer**: the writer only asks a piece whether it will absorb
the next (`MailWriterWork.absorb`), and the piece that carries changes — `MailActionWriter`,
P14b — answers no once it holds fifty.

## 5. Sync

### 5.1 The transport

Three layers, each with one job.

**`GmailAPI` — one HTTP request per method.** The real implementation speaks HTTPS (P22a); the
fake is an in-memory Gmail (P10). The token is the only thing that says whose mailbox a request
is for — every path is `users/me`, as on the wire — which is what makes invariant 2 testable.

```swift
protocol GmailAPI: Sendable {
    func profile(token: String) async throws -> GmailProfile           // emailAddress, historyId, messagesTotal
    func labels(token: String) async throws -> [GmailLabel]
    func label(token: String, id: String) async throws -> GmailLabel    // with messagesTotal, threadsTotal, threadsUnread
    func createLabel(token: String, name: String, hidden: Bool) async throws -> GmailLabel
    func deleteLabel(token: String, id: String) async throws
    func listMessages(token: String, labelIDs: [String], query: String?, includeSpamTrash: Bool,
                      pageToken: String?, maxResults: Int) async throws -> GmailIDPage    // [(id, threadId)], nextPageToken
    func history(token: String, start: String, pageToken: String?, maxResults: Int) async throws -> GmailHistoryPage
    func message(token: String, id: String, format: GmailFormat) async throws -> GmailMessage
    func thread(token: String, id: String, format: GmailFormat) async throws -> GmailThread
    func modify(token: String, id: String, add: [String], remove: [String]) async throws
    func batchModify(token: String, ids: [String], add: [String], remove: [String]) async throws   // at most 1,000 ids
    func trash(token: String, id: String) async throws
    func untrash(token: String, id: String) async throws
    func attachment(token: String, messageID: String, attachmentID: String, to file: URL) async throws -> Int
    func drafts(token: String, pageToken: String?) async throws -> GmailDraftPage        // [(draftId, messageId, threadId)]
    func draft(token: String, id: String, format: GmailFormat) async throws -> GmailDraft
    func createDraft(token: String, mime: MIMESource, threadID: String?) async throws -> GmailDraft
    func updateDraft(token: String, id: String, mime: MIMESource, threadID: String?) async throws -> GmailDraft
    func deleteDraft(token: String, id: String) async throws
    func sendDraft(token: String, id: String) async throws -> GmailMessage
    func sendAs(token: String) async throws -> [GmailSendAs]
    /// The `Date` header of the most recent response — Google's clock, for the timed rules (8.3).
    func lastServerDate() async -> Date?
}
// enum GmailFormat { case minimal, header, full } is declared in GmailWire.swift (P03a);
// `header` is Gmail's `metadata` with the headers of 5.6.

enum GmailError: Error, Equatable, Sendable {
    case neverLeft                         // no connection was made; the request cannot have arrived
    case unknownOutcome                    // sent, or possibly sent, and no answer: timeout, connection lost
    case unauthorized                      // 401
    case scopeMissing                      // 403 insufficientPermissions / ACCESS_TOKEN_SCOPE_INSUFFICIENT
    case apiDisabled                       // 403 accessNotConfigured
    case domainPolicy                      // 403 domainPolicy
    case limited(GmailLimit, retryAfter: TimeInterval?)
    case notFound                          // 404 whose JSON body parsed and whose reason is notFound
    case conflict                          // 409: a label of that name exists
    case refused(GmailReason)              // any other 4xx with a parsed body
    case server(Int)                       // 5xx — the request may have been carried out
    case unexplained(Int)                  // a status with no parsable Google error body, 404 included
    case malformed                         // 2xx whose body did not decode
    case networkDisabled                   // invariant 33
}
enum GmailLimit: Sendable { case user, project, concurrent, bandwidth, sending }
/// Google's machine-readable reason, from a closed list. Never Google's message text (invariant 21).
enum GmailReason: String, Sendable { case invalidArgument, failedPrecondition, tooLarge, invalidTo, labelLimit, other }
```

`notFound` is produced by exactly one shape: status 404, a JSON body that decodes as Google's
error object, and `reason == "notFound"` (or `status == "NOT_FOUND"`). A 404 from a proxy, a
captive portal or a truncated body is `unexplained(404)` and is evidence of nothing
(invariant 1). `neverLeft` is produced only for `URLError` codes that mean no connection existed:
`notConnectedToInternet`, `cannotFindHost`, `cannotConnectToHost`, `dnsLookupFailed`,
`secureConnectionFailed`, `dataNotAllowed`, `internationalRoamingOff`. Every other transport
failure — `timedOut` and `networkConnectionLost` above all — is `unknownOutcome`.

The HTTP implementation (`MailApp/GmailHTTP.swift`) uses one `URLSession`: ephemeral
configuration, `.reloadIgnoringLocalCacheData`, no cookies, no credential storage,
`httpMaximumConnectionsPerHost = 4`, `tlsMinimumSupportedProtocolVersion = .TLSv12`, a
`User-Agent` containing `gzip` (DOCUMENTED §2.3). Its delegate refuses every redirect: Google's
API does not redirect, and a redirect would carry the bearer token elsewhere. Every URL is built
from the constant `https://gmail.googleapis.com/` — App Transport Security is off for this app
(`NSAllowsArbitraryLoads`, for podcasts), so https is enforced here, by a test that every request
the transport builds has that scheme and host. There is **no batch codec**: `multipart/mixed`
batching saves no quota (DOCUMENTED §8: a batch of *n* costs *n*) and would need a parser of our
own; HTTP/2 multiplexes the same requests over one connection. Drafts are uploaded in one
request (`uploadType=multipart`: a JSON part carrying `threadId`, then `message/rfc822`) up to
Gmail's 36 MB limit; resumable upload is not built for the first release.

**`MailTransportGate` — the one door (invariant 33).** A value the HTTP implementation consults
before every request: `MailNetworkPolicy.allowed` is false when the launch arguments contain
`--disable-mail-network`, when `VisualAuditRoute.matches()`, or when Mail's fixture source is
active; then every method throws `networkDisabled` before a socket is opened. The remote-picture
fetcher and the unsubscribe poster go through the same gate. One test launches with the flag and
asserts zero requests.

**`GmailSession` — everything above the wire** (pure folder; wraps any `GmailAPI`):

```swift
final class GmailSession: Sendable {
    init(api: GmailAPI, tokens: MailTokenSource, governor: MailQuotaGoverning, clock: MailClock, journal: MailJournal)
    /// One call. Verifies the token's account, takes units from the lane, maps a 401 to one retry.
    func call<T: Sendable>(_ account: String, _ lane: QuotaLane, _ cost: GmailCost,
                           _ body: @Sendable (GmailAPI, String) async throws -> T) async throws -> T
    /// Many reads, at most `maxInFlight` at once, one result per id in the order asked.
    func messages(_ account: String, ids: [String], format: GmailFormat, lane: QuotaLane) async -> [GmailResult<GmailMessage>]
    func threads(_ account: String, ids: [String], format: GmailFormat, lane: QuotaLane) async -> [GmailResult<GmailThread>]
}
enum GmailResult<Value: Sendable>: Sendable { case ok(Value), failed(GmailError) }
protocol MailTokenSource: Sendable {
    func token(for account: String) async throws -> MailAccessToken     // MailAccessError is mapped to GmailError below
    func drop(account: String) async
}
```

In the engine the token source is `MailAccessTokens` (`M/`, P23a), a value over
`MailAccountAccess`: `token(for:)` is `mailAccessToken(accountID:)` and `drop(account:)` is
`dropMailAccessToken(accountID:)`, both on the main actor. **It is not the token flight**,
though the flight has two methods of the same names (3.3): a session handed the flight itself
would go round the ledger, which is what refuses an account that needs access and what keeps
a drop ahead of the retry that follows it. P10a's tests use a fake token source.

`call`, in order:

1. `tokens.token(for:)`. `MailAccessError.notGranted`, `.rejected` and `.unknownAccount` become
   `GmailError.scopeMissing` for that account (its state is then decided by 3.4);
   `.transport` becomes `neverLeft`; `.notConfigured` becomes `apiDisabled`.
   `CancellationError` is passed on as it is. Then `Task.checkCancellation()`: a token source
   may hand a token to a caller that was cancelled while it waited (3.3, rule 1 — the ledger
   does not, a fake may), and a cancelled call must make no request.
2. **Invariant 2.** If this token string is not in the session's verified set: `api.profile`.
   If `emailAddress.lowercased() != account`, the account is stopped
   (`MailSyncHealth.wrongAccount`), the token is not used again, and the call throws. Otherwise
   the string is remembered for the life of the process.
3. `governor.take(cost, lane)` — suspends until the lane may spend (5.2).
4. The request. On `unauthorized`: `tokens.drop`, then steps 1–4 once more; a second 401 is
   thrown. On `limited`: the governor is told, then the error is thrown to the caller.

`messages` and `threads` start one task per id, at most `maxInFlight` (4) running, and await each
task's `.value` (invariant 20). Partial failure is normal: each id has its own result.

### 5.2 The quota governor

DOCUMENTED (§0, §9): 6,000 units per user per minute for projects created since 1 May 2026;
`messages.get` 20 units, `threads.get` 40, `history.list` 2, `messages.list` 5,
`messages.batchModify` 50, `drafts.send` 100; download bandwidth limited like IMAP's, 2,500 MB a
day for a Workspace user, shared by all of that user's clients; concurrent requests limited at a
number Google does not publish. The per-user budget is per Cloud project, so every production
Banana device of his draws on the same 6,000. UNVERIFIED: whether the production project is on
these numbers or grandfathered on the old ones; how finely the minute is enforced; the consumer
bandwidth figure; **and the shape of every limit error** — which is why the governor acts on
only two facts about one: that it happened, and Google's retry time if it gave one.

One governor per account, per process (`MailQuotaGovernor`; arithmetic in `QuotaRules`).

- **A bucket of units.** Capacity 1,000 (ten seconds of budget), refilled at `rate` units a
  second. `rate` starts at 80: four-fifths of 6,000 a minute.
- **Three lanes; a lane may spend only while the bucket would stay at or above its floor.**

  | Lane | Floor | What uses it |
  |---|---|---|
  | interactive | 0 | Opening a conversation whose body is not here; asking Gmail to search; a send; an attachment he tapped; the first screenful of a first sync |
  | incremental | 200 | The history poll; fetching new mail; delivering the outbox; checks before a removal |
  | backfill | 500 | Enumeration; filling in headers and bodies; attachment prefetch |

  So the fill can never take the bucket below half, and something he is waiting for finds at
  least 500 units — 25 reads — there at once.
- **On any limit error:** the lanes below interactive pause for Google's retry time, or for
  `min(2^n + random(0…1 s), 64 s)` when it gave none, and `rate` halves (never below 5). After
  each minute without one, `rate` rises by 5, up to 80. Two or three devices on one account
  converge on a split of the one budget without talking to each other.
- **A `bandwidth` limit** closes the backfill lane until Google's retry time, or for an hour.
- **One daily number for bytes, per device.** The governor adds up the response bytes of
  backfill calls per account since local midnight (`quota_state`: `{day, bytes}`). Devices do
  not know of each other, so each has its own share, sized so that all of his together stay
  under three-fifths of the documented 2,500 MB: **500 MB a day on every device** — three
  devices, 1,500 MB. (It was 1,000 MB on a Mac and 250 MB on a phone, sized for a Mac that
  fetched everything. With a sync limit of six months the first sync of any device is about
  500 MB — ASSUMED sizes, 5.4 — so equal shares let every device finish in one day's
  allowance; a Mac set to "everything" takes about five days instead of three.) At its share
  a device's backfill lane closes until the next day; the other lanes are not capped. D7
  changes the unit arithmetic if the quota is the older one.
- **His own uploads are not fetched back.** A `messagesAdded` record for a message id that a
  local draft row holds as `uploaded_msg_id` is stored from the local draft; nothing is
  downloaded for it.
- **Requests in flight:** `maxInFlight` 4 per account; 2 for the rest of a pass after a
  `concurrent` limit.
- `rate`, the pauses and the day's bytes are saved in `account.quota_state`, so a relaunch does
  not start with a burst into a limit it had just backed away from.
- The unit costs are one table (`GmailCost`, with `QuotaProfile.may2026` and `.legacy`); D7.

Not built for the first release (E-32 accepted): hourly byte bins, an adaptive batch size, and
switching the fill to header-only reads when bytes run out.

```swift
enum QuotaRules {
    static func refilled(level: Double, rate: Double, elapsed: TimeInterval, capacity: Double) -> Double
    static func maySpend(_ units: Int, lane: QuotaLane, level: Double) -> Bool
    static func afterLimit(rate: Double, consecutive: Int, retryAfter: TimeInterval?, jitter: Double) -> (rate: Double, pause: TimeInterval)
    static func afterQuietMinute(rate: Double, ceiling: Double) -> Double
    static func backfillOpen(bytesToday: Int, dailyLimit: Int) -> Bool
}
```

`QuotaLane` (`interactive`, `incremental`, `backfill`) and the protocol `MailQuotaGoverning`
(`take(_:lane:)`, `report(_:)`) are declared in `M/MailQuotaGoverning.swift` (P10a), with
`UnlimitedGovernor`; `MailQuotaGovernor` (P11, order 6) conforms. Nothing before P11 names it.

### 5.3 One routine: reconcile

**Reconcile makes the local copy agree with Gmail by enumerating, then checking.** It runs
whenever an account has no usable history position or is asked to:

| When | The cache it starts from |
|---|---|
| First sync of an account on a device | Empty |
| Gmail answers `notFound` to `history` (the position is too old) | Full, possibly stale |
| The index was rebuilt from stored content (4.9) | Messages without labels, unconfirmed |
| A drift check fails twice (5.8), or once a week on a Mac | Full |

It never deletes the cache to start over and never touches `intent.sqlite`; the overlay keeps
applying throughout. Its position is in `account.enum_state`, so every step can be interrupted
and resumed.

**Incremental sync runs throughout** (S-17). The handshake stores the history position at once,
and every poll replays history from it while the enumeration proceeds — over days, on a phone.
New mail arrives during a first sync exactly as afterwards, and the position never ages out
behind a long enumeration.

1. **Handshake** (interactive lane). `profile`: the address is checked (invariant 2);
   `account.checkpoint = historyId` — before any listing, so every change made while listing is
   replayed — and `profile_total`. Then `labels` (below).
2. **Head** (interactive lane; only when the inbox view has no dated rows). One page of
   `listMessages(labelIDs: ["INBOX"], maxResults: 100)`; the newest 50 conversations are fetched
   in full. This is what makes mail usable in ten seconds.
3. **Enumerate** (backfill lane). For every label, `listMessages(labelIDs: [L],
   includeSpamTrash: true, maxResults: 500)` to the last page — inbox first, then unread,
   starred, drafts, sent, important, the categories, user labels, Banana's labels, trash, spam —
   and then one listing with no label, for mail that has none. For each page, the account's
   `checkpoint` is read **before the request is sent** (`floor`), and the page is applied in one
   transaction that also saves the next page token:
   - an unknown id becomes a stub (`fetch_class` from the label that found it, `list_rank` from
     its position, `history_id = floor`);
   - a membership the listing shows and the store lacks is **added now**, unless the message's
     stored `history_id` is greater than `floor` — something newer than this listing has already
     spoken for it (invariant 23) — in which case the message goes to `verify_queue` instead;
   - every (label, message) pair seen gets an `enum_mark`.
   A page token Gmail no longer accepts restarts that one listing.
4. **Close**, only when every listing reached its last page without error. A stored membership
   with no mark, on a message that existed here before this enumeration began
   (`msg_pk <= enum_state.maxPKAtStart`) and whose `history_id` is not greater than the
   enumeration's starting position, is a *possible* removal: the message goes to `verify_queue`.
   Likewise any such message absent from the unlabelled listing. **Nothing is removed here.** A
   message he chose to keep after Gmail said it was gone (`vis = 4`) is skipped: it is never
   queued again and never counted again (5.7). The marks are deleted and `enum_completed_at`
   is set.
5. **Verify.** `GmailSession.messages(ids, format: .minimal)` for the queue, fifty at a time
   (incremental lane when the queue holds 50 or fewer, else backfill). Each result is *recorded*
   in `verify_queue.outcome`:
   - `.ok` — the message's label set is set exactly, under the stale-read rule of 5.6; the row
     leaves the queue.
   - `notFound` — outcome `gone`; the row stays.
   - anything else — the row stays, to be read again.
   When no row of this generation is left unread, **all the `gone` rows are judged together**
   (5.7): that is what "a pass" means for a reconcile, however many batches it took.
6. **Fill** (5.6) runs alongside from step 2 on.

**Under a sync limit the steps are the same and the mailbox is smaller** (5.4): every listing
of step 3 is dated from the edge, the claims are listed without a date, the close of step 4
suspects only what a dated listing could have shown, and each held conversation that reaches
back past the edge is read once as a thread. What follows describes the routine; 5.4 says
what it is run over.

**Labels.** A `labels` response is *complete* only if it contains `INBOX`, `SENT`, `DRAFT`,
`TRASH`, `SPAM`, `UNREAD` and `STARRED` (every mailbox has them). An incomplete response changes
nothing. A complete one upserts every label it names. A stored label it does not name is **not
removed**: it is asked for by id (`label(id:)`), and removed — with its memberships and its
view — only on that call's `notFound`. If the labels to be removed carry more than a third of the
account's memberships (and at least 20), they are held as in 5.7 (S-3).

Why listings may add but not remove: a listing is read page by page while the mailbox changes,
and a message that moves across a page boundary can be skipped. Skipping an addition costs
nothing — history, or the next reconcile, adds it. Believing a skip as a removal would take a
conversation out of the inbox here while it sits in the inbox at Gmail, and he would not see mail
he was sent.

Cost (arithmetic on DOCUMENTED prices): listing is 5 units per 500 ids. For the 20,000
messages ASSUMED inside six months, with three labels each on average, about 160 pages: 800
units, ten seconds of budget; for 100,000 under "everything", 800 pages and 4,000 units.
Verify costs 20 units a message and is empty on a first sync.

```swift
enum ReconcileRules {
    /// What one listing page changes. `floor`: the account's history position when the request left.
    static func apply(page: [ListedID], label: String?, floor: UInt64,
                      stored: (String) -> StoredMessageState?) -> PagePlan     // .stub, .addLabel, .verify, .mark
    /// At close: which stored memberships no listing confirmed.
    static func unconfirmed(marks: Set<Membership>, stored: [StoredMembership],
                            maxPKAtStart: Int64, startedAt: UInt64) -> [Int64]   // msg_pks to verify
    /// Whether a labels response may be trusted to be the whole list.
    static func isComplete(_ labels: [GmailLabel]) -> Bool
    /// Invariant 3.
    static func removalAllowed(removing: Int, cachedInAccount: Int) -> Bool    // false when removing >= 20 && removing * 3 > cached
}
```

### 5.4 The sync limit: what a device keeps, and when it has it

**The owner's ruling: a sync limit, six months by default, and search that asks Gmail as well
whenever the limit is not "everything".** This replaces the size ceilings as the main control
of what a device holds (D3; 11.3 keeps them as a backstop), and it changes the fill.

**The setting.** `MailSyncLimit`: one month, three months, **six months** (the default), one
year, everything. It is **per device, not synced**: a phone and a Mac have different disks
and different jobs, a Mac may well keep everything while a phone keeps three months, and a
synced value would let a change made on one device delete from, or fill, another he is not
looking at. It lives in `intent.sqlite`'s `meta` — device-local, and it outlives a cache that
is deleted and rebuilt. One value for the device, every account.

**The edge** is the start of the local day that many calendar months before today; it moves
once a day, at local midnight. With "everything" there is no edge, and everything below about
edges, release and "older mail" does not apply.

**The rule — what a device keeps.** *A conversation is held when something about it is on this
side of the edge, or when he has a claim on it. A held conversation is held whole.* Exactly:

1. **Recent mail.** Its newest message is dated on or after the edge.
2. **Recent attention.** He looked at it or acted on it on or after the edge: opened it,
   changed it, or had it fetched because he asked for it (a search result he opened, a
   notification he tapped). `thread.attended_at` records the last of these.
3. **A claim**, which has no date and holds for as long as it stands:
   - a message of it carries `STARRED`;
   - it has an unsent draft — a message carrying `DRAFT`, or a draft row of this device's;
   - it carries one of Banana's own labels (`Snoozed/*`, `Waiting/*`, `Returned`, `Muted`);
   - a send of his in it is unfinished: held, waiting, sending, being checked, scheduled,
     failed, or asked about;
   - a change of his to it has not reached Gmail, or was refused and not yet dismissed;
   - a question about it is open, it is in a held removal, or he kept it after Gmail removed
     it (`vis = 4`) — that last is nowhere else on earth and is never let go.

Nothing else keeps a conversation. Being in the inbox does not, nor being unread, nor being
marked important: none of those is something he did, and an account whose inbox was never
emptied would otherwise defeat the limit. The rule is `MailHoldRules` (pure; P05):

```swift
enum MailHoldRules {
    /// The start of the local day `limit` before `now`; nil for `.everything`.
    static func edge(for limit: MailSyncLimit, now: Date, calendar: Calendar) -> Date?
    /// Whether a conversation is held, and by what. `claims` are the facts of rule 3.
    static func holds(newestMessage: Date, attendedAt: Date?, claims: MailClaims, edge: Date?) -> MailHoldReason?
    /// Whether a label, added to a message this device does not hold, makes its conversation held.
    static func isClaim(labelID: String, bananaLabelIDs: Set<String>) -> Bool   // STARRED, DRAFT, Banana's
}
struct MailClaims: OptionSet, Sendable { /* starred, draft, bananaLabel, unfinishedSend, pendingChange, question, keptAfterRemoval */ }
enum MailHoldReason: Sendable { case recentMail, recentAttention, claim(MailClaims), everything }
```

**Whole, or not at all.** A held conversation has every one of its messages here, the ones
older than the edge too: a conversation with its first half missing is not one he can read or
reply to. So a conversation is the unit of holding, of fetching and of release. Fetching one
whole is one `thread` read (40 units, whatever its length). A conversation every one of whose
messages was listed needs no such read: **a thread's id is the id of its first message**
(ASSUMED; probe item 14; the fake's row 51), so when the listed ids of a thread include the
one equal to the thread's id, the whole conversation is inside the edge and its messages are
read one by one as before; when they do not, its beginning is older, and it is read as a
thread. If the probe shows the assumption false, every conversation is read as a thread: the
cost of 5.4's table rises by at most half.

**Not held — the third state.** A conversation is *present* (held, with rows), *absent* (Gmail
said it is gone: its rows were deleted and a tombstone written, under 5.7), or **not held**:
in Gmail, and not on this device because of the limit. Not held is not stored — there is no
row, stub, mark or tombstone for it, which is the only way nothing can ever mistake it for
anything — and it is the state of every conversation Gmail has that this device has no row
for. Invariant 34 is what follows from that:

- Nothing concludes anything about Gmail from a conversation not being here. The removal
  rules of 5.7 are about rows that exist; the hold of invariant 3 counts removals of rows that
  exist; "unknown is not absent" (invariant 22) now also reads "not held is not absent".
- A screen is never told "deleted" for it. `observeConversation` answers `nil`, which the
  contract already defines as "this device holds no such conversation now", and `wants`
  fetches it. A list says how far back it reaches (`MailListSnapshot.heldSince`, 13.10) and
  never ends as if nothing older existed.
- A count is of what is held, and says "at least" when Gmail's own counter for that label is
  larger (below).

**How the listings change (5.3).** Enumeration under an edge is the same routine over a
smaller mailbox:

- Every listing of step 3 — the one with no label first, then each label's — carries
  `query: "after:<seconds>"`, where the seconds are the edge **less one day** (the margin
  covers Gmail's own reading of a date; probe item 14). The edge an enumeration runs with is
  fixed when it starts (`enum_state.edge`).
- **The claims are listed without a date**: `STARRED`, `DRAFT`, and each of Banana's labels.
  They are small. A message they turn up that is older than the edge is a stub like any other,
  and its conversation is fetched whole.
- **At the close (step 4), a listing vouches only for what it could have listed.** A stored
  membership with no mark is a possible removal only when its message is dated on or after
  that listing's edge. For an older message — the tail of a long conversation, a starred
  conversation from 2019 — absence from a dated listing is evidence of nothing, not even a
  reason to verify.
- **Instead, each held conversation with a message older than the edge is read once per
  reconcile**, as a thread, `minimal` (40 units): the answer sets the label set of every
  message it names, under the stale-read rule, and a stored message it does *not* name goes to
  `verify_queue` for the per-message read that alone can remove it (invariant 1). A first
  sync has none of these. Later ones have the claims, the long conversations and what he
  looked at — hundreds, ASSUMED — at backfill priority.
- The comparison of ids listed with `messagesTotal` (5.8) is made only under "everything".

**History under an edge (5.5).** A history record about a message this device holds is
applied as before. About one it does not hold:

| Record | What happens |
|---|---|
| `messagesAdded` | The message is read first (`header`, 20 units), and **nothing is written until it has been**. Dated on or after the edge — new mail, the ordinary case — its conversation becomes held and is fetched whole. Older, and with no claim label — an import, a message put there by another program — nothing is stored: not a stub, not a tombstone. |
| `labelsAdded` naming a claim label (`STARRED`, `DRAFT`, one of Banana's) | He starred, drafted in or snoozed an old conversation somewhere else: it is fetched whole and held. |
| any other `labelsAdded` or `labelsRemoved` | **Nothing.** No stub, no read. Ten thousand old messages archived on the web are ten thousand records this device skips. |
| `messagesDeleted` | Nothing, and no tombstone: there is no row to delete and none to protect. |

So a record never makes a half-known row. (The first design read every unknown message a
label record named; under an edge that would have pulled the whole mailbox in, one bulk
archive at a time.)

**The rolling edge: release.** Each day the edge moves on, and the conversations it has
passed — no recent mail, no recent attention, no claim — are **released**:

- by a pass of its own (`MailRelease`, P33), once a day per account after the edge has moved,
  at the pace of 4.12 like any local pass: on a Mac whenever the pace allows; on an iPhone or
  iPad inside the overnight task, or with Mail on screen at the paced share;
- in batches of 50 conversations, each one piece of work for the writer: the index rows first
  (the conversation, its messages, their labels, its place in every view), **with no
  tombstone**; then the content rows and files; then its search entries, queued for the
  indexer. Index first, content second, as eviction does (11.3), so a crash between the two
  leaves an orphan to delete and never a row that points at nothing;
- never while an enumeration is unfinished for the account, never a conversation in
  `verify_queue` or `held_removal`, never one a screen is observing, and never one with a
  claim — the test of rule 3 is made again inside the transaction that releases;
- counted in the journal and nowhere else: not in `MailPassReport.deletedCount`, not in
  `account.removals`, not towards invariant 3.

A day's release is a day's mail from six months ago: tens of conversations.

**Changing the limit.** *Raising it* (or choosing "everything") starts an enumeration with the
wider edge — a reconcile from a full cache, removing nothing — and the fill goes on, newest
first, into the older mail; health is `.catchingUp`. *Lowering it* takes effect on the fill at
once and on the store through release, at its pace; the screen asks first, and
`conversationsBeyond(_:)` (13.10) gives it the number to say — "about 8,200 conversations
will be removed from this Mac; they stay in Gmail" — and, afterwards, how many are still to
go. Raising it again fetches them again.

**What "complete" means, and how it is said.** An account is complete on a device when the
enumeration for the current edge has closed and both fetch queues are empty: every held
conversation is here, whole, with its text. `MailDownload` (13.4) says where that stands:
`limitEdge` — the edge, or nil for everything; `backTo` — the date back to which every held
message has its text; `messagesHere` and `messagesAbout` — of the mail inside the limit, not
of the mailbox. "Mail since 6 April is on this Mac" is `backTo <= limitEdge`. A list's foot
says the same about itself, and a search says what Gmail added (9.4).

**Counts under an edge.** A place's counts are of held conversations. For a Gmail label —
the system ones and his own — `label(id:)` (1 unit) gives Gmail's own `threadsTotal` and
`threadsUnread`: read for the inbox at every drift check (5.8), and for the others after each
enumeration and once a day. Where Gmail's number is larger than what is held, that place's
`MailCount.isAtLeast` is set — "12+" — and so is every split's, since a split is a part of
the inbox.

**When it is here.** Arithmetic on the documented quota, one device syncing, the governor at
80 units a second with a 1,000-unit bucket; the first screenful in the interactive lane. The
mailbox is ASSUMED at **110 messages a day across his accounts — about 20,000 messages in six
months — and 25 KB a message as it arrives, compressed**; neither is known until the first
real sync reports it, and both scale the table directly: **a thousand messages are about four
minutes of quota and 25 MB.**

| After | Units spent | What is on the device |
|---|---|---|
| 10 s | ≈ 1,800 | The newest 50–80 inbox conversations, with bodies, prepared and searchable. The label list. |
| 1 min | ≈ 5,800 | About 250 messages. **Every message inside the limit is known by id and label** — the dated listings of 20,000 messages are about 160 pages, 800 units — so counts are exact from here. |
| 30 min | ≈ 145,000 | About 7,000 messages: the newest two months. |
| **Six months complete** | **≈ 400,000–450,000** | **About an hour and a half of quota**, and about 500 MB — one day's allowance (5.2). |
| A year, by choice | ≈ 850,000 | About three hours of quota; about 1 GB, two days of allowance. |
| Everything, by choice: 100,000 messages | 1.1–2.0 million | 3.8–7 hours of quota; about 2.4 GB, five days of allowance. |

Preparing what arrives (section 10) is not the limit: the fill delivers about 4 messages a
second and preparation, even paced to a fifth of a core, handles about fifteen a second (4.12).

Said plainly, and shown in Settings in these terms:

- **A Mac that stays on** is usable from the first ten seconds and has its six months in
  about an hour and a half. Quota is the limit; the day's bytes are not, at these sizes.
- **An iPhone or iPad** fills in only while Mail is on screen, and in overnight windows on
  power and Wi-Fi (12.2). On battery, with Mail on screen, the fill uses two requests at a time
  and the paced share of a core (12.1); off screen it stops. **Six months is one night on the
  charger, or a few days of ordinary use**; "everything" is a week or more (R-8). Until then
  the device has what is newest, and fetches anything else when it is opened — which needs a
  connection. The first-sync screen says this in these words, with the date it has reached.
- **Two devices at once** share the one budget and each takes about half the speed.

### 5.5 Incremental sync

Every poll, for each connected account with a history position, in the incremental lane:

1. `history(start: checkpoint, maxResults: 100)`, every page (2 units each; all four record
   types; **no label filter** — it is UNVERIFIED whether a filter hides a message leaving that
   label, so the design does not depend on the answer).
2. **Each page is one index transaction, which also moves the checkpoint** to that page's last
   record id (after the final page: to the response's own `historyId`). That is the only
   transaction rule. A kill between pages replays from the last committed page, which is
   harmless because applying is by state.
3. **A pass that found no records writes nothing** — no transaction, no publish — unless the
   stored position is more than an hour old, in which case it stores the response's `historyId`
   (one write an hour keeps the position inside Gmail's retention).
4. Fetch what was added (5.6), in the same pass.
5. `notFound` from `history`: `checkpoint = NULL`, health `.checking`, run reconcile. Any
   other failure leaves everything as it was.
6. Read back what a change's 404 queued (6.5): up to 50 `verify_queue` rows with that reason,
   `minimal`, in the incremental lane. A read that answers sets the labels and lets the waiting
   assertions retry; `notFound` deletes the message under the 24-hour count of 5.7 and drops
   them as moot. Rows queued by a reconcile are that reconcile's (5.3 step 5).

```swift
enum HistoryRules {
    static func plan(_ records: [GmailHistoryRecord], known: (String) -> StoredMessageState?,
                     knownLabel: (String) -> Bool, tombstoned: (String) -> Bool) -> HistoryPlan
}
struct HistoryPlan: Equatable {
    var createStubs: [NewStub]             // id, threadId; history_id = the record's id
    var setLabels: [LabelChange]           // message, add, remove, record id
    var delete: [String]                   // message ids — subject to 5.7
    var fetch: [String]                    // ids to read in this pass
    var echoes: [EchoedIntent]             // (message, label, want, record id) seen coming back (6.2)
    var unknownLabels: Set<String>         // label ids no row exists for
}
```

- `messagesAdded`: an unknown id becomes a stub and is fetched; a tombstoned id is ignored; a
  known id changes nothing. **Under a sync limit, an unknown id whose conversation is not held
  is read before anything is written**, and becomes a row only if that makes its conversation
  held (5.4's table): new mail does; an old message that someone imported does not.
- `messagesDeleted`: a positive statement. The row, its labels, its search entry and its content
  are deleted and a tombstone is written — unless the pass trips invariant 3 (5.7). For a
  message this device does not hold there is nothing to delete, and nothing is written.
- `labelsAdded` / `labelsRemoved`, message known: applied to `message_label` and the message's
  `history_id` raised to the record's id — unless the record's id is not greater than the stored
  `history_id`, in which case what is stored already reflects it. **A record never sets
  `labelsKnown`** (6.1): on a stub it changes the labels it names and leaves the rest unknown.
- `labelsAdded` / `labelsRemoved`, **message unknown**: under "everything", a stub is made with
  no memberships and is read in this pass (`minimal`) — a record says what changed, not what
  the label set is, and a partial set would be a statement about labels the record never
  mentioned (invariant 22). **Under a sync limit the message is not held, and the record is
  skipped** — no stub, no read — unless it adds a claim label (`STARRED`, `DRAFT`, one of
  Banana's), in which case the conversation is fetched whole and held (5.4).
- **Labels are read again once an hour** with the poll (`labels`, 1 unit, by the complete-list
  rule of 5.3), so a label renamed or recoloured elsewhere is seen within the hour, not at the
  next weekly reconcile.
- **A label id with no row**: the pass calls `labels` once and plans the page again. If the id is
  still unknown, a row is created for it with `kind = 1` and its id as its name; the next
  `labels` read names it.
- An id added and deleted within one page is neither stubbed nor fetched.
- A message that answers `notFound` when read in the pass that added it keeps its stub and is
  read once more in the next pass; a second `notFound` deletes the stub by 5.7. One answer is
  not enough: Gmail may list a message a moment before it can be read.

Applying is by state, not by event: adding a label that is there and removing one that is not
are no-ops, so replaying a stretch of history ends in the same place.

What a pass returns, for everything that reacts to sync (notifications, the timed rules, status,
the outbox's echoes) — a value, not a callback:

```swift
struct MailPassReport: Equatable, Sendable {
    var account: String
    var result: MailSyncHealth
    var added: [String]                    // Gmail message ids stored for the first time
    var deletedCount: Int, heldCount: Int
    var touchedThreads: Int
    var newInInbox: [String]               // ids added with INBOX and UNREAD — for NotifyRules
    var repliesIn: [String]                // thread ids that gained a message not from him — for section 8
    var echoes: [EchoedIntent]
}
```

### 5.6 Filling in

Two queues, both newest first within a class, both partial indexes in `index.sqlite`:
`message_stub_queue` (ids with no header) and `message_body_queue` (headers with no body).

`fetch_class` — which mail first: 0 inbox, starred, drafts, anything snoozed or waiting; 1 sent,
important; 2 everything else outside trash and spam; 9 trash and spam (fetched only when those
lists are opened, or last).

```swift
enum FetchPlanRules {
    static func fetchClass(labels: Set<String>, hasBananaLabel: Bool) -> Int
    /// Turn the next ids into calls. `sizes`: messages per conversation, where known.
    static func plan(next: [QueuedMessage], sizes: [String: Int], want: GmailFormat) -> [FetchCall]
    /// Invariant 23. `floor`: the response's own historyId, or the account's position when the
    /// request left if the response carries none.
    static func labelsApply(storedHistoryID: UInt64?, floor: UInt64) -> Bool     // stored == nil || stored <= floor
}
```

- **One conversation call or several message calls.** A conversation costs 40 units whatever its
  size, a message 20. Three or more wanted messages in one conversation of at most 40 are
  fetched as the conversation; otherwise one by one.
- **Full, once.** A read costs 20 units in any format, so the default is `full`: everything a
  device holds, it holds with its text (5.4). `header` format is read in three places only —
  an unknown message a history record adds, to learn its date before deciding whether it is
  held; the fallback for a message whose `full` answer cannot be decoded (below); and a row
  only Gmail found (9.4), which is not stored at all. (The first design had a tier of
  messages kept as headers because their bodies were past a size ceiling. The sync limit
  replaces it: older mail is not held, not half held. A body dropped by the backstop of 11.3
  is the one header-level message left.)
- **Header format** asks for `From, Sender, To, Cc, Bcc, Reply-To, Subject, Date, Message-ID,
  In-Reply-To, References, List-Id, List-Unsubscribe, List-Unsubscribe-Post, Content-Type,
  Authentication-Results, Delivered-To, Auto-Submitted, X-Google-Original-Message-ID,
  X-Banana-Send-At, X-Banana-Send-Owner`.
- **What is read from a message.** Gmail returns the MIME tree already parsed (`payload`), so no
  MIME parser is built. The tree is walked with two limits — depth 20, 1,000 parts — and a
  message beyond either is stored as headers with `body_kind = tooLarge`. Part bodies are
  base64url, decoded with Foundation in 64 KB pieces (MEASURED by the reuse review: 41 ms for
  25 MB, against 458 ms and 91 MB of memory for one whole-buffer decode). Text parts are
  transcoded to UTF-8 with `CFStringConvertIANACharSetNameToEncoding`.
- **An unknown charset — one rule, for a body and for a header's encoded word alike:** the
  bytes are read as UTF-8 if they are valid UTF-8, and as Windows-1252 otherwise (a byte
  Windows-1252 leaves undefined becomes U+FFFD). Never left as the raw `=?…?=`: the label
  that turns up in real mail is `unknown-8bit`, on text that is one of those two, and "Café"
  is better than `=?unknown-8bit?Q?Caf=E9?=`. `cleaned` (10.8) runs on the result as on any
  other text.
- **Headers are the sender's, and are kept under limits**: 1,000 fields, 256 KB, 16 KB a
  value (`MessageHeaders`). What a limit removes is *unknown*, not absent, and
  `isComplete` says so. **But a limit bounds what is kept, not what is known**: the headers
  the engine reads by name — the list of the header format above, **less
  `Authentication-Results`** — are looked for through the whole of what Gmail sent, and the
  first of each that the kept part lacks is kept too, its value cut at 16 KB like any other.
  So a `From` placed after five thousand lines of padding is still the sender, as it is in
  Gmail; hiding it costs the sender nothing and would otherwise have worked.
  `Authentication-Results` is not looked for further down: its meaning is its position
  (10.6), and Gmail's own is in the first few lines. A `From` that is still not readable —
  absent, or cut before its address — is the unreadable sender of 10.8.
- **A message's labels, when the answer names none.** The wire type keeps the difference
  between a `labelIds` that was sent and one that was not, and what a missing one means
  depends on what was asked. **In a per-message read** — `messages.get` in any format, and
  each message of a `threads.get` — **a missing `labelIds` means the message has no labels**:
  the empty set, known. Google's JSON leaves out an empty list (ASSUMED of Gmail; probe item
  12; the fake's switch `omitsEmptyLabelIds`, on by default), and read the other way a
  message whose last label was removed elsewhere would keep it for ever, through every
  reconcile. The engine asks for no partial response, so nothing of its own making can drop
  the key. **Everywhere else** — an item of a listing, the message inside a history record —
  a missing `labelIds` is unknown, and is evidence of nothing. If the probe shows that Gmail
  always sends the key, a per-message answer without it becomes `malformed` for that message,
  and nothing is concluded from it.
- **Mail bounds its own recursion.** Decoding a `GmailPart` counts its depth and throws past
  64 nested parts — a number of mail's own, well over the walk's 20 and under Foundation's
  limit as measured — so that what stops a hostile tree is not a limit somebody else may
  raise. A message stopped there is the undecodable message below.
- **`fetch_state = 2` means the `full` read has been made and there is nothing more to
  fetch** — not that a body is stored. A message beyond the walk's limits is at
  `fetch_state = 2` with `body_kind = tooLarge` and a header-level content row, and so is out
  of both queues for good; opened, it says it is too large to show here and offers Gmail.
- **A message whose `full` answer cannot be decoded** is that same state, reached another
  way. Foundation's JSON reader has a nesting limit of its own, and a MIME tree about 120
  parts deep exceeds it (MEASURED by P03a): the whole response fails to decode —
  `GmailError.malformed` — before any walk can cut it. `malformed` is evidence of nothing
  about the message (5.5), and a captive portal can produce it for every message at once, so
  one such answer marks nothing. Instead: **a `full` read that answers `malformed` is
  followed, once, by a `header` read of the same id.** If that decodes, Gmail is answering
  and it is this message's body that cannot be read: it is stored from the header read at
  `fetch_state = 2`, `body_kind = tooLarge`, and never asked for in `full` again. If the
  header read fails too, in any way, nothing is concluded and nothing is stored; the id is
  left alone for the rest of this process — at most two reads of it per launch, never a loop
  inside a pass — and tried again in the next. A `thread` read that answers `malformed` is
  not repeated as a thread: its wanted messages are read one by one, and each meets this rule
  on its own. (Invariant 1: the message is a row that says what it is. It is not dropped,
  and it is not fetched for ever.)
- **Writing a batch — at most 20 messages** (4.12). Content goes to `blobs.sqlite` first, then
  one index transaction: the message rows; correspondents; summaries; views; `fts_dirty`;
  `prep_state = 0`. Then the labels:
  - **The stale-read rule (invariant 23).** The fetched label set replaces the stored one only
    if `FetchPlanRules.labelsApply` says so, and that — and nothing else — sets `labelsKnown`
    (6.1). Otherwise the stored labels stand — a newer history record has already been
    applied — the content is stored all the same, and `labelsKnown` is left as it was.
  - **Tombstones (invariant 29).** An id in `tombstone` is not stored; its job is dropped.
  A crash between the two files leaves a blob with no index row, which the next fetch
  overwrites. The reverse — an index row that says "body here" with no blob, after a power loss
  took one file's last commits and not the other's — is repaired three ways (S-16): opening a
  message whose content row is missing sets it back to `fetch_state = 1` and fetches it; after
  an unclean exit a paced pass compares the two files and sets every such row back; and eviction
  always changes the index before it deletes the blob.
- UNVERIFIED: that `messages.get` returns `historyId` in every format. If it does not, the floor
  is the account's position when the request left, which is always safe: it can only cause an
  extra read.

### 5.7 What removes a message or a label

Collected in one place, because this is the rule the calendar learned the hard way.

| Evidence | Effect |
|---|---|
| `messagesDeleted` for the id | Delete, and write a tombstone |
| `notFound` (as defined in 5.1) from `message(id:)` for that id, token verified | Delete if it was stored; drop the job if it was not |
| `labelsRemoved` for the message | Remove those memberships |
| A per-message read (`minimal`, `header` or `full`) that passes the stale-read rule | Its label set, exactly — and a read that carries no `labelIds` says the set is empty (5.6) |
| `notFound` from `label(id:)` | Remove the label |
| A 404 from a change (`modify`, `batchModify`, `trash`, `untrash`) | **Nothing.** The message is queued for a per-message read; the change waits for its answer (6.5) |
| Absence from a listing, or from a `labels` response | Nothing. Queue a per-id read. |
| `unexplained`, `unknownOutcome`, `neverLeft`, `limited`, `server`, `malformed` | Nothing |
| A token that answered for another address | Nothing; stop the account |
| Absence from a listing dated from the edge, of a message older than that edge | Nothing — not even a read (5.4) |
| The sync limit's edge passing a conversation with no claim on it | **Release, which is not a removal** (invariant 34): its rows go, no tombstone is written, nothing is counted towards the hold, nothing is announced |

**The hold (invariant 3).** Deletions are counted where they are decided:

- *A reconcile:* all the `gone` outcomes of one generation's verify queue, together.
- *Incremental sync:* this pass's `messagesDeleted` plus those applied in the previous 24 hours
  (`account.removals`: hourly counts).

If the count is at least 20 and more than a third of the account's cached messages, **none of
them is deleted**. Each is written to `held_removal` with its evidence; the rest of the pass —
additions, label changes, the checkpoint — is applied as usual, so sync stays alive and the
evidence is not lost when history moves on. The question `removalHeld(account:count:)` (13.2)
is raised, **what it would remove can be looked at first** — the place
`.heldRemoval(account:)` lists those conversations through `observeList` like any other —
and the person answers once:

- **Remove them** — the held deletions are applied.
- **Keep them on this device** — each held row is marked `kept`; its message gets `vis = 4`,
  stays readable and searchable, is drawn as "no longer in Gmail", and accepts no change (there
  is nothing in Gmail to change). Settings keeps "Remove mail that Gmail no longer has".

Until he answers, held messages are shown as they were. A later pass adds to the same hold; it
does not ask again. After he has answered, kept messages (`vis = 4`) are outside invariant 3
altogether — not verified, not counted towards the next hold, not in "cached messages" (S-N4).

### 5.8 Catching drift

History can lose records ("records might be unavailable in rare cases", DOCUMENTED §1.3), and a
listing may lag behind a change (UNVERIFIED). Cheap checks, one unit each:

- Every six hours with Mail open on a Mac, and in each overnight window on a phone or iPad:
  `label("INBOX")`. If its `threadsUnread` or `threadsTotal` differs from the local inbox view —
  compared only when no overlay touches the inbox and the last pass is over a minute old —
  note it. The same difference at the next check, at least ten minutes later, re-lists that one
  label by 5.3's steps 3–5. One disagreement is not acted on: the calendar's two-pass rule.
- Once a week on a Mac, and in an overnight window on a phone when a week has passed, a whole
  reconcile at backfill priority.
- After every reconcile under "everything", the number of ids listed is compared with
  `messagesTotal`; a shortfall re-runs the unlabelled listing once.
- **Under an edge, Gmail's counters cover mail this device does not hold, so the inbox check
  compares ids, not numbers**: one listing of `INBOX` dated from the edge (5 units a page; an
  inbox is a page or two) against the held inbox's messages on or after the edge. A
  difference that is still there at the next check re-lists that label by 5.3's steps 3–5,
  as above. `label("INBOX")` is still read at the same moment, for its counters: where they
  exceed what is held, the place says "at least" (5.4).

### 5.9 How complete, stored and shown

Per account, in `index.sqlite`, cheap to read:

| Fact | From |
|---|---|
| The limit, and its edge | `MailSyncLimit` from `intent.sqlite`'s `meta`; `enum_state.edge` for the enumeration in hand |
| Messages inside the limit | `count(*) FROM message WHERE vis < 3` once an enumeration for the current edge has closed; before that, "about", from the dated listing's size estimate. Under "everything", `profile_total` |
| With header / with body / prepared | counts on the three queues' partial indexes |
| "Everything since <date>" | `headers_through`, `bodies_through` — moved back as the queues drain in order |
| Search behind by | `count(*) WHERE fts_dirty = 1` |
| What is holding it up | the governor (limited until; the day's bytes spent), the pace (on battery; warm; Low Power Mode), the free-space floor, waiting for Wi-Fi, waiting for Mail to be opened |

These are `MailStatusValue.downloads` (13.4), published at most once every two seconds. Every
list of search results, and the bottom of every list, can say truthfully what it does not cover.

### 5.10 An option, not built: seeding from another Banana device

A phone could take stored content from a Mac that has finished, over the local network, and skip
both of Google's limits. It is not in the plan. If it is ever built, the floor is fixed here so
that nobody sketches it on the podcast peer protocol, which is unauthenticated and replayable
(P-15): mutual authentication with a key only his synced keychain holds; an encrypted channel
(TLS with a pre-shared key, or Noise); a fresh challenge per session; content offered only for
accounts the receiver has itself been granted; nothing from `intent.sqlite`, ever; and its own
security review. D12.

## 6. The outbox

### 6.1 One rule

**An intent is the state the person wants one thing to be in. A new intent for the same thing
replaces the old one. It is shown at once, durable in the commit that follows, applied to what
is shown until Gmail agrees, and delivered as many times as it takes.**

There are three kinds of thing, all in `intent.sqlite`:

| Thing | Key | Desired state | Where |
|---|---|---|---|
| A label on a message | (account, message id, label) | present or absent | `label_intent` |
| A draft's content | local draft id | this revision, in Gmail's Drafts — or deleted | `draft` (7.3) |
| A message to send | local draft id | sent, not before a time | `draft` (7.4) |

Every triage change is label assertions and nothing else:

| `MailChange` (13.2) | Assertions |
|---|---|
| `done` | `INBOX` absent on the messages that have it; `UNREAD` absent on those that have it — one change, one undo |
| `notDone` | `INBOX` present on the last message |
| `read(true)` / `read(false)` | `UNREAD` absent on those that have it / present on the last message |
| `star(true)` / `star(false)` | `STARRED` present on the last message / absent on all that have it |
| *in every row* | "the last message" is the last one that is not a draft |
| `important(Bool)` | `IMPORTANT` present on every message / absent |
| `label(account:add:remove:)` | each label present / absent on every visible message, **for the target's conversations in `account` only**; the others are untouched and not counted (a label's id is one account's) |
| `move(account:to:from:)` | `to` present and `from` (or `INBOX`) absent, for the same conversations |
| `trash` / `restore` | `TRASH` present on every message / absent |
| `spam` / `notSpam` | `SPAM` present and `INBOX` absent / `SPAM` absent and `INBOX` present |
| `mute`, `snooze`, `unsnooze`, and the wake-ups | Banana's labels, with `INBOX` (section 8) |

Three rules about which messages an assertion names:

- **Messages, not conversations.** "Done" becomes "these four message ids have no `INBOX`".
  Sent as a conversation-level call later, it would also archive a reply that arrived in
  between — mail he has not seen.
- **As of what he saw.** The contract's commands carry, for each conversation on screen, the
  date of the newest message its row summarised (`asOf`). Messages newer than that are left
  alone. A command from a notification names one message and is as of that message. A command
  on a whole scope (`MailTarget.scope`) is as of the moment the writer handles it.
- **Never a draft.** A message with `DRAFT` gets no assertion: Gmail does not let a draft carry
  labels, and the request would be refused for the whole batch (E-22).

```swift
enum OutboxRules {
    /// The assertions a change means for one conversation, given its messages as they are now
    /// (effective labels), limited to messages not newer than `asOf`. Assertions that would
    /// change nothing are not produced.
    static func assertions(for change: MailChange, messages: [MessageFacts], asOf: Int64,
                           labelIDs: [String: String], now: Date) -> [Assertion]
    /// Requests that deliver these assertions, cheapest first (6.5).
    static func batches(_ pending: [StoredAssertion]) -> [LabelBatch]
    /// An assertion Gmail already agrees with is dropped, not sent. `gmailHas` is nil when no read
    /// has established this message's label set — a missing row, a stub, a rebuilt row — and nil
    /// is never moot (invariant 22).
    static func isMoot(want: Bool, gmailHas: Bool?) -> Bool      // gmailHas == want
}
```

`gmailHas` is `true` when the stored set has the label; `false` only when it does not **and** the
message's `labelsKnown` flag is set; otherwise `nil`.

**`labelsKnown` is set by one thing only: a per-message read** (`minimal`, `header` or `full`)
whose label set was applied under the stale-read rule of 5.6. A listing page does not set it —
a listing says one label is present and nothing about the others. A history record does not set
it — a record says what changed, not what the set is. The close of an enumeration does not set
it — a listing can skip a message (5.3). So a stub that listings and history have touched but
no read has yet described still answers `nil` for every label it does not show, and a
mark-read or an un-star made on it during a days-long first sync is delivered, not dropped
(S-N1). Once set, the flag stays: history keeps a known set current. The cost of being strict
is an occasional `modify` that changes nothing, at 5 units.

### 6.2 Accepting a change: shown, then durable

```
 key press ─▶ MailSource.apply (main actor, synchronous)
                1. a receipt: the next sequence number
                2. every live list and conversation observation applies MailRowRules to its own
                   rows and delivers — this is "shown"
                3. the change is handed to the writer; apply returns the receipt
             ─▶ MailWriter (its own serial queue)
                4. takes everything handed over since it last looked — at most 50 changes
                5. reads the targets' messages; OutboxRules.assertions
                6. ONE intent.sqlite transaction, full fsync — this is "durable"
                7. ONE index.sqlite transaction: overlay rows, summaries, view rows; commit
                8. announces the commit, tagged with the highest sequence it carries
                9. looks again; if more arrived meanwhile, back to 4
```

- **There is no timer in the group commit.** A commit carries whatever arrived during the
  previous one. One key press alone is committed immediately; a burst — ten quick presses of
  `E`, or a script — produces as many commits as the disk can take and no more, with no change
  waiting longer than one commit. (A held action key acts once, by the UX's rule; only a
  movement key repeats.) On this Mac that is 0.8 ms p50, 2.1 ms p95 for step 6 and
  0.2 ms for step 7 (MEASURED, 4.12). A phone's full fsync is ASSUMED to cost 5–20 ms
  and is measured on the device before order 3 (R-4).
- **Steps 6 and 7 are not atomic together** — no two SQLite files in WAL mode can be. The order
  makes a crash between them repairable by rule: the overlay is rebuilt from intent at launch
  (6.4). A crash before step 6 loses a change that was on screen for a few milliseconds and in
  nothing else; after a relaunch the screen shows what is true.
- **Nothing leaves without step 6.** Delivery reads `intent.sqlite`; the index and
  `first-page.json` are written only at or after step 7. So nothing reaches Gmail, and nothing
  survives a relaunch looking real, unless it is durable (invariant 4).
- **If step 6 fails** — `SQLITE_FULL`, an I/O error, the store unavailable — the writer
  discards that group, announces `MailEvent.notSaved(receipt, reason)` for each receipt in it,
  and every observation re-reads from the index, which never had the change: the rows come back.
  `MailStatusValue.store` becomes `.cannotSave(reason)` and the screens say what to do (free
  space; restart). The writer goes on working: the next group is attempted normally.
- **If step 7 fails after 6 succeeded** the change is durable and will be delivered; the overlay
  is rebuilt from intent at the next launch and at once if the index can be reopened.
- **No row flashes back while a commit is in flight.** Every index commit is tagged with the
  highest sequence it carries. A list observation keeps its own optimistic changes until a
  read tagged at or beyond them arrives, and only then drops them (13.7).
- **Counts.** `MailReceipt.count` is the number of conversations changed when the target was
  listed rows; for a `.scope` target it is `nil` until step 5 has counted, and then arrives as
  `MailEvent.applied(receipt, count:)`.
- **When the intent store is not open** (4.10), `apply` changes nothing on screen, returns a
  receipt with `count` 0 and announces `notSaved(.storeUnavailable)`.

The free-space floor (11.3) is what keeps step 6 from failing in ordinary life: the fill stops
with at least 1 GB free, and a change is a few hundred bytes.

### 6.3 The life of an assertion

```
          step 6                  request leaves:               2xx, and seq is still sent_seq
 (none) ─────────▶ pending ───── sent_seq = seq ─────▶ in flight ─────────────▶ settling ─▶ (deleted)
                    ▲   ▲                                  │                       the first sync pass
  a newer assertion │   └── retriable failure (backoff) ───┤                       begun after the 2xx
  for the same key  │   └── 2xx, but seq has moved on ─────┤                       has committed
  replaces it       │                                      ▼
  (seq rises)       │              404 or 400 for the batch: one request per message;
                    │              404 for one message: queue a read of that message; wait for it
                    │
                    └── person retries ◀── failed ◀── refused in a way that will not change
```

- **pending, in flight, settling** all count for the overlay (6.4). **failed** does not: a change
  that will never happen must not be shown as if it had (6.9).
- **Delivery marks only what it sent (invariant 25).** Leaving, a request stores each row's
  `seq` in `sent_seq`. Its answer updates rows `WHERE seq = sent_seq` and no others. If he
  pressed undo while the request was on the wire, the row's `seq` has moved on: the answer
  records what Gmail now has (`message_label` is updated — the mutation's 2xx is trusted) and
  leaves the newer assertion pending, to be delivered next.
- **Settling** holds the row steady while history catches up. It ends when the first
  incremental pass that *began* after the 2xx has committed. During that pass, a history record
  for a settling key is handled by `HistoryRules`: the same sense is the echo; the opposite
  sense *after* the echo is a newer change made elsewhere and is applied; the opposite sense
  with no echo before it is not applied — the message is read on its own, and that read is the
  truth. This holds whether or not Gmail's history reports this client's own changes
  (UNVERIFIED; the fake runs both ways), and there is no ten-minute timer.
- A row found **in flight** at launch was interrupted: it goes back to pending. Replaying a
  label change is safe; it is a set operation.

### 6.4 The overlay

```swift
enum OverlayRules {
    /// Gmail's labels for one message with the undelivered assertions applied.
    static func effective(gmail: Set<String>, assertions: [String: Bool]) -> Set<String>
}
```

Written through at step 7, not joined at read time: the `overlay` rows, the two summary rules
re-run for the conversations touched, `thread` and `view_thread` rewritten. **A list never joins
pending state**; only opening a conversation reads `overlay`, for its own handful of messages.

At launch, and after any cache rebuild, `overlay` is emptied and refilled from `label_intent`
(pending, in flight, settling) and those conversations are re-summarised, in transactions of
500 rows. **No view is read until the rebuild has finished** (S-N5): the first-frame snapshot,
which already shows those changes, stays on screen for that time, and a first page read from
a half-rebuilt index — archived conversations back in the inbox for a moment — is never
delivered. The wait is off the main thread and short: 45 ms p50 for opening the stores, 30
rows and the first page, and 0.2 ms more for each further change written through (MEASURED
under heavy load, 4.12); a day of offline triage is tens of milliseconds. An assertion
whose message has no index row yet — a rebuilt cache still filling — is remembered by key (the
set is loaded from intent, which stays the only owner) and applied in the transaction that
creates that message's row. This is the repair for a crash between steps 6 and 7, and the
reason a cache reset cannot lose a pending change.

### 6.5 Delivery

The driver runs per account, after that account's incremental pass *attempt* — so what it sends
is compared against Gmail as of a moment ago when the pass succeeded, and is not held up when
it did not. **His own assertions never wait for an enumeration** (S-17). Assertions a rule made
do, and step 1 says exactly when they may go.

1. **Re-derive** the assertions that a rule made (invariant 24): every undelivered assertion
   with `origin = rule` for the account is deleted and `due` is run afresh. **The fresh ones
   are delivered in this run only if both gates of 8.3 hold:** (a) the pass attempt just made
   *succeeded*, and an offset for Google's clock exists; (b) the account has no unfinished
   enumeration — `enum_state` is `NULL` and `verify_queue` holds no unread row of its last
   generation. If either fails they stay in the overlay, shown, and are derived again next
   time; nothing a rule made is sent.
2. **Resolve label references.** An assertion on `name:Banana/Snoozed/…` needs the label to
   exist: look it up by name; if absent, `createLabel(name:hidden: true)`; on `conflict` (a lost
   answer, or another device got there first) call `labels` and take its id. Rewrite the intent
   rows to the real id, then merge any `local:` label row in the index into the real one by name
   (the merge is repeated on every `labels` read, so a crash between the two files heals).
3. **Drop moot rows** — `isMoot`, with its three answers.
4. **Group** pending rows per message into (labels to add, labels to remove), then group
   messages with the same pair. Each group is one request:
   - 9 or fewer messages: `modify` each (5 units), through `GmailSession` in parallel;
   - 10 or more: `batchModify`, up to 1,000 ids (50 units);
   - a group that adds `TRASH`: `trash` per message (20 units), and one that removes it
     `untrash` — until the probe shows that adding the label is equivalent (UNVERIFIED).
5. Mark the rows in flight with `sent_seq` (one intent transaction), send, then handle the
   answer:

| Answer | The assertions in that request |
|---|---|
| 2xx | `message_label` updated; rows still at `sent_seq` → settling |
| `neverLeft`, `unknownOutcome`, `server`, `unexplained`, `malformed`, any `limited` | pending; `next_attempt_at` by backoff (a limit uses the governor's pause). Replaying is safe. |
| `notFound` or `refused` **for a `batchModify`** | The batch is not judged. Each message is sent on its own `modify`, so one dead id cannot fail or delete the rest (S-19). |
| `notFound` for one message's `modify`, `trash` or `untrash` | **Nothing is deleted** (invariant 1: this is a change's 404, not a read's). The message is queued for a per-message read, **which the next incremental pass makes** (5.5 step 6 — not the next reconcile, which may be a week away); its assertions wait in pending with no retry time. If the read answers `notFound`, the message is deleted by 5.7 and its assertions are dropped as moot — the one case where "the message is gone" is known. If the read answers, they are retried. |
| `unauthorized`, `scopeMissing`, `apiDisabled`, `networkDisabled` | pending; not retried until the account's state changes |
| `refused`, `domainPolicy`, `conflict` for one message | failed |

A held `e` over a hundred conversations is one `batchModify`: 50 units. Delivery waits 1.5 s
after the last change (5 s at most), so a burst goes as one request and a change undone within
the second sends nothing.

```swift
enum DeliveryRules {
    static func outcome(for error: GmailError, wasBatch: Bool, attempts: Int) -> DeliveryOutcome
        // .retry(after:), .splitBatch, .verifyTarget, .failed(MailFailure), .waitForAccount
    static func backoff(attempts: Int) -> TimeInterval      // 5 s, 30 s, 2 min, 10 min, 1 h, then hourly
    /// Which rows an answer may mark (invariant 25).
    static func marks(sent: [SentKey], rows: [StoredAssertion]) -> [SentKey]   // those whose seq == sentSeq
}
```

### 6.6 What wakes the driver

One driver, `MailOutboxDriver.kick(reason:)`, idempotent and coalesced. It is kicked:

- when a change is durable (after the 1.5 s debounce);
- at launch, once the intent store has loaded;
- on a real return to the foreground;
- when `NetworkMonitor.isOnline` goes from false to true (through `$isOnline`; its single
  `onWiFiAvailable` slot belongs to downloads);
- after every sync pass attempt;
- when a `next_attempt_at` or a send's `hold_until` comes due — one sleeping task for the
  soonest, foreground only;
- in the iOS background refresh task and when a notification action arrives (section 12).

This is the retry the calendar's pending writes never had.

### 6.7 Undo

**Undo is: assert what was there before.** For every key a change touched, step 5 records
whether the label was effectively present beforehand. `undo(receipt)` submits those as new
assertions through the same path. If the original has not been sent, coalescing collapses the
pair to nothing; if it has, the inverse is sent. One path for both cases.

- The "before" lists of the last 50 receipts are kept **in memory**, for the life of the
  process (E-32 accepted: they are not intent, and persisting them was cost without a risk
  retired). After a relaunch `undo` of an older receipt returns `count` 0 and the UI says so.
  The undo toast's six seconds is the UI's.
- A change may cover a whole view: thousands of keys, each with its own "before", so undo gives
  every conversation back its own labels.
- An undo is not itself undoable; there is no redo.
- A send is undone differently: only while it is held (7.5).

### 6.8 Against changes made elsewhere

Gmail offers no preconditions (DOCUMENTED §5.2): whichever write arrives last wins. History
records carry no times, so when his offline archive and a later un-archive on the web meet,
Banana cannot know which he did second.

**The rule: a pending assertion is delivered unless Gmail is known to agree with it already or
its message is known to be gone.** The two ways to be wrong are not equal. Delivering when the
other change was newer flips a label back to what he chose on this device — visible, and one
key to undo. Dropping when ours was newer makes something he did offline quietly not happen,
which is the failure this section exists to prevent. Delivery follows a sync pass, so "Gmail
agrees" is judged against fresh state and the window for the wrong outcome is seconds. An
assertion that waited more than a day (a device left in a drawer) is delivered by the same
rule; the outbox place shows how old the oldest undelivered change is.

### 6.9 When it will never work

A failed assertion stops overlaying, so the list shows Gmail's truth again, and
`thread.pending = 2` marks the conversation. `MailStatusValue.refused` lists them, one
`MailRefusedChange` per action — what was asked, of how many conversations, and why not —
rebuilt after a relaunch from `change_group` and the refused rows' `group_seq` (4.8), so the
receipt `retry(_:)` and `discard(_:)` take (13.3) is never lost. Nothing is discarded by a timer (invariant 6). Causes that reach this
state: a label deleted elsewhere; a Workspace policy. Everything else is a retry.

Changes for an account that is no longer connected stay in `intent.sqlite` and are listed under
"From an account no longer connected", each with Discard (3.6).

## 7. Compose, drafts, send

### 7.1 A draft is local first

The composer edits a row of `intent.sqlite`'s `draft` table — structured fields, not MIME:

```swift
struct MailDraftContent: Equatable, Codable, Sendable {
    var from: String?                      // a send-as address; nil = the account's default
    var to: [MailPerson], cc: [MailPerson], bcc: [MailPerson]
    var subject: String
    var body: MailText                     // what he typed: blocks of styled runs (13.2)
    var signature: MailFragment?           // the identity's signature: sanitised HTML, shown, not edited here
    var quote: MailFragment?               // the quoted original: sanitised HTML, removable, not edited here
    var attachments: [MailDraftAttachment]
}
```

- **The body is text with a small set of styles** — bold, italic, underline, strikethrough,
  links, lists, quotes — edited natively (TextKit; the UX's choice) and turned into HTML by
  `MailTextHTML.serialise` (about 80 lines: `<div> <b> <i> <u> <s> <a> <ul> <ol> <li>
  <blockquote> <br>`, text escaped). There is no HTML editor and no HTML-to-attributed-string
  conversion anywhere (P-4).
- **The signature and the quote are fragments**: HTML that has already been through the
  sanitiser (section 10), kept as it is and placed after the body. They can be removed whole;
  "edit the quote" (`quoteAsText(in:)`) converts it to blocks with
  `MailHTMLPreparer.text(of:)`, losing its design, and says so. **A screen never has to read
  the HTML**: the contract hands each to the composer as a `MailDraftPart` (13.2) — the
  fragment, and the body the engine made by preparing that fragment like any other (10.4),
  native text when it is plain enough and a designed document when it is not. What a designed
  part refers to is served by `resource(_:forDraft:presentation:)`, scoped to that draft: a
  quote's pictures under the rules of the message it quotes; a signature's, which are his own,
  whenever the composer is on screen.
- **A draft written elsewhere** (Gmail's web composer) is opened by preparing its HTML: if
  every element in it is one `MailText` can express, it becomes `body`; otherwise the draft is
  `foreign` — shown, sendable as it is, with "Edit as plain text" (which converts) and "Open in
  Gmail". Nothing is ever silently simplified.
- Attachments are files in `Intent/Attachments/<localDraftID>/`; a forwarded attachment is a
  reference (`forward:<message>:<part>`) resolved when the MIME is built.
- Every change is written within half a second and on every pause, backgrounding and close
  (invariant 9), through the same writer as actions. `ShellState` holds only the local draft
  id.

**Made once and never changed** when a draft is created, in its row (invariant 28):
`rfc_message_id` (`<UUID@the sender's domain>`), `mime_date`, and for a reply or forward the
original's Gmail message id, its thread id, `in_reply_to` and `references_hdr` (from
`ReplyRules.threading`) and the subject. The original may be evicted, trashed or deleted
afterwards; the reply can still be built and still threads.

A new conversation that has not been sent has no Gmail thread; its `MailConversationID.thread`
is `"local:" + localDraftID` until the sent message arrives.

### 7.2 MIME

`MIMEBuilder.build(_ draft: StoredDraft, purpose: MIMEPurpose) -> MIMESource` is pure and
deterministic: the same revision and purpose yield the same bytes (boundaries derive from the
local id and revision), so a hash says whether Gmail has this revision.

```swift
struct MIMESource: Sendable {
    var headers: [(name: String, value: String)]
    var hash: String                       // SHA-256 of the bytes
    var byteCount: Int
    var write: @Sendable (FileHandle) throws -> Void      // streams; attachments are never held in memory whole
}
enum MIMEPurpose: Sendable { case draft, scheduledDraft(at: Date, ownerDeviceID: String), final }
```

- `multipart/alternative` (text/plain derived from the same blocks, then text/html); wrapped in
  `multipart/related` when there are inline images (`Content-ID`); wrapped in `multipart/mixed`
  when there are attachments. UTF-8; quoted-printable for text, base64 for binary (Foundation,
  in 57-byte lines); RFC 2047 for non-ASCII header text; RFC 2231 for file names; header lines
  folded at 78.
- Headers: `From`, `To`, `Cc`, `Bcc`, `Subject`, `Date`, `Message-ID`, `MIME-Version`, and for a
  reply `In-Reply-To` and `References` from the draft row.
- **A header value cannot inject a header (P-13).** Every value is built from typed fields.
  CR, LF and every other control character are removed from names, subjects and file names
  before encoding; an address must pass `MailAddressRules.isValid` (one `@`, no whitespace, no
  angle brackets, no comma or semicolon, a host with a dot) or the draft cannot be sent; a
  display name is RFC 2047-encoded when it is not plain ASCII and quoted otherwise.
- **The final message carries nothing of Banana's.** `purpose: .final` writes no `X-Banana-*`
  header, and the builder fails — the send becomes `failed(.internal)` — if the bytes contain
  `banana-mail:` anywhere (P-2). `.scheduledDraft` adds `X-Banana-Send-At` (RFC 3339) and
  `X-Banana-Send-Owner` (a device UUID and nothing else — no device name; P-16).
- **What a quote carries out (P-16).** The quoted fragment is the *sanitised* original with
  every image the tracker rules of 10.6 would never fetch removed entirely, hidden elements
  removed, and remote pictures kept only as the plain `https` URLs they arrived with. A reply
  drops the original's inline pictures; a forward attaches them again.
- Limit: 35 MiB encoded (DOCUMENTED §6.2), about 25 MB of attachments. `MIMEBuilder.size` is
  checked as attachments are added, and the composer says so then, not at send.
- Verified by golden files: each fixture draft's bytes are committed, and a test-only script
  parses them with Python's `email` package and compares the structure — a second, standard
  reader checks ours.

```swift
enum ReplyRules {
    /// RFC 5322 §3.6.4: In-Reply-To is the parent's Message-ID; References is the parent's
    /// References (or its In-Reply-To, if it has none) followed by its Message-ID.
    static func threading(parentHeaders: [(String, String)]) -> (inReplyTo: String?, references: String?)
    static func subject(for kind: MailDraftKind, original: String) -> String     // one "Re: " / "Fwd: ", never stacked
    static func recipients(for kind: MailDraftKind, original: MessageHeaders, myAddresses: Set<String>) -> Recipients
    /// The identity to send from: the one the original was delivered to, else the account's default.
    static func identity(original: MessageHeaders?, identities: [MailIdentity]) -> MailIdentity?
    /// The quoted original as a fragment (see above), with its attribution line.
    static func quote(prepared: PreparedBody, attribution: String, kind: MailDraftKind) -> MailFragment
}
```

`ReplyRules` is the only owner of reply addressing; `MailSource.newDraft` returns its result
and no screen computes recipients (E-30). A reply threads only when all three hold (DOCUMENTED
§6.3): the conversation's `threadId` on the request, correct `In-Reply-To` and `References`,
and a matching subject.

### 7.3 Drafts in Gmail

A draft appears in Gmail's Drafts on every device because Banana uploads it — **when he has
stopped changing it for 60 seconds, when the app goes to the background, and before a send**;
not while he types (E-31, P-16: unfinished text does not reach Google, his other devices and
a Workspace archive every five seconds). "Stopped for 60 seconds" is how the engine sees a
composer close — a screen has no call to make for it (13.3) — and it also covers a composer
left open and walked away from. It is one sleeper on the clock per open draft, re-armed by
`save`, foreground only. `createDraft` the first time (10 units), `updateDraft` after
(15 units; DOCUMENTED §6.4: each update replaces the message and changes its message id, so a
draft is always known by its *draft* id). Uploads use the incremental lane.

- **A create is never repeated blind (S-20).** `upload_started` is committed before the first
  `createDraft` leaves. Whenever it is set and no draft id is stored, the driver first looks
  for its own draft — `listMessages(query: "rfc822msgid:<Message-ID>", labelIDs: ["DRAFT"])`,
  then the draft id from `drafts` — and adopts it. If that operator does not find drafts
  (UNVERIFIED), it compares `Message-ID` across the newest 20 drafts. Any second draft with the
  same `Message-ID` is this one's duplicate and is deleted.
- **A draft made or edited elsewhere** arrives through sync as a `DRAFT` message. Opening it
  makes a local row linked to it. If Gmail's copy changed and it was not this device's upload
  (`uploaded_msg_id` differs): with no local changes since the last upload, the local row takes
  Gmail's content; with local changes too, the composer keeps the local text and raises the
  question `draftChangedElsewhere` — Keep mine / Use the other. Neither is discarded until he
  chooses.
- **A draft that answers `notFound`** on its next upload was sent or deleted somewhere. The
  driver **asks Gmail, not its own index** (S-18): the Sent check of 7.4 S4, **both steps** —
  the operator, then the newest 20 Sent messages' headers — so an API that does not honour
  `rfc822msgid:` cannot make "sent elsewhere" look like "deleted". Found: the row is retired as
  "Sent from another device", and anything typed here since is kept as a new draft with a new
  `Message-ID`. Not found by either step: the local row stays (invariant 5), a new Gmail draft
  is created for it, and the row is marked `gone_once` — which makes any later send of it run
  the whole Sent check again first (7.4, S1).
- **A draft sent or deleted elsewhere** is also noticed by sync: when a pass deletes a `DRAFT`
  message that a local row was uploaded as, or stores a `SENT` message with a local row's
  `Message-ID`, `DraftRules.reconcile` retires or re-links the row at once, so Drafts does not
  go on listing it.
- The Drafts place merges local rows with synced `DRAFT` messages and hides a synced one whose
  `Message-ID` a local row holds, so no draft is listed twice across an upload.

### 7.4 Sending at most once

There is no server to hold a queue, no idempotency key on any Gmail method (DOCUMENTED §5.2),
and `messages.send` repeats the mail if repeated. What Gmail does offer: **`drafts.send` deletes
the draft it sends** (DOCUMENTED §6.4), so a draft id can be spent once. Everything below is
built on that, and on one rule (invariant 7): **after a send whose result is unknown, the
engine never sends again by itself.**

```swift
enum SendRules {
    enum State: Equatable, Codable {
        case editing
        case held(until: Date)                 // the undo window
        case scheduled(at: Date)               // send later; this device owns it (7.6)
        case uploading                         // making Gmail's draft equal to the final revision
        case ready                             // uploaded_hash == hash(final MIME), draft id known
        case sending(since: Date)              // the request may be on the wire
        case verifying(since: Date, checks: Int)
        case sent(messageID: String, threadID: String)
        case needsDecision(MailQuestion.Kind)  // the person must choose (13.2, 13.3)
        case failed(MailFailure)
    }
    static func next(_ state: State, event: SendEvent, now: Date) -> Transition   // new state + effects to run
    static func afterRelaunch(_ state: State, now: Date) -> State
    /// What an answer to sendDraft means.
    static func classify(_ result: Result<GmailMessage, GmailError>) -> SendAnswer   // .sent, .neverLeft, .refused(…), .unknown, .draftGone
    static func nextCheck(checks: Int) -> TimeInterval?      // 5 s, 30 s, 2 min, 10 min, then nil
}
```

The path: `editing` → `held` → `uploading` → `ready` → `sending` → `sent`.

**S1. Only a `ready` draft is sent.** Ready means Gmail's draft holds exactly the final bytes:
the answer to the last `updateDraft` carried the hash's revision and its message id is stored.
If that message id is no longer the draft's (history showed the draft change, or `gone_once` is
set), the final revision is uploaded again first — what goes is what was on this screen when he
pressed Send (S-36) — and for a `gone_once` draft the Sent check of S4 runs before sending,
both steps; found, the row is retired as sent and nothing goes.

**S2. `sending` is committed, with a full fsync, before the request leaves.** If the process
dies anywhere after, the record says a send may be on the wire.

**S3. What the answer means:**

| Answer to `sendDraft` | Class | Next |
|---|---|---|
| 2xx with a message | sent | `sent`, with Gmail's message and thread ids from the response |
| `neverLeft` | No connection existed; the request cannot have arrived | `ready`; retried by backoff and when the network returns |
| `limited(.sending, …)` — a parsed refusal | Refused | `ready`; retried at Google's retry time, **after a Sent check finds nothing**; the person is told when |
| `unauthorized`, `scopeMissing`, `apiDisabled`, `networkDisabled` | Refused before anything was done | `ready`; waits for the account |
| `refused`, `domainPolicy` | Refused for good | `failed`, shown, the draft intact |
| `notFound` | The draft is gone: **sent by an earlier attempt, sent elsewhere, or deleted** | `verifying` |
| `unknownOutcome`, `server`, `unexplained`, `malformed`, any other `limited` | **Unknown** | `verifying` |

That a parsed sending-limit refusal means "not sent" is ASSUMED (the fake can be switched to
send anyway), which is why its retry is preceded by a check.

**S4. Verifying reads; it never sends.** *The Sent check* has two steps:

1. `listMessages(query: "rfc822msgid:<Message-ID>", labelIDs: ["SENT"])` — 5 units, and it
   needs no thread, so a brand-new message is verified like a reply (S-8). That the API honours
   this operator at all is UNVERIFIED (the fake's `msgidFindsSent` switch runs it both ways).
2. The newest 20 `SENT` messages' headers, compared on `Message-ID` and on
   `X-Google-Original-Message-ID`, in case the operator is blind or Gmail replaced ours
   (UNVERIFIED).

While verifying a send, step 2 runs only on the last check (it costs up to 400 units). Wherever
a "not found" would be followed by *creating or sending something* — 7.3's draft that answered
`notFound`, and S1's `gone_once` draft — **both steps always run**, because there a blind
operator would mean a second copy (S-18).

Found → `sent`. Not found → the next check, at 5 s, 30 s, 2 min and 10 min after the attempt
(Gmail's own lag is reported at 2–5 s by third parties; UNVERIFIED), resumed across a relaunch.
After the last, `needsDecision(.sendUnconfirmed)`: "Banana can't confirm this was sent", with
what is known — whether it is in Sent (no) and whether its draft is still in Gmail — and three
choices: *Check again*, *Send again*, *Keep as a draft*. **That the draft is still in Gmail
never sends it again by itself** (E-4): a read that still sees the draft may simply be behind.
*Send again* is his decision; it spends the same draft id if the draft exists, and otherwise
builds a new draft with the same `Message-ID`, so a receiving system that had the first copy
can recognise the second.

At any later time, a sync pass that stores a `SENT` message whose Gmail id is a local row's
`sent_msg_id`, or whose `Message-ID` is a local row's, moves that row to `sent`, whatever
state it was in — and withdraws the question.

**S5. A relaunch that finds `sending` goes to `verifying`.** It does not send.

**S6. A relaunch that finds `held`, `uploading` or `ready` carries on** — he pressed Send. If
that is more than `lateSendAsks` (24 hours) after he pressed it, it asks first
(`needsDecision(.sendLate)`); otherwise it goes and `MailEvent.sentLate` says since when.

**The lost answer, walked through.** `sendDraft` reaches Gmail, the mail goes, the response
never arrives. `sending` → `unknownOutcome` → `verifying`; the first or second check finds the
`Message-ID` in Sent → `sent`. One request was made. Had the request never arrived, no check
finds it, and after ten minutes he is asked — with "it is not in Sent and the draft is still in
Gmail" in front of him, *Send again* is one tap and is his.

**Two devices.** The same Gmail draft can be open in Banana on two devices. If he sends from
one, the other learns it from sync or from its next upload's `notFound` (7.3). If two devices
call `sendDraft` on one draft id in the same instant, the outcome rests on Gmail spending a
draft atomically — how it must work for the draft to be "deleted when sent", and documented
nowhere under a race (UNVERIFIED; probe W4). For one person it needs Send pressed on two
devices within the same second; it is risk R3, and the reason scheduled sends have one owner.

**A 200 is not delivery.** Gmail can accept a send and enforce a limit minutes later
(DOCUMENTED §5.2). Banana reports "sent" when Gmail says so; a bounce arrives as mail.

**While it is going**, the conversation shows the outgoing message from the local row —
`MailDelivery.sending`, then `.checking` while the Sent check runs — merged at read time (13.7),
not written into the index. Once it is sent the message has no `delivery`. When the real `SENT`
message is stored, the local row is retired: **matched first on the Gmail message id the send
answered with** (`sent_msg_id`), and only if none was ever recorded, on `Message-ID` — so a
`Message-ID` Gmail rewrote cannot show his message twice.

### 7.5 Undo send, and leaving

The undo window (ten seconds by default, D9) is the `held` state: nothing has been sent, so
undo puts the state back to `editing`. Meanwhile the driver uploads the final revision, so the
send itself is one small call when the hold ends.

**One rule on every platform: leaving ends the hold and sends (invariant 27).**

- **iOS and iPadOS, `didEnterBackground`:** the hold ends now and the send runs under a
  background assertion (`MailEnvironment.beginBackgroundWork`).
- **macOS, quit:** `applicationShouldTerminate` asks the engine `hasUnfinishedSends`. If so it
  returns `.terminateLater`; the engine ends every hold and sends; the app replies
  `reply(toApplicationShouldTerminate: true)` when no draft is left in `held`, `uploading`,
  `ready` or `sending`, or after 20 seconds at most. A window says "Sending 1 message…" for
  that time.
- **macOS, sleep:** while a draft is `held`, `uploading` or `sending` the app holds an
  idle-sleep assertion (`ProcessInfo.beginActivity(.idleSystemSleepDisabled)`) — **for at most
  60 seconds per draft, and never for a draft that is `ready` and waiting for the network**: a
  Mac left on a desk with Wi-Fi off must still sleep, and the network's return wakes the
  driver anyway (6.6). On `NSWorkspace.willSleepNotification` (a closed lid) the holds end and
  the sends start in the time the system allows.
- **Whatever was not handed over** — killed, or out of time — is in a durable state and S5 or
  S6 picks it up at the next launch or wake. On every platform a local notification is
  scheduled for ten minutes later, "A message is still waiting to send", and cancelled when it
  goes. A message he pressed Send on is never left unsent without telling him.
- **`cancelSend` answers truthfully, and only once it is durable.** Whether a message can still
  be taken back is decided under one lock, `MailSendGate` — the engine's only lock, held for a
  dictionary lookup: the driver takes it to move a message from `ready` to `sending`;
  `cancelSend` takes it to mark the message as being cancelled, commits `editing` to
  `intent.sqlite`, and then answers `true`. `false` means it has left. If the process dies
  between the press and that commit — a few milliseconds — the stored state is still `held`
  and the message goes at the next launch; no design without a second device can close that.
- **Undo of "Send and Done"** after the hold has ended undoes the Done; the receipt's event
  says the message has gone.
- **Later (P29):** on iOS, hand the final `sendDraft` to a background `URLSession`, which
  finishes it when the network returns even if Banana is suspended. Safe only because a draft
  id can be spent once.

### 7.6 Send later — in the first release, by the owner's ruling (P18b, order 7)

A scheduled message is a Gmail draft, uploaded at once with `purpose: .scheduledDraft`, plus
`scheduled(at:)` on the device where he scheduled it. That device, and only that device, sends
it (invariant 8), until probe W4 shows that two simultaneous sends of one draft yield exactly
one message (D8).

- **Every device can see it is scheduled**: the two headers travel with the draft through
  Gmail. UNVERIFIED: that Gmail keeps unknown headers on a draft. If it drops them, other
  devices see an ordinary draft and nothing else changes.
- **At the time**, the owner reads the draft (`draft(id:format: .header)`). It must still
  exist, still name this device and this time, and its message id must be the one this device
  uploaded. Then the final revision — without the two headers — is uploaded and sent by S1–S6.
  Anything else: it does not send, and says why (`needsDecision(.scheduleChangedElsewhere)`),
  or, if another device has taken over, retires quietly.
- **Late is said, everywhere (S-10, U-4).** `MailDraft.schedule` carries `at`, whether this
  device owns it, and `isLate` — the time has passed by more than five minutes and the draft
  still exists. Every device shows a late message as late: "Scheduled for 8:00 on another
  device — not sent yet", with *Send now from here*. The owner, when it next runs, sends a
  message up to `lateScheduleAsks` (30 minutes) late and says so, and asks about one later than
  that. An owner that was wiped or restored never runs; the other devices' "not sent yet" is
  what tells him.
- **Editing on a device that is not the owner must choose (S-11).** `save` for such a draft is
  refused with the question `scheduleOwnedElsewhere`: *Send from this device instead* (take
  over) or *Cancel the schedule*. It never silently turns a scheduled message into a draft.
- **Taking over** (the answer `sendFromHere` to either schedule question) first asks Gmail whether the draft still exists and whether
  its `Message-ID` is in Sent; then deletes the draft and creates a new one owned by this
  device. The old owner's draft id is dead, so it cannot send.
- **What he will experience when every device is asleep at the time:** the message goes when
  the owning device next runs Banana with a connection — a Mac that is awake, within a minute;
  an iPhone, when iOS next grants background time or he opens it. The composer says which
  applies when he schedules, and the owner schedules a local notification for five minutes
  after the time, cancelled if it has gone.

### 7.7 Identities and signatures

`sendAs` (1 unit, `gmail.modify` suffices — DOCUMENTED §6.5) is read at each handshake and at
most daily into `account.send_as`: address, display name, reply-to, signature HTML, default,
primary, verified. Unverified aliases are not offered. Gmail does not append signatures for API
clients (DOCUMENTED): a new draft takes the identity's signature, sanitised, as its `signature`
fragment, and `changeIdentity(of:to:)` swaps it with the address. Creating aliases and editing signatures stay
in Gmail's settings; `gmail.modify` cannot write them.

## 8. Snooze, reminders and mute

All of it is in the first release, by the owner's ruling (22, M2): snooze and mute in P19a,
"remind me if no reply" in P19b, order 7. They are built on the fake; probe W5 — that hidden
labels behave in Gmail's own apps as assumed — gates the first use on a real account, not
the building (18.10).

### 8.1 Where the state lives

The requirement: every device and Gmail's own apps agree where a conversation is, with no
server, and whichever device is awake can wake it without doing it twice.

**The rule: Banana's per-conversation state is a Gmail label, and every timed change is a
label assertion that any device may make.** A snoozed conversation really is out of the inbox,
in Gmail, for every client. The time it comes back is in a label's name. Waking is "this
message has `INBOX`", the same whether one device says it or three.

Labels are created with `labelListVisibility: labelHide` and `messageListVisibility: hide`.

| Label | On | Means |
|---|---|---|
| `Banana/Snoozed/<yyyyMMdd'T'HHmm'Z'>` | every message of the conversation at the time | Snoozed until that time (UTC, **rounded up to five minutes** — at most 288 labels a day can ever exist) |
| `Banana/Waiting/<yyyyMMdd'T'HHmm'Z'>` | the sent message | Remind me if nobody has replied by then |
| `Banana/Returned` | **exactly the messages that carry the timed label** | It came back, at the time in the label beside it |
| `Banana/Muted` | every message at the time | New replies stay out of the inbox |

A record per conversation in `CloudControlsSync` was considered and not chosen: it makes a
second truth beside the label that actually moves the conversation; it reaches other devices
once a minute and only while they are open, and not at all in the Simulator, in tests, or
without iCloud; and the label version can be tested end to end, two engines against one fake.

### 8.2 The rules

```swift
enum BananaLabelRules {
    static func snoozedName(until: Date) -> String          // rounded up to five minutes, UTC
    static func waitingName(until: Date) -> String
    static func parse(_ labelName: String) -> BananaLabel?   // .snoozed(Date), .waiting(Date), .returned, .muted
    /// What a conversation's labels say about it. With several Snoozed labels, the latest time.
    static func state(_ messages: [MessageFacts]) -> BananaState     // wakeAt, returnedAt, waitingUntil, muted
    /// The assertions that are due for these conversations at `now` (Google's time, 8.3).
    static func due(_ conversations: [[MessageFacts]], myAddresses: Set<String>, now: Date,
                    options: BananaLabelOptions) -> [Assertion]
}
```

`due` produces, and only produces:

1. **Wake.** A conversation has `Snoozed/<t>` with *t* ≤ now, `Returned` on none of its
   messages, and `INBOX` on none: assert `INBOX` present on its **last message that is not a
   draft** and `Returned` present on every message carrying the snooze label (and `UNREAD`
   present on that same message, if that option is on — D10). An unsent reply sitting last in
   the conversation can take no label (6.1); were the wake aimed at it, `Returned` would land,
   `INBOX` would not, and rule 5 would cancel the snooze for good.
2. **Came back early.** `Snoozed/<t>`, `INBOX` present, no `Returned` — a reply arrived, or he
   moved it back in Gmail: assert every `Snoozed/*` absent. The snooze is over.
3. **A reply arrived.** `Waiting/<t>` and a message newer than the labelled one that is not
   from him: assert `Waiting/<t>` absent.
4. **No reply.** `Waiting/<t>` with *t* ≤ now, no reply, no `Returned`: assert `INBOX` and
   `Returned` present on the labelled message.
5. **Left the inbox.** `Returned` present and `INBOX` on none (archived in Gmail's own app):
   assert `Returned`, every `Snoozed/*` and every `Waiting/*` absent.
6. **Muted.** A message has `INBOX`, its conversation has `Banana/Muted` on an earlier message,
   and `MuteRules.staysOut(message, myAddresses)` holds (he is not the only direct recipient):
   assert `INBOX` absent and `Banana/Muted` present on it.

**What keeps a conversation from returning twice (E-5).**

- `Returned` and the timed label are always added and removed **together, per message, in one
  request** — they are on the same messages, so they fall in the same `modify`. No device can
  read a message that has one without the other.
- **Any change of his that takes a conversation out of the inbox** — done, trash, spam, move,
  snooze again — also asserts `Returned`, every `Snoozed/*` and every `Waiting/*` absent on
  its messages (snooze then adds its new label). After he has dealt with a returned
  conversation, nothing of the snooze is left to fire.
- A snooze asserts every *other* `Snoozed/*` absent, so two devices that snoozed the same
  conversation offline to different times converge on the later one.
- Every one of these six is a desired end state, so two devices producing the same one is one
  change, and **each is derived again on fresh state before it is delivered** (8.3): a device
  with a stale cache may show a wake for a moment, but cannot send one.

The snooze change itself: assert `Snoozed/<t>` present and `INBOX` absent on the conversation's
messages that are not drafts. Offline, the label may not exist yet; the assertion names it by
name, the index gets a `local:` label row so the Snoozed list works at once, and delivery
creates it (6.5). Un-snooze asserts the label absent and `INBOX` present.

**The janitor**, in the weekly reconcile: for each `Banana/Snoozed/*` and `Banana/Waiting/*`
label whose time is more than a day past, `label(id:)`; delete the label only if **Gmail's**
`messagesTotal` is 0 (S-25). Local absence is not evidence.

### 8.3 When the rules run, and on whose clock

- **After every successful sync pass**, on what that pass left, and then **again immediately
  before delivery** (6.5 step 1): every undelivered assertion with `origin = rule` for that
  account is deleted and `due` is run afresh. What it no longer produces is gone (invariant
  24). This is what stops a wake computed before the pass — on a cache that did not yet know
  the conversation had been woken and archived elsewhere — from being sent.
- **Two gates stand between a derived assertion and Gmail, and both must hold** (S-7):
  1. *The pass just made succeeded, and Google's clock is known* (below).
  2. *No enumeration is unfinished for the account*: `enum_state` is `NULL` and no row of its
     last generation is waiting in `verify_queue`. A succeeded pass is not a fresh cache.
     After history has expired, the handshake stores a new position and the very next poll
     succeeds with nothing to report — while the listing of `Banana/Returned`, and the reads
     that would show a snooze label gone, are still minutes away in the backfill lane. Until
     that enumeration has closed and its reads have answered, a device may show a wake and may
     not send one.
- **At launch and on a real return to the foreground, before the network**, so a conversation
  due while every device slept is back in the inbox the instant Banana opens. Those assertions
  are shown through the overlay and are not delivered until both gates hold and they have
  been derived again.
- On a sleeping task for the soonest wake, foreground only; and in the iOS background refresh,
  after its pass.

**The clock is Google's (E-39, S-23).** Every Gmail response carries a `Date` header; the
transport keeps the difference between it and the device's clock. `due` is given
`deviceNow + offset` when an offset newer than 24 hours exists. Without one — offline since
launch — it runs on the device's clock, and its assertions are only shown; before anything is
delivered a pass has succeeded, an offset exists, no enumeration is unfinished, and the rules
have run again. A phone whose
clock is a day fast cannot wake his snoozes in Gmail.

Each device also schedules a local notification for each wake time it knows of ("Back in your
inbox", id `banana.mail.wake.<hash>`), which fires on time whether or not Banana is running,
and removes it when the wake has happened or the snooze has gone (12.3 for what it shows).

**What he will experience:** on any device that is awake, a snoozed conversation returns within
the poll interval of its time, everywhere, Gmail's apps included. If every device is asleep,
the notification still arrives on time; the conversation itself returns when a device next
runs Banana. Gmail's own apps show it archived until then. In Gmail's apps a returned
conversation sits at its original date; in Banana it sorts at the time it was due.

Muting is weaker than Gmail's own: a reply to a muted conversation is in the inbox, in Gmail's
apps, until some Banana device archives it. Gmail's mute is not in the API (UNVERIFIED).

### 8.4 If the labels are tampered with

Deleting `Banana/Snoozed/…` in Gmail's settings removes it from its messages: the conversation
stays archived and never wakes. Deleting a label is his action and is respected. Nothing else
depends on Banana's labels being intact.

### 8.5 What does use `CloudControlsSync`

Things he edits as lists, one record each, newest edit wins, deletes as tombstones:

| State | Kind |
|---|---|
| Split inboxes (name, query, order) | new `ControlKind.mailSplit`, one record per split |
| "Always show pictures" for a sender or a domain | new `ControlKind.mailSender`, one record per **rule** (10.6): its key is `a:<address>` for a sender and `d:<domain>` for a domain |

Scalar preferences (undo-send seconds, which accounts have Mail on, "always show pictures"
for everyone, "block tracking pixels") are optional fields of `AppSettings.Snapshot`. **The
sync limit is not among them: it is per device** (5.4), in `intent.sqlite`'s `meta`. Where he is in mail is `ShellNavigation`, per device. Nothing here
needs a new CloudKit record type or zone.

## 9. Search

### 9.1 One language, one tokenizer, three uses

A query is read once, by a pure parser, into a small tree. The same tree searches the local
index, is sent to Gmail when the local copy is not complete, and decides which conversations
belong to a split inbox. The parser's tokenizer is the only one: it returns each token with its
range in the typed text, which is what the search field needs for chips and highlighting, so
the UI has no tokenizer of its own (reuse B-10).

```swift
indirect enum MailQuery: Equatable, Codable, Sendable {
    case text(String, prefix: Bool)             // a word; prefix = still being typed
    case phrase(String)                         // "in quotes"
    case field(Field, MailQuery)                // from: to: cc: subject: filename:
    case label(String), system(MailMailbox)     // label:x  in:inbox  category:updates
    case flag(Flag)                             // is:unread is:starred is:important has:attachment is:snoozed is:muted
    case date(DateBound, Date)                  // before: after: older_than: newer_than:
    case list(String)                           // list:
    case account(String)
    case not(MailQuery), and([MailQuery]), or([MailQuery])
}
struct MailQueryToken: Equatable, Sendable {    // declared in MailContract.swift
    var range: Range<Int>                       // UTF-16 offsets in the typed text
    var kind: Kind                              // .word, .phrase, .operatorName(String), .value, .negation, .unknownOperator
}
enum MailQueryRules {
    static func tokens(_ text: String) -> [MailQueryToken]
    static func parse(_ text: String, now: Date, typing: Bool) -> MailQuery
    /// The FTS5 MATCH expression and the SQL conditions on `message`, or nil if nothing textual.
    static func local(_ query: MailQuery) -> LocalSearchPlan
    /// Gmail's `q`, with dates as epoch seconds (DOCUMENTED §11: bare dates mean midnight PST).
    static func gmail(_ query: MailQuery) -> String
    /// Whether one conversation matches — for splits. No text search here: fields and flags only.
    static func matches(_ query: MailQuery, conversation: [MessageFacts], myAddresses: Set<String>) -> Bool
}
```

The syntax is Gmail's, for the operators listed. An operator Banana does not know is passed to
Gmail as typed and matched locally as plain words. Words are escaped for FTS5 by one function
(`MailQueryRules.ftsQuoted`): doubled quotes inside quotes, nothing else interpreted — a typed
`"`, `*`, `^`, `:` or `NEAR` can never become FTS5 syntax.

### 9.2 Local search

Search is a place like any other: `observeList(MailScope(place: .search(text), …))` (13.3). It
runs on its own read-only connection to `search.sqlite` with `index.sqlite` and `blobs.sqlite`
attached, so cancelling it can never cancel a list read (4.2). **The index covers what the
device holds** — under a sync limit, the conversations of 5.4 — and that is what this
subsection searches; 9.4 is where Gmail's answer joins it.

```sql
SELECT m.thread_pk, m.msg_pk
FROM msg_fts f JOIN idx.message m ON m.fts_rowid = f.rowid
WHERE f.msg_fts MATCH ?1 AND m.vis = 0 /* plus the plan's conditions */
ORDER BY f.rowid DESC
LIMIT 400;
```

Read row by row, stopping at 50 distinct conversations; more are read as the list grows.
Results are conversations, newest matching message first. **There is no relevance ranking**, and
a test asserts that no SQL string in the engine contains `rank` (R-19: ranking a common word
costs 764 ms, MEASURED, and would spill a temporary table into memory). Numbers are
in 4.6.

- A query runs once it has two characters, **at once, with no debounce**; the query it
  supersedes is interrupted (`DatabaseQueue.interrupt()` on the search reader — MEASURED: it
  ends in 1.5 ms), so at most one runs.
- The word being typed matches as a prefix; finished words match whole.
- A query with no text (only `from:`, `is:`, a label) reads `message` and `view_thread`.
- Trash and spam are left out unless the query names them.
- A result's snippet is the excerpt around the first match. The index is contentless, so the
  excerpt is cut from `blobs.prepared.text` — the prepared body's own text (4.7), inflated for
  the rows being returned and for no others. A message with no prepared row yet, one at
  header level, shows Gmail's own `snippet` from the index instead. (This line once named
  `content.text`, a column 4.7 does not have.) The two attached files are `idx` and `blobs`
  (`MailStores.attachedIndexName`, `attachedBlobsName`).
- A search list delivers at most twice per query: what the device has, then what Gmail added.
  Its `total` is `MailCount(value:isAtLeast:)` — "at least 50" until the scan ends.
- Every command works on search results, including `MailTarget.scope` for a search scope,
  which the writer resolves from the same plan.
- The typed text is never written to `ShellState`, the journal or `UserDefaults` (P-20).

### 9.3 Splits are saved queries, kept as views

A split inbox is a name and a query (`MailSplit`), synced as one record each (8.5). Its
membership is maintained when conversations change, by `ViewMembershipRules` calling
`MailQueryRules.matches`, so reading a split costs exactly what reading the inbox does (4.4).
A split's query may use fields, flags, labels, categories, lists and accounts — not free text,
which would need the index at write time. Its scope is the inbox.

**An inbox conversation is in exactly one split**: the first, in matching order, whose query it
satisfies; the last split has no query and takes what is left. **The order shown** is the order
of `MailPlaces.splits`, and of the array given to `saveSplits`. **Matching order is the
engine's and is not a field**: custom splits in the order shown, then Calendar, then
Important, then Other (MAIL-UX 2.3). The built-in three are the engine's rules, with `query`
nil: Calendar is "has an invitation", Important is "has `IMPORTANT`", Other is the rest; they
are pure functions in P05, so both sources have them from order 1. The split counts therefore
add up to the inbox's.

When a split is added or its query changes, `definition_rev` rises and a paced background pass
re-evaluates the inbox's conversations (thousands, not hundreds of thousands) and the writer
replaces that view's rows in batches; until `built_rev` catches up the list reports
`isRebuilding`.

### 9.4 One search, two places: the device and Gmail

**The owner's ruling: when the sync limit is not "everything", a search asks the device and
Gmail together, and the results are one list.** A device that holds six months cannot answer
for the rest, and he should not have to know which half a message is in.

**When Gmail is asked.** Without being told to, for a `.search` scope with text, whenever the
device's copy does not cover the mailbox: the limit is not "everything", or it is and the
account is not complete yet. Under "everything", complete, Gmail is not asked unless he asks
(`askGmail`, below) — the index has it all, and Gmail's search can still find what the index
leaves out (an attachment's contents, quoted text; UNVERIFIED).

**The latency rule.** The device answers at once — at two characters, with no debounce (9.2)
— and that answer is the list. Gmail is asked **400 ms after the text stops changing**, in
the interactive lane, and its rows join when they arrive. **Nothing already in the list moves
when they do**: they are added below.

**The merge.**

- **Identity** is the conversation: account and thread id. Gmail's API matches messages
  (DOCUMENTED §11); its results are grouped by thread, and a conversation counts once.
- **Two groups, and group is by who found it.** What the device's own index matched is
  group 0, in date order, shown at once. What only Gmail matched is group 1, in Gmail's
  order — newest first — below. `MailOrderKey.group` already says this, and
  `MailRow.fromGmailSearch` marks the row. When the device's copy is complete to its edge
  the two groups are also, very nearly, one date order: what only Gmail finds is what is
  older than the edge. Where they are not — a first sync still running; a held conversation
  that only Gmail matched, by an attachment's text — the row still joins below, because
  date order bought by moving rows under his cursor is not worth it.
- **De-duplication.** A conversation Gmail returns that group 0 already has is dropped. One
  that the device holds but its own index did not match joins group 1 like any other of
  Gmail's, and opening it fetches nothing.
- **A row only Gmail found is not stored.** For each such conversation the newest matching
  message is read at `header` level (20 units) and the row is made from that read alone:
  its sender (by `MessageHeaders.sender`, 10.8), subject, date, Gmail's snippet, and the
  flags its labels give. `messageCount` and `peopleTotal` are of what matched, not of the
  conversation, and `isOnDevice` is false (13.10). These rows live in the search's feed, in
  memory, for as long as that search is observed; the header reads are kept for the session
  (at most 500), so a query typed again costs one listing. **Nothing of them goes into a
  store** — a header of a conversation the device does not hold would be exactly the
  half-known row invariant 34 forbids, and would turn up in other lists at a date years back.
- **Opening one holds it.** `wants` — the pane following the cursor, or an open — fetches the
  conversation whole (`thread`, `full`: 40 units, interactive lane), stores it, and marks it
  attended: it is now held like any conversation he looked at today, for the length of the
  limit, and is released after that unless he looks again (5.4). The row stays where it was,
  now `isOnDevice`.
- **A change needs the conversation.** `apply` to a conversation the device does not hold
  answers `count` 0 and shows nothing (13.3: "nothing was changed"); a screen offers its
  actions on such a row once it is on the device, which for the row under the cursor is a
  moment after the cursor rests. A `.scope` target over a search covers the conversations
  the device holds.

**Cost, and cancelling as he types.** A settled query is one `listMessages(query:,
maxResults: 50)` — 5 units — and `header` reads for the first ten conversations only Gmail
found — at most 200 units; the rest are read as the list grows into them. Every change to
the text cancels the request and the reads in flight for the text before it (their task is
cancelled, and with it the connection); reads that had already answered stay in the session's
cache. Nothing is asked for a query of fewer than two characters, for a query with no text,
or while the 400 ms run.

**Offline, and when Gmail does not answer.** The device's results are the list.
`MailListSnapshot.remote` says `.offline`, or `.failed`, and the list's foot says in words
what was and was not searched: "On this Mac: mail since 6 April. Gmail was not searched —
offline." A row only Gmail found cannot be opened offline; it is not on the device, and it is
gone from the list when the search ends.

**`askGmail(_:)` — the explicit call, generalised** (it was `searchGmail`; 13.10). It asks
Gmail for what a list does not hold:

- for a `.search` scope: Gmail's matches — again after `.failed` or `.offline`, the next
  fifty after `.done(added:more: true)`, or for the first time where the engine did not ask
  (a device that holds everything);
- **for any other place: its mail older than the edge.** A list under a sync limit ends at
  the edge, says so (`heldSince`), and offers "Older mail in Gmail": `askGmail` lists that
  place in Gmail before the edge (`listMessages(labelIDs:, query: "before:<seconds>")`) and
  the rows join below as group 1, exactly as a search's do — not stored, held when opened.
  A place is never asked about without that call: opening the inbox costs Gmail nothing.

Gmail's search differs from the local one: it does not expand aliases, and its API form matches
messages, not conversations (DOCUMENTED §11). It may also match attachment contents and quoted
text, which the local index leaves out (UNVERIFIED; the probe checks).

### 9.5 Recipients

`correspondent` counts, per address, how often he wrote to it and it wrote to him, updated as
each message is stored (From, To, Cc; mail from himself counts as "sent"). `correspondent_key`
indexes each name word, the address and its domain.

```sql
SELECT c.addr, c.name, c.sent, c.received, c.last_date
FROM correspondent_key k JOIN correspondent c ON c.addr = k.addr
WHERE k.key >= ?1 AND k.key < ?2          -- prefix and prefix + U+10FFFF
ORDER BY c.sent DESC, c.last_date DESC LIMIT 8;
```

MEASURED over 30,000 addresses: 1.2 ms p50, 3.0 ms p95. `RecipientRules.merge`
then folds in `GuestSources.people()` — calendar guests and Contacts, already ranked by
`GuestDirectory` — preferring people he has written to, then people he meets. No Google People
API and no extra scope.

Rules against a poisoned list (P-13): a name is taken into `correspondent` only from mail he
*sent*, or from received mail whose sender domain is authenticated (10.6); an address he has
never written to is offered below every address he has, is shown by address rather than name,
and is marked `fromTheirMail`; and an entry whose name equals the name of someone he has written
to at a different address is not offered at all.

## 10. HTML

Mail is the app's first web view, and the content is hostile by default: the API hands over
whatever the sender wrote (DOCUMENTED §14.16).

### 10.1 Two layers, both required

**Preparation** (Banana's code, pure, off the main thread) turns the HTML into something inert.
**The web view's configuration** refuses everything preparation is meant to have removed. A
mail client that relies on one of them is one bug from loading a tracking pixel or running a
script.

### 10.2 When: once, when the message is fetched

Preparation is not cheap. The first draft measured a byte scan that was not a sanitiser
(0.19 ms for a 63 KB newsletter) and prepared at open. Measured properly — parse, allow-list
walk, serialise, text — on the two fixture newsletters (MEASURED, load 13):

| | 63 KB | 261 KB | Throughput |
|---|---|---|---|
| SwiftSoup, parse only | 2.6 ms | 10.9 ms | 22.7 MB/s |
| **SwiftSoup, prepare** | **15.4 ms** p50, 16.7 p95 | **64.9 ms** p50, 75.6 p95 | 3.9 MB/s |
| libxml2 (system), parse only | 0.94 ms | 3.9 ms | 64 MB/s |
| libxml2, prepare | 4.3 ms p50, 4.6 p95 | 17.6 ms p50, 18.9 p95 | 14.1 MB/s |

Eighty times the number the first design rested on, before a phone's slower core. So:

- **A message is prepared when it is fetched**, by `MailPrepareQueue`, newest first, paced
  (4.12). Opening a conversation reads prepared output and does no HTML work at all.
- **One parse yields everything**: the sanitised fragment; the message's own text, for search
  and snippets; the body's kind; every picture's box, so layout does not jump when pictures
  arrive; the quote boundary; and, when the message is plain enough, the native text.
- A message opened before its turn (just arrived, or its body just fetched because he tapped
  it) is prepared at once, ahead of the queue, off the main thread; the reader shows the
  message's header and a placeholder of the right kind for those milliseconds.
- **Raising `MailHTMLPreparer.version` re-prepares lazily**: on open, and by the paced queue
  behind new mail. **A row prepared by an older version is never shown** (N-4): on open it is
  treated exactly as an unprepared message — prepared ahead of the queue, behind the
  placeholder — and is not handed to `MailDocument` or the native reader. A sanitiser fix
  takes effect at the moment of opening, not when the queue gets there. At full speed 200,000 messages would be about 25 minutes of one core with
  SwiftSoup (ASSUMED 30 KB of HTML each); paced on a phone it is days, which is why nothing
  waits for it.
- Warming and preparing fetch nothing remote (invariant 30).

### 10.3 The parser, behind one seam

A real HTML parser builds the tree: **SwiftSoup** (2.13.9, exact pin), a Swift port of jsoup's
WHATWG tree builder. It is slower than libxml2 but it is memory-safe Swift fed with hostile
input, and it parses as browsers do; libxml2's HTML parser is HTML 4 in C. One file imports it.

```swift
/// The only door to an HTML parser. `MailHTMLSwiftSoup.swift` is the one file that imports
/// SwiftSoup; a libxml2 implementation lives in the test target as a second opinion (17.1) and
/// can replace it by changing one line.
protocol MailHTMLSource {
    /// Parse as a browser would and walk the body in document order.
    static func walk(_ html: String, limits: MailHTMLLimits, visitor: inout some MailHTMLVisitor) throws
}
protocol MailHTMLVisitor {
    /// Names are lower-cased; attribute values are entity-decoded. Return false to skip the subtree.
    mutating func open(_ name: String, attributes: [(name: String, value: String)]) -> Bool
    mutating func text(_ text: String)
    mutating func close(_ name: String)
}
struct MailHTMLLimits: Sendable {
    // Checked on the bytes, before any parser sees them (MailHTMLBound):
    var maxBytes = 2_000_000, maxStartTags = 100_000
    var maxFormattingStartTags = 3_000, maxTableStartTags = 1_500
    // Enforced by the walk:
    var maxDepth = 200
    var maxAttributes = 64, maxAttributeBytes = 4_096, maxStyleBytes = 32_768
    var maxPictures = 500
}
enum MailHTMLBound {
    /// One pass over the bytes. Counts things that look like start tags, outside comments,
    /// and gives **no credit for end tags** — so it can over-count nesting and never under-count.
    static func scan(_ html: String.UTF8View) -> (startTags: Int, formatting: Int, tables: Int)
}
```

**The tree is bounded before it exists** (N-6). SwiftSoup builds the whole tree before any
visitor of ours runs, so a limit applied by the visitor is too late for whatever the *parser*
does with a hostile shape. MEASURED on a secondary thread with a 512 KB stack — the kind the
prepare queue and a background task run on (`spikes/deep/`, 21):

| Input | SwiftSoup 2.13.9 |
|---|---|
| `<div>` or `<span>` nested 100,000 deep (500 KB) | Parse, an iterative walk and releasing the tree all complete; 0.12–0.16 s. **No stack overflow.** |
| `<b>` nested 3,000 / 10,000 / 30,000 deep (9 / 30 / 90 KB) | 0.41 s / 4.9 s / 54 s — **quadratic**; `<font>` and `<i>` the same; 100,000 took about five minutes |
| `<table><tr><td>` nested 3,000 / 10,000 deep (48 / 160 KB) | 2.0 s / 44 s — quadratic |
| `<a>` nested 30,000 deep | 0.10 s (each closes the last) |

So depth by itself does not crash this parser, and the real danger is one the review did not
name: a 90 KB message of unclosed formatting tags costs a minute of CPU, and nothing can stop
a parse once it has begun. Therefore:

- **`MailHTMLBound.scan` runs first**, on the bytes: 0.5 ms for 500 KB (MEASURED). Over 2 MB,
  over 100,000 start tags, over 3,000 start tags of the formatting elements (`b big code em
  font i nobr s small strike strong tt u`), or over 1,500 `<table` start tags → **the HTML is
  never handed to a parser**; the message is shown as text from its plain part, with the
  notice `tooLarge` or `shownAsText`. At the bounds the worst case is about a second of parse.
  The bound gives no credit for end tags because any scan that did could be fooled by an end
  tag inside a comment, a script or an attribute; the price is that a very large, heavily
  styled but honest message may be shown as text. The two numbers are ASSUMED to clear
  ordinary mail: the probe (19.2 item 4) and the first Mac fill count how many messages each
  bound refuses, and they are raised, at a known price in worst-case seconds, if newsletters
  he reads are among them.
- **The walk is iterative.** `MailHTMLSwiftSoup` calls `SwiftSoup.parse` and walks with
  `NodeTraversor` (a loop, not recursion — MEASURED above at 100,000 deep) and calls nothing
  else of SwiftSoup's. The sanitiser, the text builder and the serialiser are driven by
  `open`/`text`/`close` events and keep their own explicit stacks; no function in mail's HTML
  code calls itself. A source delivers events only down to `maxDepth` (200): below it the
  subtree is skipped — not flattened — and the notice is `truncated`.
- **SwiftSoup's own serialisers and cleaner are forbidden**: `.outerHtml(`, `.html()`,
  `Cleaner(`, `Whitelist` and `Safelist` are tokens the static test of 10.4 refuses in every
  mail folder (the reuse review found `Cleaner` leaves `<` and `>` unescaped in attribute
  values).
- **The libxml2 source behaves the same at its limit.** It runs the same `MailHTMLBound`
  first, parses with `HTML_PARSE_RECOVER | HTML_PARSE_NONET | HTML_PARSE_HUGE`, walks
  iteratively, and stops at the same `maxDepth` — 200, below libxml2's own 255, so the two
  sources never disagree about where a deep document ends.
- Tests run each of `nested-100k-divs`, `nested-100k-inline`, `nested-30k-bold` and
  `nested-10k-tables` on a thread created with a 512 KB stack: the first two are prepared and
  cut at depth 200; the last two are refused by the bound in under 5 ms and no parser is
  called (a counting source).

- **Output is serialised, never spliced.** The sanitiser is a visitor that writes a new
  document from the events it accepts: every text node escaped (`& < > " '`; U+0000 becomes
  U+FFFD), every attribute value re-quoted, no comment, no DOCTYPE, no raw-text element. No
  substring of the input reaches the output unescaped.
- **Limits inside the walk.** Beyond 64 attributes on an element, 4 KB in an attribute value,
  32 KB of style in a message or 500 pictures, the excess is dropped and the notice is
  `truncated`.
- **If the parser crashes the process all the same**, the message that was being parsed is known: the queue
  sets `prep_state = 1` before parsing and `2` after. A row found at 1 at launch is set to 3 —
  shown as text from Gmail's snippet and plain part, never parsed again by that
  `MailHTMLPreparer.version` — and journalled. One hostile message cannot crash Mail twice.

### 10.4 What preparation produces

```swift
enum MailHTMLPreparer {
    static let version = 1
    static func prepare(html: String?, plain: String?, context: PrepareContext) -> PreparedBody
    /// A fragment's text as blocks — for "edit the quote" (7.1) and "Edit as plain text".
    static func text(of fragment: MailFragment) -> MailText
}
struct PrepareContext: Sendable {
    var messageKey: String                  // opaque; goes into banana-mail://cid/<messageKey>/…
    var inlineParts: [String: String]       // Content-ID → part key, for THIS message only
    var trackers: MailTrackerList
}
struct PreparedBody: Equatable, Codable, Sendable {
    var kind: MailBodyKind                  // .text, .designed, .tooLarge, .unparsed
    var fragment: String                    // sanitised HTML, safe inside Banana's wrapper; "" unless .designed/.text
    var native: MailText?                   // set when kind == .text
    var ownText: String                     // his correspondent's own words: quotes stripped, 16,000 characters at most
    var quoteStartsAt: Int?                 // block index (native) and marked in the fragment
    var pictures: [MailPicture]             // remote and inline: key, declared width and height, isTracker
    var remoteSources: [String: String]     // remote key → the original https URL. Never leaves the engine.
    var trackersRemoved: Int
    var trackerListVersion: Int             // the list that prepared it (N-2)
    var links: [String: MailLinkFacts]      // href → what the reader was shown for it (10.7)
    var notices: [MailBodyNotice]           // .tooLarge, .truncated, .shownAsText
    var version: Int
}
struct MailLinkFacts: Equatable, Codable, Sendable { var shownText: String; var isImage: Bool }
```

**Kind.** `.text` when every element is one `MailText` can express — paragraphs, line breaks,
emphasis, links, lists, quotes — and there is no picture, no table and no colour or font of the
sender's own; the reader draws it natively. Otherwise `.designed`, drawn in a web view. Most
person-to-person mail is `.text`; newsletters and receipts are `.designed`.

**The allow-list is the contract** — adopted whole from the security review; `MailHTMLRules`
holds it as data and its tests are generated from this text.

*Elements kept* (everything else is dropped and its content kept, unless listed below):
`a abbr b bdi bdo blockquote br caption center cite code col colgroup dd del dfn div dl dt em
figcaption figure font h1–h6 hr i img ins kbd li mark ol p pre q s samp small span strike
strong sub sup table tbody td tfoot th thead tr tt u ul var wbr`; plus `details` and `summary`
only as Banana's own quote fold (a sender's are unwrapped).

*Dropped with everything inside:* `script style iframe frame frameset object embed applet svg
math template head title base link meta noembed noframes xmp plaintext canvas audio video source
track map area form input button select option textarea label fieldset legend datalist output
progress meter dialog menu slot portal`. `picture` keeps its `img` and drops its `source`s.
`noscript` is unwrapped — scripting is off, so its children are content, and a pixel inside it
is classified like any other. Comments, CDATA, processing instructions and DOCTYPE are dropped.

*Attributes kept.* Globally: `lang`, `dir` (`ltr`, `rtl`, `auto`), `title` (cleaned, 10.8),
`aria-hidden`. Everything else is dropped — every `on…`, `id`, `class`, `tabindex`,
`contenteditable`, `draggable`, `is`, `slot`, `part`, `xmlns`, `xml:*`, `xlink:*`, other
`aria-*`, `role`; `hidden` becomes `display:none` through the CSS filter. Per element:

- `a`: `href` — `http`, `https`, `mailto` only, absolute, no userinfo; `title`.
- `img`: `src` (rewritten, below, or the element is dropped), `alt`, `width`, `height`
  (integers up to 2,000; percentages up to 100 %; anything else is dropped and the picture is
  `auto` with `max-width: 100%`), `align`, `border`, `hspace`, `vspace`; `srcset` → its first
  candidate only, rewritten, else dropped. A picture gets a box (10.5 item 2) only when both
  dimensions were declared within those bounds. At most 500 pictures a message; the rest are
  dropped with `truncated` (N-5; fixture `pictures-10000x10000-x1000`).
- `table td th tr col colgroup`: `width height align valign bgcolor border cellpadding
  cellspacing nowrap`, `colspan` and `rowspan` up to 100; `background` rewritten like `src` or
  dropped.
- `ol`: `start type reversed`; `li`: `value`; `font`: `color face size`; `hr`: `width size
  align`.
- `style` on a kept element: through the CSS filter, re-serialised.

*URLs — the rewriter is total (P-2).* Every URL-bearing attribute and every CSS `url()` is
resolved after entity decoding, removal of C0 controls, tabs, newlines and surrounding
whitespace, with the scheme compared case-insensitively and `URLComponents` required to parse
it. Then exactly one of:

- `cid:x`, where `x` is in `context.inlineParts` → `banana-mail://cid/<messageKey>/<partKey>`.
  Both sides are compared after one normalisation — angle brackets and surrounding whitespace
  stripped, percent-decoded once, case-folded; a miss removes the picture;
- `http://…` or `https://…` → `banana-mail://remote/<sha256 of the URL>`, the URL recorded in
  `remoteSources`;
- `data:image/(png|jpeg|gif|webp);base64,…` up to 256 KB → kept;
- **anything else is removed**: relative and scheme-relative URLs, unknown schemes, `tel`,
  `sms`, `javascript`, `vbscript`, `blob`, `file`, `about`, other `data:`, SVG images — and
  `banana` and `banana-mail` themselves. **`banana-mail:` is write-only**: no URL of that scheme
  appears in the output unless this function generated it from a `cid:` or `http(s):` URL of
  this message, and a test asserts it over every fixture.

*CSS — a filter of our own, the smallest that works* (nothing standard fits; reuse B-7). The
first release filters **declarations in `style` attributes** with a CSS Syntax Level 3
tokenizer (comments, strings, escapes such as `\75 rl(`), re-serialising values from tokens.
`<style>` blocks are dropped whole; rules from blocks (class selectors and `@media` with width
and colour-scheme queries, the only at-rule that will ever be kept) are a later package with
the same property list. Kept: `background-color`, `background` (colour only), `border` and
`border-*` (width, style, colour, radius), `box-sizing`, `clear`, `color`, `direction`,
`display` (`block inline inline-block table* flex none list-item`), `float`, `font`,
`font-family`, `font-size` (6–96 px), `font-style`, `font-variant`, `font-weight`, `height`,
`letter-spacing`, `line-height`, `list-style-type`, `list-style-position`, `margin*` (±10,000
px), `max-height`, `max-width`, `min-height`, `min-width`, `opacity`, `overflow`,
`overflow-wrap`, `padding*`, `position` (`static relative absolute`), `top right bottom left`
(clamped), `table-layout`, `text-align`, `text-decoration`, `text-indent`, `text-overflow`,
`text-transform`, `unicode-bidi` (`normal embed isolate`), `vertical-align`, `visibility`,
`white-space`, `width`, `word-break`, `word-spacing`, `z-index` (0–1,000). `!important` is
stripped. Dropped: every declaration containing `url(`, `image-set(`, `var(`, `attr(`, `env(`,
`element(`, `cross-fade(`, `src(` or `expression(`; `animation*`, `transition*`, `transform*`,
`filter`, `backdrop-filter`, `mix-blend-mode`, `clip-path`, `mask*`, `content`, `cursor`,
`pointer-events`, `user-select`, `will-change`, `appearance`, `resize`, `behavior`, `binding`,
`position: fixed|sticky`, every vendor-prefixed property, and every at-rule.

**Trackers.** An image declared 2 px or less in either dimension, or hidden by its own style,
or on a host in the vendored list is **marked as a tracker and counted** (`MailPicture.isTracker`).
It is not removed from the prepared document: whether it is fetched is decided when it is
asked for (10.6), and while "Block tracking pixels" is on — which it is unless he turns it
off — the answer is never, at every level of the picture setting.
The list is `Banana/Resources/MailTrackers.json`, extracted from the MailTrackerBlocker
project (`apparition47/MailTrackerBlocker`) by `tools/update-tracker-list.sh`, which writes
the source commit, the date and a `version` number into the file — that script is the update
path, run by hand. The project's licence is read from the vendored copy when it is vendored
(believed BSD-3-Clause; not assumed), ships beside the list, and its notice must appear in
Settings › About › Acknowledgements, which a binary distribution requires. **The list is
consulted twice** (N-2): at prepare time, and again by `RemoteImageRules` at the moment a
picture would be fetched, against the list as it is *then* — so a host listed after a message
was prepared is still never fetched. `PreparedBody.trackerListVersion` records which list
prepared it.

**Quoted text** is detected (`blockquote[type=cite]`, Gmail's `gmail_quote`, Outlook's reply
header block, an "On … wrote:" line before a blockquote, a run of `>` lines in plain text) and
wrapped in `<details class="banana-quote">`, which folds with no script; the native form
carries `quoteStartsAt`.

**Plain-text mail** becomes `MailText` directly. Links are made only from `https?://…` and
`mailto:` tokens and bare `www.` hosts, with the shown text equal to the URL. `NSDataDetector`
is not used: phone numbers, addresses and dates in mail are text.

**Forbidden in mail code**, and enforced by a test that greps `Banana/Model/Mail/`,
`Banana/Model/MailApp/`, `Banana/Model/MailUI/` and `Banana/Views/Mail/`:
`NSAttributedString(html`, `.documentType`, `AttributedString(markdown`, `NSDataDetector`,
`NSWorkspace.shared.open(` and `UIApplication.shared.open(` on anything but a URL that
`MailLinkRules` returned; SwiftSoup's `.outerHtml(`, `.html()`, `Cleaner(`, `Whitelist` and
`Safelist` (10.3); and — outside `MailFiles.swift` — `copyItem(`, `moveItem(`, `createFile(`
and `.write(to:` (11.2). The first loads remote content and spins a run loop on the main
thread (the lesson already recorded in `ShowNotes.swift`); the second parses a sender's text as
markup.

**Dark mode.** A `.text` message follows the system appearance. A `.designed` one is drawn as
its sender designed it, on a light card; "dark anyway" applies a CSS inversion with images
re-inverted, no script.

### 10.5 The document and the web view: the contract

The reader shows one `.designed` message per web view. `MailDocument.assemble(_ body:
PreparedBody, options:) -> String` (pure, off the main thread, cached, never edited afterwards)
builds the document. This list is the contract P26 builds and a reviewer ticks.

*The document*

1. `<!doctype html><html><head><meta charset="utf-8">`, then the policy:
   `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src banana-mail:
   data:; style-src 'unsafe-inline'; font-src 'none'; media-src 'none'; frame-src 'none';
   object-src 'none'; connect-src 'none'; form-action 'none'; base-uri 'none'">`, then
   `<meta name="viewport" content="width=device-width, initial-scale=1, user-scalable=no">` and
   `<meta name="referrer" content="no-referrer">`, then Banana's own `<style>`, then
   `<body dir="auto">` and the fragment in `<section class="banana-message">`. **No byte of the
   sender's appears before `<body>`**, and no string from a message is put into the wrapper by
   any other path.
2. Every `img` in the fragment carries its declared box, so the page's height does not change
   when pictures arrive.

*Configuration — one `MailWebConfiguration.make()`, the only place a mail
`WKWebViewConfiguration` is created*

3. `defaultWebpagePreferences.allowsContentJavaScript = false`.
4. `preferences.javaScriptCanOpenWindowsAutomatically = false`;
   `isElementFullscreenEnabled = false`; text selection stays on.
5. `websiteDataStore = .nonPersistent()`, made once for mail and shared with no other web view.
6. `setURLSchemeHandler(MailSchemeHandler, forURLScheme: "banana-mail")` — the only
   network-capable object the web view can reach.
7. A compiled `WKContentRuleList`, installed before the first load, from exactly:
   `[{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
   {"trigger":{"url-filter":"^banana-mail://(cid|remote)/"},"action":{"type":"ignore-previous-rules"}},
   {"trigger":{"url-filter":"^data:image/(png|jpeg|gif|webp);base64,"},"action":{"type":"ignore-previous-rules"}}]`.
   If it fails to compile, no web view is shown — the message is drawn as text.
8. `mediaTypesRequiringUserActionForPlayback = .all`; inline playback, AirPlay and
   picture-in-picture off.
9. Mail's own `WKProcessPool`, so no other part of the app shares a web process with message
   content.
10. Height is measured by a `WKUserScript` in its own `WKContentWorld`
    (`banana-mail-measure`), at document end, main frame only, with one message handler that
    accepts a `Double` between 0 and 200,000 and ignores everything else. Nothing is evaluated
    in the page's world.

*The view — `MailWebView`*

11. `allowsLinkPreview = false`; back-forward gestures off; `dataDetectorTypes = []`;
    `isInspectable = false` outside DEBUG.
12. Loaded only by `loadHTMLString(document, baseURL: banana-mail://document/<a UUID per
    load>/)` — a dead host. Never `load(URLRequest)`, never `loadFileURL`.
13. Navigation: allowed only for the first load and same-document fragments; everything else
    cancelled. A link activation is cancelled and handed to `MailSource.decideLink(_:in:)`,
    which finds what the reader was shown for that address in the prepared body and applies
    `MailLinkRules` (10.7) — the web view itself reports only a URL.
    Responses that are not `banana-mail:` or `data:` are cancelled; downloads are cancelled.
14. UI delegate: no new windows; script alerts complete without showing; the context menu is
    replaced by Copy, Copy Link, Open Link (through `MailLinkRules`) and Copy Image.
15. Drops are refused on both platforms.
16. The web view does not scroll; the native reader does. Its frame is the measured height,
    clamped to 50,000 pt; a taller document is cut with a native "Show the whole message".
17. **The scheme handler is scoped to the message** assigned to that web view: it serves
    `cid/<m>/<x>` only when `<m>` is that message's key and `<x>` one of its inline parts, and
    `remote/<h>` only when `<h>` is in its `remoteSources`. Anything else — host `document`
    included — is a 404 with no fetch and no log line. Every response carries a sniffed
    `Content-Type` (`image/png|jpeg|gif|webp|heic` only), `Cache-Control: no-store` and
    `X-Content-Type-Options: nosniff`. A request from a web view that is not on screen gets the
    transparent placeholder.
18. One web view per designed message that is open, six at most in a conversation (the
    UX's cap); a web view is assigned its message before loading and emptied
    (`loadHTMLString("", baseURL: nil)`) when it leaves the screen; all are destroyed with the
    tree when the app is blanked (`AppVisibility`). Never created, loaded or measured inside a
    view's `body`.
19. No Banana control, text or icon is drawn inside a web view. The pictures line, attachment
    chips, menus and the reply field are native, outside the card's border — so nothing a
    sender draws can pass for one of them.

*Verification, on the hostile fixtures (17.5)*

20. The handler's log shows only this message's `cid` and `remote` keys; with the default
    setting the fake picture loader records zero requests.
21. A canary script leaves `document.title` unchanged; a meta refresh and a form produce no
    navigation; a tapped link reaches `MailLinkRules` and was cancelled in the web view.
22. The differential test: every fixture's fragment, parsed by a second parser (libxml2 in the
    test target; WebKit in the UI test), contains only allow-listed elements and attributes.
23. `nested-100k-divs` and `html-2mb-plus` stay inside the route's memory and time budget.

### 10.6 Remote pictures

A remote picture fetched from the device tells the sender's server his IP address and that,
and when, the mail was opened. Banana has no server to fetch through, which is why Apple Mail
can hide his address and Banana cannot.

**The owner's ruling: "Default to ask, but allow to set always for this sender, always for
this domain, and always period."** Four levels, each wider than the last:

| Level | Pictures load | Kept as | Undone by |
|---|---|---|---|
| **Ask** — the default | when he taps *Show pictures*, for that message | one row per message, on this device | — |
| **Always for this sender** | for mail from one address | a synced rule, `MailPictureRule.sender(address)` | removing the rule: in Settings › Mail › Pictures, or from any message it is showing ("Shown because: always from …") |
| **Always for this domain** | for mail from one domain and its subdomains | a synced rule, `.domain(domain)` | the same |
| **Always** | for all mail | a synced setting, `mailPictures = .always` | the same: `.everyone` is listed with the rules, and removing it is "ask" again |

```swift
/// What he has allowed. `everyone` and `blockTrackers` are synced settings; the two sets are
/// synced lists, one record a rule (8.5).
struct MailPicturePolicy: Equatable, Sendable {
    var everyone: Bool
    var domains: Set<String>
    var senders: Set<String>            // addresses, lower-cased
    var blockTrackers: Bool             // on unless he turns it off
}
/// Who a message is from, as far as pictures are concerned: nil unless Gmail vouched for it.
struct MailPictureSender: Equatable, Sendable {
    var address: String                 // MessageHeaders.sender (10.8)
    var domain: String                  // MailAuthRules.authenticatedDomain (below)
}
enum RemoteImageRules {
    static func decision(picture: MailPicture, sender: MailPictureSender?, policy: MailPicturePolicy,
                         allowedForMessage: Bool, inSpam: Bool, cached: Bool,
                         presentation: MailPresentation) -> RemoteImageDecision
        // .serveCached, .fetchThenServe, .placeholder, .refuse
    /// The rule of the policy that lets this message's pictures load, if one does.
    static func rule(for sender: MailPictureSender?, policy: MailPicturePolicy, inSpam: Bool) -> MailPictureRule?
}
enum MailPresentation: Sendable { case onScreen, warming }
enum MailAuthRules {
    /// The domain Gmail authenticated for this message, if it speaks for the From line.
    static func authenticatedDomain(headers: [(String, String)], fromDomain: String) -> String?
}
```

The decision, the first that applies:

1. **A recognised tracker, while `blockTrackers` is on → `.refuse`** — at every level, "always"
   and "show pictures on this message" included. Recognised means the prepared body says so,
   or the host of its source is on the tracker list as it is now (10.4).
2. `presentation == .warming` → `.placeholder` unless cached, whatever the policy. Making a
   message ready can never fetch (P-1, invariant 30).
3. Cached → served, online or not.
4. **Anything in Spam → `.placeholder` unless he allowed that message.** No rule and no
   setting reaches into Spam; "always" does not mean "for mail Gmail has already called
   hostile".
5. Allowed for this message; or `everyone`; or the message has a `MailPictureSender` and a
   rule covers it — its address is in `senders`, or its domain is one of `domains` or a
   subdomain of one — → fetched once and cached in `Cache/Remote.noindex/`.
6. Otherwise → a transparent placeholder of the declared size; `MailBody` reports how many
   pictures are waiting.

**What "this sender" and "this domain" are keyed on.** Not on a From line — a From line is
free to forge. Both are keyed on what Gmail vouched for:

- **"This domain"** is the message's authenticated domain (the rule below): the one Gmail
  authenticated *and* that speaks for the From line. A domain rule covers that domain and its
  subdomains, on a dot boundary — whoever answers for `example.com` answers for
  `news.example.com`. The rule's key is always a domain some message of his was authenticated
  as, so it is never a public suffix.
- **"This sender"** is the From address of a message that has an authenticated domain — the
  one mailbox `MessageHeaders.sender` reads (10.8) — and the rule applies only to messages
  that have one. It is narrower than the domain rule, not stronger: Gmail vouches for the
  domain, and anyone who can send as that domain can write that address. For a shared domain
  such as `gmail.com`, where the provider itself ties the address to an account, it is the
  right key and "this domain" would be everyone there; the menu offers both and says which.
- **A message with no authenticated identity** — no header of Gmail's, nothing that speaks
  for the From line, an unreadable sender — is offered neither. It has *Show pictures* for
  that message, and it is covered by "always" if he has chosen that. `MailPictures.offers`
  (13.10) lists exactly what may be offered, so a screen never shows a choice the engine
  would not keep.

**How each is stored, synced and undone.** The two lists are synced controls, one record a
rule, newest edit wins, removal a tombstone (8.5), so a rule made on the Mac holds on the
phone and one removed on the phone stops on the Mac. `everyone` and `blockTrackers` are
synced settings (`AppSettings`: `mailPictures`, `mailBlockTrackers`). "This message" is a
row on this device and is not synced. Every level has a way back in the same two places:
Settings lists every rule with a remove, `everyone` among them (`pictureRules()`,
`removePictureRule(_:)`), and a message whose pictures are showing because of a rule says
which (`MailPictures.shownBy`) and offers to remove it there. Removing a rule fetches nothing
and deletes nothing: pictures already on the device stay, and the next message asks.

**Trackers have their own switch, and it is on.** The owner's levels say when pictures load;
the coordinator's default, kept here, is that a recognised tracking pixel loads at none of
them. It is a setting of its own — "Block tracking pixels", `mailBlockTrackers`, on — because
"always" then means "always show me the pictures", not "always tell every sender I opened
it". For the switch to be something he can turn off, **preparation marks a tracker and does
not remove it**: its element stays in the prepared document, pointing at the scheme handler
like any picture, and what the handler answers is the decision above. (The first design
removed it at preparation, which a switch would have needed every stored body prepared again
to undo.) `trackersRemoved` is the number held back; with the switch off it is zero. A quoted
message in a reply still loses its trackers whatever the switch says (7.2): that is what he
sends, not what he sees.

**A pane that follows the cursor is on screen only once he has stopped on it.** With a
reading pane (the owner's ruling on layout), the message under the cursor is drawn without
being opened. Drawn is not read: under "always", arrowing down thirty messages would tell
thirty senders he had opened their mail. So a pane asks for its pictures as `.warming` until
the cursor has rested on that conversation for one second, and as `.onScreen` after; a
conversation he opens is `.onScreen` at once. The number is the screens' to hold — one second
is what this document proposes to the UX author — and the rule is here because invariant 30
is.

**The authenticated domain.** `MailAuthRules` reads one header and no other: **the first
`Authentication-Results` header of the message, and only if it is Gmail's.** With no
authenticated domain a message has no `MailPictureSender`: it asks every time, and neither
"this sender" nor "this domain" is offered.

**Which header is Gmail's — exactly.** Gmail writes its own on receipt, above everything the
message arrived with. So:

- **It is the first field named `Authentication-Results`**, in the order Gmail sent the
  headers. Not the first that *claims* to be Google's: the reader does not look past another
  server's header for one that says `mx.google.com`. If the first names any other server,
  Gmail wrote none, and there is no authenticated domain — whatever sits below.
- **Its authserv-id** — the first word of its value, comments aside, compared without regard
  to case — **is `mx.google.com`.** Otherwise it is not read.
- **Folded**, it is one header: the value is unfolded before it is read. **Repeated**, only
  the first counts; a second, whatever name it carries, is ignored. **Cut** — its value over
  the 16 KB a header value is kept to (5.6) — it is not read at all: a sender can lengthen
  what Gmail writes there, and a result that was cut away is unknown, not absent.
  `ARC-Authentication-Results` is another header and is never read. It is never among the
  headers looked for past the cut (5.6).
- **What no reading can tell.** A message that did not come through Gmail's own receiving
  servers — imported, put there by another program with access to his account, perhaps one
  fetched from another provider — may have no header of Gmail's, and then the first one is
  whatever its author wrote. Position is all there is to go on. What such a forgery buys is
  pictures loading without being asked and a one-click unsubscribe being offered, for a
  message someone with access to his mailbox put there; it is accepted, and said. The probe
  asks what Gmail writes on such mail and whether it removes a header that claims its name
  (19.2, item 11).

**What "the authenticated domain" is: the one Gmail vouched for *and* that speaks for the
From line.** A message can pass DKIM for its mailing service's domain and SPF for a bounce
domain, and neither is the sender he sees. So a result counts only if it is tied to the From
domain, and the results are read in this order, the first that counts winning:

1. **`dmarc=pass` whose `header.from` is the From domain, exactly.** DMARC passing *is*
   Gmail saying that DKIM or SPF passed for a domain aligned with the From line — and Gmail
   does that alignment with the public-suffix list, which Banana does not have. The answer is
   the From domain.
2. **`dkim=pass`**, for the signing domain: **`header.d` if the result carries it, otherwise
   the domain of `header.i`** — what follows its last `@`. It counts when it is the From
   domain or a parent of it on a dot boundary (a signature by `example.com` speaks for
   `mail.example.com`; not the reverse). Each `dkim=pass` result is tried, in order.
3. **`spf=pass`**, for the domain of `smtp.mailfrom` (what follows its `@`, or the whole
   value), under the same test.

**Both spellings of a DKIM result are read because which one Gmail writes is not verified.**
The first text of this section said `header.d`. The implementer of P03a believes — and so
does this author, from headers seen and no document — that Gmail writes
`dkim=pass header.i=@example.com header.s=… header.b=…`, and `dmarc=pass (p=…) header.from=…`
beside it: ASSUMED, UNVERIFIED. Read as first written, no message from Gmail would ever have
had an authenticated sender, and nothing would have failed. So the reader accepts either, the
read probe records what Gmail writes (19.2, item 11), and **the fake writes Gmail's believed
form** — `dkim=pass header.i=@<domain> header.s=<selector> header.b=<8 characters>;
spf=pass (…) smtp.mailfrom=<bounce address>; dmarc=pass (p=NONE sp=NONE dis=NONE)
header.from=<domain>` — with a switch for the other (17.2, row 47). Where `header.i` names a
subdomain of the signing domain (a signer may), rule 2 alone can miss a From at the parent;
rule 1 is what catches it.

The loader (`MailRemoteImageLoader`, through the transport gate): an ephemeral `URLSession`; no
cookies, no cache, no referrer, no `Accept-Language`; `https` only, TLS 1.2 or later; at most
three redirects, each `https` and none to a loopback, link-local or private address; 15 s;
10 MB **counted after decompression**, in a data-task delegate.

- **Its `User-Agent` is one constant**, `MailRemoteUserAgent`, set on this session and on the
  unsubscribe session and asserted by their tests: the plain WebKit string a mail client's web
  view sends on that platform (on the Mac, `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)
  AppleWebKit/605.1.15 (KHTML, like Gecko)`; the iPhone and iPad forms likewise). Never
  `URLSession`'s default, which names Banana and its build — a string one person on earth
  sends (N-8).
- **It has a seam, so its rules are tested without a network.** The redirect and size
  decisions are two pure functions — `RemoteFetchRules.mayFollow(from:to:hop:)` and
  `RemoteFetchRules.mayContinue(received:limit:)` — and the loader is created with a
  `URLSessionConfiguration` handed in, so a test installs a `URLProtocol` that plays the
  server. P21a's tests: a redirect to `http://` is refused; a redirect to
  `https://10.0.0.1/` is refused; a fourth hop is refused; a gzip body that inflates past
  10 MB is abandoned (`attachment-gzip-bomb-image`); the request carries the constant
  `User-Agent`, no cookie and no `Accept-Language`. `https` is enforced in this code because
  App Transport Security is off for the app (5.1); the platform does not do it. Before
an image is cached its header is read without decoding (`CGImageSourceCopyPropertiesAtIndex`)
and anything over 8,192 px on a side or 50 megapixels is refused.

There is no certificate pinning: the system trust store is the root of trust for mail and for
tokens, and a root certificate he or a profile installs can read both.

`cid:` pictures are attachments (section 11): served from disk if downloaded, fetched in the
interactive lane if not — only for the message on screen — and a placeholder offline.

### 10.7 Links

A link never opens by itself, in a web view or in native text: both reach one pure function
with `(url, shownText, shownIsImage)`. Native text has the shown text in the run that was
tapped, and the reader installs the rule as the environment's `openURL` so a native link
cannot bypass it. A web view knows only the URL (the navigation action carries no anchor
text), so preparation records, for every `href` it keeps, what was shown for it
(`PreparedBody.links`; where one address appears twice, the entry that would warn wins), and
`MailSource.decideLink(_:in:)` looks it up — without that the mismatch warning could never
fire for designed mail (N-7). `MailLinkRules`, `MailLinkDecision` and `MailLinkWarning` are
declared in `MailContract.swift`, because the reader names them.

```swift
// M/MailLinkRules.swift (P20b). The three types are the contract's (13.2); this adds the function.
extension MailLinkRules {
    static func decide(url: URL, shownText: String, shownIsImage: Bool) -> MailLinkDecision
}
```

- **Refuse:** any scheme but `http`, `https`, `mailto`; an `http(s)` URL with userinfo; a host
  that is an IP literal, `localhost`, `.local`, link-local or private (the browser would reach
  his own network with his cookies); a URL over 2,048 bytes.
- **Warn** — a sheet showing the whole destination with the host emphasised — when the shown
  text contains something that reads as a host or address and the destination's host is neither
  equal to it nor a subdomain of it nor its parent; when the host has non-ASCII labels (shown
  in its `xn--` form, from `URLComponents.encodedHost`); and always when the link is a picture.
  The comparison is by suffix on dot boundaries — no public-suffix list is needed for "does
  what it says" (reuse B-13).
- **`mailto:`** → the composer, with To and Subject only. `cc`, `bcc`, `body` and `attachment`
  parameters are dropped: a link cannot add a recipient he does not see.
- `tel:` is not a link in mail.

### 10.8 Who it says it is from

```swift
enum MailAddressRules {
    static func isValid(_ address: String) -> Bool
    /// The name to show, or nil to show the address instead.
    static func displayName(_ name: String?, address: String) -> String?
    /// Text with direction controls and invisible characters removed.
    static func cleaned(_ text: String) -> String
}
```

- A display name is replaced by the address when it contains `@`, `<`, `>`, something that
  reads as a URL, or **a word that mixes look-alike scripts** (below).
- **Mixed scripts: one word, three scripts.** The spoof is a word that looks like a name he
  knows and is not spelt with its letters — `Pаypal` with a Cyrillic `а`. So the test is per
  **word** (a run of letters, marks and digits), and it is failed by a word that holds letters
  of two of **Latin, Cyrillic and Greek**: the three scripts whose letters pass for one
  another. Nothing else is flagged. A Japanese name is Han and kana in one word and is a name;
  "Tinkoff Банк" is two words, each in its own script, and is how people there write; Latin
  beside Han, Hangul, Arabic or Devanagari deceives no one. A flag that fires on honest mail
  is a flag he learns not to read. (This is narrower than Unicode's own "highly restrictive"
  level, UTS #39, which is meant for identifiers and would refuse the bank.) What it does not
  catch is a word spelt *wholly* in another script's look-alikes; that needs Unicode's table
  of confusables, and the address beside the name of anyone he has not written to (below) is
  what stands in for it.
- **Where a letter's script comes from: `NSRegularExpression`.** `\p{Script=Latin}`,
  `\p{Script=Cyrillic}`, `\p{Script=Greek}` — a public API over the system's own Unicode
  data (DOCUMENTED: ICU's regular expressions take any Unicode property in `\p{…}`). There
  is no hand table. Swift's standard library exposes many properties of a scalar but not its
  script; the complete standard answer, ICU's spoof checker (`uspoof`), is in the system's
  ICU and **private** on Apple's platforms, so it is not used. Each word is tested against the
  three patterns over its own range — linear, with no look-around.
- **`cleaned` removes what cannot be seen**, from names, subjects, snippets, file names and
  link text **when they are stored**, so no screen has to remember to. Emoji stay — whole.
  - *What is removed* is every character Unicode itself calls invisible by design:
    `Default_Ignorable_Code_Point` (`Unicode.Scalar.Properties.isDefaultIgnorableCodePoint`,
    the standard library's — not a hand list). That is the direction controls (U+061C,
    U+200E–U+200F, U+202A–U+202E, U+2066–U+2069), the zero-width and word-joining characters
    (U+200B–U+200D, U+2060, U+FEFF), the soft hyphen, the fillers, the variation selectors
    and the tag characters.
  - *Except one that is doing its work*, where removing it would change what he reads:
    1. **A variation selector** (`isVariationSelector`) directly after a character that is
       kept and is not white space: emoji presentation, and the ideograph variants that
       Japanese names use.
    2. **U+200D inside an emoji sequence**: inside one grapheme cluster — one `Character`,
       the standard library's segmentation, which joins across U+200D only in a sequence
       Unicode defines — with an emoji that is not ASCII before it and after it. Families,
       professions, couples. And **a tag sequence**, U+E0020–U+E007E closed by U+E007F,
       directly after U+1F3F4: the flags of England, Scotland and Wales. Tag characters
       anywhere else are removed; they are how text is hidden inside text.
    3. **U+200C and U+200D inside a word of a script that is written with them**, by the rule
       the IDNA standard already made for exactly this (RFC 5892, appendix A.1 and A.2):
       either, after a virama (`\p{ccc=Virama}`) — the Indic scripts; and U+200C between a
       letter that joins to its left and one that joins to its right
       (`[\p{jt=L}\p{jt=D}]\p{jt=T}*` before it, `\p{jt=T}*[\p{jt=R}\p{jt=D}]` after, at
       most eight transparent marks either side) — Persian and Urdu, where it is part of how
       a word is spelt. Between Latin, Cyrillic or Greek letters neither is ever kept.
  - *Never excepted:* the direction controls. Nothing in a name or a subject needs one, and
    one is how a file named `…fdp.exe` is made to read `…exe.pdf`.
  - *Addresses are not cleaned.* An address holding any of these characters is not an
    address: `isValid` is false, and its sender is unreadable (below). That stands.
  - (The first list here named U+200B–U+200D outright; followed literally it split every
    joined emoji and took the joiner out of honest Persian names. P03a found it.)
- **What is in quotes is a name, always.** The reader of an address list never tries a quoted
  string as an address — with angle brackets or without. With brackets, the address is what
  is inside them and everything before is the name. Without, the address is the one unquoted
  word that is an address; a quoted string beside it is its name, and a quoted string alone
  is no mailbox at all. So `"ceo@victim.example" attacker@evil.example` is one mailbox,
  `attacker@evil.example`, whose name looks like an address and is therefore not shown;
  `"ceo@victim.example" x` holds no address and is unreadable; and two bare addresses with no
  comma between them are not two mailboxes but one item that cannot be read.
- **Who a message is from is one reading, `MessageHeaders.sender`, and nothing else takes an
  address out of `From`.** It answers a single mailbox or nothing. It answers a mailbox only
  when **all** of these hold: the message has exactly one `From` header; its value was not
  cut (5.6); it reads as **exactly one mailbox** — one address, no second, no group, nothing
  left over that could not be read; that address is one an address may be (next); and, when
  Gmail's own header (10.6) carries a `dmarc=` result of any verdict, its `header.from` is
  the domain of that address. Otherwise the sender is unreadable. **Never the first of
  several**: in every shape with more than one — two mailboxes, two `From` headers, a
  bracketed address followed by a bare one — the first is the one a forger chose to put
  there. (A `From` of two mailboxes with a `Sender` header is legal, and Gmail is believed to
  refuse it at the door, as it does a message with two `From` headers: ASSUMED; write probe
  W7. No exception is made for it.) The `dmarc=` test is there because Gmail and Banana are
  two readers of one line: when they disagree about whose it is, what Gmail authenticated is
  not what the screen would show, and the honest answer is neither.
- **What an address may contain.** An address is `local@domain` with exactly one `@`
  (U+0040), at most 320 bytes, and:
  - *the local part* holds only ASCII letters and digits, the characters
    ``!#$%&'*+-/=?^_`{|}~.``, and — outside ASCII — letters, combining marks and digits. No
    quotation mark, bracket, parenthesis, backslash, colon, semicolon, comma or space: a
    quoted local part is legal and is not read. It is **unchanged by compatibility folding**
    (NFKC), so a full-width `＠`, a small `﹫`, full-width or mathematical letters cannot
    stand in it; it holds **no default-ignorable character** (a variation selector, a
    grapheme joiner and the Hangul fillers are marks and letters, and are still refused); it
    **does not begin with a combining mark**; and **no word of it mixes two of Latin, Cyrillic
    and Greek** — the rule for a name, because the address is what is shown *instead of* a
    suspect name and is the last thing that may deceive;
  - *the domain* is lower-cased, turned to its `xn--` form by the system when it is not
    ASCII, and then held to letters, digits, hyphen and underscore in at least two labels.

  Anything else is not an address. It is never cleaned or repaired into one: it makes its
  mailbox unreadable. A screen draws an address in a left-to-right isolate of its own — a
  local part may honestly hold right-to-left letters, and without the isolate its two halves
  can change places.
- **A sender that cannot be read** is one state — the UX's "unreadable sender" — however it
  came about: no `From`; a `From` that is not exactly one mailbox; an address that is not one;
  a value cut before its address; a `From` Gmail read differently. Nothing downstream tells
  them apart. The engine stores `from_addr` and `from_name` NULL; the person it gives a
  screen has `name == nil` and **an empty `address`**, `isMe` and `isKnown` false. **A row and
  a conversation's header both show that person** — one sender, said to be unreadable — and
  never nobody, never the first of several, and never the header's own text: what could not
  be read is not put where a sender goes, because it may be `Noor <noor@plan.example`. Such a
  message is never from a known correspondent, never from an authenticated domain (10.6),
  matches no `from:`, and a reply to it starts with no recipient; "Open in Gmail" is where he
  can see what Gmail made of it.
- **A name is judged once, when its message is stored** — the fold, the link test, the three
  patterns — and what is stored is the answer. No list row asks again.
- A domain with non-ASCII labels is given to the UI in its `xn--` form.
- `MailPerson.isKnown` says whether he has ever written to that address; the UI shows the
  address beside the name when he has not.
- `MailFileName.safe(_:)` for attachments: `/`, `:`, NUL, control and direction characters and
  leading dots removed; whitespace collapsed; 255 bytes at most, extension kept; empty becomes
  "Attachment".

### 10.9 Unsubscribe

```swift
enum MailUnsubscribeRules {
    static func decide(headers: [(String, String)], authenticatedDomain: String?) -> MailUnsubscribe?
        // .oneClick(host:), .openPage(URL), .compose(to:subject:)
}
```

One-click is offered only when all hold: `List-Unsubscribe-Post: List-Unsubscribe=One-Click`;
an `https` URL; a `List-Id`; and the URL's host equal to, or a subdomain of, the authenticated
domain. Otherwise the offer is "Open unsubscribe page" (through `MailLinkRules`) or "Write to
unsubscribe" (the composer, To and Subject visible, not sent for him). One-click is confirmed
once per list in a sheet naming the host; never from a notification, never for several
conversations at once, never on a key alone. The POST goes through the transport gate on its
own ephemeral session: `https`, redirects refused (RFC 8058), no cookies, body exactly
`List-Unsubscribe=One-Click`, 10 s. A 2xx is reported as "Asked *host* to unsubscribe you" —
the word "Unsubscribed" is not used, because nothing proves it.

### 10.10 Invitations

No calendar-file parser is built. `MailInviteRules.read(_ ics: Data) -> MailInvite?` scans at
most 256 KB of a `text/calendar` part for two unfolded lines, `METHOD:` and `UID:`, and returns
`MailInvite { method, uid }`. The event itself is found through the calendar's existing lookup
by iCalendar UID (`MailEnvironment.findEvent(uid:)`); what the card shows comes from the
calendar, not from the sender's file. With no match the card says "Not on a calendar Banana can
see". Recurrence is never expanded here. **It is read when the message is**: the extraction
(P03b) calls it on a `text/calendar` part whose data came with the message and records what it
found in `MIMEStructure.invite` (appendix A), so a conversation knows its invitation without
fetching anything. A part too large to have come inline leaves `uid` nil until it is fetched.
`MailInviteRules` is therefore P03b's, its first user, and not P20b's.

### 10.11 The seam for an on-device model

Nothing in the first release gives a message to a model. When something does, the seam carries
these rules from its first line (P-14): no tools; output is text for a person and nothing
parses it; one conversation per session, own text only; on the device only unless he turns on a
separate setting; never automatic; and anything that becomes an event, a reminder, a request or
a send comes from the deterministic rules above, never from generated text.

## 11. Attachments and disk

### 11.1 Fetching and keeping

- **What is always here:** every attachment's name, type and size, from the message's MIME
  structure (`attachment` rows).
- **Bytes are fetched lazily, with a prefetch policy:**

  ```swift
  enum AttachmentRules {
      static func shouldPrefetch(_ a: AttachmentFacts, message: MessageFacts, age: TimeInterval,
                                 network: NetworkKind, policy: AttachmentPolicy) -> Bool
      static func evictionOrder(_ candidates: [StoredAttachment], now: Date) -> [StoredAttachment]
  }
  ```

  Inline pictures up to 2 MB are fetched when their message's body is, on any network —
  **but never inside a background task** (N-10): `Attachments.noindex` cannot be written while
  the phone is locked, so the refresh and overnight tasks fetch bodies and text only, make no
  attachment request, and an inline picture arrives when its message is on screen (10.6) or
  with the foreground fill. Other
  attachments up to 10 MB are fetched for mail in the inbox, starred, snoozed or under 30 days
  old, on Wi-Fi or wired only (`NetworkMonitor.isCheap`), in the backfill lane. Everything else
  is fetched when tapped, in the interactive lane. A single file over 50 MB is never
  prefetched and says its size before downloading.
- **Fetching.** `messages.attachments.get` is 20 units and returns the whole file as one JSON
  string of base64url — a 25 MB file is a 33 MB response, with no range requests (DOCUMENTED
  §7). It is streamed to a temporary file and decoded with Foundation in 64 KB pieces, then
  moved atomically into `Cache/Attachments.noindex/`.
- **Gmail's attachment id is not a key** (its stability is UNVERIFIED): files are keyed by
  account, message id and part id. A `notFound` re-reads the message's structure for a fresh id
  and tries once more.
- **Outgoing:** a file attached in the composer is copied into `Intent/Attachments/` at once,
  so the original can move or vanish. A forwarded attachment that is not on the device is
  fetched before the draft can upload, and the draft says so until then.

### 11.2 A file from a stranger

Adopted from the security review (P-8); `UniformTypeIdentifiers` is the one framework this adds
to the pure folder.

- **Type is what the bytes say.** The stored file's extension, the chip's icon and the preview
  come from the type sniffed from the first bytes; the declared type is used only when the
  bytes agree. A mismatch is shown as "Document", with a generic icon, and kept as `.bin`.
- **Names** pass `MailFileName.safe` (10.8) before they reach a chip, a Save panel, a share
  sheet or a drag.
- **One door for files.** Every file mail creates outside SQLite — an attachment, a remote
  picture, the first-frame file, a draft's attachment, an upload body — is created by
  `MailFiles.install(temporary:at:protection:quarantine:)`: written to a temporary file
  beside its destination; given, on the Mac, its quarantine **while it is still the temporary
  file**; then moved into place atomically; then given its protection class (a moved file
  keeps the class it was created with, not its new directory's — N-3). A file that cannot be
  given what it was asked for is not left behind. The
  static test of 10.4 refuses `copyItem(`, `moveItem(`, `createFile(` and `.write(to:` in any
  other mail file, so a later export path cannot write a file that skipped either.
- **Quarantine on the Mac.** Every attachment and every saved or dragged copy is given
  `URLResourceValues.quarantineProperties` **before that move, on the temporary file** — an
  extended attribute travels with a rename, so the file is quarantined from the first moment
  it has its real name, before anything can reach it; and the Finder carries the attribute
  onto copies. (Set after the move, there would be a moment with the name and without the
  mark.) The properties are
  `kLSQuarantineTypeKey = kLSQuarantineTypeEmailAttachment`,
  `kLSQuarantineAgentBundleIdentifierKey` (Banana's) and `kLSQuarantineOriginURLKey` (a
  `mailto:` of the sender), so a saved `.command` or `.pkg` meets Gatekeeper as a mail
  attachment. The test on the Mac host reads `com.apple.quarantine` back and asserts its flags
  field marks the file as not yet assessed and its type as an email attachment — not merely
  that the attribute exists. The review asked for the app-wide
  `LSFileQuarantineEnabled` as well; that is declined, because it would also quarantine every
  podcast, export and photo the rest of Banana writes — a change to the daily driver that mail
  does not need. A test on the Mac host reads the attribute back from a stored file.
- **Quick Look only.** An attachment is previewed through Quick Look and nothing else; no mail
  code opens a file URL with the system (the static test of 10.4).
- **Not indexed.** `Attachments.noindex` and `Remote.noindex`: Spotlight does not read them.
- **Pictures** served into a web view must sniff as `image/png|jpeg|gif|webp|heic`, and pass
  the size check of 10.6.
- Forwarding a file whose bytes are executable (Mach-O, PE, a script, a package, a disk image)
  asks once.

### 11.3 Ceilings, the floor, and eviction

- **The sync limit is what bounds a device's mail** (5.4; D3, answered): what is inside it is
  held whole, and what is outside is not held. **The ceilings are a backstop**, for a limit he
  has set wider than the device can carry: attachments plus remote pictures — 2 GB on an
  iPhone, 4 GB on an iPad, 20 GB on a Mac; bodies — 4 GB on an iPhone, 8 GB on an iPad, none
  on a Mac. Six months of mail is ASSUMED far under them. Over a ceiling, the least recently
  used go first. Never evicted: anything opened in the last seven days, anything marked
  "keep", and files attached to unsent messages (they are not in `Cache/`). An evicted body
  drops its message to header level: still listed, still searchable, fetched again when
  opened — and Settings then says the limit is wider than this device keeps whole.
- **Everything is in Application Support, never in `Caches`.** The system may empty `Caches`
  without asking, and "all mail cached locally" would then be untrue without a word. The
  ceilings are what bound it instead.
- **The free-space floor (invariant 26).** The floor is **1 GiB on an iPhone or iPad and
  5 GiB on a Mac**; the sizes of this bullet are binary, like the page caches of 4.2, which
  errs towards stopping early. Below it the fill, attachment prefetch, preparation and the
  indexer stop; eviction runs until free space is 500 MiB above the floor; then they resume.
  - **The rule is pure and has two thresholds**, so it is told its own previous answer:
    `MailDiskRules.state(free:floor:was:) -> MailDiskState`, where `MailDiskState` is `ok` or
    `belowFloor`. From `ok` it becomes `belowFloor` when free space is **strictly less than**
    the floor (`free == floor` is ok). From `belowFloor` it becomes `ok` only at
    `floor + 500 MiB` or more (`evictionTarget(floor:)`): a fill let go at the floor itself
    would be stopped again by its next batch. `floor(for:)` and
    `shouldReadFreeSpace(secondsSinceLastRead:bytesWrittenSinceLastRead:)` are beside it.
  - **The memory of having stopped lives in one object, `MailDiskWatch`** (P02), of which the
    engine makes one (P23a) and hands it to whatever fills the disk. It reads free space
    through `MailEnvironment.freeDiskBytes` (`volumeAvailableCapacityForImportantUsage`) —
    never on the main thread, at most once a minute, and again after every 50 MiB its users
    report having written (`wrote(_:)`) — applies the rule to its last answer, and answers
    `state()`. Each of the four asks it before a batch and does not start one while it says
    `belowFloor`. **Eviction (P33) is what brings it back**; until P33 exists nothing does,
    and a device under its floor stays stopped and says so.
  - `MailStatusValue.downloads.heldBy` says `.diskNearlyFull`. Actions, drafts and sends are
    never stopped by the floor: they are a few hundred bytes each, and the floor exists so
    that they always fit.
- **Eviction changes the index first**, then deletes the content row or the file (5.6), so a
  crash between the two leaves an orphan to delete, never a promise that cannot be kept.
- The disk-usage walk, integrity checks and eviction planning run on a Mac when idle and, on a
  phone or iPad, only inside the overnight task (R-17).

`MailSource.storageUsed()` (13.3) reports bodies, attachments, search and the index separately,
from `meta` counters maintained by the writers — not from a directory walk.

## 12. Background, polling, notifications

There is no push. Gmail's `watch` posts to a Cloud Pub/Sub topic, which needs a server to
receive it (DOCUMENTED §10); Google itself recommends polling for installed apps.

### 12.1 While the app is open

One driver for all accounts (`MailRuntime`), shaped like `CloudSyncPoll`: `resume()` on a real
return to the foreground, `suspend()` on backgrounding.

```swift
enum PollRules {
    static func interval(role: MailDeviceRole, appActive: Bool, mailVisible: Bool, lowPower: Bool) -> TimeInterval?
    /// The quick checks after he asks or arrives: the times of the polls still to make.
    static func burst(since trigger: Date, now: Date, appActive: Bool, mailVisible: Bool, lowPower: Bool) -> TimeInterval?
}
```

| | Mail on screen | Banana in front, elsewhere | Banana running, not in front |
|---|---|---|---|
| iPhone, iPad | 60 s | 5 min | nil — no polling (invariant 15) |
| Mac | 60 s | 60 s | 5 min |

Sixty seconds, not twenty (R-14): the app already polls CloudKit once a minute, and a third
timer three times as fast would triple the app's wake-ups for mail that is rarely that urgent.
The timer has a ten-second tolerance so the system can fire both together. Plus, at once: on a
real return from the background (the app's existing foreground-cascade rule decides what is
real; a glance at Control Center is not), when the network returns and stays up two seconds,
on pull-to-refresh and `checkNow()`, and on the Mac waking. In Low Power Mode the intervals
double.

**A bounded burst after he asks or arrives** (the UX's A6): for **60 seconds** after
`checkNow()`, after a real return to the foreground with Mail on screen, and after Mail's tab
comes to the front, the poll runs every **5 seconds** — twelve polls at most — and then the
table above resumes. That is how a sign-in code or a reply he is waiting for arrives in
seconds. It is inside the polling rules because of its bounds: only while the app is active
and Mail is on screen (leaving either ends it at once, and `suspend()` cancels it); never in
Low Power Mode, where the one immediate check is all there is; a new trigger restarts the
minute, a poll does not; and it costs twelve `history` calls an account — 24 units of 6,000
a minute — each of which writes and publishes nothing when there is nothing new. It is not a
faster standing cadence: R-14's objection was to that, and still holds.

A poll is one `history` call per account: 2 units. A poll that finds nothing writes nothing,
publishes nothing and costs a few milliseconds of CPU (5.5).

**What runs when** — the pace of 4.12 applied. As there, **the first row that applies
decides**:

| | Network (the fill) | Local passes (prepare, index, rebuild) |
|---|---|---|
| iOS background, outside a task | nothing | nothing |
| Thermal state fair or worse, or Low Power Mode — any device, the overnight task included | new mail only | none |
| Inside the overnight task (12.2) | full | full speed |
| Mac on mains | full | full speed |
| Mac on battery | full | a fifth of one core |
| iPhone or iPad, Mail on screen, charging | full | a fifth of one core |
| iPhone or iPad, Mail on screen, on battery | 2 requests in flight | a fifth of one core |
| iPhone or iPad, another tab in front | new mail only | none |

With the phone in a pocket playing a podcast the process is alive and in the background:
`MailRuntime` is suspended, the fill has stopped at its next batch boundary, the prepare queue
and the indexer after their current item, and every sleeping task is cancelled. A unit test
drives the engine with a manual clock and the fake, calls `suspend()`, advances an hour, and
asserts zero requests and zero scheduled work.

**`activate()`** — the call the first Mail screen makes — does at most 1 ms of work on the
main actor (it records that Mail was opened and hands the rest to the engine's start queue)
and is never awaited there. Opening the stores, rebuilding the overlay and the first read
happen off the main thread (45 ms p50 on this Mac under heavy load, MEASURED) while the first
frame is drawn from `first-page.json`. **The start queue is a serial `DispatchQueue` of the
engine's own (`mail.start`, user-initiated), not a detached task**: opening a store is
blocking GRDB work — it opens files, may replay a log, runs migrations — and a detached task
would run it on Swift's cooperative pool, which 4.2 forbids. (This paragraph once said "a
detached task"; P02 caught it.) What follows the opening is ordinary: the overlay through the
writer, the first read through GRDB's `async` read.

### 12.2 iOS background tasks

Two identifiers, each listed in **both** `BGTaskSchedulerPermittedIdentifiers` (targets
`Banana` and `BananaBeta` in `project.yml`) and registered in `BananaApp.init` beside
`CalendarWriteBackRefresh.register()`.

**`com.boris.banana.mail.refresh`** — `BGAppRefreshTask`, modelled on
`CalendarWriteBackRefresh`. Scheduled on every backgrounding and first thing in every run;
earliest begin is the sooner of 15 minutes and the next due wake. A run, checking the
expiration flag between steps:

1. Incremental sync for each connected account (most recently used first); fetch new inbox
   mail, at most 30 messages, and prepare those; nothing else.
2. The timed rules (8.3), then the outbox: label changes, wakes, and this device's due sends.
3. Notify (12.3).
4. Passive checkpoint; complete.

No enumeration, no fill, no attachment prefetch, no rebuilds. iOS decides when and whether this
runs; it does not run at all after a force-quit.

**`com.boris.banana.mail.fill`** — `BGProcessingTask`, `requiresExternalPower` and
`requiresNetworkConnectivity`, like `OvernightRefresh`. Runs the fill, preparation, the
indexer, the weekly reconcile, drift and integrity checks, eviction and the day's release (5.4), at full speed, until it
expires. This is how a phone's copy gets complete without being held open. **Unless the
device is warm or in Low Power Mode** (4.12, row 1): then the pace is `stopped`, and the task
does not sleep through it inside a background task — it finishes the item in hand, completes,
and schedules its next run. It asks the pace before each stage and at each batch boundary.

The Mac has no `BGTaskScheduler`; it polls while it runs.

### 12.3 New-mail notifications

Local notifications, posted when a sync pass (in the foreground with Mail not on screen, or in
a background task) stores new mail.

```swift
enum NotifyRules {
    static func toNotify(_ added: [MessageFacts], baselineAt: Date, notifiedThrough: Date,
                         myAddresses: Set<String>, mutedThreads: Set<String>) -> [MessageFacts]
    /// What a notification may show. The snippet only when the setting allows it.
    static func content(for message: MessageFacts, showSnippet: Bool) -> MailNotificationContent
}
```

- A message notifies when it has `INBOX` and `UNREAD` as fetched, is not from him, is not in a
  muted conversation, is in the first split (unless he chooses "all of the inbox"), and arrived
  after both the account's baseline and what was already notified. The first sync of an account is a baseline, not news; the marks live in
  `intent.sqlite`, so a rebuilt cache does not announce a year of mail. More than five at once
  become one summary.
- **What it shows (P-18):** the sender's name (through `MailAddressRules`) and the subject; the
  snippet only if he turns that on. The category sets `hiddenPreviewsBodyPlaceholder` to
  "%u new messages", so with previews hidden the lock screen shows a count. *Done* requires
  the device to be unlocked (`.authenticationRequired`); *Mark read* does not. Not
  time-sensitive.
- Identifiers are `banana.mail.<account hash>.<message id>`; a pass that finds the message
  read or archived elsewhere removes its notification. All of an account's notifications are
  withdrawn when Mail is turned off for it, when it is disconnected, and by "Remove downloaded
  mail".
- Actions go through the outbox like any other change, as of that message (6.1). A tap opens
  that conversation: the notification carries `MailConversationID.text` and nothing else. The
  "still waiting to send" notification of 7.5 offers *Send now*.
- The engine posts through `MailEnvironment.notifier`; it never imports `UserNotifications`.

**What he will experience:** on a Mac that is running, a notification within a minute. On an
iPhone with Banana open on another tab, within five minutes; with Mail open there is no
notification, the list simply changes. On an iPhone in a pocket, when iOS next runs the refresh
task: typically tens of minutes, sometimes hours, and not at all after a force-quit. Each
device notifies for itself.

**An option (D13): the Mac wakes the phone**, through a one-field CloudKit record and iCloud's
silent push — `MealBacklogWake`'s mechanism. Not in the base plan.

### 12.4 The badge

`MailBadges` is two numbers: unread conversations in the *first split* — not the whole inbox,
so forty unread newsletters in the last split do not badge the tab — and `needsAnswer`: the
questions about a send that are waiting for him (13.3) **plus every send in `failed`**,
refused for good (7.4). A message that did not go must badge the tab whether or not it comes
with a question. The first is a count over one view's partial index (4.4); the second a count
over a handful of rows of `intent.sqlite`, made on the writer's queue when a draft's state
changes.

`ActionBadges.start()` runs before any window, in a background launch too, and on devices where
Mail has never been opened. So the engine mirrors the two numbers to `UserDefaults` whenever
they change, and `ActionBadges` reads that: under a millisecond, no store opened, no engine
constructed. **The key and the stored form are the contract's** —
`MailBadgeCounts.mirrorKey` (`mailBadge`, dot-free), an array of the two integers, read by
`MailBadgeCounts.mirrored(in:)` and written by `mirror(to:)` (13.2) — so the screen that draws
the badge can be built before the engine that writes it. Whether the first number joins
`ActionItems.Counts.total` — and so the app icon and the Dock — is decision D4.

### 12.5 The switch that turns mail's network off

`--disable-mail-network`, and every `VisualAuditRoute` launch, make `MailNetworkPolicy.allowed`
false (5.1): no Gmail request, no picture fetch, no unsubscribe post, no token mint. The engine
still opens its stores and serves what is on disk; an audit route with a mail screen runs on
the fixture mailbox — the real engine over the fake by default, `MailFixtureSource` under
`--mail-source memory` (13.6; MAIL-UX 13.1). The performance gate launches every route with the flag and asserts
the transport saw nothing — the guarantee the calendar never had, and the reason an audit
route cannot touch his mailbox (R-20).

## 13. The contract: what the screens stand on

### 13.1 One file

`Banana/Model/Mail/MailContract.swift` holds **every type a view or a UI model may name, and
the one protocol they call**. It imports Foundation and Combine and nothing else. **The file
exists (package C0a) and compiles, and the two Swift blocks of 13.2 and 13.3 are its text, in
that order, character for character** — they include `MailAccountState` and `MailAccessGap`,
whose rules are 3.4 — and nothing else is in it. Where the two are ever found to differ, the
file is right, because it is the one that was compiled, and this section is corrected to it.
Every type the file uses is declared in it (`xcrun swiftc -typecheck` on the one file
succeeds), every function in it has a body or is a protocol requirement, and the structs rely
on Swift's own memberwise initialisers (nothing is `public`; the tests compile this folder
into their own module). The file changes only by a change both authors agree, landing alone,
with the contract suite extended and these two blocks replaced in the same commit.
MAIL-UX's section 12 declares no types; where it and this section differ, this section stands
and 22 lists each difference.

Two files sit beside it, also C0a's, so that the contract file itself never holds a body it
could not have:

- `M/MailRowRules.swift` adds `MailRowRules.apply` by extension — the table below.
  (`MailLinkRules.decide` is added the same way by `M/MailLinkRules.swift`, P20b.)
- `M/MailSource+NotYet.swift` gives every requirement of `MailSource` a default, by one
  `extension MailSource` (13.3, "Until it is built"). **A source implements a member by
  declaring it in a file of its own; no source file holds a stub, and no later slice edits an
  earlier slice's file.**

Two things implement the protocol:

- `MailEngine` — the real one, over the stores and Gmail (sections 4–12);
- `MailFixtureSource` — in memory, over the fixture mailbox, for previews, audit routes and UI
  tests (`#if DEBUG || MAIL_FIXTURES`).

Both are built from the same fixture mailbox, defined once at Gmail's level (13.6), and both
pass the same contract tests. There is no adapter between the screens and the engine and there
never is a milestone at which the screens have met only the fixture: from order 1 the real
engine is behind the first screen (18).

**What compiling it changed (C0a).** The declarations compiled as they were written; the
generated interface of the file is the reviewed one except in one type. Three things differ
from the text that was reviewed, and each is now what this section says:

1. **`MailObservation.cancel()` is a method, and the observation stops once.** As written, it
   held the closure as a public `let cancel` and its `deinit` called it again, so a screen
   that cancelled and then let go stopped its observation twice. Now `cancel()` may be called
   any number of times, letting go is the same as cancelling, and the closure runs once.
   Call sites read the same.
2. **A filter is asked of the row as changed** (13.2). The reviewed sentence named three
   changes; the rule they are instances of also covers `done` under `.unread`, which the first
   table already implied by marking read.
3. **The two `discard`s report under different names** to `MailNotYet` (13.3), because
   `#function` gives both `discard(_:)`.

The comments became documentation comments and the section rules became `// MARK:` lines;
no declaration, case, field or default moved.

**What its review changed (C0a, before the commit).** The code review
(`mail-working/review/c0a-code-review.md`) found six things that are each a few lines before
anything compiles against the file and a both-authors change after. All are in the text below:

1. **`MailChange.label` and `.move` carry the account** their label ids are in: Gmail numbers
   a person's labels per mailbox, so one id names different labels in two accounts, and a
   target may span accounts. `MailLabelNode.id` is unique across accounts for the same reason.
2. **`MailRowRules.Outcome.unknown` carries the row as changed**, so a change shows at once
   even where its place cannot be known (a search, Drafts, a custom split). "No reply" is no
   longer asked, and a row whose place is unknown but which certainly fails a filter leaves.
3. **A split is not just the inbox**: `important` moves a conversation between Important and
   Other, and a custom split answers `unknown` for whatever stays in the inbox. The ids of the
   built-in three are constants, `MailSplit.importantID`, `.calendarID`, `.otherID`.
4. **A `MailReceipt` is its `sequence`**: equality and hashing ignore `count`, so the receipt
   kept for undo equals the one an event returns with the count filled in.
5. **The row family is `Codable`** — `MailRow`, `MailRowReason`, `MailListSnapshot`,
   `MailRemoteSearch`, `MailCoverage`, `MailQuestion.Kind` — because the first page of the
   last list is stored (4.11).
6. **A member no source built cannot pass unseen**: one probe calls every member through the
   protocol and is run against both sources; `MailNotYet.onReach` reports a default reached
   in the running app; the default `saveSplits` answers that no split was saved (13.3).

And, smaller: `MailConversationID.init?(text:)`, the way back from `text`; `MailObservation`
may be cancelled from any thread; a snooze does not replace a line that outranks it; comments
saying what a `nil` conversation means and which account wins in a narrowed scope.

### 13.2 The values

```swift
// The one contract between mail's screens and mail's engine: docs/design/MAIL-ENGINE.md,
// section 13, whose two Swift blocks are this file's text and are kept identical to it.
//
// Every type a view or a UI model may name is declared here, with the one protocol they call.
// Two things implement that protocol — the engine, and an in-memory source built from the same
// fixture mailbox — and both must pass the same tests. That is why there is one file: a screen
// built against it has met everything it will ever meet, and there is no adapter to write the
// day the real engine arrives.
//
// The rules of the file. It imports Foundation and Combine and nothing else. It names nothing
// declared outside itself, so it compiles alone (`swiftc -typecheck` on this one file is part
// of its acceptance). It holds no rule's body: `MailRowRules.apply` and `MailLinkRules.decide`
// are added by extension in files of their own. And it changes only together with the
// contract suite, in one commit.
import Foundation
import Combine

// MARK: - Identity

/// A conversation, named the way it is named everywhere outside one device's store: by the
/// account's address and Gmail's thread id. Never a local row id — those are renumbered when a
/// cache is rebuilt, and this value is kept in `ShellState`.
struct MailConversationID: Hashable, Codable, Sendable {
    /// The account's address, lower-cased.
    let account: String
    /// Gmail's thread id, or `"local:<draft id>"` for a new message that has not been sent yet
    /// and so has no thread.
    let thread: String

    /// One string for `ShellState` and for accessibility identifiers.
    var text: String { account + "|" + thread }

    /// Gmail's own web address for the conversation: "Open in Gmail" and "Copy link". Nil for a
    /// thread that exists only on this device.
    var gmailURL: URL? {
        guard !thread.hasPrefix("local:"),
              let who = account.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        return URL(string: "https://mail.google.com/mail/u/\(who)/#all/\(thread)")
    }
}

extension MailConversationID {
    /// The way back from `text`. It splits at the **last** bar: an address may hold one, and a
    /// thread id cannot. Nil when either half is missing. (In an extension so that the struct
    /// keeps its memberwise initialiser.)
    init?(text: String) {
        guard let bar = text.lastIndex(of: "|") else { return nil }
        let account = String(text[..<bar])
        let thread = String(text[text.index(after: bar)...])
        guard !account.isEmpty, !thread.isEmpty else { return nil }
        self.init(account: account, thread: thread)
    }
}

struct MailMessageID: Hashable, Codable, Sendable {
    let account: String
    let message: String
}

/// The device's own id for a draft, stable for the draft's life. Gmail's draft and message ids
/// change on every save and never reach the UI.
struct MailDraftID: Hashable, Codable, Sendable {
    let raw: String
}

/// A message and a part. Never Gmail's `attachmentId`, which is not stable between reads.
struct MailAttachmentID: Hashable, Codable, Sendable {
    let message: MailMessageID
    let part: String
}

/// Where a row stands in its list.
///
/// **A list is its rows in descending key order, in every place.** The engine chooses what the
/// key means there — the newest message carrying the label; the time a snooze ends, reversed;
/// a search's match — so the UI compares and stores keys and never builds or interprets one.
/// It contains nothing local to one device's store.
struct MailOrderKey: Hashable, Comparable, Codable, Sendable {
    /// 0, or 1 for rows only Gmail found in a search: they sort after everything this device
    /// found itself.
    let group: Int
    let sortKey: Int64
    /// A stable hash of the conversation id, so two rows with one `sortKey` still have an order
    /// that is the same on every device.
    let tie: Int64

    static func < (a: MailOrderKey, b: MailOrderKey) -> Bool {
        (-a.group, a.sortKey, a.tie) < (-b.group, b.sortKey, b.tie)
    }
}

// MARK: - Scope

/// This device's retained history. Older mail stays in Gmail and remains searchable.
enum MailSyncLimit: String, Codable, CaseIterable, Sendable {
    case oneMonth, threeMonths, sixMonths, oneYear, everything
    static let standard = MailSyncLimit.sixMonths
}

enum MailMailbox: String, Codable, CaseIterable, Sendable {
    case inbox, starred, important, drafts, snoozed, sent, outbox, done, all, spam, trash, muted
}

enum MailPlace: Hashable, Codable, Sendable {
    /// One of the built-in three (`MailSplit.importantID`, `.calendarID`, `.otherID`), or a
    /// custom split's id.
    case split(String)
    case mailbox(MailMailbox)
    case label(account: String, id: String)
    /// Text in the query grammar (MAIL-ENGINE 9.1).
    case search(String)
    /// The conversations Gmail says were deleted, held until he has answered (5.7).
    case heldRemoval(account: String)
}

enum MailFilter: String, Codable, Sendable {
    case unread, starred, important, noReply
}

struct MailScope: Hashable, Codable, Sendable {
    var place: MailPlace
    var filters: Set<MailFilter> = []
    /// Narrowed to one account; nil is every account. A place that names its own account
    /// (`.label`, `.heldRemoval`) is that account's whatever this says: the place wins.
    var account: String? = nil
}

/// A count that says when it cannot be vouched for: `isAtLeast` while a scan stopped early or a
/// listing is incomplete, or Gmail has more in this place than the device holds.
/// "40+" is drawn from this, never guessed.
struct MailCount: Equatable, Codable, Sendable {
    var value: Int
    var isAtLeast: Bool
}

// MARK: - Text

/// Text the engine hands to the screens and takes back from the composer: meaning, no fonts.
/// The UI maps it to attributed text with its own type styles, in one place — so no screen
/// ever parses a message's HTML, and no HTML-to-attributed-string conversion exists anywhere.
struct MailText: Equatable, Codable, Sendable {
    var blocks: [MailTextBlock]
}

struct MailTextBlock: Equatable, Codable, Sendable {
    enum Kind: Equatable, Codable, Sendable {
        case paragraph
        case quote(depth: Int)
        case item(ordered: Bool, depth: Int, number: Int?)
        case heading(level: Int)
        case preformatted
        case rule
    }
    var kind: Kind
    var runs: [MailTextRun]
}

struct MailTextRun: Equatable, Codable, Sendable {
    var text: String
    var style: MailTextStyle = []
    /// `http`, `https` or `mailto` only — and opened only through `MailLinkRules` (10.7).
    var link: URL?
}

struct MailTextStyle: OptionSet, Codable, Hashable, Sendable {
    let rawValue: Int
    static let bold = MailTextStyle(rawValue: 1)
    static let italic = MailTextStyle(rawValue: 2)
    static let underline = MailTextStyle(rawValue: 4)
    static let strikethrough = MailTextStyle(rawValue: 8)
    static let code = MailTextStyle(rawValue: 16)
}

/// HTML that has been through the sanitiser. Only the engine makes one; the UI stores it and
/// hands it back untouched, and never reads what is inside.
struct MailFragment: Equatable, Codable, Sendable {
    let html: String
}

// MARK: - Rows

struct MailPerson: Hashable, Codable, Sendable {
    /// Cleaned of invisible and direction characters; nil when the address must be shown
    /// instead, because the name itself looks like an address or a link (10.8).
    var name: String?
    /// A non-ASCII domain arrives in its `xn--` form.
    var address: String
    var isMe: Bool
    /// He has written to this address.
    var isKnown: Bool
    /// Set only by `people(matching:)`: known from mail he received and never written to, so it
    /// is offered last, by address, and marked.
    var fromTheirMail: Bool
}

struct MailLabelRef: Hashable, Codable, Sendable {
    /// Gmail's id, or `"local:<name>"` until Gmail has made the label. Both stay valid in every
    /// call for the life of the process.
    ///
    /// **An id is one account's.** Gmail numbers a person's labels per mailbox (`Label_12`), so
    /// the same id names a different label in another account. Whatever takes a label id
    /// therefore takes its account beside it: a place, a change, a suggestion. A ref on a row
    /// or a conversation is of that conversation's account.
    var id: String
    var name: String
    var colorHex: String?
}

/// Why something did not happen. A closed list — never Google's words, which echo what was
/// sent and so may carry an address or a subject into a log (invariant 21).
enum MailFailure: String, Codable, Sendable {
    case tooLarge, addressRejected, signedOut, accessMissing, notAllowedByAdmin
    case labelMissing, limitReached, internalError, other
}

/// The one line under a row's subject, when there is something to say. At most one per row; the
/// cases are in the order they outrank each other.
enum MailRowReason: Equatable, Codable, Sendable {
    /// A question about it is open. The kind is carried so the row alone says which line to
    /// draw: equal rows must make equal displays.
    case asking(MailQuestion.ID, MailQuestion.Kind)
    case failedToSend(MailFailure)
    /// A change to it was refused for good (6.9).
    case changeRefused(MailFailure)
    /// Sent, and still inside the undo hold: "Sending…" with Undo.
    case held(until: Date)
    case waitingToSend, sending, checkingSent
    case scheduled(Date, onThisDevice: Bool, isLate: Bool)
    case draft(firstLine: String)
    case backFromSnooze(due: Date, wasIfNoReply: Bool)
    case snoozed(until: Date, ifNoReply: Bool)
    /// Gmail no longer has it; it is kept on this device by his choice (5.7).
    case keptAfterRemoval
}

struct MailRow: Identifiable, Equatable, Codable, Sendable {
    let id: MailConversationID
    var key: MailOrderKey
    /// The date the row shows. Not the key: where a row sorts and what date it shows differ in
    /// Snoozed and for a conversation back from a snooze.
    var date: Date
    /// Authors in order of first appearance, at most six — recipients instead, in Sent, Drafts
    /// and Outbox.
    var people: [MailPerson]
    var peopleTotal: Int
    var messageCount: Int
    /// As sent, cleaned (10.8). The UI removes "Re:" and "Fwd:".
    var subject: String
    /// Gmail's own; in a search, the excerpt around the match.
    var snippet: String
    var isUnread, isStarred, isImportant, hasAttachment, isInvitation, inInbox, isMuted: Bool
    /// Something about it has not reached Gmail yet.
    var hasPendingChange: Bool
    /// Found by Gmail, not by this device: a search match or a place's older mail.
    var fromGmailSearch: Bool
    /// His own labels only.
    var labels: [MailLabelRef]
    var reason: MailRowReason?
    /// False for a Gmail-only result. Opening fetches its conversation before it can change.
    var isOnDevice: Bool = true
}

struct MailListSnapshot: Equatable, Codable, Sendable {
    var scope: MailScope
    /// The first `limit` rows, in order.
    var rows: [MailRow]
    var total: MailCount
    var hasMore: Bool
    /// Conversations known to belong here whose first message has not arrived yet. An empty
    /// `rows` with this above zero is "still loading", not "nothing here".
    var stillLoading: Int
    /// A split whose membership is being recomputed.
    var isRebuilding: Bool
    /// Any list: nil when Gmail was not asked.
    var remote: MailRemoteSearch?
    /// A search: how much of the mailbox this device could look through.
    var coverage: MailCoverage?
    /// Every command with a sequence up to this is in the rows.
    var appliedThrough: UInt64
    /// This list holds mail since then; older mail may be in Gmail. Nil: the list is whole.
    var heldSince: Date? = nil
}

enum MailRemoteSearch: Equatable, Codable, Sendable {
    case pending, failed, offline, done(added: Int, more: Bool)
}

struct MailCoverage: Equatable, Codable, Sendable {
    var searched: Int
    var of: Int
}

// MARK: - A conversation

/// What kind of body a message has, without the body: the conversation carries this for every
/// message, and the body itself is asked for only when a message is opened.
enum MailBodyState: String, Codable, Sendable {
    case notOnDevice, preparing, text, designed, tooLarge
}

enum MailBodyNotice: String, Codable, Sendable {
    case tooLarge, truncated, shownAsText
}

struct MailPictureBox: Equatable, Sendable {
    var key: String
    var width: Int?
    var height: Int?
}

enum MailPictureGrant: String, Codable, Sendable {
    case sender, domain, everyone
}

enum MailPictureRule: Hashable, Codable, Sendable {
    case sender(String), domain(String), everyone
}

struct MailPictures: Equatable, Sendable {
    /// Every remote picture with the size its sender declared, so the layout does not jump
    /// when pictures arrive.
    var boxes: [MailPictureBox]
    /// Not shown yet.
    var waiting: Int
    /// Held back; zero when tracker blocking is off.
    var trackersRemoved: Int
    /// Sender/domain are offered only when Gmail vouched for the sender; none in Spam.
    var offers: [MailPictureGrant] = []
    var sender: String? = nil
    var domain: String? = nil
    /// The persistent rule showing these pictures, for its matching undo control.
    var shownBy: MailPictureRule? = nil
}

/// A body, ready-made: decided and prepared when the message was fetched, so opening is a read.
/// From `MailSource.body(_:)`, not carried in `MailMessage`.
enum MailBody: Equatable, Sendable {
    case notOnDevice
    case text(MailText, quoteStartsAt: Int?, notices: [MailBodyNotice])
    /// `document` is a whole HTML document for one web view (10.5). It holds no script and no
    /// reachable remote reference; its pictures come only from `MailSource.resource`.
    case designed(document: String, pictures: MailPictures, hasQuote: Bool,
                  plain: MailText, notices: [MailBodyNotice])
}

/// Whether what asks for a picture is in front of him. A picture is never fetched from its
/// sender for a message that is only being made ready (invariant 30).
enum MailPresentation: Sendable {
    case onScreen, warming
}

struct MailResource: Equatable, Sendable {
    var data: Data
    var mimeType: String
}

enum MailDelivery: Equatable, Sendable {
    case held(until: Date), waitingForNetwork, scheduled(Date), sending, checking
    case failed(MailFailure), asking(MailQuestion.ID, MailQuestion.Kind), sentLate(due: Date)
}

struct MailAttachment: Identifiable, Equatable, Sendable {
    let id: MailAttachmentID
    /// Safe to show and to save under (10.8).
    var name: String
    /// What the bytes are, once they are known; what the sender said until then.
    var mimeType: String
    /// The bytes are not what the sender said they were: show a generic icon.
    var typeMismatch: Bool
    var bytes: Int
    /// Non-nil when it is on this device.
    var localFile: URL?
    var isInline: Bool
    var isExecutable: Bool
}

struct MailMessage: Identifiable, Equatable, Sendable {
    let id: MailMessageID
    var from: MailPerson
    var to, cc, bcc, replyTo: [MailPerson]
    /// Which of his addresses received it.
    var deliveredTo: String?
    var listName: String?
    var date: Date
    var isUnread, isMine: Bool
    /// The folded row.
    var firstLine: String
    var body: MailBodyState
    var attachments: [MailAttachment]
    /// His own message, still in the outbox or sent late. Nil once it has simply been sent.
    var delivery: MailDelivery?
    /// Set while it can be reopened.
    var draft: MailDraftID?
}

struct MailInvite: Equatable, Sendable {
    enum Method: String, Sendable {
        case request, cancel, reply, other
    }
    var method: Method
    /// The event is found by the calendar's own lookup of this id — never read from the
    /// sender's file.
    var uid: String
}

enum MailUnsubscribe: Equatable, Sendable {
    case oneClick(host: String), openPage(URL), compose(to: String, subject: String?)
}

struct MailConversation: Equatable, Sendable {
    let id: MailConversationID
    var subject: String
    var labels: [MailLabelRef]
    var inInbox, isStarred, isImportant, isMuted: Bool
    var snoozedUntil: Date?
    /// `.trash` or `.spam` when it is there.
    var system: MailMailbox?
    /// Oldest first; his unsent ones last.
    var messages: [MailMessage]
    var invite: MailInvite?
    var unsubscribe: MailUnsubscribe?
    /// An unsent reply attached to this conversation.
    var draft: MailDraftID?
    var newestIsMine: Bool
    var appliedThrough: UInt64
}

// MARK: - Writing

struct MailIdentity: Hashable, Codable, Sendable {
    var account: String
    var address: String
    var name: String?
    var isDefault: Bool
    /// The signature itself arrives on the draft, in a form that can be drawn.
    var hasSignature: Bool
}

/// A draft's signature or quote: the fragment that is stored and sent, and a way to draw it.
/// `body` is one of the two forms a message's body has (never `.notOnDevice`), prepared by the
/// engine; the UI draws it as it draws a message and hands `fragment` back untouched.
struct MailDraftPart: Equatable, Sendable {
    let fragment: MailFragment
    var body: MailBody
}

struct MailDraftAttachment: Identifiable, Equatable, Codable, Sendable {
    let id: String
    var name: String
    var bytes: Int
    /// Nil for a forwarded attachment that has not been downloaded yet.
    var file: URL?
    var isExecutable: Bool
}

enum MailDraftKind: Equatable, Sendable {
    case new(account: String?)
    case reply(to: MailMessageID), replyAll(to: MailMessageID), forward(MailMessageID)
    /// From a `mailto:` link: To and Subject, and nothing else a link might ask for.
    case toAddress([String], subject: String?)
}

struct MailSchedule: Equatable, Codable, Sendable {
    var at: Date
    var onThisDevice: Bool
    var isLate: Bool
}

struct MailDraft: Identifiable, Equatable, Sendable {
    /// `banana`: written here, as text. `foreign`: written elsewhere in a form the text editor
    /// cannot hold; shown and sendable as it is (7.1).
    enum Format: String, Codable, Sendable {
        case banana, foreign
    }
    let id: MailDraftID
    var conversation: MailConversationID
    var account: String
    var isReply: Bool
    var isForward: Bool
    var from: MailIdentity
    var to, cc, bcc: [MailPerson]
    var subject: String
    var body: MailText
    /// Set nil to send without it.
    var signature: MailDraftPart?
    /// Set nil to remove it; `quoteAsText(in:)` to edit it.
    var quote: MailDraftPart?
    var attachments: [MailDraftAttachment]
    var format: Format
    var schedule: MailSchedule?
    var remindIfNoReply: Date?
    /// Nil while it is simply a draft.
    var delivery: MailDelivery?
    /// What it would weigh as sent. The limit is `MailTuning.maxEncodedBytes`.
    var encodedBytes: Int
    var editedAt: Date
}

// MARK: - Accounts and places

/// What is true of one account's mail on this device (the rules are MAIL-ENGINE 3.4).
enum MailAccountState: Equatable, Sendable {
    /// Mail is not turned on for this account.
    case off
    /// Turned on, but this device has not opened Mail yet: nothing has been fetched.
    case waitingForFirstOpen
    /// Turned on, but this device cannot reach its mail.
    case needsAccess(MailAccessGap)
    /// Usable. How sync is going is `MailSyncHealth`.
    case connected
}

enum MailAccessGap: Equatable, Sendable {
    /// Never allowed on this device.
    case notAllowedHere
    /// Google refused the stored credential, or the scope.
    case withdrawn
}

enum MailSyncHealth: Equatable, Codable, Sendable {
    case live, offline, firstSync, catchingUp
    case limited(until: Date), bytesSpent(until: Date)
    /// Gmail's history ran out: the cache is being compared with Gmail. Nothing disappears
    /// while it is.
    case checking
    case apiDisabled, notAllowedByAdmin, wrongAccount
}

struct MailAccount: Identifiable, Equatable, Sendable {
    /// The address, lower-cased.
    var id: String
    var shortName: String
    /// The synced choice.
    var wantsMail: Bool
    /// What is true on this device.
    var state: MailAccountState
    /// Meaningful when `state == .connected`.
    var health: MailSyncHealth
    var lastSyncAt: Date?
    var identities: [MailIdentity]
    /// Messages he kept though Gmail says they are gone (5.7). Above zero, Settings offers to
    /// remove them.
    var keptAfterRemoval: Int
}

struct MailSplit: Identifiable, Equatable, Codable, Sendable {
    /// The ids of the built-in three. A custom split's id is never one of them.
    static let importantID = "important"
    static let calendarID = "calendar"
    static let otherID = "other"

    var id: String
    var name: String
    /// Nil for the built-in three, which are the engine's rules. Fields and flags only (9.3).
    var query: String?
}

struct MailLabelNode: Identifiable, Equatable, Sendable {
    /// Unique among every account's labels — `"<account>|<label id>"` — so that two accounts'
    /// trees can be drawn in one list. The id a change or a place takes is `ref.id`.
    var id: String
    var ref: MailLabelRef
    var children: [MailLabelNode]
}

/// Two counts for one place. `total` is conversations, read or not — what is left to triage.
/// `total.isAtLeast` while it cannot be vouched for: the inbox still holds conversations whose
/// first message has not arrived (a conversation cannot be put in a split before then), the
/// split is being rebuilt, or the count stopped at 10,000.
struct MailPlaceCount: Equatable, Sendable {
    /// Counts are lower bounds when Gmail holds more in this place than the device does.
    var unread: MailCount
    var total: MailCount
}

struct MailPlaces: Equatable, Sendable {
    /// In the order shown; "other" last.
    var splits: [MailSplit]
    var splitCounts: [String: MailPlaceCount]
    var mailboxCounts: [MailMailbox: MailPlaceCount]
    var outboxNeedsAnswer: Bool
    /// By account. Banana's own labels are never listed.
    var labels: [String: [MailLabelNode]]
    /// Keyed by MailLabelNode.id; count changes do not replace the label tree.
    var labelCounts: [String: MailPlaceCount] = [:]
}

// MARK: - Status

/// What is holding a download up, when something is.
enum MailHold: String, Codable, Sendable {
    case limitedByGoogle, bytesSpentToday, onBattery, deviceWarm, lowPowerMode
    case diskNearlyFull, waitingForWiFi, mailNotOnScreen
}

struct MailDownload: Equatable, Sendable {
    var account: String
    /// Every message since then has its text here.
    var backTo: Date?
    var messagesHere, messagesAbout: Int
    var notYetSearchable: Int
    var secondsLeft: TimeInterval?
    var heldBy: MailHold?
    /// Messages on or after this edge are retained; nil means everything.
    /// The two message counts describe mail inside this limit.
    var limitEdge: Date? = nil
}

enum MailCheck: Equatable, Sendable {
    case running, finished(new: Int, at: Date)
}

enum MailStoreProblem: String, Codable, Sendable {
    case diskFull, damaged, newerVersion, unavailable
}

enum MailStoreState: Equatable, Sendable {
    case notOpened, ready, rebuilding
    /// Reading works; changes are refused, and say so.
    case cannotSave(MailStoreProblem)
    case unavailable(MailStoreProblem)
}

/// A change Gmail will never accept (6.9): what to draw for it, and the receipt `retry` and
/// `discard` take. Listed in the status value rather than announced once, so it is still there
/// after a relaunch.
struct MailRefusedChange: Identifiable, Equatable, Sendable {
    let receipt: MailReceipt
    var change: MailChange
    /// Conversations.
    var count: Int
    var failure: MailFailure
    var account: String

    var id: UInt64 { receipt.sequence }
}

struct MailStatusValue: Equatable, Sendable {
    var isOnline: Bool
    var lastChecked: Date?
    /// Online, and Gmail has not answered since then.
    var unreachableSince: Date?
    /// Google is limiting requests.
    var slowedSince: Date?
    /// A check he asked for.
    var asked: MailCheck?
    /// Changes not yet at Gmail that have waited longer than the delivery debounce's five
    /// seconds, or any at all while offline. So ten quick changes online move nothing here.
    var waitingChanges: Int
    var waitingSince: Date?
    var waitingMessages: Int
    /// One per action.
    var refused: [MailRefusedChange]
    var downloads: [MailDownload]
    var store: MailStoreState
    var questions: [MailQuestion]
}

/// The tab's two numbers. `needsAnswer` is open questions about a send **plus sends that failed
/// for good** — every message of his that did not go and will not go by itself.
struct MailBadgeCounts: Equatable, Codable, Sendable {
    var unreadInFirstSplit: Int
    var needsAnswer: Int

    /// The launch-time mirror (12.4): two integers in `UserDefaults`, written by the engine and
    /// readable by anyone before any store is open. The key and the stored form are here, in
    /// the contract, so the screen that draws the badge can be built before the engine that
    /// writes it. An array of integers, not JSON: nothing of mail's is decoded at launch.
    static let mirrorKey = "mailBadge"

    static func mirrored(in defaults: UserDefaults) -> MailBadgeCounts? {
        guard let pair = defaults.array(forKey: mirrorKey) as? [Int], pair.count == 2 else {
            return nil
        }
        return MailBadgeCounts(unreadInFirstSplit: pair[0], needsAnswer: pair[1])
    }

    func mirror(to defaults: UserDefaults) {
        defaults.set([unreadInFirstSplit, needsAnswer], forKey: MailBadgeCounts.mirrorKey)
    }
}

struct MailStorage: Equatable, Sendable {
    var bodies, attachments, search, index: Int64
}

/// What an `observe…` call hands back. Letting go of it stops the observation; so does
/// `cancel()`, which may be called more than once and from any thread. The closure it was made
/// with runs once, on whichever thread cancels or lets go — so it must not assume the main one.
final class MailObservation: @unchecked Sendable {
    /// Guards `onCancel`: an observation is handed between threads (the engine's own are), and
    /// two cancels arriving together must still stop it once.
    private let lock = NSLock()
    private var onCancel: (() -> Void)?

    init(_ onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    func cancel() {
        lock.lock()
        let stop = onCancel
        onCancel = nil
        lock.unlock()
        stop?()
    }

    deinit { onCancel?() }
}

/// Status is a leaf: the status line, the foot card and the alert cards observe it, and no
/// shell, tab bar or list container does. It changes at the rate of meaning, never per message.
@MainActor final class MailStatus: ObservableObject {
    @Published var value: MailStatusValue
    init(_ value: MailStatusValue) { self.value = value }
}

/// A leaf, like `MailStatus`. Changes only when a number moves.
@MainActor final class MailBadges: ObservableObject {
    @Published var value: MailBadgeCounts
    init(_ value: MailBadgeCounts) { self.value = value }
}

/// A leaf: one attachment's download, 0 to 1.
@MainActor final class MailProgress: ObservableObject {
    @Published var fraction: Double = 0
    init() {}
}

enum MailSuggestion: Equatable, Sendable {
    case from(MailPerson), to(MailPerson), label(MailLabelRef, account: String), split(MailSplit)
}

enum MailPermissionResult: Equatable, Sendable {
    case granted, notGranted, cancelled, differentAccount, noWindow, failed
}

enum MailUnsubscribeResult: Equatable, Sendable {
    /// A 2xx from the list's server. "Asked", not "unsubscribed": nothing proves the second.
    case asked(host: String)
    case failed, unavailable
}

// MARK: - Commands

enum MailChange: Equatable, Codable, Sendable {
    case done, notDone, trash, restore, spam, notSpam
    case read(Bool), star(Bool), important(Bool), mute(Bool)
    /// Label ids, and the account they are ids in (see `MailLabelRef.id`). The change applies
    /// to the target's conversations **in that account**; any others in the target are
    /// untouched and not counted. One receipt, one undo.
    case label(account: String, add: [String], remove: [String])
    /// Add `to`; leave the inbox, and `from` when the list being looked at is a label's. The
    /// ids are `account`'s, and it applies as `label` does.
    case move(account: String, to: String, from: String?)
    case snooze(until: Date, ifNoReply: Bool), unsnooze
}

enum MailTarget: Equatable, Sendable {
    /// As of what the newest reading of each showed: a reply that arrives after the key press
    /// is not swept up in the change (6.1).
    case conversations([MailConversationID])
    /// As of that message — a notification's action.
    case message(MailMessageID)
    /// Every conversation in the scope at or after that key, on screen or not.
    case scope(MailScope, from: MailOrderKey?)
}

/// What a command returns at once.
///
/// `sequence` only grows, and no command is ever given 0: a receipt with `sequence` 0 is the
/// receipt of nothing, which is what a member no source has built returns. `count` is how many
/// conversations the command changed — nil for a `.scope` target until the engine has counted
/// (`MailEvent.applied` follows), and 0 when it changed nothing, in which case a screen shows
/// nothing and offers no undo.
///
/// **A receipt is its sequence.** Two receipts with one sequence are equal whatever their
/// counts. So the receipt a screen kept before the count was known still equals — and, as a
/// dictionary key, still finds — the one that comes back in an event with the count filled in.
struct MailReceipt: Hashable, Sendable {
    let sequence: UInt64
    let count: Int?

    static func == (a: MailReceipt, b: MailReceipt) -> Bool {
        a.sequence == b.sequence
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(sequence)
    }
}

struct MailSendOptions: Equatable, Sendable {
    /// The undo hold. Nil: the hold he chose in Settings. 0: Send now.
    var hold: TimeInterval?
    /// Send and Done: one receipt covers both.
    var thenDone: Bool
    /// Send later: nil is now, after the hold. The schedule a draft then carries is
    /// `MailDraft.schedule`, set by the engine (13.10).
    var at: Date? = nil
}

// MARK: - Questions: things only he can decide

struct MailQuestion: Identifiable, Equatable, Sendable {
    struct ID: Hashable, Codable, Sendable {
        let raw: String
    }
    enum Kind: Equatable, Codable, Sendable {
        /// Gmail says many messages were deleted; they are held, not removed (5.7).
        case removalHeld(account: String, count: Int)
        /// A send whose result is unknown and cannot be found in Sent (7.4).
        case sendUnconfirmed(MailDraftID, draftStillInGmail: Bool?)
        /// A message he sent long ago that had not gone (7.4).
        case sendLate(MailDraftID, since: Date)
        case draftChangedElsewhere(MailDraftID)
        case scheduleChangedElsewhere(MailDraftID)
        case scheduleOwnedElsewhere(MailDraftID)
        /// Changes that had not reached Gmail could not all be read back (4.10).
        case changesLost(recovered: Int)
    }
    let id: ID
    var kind: Kind
    /// The ones that apply, in the order to offer them.
    var choices: [MailChoice]
}

enum MailChoice: String, Codable, Sendable {
    /// `removalHeld`.
    case remove, keepHere
    /// `sendUnconfirmed`.
    case checkAgain, sendAgain, keepAsDraft
    /// `sendLate`, with `keepAsDraft`.
    case sendNow
    /// `draftChangedElsewhere`.
    case keepMine, useOther
    /// The two schedule questions.
    case sendFromHere, cancelSchedule
    /// `changesLost`.
    case acknowledge
}

// MARK: - What the engine says unasked

/// Events carry ids and closed enums — never a subject, an address or Google's words. The UI
/// looks up what it needs to say, and may show it; neither side may log it.
enum MailEvent: Equatable, Sendable {
    /// A `.scope` target has been counted.
    case applied(MailReceipt, count: Int)
    /// The change could not be saved: it was put back on screen, and nothing was sent.
    case notSaved(MailReceipt, MailStoreProblem)
    /// What he is typing is in memory only, until a save succeeds.
    case draftNotSaved(MailDraftID, MailStoreProblem)
    /// Gmail refused it for good; it is shown as not done.
    case refused(MailReceipt, MailFailure)
    /// Undo arrived after the message had left.
    case sendGone(MailReceipt)
    case sent(MailDraftID, MailConversationID)
    case sentLate(MailDraftID, due: Date, sent: Date)
    case sendFailed(MailDraftID, MailFailure)
    case asked(MailQuestion)
    /// A question answered itself, or was answered elsewhere.
    case settled(MailQuestion.ID)
}

// MARK: - Pure rules the screens share with the engine

struct MailQueryToken: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case word, phrase, operatorName(String), value, negation, unknownOperator
    }
    /// In UTF-16 units of the typed text.
    var range: Range<Int>
    var kind: Kind
}

/// What a change does to one row of one list, decided from the row and the scope alone — which
/// is what lets a change show in the same turn as the key press, with nothing read.
///
/// `MailRowRules.apply(_:to:in:) -> Outcome` is added by extension in MailRowRules.swift.
enum MailRowRules {
    enum Outcome: Equatable, Sendable {
        /// The row as changed.
        case stays(MailRow)
        /// It no longer belongs here. The row as changed is carried for a list that keeps
        /// showing it until the place is next entered.
        case leaves(MailRow)
        /// Whether it still belongs is not known here. Draw the row as changed, where it is,
        /// and let the next reading decide.
        case unknown(MailRow)
    }
}

enum MailLinkWarning: String, Codable, Sendable {
    case goesElsewhere, lookalikeHost, pictureLink
}

/// What to do with a tapped link (10.7). The only way a link in mail is ever opened.
enum MailLinkDecision: Equatable, Sendable {
    case refuse
    case open(URL)
    case openAfterWarning(URL, MailLinkWarning)
    case compose(to: [String], subject: String?)
}

/// `MailLinkRules.decide(url:shownText:shownIsImage:) -> MailLinkDecision` is added by extension
/// in MailLinkRules.swift, with the HTML packages. Until then nothing can call it, and
/// `decideLink` answers `.refuse`.
enum MailLinkRules {}
```

`MailRowRules` is what lets a change show in the same turn as the key press without the main
thread reading anything (6.2). It answers from the row and the scope alone, in three steps —
and **every answer carries the row as changed**, so the change itself always shows at once;
what can be unknown is only where the row belongs.

**First, whose change it is.** A label's id is one account's (`MailLabelRef.id`), so `label`
and `move` name the account their ids are in. A row of another account is not touched by
such a change: the rule answers `stays` with the row exactly as it was, not pending, in every
place. (The engine applies the same rule to a target that spans accounts: the conversations
of the named account are changed and counted, the others are not.)

**Then, the row as changed** — the same in every place:

| Change | The row afterwards |
|---|---|
| `done` | `inInbox` false, `isUnread` false |
| `notDone`, `notSpam`, `unsnooze` | `inInbox` true; `unsnooze` also clears a `.snoozed` reason |
| `trash`, `spam`, `move(account:to:from:)` | `inInbox` false; `move` also drops `from` from `labels` |
| `restore` | unchanged (where it returns to is Gmail's to say) |
| `read(b)` / `star(b)` / `important(b)` | `isUnread = !b` / `isStarred = b` / `isImportant = b` |
| `mute(b)` | `isMuted = b`; when true, `inInbox` false |
| `snooze(until:ifNoReply:)` | `inInbox` false; `reason = .snoozed(until:ifNoReply:)` — **unless a reason that outranks a snooze is showing** (a question, a refused change, any state of a send, a schedule, a draft), which is kept. Nothing, an earlier snooze, "back from snooze" and "kept after removal" are replaced. |
| `label(account:add:remove:)` | `labels` loses every ref whose id is in `remove`. **An added label is not drawn yet**: the rule has only its id, not its name or colour; the next reading brings it. |
| every change | `hasPendingChange` true |

**Then, whether it still belongs.** The kinds of place are: *inbox* — `.split(_)` and
`.mailbox(.inbox)`; *done* — `.mailbox(.done)`; *label-like* — `.mailbox(.all)`, `.sent`,
`.starred`, `.important`, `.muted` and `.label(_, _)`; *bin* — `.mailbox(.trash)` and `.spam`;
*snoozed* — `.mailbox(.snoozed)`; *search* — `.search(_)`; *composed* — `.mailbox(.drafts)`,
`.mailbox(.outbox)` and `.heldRemoval(_)`.

| Change | inbox | done | label-like | bin | snoozed | search | composed |
|---|---|---|---|---|---|---|---|
| `done` | leaves | stays | stays | stays | leaves | unknown | unknown |
| `notDone` | stays | leaves | stays | stays | unknown | unknown | unknown |
| `trash` | leaves | leaves | leaves | stays in Trash; leaves Spam | leaves | leaves | unknown |
| `spam` | leaves | leaves | leaves | stays in Spam; leaves Trash | leaves | leaves | unknown |
| `restore` | stays | stays | stays | leaves Trash; stays in Spam | stays | unknown | unknown |
| `notSpam` | stays | stays | stays | leaves Spam; stays in Trash | stays | unknown | unknown |
| `read(b)` | stays | stays | stays | stays | stays | stays | unknown |
| `star(b)` | stays | stays | stays; `star(false)` leaves `.starred` | stays | stays | stays | unknown |
| `important(b)` | stays — but see the splits, below | stays | stays; `important(false)` leaves `.important` | stays | stays | stays | unknown |
| `mute(true)` | leaves | stays | stays | stays | stays | unknown | unknown |
| `mute(false)` | stays | stays | stays; leaves `.muted` | stays | stays | unknown | unknown |
| `snooze` | leaves | stays | stays | stays | stays | unknown | unknown |
| `unsnooze` | stays | leaves | stays | stays | leaves | unknown | unknown |
| `label(account:add:remove:)` | stays | stays | stays; leaves `.label(_, id)` when `id` is in `remove` | stays | stays | unknown | unknown |
| `move(account:to:from:)` | leaves | stays | stays; leaves `.label(_, id)` when `id == from` | stays | leaves | unknown | unknown |

**A split is a part of the inbox, and a row that stays in the inbox may still change split.**
The *inbox* column is the answer for `.mailbox(.inbox)`. For a split, a change that leaves the
inbox leaves the split; one that stays in the inbox is then asked of the split:

| Split | A change that stays in the inbox |
|---|---|
| `.split("important")` — "marked important" | stays; **`important(false)` leaves** (it goes to Other) |
| `.split("other")` — the rest | stays; **`important(true)` leaves** (it goes to Important) |
| `.split("calendar")` — "has an invitation" | stays: no change alters that |
| any other id — a custom split | **unknown**, whatever the change: a custom split's query may test flags and labels (9.3), and the rule does not have it |

The three ids are `MailSplit.importantID`, `.calendarID` and `.otherID`. One thing the rule
cannot see at all: **a custom split claiming a row out of a built-in one** — labelling a
conversation in Important when a custom split collects that label. Custom splits are matched
first (9.3), so the next reading drops the row from Important though the rule said `stays`.
Nothing vanishes under the cursor for that reason, because **a list keeps a row he has just
marked, whatever the next reading says** (MAIL-UX T17) — not only when the rule answered
`leaves`.

**And the scope's filters, last.** They are asked of a row that would stay and of one whose
place is unknown — a row that has left has left — and they are asked of **the row as
changed**: it *leaves* when it now fails a filter the scope carries (`isUnread` under
`.unread`, `isStarred` under `.starred`, `isImportant` under `.important`). So `read(true)`
leaves an unread-only list, and so does `done`, which marks read — in a search and in Drafts
too, where the place alone would have been unknown: that it no longer passes is certain.
`star(false)` and `important(false)` leave theirs. **`.noReply` is not asked**: no change
alters whether anyone has replied, so a row that was in the list still passes it.

**What each answer asks of a list.** `stays(row)`: draw the row as changed. `leaves(row)`: the
row no longer belongs; remove it, or — for a marking action — keep drawing the row carried,
dimmed, until the place is next entered (MAIL-UX T17). `unknown(row)`: draw the row as
changed, where it is, and let the next reading decide whether it belongs; it arrives a few
milliseconds later. So Done on a search result shows at once as a row without its inbox mark
(MAIL-UX 3.10, case 19), though whether it still matches the search is not known here. **The
engine's own snapshots never contain a row that has left**; a list that keeps one does so
itself.

**One test holds the two implementations of this table together**: for every change, every
kind of place and every fixture conversation, where `MailRowRules` answers `stays` or
`leaves`, `ViewMembershipRules` after the commit answers the same
(`MailRowRulesAgreementTests`, created by P05 — the first package to have both). It runs with
**no custom split defined** — with one, a built-in split's `stays` can be contested by the
claim described above, which is the rule's stated limit and not a disagreement — and it has
nothing to compare where the rule answers `unknown`. Until P19a ships the timed labels, the
engine does not accept `.snooze`, `.unsnooze` or `.mute` at all (`apply` returns `count` 0 and
shows nothing), so the two cannot disagree about them; the test gains those rows with P19a.

### 13.3 The protocol

```swift
// MARK: - The protocol

/// Everything a screen may ask of mail. Every requirement has a default in
/// MailSource+NotYet.swift, so a source builds a member by declaring it and holds no stubs.
@MainActor protocol MailSource: AnyObject {

    // MARK: Life

    /// The first Mail screen calls this. At most 1 ms on the main actor; returns at once.
    func activate()
    /// Whether a Mail screen is in front. Drives polling (12.1); nothing else reads it.
    func setVisible(_ visible: Bool)

    // MARK: Reads

    var accounts: [MailAccount] { get }
    /// This device's history policy, independent of the provider's retained mail.
    var syncLimit: MailSyncLimit { get }
    /// Returns at once: raising fetches more; lowering releases local cached conversations.
    func setSyncLimit(_ limit: MailSyncLimit)
    /// Held conversations this limit would release, for confirmation and progress.
    func conversationsBeyond(_ limit: MailSyncLimit) async -> Int
    func observeAccounts(_ onChange: @escaping @MainActor ([MailAccount]) -> Void) -> MailObservation
    func observePlaces(_ onChange: @escaping @MainActor (MailPlaces) -> Void) -> MailObservation
    /// The one synchronous read. Up to `MailTuning.firstPageRows` rows of the scope last shown,
    /// or nil. It never touches a database.
    func cachedFirstPage(_ scope: MailScope) -> MailListSnapshot?
    /// The first `limit` rows of a scope, kept current. To show more, observe again with a
    /// larger limit (`listStep` more each time, up to `listCap`); the new observation's first
    /// value arrives before the old one is let go.
    func observeList(_ scope: MailScope, limit: Int,
                     _ onChange: @escaping @MainActor (MailListSnapshot) -> Void) -> MailObservation
    /// One conversation, kept current. `nil` means this device holds no such conversation now:
    /// it was never fetched, or it has been removed. It never means "not read yet" — nothing is
    /// delivered before the first reading is done — and the observation stays live, so a
    /// conversation that arrives later is delivered then.
    func observeConversation(
        _ id: MailConversationID,
        _ onChange: @escaping @MainActor (MailConversation?) -> Void
    ) -> MailObservation
    /// One reading of it; `nil` as for `observeConversation`.
    func conversation(_ id: MailConversationID) async -> MailConversation?
    /// A message's body, ready-made. Never fetches; `.notOnDevice` when it is not here.
    func body(_ id: MailMessageID) async -> MailBody
    /// A picture a designed body refers to (10.5). Nil: answer 404. Fetches a remote picture
    /// only when `presentation == .onScreen` and the picture rules allow it.
    func resource(_ url: URL, for message: MailMessageID,
                  presentation: MailPresentation) async -> MailResource?
    func suggestions(for text: String) async -> [MailSuggestion]
    func people(matching text: String, limit: Int) async -> [MailPerson]
    /// Pure; for the search field's chips and highlighting. The UI has no tokenizer of its own.
    func queryTokens(_ text: String) -> [MailQueryToken]
    /// A link tapped in a designed body: looks up what was shown for it, then `MailLinkRules`.
    /// (A web view reports only the address, so the mismatch warning needs this lookup.)
    func decideLink(_ url: URL, in message: MailMessageID) async -> MailLinkDecision
    func draft(_ id: MailDraftID) async -> MailDraft?
    var status: MailStatus { get }
    var badges: MailBadges { get }
    func attachmentProgress(_ id: MailAttachmentID) -> MailProgress
    func storageUsed() async -> MailStorage

    // MARK: Changes to conversations

    /// A conversation this device does not hold is not changed; its receipt counts zero.
    @discardableResult func apply(_ change: MailChange, to target: MailTarget) -> MailReceipt
    @discardableResult func undo(_ receipt: MailReceipt) -> MailReceipt
    /// A refused change: try again.
    func retry(_ receipt: MailReceipt)
    /// A refused change: give it up.
    func discard(_ receipt: MailReceipt)

    // MARK: Drafts and sending

    /// A new draft, durable before this returns, addressed by the engine's reply rules.
    func newDraft(_ kind: MailDraftKind) async -> MailDraft
    /// Nothing waits on it.
    func save(_ draft: MailDraft)
    func addAttachment(_ file: URL, to draft: MailDraftID) async -> MailDraftAttachment?
    func removeAttachment(_ id: String, from draft: MailDraftID)
    /// A foreign draft, made editable.
    func rewriteAsText(_ draft: MailDraftID) async -> MailDraft?
    /// "Edit the quote": its text joins `body` as quoted blocks and `quote` becomes nil. Its
    /// design and pictures are lost, and the UI says so before calling.
    func quoteAsText(in draft: MailDraftID) async -> MailDraft?
    /// Send from another of his addresses: `from` and the signature are replaced together.
    func changeIdentity(of draft: MailDraftID, to address: String) async -> MailDraft?
    /// A picture a draft's designed signature or quote refers to; as the other `resource`.
    func resource(_ url: URL, forDraft draft: MailDraftID,
                  presentation: MailPresentation) async -> MailResource?
    /// Undoable.
    @discardableResult func discard(_ draft: MailDraftID) -> MailReceipt
    @discardableResult func send(_ draft: MailDraftID, _ options: MailSendOptions) -> MailReceipt
    /// True: it is a draft again, durably. False: it has left.
    func cancelSend(_ draft: MailDraftID) async -> Bool
    func retrySend(_ draft: MailDraftID)
    /// Whether leaving now would strand a message (the Mac's quit; 7.5).
    var hasUnfinishedSends: Bool { get }
    /// Ends every undo hold and sends. Returns when nothing is left to hand over, or after
    /// `limit`.
    func finishSends(within limit: TimeInterval) async

    // MARK: Questions

    func answer(_ question: MailQuestion.ID, _ choice: MailChoice)

    // MARK: Fetching: hints and requests; none is waited on

    func checkNow()
    /// Ask Gmail for search matches or a place's mail older than the local edge (9.4).
    /// Again requests the next page or retries. Bounded-history searches also ask automatically.
    func askGmail(_ scope: MailScope)
    /// The cursor rests here: have these ready. Never fetches anything from a sender.
    /// A conversation not held here is fetched whole from Gmail and then retained.
    func wants(_ ids: [MailConversationID])
    func fetchBody(_ id: MailMessageID)
    func fetchAttachment(_ id: MailAttachmentID)
    /// Nil means this message only; otherwise the explicit persistent permission chosen.
    func showPictures(in id: MailMessageID, always grant: MailPictureGrant?)
    /// Every persistent picture permission, including everyone, and the way back from each.
    func pictureRules() async -> [MailPictureRule]
    func removePictureRule(_ rule: MailPictureRule)

    // MARK: Accounts, splits, labels

    func setWantsMail(_ on: Bool, account: String)
    /// The one interactive call: Google's consent for this account's mail, on this device.
    func requestPermission(account: String) async -> MailPermissionResult
    /// This device's credential. Revokes nothing at Google.
    func forgetPermission(account: String)
    /// Returns the ids of splits whose query cannot be kept as a view (free text); they are
    /// not saved.
    @discardableResult func saveSplits(_ splits: [MailSplit]) -> [String]
    func createLabel(named name: String, account: String) -> MailLabelRef
    /// After the UI's confirmation, for a `.oneClick` offer only.
    func unsubscribe(_ id: MailConversationID) async -> MailUnsubscribeResult
    func removeDownloadedMail(account: String?) async
    /// Settings' "Remove mail that Gmail no longer has": raises `removalHeld` again for the
    /// messages he kept (`MailAccount.keptAfterRemoval`), to be answered like the first time.
    func reconsiderKeptMail(account: String)

    // MARK: What the engine has to say unasked

    func observeEvents(_ onEvent: @escaping @MainActor (MailEvent) -> Void) -> MailObservation
}

/// Every number a screen and the engine share.
enum MailTuning {
    static let firstPageRows = 50
    static let listStep = 100
    /// Prototype P1 decides whether this can rise.
    static let listCap = 2_000
    static let searchMinimumCharacters = 2
    static let maxOpenDesignedBodies = 6
    /// A message as sent; about 25 MB of attachments.
    static let maxEncodedBytes = 35 * 1_048_576
}
```

**Until it is built.** `M/MailSource+NotYet.swift` (C0a) is one `extension MailSource` that
gives every requirement the default below and records that it was reached
(`MailNotYet.reached(#function)`; the names are read from `MailNotYet.reachedNames` — and the
two `discard`s, which share a `#function`, record `"discard(_:) receipt"` and
`"discard(_:) draft"`). A source that has not built a member simply does not declare it.

**A default must not pass for a built member.** A quiet answer is also how a forgotten member
looks, and how one looks whose source declared it with a near-miss signature — a wrong label,
`async` on a synchronous requirement — which Swift accepts as an overload and the protocol
never calls: every screen then gets the default while the source's own tests, which call the
concrete type, pass. Three things turn that into a failure someone sees:

- **One probe, both sources.** `T/MailSourceProbe.swift` (C0a) calls every one of the 59
  members once, through the protocol, and returns the defaults reached. C0a asserts that a
  source with no members reaches all 59 — which proves the probe is complete and every default
  reports — and that the 59 are the protocol's requirements, counted from the contract's
  source. **Gate F runs the same probe on `MailEngine` and on `MailFixtureSource` and asserts
  that neither reaches any default**, less a short list, named in the test, of members that
  come after the first release (`createLabel`, `unsubscribe`, and whatever D20 defers).
- **`MailNotYet.onReach`** is called each time a default is reached. P24 sets it where it
  builds the engine: an `assertionFailure` in a debug build, one journal line carrying the
  member's name in a release one. A default reached on a device is then not silent.
- **No default claims success.** A change answers with a count of 0; `saveSplits` answers
  with every id, which means none was saved.

| Members | Until built |
|---|---|
| `setSyncLimit`, `activate`, `setVisible`, `checkNow`, `askGmail`, `wants`, `fetchBody`, `fetchAttachment`, `showPictures`, `removePictureRule`, `save`, `removeAttachment`, `retry`, `discard(_: MailReceipt)`, `retrySend`, `answer`, `setWantsMail`, `forgetPermission`, `reconsiderKeptMail`, `finishSends`, `removeDownloadedMail` | Nothing happens |
| `observeAccounts`, `observePlaces`, `observeList`, `observeConversation`, `observeEvents` | Nothing is ever delivered; the observation returned does nothing |
| `accounts`, `suggestions`, `people`, `queryTokens`, `pictureRules` | `[]` |
| `saveSplits` | The id of every split it was given: none was saved |
| `cachedFirstPage`, `conversation`, `draft`, both `resource`s, `addAttachment`, `rewriteAsText`, `quoteAsText`, `changeIdentity` | `nil` |
| `syncLimit` | `.sixMonths` |
| `conversationsBeyond` | `0` |
| `body` | `.notOnDevice` |
| `decideLink` | `.refuse` |
| `status`, `badges` | One shared instance each: `isOnline` true, `store` `.notOpened`, everything else empty or zero |
| `attachmentProgress` | A new `MailProgress` at 0 |
| `storageUsed` | Zeros |
| `apply`, `undo`, `discard(_: MailDraftID)`, `send` | `MailReceipt(sequence: 0, count: 0)` |
| `newDraft` | A draft with a new random id, the kind's account or "", everything else empty, `format: .banana`; it is saved nowhere |
| `cancelSend`, `hasUnfinishedSends` | `false` |
| `requestPermission` | `.failed` |
| `createLabel` | `MailLabelRef(id: "local:" + name, name: name, colorHex: nil)` |
| `unsubscribe` | `.unavailable` |

| Command | Undo | What a screen may assume |
|---|---|---|
| `apply` | `undo(receipt)` | Returns at once with a receipt whose `sequence` only grows. Before it returns, every live observation has delivered a snapshot that includes the change (`appliedThrough >= sequence`). `.done` also marks read. A conversation Gmail no longer has makes the change a success, not a refusal. If it could not be saved: `notSaved`, and the rows are back. |
| `undo` | — | Puts back exactly what that `apply` changed, for every target, from what each conversation was before. A change not yet delivered is cancelled, not delivered and reversed. `count` 0: there was nothing left to undo (an older session's receipt). |
| `retry`, `discard` (a receipt) | — | For a change in `status.value.refused`, which lists each with its receipt and survives a relaunch. Discard makes the row show Gmail's truth and forgets the change. |
| `newDraft` | `discard` | The draft exists on disk when it returns. Recipients, subject, identity, signature and quote are the engine's (`ReplyRules`); the UI never computes them. |
| `save` | — | Durable on this device within half a second and on every pause. Never blocks; never fails visibly **while the store can save**. If the commit fails, or `status.store` is `.cannotSave`, the engine keeps the text in memory, announces `MailEvent.draftNotSaved` once, retries on every later `save` and when the store recovers, and the composer shows "Not saved — this iPhone is full" until a save succeeds (invariants 4 and 9). `addAttachment` returns nil and announces the same when the file cannot be copied in. A scheduled draft owned by another device is not changed: the question `scheduleOwnedElsewhere` is raised instead. |
| `discard` (a draft) | `undo(receipt)` restores it, for the life of the process | The Gmail draft is deleted only when the undo can no longer happen. |
| `send` | During the hold, `cancelSend`; `undo(receipt)` also reverses the Done of Send and Done | `options.hold == nil` uses the hold he set in Settings (a synced setting the engine reads; no screen needs its value). From the next reading the message is in its conversation with a `delivery`. Leaving the app during the hold sends it (7.5). No device ever sends one message twice by itself. |
| `cancelSend` | — | Truthful; answers only once the answer is durable — a few milliseconds. |
| `answer` | — | The question leaves `status.questions` in the same turn; what was chosen happens through the ordinary paths. |
| `checkNow` | — | `status.asked` becomes `.running`, then `.finished(new:at:)`, counting only mail from elsewhere. |
| `askGmail` | — | Ask for search matches or older mail in an observed place; repeat for the next page or retry (9.4). |
| `setSyncLimit` | Change the limit again | Returns at once; raising fetches more, lowering releases local copies (5.4). |
| `reconsiderKeptMail` | Answer `keepHere` again | Does nothing when the account has kept nothing. |
| *(no call)* a draft reaching Gmail's Drafts | — | The engine uploads a draft when `save` has not been called for it for 60 seconds — which is what closing the composer looks like from here — when the app goes to the background, and before a send (7.3). A screen calls nothing for it. |
| `wants`, `fetchBody`, `fetchAttachment`, `showPictures` | — | Results arrive as changes to observations or progress. Offline they are remembered for this session. `wants` never fetches anything from a sender (invariant 30). |
| `setWantsMail` | Call it again | Off hides the account's mail at once and stops syncing it; what is downloaded stays until removed. |
| `saveSplits` | The UI keeps the previous list | Synced between devices. Counts and membership follow at the next reading; `isRebuilding` meanwhile. |
| `createLabel` | — | Usable in a change at once, online or not. |
| `quoteAsText`, `changeIdentity` | The UI keeps the previous draft value and saves it again | The returned draft is durable. A draft part's `body` is drawn exactly as a message's body is; its pictures follow the rules of the message it quotes (10.6), and a signature's are his own and load when the composer is on screen. |
| `removePictureRule` | `showPictures(in:alwaysFromSender: true)` on a message from that domain | Synced like the choice it reverses (8.5). Pictures already on the device stay; the next message from that domain asks. |

### 13.4 Status, badges and events

- `status` is one leaf observable. Online, offline, a finished check and a new question change it
  at once; the download figures at most every two seconds; and it never changes more than once
  a second otherwise (invariant 13). **No shell, tab bar or list container observes it** — the
  status line, the foot card and the alert cards do; a list's empty area learns of `store`
  and `questions` through those, not by observing status itself (promise 8).
- `badges` changes only when a number moves. It is readable at launch, before any store is
  open, from the `mailBadge` mirror (12.4).
- `attachmentProgress(id)` is one leaf observable per attachment, at most four changes a second.
- `MailEvent`s carry ids and closed enums — never a subject, an address or Google's words. The
  UI looks up what it needs to say, and may show it; neither side may log it.
- Open questions are in `status.value.questions` for as long as they are open, and each is also
  announced once as `MailEvent.asked`. A question about a draft also shows on that draft's row
  and message (`MailRowReason.asking`, `MailDelivery.asking`), each carrying the question's
  kind, so a row can be drawn from the row alone.
- Refused changes are in `status.value.refused`, one per action, for as long as they are
  neither retried nor discarded — across a relaunch, because the receipt is rebuilt from the
  stored rows' `group_seq` (6.9).

### 13.5 What a screen may rely on

1. **A command returns at once, with a number.** `apply`, `undo`, `send`, `discard`, `save`
   return synchronously and never throw.
2. **Every reading says which commands it includes** (`appliedThrough`). Because the source
   applies a command to its own observations before returning, a screen needs no overlay of its
   own; one that keeps an overlay anyway finds it empty.
3. **The engine owns the reverse of a change.** The UI owns only the screen that undo returns
   to.
4. **A target can be a scope**, resolved by the engine: one receipt, one undo.
5. **One synchronous read exists, and only one**: `cachedFirstPage`. It never touches a
   database. Everything in it is durable: a change shown in it is in `intent.sqlite` and will be
   delivered, so it is still true after a relaunch.
6. **Readings arrive at the rate of meaning** (invariant 13): at once for his own command; at
   most once a second per observation from sync; never per message. His own changes are never
   counted as new mail.
7. **Bodies are ready-made.** A message's body was decided and prepared when it was fetched;
   `body(_:)` is a read of a few milliseconds. A designed document contains no script and no
   reachable remote reference; pictures come only through `resource`.
8. **Nothing is represented by an empty list.** An empty list means the place is empty, and
   only when `stillLoading == 0`, `isRebuilding == false` and the store is `ready`.
9. **The cursor is the UI's, and a leaf.** No engine object publishes anything when the cursor
   moves; `wants` is a hint that publishes nothing. A held `J` therefore cannot make a list
   container re-evaluate through the engine (invariant 14).
10. **Order is the engine's.** Rows arrive sorted; the UI never sorts, and never compares a key
    with anything but another key from the same scope.
11. **Restoring a position needs no extra call**: the UI stores the limit it had and the id of
    the row at the top, observes with that limit, and finds the row by id.

### 13.6 Two sources, one fixture mailbox, one test suite

**The fixture mailbox is defined once, at Gmail's level.** It holds what Gmail holds, as
Gmail's own JSON, in Swift literals — no file is read, because the app's routes need it and
`BananaTests/Fixtures` is not in the app — and, kept apart, the things this *device* has done
that Gmail does not know, because some states a screen must draw are not Gmail's.
`M/Testing/MailFixtureMailbox.swift` (C0b; `#if DEBUG || MAIL_FIXTURES`):

```swift
struct MailFixtureMailbox {
    struct Account { var address: String; var labels: String; var sendAs: String }   // labels.list and sendAs.list JSON
    struct Conversation {
        var key: String            // the fixture's name — "forty", "newsletter" — and its accessibility key
        var account: String
        var messages: [String]     // each a whole users.messages.get (format=full) JSON object, oldest first
    }
    struct Draft { var key: String; var account: String; var message: String }       // a messages.get JSON with DRAFT
    /// What is true on this device and not in Gmail. Each source applies these after loading.
    enum DeviceState {
        case bodyNotFetched(conversation: String)                      // "headers-only"
        case attachmentFetched(conversation: String, part: String)     // every other attachment is not on the device
        case unsent(draft: String, MailDelivery)                       // waiting, held, failed, asking…
        case refusedChange(conversation: String, MailChange, MailFailure)
        case heldRemoval(conversations: [String])
        case question(MailQuestion.Kind)
    }
    var accounts: [Account] = []
    var conversations: [Conversation] = []
    var drafts: [Draft] = []
    var device: [DeviceState] = []
    /// The oracle of the read tests: for each place, by name, the fixture keys in list order.
    var expectedOrder: [String: [String]] = [:]
    mutating func add(_ part: MailFixtureMailbox)

    /// Every part in `MailSlices.fixtureParts`, added together. The one value both sources load.
    static var standard: MailFixtureMailbox { get }
    /// `standard` plus generated mail — the 5,200-row list. The same for the same seed.
    static func bulk(conversations: Int, seed: UInt64 = 1) -> MailFixtureMailbox
}
```

- A later package adds conversations by adding a part: a function in
  `MailFixtureMailbox+<package>.swift` and one line in `MailSlices.fixtureParts` (18.2).
- Items too large for a literal — the 1.2 MB newsletter, the 2.4 MB attachment, the hostile
  messages of 17.5 that are large by design — are made by seeded functions when the mailbox is
  built.
- The bulk builder makes Gmail JSON, so that what it makes passes through the fake and through
  sync. The benchmark's generator (`M/Bench/MailSynthetic.swift`, P09a) is a different thing
  on purpose: it writes index rows directly, for stores of 200,000 messages.
- `MailFixtureMailbox+Fake.swift` (P10a) loads the Gmail half into a `FakeGmail`.
  `MailEngine.onFixtures` (P23a) then syncs to completion and applies the device half through
  the stores' own operations; the in-memory source applies it to its own model.

The two sources:

- `MailEngine` on the fixtures = the real engine, temporary stores, `FakeGmail` loaded with the
  mailbox, synced to completion before the first frame. It is what a route shows by default.
- `MailFixtureSource` (the UX's, `MailUI/Pure/Testing/`; `--mail-source memory`) = an in-memory
  implementation that derives its rows by running the same pure rules (`ThreadSummaryRules`,
  `ViewMembershipRules`, `MailBuiltInSplits`, `MailRowMapper`, `MailRowRules`, and later
  `OutboxRules` and `MailHTMLPreparer`) over the same mailbox. It has no SQLite and no sync; it
  exists so a preview can draw in a few milliseconds and so the contract has a second
  implementation to be tested against. It is the one UI file allowed to name those engine
  types (invariant 32).

**The contract suite** (`T/MailContractTests.swift`, C0b) is a base `XCTestCase` whose tests run
against whatever its subclass supplies:

```swift
struct MailContractSubject {
    var source: MailSource
    var elsewhere: MailFixtureElsewhere                 // a change made "in Gmail", by another client
    var advance: (TimeInterval) async -> Void           // move the clock; let sync and sleepers run
    var settle: () async -> Void                        // until nothing is in flight
}
protocol MailFixtureElsewhere {
    func archive(_ key: String) async
    func markRead(_ key: String) async
    func label(_ key: String, add: [String], remove: [String]) async
    func deliver(_ message: String, into key: String?, account: String) async    // a messages.get JSON
    func delete(_ key: String) async
}
class MailContractTests: XCTestCase {
    /// The base class has no subject and skips. A subclass per source overrides this.
    func makeSubject() async throws -> MailContractSubject { throw XCTSkip("no source") }
}
```

Every test runs against both subclasses — `MailFixtureSourceContractTests` (U0′) and
`MailEngineContractTests` (P23a). The read tests compare each scope's rows with
`MailFixtureMailbox.standard.expectedOrder`, written by hand; from P23a,
`MailSourcesAgreeTests` (the UX's) also compares the two sources with each other, row for
row. After that: every command yields the same next snapshot on both; `appliedThrough` and
receipts behave as 13.5 says; publish counts are as invariant 13 says (which is what
`elsewhere` and `advance` are for: sync-driven deliveries cannot be tested without a change
from elsewhere and a clock); questions can be answered. A behaviour the UI depends on is
added here first. **The suite runs for the first time in U0′** — C0b, which writes it, has no
source to run it on.

**What the real engine is built from** — the only things it takes from outside the pure folder,
all handed in:

```swift
struct MailEnvironment {
    var access: MailAccountAccess
    var gmail: GmailAPI
    var clock: MailClock
    var directories: MailDirectories
    var role: MailDeviceRole                               // .phone, .pad, .mac
    var journal: MailJournal
    var settings: MailSettings                             // wantsMail, hold seconds, pictures; synced lists (8.5)
    var notifier: MailNotifier
    var isOnline: @Sendable () -> Bool
    var onlineChanges: @Sendable (@escaping @Sendable (Bool) -> Void) -> MailObservation
    var isCheapNetwork: @Sendable () -> Bool
    var power: @Sendable () -> MailPower                   // onMains, lowPowerMode, thermalFairOrWorse
    var freeDiskBytes: @Sendable () -> Int64
    var beginBackgroundWork: @Sendable (_ name: String) -> MailBackgroundWork     // call .end() when done
    var findEvent: @Sendable (_ uid: String) async -> Bool                        // the calendar's lookup
    var otherPeople: @Sendable () async -> [MailPerson]                           // GuestSources
    var networkAllowed: @Sendable () -> Bool                                      // 12.5
}
enum MailDeviceRole: Sendable { case phone, pad, mac }
struct MailPower: Equatable, Sendable { var onMains: Bool; var lowPowerMode: Bool; var thermalFairOrWorse: Bool }
struct MailBackgroundWork: Sendable { let end: @Sendable () -> Void }
enum RemoteImageSetting: String, Codable, Sendable { case askFirst, always }   // "always": for everyone (10.6)
enum MailNotifySetting: String, Codable, Sendable { case firstSplit, inbox, off }
struct MailNotificationContent: Equatable, Sendable {
    enum Kind: String, Sendable { case newMail, summary, backInInbox, waitingToSend, sendFailed }
    var kind: Kind
    var title: String, subject: String?, snippet: String?      // snippet only if the setting allows (12.3)
    var count: Int
    var conversation: String?                                  // MailConversationID.text, for the tap
}
protocol MailClock: Sendable {
    var now: Date { get }
    func sleep(until deadline: Date) async throws          // throws CancellationError
}
protocol MailNotifier: Sendable {
    func post(_ content: MailNotificationContent, id: String) async
    func schedule(_ content: MailNotificationContent, id: String, at: Date) async
    func withdraw(ids: [String]) async
    func withdraw(prefix: String) async
}
protocol MailSettings: Sendable {
    func wantsMail(_ account: String) -> Bool
    func setWantsMail(_ on: Bool, account: String)
    var undoSendSeconds: TimeInterval { get }
    var pictures: RemoteImageSetting { get }; func setPictures(_ setting: RemoteImageSetting)
    var blockTrackers: Bool { get }                        // "Block tracking pixels"; true unless he turned it off
    var notifyFor: MailNotifySetting { get }               // 12.3; the Settings screen writes the same synced field
    var splits: [MailSplit] { get }; func saveSplits(_ splits: [MailSplit])
    var pictureRules: Set<MailPictureRule> { get }         // `.sender` and `.domain` only: the synced list (8.5)
    func addPictureRule(_ rule: MailPictureRule); func removePictureRule(_ rule: MailPictureRule)
}
```

`MailEnvironment.live()` is built in `Banana/Model/MailApp/MailWiring.swift`; tests build one
from fakes in a line. The engine is created lazily by `MailRuntime.shared.source`, never at
launch (invariant 16).

The block shows these types together; **each is declared by the package that first uses it**,
which is not always the one that declares `MailEnvironment` (P23a): `MailClock`, the protocol,
by P01a (`M/MailClock.swift`), for the token flight; `SystemMailClock` and `ManualMailClock`
by P02 (`M/MailClocks.swift`); `MailDeviceRole` and `MailPower` by P02 (`M/MailDevice.swift`),
for the work pace; `MailJournal` and `MailDirectories` by P02; `GmailAPI` by P10a; and
whatever in the block no earlier package has needed, by P23a.

### 13.7 Inside the engine: feeds and the change hub

Not contract — this is how `MailEngine` keeps the promises of 13.5, stated so that P23a's
implementer does not have to invent it.

- **`MailListFeed`**, one per `observeList` call, lives on the main actor. It holds `base` (the
  rows of the last index read, and the sequence that read was tagged with) and `pending` (its
  own optimistic changes with a higher sequence). What it delivers is `base` with `pending`
  applied through `MailRowRules`.
  - On `apply`: append to `pending`, recompute, deliver — synchronously, no I/O.
  - On a commit notice from the writer (below) that touches its view: read `limit` rows off the
    main thread (`pool.read`), then on the main actor replace `base`, drop every pending change
    the read's tag has reached, recompute, and deliver **only if the rows differ**.
  - On `notSaved` for a receipt: drop that pending change, recompute, deliver.
  - Sync-driven deliveries are coalesced to one a second; the feed's own commands are never
    delayed.
- **`MailConversationFeed`** is the same shape for one conversation: index rows merged with the
  conversation's unsent rows from `intent.sqlite` (7.4).
- **`MailChangeHub`.** After every index commit the writer hands (4.2: once `write` has
  returned, on its own queue — not from inside GRDB's commit callback)
  its summary of that transaction — the view keys and conversation ids it touched, and
  the highest command sequence it carried — to the hub, which wakes only the feeds whose view
  or conversation is in it. A commit that touched nothing a feed shows wakes nothing. GRDB's
  `ValueObservation` is not used: it re-runs queries per transaction, and the rate here must be
  the engine's to set.
- Rows are decoded by column index from a cursor into `MailRow`; no `Codable` record types on
  the list path.
- Outbox and Drafts are composed places: Drafts merges local draft rows with `DRAFT`
  conversations (7.3); Outbox lists messages in `held` … `needsDecision` and `failed`. Refused
  changes are not rows of that place: they are `status.value.refused`. Both places are read
  from `intent.sqlite` on the writer's queue and are small. `.heldRemoval` is composed too, from `held_removal` (4.4), and exists
  from P13a.
- `MailPlacesFeed` reads, for every place it lists, both counts of `MailPlaceCount` in one
  read (`MailIndexReader.counts` already returns unread, total and still-loading per view),
  at most once a second and only after a commit that touched one of those views.
- `cachedFirstPage` returns the value `MailFirstPaint` decoded at launch (4.11), or the first
  `MailTuning.firstPageRows` rows of the last snapshot a feed for that scope delivered in this
  process.

### 13.8 What belongs in `ShellNavigation`

`ShellState` gains one optional field, `mail`, decoded with `decodeIfPresent`. The struct is the
UI's (MAIL-UX 3.10). The engine's requirements of it:

- It holds scopes without their search text, conversation ids, draft ids, a limit and
  booleans — **never a draft's text, a subject, a query, or anyone's address but his own
  accounts'** (a scope's `account` and a conversation id are his own addresses; invariant 9,
  P-20). A test encodes one built from a session full of marker strings — the account
  addresses left unmarked — and asserts no marker is in the JSON. Recent searches are kept in
  memory for the session and nowhere else in the first release; if they are ever kept longer
  it will be in the engine's own store, never in `UserDefaults` or the journal.
- It is pruned on load against conversations that still exist.
- Once a draft is sent or discarded the composer field is cleared, so it cannot reopen over a
  later screen.
- Not here: the cursor, a scroll offset in points, anything per frame.

### 13.9 Two seams left open on purpose

- **Turning a message into a reminder or an event.** `MailReference` — account, conversation
  id, `Message-ID`, subject — with Gmail's own web address for the conversation, which is what
  is written into a reminder or an event's notes because it works everywhere today. A
  `banana://mail/…` link is **not registered in the first release** (P-7). When it is, it
  navigates only — to a conversation already on the device, in a connected account — and never
  fetches, composes or acts; arriving from outside the app it asks first.
- **An on-device model.** `MailAssist` is a protocol with no implementation, bound by the rules
  of 10.11.

### 13.10 What the owner's rulings change in the contract

The owner reviewed the direction and ruled on six things (22, rows M1–M6). Four of them change
`MailContract.swift`. C0c applies the table below to the compiled contract, its defaults, the member
probe and the shape tests together. The blocks of 13.2 and 13.3 now match that
source. This declares the engine boundary; it does not implement live Gmail sync
or replace the fixture source. Validation artifacts are retained under
`.build/mail-contract-owner-20261010`; full app acceptance remains separate. (The block of
13.6, which is `MailEnvironment`'s and not the contract file's, is already as ruled.) Every new field
has a default value, so no place that builds one of these values by its memberwise
initialiser has to change. The last column names the package that makes the member *do*
something; until then `MailSource+NotYet` answers it.

| Declaration | Before | After | Declared · built |
|---|---|---|---|
| `MailSyncLimit` | — | `enum MailSyncLimit: String, Codable, CaseIterable, Sendable { case oneMonth, threeMonths, sixMonths, oneYear, everything }`, with `static let standard = MailSyncLimit.sixMonths` | C0c · P05 (`MailHoldRules`) |
| `MailSource.syncLimit` | — | `var syncLimit: MailSyncLimit { get }` — this device's; default `.sixMonths` | C0c · P13b |
| `MailSource.setSyncLimit(_:)` | — | `func setSyncLimit(_ limit: MailSyncLimit)` — returns at once; raising starts a fetch, lowering a release (5.4) | C0c · P13b |
| `MailSource.conversationsBeyond(_:)` | — | `func conversationsBeyond(_ limit: MailSyncLimit) async -> Int` — held conversations a limit would release: the number for the confirmation, and afterwards how many are still to go; default 0 | C0c · P13b |
| `MailDownload` | `account, backTo, messagesHere, messagesAbout, notYetSearchable, secondsLeft, heldBy` | adds `var limitEdge: Date? = nil` — mail on or after it is what this device keeps; nil: everything. `messagesHere` and `messagesAbout` are of the mail inside the limit | C0c · P13b |
| `MailListSnapshot` | … `remote`, `coverage`, `appliedThrough` | adds `var heldSince: Date? = nil` — this list holds its mail since then, and older mail may be in Gmail (`askGmail`); nil: the list is whole. `remote`'s comment: any list, not only a search | C0c · P23a |
| `MailRow` | … `fromGmailSearch`, `labels`, `reason` | adds `var isOnDevice: Bool = true` — false for a row only Gmail found whose conversation this device does not hold: opening it fetches it, and it takes no change until then. `fromGmailSearch`'s comment: found by Gmail and not by this device — in a search, or as a place's older mail | C0c · P05 (the mapper), P23e |
| `MailRemoteSearch` | `case pending, failed, done(added: Int)` | `case pending, failed, offline, done(added: Int, more: Bool)` | C0c · P23e |
| `MailSource.searchGmail(_:)` | `func searchGmail(_ scope: MailScope)` — a `.search` scope only | **renamed** `func askGmail(_ scope: MailScope)` — ask Gmail for what this list does not hold: a search's matches (again, or the next fifty), or a place's mail older than the edge (9.4). A search is asked without it whenever the device does not hold everything | C0c · P23e |
| `MailSource.wants(_:)` | "have these ready" | comment adds: a conversation this device does not hold is fetched from Gmail, whole, and is then held | C0c · P23c, P23e |
| `MailSource.apply(_:to:)` | — | comment adds: a conversation this device does not hold is not changed; `count` 0 | C0c · P23b |
| `MailCount.isAtLeast`, `MailPlaceCount` | "a scan stopped early or a listing is incomplete" | comment adds: or Gmail has more in this place than the device holds (5.4) | C0c · P13b |
| `MailPlaces` | `splits, splitCounts, mailboxCounts, outboxNeedsAnswer, labels` | adds `var labelCounts: [String: MailPlaceCount] = [:]`, keyed by `MailLabelNode.id` — a count for every label, apart from the tree so that a count changing does not change the tree | C0c · P23a |
| `MailPictureGrant` | — | `enum MailPictureGrant: String, Codable, Sendable { case sender, domain, everyone }` — which "always" he is choosing, for the message in hand | C0c |
| `MailPictureRule` | — | `enum MailPictureRule: Hashable, Codable, Sendable { case sender(String), domain(String), everyone }` — an "always" he has chosen | C0c |
| `MailPictures` | `boxes, waiting, trackersRemoved, senderDomain: String?` | `senderDomain` **removed**; adds `var offers: [MailPictureGrant] = []` (what may be offered for this message: `.sender` and `.domain` only when Gmail vouched for its sender; none in Spam), `var sender: String? = nil` and `var domain: String? = nil` (what those two would name, for the menu's words), `var shownBy: MailPictureRule? = nil` (the rule showing them now, with the way back). `trackersRemoved`: held back, zero when blocking is off | C0c · P23c |
| `MailSource.showPictures` | `func showPictures(in id: MailMessageID, alwaysFromSender: Bool)` | `func showPictures(in id: MailMessageID, always grant: MailPictureGrant?)` — nil: this message only | C0c · P23c |
| `MailSource.alwaysShownPictureDomains()` | `async -> [String]` | **replaced by** `func pictureRules() async -> [MailPictureRule]` — every "always" in force, `.everyone` among them | C0c · P23c |
| `MailSource.stopAlwaysShowingPictures(from:)` | `(from domain: String)` | **replaced by** `func removePictureRule(_ rule: MailPictureRule)` | C0c · P23c |
| `MailSendOptions` | `hold: TimeInterval?`, `thenDone: Bool` | adds `var at: Date? = nil` — send later: nil is now, after the hold. The schedule a draft then carries is `MailDraft.schedule`, set by the engine; "remind me if no reply" stays `MailDraft.remindIfNoReply`, set by the composer and saved with the draft | C0c · P18b, P19b |

With it: `MailSource` has 59 requirements, not 56 (`MailSourceProbe.everyMember`,
`MailSourceTreeTests`); `MailSource+NotYet` has the three new defaults and the four renamed
ones; the "Until it is built" and command tables of 13.3 take the same names; the stored-form
test gains `MailSyncLimit`, `MailPictureRule` and `MailPictureGrant`.

**What the new layout needs of this section** (the owner's ruling: a control column, the list,
a reading pane and a details column on a wide window; the UX author is revising the screens).
Checked against the contract as it will stand after C0c:

- **A pane that follows the cursor.** Served, with nothing added. When the cursor rests the
  screen calls `wants([id])`, observes the conversation and asks for the body of the message
  it will show; `wants` publishes nothing (13.5, promise 9), so a held `J` reaches no
  container. **What a rest costs:** for a conversation the device holds — every row of an
  ordinary list — one index read of the conversation's rows and one or two blob reads, a few
  milliseconds off the main thread, no request and no write. (`thread.attended_at` is written
  at most once a day per conversation, and only for one whose newest message is within a
  month of the edge or past it: a conversation well inside the limit is held by its date and
  needs no mark.) For a row only Gmail found: one `thread` read, 40 units, and the
  conversation is then held (9.4). A designed body costs a web view, of which at most
  `MailTuning.maxOpenDesignedBodies` are alive. **What the pane must not do** is count as
  "on screen" for pictures before he has stopped on it (10.6); marking read is the UX's rule
  and is an ordinary `apply`.
- **A details column.** Served: `MailConversation` carries the labels, the flags, the snooze,
  the invitation (`invite`, whose event the screen finds through the calendar) and every
  message, and `MailMessage` carries everyone it is from and to, its date and its
  attachments. The column is read off the value the pane already observes; it asks for
  nothing more. A list of "everyone in this conversation" and "every attachment in it" is a
  fold over `messages`, which the screen may do.
- **A control column that is always visible.** `observePlaces` already delivers every place's
  counts together, and the places feed recounts only the views a commit touched, at most once
  a second (13.7) — so counts for seventy places cost what counts for the one in front cost.
  **One thing is missing: labels have no counts.** `MailPlaces.labelCounts` (the table above)
  adds them. Unread counts come off a partial index (0.41 ms for twelve, MEASURED) and totals
  are capped at 10,000 (4.4); with a six-month limit every view is smaller than the ones
  those numbers were measured on. Counts per account for each mailbox are not in the
  contract; if the control column lists accounts separately, `MailPlaces` needs them, and
  the store already has the views.

## 14. Saying what is true

Every state the owner can be in, what the engine reports, and what a screen can therefore say.

| Situation | Detected by | Reported | True things to say |
|---|---|---|---|
| Offline | `isOnline`, `GmailError.neverLeft` | `health = .offline`, `lastSyncAt` | "Offline. Showing mail as of 14:02. 3 changes will send when you're back." Everything works. |
| Online, Gmail not answering | `unknownOutcome`, `server` on every call for a minute | `status.unreachableSince` | "Can't reach Gmail since 14:02." Not "offline". |
| Mail never allowed on this device | `MailGrant.none` | `state = .needsAccess(.notAllowedHere)` | "Allow Mail on this iPhone." |
| Google withdrew mail's access | `MailGrant.rejected`, or 403 for the scope | `state = .needsAccess(.withdrawn)` | "Google no longer lets Banana read this account's mail. Allow it again." Cached mail stays readable; changes queue. The calendar is unaffected and says nothing. |
| Gmail API not enabled for the project | 403 `accessNotConfigured` | `health = .apiDisabled` | A setup problem, in those words, for the developer — him. |
| A Workspace admin forbids it | 403 `domainPolicy` | `health = .notAllowedByAdmin` | "This organisation doesn't allow Banana to read mail." No retry loop. |
| Rate limited | limit errors | `health = .limited(until)`, `status.slowedSince` | Nothing, unless it lasts; then "Syncing is paused until 14:07". |
| The day's bytes spent | the governor's counter, or Google's limit | `health = .bytesSpent(until)` | "Older mail will keep downloading tomorrow. New mail is unaffected." |
| History expired | `notFound` from `history` | `health = .checking` | "Checking this account against Gmail." Nothing disappears while it checks. |
| First sync or fill under way | queues not empty | `.firstSync` / `.catchingUp`, `downloads` | "Everything since March 2019 is on this iPhone. 61,204 older messages to go." On a phone: "This takes days of normal use" (5.4). |
| The fill is paused | the pace, the floor | `downloads[].heldBy` | "Paused while on battery", "…while this iPhone is warm", "…this iPhone is nearly full". |
| A list ends at the sync limit | 5.4 | `MailListSnapshot.heldSince` | "Mail before 6 April is in Gmail, not on this Mac. Older mail in Gmail…" — never an end that looks like the end of the mail. |
| A search, under a sync limit | 9.4 | `remote`, `coverage`, rows with `fromGmailSearch` | "On this Mac: mail since 6 April. From Gmail: 12 older results." While it waits: "Searching Gmail…". |
| A search Gmail could not answer | 9.4 | `remote = .offline` or `.failed` | "Gmail was not searched — offline. Showing what is on this Mac." Try again. |
| A count that Gmail's exceeds | 5.4 | `MailCount.isAtLeast` | "12+": at least twelve; more are older than this device keeps. |
| The limit was lowered | 5.4 | `conversationsBeyond(syncLimit)` | "Removing mail older than 6 January from this Mac — 3,120 conversations to go. It stays in Gmail." |
| Search does not cover everything | 5.9 | `MailListSnapshot.coverage` | "Searched 23,117 of 100,412 messages." |
| A body is not here and it is offline | `MailBodyState.notOnDevice` | per message | "This message's text isn't on this iPhone. It will load when you're online." |
| A change could not be saved | 6.2 | `MailEvent.notSaved`, `store = .cannotSave` | "Couldn't save that — this iPhone is full." The row is back. |
| A change was refused for good | 6.9 | `MailEvent.refused`, `status.value.refused`, the row's reason | "Couldn't move 3 conversations: that label no longer exists. Retry · Discard." |
| A send cannot be confirmed | 7.4 S4 | question `sendUnconfirmed` | "Banana can't confirm this was sent. It isn't in Sent, and its draft is still in Gmail." Check again · Send again · Keep as a draft. |
| A message is going out late | 7.4 S6, 7.6 | `sentLate` / question `sendLate` | "Sent a message that had been waiting since 14:02." |
| A scheduled send's device is not this one, and it is late | the draft's headers | `MailSchedule.isLate` | "Scheduled for 8:00 on another device — not sent yet. Send now from here." |
| Many removals at once | invariant 3 | question `removalHeld` | "Gmail says 4,210 messages on this Mac were deleted. Remove them here too?" Remove · Keep on this Mac. |
| Token for the wrong address | invariant 2 | `health = .wrongAccount` | An internal error, said as one; that account's sync is stopped. |
| The cache is being rebuilt | 4.10 | `store = .rebuilding` | "Rebuilding mail on this device." Unsent changes are untouched and still listed. |
| Pending changes could not be read | 4.10 | `store = .unavailable(.damaged)`, question `changesLost` | "Banana couldn't read changes that hadn't been sent yet. 4 were recovered; some may be lost." |
| The app is older than its stored changes | 4.9 | `store = .unavailable(.newerVersion)` | "Update Banana to use Mail on this device." Nothing is reset. |
| Beta | compile flag | — | Beta is isolated from Banana's data, not from the mailbox: a send from Beta is a real send. |

## 15. Performance budgets

Budgets are for a device (iPhone, Release) at 200,000 messages. The "this Mac" column is
evidence that a budget is reachable, not proof that it is met: every figure was taken with the
machine's load average between 600 and 830 (other work was running all day), so each is an
upper bound, and quiet medians will be recorded by `--verify-mail-bench` (17.6) when the first
packages exist. Budgets that rested on the first draft's byte scan, its 8 MB caches or its
50-message batch are restated here.

| What | Budget | This Mac (MEASURED, loaded) | Checked by |
|---|---|---|---|
| App launch, Mail not the restored tab | Nothing of mail's before the first frame except two `BGTaskScheduler.register` calls | — | Whole-app gate: every launch mark within the noise of the baseline |
| First frame with Mail restored | One file read and decode ≤ 2 ms on the main thread; no other main-thread I/O | 0.27 ms p50, 0.45 ms p95 (50 rows, 24.9 KB) | `LaunchClock` mark `mail.snapshot`; bench `firstPage` |
| `activate()` | ≤ 1 ms on the main actor, never awaited there; first real page ≤ 60 ms later, off the main thread | 45 ms p50, 73 ms p95 for four stores, 30 overlay rows and a page | Structural test (P23a); bench `activate`; journal `✉️ activate` |
| A list read, first 100 rows | ≤ 5 ms p95 | 0.11 ms p50 for 50; 0.37 ms for 400 | Bench `pageRead` |
| A list read at the cap (2,000 rows) | ≤ 20 ms p95, off the main thread | 1.8 ms p50, 7.0 ms p95 | Bench `listRead2000`; ratio to 400 rows ≤ 6 |
| Applying a new reading to the list on screen | The UX's budget; depends on the host | — | Prototype P1 (`listApply` at 400 and 2,000 rows) |
| Unread counts for 12 views | ≤ 3 ms | 0.41 ms p50, 1.3 ms p95 | Bench `unreadCounts12` |
| Opening a conversation: its rows | ≤ 5 ms p95 | 0.13 ms p50, 0.99 ms p95 | Bench `conversationRows` |
| Opening a conversation: a prepared body | ≤ 10 ms a message: a keyed read and an inflate, **no HTML work** | inflate 0.05 ms for 261 KB | Bench `bodyRead`; a counting parser asserts zero parses |
| Opening a message that is not prepared yet | ≤ 100 ms for 63 KB of HTML, off the main thread, behind a placeholder | 15.4 ms (63 KB), 64.9 ms (261 KB) with SwiftSoup | Bench `prepare`; device run |
| Preparing at fetch | Never on the main thread; paced; ≤ 20 ms per 100 KB on this Mac | 3.9 MB/s | Bench `prepare` on the fixtures and the hostile set; 2 MB + 1 refused |
| A change: main thread | ≤ 1 ms; no I/O | — (an array edit through `MailRowRules`) | A blocking fake store: `apply` returns without it |
| A change: durable | ≤ 20 ms p95 on a phone | 0.84 + 0.21 ms p50; 2.1 + 0.78 ms p95 | Bench `intentCommit`, `writeThrough`; **the phone's full fsync is ASSUMED 5–40 ms: owner run 1** |
| A burst: 10 changes in a second, and 300 scripted in ten | No dropped frame from mail; 0 `MailStatus` changes; one list delivery per change; ≤ 2 commits per 20 ms burst | one commit of 50 changes costs 1.1 ms p50 | Publish-count test; coalescing test; gate route `mail-triage` |
| Search as you type, two or more letters | Median ≤ 5 ms; p95 ≤ 30 ms **on the phone, not yet shown**; a superseded query ends ≤ 10 ms | p50 0.35–4.3 ms; p95 30–52 ms cold and loaded; interrupt 1.5 ms | Bench `fts2…fts6` over forty words; owner run 1 decides `prefix` (4.6) |
| Recipient lookup | ≤ 10 ms p95 | 1.2 ms p50, 3.0 ms p95 | Bench `recipients` |
| A sync batch's hold on the writer | ≤ 30 ms p95 on a phone | 6.2 ms p95 for 20 messages with a reader active | Bench `syncBatch20`; the batch size is the knob |
| A poll that finds nothing | 0 writes, 0 publishes, ≤ 5 ms CPU | — | Unit test counting commits and deliveries |
| Polling | One wake a minute with Mail on screen, sharing its tolerance with the app's other minute timer; plus at most twelve polls in the minute after he asks or arrives (12.1) | — | Gate: wake-ups against the baseline; `PollRulesTests` for the burst's bounds |
| Local passes off mains | ≤ 25 % of one core averaged over 10 s; none when warm or in Low Power Mode | — | Gate route `mail-reindex`: `⚡ POWER` average; thermal nominal |
| The fill with Mail on screen, on battery | 2 requests in flight; the paced share for local work | — | Owner run 4 |
| Foreground, Mail visible, idle | ≈ 0 % CPU between polls; no STORM line | — | Gate idle run; `PerfWatchdog` |
| iOS background | No request, sleeper or write outside a `BGTask`; the process suspends as before | — | `MailSuspendTests`; owner run 5 (the two-hour soak) |
| SQLite page caches | ≤ 31 MB in total (4.2) | — | `sqlite3_status` in the journal's minute line |
| Memory, the whole app | ≤ baseline + 60 MB with Mail open on a list; ≤ baseline + 100 MB with six designed messages open, and back to + 60 MB within 60 s of leaving | — | Gate routes `mail-inbox`, `mail-newsletter` |
| Memory, web content processes | ≤ 150 MB with six web views | — | Owner run 2 (the Simulator cannot show it) |
| Disk at 200,000 messages | index ≈ 0.17 GB; search 0.4–1.1 GB; bodies and prepared output 3–8 GB (ASSUMED); attachments to their ceiling; never under the free-space floor | index 172.7 MB; search 1.1 GB on synthetic text | Counters in `MailStorage`; owner run 3 replaces every ASSUMED |

Standing rules, from PERF-PLAN and the owner's notes, as they apply here:

- Shells do not observe `MailStatus`, `MailBadges` or any list. The Mail section's own root
  observes what it draws; the tab badge reads one number through a zero-size presenter.
- Row views are small `Equatable` types, split so a Release build's stack frames stay small;
  `ScreensOpenUITest` on a device in Release after any large view change.
- No un-quantised value in a `PreferenceKey`.
- `RenderStats.note("MailShell")` on the section's container, which must not re-evaluate on
  cursor moves or changes.
- No `@AppStorage` key with a dot in it anywhere under mail.
- Every gate re-runs the whole app's gate, not only mail's routes.

## 16. Diagnostics

Engine files cannot name `PlaybackDiagnostics` or `Signpost` (invariant 17), so they log through
a value the app hands in (`MailEnvironment.journal`). **Its shape is what enforces invariant
21**: a line is an event from a closed list and typed fields — there is no parameter a subject,
an address or Google's error text could be passed in.

```swift
struct MailJournal: Sendable {
    var line: @Sendable (_ event: MailJournalEvent, _ fields: [MailJournalField]) -> Void
    var begin: @Sendable (_ name: StaticString) -> MailSignpost      // .end()
}
enum MailJournalEvent: String, Sendable {
    case activate, sync, syncQuiet, quota, reconcile, outbox, send, prepare, index, store, search, wake, bg, ui
}
enum MailJournalField: Sendable {
    case count(StaticString, Int), ms(StaticString, Double), flag(StaticString, Bool)
    case account(Int)                              // a1, a2: position in the account list
    case id(StaticString, MailJournalID)           // a salted hash, below
    case code(StaticString, any MailJournalCode)   // a closed enum's raw value
}
protocol MailJournalCode: RawRepresentable, Sendable where RawValue == String {}   // adopted only by closed enums
struct MailJournalID: Sendable {
    /// The first 10 hex digits of SHA-256 over the salt, a bar, the account, a bar, the id —
    /// **the two bars are literal bytes ("|")**, so that account "ab", id "c" and account "a",
    /// id "bc" are not one hash. The salt is random per install and kept in intent.sqlite's
    /// meta, so a session's lines match each other and nothing outside the device.
    init(salt: Data, account: String, id: String)
}
```

`GmailError`, `MailFailure`, `MailStoreProblem`, `SendRules.State`'s case name and the like adopt
`MailJournalCode`. `String` does not.

| Line | Fields |
|---|---|
| `✉️ activate` | `ms`, stores opened, intents pending, overlay rows |
| `✉️ sync` | account, kind (`poll`/`reconcile`/`fill`), history pages, added, deleted, held, label changes, fetched, units, bytes, `ms`, checkpoint moved |
| `✉️ syncQuiet` | at most once an hour: polls since, all empty |
| `✉️ quota` | account, event (`limited`/`recovered`/`bytesSpent`), rate, pause, lane |
| `✉️ reconcile` | account, listings, ids, additions, to verify, gone, held, units, `ms` |
| `✉️ outbox` | account, sent, requests, units, settled, retried, refused, split batches, verifying |
| `✉️ send` | draft (hashed), step, outcome, attempt, check number, `ms` — every step of 7.4 |
| `✉️ prepare` | prepared, as text, too large, crashed-before, behind, `ms` |
| `✉️ index` | messages indexed, behind, `ms` |
| `✉️ store` | file, event (`checkpoint`/`quickCheck`/`corrupt`/`rebuilt`/`migrated`/`full`/`floor`), size, `ms` |
| `✉️ search` | characters, operator kinds, hits, `ms`, asked Gmail — never the text |
| `✉️ wake` | due, asserted, re-derived away, kind |
| `✉️ bg` | task, steps done, expired, `ms` |
| `✉️ ui` | the UI's own lines, through the same value |

One line per pass, not per message. Signposts wrap `mail.sync`, `mail.apply`, `mail.prepare`,
`mail.index`, `mail.send`.

**The UI logs under the same rule, without naming an engine type.** `MailJournal` is not in
the contract, so no screen can name it (invariant 32). The UI is handed one closure at wiring
(P24) — `MailUILog`, declared on the UI's side as `(_ name: StaticString, _ counts:
[StaticString: Int], _ milliseconds: Double?) -> Void` — which the wiring forwards to the
journal's `ui` event. Its shape, like the journal's, has nowhere to put a subject or an
address. No file under `Banana/Views/Mail/` or `Banana/Model/MailUI/` names
`PlaybackDiagnostics`, `DiagnosticJournal`, `Logger`, `os_log` or `print(`; a test greps for
those tokens (P-12).

**Storm detection.** `PerfWatchdog` gains sinks for `MailStatus` and `MailBadges`
(`objectWillChange → RenderStats.note("mail↻")`), attached when the engine is first created, so
a mail storm names itself. The sinks and the watchdog's probes must exist on the Mac too and
without `--perf-trace` (whole-app findings F11, F12 — order 0).

**The paced passes are not a storm.** The watchdog's CPU line is told which mail pass is
running (`MailWorkPace.current`), so a prepare pass at a fifth of a core is reported as that and
is checked against *its* budget, not flagged as a runaway (R-3).

**The privacy test** (`MailJournalPrivacyTests`): a whole first sync, a search, a triage burst,
a draft and a send against a fake mailbox in which every subject, sender, recipient, snippet,
body, file name, label name, query, account address and error text contains a marker string.
The fake's access and refresh tokens carry the marker too (N-9). Captured: every journal line,
and every thrown error's `String(describing:)`. Asserted: the marker appears in none. A static
test also refuses, in every mail file, a string interpolation of `accessToken`,
`refreshToken`, a `MailAccessToken`'s `value`, `allHTTPHeaderFields` or a `URLRequest`. P24 adds the same assertion over the real files — `playback.log` and
`Diagnostics/events.ndjson` in the route's temporary directory.

The existing journal carries calendar event titles (`calendar news`); mail does not follow that
precedent.

## 17. Testing

### 17.1 Layers

| Layer | What | Where |
|---|---|---|
| Pure rules | One test class per rule file; sentences for names; fixed dates; small builders that decode JSON literals into the real model; failure messages that say the consequence | `BananaTests/Mail…Tests.swift` |
| Store | Real GRDB stores in a temporary directory; schema, migrations, the pragmas read back, the read queries' *plans* asserted by **absence** — no `SCAN` of a table and no `TEMP B-TREE` in the plan text — overlay rebuild, damaged files, a full disk | same |
| Engine against the fake | Sync, outbox, drafts, send, timed labels — whole flows, no network, a manual clock | same |
| Two engines, one fake | Separate directories and device ids against one `FakeGmail`: every cross-device behaviour of sections 6–8, **each run with every switch of 17.2 both ways** | same |
| The contract | `MailContractTests`, against `MailEngine` and `MailFixtureSource` (13.6) | same |
| HTML | Every hostile fixture (17.5); the differential test against libxml2; the limits | same |
| HTTP | `GmailHTTP` against canned responses **recorded by the probe** (19.2): request shapes, error mapping, upload framing | fixtures in `BananaTests/Fixtures/Gmail/` |
| Shape assertions | Things a Debug Simulator can decide: plans; zero writes and zero publishes on an empty poll; publish counts per command; no request after `suspend()` | same |
| Benchmarks | `--verify-mail-bench` (17.6): a Release build, ratios against recorded medians | the Mac app |
| Screens | Launch-argument routes on the fixture mailbox; `BananaUITests` by accessibility identifier | UX packages |

- **Thread Sanitizer runs over the mail tests at every gate** (E-27), not once.
- No test touches a real mailbox, the real `AppSupport.directory`, the keychain or the network.
- Three tools every flow test uses:
  - **the convergence check** — after a scenario settles, every message's label set in the
    index equals the fake's, every message the fake has is in the index or queued, and no
    intent has vanished without one of invariant 6's three reasons;
  - **the publish recorder** — across a scenario, once a delivered row reflects command *n*, no
    later delivery shows it without, unless an undo, a refusal or an outside change explains
    it. A flash-back is a transient; an end-state assertion cannot see one;
  - **the seeded random run** (gates B and after) — device changes, changes "on the web", kills
    at commit points, lost and delayed answers, in an order chosen by a seeded generator; then
    the convergence check. The seed is printed on failure.

### 17.2 The fake Gmail, behaviour by behaviour

`FakeGmail` (`Banana/Model/Mail/Testing/`, `#if DEBUG || MAIL_FIXTURES`) implements `GmailAPI`
over one in-memory mailbox per account. **It is the oracle the engine is judged against, so it
is specified here, not left to its implementer**, and `FakeGmailTests` has one test per row,
citing the row. A row marked *switch* is a behaviour nobody has verified against Gmail: the
fake does either, and every safety test (send, removal, wake) runs under both. After the probe
(19.2) each switch's default is set to what Gmail did and the row is relabelled.

**State.** Per account: messages (`id`, `threadId`, label ids, `internalDate`, `historyId`,
headers, parts, size, snippet); labels; drafts (`draftId` → message id); a history log. Ids are
16 hex digits from a counter; history ids grow by a seeded step of 1–7 (never contiguous).
Tokens are strings mapped to accounts by `issueToken(for:)`.

| # | Call or case | What the fake does | Source |
|---|---|---|---|
| 1 | Any call, unknown token | `unauthorized` | DOCUMENTED |
| 2 | `profile` | The token's address; `historyId` = newest log id; `messagesTotal` counts every message | DOCUMENTED; *switches* `totalExcludesSpamTrash`, `profileHistoryLags(records: n)` (its `historyId` is behind the log) |
| 3 | `profile`, token marked `answersAs(other)` | The other address — invariant 2's test | injection |
| 4 | `labels` | Every label, system labels first | DOCUMENTED |
| 5 | `labels`, injected `.empty`, `.missing(id)`, `.malformed` | An empty list; a list without that label; `malformed` | injection (S-3) |
| 6 | `label(id:)` | Exact `messagesTotal`, `threadsTotal`, `threadsUnread`; unknown id → `notFound` | DOCUMENTED; *switch* `labelCountsLag(calls: n)` |
| 7 | `listMessages` | Messages carrying **all** `labelIDs`; newest `internalDate` first, ties by id descending; Trash and Spam only if asked for or named; at most `maxResults` | DOCUMENTED §2 |
| 8 | `listMessages` paging | The token encodes the last item returned (keyset) | ASSUMED; *switch* `listingPaging = .offset`, which skips an item when an earlier one is deleted between pages |
| 9 | `listMessages`, a token it did not issue | `refused(.invalidArgument)` | ASSUMED; *switch* `stalePageToken = .notFound` |
| 10 | `listMessages`, `beforePage(n) { … }` hook; injected `.endsEarly(afterPage:)` | Runs the closure between pages; omits the next token before the end | injection (S-12) |
| 11 | `listMessages(query:)` | Understands `rfc822msgid:`, `in:`, `label:`, `from:`, `subject:`, `after:`/`before:` (epoch seconds) and bare words (substring of subject and text). Anything else matches nothing and is recorded in `unsupportedQueries` | modelled |
| 12 | `rfc822msgid:` with `labelIDs: ["DRAFT"]` | Finds the draft | UNVERIFIED; *switch* `msgidFindsDrafts = false` |
| 12a | `rfc822msgid:` with `labelIDs: ["SENT"]`, or with no label | Finds the message | UNVERIFIED; *switch* `msgidFindsSent = false` (the operator matches nothing; S-18) |
| 13 | `history(start:)` | Records with id > `start`, ascending, `maxResults` a page; the response's `historyId` is the newest log id even when there are no records | DOCUMENTED §1; *switch* `historyStartInclusive` (the record at `start` is returned again) |
| 14 | `history`, `start` older than `expireHistory(before:)` | `notFound` | DOCUMENTED §1.4 |
| 15 | History records | `messagesAdded`, `messagesDeleted`, `labelsAdded`, `labelsRemoved`, each with message id, thread id and, for label records, **only the labels that changed** | ASSUMED; *switch* `historyCarriesFullLabels` (a record's message also lists every label it now has) |
| 16 | History and this client's own changes | Recorded like anyone's | UNVERIFIED; *switch* `historyOmitsOwnChanges` |
| 17 | `message(id:format:)` | `minimal`: ids, labels, `internalDate`, `historyId`, size, snippet. `header`: plus the headers of 5.6. `full`: plus the parts. Unknown id → `notFound` | DOCUMENTED §2; *switch* `contentChangesUnderID` (a later read of the same id returns different parts) |
| 18 | `message`, formats and fields | — | UNVERIFIED; *switches* `getOmitsHistoryID`, `headerOmitsInternalDate` |
| 19 | `message`, injected per id | `.delay(until:)` a named signal; `.labelsBehind(n)` records; `.unexplained404` | injection (S-6, S-14, S-26) |
| 20 | `thread(id:)` | Its messages oldest first, drafts, Trash and Spam included | DOCUMENTED |
| 21 | `modify`, unknown message | `notFound` | DOCUMENTED |
| 22 | `modify`, unknown label id; adding or removing `SENT` or `DRAFT` | `refused(.invalidArgument)` | DOCUMENTED §3 |
| 23 | `modify` on a message that has `DRAFT` | `refused(.failedPrecondition)` | ASSUMED; *switch* `draftsAcceptLabels` |
| 24 | `modify` adding or removing `TRASH` or `SPAM` | `refused(.invalidArgument)` | UNVERIFIED; *switch* `modifyAcceptsTrash` |
| 25 | `modify` that changes nothing | 2xx; no record; `historyId` unchanged | ASSUMED; *switch* `noOpWritesHistory` |
| 26 | `modify` otherwise | Labels changed; the message's `historyId` becomes the new record's id; one record per direction | DOCUMENTED |
| 27 | `batchModify`, more than 1,000 ids | `refused(.invalidArgument)` | DOCUMENTED |
| 28 | `batchModify` with one unknown id | 2xx, the unknown id skipped, the rest applied | UNVERIFIED; *switch* `batchBadID = .refused | .notFound`, each with `appliesValid` true or false (S-19) |
| 29 | `trash` / `untrash` | Adds / removes `TRASH`; other labels untouched | ASSUMED; *switch* `trashRemovesInbox` |
| 30 | `createLabel`, a name that exists (case-insensitively) | `conflict` | UNVERIFIED; *switch* `duplicateLabel = .refused` (S-28) |
| 31 | `deleteLabel` | The label leaves every message, a `labelsRemoved` record each, then goes | ASSUMED; *switch* `labelDeleteSilent` |
| 32 | `createDraft` | A new draft id and a new message with `DRAFT`, in `threadID` or a new thread; `messagesAdded`. Every header of the MIME is kept | DOCUMENTED §6.4; *switch* `draftsDropUnknownHeaders` |
| 33 | `createDraft` / `updateDraft`, a thread id that does not exist | `notFound` | UNVERIFIED; *switch* `badThread = .refused` |
| 34 | `updateDraft` | The draft's message is replaced: the old id `messagesDeleted`, a new id `messagesAdded` | DOCUMENTED §6.4 |
| 35 | `deleteDraft` | `messagesDeleted`; the draft id answers `notFound` after | DOCUMENTED |
| 36 | `sendDraft` | The draft and its message go (`messagesDeleted`); a message with `SENT` and a **new id** joins the draft's thread (`messagesAdded`), with `INBOX` and `UNREAD` too if he is a recipient; `Message-ID` kept; the message is returned | DOCUMENTED §6.4; *switches* `sentKeepsDraftMessageID`, `rewritesMessageID` (replaces it and adds `X-Google-Original-Message-ID`) |
| 37 | `sendDraft` again on a spent id | `notFound` | INFERENCE; *switch* `sendReplay = .sendsAgain` |
| 38 | Two `sendDraft` on one id at once | One sends; the other gets `notFound` | UNVERIFIED; *switch* `concurrentSend = .bothSend` (R3) |
| 39 | `draft(id:)` after its send | `notFound` | UNVERIFIED; *switch* `draftLingers(calls: n)` (E-4) |
| 40 | `sendDraft` over the fake's sending allowance | `limited(.sending, retryAfter:)`, nothing sent | ASSUMED; *switch* `limitErrorMaySend` |
| 41 | `attachment` | The part's bytes to the file; unknown id → `notFound` | DOCUMENTED §7; *switch* `attachmentIDsChange` (a new id on every `message` read) |
| 42 | Units | Every call is charged from `GmailCost`; a minute over `perMinute` (6,000) answers `limited(.user, retryAfter:)` until the minute turns | DOCUMENTED §9; *switch* `limitShape = .noRetryAfter | .asBandwidth` |
| 43 | Concurrency, bytes | More than `maxConcurrent` (8) calls at once → `limited(.concurrent)`; over `bytesPerDay` → `limited(.bandwidth)` | ASSUMED; *switches* `maxConcurrent = n`, `concurrencyAnswersAs = .user` |
| 44 | Lag | Writes are visible to every read at once | UNVERIFIED; *switches* `listingLag(calls: n)`, `historyLag(calls: n)` |
| 45 | A delayed answer | Carries the state when the request arrived | ASSUMED; *switch* `delayedReadsAt = .reply` |
| 46 | `lastServerDate` | The fake's own clock, settable per test | injection (S-23) |
| 47 | The `Authentication-Results` of a received message | `mx.google.com; dkim=pass header.i=@<domain> header.s=… header.b=…; spf=pass (…) smtp.mailfrom=…; dmarc=pass (…) header.from=<domain>`, above any the sender wrote; none on his own sent mail | ASSUMED, UNVERIFIED (10.6; probe item 11); *switch* `authResultsForm = .signingDomain` (`header.d` in place of `header.i`), `.noDMARC`, `.none` |
| 48 | A message whose `full` answer cannot be decoded (`mime-depth-200`) | `message(id, .full)` and a `thread` holding it answer `malformed`; `message(id, .header)` answers as usual | MEASURED by P03a (the JSON reader's own nesting limit); 5.6 |
| 49 | A message with no labels, read alone or in its thread | The answer carries no `labelIds` key | ASSUMED (5.6; probe item 12); *switch* `omitsEmptyLabelIds = false` (an empty list is sent) |
| 50 | A message that did not come through Gmail's servers | Its first `Authentication-Results` is another server's, with one written by the sender that claims `mx.google.com` below it; and one with only the sender's | 10.6: the first authenticates nobody — its first header is not Gmail's; the second is believed, because it cannot be told from Gmail's own, and is the stated limit |
| 51 | Thread ids | A thread's id is the id of its first message | ASSUMED (5.4; probe item 14); *switch* `threadIDIsFirstMessage = false` (thread ids come from their own counter) |
| 52 | `listMessages` with `after:` / `before:` and `labelIDs` together | Both conditions hold; the dates are compared with `internalDate` to the second | ASSUMED (5.4; probe item 14); *switch* `dateQuery = .wholeDays` (a date is rounded to the day in the account's zone, which is why the edge is listed a day early) |

**Failure injection**, for any method, by call number or predicate:
`.failBefore(GmailError)` — nothing is applied; **`.applyThenFail(GmailError)` — the change is
made and the answer is lost**, for every mutating method (`modify`, `batchModify`, `trash`,
`untrash`, `createLabel`, `deleteLabel`, `createDraft`, `updateDraft`, `deleteDraft`,
`sendDraft`); `.delay(seconds)` and `.delay(until: signal)`.

**A second client.** `fake.web(account)` makes changes "elsewhere", uncharged and always
recorded: archive, label, reply into a thread, edit a draft (optionally dropping its
`X-Banana-*` headers), delete a draft, send a draft another engine holds, delete 40 % of a
mailbox in one history window.

**A ledger** tests assert on: units by lane and call, requests in flight, bytes — "a hundred
archives cost at most 60 units"; "after `suspend()` an hour makes no request".

**Store-side faults** are not the fake's: `MailIntentStore` and `MailBlobStore` take a test
hook that throws `SQLITE_FULL` on the next commit, and a test truncates one store's log before
reopening to play a lost commit (S-2, S-16).

### 17.3 What the pure folder may name from outside itself

`Banana/Model/Mail/` is listed in `project.yml` under `BananaTests.sources` as a directory, once
(C0a), and `BananaTests` gains GRDB and SwiftSoup as package dependencies in the same edit.
Every Swift file added to the folder is then compiled into the tests with no further edit, and
invariant 17 is a build failure rather than a convention. **Only Swift files live there**;
fixtures and resources are elsewhere, because a directory entry would also copy them into the
app. The test target's two entries carry `includes: ["**/*.swift"]`, which keeps anything else
out of the test bundle; the apps take the folders through their own `Banana` entry, where
nothing filters, so `MailSourceTreeTests` (C0a) walks both folders and fails on any file that
is not Swift. `MailIdentifiers*.swift` of the pure UI folder are also compiled into
`BananaUITests`, which has nothing else of the app's: those files name Foundation only.

From outside the folder, engine files may reference only types already in the test target:
`GoogleTokenMinter`, `AppSupport`, `DeviceRole`, `ShellNavigation`/`ShellState`, `AppSection`,
`GuestDirectory`, `SnapshotLoader`, `CoalescingRun`. Everything else — WebKit, BackgroundTasks,
UserNotifications, `GoogleCalendarService`, `PlaybackDiagnostics`, `NetworkMonitor`,
`PerfWatchdog`, `URLSession`'s delegate types — lives in `Banana/Model/MailApp/` and is kept
thin.

### 17.4 Fixtures from the real world

The read-only probe (19.2) records real response *shapes* with content replaced: every string
value in a body, subject, snippet, address or file name is substituted with a same-length
placeholder before it is written (a tested pure function). Those are the HTTP layer's
fixtures. **Error bodies are recorded too** — the mapping of 5.1 is tested against what Google
sent, not against a guess (E-27).

### 17.5 The hostile messages

Each is a complete `messages.get` object in a Swift literal under `M/Testing/Hostile/`
(`#if DEBUG || MAIL_FIXTURES`) — in code, not in a resource bundle, because the same message
must drive the unit tests, the web view test and a route inside the app. The very large ones
(`html-2mb-plus`, `nested-100k-divs`, `attr-bomb`, `header-1mb`, `invite-10mb-ics`,
`mime-2000-parts`) are generated by a function. They are part of the fixture mailbox (13.6).
The list is the security review's, by name:

`script-everywhere` · `event-handlers` · `url-obfuscation` · `cross-reference` ·
`meta-base-link` · `forms-and-inputs` · `frames-objects` · `svg-inline` · `svg-as-image` ·
`mathml` · `css-attacks` · `css-overlay-spoof` · `conditional-comments` · `noscript-pixel` ·
`raw-text-escapes` · `malformed-nesting` · `encoding-tricks` · `nested-100k-divs` ·
`nested-100k-inline` · `nested-30k-bold` · `nested-10k-tables` ·
`pictures-10000x10000-x1000` · `html-2mb-plus` · `attr-bomb` · `mime-depth-50` · `mime-depth-200` · `mime-2000-parts` · `header-1mb` ·
`newsletter-tracked` · `simple-links` · `plain-text-urls` · `link-mismatch` · `mailto-prefill` ·
`unsubscribe-aligned` · `unsubscribe-misaligned` · `unsubscribe-http` · `unsubscribe-mailto` ·
`from-name-is-address` · `from-rlo-subject` · `from-homograph-domain` · `reply-to-elsewhere` ·
`correspondent-poison` · `header-injection-reply` · `attachment-rlo-name` ·
`attachment-pdf-is-macho` · `attachment-png-is-html` · `attachment-30000px-png` ·
`attachment-gzip-bomb-image` · `invite-wrong-organiser` · `invite-10mb-ics` ·
`prompt-injection` · `quoted-reply-with-trackers`.

What each must prove is in `mail-working/review/security-privacy.md` ("Hostile fixture
messages"); the package that first uses a fixture writes it and its assertions. **P03a
creates the directory and seven**: the six about who a message says it is from —
`from-name-is-address`, `from-rlo-subject`, `from-homograph-domain`, `reply-to-elsewhere`,
`correspondent-poison`, `header-injection-reply` — and the generated `header-1mb`. (This
sentence once said "the first ten", and P03a's entry "the header and sender ones"; seven is
what those are.) **P03b** writes the four about a message's shape: `mime-depth-50`,
`mime-2000-parts`, `encoding-tricks`, and `mime-depth-200` — a tree deeper than the JSON
reader will decode, added to the list by P03a's finding (5.6). P20a and P20b write the HTML
ones; P21a the attachment ones; the invitation and unsubscribe ones, the package that builds
each.

**These files are compiled into the app, on purpose, and fenced.** `M/Testing/` is inside
the folder the four app targets take whole, and it has to be: the fixtures drive routes inside
the app — the audit routes, the in-memory source, the owner's device runs on Beta — as well
as the tests. **Every file under `M/Testing/` is wholly inside `#if DEBUG || MAIL_FIXTURES`
… `#endif`**, its first line and its last. So a Debug build has them; a Release build of the
two production targets, which defines neither, compiles each of those files to nothing; and
the two Beta targets' Release configuration defines `MAIL_FIXTURES` (P24), which is how the
owner's device runs have the fixture mailbox. A file there without the fence would put
hostile HTML and a pretend mailbox in the shipped app and nothing would say so; so a test
reads the folder and fails on any Swift file under `M/Testing/` whose first line is not that
`#if` or whose last is not `#endif` (P03a, which made the folder; in the manner of C0a's
`MailSourceTreeTests`). Gate F also looks for the fixtures' marker in the production Release
binary and must not find it.

### 17.6 Benchmarks that can fail

A budget asserted in a Debug build on a shared Simulator proves nothing: it passes by being
loose or fails by being loaded. So:

- **`--verify-mail-bench`** is a launch argument of the app, in the style of the repo's other
  `--verify-…` routes. The gate runs it on the **Mac, built Release**; the same route runs on
  the Mail iPhone simulator through `tools/perf-gate.sh` and, when the owner says so, on his
  phone (D18). It builds the synthetic store in a temporary
  directory (the generator of 21, at 20,000 messages by default and 200,000 with
  `--mail-bench-full`), runs each measured operation of section 15 several hundred times,
  prints one line each — `mail-bench <name> p50=… p95=… load=… ratio=…` — and exits non-zero if
  any p50 is more than **twice** the recorded median for that machine
  (`tools/mail-bench-baseline.json`, keyed by hardware model; a first run on a new machine
  records and passes). It opens no window, touches no real store and makes no request.
- **Ratios, not absolutes.** The absolute budgets of section 15 are checked on a device by the
  owner's runs (D18); the gate checks that nothing got twice as slow.
- Every line carries the load average, and a run with a 1-minute load over 8 is reported as
  inconclusive, not as a failure.
- The **shape assertions** of 17.1 run in every ordinary test run and can fail anywhere.

### 17.7 Commands

```sh
xcodegen generate                    # after any new file: the project is generated from globs
SIM=<simulator id>; DD=.build/mail-<package>          # a private derived-data path per package

xcrun swiftc -typecheck Banana/Model/Mail/MailContract.swift   # C0a: the contract compiles alone

xcodebuild test -project Banana.xcodeproj -scheme Banana \
  -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath $DD \
  -only-testing:BananaTests/<TestClass> CODE_SIGNING_ALLOWED=NO          # judge by "** TEST SUCCEEDED **"; never -quiet

xcodebuild build -project Banana.xcodeproj -scheme BananaMacBeta -configuration Debug \
  ONLY_ACTIVE_ARCH=YES -derivedDataPath $DD                              # the Mac build: the Beta scheme, always

xcodebuild test … -enableThreadSanitizer YES -only-testing:BananaTests/<the package's classes>   # at gates

xcodebuild build -project Banana.xcodeproj -scheme BananaMacBeta -configuration Release \
  ONLY_ACTIVE_ARCH=YES -derivedDataPath $DD-bench CODE_SIGNING_ALLOWED=NO \
  && "$DD-bench/Build/Products/Release/Banana Beta.app/Contents/MacOS/Banana Beta" --verify-mail-bench

swift test --filter MailMacChecksTests                 # P21a on: the Mac-only checks, through the root Package.swift
```

**Every Mac build an agent makes is of `BananaMacBeta`, never `BananaMac`.** The Beta target
has its own bundle id, its own storage directory and its own entitlements (`project.yml`), so
building it never touches the production app's signing or entitlements, and what is built
cannot be taken for, or put in the place of, the app he uses. `BananaMac` is built for a
release, by the owner. (On iOS the tests belong to the `Banana` scheme; they are built
unsigned for a Simulator and nothing is installed on a device.) Judge a build by
`** BUILD SUCCEEDED **`.

One implementer works in the tree at a time (18.2), so there is nothing to take or release
before building. No package launches the app plainly, installs on a device, or calls Google.

## 18. The packages

The order in which these are built, the UI packages beside them, the gates and the prototypes
are in `docs/design/MAIL-PLAN.md`. This section specifies each engine package completely. Each
is one implementer, one sitting, roughly 400–1,400 lines with its tests, built from this
document alone.

Paths: `M/` is `Banana/Model/Mail/`, `A/` is `Banana/Model/MailApp/`, `T/` is `BananaTests/`.

### 18.1 Rules for every package

- Create files only where the package lists. **Do not edit a file another package created**;
  add to a type from another package in an extension file of your own. The one exception is
  the registry file, `M/MailSlices.swift` (18.2), which exists to be added to. GRDB handles
  (`Database`, the pools and queues inside `MailStores`) are `internal`, by rule, so an
  extension in a later package can use them; `MailIntentStore`'s are `private`, by rule (4.8).
- Do not edit any existing file unless the package's *Touches* line names it. The files more
  than one package touches, and the order, are a table in MAIL-PLAN.
- Engine files obey invariant 17; rules obey invariant 18; nothing breaks invariant 20; nothing
  reads the device clock except through `MailClock`; nothing sleeps except
  `clock.sleep(until:)`.
- A member of `MailSource` is built by declaring it in the package's own file. Nothing is
  stubbed in a source file: what is not built yet is answered by `MailSource+NotYet.swift`
  (13.3).
- Ship the tests listed, written as the repo writes them (17.1). **Accept** means: the named
  test classes succeed with the commands of 17.7; the iOS app, the Mac app and the whole of
  `BananaTests` build; Thread Sanitizer is clean over the package's classes; the package's
  performance check holds; the per-package checks of MAIL-PLAN are done; and **the package's
  one commit holds exactly the files its *Creates* and *Touches* lines name** (`git show
  --stat`).
- No plain app launch, no device install, no call to Google.

### 18.2 Working in one tree

Every file under `Banana/` is compiled into four app targets, and every file under `M/` into
the tests as well, so one half-written file stops every build. That is handled by scheduling,
not by tooling — there is no lock and no compile guard:

**A package is built by one implementer, who is the only one editing the tree while it is
built. It lands as one commit, made by the orchestrator after the package's checks and its
code review have passed. A package that has to be developed alongside another is developed in
its own git worktree and merged by the orchestrator.**

Three things keep that workable:

- **The map of shared files** — which packages may edit which existing file, and in what
  order — is a table in MAIL-PLAN section 5. It is where conflicts would be, and with one
  package landing at a time it is also the order of the edits.
- **Only C0a, P21a, P24 and P25 edit a project file**: `project.yml` (C0a, P24, P25) and the
  root `Package.swift` (P21a, for the Mac-only checks of 17.1). `xcodegen generate` is run by
  whoever is building, after any new file.
- **One registry file that later packages add to** — `M/MailSlices.swift`, created by P02 —
  because an extension can add a member to a type but cannot add an element to a list another
  file wrote:

  ```swift
  enum MailSlices {
      /// Every schema step of the three cache stores. Each store package adds its line.
      static func migrations() -> MailMigrations
      /// What reacts to a finished sync pass, in order: the outbox, the timed rules, status. (P23a on.)
      static func passConsumers(_ engine: MailEngine) -> [MailPassConsumer]
      /// The lines `--verify-mail-bench` runs. (P09a on.)
      static let benches: [MailBench]
      #if DEBUG || MAIL_FIXTURES
      /// The parts of the fixture mailbox. (C0b on.)
      static let fixtureParts: [() -> MailFixtureMailbox]
      #endif
  }
  ```

  A section is added to it by the first package that has the type it lists; after that a
  package adds one line. Consumers that live in `MailApp/` (the notifier) are added at wiring,
  with `engine.addPassConsumer(_:)`, since the pure folder cannot name them.

### 18.3 Order 0

**G0 — The performance gate** is not an engine package: the performance auditor owns it. It
moves the gate script into `tools/perf-gate.sh`, makes it read its routes from
`tools/perf-routes.d/*.routes`, and records the pre-mail reference run P0′. Every later
"whole-app gate" in this section means that script against that run.

**C0a — The contract.** Built and reviewed: 1,754 lines of source (the contract file is
1,026 of them) and 1,295 of tests. The first commit of mail.
- *Goal:* the one surface both halves compile against, frozen by compiling it.
- *Creates:*
  - `M/MailContract.swift` — the text of the two Swift blocks of 13.2 and 13.3, in that
    order, and nothing else. Imports Foundation and Combine.
  - `M/MailRowRules.swift` — `extension MailRowRules { static func apply(_ change: MailChange,
    to row: MailRow, in scope: MailScope) -> Outcome }`, the tables of 13.2.
  - `M/MailSource+NotYet.swift` — `extension MailSource` with a default for every requirement
    (13.3, "Until it is built"), each calling `MailNotYet.reached(#function)` (the two
    `discard`s add `" receipt"` and `" draft"`, since `#function` gives both one name); and
    `@MainActor enum MailNotYet` holding the set of names reached (`reachedNames`), the shared
    `MailStatus` and `MailBadges` instances the defaults return, `reset()`, and the hook
    `onReach` (13.3).
  - `Banana/Model/MailUI/Pure/MailIdentifiers.swift` — `enum MailID` with
    `static let list = "mail.list"` and `static func row(_ key: String) -> String`
    (MAIL-UX 10.2), so that folder exists and both halves have it from the first package.
    Later packages add their own in `MailIdentifiers+<package>.swift`. These files name
    Foundation only: they are also compiled into the UI tests.
  - `T/MailRowRulesTests.swift`, `T/MailContractShapeTests.swift`,
    `T/MailSourceProbe.swift` (the 56-call probe of 13.3, shared with gate F),
    `T/MailSourceTreeTests.swift` (rules about the source files themselves, 17.3).
- *Touches:* `project.yml` — under `packages`: GRDB (`https://github.com/groue/GRDB.swift.git`)
  and SwiftSoup (`https://github.com/scinfu/SwiftSoup.git`), **each pinned by `revision:`**, the
  tagged version in a comment (7.11.1 = `b83108d1…`, 2.13.9 = `18b80329…`; in full under R22),
  because `Package.resolved` cannot be committed; both as dependencies of `Banana`,
  `BananaBeta`, `BananaMac` and `BananaMacBeta`, and of `BananaTests`, **which had no
  `dependencies:` key and gains one**; under `BananaTests.sources`:
  `- path: Banana/Model/Mail` and `- path: Banana/Model/MailUI/Pure`, each with
  `includes: ["**/*.swift"]`, listed once here so that no later package of either half edits
  `project.yml` for a source file (a directory entry needs a Swift file in the directory;
  this package puts one in each); under `BananaUITests.sources`:
  `- path: Banana/Model/MailUI/Pure` with `includes: ["MailIdentifiers*.swift"]`, so a UI test
  uses the constants the views use.
- *Must not:* declare in the contract file anything 13.2 and 13.3 do not; give it a third
  import; put a function body in it other than those the blocks contain (the two computed
  properties of `MailConversationID` and its `init?(text:)`, `MailOrderKey.<`,
  `MailReceipt`'s `==` and `hash(into:)`, `MailRefusedChange.id`, the badge mirror's two
  functions, `MailObservation`'s initialiser, `cancel()` and `deinit`, and the three classes'
  initialisers).
- *Tests:* every cell of the `MailRowRules` tables — a grid of every change against every
  mailbox, the three built-in splits, a custom split, a label, a search and a held removal —
  and that every outcome carries the row as changed; a `label` or `move` naming another
  account leaves the row untouched; a snooze keeps a line that outranks it; the filters,
  including a row whose place is unknown; that the grid names every case of `MailChange` (an
  exhaustive `switch`, so a new case does not compile there). `MailOrderKey` orders group 0
  before group 1 and a larger `sortKey` first; `MailConversationID.text` reads back through
  `init?(text:)`, with a bar in the address; `gmailURL` is nil for a `local:` thread and
  percent-encodes the account; two receipts with one sequence are equal and one dictionary
  key whatever their counts; **the stored form of every type kept across launches**
  (`MailConversationID`, `MailMessageID`, `MailDraftID`, `MailOrderKey`, every case of
  `MailPlace` and of `MailChange`, `MailScope`) is compared with a literal, so a renamed case
  or label fails a test; a first page of rows with every `MailRowReason` reads back as
  written; `MailBadgeCounts` round-trips through `mirror(to:)` and `mirrored(in:)` on a
  throwaway `UserDefaults` suite, and a malformed value reads as nil; an observation's
  closure runs once, whether it is cancelled, let go, both, or cancelled from eight threads
  at once; every default of `MailSource+NotYet` returns the value 13.3 lists and is recorded
  by `MailNotYet` (a source with no members at all compiles, which is the proof that every
  requirement has one); the probe reaches all 56 on that source, 55 on one that built a
  member, and still 56 on one that declared the member with a near-miss signature; `onReach`
  is called each time. From the source files: the two folders hold only Swift; the contract
  imports Foundation and Combine and nothing else; the identifier files import only
  Foundation; the protocol has 56 requirements and the probe 56 names.
- *Accept:* `xcrun swiftc -typecheck Banana/Model/Mail/MailContract.swift` succeeds with that
  one file — the contract names nothing outside itself; the same with the three `M/` files
  together; the four test classes; the four apps and the tests build with the two packages
  resolved.
- *Needs from the owner:* approval of the two packages (D19). Nothing else.
- *Unblocks:* everything. P01a and P02 need only this.

**C0c — The contract, as the owner ruled.** ≈ 400 lines changed. Next: before P05, which
builds rows.
- *Goal:* the contract file says what 13.10's table says, and compiles.
- *Touches:* `M/MailContract.swift` — every row of that table, and nothing else;
  `M/MailSource+NotYet.swift` — the defaults for `syncLimit` (`.sixMonths`), `setSyncLimit`
  (nothing), `conversationsBeyond` (0), `pictureRules` (`[]`), `removePictureRule` (nothing),
  `askGmail` (nothing), `showPictures(in:always:)` (nothing), each reporting to `MailNotYet`;
  `T/MailSourceProbe.swift` — 59 calls and 59 names; `T/MailContractShapeTests.swift` and
  `T/MailSourceTreeTests.swift` — the count, the new stored forms (`MailSyncLimit`,
  `MailPictureRule`, `MailPictureGrant`), a first page of rows with `isOnDevice` both ways;
  sections 13.2 and 13.3 of this document — the two blocks replaced by the file's text, the
  "Until it is built" and command tables renamed. Any place that names `searchGmail`,
  `alwaysShownPictureDomains`, `stopAlwaysShowingPictures`, `showPictures(in:alwaysFromSender:)`
  or `MailPictures.senderDomain` — in the UI's files, the UX author's — is renamed in the
  same commit, by agreement, as 13.1 requires of every contract change.
- *Must not:* change a declaration the table does not name; give a new field no default.
- *Accept:* the contract compiles alone; the mail folder compiles; the four test classes;
  the apps and the tests build.
- *Unblocks:* P05 (`MailRow.isOnDevice`), P23a, P13b, P23c, P23e, P18b.

**C0b — The fixture mailbox and the contract suite.** ≈ 900 lines. Lands in order 1, after
P05 and immediately before the UX's U0′ — the first thing that can run the suite.
- *Goal:* one mailbox both sources are built from, and one set of tests both must pass.
- *Creates:* `M/Testing/MailFixtureMailbox.swift` (the type of 13.6);
  `M/Testing/MailFixtureMailbox+Standard.swift` (the conversations MAIL-UX 13 names, as Gmail
  wire JSON in Swift literals, with their device states and expected orders);
  `M/Testing/MailFixtureGenerated.swift` (the bulk builder, and the large items no literal
  should hold — the 1.2 MB newsletter, the 2.4 MB attachment — made by seeded functions);
  `T/MailContractTests.swift` (the base class and `MailContractSubject`, 13.6; the publish
  recorder); `T/MailContractTests+Reads.swift` (promises 2, 5, 6, 8, 10 and 11 of 13.5);
  `T/MailFixtureMailboxTests.swift`.
- *Touches:* `M/MailSlices.swift` — the `fixtureParts` section, with the standard part.
- *Tests:* every message of the mailbox decodes as a `GmailMessage` (P03a); every key is
  unique; every key an expected order or a device state names exists; `bulk(conversations:
  5_200)` is the same twice for one seed.
- **What cannot run yet, said plainly:** `MailContractTests+Reads` has no source to run
  against in this package. The base class skips itself; the read tests are **first executed
  by U0′**, on the in-memory source, and by P23a on the engine. This package is accepted on
  the mailbox's own tests and on the suite compiling.
- *Unblocks:* U0′, P10a.

### 18.4 Order 1 — an inbox from the real store, filled by the fake

**P01a — Account types.** ≈ 450 lines. Pure. No existing file changes. Needs only C0a.
- *Creates:* `M/MailAccountAccess.swift` — the declarations of 3.3's first block, with
  `MailScopes.parse` given its body, and `MailGrantRejection.init(oauthSummary: String?)`
  (3.3); `M/MailAccountRules.swift` — **`enum MailAccountRules` only**: `MailAccountState` and
  `MailAccessGap` are the contract file's and are not declared again;
  `M/MailClock.swift` — **the protocol `MailClock` of 13.6 and nothing else**: P01a is its
  first user, so P01a declares it (the system clock and the manual one are P02's);
  `M/MailTokenFlight.swift` — the single flight of 3.3, with the names 3.3 gives: an actor
  made by `init(clock:mint:)` over a `@Sendable` minting closure
  `(String) async throws -> (value: String, expiresAt: Date, scopes: Set<String>?)`, with
  `token(for:)`, `drop(account:)`, `forget(account:)`, `renewalMargin`, and the test-only
  `waitingCallers(for:)`; `T/MailAccountRulesTests.swift` (the rows of 3.4 **and the rejection
  kinds of `MailGrantRejection(oauthSummary:)`**), `T/MailScopesTests.swift`,
  `T/MailTokenFlightTests.swift` (with a still clock of its own: P02's manual clock does not
  exist yet).
- *Tests:* every row of 3.4 in order — declining Mail is `needsAccess(.notAllowedHere)`, a
  rejected grant is `.withdrawn`, a token whose known scopes lack Gmail is `.withdrawn`, unknown
  scopes are not; **`MailScopes.parse` of nil or of an empty field is nil — unknown, never the
  empty set** (an empty `scope` field must not mark a working account withdrawn) — and of a
  space-separated list, that set; `invalid_grant: …` reads as `.invalidGrant`,
  `invalid_client: …` as `.clientRejected`, nil as `.invalidGrant`, and **a summary with no
  colon is read whole, as the code**; ten concurrent callers of `MailTokenFlight` cause one
  mint, and share a failure too; a token with more than a minute left is used, and one with
  exactly a minute or less is minted again (3.3, rule 2); a rejection is remembered until
  `forget`, a transport failure is not; **a token or a rejection that arrives after `forget`
  is neither cached nor remembered, and its waiters are still answered** (3.3, rule 4).
- *Follow-up after its code review* (`mail-working/review/pkg-P01a.md`), one small package
  before P02, the last to edit these files:
  - *Source.* `MailAccountAccess.swift` gains `cancelMailTokenRequests()`.
    `MailTokenFlight.swift` gains `cancelMint(account:)` (cancel the task of the account's
    mint in the air; touch nothing else), the two sentences on `Mint`, and `waitingCallers`'
    wording — all as 3.3 gives them. **Nothing else changes**: a cancelled caller still waits
    (rule 1), and `drop` keeps its shape (rule 8).
  - *Tests,* in `T/MailTokenFlightTests.swift`, by name. The overlap cases need a gate per
    call (`release(call: n)`) in place of the one gate for every call.
    - `testACancelledWaiterStaysAndIsGivenTheToken` — three callers on one gated mint; cancel
      one that joined; release: all three are given the token, the closure saw
      `Task.isCancelled == false`, one mint.
    - `testCancellingTheCallerThatStartedTheMintLeavesItRunning` — the same, cancelling the
      caller whose call started the mint.
    - `testCancelMintCancelsTheMintInTheAir` — the closure, waiting on its gate, sees its task
      cancelled.
    - `testWaitersOfACancelledMintAreToldWhatItThrew` — every waiter gets the closure's own
      error, once with `CancellationError` and once with `.transport`.
    - `testACancelledMintIsNotRememberedAndTheNextCallMintsAgain` — the next call is given a
      token; two mints.
    - `testCancelMintLeavesACachedTokenAndOtherAccountsAlone` — with nothing in the air a
      cached token is still served; another account's mint in the air is not cancelled.
    - `testAMintThatIgnoresCancellationIsCachedAsUsual` — a closure that returns a token
      regardless: waiters get it and the next call is served from the cache.
    - `testALateDropDiscardsANewerTokenAtTheCostOfOneMint` — `t1` cached; `drop`, `token` is
      `t2`; a second `drop` for the same dead token; `token` is `t3`; three mints, no error
      (rule 8, accepted).
    - `testATokenMintedInsideTheMarginIsHandedOutAndMintedAgainNextTime` — a mint lasting
      30 s: its caller gets it; the next call mints (rule 2).
    - `testAnOldMintRefusedAfterForgetDoesNotRefuseTheNewCredential` — mint 1 in the air;
      `forget`; a caller starts mint 2; mint 1 answers `.rejected`: its waiter is told
      `.rejected`, nothing is remembered, mint 2's caller is given its token, and the next
      call is served from the cache.
    - `testAnOldMintsTokenAfterForgetIsNotCachedOverTheNewOne` — as above with mint 1
      answering a token first: its waiter is given the old token; after mint 2 answers, the
      cache holds mint 2's.
    - `testANewMintThatAnswersFirstIsKeptWhenTheOldOneAnswers` — mint 2 answers, then mint 1
      (once with a token, once with `.rejected`): the cache still holds mint 2's and nothing
      is remembered.
    - And the review's own: `testForgetDropsACachedToken`,
      `testForgetLeavesAnotherAccountsTokenAndRejectionAlone`,
      `testADropWhileAMintIsInTheAirDoesNotStartASecondMint`.
- *Unblocks:* P10a, P23a.

**P02 — The stores' foundation.** Built: 3,210 lines with its tests. Needs C0a and P01a's
`MailClock`.
- *Goal:* the four GRDB stores opened exactly as 4.2 says, the writer's queue, the clocks, the
  pace — every seam later packages would otherwise each invent.
- *Creates* (as built, with what its own questions changed — "Before it is committed", below):
  - `M/MailDirectories.swift` — the tree of 4.1, backup exclusion, and the protection class of
    each directory. **Making a `MailDirectories` is what prepares the tree**, and a store opens
    only from one, which is how "before any store is opened" is kept.
  - `M/MailFiles.swift` — 11.2's one door for files: a temporary file beside the destination,
    the Mac's quarantine on the temporary file, an atomic move, the protection class after the
    move; a file that cannot be given what it was asked for is not left behind. `MailQuarantine`;
    `MailFileError` (the step and the system's number, nothing of the file). Foundation only,
    and its attribute calls go through a small `MailFileAttributes` value of closures so a test
    can watch their order.
  - `M/MailDevice.swift` — `MailDeviceRole` and `MailPower` (13.6 shows them; they are declared
    here, because `MailWorkPace` needs them long before `MailEnvironment` exists).
  - `M/MailStores.swift` — `struct MailStores { let index: DatabasePool; let blobs:
    DatabasePool; let searchWriter: DatabaseQueue; let searchReader: DatabaseQueue; let
    directories: MailDirectories }` with `static func open(_ directories: MailDirectories,
    migrations: MailMigrations) throws -> MailStores` — one `Configuration` per row of 4.2,
    the search reader attaching the other two as `idx` and `blobs` — and the intent
    connection's one way in: `func openIntent() throws -> DatabaseQueue` for the real file and
    `static func openIntentQueue(at:)` under it, which the salvage path of 4.10 uses for its
    fresh file. **Only `MailIntentStore` calls either** (P14a's source scan holds that).
    `struct MailMigrations { var index, blobs, search: DatabaseMigrator }` is built by whoever
    opens: a test builds what it needs; the engine asks `MailSlices.migrations()`.
    `MailStoreFile`; `MailStoreError` (`newerThanThisVersion(_)`, `notDurable`);
    `MailMainQueueGuard` (invariant 10, as a precondition a test can replace).
  - `M/MailSlices.swift` — the registry of 18.2, with its first section, `migrations()`,
    returning three migrators with nothing registered.
  - `M/MailWriter.swift` — the serial queue `mail.writer` and the types below;
    `MailCheckpointRule` and `MailLogCheckpointer` (4.2: when a log is due, and the object
    that holds that rule for one log — the blob store and the indexer each use one too).
  - `M/MailClocks.swift` (`SystemMailClock`, and `ManualMailClock` with `advance(by:)` and
    `pendingSleeps`. **The protocol `MailClock` is not declared here**: it is P01a's, in
    `M/MailClock.swift`, and that file is not edited); `M/MailJournal.swift` (section 16, with
    `struct MailSignpost: Sendable { let end: @Sendable () -> Void }` and `MailJournal.silent`);
    `M/MailWorkPace.swift` (4.12); `M/MailDiskRules.swift` and `M/MailDiskWatch.swift`
    (11.3); `M/MailKnobs.swift` (every number of 4.12, one place).
  - `T/MailStoresTests.swift`, `T/MailWriterTests.swift`, `T/MailClockTests.swift`,
    `T/MailWorkPaceTests.swift`, `T/MailDiskRulesTests.swift`, `T/MailFilesTests.swift`.
- *The writer's seam*, on which P14b and every sync package build:
  ```swift
  /// One piece of work for the writer's queue. The writer takes everything that is waiting,
  /// lets each piece absorb the next where it can, then runs each: the intent step, and only
  /// if that did not throw, one index transaction.
  protocol MailWriterWork: AnyObject {
      /// Fold `next` into this piece so the two commit together. False: it runs on its own.
      /// How many changes one piece will carry is the piece's to decide (4.12: fifty).
      func absorb(_ next: MailWriterWork) -> Bool
      /// 6.2 step 6. The piece calls MailIntentStore itself — P02 cannot name that type, and
      /// the intent store's connection is private. Sync's pieces do nothing here.
      func writeIntent() throws
      /// 6.2 step 7, inside the index writer's transaction.
      func writeIndex(_ db: Database) throws -> MailStoreChange
      /// Either step threw. Called on the writer's queue; the writer then goes on to the next piece.
      func failed(_ error: Error)
  }
  /// What one index transaction touched. Handed to the sink after the commit.
  struct MailStoreChange: Equatable, Sendable {
      var viewKeys: Set<String> = []                  // `view.key` of each view touched (4.3)
      var conversations: Set<MailConversationID> = []
      var labelsChanged = false
      var through: UInt64 = 0                         // the highest command sequence carried; 0 for sync
      mutating func formUnion(_ other: MailStoreChange)
  }
  /// Told of every index commit, on the writer's queue, once `index.write` has returned (4.2).
  protocol MailChangeSink: AnyObject { func committed(_ change: MailStoreChange) }
  /// A write-ahead log other than the index's whose writes happen on the writer's queue:
  /// intent.sqlite's, which only MailIntentStore can reach (4.2).
  protocol MailWriterLog: AnyObject {
      func checkpointIfDue()        // after a piece, on the writer's queue: PASSIVE if due
      func truncateCheckpoint()     // from the writer's truncateCheckpoint(), on its queue
  }

  final class MailWriter {
      init(stores: MailStores, sink: MailChangeSink?)
      func submit(_ work: MailWriterWork)                                  // returns at once
      func submit(task: @escaping @Sendable () -> Void)                    // `perform` that does not wait; keeps its place in the order
      func perform<T>(_ body: @escaping () throws -> T) async throws -> T   // anything else on the queue
      func keep(_ log: MailWriterLog)     // P14a hands it the intent store
      func truncateCheckpoint() async     // TRUNCATE the index's log and every kept log: on suspend and quit (P24 calls it)
      static var isOnWriterQueue: Bool { get }
  }
  ```
  Between pieces of work the writer runs a `PASSIVE` checkpoint of the index's log if it is
  due, and asks each kept log to do the same (4.2); it never waits to be idle.
- **Before it is committed** — three changes to the code as built, each from one of its own
  questions (22, rows K1 and K3), and one comment:
  1. *The checkpoint measure.* Every connection that can write sets
     `PRAGMA journal_size_limit = MailKnobs.checkpointOverBytes`, and
     `MailLogCheckpointer.afterPiece` first lowers `standing` to the file's present length if
     that is less. Tests: the pragma reads back from every writer; a log grown to about
     12 MiB, checkpointed, and then written to once more is 8 MiB long, and no further
     checkpoint runs until it has grown past that; the clamp, in the rule's own test. **If the
     system's SQLite does not cut the file as its documentation says, stop and say so** — the
     rule then needs another measure, and that is a design question.
  2. *Other logs.* `MailWriterLog` and `keep(_:)` as above: after each piece, after the
     index's own check, each kept log is asked; `truncateCheckpoint()` empties each after the
     index's. Tests, with a log that records: it is asked once per piece, on the writer's
     queue, never between a piece's two steps; and it is emptied by `truncateCheckpoint()`.
  3. *The disk rule's second threshold.* `MailDiskRules.state(free:floor:was:)` in place of
     the two-argument form, and `MailDiskWatch` (11.3): `init(floor:clock:freeBytes:)`,
     `state()`, `wrote(_:)`. Tests: both thresholds at, just under and just over; the watch
     reads at most once a minute and again after 50 MiB, calls `MailMainQueueGuard`, and
     stays `belowFloor` between the floor and the floor plus 500 MiB.
  4. `MailWorkPace`'s comment says 4.12's table and 12.1's disagree; they no longer do.
- *Confirmed as built* (22, rows K2, K4, K5): thermal state and Low Power Mode stop the local
  passes inside the overnight task too; the sink is told once the write has returned, not from
  GRDB's commit callback; quarantine goes on the temporary file; the journal id's two bars are
  literal; the attached names are `idx` and `blobs`; `submit(task:)`, `openIntentQueue(at:)`
  and `directories` stay; the fifty is the pieces'; `free == floor` is ok and the sizes are
  binary; pool readers keep `wal_autocheckpoint = 1000`, which cannot fire.
- *Tests:* the system SQLite is 3.43 or later and FTS5 with `contentless_delete=1` creates,
  replaces and deletes; **every pragma of 4.2 read back from every connection**; a plain
  GRDB open of a WAL store reads back `synchronous = 1` — the fact P14a's own test exists
  because of — while `fullfsync` set in `prepareDatabase` survives; changing `synchronous`
  inside a transaction throws; a pool's readers answer a 2-second busy timeout, not GRDB's
  ten; a reader sees the last commit while a write is open; `searchReader.interrupt()`
  ends a long search and does not disturb a concurrent index read; a store newer than the
  migrations it is opened with is refused; both directories are excluded from backup; errors'
  descriptions carry no bound values; thirty submissions made during one slow commit run as
  one piece when each absorbs the next, and as thirty when none does; a piece whose intent
  step throws runs no index step, is told `failed`, and the next piece runs; the sink is told
  after the commit and may read the store it is told about; a manual clock wakes sleepers in
  deadline order and reports what is pending; every row of the pace table, the warm overnight
  task among them.
- **Protection classes: what a Simulator can and cannot show.** The Simulator does not enforce
  protection classes and reports none. The unit test therefore watches the *calls*, through
  `MailFileAttributes`: each directory's class is set before the first store is opened, and a
  file's class is set after its move, never before. The real classes are read back on a
  device, by the `protection` check P09a adds to `--verify-mail-bench`, in the owner's first
  device run (D18).
- *Performance:* none asserted. The commit rate of `index.sqlite` and the cost of a
  full-fsync commit are logged; ratios begin with P09a (17.6).
- *Unblocks:* P06a, P07, P08b, P14a.

**P03a — Gmail's wire models, addresses, headers.** ≈ 800 lines. Pure.
- *Creates:* `M/GmailWire.swift` (Codable models for profile, label, message, part, thread,
  history page and record, draft, send-as, id page — every field optional, unknown fields
  ignored; field lists in appendix A — and, so that nothing in order 1 waits on a later
  package, `enum GmailFormat` and the value `struct MIMEStructure` with its part and attachment
  records); `M/MailHeaders.swift` (`MessageHeaders`: case-insensitive
  lookup in original order; limits of 1,000 lines, 256 KB, 16 KB a value);
  `M/MailAddress.swift` (`MailAddressRules` of 10.8; address lists, quoted names, groups,
  RFC 2047 decoding with `CFStringConvertIANACharSetNameToEncoding`); `M/MailAuthRules.swift`
  (10.6); `M/MailFileName.swift`; `M/Testing/Hostile/` with seven fixtures of 17.5 as Swift
  literals — the six sender ones and `header-1mb`; tests for each. Built: 2,300 lines of
  source, 213 tests.
- *Tests include:* a `minimal` message with no payload; an unknown system label; the six
  sender fixtures (`from-name-is-address` shows the address; `from-rlo-subject` loses its
  override; `from-homograph-domain` is given as `xn--`); `header-1mb` is cut at the limits;
  an `Authentication-Results` written by the sender below Gmail's own is ignored; a ratio
  test over the hostile input families — doubling an input may not much more than double the
  time — which is what found a quadratic path in this package's own first draft.
- **Before it is committed** — eight changes to the code as built, each from one of its own
  questions (22, rows L1–L10):
  1. *`MailAuthRules`* (10.6): `dmarc=pass` with `header.from` equal to the From domain
     first; then `dkim=pass` by `header.d`, **or by the domain of `header.i` when there is no
     `header.d`**; then `spf=pass`. The test that pinned "`header.i` authenticates nobody" is
     turned round, and there is one test for each of the three rules, for their order, for a
     `header.i` at a subdomain of the signing domain, and for a DKIM pass by a mailing
     service's domain that does not speak for the From line.
  2. *`MIMEStructure`* (appendix A): `htmlPartID`, `plainPartID`, `invite` (with
     `MIMEStructure.Invite`) and `cut` (with `MIMEStructure.Cut`), all optional; a test that a
     value stored without them decodes.
  3. *`cleaned`* (10.8): `isDefaultIgnorableCodePoint` in place of the list, with the three
     exceptions. Tests by name: a family, a profession and a couple emoji survive whole; the
     flag of Scotland survives and a tag sequence after anything else does not; a Persian
     word keeps its U+200C and a Devanagari conjunct its joiner; `Pay` U+200D `Pal` loses its
     joiner; a variation selector survives after an emoji and after an ideograph and not after
     a space; every direction control goes, inside an emoji sequence too.
  4. *Mixed scripts* (10.8): the hand table goes; `NSRegularExpression` with
     `\p{Script=…}`, per word, Latin, Cyrillic and Greek only. Tests: `Pаypal` with a Cyrillic
     letter shows the address; a Japanese name in Han and kana, "Tinkoff Банк", a Korean name
     beside a Latin one, and an Arabic name with Latin digits all show the name. **If a
     pattern here or in 3 does not compile on the system's ICU, stop and say so.**
  5. *An unknown charset in an encoded word* (5.6): UTF-8 if the bytes are valid UTF-8, else
     Windows-1252 — not left as written.
  6. *`MessageHeaders`* (5.6): the named headers, less `Authentication-Results`, are looked
     for past the cut and the first of each is kept. Tests: `header-1mb` with its `From`
     after the five thousand lines still has a sender; an `Authentication-Results` past the
     cut is not kept; a `From` whose value is cut before its address is the unreadable sender
     of 10.8, with an empty address.
  7. *Two envelopes* (appendix A): `GmailLabelList`, `GmailSendAsList`.
  8. *The fence* (17.5): the test that every Swift file under `M/Testing/` begins with
     `#if DEBUG || MAIL_FIXTURES` and ends with `#endif`.
- **And from its code review** (22, rows L11–L15) — the rules are 10.6, 10.8, 5.6 and
  appendix A; the code changes are these:
  9. *A quoted string is never tried as an address* (10.8). Tests for the four shapes of the
     review's first table.
  10. *`MessageHeaders.sender`* (10.8): the one reading — exactly one `From`, uncut, exactly
      one mailbox, a permitted address, and Gmail's `dmarc=` `header.from`, when there, the
      same domain; otherwise nothing. Tests: every shape with more than one is unreadable;
      no test asserts on the first mailbox of `From` as "the sender".
  11. *What an address may contain* (10.8): the local part's characters, NFKC-stable, no
      default-ignorable character, no leading combining mark, no word mixing two of the
      three scripts. Tests: `noor＠plan.example@evil.example`, a variation selector, a Hangul
      filler, `<mailto:x@y.z>`, a quoted local part and a mixed-script local part are each
      not an address; an honest non-ASCII local part is.
  12. *The first `Authentication-Results` only* (10.6). The test that pinned the skip is
      turned round; a folded one reads as one; a second is ignored; a cut one is not read.
  13. *`MIMEStructure.Attachment`* (appendix A): `size` optional; `name` documented as the
      safe name. *`GmailPart`* (5.6): its decode counts depth and throws past 64.
- *Confirmed as built:* the seven fixtures; a `From` that cannot be read is one state however
  it came about.
- *Unblocks:* P05, P06a, P10a, P16.

**P05 — Conversation rules and the engine's shared types.** ≈ 1,000 lines. Pure.
- **From the owner's rulings (22, M1–M6; 13.10):** `M/MailHoldRules.swift` — `MailHoldRules`, `MailClaims`, `MailHoldReason` (5.4), pure,
  with `T/MailHoldRulesTests.swift`: every line of the rule on both sides of the edge; a
  claim holds at any age; attention holds for the limit's length and no longer; "everything"
  holds everything; the edge is the start of a local day and moves at midnight, across a
  daylight-saving change too. `ThreadSummary` gains what the rule reads (`attendedAt`, the
  claims it can see in a conversation's messages). `MailRowMapper` sets `isOnDevice` true:
  every row it makes is of a held conversation.
- *Creates:* `M/MailEngineTypes.swift` — appendix A, field by field, **and `MailViewKey`,
  exactly as 4.4 gives it**: appendix A names it and no earlier package declares it (the file
  also names `GmailFormat` and `MIMEStructure`, which P03a declares, and `MailStoreChange`,
  which is P02's);
  `M/ThreadSummaryRules.swift` and `M/ViewMembershipRules.swift` (4.5; the timed fields stay
  nil until P19a); `M/MailBuiltInSplits.swift` — **the three built-in splits as pure
  functions** over a conversation's facts: Calendar is "has an invitation", Important is "has
  `IMPORTANT`", Other is the rest, matched in that order (9.3), so both sources show the first
  split from order 1. A custom split's match is a closure that answers false until P08a: a
  custom split is empty until then, and the fixture's VIP split is checked from gate E;
  `M/MailRowMapper.swift` — `static func row(_ stored: IndexRow, labels: [MailLabelRef],
  reason: MailRowReason?, in scope: MailScope) -> MailRow`, the one mapping from a stored
  summary to a row, used by the engine's feed and by the in-memory source, with
  `IndexRow.init(summary:id:key:)` for a source that has no SQL;
  `T/ThreadSummaryRulesTests.swift`, `T/ViewMembershipRulesTests.swift`,
  `T/MailBuiltInSplitsTests.swift`, `T/MailRowMapperTests.swift`,
  `T/MailRowRulesAgreementTests.swift` (13.2).
- **Who a message is from is `MessageHeaders.sender`** (10.8) and nothing else: no rule here,
  and nothing after it, takes a mailbox out of `From` or reads the first of several. An
  unreadable sender is a person with an empty address, in a summary's people as anywhere,
  and the text that could not be read is never put where a sender goes.
- *Tests include:* a conversation entirely in Trash; a new reply lifts it in the inbox and not
  in Sent; a stub gives a negative sort key and still counts as unread; soonest-first places
  store reversed keys, so every place reads in descending order; `tie` is the same on two
  devices for the same conversation id; an inbox conversation is in exactly one built-in
  split; in Sent, Drafts and Outbox the mapper gives recipients, elsewhere authors, six at
  most with the true total.
- *Unblocks:* P06a, P14a, C0b, the UX's fixture source.

**P05 implementation clarification (October 10):** `IndexRow.lastDate` is independent
of a view's sort key, and recipient summaries and explicit own-address identity
are retained, rather than guessed from a reversed key or display name. P06a must
persist/read recipient summaries with the author summary; its schema implementation
is still pending. Source/test evidence: `mail-working/integration/P05-20261010.md`.

**P06a — The index store: schema, storing, reading.** ≈ 1,200 lines. After P02, P03a, P05.
- **From the owner's rulings (22, M1–M6; 13.10):** the schema gains `thread.attended_at` and `account.limit_edge` (the edge the last
  closed enumeration ran with), and `enum_state` its `edge`. The writer gains **`release`** —
  remove conversations' rows with no tombstone, re-testing the claims inside the
  transaction — and `markAttended`; the reader, the scans release and the reconcile need:
  conversations wholly before an edge with no claim, and held conversations that reach back
  past one. Tests: a released conversation leaves no row in any table and no tombstone; a
  conversation that gained a claim between the scan and the write is not released; the hold
  of invariant 3 does not count it.
- *Creates:* `M/MailIndexSchema.swift` (4.3, verbatim, as migration `v1`, offered as
  `static func register(in migrator: inout DatabaseMigrator)`);
  `M/MailIndexWriter.swift`; `M/MailIndexReader.swift`; `T/MailIndexStoreTests.swift`,
  `T/MailIndexPlanTests.swift`.
- **What is stored about a sender is decided once, here, when the message is stored** (10.8):
  `from_addr` and `from_name` come from `MessageHeaders.sender` — NULL for an unreadable
  sender, never the first of several — and the name is judged then (`displayName`, `cleaned`)
  and stored as judged, so no row of a list does that work again. A per-message read that
  carries no `labelIds` stores an empty label set; an item of a listing or of a history
  record that carries none changes nothing (5.6).
- *Touches:* `M/MailSlices.swift` — one line in `migrations()`, calling that `register`.
  (Every later schema package does the same: P07, P08b; P14a registers intent's inside
  `MailIntentStore`, which nothing else opens.)
- *The writer* — static functions taking the `Database` of a transaction the caller opened,
  each returning the `MailStoreChange` it caused:
  ```swift
  enum MailIndexWriter {
      static func upsertAccount(_ db: Database, email: String) throws -> Int64
      static func setSync(_ db: Database, account: Int64, _ change: AccountSyncChange) throws
      static func upsertLabels(_ db: Database, account: Int64, _ labels: [GmailLabel]) throws -> MailStoreChange
      static func ensureViews(_ db: Database, _ keys: [MailViewKey]) throws
      static func insertStubs(_ db: Database, account: Int64, _ stubs: [NewStub]) throws -> MailStoreChange
      static func store(_ db: Database, account: Int64, _ messages: [FetchedMessage]) throws -> MailStoreChange
      static func applyLabels(_ db: Database, account: Int64, _ changes: [LabelChange]) throws -> MailStoreChange
      static func delete(_ db: Database, account: Int64, gmailIDs: [String], at: Int64) throws -> MailStoreChange
      static func resummarise(_ db: Database, threads: Set<Int64>, context: SummaryContext) throws -> MailStoreChange
  }
  enum MailIndexReader {
      static func page(_ db: Database, _ request: PageRequest) throws -> [IndexRow]      // 4.4
      static func counts(_ db: Database, views: [MailViewKey]) throws -> [MailViewKey: ViewCounts]
      static func conversation(_ db: Database, id: MailConversationID) throws -> IndexConversation?
      static func facts(_ db: Database, threads: Set<Int64>) throws -> [Int64: [MessageFacts]]
      static func stored(_ db: Database, account: Int64, gmailIDs: [String]) throws -> [String: StoredMessageState]
      static func labels(_ db: Database, account: Int64?) throws -> [StoredLabel]
  }
  ```
  `store` applies the stale-read rule of 5.6 and refuses tombstoned ids itself — no caller can
  forget. `view.key` is `MailViewKey`'s JSON with sorted keys. View rows for an account's
  system labels, All Mail, Done and the unified twins are made by `ensureViews` when the account
  is first stored; a label's view when the label is.
- *Tests include:* the plans of the page query, the unread count, the unread-only page, the
  conversation read and the two queues contain **no `SCAN` of a table and no `TEMP B-TREE`**;
  a store built twice from the same inputs is identical; after every write, `view_thread`
  equals recomputing it from scratch (a repair function, kept as the oracle); a fetch older
  than a stored history record does not change labels; a tombstoned id is not stored;
  `labelsKnown` is set by `store` when it applies a read's label set and by nothing else —
  `insertStubs` and `applyLabels` leave it as it was.
- *Performance:* a 5,000-message store built in the test — a page read is one index range
  (asserted by plan), and reading 2,000 rows takes less than ten times reading 200.
- *Unblocks:* P12a, P23a, P06b.

**P10a — The Gmail protocol and the fake, part one.** ≈ 1,400 lines. After P03a, C0b.
- **From the owner's rulings (22, M1–M6; 13.10):** the fake's rows 51 and 52 (17.2): a thread's id is its first message's, and dated
  listings — both with their switches.
- *Creates:* `M/GmailAPI.swift` and `M/GmailSession.swift` (5.1; `GmailFormat` is P03a's and
  is not declared again), `M/GmailCost.swift` (`QuotaProfile.may2026`, `.legacy`),
  `M/MailQuotaGoverning.swift` (`QuotaLane`; the protocol `MailQuotaGoverning` with
  `take(_:lane:)` and `report(_:)`; `UnlimitedGovernor`, used until P11);
  `M/Testing/FakeGmail.swift`, `M/Testing/FakeGmail+Injection.swift`,
  `M/Testing/FakeGmail+Web.swift` — rows 1–31 and 42–52 of 17.2 (51, 52: thread ids and
  dated listings, for the sync limit; 49: no `labelIds` on a
  message without labels; 50: mail that did not come through Gmail, with a forged header; 47: the
  `Authentication-Results` every received message carries, in Gmail's believed form, with
  its switch — 10.6; 48: a message whose `full` answer is `malformed` — 5.6), the injections, the ledger,
  the second client; `M/Testing/MailFixtureMailbox+Fake.swift` (loads the mailbox of 13.6
  into a fake); `M/Testing/MailConvergence.swift` (the convergence check of 17.1, usable from
  P12a on); `T/FakeGmailTests.swift` (one test per row, named by its number),
  `T/GmailSessionTests.swift`.
- *Tests include:* an unverified token's first call is `profile`; a token that answers for
  another address stops the account and is never used again; a token minted "by someone else"
  is verified all the same; one 401 is retried with a fresh token and a second is thrown;
  `messages(ids:)` never has more than four requests in flight (the ledger) and returns results
  in the order asked; the standard mailbox loads, and the fake then lists exactly its
  conversations; `testACallCancelledWhileItWaitedForATokenMakesNoRequest` — a token source
  that hands a cancelled caller a token all the same: the call throws `CancellationError` and
  the ledger shows no request (5.1, step 1).
- *Unblocks:* P12a, and every flow test after.

**P12a — Sync, part one: handshake, head, headers.** ≈ 800 lines. After P06a, P10a.
- **From the owner's rulings (22, M1–M6; 13.10):** the fetcher holds a conversation **whole**: when the ids it knows of a thread do not
  include the thread's own id, it reads the thread, not the messages (5.4). The head is
  unchanged — the newest inbox page is inside any limit. Tests: a reply that arrives in a
  conversation begun before the edge brings the whole conversation; a conversation wholly
  inside it costs one read a message; with `threadIDIsFirstMessage = false` every
  conversation is read as a thread.
- *Creates:* `M/MailSyncEngine.swift` (one per account: `handshake()`, `runHead()`,
  `runPass() async -> MailPassReport`, health); `M/FetchPlanRules.swift`; `M/MailFetcher.swift`
  (header-format reads → `MailIndexWriter.store`, batches of 20); `M/MailPassReport.swift`;
  `T/FetchPlanRulesTests.swift`, `T/MailFirstSyncTests.swift`.
- *Tests include:* the fixture mailbox's inbox is in the index after `handshake` and `runHead`,
  in Gmail's order; a `labels` answer missing `INBOX` changes nothing; a profile for another
  address stores nothing; a read that answers `notFound` for an id never stored removes
  nothing; three wanted messages of one conversation are one `thread` call.
- *Performance:* the ledger shows at most 1,800 units for the first fifty conversations.
- *Unblocks:* P23a.

**P23a — The engine: activate, lists, places, the change hub.** ≈ 1,400 lines. After P12a.
- *Creates:* `M/MailEnvironment.swift` (13.6's block, except `MailDeviceRole` and `MailPower`,
  which are P02's, and `MailClock`, which is P01a's); `M/MailAccessTokens.swift` — the
  `MailTokenSource` the session is given (5.1), over `MailEnvironment.access`; **the engine
  never holds a `MailTokenFlight`**; `M/MailEngine.swift` — `final class
  MailEngine: MailSource`, holding the stores, the writer, the sync engines and the feeds'
  registry, **and no member of the protocol that this slice does not build**: those are
  answered by `MailSource+NotYet.swift` until a later slice declares them in its own file;
  `M/MailEngine+Reads.swift` (`activate`, `setVisible`, `accounts`, `observeAccounts`,
  `observePlaces`, `cachedFirstPage`, `observeList`, `status`, `badges`, `observeEvents`);
  `M/MailChangeHub.swift` (the `MailChangeSink`), `M/MailListFeed.swift`,
  `M/MailPlacesFeed.swift`, `M/MailFirstPaint.swift`, `M/MailStatusModel.swift`,
  `M/MailBadgeMirror.swift` (writes `MailBadgeCounts.mirror(to:)` when a number moves),
  `M/PollRules.swift`, `M/MailRuntimeCore.swift` (`resume()`, `suspend()`, the poll loop on
  the clock, and `addPassConsumer(_:)`); `M/MailPassConsumer.swift` — `protocol
  MailPassConsumer: AnyObject { func passFinished(_ report: MailPassReport) async }`;
  `M/Bench/MailBench+Engine.swift` (the `activate` and `firstPage` lines gate A needs);
  `M/Testing/MailEngine+Fixtures.swift` (`MailEngine.onFixtures(_:)`: temporary stores, the
  fake loaded and synced, the mailbox's device states applied through the stores' own
  operations); `T/MailEngineContractTests.swift` (the suite's subject for the real engine),
  `T/MailListFeedTests.swift`, `T/MailFirstPaintTests.swift`, `T/PollRulesTests.swift`,
  `T/MailSuspendTests.swift`.
- *Touches:* `M/MailSlices.swift` — the `passConsumers` section (status only, so far) and two
  lines in `benches`.
- **`activate()` opens the stores on the engine's start queue** — a serial `DispatchQueue`,
  `mail.start` — never in a detached task: opening is blocking GRDB work and a detached task
  runs on the cooperative pool (4.2, 12.1). **The engine makes the one `MailDiskWatch`**
  (11.3) from `MailEnvironment.freeDiskBytes`, the role's floor and the clock, and hands it
  to each thing that fills the disk as that thing is built.
- *Tests include:* `activate()` returns before any store is opened (a store that never opens:
  the call still returns), **and the opening runs on `mail.start`, not on a thread of the
  cooperative pool** (the fake store's `open` records the queue it was called on); a commit
  that touches no view a feed shows wakes no feed; a sync
  burst delivers at most once a second per feed; a poll with nothing new delivers nothing and
  writes nothing; after `suspend()` an hour on the manual clock makes no request and leaves no
  sleeper; **`suspend()` is synchronous and awaits nothing — it cancels the passes and the
  sleepers and calls `access.cancelMailTokenRequests()`, and waits for none of them to
  unwind** (`testSuspendCancelsTokenRequestsAndAwaitsNothing`, in `T/MailSuspendTests.swift`:
  a fake access whose token request answers only when cancelled — `suspend()` returns, the
  fake was told, the pass then ends having made no request; 3.3, rule 7);
  `cachedFirstPage` is nil unless the restored scope matches, and reads no database;
  growing a list from 100 to 200 delivers the larger list before the smaller observation ends;
  `MailPlaces` carries an unread count and a total for every split and mailbox, the total
  "at least" while the inbox still has undated conversations (A1); the burst is twelve polls
  five seconds apart and no more, ends when Mail leaves the screen, does not start in Low
  Power Mode, and is not restarted by its own polls (A6); **the contract's read tests pass on
  the engine, and every scope's rows equal the in-memory source's** — the first time the two
  sources are compared.
- *Performance:* `activate()` ≤ 1 ms on the main actor (asserted with a blocking fake store,
  by structure, not by a stopwatch).
- *Unblocks:* the first screen; P23b.

**P09a — The generator and the read benchmarks.** ≈ 500 lines. After P06a; needed for gate A.
- *Creates:* `M/Bench/MailBench.swift` — `protocol MailBench { var name: String { get };
  func run(in directory: URL, messages: Int) throws -> [Double] }`, compiled in every
  configuration because the run is a Release run; `M/Bench/MailSynthetic.swift` (the
  generator of section 21, writing index rows directly: 200 conversations, 20,000 messages,
  200,000 messages — **not** the fixture mailbox's bulk builder, which makes Gmail JSON for
  the fake; 200,000 messages of JSON through a fake would take minutes, and no screen uses
  this one); `M/Bench/MailBench+Read.swift` (the read rows of section 15);
  `A/MailBenchVerification.swift` (`--verify-mail-bench`, 17.6: runs `MailSlices.benches`,
  prints, compares — **and the `protection` check, which is not a timing**: in the tree the
  run made, it reads back the protection class of `index.sqlite-wal`, of `first-page.json`
  installed through `MailFiles`, and of a file it installs through `MailFiles` in
  `Attachments.noindex`, prints `mail-check protection wal=… firstPage=… attachment=…`, and
  on a device exits non-zero unless they are `completeUntilFirstUserAuthentication`,
  `complete` and `complete`. On a Simulator and on a Mac it prints `not enforced here` and
  passes: neither enforces the classes, and the Simulator reports none (4.1). This is where
  the classes are verified — the owner's first device run, D18); `tools/mail-bench-baseline.json`.
- *Touches:* `M/MailSlices.swift` — the `benches` section; `BananaApp.swift` — one line,
  `MailBenchVerification.runIfRequested()`, beside the other `…Verification.runIfRequested()`
  calls; `CalendarWriteBack.isDiagnosticLaunch` — `--verify-mail-bench` in its list, so a
  bench launch never syncs calendars.
- *Accept:* the Release run prints every line and exits 0; its output, with the load, is in
  the package note.

### 18.5 Order 2 — changes, delivery, undo

**P06b — The index store: overlay, marks, queues, holds.** ≈ 700 lines. After P06a.
- *Creates:* `M/MailIndexWriter+Overlay.swift`, `M/MailIndexWriter+Reconcile.swift`,
  `M/MailIndexRepair.swift` (the from-scratch recomputation, as a function);
  `T/MailIndexOverlayTests.swift`, `T/MailIndexReconcileStoreTests.swift`.
- *The primitives* — as P06a's, static functions on the `Database` of the caller's transaction:
  ```swift
  extension MailIndexWriter {
      static func setOverlay(_ db: Database, account: Int64, _ assertions: [Assertion]) throws -> MailStoreChange
      static func clearOverlay(_ db: Database, account: Int64, keys: [SentKey]) throws -> MailStoreChange
      /// Empties `overlay` and refills it from `rows`, 500 at a time; returns when done (6.4).
      static func rebuildOverlay(_ db: Database, from rows: [StoredAssertion]) throws -> MailStoreChange
      static func mark(_ db: Database, account: Int64, generation: Int, _ seen: [Membership]) throws
      static func clearMarks(_ db: Database, account: Int64, generation: Int) throws
      static func queueVerify(_ db: Database, msgPKs: [Int64], reason: VerifyReason, generation: Int, at: Int64) throws
      static func recordVerify(_ db: Database, msgPK: Int64, gone: Bool) throws
      static func nextToVerify(_ db: Database, account: Int64, reason: VerifyReason?, limit: Int) throws -> [QueuedVerify]
      static func hold(_ db: Database, msgPKs: [Int64], evidence: Int, at: Int64) throws
      /// `.remove` deletes the held messages; `.keep` marks them `vis = 4`.
      static func resolveHold(_ db: Database, account: Int64, _ choice: HoldChoice, at: Int64) throws -> MailStoreChange
      static func pruneTombstones(_ db: Database, olderThan: Int64) throws
  }
  enum VerifyReason: Int, Sendable { case unconfirmedByListing = 1, changeAnswered404 = 2, staleListing = 3 }
  enum HoldChoice: Sendable { case remove, keep }
  struct QueuedVerify: Equatable, Sendable { var msgPK: Int64; var gmailID: String; var reason: VerifyReason; var generation: Int }
  ```
- *Unblocks:* P14b, P12b, P13a.

**P14a — The intent store and the two rules.** ≈ 900 lines. After P02, P05.
- **From the owner's rulings (22, M1–M6; 13.10):** `syncLimit()` and `setSyncLimit(_:)` on `meta` — the limit is this device's and must
  outlive a rebuilt cache (5.4) — and `claims(account:) -> Set<String>`, the thread ids this
  store has a claim on (a draft, an unfinished send, an undelivered or refused change, an
  open question), which release reads.
- *Creates:* `M/MailIntentSchema.swift` (4.8); `M/MailIntentStore.swift` — owns its
  `DatabaseQueue` **privately**, made by `MailStores.openIntent()` (which sets
  `synchronous=FULL` and `fullfsync=ON` in `prepareDatabase` and again after opening, and
  refuses a connection that does not read them back — 4.2; read back from a fresh store in
  the test), and exposes only typed operations. **It checkpoints its own log**: it conforms
  to `MailWriterLog` (P02) with a `MailLogCheckpointer` for `intent.sqlite-wal` —
  `checkpointIfDue()` is a `PASSIVE` checkpoint when the rule of 4.2 says the log is due,
  `truncateCheckpoint()` a `TRUNCATE` — and whoever builds a writer and an intent store hands
  the one to the other (`writer.keep(intent)`), so that both run on the writer's queue,
  after a piece and never inside one. Nothing else checkpoints this file. Because the queue is private and no later package may edit
  this file, **it carries every operation the later packages need, from the start**:
  assertions — `write(_ group: [StoredAssertion], change: StoredChangeGroup?) throws`,
  `pending(account:) -> [StoredAssertion]`, `markSent`, `markAnswered` (rows `WHERE seq =
  sent_seq`), `removeDelivered(keys:)`, `discard(group:)`, `refusedGroups() ->
  [StoredChangeGroup]`, `deleteDerived(account:)`; drafts — `insertDraft`, `updateDraft`,
  `draft(id:)`, `drafts(account:)`, `markDiscarded(id:at:)`, `restoreDiscarded(id:)`,
  `removeDiscarded(olderThan:)` (by id, a day later), and the same for `draft_attachment`;
  `appendSendLog` and `pruneSendLog(olderThan:)` (by id, at 90 days); questions —
  `raise(_:)`, `settle(id:)`, `openQuestions()`; `setNotifyMark(account:…)` and
  `notifyMark(account:)`; the journal salt and `nextSequence()`; a test hook
  `failNextCommit(_:)`. Each is a few lines over the DDL of 4.8, and each removes rows only
  by key. No `erase`, no `vacuum`, no method that removes a table, the file, or
  rows by anything but their key; `M/MailIntentSalvage.swift` (4.10); `M/OutboxRules.swift`,
  `M/OverlayRules.swift`; `T/OutboxRulesTests.swift`, `T/OverlayRulesTests.swift`,
  `T/MailIntentStoreTests.swift`.
- *Tests include:* every row of 6.1's table — except that `snooze`, `unsnooze` and `mute`
  produce nothing until P19a brings their label names, and the test says so; an assertion
  never names a draft, and "the last message" skips one; `asOf` leaves a
  newer reply alone; `isMoot` is false for `nil` in both directions; `gmailHas` is `nil` for
  an absent label on a stub, on a rebuilt row, and on a row that only listings and history
  records have touched; a source scan asserts the
  file contains none of `erase(`, `vacuum`, `DROP`, `eraseDatabaseOnSchemaChange`, **and that
  no file of `M/` but `MailIntentStore.swift` and `MailIntentSalvage.swift` calls
  `openIntent(` or `openIntentQueue(`**; kept by a writer, the store is asked to checkpoint
  once after each piece and not between a piece's two steps, a log over 8 MiB is checkpointed
  and one under it is not, and `truncateCheckpoint()` leaves the log empty; a store newer
  than the code is not opened and not touched; a damaged file is copied aside before anything
  else.
- *Performance:* the intent commit's cost on the Simulator, logged.
- *Unblocks:* P14b, P17.

**P14b — Accepting a change.** ≈ 800 lines. After P14a, P06b.
- *Creates:* `M/MailActionWriter.swift` (6.2 steps 4–9 as one `MailWriterWork`; **its
  `absorb` answers no once the piece carries `MailKnobs.groupCommitChanges`, fifty** — the
  writer does not count, 4.12 — with a test that sixty changes handed over during one slow
  commit make two commits, of fifty and ten);
  `M/MailOverlayRebuild.swift` (launch and after a rebuild; the remembered keys of 6.4);
  `T/MailActionWriterTests.swift`, `T/MailOverlayRebuildTests.swift`.
- *Tests include:* deleting `Cache/` whole leaves every intent and re-applies it; a kill
  between steps 6 and 7 is repaired at launch; **a commit that fails with `SQLITE_FULL` writes
  nothing to the index, reports each receipt, and the next change is accepted normally**;
  archive then un-archive leaves nothing to send; an assertion for a message not in the index
  is applied when its row arrives.
- *Unblocks:* P15a, P23b.

**P12b — Incremental sync.** ≈ 900 lines. After P12a, P06b.
- **From the owner's rulings (22, M1–M6; 13.10):** history under an edge (5.4's table, 5.5): `HistoryRules.plan` is given the edge and
  the claim labels, and for a message whose conversation is not held it plans a read before
  any write (`messagesAdded`), a fetch of the whole conversation (a claim label added), or
  nothing. Tests: ten thousand `labelsRemoved` records for mail outside the limit cost no
  read and write no row; an old message that was imported is read once and not stored; new
  mail in an old conversation holds it whole; starring an old conversation elsewhere holds
  it; a `messagesDeleted` for a message not held writes no tombstone.
- *Creates:* `M/HistoryRules.swift`; `M/MailSyncEngine+Incremental.swift`;
  `T/HistoryRulesTests.swift`, `T/MailIncrementalSyncTests.swift`.
- *Tests include:* new mail; labels changed elsewhere; a deletion writes a tombstone; a fetch
  delayed past a newer history record does not overwrite it (the fake's `.delay(until:)`); a
  fetch in flight across a deletion does not bring the message back; a kill between pages
  replays to the same state; added-then-deleted is never fetched; a record naming an unknown
  label reads `labels` once; a label change for an unknown message makes a stub and reads it;
  a pass with no records commits nothing and publishes nothing, and writes the position at
  most once an hour; `notFound` from `history` leaves every row and clears the position; and
  each of these again with `historyOmitsOwnChanges`, `getOmitsHistoryID` and `listingLag`.
  **The pinning test for S-N1:** a stub listed under `INBOX` only, then a `labelsAdded STARRED`
  record, still has `labelsKnown` false; marking it read produces an `UNREAD`-absent assertion
  that `isMoot` does not drop and delivery sends; after a `minimal` read the flag is true.
- *Performance:* a pass with nothing new is one call, zero commits (asserted).
- *Also drains* `verify_queue` rows whose reason is a change's 404 (6.5), at most 50 a pass.
- *Unblocks:* P15a.

**P15a — Delivery and settling.** ≈ 900 lines. After P12b, P14b.
- *Creates:* `M/DeliveryRules.swift`; `M/MailOutboxDriver.swift` (a `MailPassConsumer`);
  `T/DeliveryRulesTests.swift`, `T/MailOutboxTests.swift`, `T/MailSeededRunTests.swift` (the
  seeded random run of 17.1, ending in P10a's convergence check; gate B and every gate after).
- *Touches:* `M/MailSlices.swift` — the outbox driver's line in `passConsumers`.
- *Tests include:* a hundred archives cost at most 60 units; an answer lost after Gmail applied
  the change, then replayed, converges; **an undo pressed while the request is on the wire is
  still pending after the 2xx**; a `batchModify` with one dead id falls back to single calls and
  the other 99 are delivered, under each `batchBadID` switch; a change's 404 deletes nothing
  and queues a read; a refused assertion stops overlaying and is listed; the conflict rule of
  6.8 with a change made "on the web"; an opposite record with no echo before it is not
  applied and a read follows; in flight at relaunch becomes pending; the convergence check
  after each.
- *Unblocks:* P15b, P17.

**P15b — Undo, retry, discard.** ≈ 400 lines. After P15a.
- *Creates:* `M/MailUndo.swift` (the last 50 "before" lists, in memory);
  `T/MailUndoTests.swift`.
- *Tests include:* undo before delivery sends nothing; after delivery sends the inverse; a
  whole-scope change gives each conversation its own labels back; an unknown receipt returns
  `count` 0.

**P23b — Commands on the contract.** ≈ 900 lines. After P15b.
- **From the owner's rulings (22, M1–M6; 13.10):** a change to a conversation this device does not hold is not made: `count` 0, nothing
  shown (9.4). A change marks its conversation attended.
- *Creates:* `M/MailEngine+Commands.swift` (`apply`, `undo`, `retry`, `discard`,
  `createLabel`, `checkNow`; until P19a, `apply` of `.snooze`, `.unsnooze` or `.mute` returns
  `count` 0 and shows nothing — 13.2); `M/MailReceipts.swift`; `M/MailEvents.swift`;
  `M/MailListFeed+Pending.swift`; `T/MailContractTests+Commands.swift`,
  `T/MailPublishTests.swift`.
- *Tests include* (on both sources): `apply` returns with a store that never answers; the
  snapshot delivered before `apply` returns includes the change; *n* changes are *n* list
  deliveries and no `MailStatus` change; a scope target is one receipt and one undo; what
  `apply` shows at once equals what the store then says, for every row of 13.2's table; a
  failed save puts the row back and announces `notSaved`; the publish recorder sees no
  flash-back across the seeded random run.

**Pure packages that can be built beside order 2, landing one at a time:**

**P04 — Text and small codecs.** ≈ 500 lines.
- *Creates:* `M/MailTextHTML.swift` (`MailText` → HTML, 7.1); `M/MailPlainText.swift` (plain
  mail → `MailText`: the linkifier of 10.4, `>` quotes); `M/MailRowID.swift` (4.6);
  `M/MailCompression.swift` (`NSData.compressed(using: .zlib)` behind two functions); tests.
- *Tests include:* `plain-text-urls`: two links and one `mailto:`, nothing else actionable;
  the serialiser's output passes the sanitiser unchanged.

**P16 — MIME and reply rules.** ≈ 900 lines.
- *Creates:* `M/MIMEBuilder.swift`, `M/MailHeaderCoding.swift`, `M/ReplyRules.swift`; golden
  files under `T/Fixtures/Mail/mime/` with `tools/check-mime.py` (Python's `email` parses each
  and prints its structure for comparison); `T/MIMEBuilderTests.swift`,
  `T/ReplyRulesTests.swift`.
- *Tests include:* the same draft builds the same bytes; `header-injection-reply`
  (`subject: "Hi\r\nBcc: x@evil"`) yields one `Subject` and no `Bcc`; an invalid address
  refuses to build; `.final` carries no `X-Banana-*` header and the bytes contain no
  `banana-mail:`; RFC 5322's three threading cases; one "Re:", never two; reply-all leaves his
  own addresses out and never copies `Bcc`; the identity is matched against verified aliases by
  exact address; `quoted-reply-with-trackers` loses its trackers and its parent's `cid`.

**P20a — HTML: the parser seam, the sanitiser, the text.** ≈ 1,400 lines.
- *Creates:* `M/MailHTMLSource.swift` and `M/MailHTMLBound.swift` (10.3);
  `M/MailHTMLSwiftSoup.swift` — **the only file that imports SwiftSoup, and it may call
  `SwiftSoup.parse` and `NodeTraversor` and nothing else**; `tools/update-tracker-list.sh`; `M/MailHTMLRules.swift` (the allow-list of 10.4 as data);
  `M/MailHTMLSanitiser.swift`; `M/MailCSSFilter.swift`; `M/MailURLRewriter.swift`;
  `M/MailQuoteDetector.swift`; `M/MailNativeText.swift`; `M/MailHTMLPreparer.swift`;
  `M/MailTrackerList.swift` with `Banana/Resources/MailTrackers.json` and its licence;
  `T/MailHTMLLibxml2.swift` (a `MailHTMLSource` over the system libxml2, test target only);
  the HTML fixtures of 17.5; `T/MailHTMLPreparerTests.swift`, `T/MailCSSFilterTests.swift`,
  `T/MailHTMLDifferentialTests.swift`, `T/MailForbiddenAPITests.swift` (the grep of 10.4).
- *Tests include:* every HTML fixture's stated assertion; over every fixture the output,
  parsed again by libxml2, holds only allow-listed elements and attributes, no `on…`, no URL
  outside `banana-mail:` and raster `data:`; no `banana-mail:` URL that this run did not
  generate; `html-2mb-plus` is refused before parsing; **on a thread created with a 512 KB
  stack**, `nested-100k-divs` and `nested-100k-inline` are prepared and cut at depth 200, and
  `nested-30k-bold` and `nested-10k-tables` are refused by `MailHTMLBound` with no parser
  called (a counting source) — the bound's own cost is a bench line, not a stopwatch in a
  test; the bound never counts fewer start tags than either
  parser builds elements, over every fixture; no function in the HTML files calls itself (a
  source scan for the walk and the serialiser); the forbidden-token test includes
  `.outerHtml(`, `.html()`, `Cleaner(`, `Whitelist`, `Safelist`, and the file-writing tokens
  outside `MailFiles.swift`; the libxml2 source, with `HTML_PARSE_HUGE`, ends a deep document
  at the same depth; `pictures-10000x10000-x1000` yields 500 pictures and no boxes; a
  Content-ID in angle brackets, upper case or percent-encoded still matches its part;
  the kind is `.text` for `simple-links` and `.designed` for anything with a table or picture.
- *Performance:* `--verify-mail-bench prepare`: the 63 KB and 261 KB fixtures within twice the
  recorded medians; `dispatchPrecondition(condition: .notOnQueue(.main))` in `prepare`.

### 18.6 Order 3 — reading

**P03b — MIME structure.** ≈ 500 lines. Pure.
- *Creates:* `M/MailMIME.swift` — the extraction only: `extension MIMEStructure { static func
  extract(_ payload: GmailPart, limits: MIMELimits) -> MIMEExtraction }`, where
  `struct MIMEExtraction { var structure: MIMEStructure; var html: String?; var plain:
  String? }` and `MIMELimits` (depth 20, 1,000 parts) are this package's own. **The value
  type `MIMEStructure` is P03a's, whole (appendix A), and is not edited or redeclared**: this
  package fills every field of it — the tree; the attachments with part id, name, declared
  type, size, content id, inline flag and `isInvite`; `htmlPartID` and `plainPartID` for the
  two parts it chose and decoded to UTF-8; `invite`; and `cut` when a limit stopped the walk.
  `M/MailInviteRules.swift` (10.10: `read(_ ics: Data) -> MailInvite?`, at most 256 KB, two
  unfolded lines — here because the extraction is its first user); `M/Base64URL.swift`
  (Foundation, in 64 KB pieces); the four shape fixtures of 17.5 (`mime-depth-50`,
  `mime-2000-parts`, `encoding-tricks`, `mime-depth-200`, the large ones generated); tests.
- *Tests include:* alternative inside mixed inside related; Latin-1 and UTF-8 bodies; an
  unknown charset is UTF-8 when the bytes are, Windows-1252 when not (5.6); `mime-depth-50`
  and `mime-2000-parts` come back with `cut` set and no bodies (stored by P12c as headers with
  `body_kind = tooLarge`); **`mime-depth-200` does not decode as a `GmailMessage` at all**,
  which is the fact 5.6's fallback exists for; an invitation as a file and as an alternative
  of the body both give `invite` with its method and UID, and one whose part has no data
  gives `uid == nil`; base64url with and without padding; `encoding-tricks` yields valid
  UTF-8 with no NUL.

**P07 — The blob store.** ≈ 600 lines. After P02, P03b.
- *Creates:* `M/MailBlobSchema.swift` (4.7; its migration is added to `MailSlices.migrations()`),
  `M/MailBlobStore.swift` (content, prepared, attachment rows, sizes, removing an account,
  the test hook for a lost commit); `T/MailBlobStoreTests.swift`.
- `MailBlobStore` is the writer of `blobs.sqlite` and checkpoints it itself, on its own
  queue, with a `MailLogCheckpointer` of its own (P02; the rule of 4.2): `afterPiece` after
  each of its transactions, and `truncateCheckpoint()` for suspend. `MailWriter` checkpoints
  the index and the logs it is handed, which is intent's and not this one.

**P12c — Full messages and bodies.** ≈ 600 lines. After P07, P12b, P20a.
- *Creates:* `M/MailFetcher+Full.swift` (content to blobs, then the index); `M/MailBodyRepair.swift`
  (the three repairs of 5.6); `T/MailBodyFetchTests.swift`.
- **A message that cannot be had whole is still stored, once** (5.6): one whose walk was
  `cut`, and one whose `full` answer is `malformed` while its `header` answer decodes, are
  both written at `fetch_state = 2` with `body_kind = tooLarge` and a header-level content
  row, and leave both queues. A `malformed` answer whose `header` read also fails stores
  nothing and is not read again in this process; a `thread` that answers `malformed` is
  read message by message.
- *Tests include:* a blob commit lost on reopen is found and fetched again; opening a message
  whose content row is missing sets it back and fetches it; **`mime-depth-200` on the fake
  (17.2, row 48) becomes a row that says it is too large, costs one `full` and one `header`
  read ever (the ledger, over three passes and a relaunch), and does not hold up the messages
  queued behind it; with every answer `malformed` — a captive portal — nothing is marked, and
  each id is read at most twice in the process**; a conversation of three with one such
  message stores the other two whole.

**P20b — The prepare queue, the document, and the rules for links, pictures, lists.** ≈ 1,000 lines.
- **From the owner's rulings (22, M1–M6; 13.10):** `RemoteImageRules` takes `MailPicturePolicy` and `MailPictureSender` (10.6): four
  levels, the tracker switch, nothing in Spam without his tap. **A tracker is marked, not
  removed** (10.4). Tests: every line of the decision in order; a sender rule does not cover
  a message with no authenticated domain; a domain rule covers a subdomain and not a
  look-alike that merely ends with the same letters; `everyone` loads an unauthenticated
  message and nothing in Spam; with blocking on, a tracker is refused under `everyone` and
  under "this message", and with it off is a picture like any other; `.warming` never
  fetches at any level.
- *Creates:* `M/MailPrepareQueue.swift` (paced; `prep_state` 0 → 1 → 2, and 3 at launch for a
  row found at 1); `M/MailDocument.swift`; `M/MailLinkRules.swift`; `M/RemoteImageRules.swift`;
  `M/MailUnsubscribeRules.swift`; tests for each. (`MailInviteRules` is P03b's: 10.10.)
- *Tests include:* the table of 10.7 (`paypal.com.evil.example` shown as "paypal.com" warns;
  userinfo refuses; an `xn--` host warns; `127.0.0.1` refuses; `mailto:` with `bcc` and `body`
  composes with To only; a picture link warns); `newsletter-tracked`: with the default, zero
  fetch decisions, 58 waiting, 3 trackers removed; `.warming` never fetches under any setting;
  an unauthenticated sender is never "always"; the four unsubscribe fixtures; a row left at
  `prep_state = 1` is shown as text and not parsed again; the queue stops when the pace says
  so; a picture prepared under tracker list 1 and decided under list 2, which names its host,
  is refused (N-2); `PreparedBody.links` records the shown text for every kept `href`, and for
  a duplicate the entry that warns.

**P23c — Conversations and bodies on the contract.** ≈ 800 lines. After P12c, P20b.
- **From the owner's rulings (22, M1–M6; 13.10):** `MailPictures.offers`, `sender`, `domain` and `shownBy`; `showPictures(in:always:)`,
  `pictureRules()`, `removePictureRule(_:)`. `wants` fetches a conversation the device does
  not hold, whole, and marks it attended; opening marks attended at most once a day, and only
  near or past the edge (13.10). Tests: `.sender` and `.domain` are offered only with an
  authenticated sender, and nothing is offered in Spam; a rule added from a message shows
  that message's pictures and names itself in `shownBy`; removing it stops the next message
  and deletes no picture.
- *Creates:* `M/MailConversationFeed.swift`; `M/MailEngine+Conversation.swift` (`conversation`,
  `observeConversation`, `body`, `resource`, `decideLink`, `wants`, `fetchBody`, `showPictures`,
  `alwaysShownPictureDomains`, `stopAlwaysShowingPictures` — A4);
  `T/MailContractTests+Conversation.swift`.
- *Tests include:* `body` of a prepared message performs no parse (a counting parser); `body`
  of a row prepared at version 1 under code at version 2 performs exactly one parse and
  returns version 2 — the old fragment is never returned (N-4); `decideLink` for
  `link-mismatch` returns the warning; a resource for another message's key is nil; a resource
  asked for while `.warming` is never fetched; opening marks nothing read by itself.

**P21a — Attachments on demand, and the picture cache.** ≈ 800 lines. After P07, P20b.
- *Creates:* `M/MailAttachmentStore.swift` (the file tree, sniffed types, safe names, the Mac
  quarantine attribute through an injected closure); `M/AttachmentRules.swift` (11.1; prefetch
  answers false until P21b); `M/MailRemoteImageCache.swift`; `A/MailRemoteImageLoader.swift`
  (10.6, through the transport gate, created with a `URLSessionConfiguration` handed in);
  `M/RemoteFetchRules.swift`; `M/MailEngine+Attachments.swift`; the attachment fixtures;
  tests, with a `URLProtocol` standing in for the network.
- *Tests include:* `attachment-pdf-is-macho` is stored as `.bin`, marked a mismatch and
  executable; `attachment-png-is-html` is never served as a picture; `attachment-30000px-png`
  is refused without decoding; a stale attachment id is refreshed once; a 30 MB download
  decodes in constant memory; **the loader's rules (P-10's minimum):** a redirect to `http://`
  is refused, a redirect to `https://10.0.0.1/` is refused, a fourth hop is refused, a gzip
  body inflating past 10 MB is abandoned, and the request carries `MailRemoteUserAgent`, no
  cookie and no `Accept-Language`; the file-writing tokens appear in no mail file but
  `MailFiles.swift`.
- *The quarantine test (P-8's minimum), and where it runs.* Both test bundles of the project
  are iOS, and the Mac app may not be launched. The repository's root `Package.swift` already
  runs macOS tests with `swift test`; this package adds to it a target `MailMacChecks` —
  sources `Banana/Model/Mail/MailFiles.swift` and `MailFileName.swift`, which are Foundation
  only for this reason — and a test target `MailMacChecksTests`
  (`PerformanceInfrastructure/Tests/MailMacChecksTests`). Run with `swift test --filter
  MailMacChecksTests`, it installs a file through `MailFiles` with the real quarantine
  closure and asserts that `com.apple.quarantine` has an unassessed flags field and the
  email-attachment type, and was set before the file reached its final path.
- *Touches:* the root `Package.swift` — those two targets.

**P26 — The web view.** Built together with the UX's reader package; ≈ 700 lines.
- *Creates:* `A/MailWebConfiguration.swift`, `A/MailSchemeHandler.swift`,
  `Banana/Views/Mail/MailWebView.swift` (iOS and Mac), the `--mail-webview` route on the
  hostile fixtures, `BananaUITests/MailWebViewUITest.swift`.
- *Touches:* `BananaApp.swift` (`VisualAuditRoute.flags`), `RootView.swift` (the route),
  `MacDebugSnapshotViews.swift` (one case).
- *Tests:* items 20–23 of 10.5; `link-mismatch` tapped in the web view raises the warning
  sheet (through `decideLink`).
- *Performance:* the route's idle CPU and both processes' memory in the gate.

### 18.7 Order 4 — writing and sending

**P10b — The fake, part two: drafts and send.** ≈ 600 lines.
- *Creates:* `M/Testing/FakeGmail+Drafts.swift` — rows 32–41 of 17.2 and their switches;
  `T/FakeGmailDraftTests.swift`.

**P17 — Drafts.** ≈ 1,000 lines. After P15a, P16, P10b.
- *Creates:* `M/MailDraftStore.swift` (the `draft` table through `MailIntentStore`),
  `M/DraftRules.swift`, `M/MailDraftSync.swift`; `T/DraftRulesTests.swift`,
  `T/MailDraftTests.swift`.
- *Tests include:* text typed and never saved by hand survives a kill; nothing is uploaded
  while the composer is open and untouched by a close; a create whose answer was lost adopts
  its own draft, under `msgidFindsDrafts` both ways; a draft edited "on the web" with no local
  change is taken, with local changes is asked about; a draft's `notFound` asks Gmail's Sent,
  not the index — **and with `msgidFindsSent = false` a draft sent from the web is still found
  by the newest-Sent fallback, the row is retired, and the ledger shows no `createDraft`**; a
  reply whose original has been deleted still builds and threads.

**P18 — Send.** ≈ 1,200 lines. After P17.
- *Creates:* `M/SendRules.swift`, `M/MailSendDriver.swift`, `M/MailSendGate.swift`,
  `M/MailOutgoing.swift`; `T/SendRulesTests.swift`, `T/MailSendTests.swift`.
- *Tests include:* every row of S3 by injection; **after `unknownOutcome` the fake's ledger
  shows exactly one `sendDraft`, under `sendReplay = .sendsAgain` and `draftLingers` — the
  proof that nothing but the person sends twice**; the lost answer ends in `sent` with one
  `SENT` message; a new message with no thread is verified by `rfc822msgid:`; with
  `rewritesMessageID` the fallback finds it; a kill in every state, then `afterRelaunch`; undo
  inside the hold answers true only after the commit (a slow commit: the answer waits);
  `finishSends` ends holds and returns within its limit; a hold that ended 25 hours ago asks; a `gone_once` draft whose copy was sent from the web is
  not sent again with `msgidFindsSent` either way;
  two engines, one draft, one send — and under `concurrentSend = .bothSend` the test records
  that the design cannot prevent it (R3). The fake has no `messages.send`, so half of invariant
  7 is a compile-time fact.

**P23d — Drafts, sending, questions and recipients on the contract.** ≈ 1,000 lines. After P18, P20a.
- *Creates:* `M/MailEngine+Drafts.swift` (every draft and send member of 13.3, with
  `quoteAsText`, `changeIdentity` and `resource(_:forDraft:…)` — A2); `M/MailDraftParts.swift`
  (a fragment prepared into a `MailDraftPart`, and what its document may be served);
  `M/MailQuestions.swift`; `M/MailEngine+People.swift` and `M/RecipientRules.swift`
  (`people(matching:limit:)`, 9.5 — here, not in P23e, because the composer of order 4 needs
  it); `T/MailContractTests+Drafts.swift`, `T/RecipientRulesTests.swift`,
  `T/MailJournalPrivacyTests.swift` (section 16 — here, because this is the first slice with a
  whole session to run: sync, search of the index it has, triage, a draft and a send).
- *Tests include:* each `MailQuestion.Kind` can be raised and answered, and leaves
  `status.questions` in the same turn; a question that answers itself announces `settled`;
  a new reply's `quote` and `signature` arrive as parts whose `body` is `.text` or
  `.designed` and whose `fragment` round-trips through `save` unchanged; `quoteAsText` moves
  the quote's words into `body` and clears `quote`; `changeIdentity` replaces address and
  signature together; a picture in a quote is served only for that draft and only as the
  quoted message's own rules allow; **`needsAnswer` rises when a send is refused for good and
  falls when he discards or re-sends it** (A3); `people` ranks written-to addresses first, and
  `correspondent-poison` is not offered.

### 18.8 Order 5 — search and splits

**P08a — The query language and splits.** ≈ 800 lines. Pure.
- *Creates:* `M/MailQuery.swift`, `M/MailQueryRules.swift`, `M/MailSplits.swift` (the three
  built-in splits as queries; merge of synced definitions), `M/ViewMembershipRules+Splits.swift`;
  tests.
- *Tests include:* the operators of 9.1 round-trip; tokens' ranges cover the text; dates
  become epoch seconds for Gmail; no typed character can become FTS5 syntax; an inbox
  conversation is in exactly one split and the split counts add up to the inbox's.

**P08b — The full-text index.** ≈ 900 lines. After P07, P08a.
- *Creates:* `M/MailSearchSchema.swift` (4.6; its migration added to
  `MailSlices.migrations()`), `M/MailSearchIndexer.swift` (paced; the writer of
  `search.sqlite`, and so the one that checkpoints it — a `MailLogCheckpointer` of its own
  (P02; the rule of 4.2) after each of its transactions, `truncateCheckpoint()` for suspend),
  `M/MailSearchReader.swift`; `T/MailSearchTests.swift`.
- *Tests include:* results are conversations, newest first, with no sort step in the plan; a
  header-only row is replaced when its body arrives; a superseded query is interrupted; a kill
  between indexing and clearing the flag re-indexes harmlessly; a rebuilt index keeps the same
  search row ids; no SQL in `M/` contains `rank`.

**P23e — Search and suggestions on the contract.** ≈ 600 lines.
- **From the owner's rulings (22, M1–M6; 13.10):** **the merged search** (9.4), about 500 lines more: `M/MailRemoteRows.swift` — Gmail's
  rows for one list, in memory, with the session's cache of header reads; the 400 ms settle,
  cancellation on every change of text, ten header reads at once and the rest as the list
  grows; `askGmail` for a search and for a place's older mail; `heldSince`. Tests, on the
  fake: the device's rows are delivered before Gmail is asked and none of them moves when
  Gmail's arrive; a conversation both found is one row, in group 0; a row only Gmail found
  is in no store (every table counted before and after); opening it stores it whole and
  marks it attended, and it is released when the edge passes that day; typing five
  characters quickly makes one listing, not five (the ledger); a cancelled query's reads
  stop; offline is `.offline` and the device's rows; `askGmail` on the inbox lists mail
  before the edge and on a second call the next fifty; under "everything", complete, no
  request is made unless asked.
- *Creates:* `M/MailEngine+Search.swift`, `M/MailSearchFeed.swift`;
  `T/MailContractTests+Search.swift`. (`people` is P23d's.)
- *Tests include:* a search delivers at most twice per query; Gmail's extra rows are group 1;
  coverage says what was searched.

**P27 — Synced lists.** ≈ 400 lines.
- **From the owner's rulings (22, M1–M6; 13.10):** the picture rules are the synced list, one record a rule, keyed `a:<address>` or
  `d:<domain>` (8.5); `everyone` and the tracker switch are settings, not records.
- *Creates:* `A/MailControlsSource.swift` (a `CloudControlSource` for the two kinds);
  `M/MailEngine+Splits.swift` (`saveSplits`, which no earlier slice built);
  `T/MailSplitsSyncTests.swift`.
- *Touches:* `ControlsCloudRecords.swift` — `ControlKind.mailSplit` and `.mailSender`;
  `BananaApp.wireUp` — two `register` lines; `T/ControlsSyncTests.swift`.
- *Tests include:* a sender domain removed on one device (A4) is a tombstone, and the next
  message from it asks on the other.

**P09b — The remaining benchmarks.** `A/MailBenchVerification+Write.swift`,
`+Search.swift`, `+Prepare.swift`: the write, search and prepare rows of section 15.

### 18.9 Order 6 — a real mailbox

**P11 — The quota governor.** ≈ 500 lines.
- **From the owner's rulings (22, M1–M6; 13.10):** the day's bytes are **500 MB on every device** (5.2).
- *Creates:* `M/QuotaRules.swift`, `M/MailQuotaGovernor.swift`; tests.
- *Tests include:* the fill never takes the bucket below its floor while an interactive call
  is served at once; the rate halves and recovers; the day's bytes close the backfill lane
  only; state survives a round trip; two governors on one fake account settle near half the
  budget each; each `limitShape` is handled.

**P13a — Reconcile.** ≈ 1,000 lines. After P12b, P11.
- **From the owner's rulings (22, M1–M6; 13.10):** reconcile under an edge (5.4): dated listings, with a day's margin; the claims listed
  without a date; a close that suspects only what a dated listing could have shown; one
  `thread` read for each held conversation that reaches back past the edge.
  `ReconcileRules.unconfirmed` is given the edge. Tests: a first sync with a six-month limit
  on a fixture of three years stores nothing older than the edge but the claims, whole; a
  starred conversation from before the edge is neither queued for removal nor removed by a
  second reconcile; a message deleted from it elsewhere is found by the thread read and
  removed only by its own read's `notFound`; with `dateQuery = .wholeDays` the margin still
  covers the edge.
- *Creates:* `M/ReconcileRules.swift`, `M/MailSyncEngine+Reconcile.swift`;
  `M/MailEngine+HeldRemoval.swift` (the place `.heldRemoval(account:)` and the two answers —
  A5); `T/ReconcileRulesTests.swift`, `T/MailReconcileTests.swift`.
- *Tests include:* a first sync of a 2,000-message fake end to end, with new mail arriving
  through history while it runs; resuming after a kill at every step; a listing that skips an
  id (`listingPaging = .offset`) removes nothing and queues one read; history expiry during an
  enumeration; history expiry on a full cache keeps the cache and every pending intent; **a
  mailbox 40 % deleted elsewhere is held as one question although it was verified fifty at a
  time; the place `.heldRemoval` lists exactly those conversations until he answers and is
  empty after; "keep" leaves sync running and the messages readable; "remove" removes them**; a short
  `labels` answer removes nothing; an offline archive survives a cache rebuild and is
  delivered (the tri-state moot check).

**P13b — Fill, progress, drift.** ≈ 800 lines.
- **From the owner's rulings (22, M1–M6; 13.10):** the fill under a limit, and the limit itself on the contract:
  `M/MailEngine+SyncLimit.swift` (`syncLimit`, `setSyncLimit`, `conversationsBeyond`).
  Raising starts an enumeration with the wider edge; lowering stops the fill past the new
  edge at once and leaves the removing to release (P33). `MailDownload.limitEdge`; complete
  means `backTo <= limitEdge` with both queues empty. `isAtLeast` from Gmail's label
  counters; the inbox drift check compares ids from a dated listing (5.8). Tests: the units
  and bytes a six-month fixture costs (the ledger) against 5.4's table; raising from three
  months to a year fetches the nine months between and removes nothing; a count says "at
  least" exactly when Gmail's counter is larger.
- *Creates:* `M/MailSyncEngine+Fill.swift`, `M/MailDownloadProgress.swift`,
  `M/MailDrift.swift`; tests.
- *Tests include:* what is fetched within the first 1,800 and 5,800 units (5.4); the fill
  stops under the free-space floor and resumes above it; on battery it keeps two requests in
  flight; the two-pass drift check.

**P33 — Store upkeep.** ≈ 900 lines. Everything section 4 designs that no other package builds.
- **From the owner's rulings (22, M1–M6; 13.10):** `M/MailRelease.swift` — the release pass (5.4): once a day per account when the edge
  has moved, and after the limit is lowered; paced; fifty conversations a piece; index, then
  content, then search entries. Tests: nothing with a claim is ever released, each claim in
  turn, and one that appears mid-pass; a conversation a screen is observing is skipped; a
  released conversation's content and search entries are gone and its id is in no
  tombstone; a kill between index and content leaves an orphan the next pass deletes;
  lowering the limit releases what `conversationsBeyond` said it would and that number
  reaches zero; **after release, a reconcile and a week of history leave the mailbox in
  Gmail exactly as it was — nothing was sent, nothing asked to be removed**.
- *Creates:* `M/MailUpkeep.swift` (the unclean-exit marker, `quick_check` scheduling, storage
  counters, the free-space reading); `M/MailCorruption.swift` (4.10's table);
  `M/MailCache.swift` (`MailCache.reset()` — 4.1: it takes `Cache/`'s URL and nothing else —
  and `removeDownloaded(account:)`, the primitive under `removeDownloadedMail`);
  `M/MailRebuild.swift` (the index from stored content; search from text; derived-version
  rebuilds; all paced); `M/MailEviction.swift` (to the ceilings and the floor; index first);
  tests with deliberately damaged files.
- *Tests include:* a rebuilt index shows nothing unconfirmed and removes nothing that a
  listing does not confirm gone; a rebuild keeps search row ids; eviction never takes a
  draft's files or something opened this week; `MailCache.reset()` with pending intents
  leaves `intent.sqlite` byte-identical and every intent re-applies.

**P22a — Gmail over HTTP.** ≈ 1,000 lines. After the probe's fixtures exist.
- *Creates:* `M/GmailRequests.swift` (pure: every `URLRequest`), `M/GmailErrorMapping.swift`
  (pure: status and body → `GmailError`, as 5.1), `M/MailNetworkPolicy.swift`;
  `A/GmailHTTP.swift`; canned responses under `T/Fixtures/Gmail/`;
  `T/GmailRequestsTests.swift`, `T/GmailErrorMappingTests.swift`.
- **`malformed` is a 2xx whose body claims to be JSON and does not decode**
  (`Content-Type: application/json`). A 2xx of any other type — a captive portal's page — is
  `unexplained(200)`: it did not come from Google. Neither is retried inside the transport;
  what a `malformed` read means for one message is the fetcher's to decide (5.6), and the
  transport must not hide it by trying again. The two envelopes are decoded with P03a's
  `GmailLabelList` and `GmailSendAsList`.
- *Tests include:* every request's scheme and host; a 404 with an HTML body is `unexplained`;
  a 200 with an HTML body is `unexplained(200)`, and a 200 of JSON nested past the reader's
  limit is `malformed`, each after exactly one request; each recorded limit error maps to its
  `GmailLimit`; a redirect is refused; with the network policy off, zero requests.

**P22b — Uploads and downloads.** ≈ 500 lines.
- *Creates:* `M/GmailUpload.swift` (the two-part body written to a file), `A/GmailHTTP+Transfer.swift`.

**P01b — The calendar-touching half.** ≈ 700 lines. Alone; reviewed with P24.
- *Creates:* `M/MailGrantLedger.swift` — the ledger of 3.3 and `MailCredentialRefused`, pure
  and `@MainActor`: the grant state the main actor reads, the route a refusal's reason takes,
  and the order in which the flight is told things; `M/MailCredentialRecord.swift` — the
  keychain item's record and its coding (`[{email, refreshToken, scopes, grantedAt}]` to and
  from `Data`, `decodeIfPresent` for every field but the first two), Foundation only, in the
  pure folder **only so that its coding is tested**: no other file of `M/` may name it;
  `A/MailCredentialStore.swift` — the keychain calls and nothing else;
  `A/MailGoogleAccess.swift` (3.3); `T/MailGrantLedgerTests.swift`,
  `T/MailCredentialRecordTests.swift`.
- *Touches:* `GoogleCalendarService.swift` — the three-line change to `interactiveSignIn` and
  the appended `googleConsent` extension, nothing else; `GoogleTokenMinter.swift` — the
  `session` parameter, `scope` decoded, `MintedToken.scopes`, `token(from:now:)`;
  `BananaApp.swift` — `.onOpenURL` dispatching by scheme; `T/GoogleTokenMinterTests.swift`.
- *Must not:* touch `accept`, `reconnect`, `adoptAccountsFromStore`, `GoogleAccountCredential`
  or `GoogleAccountStore`; add the Gmail scope to `requiredScopes`; change the minute
  `GoogleTokenMinter` takes off the expiry it reports (3.3, rule 2 — the calendar's); edit
  `MailTokenFlight.swift` or `MailAccountAccess.swift` (the ledger is built round them); give
  the flight to anything but the ledger; tell the flight anything from a task nobody awaits.
- *Tests:* `token(from:now:)` with and without `scope`. **The ledger**, over a minting closure
  the test controls and a still clock: a refusal's reason is in `grant` before the first
  caller is told; `.none` and `.rejected` never reach the mint (the mints are counted); an
  empty credential is `.rejected(.emptyCredential)` and is never minted from; a transport
  failure is recorded nowhere; a refusal that arrives after `stored` is recorded against
  nothing, and the caller that was waiting is given the *new* credential's token; after
  `deleted`, a caller that was waiting on the old mint is told `.notGranted`; `dropToken`
  followed by `token(for:)` mints again **even when another caller asks in between**;
  `stored` clears a refusal and nothing else does. And, by name, the cases P01a's review
  asked for (3.3, the ledger's steps 1, 4 and 5, and `cancelMints`):
  `testAnErrorFromAReplacedCredentialsMintIsDroppedAndTheCallerStartsAgain` (the old mint
  refused, and again with `.transport`: the caller is given the new credential's token and
  `grant` stays `.granted`), `testAnErrorFromADeletedCredentialsMintIsToldNotGranted`,
  `testAnErrorFromTheCurrentCredentialsMintIsThrownAsItIs`,
  `testACancelledCallerIsToldItWasCancelledAndGivenNoToken`,
  `testACancelledCallerDoesNotStartAgainAfterAReplacement`,
  `testCancelMintsEndsTheMintOfEveryAccountHeld`,
  `testACancelStillOnItsWayDoesNotCancelTheNextRequestsMint`. **The record**: decodes with and without
  its optional fields, ignores fields it does not know, and round-trips; and, by reading the
  folder, no other file of `M/` names `MailCredentialRecord` or `refreshToken`.
- **What cannot be unit-tested, said plainly:** `A/` is not compiled into the tests, and the
  pure folder may not import Security (invariant 17). So `MailCredentialStore`'s keychain
  calls and their attributes — the service name, not synchronizable,
  `AfterFirstUnlockThisDeviceOnly` — are read in the code review, and seen working in the
  owner's before-and-after probe below.
- *Accept:* in the package's commit, `git show -U0 -- Banana/Model/GoogleCalendarService.swift
  | grep -c '^-[^-]'` prints `3`; the whole-app gate equals the baseline; and, with the
  owner's go-ahead, the before-and-after probe: `--google-window` on Mac Beta gives the same
  accounts and the same calendar summary before the package, after it, and after one Mail
  consent — **and a calendar sign-in on iOS still completes** (the `.onOpenURL` change, 3.3).

**P24 — App wiring and lifecycle.** ≈ 900 lines. After P01b, P22a, P23e, P33.
- **From the owner's rulings (22, M1–M6; 13.10):** `AppSettings.Snapshot` gains `mailPictures` with two values and `mailBlockTrackers`
  (optional; nil is on). The sync limit is not in it: it is per device (5.4).
- *Creates:* `A/MailRuntime.swift` (the engine, lazily; the poll timer; `resume`, `suspend` —
  which ends with `MailWriter.truncateCheckpoint()` and the blob and search stores' own);
  `A/MailWiring.swift` (`MailEnvironment.live()`, and the `MailUILog` closure the UI is handed,
  forwarded to the journal's `ui` event — section 16); `A/MailSettingsBridge.swift`;
  `A/MacAppDelegate+Mail.swift` (`#if os(macOS)`: `applicationShouldTerminate` and the sleep
  and wake observers of 7.5, as an extension of the app delegate U5 created);
  **`M/MailEngine+Accounts.swift`** — the members no earlier slice built: `setWantsMail`,
  `requestPermission`, `forgetPermission`, `storageUsed`, `removeDownloadedMail` (over P33's
  primitive), `reconsiderKeptMail`; and what 3.6 asks of an account that has gone: marking it
  detached, deleting its cache after seven days' absence, listing its unsent work;
  `T/MailAccountLifecycleTests.swift`.
- *Touches:* `BananaApp.swift` — one line in `wireUp()` (start if this device has opened Mail)
  and the environment value; `RootView.swift` — in the scene-phase handler, on a real return
  `MailRuntime.shared.resume()`, on `.background` `suspend()`; `MacRootView.swift` — resume on
  becoming active; `PerfWatchdog.swift` — the two sinks, outside `#if os(iOS)`;
  `AppSettings.swift` — optional `mailAccounts`, `mailUndoSendSeconds`, `mailPictures`,
  `mailNotifyFor` in `Snapshot`; `project.yml` — `MAIL_FIXTURES` in the Beta targets'
  Release configuration only (the owner's device runs use Beta).
- *Must not:* start anything in a `VisualAuditRoute` launch, in a diagnostic launch, or before
  `mailActivatedAt` is set.
- *Tests:* the journal privacy assertion over the real files; with `--disable-mail-network`,
  zero requests across a scripted session; an account absent for seven days loses its cache
  and none of its intents; **`MailSourceProbe.defaultsReached(by:)` is empty for `MailEngine`
  and for `MailFixtureSource`**, less the members named in the test as coming after the first
  release (gate F; 13.3) — each over a throwaway store and the fake Gmail, because the probe
  sends, discards and removes; `MailNotYet.onReach` is set by `MailWiring`.
- *Performance:* the whole-app gate: every existing route and every launch mark unchanged.

**P25 — Background tasks and notifications (iOS).** ≈ 700 lines. After P24.
- **From the owner's rulings (22, M1–M6; 13.10):** the overnight task runs the release pass after the fill (5.4), at the pace of 4.12.
  A scheduled message's five-minute notification and a reminder's wake are P18b's and
  P19b's, through the same `MailNotifier`.
- *Creates:* `A/MailBackgroundRefresh.swift` (both tasks of 12.2), `A/MailNotifications.swift`
  (the `MailNotifier`; the category and its actions; and **the handler for a tap and for an
  action**: a tap calls the UI's `MailSession.show(_:)` — U6 provides it — with the
  conversation the notification carries; *Done* and *Mark read* call `apply` with
  `.message(_)`; *Send now* answers the question), `M/NotifyRules.swift` (new mail, the
  summary, and `sendFailed` for a send refused for good); `T/NotifyRulesTests.swift`.
- *Touches:* `project.yml` — the two identifiers in **both** `Banana` and `BananaBeta`;
  `BananaApp.init` — `MailBackgroundRefresh.register()`; `RootView.swift` — schedule on
  backgrounding.
- *Tests include:* a first sync notifies nothing; mail read elsewhere before this device
  synced does not notify; a rebuilt cache does not notify again; the content carries no
  snippet unless the setting says so; a background refresh on the fake makes no attachment
  request (N-10).
- **The overnight task asks the pace** (4.12) before each stage and at each batch boundary.
  When it is `stopped` — the device is warm, or in Low Power Mode — the task finishes the
  item in hand, completes, and schedules its next run; it never sleeps inside a background
  task waiting for the device to cool.
- *Must not:* wait, in a task's expiration handler, for a pass to unwind. The handler calls
  the same `suspend()` the scene phase does — which cancels the passes and every token request
  in the air (3.3, rule 7) and returns at once — and completes the task.

### 18.10 Order 7 — timed things: snooze, remind me, send later

**In the first release, by the owner's ruling** ("I want these"; 22, M2). They come after
order 6 because each of them stands on something order 6 builds — the timed rules on the
reconcile's state (8.3's second gate), send later on a send that has been proved — and
because a real mailbox should be in use for the days its first sync takes while these are
built. All three are built and tested on the fake, both ways round for every behaviour a
probe has not settled; **what a probe gates is turning the feature on for a real account**
(gate G, MAIL-PLAN), never the building.

**P19a — Snooze and mute.** ≈ 900 lines. After P13a, P15b, P23b.
- *Creates:* `M/BananaLabelRules.swift` (8.2 — all six rules of `due`, the two about
  `Waiting` among them, so that P19b adds no rule), `M/MuteRules.swift`,
  `M/MailTimedRules.swift` (8.3; a `MailPassConsumer`, with its line in `MailSlices`),
  `M/MailLabelJanitor.swift` (8.2's janitor, run by the weekly reconcile);
  `T/BananaLabelRulesTests.swift`, `T/MailTimedRulesTests.swift`.
- From here `apply` accepts `.snooze`, `.unsnooze` and `.mute`, and the agreement test of 13.2
  gains their rows. A conversation carrying one of Banana's labels is a claim: it is held at
  any age and never released (5.4).
- *Tests include:* two engines wake one conversation once; **a stale engine, asleep across a
  wake and an archive elsewhere, sends no wake**; woken then done is not woken again; **after
  history has expired, a stale engine's first successful poll sends no wake until the
  enumeration has closed and its reads have answered (the second gate of 8.3)**; a device
  three days fast sends nothing early; the janitor deletes only on Gmail's zero, under
  `labelCountsLag` both ways; a snoozed conversation two years old is here, whole, after a
  first sync with a one-month limit.
- *Probe:* **W5** — whether hidden labels stay hidden in Gmail's own apps, what two snooze
  labels on one conversation look like there, and a label's counts. Not run: nothing in the
  rules depends on the labels being hidden, and the janitor is tested with counts that lag
  and counts that do not. **W5 gates the first snooze on a real account**, because what it
  could show is clutter in his Gmail — reversible, and his to see first.

**P19b — Remind me if no reply.** ≈ 400 lines. After P19a, P18.
- *Creates:* `M/MailReminders.swift` — what *sets* a reminder: when a send whose draft
  carries `remindIfNoReply` is confirmed (7.4), one assertion, `Banana/Waiting/<t>` present
  on the sent message, by the sent message's id; and `.snooze(until:ifNoReply: true)` on a
  conversation, which asserts the same on his last sent message in it and changes nothing
  else. What fires it is P19a's rules 3 and 4, already there; `T/MailReminderTests.swift`.
- *Tests include:* a reply before the time removes the label and nothing returns; no reply
  by the time brings the conversation back, once, on whichever of two engines is awake; a
  send that is still unconfirmed sets no reminder, and sets it when it is confirmed; a
  reminder on a message sent three years ago holds that conversation; the row says
  `.snoozed(until:ifNoReply: true)` and then `.backFromSnooze(due:wasIfNoReply: true)`.
- *Probes:* **W5**, as P19a; **W3**, which P18 already needed, for the sent copy's id.

**P18b — Send later.** ≈ 800 lines. After P18, P17.
- *Creates:* `M/ScheduleRules.swift` (pure: owner, late, takes over — 7.6),
  `M/MailScheduledSends.swift` (the owner's timer on the clock, in the foreground and inside
  the background refresh; the read of the draft before it sends; the five-minute
  notification), `M/MailEngine+Schedule.swift` (`MailSendOptions.at`, the two schedule
  questions, `sendFromHere`, `cancelSchedule`); `T/ScheduleRulesTests.swift`,
  `T/MailScheduledSendTests.swift`.
- **The safety rules are unchanged by being early** (invariant 8, D8): only the device a
  message was scheduled on sends it; no device takes one over by itself; every device shows
  a late one as late; the owner sends up to thirty minutes late and says so, and asks beyond
  that; a take-over is his answer, and first looks in Sent. A scheduled message is a claim:
  its conversation is held at any age.
- *Tests include:* two engines, one scheduled draft: the owner sends once and the other
  never does, under `concurrentSend = .bothSend` too; the other shows it late at five
  minutes; the owner asleep for forty minutes asks instead of sending; edited on the web
  between scheduling and the time, it does not send and asks; with
  `draftsDropUnknownHeaders` the other device sees an ordinary draft and nothing else
  changes; a kill at every state, then a relaunch.
- *Probes:* **W2** — whether Gmail keeps the two `X-Banana-*` headers on a draft, and through
  an edit elsewhere. Not run: built under `draftsDropUnknownHeaders` both ways; if Gmail
  drops them, other devices cannot say "scheduled" and the owner still sends. **W4** — two
  sends of one draft at once. Not run: **nothing changes, because the rule already assumes
  the worst** — one owner; W4 could only ever *relax* it (D8). **W3**, P18's. **W2 and W3
  gate the first scheduled send on a real account; W4 gates nothing but the relaxation.**

### 18.11 Later, each on its own decision

| Package | What | Needs |
|---|---|---|
| P28 | One-click unsubscribe's request and the invitation card's lookup | P20b; D-none |
| P21b | Attachment prefetch and its policy | D3 |
| P20c | CSS from `<style>` blocks | The first Mac fill's newsletters |
| P29 | Finish a send in a background `URLSession` on iOS | M5 |
| P30 | The Mac wakes the phone for new mail | D13; Push on the App ID |
| P31 | Seeding from another device | D12; its own design and security review |
| P32 | Extract an account type from `GoogleCalendarService` (3.2, option B) | A Connected Accounts screen |

## 19. Risks, and the probes that retire them

### 19.1 Risks

| | Risk | If it goes the wrong way | Held by | Retired by |
|---|---|---|---|---|
| R1 | The Cloud project's quota regime is unknown | The governor is four times too cautious, or the unit table is wrong | The rate adapts to real limit errors; the unit table is one constant | D7 (look in the console) |
| R2 | Bandwidth: 25 KB a message and the consumer allowance are guesses | A first sync takes longer than stated, or hits Google's limit before ours | The daily byte count; honest progress | Probe item 4 |
| R3 | Two `drafts.send` calls on one draft at the same instant | A message sent twice | One owner per scheduled send; only a person pressing Send on two devices within a second can reach it | W4 |
| R4 | A replayed `drafts.send` sends again instead of answering 404 | — | The engine never replays one (invariant 7) | W3 |
| R5 | Gmail drops unknown headers from a draft | Other devices cannot see that a draft is scheduled | The owner still sends it; nothing else depends on the headers | W2 |
| R6 | Gmail replaces our `Message-ID` | Verification by `rfc822msgid:` finds nothing | The fallback compares the newest Sent messages' headers; if that fails too he is asked, never resent | W3 |
| R7 | History does not report our own changes | — | Settling does not depend on the echo (6.3) | W1 |
| R8 | Reads lack `internalDate` or `historyId` in some format | An extra per-message read now and then | The floor falls back to the position when the request left (5.6) | Probe item 3 |
| R9 | Hidden labels are not hidden in Gmail's apps, or two snooze labels look wrong there | Clutter in Gmail | — | W5; the fallback is one `Banana/Snoozed` label plus a synced record for the time |
| R10 | iOS's SQLite lacks `contentless_delete` | The search schema needs another shape | P02's first test, on day one | P02 |
| R11 | A phone's flash is much slower than this Mac's SSD | The durable-change budget, the batch hold, cold reads | No commit window to tune; batch 20; the first-frame file | Owner run 1 |
| R12 | WebKit: script off but the measuring script needed; rule lists; a custom scheme | Height or picture loading needs another approach | Two layers; nothing depends on script in content | P26's UI test; prototype P3 |
| R13 | A sanitiser bug | Something hostile reaches the web view | The web view refuses it anyway; the differential test | The security review at gate C |
| R14 | The consent screen is in Testing; a Workspace admin restricts restricted scopes | Tokens die weekly; an account cannot grant Mail | Honest states | D1 |
| R15 | iOS runs the refresh task rarely | Late notifications and wakes on a phone in a pocket | Local notifications at the due time; plain words in the UI | D13 |
| R16 | A Google password change revokes the calendar's token too, once the same client holds a Gmail grant | The calendar is signed out on every device | Separate credentials (3.2) make it unlikely, not certain | W6 |
| R17 | A data race in engine code | Wrong state | GRDB's queues; one writer queue; Thread Sanitizer at every gate | — |
| R18 | A listing skips a message that nothing else mentions | It is missing here until the next reconcile | The count against `messagesTotal`; the weekly reconcile | Probe item 5 measures how often |
| R19 | Beta is not sandboxed from the mailbox | A test sends real mail | A test account for Beta until M5 (D11) | — |
| R20 | Real mailboxes are bigger or heavier than the synthetic one | Disk, index size, prepare time | Ceilings; the floor; a local rebuild can change the search configuration | Owner run 3 |
| R21 | The HTML parser crashes or burns CPU on something hostile | Mail crashes, or a 90 KB message costs a minute of a core (MEASURED: nested formatting tags and tables are quadratic in SwiftSoup) | `MailHTMLBound` on the bytes before any parse (10.3); an iterative walk; the "being parsed" mark; libxml2 behind the same seam | The nesting fixtures on a 512 KB stack; gate C. The bound's two numbers may refuse honest mail — owner run 3 counts how often |
| R22 | Two new dependencies | A bad release, or an upstream compromise | **Pinned by revision in `project.yml`** (C0a), the tagged version in a comment; each behind one seam (`MailStores`, `MailHTMLSource`). The revisions are the ones the spikes measured: GRDB 7.11.1 = `b83108d10f42680d78f23fe4d4d80fc88dab3212`, SwiftSoup 2.13.9 = `18b80329749eca5ea29fc50211dca5c7eff5bfec`; neither brings a package of its own. A revision, not a version, because a tag can be moved and `Package.resolved` — the usual record of which code a version was — cannot be committed here: it lives inside `Banana.xcodeproj/`, which is generated and ignored. (Older than mail and not changed by it: GoogleSignIn's seven transitive packages still resolve by range.) | D19 |
| R23 | The volumes behind the six-month estimate are assumed: 110 messages a day, 25 KB each | A first sync that takes longer than said, or a day's allowance that does not cover it | Both scale directly, and the fill says where it has got to; probe item 14 counts them; the first real sync reports both | 5.4 |
| R24 | Gmail's `after:` is not what is assumed — rounded to a day, read on another clock, not compared with `internalDate` | The dated listings miss or include a day at the edge | A day's margin; the claims and history do not depend on it; probe item 14; the fake's row 52 both ways | 5.4 |
| R25 | A thread's id is not the id of its first message | A conversation held with its beginning missing | The fallback is to read every conversation as a thread, at up to half as much quota again; probe item 14; the fake's row 51 both ways | 5.4 |
| R26 | With no server, a scheduled message goes only when the device it was scheduled on runs | A message he believes left at 8:00 leaves at 9:40 | Said when he schedules; shown late on every device; a notification five minutes after the time; "send now from here"; D8 again after W4 | 7.6 |
| R23 | Search's slow tail on a phone | Typing feels late at two to four letters | `prefix='2 3 4'` is a measured local rebuild away (4.6) | Owner run 1 |
| R24 | A listing lags behind history | A label just removed is put back until the drift check | The floor rule covers the opposite order; the drift check repairs this one | Probe; the fake's `listingLag` |

### 19.2 The read probe — before the fake is written

The first draft ran this after three milestones had been built on assumptions. It now runs at
**order 0, outside the app, with `curl` and a token for a test account** — no Banana code, an
afternoon — and its answers set the defaults of the fake's switches (17.2) and become the HTTP
layer's fixtures (17.4). It needs the owner's go-ahead and a test Google account (D11); no
agent calls Google. Output goes under the scratch directory with mode 0600; it records shapes,
counts, sizes and timings, never content, and prints whether the address matched, not the
address.

1. `getProfile`: fields present.
2. `labels.list`: every system label id; whether a conversation snoozed or muted in Gmail's
   own app carries any label; how nested labels are named; **the body when `fields=` is
   wrong** (what a short answer looks like).
3. One message read in each format: which keys come back (`historyId`, `internalDate`,
   `snippet`, `sizeEstimate`, headers), and whether the header filter is honoured.
4. Two hundred messages in `full`: gzipped response size, HTML size, text size, attachment
   counts, and per message the number of start tags, formatting start tags and `<table` tags —
   the distributions behind every ASSUMED size here and behind the two bounds of 10.3.
5. `history.list` from now, from an old message's id, from `1`, and from positions two days
   and a week old: status and error body for stale history, and how long history is really
   kept. Two complete listings of the inbox ten seconds apart, with one archive made in Gmail
   between them: do they agree, and does a listing ever end early.
6. A read of an id that does not exist: status and exact body. Twenty reads in parallel over
   one connection: timings, any limit, any retry header.
7. `drafts.list`, `settings.sendAs.list`: fields; whether a draft's `internalDate` is its
   creation or its last update.
8. `q=rfc822msgid:` for a known id, in mail and in drafts; `in:snoozed`; `is:muted`.
9. A message with attachments read twice: are the attachment ids the same.
10. Whether every response carries a `Date` header.
11. From twenty received messages' headers, **the exact form of the `Authentication-Results`
    Gmail adds**: its authserv-id; which properties a `dkim=` result carries (`header.i`,
    `header.d`, both); whether a `dmarc=` result with `header.from` is there, and for which
    senders it is not; whether a message in Sent, a draft, and a message imported or fetched
    from another account carry the header at all — **and whether a header written by the
    sender that claims `mx.google.com` survives**, above or below Gmail's. Property names and
    counts only (10.6).
12. A message with no labels at all — archived, read, uncategorised — read alone and inside
    its thread: **whether `labelIds` is absent or an empty list** (5.6). And, in the same
    reads: whether header values arrive with their encoded words decoded, and whether
    `snippet` arrives HTML-escaped.
13. Not Gmail's, and unverified in the same way: that the patterns of 10.8 —
    `\p{Script=Latin}`, `\p{Script=Cyrillic}`, `\p{Script=Greek}`, `\p{ccc=Virama}`,
    `\p{jt=…}` — compile and classify as expected on the system's ICU, on each platform the
    app runs on. No Google is needed: it is a unit test (P03a's), and its result is recorded
    here.
14. **For the sync limit** (5.4): whether `messages.list` takes `q=after:<epoch seconds>` and
    `before:` together with `labelIds`; whether the seconds are honoured or rounded to a day,
    and against which clock; whether it compares with `internalDate`; and, over two hundred
    conversations, **whether a thread's id is the id of its first message**. Also how many
    messages the account has in each of the last six months — the one number 5.4's table
    assumes.
15. **For the merged search** (9.4): for five queries, the ids `messages.list?q=` returns
    against the ids the same words find in a full local copy; whether its results are newest
    first; and the time to the first page.

**What is believed about Gmail without a document to cite**, each a row of 17.2 with a switch
that makes the fake behave the other way: that the profile's `historyId` is a safe place to
start history from (row 2, `profileHistoryLags`); that a history record's id can be used as
the next start (row 13, `historyStartInclusive`); that a label's counts are exact enough for the
drift check (row 6, `labelCountsLag`); that a read after a write reflects it (row 44); that a
parsed limit refusal means the request was not carried out (row 40); that a message's content
does not change under its id (row 17, `contentChangesUnderID`).

### 19.3 Write probes — each needs its own explicit yes

On the test account. W3 and W4 send mail, to that account only.

**What the first release now waits on** (the owner put send later and "remind me" in it):
W3 before P18's gate, as before. **W2 and W3 before the first scheduled send on a real
account; W5 before the first snooze or reminder on one.** W4 gates nothing: the rule it
could relax — only the owning device sends a scheduled message — stands until it has run
and shown that Gmail never sends one draft twice. A package whose probe has not run is
built with the fake behaving both ways (18.10 says which switch).

| | Does | Settles | Gates |
|---|---|---|---|
| W1 | Adds and removes a label twice; a `batchModify` with one bogus id; `TRASH` by `modify` against `messages.trash`; `labels.create` with a name that exists; reads history after each | Replay; whether history shows this client's changes (R7); the batch's answer (fake row 28); the duplicate answer (row 30); whether trash can ride in a batch | P15a |
| W2 | Creates a draft with the two `X-Banana-*` headers; reads it back; edits it in Gmail's web UI; reads it again; deletes it | R5; whether an edit elsewhere drops the headers | P17; P18b |
| W3 | Sends one message to itself with a chosen `Message-ID`; reads `drafts.get` at 0, 1, 2 and 5 s; searches `rfc822msgid:` under `SENT` at 0, 2, 5 and 30 s; replays `drafts.send`; reads the sent copy's headers and history | R4, R6; how long a spent draft lingers (row 39); how soon Sent can be searched; whether the sent copy keeps the draft's message id | P18 |
| W4 | Twenty drafts, each sent by two requests at once | R3 — and with it D8 | P18b |
| W5 | Creates `Banana/Snoozed/…` hidden; applies it, and a second one; `labels.get` for its counts; a screenshot of Gmail on the web and the phone, by the owner | R9; the janitor's count (8.2) | P19a |
| W6 | On the test account: allow Mail on a device, change the Google password, then ask whether the calendar's own token still mints | R16 — and with it D15 | P01b |
| W7 | Mail sent **to** the test account from a server outside Google, with a `From` in each doubtful shape — a quoted name that is an address, beside a bare address and alone; two mailboxes; two `From` headers; a bracketed address followed by a bare one; a group — and with a DKIM `i=` and an envelope sender whose local parts hold a space and a `;`. For each: whether Gmail accepts it; which address its `Authentication-Results` names; whether sender-written text arrives escaped inside that header | How Gmail itself reads a malformed `From` and which shapes it refuses (10.8); whether a sender can write a result into Gmail's own header (10.6) | P05, P06a — the rules hold whichever way it answers; the answers say how much they are worth |

## 20. Decisions for the author

**The one list he answers from is `MAIL-PLAN.md` section 8**, for both halves of mail; it cites
these as "E-D*n*". This section is the reasoning behind the engine's rows of that table: each
with a recommendation, and what changes if he chooses otherwise. Neither this document nor
MAIL-UX keeps a decisions list of its own.

**D1. The OAuth consent screen's publishing status.** *Recommend: External, "In production",
unverified, for both the production and the beta project.* One extra "unverified app" screen
per account per device, once; no seven-day expiry; the hundred-user lifetime cap is irrelevant
for one person (DOCUMENTED §12.2). His accounts span several Workspace domains and gmail.com,
so *Internal* does not fit. For each Workspace domain the admin console may need Banana's
client id trusted for restricted scopes. *If it stays in Testing:* every refresh token dies
seven days after consent, for the calendar as much as for mail. The client id is public; a
client Google suspends signs every device out, so a second OAuth client is worth keeping ready.

**D2. Remote pictures — ANSWERED: "Default to ask, but allow to set always for this sender,
always for this domain, and always period."** Four levels (10.6), keyed on what Gmail
authenticated; recognised tracking pixels are blocked at every level behind a switch of
their own that is on; nothing in Spam loads without his tap; a pane that follows the cursor
fetches nothing until he has stopped on a message. The reasoning that stood behind the
recommendation, for the record: *ask first.
Nothing is fetched until he taps "Show pictures" on a message or has chosen "Always from this
sender"; tracking pixels Banana recognises are never fetched; nothing is fetched for a message
he has not opened.* When pictures do load, that sender's server sees his IP address and the
time, and — where the picture's address was made for him alone, which is normal for
newsletters — that he opened that message. Banana cannot hide that: it has no server to fetch
through. *An option to turn on, not the default:* load pictures automatically from people he
has written to (only when Gmail authenticated the sender). *If "always load":* every sender
learns it for every mail he opens.

**D3. How much mail a device keeps — ANSWERED: "a sync limit, so lets say 6 months by
default", with search merged with Gmail's whenever the limit is not everything.** One month,
three, six, a year or everything; per device; six months unless he changes it (5.4, 9.4).
A device keeps what is inside the limit whole, and what he has a claim on at any age; older
mail is in Gmail and found by search. The size ceilings this decision used to be about are a
backstop now (11.3): attachments up to 2 GB, 4 GB and 20 GB, bodies up to 4 GB and 8 GB on an
iPhone and an iPad, and always at least 1 GB free on a phone or iPad and 5 GB on a Mac. *If
"everything":* 3–8 GB per 200,000 messages on that device plus attachments, and a first fill
of about five days of allowance on a Mac and a week or more on a phone.

**D4. Does unread mail count on the app icon?** *Recommend: no.* The Mail tab shows it; the
icon keeps meaning "something needs you today". Questions waiting for his answer do count.

**D5. May an account be connected for Mail only?** *Recommend: not now.* It needs the calendar
to stop requiring calendar scopes of every account — a change to the daily driver, with P32.

**D6. Mail per account, opt-in.** *Recommend: off for every account until turned on (a synced
setting); each device asks Google once per account, and starts fetching the first time Mail is
opened on it.*

**D7. Which quota applies.** *An action, not a choice:* Cloud Console → IAM & Admin → Quotas →
Gmail API, "per minute per user", for both projects. If it says 15,000, a first sync is about
four times faster than 5.4 says.

**D8. Who may send a scheduled message, and what "late" does.** *Recommend: only the device it
was scheduled on; every device shows a late one as late; up to 30 minutes late it goes and
says so, later it asks.* Decide again after W4: if Gmail never sends one draft twice, any
device that runs after the time could take a late message over. **Send later is in the first
release, by his ruling** (P18b, order 7), and it is built on this recommendation as its rule:
W4 can relax it later and cannot be needed for it.

**D9. The undo-send window.** *Recommend: ten seconds; leaving the app ends it and sends — on
the Mac, quitting waits up to 20 seconds for it.*

**D10. Does a conversation returning from a snooze become unread?** *Recommend: yes.*

**D11. Live access.** Separate permissions, each his: a test Google account; the read probe by
`curl` at order 0; the write probes one by one; Mail on Mac Beta against the test account at
order 6; and M5 — the first real send, by him, to himself.

**D12. Seeding a device from another over the local network.** *Recommend: decide after the
phone's first real fill.* It needs its own design and security review (5.10).

**D13. The Mac waking the phone for new mail.** *Recommend: yes, once mail is in daily use.* It
needs the Push capability on the App ID.

**D14. The search index: `prefix='2 3'` or `'2 3 4'`.** *Recommend: decide from the phone's
number (run 1 of D18).* The second removes the slowest case and makes the search index about
40 % larger (MEASURED); either way it is a local rebuild.

**D15. Where the Gmail credential lives.** *Recommend — and the security auditor, verifying
this revision, recommends the same: on each device, separately from the calendar's, not
synced (3.2, option C).* What it costs him:

- **Consent sheets.** One Google sheet per account per device, once: four accounts on three
  devices is about a dozen sheets over the first days, some twenty seconds each including
  Google's "unverified app" screen (D1). The turning-on screen walks the accounts, so a device
  is done in a few minutes. A new or restored device repeats it; a reinstall does not.
- **A Google password change** signs mail out on each device separately — one re-consent per
  device for that account — and, as far as can be told before probe W6, leaves the calendar
  alone.
- **What it buys.** The grant that can read and send his mail is on the devices where he
  allowed Mail and nowhere else: not in iCloud Keychain, not in its escrow, not on a Mac that
  never ran Mail. "Forget Mail access on this device" is a local act he can undo.

*If one shared, synced credential instead (option A):* one consent per account covers every
device — a few minutes saved, once; the Gmail grant is on every device signed into his Apple
ID whether or not Banana runs there; and a Google password change signs the calendar out
everywhere. The engine is the same either way; only P01b differs, so this needs an answer
before order 6, not before order 1.

**D16. What "Disconnect" says and does.** Disconnecting one account revokes nothing at Google;
"Disconnect all accounts" revokes at most the one account the Google SDK signed in during that
run, and mail's consent never becomes that account (3.3). *Recommend: say so* —
"Banana forgets this account. To withdraw Banana's access, remove it in your Google account" —
with a button to that page. *If he wants a button that revokes:* it ends Banana's access to
that account on every device at once, calendar included.

**D17. The mail store on the Mac — to be decided before order 6**, because order 6 puts real
mail on a Mac and after that the store exists. Any program he runs on the Mac as himself can
read it; unlike Apple Mail's, nothing asks first. FileVault protects the disk if the Mac is
lost, not against software running on it. *Recommend: accept that for the first release, and
say it where he will read it.* The sentence for Settings › Mail on the Mac, which the UX
document does not yet carry:

> Mail on this Mac is kept in your Library folder, unencrypted. Other apps you run can read
> it. FileVault protects it if the Mac is lost or stolen.

*If not:* bodies and attachments can be encrypted under a keychain key (about a package of
work, to be built before P24); subjects, senders and the search index would still be
readable, so it halves the exposure rather than removing it.

**D18. Six runs on his devices** — none of them touches his mail until the third. Agents may
not install on a device, and two checks mean nothing on a Simulator, so they are his: **at
every gate, `ScreensOpenUITest` in Release on the iPad** (the one place a too-large view type
overflows the stack; the rule it protects — small, type-erased view types — is a review item
for every view package), and the real protection classes of mail's files.

1. Beta on his iPhone, the fixture route, 30 minutes: the real full fsync, the four-letter
   search tail, the batch hold, hitches on the chosen list host; and the protection classes,
   read back by `--verify-mail-bench protection` (P09a) from `index.sqlite-wal`,
   `first-page.json` and a file installed in `Attachments.noindex` — the one place they are
   verified, since no Simulator reports them. Before order 3.
2. Six web views open on his iPhone, 20 minutes: both processes' memory. With gate C.
3. The first sync of a real mailbox on Mac Beta — an afternoon at the default limit of six
   months, days only if he sets it to everything: the real quota rate, **the two numbers
   5.4's table assumes (messages a day, bytes a message)**, prepare cost on his newsletters,
   whether the Mac's indexer heats a laptop; then a search that reaches past the limit.
4. An hour of his iPhone in front during its first sync, then a night on the charger.
5. Two hours with a podcast playing and Mail's tab last shown: that nothing of mail's runs in
   the background.
6. Five minutes of Control Center glances mid-episode: requests per glance.

**D19. Two packages and one data file — ANSWERED: approved ("Sounds good"), with the
whole-app performance commits.** GRDB 7.11.1 and SwiftSoup 2.13.9, each
pinned to the exact revision of that version, each behind one seam; and the MailTrackerBlocker host list (BSD-3)
vendored as data. This withdraws the earlier "no third-party dependency" constraint, as he
asked. *What linking them costs, MEASURED at C0a (simulator builds, before any mail code uses
either):* the Debug app bundle 234,888 → 247,704 KB (+12.8 MB); the Release app bundle
183,164 → 192,476 KB (+9.3 MB), of which about 5.1 MB is code (GRDB 2.1 MB, SwiftSoup 3.0 MB
of text) and the rest symbols a store build strips. It is paid from C0a on: `-dead_strip`
does not remove a Swift library nothing imports, because its type and conformance records keep
it alive. GRDB also adds one 8 KB resource bundle to the app, its privacy manifest. Neither
library reaches the Watch app or either widget. Both are pinned by revision (R22).

**D20. What the first release is — as he ruled.** Accounts, the inbox and splits, triage with
undo, reading — in a pane beside the list on a wide window — compose and send with undo-send,
search across the device and Gmail, attachments on demand, a sync limit, **snooze, "remind me
if no reply" and send later** (order 7). The Mac first, and built for the phone from the
first package (22, M5). Later: unsubscribe, attachment prefetch.

**D21. Drafts and Gmail.** A draft is saved to Gmail when he has left it alone for a minute —
which includes closing it — when the app goes to the background, and before sending; not as
he types. So an unfinished draft on one device appears on the others about a minute after he
stops. *If he wants it there as he types:* it is one
number, and unfinished text then reaches Google, his other devices and a Workspace archive
within seconds.

## 21. Measurements

Everything labelled MEASURED comes from one of three programs, all under
`docs/design/mail-working/`, all standalone — none touches the app, a device or Google.

| Program | What it is | Output |
|---|---|---|
| `spikes/mailstore_spike.swift`, `spikes/content_spike.swift` | The first spike: the raw C API, 8 MB caches, auto-checkpoint on, an earlier schema. Still the source for the comparisons that need two layouts built (search in or out of the index file; a unified view against an `IN` list; auto-checkpoint on or off; a reader holding a transaction). | `spikes/*.txt` |
| `spikes/grdb/` (a Swift package: `mailgrdb`) | **The re-measurement the performance review asked for (R-10): GRDB 7.11.1, the schema of 4.3 verbatim, the connections and pragmas of 4.2.** Modes `build`, `read`, `act`, `under`, `search`, `open`, `check`, `prefix`, `fsync`. Build with `swift build -c release --build-path <outside the tree>`. | `spikes/remeasure/*.txt` |
| `review/reuse-spikes/htmlspike/` | The reuse review's parser comparison: SwiftSoup and libxml2 over the two fixture newsletters — parse, allow-list walk, serialise, text. | `spikes/remeasure/html-prepare.txt` |
| `spikes/deep/` (a Swift package: `maildeep`) | SwiftSoup 2.13.9 on a secondary thread with a 512 KB stack: parse, iterative walk and release of *n* nested elements, one process per case; and the pre-parse bound's cost. Added in the correction pass (N-6). | `spikes/remeasure/deep-nesting.txt` |

**Conditions.** M1 Max, macOS 26.6, SQLite 3.51.0. The synthetic mailbox: 200,011 messages in
69,608 conversations across four accounts, 763 MB of text from a Zipf-distributed vocabulary of
120,000 words, 30,000 correspondents, labels and splits as a real mailbox has them. It has no
HTML, no quotes and no MIME; real mail will differ, which is what owner run 3 is for.

**Load.** Every run prints the load average beside its numbers. The HTML runs were taken at a
load of 12–13. **The store runs were taken at a load of 600 to 830**: other agents were
building and testing on this machine throughout, a script waited thirty minutes for it to
quieten, and it did not. Those numbers are therefore upper bounds, and their tails especially
are the machine's as much as the store's. They are good enough to choose between designs —
every choice below has a margin of two or more — and not good enough to be baselines;
`--verify-mail-bench` records those (17.6).

**Where a number moved enough to change a choice**

| Number | First design | Re-measured | What changed |
|---|---|---|---|
| Preparing a 63 KB / 261 KB newsletter | 0.19 ms / 0.60 ms — a byte scan that was not a sanitiser | 15.4 ms / 64.9 ms with SwiftSoup (libxml2: 4.3 ms / 17.6 ms) | **Prepared when fetched, on a paced queue, not when opened** (10.2). A version bump re-prepares lazily. |
| A sync transaction with a list reader running | 50 messages: 25.4 ms p95, against a 30 ms budget | 50: 23.7 ms p95, 41.7 ms p99. 20: 6.2 ms p95, 18.4 ms p99 | **Batches of 20** (4.2). |
| One intent commit carrying *n* changes | A fixed 8 ms window, sized from one fsync figure | 1, 5, 20, 50 changes: 0.8, 0.3, 0.6, 1.1 ms p50 | **No window**: a commit takes what arrived (6.2). |
| The log during continuous sync | "checkpoint when idle" | 348 MB after 8 s without one; its checkpoint 175 ms | **Checkpoint between batches** over 8 MB, not only when idle (4.2). |
| Search, two to four letters | 0.2 ms, one word repeated; 18 ms p95 at four letters | Forty words: p50 0.35 / 0.46 / 4.3 ms, p95 30 / 46 / 52 ms | **The 30 ms p95 budget is not claimed**; it is a device measurement, and `prefix='2 3 4'` (133 % → 187 % of the text; four letters 0.58 → 0.12 ms p50) is held ready (4.6, D14). |
| Counting a large view's rows | not measured | 2.5 ms p50, 11.4 ms p95 for 69,040 rows | **Totals stop at 10,000** (4.4). |
| Removing 50 messages' search entries | not measured | 88 ms p50, 375 ms p95 | Queued and paced like indexing; one more reason search has its own file. |
| GRDB after opening a WAL store | — | `synchronous = 1` whatever the configuration; `fullfsync` is left as `prepareDatabase` set it (P02: it reads back 1 when set there, 0 when not) | **Intent sets both, in `prepareDatabase` and again after opening**, outside a transaction, and a test reads them back (4.2). |
| A hostile nesting, on a 512 KB stack | "flattened at depth 256" by the visitor, after the tree exists | 100,000 nested `div` or `span`: no overflow, 0.12–0.16 s. 30,000 nested `b`: **54 s**; 10,000 nested tables: **44 s** — quadratic (load 220) | **A bound on the bytes before any parse** (`MailHTMLBound`: 0.5 ms for 500 KB), an iterative walk, depth 200 (10.3). |

**Where it did not**

| | First spike (raw API) | Through GRDB, this schema, loaded |
|---|---|---|
| First 50 rows of a view | 0.029 ms p50 | 0.11 ms p50, 0.18 ms p95 |
| Unread counts, twelve views | 0.22 ms | 0.41 ms p50 |
| A conversation's rows | 0.63 ms p95 | 0.13 ms p50, 0.99 ms p95 |
| An action written through to the index | 0.33 ms p50 | 0.21 ms p50, 0.78 ms p95 |
| Intent commit, full fsync | 2.98 ms p50, 5.0 ms p95 | 0.84 ms p50, 2.1 ms p95 (`fsync` mode, interleaved: NORMAL 0.04, FULL 0.10, FULL + fullfsync 0.38 ms) |
| Recipient lookup | 1.1 / 4.6 ms | 1.2 / 3.0 ms |
| First-page file, 50 rows | 17.6 KB, 0.27 ms | 24.9 KB, 0.27 ms p50, 0.45 ms p95 |
| `quick_check` of the index | 0.38 s (141 MB) | 0.69 s (172.7 MB) |
| Interrupting a search | 3.1 ms | 1.5 ms p50 |
| Index file | 141.3 MB | 172.7 MB — the columns and index this revision added |
| Search file | 1,105.6 MB after `optimize` | 1,118.2 MB before it |

**Not re-measured**, and still from the first spike: search in the index file against its own
file; the unified view against an `IN` list; auto-checkpoint on against off; a reader holding a
transaction (486 MB of log); `OFFSET` against keyset paging; base64 decoding in pieces (the
reuse review's 41 ms for 25 MB); zlib inflation.

**Differences between the spike's store and the design's that remain:** the spike has 4.5 view
rows per conversation and the design, with a per-account twin of All Mail and Done, about six
(roughly 10 MB more of `view_thread`); the spike's `label_intent` has a text group column
where the design has an integer; and the spike has no `question` table. None bears on a number
above.

## 22. What MAIL-UX conforms to, and what became of each finding

### 22.1 Differences from MAIL-UX section 12, which section 13 here replaces

Section 13 keeps the UX's names wherever it could. Where it differs, this is why — the rows
are the engineering review's forty (E-8), by its numbers.

| E-8 row | Now |
|---|---|
| 1 Identity | The UX's four id types, unchanged. |
| 2 Scope | `MailScope` with a filter set and an account, as the UX has it (4.4 says how each is read). |
| 3 Outbox and Drafts | Places, read through `observeList` like any other (13.7). |
| 4, 5 Order and cursor | **Changed:** `MailOrderKey` is `(group, sortKey, tie)`, not `(group, date, id)`. A list is descending key order in every place; the engine chooses what the key means. The row's `date` is a separate field. |
| 6 Paging | The UX's model — a limit that grows by 100 — with the cap at 2,000 until P1 says more is affordable. |
| 7, 8 Observation | Closures returning `MailObservation`, as the UX has it; `observeConversation` exists. |
| 9 Rate | At once for his own command; at most once a second from sync. |
| 10, 11 Counts and places | `total`, `MailPlaces` with counts, as the UX has them; a total past 10,000 is "at least". |
| 12 First page | Up to 50 rows; everything in it is durable (13.5 promise 5). |
| 13, 14 Bodies | **Changed:** `MailMessage.body` is a state; the body itself comes from `body(_:)`. Text is `MailText` — blocks and runs — not `AttributedString`: the engine has no fonts, and the UI maps it in one place. Anything with a picture or a table is `.designed`. |
| 15 Row | The UX's fields, plus `date`, `isImportant`, `isMuted`, `hasPendingChange`, `fromGmailSearch`; reasons extended for a refused change, an open question and a kept message. |
| 16 Back from snooze | **Declined:** "set Mon" cannot be shown. When a snooze was set is stored nowhere — the label carries only when it ends — and adding a second label per snooze to carry it would double Banana's labels in his Gmail. The reason carries `due`. |
| 17–21 Changes | The UX's `MailChange`, with `restore` added, `move(account:to:from:)` naming the label being left (and, like `label`, the account its ids are in), and `snooze(until:ifNoReply:)` as the UX has it (8.2 says what it asserts). |
| 22 Drafts | **Changed:** `newDraft(_:)` is the engine's and is `async`; `ReplyRules` is the only owner of reply addressing, so `MailDraft.reply` on the UI's side goes. The body is `MailText`; signature and quote are fragments. |
| 23, 24 Draft commands | `discard`, `retrySend`, `send(_:_:)` as the UX has them. `sendNow` is `answer(_, .sendNow)`. |
| 25, 26, 27 Status | The UX's `MailStatusValue`, `MailStatus`, `MailBadges`, `MailProgress` and their meanings, with `store`, `questions`, `refused` and `heldBy` added. |
| 28 Account state | **Changed:** `MailAccountState` is 3.4's four cases, beside `MailSyncHealth`. The UX needs words for `apiDisabled`, `notAllowedByAdmin`, `wrongAccount` and the store's states (section 14 has them). |
| 29, 30 Identities, attachments | On `MailAccount`; `fetchAttachment` and `attachmentProgress` as the UX has them. |
| 31 Events | **Changed:** ids and closed enums only; no subject and none of Google's words (invariant 21). The UI looks the words up. |
| 32, 33 Search | A place, as the UX has it, with no debounce; `MailTarget.scope` works on it. |
| 34 Splits | `saveSplits` exists. **Declined:** a custom split with free text — membership is kept when mail changes, and free text would need the search index inside that transaction. `saveSplits` returns the ids it could not keep; the built-in splits are queries (`is:important`, an invitation flag, the rest). |
| 35–38 | `suggestions`, `createLabel`, `unsubscribe`, `setWantsMail`, `requestPermission`, `storageUsed`, `removeDownloadedMail`: present. `unsubscribe` is `async` and only for a one-click offer the UI has confirmed. |
| 39 Restore | No call needed (13.5 promise 11). |
| 40 Notifications | The first split only by default; a tap opens the conversation; *Send now* on the waiting-to-send notification (12.3). |

Also new to the UX: `activate()`, `setVisible(_:)`, `body(_:)`, `resource(_:for:presentation:)`,
`queryTokens(_:)`, `retry` and `discard` of a receipt, `answer(_:_:)`, `addAttachment`,
`removeAttachment`, `rewriteAsText`, `hasUnfinishedSends`, `finishSends(within:)`,
`forgetPermission`, `decideLink(_:in:)` with `MailLinkRules`, `MailLinkDecision` and
`MailLinkWarning` now declared in the contract, `MailEvent.draftNotSaved`, and `cancelSend`
being `async`. Added at the UX's request after it conformed (22.2, last table):
`MailPlaceCount`, `MailDraftPart`, `quoteAsText(in:)`, `changeIdentity(of:to:)`,
`resource(_:forDraft:presentation:)`, `alwaysShownPictureDomains()`,
`stopAlwaysShowingPictures(from:)`, `MailPlace.heldRemoval`, and `needsAnswer`'s wider
meaning.

### 22.2 The findings

Every BLOCKER and MAJOR in the reviews that concerns the engine. "Fixed" names the section
that now carries the rule and, where there is one, the package whose test pins it. Nothing is
marked fixed that is only mentioned.

**Engineering**

| | | Outcome |
|---|---|---|
| E-1 | B | **Fixed.** P01a no longer names `GoogleAccountCredential` (3.3); the folder and its `project.yml` entry are created together by C0a (18.3). |
| E-2 | B | **Fixed.** One file, two implementations, one suite, one fixture mailbox (13.1, 13.6); the engine is behind the first screen (P23a). |
| E-3 | B | **Fixed.** Invariant 4 and 6.2: shown, then durable, with the failure path; `MailRowRules` (13.2); `MailReceipt.count` optional. Tests in P14b, P23b. |
| E-4 | B | **Fixed.** Invariant 7; 7.4 S3 and S4: nothing unknown is ever sent again by the engine. P18's ledger test. |
| E-5 | B | **Fixed.** 8.2's three rules and 8.3's second derivation; invariant 24. P19a's stale-engine test. |
| E-6 | B | **Fixed.** Invariant 23: the floor rule for listings (5.3) and reads (5.6); settling without a timer (6.3). P06a, P12b. |
| E-7 | B | **Fixed.** 18.2; the shared-file table in MAIL-PLAN. |
| E-8 | M | **Fixed**, row by row in 22.1 — except rows 16 and 34, declined there with reasons. |
| E-9 | M | **Fixed.** `MailQuestion`, `answer`, `retry`, `discard` (13.2, 13.3); P23d. |
| E-10 | M | **Fixed by removing its cause.** Mail no longer shares the calendar's credential, cache or state (3.2, 3.3). |
| E-11 | M | The UX's to fix. The engine's half — one list model — is 13.3 and 4.4. |
| E-12 | M | **Fixed.** P01a and P01b. |
| E-13 | M | **Fixed.** Outcomes and errors are mapped case by case in 3.3; the minter gains `token(from:now:)`; the gate script moves into `tools/` (MAIL-PLAN, order 0); the engine re-reads accounts at each pass. |
| E-14 | M | **Fixed.** 13.2 for what the UI builds on; appendix A for what two engine packages share; P05 creates the file. |
| E-15 | M | **Fixed.** 4.2 and P02: `MailWriter`, the two clocks (the protocol `MailClock` is P01a's, its first user — I1 below), per-store pragmas, who checkpoints, the mode of the performance line. |
| E-16 | M | **Fixed.** P06a and P06b, primitives as signatures, plans asserted by absence. |
| E-17 | M | **Fixed.** 5.5: one transaction rule, the hourly position write, the unknown message, the unknown label; lanes and invariant 2 in `GmailSession` (5.1); `MailPassReport` in place of an observer. |
| E-18 | M | **Fixed.** `modify` and `batchModify` apart, a result per message (5.1, 6.5); `GmailError.conflict`; invariant 5 reworded; `group_seq`; fake rows 28 and 30 switchable. |
| E-19 | M | The UX's. |
| E-20 | M | **Fixed.** P23a–e; `MailEnvironment` (13.6). |
| E-21 | M | **Fixed.** P33; checkpoints in P02. |
| E-22 | M | **Fixed.** Unknown label id (5.5); never a draft (6.1); the janitor on Gmail's count, five-minute rounding (8.1, 8.2). |
| E-23 | M | **Fixed.** The header list (5.6); the send no longer replaces content, so it needs no thread id (7.4 S1); identity from the response's ids, then `Message-ID` (S3, S4); the schedule check precedes the final upload (7.6). |
| E-24 | M | **Fixed.** Invariant 1; 5.7; 6.5: a change's 404 deletes nothing. P15a. |
| E-25 | M | **Fixed.** 17.2's table, switches and three tools. |
| E-26 | M | **Fixed.** The probe is at order 0, by `curl` (19.2); the claims are relabelled where they stand (5.5, 7.4, 9.4, 4.7) and listed in 19.2. |
| E-27 | M | **Fixed** for the engine: Thread Sanitizer at every gate (17.1); a Release fixture build (`MAIL_FIXTURES`, P24); error bodies from the probe (17.4); invariant 2 tested on the fake (P10a); the silence test and the soak (D18). The Mac key-table test is the UX's. |
| E-28, E-29 | M | The UX's. |
| E-30 | M | **Fixed.** One owner each: reply addressing (7.2), the tokenizer (9.1), `ShellState.mail` (13.8), the web view (P26, built with the UX's reader). |
| E-31 | M | **Fixed, one part declined.** The governor is the core only and uploads have their times (5.2, 7.3). **Declined:** dropping the byte budget entirely. One daily counter stays, because without it the fill can spend his whole documented allowance (2,500 MB a day, shared by all his clients) and lock his other mail apps out. |
| E-32 | M | **Accepted**: the window is gone (4.4), undo is in memory (6.7), the governor's extras are gone (5.2), timed labels and send later were later — and are in the first release since the owner's ruling (order 7, 18.10). Four files stay, as the review itself concluded. |
| E-33 | M | **Fixed.** The draft's body (7.1); native text (10.4, 13.2); what a notification shows (12.3); what an Outbox row is (13.7); labels changing elsewhere (5.5). |
| E-34 | M | **Fixed.** 17.6. |

**Data safety**

| | | Outcome |
|---|---|---|
| S-1 | B | **Fixed.** `isMoot` has three answers (6.1); invariant 22; rebuilt rows are unconfirmed (4.9). P14a, P13a. |
| S-2 | B | **Fixed.** 6.2's failure path; the free-space floor (11.3); invariant 26. P14b. |
| S-3 | B | **Fixed.** A complete `labels` answer is defined; a missing label is asked for by id (5.3). P12a, P13a. |
| S-4 | B | **Fixed.** Invariant 27; 7.5: quit and sleep on the Mac. P18, P24. |
| S-5 | M | **Fixed.** Invariant 25; `sent_seq` (6.3). P15a. |
| S-6 | M | **Fixed.** Invariant 23 (5.6). P06a, P12b. |
| S-7 | M | **Fixed**, completed in the correction pass: two gates, both required — a succeeded pass with Google's clock, and no enumeration unfinished (invariant 24; 8.3; 6.5 step 1). P19a's expired-history test. |
| S-8 | M | **Fixed.** `rfc822msgid:` under `SENT` needs no thread (7.4 S4). P18. |
| S-9 | M | **Fixed, more strictly than asked.** There is no automatic retry after an unknown result at all (7.4). |
| S-10, S-11 | M | **Fixed in the design** (7.6: late is shown everywhere; a non-owner must choose). Built with send later (P18b, order 7), which the owner's ruling put in the first release. |
| S-12 | M | **Fixed.** A reconcile's removals are judged together; incremental ones over 24 hours (5.3, 5.7). P13a. |
| S-13 | M | **Fixed.** `held_removal`, the question, sync continuing (5.7). P13a. |
| S-14 | M | **Fixed.** `notFound` has one shape (5.1); with no batch codec there is no outer status to confuse. P22a. |
| S-15 | M | **Fixed.** Invariant 28 (7.1). P17. |
| S-16 | M | **Fixed.** Three repairs (5.6); eviction order (11.3). P12c, P33. |
| S-17 | M | **Fixed.** Incremental sync runs during an enumeration; delivery never waits for one (5.3, 6.5). P13a. |
| S-18 | M | **Fixed**, completed in the correction pass: the draft-404 path and the `gone_once` check run the Sent check in full — the operator, then the newest 20 Sent messages (7.3; 7.4 S1, S4); fake row 12a, `msgidFindsSent`. P17, P18. |
| S-19 | M | **Fixed.** 6.5. P15a, under each `batchBadID`. |
| S-20 | M | **Fixed.** `upload_started` (7.3). P17. |

**Security and privacy**

| | | Outcome |
|---|---|---|
| P-1 | B | **Fixed.** Ask first; `presentation`; the authenticated domain (10.6); invariant 30. P20b, P23c. |
| P-2 | B | **Fixed.** A total rewriter; `banana-mail:` write-only; a dead base; a handler scoped to the message (10.4, 10.5); nothing of it in outgoing mail (7.2). P20a, P16, P26. |
| P-3 | M | **Fixed.** A real parser behind a seam, serialised output, limits (10.3, 10.4, 5.6). P20a, P03b. |
| P-4 | M | **Fixed.** `MailText`; the forbidden APIs and their test; one link path (10.4, 10.7). P20a. |
| P-5 | M | **Fixed**, with comparison by suffix in place of a public-suffix list, as the reuse review advised (10.7). P20b. |
| P-6 | M | **Fixed.** 10.9. P20b; the request itself is P28. |
| P-7 | M | **Fixed.** Not registered; the rules for when it is (13.9); `onOpenURL` by scheme (3.3). P01b. |
| P-8 | M | **Fixed, one part declined; the decline accepted with a minimum, now met.** 11.2. **Declined:** the app-wide `LSFileQuarantineEnabled`, which would quarantine every file the rest of Banana writes. Instead: type, agent and origin keys, applied at the atomic move, the flags asserted by a test, and one door for every file mail writes (`MailFiles`) with a static test that nothing else writes one. P02, P21a. |
| P-9 | M | **Fixed.** A credential per device (3.2); what Disconnect does and does not do (3.6); D15, D16. |
| P-10 | M | **Fixed for mail; one part is not mail's; the minimum now met.** Mail's sessions enforce `https`, TLS 1.2 and their redirect rules themselves (5.1, 10.6, 10.9); the picture loader has a seam and its redirect-downgrade, private-address, hop-count and inflated-size tests are in P21a's list (10.6). **Declined here:** narrowing the app's global transport exception, which exists for the podcast library and is that code's change to make; listed for the owner in MAIL-PLAN. |
| P-11 | M | **Declined, as a decision for him (D17) — accepted by the auditor on two conditions, both now in D17:** it is decided before order 6, and the sentence Settings must show is written there. It is said plainly (4.1). The encryption proposed would cover bodies and attachments and leave subjects, senders and the search index readable — by the review's own account it halves the exposure — while adding a key whose loss is a rebuild and a decrypt to every body read. |
| P-12 | M | **Fixed.** A journal that cannot be handed content; salted ids; the UI under the same rule; the end-to-end test (16). P02, P24. |
| P-13 | M | **Fixed.** 10.8, 9.5, 7.2. P03a, P16, P23d. |
| P-14 | M | **Fixed.** 10.11. Nothing is built that could break it. |
| P-15 | M | **Fixed.** 5.10 states the floor; not built. |
| P-16 | M | **Fixed.** What a quote carries (7.2); when a draft is uploaded (7.3); the owner header (7.2). The composer takes no HTML, so there is nothing pasted to sanitise (7.1). |

**Performance**

| | | Outcome |
|---|---|---|
| R-1 | B | **Fixed.** 10.2. |
| R-2 | B | The host is prototype P1's to decide. The engine's half is fixed: one list model, one read of *n* rows, measured (4.4), and a budget row for applying it (15). |
| R-3 | B | **Fixed.** Invariant 31; `MailWorkPace` (4.12); the table of 12.1; the watchdog told (16). P02. |
| R-4 | B | **Fixed** as a design: no window (6.2). The phone's fsync is still ASSUMED and is owner run 1. |
| R-5 | M | **Measured, and left open on purpose.** The cure costs 40 % more search index (4.6). It is adopted or not on the phone's number (D14). |
| R-6 | M | **Fixed.** 17.6. |
| R-7 | M | The engine's half is fixed: `activate()` at most 1 ms and never awaited (12.1); the sinks on the Mac (16, P24). The four whole-app fixes are order-0 items in MAIL-PLAN. |
| R-8 | M | **Fixed.** 5.4 says days; 12.1 budgets the foreground; section 14 has the words. |
| R-9 | M | **Fixed.** Whole-process and web-content rows (15). |
| R-10 | M | **Fixed.** Section 21. |
| R-11 | M | **Fixed.** 20, measured (4.2). |
| R-12 | M | **Fixed.** The writer survives a failed commit (6.2). P14b. |
| R-13 | M | **Not met, and said so.** No quiet machine was available: the load is beside every number (21), and the recorded medians are 17.6's job. |

**Reuse**

| | Outcome |
|---|---|
| B-1 GRDB | **Adopted** (4, 4.2), with its three behaviours pinned by tests (P02). |
| B-2, B-3 SwiftSoup behind a seam; one parse | **Adopted** (10.2–10.4). |
| B-4 The batch codec | **Removed** (5.1). |
| B-5 The calendar-file parser | **Removed** (10.10). |
| B-6 MIME for sending | **Kept, smaller**, checked by a standard reader (7.2). |
| B-7 The CSS filter | **Kept**, declarations first (10.4); blocks are P20c. |
| B-8, B-15, B-16 Base64, charsets, compression, no date-header parser, no resumable upload | **Adopted** (5.1, 5.6, 4.7). |
| B-9 Typed times | The UI's; it uses the repo's `EventPhrase.takeDate`. |
| B-10 One tokenizer | **Adopted** (9.1). |
| B-11 The composer's body | **Adopted** (7.1). |
| B-12 Attachments | **Adopted** (11.2; invariant 17 names the framework). |
| B-13 Link rules | **Adopted** (10.7). |
| B-14 The tracker list | **Adopted**: vendored (10.4). |

**The UX review's three that are the engine's**

| | Outcome |
|---|---|
| U-1 | As R-2: one list model here; the host is P1's. |
| U-4 | **Fixed in the design** (7.6, D8); built with send later. |
| U-5 | **Fixed.** `MailText` for native bodies; one web view per open designed message, six at most; picture boxes so nothing jumps (13.2, 10.5). |

**Found by the two verifications of this revision** (`mail-working/review/data-safety-verify.md`,
`security-verify.md`), and corrected in place

| | | Outcome |
|---|---|---|
| S-N1 | M | **Fixed.** `labelsKnown` is set only by a per-message read whose labels were applied — never by a history record, a listing page or an enumeration's close (6.1; 5.5; 5.6; 4.9; appendix A). Stricter than the auditor's wording, which would also have let an enumeration's close set it: a listing can skip a message. Pinned in P06a, P12b, P14a. |
| N-6 | M | **Fixed, and found to be wider than reported.** Measured on a 512 KB stack: depth alone does not overflow this parser, but nested formatting tags and tables cost it quadratic time — 54 s for a 90 KB message. `MailHTMLBound` refuses on the bytes before any parse; the walk is iterative; depth is 200 on both sources; SwiftSoup's serialisers and `Cleaner` are forbidden tokens; four nesting fixtures (10.3; P20a). |
| N-1 | M | The UX document's. The engine's part: `MailLinkRules` and the event and call the reader needs are now in the contract (13.2, 13.3), and D17 carries the sentence Settings must show. |
| S-N2 | m | **Fixed.** The Mac's sleep assertion: `held`, `uploading`, `sending` only, 60 s at most per draft, never for `ready` (7.5). |
| S-N3 | m | **Fixed.** `save` fails visibly when the store cannot save: `MailEvent.draftNotSaved`, retried; `addAttachment` likewise (13.2, 13.3; invariant 9). |
| S-N4 | m | **Fixed.** Kept rows are not verified or counted again (5.3 step 4; 5.7). |
| S-N5 | m | **Fixed.** No view is read until the overlay rebuild has finished (6.4). |
| S-N6 | m | **Fixed.** Every incremental pass reads back what a change's 404 queued (5.5 step 6; 6.5). P12b. |
| S-N7 | m | **Fixed.** Full fsync is per connection: set in `prepareDatabase` and after open, on the one connection, and on the salvage file; read back from a fresh store (4.2; 4.10). P14a. |
| N-2 | m | **Fixed.** The tracker list has a version, an update script and a licence notice, and is consulted again when a picture would be fetched (10.4; 10.6). P20a, P20b. |
| N-3 | m | **Fixed.** Protection classes set on directories before any store opens and on files after their move; the calls and their order are watched by a test (P02), and the classes are read back on a device (P09a's check, D18) — no Simulator reports them (4.1; 11.2). |
| N-4 | m | **Fixed.** A row prepared by an older version is never shown (10.2). P23c. |
| N-5 | m | **Fixed.** Picture boxes bounded; 500 pictures a message (10.4). P20a. |
| N-7 | m | **Fixed.** `PreparedBody.links` and `MailSource.decideLink` (10.5 item 13; 10.7). P20b, P23c, P26. |
| N-8 | m | **Fixed.** One defined `User-Agent`, asserted (10.6). P21a. |
| N-9 | m | **Fixed.** Tokens carry the marker; a static test refuses interpolating one (16). |
| N-10 | m | **Fixed.** No attachment or inline picture is fetched inside a background task (11.1). P25. |
| N-11 | m | **Fixed.** Content-IDs are normalised before matching (10.4). P20a. |

**Contract changes asked for by the UX after it conformed to section 13** (MAIL-UX 12.6)

| | What a screen needed | Now in the contract | Delivered by |
|---|---|---|---|
| A1 | Conversations per split, read or not | `MailPlaceCount { unread, total }` for every split and mailbox in `MailPlaces`; `total.isAtLeast` while it cannot be vouched for (13.2, 13.7) | P23a; custom splits' membership with P08a |
| A2 | A draft's signature and quote in a form a screen can draw; a quote made editable | `MailDraftPart { fragment, body }` on `MailDraft`; `quoteAsText(in:)`; `changeIdentity(of:to:)`; `resource(_:forDraft:presentation:)`; `MailIdentity.hasSignature` replaces its fragment (13.2, 13.3, 7.1) | P23d |
| A3 | The badge to count a send that failed for good | `MailBadgeCounts.needsAnswer` = open questions about a send plus sends in `failed` (13.2, 12.4) | P23d (the mirror itself from P23a) |
| A4 | A way back from "always show pictures" | `alwaysShownPictureDomains()`, `stopAlwaysShowingPictures(from:)`; `MailSettings.disallowPictures(from:)` (13.3, 13.6) | P23c; synced by P27 |
| A5 | The messages behind a held removal, as a list | `MailPlace.heldRemoval(account:)`, read through `observeList` (13.2, 4.4, 5.7) | P13a |
| A6 | Five-second checks for a minute after a check he asked for, and after Mail comes to the front | No contract change. **Yes, with bounds**: twelve polls at most, only while the app is active and Mail is on screen, not in Low Power Mode, never re-armed by a poll (12.1; `PollRules.burst`) | P23a |
| — | Recipient autocomplete in the composer's order | `people(matching:limit:)` and `RecipientRules` move from P23e to **P23d** (18.7) | P23d |
| — | `MailUI/Pure/MailIdentifiers.swift` from the first package | C0a places it, with `MailID.list` and `MailID.row(_:)` (18.3) | C0a |

**The engineering verification of all three documents** (`mail-working/review/engineering-verify.md`):
its T-changes that touch this document or the plan, and the remainders it named

| | Outcome |
|---|---|
| T10 | **Applied**, first form: `Outcome.leaves(MailRow)`; the engine's snapshots never hold a row that has left, and a list that keeps one uses the row carried (13.2). |
| T11 | **Applied.** `MailRefusedChange`, `status.value.refused`; `change_group` in `intent.sqlite` so it survives a relaunch (13.2, 4.8, 6.9). `MailChange` is `Codable` for it. |
| T12 | **Applied.** `searchGmail(_:)` (13.3). |
| T13 | **Applied.** `asking(MailQuestion.ID, MailQuestion.Kind)` in `MailRowReason` and `MailDelivery`. |
| T14 | **Applied.** `MailRowReason.held(until:)`. |
| T15 | **Applied.** `MailPerson.fromTheirMail`. |
| T17 | **Applied.** `waitingChanges` is defined (13.2); gate B's "0 status changes" holds. |
| T18, T19 | **Applied** (9.3; 7.4). |
| T21 | **Applied.** `MailConversationID.gmailURL`. |
| T22 | **Applied** on this side: `sendFailed` notification kind, `MailSettings.notifyFor` (13.6; P25). |
| T23 | **Applied.** `MailTuning.maxEncodedBytes`. |
| T31 | **Ruled:** recent searches are in memory for the session; this document's rule stands and says so (13.8). |
| T34–T36, T40–T46, T48, T49 | **Applied** where each names. |
| T37 | **Applied**, with the definition the dry run asked for: `MailFixtureMailbox`, its device states, its expected orders, its parts (13.6). |
| T38, T39 | **Applied.** The two blocks of 13.2 and 13.3 are the file; no function in them lacks a body; `MailAccountState` is written out there and not in 3.4; the classes have initialisers; 10.7 extends rather than redeclares (13.1). |
| T47 | **Applied.** `MailSendOptions.hold: TimeInterval?`. |
| T50, T55, T56 | **Superseded by a ruling:** no lock and no compile guard. One implementer at a time, one commit a package, a worktree for anything developed alongside (18.2). |
| T51 | **Applied, one part differently.** `reconsiderKeptMail(account:)` and `MailAccount.keptAfterRemoval` for Settings. For the draft upload the proposed form — "when the composer's model is released" — is something the engine cannot see; it is "no `save` for 60 seconds" instead, and still needs no call (7.3, 13.3, D21). |
| T52 | **Applied.** `MailSource+NotYet.swift`, the "Until it is built" table, no stubs in any source (13.1, 13.3; C0a). |
| T53 | **Applied** (3.4; P01a). |
| T54 | **Applied**, with `MailWriterWork` shaped so the intent store stays private: the piece writes intent itself (P02). `MailStoreChange` is P02's and names views by key. |
| T57, T58 | **Applied.** `MailJournalPrivacyTests` is P23d's; the `activate` and `firstPage` bench lines are P23a's. |
| T59 | **Applied** (invariant 32; 13.6). |
| T60 | **Applied, one detail differently:** the mirror is an array of two integers, not JSON, so that nothing is decoded at launch (13.2, 12.4). |
| T61 | **Applied.** `MailBuiltInSplits` in P05. |
| T62 | **Applied.** U5 creates the Mac app delegate; P24 extends it in a file of its own. |
| T63 | **Applied.** C0a, and C0b placed immediately before U0′ (18.3). |
| T64, T65 | **Applied** (P03a, P10a; 5.1, 5.2). |
| T66 | **Applied.** The registry is `M/MailSlices.swift`, not `MailEngine+Slices.swift`: P02 creates it, before `MailEngine` exists (18.2). |
| T67, T68 | **Applied** (P24, P27; P14a). |
| E-10 remainder | **Closed.** The `.onOpenURL` row and the sign-in check (3.3; P01b). |
| E-13 remainder | **Closed.** `GoogleConsentError`; the rejection kind parsed from the minter's summary, never kept; `MailTokenFlight` in the pure folder with tests (3.3; P01a). |
| E-14 remainder | **Closed.** `MailWriterWork`, `MailChangeSink`, `MailSignpost`, `StoredDraft` declared; `MailCache` has a file; `MailReference` and `MailAssist` are said to have none (P02; appendix A). |
| E-15 remainder | **Closed.** Each store is checkpointed by its one writer (4.2; P07, P08b). |
| E-16 remainder | **Closed.** P06b's signatures. |
| E-21 remainder | **Closed.** `MailCache.reset()` (P33); the label janitor (P19a); a detached account (P24); `removeDownloadedMail` (P24 over P33); `MailJournalPrivacyTests` (P23d). |
| E-22 remainder | **Closed.** "The last message that is not a draft" (6.1; 8.2). |
| E-23 remainder | **Closed.** The outgoing row is retired on the sent message id first (7.4). |
| E-24 remainder | **Closed.** A stub read once more before it is believed gone (5.5). |
| E-25, E-26 remainders | **Closed.** Switches for rows 2, 6, 9, 13, 15, 17 and 43; the convergence check is P10a's and the seeded run P15a's (17.2; 19.2). |
| E-27 remainder | **Closed by a ruling.** The Mac quarantine test runs under `swift test` through the root `Package.swift` (P21a); `ScreensOpenUITest` in Release is the owner's, at each gate (D18). |
| E-30 remainder | **Closed** on this side: the budget is a burst, not a held key (6.2; 15). |
| E-31 remainder | **Closed.** The byte share is per device and sized for three (5.2); his own uploads are not fetched back. |
| E-32 remainder | **Closed** on this side: P14a's snooze and mute rows wait for P19a. |
| E-33 remainder | **Closed.** `sendFailed`; the tap is P25's; labels are read hourly (5.5). |
| E-34 remainder | **Closed.** No absolute time is asserted in P02 or P20a; gate E's is a ratio (MAIL-PLAN). |

**What the first package built from this text found (P01a)** — places where the text left its
implementer guessing. Each is now written down where the next package will read it.

| | Where the text was silent or wrong | Now |
|---|---|---|
| I1 | `MailClock` was created by P02, which is built after its first user, P01a. | **P01a creates `M/MailClock.swift`**, the protocol only; P02 creates `SystemMailClock` and `ManualMailClock` in `M/MailClocks.swift` and does not declare the protocol (18.4; 13.6 says who declares each type its block shows). The same check, for every type P01a, P02, P03a and P05 name: `MailStoreChange`, `MailDeviceRole` and `MailPower` are P02's and first used there; `GmailFormat` and `MIMEStructure` are P03a's; `QuotaLane` is P10a's, its first user. **One more was found: `MailViewKey` (4.4) had no creator** — it is now P05's, in `MailEngineTypes.swift`. |
| I2 | The token flight's methods had no names. | 3.3 gives them as built: `init(clock:mint:)`, `Minted`, the `@Sendable` `Mint`, `token(for:)`, `drop(account:)`, `forget(account:)`, `renewalMargin`, and the test-only `waitingCallers(for:)`. And 5.1 now says what the session's token source is — `MailAccessTokens` over `MailAccountAccess` (P23a), **not the flight**, which has two methods of the same names. |
| I3 | A refusal's reason had no route to `mailGrant`; `mailGrant` is synchronous on the main actor and the flight is an actor; "replaced" had no call. | **`MailGrantLedger`** (3.3; `M/`, P01b, tested): it holds the grant state the main actor reads; the minting closure throws `MailCredentialRefused(reason:)` and the ledger records the reason, against the credential that was minted from, before the flight is told `.rejected`; "replaced" is `stored`, which chains `forget`. One token cache, one record of what needs access. |
| I4 | "Within a minute of expiry" had no boundary. | 3.3, rule 2: used while *more than* 60 s remain, minted again at exactly 60. With the minute `GoogleTokenMinter` already subtracts, two minutes in the app — both intended. |
| I5 | The rejection-kind tests had no file; a summary with no colon was undefined; 17.7 built the Mac with `BananaMac`. | They are in `T/MailAccountRulesTests.swift` (P01a). The code is the text before the first colon, or the whole summary when it has none (3.3). 17.7 uses `BananaMacBeta` for every Mac build an agent makes, and says why. |
| I6 | `forget` during a mint in the air was unspecified. | **Confirmed as built** (3.3, rule 4): the mint is not cancelled, its waiters are answered, and what it brings is neither cached nor remembered. The ledger adds the other half (3.3): a caller is never handed a token minted from a credential its account no longer holds. |
| I7 | Found while writing I3: `dropMailAccessToken` and `forgetMailAccess` are synchronous over an actor, so a retry after a 401 could overtake the drop; and P01b's keychain test was placed in `A/`, which is not compiled into the tests. | The ledger chains what the flight is owed and every token request awaits the chain (3.3). P01b's record coding is a pure, tested type; the keychain calls themselves are reviewed and seen in the owner's probe, and the entry says so (18). |

**What P01a's code review left to the design** (`mail-working/review/pkg-P01a.md`: the code
correct in every interleaving it walked; three things neither the code nor 3.3 decided).

| | The question | Ruled |
|---|---|---|
| I8 | Nothing could stop a mint and no waiter could leave; the only time limit was the closure's and unstated; a token request could outlive `suspend()`. | 3.3, rules 1, 6, 7. **The closure owns the limit: 20 seconds**, the token session's own timeouts (P01b). **A cancelled caller stays** until the mint answers and the flight hands it what the mint brought; the ledger, the only way to the flight, tells it it was cancelled and gives it no token. **`suspend()` cancels every mint in the air** through `cancelMailTokenRequests()` → `cancelMint(account:)`, and awaits nothing, so invariant 15 has no exception. Source: two small additions in P01a's follow-up. Tests named in P01a, P01b, P23a (`MailSuspendTests`), P10a; P25 must not wait for a pass in an expiration handler. |
| I9 | A late `drop` can discard a newer token. | **Accepted** (3.3, rule 8): at most one extra mint and one profile call for each request that was in the air with the dead token — four per account per event — never a wrong answer, and rare. Pinned by `testALateDropDiscardsANewerTokenAtTheCostOfOneMint`. |
| I10 | An old mint that *throws* to a caller whose credential has since been replaced. | 3.3, the ledger's step 4: the flight's answer, **a token or an error alike**, is believed only if the credential still has the stamp the request began with. Replaced: the answer is dropped and the request starts again, so the caller is given the new credential's answer. Deleted: `.notGranted`. P01b's tests, by name. |

**What the second package built from this text found (P02)** — gaps in section 4, and two
errors elsewhere. "Code" says whether P02's code, uncommitted when this was ruled, had to
change.

| | The question, or the fact | Ruled | Code |
|---|---|---|---|
| K1 | When a log is due a checkpoint: a `PASSIVE` checkpoint never shortens the file, so "over 8 MB" by length would be true for ever. And nobody checkpointed `intent.sqlite`: the writer cannot reach it. | 4.2. The measure meant is what the log *holds*; the file's length says that once every writer sets `journal_size_limit` to the same 8 MiB. P02's `standing` is kept, clamped to the file's present length — without that it could only rise. `MailIntentStore` checkpoints its own log (P14a) through `MailWriterLog`, kept by the writer, so it runs on the writer's queue after a piece. | **Yes**: the pragma, the clamp, `MailWriterLog` and `keep`. |
| K2 | Pace precedence: 4.12 listed the overnight task first, 12.1 the warm row first. | **Confirmed as built**: warm or Low Power Mode is `stopped` everywhere, the overnight task included (invariant 31). Both tables now say "the first row that applies"; the task completes instead of sleeping (12.2; P25). | No (one comment). |
| K3 | `MailDiskRules`: no return type; the resume rule needs a memory a pure function cannot hold; `free == floor`; "GB". | 11.3. `MailDiskState` is `ok` / `belowFloor`; `state(free:floor:was:)` has two thresholds and is told its last answer; that answer lives in `MailDiskWatch` (P02), one per engine (P23a); eviction that brings it back is P33's. `free == floor` is ok; sizes are binary. | **Yes**: the third argument and `MailDiskWatch`. |
| K4 | Protection classes: 4.1 said read them back on the Simulator; the entry said watch the calls. | The unit test is the calls and their order, as built. The classes are read back on a device by `--verify-mail-bench protection` (P09a), in the owner's first run (D18). | No. |
| K5 | Decisions the implementer made and flagged. | **All confirmed**, and the text now says each: the sink is told once `write` has returned, on the writer's queue (4.2, 13.7); quarantine on the temporary file, before the move (11.2); the journal id's bars are literal (16); the attached names are `idx` and `blobs` (4.2, 9.2); `submit(task:)`, `openIntentQueue(at:)` — which only `MailIntentStore` may call, P14a's scan — and `directories`; the fifty-change cap is the piece's (4.12; P14b). | No. |
| K6 | `fullfsync` set in `prepareDatabase` survives GRDB (the text said it read 0); changing `synchronous` inside a transaction throws; GRDB's pool readers have a ten-second busy timeout of their own. | Section 4's preamble, 4.2 and the measurement table of 21 corrected; the settings as read back are recorded in 4.2. | No. |
| K7 | Pool readers keep `wal_autocheckpoint = 1000`: can a reader checkpoint inside an action (invariant 12)? | **No.** An automatic checkpoint is run by the connection that has just committed to the log; a read-only connection commits nothing (4.2, DOCUMENTED). | No. |
| K8 | 12.1 had `activate()` open the stores from a detached task — the cooperative pool, which 4.2 forbids for blocking GRDB calls. | 12.1, 4.2: a serial queue of the engine's own, `mail.start`. P23a, with a test of which queue the opening ran on. | No. |
| K9 | 9.2 cited `content.text`, which 4.7 does not have. | 9.2: `blobs.prepared.text`, and Gmail's `snippet` for a message not yet prepared. | No. |

**What the third package built from this text found (P03a)** — "Code" says whether P03a's
code, uncommitted when this was ruled, had to change.

| | The question, or the fact | Ruled | Code |
|---|---|---|---|
| L1 | `Authentication-Results`: the text read `header.d`; Gmail is believed to write `header.i=@domain`. Unverified. | 10.6. The authenticated domain is the one Gmail vouched for *and* that speaks for the From line: `dmarc=pass` with `header.from` equal to it; else `dkim=pass` by `header.d` or, lacking it, the domain of `header.i`; else `spf=pass` — the last two only for the From domain or a parent. Probe item 11 records what Gmail writes; the fake writes the believed form, with a switch (17.2, row 47). | **Yes.** |
| L2 | `MIMEStructure` had no stated shape, and P03b cannot add a stored field. | Appendix A: the whole shape — the tree, the attachments, `htmlPartID`, `plainPartID`, `invite`, `cut`. No decoded text. P03b returns the bodies beside it in a type of its own, and owns `MailInviteRules`. | **Yes.** |
| L3 | U+200D was on the list to remove though "emoji stay"; U+200C was taken out of Persian names. | 10.8. Removed: everything `Default_Ignorable_Code_Point` (the standard library's property). Kept: a variation selector after a visible character; U+200D inside an emoji sequence and a flag's tag sequence; U+200C and U+200D where IDNA's own rule allows them (RFC 5892, A.1, A.2). Direction controls never. Addresses are not cleaned: one holding any of these is unreadable. | **Yes.** |
| L4 | "More than one script" flagged a Japanese name; there was a hand table. | 10.8. Per word; only Latin, Cyrillic and Greek mixed. Scripts come from `NSRegularExpression`'s `\p{Script=…}`, a public API over the system's Unicode data; the full standard check (ICU's `uspoof`) is private on Apple's platforms. | **Yes.** |
| L5 | 17.5 said "the first ten", the entry "the header and sender ones"; seven were written. | 17.5 and the entry name the seven. P03b writes the four shape fixtures. | No. |
| L6 | An unknown charset in an encoded word was left as written. | **Overruled**, for one rule with bodies (5.6): UTF-8 if the bytes are valid UTF-8, else Windows-1252. | **Yes.** |
| L7 | Cut headers: a `From` past line 1,000 was unknown. | 5.6. A limit bounds what is kept, not what is known: the headers read by name, less `Authentication-Results`, are looked for past the cut. A sender that still cannot be read is one state, the UX's "unreadable sender": `from_addr` NULL; a person with an empty address (10.8). | **Yes.** |
| L8 | A MIME tree about 120 parts deep cannot be decoded at all (the JSON reader's limit). | 5.6. A `full` read that answers `malformed` is followed once by a `header` read; if that decodes the message is stored at `fetch_state = 2`, `body_kind = tooLarge`, and never read in `full` again. Otherwise nothing is concluded, and the id rests for the life of the process. `fetch_state = 2` is defined as "nothing more to fetch". P12c stores it; P22a does not retry and calls only a JSON 2xx `malformed`; the fake's row 48. | No. |
| L9 | The `{labels:[…]}` and `{sendAs:[…]}` envelopes belonged to no package. | P03a's: `GmailLabelList`, `GmailSendAsList` (appendix A). | **Yes.** |
| L10 | `M/Testing/` compiles into the app. | Intended, and fenced: every file wholly inside `#if DEBUG || MAIL_FIXTURES`; the production targets' Release defines neither. A test reads the folder for the fence (17.5). | **Yes** (one test). |

**What P03a's code review left to the design** (`mail-working/review/pkg-P03a.md`: no
blocker; every ruling above agreed with; four things about who a message is shown to be from
that the rulings did not cover).

| | The question | Ruled |
|---|---|---|
| L11 | Without angle brackets, a quoted display name was tried as an address. | 10.8: what is in quotes is a name, always. A quoted string alone is no mailbox. |
| L12 | Nothing said who the sender is when `From` is not exactly one mailbox, and the next package would have taken the first. | 10.8, by the coordinator's ruling, which stands without exception: **exactly one mailbox, or the unreadable sender.** One reading, `MessageHeaders.sender`; and it also answers nothing when Gmail's own `dmarc=` result names another domain than the one read. Rows and the conversation's header show one sender, said to be unreadable. |
| L13 | An address could hold a full-width `＠` and characters nobody can see. | 10.8: what an address may contain. The local part is unchanged by NFKC, holds no default-ignorable character, begins with no combining mark, and mixes no two of Latin, Cyrillic and Greek in a word. Anything else is unreadable, never cleaned. |
| L14 | "Topmost" was not enforced for `Authentication-Results`: the reader looked past other servers' headers. | 10.6: the first header of that name, and only if its authserv-id is `mx.google.com`; unfolded; a second ignored; a cut one not read. What an import can forge is said. |
| L15 | Folded in from the same review. | `MIMEStructure.Attachment.size` is optional and `name` is the safe name (appendix A). A `GmailPart` deeper than 64 stops the decode, by mail's own count (5.6). A missing `labelIds` is "no labels" in a per-message read and unknown elsewhere (5.6). A name is judged once, at store (10.8). Probe items 11–13 and write probe W7 (19.2, 19.3). |

**The owner's first review of the direction.** His words are quoted exactly.

| | His ruling | What changed |
|---|---|---|
| M1 | "We should allow a sync limit, so lets say 6 months by default. Also we should merge local search with cloud search if duration is not unlimited." | **5.4, rewritten**: `MailSyncLimit`, per device, six months; the rule — a conversation is held when something about it is this side of the edge or he has a claim on it, and held whole; **not held** as a third state that is stored nowhere (invariant 34); dated listings, the claims listed without a date, history that skips what is not held, release as the edge moves, raising and lowering. **5.2**: 500 MB a day on every device. **5.4's table**: six months is about an hour and a half of quota and 500 MB, on ASSUMED volumes. **9.4, rewritten**: one search over the device and Gmail — two groups by who found it, Gmail's rows in memory and held when opened, 400 ms settle, cancelled as he types; `askGmail` also reaches a place's older mail. 11.3: the ceilings are a backstop. Contract: 13.10. Packages: C0c, P05, P06a, P12a, P12b, P13a, P13b, P14a, P23e, P33. |
| M2 | Send later and "remind me if no reply" are in the first release: "I want these...." | **Order 7** (18.10): P19a, P19b, P18b, written out as packages, each with its probe and what is built without it. The safety rules stand: one owner for a scheduled send until W4; late is shown everywhere (invariant 8, D8). `MailSendOptions.at` (13.10). |
| M3 | Remote pictures: "Default to ask, but allow to set always for this sender, always for this domain, and always period." | **10.6**: four levels; `MailPicturePolicy`; sender and domain keyed on what Gmail authenticated, and offered only when it did; two synced lists and two synced settings; every level undone from Settings and from the message; **trackers blocked at every level behind their own switch, on** — marked at preparation, no longer removed (10.4). Two rules added that he did not state and that narrow "always": nothing in Spam loads without his tap, and a pane that follows the cursor fetches nothing until he has stopped on a message. Contract: 13.10. Packages: P20b, P23c, P27, P24. |
| M4 | A reading pane, and three or four columns on a wide window. | **13.10**: the contract serves a pane that follows the cursor (a rest is one index read and one or two blob reads, no request, no write), a details column (from the conversation already observed) and an always-visible control column — with one addition, `MailPlaces.labelCounts`. |
| M5 | "For now we can focus on Mac but we should be building to support Mobile from the get go." | No engine change. Checked: nothing in the order waits for the Mac before meeting a phone's constraint — the suspend test (invariant 15, P23a) and the pace (P02) are both order 1, the protection classes are checked on his phone before order 3 (D18, run 1), memory with six web views at gate C (run 2), every gate builds and runs the iPhone and iPad routes, and the sync limit's default is the same on every device. The background tasks themselves (P25) are order 6, and nothing before them assumes they exist. |
| M6 | GRDB and SwiftSoup approved ("Sounds good"), and the whole-app performance commits. | D19 answered. |

## Appendix A. The engine's shared types

`M/MailEngineTypes.swift` (P05). These are named by more than one engine package and by no
screen. Types private to one package are its implementer's to shape.

```swift
struct MessageFacts: Equatable, Sendable {      // one message as the rules see it
    var gmailID: String
    var rowID: Int64 = 0              // local msg_pk; supplies undated stub ordering
    var internalDate: Int64            // ms; 0 for a stub
    var fetchState: Int                // 0 stub, 1 header, 2 full
    var vis: Int                       // 4.3
    var labels: Set<String>            // Gmail label ids, effective: Gmail's with the overlay applied
    var labelsKnown: Bool              // a per-message read has described the whole set (6.1); nothing else sets it
    var bananaLabels: [String]         // names of the labels of kind 2 on it
    var fromName: String?, fromAddress: String
    var isFromMe: Bool
    var toAddresses: [String], ccAddresses: [String]
    var subject: String, snippet: String
    var hasAttachment: Bool, hasInvite: Bool
    var listID: String?
    var hasUndeliveredIntent: Bool, hasRefusedIntent: Bool
}
struct SummaryPerson: Equatable, Codable, Sendable {
    var n: String?; var a: String; var u: Bool
    /// Explicit own-address identity; never inferred from a name that says "me".
    var isMe: Bool = false
}
struct ThreadSummary: Equatable, Sendable {
    var lastDate: Int64, messageCount: Int, fetchedCount: Int, unreadCount: Int
    var flags: MailThreadFlags
    var subject: String, snippet: String
    var people: [SummaryPerson], peopleTotal: Int
    var labels: Set<String>
    var wakeAt: Int64?, returnedAt: Int64?, waitingUntil: Int64?
    var pending: Int                   // 0, 1, 2
    var recipients: [SummaryPerson] = []
    var recipientsTotal: Int = 0
    var attendedAt: Int64? = nil
    /// Message-derived claims. The writer also merges durable local draft/send/question claims.
    var claims: MailClaims = []
}
struct MailThreadFlags: OptionSet, Sendable {   // thread.flags
    let rawValue: Int
    static let starred = Self(rawValue: 1), important = Self(rawValue: 2), hasAttachment = Self(rawValue: 4)
    static let hasInvite = Self(rawValue: 8), hasDraft = Self(rawValue: 16), lastIsMine = Self(rawValue: 32)
    static let isList = Self(rawValue: 64), muted = Self(rawValue: 128), keptAfterRemoval = Self(rawValue: 256)
    static let inInbox = Self(rawValue: 512)
}
struct MailMessageFlags: OptionSet, Sendable {  // message.flags
    let rawValue: Int
    static let fromMe = Self(rawValue: 1), hasAttachment = Self(rawValue: 2), hasInvite = Self(rawValue: 4)
    static let labelsKnown = Self(rawValue: 8)
}
enum SystemLabel: String, Codable, CaseIterable, Sendable {
    case inbox = "INBOX", unread = "UNREAD", starred = "STARRED", important = "IMPORTANT", sent = "SENT"
    case draft = "DRAFT", trash = "TRASH", spam = "SPAM"
    case personal = "CATEGORY_PERSONAL", social = "CATEGORY_SOCIAL", promotions = "CATEGORY_PROMOTIONS"
    case updates = "CATEGORY_UPDATES", forums = "CATEGORY_FORUMS"
}
struct ViewMembership: Equatable, Sendable { var view: MailViewKey; var sortKey: Int64; var unread: Bool }

// The outbox
enum AssertionOrigin: Int, Codable, Sendable { case person = 0, rule = 1 }
enum AssertionState: Int, Codable, Sendable { case pending = 0, inFlight = 1, settling = 2, refused = 3 }
struct Assertion: Equatable, Sendable {
    var account: String, messageID: String
    var labelRef: String               // a Gmail label id, or "name:<label name>"
    var want: Bool
    var origin: AssertionOrigin
}
struct StoredAssertion: Equatable, Sendable {
    var assertion: Assertion
    var seq: Int64, sentSeq: Int64?, groupSeq: Int64
    var state: AssertionState
    var attempts: Int, nextAttemptAt: Int64?
    var failure: MailFailure?
    var createdAt: Int64
}
struct SentKey: Hashable, Sendable { var account: String, messageID: String, labelRef: String; var sentSeq: Int64 }
struct LabelBatch: Equatable, Sendable {
    enum Call: Equatable, Sendable { case modifyEach, batchModify, trashEach, untrashEach }
    var account: String
    var messageIDs: [String]
    var add: [String], remove: [String]          // Gmail label ids
    var call: Call
    var keys: [SentKey]
}
struct EchoedIntent: Equatable, Sendable { var account: String, messageID: String, labelID: String; var want: Bool; var recordID: UInt64 }

// Sync
struct ListedID: Equatable, Sendable { var id: String, threadID: String }
struct NewStub: Equatable, Sendable { var gmailID: String, threadID: String; var fetchClass: Int, listRank: Int; var historyID: UInt64 }
struct LabelChange: Equatable, Sendable { var messageID: String; var add: Set<String>, remove: Set<String>; var recordID: UInt64 }
struct StoredMessageState: Equatable, Sendable {
    var msgPK: Int64
    var fetchState: Int, vis: Int
    var labels: Set<String>, labelsKnown: Bool   // Gmail's, without the overlay
    var historyID: UInt64?
}
struct Membership: Hashable, Sendable { var labelID: String?; var messageID: String }      // nil: the unlabelled listing
struct StoredMembership: Equatable, Sendable { var msgPK: Int64; var messageID: String, labelID: String; var historyID: UInt64? }
struct PagePlan: Equatable, Sendable {
    var stubs: [NewStub]
    var addLabel: [String]             // message ids that gain this listing's label now
    var verify: [String]               // message ids something newer has spoken for
    var marks: [Membership]
}
struct QueuedMessage: Equatable, Sendable { var gmailID: String, threadID: String; var fetchClass: Int; var internalDate: Int64 }
enum FetchCall: Equatable, Sendable {
    case message(id: String, format: GmailFormat)
    case thread(id: String, format: GmailFormat, wanted: [String])
}
struct FetchedMessage: Sendable {
    var wire: GmailMessage
    var floor: UInt64                  // 5.6
    var headers: MessageHeaders
    var structure: MIMEStructure?      // nil below `full`
}
enum AccountSyncChange: Sendable {
    case checkpoint(String?), profileTotal(Int), enumeration(generation: Int, checkpoint: String?, state: String?)
    case enumerationCompleted(at: Int64), through(headers: Int64?, bodies: Int64?)
    case quota(String), result(MailSyncHealth, at: Int64), sendAs(String, at: Int64), labelsAt(Int64), removals(String)
}

// Reads and change notices
struct PageRequest: Sendable { var view: MailViewKey; var account: String?; var filters: Set<MailFilter>; var before: MailOrderKey?; var limit: Int }
struct IndexRow: Sendable {            // the page query's columns, decoded by index
    var threadPK: Int64; var account: String, thread: String
    var sortKey: Int64, tie: Int64; var unread: Bool
    var messageCount: Int; var flags: MailThreadFlags
    var subject: String, snippet: String; var people: [SummaryPerson], peopleTotal: Int
    var labelPKs: [Int64]; var wakeAt: Int64?, returnedAt: Int64?, waitingUntil: Int64?; var pending: Int
    /// Display date is independent of a view's sort key (especially Snoozed).
    var lastDate: Int64
    var recipients: [SummaryPerson]
    var recipientsTotal: Int
}
struct ViewCounts: Equatable, Sendable { var unread: Int; var total: MailCount; var stillLoading: Int }
struct StoredLabel: Equatable, Sendable { var labelPK: Int64; var account: String, gmailID: String, name: String; var kind: Int; var colorHex: String? }
// MailStoreChange — what one index transaction touched — is declared in M/MailWriter.swift (P02; 18.4).

/// A draft as MIMEBuilder and the send driver see it: the row of 4.8, decoded.
struct StoredDraft: Equatable, Sendable {
    var localID: String, account: String, fromAlias: String?
    var kind: String                   // new, reply, replyAll, forward
    var to: [MailPerson], cc: [MailPerson], bcc: [MailPerson]
    var subject: String
    var body: MailText
    var signature: MailFragment?, quote: MailFragment?
    var format: MailDraft.Format
    var rfcMessageID: String, mimeDate: Date
    var sourceMessageID: String?, threadID: String?, inReplyTo: String?, references: String?
    var contentRev: Int
    var attachments: [StoredDraftAttachment]
}
struct StoredDraftAttachment: Equatable, Sendable {
    var id: String, filename: String, mime: String; var size: Int
    var contentID: String?; var source: String?      // nil: a file in Intent/Attachments; else "forward:<msg>:<part>"
}
/// One change of his, as intent.sqlite keeps it while any of its assertions is undelivered (4.8).
struct StoredChangeGroup: Equatable, Sendable {
    var groupSeq: Int64; var account: String; var change: MailChange; var conversations: Int; var createdAt: Int64
}
```

Not declared by any package of the first release, and so in no file: `MailReference` and
`MailAssist` (13.9 says what they would be).

**Gmail's wire models** (`M/GmailWire.swift`, P03a) — `Codable`, every property optional, the
JSON names Gmail's own:

| Type | Properties |
|---|---|
| `GmailProfile` | `emailAddress`, `messagesTotal`, `threadsTotal`, `historyId` |
| `GmailLabel` | `id`, `name`, `type`, `messageListVisibility`, `labelListVisibility`, `messagesTotal`, `messagesUnread`, `threadsTotal`, `threadsUnread`, `color { textColor, backgroundColor }` |
| `GmailMessage` | `id`, `threadId`, `labelIds`, `snippet`, `historyId`, `internalDate`, `sizeEstimate`, `payload: GmailPart` |
| `GmailPart` | `partId`, `mimeType`, `filename`, `headers: [{name, value}]`, `body { attachmentId, size, data }`, `parts: [GmailPart]` |
| `GmailThread` | `id`, `historyId`, `messages` |
| `GmailIDPage` | `messages: [{id, threadId}]`, `nextPageToken`, `resultSizeEstimate` |
| `GmailHistoryPage` | `history: [GmailHistoryRecord]`, `nextPageToken`, `historyId` |
| `GmailHistoryRecord` | `id`, `messagesAdded`, `messagesDeleted`, `labelsAdded`, `labelsRemoved` — each `[{message: {id, threadId, labelIds}, labelIds}]` |
| `GmailDraft` | `id`, `message: GmailMessage` |
| `GmailDraftPage` | `drafts: [{id, message: {id, threadId}}]`, `nextPageToken` |
| `GmailSendAs` | `sendAsEmail`, `displayName`, `replyToAddress`, `signature`, `isPrimary`, `isDefault`, `verificationStatus` |
| `GmailLabelList` | `labels: [GmailLabel]` — the envelope of `labels.list` |
| `GmailSendAsList` | `sendAs: [GmailSendAs]` — the envelope of `settings.sendAs.list` |

The two envelopes are P03a's with the rest: the fixture mailbox carries those two responses
as Gmail's JSON (13.6), the fake decodes them (P10a) and so does the HTTP layer (P22a), and
none of the three should declare them.

`historyId` and `internalDate` arrive as decimal strings; both are parsed to `UInt64` and
`Int64` by the model, and a value that does not parse is `nil`, not zero.

**`MIMEStructure`** (`M/GmailWire.swift`, P03a) — a message's MIME tree without its data: the
JSON of `content.structure` (4.7). **Its whole shape is declared once, here**, because the
packages that fill and read it (P03b, P07, P16, P20, P21, P23c) can add functions to it by
extension and cannot add a stored field:

```swift
struct MIMEStructure: Codable, Equatable, Sendable {
    /// One part, as Gmail described it.
    struct Part: Codable, Equatable, Sendable {
        var partID: String          // Gmail's partId: immutable, and the key an attachment is stored under
        var mimeType: String        // as declared, lower case, parameters removed
        var filename: String?       // as the sender wrote it
        var size: Int?              // decoded bytes, as Gmail gave it
        var attachmentID: String?   // Gmail's; not stable across reads (probe item 9) — never a key
        var contentID: String?      // without its angle brackets: the target of a cid: picture
        var isInline: Bool          // Content-Disposition: inline
        var children: [Part]
    }
    /// A part that is a file: what a chip shows, and what is fetched when it is opened.
    struct Attachment: Codable, Equatable, Sendable {
        var partID: String
        var name: String            // MailFileName.safe of what was written: cleaned when stored, at most 255 bytes
        var mimeType: String        // as declared; what the bytes are is found when they are fetched
        var size: Int?              // nil: Gmail gave none — not a file of no bytes
        var attachmentID: String?
        var contentID: String?
        var isInline: Bool
        var isInvite: Bool          // a text/calendar part
    }
    /// The invitation a message carries, read when the message is (10.10): never the event.
    struct Invite: Codable, Equatable, Sendable {
        var partID: String          // the text/calendar part, a file or an alternative of the body
        var method: String?         // METHOD, upper case: REQUEST, CANCEL, REPLY, …; nil if not found
        var uid: String?            // UID; nil if not found within the bound
    }
    /// Why the walk stopped short of the whole tree.
    enum Cut: String, Codable, Sendable { case depth, parts }

    var root: Part
    var attachments: [Attachment]
    var htmlPartID: String?         // the part chosen as the HTML body; its text is content.html
    var plainPartID: String?        // the part chosen as the plain body; its text is content.plain
    var invite: Invite?
    var cut: Cut?                   // nil: the tree is whole
}
```

`Attachment.name` is the safe name (10.8: names are cleaned when stored, so that no screen
has to remember to); `Part.filename` is what the sender wrote, cut at 1 KB, as `mimeType` is
at 127 bytes and `contentID` at 255 — they are his, and as long as he likes.
No decoded text is in it: the two bodies have columns of their own (4.7), and a copy here
would store every body twice. The four fields after `attachments` are optional, so a value
that lacks them decodes. `MIMEStructure.extract` (P03b) returns the structure beside the two
decoded bodies, in a type of its own.
