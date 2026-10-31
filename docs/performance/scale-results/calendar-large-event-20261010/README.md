# Large event image rejection — unresolved

The installed custom-renderer Beta retains the existing 2 MiB per-image guard.
A 1,440 × 120-point Day event at 2× needs 2,764,800 bytes and is rejected with
`exceedsEntryBudget`. The cache guard works as configured; the prepared view has
no large-event presentation route and consequently shows its failure state.
The request reproduction is retained in `before.json` and
`.build/calendar-large-event-20261010/repro.swift` (exit 1). This is component
evidence of the rejected request, not a screenshot of a live oversized event.

Apple's [CATiledLayer](https://developer.apple.com/documentation/quartzcore/catiledlayer)
provides asynchronous region drawing and is available through Core Animation for
the native hosts. Its clip bounds identify the requested region. A candidate
extracts the current event drawing into a caller-owned CGContext and adds bounded
region rasterization. Production files have not been changed by this experiment.

The candidate passes the existing 366 pure raster checks. A separate oracle
compares assembled tiles against a frozen copy of the current production renderer,
covering 20 combinations of event size and visual state. The largest full oracle
image is 33,177,600 bytes; individual candidate images are at most 1,048,576 bytes.
The full allocation is test-only and does not raise the production budget.

**Four exact-pixel cases fail**: three tentative hatch cases and one large dashed
border case. Differences reach 30 channel levels; these are not declared harmless
noise. A one-pixel overscan diagnostic still fails four cases. Both failures and
per-case deltas are retained. Tile composition includes extra copying and repeated
layout; its timings do not establish a speedup. No CATiledLayer host, memory-pressure
behavior, device interaction or frame timing has yet been tested.

Candidate/frozen source and harnesses remain under `.build/calendar-large-event-20261010`,
with hashes in `source-identity.json`. The initial harness compile failure (top-level
statements in a non-main Swift filename) and corrected compile are both retained.
No baseline, budget, scenario or failing result was changed to obtain a pass.

## Direct-drawing candidate

Converting strokes to outline fills produced the same four tile failures. That
candidate is retained and was not promoted. A separate source change extracts
`CalendarNativeEventRaster.draw` for a caller-owned graphics context. Oversized
prepared events now select `CalendarNativeEventCanvas` in source; this invokes
the same custom Core Text engine through SwiftUI's
[Core Graphics proxy](https://developer.apple.com/documentation/swiftui/graphicscontext/withcgcontext(content:)).
It does not invoke CalendarEventArtwork or allocate an over-budget cached image.
Framework backing-store memory and redraw costs remain unmeasured; this is not
a claim that total memory is reduced. The installed Beta has not been updated yet.

The actual Canvas capture successfully renders all 20 cases, including the large
blocks. **All 20 strict pixel comparisons still fail**, at one channel level in
130–282 bytes per image. Capturing both the frozen bitmap and Canvas through the
same ImageRenderer export does not remove the difference. Removing symbols,
using a plain title, combining both, and normalizing the metadata alpha to Float
also fail. The first differing pixels lie on the metadata line; the underlying
cause is not established. No scenario or tolerance has been changed to pass.

`tools/calendar-native-event-tests/direct.swift` and `FrozenEventRaster.swift`
retain the comparator and unchanged frozen drawing source. Runs and diagnostic
PNGs are in `.build/calendar-direct-event-20261010`. ImageRenderer is used only
to capture this test's Canvas, not by the proposed oversized-event presentation.
The integrated source compiles and passes 291 preparation lifecycle checks.
Live oversized-event interaction, device memory, persistent component regression
after this change, and physical frame/input acceptance remain pending.

## App-level check

`CalendarLargeEventIntegrationTests.testOversizedDayEventOpensAfterScrolling`
launches only an explicitly supplied `com.boris.banana.mac.large-event-review`
binary. It uses the existing varied-v1 seed 20261009 at density 1; the first
day contains the 36-hour “Family appointment · 0-0”. The test requires a block
larger than the unchanged 2 MiB image cap even at 1×, scrolls, retains a screenshot,
and opens the matching inspector. Screenshot inspection is still required to
verify the artwork itself; event accessibility alone is not proof of rendering.

Build commands, source hashes, the isolated launcher and pending run evidence are
under `.build/calendar-large-app-20261010`. The launcher checks desktop idle time
before UI automation. This is a functional integration check, not performance
acceptance, a normal signed review build, or evidence for iPhone/iPad.

The isolated Release Beta app and native XCTest runner both compiled successfully.
The app binary SHA-256 is
`bb8a0dcf9f44d79aa9a6156f95acaa2b23632abaf85ac5efe771c8174e0203a2`.
Visible execution is awaiting host availability: the first monitor samples show
one-minute load above 750 on this 10-CPU host. The launcher records samples and
waits up to 15 minutes for load at most 20, then requires at least 120 seconds of
desktop inactivity. These are test-start conditions, not performance tolerances;
no measured failure is removed or normalized. No UI pass is claimed yet.

The load-only wait was stopped before any test ran. Direct host samples showed
varying available CPU; the functional test was run under retained contention,
with no performance inference. It **failed**: `stress.ready` was absent after
30 seconds, and the captured app accessibility hierarchy contained no window.
No event assertion was reached. The failure, video, hierarchy and host samples
remain in `ui.xcresult`, `attachments` and `host-before-functional.txt`.

The app process survived XCTest's failure despite function-local `defer` cleanup.
Subsequent CUA inspection found the live Day view and `stress.ready`. Scrolling
to 2 AM showed the oversized event's title, time, ribbon and background; clicking
it opened the matching inspector. A follow-up screenshot confirmed artwork after
the inspector changed the available width. Tool conversation retains this visual
evidence. This is manual functional evidence, not a passing automated test or
timing acceptance. Startup cause is not established. The next run explicitly
activates the app and moves cleanup into XCTest's `tearDownWithError`, retaining
the same app binary and all original assertions; results go to `activated-launch`.

`activated-launch` also failed at the same readiness assertion. Teardown did
terminate its app, so that cleanup repair is retained. A third diagnostic using
Apple's [NSWorkspace application-opening API](https://developer.apple.com/documentation/appkit/nsworkspace/openapplication(at:configuration:completionhandler:))
also failed readiness (`workspace-launch`); it is not retained in the test source.
Both failures are preserved. No automated run reached the Calendar assertions,
and no startup cause is claimed. The successful manual interaction evidence is
limited to the process inspected after the first failure.

Further evidence, all against the same app binary:

- `sampled-launch`: **1 passed, 0 failed, 0 skipped**. All geometry, scrolling
  and matching-inspector assertions ran. The sampled process was mostly waiting
  in its main event loop; this passing-run sample cannot explain earlier failures.
  Its screenshot captured the wrong display and is not artwork evidence.
- `window-capture`: failed at XCTest screenshot creation on display 2, after the
  event-size and scroll checks. The failure is retained.
- `primary-capture`: **1 passed, 0 failed, 0 skipped**, after moving only the
  isolated review window onto the primary display. Event geometry was 836 × 1281
  points (4,283,664 RGBA bytes even at 1×). The screenshot captures the right
  window but is blurred; it does not establish text/artwork correctness. The
  clear earlier CUA views remain the visual evidence. XCTest also reported and
  dismissed an intervening basic macOS alert; its cause remains unestablished.

No app renderer change or readiness-timeout increase occurred between these runs.
Intermittent startup remains unresolved despite the two functional passes. The
test now records startup state on failure, captures geometry, and closes its app
in teardown. No app process from these runs remains active. The normal signed
builds are being refreshed separately as build 55; installation is not yet claimed.
