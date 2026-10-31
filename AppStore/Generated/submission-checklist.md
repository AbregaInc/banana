## Candidate 83 — 29 October 2026

Both iOS and Mac build **83** uploads are VALID and selected in their
MANUAL / PREPARE_FOR_SUBMISSION drafts. Apple reported no upload errors/warnings.
No App Review or new Beta App Review submission has been made. Reviewer credentials
and notes remain saved only in Apple's private review fields; actual Google login
and final browser-only checks still require an unlocked Mac session and owner review.

The combined functional gate covers 93 targeted native cases and 251 passing UI
cases, with the same 23 skips across the full 274-case UI workload. All original
failed runs and passing focused repairs are retained. The first iOS upload's Watch
architecture rejection was fixed by using standard iOS/Watch architectures while
keeping Mac arm64 only. The corrected Watch app/widget both contain arm64 and
arm64_32, and the local release gate now verifies these slices before export.
Performance acceptance remains unmeasured against the retained Xcode-mismatched
baseline; no budget or baseline was changed. See [candidate 83](../../docs/release/candidate-83-20261029.md).

## Final API review — 28 October 2026

Reviewer credentials are saved and read back in both App Store drafts and TestFlight
review information. Numbered sample-data and live Google walkthroughs are synchronized.
Both drafts still select VALID build 82, remain PREPARE_FOR_SUBMISSION and MANUAL;
no review submission exists. All 23 live media placements match the prepared files,
all 175 territories are enabled, pricing is free, and Apple-silicon requirement copy
is now synchronized. Browser-agent support/privacy/terms/cloud URL checks return 200.

**Final approval is still pending:** actual reviewer Google sign-in/content checks,
browser-only declarations/readiness checks, and freezing the exact binary. The local
build numbered 82 contains later native changes absent from the selected Store 82;
including them needs a new build number and validation. Detailed results and limits:
[final API review](../../docs/release/submission-api-review-20261028.md).
No password is stored in source, listing copy or review notes.

## Public module presentation — 25 October 2026

Owner approved removing Email from public Settings/onboarding and removing preview badges from
released optional modules. Separate Beta retains Email and Beta labels. Candidate **80** passes
4 focused UI and 10 module model checks, with no failures/skips. Both signed archives pass strict
signing and Email exclusion, uploaded and processed VALID, and are selected in the iOS/Mac drafts.
Final readback confirms **MANUAL / PREPARE_FOR_SUBMISSION**, nonexempt encryption false, and no
review submission. Draft descriptions/review-note policy and generated metadata match.
Normal 80 is installed/read back on iPhone/iPad and installed/signature-verified on Mac. Separate
Beta remains 79 (policy unchanged). Watch remains 79 because its connection is unavailable;
no update was forced. Current evidence: [public modules](../../docs/release/public-modules-20261025.md).
Earlier 79 full-run/performance limitations below remain recorded; this scoped change does not
claim a new full-suite, physical iPad XCTest, or timing pass. Reviewer Gmail and owner approval
are still required before submission.

## Owner-authorized launch preparation — 24 October 2026

The owner authorized final correctness checks, archive/upload/build selection, refreshed Plan
screenshots and publication of the approved privacy/listing declarations. Reviewer Gmail will
be provided later. **Public App Store and new TestFlight review submission remain on hold.**
Both iOS and Mac release methods are now **MANUAL**, verified by API. The 19-type App Privacy
declaration is **published**, verified in Connect with screenshot/AX evidence. Existing rights
and non-trader declarations are owner-approved.
Strict numerical performance optimization is follow-up after the owner clarified launch scope;
existing failures and engineering budgets remain unchanged. Physical iPad testing was explicitly
deferred after Apple's XCTest authorization prompt. No QA note was created.

Current execution and evidence: [launch preparation](../../docs/release/launch-preparation-20261024.md).
This section supersedes earlier unpublished-privacy and no-upload-authorization notes below.

