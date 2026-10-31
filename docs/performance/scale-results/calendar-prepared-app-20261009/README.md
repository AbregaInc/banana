# Prepared artwork in the real calendar — work in progress

`--calendar-prepared-artwork` selects the prepared image path in the real Mac and
mobile timed-event views in DEBUG audit builds. Release defaults remain the live
reference pending app-level evidence. This is an incremental integration: the
existing SwiftUI grid still owns geometry and interactions; native whole-viewport
virtualization is not yet adopted. This flag is independent of lane-plan caching.

The view receives current Occurrence-derived paint, monitors visibility using
[Apple’s scroll visibility callback](https://developer.apple.com/documentation/swiftui/view/onscrollvisibilitychange(threshold:_:)),
and replaces only ready event artwork. Pending/rejected work uses live artwork.
The queue accepts at most 128 jobs, prepares one miss per dispatch turn, cancels
superseded jobs and rejects stale results. Cache retention and consumer leases
have separate 32 MiB limits. Shared image storage can overlap the two accounting
figures; compositor retention is not included and still needs profiling.

Parent taps/context menus/drag handling/pending-write feedback remain intact.
VoiceOver and specialized non-event content retain the live hierarchy. Prepared
event artwork exposes a lightweight text accessibility representation, with the
existing parent labels/actions. A legacy agenda cell whose canvas height differs
from its artwork height also retains live rendering until those two inputs are
modeled separately. These are explicit incomplete integration areas, not passes.

## Preparation checks

The first [109-check run](preparation-queued-report.json) exposed needless queue
delay for warm images: median 2.085 ms, p95 4.500 ms, max 21.560 ms. This measured
API completion, not input-to-visible latency. The corrected coordinator checks
for an existing image without rendering before enqueuing a miss.

A [210-check alternating comparison](preparation-fast-report.json) retained:

| Warm policy, 101 samples | Median ms | p95 ms | Max ms |
| --- | ---: | ---: | ---: |
| Direct cache lookup | 0.0064 | 0.0113 | 0.0347 |
| Original queued lookup | 2.0611 | 2.1223 | 2.1803 |
| Coordinator fast lookup | 0.0073 | 0.0132 | 0.0582 |

This supports removing the queue delay on cache hits; it does not prove scrolling
improved. Cold ImageRenderer preparation remains on the main actor and retains the
90.529 ms first-use result from the preceding color experiment. A further [macOS 15 deployment-target check](preparation-final-report.json) passed
the same 210 checks but recorded **197.164 ms** first use during concurrent app
compilation. This is retained as a cold-preparation risk, not clean UI latency.
One job per turn does not guarantee an 8.3 ms frame. The persistent lifecycle checks cover pending
capacity, cancellation, consumer budget rejection and lease release. Cache/reference
pixel, eviction and invalidation tests remain separate and unchanged in scope.

## App validation protocol

The new dense-calendar UI case requires a prepared-artwork accessibility element,
scrolls the real grid, then activates a visible prepared event and verifies its
detail sheet. A live fallback cannot satisfy the prepared-artwork assertion.
Build, component suite and iPhone/iPad results are retained in
`.build/calendar-prepared-app-20261009/`. No result from the earlier adapter build
is claimed for this new path. Physical frame/input-to-visible acceptance remains
outstanding. Email follows calendar integration and measured optimization.


## Retained real-grid failures and diagnosis

The first prepared-grid test failed its prepared-element assertion. The retained
accessibility snapshot contains 318 event buttons, **zero intersecting the screen**;
the lowest event's bottom was y=-304.7. The app opened at the current late-night
hour after earlier tests had persisted 160-point zoom. Fixture events ended at
16:30. The previous scroll test only checked offscreen existence and could scroll
empty hours. [Geometry evidence](empty-viewport-diagnosis.json).

Both control and candidate tests now set 56-point zoom and reveal the same normal
30-minute event (`Stress event 61`, 10:10) before measurement. The prior workload
and results are preserved; changed viewport setup means these are not directly
comparable to the old empty-hour gesture timings.

The second run made events visible but still failed because the test queried
StaticText. Its snapshot proves `calendar.preparedArtwork` is installed on event
**buttons**, because SwiftUI merges the semantic text into its parent action.
[Element count](prepared-accessibility-diagnosis.json). The test now queries that
same required identifier across roles; no fallback marker was added. The app binary
is unchanged by these test fixes. Both failed xcresults and full hierarchies remain
under `.build/calendar-prepared-app-20261009/`.


A subsequent six-case run executed the old StaticText query despite the installed
runner matching the new on-disk binary SHA. Disassembly of that binary contains
the new assertion line 141; the failure reported old line 131. Refreshing only the
owned Simulator's test-runner installation made the same binary execute the new
`Any` query and visible-event setup. This establishes a stale execution symptom
and effective recovery, not the underlying Xcode cache mechanism. The failed run
is retained; its control timings are not a matched comparison with the corrected
harness. [Runner identities](runner-identity-diagnosis.json).

The refreshed run passed prepared-element discovery and scrolling, then failed
event-detail activation. Source inspection found the original stress IDs are
`stress-event-N`, while mobile `openEvent` only routes Google event-info IDs.
The existing fixture cannot open a detail with either renderer. An explicit
`--stress-actionable-calendar` mode now supplies synthetic routed IDs without
changing counts, times, titles or the default component fixture. In that mode,
Google event loading fails locally before account restoration/network access;
the detail displays the actual cached MeetingInfo. This checks local activation
and selected-event identity, not provider fetching or edit/write durability.
Both control and prepared UI tests require the same detail activation. The test
logs `CALENDAR_SCROLL_PROTOCOL=2` to identify the executing harness revision.


## Current app results

The final Release + DEBUG audit build compiles for iOS Simulator and native macOS.
The Mac binary uses the isolated `com.boris.banana.mac.stressreview` identifier and
was not opened on the desktop. [Final source/app/runner identity](final-identity.json).

The corrected, protocol-2 iPhone control/prepared interaction pair passed
([two-test summary](iphone-actions-summary.json)). Both required visible events,
scrolling, event detail presentation, selected-title identity and dismissal.
The remaining four iPhone layout checks also passed on the final app
([summary](iphone-remaining-summary.json)): crowded all-day day/week access,
cue time/activation, and short-event height through both zoom levels.
The same six focused iPad Simulator checks passed ([summary](ipad-summary.json)).
Native Mac visible interaction and physical iPhone/iPad frame/input acceptance
remain unmeasured for this integration. The current legacy app fixture is uniform;
varied-calendar/history app acceptance must be added before rollout.

The final cache implementation passes its [46-check same-API raster/lifecycle
oracle](raster-final-report.json), retaining the 14 cross-export differences and
78.470 ms first-use measurement. The preparation suite is now in calendar-core CI,
including its raw timing output; 33 Python regression-harness checks also pass.
The persistent eight-case app component gate also passed with the unchanged
baseline and budgets: [measurements](component-measurements.json),
[gate](component-gate.json). The optional 80%-idle preparation window was not met
([all preflight samples](component-readiness.jsonl)). The Simulator startup
media-analysis process fell from 315.9% CPU to idle; other desktop/backup activity
remained. One full suite was then collected with host monitoring. This is a
component gate pass under recorded shared-host conditions, not a quiet-host or
physical UI acceptance claim.
XCTest gesture durations and offscreen API times do not establish UI speed.


The full integration goal remains active. Next work is to establish prepared
coverage in the native mobile Day scroll container, move viewport ownership and
reuse into the native surface, and measure actual app cold/warm/paging/eviction
behavior. The current cache is an intermediate real-data bridge, not the complete
virtualized renderer. No baseline reduction is proposed until an integrated,
repeatable improvement is verified. Email has not been changed in this phase.
