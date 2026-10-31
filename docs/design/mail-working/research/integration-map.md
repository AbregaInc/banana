# Banana → Mail: integration map

Read-only survey of `~/orca/workspaces/gtfuwgth/stingray` at `1155270` (branch
`google-email-functionality`, 5 Oct 2026). Paths are relative to that root. `file:line` was read
in this pass unless tagged **INFERRED**. Nothing about mail exists in the code or docs yet (grep for
gmail/mail/inbox/superhuman finds only calendar account emails and the meal "inbox").

Toolchain facts: Xcode 27.0, `SWIFT_VERSION 5.0`, `SWIFT_STRICT_CONCURRENCY: minimal`
(project.yml:57-58), iOS 26.1 / macOS 26.0 deployment (project.yml:5-7), build 51
(project.yml:64). `Banana.xcodeproj` is generated and git-ignored (.gitignore:15): run
`xcodegen generate` after any `project.yml` change. Packages: FluidAudio 0.15.5, GoogleSignIn 9.1.0
(project.yml:70-76). Targets: `Banana` (iOS+iPadOS), `BananaBeta`, `BananaMac`, `BananaMacBeta`,
`BananaWatch`, `BananaWatchWidget`, `BananaWidgetExtension`, `BananaTests`, `BananaUITests`.
App targets glob `Banana/` + `Shared/`; the Mac targets compile the same `Banana/` folder with
`MAC_APP` (project.yml:868, 944); betas add `BANANA_BETA` (project.yml:321, 944).

---

## 1. Google auth as it exists

### Facts

**Credential + store** — `Banana/Model/GoogleAccountStore.swift`
- `struct GoogleAccountCredential: Codable, Equatable, Identifiable, Sendable { var email: String; var refreshToken: String; var grantedScopes: [String]; var id: String { email.lowercased() } }` (:9-15). All three fields are non-optional with synthesized `Codable`.
- `enum GoogleAccountStore` (:28): ONE keychain generic-password item (service `com.boris.banana.google-accounts`, account `credentials`, :29-30) holding the JSON array of every account. Read synced-first then device-local (:32-35); `save` tries `kSecAttrSynchronizable = true`, falls back to local (:50-56); `kSecAttrAccessibleAfterFirstUnlock` (:69). `upsert` (keyed by lowercased email, sorted, :75-82), `remove(email:)` (:85-90), `removeAll()` (:92-95).
- No file, no UserDefaults, no CloudKit holds tokens.

**Keychain groups**
- iOS prod: `keychain-access-groups` = `$(AppIdentifierPrefix)com.boris.banana` FIRST (default group for unnamed writes), then `…widget.agenda` (Banana/Banana.entitlements; project.yml:174-180).
- Mac prod: `$(AppIdentifierPrefix)$(CFBundleIdentifier)` (BananaMac/BananaMac.entitlements, BananaMacDebug.entitlements); bundle id is `com.boris.banana` (project.yml:856) → same group as iOS → the synced item is shared phone↔Mac.
- iOS Beta: no keychain group listed (Banana/BananaBeta.entitlements; project.yml:301-312). Mac Beta: `…com.boris.banana.mac.beta` (project.yml:936). **INFERRED**: the two betas therefore do not share the credential item; and they could not use each other's refresh token anyway (different OAuth clients, below).

**OAuth clients (`GIDClientID`) per target**
| Target | GIDClientID | project.yml |
|---|---|---|
| Banana (iOS prod) | `<google-client-id>` | :91 (URL scheme :95) |
| BananaMac (prod) | same as iOS prod | :819 (:823) |
| BananaBeta (iOS) | `<google-client-id>` | :239 (:243) |
| BananaMacBeta | `<google-client-id>` | :900 (:904) |
Read at runtime from `Bundle.main` (GoogleCalendarService.swift:313-316). **INFERRED**: two Google Cloud projects (numeric prefixes differ between prod and beta).

**Token minting** — `Banana/Model/GoogleTokenMinter.swift` (pure Foundation; in the test target, project.yml:606)
- `static func mint(refreshToken: String, clientID: String) async throws -> MintedToken` (:44); `MintedToken { accessToken; expiresAt }` (:16-19), expiry shortened 60 s (:77-80).
- `enum MintError { case credentialRejected(reason: String?); case transport(String) }` (:21-42).
- `static func isCredentialRejection(status: Int, error: String?) -> Bool` — only `invalid_grant` / `unauthorized_client` / `invalid_client`, or a body-less 401 (:89-100).
- The refresh response decodes only `access_token`, `expires_in` (:115-118): Google's `scope` field is ignored.
- No client secret (installed-app clients, :11-12). Uses `URLSession.shared` (:58).

**Service** — `Banana/Model/GoogleCalendarService.swift` (2,281 lines, `@MainActor final class … ObservableObject`, `static let shared`, :144-146; `import GoogleSignIn` :4 → cannot enter BananaTests)
- Scopes: `eventsScope = …/auth/calendar.events`, `calendarListScope = …/auth/calendar.calendarlist.readonly`, `private static let requiredScopes = [eventsScope, calendarListScope]` (:148-150).
- Published account state: `accounts` (:160), `accountsNeedingReconnect: Set<String>` (:166), `accountsWithUnreadableCalendars` (:180), `reconnectReasons: [String: String]` (:183), `suggestedAccountEmail` (:250), `isWorking`, `lastError` (:252-253). Derived: `hasDegradedSources` (:173-175), `isConfigured` (:264), `isConnected { !accounts.isEmpty }` (:266), `accountEmail` (:247).
- `private var tokenCache: [String: GoogleTokenMinter.MintedToken]` keyed by account id (:258). One token per account, whatever the scope.
- `init` (:318-331): sets `GIDSignIn.sharedInstance.configuration`, loads `accounts` synchronously from the keychain (first frame needs it), observes the hint, kicks `restoreIfNeeded()`.
- `restoreIfNeeded()` (:333-346) → `performRestore()` (:1636-1664): reload from store; ONLY if the store is empty and `GIDSignIn.hasPreviousSignIn()` does it call `restorePreviousSignIn` (legacy single-account migration); then `loadCalendars()`.
- `connect()` (:348-369): `interactiveSignIn(hint: accounts.isEmpty ? suggestedAccountEmail : nil)` → `accept` → `loadCalendars`.
- `reconnect(email:)` (:381-406): `interactiveSignIn(hint: email)`, refuses if Google returned a different address (:391-396), `accept`, clears needs-reconnect / reason / cached token, `loadCalendars`.
- `disconnect()` all (:408-437): `GIDSignIn.disconnect` (revokes the SDK's current user's grant), `GoogleAccountStore.removeAll()`, clears every cache + hint. `disconnect(email:)` (:1872-1878): removes from the store only — no revoke.
- `adoptAccountsFromStore() -> Bool` (:449-457): adopts accounts whose **id is new**; never mirrors a removal, never replaces a known id's credential. Called on foreground: RootView.swift:33-39 + :283 (iOS), MacRootView.swift:435 + :444-450 (Mac), and in `refresh()` (:459-471).
- `accept(_ user: GIDGoogleUser) throws` (:1671-1683): throws `.permissionMissing` unless EVERY `requiredScopes` entry is in `user.grantedScopes` (:1672-1673); upserts `GoogleAccountCredential(email:, refreshToken: user.refreshToken.tokenString, grantedScopes: user.grantedScopes ?? [])`; publishes the hint.
- `interactiveSignIn(hint:) async throws -> GIDSignInResult` (:1692-1724): iOS `GIDSignIn.sharedInstance.signIn(withPresenting: UIViewController, hint:, additionalScopes: Self.requiredScopes)` (:1698-1702), presenter found by walking the foreground-active key window (:1769-1780); macOS same call with `NSApp.keyWindow ?? mainWindow ?? windows.first` (:1709-1717). No presenter → `.noPresentationContext`.
- Cross-device hint: KVS key `googleCalendar.accountHint.v1` (:151), observe/apply/publish/clear (:1730-1762). Email only.
- Transport: `token(for:account:)` (:1998-2007; explicit account → else calendar id from the URL → else the only account), `request<Response: Decodable>(url:method:body:account:ifMatch:)` (:2009-2019), `requestVoid` (:2021-2024), `send(url:method:body:account:ifMatch:) async throws -> Data` (:2029-2058): `URLSession.shared`, `.reloadIgnoringLocalCacheData`, Bearer header, **one retry on 401** after `dropCachedToken` (:2044-2047, :2060-2069), 412 → `.changedElsewhere`, non-2xx → `.api(status:message:)`, and any non-GET sets `coreFetchedAt = nil` (:2055). The paged readers build their own requests off-main (`fetchAllPages`, :879-908) and on a 401 only drop the cached token for next time (:801-806, :972-974).
- `accessToken(for account:)` (:2079-2112): cache hit → else `GoogleTokenMinter.mint`; on `credentialRejected` it inserts into `accountsNeedingReconnect`, stores the reason, clears the token, sets `lastError`, throws `.notConnected`. A successful mint removes the account from `accountsNeedingReconnect` (:2097).
- `private enum GoogleCalendarError` (:2196-2236): `notConnected, permissionMissing, noPresentationContext, malformedResponse, eventUnavailable, notEditable, changedElsewhere, notYours, api(status:message:)`. Private to the file.
- URL callback: `static func handleOpenURL(_:)` → `GIDSignIn.sharedInstance.handle(url)` (:2125-2128), wired once at `BananaApp.swift:615` (`.onOpenURL`).

**Routing** — `Banana/Model/GoogleRequestRouting.swift:15-20`: `static func calendarID(fromRequestURL:) -> String?` (path component after `calendars`). Calendar-specific; a Gmail URL (`/gmail/v1/users/me/…`) yields nil and would fall to "the only account" or throw `.notConnected` with several accounts (GoogleCalendarService.swift:2003-2006).

**SDK facts** (GoogleSignIn-iOS 9.1.0 checkout under `~/Library/Developer/Xcode/DerivedData/Banana-*/SourcePackages/checkouts/GoogleSignIn-iOS`)
- `-[GIDGoogleUser addScopes:presentingViewController:completion:]` (iOS, GIDGoogleUser.h:88) and `addScopes:presentingWindow:completion:` (macOS, :106) both exist.
- `addScopes` fails with `kGIDSignInErrorCodeMismatchWithCurrentUser` unless the receiver IS `GIDSignIn.sharedInstance.currentUser` (GIDGoogleUser.m:203-213), and with `…ScopesAlreadyGranted` if nothing is new (GIDSignIn.m:383-394).
- Every auth request carries `include_granted_scopes=true` (GIDSignIn.m:895).
- A plain `signIn` replaces `currentUser` (GIDSignIn.m:1103-1111); the SDK holds one user.

### Answers

**(a) Requesting a Gmail scope**
- *New account*: add the Gmail scope(s) to what `interactiveSignIn` passes as `additionalScopes` (:1701, :1716). `accept` must stop treating every requested scope as required (:1672-1673) — Google's consent screen lets a person untick one, and today that would refuse the whole connection, calendar included.
- *Already-connected account*: `addScopes` is the wrong tool here. Banana's accounts live in its own store; the SDK's `currentUser` is at most the last account interactively signed in on this device, is nil after a relaunch (restore is skipped whenever the store has accounts, :1641), and never exists for an account that arrived through iCloud Keychain. The general path is the one `reconnect(email:)` already uses: `signIn(withPresenting:hint: email, additionalScopes: calendar + gmail)`; the SDK's `include_granted_scopes=true` makes it incremental; `accept` then upserts the new refresh token and scope list.
- *iOS vs macOS*: same SDK call; only the presenter differs (:1693-1723). macOS needs some window (a menu-bar-only state throws `.noPresentationContext`); iOS needs a foreground-active key window.
- *Other devices*: the new credential syncs to prod devices by keychain, but `adoptAccountsFromStore` ignores a changed credential for a known id (:451-453) — a running device keeps the old refresh token and scope list until relaunch. Betas must consent on each device.
- *Outside the code*: both OAuth projects need the Gmail API enabled and the scope on the consent screen (see Open questions).

