# Mail integration audit — October 10, 2026

## Sync regression and access follow-up — October 11, 06:31

`mailbox-sync-components/gate.json` passed all eight persistent Simulator component
scenarios with unchanged baselines/budgets. This includes the normal sync-scheduling
source but predates the following access/status changes. Stress fixtures disable
provider networking, so this does not establish live sync or physical UI latency.

Source now marks an account unavailable immediately while forgetting Mail access,
cancels its label/page/body/sync work and blocks delivery and overlapping consent.
If credential cleanup fails, the account stays off with a visible save failure;
a subsequent explicit grant can enable it again. A delayed-cleanup regression
checks the immediate state, consent ordering and failed-cleanup behavior. The
230-case engine run is active at `access-lifecycle`.

The connection bar now displays catching-up, retry, provider-limit and access-error
health instead of showing only a connected label. It still needs UI/device
validation. Signed review builds are next; no physical installation is claimed yet.

## Normal sync scheduling — October 11, 06:25

`MailLiveSource` now starts `GmailMailboxSync` by default after its durable action
store is ready and Mail is active with granted access. Bounded passes run history
before at most two enumeration steps and one verification batch. Hiding Mail,
disabling an account or forgetting access cancels its task; task identities prevent
an old completion from clearing a new owner. Transient failures retain disk progress
and back off (5–300 seconds); explicit provider retry deadlines are respected.
Wrong-account errors stop that account. These are local scheduling controls, not
a complete project-wide Gmail quota/byte-budget implementation.

Fill schedules at most sixteen message bodies per pass through the existing
two-download queue. A keyset cursor rotates past failed items; completed and kept
mail and held removals are excluded. Migration v7 adds a partial queue index over
unfinished messages, keeping working memory bounded. Normal `checkNow`, consent,
and enable-account paths start sync without a renderer or provider opt-in.
Full retained body downloading, provider failure/retry UX, large-mailbox fill,
quota behavior and physical-device lifecycle still require live validation.
Weekly reconciliation and account label-removal verification remain unfinished.

`mailbox-sync-integration` passed all six new coordinator/fill/live-source cases:
227/229 cases passed overall. Fill queries over 180,000 retained messages measured
0.071–0.415 ms (first/warm only). HTML preparation (241–254 ms) and 500-message
enumeration (199–202 ms) remain over the unchanged 100 ms ceiling. No integrated
frame/input or live-provider acceptance follows from these tests.

`removal-review-ui-3` passed all 240 functional cases, including paged review,
cached preview, keep and relaunch. The gate correctly remains failed for a runtime
priority-inversion warning. Its matching-binary trace now points to GRDB's async
`Pool.get` → `DispatchQueueActor.execute`, rather than `MailBlobStore.put`'s former
synchronous pooled read. The remaining issue is unresolved, not waived.
This UI binary predates the sync-scheduling integration. The required full
component run is active at `mailbox-sync-components`. Physical review builds have
not been refreshed yet.

## Body-store reader contention — October 11, 06:14

The tombstone read inside `MailBlobStore.put` now uses the existing serialized
index writer connection, without opening an index transaction or changing index
data. It remains inside the blob write, preserving late-body rejection and the
ordering with deletion cleanup. It adds no connection/cache. The lock-order rule
remains essential: index writers must not synchronously wait on blob operations.
The tradeoff is waiting behind index writes rather than competing for list readers.

The persistent `testBodyStorageDoesNotWaitForBusyListReaders` holds both index
readers for 250 ms. Frozen source in `blob-contention-reference` took 267.71 ms;
current source in `blob-contention-writer` took 0.204 ms. This is a controlled
contention comparison, not cold/warm/eviction coverage or UI latency acceptance.
Late-body rejection, cross-account removal recovery and body-store correctness
passed after the change. The runner now requires 223 tests.

Reference passed 219/223 cases: the expected contention failure, HTML preparation,
500-message enumeration and a 118.84 ms 1,000-message durable-action sample failed.
Current passed 221/223: only HTML and enumeration failed. The action spike did not
recur; its cause remains unknown and the original failure is retained. Source
hashes, logs, timing artifacts and host samples are retained in both directories.

`removal-review-ui-3` is building/running the corrected review selector and this
body-store fix. Its outcome, runtime warnings, preview/keep/relaunch checks and
the required following full component run remain pending. No installed physical
review build has been updated by this change.

## Checkpoint-expiry repair — October 11, 06:07

Source now invalidates an unfinished account enumeration when its history
checkpoint expires. The compare-and-swap uses the failed request's checkpoint,
clears that account's scan marks, reconciliation verification and scan decision,
and allows a fresh handshake. Cached messages, held removals, user intents,
mutation-verification requests and other accounts remain untouched. Four new
checks cover isolation/preservation, stale expiry, actual history-worker recovery,
and a disk transaction with 10,000 scan marks. All four passed in
`checkpoint-expiry` (220/222 cases passed overall). Expiration measured
1.43–1.49 ms for 10,000 marks; this does not cover large verification queues,
eviction or UI latency. HTML preparation (243–253 ms) and 500-message enumeration
(207–221 ms) remain failed. The persistent engine runner now requires 222 cases.
This source postdates the `removal-review-ui-2` binary. The removal snapshot also now returns primitive
Sendable values instead of carrying GRDB rows across its actor boundary.

`removal-review-ui-2` completed with 239 passing cases and one failing case.
The removal review reached page two; its test incorrectly selected the same title
in the obscured inbox. The exported AX hierarchy proves both elements exist and
the selected bounds belong to the inbox. The selector is now scoped to
`mail.removal.rows`; preview/keep/relaunch still need validation.

The priority-inversion warning is now symbolicated using the matching app UUID:
`Pool.get` → `DatabasePool.read` → `MailBlobStore.put` line 34. This is the synchronous
tombstone read inside the blob write waiting for an index pooled reader. Evidence
is in `removal-review-ui-2/priority-warning.log` and
`removal-review-ui-2/priority-warning-symbols.txt`. The synchronization needs correction while retaining
the anti-resurrection ordering; moving the check before the blob write is unsafe.

## Overnight follow-up — October 11, 06:00

`removal-review-ui` finished with 239 passing tests and one failure. Mail retained
search/open/clear, Calendar search entry/clear and older-mail paging passed. The
new removal-review test crashed in `ScaleStress.prepare`, whose unconditional
fixture-source cast conflicts with the deliberately disk-backed review source.
The supplementary review fixture now bypasses that stress-data preparation and
explicitly rejects measurement/idle-redraw flags; the standard stress workload
and scenarios are unchanged. This repair still requires a UI rerun. The original
result also retains a priority-inversion runtime warning in that same test;
its cause is not yet established.

Enumeration now durably clears a rejected continuation for only its current
listing, preserves positive marks/checkpoint/generation, and yields immediately.
A rejected first page still throws; transport/server failures retain their cursor.
Two new worker cases cover restart across worker instances and first-page failure.
Both passed in `reconcile-token-recovery`: 216/218 cases passed overall, with
HTML preparation at 240.62–249.44 ms and 500-message enumeration at
201.50–211.24 ms still failing the unchanged 100 ms limits. This is a recovery
correction, not a measured speed improvement or live-sync integration.
The corrected full Mail UI run is active at `removal-review-ui-2`; the post-review
full component suite must follow it without overlapping measurement jobs.

Removed only obsolete `.build/macuitest-dd/Build/Intermediates.noindex` compiler
intermediates. Products, result bundles and all workspaces are preserved. Free
disk space was 19 GiB after cleanup; device/simulator cleanup remains outstanding.

## Removal review integration — October 11, 05:48

Normal Mail now has a removal-review notice and paged sheet with cached message
preview, keep/remove choices, and retry for a saved choice that could not finish.
`MailRemovalCoordinator` captures exact account/message ids into a staged intent
review, closes the index snapshot before presenting it, and fsyncs a choice before
projection. A later hold is not swept into an earlier choice. Startup discards only
unacknowledged reviews and replays committed choices; failed cleanup keeps the
choice pending. Kept mail remains readable, gains a visible local-only reason,
cannot generate label assertions, and ignores late provider metadata imports.
Delivery is paused while a removal choice needs local repair.

`removal-review-1` passed all five new coordinator cases; overall 213/215 passed,
with HTML preparation and 500-message enumeration timing still failing.
For 100 held messages, initial review preparation measured 2.92 ms and durable
keep/projection 42.35 ms. `removal-live-source-1` passed the source-level notice,
review/page, answer and kept-state integration case; overall 214/216 passed with
the same two timing cases failing. Its review/answer samples were 3.21/43.89 ms.
These are disk-component observations, not UI latency or eviction acceptance.

