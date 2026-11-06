# Preserve newer Gmail history during backfill

A listing continuation belongs to the reconciliation scan that created it. It is
not fresh evidence merely because an intervening history poll advanced the account
checkpoint. Previously, a message archived at the current checkpoint could regain
INBOX membership from an older listing because the comparison used that current
checkpoint rather than the scan's original position.

Listing membership now compares against `State.startedAt`. New listing stubs also
carry that scan position, allowing later history to supersede them. Newer message
state is preserved and ambiguous listing results enter the existing verification
queue. This does not change Gmail, delete cached messages, or discard local intent.
It prevents the race; already stale membership still needs normal history or
per-message verification. A complete shared cloud backfill remains separate work.

The new regression failed on the previous implementation (INBOX was restored and
verification was not queued). The corrected implementation passed 37 focused
reconciliation, mailbox, history, checkpoint and importer tests, including a second
case for a new stub encountered after the account checkpoint advances. Evidence is
retained privately under `private/cloud-rollout/archive-order-before` and
`archive-order-after`. These correctness results do not establish physical UI
performance or prove the cause of a specific device's stale Inbox.

Gmail history is chronological; list continuations must not override newer message
state. Reference: https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.history/list

## Inbox repair must not wait for historical mail

An already stale Inbox used to wait for every label and the unfiltered mailbox
listing to finish before missing membership was verified. Inbox listing now yields
to a bounded local scan (100 cached entries per transaction) and minimal provider
verification (up to 50 requests, at most four concurrent). Read results can update
labels during backfill. Absence never deletes a message; removal decisions and scan
completion remain gated on the terminal verification phase. Optional bookmarks
resume older persisted scans without discarding their progress.

## Experience priorities

1. Persist local intent and show the optimistic result immediately; failures remain actionable.
2. Consume provider changes before older-mail enumeration.
3. Verify the currently relevant mailbox before historical backfill; Inbox is the first implementation.
4. Prioritize visible content, then adjacent content, then historical bodies.
5. Treat list continuations as older evidence; newer history and confirmed metadata win.
6. Report currentness honestly, including offline, catching-up and failed states.

Cross-device consistency ultimately needs one cloud-owned provider cursor and
shared ingestion/cache, with devices consuming Banana changes. The current proxy
and quota coordinator do not implement that. General visible-mailbox prioritization,
push-triggered cloud ingestion and shared backfill remain explicit follow-up work;
this release implements Inbox-first verification and the history/list ordering rule.

Validation of Inbox-first verification: the full Mail engine run executed 265 tests.
The new archive, Inbox-priority, bounded-bookmark and old-state decoding cases passed,
as did the related sync and verification cases. The full suite is **not green**:
`MailHTMLPreparerTests.testPreparationCostForGeneratedHTML` exceeded 100 ms in eight
samples (188–204 ms), and the optional installed-data migration test skipped because
no private fixture was supplied to that run. Retained evidence:
`private/cloud-rollout/inbox-priority-verified`. The initial focused run also retained
two failed expectations for the old listing order; those tests were updated to assert
the new explicit Inbox yield and resume behavior, without changing time budgets.

Final focused validation passed 50 tests, including the new on-disk Inbox case:
100 entries per transaction from a retained 100,000-entry Inbox took 11.31, 11.70
and 11.68 ms. This measures that bounded transaction, not UI input latency or an
optimization comparison. Evidence: `private/cloud-rollout/inbox-priority-final-check`.

The persistent Simulator component gate ran with unchanged budgets and failed:
RSS exceeded the baseline/ceiling for scale-1d (362.84 MB), scale-7d (402.48 MB),
Library redraw (485.77 MB), Plan redraw (503.27 MB), and Mail redraw (484.80 MB).
The 1-day sample also had incomplete host monitoring or competing-workload evidence.
There were no reported latency failures. Retained gate:
`private/cloud-rollout/inbox-priority-performance/gate.json`. No physical 120 Hz or
input-to-visible UI acceptance is claimed. These remain experimental Beta builds.

## Linked accounts define the unified mailbox

A repaired provider account does not prove the unified Inbox is current. Legacy
local indexes can retain accounts that are no longer linked to Banana Cloud. Those
accounts have no sync worker, so including their cached rows shows indefinitely
stale membership. Both devices exhibited this after the Inbox-first repair.

The live source now supplies the current linked-account set to list, count and
search SQL before pagination. An empty set returns no rows. Sidebar labels use the
same set, and account changes invalidate cached first pages and refresh observers.
Mail grant availability is deliberately separate: a still-linked account keeps its
cached mail readable when its grant is unavailable. Unlinked caches are preserved
on disk; this change neither archives provider mail nor deletes retained data.

Regression coverage includes newer orphaned rows crowding out a linked account,
search, counts, account removal, empty scope and retained cache preservation.

Account-scope validation passed 38 focused tests. A disk-backed 180,000-thread
fixture with only the oldest 50 threads linked returned the correct page and count
in 94.73, 93.22 and 93.43 ms, within the unchanged 100 ms component limit.
This is correctness/budget evidence, not a speed improvement or physical UI
measurement. Evidence: `private/cloud-rollout/account-scope-final`.

Build 100 (`3b66ffa7`) was installed on the phone and iPad, and both reported the
expected installed version. The iPad launched; the phone installed successfully
but its lock prevented launch. Remote screenshot capture was unavailable, so visible
Inbox acceptance remains pending. Installation and a changed database count must
not be reported as proof that the screen matches Gmail. Private device evidence:
`private/mac-distribution/beta-100-*-apps.json`.

The build-100 persistent component gate failed its unchanged memory comparisons:
scale-1d 362.77 MB, scale-7d 364.52 MB, scale-90d 703.98 MB, Library redraw
485.80 MB, Plan redraw 503.56 MB and Mail redraw 484.97 MB. The 1-day case
also lacked clean host-monitoring evidence. No latency failures were reported.
All samples remain in `private/cloud-rollout/account-scope-performance/gate.json`;
this is not a passing performance gate or physical-device UI acceptance.
