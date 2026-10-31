# Production calendar text adapter

`Banana/Views/CalendarNativeText.swift` is the worker-local multiline text portion
of the custom event renderer integration. It is not yet called by the shipping
event raster cache. Do not label these checks full renderer adoption.

The existing tile prototype's `PreparedText` only draws a single glyph line.
This adapter uses Apple's contextual line breaking and CTLine drawing to preserve
wrapping and fallback/color glyphs. It keeps Core Text layout objects on the
preparation worker, with only final event images intended to cross queues.
Sources: [CTTypesetterSuggestLineBreak](https://developer.apple.com/documentation/coretext/cttypesettersuggestlinebreak(_:_:_:))
and [CTLine](https://developer.apple.com/documentation/coretext/ctline).

Run without opening an app window:

```sh
mkdir -p .build/native-text-check
swiftc -O Banana/Views/CalendarNativeText.swift tools/calendar-native-text-tests/main.swift -o .build/native-text-check/checks
.build/native-text-check/checks .build/native-text-check/results.json
```

The persistent calendar-core CI job retains the report. It covers line budgets,
finite bounds, clipping, deterministic raster output, explicit CRLF/LF/Unicode
line breaks and an ellipsis oracle. Text includes Latin, combining accents, CJK,
Arabic and joined emoji. It does not establish SwiftUI pixel parity, correct
production fonts/styles, VoiceOver behavior or physical-device performance.

An alternating 200-pair ablation compares rebuilding layout plus rasterization
with reusing the same immutable layout plus identical rasterization. Every pair
must preserve exact bitmap bytes. All samples are retained; no budget or shipping
cache policy is changed. The initial local run is under
`.build/calendar-native-text-integration-20261010`; cold, eviction, memory and
full-app frame/input costs still require the actual event adapter and cache.
