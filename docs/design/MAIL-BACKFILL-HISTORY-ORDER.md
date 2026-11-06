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
