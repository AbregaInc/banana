# Release acceptance follow-up — 24 October 2026

Owner authorization: finish the shared routines/reminders layout and the outstanding validation,
investigate failures and repair feasible defects. **Public App Store and new TestFlight review
submission remain held for owner review.** Drafts continue to select build 76; candidate 78 is
compiled after initial 77 validation. No baseline, workload or latency budget is changed.

## Changes under validation

- iPhone/iPad: due routine chips and reminders share one wrapping band in Day and selected-day
  Week. All-day calendar events stay under their own dates. Mac uses a shared to-do section.
- Watch: implement Apple's active-workout recovery callback, retain the app's session identity
  and configuration in a backup-excluded atomic checkpoint, and reopen raw samples in append
  mode. Restore the associated HealthKit builder, cumulative statistics and pause history.
  Preserve complete binary records and discard only an incomplete final record. An unflushed
  in-memory buffer tail cannot be reconstructed and is explicitly logged. Failed/unmatched
  recovery preserves files, ends orphaned HealthKit runtime and presents an error.
- Note reminder write-back: a missing device-local EventKit ID now falls back to the stable note
  URL. Save/read interruption and concurrent-edit checks preserve pending work; completed
  reminders stay completed. Live two-device/provider propagation still requires evidence.

## Evidence so far

Private root: `~/Library/Logs/Banana/ReleaseAcceptance-20261024/`.

- Initial focused phone UI: 5 passed, 2 failed. The all-day count still expected routine entries
  in the old band; the completion harness expected an empty attention band after relaunch.
  Retained `layout-ui-results/phone-20261024-102544.xcresult` and
  `ui-shared-plan-band-phone.log`.
- After correcting those expectations: 3 passed, 0 failed; retained
  `layout-ui-results/phone-20261024-103201.xcresult` and `ui-shared-plan-band-repair.log`.
  These results do not replace final candidate regression evidence.
- Persistent component gate: **unmeasured**, installed Xcode 27.1 differs from recorded Xcode
  27.0 reference. Raw gate/policy retained in `component-gate/`. No baseline was replaced.
- Pi worktree confirmed no devices or simulators reserved. Its installed app is preserved.
- Phone/iPad report iOS/iPadOS 27.0.1 and Developer Mode enabled. Watch was initially locked. The owner subsequently confirmed all three devices are unlocked and free.
  Pre-update Watch diagnostics were recovered; no active workout span was present before install.

- Focused iPad layout checks: **7 passed, 0 failed, 0 skipped**, retained
  `layout-ui-results/pad-20261024-103756.xcresult` and `ui-shared-plan-band-pad.log`.
- Notes/recovery/health/backup model checks: initial **75 passed, 1 failed**, retained
  `model-checks.xcresult`. The purge safety test tried to create a health writer through the
  now-read-only production mode store; it now injects that forbidden legacy state at the purge
  boundary, preserving all no-deletion assertions. Recheck: **76 passed, 0 failed, 0 skipped**,
  retained `model-checks-fixed.xcresult`. All seven new recovery/write-back fault cases pass.
- Read-only Mac backup metadata inventory: **21 known paths, 9 not excluded**. Applied the
  existing protection helper to those known Banana-owned roots. Recheck: **21 excluded,
  0 remaining failures, 0 changed file contents**. Both inventories retained. This changes
  metadata only, not health data, and does not erase prior cloud or Time Machine backups.

- Main and separate Beta Release candidates compile on iOS and Mac, build 77. Watch Release
  compile and strict signing verification pass. Main iOS has no unreleased Email code (4 executables).
- Main 77 installed on phone/iPad/Watch without uninstalling. Device version readback and remaining
  main/Beta installs are being checked. Existing Banana Pi is preserved.
- Physical runner initially lacked the newer shared `Ready.swift` helpers; the source dependency
  was repaired and both iOS and Watch UI runners now build. No product assertion was removed.
- Current phone/iPad health file metadata: 8 known paths on each device, all carry Apple's backup
  exclusion attribute. This is current-files evidence, not proof of deletion from historical backups.

- First live phone/iPad navigation attempts reached the native Day calendar but the new runner
  queried the container identifier as a collection identifier. The retained AX trees show
  `plan.surface.day` is an Other containing `calendar.nativeDay.viewport` (CollectionView).
  The runner now asserts the named surface and its native collection child; assertions stay.
