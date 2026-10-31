# Calendar Agenda integration and startup regressions

Current status: native per-day accessibility grouping and corrected Agenda geometry
are enabled. Early events open their own details on iPhone/iPad. The prepared
backend remains experimental: its cancellation-race check passes, but iPad Agenda
still exceeds admission capacity and fails the prepared-coverage assertion.
Two synchronous Core Location reads that blocked startup have been replaced with
callback-delivered state; the combined change passes the controlled daemon-stall
comparison. Full native viewport integration and physical frame/input acceptance
remain unfinished. The latest full component suite fails cold Notes/podcast query
budgets; matched prior builds also fail, with SQLite file-read waits captured.
Detailed component evidence is below.

The protocol-3 test reached real Agenda content. The ungrouped control repeatedly
spent approximately 20 seconds resolving the same target event. A two-second
sample found 1,217 main-thread samples inside XCTest-driven accessibility traversal,
including 1,120 under SwiftUI accessibility geometry sorting. It is evidence of
expensive accessibility queries, not a measurement of frame or input delivery.
The run was explicitly interrupted after 191 seconds; [terminal result](control-interrupted-summary.json).
The remaining selected tests did not run and are not passes. Raw log/screenshot/sample
remain under `.build/calendar-day-integration-20261010/`.

## Native capability before custom implementation

Apple's [accessibility child behavior](https://developer.apple.com/documentation/swiftui/accessibilitychildbehavior/contain)
provides a native parent accessibility element while preserving its children.
It is a public SwiftUI API available on iOS and macOS; it requires no external
library or custom accessibility implementation. This experiment adds one semantic
container per Agenda day, with a localized date label. It preserves event nodes,
labels and actions and leaves the rendered layout unchanged. Explicit child
ordering and VoiceOver navigation still require verification.

The initial experiment used `--calendar-group-agenda-accessibility` as an opt-in.
Grouping is now enabled by default; `--calendar-ungrouped-agenda-accessibility`
retains the original hierarchy for controlled DEBUG comparisons. Both `testGroupedAgendaGridScroll`
and `testGroupedPreparedArtworkAgendaGridScroll` use the same workload, mode/content
assertions, event query, scroll cycles and event-detail identity checks as their
ungrouped controls. Tests remain automation/correctness diagnostics, not UI latency
acceptance. The original failed Week selection and interrupted Agenda control
are retained; this candidate does not erase or declare either resolved.

Artifacts: `.build/calendar-agenda-accessibility-20261010/`. The previous control
app binary is retained there as `control.app` for reproducible comparison.


## First grouped app result and selection diagnosis

[Five-test result](grouped-first-summary.json): four pass, one fails. Real Day
control/prepared, grouped live Agenda, and prepared Week pass scrolling and selected
event detail. Grouped prepared Agenda passes marker discovery and scrolling but
opens Stress event 10 after querying Stress event 1. This failure is retained.

The before/after accessibility trees show event 1 (00:10), event 4 (00:40), event 7
(01:10), and day-long event 10 (01:40) at the same x/y. The old Agenda axis starts
at 06:00 and clamps all earlier starts to y=0, even though its lane allocation
uses their actual times. It also draws uncapped overnight duration into following
day sections. The tap reaches overlapping event 10; this is a real legacy geometry
bug, not evidence that the image cache changed the event's action identity.
The earlier separate Week mismatch remains unproven, despite a later Week pass.

Grouping retains seven day containers and every exposed event node (see
[tree counts](accessibility-counts.json)). In the matched event-query section,
repeated Find operations take about 0.09–0.10 seconds with grouping versus about
20 seconds in the retained ungrouped control. The full grouped live Agenda test
finishes in 55.147 seconds, whereas the original was interrupted at 191 seconds
before starting its scroll cycles. These are automation-query diagnostics, not
frame/input acceptance or a completed control UI run.

## Day geometry correction under validation

`CalendarAgendaGeometry` uses the actual civil-day interval (including DST), clips
both ends of events, and limits minimum-height extension to available time/day end.
It computes successors once rather than scanning for each event. Agenda now draws
the entire day, and visible/hit geometry is clipped to each corrected frame.
No events are removed to pass the selection test.

[25 pure geometry checks](geometry-report.json) cover early times, adjacent events,
overnight/multi-day clipping, empty/outside/zero-duration intervals, 23/25-hour
New York days and Lord Howe's half-hour transition. All pass. The new suite runs
in calendar-core CI and retains 201 preparation-cost samples at 100/300/1000/5000
events. The 100-event median is 0.0108 ms; the 5000-event maximum is 0.6474 ms.
Those are geometry API costs, not renderer performance or pixel equivalence with
the broken layout. App interaction and persistent component validation of this
correction are reported below.


