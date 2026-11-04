# Pi on the public repository

The Pi branch is rebased onto public `origin/main` at `c1046202`. Its 27 development commits and subsequent fixes are consolidated into one commit above that public history. The old private ancestors are not part of the rebased branch. Local backup references and the pre-rebase stash are retained.

The public root was exported from an old-history commit with an identical file tree. That relationship identified the original fork for the rebase; no replacement refs or artificial merge ancestry remain.

Integration retains main's Mail module, module visibility, shared-calendar ownership/availability rules, paged note storage, durable calendar writes, and current shared screens. Pi's workspace, native review editors, sample workspace, local model, and Mac chat panel are adapted to those APIs. Conflicting older shared-screen redesigns yield to main's current screens; the original development branch remains in the local backup. Assistant note saves now use the repository's durable persistence path; assistant meal saves retain full history and update the store revision and sync notifications.

## Conversation clock repair

Each submitted turn gets a native clock snapshot: local date, instant, IANA timezone and UTC offset. Capability selection and argument extraction retain that snapshot. A latest-message relative day such as “tmrw” remains `tomorrow` in the native agenda request, even when a previous response contained an absolute date. Native code resolves the day when executing the tool. Fixed-clock regressions cover crossing midnight, changing timezones and daylight saving time.

## Public evidence

New retained evidence and documentation are scrubbed using the repository's private-text rules. The deny list stays outside the repository. The configured pre-push hook checks every outgoing commit, including historical commits, and refuses private text or tracked `private/` content.

Older benchmark reports describe their original executions. Public redaction can change exported bytes; original recorded hashes are provenance of the execution inputs, not claims that the redacted export has identical bytes. The historical 900-case qualification is not a new 900-case run of the rebased clock-aware policy.

## Validation

- Mac Pi build passed after resolving the shared-component and storage API changes.
- 35 routing/clock unit checks, 13 workspace conformance checks, 12 provider conformance checks, and 10 evaluation-scorer tests passed.
- [Five fresh local-model overnight cases](pi-apple-host-results/overnight-public-v1.json) passed, including the exact “what about tmrw” follow-up with a stale earlier agenda date.
- [Full-app workspace verification](pi-apple-host-results/public-rebase-workspace.json) passed: clock changes, source timezone/flight checks, review/save deduplication, draft provenance, restored conversations, and unsupported-action boundaries.
- [Full-app nutrition verification](pi-apple-host-results/public-rebase-nutrition.json) passed: charts, filters, meal search, copying, save deduplication, and restore.
- Validation in this integration is for Mac Pi. It does not certify a new iPhone/iPad UI run or UI performance.


The [final isolation run](pi-apple-host-results/public-rebase-isolation-workspace.json) repeated workspace acceptance while checking the personal notes database, WAL and shared-memory files as well as existing history, meals and preferences. All checks passed.

During final validation, main advanced from `872bd4bc` to `c1046202` with Service/web-only changes. The final rebase applied cleanly; native Pi sources and the tested installed binary were unchanged by that update.