Seven fresh iPhone captures use tested executable 79. Five Mac and six landscape iPad captures
show the shared layout from executable 78, with actual hashes retained; Watch artwork is
unchanged. All screenshot and header/search creative draft placements are verified. Matching
website derivatives are deployed and all nine live image hashes match. Candidate **79** fixes
a newly found onboarding-to-Week crash; all 15 focused checks pass. Full 79 regression is
complete: 242 passes, 3 failures and 23 skips; all three findings are closed by retained focused rechecks. Both signed 79 archives
pass signing/Email exclusion. Normal and Beta 79 are installed on the primary phone, iPad and
Mac; Watch 79 is verified too. Both 79 uploads succeeded, processed VALID and are selected in both drafts. Final API readback
confirms MANUAL / PREPARE_FOR_SUBMISSION and no nonexempt encryption on both platforms.
No review submission has been made.

## Historical candidate follow-up — superseded by current status

Candidate 78 adds final Watch stop/start and note-deletion safety fixes to the initial 77
validation candidate. Both main/Beta 78 compile and are installed on iPhone, iPad and Mac.
Watch 78 is also installed and verified after the owner returned home. iPad 78 live navigation
passes 2/2; iPhone 78 main/Beta live navigation now also passes 2/2. The controlled Watch
Strength recovery and one-workout durable phone receipt pass; physical performance remains open.
The 78 archive attempt was stopped after a real onboarding crash was found; it was not uploaded.

Build 77 finishes the shared routines/reminders band, adds Watch active-session recovery and
repairs note-reminder lookup after a device-local EventKit identifier changes. Main/Beta 77 are
installed on the owner's iPhone, iPad and Mac, and Watch 77 is installed. Current validation and
remaining physical gates are tracked in [the acceptance follow-up](../../docs/release/acceptance-20261024.md).
The public App Store drafts remain on build 76 and **submission stays held for owner review**.
No TestFlight review request or App Privacy publication has been made for this follow-up.

# Banana App Store submission checklist

`validate.py` checks media format and copy limits. Passing it does not establish that captures
are current or that a release is ready. The following
items require real business information or an App Store Connect decision and are intentionally
not invented by the generator.

## Active follow-up — 23 October 2026

Latest artwork follow-up: **build 76**, native source `483cc478`, replaces app icons and
in-app/Watch branding with the owner's supplied mascot. Both supplied files are preserved
unchanged in Brand/. Native/store exports are full-bleed and opaque where required; Beta
adds a badge above the left eye. All 23 catalog icon exports validate, and compiled main/Beta
icons were inspected. Main and separate Beta 76 are installed and verified on the owner's
phone, iPad and Mac. The Watch remains unavailable; its updated companion is in main iOS 76.
The Pi branch released both physical devices before these installs and was notified afterward.

The website mascot/header/favicons are deployed and byte-verified, with versioned asset URLs
to avoid retaining the previous icon in browser caches. Production/beta cloud app marks and
favicons are deployed and byte-verified too; 17 focused web tests pass. Both build 76 archives passed
the no-unreleased-Email check, uploaded, processed VALID and are selected in the editable
public drafts. Both remain PREPARE_FOR_SUBMISSION. Apple’s full-size iOS/Watch icons match
the new master pixel for pixel; its Mac preview matches the compiled icon. No public or
TestFlight review submission was performed. Existing functional evidence below is reused for this resource-only change; no Swift implementation,
performance budget or baseline changed. Detailed records are under the audit's `icon76/`.

The following build 75 review records the functional/legal baseline for the icon follow-up.

Candidate build **75**, source `96c0d987`. Main Banana and separate Banana Beta 75 are
installed and verified on the owner's iPhone, iPad and Mac. Initial connection failures were
resolved by the follow-up installation; both iOS devices have both variants. The Watch remains
unavailable and its installed version is not verified. Build 75 changes only bundled third-party
license notices and the version relative to tested 74; all eleven pinned Swift package licenses
are now included, with a reproducible notice check and archive-byte verification.