The geometry-only component build completed all eight cases but failed the retained
Mail first-page regression limit again: 15.254 ms versus 14.830 ms allowed
([gate](component-corrected-gate.json), [measurements](component-corrected-measurements.json)).
That failure is not waived; a matched diagnostic control/candidate collection is
planned. No Mail implementation was changed in this experiment.

The final candidate enables native per-day accessibility containers by default;
`--calendar-ungrouped-agenda-accessibility` retains the old hierarchy for DEBUG
comparison. The initial opt-in test names are retained. It also starts grid weather
at midnight and anchors its final minute within the same day, avoiding the legacy
weather map's next-midnight/00:00 alias. Weather still has wall-clock rather than
absolute-time semantics at repeated DST hours; full weather alignment across DST
is not claimed by the geometry tests. Fractional-hour grid ticks display minutes.
Final component/UI validation is reported below. Native surface completion and physical
frame/input performance acceptance remain outstanding.


## Final geometry app checks and remaining preparation question

The [eight-case final component gate](component-final-gate.json) passes unchanged
([measurements](component-final-measurements.json)). The [five final UI cases](final-ui-summary.json)
pass on the corrected app: Day control/prepared, Agenda control/prepared and
prepared Week. [Final accessibility counts](final-accessibility-counts.json) retain
754 Agenda event nodes and 700 unique labels with both renderers.

The [targeted early-event run](early-first-summary.json) adds events 1/4/7/10 rather
than accepting a newly selected first-visible event. The reference passes all four:
y positions 155.3/170.3/185.3/200.3 instead of the identical pre-fix 150.3. The prepared
case stops before tapping because event 1 lacks the prepared marker. Its failure
tree contains 98 other prepared markers, including cells with the same 15-point
height. Preparation admission/visibility remains under diagnosis; this is not
claimed as a renderer or marker fix. New bounded diagnostics record queue rejection
count and at most 16 rejected titles (128 UTF-8 bytes each) only when profiling.
The experimental marker-only change was reverted without building it.

The early-test Xcode process stayed live after XCTest finished. Sampling identified
`collectSimulatorDiagnostics` waiting for its `simctl diagnose --timeout=600` child.
Terminating that owned diagnostic child allowed the original failed result to
finalize with exit 65. Partial diagnostics, result and attachments remain. The
next focused assertion run uses `-collect-test-diagnostics never`; assertions,
results, screen recordings and explicit attachments remain enabled.

[Diagnostic Mail comparison](mail-diagnostics.json), previous/candidate/candidate/previous:
12.653/12.072/12.331/12.225 ms. Process CPU closely follows wall time, with zero
reported major faults or context switches and nominal thermal state in all four
first-page samples. This collection does not reproduce or explain the original
18.642/15.254 ms failures. No budget or baseline changed, and those failures remain
retained. The diagnostic candidate is the early-test build before queue counters;
its actual binary hashes are included. The early test build relinked the app, so
its identity is distinct from the preceding component/five-case UI binary even
though only test source changed at that step.


## Preparation queue diagnosis

The [profiled failing transition](queue-diagnostic-idle.json) records 19 queue
rejections, no raster-cache rejections, 118 renders and a drained queue. Cache
pixels are 5,616,608 bytes and consumer pixels 3,133,088 bytes, each below its
32 MiB cap. The first 16 rejected titles descend from event 18 through event 3;
the bounded report does not name the remaining three. Thus this result establishes
queue saturation, not a specific rejection record for event 1. The targeted UI
assertion still fails before that event is tapped.

A one-main-queue-turn admission deferral is under controlled comparison with the
immediate-rejection policy. It gives obsolete-view cancellation callbacks a chance
to release capacity, then applies the unchanged 128-job cap. It does not spin or
increase the queue. The prepared renderer remains audit-only; this experiment is
not yet an accepted integration or speed improvement.


The unchanged [eight-case component suite passes](component-admission-gate.json).
The same-binary deferred/immediate/immediate/deferred app comparison gives
pass/fail/fail/pass ([results](admission-results.json), [binary](admission-binary.json)).
Both failures occur at event 1's prepared marker assertion before tapping; both
passing runs open events 1, 4, 7 and 10 with their own correct details.
These remain correctness results, not UI-latency measurements.