The persistent Mail UI runner now requires
`testMailRemovalReviewPagesKeepsAndPersists`. It exercises 52 held messages, page
two, cached preview, keep, visible kept status and relaunch. Its isolated fixture
requires DEBUG Simulator, `--stress-days` and `--mail-removal-review`; it opens a
separate temporary store and disables all Gmail transport. An explicit reset flag
clears only that fixture store. Normal launches continue using the real source.
The UI build/run is pending at `.build/mail-download-20261011/removal-review-ui`.
The default `.heldRemoval` list scope, reconsidering previously kept messages,
and live history/reconciliation scheduling still need integration. Review builds
on the physical devices and Mac have not yet been updated with these changes.

`verification-components/gate.json` passed all eight component scenarios before
these removal-review changes. A post-review full component run remains required.

## Verification foundation — October 11, 05:29

`GmailVerificationSync` verifies the token's account, reads missing messages with
four requests in flight, and commits outcomes in batches of twenty. Only structured
per-message `notFound` becomes absence evidence. Authentication/proxy/server/decode
failures leave the queue unread. `MailVerificationIndex` waits for the entire
generation, persists its aggregate removal decision, and applies at most fifty
removals per transaction. Newer history invalidates old absence evidence; an existing
removal hold takes precedence. Applied counts track committed deletions, while
tombstones retain cross-store cleanup work after a post-commit failure.

Direct HTTP message/thread reads now normalize omitted label arrays to a known
empty set and reject malformed arrays. History records retain unknown-label
semantics. `verification-http` passed all 16 transport cases.

`verification-1` passed all nine new index/worker cases. The fifty-message disk
removal transaction measured 11.53 ms (one first-use sample, not UI acceptance).
Overall 207/210 engine cases passed: HTML preparation, 500-message enumeration,
and an existing keyset query timing case failed. The latter retained a 101.3515 ms
sample for offset-zero/limit-500 versus typical 3–4 ms samples; the query/test
source hashes are unchanged from `reconcile-worker-2`, which had a 12.08 ms overall
keyset maximum. This does not establish a cause. `verification-paging-abba` is
compared frozen pre/post binaries in reference/current/current/reference order.
All four exact tests passed without sampled competing developer processes. The
previously failing offset-zero/limit-500 case's maxima were 2.998/2.907/2.927/3.039 ms;
its eviction samples were 3.34/3.17/3.34/3.37 ms. Overall keyset maxima across all
sizes were 11.73/16.23/11.71/11.81 ms. The spike did not reproduce; this does not
identify its cause or replace the original failed full-engine run. Frozen binary
hashes, raw measurements and host samples are retained in that directory.

This is still not enabled in normal Mail. Held-removal review/answers, enumeration
recovery gaps, fill/quotas and lifecycle wiring remain required. Review installations
have not been updated with it. The preceding `reconcile-components/gate.json`
passed all eight scenarios, but predates verification and direct-read normalization.
The full follow-up is now running at `.build/mail-download-20261011/verification-components`.

## Reconciliation enumeration foundation — October 11, 05:20

`MailReconcileIndex` stores the account handshake, enumeration generation, ordered
label listings, page continuation and bounded close-scan position. Each page and
its cursor commit together. Stale responses cannot overwrite newer history;
absence queues a per-message verification and never removes data. The close scan
skips messages introduced after the scan began, newer history, and kept messages.
`GmailReconcileSync` verifies the account before access, saves the handshake before
listing, and resumes interrupted pages. It yields after a bounded number of steps
and stops explicitly at `needsVerification`.

This is not live reconciliation yet. Verification and aggregate removal decisions,
held-removal review, expired-list-token restart, checkpoint-expiry recovery during
enumeration, fill scheduling, quotas/backoff and source lifecycle wiring remain
required. It currently enumerates everything, matching `MailLiveSource`; bounded
retention/claim listings must be implemented before exposing the specified limited
sync setting. No installed review binary includes this foundation yet.

`reconcile-index-1` passed all five correctness cases. Its actual disk page benchmark
measured 39.80–40.55 ms at 100 messages and **199.16–205.96 ms at 500**, failing the
unchanged 100 ms ceiling. The network worker therefore requests 100 messages per
page; it still scans the full mailbox. The 500-message test remains required and
failed, not dropped or relaxed. `reconcile-worker-1` passed all three new worker
cases. It retained the large-page and HTML timing failures plus an old wire test
that expected a malformed cursor to become a final page; that expectation was
corrected to require rejection. `reconcile-worker-2` passed 199/201 cases: all
reconciliation/worker/wire correctness cases passed; HTML and 500-message page
timing cases remain failed. Page samples were 39.61–41.54 ms at 100 messages and
198.32–199.41 ms at 500. No optimization or device timing claim follows from these.

`reconcile-http` passed all 14 transport cases, including malformed listing-token
rejection. This changes continuation validation, not optional count estimates.
The prior full app component pass in `removal-components` predates this foundation;
the full follow-up passed all eight scenarios at `.build/mail-download-20261011/reconcile-components/gate.json`.
Physical search, sync and frame/input acceptance are still open.

## Deletion recovery foundation — October 11, 05:10

`MailRemovalRecovery` replays account-scoped index tombstones in bounded batches,
settles only the removed messages' label assertions/inverses, removes original and
prepared bodies, and removes cached attachment files before their tracking rows.
File failures leave tracking rows for replay; paths outside the attachment cache
are rejected. The blob writer checks the index tombstone inside its serialized
transaction so a late download cannot restore content after cleanup. Index writers
must not wait on blob writes, preserving the documented cross-store lock order.
Tombstones remain retained; coordinated expiry remains future work.

This helper is not yet connected to normal polling. Bootstrap/reconciliation and
held-removal review still gate that integration. No installed review build includes
this change yet. `removal-recovery-1` passed 191/192 engine cases, including both
new cleanup cases and the durable intent-removal test. Large HTML preparation alone
failed at 242.30–249.81 ms. The full app component run passed all eight scenarios at
`.build/mail-download-20261011/removal-components/gate.json`. This build predates
the reconciliation foundation and listing-cursor decoder correction.
No speedup or physical-device acceptance is claimed.


## History worker foundation — October 11

`GmailHistorySync` now verifies the account, recovers pending follow-up work through
an explicit callback, and resumes an established checkpoint. Pagination keeps its
original request floor while each index transaction commits its restart position.
A final empty page after earlier records still advances to the response position;
a recent entirely empty poll does not open a writer transaction. Structured history
notFound requests reconciliation; proxy/unexplained 404 and other failures preserve
the checkpoint. A bounded pass returns whether more work remains. Post-commit
failure leaves its stubs/tombstones/checkpoint available for recovery.

This worker is **not wired into normal Mail**. Bootstrap/reconciliation, concrete
post-commit cleanup, and held-removal UI remain required before activation. Its
six provider/restart tests passed in `history-worker-1`. Overall 187/189 engine
cases passed; dense-action and HTML preparation timing cases failed. No live sync
acceptance is claimed. The engine gate now includes 189 cases.

`history-index-disk` completed 183 cases with 182 passing and only the retained
HTML preparation timing failure. Actual disk-index history application measured
35.59–42.17 ms for 100 conversations across six first/warm samples. Those samples
do not cover power loss, memory eviction, integrated UI or physical-device timing.

## Atomic history application and deletion holds — October 11

`MailHistoryIndex` now applies validated provider deltas and the next checkpoint
inside the same index transaction. It rejects stale workers and invalid continuation
pages, preserves account isolation and unknown-label-set stubs, removes local search
entries with positive deletions, and leaves tombstones for cleanup/recovery.
`MailRemovalRules` keeps rolling applied-removal counts and preserves unresolved
holds across pages. The boundary hour is retained conservatively so recent removals
cannot disappear early; backwards clock changes also retain existing counts.

This code is **not connected to live polling yet**. Required next work includes
verified-account worker scheduling, durable bootstrap/reconciliation, body/intent
cleanup, and the held-removal review/answer UI. It must not be presented as live sync.