iOS TestFlight **75** is live internally and externally, with group membership verified. Mac 75
archive is uploaded; its review publisher was stopped at the owner’s explicit request.
Mac 74 remains available internally, with external Beta Review last observed pending. iOS public
and Mac public drafts now both select processed, verified build 75. Both remain
PREPARE_FOR_SUBMISSION. **Do not submit either platform, publish App Privacy, or submit a new
TestFlight review until the owner has reviewed and authorized it.** iOS TestFlight75 preceded
that hold. Continue preparing fields/assets. This section supersedes historical findings below.

The brand uses the supplied mascot, IBM Plex Mono, cream/ink/yellow and pastel
panels. Main/Beta icons, in-app mark, screenshot compositions, optional creative artwork and
English store/TestFlight materials have been refreshed. Fresh real iPhone, iPad and Watch
captures have product/raw hashes in `AppStore/Generated/capture-status.json`. Mac raw captures
are now refreshed, visually checked and composed. Sleep requires selecting its Review row;
the legacy launch route opens the Review list. The phone continuity inset and product-page
header use the fresh Mac capture. The optional video remains a storyboard.
Review package: http://100.89.44.104:8899/ while the local preview server is running.

Owner requested landscape iPad artwork. All six iPad scenes were recaptured in actual
landscape on the existing simulator after coordination with the Pi branch. Raw and composed
images are 2752 × 2064; copy sits beside the complete app screen. The physical iPad and phone
were untouched. Capture-product version/hashes are retained explicitly rather than relabeled
as build 75; no app source or binary was changed. Apple processed all six landscape images;
the six unpublished IPAD_13_PROFILE placements and their order are verified.

Seven listing checks pass, including indexed Calendar and optional module names with the new
website tagline. The refreshed keyword field is exactly 100 UTF-8 bytes.

Three English text drafts were updated and read back in Connect. Six new iPad library images
and three new Watch images finished processing and their unpublished placements were verified.
All seven iPhone, five Mac and both optional creative assets subsequently processed; their
unpublished placements and order were read back. Website screenshot derivatives are deployed.
These operations changed draft metadata/media; no public submission was made.

The privacy policy and refreshed site images are deployed and the live policy matches source.
It now explains approved guest sharing, the separate Beta-only Gmail preview and incomplete
legacy cleanup without claiming that all prior copies were removed. A source audit also found
three omitted contact categories: Google profile Name, and Phone Number/Physical Address in
native Booking settings. The embedded manifest and App Privacy worksheet now declare those
linked for App Functionality. Six privacy-contract checks pass, after retaining the initial
failures proving these omissions. The live Connect questionnaire now has all 19 data types
configured and read back: 17 linked,
Crash/Performance Data unlinked, no tracking, and purposes matching the worksheet. It remains
an unpublished draft for owner review. The US base territory and customer price $0 were read
back. With owner confirmation, availability was configured for all 175 supported countries and
regions (including future regions); the UI verifies Available on App Release. The owner also
confirmed necessary content rights; USES_THIRD_PARTY_CONTENT was saved and API-read back.
The existing non-trader DSA designation was observed and left unchanged.

Health/food inventory counts were also removed from optional usage collection: meals in the last
week, supplements and saved foods. Native batch serialization filters old queued counts, and
both deployed service variants discard them from older clients. Nine native collector checks
and all **265** service tests in each of UTC and America/New_York pass. The initial failing
privacy tests and final results are retained. Historical analytics entries were not deleted;
the policy states that separately. This is data minimization, not a UI speed claim.

Notes now commits a local reminder intent with the note, then writes EventKit from that durable
queue. Retry locates the stable note URL before creating another reminder. Acknowledgement and
intent removal are atomic, newer edits retain pending work, remote imports do not enqueue new
reminders, and deletion cancels pending work. Links open the matching main/Beta app. A failure
banner offers Retry. The pending query is bounded by the outbox rather than all retained notes.
Real EventKit interruption/relaunch and concurrent cross-device acceptance remain required.

Health-file writes protect staging before bytes are written, exclude the replacement inode
before atomic rename, and preserve the old destination on failure. Existing health/food files,
workout/photo directories, quarantine files and Watch summary are covered. App-owned iOS/Watch
Preferences directories are excluded too, including native atomic replacements; sandboxed Mac
containers receive the same protection. Unsandboxed Mac global Preferences are deliberately
untouched. These checks do not certify every legacy state, backup or data-retention policy.

