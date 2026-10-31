# Real event artwork adapter — October 9, 2026

The full calendar integration goal remains active. This change establishes the
real event-painting boundary needed by the native renderer; it does not yet replace
the production grid with the prototype surface, and claims no rendering speedup.

## Production changes

Mac `occurrenceBlock` and mobile `gridBlockContent` now build a `CalendarEventPaint`
value and call `CalendarEventArtwork`. The value contains title/time/icon data,
completion/skipped state, free/tentative/unanswered state, declined-guest warning,
calendar colors/ribbons, and optional travel/location captions. It owns no provider
object, store, gesture closure, EventKit identity or pending-write operation.

`CalendarEventPaint+Occurrence.swift` adapts the actual current occurrence. It does
not use fixture events or an ID-only cache. Return-leg eligibility and the existing
height-dependent caption formatting stay with the calendar's current logic.
Unneeded time-range formatting is not added to short blocks.

The two platform-specific visual trees moved into the shared artwork reference.
Desktop and mobile differences remain deliberate: title color, height thresholds,
icon rules, skipped opacity, ribbon inset/rounding, and travel/location text.
Ribbons, declined-guest marks and reply-state decoration are now independent of
provider models so native preparation and standalone parity tests can consume them.

The existing calendar still owns taps, context menus, recurrence handling, drag
feedback/commit, pending-write badges, failed-write retries, outer accessibility
labels/actions and blocked-day underlay. All-day controls and travel bands outside
the event block remain in the same production grid. This is a renderer-adapter
refactor, not an optimization accepted by the performance contract.

## Validation

The standalone reference comparison passed **2,496 exact RGBA comparisons** at 2x:
13 state/text cases × 8 heights × 3 widths × 2 appearances × 2 layout directions ×
2 platform layout branches. It covers narrow/short clipping, tasks/cues/alarms,
completed/skipped state, free/tentative/unanswered events, guest warning, merged
calendar ribbons, return travel, location/video captions and multilingual text.

The test-only reference freezes the old painting trees after mechanically adapting
occurrence fields to paint inputs. Therefore this checks painting given those
inputs, not the Occurrence adapter itself. Both layout branches use macOS fonts;
it is not an iOS pixel result. The new persistent CI command and reproduction are
in [`tools/calendar-artwork-tests`](../../../../tools/calendar-artwork-tests/README.md).
No tolerance, baseline or workload was loosened. The runner refuses to overwrite
an existing evidence directory.

The Release Simulator build and full eight-case persistent component suite passed:
[measurements](component-measurements.json), [gate](component-gate.json). Source and
logs remain under `.build/calendar-artwork-integration-20261009/`.
Six iPhone 17 Pro / iOS 26.5 Simulator UI tests passed: default/prepared dense
scrolling, cue time/activation, both crowded all-day controls, and short-event
height at both zoom levels. [UI summary](iphone-ui-summary.json). The final
[pixel report](pixel-report.json) retains all 2,496 cases and diagnostics.
33 Python harness tests, native Mac compilation, and the same six iPad checks
also passed ([iPad summary](ipad-ui-summary.json)). An unrelated build overlapped
part of the iPad run; its results establish correctness only. The local
`concurrent-builds.json` preserves this limitation.
Physical frame/input-to-visible measurements are not supplied by this refactor.

## Native framework check and next renderer step

Apple's [ImageRenderer documentation](https://developer.apple.com/documentation/swiftui/imagerenderer)
supports rendering SwiftUI's own text, shapes and images. That covers this extracted
artwork and provides a faithful reference for the prepared surface. Its
[Core Graphics render method](https://developer.apple.com/documentation/swiftui/imagerenderer/render(rasterizationscale:renderer:))
is main-actor isolated. It must not be described as an off-main-thread text engine.

The oracle retains diagnostic render times: roughly 0.6 ms median per block on this
Mac, with a 91.96 ms first reference call. Fixed reference-first order, framework
warm-up and offscreen rendering prevent an improvement claim. Recreating hundreds
of such views synchronously on an input callback would violate the intended design.

The next integration is a bounded prepared-artwork backend feeding the native
viewport surface, with explicit environment/content invalidation and cancellation.
Use the extracted reference to preserve pixels while evaluating native cached
artwork versus the prototype's prepared-text path. Measure cold mount, warm reuse,
eviction, rapid navigation and main-thread preparation independently. Preserve the
existing event actions and accessibility through native cells/overlays; do not keep
an invisible full SwiftUI grid as a substitute for integration. Default rollout
requires correctness and measured app-level benefit, followed by physical-device
acceptance. Email's native list/row preparation work remains after calendar.

## Prepared artwork cache and a production-color failure

`CalendarArtworkRaster.swift` adds a byte/count-bounded LRU with complete content,
size and rendering-environment invalidation. It is currently standalone-tested;
the app binaries above do not include it. Unsupported explicit symbol rendering
modes and oversized blocks reject preparation and require live artwork fallback.
The 32 MiB cache cap is not a device memory budget; surface/compositor ownership
needs a separate bound when integrated.

The initial `ImageRenderer.cgImage` backend failed exact clear/eviction recovery.
A cache-independent A/B/A probe reproduced 59 mismatches in 60 trials, with
one-byte alpha differences; reading the same image twice was stable. Rendering
through Apple's explicit `render(rasterizationScale:renderer:)` into an sRGB
8-bit CGContext produced zero mismatches in 60 trials. These are distinct
rasterization paths: their images differ and **cross-API parity is not claimed**.
All failed runs remain in `.build/calendar-artwork-integration-20261009/`.
See [cgImage repeats](repeat-cgimage.json), [context repeats](repeat-context.json),
and the [40-check cache result](raster-report.json).

Testing actual `CalendarColor.color(hex:)` exposed a second bug: newly created
platform color objects compare unequal even when their resolved RGBA is identical.
The key now uses resolved tint/ribbon components, retaining order/count and the
full remaining paint/environment identity. The original paint is still rendered;
normalizing the key does not alter the image. A controlled same-process ablation
recreates the production color for every request and alternates five policies.
The [46-check result and all samples](raster-color-report.json) retain:

| Component, 201 samples each | Median ms | p95 ms | Max ms |
| --- | ---: | ---: | ---: |
| No cache | 1.037 | 1.674 | 3.224 |
| Warm cache | 0.012 | 0.028 | 0.177 |
| Eviction/rerender | 1.026 | 1.653 | 2.463 |
| Recreated colors, resolved identity | 0.044 | 0.078 | 0.179 |
| Recreated colors, object identity control | 1.155 | 1.757 | 3.503 |

The resolved-color case retained 163,840 bytes versus 32,931,840 for the control.
This establishes an offscreen cache lookup/memory improvement for equivalent
production colors, not scrolling or frame delivery. First render took **90.529 ms**
in this run (62.037 ms in the previous run). Main-actor preparation cannot be
inserted synchronously into an input handler. All 14 comparisons against the
other export API differ and remain explicitly reported. No baseline was reduced
or replaced, and no physical performance acceptance was added.