- Watch UI runner starts on the physical Watch but fails initialization while enabling UI
  automation. The failed attempt is retained in `watch-picker77.xcresult`; this is not an app pass.

- Live main/Beta navigation checks now pass **2/2 on iPhone and 2/2 on iPad**, zero skips.
  Retained `phone-live77-ready.xcresult` and `pad-live77-ready.xcresult`. They exercise native
  Day/Week scrolling, live filter chips, dismissal and relaunch; they do not measure latency.
- Recovered pre-update Watch diagnostics contain an October 21 HealthKit failure reporting
  `Another session is starting`, plus an earlier process end without a terminal event. These
  identify a HealthKit conflict and an interrupted process respectively, not the competing app
  or an OS-level crash cause. Most later retained captures ended normally and were acknowledged.
- Post-initial-build safety follow-up: deleting a note must not uncomplete its linked reminder;
  Watch Stop now holds a finishing state until the old builder is finalized, and the completion
  callback verifies its session identity. These final follow-ups need refreshed candidate builds
  and are not yet in the installed initial 77 binaries.

- First Mac fixture attempt: 3 functional failures (activation/readiness) and incomplete trace.
  The app was sampled before retry: main thread idle, no hot-loop attribution. Once visible, its
  real AX tree confirmed the full varied fixture ready. Calendar search now exposes the live
  filter text field `filters.plan.query`, not the old search-field label; the native harness was
  corrected to that observed control. Results are retained in `mac-live77.xcresult`.
- Instruments with Time Profiler failed internally (`tagged-backtrace` schema error). Partial
  commit data includes a 10.017 ms maximum (over 8.3 ms); capture was incomplete and interactions
  were not validated, so it is not acceptance evidence. Retained `mac-trace77/`. The next capture
  omits the failing optional CPU instrument and is a separately labeled run, not a comparison.
- Native trace host monitoring now optionally accepts the known UI runner PID. Its process tree
  is retained separately from unrelated jobs using the existing monitor classifier; default
  behavior is unchanged. All 8 classifier tests pass. No baseline or timing budget changed.

- Once the real Mac search control was observed and the fixture was ready, all **3 Mac native
  interaction checks passed**. The complete separate commit/run-loop recording nevertheless
  **fails performance**: commit p95 14.647 ms, max 397.790 ms (128 over 8.3 ms); non-waiting main
  run-loop max 237.447 ms. Host monitor saw no unrelated developer job. Missing input/display
  evidence remains missing. Retained `mac-live77-ready.xcresult` and `mac-trace77-ready/`.
  The longest commit intervals align approximately with Day/Week changes; CPU attribution is
  being collected before choosing an implementation change. No speedup is claimed.


- After the owner unlocked the Watch, a second UI initialization attempt still timed out
  enabling automation. Screenshot and lock-state services then failed CoreDevice assertions
  (4016), so neither a new screenshot nor device recovery evidence was obtained. Retained
  `watch-picker77-unlocked.xcresult` and `watch77-after-unlock-capture.log`. Do not treat
  this as proof that the owner failed to unlock the Watch or that Banana crashed.
- The iPad live scrolling correctness run passed **1/1**, and its physical Animation Hitches
  capture completed. For main 77 and real retained calendar data, 1,172 app update intervals
  have p95 **1.696 ms**, p99 **31.270 ms**, max **34.621 ms**, with **28 over 8.3 ms**;
  2 app-attributed hitch rows. Associated render intervals max **9.426 ms**. This fails the
  measured work budget. Pipelined frame lifetimes and display-wide variable cadence are retained
  separately and do not prove input latency. Raw `pad-hitches77/` and slim
  `pad-hitches77-summary.json` retained. The real-data density is uncontrolled, so this does
  not replace the required stress workload.
- Follow-up Watch review also found a failed `beginCollection` callback only logged failure
  while leaving the recording UI running. It now reports the error, ends the failed session,
  and finalizes/preserves the recording. The callback must match its originating session.
  Recovery also refuses to overlap a recording that is still finishing.
- Candidate **78** distinguishes these final Watch/note deletion fixes from installed initial
  77. No 78 installation or submission is implied by compilation.
- Before broad regression, host memory was **63 GB used / 64 GB**, with **12.9 GB / 14 GB swap
  used**. The owned Mac stress fixture was stopped after its evidence was saved. No user apps
  were closed. A full UI run under this pressure is deferred rather than repeatedly timing out;
  this does not waive the final regression requirement or excuse the retained timing failures.