Validation: **16** native Notes/file-protection tests and **21** recent-meal persistence checks
pass. The focused phone checks and all three unique iPad checks pass after documented harness
repairs. Five media-validator checks pass. The full phone run finished with **222 passes,
23 failures and 23 skips**. Subsequent focused runs have passing results for every one of the
23 failed cases: 22 in the first repair run, then the remaining scheduled-mail flow. Repairs
isolate orientation, pin calendar mode/zoom, use the modern accessibility element type, reveal
lazy/offscreen content and dismiss a confirmation overlay before touching its covered control.
The failed full result and passing follow-ups remain retained; this is not a green full rerun.

The partner's TestFlight device reports **1.0 (73)**. The paired spare phone is a
different device, so its old version does not explain the supplied screenshot. Their remaining
Busy duplicates are **not yet resolved**. A source fix adds an anonymous, explicitly shared
calendar troubleshooting report; 28 native calendar tests pass, including privacy/linkage checks.
The owner and guest web API field masks separately omitted identity fields needed for merging;
that defect is repaired and deployed to both environments. All 267 service tests pass in both
time zones. This cloud correction is not evidence of a fix on the partner's native phone.

Owner-side sharing API reads were attempted on all six owned calendars. Google rejected every
request for insufficient authentication scopes. A separate read-only ACL consent is required;
no sharing changes were made and permissions remain unknown. The owner explicitly deferred
sharing investigation and additional consent; do not hold the remaining rollout on it.

The owner declared general wellness/planning intent with no regulated-device claims. That
answer is now saved in App Store Connect and visibly verified as not a regulated medical
device in any country or region.
The age questionnaire's medical-information answer was corrected from NONE to INFREQUENT,
matching the conditional medication-timing guidance in Nutrition. The write and readback are
retained; Apple's API reports legacy TWELVE_PLUS. The current Connect preview is now verified: 13+ in 172 regions, with regional exceptions, and earlier
OS global 12+. This age answer is separate from regulated-medical-device intent.

The persistent component gate remains **UNMEASURED**: Xcode 27.1 differs from the 27.0 reference,
including on the exact reference simulator. No budget or baseline changed. A controlled
100,000-note SQLite query comparison measured cache-evicted p50 5.52 ms before / 0.039 ms after;
this is query evidence, not physical frame/input acceptance. Device-visible performance,
Watch recording recovery and final signed release checks remain separate gates.

Reviewer contact first/last name, email and phone have now been copied from the existing Beta
Review contact into both public drafts and read back. Review notes were updated and read back
for both platforms, including the general-wellness intent. Dedicated connected-calendar reviewer
access remains outstanding.

Before submission: obtain owner review/authorization; finish connected-calendar App Review
access and final release-policy review; publish the reviewed App Privacy draft; select the
selected final builds; complete physical acceptance and the
legacy-data/Watch/EventKit gates above. All draft media is prepared for owner review. Evidence is retained in
`~/Library/Logs/Banana/ProductionReadiness-20261022/` (followup-evidence, fresh-captures,
store-text-applied, media-ipad, media-watch, notes-outbox-query and component-gate-reference-device).

## Live audit — 22 October 2026

This update supersedes the build/release state in the October 21 audit below.
Read-only App Store Connect checks at 22:58 UTC confirmed:

- Build **73** for iOS and macOS has been uploaded, processed, and is available to the
  **Banana Public Beta** TestFlight group (`IN_BETA_TESTING` externally on both).
  This is the **main Banana binary**, with Email excluded. It is distinct from the separate
  development-installed **Banana Beta** app.
- Main and separate Beta build 73 are installed on the owner's iPhone, iPad and Mac.
- Public iOS/macOS 1.0 drafts remain **PREPARE_FOR_SUBMISSION**; each still selects **build 7**.
  No public App Store review submission has been made.
