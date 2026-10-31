# Mobile event accessibility grouping — October 10, 2026

Tall mobile event blocks inherited the cell accessibility label separately on their
three artwork text children. A single event therefore exposed its title/time three
times. Short blocks exposed it once and did not reproduce the problem. The earlier
varied-fixture test caught this in its retained accessibility hierarchy.

`CalendarPreparedArtwork` now combines mobile event artwork into one accessibility
element before the containing cell supplies its event label. Task/cue and desktop
artwork branches are unchanged. Prepared images retain their existing explicit
accessibility representation and diagnostic identifier. Under VoiceOver, prepared
artwork continues to use the reference branch. Actual VoiceOver speech/navigation
has not been measured by these XCTest hierarchy checks.

The optimized DEBUG build retains `--calendar-reference-event-accessibility` as a
same-binary control. `testLegacyDayEventAccessibilityControl` deliberately expects
three title repetitions for the tall event and one for the short event; it is a
bug-reproduction control, not production accessibility acceptance. Native,
reference-host and prepared-artwork tests require exactly one title repetition,
then open each short/tall event and verify its actual detail title. The prepared
case waits for the selected event itself to carry the prepared-artwork identifier.

Raw artifacts: `.build/calendar-mobile-accessibility-20261010/`.
The initial `labels-before` three-test run covered only short events and passed;
it does not reproduce the tall-event defect. Keep it separate from the expanded
same-binary comparison. Source/app hashes are retained in `identity.json`.

All four expanded iPhone label/control tests and four old/new/new/old scroll runs
passed with zero skips. The scroll runs use the unchanged 30-day legacy fixture
and the native Day host for both policies. Steady physical-memory medians (kB):
195660.224, 195512.768, 196839.872, 195496.384. The ranges overlap; this is a correctness
fix with no demonstrated speed or memory improvement. Raw XCTest automation and
scroll-duration samples are retained, but are not input-to-visible/frame timings.

The current-source optimized macOS preparation oracle passed 265 lifecycle checks.
This validates cache/preparation behavior and compilation; it is not macOS UI or
accessibility evidence.

The four shared iPhone interaction tests passed: Week dense scrolling, Agenda early
event identity, prepared native Day scrolling and durable move retry/discard across
two relaunches. The iPad Pro 13-inch M5 / iOS 26.5 Simulator passed three tests:
native and prepared short/tall label/detail checks, plus Agenda early-event identity.
That is 15 completed UI tests after the change, with zero failures or skips, plus
the separate three short-only preliminary tests described above.

The full eight-case persistent component suite passed against unchanged baseline
version 1 (four history tiers and four redraw probes). After UI runs and its required rebuild, the executable had
a different binary hash; `identity-after-component-build.json` records it separately.
The modified artwork and UI-test source hashes match the initial identity. All four
old/new/new/old scrolling runs used the initial binary; iPad checks used the rebuilt
binary. No identical-binary claim is made across the component rebuild.

Both owned Simulators were shut down. Cleanup removed 29 isolated temporary fixture
directories, 4.121 GiB logical, retaining reports, result bundles and prior failed-query
database backups. No workspace, worktree or user app data was removed.

Physical 120 Hz frames, input-to-visible latency, actual assistive speech and dense
calendar readability remain open. No baseline or performance budget is changed.