**(b) `grantedScopes`**: stored per credential as `[String]` (GoogleAccountStore.swift:12), written in exactly one place (`accept`, GoogleCalendarService.swift:1680), **read nowhere** (grep). So "this account lacks Gmail" is detectable locally with `credential.grantedScopes.contains(scope)`. Limits: it is what the SDK reported at consent on the consenting device, and nothing re-verifies it (the minter drops the token response's `scope`). Server truth is a Gmail 403 for insufficient scope.

**(c) What to extract** (seam, not a design): an account/token piece with no calendar knowledge owning — `accounts`, `accountsNeedingReconnect`, `reconnectReasons`, `tokenCache`, `clientID`, `connect / reconnect / disconnect / accept / interactiveSignIn`, the KVS hint, `adoptAccountsFromStore`, `accessToken(for: GoogleAccountCredential)`, and an authorised `send` with the 401 retry that takes the account explicitly. Calendar keeps `account(forCalendarID:)` (:269-276), `GoogleRequestRouting`, calendars, event caches, `coreFetchedAt`. Couplings to cut: `connect/reconnect` call `loadCalendars()` (:363, :401); `disconnect` resets calendar caches (:426-434); `send` invalidates the calendar core read (:2055); `accessToken` writes the calendar-wide `lastError` (:2109), which `windowFetch` overwrites (:574-576); `GoogleCalendarError` is `private`. Readers of account state to keep working: SettingsView (15 refs), SmartScheduleStore (11), CalendarDiagnosticsView, OnboardingStore, CalendarWriteBack, WriteBackCalendarSetup, TodayView, RootView, MacRootView (`MacGatedRootView` observes the service, :70), GuestSources (:39-40), GoogleRoundTripProbe. Anything pure (scope rules, credential model, routing) should sit in a file without `import GoogleSignIn` so BananaTests can list it.

**(d) Where `accountsNeedingReconnect` shows**: Settings root account row — dot + "Sign in again" (SettingsView.swift:440-446, drawn at :164-169 Mac and :416-426 phone); the account card (:738-807: `StatusDot(.attention)`, "Sign in again" / "No calendars — sign in again", a bordered "Sign in" button, ••• menu Reconnect / Disconnect, swipe actions, "Google said: …" :799-806); a footnote (:808-812); `lastError` in danger red (:906-910); CalendarDiagnosticsView.swift:27-36. Nowhere else: a rejected account stays "connected" (`isConnected`), so Today's "Calendar isn't connected" card (TodayView.swift:291) and the Mac gate (MacRootView.swift:85) do not fire. Behaviourally, write-back refuses removals while degraded (CalendarWriteBack.swift:555).

### For mail this means
- One access token per account already covers every granted scope: mail and calendar must share one token cache and one "needs reconnect" set, or they will mint twice and disagree about whether an account works.
- Mail requests must name the account explicitly; there is no URL to derive it from.
- "Mail not granted for this account" is a third account state (connected · needs sign-in · connected without Mail) that the store can express today but no UI shows.
- Any new field on `GoogleAccountCredential` must decode as optional (see Traps).
- A scope upgrade is a full interactive consent per account, on a device with a window in front.

---

## 2. The offline-first calendar pattern

### Facts

**Read cache**
- `GoogleEventSync.Snapshot: Codable { start, end, fetchedAt, fullReadAt, syncToken, events: [GoogleEvent] }` per calendar (GoogleEventSync.swift:22-38); `covers` (:31), `overlaps` (:42-44).
- In memory: `eventCache: [calendarID: Snapshot]` (GoogleCalendarService.swift:191). On disk: `GoogleEventDiskCache` — one JSON file per calendar under `AppSupport.directory/GoogleEventCache/<hex(calendarID)>.json` (GoogleEventSync.swift:134-170), `load / save / prune(keeping:)`, every function takes `in directory:` for tests. Plain `try? JSONDecoder` — not `SnapshotLoader` (a cache; a bad file costs a full read).
- Core window: 8 days back to 46 ahead (`coreWindow`, :828-834). One shared read of every readable calendar over it (`refreshCoreRead`, :621-681): joins a running read, reuses one younger than `cacheLifetime = 45 s` (:211), loads disk copies once per calendar per run (`loadDiskSnapshots`, :923-933), syncs all calendars concurrently with **detached tasks** (`syncCalendars`, :937-980), saves changed snapshots off-main (:665-670).
- Other ranges: direct read, not cached (`readCalendars`, :767-810).
- Failure: per-calendar `coreFailures` (:612); `lastKnownGood` serves any overlapping copy whatever its age (:821-824); the fetch is reported `isComplete: false` with `problems` and `covered` (`GoogleWindowFetch`, :122-136; assembled :522-606). Incomplete reads never justify removal.
- The slice + model build runs off the main actor (`Task.detached`, :597-605).

**Incremental sync** — pure rules in `GoogleEventSync` (GoogleEventSync.swift)
- `canContinue(_:window:now:)` (:59-64): same window, non-empty token, full read < 24 h old (`fullReadLifetime`, :56), clock not gone backwards.
- `apply(_ changes:to:)` (:67-87) by id; cancelled removes. `changedIDs(from:to:)` (:90-97) via a per-event fingerprint (`updated|status|start|end|summary`, :119-129).
- Transport: `sync(calendarID:token:previous:window:now:)` (GoogleCalendarService.swift:982-1008): incremental with `syncToken`; HTTP 410 → full read; first read is a baseline, not news (`SyncOutcome.hadBaseline`, :912-920).
- Change poll while open: every 120 s, foreground only (`observeCalendarChanges`, SmartScheduleStore.swift:1483-1508) → `hasChanges(since:excluding:)` (GoogleCalendarService.swift:846-856).

**Own-write echo**
- `recentOwnWrites: [eventID: Date]`, `noteOwnWrite(_:)` (:197, :203-207); `GoogleEventSync.containsNews(_:ownWrites:now:echoWindow: 600)` (GoogleEventSync.swift:100-106), `pruned` (:114-117); `GoogleOwnWrites.writtenAt` matches a series' occurrences `<master>_<instant>` (GoogleEventEditing.swift:185-194). In memory only.

**Optimistic writes, end to end**
| Write | Drawn at once by | Durable? | Confirmed by | Failure |
|---|---|---|---|---|
| Create | `OccurrenceStore.createCalendarEventOptimistically(input:calendarID:)` (OccurrenceStore.swift:1156-1162) → `PendingCalendarWriteStore.enqueue` → `pendingWritesDidChange()` (:826-834) overlays `optimisticOccurrence` (PendingCalendarWrites+Occurrence.swift:9-48) | Yes: `pending-calendar-writes.json` via `SnapshotLoader` (PendingCalendarWrites.swift:44-83) | `markWritten(remoteID)` → `.awaitingReadBack` → retired in `publish` by `reconcile(against:)` before merging (OccurrenceStore.swift:871; rules below) | `markFailed` → stays on the grid with a red badge (`EventSyncBadge.swift`), `retryPendingWrite` / `discardPendingWrite` (:1166-1178), dialog "Try again / Discard / Keep for later" (WeekView.swift:3177-3196, iOS) |
| Edit | `SmartScheduleStore.saveEventEdit(_ edit: EventEdit)` (SmartScheduleStore.swift:215-241) → `OccurrenceStore.beginEventEdit(PendingEventEdit)` (OccurrenceStore.swift:837-840); overlay by `PendingEventEditStore.apply` (PendingEventEdits.swift:35-53), `syncState = .syncing` | No — memory only, by design (PendingEventEdits.swift:17-18) | awaited `refreshAgenda` + `recompute`, then `endEventEdit`, then `ToastCenter.offerUndo` (:228-231) | `endEventEdit` restores the read copy (`editOriginals`, OccurrenceStore.swift:51, :848-865) and `ToastCenter.offerRetry("Couldn't save …")` (:233-238) |
| Delete / decline | `ToastCenter.deferDelete(eventID:hiding:title:span:delete:)` (ToastCenter.swift:173-182) / `deferRemoval(id:message:failure:commit:)` (:58-77): id goes into `hiddenIDs`, nothing is sent yet. Series via `PendingRemovals.seriesToken` (PendingRemovals.swift:27-32), `CalendarEditSpan.hiding` (:56-66). Decline: `InvitationReply.decline` (InvitationReply.swift:17-36) | No — memory only; app death inside the window = nothing happened | commit runs when the 6 s window ends (`ToastCenter.window`, :26), on backgrounding (iOS `didEnterBackground`, Mac `willResignActive`, :46-53), or when the next toast is shown; the commit awaits the recompute before un-hiding (SmartScheduleStore.swift:184-198) | item un-hides and a notice toast says why (:66-71) |
| Drag | `optimisticStart[occurrenceID]` view state (WeekView.swift:331, :1734-1755, :2871-2895) | No | `offerMoveUndo` (ToastCenter.swift:184-188; single occurrence only) | position snaps back |

- Pure rules: `PendingWriteState { writing, awaitingReadBack, failed }` and `PendingCalendarWriteRules` (PendingCalendarWriteRules.swift:9-87): `readBackGraceInterval = 300`, `inFlightGraceInterval = 90`, `signature(title:start:)` (title + minute), `shouldRetire(state:remoteID:signature:confirmedRemoteIDs:confirmedSignatures:)` (id preferred; a failed or in-flight write is never retired by a read), `hasOutlivedReadBack`, `stateAfterRelaunch`.
- Hidden ids are filtered where the day is read: `OccurrenceStore.occurrences(on:)` (OccurrenceStore.swift:1262), both grids (WeekView.swift:1534, :3364, :4269), and the store republishes on every `hiddenIDs` change (:141-156).
- Placeholders are never baked into the first-paint snapshot (OccurrenceStore.swift:38-44, :885-896).
- `ToastCenter` holds ONE pending commit; a new `deferRemoval` takes the previous commit, shows its own toast, then **awaits the previous commit's network call** before returning (ToastCenter.swift:61-76; tested in ToastCenterTests `testOverlappingRemovalsEachCommit`, `testTheNextEditCommitsThePreviousDelete`).

**On relaunch**
- `PendingCalendarWriteStore.init` loads; any entry still `.writing` and older than 90 s becomes `.failed` with "Interrupted before it finished saving." (PendingCalendarWrites.swift:54-65). **Nothing retries automatically** — not on launch, not when the network returns (`NetworkMonitor` is not consulted).
- `OccurrenceStore.init` loads `occurrences-snapshot.json` and `planning-windows.json` synchronously for first paint (:157-170); `lastComputed` stays nil so a real recompute follows (wireUp, BananaApp.swift:759).
- Calendar disk snapshots are picked up lazily by the first core read.

**Style**: pure `enum` namespaces of static rules with the reasoning in doc comments (`GoogleEventSync`, `PendingCalendarWriteRules`, `PendingRemovals`, `GoogleRequestRouting`, `ControlMerge`, `GoogleEventWindow`, `CalendarWriteBackPolicy`), thin `@MainActor` stores around them, a `+Occurrence` extension file to keep the pure half free of the app's dependency graph, and one test class per rule file. Doc comments say why, usually by naming the incident.

### For mail this means
- The template exists: per-container snapshot + sync token (Gmail's `historyId` plays `syncToken`; "history too old" is the 410 case) + own-write echo + last-known-good + "incomplete read never removes".
- The calendar cache is whole-file JSON per calendar, rewritten on every change — fine for ~10³ events, wrong for a mailbox. There is no precedent for an incrementally written store (§3).
- Only *creates* are durable today. Mail needs every mutation durable (archive, label, send) — a new store, not a reuse of `PendingEventEditStore` / `ToastCenter.hiddenIDs`.
- `ToastCenter` serialises: awaiting `deferRemoval` from a key handler would block fast repeat archives behind the previous network call; and its single slot means only the last action is undoable.
- No automatic retry exists anywhere; an outbox needs its own retry driver (launch, foreground, `NetworkMonitor`, background task).
- Follow the shape: rules in pure enums in their own files (so BananaTests can list them), transport in the service, overlays applied at the read seam.

---

## 3. Persistence conventions

### Facts
- **Root**: `AppSupport.directory` (Banana/Model/AppSupport.swift:41-53) = Application Support root in prod, `…/Banana Beta/` under `BANANA_BETA`. Mac prod is unsandboxed, so files sit at the root of `~/Library/Application Support` (docs/MAC-VARIANTS.md:10, :26-29). `AppCloud.containerID` / `hasContainerEntitlement` in the same file (:8-31).
- **Stores take their directory/URL as an init parameter defaulting to `AppSupport.directory`** so tests use a temp folder: `PendingCalendarWriteStore(directory:now:)` (PendingCalendarWrites.swift:44), `MyFoodsStore(fileURL:)`, `MealInboxStore(fileURL:…)`, `MealPhotoStore(directory:)`, `NarratorVoiceStore(directory:)`, `SkipPlanStore`, `GoogleEventDiskCache.*(in:)`.
- **JSON snapshots**: `Shared/SnapshotPersistence.swift` — `SnapshotLoader.load(from:as:now:) -> SnapshotLoadResult { .empty | .loaded | .corrupt(error:quarantinedTo:) }` (:89-102), `quarantine(fileAt:)` copies to `<name>.corrupt-<stamp>.json` (:108-118), `LossyArray` / `LossyDictionary` / `FailableDecodable` (:28-61). Convention when quarantine fails: refuse to save (`mustRefuseSaves`, PendingCalendarWrites.swift:38-40, :78-80). Writes are `.atomic`.
- **Decoders are hand-written with `decodeIfPresent`** wherever a stored type gains fields (`ShellState.init(from:)` ShellNavigation.swift:73-84; `CloudControlsSync.SyncState` :83-93; `HubStatus` :47-60).
- **SQLite**: used in two places only, both **read-only bundled databases**, raw `SQLite3` C API, no wrapper library.
  - `FoodDatabase` (Banana/Model/FoodDatabase.swift): `private final class FoodSQLite` opens `SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX` per call, closes in `deinit` (:501-530); `rows(_:_:_:)` prepare/bind/step (:532-549); text binds use `SQLITE_TRANSIENT` (:556). "Every call opens its own read-only connections … safe from any thread" (:30-31). **FTS5 is used**: `foods_fts MATCH ?` with column filters (:278, :293-295, :336), `branded_fts` (:350); the indexes are contentless FTS5 built by `tools/build_food_database.py` (:392-394, optimize :484-485).
  - `BarcodeProductLookup.lookup(_:databaseURL:)` (BarcodeProductLookup.swift:247-290): open-per-call read-only, one prepared statement.
  - `FoodDatabaseTests.testSystemSQLiteRunsFTS5Match` asserts `sqlite3_compileoption_used("ENABLE_FTS5") == 1` on the OS SQLite (BananaTests/FoodDatabaseTests.swift:32-44).
  - **No writable SQLite database exists anywhere** (no `SQLITE_OPEN_READWRITE`, no WAL, no migrations, no GRDB / SwiftData / Core Data — grep). Bundled DBs: `Banana/Resources/Foods.sqlite` (20 MB), `BarcodeProducts.sqlite` (57 MB).
- **Network caches as JSON**: `BarcodeNetworkCache-2.json` (BarcodeProductLookup.swift:881).
- **Image cache**: `ImageCache` (Banana/Model/ImageCache.swift) — `NSCache` (120 items / 40 MB decoded, :48-49) over a disk cache in **`Caches/Artwork`** (:45-46; not AppSupport), files named by SHA-256 of the URL (:199-203), ImageIO downsample to buckets 128/256/512/1000 px (:205-213), one network fetch per URL (shared in-flight task), 60-day sweep at init (:56-69). API: `memoryImage(for:targetPixelSize:)` (:72), `image(for:targetPixelSize:) async` (:84), `clearMemory()` (:79, called on memory warning RootView.swift:230-232), DEBUG `injectPreviewOriginal(_:for:)` (:223). It fetches with plain `URLSession.shared.data(from:)` — no auth header (:140).
- **File protection**: only `TripLearningService` (`.completeFileProtectionUntilFirstUserAuthentication`, :243) and the diagnostics directory set a class; everything else takes the default.
- **Backups**
  - `CloudBackup` (Banana/Model/CloudBackup.swift) is an explicit allowlist: eight files (:122-131) and one directory (:132-134) plus the **whole UserDefaults domain** (:388) into one `backup.plist` in the ubiquity container (:171-183). Phone and Mac write it; an iPad never does (:208). Nothing else in AppSupport is included.
  - iOS device backup: `isExcludedFromBackup` is set in exactly two places — `MealPhotoPrints` directory (MealPhotoPrints.swift:27-34) and the diagnostics directory (Shared/DiagnosticsTracing.swift:586-599). That is the pattern for a rebuildable cache: create the directory, set the resource value on it.
- **UserDefaults holds a lot of state**: CKSyncEngine serialisations, zone poll tokens (`zonePoll.<zone>`), `shellState`, settings blobs. Keys are dot-free where a hot view reads them (ShellNavigation.swift:113).

### For mail this means
- A writable SQLite mail store would be the first of its kind: connection lifetime, threading (existing code is NOMUTEX-per-call, which does not fit a writer), WAL, schema versioning and corruption recovery all have to be decided — and written with the raw C API unless a dependency is added.
- FTS5 is proven available on the OS SQLite and already has a test asserting it; mirror that test for the mail schema.
- Put the cache under `AppSupport.directory/<Folder>` (beta isolation), take the directory as a parameter, mark it `isExcludedFromBackup`. `Caches/` is purgeable by the OS — unusable for offline-first bodies.
- Do not put mail state in UserDefaults: it is copied wholesale into the iCloud backup snapshot.
- `ImageCache` cannot fetch Gmail attachments (needs a Bearer token) and its 60-day sweep is by access date; avatars/remote images fit, attachment bytes need their own store.
- Nothing of mail should be added to `CloudBackup.files` — it is re-derivable from Gmail.

---

## 4. Navigation shell

### Facts
- **`AppSection`** (Banana/Model/AppSection.swift:7-75), `String, Codable, CaseIterable`, order = `plan, workouts, sleep, trends, nutrition, notes, routines, library, settings` (:8). Symbols :25-37 (`sun.max.fill, figure.run, bed.double.fill, chart.line.uptrend.xyaxis, fork.knife, quote.bubble.fill, repeat, square.stack.fill, gearshape.fill`). `iOSTabs = [.plan, .workouts, .nutrition, .notes, .library]` (:40) — **used only by tests**; the real tab list is hand-written in `RootView.mainTabs`. `tabBarHome` (:44-50): sleep/trends → workouts, routines/settings → plan. `macSidebar = allCases` (:54). `macShortcuts = macSidebar` minus settings (:65). `chosen(_:current:)` (:59-61). Raw values are persisted (`ShellState.tab`) and are launch-argument values (`--tab`, `--mac-section`).
- **iOS/iPadOS shell**: `RootView.mainTabs` (Banana/Views/RootView.swift:397-508) — one `TabView(selection:)` of `Tab(title, systemImage:, value:)`, `.tabViewStyle(.sidebarAdaptable)` (:477), `.tabBarMinimizeBehavior(.onScrollDown)` (:489), `.tabViewBottomAccessory` for the now-playing bar (:490-498). Every tab's content gets `.measuresLayoutClass()` and `.toastHost()` (toast per tab, not on the TabView, :395-396); synced sections add `.syncWaitingNote(domain)`; badges via `.badge(badges.counts.…)` (:412, :448).
- **Sidebar-only sections**: wrapped in `if showsSidebarSections { Tab(…).tabPlacement(.sidebarOnly) }` where `showsSidebarSections = horizontalSizeClass == .regular && DeviceRole.current != .phone` (:383-385). `.tabPlacement(.sidebarOnly)` alone leaked them into the iPhone bar as "More" (:379-382). `tabSelection` maps a sidebar-only selection to its `tabBarHome` when the sidebar is gone (:389-393).
- **Five-tab cap**: docs/design/IA-2026-09.md:29 ("5 tabs, no More overflow") and :3 ("so … does not creep back as a sixth tab"); asserted by `AdaptiveShellUITest` (BananaUITests/AdaptiveShellUITest.swift:35-41).
- **Per-section arrangement**: chosen in one place by `@Environment(\.layoutClass)` — `WorkoutsSection`, `NutritionSection` (RootView.swift:687-709).
- **`LayoutClass`** (Banana/Views/AdaptiveLayout.swift:9-24): `.compact` / `.regular` split at 600 pt; `EnvironmentValues.layoutClass` (:29); `.measuresLayoutClass()` uses `onGeometryChange` (:34-48).
- **`DeviceRole`** (Banana/Model/DeviceRole.swift:10-44): `.phone / .pad / .mac`, `isHub` (phone only), `name`.
- **Mac shell**: `MacRootView` (Banana/Views/MacRootView.swift:252-398): `NavigationSplitView`; sidebar `List(AppSection.macSidebar, selection:)` selected by row id, not `.tag` (:285-295); detail is a `switch nav.section` of the shared views (:307-317) with ONE `.toastHost()` (:321); a right-hand in-content panel (event inspector 350 pt / availability 340 pt) deliberately **not** `.inspector` (:300-304, :339-349); a bottom now-playing bar (:358-364). `MacNavigator` (:22-60): `@Published var section`, `showFullPlayer`, `showMorningBriefing`, `inspectedMeeting`, `showsAvailability`, `offeredSlots`; `--mac-section <raw>` (:53-57). **Section is not persisted** (FUTURE.md:346-348). `MacGatedRootView` puts the whole app behind a connected Google calendar (:83-90).
- **⌘-numbers**: `ForEach(AppSection.macShortcuts.enumerated())` → `KeyEquivalent(Character(String(index + 1)))` (MacRootView.swift:521-524). Today 8 numbered sections (⌘1…⌘8).
- **State restoration**: `ShellState` (Banana/Model/ShellNavigation.swift:16-107) — `tab`, `workouts: [WorkoutsRoute]`, `notes: [UUID]`, `library: [UUID]`, `nutritionSection`, `nutritionCapture`, `noteComposer`, `nutritionDay`, `savedAt`; all decoded with `decodeIfPresent`; `restoreWindow = 3600 s` (:87); `restored(from:now:)` (:90-98); `pruned(_:known:)` (:103-106). `ShellNavigation.shared` (:109-134) persists JSON under UserDefaults key `shellState` on every change and on backgrounding. Usage pattern: `NavigationStack(path: $shell.state.library)` + `navigationDestination(for:)` + prune on load (PodcastsView.swift:13-78; NotesView.swift:12-25, :110, :200). In-memory unsaved text: `enum Drafts` (:138-145). A sheet kept in `ShellState` reopens on the next launch within the hour (owner note `banana-ui-test-and-gesture-gotchas`).
- **Tree discard**: `AppVisibility` (Banana/Model/AppVisibility.swift): `isActive` flips at once; `rendersContent` goes false 2.5 s later (`snapshotGrace`, :40, :44-64). `RootView.gatedContent` renders `Color.black` then (RootView.swift:336-349). Only `.background` gates; `.inactive` keeps the tree (:302-310). iOS only — the Mac has no blank, but rebuilds a section's view when the sidebar leaves it.
- **Badges**: `ActionBadges` / `ActionItems.Counts { plan, food, taken; nutrition; total }` (ActionBadges.swift:14-64, ActionItems.swift:7-17); `total` is written to the app icon / Dock tile (:55-63). Mac sidebar badge: `badgeCount(_:)` (MacRootView.swift:273-279).

### Adding a top-level "Mail" section touches

*Shared*
- `AppSection`: a new case (position in the enum = Mac sidebar order and ⌘-number), `title`, `symbol`; `iOSTabs` and/or `tabBarHome`.
- `ShellState`: a mail route/selection field (+ `init`, + `decodeIfPresent`), pruning against known thread ids.
- `ActionItems.Counts` / `ActionBadges` if unread should badge the tab — note `total` drives the app-icon badge.
- Tests that pin the section lists: `MetricTrendsTests.swift:169-174`, `MacSidebarSelectionTests`, `ShellNavigationTests`, `AdaptiveShellUITest.swift:22-41`, `ScreensOpenUITest.swift:9-10`.

*iPhone / iPad* — `RootView.mainTabs`: a hand-written `Tab` with `.measuresLayoutClass().toastHost()` (+ `.badge`), a `MailSection`-style switch on `layoutClass` if the two arrangements differ; `--tab mail` then works (RootView.swift:480-486). A preview route needs `VisualAuditRoute.flags` (BananaApp.swift:17-25) + the `RootView.body` chain (:59-189).

*Mac* — one `case` in `MacRootView`'s switch (:307-317). Sidebar row, ⌘-number, `--mac-section mail` and the ⌘K "Open Mail" entry (MacCommandCenter.swift:236-239) follow from the enum. `MacNavigator` needs mail's selection state if it must survive a section switch (the detail view is rebuilt).

*What the IA docs imply for iPhone*: the tab bar is full (Plan, Workouts, Nutrition, Notes, Library) and the record forbids a sixth. The same record's rule is that daily tools are tabs and configuration is demoted (IA-2026-09.md:24-27, :39-41). So Mail on iPhone must either take one of the five seats or live under another tab's home (`tabBarHome`, as Sleep/Trends/Routines/Settings do); the docs name no seat for it. On iPad and Mac a sidebar row is free.

### For mail this means
- Selection, open thread, open draft and the split/filter in view must live in `ShellNavigation` (iOS discards the tree) — and a compose sheet stored there reopens on relaunch; unsent text is in-memory `Drafts` today, which is not good enough for mail.
- The list must be reconstructible instantly from a store after the 2.5 s blank (scroll position, selection).
- Use `layoutClass`, never device checks; at most two arrangements (list-then-push; list + reading pane).
- Mail is not a hub duty: do not gate on `DeviceRole.isHub`. Every device talks to Gmail.
- On the Mac a reading pane beside the list should follow the in-content `HStack` precedent, not `.inspector`.

---

## 5. Mac keyboard and command surface

### Facts — all in `Banana/Views/MacCommandCenter.swift` (`#if os(macOS)`) unless noted
- `enum MacCalendarAction` (:6-14): today, nextPeriod, previousPeriod, goTo(Date), dayView, weekView, span(Int), newEvent, newTask, refresh, shareAvailability, nextEvent, previousEvent, closeInspector, respond(GoogleCalendarRSVP), joinNextMeeting. Calendar-only.
- `MacCommandCenter.shared` (:22-101): `@Published showsCommandMenu`, `showsShortcuts`, `lastError`; `perform(_ action:)` either mutates `MacNavigator` / UserDefaults directly or posts `Notification.Name.macCalendarAction` with the action as `object` (:59-61). Receivers are `.onReceive` in the visible planner (WeekView.swift:609-629, :3331; TodayView.swift:512-515). `reply(to:with:)` (:82-100).
- **Single keys**: `MacKeyMonitor.shared.install()` (called from `MacRootView.onAppear`, MacRootView.swift:396) adds ONE `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` (:115-121). `handle(_:)` (:123-178): ⌘Z → toast undo unless the first responder is `NSText` (:127-132); otherwise bails on any modifier, on sheets / panels (:134-135), when the first responder is `NSText` (:136), or while ⌘K is open (:138). Then a hard-coded `switch key`: `t j k d w 1-7 n b c s ? / e` (:160-176) plus the two-key `e` then `y/n/m` with a 1.5 s window (:148-158, `pendingPrefix`). Escape closes the inspector (:139-145).
- **The monitor is not section-aware.** It never reads `nav.section`; most actions set `nav.section = .plan` first (`perform`, :35-60). Pressing `j`, `k`, `c`, `s`, `t`, `d`, `w`, `n`, `b` or a digit in any section jumps to Plan and acts there.
- **⌘K palette exists**: `struct MacCommand { id, title, symbol, shortcut, run }` (:182-242); `static var all` is a hand-built array (:206-241) with `section` derived from a `switch id` (:190-201) and `sectionOrder` (:203). `MacCommandMenu` (:246-392): substring match on title words (:260-263), a typed date via `CommandMenuDateParser` (:254-258; Banana/Model/CommandMenuDateParser.swift), ↑/↓/Return/Esc with `.onKeyPress` on the field (:294-296), grouped when empty, key-hint footer, 560 pt wide, `DS.Radius.panel`. Presented as an overlay in `MacRootView` (:384-394). `MacShortcutsSheet` (:395-445) has a hard-coded shortcut table (:398-405).
- **Menu bar**: `MacCommands: Commands` (MacRootView.swift:494-560), attached with `.commands { MacCommands() }` on macOS only (BananaApp.swift:304-308): ⌘, Settings; ⌘N New Event; ⇧⌘N New Task; ⌘1…n sections; ⌘R Refresh Calendar; ⇧⌘M Morning Briefing; ⌘K Command Menu; ⌘/ Keyboard Shortcuts; Join Next Meeting. Commands talk to views by `NotificationCenter` (`macNewEventRequested`, `macNewTaskRequested`, `macForceRefreshRequested`, :562-573).
- **Global hotkey**: `JoinMeetingHotKey` via Carbon `RegisterEventHotKey` ⌃⌘J (MenuBarAgenda.swift:228-250), registered after launch (BananaApp.swift:222-225).
- **Design-system pieces**: `KeyCap(key:)` (Shared/BananaDesign.swift:220-235), `KeyCombo(combo:)` with `static func keys(_:)` splitting "⌃⌘J" into caps and keeping words like "Esc"/"then" (:238-260); tested in `BananaDesignTests`.
- **Focus**: no `FocusedValue` / `focusedSceneValue` / responder-chain commands anywhere. `@FocusState` is used only for text fields. The one SwiftUI key-handling list/detail is `WideWorkoutDetailView` (`.focusable().focused($isFocused).onKeyPress(keys:phases:action:)`, :76-80) and `MealPhotoViewer` (:73-74). The week view has a scroll-wheel monitor only (WeekView.swift:2125).
- **iOS / iPadOS**: no palette, no command menu, no key monitor. Hardware-keyboard shortcuts are limited to ⌘Z on the toast's Undo (ToastCenter.swift:217-219) and ⌘↩ on a few save buttons (TodayView.swift:1516, :1530, :2404). `.commands` is not attached on iPad.

### For mail this means
- To build on: the local-monitor approach and its typing/sheet guards, the two-key prefix mechanism, `MacCommand` + `MacCommandMenu` (UI, ranking-free filter, key hints), `KeyCombo`, `MacShortcutsSheet`, and the notification bridge from menu commands to the visible view.
- Missing: any notion of scope. Mail's `j/k/e/r/c/#//` collide with calendar bindings that are global today — the monitor must dispatch by `nav.section` (and by what has focus inside Mail: list vs reader vs composer) before a single mail key can be added. `MacCommand.all` and the shortcut sheet are static calendar lists; there is no registration API, no per-section command provider, no fuzzy ranking, no recents.
- `MacCalendarAction` and the notification name are calendar-specific; mail needs its own action type or a generalised one.
- ⌘K on iPad/iPhone hardware keyboards does not exist at all; if wanted there it is new work (and the palette view is inside `#if os(macOS)`).
- ⌘R is "Refresh Calendar" and ⌘N is "New Event"; Superhuman-style ⌘-shortcuts need a decision on precedence per section.

---

## 6. Design system

### Facts — `Shared/BananaDesign.swift` (485 lines; compiled into the app, the widget and BananaTests)
| Name | Line | What it is |
|---|---|---|
| `DS.Space` | :18-26 | `hair 2, xs 4, s 8, m 12, l 16, xl 24, xxl 32` |
| `DS.Radius` | :30-36 | `block 5, chip 6, control 8, card 12, panel 16` (always `.continuous`; nested shapes step down) |
| `DS.artworkRadius(for:)` | :40-47 | corner by size tier |
| `DS.Typeface` | :51-67 | fixed grid/chrome sizes: `periodTitle, eyebrow (+eyebrowTracking), dayHeader, dayHeaderToday, gutter, eventTitle, eventMeta, keyCap`. Everything else uses system text styles |
| `DS.Palette` | :72-118 | `accent` (= `Color.orange`), `now`, `success, danger, warning, info`, `task, travel`, `Feature { calendar, travel, wake, podcasts, workouts, icloud, system }` (settings icon-tile identity, :92-100), `zones`, `Macro { protein, carbs, fat }`, neutrals `separator, gridHour, gridHalfHour, selection, todayWash` |
| `DS.Tint` | :122-128 | the only wash opacities: `wash .04, subtle .08, soft .14, fill .2, strong .35` |
| `DS.Event` | :131-141 | block spine/fill constants |
| `DS.Row` | :145-155 | **sizes only**: `minHeight 44, iconTile 28, glyphTile 40, avatar 32, statusDot 8`. Not a view |
| `DS.placeholder` | :159 | "—" |
| `TimeRangeText` | :164-217 | `compact(_:_:calendar:locale:)`, `time(_:)`, `clockOnly(_:)`, `uses12Hour(_:)` |
| `KeyCap`, `KeyCombo` | :220-260 | key caps |
| `StatValue` | :269-352 | `StatValue(label:value:unit:footnote:size:alignment:)`, sizes `.row/.tile/.hero`, `static split(_:)` |
| `DSCard` / `.dsCard()` | :357-372 | card background (grouped background on iOS; wash + hairline on Mac) |
| `IconTile` | :376-399 | `IconTile(systemImage:tint:style:size:)`, `.solid` / `.soft` |
| `ConnectionStatus`, `StatusDot` | :404-426 | `.ok/.working/.attention/.off` → colour; 8-pt dot |
| `CalendarColor` | :434-485 | hue-preserving normalisation of Google colours, appearance-aware |
Elsewhere:
- `ToastCenter` (Banana/Model/ToastCenter.swift:22-163): `deferRemoval(id:message:failure:commit:)`, `offerUndo(_:undo:)`, `notify(_:)`, `offerRetry(_:retry:)`, `undo()`, `dismiss()`, `commitPending()`, `hiddenIDs`, `static var window = .seconds(6)`; `View.toastHost()` (:193-200); `ToastView` (:202-243, capsule on `.regularMaterial`).
- `calendarTint(_ hex:) -> Color` lives in TodayView.swift:2116, not in the design file. `GuestAvatar` in TodayView.swift:2726.
- `SyncWaitingNote` / `.syncWaitingNote(_:)`, `SyncStatusSection` (Banana/Views/SyncStatusViews.swift).
- `.settingsFormStyle()` (SettingsView.swift:1656-1667), `settingsRow(_:symbol:tint:value:)` is a private helper inside `SettingsView` (:499-510).
- Row views are per feature and mostly private (`EpisodeRow`, `VoiceNoteRow`, `WorkoutRow`, `MealInboxRow`, …). **There is no shared list-row view.**

**Rules the doc insists on** (docs/design/DESIGN-SYSTEM.md): views name roles, never numbers (:4-5); rows ≥ 44 pt and the leading element decides the row kind (:55-68); section headers outside cards, sentence case, UPPERCASE only for the eyebrow (:49-53); identity colour is a 3-pt spine + a `Tint` wash, never text colour (:67-68); accent only for Banana itself / primary action / selection (:26-27); every time through `TimeRangeText` (:37-39); undo over "Are you sure?", one-line toast, at most ONE action, removals deferred (:94-99); layouts never jump — fixed-size placeholders and skeletons with the result's geometry, background work as a card not a blocking spinner, empty state = one line, one hint, one action (:101-104); permissions asked where first used with one priming template (:106-112); where-you-are state in `ShellNavigation`, pushes value-based (:123-129); shortcuts drawn with `KeyCombo`, palettes have a key-hint footer (:131-132); Cancel/Done in the toolbar for edit sheets, never a floating Save (FUTURE.md:134).

**What FUTURE.md reserves that mail touches**
- One app-wide toast, hosted per tab (:16).
- Account, sync and permission status = dot + word (:18); a future **Connected Accounts screen: one card per account with per-service toggles**, Resync and Remove in ••• (:150, :173-176) — the natural home for a per-account Mail switch; not built (today's card has no toggles, SettingsView.swift:748-790).
- Settings: each setting gets a stable id + breadcrumb for a generated search index; nesting ≤ 2 levels; Mac settings as a sidebar window still future (:92-121).
- Today: fixed module order "Now/Next → Morning/Afternoon/Evening → Health → Briefing → everything else collapsed", at most one alert card at a time (:62-73) — a mail module on Today would be "everything else".
- Navigation: every new push value-based with its path in `ShellNavigation`; open sheets and the Mac section are not restored yet (:336-351).
- Nothing in FUTURE.md mentions mail; nothing reserves a tab or a colour for it. `DS.Palette.Feature` has no mail identity colour (calendar is red, podcasts purple, travel/info blue).

### For mail this means
- A mail row is a new row kind; define its anatomy against `DS.Row` sizes (44-pt minimum, 32-pt avatar exists as a size) and add any new role to `DS` rather than inline numbers — a dense Superhuman-style row under 44 pt contradicts the written rule and needs an explicit decision.
- Unread/selected/starred need role names; "accent = selection marks" is already the rule.
- Archive/trash/snooze confirmations are toasts with Undo; a send is the one place an "applied change" toast with a different verb is needed — `ToastCenter` supports only Undo or Retry as the single action.
- Message dates are not ranges: add a role/helper beside `TimeRangeText` rather than formatting inline.

---

## 7. App wiring and lifecycle

### Facts — `Banana/BananaApp.swift`
- **Stores**: `@StateObject` for `AlarmStore`, `HealthKitStore`, `SmartScheduleStore.shared`, `AppSettings`, `ListenHistoryStore`, `OnboardingStore`, `WellnessStore.shared` (:40-55); `let` singletons for the rest (:50-64). Injection is `configured(_:)` — a chain of `.environmentObject` plus `\.weekSmartStore`, `\.alarmStore`, `\.calendar` (:582-617), and `.onOpenURL { GoogleCalendarService.handleOpenURL($0) }` (:615). Many stores are reached as `.shared` and deliberately **not observed** by shells (RootView.swift:12-27).
- **`init()`** (:66-229) runs before any window: diagnostics session, `CloudModelGuard.checkAtLaunch`, `ControlChangeReporter.connectToCloud()`, `MealBacklogWake.startSync()`, WatchConnectivity, **BG task registration** (`TranscriptCoordinator.registerBackgroundTasks`, `OvernightRefresh.register`, `CalendarWriteBackRefresh.register`, `MealPhotoScanner.register`, `MealEstimateCatchUp.register`, :108-120), `ActionBadges.start`, `PerfWatchdog.start`, `Metrics.start` (iOS), DEBUG verification hooks, Mac: `GoogleRoundTripProbe.runIfRequested`, then (unless `CalendarWriteBack.isDiagnosticLaunch`) `JoinMeetingHotKey` + `MenuBarAgendaItem` on the next run-loop turn (:217-227).
- **`wireUp()`** (:620-908) is attached as `.task` on `configuredRoot` only (:570-573). It wires callbacks, starts `CloudSettingsSync.startIfPossible()` (:684), schedules BG tasks (:729-731), kicks the launch recompute un-awaited (:759), runs the restore check, then **awaits each store's `whenLoaded()` before starting its sync** (`library` :783, `history` / `wellness` :853-854, `fitness` :859), registers `CloudControlsSync` sources (:809-830) and starts the syncs (:806, :855, :860, :864).
- **Scene routing** (:235-312): iOS DEBUG → `--verify-timeline`, `--occurrences`, `--day-real-calendar`, else `isVisualAuditLaunch` → `configuredPlatformRoot.task { injectVisualAuditSamples() }` (no `wireUp`), else `configuredRoot`. Mac DEBUG → `--snapshot-routine-editor`, `--snapshot-app-store` (+ `--snapshot-view`), `--snapshot-workout-review`, `--ui-audit`, else `configuredRoot`. Mac scene: `defaultSize 1120×780`, `.commands { MacCommands() }` (:304-308).
- **`VisualAuditRoute`** (:14-29, `#if DEBUG && os(iOS)`): the single flag set shared by `BananaApp` (route + no `wireUp`) and `RootView` (skip the production scene-phase handler, RootView.swift:270). A route flag missing from this set starts the production graph and crashes the unsigned Simulator build (:15-16).
- **Per-screen preview routes**: the `if/else` chain in `RootView.body` (RootView.swift:59-189): `--ui-preview` (real shell + real blank gate, :63-77; `--toast-preview`), `--settings`, `--notes`, `--library`, `--wellness` (+ sub-flags), `--plan`, `--week`, `--day`, `--today`, … and `--tab <AppSection raw>` inside `mainTabs` (:480-486). Fixtures: `injectVisualAuditSamples()` (BananaApp.swift:502-559), which also seeds **connection state** (:513-515) so cards don't render "not connected".
- **Mac snapshot harness**: `--snapshot-app-store <png>` renders offscreen and exits (`scheduleHeadlessAppStoreSnapshotIfNeeded`, :331-447); `--snapshot-view <name>` picks from `MacDebugSnapshotViews.view(named:smart:)` (Banana/Views/MacDebugSnapshotViews.swift:9-74: `menu-bar, command-menu, shortcuts, availability, availability-panel, inspector, inspector-travel, meal-editor, supplement-editor, place-picker, calendar-picker, player, workout-charts, undo-toast`); modifiers `--appearance light|dark`, `--compact-window`, `--capture-height`, `--snapshot-delay`; without `--snapshot-view` it captures the whole root, steerable with `--mac-section`. `--ui-audit` runs the real Mac window on fixtures (`injectMacVisualAuditSamples`, :459-492) and bypasses the calendar gate (MacRootView.swift:73-81). The offscreen renderer cannot draw system materials (DESIGN-SYSTEM.md:143-144).
- **How a preview launch stays off the network / iCloud**
  1. `VisualAuditRoute` → no `wireUp()`, no production scene-phase work.
  2. `--disable-icloud` checked by each sync: CloudSettingsSync.swift:44, CloudBackup.swift:152, CloudControlsSync.swift:106, CloudWellnessSync.swift:78, CloudProgressSync.swift:767.
  3. Compile-time `#if targetEnvironment(simulator)` → unavailable: CloudControlsSync.swift:103, CloudWellnessSync.swift:75, CloudProgressSync.swift:84, :771. **`CloudSettingsSync.startIfPossible` has no simulator guard** (:42-60) — that is the unsigned-Simulator trap.
  4. `AppCloud.hasContainerEntitlement` (macOS entitlement probe, AppSupport.swift:20-30).
  5. `CalendarWriteBack.isDiagnosticLaunch` (CalendarWriteBack.swift:889-895; arguments `--google-roundtrip, --google-window, --google-dump, --snapshot-app-store, --adopt-legacy-blocks, --google-sync, --google-repeat`): no write-back (:459), no settings migration (SmartScheduleStore.swift:531), no menu-bar item.
  6. `--ui-audit` skips notification authorisation (NotificationService.swift:11) and several view-level refreshes (WeekView.swift:567, :3215-3248; TodayView.swift:489).
  7. Not covered: `GoogleCalendarService.shared.init` always loads the keychain and starts a restore (GoogleCalendarService.swift:318-331). On a Simulator there are no accounts; on a Mac `--ui-audit` launch the real accounts are there and the calendar list is fetched.
- **Foreground / background hooks** — iOS `RootView.onChange(of: scenePhase)` (RootView.swift:252-333): `.active` → `AppVisibility.set(active: true)`, `CloudSyncPoll.resume()`, `adoptGoogleAccountsAddedElsewhere()`, permission re-reads, `smart.recomputeIfStale()`, `CloudProgressSync.flushNow`, `downloads.refreshFeedsAndReconcile()` (:273-301); `.inactive` → still visible (:302-310); `.background` → `CloudSyncPoll.pause()`, `AppVisibility.set(active: false)`, `ShellNavigation.save()`, progress commit, `CloudBackup.backUpNow`, `CalendarWriteBackRefresh.schedule()` (:311-329). `ToastCenter` commits its pending change on background by its own observer. Mac: `NSApplication.didBecomeActiveNotification` → `CloudProgressSync.flushNow` + `CloudSyncPoll.resume()` (MacRootView.swift:325-331); scenePhase `.active` → payoff checks + account adoption (:432-437). The Mac keeps polling while in the background.
- **BGTaskScheduler** — identifiers in `BGTaskSchedulerPermittedIdentifiers` for `Banana` (project.yml:137-156) and mirrored for `BananaBeta` (:269-279): `com.boris.banana.transcribe.overnight`, `…feeds.overnight`, `…transcribe.*`, `…calendar.refresh`, `…meals.scan`, `…meals.estimate.*`, `…meals.catchup`. `UIBackgroundModes`: `audio, processing, fetch, location, remote-notification` (:123-133). Code: `CalendarWriteBackRefresh` (BGAppRefresh, 2 h floor; register :26-31, schedule :37-46, run :48-83 re-schedules first, honours expiry), `OvernightRefresh` (BGProcessing, OvernightRefresh.swift:16-33), `TranscriptCoordinator` (:601-614), `ContinuedTranscription` (BGContinuedProcessing, :59-81), `MealPhotoScanner` (:31, :96, :328), `MealEstimatesInBackground` (:27-45, :98-118). All `register` calls happen in `BananaApp.init`. None exist on macOS.
- **Push**: `aps-environment: development` is in the iOS prod entitlements (Banana/Banana.entitlements; project.yml:192-194); not in iOS Beta, not on any Mac target. Used only for a silent CloudKit zone subscription on the Meals zone (`MealBacklogWake`, Banana/Model/MealBacklogWake.swift:35-88; `AppDelegate.swift:22-27, :48-68`).
- **`AppDelegate`** (iOS only, Banana/Model/AppDelegate.swift): background-URLSession completion and remote-notification delivery.
- **`NotificationService`** (Banana/Model/NotificationService.swift): `requestAuthorization()` (:7), per-kind `schedule…` functions that diff against pending requests by id prefix (`banana.event.` :223) and skip unchanged fingerprints (:41-49); `.timeSensitive` (:246). Meal questions have their own delegate/category (`MealPhotoNotifications.register`, BananaApp.swift:118).
- **`NetworkMonitor.shared`** (Banana/Model/NetworkMonitor.swift): `isOnline`, `isExpensive`, `isConstrained`, `isCheap`, `onWiFiAvailable` — a single callback slot, already taken by downloads (BananaApp.swift:673).
- **Launch timing**: `LaunchClock.mark(_:)` (Banana/Model/LaunchClock.swift:29-38) → journal `⏱` lines; snapshots load synchronously before first frame by design (PERF-PLAN.md:338-344).

### For mail this means
- A mail store must be constructible with no side effects and started from `wireUp()` (after its own `whenLoaded()`), so audit routes, snapshot harness and UI tests can show it on fixtures. A singleton that syncs from `init` breaks every preview route.
- Add: a `VisualAuditRoute` flag + `RootView` branch + fixture injector (iOS); `MacDebugSnapshotViews` cases + `injectMacVisualAuditSamples` (Mac). Seed connection state too.
- Background mail refresh on iOS needs a new identifier in BOTH Info.plists (prod and beta) and a `register()` in `BananaApp.init`; follow `CalendarWriteBackRefresh` (re-schedule first, check expiry between steps).
- There is no server and no general push: Gmail's push (`users.watch` → Pub/Sub) has nowhere to land. Freshness = polling in the foreground + opportunistic BGAppRefresh on iOS + a Mac that keeps running.
- `NetworkMonitor.onWiFiAvailable` is single-subscriber; a second consumer needs it widened or its own `$isOnline` subscription.
- First paint: load a small synchronous snapshot (the visible inbox page) before the first frame; everything else async with merge guards.

---

## 8. Sync between the owner's own devices

### Facts
- **Containers**: `AppCloud.containerID` = `iCloud.com.boris.banana` (prod) / `iCloud.com.boris.banana.beta` (beta) (AppSupport.swift:8-15); KVS identifier likewise shared iOS↔Mac per flavour (project.yml:203, :312, :935). Prod pins `icloud-container-environment: Production` (:191). Beta's App IDs are not entitled for the prod container and beta code has no legacy fallback (DEV-CYCLE.md:33-36).
- **No general push**: CKSyncEngine only fetches on push, so each sync has a `CloudZonePoller` (Banana/Model/CloudZonePoller.swift:19-83): own `CKServerChangeToken` per zone in UserDefaults (`tokenKey`, :47-58), `caughtUp` flag (:71-74), `startOver()` (:62-65), `poll()` refuses to run in the iOS background unless `backgroundOK` (:78-85), coalesced by `CoalescingRun`; big zones bootstrap by listing with `desiredKeys: []` (`isStale`, :26-29).
- **`CloudSyncPoll`** (Banana/Model/CloudSyncPoll.swift): `interval = 60` (:14); `resume()` / `pause()`; `checkNow()` asks `CloudChangeCheck.changedZones()` (one database-changes request, CloudChangeCheck.swift:27-48) and refreshes only the syncs whose zone changed or that are not yet `caughtUp` — **a hard-coded list of five syncs** (:36-43).
- **`CloudControlsSync`** (Banana/Model/CloudControlsSync.swift:26-33): two instances — `shared` (zone "Controls") and `meals` (zone "Meals", `backgroundOK`, push-ready). One record per item, record type `"SettingsSnapshot"` with the envelope in `payload` — reused because production's schema already has it; a new record type needs a schema deployment (:38-40). Rules (:11-18): newer *edit* wins by `ControlEnvelope.editedAt`; delete = tombstone record; every device offers what it has once per kind; `adoptsPhoneSet` kinds are the phone's.
  - `enum ControlKind` (Banana/Model/ControlsCloudRecords.swift:8-96): 22 cases; `channel` (:55-60); `adoptsPhoneSet` (:66-71); `recordName(_:)` = `"<kind>-<safeID>"`, ids that are not short plain ASCII are SHA-256 hashed with the original in `ControlEnvelope.key` (:76-85); `parse(_:)` longest-prefix (:89-95) — a kind unknown to an older build parses to nil and is skipped.
  - `ControlEnvelope { editedAt, deleted, item, key, packed }` (:117-152): LZFSE above 16 KB, **900 KB cap per record** (:130-132), `unedited` = epoch 0 for offered items (:128).
  - `ControlMerge.remoteWins(remote:local:)`, `localOnly(local:server:)` (:154-168).
  - `protocol CloudControlSource` (:175-197): `cloudItems(_:)`, `cloudItemIDs(_:)`, `cloudItem(_:id:)`, `applyCloud(_:id:item:) -> Bool` (false = "can't apply yet", retried on `refetchAll`).
  - Stores report edits through `ControlChangeReporter.changed / deleted / offered` (:202-210) — closures that go nowhere in unit tests.
  - Registration in `wireUp` (BananaApp.swift:809-830), `start()` after every source has loaded (:855).
  - Availability: off in the Simulator, with `--disable-icloud`, or without the container entitlement (CloudControlsSync.swift:101-108). State files `cloud-<channel>-sync.plist`, `cloud-<channel>-fields.plist` in AppSupport (:98-99).
- **`CloudWellnessSync`** (zone "Wellness"): record names `meal-<uuid>`, `supplement-<uuid>`, `dose-<supplementUUID>-<yyyyMMdd>` (WellnessCloudRecords.swift:13-28); newest edit wins; only explicit deletes remove; pending deletes remembered until confirmed (CloudWellnessSync.swift:9-17, :46-56). Merge rules are pure and tested.
- **`CloudSettingsSync`** (zone "Settings", ONE record `smart-settings`, own tiny engine; CloudSettingsSync.swift:13-27, :64-68): carries `SmartScheduleStore`'s `CloudSettingsSnapshot` blob (SmartScheduleStore.swift:422; LWW on `settingsUpdatedAt`, single adoption path `adopt`, :1682-1713). Same blob also rides the LAN peer channel and KVS (BananaApp.swift:675-685).
- **`AppSettings`**: one KVS blob under `appSettings`, `Snapshot` with all-optional fields, `applyingRemote` guard (AppSettings.swift:105-120).
- **Other KVS users**: Google account hint, `HubStatus` (`hubStatus.v1`), `HubRequests` (`hubRequests.v1` / `hubRequestsHandled.v1`), wake plan, `GuestPicks` (`guestPicks.v1`, mirrored to UserDefaults; GuestSources.swift:109-131), `ReminderAnchors`, `MealEstimators`, `FoodSearchSources`.
- **`HubStatus` / `HubRequests`** (Banana/Model/HubStatus.swift:14-97): what only the phone does, published for other devices' controls; requests are timestamps the phone acts on once (`pending(after:)`, :90-96), handled on foreground (RootView.swift:277) and at wire-up (BananaApp.swift:691-699).
- **Progress, Fitness**: own engines, manual cadence, big histories — not a model for anything new (owner note `banana-cloud-sync-polling`).
- **`SyncProgress` / `SyncDomain`** (Banana/Model/SyncProgress.swift:5-34): `fitness, wellness, progress, controls, meals` with user-facing titles; drives `SyncWaitingNote` and Settings › iCloud.
- **What Beta does differently**: staging container + staging KVS, iPhone Beta ↔ Mac Beta only; no Watch, no widget; no `aps-environment` (so no Meals push); separate OAuth clients; separate local data. Simulator: all CloudKit off.

### Which mechanism fits which kind of mail state
| State | Fits | Why / limit |
|---|---|---|
| Read, archived, starred, labels, drafts, sent | **None of these — Gmail is the sync** | Each device reads and writes Gmail directly; mirroring into CloudKit creates a second truth |
| Message/thread cache, bodies, attachments, search index | Local only, per device | Size; zone history walks are slow; 900 KB record cap |
| Per-thread Banana-only state with deletes (snooze-until, "remind me if no reply", pins) | A new `ControlKind` in `CloudControlsSync` | Per-item LWW + tombstones exist; id = Gmail thread id (plain ASCII, no hashing needed). Latency: other devices see it within 60 s **only while open**; a closed phone learns of it at next open |
| Lists the person edits (split-inbox rules, snippets, signatures) | A new `ControlKind` (one record per rule) | Same; decide whether it `adoptsPhoneSet` (only for lists every install seeds with defaults) |
| Scalar preferences (default account, undo-send seconds, swipe actions, density) | Fields in `AppSettings` (KVS blob) | Whole-blob last-writer-wins: two devices changing different fields close together lose one |
| "Where am I" (selected split, open thread) | `ShellNavigation` — device-local, not synced | By design |
| Time-critical state that must reach a closed phone (a snooze that should notify on the phone) | Own channel/zone with `backgroundOK` + zone subscription, as `meals` does | Needs push on the App ID; iOS prod only today; nothing on Mac/beta |
| Send-later queue | **No existing mechanism fits** | Needs exactly-once execution by some awake device; `CloudControlsSync` gives LWW records, not a lock (see Open questions) |
| Device status ("Mac last synced mail 2 min ago") | `HubStatus`-style KVS only if needed | Mail has no hub |

### For mail this means
- A new synced kind = one enum case + `channel` + a `CloudControlSource` conformance + one `register` line + `ControlChangeReporter` calls in the store's mutators. No CloudKit schema change.
- A new zone = also a line in `CloudSyncPoll.checkNow()` and a `SyncDomain` case.
- Never fetch "everything again" by resetting an engine or a poller token.
- Design for "another device may be offline for a day": snooze wake-ups must be computed locally on each device from the synced record, not delivered.

---

## 9. Diagnostics and performance guards

### Facts
- **Journal**: `PlaybackDiagnostics.shared.log(_ event:, _ detail:)` (Banana/Model/PlaybackDiagnostics.swift:36-46) appends to `AppSupport.directory/playback.log` on a serial utility queue, capped at 512 KB keeping the newest half (:17-19, :61-70); mirrored to unified logging. Ships in release. Shown in Settings › About › Diagnostics (`PlaybackLogView`).
- **Structured journal**: `DiagnosticJournal.shared` (Shared/DiagnosticsTracing.swift:169): `startSpan(_:parent:attributes:)` (:292), `checkpoint` (:332), `finish` (:371), `record(operation:parent:name:attributes:)` (:412), process-death recovery of unfinished spans (:239-), bounded `events.ndjson` + `active-spans.json`, directory excluded from backup (:586-599). Privacy rule: identifiers and state, never titles / contact info / content (docs/DIAGNOSTICS.md:67-74).
- **`PerfWatchdog`** (Banana/Model/PerfWatchdog.swift:107-327): samples process CPU every 15 s in the foreground on iOS, 30 s while playing in the background, 60 s otherwise, 20 s on the Mac, 5 s with `--perf-trace` (:305-327). Each tick drains `RenderStats`.
  - **STORM** = any counted name at **≥ 2 per second** averaged over the sample (`stormRate`, :120; :261-284) → `🌀 STORM: <name> at N/s` in the journal + a `publisher_storm` record. Publisher sources (names ending `↻`) are preferred as the named cause (:268-269).
  - **HIGH CPU** = ≥ 25 % over the sample (:110, :286-298).
  - Counted publishers: `OccurrenceStore`, `WeatherStore`, `RoutineStore`, `FitnessStore` (:151-159), on iOS also connectivity, library, player, music, downloads, backup (:160-174), late sinks for alarms / smart / onboarding / settings (`registerLateSinks`, :211-218, called at BananaApp.swift:626).
  - A minute-level power rollup line (CPU avg/max, memory, wakeups, thermal) (:420-458).
- **`RenderStats.note("ViewName")`** as the first line of a body (`let _ = RenderStats.note("RootView")`, RootView.swift:55); used by 15 views (WeekView.swift:379 "MacWeekView", :2997 "WeekView", PlannerTab.swift:67, TodayView.swift:256, PodcastsView.swift:17, …). `RenderStats.lifetimeCount` backs UI-test render probes (RootView.swift:571-587).
- **`Signpost.begin(_:) / end(_:)`** (Banana/Model/Signpost.swift:13-32): `os_signpost` interval + `PowerTrace` so the name shows in the minute rollup.
- **`MemoryLog`** (Banana/Model/MemoryLog.swift): `footprintMB()`; periodic logging only with `--memory-trace` (BananaApp.swift:904-906).
- **`Metrics.start()`** (iOS, BananaApp.swift:139): MetricKit crash/hang/CPU-limit diagnostics into the journal; stack JSON files in AppSupport.
- **`LaunchClock`**, **`FrameProbe`** (`--frame-probe`, BananaApp.swift:141-147), `--storm-selftest`, `--perf-trace`, `--library-publish-regression` (:150-172).
- **Budgets** (docs/PERF-PLAN.md:367-380): background playback ≤ ~2 % CPU, 0 UI body evals, 0 storms; foreground browsing "body evals ∝ interactions; no 2/s storms"; unlock → Today no main-thread I/O > 50 ms. **Protected pattern** (:382-390): "publish at the rate of meaning, not the rate of I/O" — `PlaybackClock`, `LiveProgress`, the download `ProgressTicker`: a narrow leaf observable for anything that ticks.
- **Shell rules already in code**: shells do not observe busy stores (RootView.swift:12-27); heavy subtrees are `Equatable` with `.equatable()` (`PlannerTab`, RootView.swift:407; PlannerTab.swift:64); presenters that must watch chatty stores are zero-size sibling views (`WorkoutReviewPresenter`, RootView.swift:525-566; `MacPayoffPresenter`, MacRootView.swift:407-491); Settings pages are type-erased per page to keep Release stack frames small (SettingsView.swift:305-315).
- **Lessons recorded** (owner notes, verified where they name code):
  - A SwiftUI render loop in a background-audio app is a `cpu_resource_fatal` kill; the root blank gate stays (`AppVisibility`, RootView.swift:336-349).
  - Preference values must be quantised and every `onPreferenceChange` write equality-guarded (PERF-PLAN.md:96-105).
  - A dotted `@AppStorage` key in a hot view re-rendered it 5–7×/s forever (owner note; dotted keys still exist in SettingsView.swift:129-131 — a cold view).
  - Giant view types overflow the 1 MB iOS main-thread stack in Release only; check with `ScreensOpenUITest` on a device.
  - WebKit's HTML importer in a view body froze the app (three `0x8BADF00D` kills) → `ShowNotes`.
  - `withTaskGroup` inside `@MainActor` service code returned zero results once; the service uses `Task.detached` per request and awaits `.value` (GoogleCalendarService.swift:780-794, :950-962). Remaining task-group sites: Intelligence.swift:260, FoodTextExtractor, WeatherStore.
  - Never gate a hosted/cached view on a hand-kept "content token"; refresh display caches when the source changes.
  - A `.simultaneousGesture(DragGesture)` blocks the enclosing ScrollView on iOS 26 (swipe actions on rows need care).
  - Decode thousands of items off the main actor; a calendar read once held the app for seconds (GoogleCalendarService.swift:593-605).

### What a hot mail list must do
- Keep the mail store's publishes sparse: one publish per sync batch, never per message; progress counters in a leaf observable. A store publishing ≥ 2/s for a 15-s window is a logged STORM whether or not anything draws.
- Keep keyboard selection (held `j`/`k` repeats far above 2/s) in a leaf observable read by rows, not in state that re-evaluates the list container — and only add `RenderStats.note` to bodies where a sustained re-render really is a bug.
- Register the mail store with `PerfWatchdog` (a `mail↻` sink) so a future storm names itself.
- Wrap sync passes, index writes and body parses in `Signpost`; log one journal line per pass (`✉️ …` with counts and ms, no subjects or addresses).
- No main-thread I/O: SQLite reads for the visible page, HTML → text, MIME decoding and JSON decoding all off-main; only the first-paint snapshot may be synchronous and it must be small.
- No timers in the background on iOS; polling follows `CloudSyncPoll` (pause on `.background`).
- Split the row and the section into small view types (Release stack depth), and re-verify in Release on a device.
- Nothing un-quantised into a `PreferenceKey` (scroll offsets for "new mail" pills, sticky headers).

---

## 10. Tests

### Facts
- **`BananaTests`** (project.yml:341-699): iOS unit-test bundle with **no dependency on the app target**. Sources = the whole `BananaTests/` folder (:345) **plus each model file listed individually** (:352-695). New test files are picked up automatically; every new model file a test needs must be added to the list (then `xcodegen generate`). Never `@testable import Banana` — tests compile the listed sources directly (`import XCTest` only). A listed file drags in everything it references, hence the many "split out so the test target doesn't pull in X" comments (:346-351, :523-528, :545-549, :652-659). Files that `import GoogleSignIn`, CloudKit-heavy stores, `CloudBackup`, `HealthKitStore`, `WellnessStore` are deliberately out.
- Already listed and reusable from mail tests: `SnapshotPersistence`, `AppSupport`, `ToastCenter`, `ShellNavigation`, `AppSection`, `DeviceRole`, `AppVisibility`, `BananaDesign`, `GoogleTokenMinter`, `GoogleRequestRouting`, `GoogleEventSync`, `GoogleCalendarModels`, `ControlsCloudRecords`, `CoalescingRun`, `SyncProgress`, `PendingRemovals`, `ShowNotes`, `Intelligence`, `GuestDirectory`, `EventPhrase`, `MeetingLinkDetection`, `FlightParser`, `CommandMenuDateParser`, `FoodDatabase` (+ both bundled `.sqlite` as resources, :555, :668).
- **Style**: one `final class <Thing>Tests: XCTestCase` per rule file, a doc comment stating what failure matters; test names are sentences (`testAnUnrelatedReadDoesNotRetireAPlaceholder`, `testANewDaysWindowIsReadInFull`, `testTheNextEditCommitsThePreviousDelete`); small private builders that decode JSON literals into the real model (`GoogleEventSyncTests.event(…)`, :5-12); fixed `Date(timeIntervalSince1970:)` instants and injected `now:`; assertion messages explain the consequence. Real captured API responses as JSON fixtures listed as resources (project.yml:558-568); SQLite fixtures in `BananaTests/Fixtures/` built by the same script as the shipped DB (`tools/build_food_database.py --fixture`).
- **Temp directories**: `FileManager.default.temporaryDirectory.appendingPathComponent("<name>-\(UUID().uuidString)")` with `defer { try? removeItem }` (GoogleEventSyncTests.swift:104-106) or `setUp`/`tearDown` (MyFoodsStoreTests.swift:9-16, RepeatPhotoMealTests.swift:190-194); `UserDefaults(suiteName:)` for defaults-backed state (ShellNavigationTests.swift:14-22). Tests must never touch the real `AppSupport.directory` (BarcodeProductLookup.swift:969).
- Statics exposed as `var` "so tests can shorten it": `ToastCenter.window`, `AppVisibility.snapshotGrace`.
- Live-model tests exist but need a device (`GroundedEstimateLiveTests`); model calls never run in the unit target.
- **`BananaUITests`** (project.yml:328-339; 34 files): launch the real app with launch arguments, typically `[<route>, "--disable-icloud", "--ui-audit", "-onboardingCompleted", "YES"]` (e.g. `["--week", "--disable-icloud", "--ui-audit", "-onboardingCompleted", "YES"]`); `-onboardingCompleted YES` is a UserDefaults argument-domain override of `OnboardingStore`'s key (OnboardingStore.swift:27). Whole-shell tests use `["--ui-preview", "--dummy-health"]` (AdaptiveShellUITest.swift:9). Assertions go through accessibility identifiers (`toast.undo`, `event.sync.failed`, `settings.accounts`, `mobile.week.newEvent`) and labels; screenshots are attached with `.keepAlways`. Tests read positions, not device types. Tests that cannot run on a Simulator `XCTSkip`.
- **Unsigned-Simulator CloudKit trap**: a launch that is not a `VisualAuditRoute` runs `wireUp()` → `CloudSettingsSync.startIfPossible()` → `CKContainer` → trap, unless `--disable-icloud` is passed (CloudSettingsSync.swift:42-48). Tests that launch with only `-onboardingCompleted` are the known casualties (owner note `banana-ui-test-and-gesture-gotchas`).
- Leftover Simulator state leaks between UI tests (restored sheets from `ShellNavigation`, fixtures pushing rows below the fold; lazy lists have no off-screen elements — swipe until `isHittable`).
- **SwiftPM** (`Package.swift`): only the performance infrastructure; `swift test` runs `PerfControlCoreTests` (incl. `DiagnosticJournalTests`), not BananaTests.

### Commands
```sh
xcodegen generate                                   # after any project.yml change (README.md:34)

# builds (docs/DIAGNOSTICS.md:88-92)
swift test
xcodebuild -project Banana.xcodeproj -scheme Banana \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Banana.xcodeproj -scheme BananaMac \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build

# Simulator build + launch a route (docs/design/VERIFICATION-RESULTS.md:14-18; owner note banana-build-verify-loop)
xcodebuild -scheme Banana -destination "id=<SIM>" -configuration Debug CODE_SIGNING_ALLOWED=NO build
xcrun simctl install <SIM> <app>
xcrun simctl launch <SIM> com.boris.banana <route-arg> --disable-icloud
xcrun simctl io <SIM> screenshot <png>

# UI tests on a device (docs/HANDOVER_DAY_VIEW.md:595-605; owner note banana-release-builds-on-device)
xcodebuild -project Banana.xcodeproj -scheme Banana -destination 'id=<device>' \
  -derivedDataPath .build/<name> -parallel-testing-enabled NO \
  -only-testing:BananaUITests/<Class>/<test> test

# installs (docs/DEV-CYCLE.md:25-31) — beta by default; prod prompts
tools/ios-install.sh beta [device-id]      # Release unless CONFIG=Debug
tools/mac-install.sh beta
```
- The `Banana` scheme's test action runs `BananaTests` + `BananaUITests`, Debug (project.yml:10-19). **INFERRED** (no doc spells it out): unit tests alone = `xcodebuild test -project Banana.xcodeproj -scheme Banana -destination 'platform=iOS Simulator,id=<SIM>' -only-testing:BananaTests CODE_SIGNING_ALLOWED=NO`.
- Judge a build by `BUILD SUCCEEDED` without `-quiet` (owner note); guard concurrent builds with `pgrep -x xcodebuild`. Use a private `-derivedDataPath` under `.build/` (git-ignored).
- Mac visual check: `"<app>/Contents/MacOS/Banana" --snapshot-app-store <png> --snapshot-view <name>` or `--ui-audit --mac-section <section>` + `screencapture -l <windowid>`; never whole-screen `screencapture` (DEV-CYCLE.md:47-48).

### For mail this means
- Decide the pure/impure file split first: every rule a test should pin (history application, own-write echo, outbox state machine, snooze merge, split-rule matching, MIME/HTML → text, search-query parsing) goes in a Foundation-only file listed in `project.yml`; transport and SDK stay out.
- A SQLite-backed store is testable in the unit target (SQLite3 links there already) if it takes its path as a parameter.
- Capture real Gmail API JSON as fixtures; never hit the network in tests.
- Every mail screen needs a launch-argument route that lands directly on it with fixtures (simctl cannot tap), added to `VisualAuditRoute`.
- AGENTS.md (repo-level instruction): "Always write tests for changed behavior."

---

## 11. Things mail can reuse directly

| Piece | Where | Signature / notes |
|---|---|---|
| People ranking ("the ones you meet most first", commit a015abc) | `Banana/Model/GuestDirectory.swift` (pure, in tests) | `struct GuestPerson { email, name, met, lastMet, inContacts; isFavorite }` (:5-27); `merged(calendar:contacts:)` (:40-54); `fromEvents(_:own:)` (:58-74); `isPerson(_:)` filters rooms/groups/no-reply (:77-83); `quality(_:_:) -> Int` (:89-105); `matches(_:in:picks:)` (:109-123); `best(_:in:picks:)` (:128-140); `names(in:)`, `emails(in:)` (:146-166) |
| People sources | `Banana/Model/GuestSources.swift` | `people() async` (:11-18) = calendar guests read from `GoogleEventDiskCache` off-main (:37-62) + Contacts when already allowed (:66-103); `requestContactsIfNeeded()` (:78-85); DEBUG `--guest-fixtures` (:23-31). `GuestPicks` remembers which address a typed name meant, in KVS (:109-131). `NSContactsUsageDescription` exists on every target (project.yml:164, :294, :836, :917) — worded for event guests |
| Guest UI | `GuestAvatar` (TodayView.swift:2726) | private-ish view in a 2,744-line file |
| Meeting links | `Banana/Model/MeetingLinkDetection.swift` (pure, in tests) | `MeetingPlatform.classify(_:)` (:43), `mayNameAPlatform(_:)` (:78), `MeetingLink.detect(location:notes:url:) -> (platform, url)?` (:94), `joinRank`, `isAsset`, `isUtilityPage`, `hasJoinShapedPath` (:148-186), memoised (`DetectionMemo`, :241). Join button views in `MeetingLink.swift` |
| Flights | `Banana/Model/FlightParser.swift` + `AirportTable.swift` (in tests) | `FlightParser.parse(title:location:notes:) -> Result?` (:51) — tuned to calendar-event text, airports from a bundled table |
| Natural-language event entry | `Banana/Model/EventPhrase.swift` (in tests) | `EventPhrase.parse(_:now:calendar:defaultDuration:) -> Draft` (:33-); dates always by `NSDataDetector`, the model only labels words (:8-13, model call :212). Feeds `OccurrenceStore.createCalendarEventOptimistically` |
| Date words | `Banana/Model/CommandMenuDateParser.swift` | `date(in:now:calendar:) -> Date?` ("next friday", "oct 12") — usable for snooze / send-later entry |
| Language model | `Banana/Model/Intelligence.swift` (pure routing in tests) | Apple **FoundationModels**. `Intelligence.Need { structuring, knowledge, vision }`, `Route { cloud, device, none }`, `route(_:given:)` (:66-91), `current: Availability` (:126-147), `session(for:instructions:tools:availability:) -> (LanguageModelSession, Route)?` (:175-195), `promptCharacterBudget(for:)` (:226-229; device window 4,096 tokens, cloud 32K), `withTimeout(seconds:route:operation:)` (:242-246), `privacyNote` (:105-116). Cloud = `PrivateCloudComputeLanguageModel` on OS 27, **disabled in every build** (`BananaPrivateCloudCompute: false`, project.yml:160, :284, :840, :914; `CloudModelGuard`, :288-328). Every caller has a non-model fallback. Measured: on-device answer ≈ 7 s on a Mac (FUTURE.md:37-38) |
| Assistant with tools | `Banana/Model/BananaAssistantStore.swift` | `LanguageModelSession(tools: [AssistantNextTool, …])` (:112-128); "the model can read and propose; Swift owns every mutation" (:7-8) |
| HTML → text | `Banana/Model/ShowNotes.swift` (pure, in tests) | `ShowNotes.attributed(_ html:) -> AttributedString?` (:11-57): regex tag walk; keeps paragraphs, breaks, list bullets, links (`http/https/mailto` only, :60-66); drops script/style and everything else; decodes entities; data-detects bare links. Called off-main (`Task.detached`, PodcastDetailView.swift:882, NowPlayingView.swift:442) |
| Web view | — | **None.** No `WKWebView`, no `import WebKit`, no `SFSafariViewController` anywhere (grep) |
| Link opening | `@Environment(\.openURL)` (MeetingLink.swift:13, EventDetailView.swift:18, …); `NSWorkspace.shared.open` (Mac) | external browser only; `AttributedString` links open through the environment |
| Sharing | `ShareLink(item: String)` (NotesView.swift:152, AvailabilitySheet.swift:133, PlaybackLogView.swift:59) | text only. No `UIActivityViewController`, no QuickLook, no `fileImporter/exporter`, no document picker, no drag-and-drop of files |
| Photo picking | `PhotosPicker` (MealBacklogViews.swift:577, ScanCorrectionSheet.swift:229) | the only attachment-like input |
| Images | `ImageCache.shared` (§3) | unauthenticated URLs, downsampled |
| Clipboard | `Clipboard.copy(_:)` (Mac, PlatformShim.swift:55-62) | |
| Cross-platform shims | `PlatformShim.swift`, `MacStubs.swift` | `UIImage = NSImage`, system colour names, `navigationBarTitleDisplayMode` no-op on Mac |
| Calendar from mail | `OccurrenceStore.createCalendarEventOptimistically(input:calendarID:)` (OccurrenceStore.swift:1156), `GoogleCalendarService.respond(to:with:)` (:1452), `InvitationReply` | accept an invitation or make an event straight from a message |
| Availability text | `AvailabilityFinder` + `AvailabilitySheet` / `MacAvailabilityPanel` | "share availability" → paste into a reply (already ⌘C on Mac) |
| Notifications | `NotificationService` diff-and-fingerprint pattern; time-sensitive entitlement on all app targets | |
| Diagnostics | §9 | |

### For mail this means
- Recipient autocomplete can start from `GuestSources.people()` + `GuestDirectory.matches`, but the corpus is calendar guests and Contacts; mail correspondents (the better signal) are a new source to merge in, and `met` / `isFavorite` are meeting counts.
- `ShowNotes` is a plain-text extractor: no CSS, images, tables, quoted-reply collapsing or remote-content blocking. Faithful HTML mail needs a web view — the app's first — with the off-main / never-in-a-body lesson applied; `ShowNotes` remains useful for snippets, search text and notifications.
- On-device model: a 4K-token window and seconds per answer rule it out of the hot path; route through `Intelligence.session` and keep a deterministic fallback. Privacy copy must come from `Intelligence.privacyNote`.
- Attachments (download, preview, save, share, attach from Files, drag in) have no precedent at all.

---

## 12. Settings

### Facts — `Banana/Views/SettingsView.swift` (1,689 lines)
- **Pages**: `enum SettingsPage: String, Hashable, CaseIterable { accounts, calendar, travel, wake, podcasts, workouts, watch, icloud, permissions, about }` with `title`, `symbol`, `tint` (:259-303).
- **Phone root** (`phoneBody`, :216-251): `Form` of `accountSection` (:408-432), `featuresSection` (:448-456: Calendar, Travel, Wake & bedtime, Podcasts, Workouts — each `featureRow(page, value:)` showing a current value), `generalSection` (:475-484: Apple Watch, iCloud, Compare speech engines, Permissions "N off"), `aboutSection` (:486-490); `.searchable`. `featureRow` / `settingsRow` (:492-510) = `IconTile` · title · trailing value.
- **Mac** (`macBody`, :148-205): its own 240-pt page list inside the section (search field, account row, "Features" = calendar/travel/wake/podcasts/workouts (:176), "General" = icloud/permissions (:179), about) and a `NavigationStack` for the chosen page; `macPage` is `@State` (:144).
- **Page content**: `page(_:) -> AnyView` (:309-315) and `pageSections(_:) -> AnyView` (:326-374) — **type-erased on purpose** (Release stack overflow, :305-308). Each page is a `Group` of section properties.
- **Search index**: hand-kept `static let searchIndex: [SettingsSearchEntry]` (title, page, keywords; :24-59), matched by substring (:16-20); results open the page (:376-395).
- **Google account cards**: `googleCalendarSection` (:732-916) — per account: 32-pt initial avatar, email, `StatusDot` + word, "Sign in" when broken, ••• menu (Reconnect, Disconnect), swipe actions (:738-807); then "Add another Google account" (`settings.addGoogleAccount`, :813-822), "Refresh Google calendars" (:823-831), per-account and all-accounts disconnect confirmations that say "on every device" (:832-872); not-connected state with the cross-device hint (:873-897); working / error lines (:899-910); footer copy describing calendar access only (:913-915). Followed by `calendarCoverageSection` (:917-) with links to All-day events, Calendar colours, Calendar diagnostics (:932).
- **Permissions page**: `permissionsSection` (:1489-1549) — `permissionRow(title:icon:granted:detail:blocked:settings:connect:)` (:1570-1617) for Google Calendar, Reminders, Health (hub only), Location, Notifications, Apple Music, Alarms (hub, iOS). A Connect that comes back without a grant flips to "Open Settings" + a toast (:1601-1612). `permissionGranted(_:)` is a `switch` on the row **title string** (:1629-1638). Non-hub devices also show `phoneStatusSection` from `HubStatus` (:1555-1568). The "N off" count is `missingPermissions` (:458-468).
- **Sync status**: `SyncStatusSection()` on the iCloud page (:361; SyncStatusViews.swift:43-58), one row per `SyncDomain`.
- **How settings are stored/synced**: `AppSettings` (`@EnvironmentObject`, KVS blob — §8) for app prefs; `SmartScheduleStore.settings` (`CloudSettingsSnapshot`: LAN peer + CloudKit "Settings" zone + KVS) for schedule/calendar/travel prefs; `CalendarWriteBack` choices bound to the synced settings (BananaApp.swift:687); a few **device-local** `@AppStorage` values (`durStyle`, transcription engine, `menuBarAgenda.enabled`, trip time zone; :113-115, :129-131). Rule: every control on every device, synced; only the doing is the hub's (ADAPTIVE-LAYOUT.md:26-32).
- **Onboarding**: welcome → Google Calendar → done (FUTURE.md:138-139); the Mac has a hard calendar gate (`MacCalendarOnboardingView`, MacRootView.swift:99-250).

### Where a "Mail" page slots in
- A `SettingsPage.mail` case (title, symbol, tint → needs a `DS.Palette.Feature` colour), a `featureRow(.mail, value:)` in `featuresSection` (:448-456) and in the Mac list (:176), a `case .mail:` in `pageSections` (:326-374), entries in `searchIndex` (:24-59), and `ScreensOpenUITest.settingsPages` (:11-12).
- Per-account "Mail on/off" and "grant Mail access" belong on the account card in `googleCalendarSection` (the reserved "per-service toggles"); the section header/footer and the root row's status word are calendar-worded today ("Google Calendar", "Live · N calendars", "Connect Google Calendar", :434-446, :912-915).
- A "Gmail" row on the Permissions page needs a `granted` source and a branch in `permissionGranted` (string-keyed).
- A `SyncDomain`-style status line if mail sync state should appear under Settings › iCloud — or its own section, since mail does not sync through iCloud.

### For mail this means
- Settings are added in five hand-kept places (enum, root row, Mac list, page switch, search index) plus one UI test list.
- Keep each page's sections type-erased; do not grow one giant view type.
- Synced mail prefs go into `AppSettings.Snapshot` as optional fields; device-local ones use dot-free `@AppStorage` keys.
- The account surface is calendar-first in copy and in status; it needs rewording once an account carries two services.

---

## Open questions the code does not answer

1. **Google Cloud side.** Is the Gmail API enabled, and are Gmail scopes on the OAuth consent screen, for both projects (prod and beta)? Gmail read/modify/send scopes are Google "restricted" scopes (general Google policy, not from this repo); an app whose consent screen is in "Testing" issues refresh tokens that die after 7 days — the owner's notes already suspect that for `<account>` (`invalid_grant: Token has been expired or revoked`, unverified). Which accounts are Workspace (`<account>`, `<account>`, `<account>`) and which consumer changes the answer.
2. **Which scopes.** `gmail.modify` (+ `gmail.send`?) vs full `mail.google.com`; whether `gmail.settings.basic` (signatures, send-as aliases) is wanted.
3. **Do old refresh tokens gain the new scope?** After an incremental grant, does a refresh token issued earlier (still held by another running device) mint tokens that include Gmail? Unknown here; the code can only tell by `grantedScopes` on the stored credential or by a 403.
4. **iPhone seat.** Which of the five tabs gives way, or does Mail live under another tab's home on iPhone? The IA record forbids a sixth and names no seat.
5. **App-icon badge.** Should unread mail count toward `ActionItems.Counts.total` (app icon / Dock)?
6. **Push.** Is the Push capability actually enabled on the `com.boris.banana` App ID (the entitlement file says `aps-environment: development`; `MealBacklogWake` logs "not available" when registration fails)? No Mac or beta build carries it. No server exists to receive Gmail `watch` Pub/Sub pushes.
7. **Send later / snooze wake-ups with no server.** Which device sends a scheduled message, and what prevents two devices sending it? Nothing in the repo provides a cross-device lock; there is no always-on host (the Mac comes closest: it keeps polling in the background).
8. **Mac gate.** `MacGatedRootView` blocks the whole app until Google Calendar is connected; should a mail-only account pass it?
9. **Storage engine.** Raw SQLite3 (precedent: read-only only) vs adding a dependency (none exist for storage); how big the local mirror may grow; whether the cache directory is excluded from device backup.
10. **HTML rendering.** A web view (first in the app) vs. extending `ShowNotes`; remote-image policy; dark-mode treatment.
11. **Notifications.** Which device notifies for new mail when there is no push; whether mail notifications are time-sensitive.
12. **Density.** The design system's 44-pt row minimum vs a Superhuman-density list on the Mac.
13. **Calendar ↔ mail accounts.** Is Mail per connected account by default, or opt-in per account (calendar-only accounts exist, e.g. shared family calendars)?
14. **Beta data.** Beta shares nothing with prod but talks to the same real Gmail — sends, archives and label changes made while testing are real (same caveat MAC-VARIANTS.md:36-41 gives for calendars).
15. **`.build/mail-dd`** exists in this worktree — someone is already building here; coordinate derived-data paths.

---

## Traps

Things that go wrong silently if general iOS practice is followed instead of this repo's rules.

**Auth**
- Calling `GIDGoogleUser.addScopes` — fails (`MismatchWithCurrentUser`) or acts on the wrong account, because Banana's accounts are not the SDK's `currentUser`.
- Reading `GIDSignIn.sharedInstance.currentUser` for "who is signed in" or letting the SDK refresh tokens — it knows one account, per device.
- Adding a non-optional field to `GoogleAccountCredential`: synthesized `Decodable` throws on stored items that lack it, `read` returns nil, `load()` returns `[]` — every account appears disconnected and the next save overwrites the synced keychain item on every device.
- Making the Gmail scope part of `requiredScopes`: a person who declines Mail can no longer connect Calendar.
- Dropping an account whose Gmail call fails. The rule is mark, never remove (the synced store re-adds it and it flaps); and a failed read is never evidence of emptiness.
- Deriving the account from the URL (works for calendar ids, not for `/gmail/v1/users/me`), or defaulting to `accounts.first`.
- Expecting a scope upgrade on the Mac to reach a running phone: `adoptAccountsFromStore` ignores changed credentials for known ids.
- Trusting the comments at GoogleCalendarService.swift:248-249 and :1728-1729 ("tokens stay device-local"): in prod they sync through iCloud Keychain; "Disconnect" removes the account on every device.
- A second `URLSession`/`URLCache` path for Google: reads after writes must use `.reloadIgnoringLocalCacheData`.

**Offline / optimistic**
- Blocking a sheet, a button or a key press on a network write. Show the result, reconcile, toast on failure.
- Awaiting `ToastCenter.deferRemoval` inline: it awaits the previous commit's network call.
- Un-hiding an item when the request returns rather than after the store has re-read (it flashes back).
- Treating `ToastCenter.hiddenIDs` / `PendingEventEditStore` as durable — both are memory-only. Only `PendingCalendarWriteStore` survives a kill, and nothing retries it automatically.
- Baking optimistic state into a first-paint snapshot (it returns after relaunch looking real).
- Counting your own writes as news and re-syncing after every action.
- A hand-kept "content token" deciding when a cached/hosted list refreshes.

**Persistence**
- `FileManager…applicationSupportDirectory` directly instead of `AppSupport.directory` (beta would read and write prod's files on the Mac). One existing offender: `CloudModelGuard` (Intelligence.swift:294-296).
- `try? JSONDecoder().decode` then save: one new field or one bad record empties the store and the next save makes it permanent. Use `SnapshotLoader`, `LossyArray`, `decodeIfPresent`, and refuse to save if quarantine failed.
- Caches in `Caches/` for anything offline-first; large caches in AppSupport without `isExcludedFromBackup`; state in UserDefaults (it is copied into the iCloud backup snapshot wholesale).
- Sharing one SQLite handle across threads on the existing `NOMUTEX` pattern.
- Constructing `CKContainer` unguarded (traps on an unsigned Simulator build and can kill an unentitled Mac build).

**UI / lifecycle**
- Navigation, selection, the open thread or a draft in `@State`: iOS discards the whole tree 2.5 s after backgrounding; the Mac rebuilds the section when the sidebar leaves it.
- `NavigationLink { destination }` instead of value-based pushes with the path in `ShellNavigation`.
- `@Environment(\.scenePhase)` inside a `Tab {}` content closure — stale there; use `AppVisibility.shared`.
- Treating `.inactive` as "backgrounded".
- Observing a chatty store from `RootView` / `MacRootView` (`@EnvironmentObject` on the shell rebuilds every tab).
- A dotted `@AppStorage` key in a hot view.
- Un-quantised values in a `PreferenceKey`, or `onPreferenceChange` without an equality guard.
- `#if os(iOS)` to mean "the iPhone" (true on iPad), or `UIDevice.userInterfaceIdiom` for layout (use `layoutClass`).
- `.tabPlacement(.sidebarOnly)` without the `showsSidebarSections` guard → a "More" tab on iPhone.
- A sixth iPhone tab.
- `.toastHost()` on the `TabView` instead of each tab; a feature-local toast or an "Are you sure?" for something undoable.
- Adding a tenth numbered Mac section: `Character(String(index + 1))` traps on "10" (MacRootView.swift:523).
- `.tag(section)` followed by `.badge` on Mac sidebar rows (the badge hid the tag; rows are selected by id now).
- SwiftUI `MenuBarExtra` (hung the Mac app at launch) — AppKit `NSStatusItem` after launch.
- `.inspector` for a Mac side pane (splits the toolbar, clips content).
- Adding single-key mail shortcuts to `MacKeyMonitor` as it stands: the existing keys are global and navigate to Plan.
- `.simultaneousGesture(DragGesture)` on a row inside a `ScrollView` on iOS 26 (kills scrolling).
- One enormous view type (Settings-style `switch` of concrete views): fine in Debug/Simulator/Mac, stack overflow in Release on a phone.
- HTML through `NSAttributedString(.html)` / WebKit import on the main thread or in a body.
- Model or parse work in a view body; thousands of rows decoded on the main actor.
- `withTaskGroup` in `@MainActor` code without a live check that results arrive; prefer `Task.detached` + `await .value`.

**Sync between devices**
- Expecting CKSyncEngine to fetch other devices' changes (no push → it does not); a new zone must register a `CloudZonePoller` and be added to `CloudSyncPoll.checkNow()`.
- "Reset and refetch everything" as a repair (walks months of history).
- A new CloudKit record type (needs a production schema deployment) instead of `"SettingsSnapshot"` + `payload`.
- Removing a record to delete (deletes are tombstones with a time) or treating "missing in the cloud" as deleted.
- Seeding a sync from a store that has not finished loading (an empty list mid-decode is not the truth) — await `whenLoaded()`.
- Hiding or disabling a control because the device is not the hub; assuming the phone is awake to act.
- Polling big zones in the iOS background.

**Process**
- A preview/route flag not added to `VisualAuditRoute` → production graph starts → Simulator crash.
- A mail store that starts network work in `init` (previews, snapshots and UI tests all construct the graph).
- `@testable import Banana`; forgetting to list a new model file under `BananaTests` in `project.yml`; editing the generated `.xcodeproj`.
- A new BG task identifier in one Info.plist but not the beta's (silently never scheduled); registering after launch finished; registering the same identifier twice (kills the app).
- Judging a build by `xcodebuild -quiet`; `pgrep -f "xcodebuild.*Banana"` as a guard (matches itself).
- `devicectl device uninstall`, installing to a production device unasked, whole-screen `screencapture`, `git --no-optional-locks`.
- Testing mail in Beta as if it were sandboxed: it is isolated from Banana's data, not from the real mailbox.
- Logging subjects, senders or snippets to the diagnostic journal (the stated rule is identifiers and state only — though `playback.log` already carries event titles, GoogleCalendarService.swift:653-656).

---

## Where docs / notes and code disagree

| Claim | Where | Code says |
|---|---|---|
| "No push entitlement / profiles have no `aps-environment`" | owner notes `banana-cloud-sync-polling`, `banana-adaptive-layout-ipad`; ADAPTIVE-LAYOUT.md:124-125 lists it as "Next" | iOS prod has `aps-environment: development` (Banana/Banana.entitlements; project.yml:192-194) and a Meals-zone push path (`MealBacklogWake`, `AppDelegate`). Still none on Mac or beta; whether the App ID has the capability is not visible |
| "Beta has EMPTY entitlements → no iCloud" | owner note `banana-prod-beta-variants` | Both betas carry the staging container + KVS (BananaBeta.entitlements, BananaMacBeta.entitlements); DEV-CYCLE.md:33-38 and MAC-VARIANTS.md:30-32 agree with the code |
| Google credentials stay per device; only the email hint syncs | MAC-VARIANTS.md:33-34; GoogleCalendarService.swift:248-249, :1728-1729 | `GoogleAccountStore` writes a `kSecAttrSynchronizable` item (GoogleAccountStore.swift:24-27, :50-56); Settings copy says "on every device" (SettingsView.swift:839, :848). True only for betas |
| Mac sidebar "Plan ⌘1 · Workouts ⌘2 · Notes ⌘3 · Routines ⌘4 · Library ⌘5 · Settings"; Nutrition hidden behind `#if DEBUG` | IA-2026-09.md:43-51 | `macSidebar = allCases`: Plan, Workouts, Sleep, Trends, Nutrition, Notes, Routines, Library, Settings → ⌘1…⌘8 (AppSection.swift:8, :54, :65) |
| `SmartScheduleStore.createCalendarEventOptimistically` | owner note `optimistic-ui-writes` | It is `OccurrenceStore.createCalendarEventOptimistically` (OccurrenceStore.swift:1156) |
| Mac prod bundle id `com.boris.banana.mac` | MAC-VARIANTS.md:8 (table) | `com.boris.banana` (project.yml:856; the same doc's later section and DEV-CYCLE.md:19 say so) |
| Diagnostics live under `Documents/Diagnostics` | DIAGNOSTICS.md:8-9 | `Application Support/<bundle id>/Diagnostics` (DiagnosticsTracing.swift:601-610); `playback.log` in `AppSupport.directory` |
| "ALL local persistence goes through `AppSupport.directory`" | MAC-VARIANTS.md:26; owner note | `CloudModelGuard` and `DiagnosticJournal` use the raw directory; `ImageCache` and weather use `Caches/` |
| `DS.Row` and `calendarTint(hex)` as design-system primitives; account card with per-service toggles and Resync | DESIGN-SYSTEM.md:55-66, :33 | `DS.Row` is sizes only; `calendarTint` is in TodayView.swift:2116; the card has Reconnect/Disconnect and no toggles |
| `AppSection.iOSTabs` picks the phone's tabs | AppSection.swift:5-6 (comment) | Used only by tests; tabs are hand-listed in `RootView.mainTabs` |
| `PerfWatchdog.registerLateSinks` "NOT YET CALLED" | PerfWatchdog.swift:204-210 | Called at BananaApp.swift:626 |
| Background refresh uses "whatever access token `GIDSignIn` has cached" | CalendarWriteBackRefresh.swift:67-69 | Tokens are minted by `GoogleTokenMinter` from the stored refresh token |
| `xcodebuild -quiet` reports fake errors — never use it | owner note `banana-build-verify-loop` | Both install scripts build with `-quiet` (tools/ios-install.sh:69-71, tools/mac-install.sh:34-36) |
| Chat assistant: "Nothing built" | docs/design/CHAT-ASSISTANT-PLAN.md:3 | `BananaAssistantStore` + `BananaAssistantView` exist |
| The hub "writes the calendar holds" | ADAPTIVE-LAYOUT.md:22-23; DeviceRole.swift:32-33 | Every device writes busy blocks (ADAPTIVE-LAYOUT.md:98-102; DeviceRole.swift:6-7) |
| `EpisodeInfoSheet.formattedSummary` | owner notes | Gone; the sheet uses `ShowNotes.attributed` off-main (PodcastDetailView.swift:837-882) |
| README: "2 targets" | README.md:140 | Nine targets |
