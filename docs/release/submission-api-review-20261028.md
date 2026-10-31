# App Store final API review — 28 October 2026

Build selection and binary freeze are now superseded by [candidate 83](candidate-83-20261029.md).

Status: API preparation complete; **not submitted**. Both releases remain manual.
The owner asked to finish API checks while the Mac remains locked. Google sign-in
and the final browser-only checks are therefore still pending.

## Saved and verified

- Dedicated reviewer credentials are saved in Apple's private App Review fields on
  both iOS and Mac drafts, and synchronized with TestFlight review information.
  Password write/readback matched. No credentials are stored in this repository,
  public listing copy, notes, or screenshots.
- Both drafts and TestFlight have the same numbered walkthrough: public sample-data
  entry, editable fictional content, how to leave demo and sign in with Google,
  account deletion, optional permissions and the limits of simulated integrations.
- Both Store drafts select build 82, processing VALID, App Store eligible,
  nonexempt encryption false, PREPARE_FOR_SUBMISSION, release MANUAL.
- Reviewer contact fields are populated on both drafts. No review submission exists.
- All 23 live image placements match local SHA-prefix references and file sizes:
  seven iPhone, six landscape iPad, three Watch, five Mac and two creative assets.
  All images have editable draft status. Local media/copy validation passes.
- The Apple-silicon/macOS requirement sentence was missing from live descriptions;
  the prepared copy was applied and read back on both drafts. Keywords, promotional
  text, name and subtitle were included in the draft synchronization.
- Price is USD 0 with automatic equalization. All 175 configured territories are
  available and new-territory availability is enabled. Their unreleased-app sale
  status is expected before approval/release.
- Support, privacy, terms and cloud-app URLs return HTTP 200 with a normal browser
  user agent. Initial default Python-user-agent failures are retained separately;
  these are not represented as a live browser outage.
- iOS archive release gate and signature passed. The Mac archive release gate,
  arm64-only architecture and signature passed. The initial Mac path assumption
  was wrong; that failed attempt is retained, followed by the corrected check.

## Remaining before final approval

1. Sign into the supplied Google account through the actual review flow. Verify
   password/verification prompts, Calendar authorization, useful fictional calendar
   content and live event edits. Saving credentials in Connect does not prove Google
   accepts them. Do not weaken the account's security to bypass a blocked login.
2. Recheck browser-only privacy/medical-device declarations, agreements and Connect's
   final readiness screen after the Mac is unlocked. The published privacy evidence
   from 24 October remains available; it was not newly verified through the API.
3. Freeze the exact release binary. Selected Store 82 is the previously archived,
   tested candidate (native archive commit 09f55521). The current local install also
   uses number 82 but includes later uncommitted native changes, including podcast
   peer-transfer hardening and transcript parsing. Those changes are not in the
   selected Store archive. Including them requires a new build number and relevant
   regression/architecture/signing gates; do not claim the two build-82 binaries
   are identical or reuse the earlier archive's source-unchanged attestation for them.
4. Owner reviews the final package and explicitly authorizes review submission.
   Manual release remains in effect after approval.

The retained build-82 full functional run and repairs are documented in
[the dimensional rollout](dimensional-brand-82.md). Its performance component gate
was unmeasured because of an Xcode-version mismatch; no baseline was changed and
no physical 120 Hz/input-latency acceptance is claimed. Physical iPad XCTest and
Watch Night Mode evidence remain the previously disclosed limits.

## Follow-up from the linked Twitter post

- Public Beta/Coming Soon presentation: fixed in build 80 and retained in 82.
- Concrete reviewer walkthrough: now saved on both drafts and TestFlight. Real
  Google login/content verification remains open as described above.
- Short reviewer demonstration video: still optional and unmade. The calendar-only
  blog fixture recording is not a full account/module/Watch reviewer demonstration.

Apple's current [Before You Submit guidance](https://developer.apple.com/app-store/review/guidelines/#before-you-submit)
requires complete metadata, reviewer access and live backend services. It does not
establish the article's turnaround promises or queue-shortcut claims.

Private evidence: `~/Library/Logs/Banana/SubmissionFinalReview-20261028/`.
Reviewer passwords are not written into the local evidence files, repository or
report. Apple stores them only in its designated private review-access fields.