The [265-check lifecycle result](preparation-admission.json) includes 11 alternating
replacement races per policy. Immediate admission rejects all 11 replacements;
one-turn deferral accepts all 11 after the obsolete job is cancelled, with no
queued work left. Median replacement API completion is 1.952 ms and max 10.479 ms
with deferral. Immediate rejection returns nil in median 0.005 ms/max 0.009 ms, so
these are different outcomes rather than a claimed speedup. The new latency tail
remains explicit; no frame/input acceptance follows from this component check.

The app idle snapshots are captured once, seven seconds after stress readiness;
they are **not end-of-test counters**. Both passing snapshots report zero deferrals
and zero rejections; the controls report five/four rejections. Therefore they do
not establish that the passing transitions exercised deferral after the snapshot.
The focused lifecycle test provides the direct cancellation-race evidence. A future
interaction collector must timestamp and bracket preparation through completion.
The renderer remains audit-only pending native viewport integration and physical
performance acceptance. The iPad correctness outcome is recorded below; prepared Agenda coverage fails.


## iPad startup failure, isolated from calendar rendering

The iPad Simulator run failed before stress readiness or calendar display. The
retained [interrupted result](ipad-admission-summary.json) contains one main-loop
snapshot timeout and one explicitly cancelled test; the remaining two did not run.
After sampling the app and its own Simulator's locationd, the run was stopped
rather than repeatedly waiting for unrelated calendar assertions. App samples
show all 1,519 main-thread samples in `OnboardingStore.init`, line 35's synchronous
`locationManager.authorizationStatus`, waiting on an XPC reply. The location daemon
itself is waiting on internal serial queues; unsymbolicated frames do not establish
its underlying cause. Screenshot and raw samples remain under the local artifact
root (`ipad-startup.png`, `ipad-startup-sample.txt`, `ipad-locationd-sample.txt`).

Apple's [authorizationStatus documentation](https://developer.apple.com/documentation/corelocation/cllocationmanager/authorizationstatus-swift.property)
guarantees the initial and changed statuses through the delegate callback. The
candidate initializes status as notDetermined, reads it only when that callback
arrives, and suppresses identical publications. It removes the eager initializer
and refresh queries. This is not fixture-only bypassing: production follows the
same callback path. Validation is pending against the same stalled Simulator
service, which has not been restarted. Permission requests remain explicit.


The service recovered without being restarted while the candidate compiled. The
[normal-service A/B/B/A run](location-startup-comparison.json) starts all four
builds (10.734/8.112/8.112/8.147 seconds to the component report); it does not prove
the hang was fixed or establish a warm startup improvement.

A [controlled paused-service comparison](location-startup-paused.json) retains four
30-second timeouts. The old build waits in OnboardingStore's status getter; both
intermediate candidates pass that point and then wait in WeatherStore's synchronous
`locationManager.location` getter. Thus the onboarding-only change is insufficient.
The selected Simulator's locationd was resumed in finally and confirmed running.

The next candidate uses delegate-delivered weather location/authorization, keeps
one recent location for at most the existing 15-minute forecast TTL, and waits
asynchronously when initial authorization has not arrived. Denial clears that local
location. Persistent reproduction lives in
[the startup collector](../../../../tools/onboarding-location-tests/README.md).
Validation of the combined change is pending. These faults are separate from the
calendar renderer and are not counted as calendar performance acceptance.


The combined change passes the [controlled fault comparison](location-startup-combined-results.json)
with [binary/device/collector identity](location-startup-combined-identity.json).
With the same Simulator locationd paused, both old launches time out at 30 seconds;
both combined candidates produce the complete 30-day report in 8.374/8.167 seconds.
The candidate screenshot visibly contains the Week calendar and Stress ready badge.
The daemon was resumed and its process state confirmed running. These are startup
availability and workload checks, not an 8-second navigation claim or UI-budget pass.
iPad interaction and final component results are recorded below.
The collector also rejects an unbooted Simulator before creating output or installing
an app; no physical-device destination is accepted.


The [post-recovery iPad UI run](ipad-location-fixed-summary.json) passes three of
four cases: early-event reference selection, prepared Day scroll and prepared Week
scroll. The prepared early Agenda case fails at the unchanged prepared-marker
assertion before tapping. Its [one-shot profile](ipad-early-idle.json) records 119
admission deferrals and 74 remaining queue rejections, zero raster rejections and
a drained queue. Consumer/cache pixels remain below their 32 MiB limits. This shows
the one-turn deferral does not cover the iPad's larger demand; do not generalize the
iPhone pass to iPad. Prepared-artwork default rollout remains blocked by this
coverage failure, independently of physical frame/input acceptance. The live
reference remains available. The iPad Simulator is shut down after collection.

