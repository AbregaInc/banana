# Earlier Beta Mail stores

Earlier Beta builds shipped index migrations through `v13-known-header-dates` and intent
migrations `v6-local-drafts` and `v7-block-rules`. The cloud release branch omitted these names.
GRDB therefore correctly refused the existing stores as newer than the code, and Mail startup
showed its saved-data failure before offering Google consent. Retrying could not resolve it.

`MailLegacySchema` retains the exact shipped schema steps. Existing indexes, identities,
block-rule records, attachment files and action journals remain intact. Unknown migration
names still refuse to open. There is no database deletion, replacement or unknown-version bypass.

The old `draft` rows remain untouched. A bounded, transactional import copies their editor
content into the account-bound cloud draft outbox, with an import receipt preventing repetition.
Only currently connected Google identities qualify. Existing outbox rows are never overwritten.
Local attachment paths and known Gmail draft/message IDs are retained.

Ordinary saved drafts remain drafts. A previous upload/send/schedule requiring review becomes
an uncertain record that cannot automatically submit work, be edited or be sent. The existing
question UI offers **Keep as draft**; that explicit choice resumes draft editing, never sending.
Terminal sent/discarded records remain terminal. The original legacy journal remains available
for reconciliation and evidence; it is not erased by import.

Validation covers old-schema reopening, retained rows, owner filtering, idempotency, unknown
future-schema refusal, interrupted sends and explicit keep-as-draft behavior. An optional private
SQLite backup of an installed Beta reproduces the original refusal and verifies the corrected
opening and saved-draft recovery. No user database is modified by these tests.

The repair passed 51 targeted Mail tests. Separate checks against retained Mac and iPad
Beta data reproduced the refusal and opened both stores successfully; the Mac fixture also
verified saved-draft recovery. Device installation and live provider consent are separate
acceptance steps.

The repaired iPad Beta was installed and launched. A post-install copy of its intent database
confirmed `v7-legacy-beta-import` was applied; its copied startup log contained no Mail startup
failure. Gmail consent and live inbox sync remain separate, unconfirmed steps.

Both iOS and Mac Release builds passed. The component regression suite completed all eight
scenarios but failed seven RSS comparisons and the seven-day Notes search p95 comparison
(8.493 ms versus an 8.389 ms limit). Results are retained privately in
`private/cloud-rollout/mail-legacy-performance`; no baseline or limit changed. Physical UI
performance was not measured. The Mac build is prepared, not installed over the running app.

## History replay recovery

A subsequent device diagnostic identified `MailHistoryRules.Failure.incomplete`: successful
provider responses reached the client, but a rejected history batch retried indefinitely.
The sync worker now rolls back an unusable history page and conditionally expires only its
own saved checkpoint. The existing bounded reconciliation then reacquires a current mailbox
position and verifies message state. It does not infer deletion from incomplete history or
clear cached mail, drafts, pending actions or removal holds. Transport failures retain their
existing retry behavior. This recovery can require a full mailbox scan; it is not a speedup.

The targeted history, checkpoint, reconciliation and verification suite passes 37 tests,
including partial-page recovery and convergence to a newer checkpoint. Private results:
`private/cloud-rollout/mail-history-recovery-final`.