`history-index-1` retains initial compiler/type-check and fixture argument-order
failures. `history-index-2` executed 182 cases: all new transaction and removal-hold
checks passed; 181/182 cases passed overall, with only HTML preparation failing
(about 242–251 ms). `history-index-3` completed 183 cases, with 181 passing and dense-action plus HTML
cost cases failing. Its six in-memory 100-conversation atomic-page samples were
35.75–43.34 ms; they do not establish disk or UI acceptance. The benchmark now uses
the actual `MailStores` disk index and is running in `history-index-disk`. No timing
budget changed. The engine gate now requires 183 cases. The stricter history continuation decoder
also passes all 13 HTTP cases in `history-continuation-http`.

The full app suite `search-history-components` failed its saved relative tolerances
in the one-day case: Calendar visible week 5.258 ms and podcast next 4.438 ms.
Both are first samples; their warm samples were roughly 0.04–0.07 ms and 0.51–0.54 ms.
The other seven scenarios passed. The host monitor found no competing developer
processes, though load was high; cause is not established. `cold-component-abba`
retains a frozen current app and runs old/new/new/old one-day comparisons to diagnose
this without changing a baseline or replacing the failed suite. The completed
comparison did not reproduce an adverse current-binary difference: current first-use
week lookup 1.83–2.10 ms versus reference 1.97–2.08 ms; current podcast-next
2.46–2.68 ms versus reference 2.58–2.74 ms. All four runs had clean developer-job
monitoring and identical workload counts. This is evidence of variability, not an
identified cause or permission to discard the failed full-suite samples. All four
supplemental runs failed the historical relative RSS gate at 317.08–317.58 MB
(the older binary also failed). Their latency checks passed, but the supplemental
runs are not overall passes and do not establish memory acceptance.

## History planning foundation — October 11, 04:37

`MailHistoryRules` now plans a validated page against an account-scoped snapshot:
known label deltas preserve per-message UInt64 history ordering, both directions
within one record are combined, unknown messages become fetch-only stubs, same-page
add/delete cancels, and kept/tombstoned messages are not changed. Deletions are only
proposals for the mandatory removal-hold policy. This planner is **not yet wired**
to live sync; atomic checkpoint application, worker scheduling, reconciliation,
held-removal review and restart tests remain required.

`history-rules-1` executed 170 tests: all 46 existing wire-format checks and five
new history-rule cases passed; 168 cases passed overall. The engine gate failed:
HTML preparation was 249–266 ms, and a single warm 1,000-message action reached
192.36 ms (its other five samples were 88–98 ms). No claim of causal regression or
improvement follows from this run. The host monitor includes the suite's own compiler
and XCTest process; its aggregate overlap flag is not proof of competing work.

A six-sample 100-record/2,000-message-delta planner measurement is added in
`history-rules-2` completed: planner samples were 1.77–1.86 ms. All six planner
cases and all 46 wire cases passed. Overall 169/171 cases passed; the same two
performance cases failed (dense action 101.70/104.25 ms and HTML 248–252 ms).
Planner timings cover no database application, eviction, sync completion or UI latency. The engine gate now requires
171 tests; no existing budget was loosened. The full persistent app component suite
is running under `search-history-components` after both engine runs finished.

## Signed review installs and live Calendar search — October 11, 04:30

The signed `BananaMacBeta` build passes deep/strict signature verification and is
installed at `/Applications/Banana Beta.app`. Launching that installed app restored
the existing Google Calendar account and events. The earlier unsigned build's empty
account state was not representative of the signed review app. Mail offers **Allow
Mail** for the restored account; Gmail consent remains a user step. No consent was
granted and no real mail/calendar mutation was performed.

Read-only native Calendar search returned 39 events outside the displayed week.
Opening a title showed the matching Google event detail; Cancel returned to search.
Clicking the blank center of a short result row did nothing. The corrected signed `search-hitarea-mac` build is now installed. The same AX
row-center click opens the matching event detail; Cancel returns to results. Its
identity and verification are retained in `search-hitarea-mac-install.json`. These are functional checks, not input/display timing acceptance.

The signed iOS `BananaBeta` Release build was installed OVER the existing Beta on
the spare iPhone, primary iPhone and iPad, preserving their containers. The spare's
two `ReviewLaunchUITests` passed with no failures, skips or runtime warnings:
normal launch/relaunch and Plan Day/Week plus Mail navigation. The latter bypasses
onboarding only through launch arguments, and does not establish populated live
mail or event-rendering acceptance. iPad/primary were passcode-locked; their installs
succeeded, but current UI checks remain outstanding. Exact hashes/install records
and `triage-spare-ui.xcresult` are under `.build/mail-download-20261011`.

These review binaries predate the history-decoder and Calendar hit-area corrections;
those source changes need a subsequent build/install. The old Mac bundle is retained
locally for rollback, without changing any application data.

## History response validation — October 11

A controlled transport test reproduced 12 malformed nested history change lists
being accepted as absent. The decoder now rejects unreadable `messagesAdded`,
`messagesDeleted`, `labelsAdded` and `labelsRemoved` arrays, preserving the distinction
between no changes and changes that could not be read. Absent lists remain valid.
`history-decode-before` retains the failing test; `history-decode-after` passes all
13 HTTP cases. The persistent transport gate requires this regression case.
This corrects a prerequisite for sync; history replay/checkpoint advancement is
still not integrated. Field-level validation and atomic replay remain required.
The triage device builds predate this correction and do not implement history replay.

The broader wire-compatibility attempts (`history-wire-compatibility{,-2}`) failed
to compile because the small HTTP harness omitted the header/address/auth dependencies.
Those failed runs are retained. The 46 existing wire-model cases now belong in the
full engine runner, which already includes those dependencies; its minimum rises
from 119 to 165. That expanded engine run is pending after the Mac build to avoid
contaminating its component timings with compilation. The 13-case HTTP pass above
remains the only completed post-fix transport result so far.


## Mac build-target correction and label completeness — October 11

A native UI check found that `delivery-mac`, `refusal-ui-mac` and `labels-mac`
were invoked with scheme `Banana`, not `BananaMacBeta`. Their successful exit codes
are **not Mac Beta build evidence**. The running Beta executable remained dated
02:34 and still displayed the old preview text after relaunch. Those earlier Mac
claims are withdrawn. The explicit `triage-native-mac` build uses `BananaMacBeta`;
it completed successfully. `triage-native-mac-identity.json` records the new executable hash and bundle ID. After quitting the old process and relaunching the exact built app through CUA, Mail displays the current reading/search/actions banner, with composing disabled. The Calendar native viewport is present. This verifies startup and binary identity only: no Google account is connected, and live-provider or interaction timing acceptance remains open.
The repository's existing `tools/mac-install.sh beta` uses the correct scheme.

Reviewing MAIL-ENGINE 5.3 found another error in the first label implementation:
listing absence had hidden directory entries. The catalog now accepts only a
response containing all seven required system labels; incomplete responses change
nothing. A missing cached label remains visible until a verified per-label check
can establish deletion. That verification/removal path is still unfinished.
`labels-completeness` passes the new absence/incomplete tests and all existing
correctness checks (118/119 cases overall); HTML preparation remains failed.

