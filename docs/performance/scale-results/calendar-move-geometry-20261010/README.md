# Calendar relative move correction — October 10

Status: **corrected iPhone/iPad integration, component gate and native Mac compile passed. Physical UI timing remains unmeasured.**

The native Day continuation UI test failed against the pre-fix app with exit 65.
It moved event 10's next-day continuation downward one hour, then checked the saved
retry destination. The retained journal has originalStart 813303600 and destination
813393600 (Foundation reference-date seconds): **90,000 seconds / 25 hours**.
The intended change was 3,600 seconds / one hour. Both mobile and Mac drag code
reconstructed the event clock time on the displayed day, adding an unintended day.

`CalendarMoveGeometry.start` instead applies Calendar day steps to the original
start and then adds the existing five-minute-snapped vertical delta. A zero day
step preserves the precise instant, including the second repeated DST hour and
sub-minute precision. The shared helper is wired into mobile and Mac drag commits.
Mobile optimistic ends now receive the same delta as their starts; same-lane gap
joining uses displayed neighbour starts and excludes the current event.

The component checker retained 147 assertions: frozen pre-fix calculations fail
108; corrected calculations pass all 147. Covered: continuation offsets 0/1/2/7,
horizontal shifts -2...2, positive/negative/no-op snapping, repeated-hour no-op,
sub-minute no-op, DST horizontal clock preservation, optimistic duration and
ordinary-path parity. The vertical rule is still elapsed minutes; wall-clock drag
semantics through a DST gap remain separate work.

A counterbalanced R/N/N/R component run retained 28 samples of 1,000 ordinary
moves. Reference median/max 9.479/9.704 ms; relative 0.247/0.268 ms. This removes
unnecessary date-component reconstruction, but the absolute per-move saving is
only microseconds and **does not prove UI/input/frame speed**. The primary change
is correctness. No baseline or budget was altered. CI now retains the component
check and its timing samples.

Raw builds and XCTest bundles: `.build/calendar-move-geometry-20261010/`.

## Corrected real-app checks

All five selected iPhone 17 Pro / iOS 26.5 Simulator cases passed, with no skips:
continuation destination, short move failure, beyond-viewport move failure,
durable recovery, and paging/zoom. The corrected journal retained a 3,600-second
change; its JSON is included alongside the original 90,000-second failure.
Short/long/recovery move probes each changed parent render counts from 6 to 8,
matching the earlier native feedback path. This is redraw coverage, not latency.

Optimistic duration is checked by the shared arithmetic tests and connected to
mobile event geometry; a deliberately delayed-provider visual check is not included
in this run. No live provider request was sent. Mac drag uses the same corrected
start helper, but native desktop pointer interaction remains separately unmeasured.

The full eight-case persistent component suite passed unchanged baseline version 1
with no failures. Its rebuild retained the same optimized Simulator binary hash.
All four history tiers and four redraw scenarios are included; no slow sample,
scenario, baseline or budget was removed or loosened.

Mail follow-up: both native list coordinators retain old row/display entries across
membership changes, and `MailTuning.listCap` is 2,000. Test scope switching and
browsing beyond that boundary explicitly; current first-page tests do not prove
bounded memory or access through an arbitrarily long history.

The same optimized binary passed all three selected iPad Pro 13-inch M5 / iOS 26.5
Simulator cases (continuation, recovery, paging/zoom), with no skips. The recovery
move still recorded 6→8 parent renders. The iPhone recovery screenshot was visually
inspected: the next-day page remains behind a saved destination on the original
day at 02:40, with visible retry/discard access.

Cleanup removed 23 UUID-scoped temporary fixture directories (3.100 GiB logical)
after both owned Simulators shut down. Preserved the original failing journal,
corrected journal, all result bundles and prior failed-query database backups.
Workspace/worktree and binaries remain. Physical 120 Hz/input-to-visible acceptance
is still unmeasured for these integrated paths.

Native BananaMac Release/arm64 compile/link completed with exit 0. This verifies
the shared helper is built into AppKit; no visible Mac interaction was driven.
