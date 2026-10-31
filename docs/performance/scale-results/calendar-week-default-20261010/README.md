# Native Week default adoption — October 10, 2026

Native Week is now the iPhone/iPad production and DEBUG default, matching Day.
`--calendar-reference-week` preserves the old DEBUG comparison host. No renderer
flag is passed by the native scroll, navigation, rotation or creation tests.
Reference scroll/cached/prepared/neighbor cases explicitly preserve their previous
host, so the policy change does not silently compare native against itself.

## Verified iPhone Simulator coverage

`.build/calendar-week-default-20261010/default-ui.xcresult` passed **7 tests, zero
skips, zero failures and zero runtime warnings**, on the owned iPhone 17 Pro,
iOS 26.5, Release optimization with DEBUG audit fixtures:

- Explicit reference dense Week scrolling.
- Default native Week dense scrolling and exact event detail.
- Default native Week varied-calendar navigation, paging, zoom and reuse.
- Default native Week portrait/landscape/portrait rotation.
- Default native Week blank-slot gesture opens the editor and accepts a title.
- Default native Day paging/zoom and creation-editor gesture.

Creation checks do not save to a provider. Scroll XCTest durations and memory
metrics are not frame/input-to-visible acceptance. No speedup or baseline reduction
is claimed by this default-policy change. Earlier paired native/reference evidence
is retained in the native Week report.

`ui-summary.json` and `ui-tests.json` retain exact coverage; `source-identity.json`
and `source-stability.json` describe source provenance. Mac-only integration edits
occurred during the iOS build, so the whole working tree was not frozen. The shared
WeekView body comparison is unchanged. A fresh component build remains required.

## Outstanding coverage

Week move failure/retry/relaunch, the matching iPad default-path checks, and the
unchanged full component suite are queued behind the Mac build by
`.build/calendar-week-default-20261010/cross-device.py`. Pending jobs are not passes.
The iPad tests create their own owned Simulator and shut it down afterward; the
existing review iPad is preserved. Physical-device measurements, successful provider
writes, full edit/recurrence/live-update parity and Mac acceptance remain open.

## Week move recovery follow-up

`week-move.xcresult` and `week-move-summary.json` now retain one additional passing
iPhone Simulator test, zero skips/failures/runtime warnings. The default Week drag
reaches the isolated provider rejection, restores the event, identifies its saved
move, survives relaunch and retains a rejected retry. This proves the failure path;
a successful real-provider move and physical latency remain unverified.

## iPad Simulator follow-up

`ipad-default-ui.xcresult`, `ipad-summary.json` and `ipad-tests.json` retain **7
passed, zero failed/skipped, zero runtime warnings** on the dedicated iPad Pro
13-inch (M5), iOS 26.5 Simulator. Coverage is default Week scroll/detail,
navigation/zoom, rotation, creation-editor gesture and move recovery, plus default
Day paging/zoom and creation-editor gesture. The dedicated Simulator was shut down
successfully; the existing review iPad was not replaced or reset. Split-window
resizing, physical input/frame measurements and successful provider writes remain
open. The full component run is in progress under `components/`.

## Full component regression

The complete eight-scenario run finished with exit 0 and `components/gate.json`
reports **pass**, unchanged baseline version 1. All four retained-history tiers
and four redraw scenarios were included. `cross-device-exits.json` records zero
exits for phone recovery, iPad UI and this component suite. No baseline was changed.
This passing cohort does not erase or explain the retained earlier Mail first-page
failure and is not physical frame/input acceptance. Mac visible checks follow in
an idle session; their results are separate.
