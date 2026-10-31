# Default Beta populated mobile verification — October 10

The normal Beta build 55 remains separately installed on Mac, spare iPhone and
iPad. Its mobile Google Calendar accounts were not connected during normal-app
checks, so those empty-view passes did not establish populated renderer coverage.
This supplementary fixture uses the same frozen app source and Beta renderer,
with the guarded physical fixture route enabled. It is not live-account acceptance.

## Build and workload

Artifacts: `.build/calendar-populated-mobile-20261010`.
`command.json`, `source-identity.json`, `exit.json`, `signed-review.json` and
`ui-build-command.json` retain commands, source hashes and build evidence.
Fixture binary SHA-256:
`2024c8569a2c057cf22f34f7fe0d4038516ae90fbb9ed3b291253930f7fd38af`.
App and UI runner builds exited 0. Signing verifies the source freeze and a profile
that permits both test devices. Bundle ID is `com.boris.banana.stressreview`;
normal Beta and non-Beta installations are preserved.

The physical launch helper keeps 180,000 emails over 90 days, 36,500 events over
365 days, 5,000 notes and 20,000 podcast episodes. The calendar is `varied-v1`,
with 12 calendars and different daily/weekly patterns. No renderer opt-in is passed.
Each test checks installed calendar metadata, the native collection viewport,
visible prepared artwork before/after scrolling, explicit preparation failures,
and the exact event detail opened from its clipped visible area.

## Results

Initial physical results:

- Spare iPhone 14 Pro / iOS 27.0.1: **2 passed, 0 failed, 0 skipped**.
  Both screenshots were inspected: replacement artwork is visible, with severe
  title truncation in narrow lanes at this density. This is not dense-layout UX
  sign-off. Normal Beta restore passed separately.
- iPad Pro 12.9-inch (5th generation) / iPadOS 27.0.1: **0 passed, 2 failed**.
  Both hit the 15-second visible-artwork readiness timeout. The retained recordings
  show populated artwork and an external video picture-in-picture overlay; they
  contradict an inference that the renderer drew nothing. Normal Beta restore
  passed separately. The failure cause is not yet established.

The initial predicate queried every artwork element's remote geometry with
`filter`, even after encountering a visible event. `short-circuit-probe/` rebuilds
only the runner, stopping at the first qualifying event and reading viewport
bounds once. It retains the same timeout, workload, installed app binary and
correctness assertions, and adds explicit readiness-failure captures. The iPad probe
passed **2 tests, 0 failures, 0 skips**, on the unchanged fixture binary; its normal
Beta restore also passed. The new Day/Week screenshots show populated replacement
artwork and were inspected. The external video overlay is absent in these captures,
so this is not a perfectly controlled attribution experiment. The original
failure remains a harness-readiness failure, not proof of an empty renderer or an
app performance regression. The matching spare-phone probe also passed **2 tests, 0 failures, 0 skips**.
`functional-verification.json` validates exact device IDs, counts and no runtime
warnings. These checks did not modify app code or any performance baseline.
Both normal-Beta restoration tests then passed (1 test each, zero skips/failures);
normal Beta is left foreground. The owned fixture Simulator remains shut down.

All six exported original/iPad-probe workload attachments agree on content checksum
`1550fd1978dd9444` and installed checksum `370b1e898c9c021c`, seed `20261009`,
17–193 events/day (mean 100), and 700 events per complete seven-day block.

The runner retains device command logs, xcresults and summaries, then runs a
separate normal-Beta launch check to restore the review app to the foreground.
Original failures and recordings remain preserved.

This is functional coverage only. XCTest waits and gesture wall-clock timings do
not measure 8.3 ms frames or input-to-visible latency. Live Google sync/writes,
rotation, VoiceOver, full cache/memory lifecycle, and device performance acceptance
remain separate requirements. No baseline or performance budget changed.