Incremental-sync research uses Google's documented history/checkpoint API and the
project's existing Gmail/GRDB adapters, not a new protocol or database engine:
[Google sync guide](https://developers.google.com/workspace/gmail/api/guides/sync)
and [history.list](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.history/list).
Implementation must preserve the project's per-ID deletion evidence, bulk-removal
hold, stale-response rules and atomic checkpoint requirements. History replay and
reconciliation are still incomplete; refreshing the first page does not satisfy them.


## Gmail label directory — October 11

The label catalog now persists account-scoped directory metadata and feeds live
places and row labels. Gmail IDs stay stable across renames. Labels missing from
a directory response remain available until a per-label request verifies deletion;
incomplete listings never change the catalog. System and Banana-owned labels
are excluded from user label pickers. Nested names retain their full path in a
flat list, including labels without a parent. Provided colors are retained; no
extra per-label network requests are issued for missing color/count fields.

Startup and Check Mail read the cached catalog and refresh granted active accounts.
Requests are cancelled when the account/tab is disabled. Equal catalog readings
are not republished. Invalid/duplicate directory entries or wrong-account responses
preserve the last good transaction. The HTTP adapter now rejects a missing labels
field instead of converting a malformed response into an empty directory.

`labels-http/status.json` passes all 12 controlled transport cases. `labels-engine` passes all four new directory/source checks: account isolation,
rename/removal, invalid-response preservation and live navigation/row publication.
Overall 117/118 engine cases pass; large HTML preparation is still the sole failed
case (about 241–250 ms). Live provider
validation remains open. Directory refresh does not replace the still-needed
history synchronization of message memberships after external Gmail edits.


## Live triage capability wiring — October 11

Normal Mail now enables the implemented action set: Done/archive, Trash/restore,
Spam/not-spam, read/unread, star, label/move and return to Inbox, with their durable
Undo path. Composing/reply, snooze, mute and unfinished cross-feature actions are
separately guarded; they cannot optimistically change rows. Label discovery is
still unfinished even though label-ID mutation is implemented.

Beta's existing test-account policy remains enforced by delivery and is now
checked by the session before optimistic input. Connected non-test accounts are
labeled Read only; the explanation points to Settings. Bulk unified actions
require all connected accounts to satisfy the policy. Automatic delayed reading
also respects account restrictions. The pane sends the actual displayed row's
arrival boundary instead of an unqualified conversation ID, and direct conversation
reads capture their acknowledgement sequence before starting the disk read.

The persistent Mail gate now requires capability separation, account-restriction
and pane-boundary cases. Its three validator tests pass. `triage-ui/gate.json` passes with 239 tests,
zero failures/skips/runtime warnings, including the three new required cases and
fixture search/navigation. Live-account and physical-device checks remain open.

`bulk-components/gate.json` passed all eight persistent Simulator component cases
against baseline version 1, with no threshold changes. This precedes the current
capability-wiring checks and does not measure live Gmail or physical frame/input
latency. The earlier failed runs remain retained; HTML preparation is still an
independent failing engine check.


## Bulk action integration — October 11

Live scope actions now consume stable 100-row list/search pages. Prepared label
assertions are staged on disk in batches of at most 500, then one full-fsync
transaction publishes the receipt, desired labels and inverse. Delivery cannot
see partially prepared actions. Startup removes only uncommitted staging rows;
committed actions and inverses are separate. At most 50 bulk inverse groups are
retained on disk. Undo atomically consumes the inverse as a new intent group.
Projection reads bounded intent pages and acknowledges only after completion.
The snapshot is explicitly closed before projection to release its WAL reader.

Evidence in `.build/mail-download-20261011`:

- `bulk-stage-1`: restart, receipt-collision rollback/retry, inverse consumption and
  abandoned-stage cleanup checks pass. Overall 110/111 cases pass; HTML cost fails.
- `bulk-scope-1`: retained failing test fixture had metadata-only messages, which
  correctly were not visible. The fixture was fixed with fetched headers and an
  explicit pre-action 2,004-conversation count assertion; no production visibility
  rule was relaxed.
- `bulk-scope-2`: 113/114 cases pass. The 2,004-conversation account-scoped action
  uses one receipt, leaves the other account untouched, retains no Swift inverse
  array, and restores all affected rows on Undo. Search-boundary/account isolation
  and live-source scope/undo receipt tests pass. HTML preparation remains failed.

The bulk test's 3.43-second wall time includes data setup, action, assertions and
Undo; it is not input-to-visible timing. Per-conversation fact preparation still
scales with the largest conversation; full-history selection and inverse arrays
are no longer required for bulk actions. No performance acceptance is claimed.
Normal triage controls and composing remain guarded pending capability wiring,
current app/device checks and the remaining unsupported action types.


## Same-binary contention follow-up — October 11

The retained `live-action-components/frozen-app.app` was rerun after the backup
and compiler exited. `backup-followup/comparison.json` checks the exact same binary
SHA and unchanged workloads/budgets. Both Plan/Mail redraw probes pass their
unchanged baseline comparisons, retain zero unrelated redraws and pass memory
checks. Plan Notes-search p95 changed from 469.15 to 15.87 ms; podcast next/download
queries changed from 154.18/189.97 to 18.01/18.81 ms. Mail Notes-search changed
from 27.83 to 15.75 ms. No app change occurred between these compared probes.

This establishes that the earlier stalls do not reproduce consistently with the
same binary. It supports contention as a contributor but does not isolate backup
causality: load remained high, despite no detected compiler or backup process.
The two-case diagnostic is not a complete persistent-suite pass or physical UI
acceptance. Original failures, monitors and all raw samples remain retained.


## Stable bulk-selection reads — October 11

The existing list/search SQL can now run inside a GRDB `DatabaseSnapshot`, with an
inclusive first-page boundary for Select From Here and strict keyset continuation
afterward. The ordinary reader keeps strict paging by default. This reuses the
pinned GRDB snapshot implementation; no custom snapshot/index engine was added.

`scope-snapshot-1` under `.build/mail-download-20261011` passes the new 5,000-row
selection test after concurrent membership deletion/date updates. All selected
rows appear once and in order in 53-row pages. The full 108-case engine run still
fails HTML preparation (243–266 ms); its source identities and timings are retained.
This run overlaps a Mac build and is not performance acceptance. Whole-scope
intent commit and inverse retention still need bounded disk staging; the query
primitive alone does not enable bulk actions or prove atomic durability.

`delivery-mac.xcresult` and `refusal-ui-mac.xcresult` completed with the wrong
scheme and do not validate Mac Beta; see the target correction above. Visual and
physical-device validation remains open. The same-frozen-binary Plan/Mail redraw
follow-up is running in `backup-followup` after verified compiler/backup exit. The prior failed runs remain.


## Refusal review and message targets — October 11

Mail now contains a review sheet for durable failed changes. It pages 50 groups at
a time, identifies undo attempts, shows account/failure details and supports Retry.
Retry waits for the local save before reloading its page; it does not wait for the
network. Status observation is confined to the notice/sheet. Mac build validation was withdrawn after the scheme audit; visual/device validation remains open.

Message targets resolve to the stored conversation, message date and arrival
sequence. Later replies are excluded even at the same timestamp. The new test
passes in `.build/mail-download-20261011/message-target-1`; 105/107 engine cases
passed overall. Dense action commit reached 100.15 ms and large HTML preparation
253–266 ms, so the suite failed. This run overlapped the Mac build and scheduled
backup; it is correctness evidence, not a clean performance comparison.
Whole-scope actions and normal action-control enablement remain unfinished.


## Provider delivery and durable refusal recovery — October 11

The live source now schedules the durable Gmail worker for eligible accounts,
respects persisted retry dates, cancels when hidden and resumes on activation.
The app's existing Google-write policy remains authoritative. Confirmation imports
provider labels before clearing intent, including partial outcomes; refused local
assertions no longer override the provider's labels. Settlement refreshes the
projected rows and emits refusal only for assertions that have not been superseded.
A cancelled pass releases the worker before honoring a pending reactivation wake.

Refused action groups can be read from disk in bounded pages after restart, with
an explicit has-more status. Retry persists the state transition and reprojects
only that group's messages. Cache repair no longer resets an active provider claim.
These are engine/source changes: the visible refusal panel, message/scope target
support and enabling normal triage controls remain unfinished. No real-account
write has been exercised and no physical-device acceptance is claimed.

Evidence under `.build/mail-download-20261011`:

- `delivery-scheduler-1`: compiled and completed 101 engine cases. Correctness
  passed; dense action commit had two samples at 100.03/104.84 ms, and HTML
  preparation failed at 249–275 ms. The run remains failed.
- `delivery-scheduler-2`: 104 of 105 cases passed. New checks cover on-disk refusal
  pagination/reopen, group paging across accounts, provider-state import before
  refusal, and source retry through controlled Gmail confirmation. The remaining
  failing case is large HTML preparation (249–258 ms).

- `delivery-scheduler-3`: 104 of 106 cases passed, including the explicit
  cancellation/reactivation race. Dense 1,000-message action commit again exceeded
  100 ms (104.39/105.01 ms), and large HTML preparation took 248–254 ms. Correctness
  cases passed; this full engine run remains failed. The persistent runner now
  requires at least 106 cases.

The scheduled backup was verified running during these runs. This does not prove
it caused the failures. Clean full-component reruns and physical UI measurements
remain required; no budget or baseline has changed.


## Durable Undo — October 11

The source now accepts Undo before the original asynchronous commit finishes and
queues the inverse behind it. Inverse assertions go through full-fsync persistence
and index projection, carry their own receipt and an additive `is_undo` group flag,
and are not redoable. Failed inverse saves keep the original inverse available.
The session restores a failed Undo to its original history position instead of
placing it above newer actions. No-op receipts withdraw their own toast, and stale
Undo buttons cannot act on a different entry; scoped dismissal preserves newer
unrelated notices.

`undo-1` under `.build/mail-download-20261011` passes 100/101 engine cases, including
immediate Undo, fresh-store persistence, duplicate rejection and retry after an
injected inverse-write failure. HTML preparation still fails. These runs overlapped
a system backup and are not clean timing comparisons. Dedicated dense-Undo timing
and physical UI latency remain open. `undo-session.xcresult` passed the
session, list, fixture, undo-stack and shared-toast checks, with zero failures,
skips or runtime warnings. The persistent runner requires the new regression
cases, and its three gate-validator checks passed.

The prior `live-action-components/gate.json` failed: Plan redraw included Notes
search p95 469.153 ms and podcast query p95s 154.178/189.973 ms; Mail redraw included
Notes search p95 27.832 ms. The developer-only monitor did not detect another build,
but recorded load averages 73–86 on a 10-logical-CPU host. A running scheduled Borg
backup was identified with overlapping timing; this is a candidate explanation,
not proven causality. `contention-investigation.json` and the exact `frozen-app.app`
are retained in that result directory for a same-binary follow-up after the backup
finishes. No failed sample or gate has been discarded or loosened.

Provider delivery, message/scope targets and refusal/retry controls remain open;
normal live action controls stay guarded until those paths are connected.


## Live action submission and displayed boundaries — October 11

Normal startup now prepares the live source's action coordinator. `apply` returns a
receipt immediately, serializes the durable save off the main actor, and emits
applied/notSaved events followed by correctly tagged list snapshots. Reads capture
the acknowledgement sequence before starting so old rows cannot be labeled with a
newer receipt. Projection failure retains saved intent/inverses and withholds
acknowledgement until Check Mail successfully repairs the cache.

The displayed MailRow now carries an opaque per-thread arrival boundary. The model
passes that actual displayed value in `MailTarget.reading`, not a newer source
reading. An additive migration supplies monotonic arrival sequences: raw SQLite
row IDs are reusable after deletion and cannot safely serve as this boundary.
Arrival/move triggers maintain each thread's cutoff without invalidating unrelated
rows. This adds two integer columns plus one persistent clock; migration latency
at large retained histories remains unmeasured.

`live-actions-2` under `.build/mail-download-20261011` passes 98/99 engine cases,
including saved receipt/snapshot publication, unsaved intent rollback, repair after
a committed projection failure, and deliberate row-ID reuse. HTML preparation
remains the failed case. `import-benchmark.json` retains alternating 20-message
batch measurements: 15.74–17.62 ms with arrival triggers versus 14.96–17.22 ms
without them. This is a correctness cost, not a performance improvement or UI
acceptance. Cold migration, eviction and physical input/display timing remain open.
`live-action-session.xcresult` passes the app session/list/fixture-source checks,
including displayed-row boundary capture, with zero failures/skips/runtime warnings.
The final component run at `live-action-components` failed; see the investigation above.

Live UI actions remain guarded: message/scope targets, provider delivery, undo,
retry/refusal presentation and the no-op toast/undo edge still need completion.
No real Gmail mutation was performed. The preceding receipt component suite
`receipt-components/gate.json` passed every baseline-1 gate.


## Receipts and unified actions — October 11

The intent store now accepts a caller-allocated receipt, checks it transactionally
against the persisted next sequence, and preserves gaps without allowing stale
reuse. A unified action can atomically persist assertions for multiple accounts
under one receipt; the group account is empty for mixed ownership, while each
assertion always retains its real account. Existing account-specific calls still
reject mixed assertions.

The coordinator accepts bounded snapshot targets (date plus message-row ceiling),
returns the exact inverse and affected conversation count, and acknowledges only
after every account's projection completes. A projection error preserves the saved
receipt and inverse in its result. The legacy single-conversation entry point keeps
its explicit committed-versus-unsaved failure behavior.

`.build/mail-download-20261011/receipts-2` passes 93/94 engine cases. New coverage
includes receipt restart/reuse, atomic mixed-account validation/retry, unified
projection/inverses, identical-date later replies, and inverse retention after an
injected projection failure. The remaining failed case is HTML preparation.
`receipts-1` and `receipts-2` retain the implementation comparison: 1,000-message
commit samples changed from 78.85–81.13 ms to 79.79–82.94 ms; one-message samples
from 1.96–2.35 ms to 2.28–2.90 ms. This adds correctness work, not a claimed speedup;
the 50 ms goal remains missed at 1,000 messages. No baseline changed.

The UI/source receipt bridge, snapshot-boundary capture and durable undo submission
still need connection before enabling live actions. The prior final session-change
component suite `action-event-components/gate.json` passed every baseline-1 gate.


## Session action events — October 11

The session now subscribes to source action events for its lifetime, including
while Mail is off screen. Unsaved/refused actions remove their undo entry and
repair the originating retained list without navigating away. Failure Retry calls
`source.retry(receipt)` instead of accidentally invoking Undo. Events emitted
synchronously inside `apply` wait until the receipt/undo effects finish, so the
rollback cannot arrive before its undo entry exists. Scope action counts update
or remove the associated undo entry.

Five new session cases cover synchronous/delayed save failure, refusal after
navigation, Retry preserving earlier Undo, and eventual counts. All 77 session
and fixture-source cases passed in `action-events.xcresult` under
`.build/mail-download-20261011`, with zero skips/failures/runtime warnings. The
persistent Mail runner now requires the five named cases; its three validator
checks also pass. A final component run for this source state is at
`action-event-components/gate.json` (passed). Provider receipt emission and durable undo remain
unconnected; this change does not enable live Gmail actions or composing.


## Startup intent recovery — October 11

Normal Mail startup now opens the durable intent store and completes recovery before
exposing the live source. Recovery resets interrupted delivery, removes overlays
whose intent was already confirmed, and replays missing overlays using bounded
index/intent pages. Refused actions retain their refusal; no provider writes occur
in recovery. A committed action followed by an index failure now throws a distinct
`projectionAfterCommit` error carrying its receipt, so the future UI bridge can
avoid incorrectly claiming that durable intent was lost.

`.build/mail-download-20261011/recovery-1` records 88/89 engine tests passing,
including injected index failure, interrupted delivery, stale-overlay cleanup and
idempotent recovery. The existing HTML preparation case still fails (241–247 ms).
Startup recovery latency at large outbox sizes, process-crash UI recovery, and
physical-device verification remain open. This is correctness integration, not a
claimed performance improvement. Receipt/event/undo handling, provider-worker
lifecycle and visible retry controls remain incomplete; live actions and composing
are still guarded.

The normal unsigned Mac Beta Release build passed at
`.build/mail-download-20261011/recovery-mac.xcresult`. The sequential component
run at `recovery-components/gate.json` passed every baseline-1 gate, with no
host-isolation failures. This remains Simulator component evidence only. Mobile app
compilation and end-to-end recovery UI remain unverified for this change.

The prior `action-components` run failed host-isolation checks in redraw scenarios
with overlapping builds. Results are retained; `recovery-components` is the passing clean rerun.

## Durable action projection — October 11

`MailActionCoordinator` serializes full-fsync intent commits followed by disposable
index projection. `MailActionIndex` changes overlays, not raw Gmail labels, and
rebuilds summaries/membership through the existing writer. Refusal is now stored
per overlay in an additive cache migration, so clearing/retrying one failure does
not leave conversation status stuck. Intent's log participates in the writer's
existing checkpoint policy. The source's synchronous receipt/event/undo bridge,
visible durable failure controls remain to be connected;
normal Mail actions are still guarded.

`action-index-1` under `.build/mail-download-20261011` passes four integration
cases: account-scoped archive, overlay-loss recovery, durable intent after an
injected index failure, and refused/retry/opposite-action transitions. The full
engine result is 86/87 with the existing HTML timing failure.

The persistent action benchmark in `action-index-2` exposed repeated full-thread
summary rebuilding: 1,000-message actions took 413–463 ms. The revised projection
keeps 20-message overlay batches and rebuilds affected threads once, after staging.
`action-index-3` on the same workload records 79–87 ms at 1,000 messages, 10–11 ms
at 100, 3.2–3.8 ms at 20, and 1.9–2.3 ms at one. Its action benchmark/correctness
checks pass; overall 87/88 engine tests pass, with large HTML still failing. Both
source snapshots and every sample are retained. This is a reproducible component
before/after, not frame or input-to-visible acceptance; the 1,000-message case still
misses 50 ms before UI work, and eviction/device/memory tradeoffs remain unmeasured.
No baseline or budget was changed. A refreshed full component regression is running
at `action-components`; pending is not passing.

## Durable provider delivery — October 11

`GmailIntentDelivery` claims saved intent atomically, validates the token's account,
serializes delivery, uses message-level calls, and reads labels back before clearing
intent. An uncertain write may be confirmed by that read; a 2xx without matching
labels remains pending. Claims contain at most 100 labels. Retry deadlines are
persisted and respect provider rate-limit hints; an idle/backoff pass makes no
provider request. Cancellation reschedules durably, and permanent failures remain
for explicit retry. The injected write policy must be supplied by app integration;
this worker is not yet connected to the screen and no real mailbox was modified.

The existing native transport follows Google's
[message modification API](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/modify)
and separate [trash API](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/trash).
No new network library or thread-level mutation path was added.

`.build/mail-download-20261011/delivery-2` passes all eight delivery cases, including
wrong-account rejection, ambiguous outcomes, cancellation, disabled policy,
rate-limit backoff, refusal/retry and newer intent during an older write. Overall
82/83 engine tests pass; the existing HTML-preparation test still fails at about
241–247 ms. `delivery-1` preserves the earlier five-case snapshot. This establishes
controlled-provider correctness, not live Google behavior or performance acceptance.

The normal iPhone/iPad Release target compiled successfully in
`review-ios.xcresult` (unsigned). It includes live startup and the corrected empty
states, but predates this delivery worker. No new physical device installation or
connected-account test is claimed.

## Durable label-intent store — October 11

`MailIntentStore` now owns a private FULL/fullfsync SQLite queue using the existing
`MailStores.openIntentQueue` implementation. A single transaction records the
receipt/change group and desired label states. Confirmation/refusal checks both
current and sent sequence numbers; a late response cannot erase a newer intent.
Interrupted delivery is retryable after restart; terminal failures and retries are
durable. Reads use bounded full-key paging, including groups larger than a page.
There is no file-reset/delete API. Provider delivery and UI action wiring are next;
this store alone does not enable actions or establish UI/disk latency acceptance.

`.build/mail-download-20261011/intent-1` passes all four new store cases (late
responses, restarted refusal/retry, cache deletion, 1,203-item paging and invalid
account-group rejection). Overall 70/71 engine tests passed, with the previously
known large HTML preparation timing case still failing. Source snapshots, logs
and unchanged budgets are retained.

## Normal Mail startup integration — in verification

Ordinary startup now selects the disk-backed Gmail source asynchronously, preserves
store-open failures for retry, and exposes account connection and separate Mail
consent. Sample mail is restricted to explicit fixture/stress launch routes in
builds that contain fixtures. `MailApplication` shares one startup/session across
windows. OAuth token sessions now refuse redirects and disable cookies/cache.

This is an intermediate reading/search integration, **not full Mail completion**.
The screen explicitly labels actions/composing as unfinished, and the session
refuses those requests before optimistic changes or draft creation. This temporary
guard must be removed as durable mutations/drafts are implemented, not treated as
the final scope. Live accounts, actual app compilation and device verification of
this startup change are pending. `startup-auth` under `.build/mail-download-20261011`
passes all 53 credential/token checks, including redirect refusal. The Mac compile in `startup-mac.xcresult` succeeded. `startup-session.xcresult`
passed 53 session tests on the iPhone Simulator, including the unfinished-action
guard. This is not physical UI timing acceptance. The earlier component run started before this
integration and cannot establish acceptance of the new startup flow.

## Provider body downloads and recovery — October 11

`GmailConversationLoader` now loads complete thread metadata, downloads selected
external MIME body parts through Gmail's attachment endpoint, and commits original
and prepared content before promoting index availability. It validates account,
message/thread identity and bounded MIME data. Attached files are not eagerly
fetched. Warm prepared content and original-content crash recovery work offline.
`MailLiveSource` schedules at most two downloads with a bounded 64-item queue;
opening a conversation requests its thread and up to eight recent bodies. Older
messages have an explicit Load message control. File attachment opening, durable
mutations/drafts/history and normal live-source/OAuth UI wiring remain incomplete.

`.build/mail-download-20261011/http-1` passes 11 transport checks.
`lifecycle-before` reproduces a retained-reader failure after leaving and returning
to Mail. `lifecycle-after` passes that provider-to-disk-to-observer test and the
original-cache recovery test, with 66 of 67 total engine tests passing. The sole
failing case remains large HTML preparation, eight samples at 240–247 ms against
100 ms; the full engine suite remains failed. These are correctness repairs, not
measured scrolling or UI latency improvements. No baseline was changed.

The refreshed persistent component run at
`.build/mail-download-20261011/components` passed every gate with baseline version 1.
It predates the new startup wiring above and proves neither that wiring nor physical
frame/input performance. Full app/device verification of these changes is
still outstanding. Normal Mail remains fixture-backed until the integration work
below is finished.

## Conversation/reader checkpoint — October 11

`MailReaderModel` now cancels obsolete reads, rejects late publications, refreshes
placeholder/changed-state bodies, evicts removed messages, and reuses unchanged
ready bodies. `.build/mail-reader-20261011/before` reproduces three failures;
`after` passes four cases. `tools/mail-reader-tests/run.py` runs these in CI.

`MailConversationReader` now projects cached index facts and bounded blob metadata
reads into the existing UI contract. It does not read raw HTML/plain columns or
prepare text on conversation open. `MailLiveSource` implements conversation
observation, one-shot reads and prepared-body reads; index commits invalidate its
observers. Correctness includes Bcc, account isolation, attachment metadata,
prepared-body availability, mixed Trash/Inbox status, and a source-observer handoff
using controlled Gmail responses and real disk stores. These are not live Gmail
or physical-device acceptance.

`.build/mail-conversation-20261011/run-3` executed 62 tests: 61 pass; the existing
HTML-preparation timing case still fails eight assertions. The full persistent
component regression finished under that directory: all component metrics met their
limits/references, but the overall gate failed because `scale-30d`, `scale-90d` and
`redraw-notes` overlapped another developer workload. Those samples are retained;
a clean-host repeat and physical acceptance remain required. Normal Mail remains fixture
backed: full-thread/body fetching, live-source/OAuth wiring, attachment opening,
durable mutations/drafts/history and final device builds are still required.

## Search checkpoint — October 11

The first local Mail search and Google Calendar search paths are implemented;
see [scope and limits](../design/mail-calendar-search.md). Normal Mail remains
fixture-backed, so this does not close connected Gmail readiness.

`.build/mail-search-20261011/run-3` retains 58 checks: 57 passed; the unchanged HTML
preparation cost test failed eight assertions. New local-search correctness checks
pass beyond 2,000 retained rows, including account isolation and edit/delete
invalidation. At 180,000 messages, selecting page IDs before summaries reduced the
broad-query samples from 139–142 ms to 78–81 ms in the alternating same-process
comparison. Rare-query samples remained below 1 ms, with a small candidate overhead.
This is a contended-host component result, still above the 50 ms UI goal before
rendering; cold-after-eviction, memory and all-device UI acceptance remain open.
The failed initial broad-query run is preserved as `run-2`.

Calendar URL checks passed in `.build/search-integration-20261011/calendar-query`.
The full persistent component suite built but refused measurements because another
Xcode test/build was active; its `components/gate.json` says **unmeasured**. Mac
Release build-4 passed, including the date-only Calendar bounds fix.
The iPhone Simulator passed both new UI cases (Mail retained search/clear/open and
Calendar entry/dismissal); real-account Calendar results and physical devices are
not covered. Exact result bundles and summaries are in the same directory.
No baseline was changed. Completed older Mail compiler caches were removed while
preserving all sources, measurements, result logs and workspaces; see the cleanup
manifest there.

## Gmail HTTP checkpoint

The native URLSession adapter now has persistent controlled-response tests:
`.build/mail-http-20261010/run-3` passed 10 tests with zero failures. The original
`run-1` retains two failed assertions for modern structured Google API-disabled
and insufficient-scope errors; the adapter now reads `error.details[].reason`
as well as legacy `error.errors[].reason`. Search/continuation escaping, malformed
pages, bounded responses, network gating, metadata headers, invalid paging and
cancellation have component coverage. CI runs `tools/mail-http-tests/run.py`.

This is not connected Gmail or integrated search. Redirect behavior, live account
responses, durable sync/index writes, production source wiring, refreshed actual
app builds, full component regression and device acceptance remain open. No
transport performance improvement or UI acceptance is claimed by these tests.
See [search scope](../design/mail-calendar-search.md) for the added readiness gate.

Mail in this checkout is not connected to a production source. This is a larger
integration gap than a paging-only optimization. `MailSession+App.shared` creates
`MailFixtureSource` for DEBUG/MAIL_FIXTURES and returns nil otherwise. The normal
production section renders `MailNotSetUp`; the two Beta targets enable fixtures.
Do not describe a sample-data review as a connected Gmail build.

User-test readiness requires integrated review builds and functional verification
on Mac, physical iPad and the spare physical iPhone, with no feature opt-in. Track
each device's build, production account/data connection, paging, selection,
message opening, live updates, offline actions/recovery and adaptive layout
results separately. Apply the [all-device completion gate](calendar-integration-status.md#all-device-completion-gate)
and retain separate physical frame/input evidence. A pass on one platform, or a
Simulator fixture pass, cannot make the other platforms ready.

## Confirmed gaps

- The original `MailSession.carry` ignored `.growTo` (along with scroll-page/restore/check-now
  effects). A candidate now replaces the source observation at the requested limit. The initial limit
  is 100 rows, so stress scrolling alone does not prove access to older history.
  `MailSessionTests.testScrollingToLoadedBoundaryRequestsAndReceivesMoreRows`
  reproduced this boundary: one test failed with 100 rows remaining after the
  model requested growth (`.build/mail-paging-20261010/before.xcresult`). The initial repair passed all 219 session/list-model tests with zero skips
  (`.build/mail-paging-20261010/after.xcresult`). A follow-up preserves the old
  subscription until replacement delivery and cancels both on leave; all 221 session/list-model tests passed with zero skips
  (`.build/mail-paging-20261010/handoff.xcresult`). This is not yet integrated scrolling.
- Both native list hosts originally omitted `.scrolled(MailViewport)`. The new UI
  test reproduced older-mail reachability failure after the session fix. Both host callbacks are now wired; the iPhone Simulator passed the unchanged
  older-mail test and existing scroll/open test (2 passed, 0 skips, 0 runtime
  warnings). Mac/iPad UI and physical latency remain unverified. See [paging evidence](scale-results/mail-paging-20261010/README.md).
- `MailListModel.growIfNeeded` additionally caps the loaded list at 2,000. Removing
  that cap alone would retain an ever-growing window; full history needs bounded
  disk-backed paging with stable cursor/viewport anchoring.
- iOS `MailListCoordinator.apply` and Mac `load` append/update their row and display
  dictionaries but never evict removed IDs. The actual-method regression probe
  reproduced 512 retained rows and 512 displays after eight disjoint 64-row scopes
  on each platform; empty scopes retain them too. The original failures are preserved.
  A candidate retirement repair now passes expanded component checks; native UI
  and performance validation are pending (see the Mail retention result report).
- The GRDB `MailStores` foundation exists (index/blobs/search/intent stores), but
  the app session is not wired to a production `MailSource`. Existing source
  protocol defaults intentionally report not-yet-implemented members.
  `MailSlices.migrations()` now registers the index schema; `MailIndexReader` has
  real GRDB keyset reads and 12 passing disk correctness/query-cost checks.
  The writer and production source are still missing. `MailAccountAccess`
  defines the credential boundary. The overnight implementation now adds
  `MailGoogleAccess`, a separate device-local credential store and a Google SDK
  consent adapter; they are not yet connected to the Mail screen. A production
  Gmail transport/sync source is still missing. Reuse the existing GRDB pools,
  wire types and credential rules; production readiness needs the missing index schema,
  source, account-access adapter and sync integration, not just a list adapter.

## Required implementation and evidence

Reuse the existing UIKit collection view, AppKit table view and GRDB stores.
Connect a real bounded list source; carry paging effects; support history beyond
2,000 rows without retaining it all. Cover scroll/keyboard navigation through page
boundaries, stable selection and viewport under live insertions, search/filter
changes, unread state, and durable offline actions/failures before adoption.

For cache pruning, preserve rows required by active snapshot transitions and
verify rapid replacement/animated removals on both native hosts. The pure probe
uses minimal row/display/snapshot adapters, so its count evidence is not memory-
byte accounting, UI correctness or frame/input latency. Run the persistent full
component suite plus relevant Mail session/list/UI checks after shipping changes.
Do not claim a speedup from the retained-count failure alone.

The source/test entry points are `Banana/Model/MailUI/Pure/MailSession.swift`,
`Banana/Model/MailUI/MailSession+App.swift`, `Banana/Model/MailUI/Pure/MailListModel.swift`,
`Banana/Views/Mail/MailListHost+iOS.swift`, `MailListHost+Mac.swift`, and
`tools/mail-row-retention-tests/run.py`. Baseline artifacts are under
`.build/mail-retention-20261010/before/`.


## Normal phone navigation — integration review

The compact shell previously excluded Mail entirely and mapped `.mail` selection
back to Plan. Mail now has a normal tab alongside Plan on iPhone and iPad; the
system handles compact overflow. `ReviewLaunchUITests.testNormalBetaPlanAndMailNavigation`
checks ordinary-shell access without `--mail` or fixture arguments. Its runner
build passed; physical execution remains pending in
`.build/integration-review-20261010`. This makes the sample UI reachable and does
not supply the missing Gmail source or connected-account acceptance.

## Overnight credential integration — October 10

`MailApp/MailGoogleAccess` now implements the credential boundary with separate
Beta/production Mail keychain services. It uses the existing Google SDK presenter
without changing Calendar's required scopes or accepting a Calendar account.
An actor performs keychain I/O; consent succeeds only after its credential is
durable. Forgetting a credential is now `async throws` so deletion failure cannot
be silently acknowledged. This replaces the earlier synchronous protocol design;
there were no existing conformers or callers to migrate. Calendar credentials are
not written or revoked by this path.

The grant ledger protects replacement/deletion against stale refresh results,
serializes cache invalidations, and prevents an in-flight consent from restoring
a credential the user just forgot. Refresh requests now percent-encode opaque
form values, expose returned scopes, reject unusable successful payloads, and
support the Mail-specific ephemeral URLSession with 15/20-second timeouts.

`tools/mail-auth-tests/run.py` and the `mail-auth` CI job retain persistent
correctness coverage. `.build/mail-auth-20261010/run-4` passed 52 tests with no
compiler warnings; URLProtocol and storage fixtures avoid live network/keychain
changes. `run-1` retains a harness-language-mode build failure (Swift 6 versus the
app's Swift 5 mode), corrected in subsequent runs. These tests are not live OAuth,
UI or performance acceptance.

The app already embeds Google client IDs. The remaining owner handoff must check
Gmail API enablement, consent/test-user configuration and actual sign-in on each
platform, rather than assume a missing client ID. Before that handoff, implement
the disk-backed Gmail source and connect the normal Mail UI; it still uses
fixtures today. Full-history paging, durable provider actions and provider sync
are still open. No claim that credentials are the only remaining blocker.

## Disk index checkpoint

### Live-source adapter — still not the normal app source

`MailLiveSource` now provides account/permission state, observed disk-backed lists,
post-commit invalidation, four-request provider paging and an eight-scope bounded
first-page cache. Controlled consent/provider tests exercise the path through
real stores to source observers. Label-owned account scope overrides the outer
filter, and unsupported search explicitly reports failure rather than showing
unrelated cached inbox rows.

`.build/mail-index-20261011/run-15` ran 54 tests. The three adapter cases passed;
the suite still fails only the eight existing HTML cost assertions. No live
OAuth or normal-app source replacement is proved. The adapter still inherits
not-yet implementations for conversation/action APIs and must not be called
fully integrated. Account-disable preference persistence, counts/labels, full
history reconciliation, body fetches, actions and search remain incomplete.

Reader integration also has a confirmed code-path gap: `MailReaderModel.received`
only reloads bodies whose dictionary entry is nil, so a cached `.notOnDevice`
answer would prevent later prepared content from appearing. Add a reproducing
reader test and fix that handoff while wiring conversations; current fixture
body success does not cover it.

### Provider page loading

`GmailPageLoader` connects the existing Gmail API boundary to metadata import and
the disk reader. It verifies the initial profile account, binds continuation to
the account/labels/query scope, bounds in-flight requests to four, and queues at
most twenty imported messages per transaction. `MailWriter.transact` uses the
existing writer queue and emits its change only after a successful commit.
Provider-page failure never returns an acknowledged continuation. History
checkpoint advancement is intentionally absent until full enumeration/history
reconciliation exists; loading a page is not a completed sync pass.

`.build/mail-index-20261011/run-14` ran 51 tests. All five new loader/transaction
checks passed, including a 53-message two-page walk through the real reader,
failed-provider no-write behavior, account/scope rejection, cancellation and
rollback notification ordering. The suite still fails on the eight existing HTML
preparation timing assertions. No live account was contacted. Real source/UI
wiring, body fetching, incremental history and durable actions remain incomplete.

### Prepared-body integration and failing performance gate

`MailHTMLPreparer` now uses the pinned SwiftSoup parser/cleaner, retains an inert
fragment and produces formatted native text for the existing reader. That reader
already displays native text for `.designed` bodies; images/design rendering is
still incomplete. Scripts, resource-loading tags, unsafe link schemes, formatting,
quotes, tables/lists and size/depth bounds have controlled correctness checks.
This is not broad adversarial or device renderer acceptance.

Blob migration `v2-preparation-revision` adds content/preparation revision checks.
Prepared reads require the current preparer version and matching content revision;
replacement invalidates output, and late jobs cannot restore stale content.
Reopened-store readback and stale-job rejection passed in runs 12/13.

**The overall suite fails.** `.build/mail-index-20261011/run-12` and `run-13`
each ran 46 tests, with eight over-budget assertions in the one new HTML cost
test. The other 45 cases passed. The unchanged generated 261 KiB workload took
247–270 ms in run 12. Run 13 retained phase timing: median/max 245.67/255.70 ms,
with median parse 87.56 ms, clean 113.73 ms, native text 16.70 ms and serialization
15.24 ms. The 63 KiB median/max was 61.50/63.99 ms. Raw samples are in
`html-benchmark.json`; these inputs are generated link-rich blocks, not the old
newsletter benchmark. Keep the 100 ms guardrail and failed runs.

Preparation is off the reader's synchronous path and its output is persisted,
but that architecture does not make these failing timings acceptable or prove
input/frame responsiveness. Full Mail source/UI integration remains the immediate
priority; parser/cleaner throughput and physical performance remain open.

### Body extraction in progress

`MailMIME` selects decoded text/HTML and records attachment/invitation metadata
from the already parsed Gmail tree. It reuses Foundation Base64 decoding and the
existing `MailCharset` policy, with depth, part-count and decoded-byte bounds.
The [Gmail resource definition](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages)
confirms that payload is a parsed MIME structure; a separate raw-message MIME
parser would duplicate provider work. The existing
[SwiftSoup dependency](https://github.com/scinfu/SwiftSoup) remains the HTML parser
candidate, rather than a handwritten HTML parser or WebKit text conversion.

This extraction is not yet wired to the live sync driver or reader. Related-root
and multiple-inline-section selection now have targeted correctness coverage;
broader provider parity, hostile-content preparation, attachment body fetches,
HTML sanitization and rendering still require implementation/parity checks before
claiming body-readiness. Do not describe the current extractor as a complete mail
renderer. Limits must remain visible outcomes, not silently empty messages.

`.build/mail-index-20261011/run-6` passed 32 checks. Its retained extraction
samples (8 per size, no result cache) measured median/max 1.323/1.380 ms at
63 KiB, 5.250/5.484 ms at 261 KiB, and 41.058/41.581 ms at 2 MiB. These are
component preparation times on this Mac, with another xcodebuild observed during
the run; they exclude storage, HTML parsing and rendering and are not clean
baseline or input/frame acceptance. The 2 MiB work belongs off the UI thread.
Earlier 29/31-test snapshots remain retained as runs 4/5.

The next selection regression reproduced three assertions in `run-7`: mixed
inline text was replaced by the last section, and a related resource displaced
the designated root. `run-8` passed 36 checks with container-scoped selection,
ordered inline sections and escaped plain sections in combined HTML. Leaf-body
timings remained similar (2 MiB median/max 42.119/42.481 ms before and
41.237/42.163 ms after); this is a correctness repair, not a demonstrated speedup.
Compound extraction costs and integrated rendering remain unmeasured.

The registered blob schema and `MailBlobStore` now commit original headers,
structure and selected body content together, invalidate prepared content on
replacement and reject incomplete replacements. `MailBlobCodec` uses Apple's
Compression zlib implementation with a versioned bounded-length envelope, not
unbounded decompression. `run-9` passed 39 checks including codec corruption,
Unicode/incompressible bytes, account isolation and incomplete replacement.
This is cache persistence, not durable mutation intent or live Mail readiness.
`run-10` also passed all 39 checks after adding closed-store/reopen body readback.
Body-store throughput/latency, full app builds and device UI remain outstanding.

The October 11 metadata importer now maps fetched Gmail headers/labels into
message rows and rebuilds conversation summaries from stored effective facts.
Unknown label fields preserve prior state; newer explicit empty labels clear
provider membership; local overlays remain separate. Tombstones prevent late
responses from resurrecting deleted messages, and stale history is rejected.
Full payloads are not marked body-persisted by this metadata-only path.

`.build/mail-index-20261011/run-3` passed 24 tests (seven importer, five writer and
twelve existing schema/reader checks), including the unchanged paging matrix.
`run-1` retains a test compile failure from a missing `try`; `run-2` passed its
22-case snapshot. The final run has two existing GRDB Sendable warnings and no
new-source warnings. Provider sync, body storage, source/UI wiring and integrated
search still remain. These results do not establish full-app performance.

`MailIndexWriter.rebuildThread` now persists derived summaries and replaces
message-owned view membership in the caller's existing index transaction. It
returns both old and new affected view keys for post-commit observation, keeps
account identities separate, and preserves independently owned scheduler and
attention fields. This takes complete effective message facts; the raw provider
importer, body storage and sync checkpoint integration remain missing.

`.build/mail-index-20261010/run-7` passed all 17 index tests, including five
writer cases for reopened-database readback, membership replacement, account
isolation, rollback and metadata preservation. It also reran the unchanged
180,000-conversation paging matrix. This adds correctness evidence, not an
integrated Mail performance claim; full app regression and device checks remain
outstanding. The earlier `run-6` passed its 16-case source snapshot and is retained.

The [index report](scale-results/mail-index-20261010/README.md) retains migration
registration, a complete 6,001-row paging walk and the 180,000-conversation cost
comparison. Bounded keyset reads work beyond 2,000 rows in the database; the UI
cap and growing-list contract have not yet been changed. This is not connected
Gmail and does not close physical Mail responsiveness acceptance.

The auth integration compiled in both actual Release app targets with zero
build errors (`.build/mail-auth-20261010/{mac,ios}-verified-build.xcresult`).
They retain 33 warnings each from the existing app; no auth warning remains.
These are unsigned compile checks, not installed review builds or live OAuth
checks. The newer index files still require refreshed app builds after source
connection.

### Native startup observation

The newly compiled Mac Beta was opened through native UI automation with no Mail
fixture arguments. Mail displayed the live account connection controls and an
empty list, rather than fixture messages. No Google account is connected in this
Beta, so real consent/download verification still requires the user. No account
permission was granted and no real message was changed.

The observation caught two stale sample labels in the live screen. The source now
shows those labels only for an explicitly marked sample session, and live empty
states distinguish downloading, failure/retry and no downloaded mail. The new
message control is disabled until durable composing is implemented. The refreshed
`review-mac.xcresult` compile succeeded. Native UI re-verification confirmed the
sample notice is absent, the live empty state is present, composing is disabled,
and submitting then clearing a search returns to Inbox. This used an empty local
mail store with no connected Google account; it is not provider or populated-list
acceptance. `review-ios.xcresult` passed the unsigned iPhone/iPad compile check.

### Label action rules

`OutboxRules` now translates archive, inbox, read/unread, star, importance,
trash/restore, spam, labels and moves into exact message-label assertions. It
excludes drafts, unconfirmed/kept-deleted messages and messages newer than the
provided cutoff. Unknown label absence never makes a removal moot. Scheduling and
mute explicitly remain unsupported until their durable label/scheduler rules are
connected; no success-shaped empty result conceals that gap.

`.build/mail-download-20261011/action-rules-1` passes four new rule cases; 74/75
engine tests pass overall. Large HTML preparation still fails its existing budget.
These rules are not yet delivered to Gmail or enabled in the UI. No real messages
were changed. This is correctness evidence, not a measured speedup.