- Reviewer first/last name, email and phone are empty on both drafts. No demo credentials
  are configured. Provide access to review the connected Google-calendar features and
  update reviewer instructions to the shipping behavior.
- Content-rights declaration is unset.
- Uploaded assets: seven iPhone, three Watch and four Mac screenshots, all COMPLETE.
  **No iPad screenshot set exists in Connect.** `validate.py AppStore/Generated` passes,
  including the generated iPad package; it still needs uploading and a current UI/copy check.
- Descriptions, keywords, support/marketing URLs and an age-rating declaration are present.
  The privacy URL is configured and responds HTTP 200. Presence does not establish that the
  current App Privacy answers or all age-rating answers match the shipping build.
- A pricing schedule exists. Verify the actual price and territories in Connect; this audit's
  availability API returned 404, which is not evidence that no territories are configured.
  iOS currently releases after approval; Mac releases manually. Confirm the intended policy.
- Both archived main executables passed `tools/check-release.sh`: no unreleased-module marker,
  Gmail endpoint or Gmail scopes. Current release notes/evidence are retained under
  `~/Library/Logs/Banana/RecentMeals-20261022/`.
- The completed full run originally had 210 passes, 30 failures and 23 skips. Subsequent
  targeted runs repair all failures (including failures encountered during repairs), and
  the saved-meal time change adds 27 passing model checks and three passing UI checks.
  This is not a new entirely green full run and does not establish physical frame/input
  performance acceptance. Finish the final real-device release acceptance before submission.

Current module policy, from `AppModules.swift` and `Features.swift`:

| Capability | Main Banana / current public TestFlight | Separate Banana Beta |
|---|---|---|
| Plan: calendars, reminders, routines, travel | Always on | Always on |
| Workouts and sleep, Food, Notes, Podcasts | Optional; labeled Beta | Optional; labeled Beta |
| Email | Disabled; Coming soon; implementation excluded | Optional; Beta; live Gmail integration under test |
| Guided workout plans/coach | Disabled | Disabled |
| Prepared calendar artwork | Off | On, experimental |

Module choices are adjustable in Settings > Modules. Beta uses separate local/iCloud/service
storage, writes Reminders only into its Beta list, and may mutate Google data only for
accounts marked as test accounts. It reads Health but does not write workouts into Apple
Health. The separate iOS Beta target does not embed a Watch app. Main TestFlight behaves
like main Banana, including the Email exclusion, rather than like the separate Beta target.

A Beta badge does not exempt an enabled main-app module from production completeness.
Review all enabled public modules against Apple's current guidelines; unfinished behavior
belongs in TestFlight. Final submission requires the review details/access, iPad assets,
content-rights declaration, checked privacy/age/export answers, confirmed commercial/release
settings, accurate metadata and selected final build. None of these declarations or business
choices were changed by this read-only audit.

Evidence: `/tmp/banana-73-store-audit.json`, `/tmp/banana-73-store-audit-followup.json`,
`/tmp/banana-73-public-privacy.html`, and the retained build 73 release evidence directory.

## Production module review — 22 October 2026

Scope: Calendar and every optional Beta-labeled module, including the separate Email preview.
Base distributed build: 73. The following source fixes form a new candidate; they are **not
present in the already-distributed build 73**. No App Store submission was performed.

### Confirmed issues fixed in this candidate

1. **Analytics consent (all modules).** `Telemetry.enabled` and Settings defaulted to on.
   Missing consent now means off. Usage and diagnostic sending share the same gate. Existing
   affirmative settings remain respected; declining clears pending reports. Terms acceptance
   does not itself enable analytics. Tests exercise absent, enabled, withdrawn and removed choices.
2. **Legacy health iCloud writers (Workouts/sleep and Food).** A bound install without a
   migration floor, or the diagnostic platform-off configuration, could allow health writes.
   The effective health mode now has an unconditional read-only floor. Completed off states
   stay off. Legacy reads/local edits are preserved for migration; consented service sync is
   untouched. The mixed iCloud Drive backup now retires whenever either tier cannot write,
   matching its actual write guard. This closes explicit legacy transport writes; see the
   separate OS-backup exclusion audit still open below.