- All **7 native trace reporter tests** pass (`native-ui-trace-tests.log`), alongside the
  previously passing 8 host classifier tests.

## Current readiness by surface

| Surface | Functional evidence | Physical performance / remaining evidence |
| --- | --- | --- |
| iPhone | Main/Beta 78 live navigation 2/2 after owner authorizes XCTest; scrolling correctness passes | 78 physical update max 30.080 ms fails 8.3 ms budget; input/display acceptance remains open |
| iPad | Main/Beta 77 live navigation 2/2; scrolling 1/1; focused layout 7/7 | Main 77 update intervals fail 8.3 ms budget; input latency unmeasured |
| Mac | Three native interactions pass on the isolated varied fixture | Commit max 397.790 ms fails; input/display evidence missing |
| Watch | 78 installed; picker and recovered Strength controls pass; original workout ID and file continuity verified through phone receipt | One controlled Strength interruption verified; broader activity coverage and performance remain separate |

Passing functional checks never closes the separate timing or recovery gates. Current 78
installation/build changes are recorded below; 77 evidence stays attributed to 77.

- Main and separate Beta **78** now compile and are installed on iPad. Normal installed-app
  Day/Week, native scrolling, live filters, dismissal and relaunch pass **2/2, zero skips**:
  `pad-live78.xcresult`. Main 78 and its embedded Watch companion pass strict signing;
  the main release exclusion check passes for all 4 executable images. iOS 78 dSYMs are
  preserved independently in `.build/dsyms/`. Both Mac variants also compile, pass signing and are installed as 78. Main Mac 78
  passes the unreleased-Email exclusion check. Both 78 Mac dSYMs are preserved.

- Symbol retention: Mac 77, iOS Beta 77, both iOS 78 and the separately installed Watch 77
  symbols are preserved. The main iPhone 77 dSYM was not copied separately before the reused
  product directory advanced to 78. Do not claim main iPhone 77 crashes are fully symbolicated
  with the 76 archive or the 78 dSYM. Install verified 78 on that phone when it is available;
  preserve the 78 symbols before future rebuilds.

- Final device inventory: the iPhone and Watch developer tunnels are **unavailable**. They
  remain on the previously installed 77; the freshly signed 78 Watch companion is prepared but
  not installed. No new phone installation was attempted. iPad and both Mac variants are 78.
  Raw inventory: `device-availability78.json`. No claim of deployment to every device.
- Build cleanup completed after copying every layout result bundle/log to the private evidence
  root and preserving installed-build symbols. Workspaces/worktrees and Pi apps are retained.

## Required closure

- Finish candidate compile/unit checks, scoped iPhone/iPad UI and final complete functional run.
- Refresh the Plan listing captures after the final layout candidate is verified; current Apple
  draft assets predate the shared band. Do not silently relabel old captures as current.
- Physical Calendar/search/navigation/playback traces on iPhone/iPad/Mac. Input-to-visible and
  display-delivery acceptance must not be inferred from XCTest duration or component timings.
- Real EventKit permission/interruption/relaunch and cross-device checks.
- Basic Watch Strength recording/recovery/phone receipt is now verified below; remaining
  activity-specific coverage must not be inferred from this one controlled recording.
- Legacy health/backup inventory, deletion/retry and current-data preservation audit. No live
  personal cloud data may be deleted merely to obtain a passing audit result.
- Owner review, reviewer account and privacy publication remain separate submission gates.

## Device rollout follow-up — owner returned home

Private evidence: `~/Library/Logs/Banana/DeviceRollout78/`.

- iPhone and Watch reconnected and initially reported 77. Both reported no passcode required
  for ordinary developer services. Watch active diagnostic spans were empty before replacement;
  no ongoing recording was interrupted. One copy attempt lost its remote connection; after a
  successful screenshot service call, the correct source file was recovered and confirmed empty.
- Main/Beta 78 installed on iPhone, and the signed main 78 companion installed directly on Watch.
  Device app inventories verify **78 for all three bundles** (`installed-versions.json`). Together
  with the earlier iPad/Mac readbacks, all intended local device surfaces now have 78.
- Watch UI initialization first failed because Xcode could not establish the device connection.
  The first iPhone check failed enabling automation. Its screenshot specifically shows Apple's
  **“Enter iPhone Passcode for XCTest — Enable UI Automation”** prompt, despite ordinary unlocked
  status. The owner completed that authorization directly on the phone; no passcode was supplied
  to the agent and no authentication requirement was bypassed. Results remain retained.
