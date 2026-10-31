# Calendar and list rendering research — October 9, 2026

## Decision

Keep the capacity search running. Do not adopt a library or start a shipping renderer rewrite
on the strength of generic performance advice. The next renderer comparison should retain the
current native implementation as control, isolate Metal presentation first, then compare a
maintained GPU text/vector engine before implementing a custom glyph atlas.

This is source research and an experiment specification, **not performance acceptance**.
No rendering behavior, dependency, budget or baseline changes as part of this research.
The [performance contract](ui-performance-contract.md) and
[capacity protocol](event-capacity-search.md) remain unchanged.

Follow-up: the [first offscreen Metal tile probe](scale-results/calendar-metal-tiles-20261009/README.md)
now has exact-pixel and timing evidence. It measures upload/composition of identical prepared
tiles, not displayed CALayer-versus-Metal performance; its retained tails prevent any claim
that tiny GPU execution alone satisfies the contract.

## What our evidence actually says

- The [existing library audit](regression-testing.md#library-first-calendar-evaluation-2026-10-08)
  already source-screened CalendarKit, KVKCalendar, HorizonCalendar, JZCalendarWeekView and
  ScheduleKit. CalendarKit/KVK are pinned in the isolated benchmark. Their earlier component
  results do not establish physical-device performance on the newer varied fixture.
- [Geometry experiments](scale-results/native-calendar-prototype-20261008/README.md) found
  compact scans faster for broad viewports, linear lane assignment faster at lower densities,
  and heaps faster at 4,000/10,000 placements. The prototype already has interval partitioning,
  normalized geometry, bounded day caching and visible-event queries. A new interval tree is
  an alternative to measure, not an automatically faster replacement.
- [The varied-fixture investigation](scale-results/calendar-varied-fixtures-20261009/README.md)
  found PreparedText construction in 2,712/4,296 sampled stacks. This was a late diagnostic
  capture after a timeout, with foreground and prefetch work included. It is neither exclusive
  CPU time nor a clean attribution of interaction latency. Text is a credible investigation
  target; GPU saturation and ARC dominance have not been established.
- Existing CGImage and IOSurface/CVPixelBuffer experiments are not a custom Metal renderer.
  Their cache-miss, recovery, memory and tail costs remain part of the comparison.

## Source-level candidate assessment

Default-branch revisions and commit dates were checked through GitHub's API on this date.
Recent commits are maintenance signals, not guarantees of support or compatibility.

| Candidate | Inspected revision/date; license | Platform and source findings | Disposition |
| --- | --- | --- | --- |
| CalendarKit | `99a4a05c641d70c3f735ef4256f60dc86580cf20`, September 12; MIT | UIKit/iOS and Mac Catalyst, not AppKit. TimelineView prepares a view per regular event attribute. Overlap grouping repeatedly sorts accumulated groups; layout is tied to layoutSubviews. Has an event pool and styling/delegate hooks, but private lifecycle methods constrain replacement. | Existing mobile day reference. No reason from this reinspection to select it as the shared dense renderer. |
| KVKCalendar | `0bcad2bd51e512a4088c0bcf65b85bc6e484d86f`, September 3; MIT | UIKit/Catalyst. Day/week/month/list features and custom view/rectangle-layout hooks; displayed-day event creation is not strict vertical virtualization. | Preserve as mobile week comparator; a lifecycle fork plus AppKit implementation would still be substantial ownership. |
| HorizonCalendar | `257927434aecbc4a70163570b5ef40976f0428a2`, September 3; Apache-2.0 | UIKit date/month grids. VisibleItemsProvider incrementally resolves the viewport; ItemViewReuseManager reuses view types. Not an hourly appointment scheduler or AppKit component. | Good candidate for date navigation and an architectural reference for viewport-bounded work. Do not generalize its historical UICollectionView measurements to every current collection view. |
| Texture | `d8aa8c796dd7770ea177989253ef1cf8878cd50a`, July 29; Apache-2.0 in LICENSE/podspec | Objective-C/Objective-C++, UIKit; podspec declares iOS/tvOS, not AppKit. ASDataController's default non-layout-delegate path visits the new element map and allocates/layouts elements lacking valid layout. ASRangeController manages display/preload ranges and shrinks them under memory pressure. | Study range management, background preparation and accessibility. An optional mobile Mail-row experiment, not a default whole-app migration. Bounded data windows are still required. |
| DGCharts | `1bad5469f57628782110b05996d4fa00473abf06`, March 4; Apache-2.0 | Package declares iOS/tvOS/macOS. LineChartRenderer uses CGContext, visible X bounds and CGMutablePath construction; Transformer composes affine transforms. Accessibility bridging exists for the platforms. | Useful source reference, not a calendar/email rendering core. No evidence that importing it solves our costs. |
| Skia / Ganesh Metal | `9f2a9afc0c4ec8c7a596d23981c57764aaed882b`, October 9; BSD-3-Clause core | Native C++ renderer, Metal context accepts MTLDevice/MTLCommandQueue. GrAtlasManager includes glyph atlas generation, lifetime and compaction machinery; a Core Text shaper is available. macOS/iOS build paths exist. | Shortlist a minimal adapter before writing our own GPU text engine. Build size, dependency licenses, Swift/ObjC++ bridge, native-font fidelity and device performance remain unmeasured. |

Pinned source references:

- [CalendarKit TimelineView](https://github.com/richardtop/CalendarKit/blob/99a4a05c641d70c3f735ef4256f60dc86580cf20/Sources/Timeline/TimelineView.swift),
  [KVK timeline](https://github.com/kvyatkovskys/KVKCalendar/blob/0bcad2bd51e512a4088c0bcf65b85bc6e484d86f/Sources/KVKCalendar/TimelineView.swift).
- [Horizon architecture](https://github.com/airbnb/HorizonCalendar/blob/257927434aecbc4a70163570b5ef40976f0428a2/Docs/TECHNICAL_DETAILS.md),
  [reuse manager](https://github.com/airbnb/HorizonCalendar/blob/257927434aecbc4a70163570b5ef40976f0428a2/Sources/Internal/ItemViewReuseManager.swift).
- [Texture data controller](https://github.com/TextureGroup/Texture/blob/d8aa8c796dd7770ea177989253ef1cf8878cd50a/Source/Details/ASDataController.mm),
  [range controller](https://github.com/TextureGroup/Texture/blob/d8aa8c796dd7770ea177989253ef1cf8878cd50a/Source/Details/ASRangeController.mm),
  [platform manifest](https://github.com/TextureGroup/Texture/blob/d8aa8c796dd7770ea177989253ef1cf8878cd50a/Texture.podspec).
- [DGCharts line renderer](https://github.com/ChartsOrg/Charts/blob/1bad5469f57628782110b05996d4fa00473abf06/Source/Charts/Renderers/LineChartRenderer.swift),
  [transformer](https://github.com/ChartsOrg/Charts/blob/1bad5469f57628782110b05996d4fa00473abf06/Source/Charts/Utils/Transformer.swift).
- [Skia Metal context](https://github.com/google/skia/blob/9f2a9afc0c4ec8c7a596d23981c57764aaed882b/include/gpu/ganesh/mtl/GrMtlDirectContext.h),
  [glyph atlas](https://github.com/google/skia/blob/9f2a9afc0c4ec8c7a596d23981c57764aaed882b/src/gpu/ganesh/text/GrAtlasManager.h),
  [Core Text shaper](https://github.com/google/skia/blob/9f2a9afc0c4ec8c7a596d23981c57764aaed882b/modules/skshaper/include/SkShaper_coretext.h),
  [build instructions](https://skia.org/docs/user/build/).

Accessibility and customization are acceptance work, not checkboxes inferred from native views.
CalendarKit's inspected Sources contain no explicit accessibility configuration matches;
that does not prove UIKit supplies no accessibility, but event labels/order/actions must be tested.
Texture explicitly supports accessibility for rasterized/layer-backed nodes; that makes it a
useful reference, not proof of our VoiceOver behavior. GPU engines supply pixels, not our event
semantics, keyboard navigation, native text editing or accessibility tree. Preserve native
controls for editing and an independent semantic event layer for a canvas.
[Texture accessibility](https://texturegroup.org/docs/accessibility.html)

## Corrections to the supplied advice

1. **Allocation:** value types do not inherently imply ARC traffic. Arrays can reuse reserved
   storage, though sharing/copy-on-write can still copy. Measure allocations, retains/releases
   and bytes copied before replacing safe storage with pointers. Reserve bounded working sets;
   never preallocate the entire retained history. "Zero allocation" should describe a measured
   steady-state path, not an assumed property of Metal.
   [Swift array capacity](https://developer.apple.com/documentation/swift/array/reservecapacity(_:))
2. **Calendar math:** interval lookup and lane assignment are separate problems. Use half-open
   intervals so adjacent meetings do not overlap. A sorted sweep with a heap can assign lanes
   efficiently, but our retained ablation already shows constants matter at realistic densities.
   Geometry keys must include data revision and calendar/timezone; text additionally depends on
   font, width, scale, language and appearance. Async results need generation checks.
3. **Virtualization:** UICollectionView is a sensible native starting point, not a performance
   guarantee. Its layout object is main-actor UI state: prepare immutable geometry off-main and
   publish it; do not dispatch its prepare() or UIKit mutations to a background queue. SwiftUI
   lazy creation is not a contractual fixed-size recycling pool.
   [UICollectionViewLayout](https://developer.apple.com/documentation/uikit/uicollectionviewlayout)
4. **Text:** a cached height does not make UILabel/Text rendering free. Prepare only the work the
   actual renderer can reuse. Core Text functions are thread-safe, but its layout objects should
   stay within one operation/queue/thread. Our PreparedText already copies glyph/position data
   out of worker-local CTLine/CTRun objects. Test mixed scripts, ligatures, emoji, bidi and font
   fallback; an ASCII-only atlas benchmark would be misleading.
   [Core Text](https://developer.apple.com/documentation/coretext)
5. **Updates:** actors isolate state but neither imply a dedicated background thread nor make
   synchronous work cheap. Use bounded immutable presentation snapshots and coalesce obsolete
   updates. Apple's diffable API can perform linear diffing off-main with consistent queue use;
   it does not make an enormous full-history snapshot cheap or promise automatic background
   diffing for SwiftUI. Native cell creation/layout and publication still have main-thread costs.
   [Apple data-source session](https://developer.apple.com/videos/play/wwdc2019/220/)
6. **Downsampling:** min–max and LTTB are different algorithms. Neither is a license to remove
   appointments. Viewport culling must preserve overlapping event identities, hit targets and
   accessibility; any aggregation would be a separate product behavior with explicit semantics.
   [MinMaxLTTB research](https://arxiv.org/abs/2305.00332)

## Apple sample findings

The exact supplied title "Processing a Large Dataset with Metal" was not located in the
official search. The verified introductory sample is
[Performing calculations on a GPU](https://developer.apple.com/documentation/metal/performing-calculations-on-a-gpu):
array addition, pipeline creation, buffers and command submission. It is educational compute
code, not a calendar renderer or a demonstration that GPU execution is instantaneous.

[Synchronizing CPU and GPU work](https://developer.apple.com/documentation/metal/synchronizing-cpu-and-gpu-work)
has macOS/iOS/tvOS schemes and demonstrates three reusable vertex buffers, a semaphore and
command-buffer completion. It still creates command buffers/encoders per frame. Reusable
resource allocation is not proof of an allocation-free render loop. Its blocking wait should
not be transplanted into our main-thread input path.

The more relevant source is
[Achieving smooth frame rates with a Metal display link](https://developer.apple.com/documentation/metal/achieving-smooth-frame-rates-with-a-metal-display-link).
The downloaded GameView/Renderer uses CAMetalDisplayLink, a preferred 120 Hz range and two
frames in flight. GameConfig.h defaults RENDER_ON_MAIN_THREAD to 1; an optional secondary
render-thread path exists when it is disabled. The default sample therefore also has a
potentially blocking main-thread semaphore wait. This establishes a concrete scheduling
option to compare with MTKView. It does not establish that our app meets the latency contract.
The sample is a game loop; calendar drawing should pause when unchanged.

Apple documents preferredFrameLatency values of 1 or 2 and says actual latency may be larger,
including windowed macOS. Compare these settings; do not assume two/three queued frames are
acceptable simply because throughput is smooth. Resource pool size and render-ahead policy
are separate choices. Preserve the latest input state while bounding queued work.
[Latency property](https://developer.apple.com/documentation/quartzcore/cametaldisplaylink/preferredframelatency)

MTKView already provides timed, invalidation-driven and explicit drawing modes; adding a second
CADisplayLink by default is unnecessary. A display callback, command completion, or transaction
flush is not an input-to-visible measurement.
[MTKView](https://developer.apple.com/documentation/metalkit/mtkview)

## Prioritized controlled experiments

| Order | Comparison and hypothesis | Required attribution and rejection conditions |
| --- | --- | --- |
| 1 | Finish multi-seed capacity confirmations and profile sparse versus dense pages. Separate fixed setup/pixel costs from event-dependent costs. | Same 12-calendar varied fixture; independent retained history/visible density; include cold, warm, recovery and rapid reversals. Sparse pages do not excuse slow fixed overhead. |
| 2 | Existing layer presentation versus Metal compositing the **same prepared tiles**, with identical data/text work. | Measure upload/copy cost, CPU encoding, drawable wait, GPU duration, presentation and memory. This isolates presentation; it cannot claim to eliminate CPU text shaping/rasterization. Reject if copying/queueing worsens tails. |
| 3 | Skia Metal drawing the same prepared event geometry and shaped text versus current raster tiles. | Establish native-font and clipping fidelity before speed claims. Pin the engine, keep bounded GPU caches, record build/binary size. Compare cold glyphs, warm glyphs and atlas eviction. This evaluates reuse of an established renderer. |
| 4 | Only if engine overhead is material: minimal Metal instanced rectangles plus a bounded glyph atlas, retaining Core Text shaping. | State the measured engine gap first. Single-variable buffer/presentation experiments, off-main preparation, no main-thread semaphore waits, stale-generation rejection. Full multilingual/color-glyph and semantic accessibility obligations remain. |
| 5 | Mail list: native reusable cells with bounded snapshots/prefetch; optionally Texture as an isolated comparator. | Profile current Mail first. Keep text wrapping/Dynamic Type and incoming-update behavior. Benchmark missed prefetch deadlines and width changes, not just cached row heights. No whole-app framework migration from calendar evidence. |

For each implementation item: alternate control/candidate, use at least three trials and two
fixture seeds near observed capacity boundaries; retain all failed runs. Include the unchanged
100/300-event workloads in addition to reduced-volume cases. Verify full event identities,
selection, drag, keyboard, VoiceOver focus, calendar filtering, resize and cache invalidation.
Add mutation/recurrence/all-day/provider-update cases before production acceptance: current
immutable timed-event fixtures do not cover them.

Record allocations/ARC samples, layout and text preparation separately from rasterization,
upload, encoding, GPU execution, presentation, process footprint and GPU resource bytes.
Measure idle power and sustained thermal behavior. Require physical iPhone/iPad plus visible
native Mac interaction for acceptance. The Mac checks wait for an idle session. Keep
8.3 ms frame work, direct p95 <10 ms/max20 ms and UI max100 ms unchanged; missing display/input
evidence remains unmeasured. Run persistent component/correctness suites after implementation
changes; propose reviewed baseline reductions only after verified improvements.

## Reproducibility

Research downloads and API snapshots are in `.build/calendar-research-20261009/`.
`rendering-research-20261009-sources.json` retains revisions, dates, download URLs and file hashes.
Only selected source files and two small Apple archives were downloaded; no framework was
installed, built or added to the app, and no simulator was created by this research.
The pinned links above support the source findings independently of local downloads.

## Skia calendar follow-up

The [matched raster experiment](scale-results/calendar-skia-raster-20261009/README.md)
now uses the pinned native Metal engine with existing Core Text glyph runs and
calendar geometry. Repeated raster timings favor Skia provisionally, but both
complete matrices contain host contention and all pixel comparisons fail. Dense
thin lanes are visibly darker. The candidate remains isolated; diagnose fidelity
and prepared-command reuse before native UI integration or adoption.

The [color and recorded-command follow-up](scale-results/calendar-skia-pictures-20261009/README.md)
identified discarded Generic RGB/Gray color spaces in the adapter, compared native
cubic paths, and used Skia's own SkPictureRecorder for bounded snapshot reuse.
Warm preparation drops to roughly 1 ms at 100/day, but completion tails, cold work
and native pixel parity still fail. The separate cache oracle retains its two
first-render mismatches; it must not be reported as a full pass.
