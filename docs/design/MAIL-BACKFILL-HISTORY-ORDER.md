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
