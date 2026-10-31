# Event-type texture prototype — October 10

The isolated prototype implements the user's dumbbell/phone/camera pattern idea
using SF Symbols cached in three small bitmap tiles and Apple's existing
[Core Graphics tiling API](https://developer.apple.com/documentation/coregraphics/cgcontext/draw(_:in:bytiling:)).
It calls the actual native event rasterizer for the baseline bars. No shipping
renderer, provider, cache policy or default was changed.

Reproduce with `tools/calendar-pattern-tests/README.md`. Retained output:
`.build/calendar-pattern-tests/run-1/` (`light.png`, `dark.png`, `results.json`).
The preview columns are current text, pattern only, and pattern plus a quiet
title area. Widths range from 16 to 180 points. This synthetic design matrix is
not the application's multi-calendar stress fixture.

## Component cost, not an improvement claim

Optimized Mac executable, 120 cases; 24 samples per case in rotating mode order.
All 120 exact-image checks after tile eviction/recreation passed.

| Variant | p50 | p95 | Max |
| --- | --- | --- | --- |
| Current text | 0.138 ms | 0.434 ms | 10.627 ms |
| Plain no-text control | 0.102 ms | 0.366 ms | 11.432 ms |
| Pattern only | 0.158 ms | 0.705 ms | 12.737 ms |
| Pattern with text | 0.182 ms | 0.667 ms | 5.736 ms |

Adding a pattern increased median and p95 raster cost. Maxima are noisy and do
not establish a faster variant. Retain the over-budget samples. The first symbol
tile took 29.389 ms to prepare; the other two took 3.498 and 0.862 ms. All three
tiles retain 29,952 pixel bytes, separate from event images and framework memory.
The first symbol cost must be moved ahead of interaction, not hidden in an average.
Cold draw samples, subsequent draws, tile recreation timing and pixel parity
are retained. Cached event-image lookups, peak RSS, physical UI, and input latency
are not measured. No host contention monitor was collected, so this run is a
design/cost feasibility check, not a calibrated performance improvement.

## Visual assessment and adoption gaps

Patterns communicate broad event type without columns of partial letters.
The narrowest bars still clip an icon; they cannot preserve the full event title.
Dark-mode contrast needs revision. The pattern-plus-title variant demonstrates
why a pattern does not rescue unreadable narrow text: use a deliberate width
policy instead of shrinking type. Wider cards can keep a readable quiet title.

Before shipping, choose event types from explicit metadata or confidently known
conference data, preserve calendar color independently of type, respect privacy
redaction, and retain invitation/completion/selection states and accessibility.
Cache identity must include type and appearance. Measure actual dense Day/Week
interactions on Mac/iPhone/iPad and rerun the persistent component suite after
app integration. This prototype is not integrated or user-testing ready in Beta.