The next renderer integration must address viewport demand and bounded admission,
not merely raise the pending limit to turn this assertion green. Apple's native
[collection view custom-layout API](https://developer.apple.com/documentation/uikit/customizing-collection-view-layouts)
supports cached frames and rectangle queries, and
[UIHostingConfiguration](https://developer.apple.com/documentation/swiftui/uihostingconfiguration)
can preserve the existing SwiftUI cell content while native UIKit owns reuse.
That hosting API supports iOS/iPadOS and Catalyst, not native AppKit; Mac needs its
own NSCollectionView adapter. These are candidates for measured integration, not
performance claims or an already implemented native viewport.


The final location candidate's [component gate fails](component-location-final-gate.json)
because [host process sampling](component-location-final-host.json) timed out in
scale-90d, redraw-plan and redraw-mail. No overlapping compiler/test process was
recorded, and no component latency, RSS or redraw assertion failed. The sampler's
`ps` subprocess exceeded its unchanged two-second timeout. Load averages were high,
but that alone does not identify the cause; the incomplete monitoring cannot be
called a clean pass. All [measurements](component-location-final-measurements.json)
are retained. A clean comparison remains required; neither budget nor monitor
timeout has been relaxed.


Native Mac validation initially selected the wrong `Banana` scheme, which builds
an iOS-on-Mac app; that build was interrupted with exit 75 and is not AppKit evidence.
The correct `BananaMac` universal build compiled the changed sources but failed
linking x86_64: the vendored Needle XCFramework declares only `macos-arm64`, and
the linker reports missing `_needle_*` symbols after ignoring its ARM library.
The vendor binary was not changed. Both logs are retained locally. A separate
explicit ARM64 AppKit build targets this host; no Intel compatibility pass is claimed.


The [explicit ARM64 AppKit build passes](appkit-arm64-build.json), with the linked
binary verified as ARM64. No native window was opened and no Mac interaction or
frame timing is claimed. The unsupported universal/Intel link failure remains
retained. The corrected Simulator source has not changed during this validation.


The subsequent [monitored component run fails actual timing budgets](component-location-clean-gate.json),
with [all raw samples retained](component-location-clean-measurements.json). The
30-day first Notes search is 52.168 ms, above the regression limit. At 90 days the
first Notes search is 153.419 ms and first podcast next/download queries are
259.949/258.995 ms, above the absolute 100 ms component budget. The following six
samples are substantially faster. Completed developer-process monitoring does not
mean the whole host is idle; it does not waive these failures.

A matched old/new/new/old diagnostic sequence runs the unchanged 1/7/30/90-day
workloads for each binary. [All four 90-day diagnostic records](cold-query-diagnostics.json)
reproduce the cold-query failures, including the previous pre-location-change build.
Thus they are not specific to the location callback changes. In the first old
run, the 292.341 ms podcast query uses 86.337 ms process CPU and reports 1,815
voluntary context switches; first Notes search is 154.176 ms versus 75.369 ms CPU.
This supports substantial waiting during cold work, but does not yet identify its
underlying wait location. A sampled trace is being collected separately; its timing
will not substitute for unprofiled acceptance. No performance failure is erased,
threshold increased or baseline replaced. The component suite remains failed.


The [sampled query stack summary](cold-query-stack-summary.json) reaches the actual
measured calls: Notes `count(*)` at NoteRepository.swift:146 and podcast payload
fetches at PodcastCatalog.swift:185 descend into SQLite pager `pread` calls.
Together with CPU/wall/context-switch diagnostics, this identifies cold file-read
waiting in these query paths. It does not identify a particular physical disk or
background process as the cause. Samples aggregate all seven invocations; they are
not individually timestamped to the first call. The [sampled model report](cold-query-sampled-model.json)
retains timing, but profiling overhead prevents substituting it for acceptance.
An earlier 1 ms sample captured only fixture construction and no model report;
that incomplete trace remains local and is not used as query evidence.

The source confirms fresh UUID-isolated fixture directories on every launch, so
this is not reuse of one accumulating logical catalog. Old directories do consume
disk, however. [Fixture cleanup](fixture-cleanup.json) preserves the latest full
90-day Notes/podcast databases (90,000/900,000 rows verified), all raw reports,
traces and comparison binaries, then removes only old ScaleStress-UUID temporary
directories in Banana containers on the two recorded owned Simulators. Workspaces
and worktrees remain intact. Both fixture Simulators are shut down.