- After the owner authorized XCTest, iPhone 78 main/Beta live navigation passes **2/2, zero
  failures/skips** (`phone-live-authorized.xcresult`). The original pre-authorization failure
  remains retained. After Watch connectivity returned, its runner still timed out enabling
  automation. A screenshot during startup shows **Enter Passcode** on the Watch itself;
  the owner entered the passcode directly. The subsequent Watch picker check passes
  **1/1, zero failures/skips** (`watch-picker-authorized.xcresult`). Recording recovery remains
  a separate check requiring a live workout.
  Successful recording recovery, performance acceptance and review submission are not implied
  by version readbacks or navigation success. No App Store/TestFlight review submission occurred.

- iPhone 78 sustained native Day scrolling also passes its functional check. Its completed
  20-second physical trace has **1,398 app update intervals**, p95 **5.355 ms**, p99 **21.883 ms**,
  max **30.080 ms**, **50 over 8.3 ms**, and **20 app-attributed hitch rows**. Associated render
  intervals max **14.863 ms**. The measured-work gate fails; input-to-visible remains unmeasured.
  Pipelined frame lifetimes are retained separately and are not interpreted as input latency.
  This is a warm real-data capture, not the controlled stress workload or an optimization
  comparison. Raw `phone-hitches78/`, environment and slim summary are retained.

### Controlled Watch recovery and phone receipt — build 78

The owner started a short Strength workout and explicitly authorized one deliberate crash.
A single `SIGABRT` was sent using the native debugger. Immediate process inventory was stale;
no second crash was sent. Later inventory and diagnostics confirm a new process and
`recovered=true` for the original workout identity, original start time, and continued
heart-rate/sample collection. Debugger follow-up targeted the retired PID and found no such
process; it was not treated as another successful attach or another crash.

- Watch recovery callback/checkpoint path restored the same recording. The pre-interruption
  raw file held **49,302 bytes**; the later file held **427,284 bytes**. Its entire earlier
  prefix is unchanged, with **11,454 additional complete records** appended.
- Recovered 30-second and one-minute rest controls pass the native UI check **1/1, zero skips**,
  retained `watch-recovered-controls.xcresult`. A real device screenshot shows elapsed time,
  heart rate, rest controls and calories together. The Watch picker also passes **1/1**.
- The owner ended the workout normally and opened main Banana on iPhone. Watch and phone each
  contain **exactly one matching summary**, with the same ID/start/end and **17,169 samples**.
  The phone's durable raw file is **566,577 bytes**, exactly 17,169 × 33, preserving both saved
  pre-interruption and post-recovery prefixes byte for byte.
- The active-workout checkpoint is absent after completion; the recovery folder only holds
  its HealthStaging directory. No personal workout was deleted, edited or marked as fictional.
- This proves this controlled Strength interruption/recovery/receipt path. It does not prove
  restoration of the unflushed in-memory sample tail, all activity types, OS-level causes of
  earlier crashes, input latency, or all other release gates.

Raw evidence and `sample-continuity.json` / `workout-end-to-end-summary.json` are in the private
rollout root. iPhone trace results remain a measured performance failure, not a release pass.
Pi's terminal was notified that physical iPad work is complete and the iPad is released.

- Phone terminal ingest trace confirms **durably_ingested_and_acknowledged**, succeeded,
  with 17,169 decoded samples in 617 ms. This is completion of background ingest, not a UI
  latency measurement. The phone queued its durable acknowledgement; Watch receipt/cleanup
  is checked separately. One large phone journal copy failed with a closed network socket;
  its zero-byte partial file and error are retained, and a later completed copy supplies the
  terminal ingest evidence.

- Watch-side receipt of the final phone acknowledgement is **not yet observed** in the copied
  journal. Foregrounding the finished Watch app succeeded, but the subsequent journal copy
  timed out; the failed attempt is retained. Do not equate a queued phone acknowledgement with
  observed Watch cleanup. The phone summary/raw-file durability and one-summary checks above
  remain directly verified.
- Cleanup ran before handoff. The script conservatively keeps `.build/sim` while Pi's separate
  worktree is running a `BananaPi` Simulator test with the same derived-data basename. That
  unrelated runner was identified and left alone. Installed build products/symbols and all
  workspaces remain preserved. The iPad release notification was accepted by the existing Pi
  terminal; no new agent was spawned, and recipient acknowledgement is not asserted.
