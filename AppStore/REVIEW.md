# Banana public release review — updated 25 October 2026

**Submission is on hold until the owner reviews and authorizes it.** Neither public App Store
version has been submitted. The owner has approved publication of the privacy declarations; they were published on 24 October. Both platforms are configured for manual release.
The pending Mac TestFlight review publisher was stopped. iOS TestFlight 75 was already live
before the hold.

Review the [artwork over Tailscale](http://100.89.44.104:8899/) and the
[App Store Connect draft](https://appstoreconnect.apple.com/apps/6792318022/distribution).

Build 80 removes Email from public Settings/onboarding and removes preview badges from released
modules. Separate Beta retains its labels and Email. Both public drafts select VALID 80, with
MANUAL / PREPARE_FOR_SUBMISSION verified. See the [focused follow-up](../docs/release/public-modules-20261025.md).

## Prepared

- Owner-supplied mascot icons, IBM Plex Mono, cream/ink/yellow/pastel screenshot compositions.
- Refreshed real captures: seven iPhone from 79, six landscape iPad (2752 × 2064) and five Mac
  from 78’s shared layout; three retained Watch captures. Header/search artwork recomposed.
  All updated Apple draft placements/order are verified; matching website images are deployed
  and byte-verified. Capture executable hashes are recorded without relabeling older products.
- English listing, keywords, review contact and review notes saved/read back.
- Medical-device declaration: No, per owner confirmation. Age: 13+ in most current regions,
  with regional/older-OS exceptions.
- All 19 privacy data categories configured: no tracking; Crash/Performance Data unlinked;
  remaining categories linked. Purposes match the audited worksheet. Published with owner approval.
- Content rights confirmed by owner and saved. Free US base price verified. Availability:
  all 175 supported regions and future regions, available on app release.
- Installed candidate 80 retains the shared routines/reminders layout, interrupted Watch workout recovery
  and reminder write-back safety fixes. Main 80 is installed on the owner's iPhone, iPad and Mac; separate Beta remains 79. The main
  Watch companion remains 79 because its developer connection is unavailable. Navigation checks pass on both
  mobile devices. One owner-authorized Strength crash/recovery test preserved the recording
  identity, original start and samples through durable ingestion on the phone.
- Both public drafts select **VALID build 80**, with MANUAL release and
  PREPARE_FOR_SUBMISSION verified after selection. Signed iOS/Watch and universal sandboxed
  Mac archives pass strict signing and unreleased Email exclusion. Neither public nor new
  TestFlight review submission occurred. See the [current launch preparation](../docs/release/launch-preparation-20261024.md)
  and [detailed acceptance evidence](../docs/release/acceptance-20261024.md).

## Main versus separate Beta

| Capability | Main Banana, including its TestFlight build | Separate Banana Beta |
|---|---|---|
| Plan and Calendar | Always available | Always available |
| Workouts/sleep, Food, Notes, Podcasts | Optional; no preview label | Optional; Beta label |
| Email | Not listed; implementation/scopes excluded | Optional; Beta label |

Module settings/storage are separate between main and Beta. A Beta badge does not waive
production readiness for features enabled in the main app.

## Remaining release preparation

- Final candidate validation and media preparation are complete with recorded limitations.
  Full 79 retained 242 passes, 3 failures and 23 skips; focused rechecks closed all three
  findings. Original failed runs and skip reasons remain preserved. The supplementary iPad
  simulator attempt stopped before runner launch; it is not passing 79 iPad UI evidence.
  Earlier iPad 78 layout/navigation and 102 model checks remain separate evidence.
- Both final 80 archives uploaded, processed VALID and are selected; refreshed screenshot and
  creative placements are verified, with matching website images deployed.
- Provide the connected-calendar reviewer account and instructions when the owner supplies Gmail.
- Obtain the owner's explicit authorization before submitting either platform for Apple review.
  Both release methods remain manual. App Privacy publication is complete.

The owner explicitly deferred live physical iPad Notes/Reminders checks after the system's
XCTest authorization prompt blocked startup. The primary phone is currently unavailable for
that check; no QA note was created. Prepared tests are not recorded as passing.

Strict numerical performance work is a separate follow-up under the owner's clarified launch
scope. Recorded phone/iPad/Mac timing failures and the component toolchain mismatch remain
visible; no budget or baseline was relaxed. Current known health-file backup paths are excluded;
this does not establish deletion of historical backups. One controlled Strength recovery does
not establish every workout type or Watch acknowledgment cleanup.

Calendar sharing investigation is explicitly deferred at the owner's request. The partner's
remaining native Busy duplicates are not claimed fixed.

Detailed status: [submission checklist](../tools/app-store/submission-checklist.md).
Private verification records: `~/Library/Logs/Banana/ProductionReadiness-20261022/`.