3. **Podcast refresh.** A non-success HTTP response containing valid RSS could be returned as
   a fresh feed. Responses outside 2xx now fail before parsing/publishing. Empty 304 responses
   retain the old catalogue. Tests inject real URLSession responses for 401/403/404/429/500/503,
   304 and 200, without live network access.
4. **Medication rescheduling (Food/Taken).** Symmetric generic gaps are not a clinical schedule.
   Automatic supplement moves are now refused if any medication is logged or recognized. Timing
   findings remain informational; drug rows no longer prescribe a numeric target gap. The detail
   explains the limitations and links to MedlinePlus; nutrient information links to NIH. No
   prescription or supplement schedule is changed by this repair. Non-medication supplement
   suggestions retain their tests. This intentionally replaces the old UI expectation that
   Calcium would automatically move around a thyroid medication.
5. **Prepared store copy.** Source/generated descriptions incorrectly claimed no server and
   universal iCloud sync. They now describe account/service sync, Health consent and Apple
   Intelligence processing accurately. Review notes no longer claim demo credentials are already
   supplied. Privacy copy explains the optional sharing control. No live metadata or website
   deployment was made by these source edits.

Primary clinical cross-check: [MedlinePlus ciprofloxacin information](https://medlineplus.gov/druginfo/meds/a688016.html)
describes direction-dependent separation from some mineral products, illustrating why a universal
symmetric gap cannot justify automatic rescheduling. The revised UI does not provide a replacement
clinical timing algorithm. Retained generic interaction detection is not a complete safety checker.

### Module verdicts and evidence limits

| Module | Findings and current decision |
|---|---|
| Calendar | Retained build-73 Day/Week, event identity, Busy mirror, reminder and navigation repairs; fresh backend calendar checks pass in two time zones. Current physical frame/input, VoiceOver and rotation/resizing acceptance across all devices is not closed. No new renderer adopted. |
| Workouts and sleep | Health transport policy hardened. Health authorization, consent/revocation, adapter/snapshot/removal and sleep checks pass. Watch recording interruption/recovery and device endurance remain live-device acceptance work. Guided plans remain unavailable. |
| Food | Meal/health sync checks pass; unsafe medication auto-moves removed and verified in UI. Photo/AI estimates still require review. The limited interaction table must not be advertised as a clinical interaction checker. |
| Notes | Repository tests pass, and the composer preserves a draft when primary persistence fails. Further fault coverage is needed for Reminders write-back: `VoiceNoteStore` currently creates the external reminder before persisting several note paths; a disk failure can leave an unmatched external reminder. A durable/idempotent cross-store write-back repair is not supplied by the repository-only tests. |
| Podcasts | HTTP error handling repaired; episode browser/filter checks pass. Retained build-71/73 responsiveness feedback is useful but does not establish current physical frame/input budgets or all audio interruption cases. Podcast content rights and age-rating answers still need review. |
| Email | Remains excluded from main. Live sessions explicitly set `allowsComposing: false`; sample-mailbox writing tests are not evidence of real Gmail sending/draft integration. Auth/token checks pass, but live OAuth, implemented action coverage and provider recovery are not full production acceptance. Keep it separate Beta-only. |

Additional privacy verification: `HealthFoodKit` blob directories and the record mirror exclude
OS backups, but primary `health.json`/`wellness.json` and other local health paths need a complete
backup-exclusion review. Blocking CloudKit/iCloud Drive writes alone must not be presented as proof
that every backup path is compliant. Existing local or legacy data was not deleted by this review.

### Current Apple requirements checked

- [October 16 update](https://developer.apple.com/news/?id=92th7e5i): changes include UGC handling,
  creative assets and the relocated hidden/dormant-functionality rule. These changes do not make
  private notes into a public social network; review actual sharing/discovery surfaces separately.
- [Current review guidelines](https://developer.apple.com/app-store/review/guidelines/): apply
  consent, health-data handling, production completeness and feature transparency to enabled
  modules. Email exclusion and debug-only preview routes were inspected; a Beta badge is not
  a substitute for production readiness.
- [Regulated medical device status](https://developer.apple.com/help/app-store-connect/manage-app-information/declare-regulated-medical-device-status): our Health & Fitness secondary category triggers a
  regional declaration requirement. Current declaration status was **not verified** by the API
  audit. Confirm intended use and the appropriate declaration; do not invent regulatory approval
  or assume a disclaimer determines legal classification.
- Reconcile the age-rating Medical/Treatment Information answer (currently NONE) with the
  medication information actually displayed. Review podcast content descriptors as well.
- [October 15 SDK acceptance](https://developer.apple.com/help/app-store-connect/release-notes/):
  this host is Xcode 27.1 build 27A9275, the accepted release. Upcoming
  [SDK requirements](https://developer.apple.com/app-store/submitting/) take effect April 2027.
- [Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications): existing generated iPhone/iPad/Watch/Mac sizes remain accepted.
  Dedicated Duo screenshots become required in April 2027. Current iPad upload remains missing.
- [Creative assets rule 2.3.14](https://developer.apple.com/app-store/review/guidelines/#accurate-metadata): ensure optional new headers/search assets reflect real features; no new assets are invented
  or treated as a current mandatory blocker here.

### Validation and release limits

- Native candidate unit checks: **131 passed**, zero failures/skips, including new FeedParser,
  LegacyCloud and Telemetry cases plus AppModules, HealthAuthorization, HealthFoodAdapter,
  WellnessCloudSync, SleepNights, NoteRepository and PodcastEpisodeBrowser.
- Medication/backup/AI-routing/Health-removal unit checks: **53 passed**, zero failures/skips.
- Phone medication UI: **2 passed**, zero failures/skips. Existing simulator reused, headless.
- Email credential/token runner: **53 passed**; no real credentials/network/provider claim.
- Service: **264 passed in UTC and 264 in America/New_York**, patched Node 24.22.1 selected by
  the Service Volta configuration. No backend code changed.
- Generated media/metadata validation passes. This does not establish that the screenshots
  depict every current UI change or have been uploaded to Connect.
- Persistent component gate: **UNMEASURED** before build, because the checked-in reference is
  Xcode 27.0 and this host is 27.1. Only Xcode.app is installed. No baseline/budget/scenario changed.
- Native Mac main and Beta Debug compile checks both exit **0**, with existing compiler warnings
  retained in the logs. Scratch derived data was deleted after reading the results. This does
  not establish Release archive acceptance, visible native UI or physical performance.

Raw logs, exact source hashes, result bundles and the component gate are retained under
`~/Library/Logs/Banana/ProductionReadiness-20261022/`. Public draft metadata, declarations and
review submission remain as in the live audit above. The main app is still held for submission
until the candidate fixes are released/validated and the remaining acceptance and store fields
are closed. This is a review with identified gaps, not a blanket production certification.

## Required human-supplied fields

- [x] Support URL resolves publicly and provides support@abrega.com (checked 21 October).
- [ ] Privacy-policy URL that resolves publicly and describes Banana’s actual data handling.
- [x] Marketing URL is set to https://bananatheapp.com/ and resolves publicly.
- [ ] App Review contact name, email, telephone number, and any reviewer instructions.
- [x] Primary category: **Productivity** in Connect.
- [x] Secondary category: **Health & Fitness** in Connect.
- [ ] Age-rating questionnaire responses.
- [ ] Content-rights declaration for podcast feeds and artwork.
- [ ] Pricing, availability territories, and release method.
- [ ] App privacy questionnaire answers checked against the shipping build. Since the last check
      the app reads Google Calendar data, Contacts (event guests), Photos (meal photos, opt-in),
      camera images of meals and labels, and food and supplement logs, and sends barcodes to public
      food databases.
- [x] Google sign-in: Google approved the OAuth consent screen (the owner, October 9, 2026). Check
      once in the Google console that it reads “In production” with `calendar.events` and
      `calendar.calendarlist.readonly` listed.
- [ ] A demo Google account for App Review, entered in the submission’s sign-in information. The
      review notes say one is supplied.
- [ ] Export-compliance answers checked against the shipping build.
- [x] Public name in Connect is `Banana: Daily Planner`; the installed name remains `Banana`.
- [ ] Confirm “Everything. Organized.” for public marketing use.

## Required generated assets

- [x] 6.9-inch iPhone screenshots: exact 1320 × 2868 PNG, one to ten.
- [x] 13-inch iPad screenshots: exact 2752 × 2064 landscape PNG, one to ten. The app runs on iPad, so the
      App Store requires them.
- [x] Apple Watch screenshots: exact 416 × 496 PNG, consistent across localizations.
- [x] Mac screenshots: exact 2880 × 1800 PNG, composed from captures of the real window. The
      capture opens windows on the desktop, so run it when the screen is free.
- [x] 1024 × 1024 app icon in the shipping asset catalog.

## Optional growth assets

- [ ] Record a 15–30 second app preview from real app interaction using the generated storyboard.
- [ ] Localize metadata and screenshot captions after validating the English positioning.
- [ ] Create Custom Product Pages for planner, podcast, and fitness intents.
- [ ] Run the screenshot-order Product Page Optimization test after baseline conversion data exists.
- [ ] Revisit Apple’s new Asset Library/header/search-result formats when Apple publishes the
      promised detailed specifications. They are announced for fall 2026 but not fully specified.

## Live audit — 21 October 2026

Checked App Store Connect for the iOS and macOS 1.0 drafts. Both are still
`PREPARE_FOR_SUBMISSION`; no App Store submission was made.

Already present in Connect:

- Public name: **Banana: Daily Planner**.
- Primary category Productivity; secondary Health & Fitness.
- An age-rating declaration (answers still need a content review).
- English descriptions, keywords, support and marketing URLs.
- Privacy-policy URL: https://bananatheapp.com/privacy.
- Mac: four screenshots. iOS: seven iPhone screenshots and three Watch screenshots.

Still missing or requiring release verification:

- Reviewer contact first/last name, email and phone are empty on both drafts.
- The app’s content-rights declaration is unset. Confirm the declaration for podcast feeds,
  artwork and other third-party content before filling it in.
- Demo account credentials are empty on both drafts. Review notes must accurately explain
  the sign-in and permissions the reviewer needs.
- **No iPad screenshot set is uploaded.** The local generated package validates and contains
  iPad assets, but the upload remains outstanding.
- Select the final tested build after the Email/performance merge and lane expansion change.
  Build 66 is installed locally in main and Beta on Mac, iPhone and iPad; its focused checks pass.
  The full release regression run and TestFlight publication remain outstanding.
  Build 65 predates this work and was submitted to TestFlight review separately.
- The current release modes differ: iOS releases after approval; Mac releases manually.
  A pricing schedule exists, but prices and territories were not fully verified by this audit.
- Verify current App Privacy and export-compliance answers, content rights, pricing,
  territories and release method. The local checklist is not evidence these fields were
  completed in Connect.
- The persistent performance comparison is currently unmeasured: its checked-in Xcode 27.0
  reference does not match this host’s Xcode 27.1. Preserve the existing baseline; use the
  matching toolchain or a separately reviewed new reference.
- Run the release regression gates and retain failures. Native physical frame/input
  acceptance remains separate from simulator correctness; imported performance evidence
  includes outstanding failures and must not be represented as a complete performance pass.
- Review readiness applies to every enabled module even when its UI says Beta. Apple’s
  [review guidelines](https://developer.apple.com/app-store/review/guidelines/) require a
  complete app and direct beta distribution through TestFlight.

Email policy for the next build: the main app shows a disabled **Coming soon** module;
Beta shows an available **Beta** module. The main release must pass `tools/check-release.sh`
with no Gmail implementation, endpoint or scopes in its executable. Email’s Google consent
and live-provider acceptance belong to the separate Beta work, not the main release.

Evidence from this audit is retained in `/tmp/banana-66-store-audit.json`,
`/tmp/banana-66-store-audit-extra.json`, and `/tmp/banana-66-assets-validation.log`.
