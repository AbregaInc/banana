# Custom event renderer integration

The production candidate consists of:

- `CalendarNativeEventAdapter`: resolves actual `CalendarEventPaint` colors,
  platform fonts and symbols on the main actor.
- `CalendarNativeEventRaster`: draws block fills, ribbons, invitation states,
  icons and multiline text with Core Graphics/Core Text.
- `CalendarNativeText`: contextual line layout and clipping.
- `CalendarArtworkRasterCache.Rendering.nativeCoreText`: connects the candidate
  to the existing bounded image cache. It does not construct ImageRenderer.

**The custom backend is now Beta's source default.** `CalendarArtworkPreparation`
selects `nativeCoreText` under `BANANA_BETA`, without a runtime opt-in. Signed Release
builds are installed on Mac, spare iPhone and iPad; cached Google events were checked
visually on Mac. Populated mobile coverage remains open. Placeholder/privacy redaction, unredaction cache recovery, and
return-caption symbols passed 156 adapter checks; populated device checks remain
required. Specialized non-event cues and VoiceOver remain separate integration
requirements. Raster work currently still executes through
the existing main-actor preparation coordinator; worker dispatch is not implemented.
Do not describe this as GPU rendering or complete calendar integration.

The pure renderer checks run in calendar-core CI:

```sh
mkdir -p .build/native-event-check
swiftc -O Banana/Views/CalendarNativeText.swift Banana/Views/CalendarNativeEventRaster.swift tools/calendar-native-event-tests/main.swift -o .build/native-event-check/checks
.build/native-event-check/checks .build/native-event-check/run
```

`compare.swift` links the same artwork/cache/design sources as the existing
`tools/calendar-artwork-tests/raster.swift` runner plus the three candidate files.
It records 20 light/dark, mobile/desktop, state cases, with alternating preparation
order and 12 samples per backend per case. First-use samples are retained. It also
checks native warm image identity, exact native pixels after clearing/rebuilding,
and retained cache pixel bytes. PNG pairs are retained for visual review; the
candidate is **not pixel-equivalent** to SwiftUI and these differences are not
accepted by changing the frozen reference or relaxing its existing oracle.

Initial evidence: `.build/calendar-native-event-integration-20261010`.
Pure checks passed 366 cases. The adapter compiled for macOS and arm64 iOS 26.1.
The first direct comparison and subsequent cache-path comparison are both retained.
Cache-path native p50/p95/max preparation: 1.003/2.427/38.198 ms; reference:
2.188/6.031/91.844 ms. Warm native lookup maximum: 0.053 ms; explicit clear/rebuild
maximum: 1.958 ms. Each retained event image occupied 288,000 pixel bytes.
These are uncached component comparisons of different artwork, not frame or input
timings, calibrated regressions, memory/RSS acceptance or a speedup claim for the app.
The complete persistent app suite and physical interaction acceptance remain open.

## Oversized-event app check

`CalendarLargeEventIntegrationTests` is a real Mac Calendar interaction check,
using the existing varied-v1 fixture's 36-hour event. It requires an explicitly
supplied optimized DEBUG/BANANA_BETA app whose bundle identifier is
`com.boris.banana.mac.large-event-review`; an installed normal Beta is rejected.
The app must not already be running. The test launches the isolated fixture,
scrolls its oversized block, captures it, opens the matching event and terminates
only that test app. It does not write to Google Calendar.

Once that dedicated binary has been built, run during an authorized idle session:

```sh
TEST_RUNNER_BANANA_LARGE_EVENT_APP='/absolute/path/Calendar Large Event Review.app' \
BANANA_NATIVE_REQUIRE_IDLE_SECONDS=120 \
bash tools/native-ui-test.sh CalendarLargeEventIntegrationTests/testOversizedDayEventOpensAfterScrolling
```

Keep the xcresult and inspect `oversized-day-event-visible`: the event's accessible
button and matching detail do not by themselves prove its artwork rendered.
The test's frame-size assertion checks that the event exceeds the unchanged image
cap even at 1×. This test supplies no frame, input-latency or memory acceptance.
The initial build and deferred execution evidence is recorded in
`docs/performance/scale-results/calendar-large-event-20261010/README.md`.
