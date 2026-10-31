# Visible Metal calendar experiment — October 9, 2026

**Not accepted for shipping.** This is an isolated Skia/Ganesh Metal preview using
native AppKit/UIKit scroll input, immutable recorded drawing commands, one background
page-preparation worker, and adjacent-page prefetch. The production calendar is unchanged.

Evidence lives in `.build/calendar-live-20261009/`. The pinned Skia checkout and
libraries live in `.build/calendar-skia-evaluation-20261009/skia` (revision
`9f2a9afc0c4ec8c7a596d23981c57764aaed882b`). Do not delete raw failures or binaries.
The [sanitized measurement archive](measurements.json) retains statistics, failures,
source/binary identities, exact-image summaries and paths to the complete local evidence.

## Workload and measurement boundaries

Physical phone: spare iPhone 14 Pro / Apple A16 GPU / iOS 27.0.1 (24A446), maximum
display capability 120 Hz. A maximum capability is not observed sustained refresh.
All measured phone runs use `varied-v1`, seed 20261009, 365 retained days, 12 calendars,
unique daily/weekly content, and the unchanged interval layout. Density means mean
new events/day; overnight continuations increase the number of visible placements.
At density 100 the fixture retains 36,500 events; the first five-day page has 728
placements. This dense week layout is a renderer stress case, not a finished phone UX.

The JSONL collector records CPU encode intervals, native scroll/button callback times,
page request times, and `CAMetalDrawable.presentedTime`. A callback starts after input
has already reached the UI framework. This is **not full hardware input-to-visible
acceptance**, and CPU encode is not total CPU/GPU/compositor frame work. Missing/zero
presentation times are retained, never converted into fast samples. Later scrolling
cannot supply a missing page-publication timestamp. Early `presentation-summary.json`
files from the initial matrix may use the earlier page attribution; use the retained
`presentation-summary-v3.json` reanalysis where present (otherwise v2).

XCTest verifies scrolling controls, date changes, cache clearing and returning to the
original page. It does not verify every event's pixels, accessibility, hit testing,
selection or edit behavior. Native screenshots are retained in each result bundle and
exported attachment directory. Automation gesture duration is not an app latency.

## Initial results

The first varied physical-phone run (`phone-functional-100`) passed its functional
scenario, but CPU encoding reached **347.07 ms** on first use. Keep this failure even
though later process launches benefit from existing system/driver caches.

| Mean events/day | Frames in flight | Scroll callback p95, ms | Maximum, ms |
| --- | ---: | ---: | ---: |
| 1 | 2 | 42.42 | 50.47 |
| 1 | 1 | 42.49 | 59.19 |
| 25 | 2 | 42.47 | 50.45 |
| 25 | 1 | 42.49 | 83.75 |
| 100 | 2 | 42.62 | 58.76 |
| 100 | 1 | 42.52 | 83.90 |

These are diagnostic single-process runs of the same binary, not a statistically
established performance baseline. Each includes six up/down gesture pairs, three
forward pages, cache eviction, and three backward pages. Full cold-page presentation
coverage is missing. No positive tested density meets the complete contract:
**even one event/day fails**. Lower event volume alone does not solve this prototype's
presentation/scheduling floor. One frame in flight is not an accepted improvement.

`CAMetalDisplayLink`, requesting 120 Hz and preferred frame latency 1, is a separate
opt-in ablation. Its first sparse run measured scroll callback p95 34.08 ms and maximum
40.70 ms; the first dense run measured 34.27 / 42.60 ms. It still fails. Samples showed
mostly approximately 16.7 ms presentation intervals; requested 120 Hz is not a grant.
Additional paired runs and GPU-completion admission are retained separately.

## Correctness findings and blockers

- Existing four-tile offscreen workload still validates all 18 runs after extending
  the adapter to support eight record-only tiles. Exact cache oracle: **286/288**
  comparisons match; two fail. Native Core Graphics parity also remains unresolved
  from the earlier experiment. No tolerance or baseline was changed.
- Two independent uncached dense renders differ in two pixels by one channel value
  (`uncached-repeat-comparison.json`). This establishes that tiny nondeterminism also
  occurs without command caching; it does not establish that every cache mismatch is
  harmless or resolve native parity.
- Mac manual scrolling, paging and eviction display varied content. Most native
  presentation timestamps are zero, including with display-link scheduling. These
  are unmeasured delivery samples. Mac timings during concurrent builds are contended.
- All three Mac XCTest startup attempts stalled before test code. The signed runner's
  sample stopped at `_dyld_start`; the bounded interrupted attempts and diagnostics
  are retained. Manual checks do not replace the missing Mac test suite.
- The iPad app installed, but launch was denied because the device relocked and now
  requires its passcode. No physical iPad result is claimed.
- The first persistent component-suite attempt refused measurement because another
  Xcode build/test was running. This is retained as **unmeasured**, not a pass.

## Reproduction

The experimental XcodeGen project references the pinned iOS library at
`skia/out/CalendarIOS/libskia.a`; its GN configuration is `SkiaLive/ios-args.gn`.
Generate and build the `CalendarMetalLiveUITests` scheme in Release for a physical
iOS destination, with a unique derived-data directory. The standalone Mac target
is compiled from `SkiaLive/{App,Model}.swift`, the four shared fixture/geometry files,
`LiveBridge.mm`, and the pinned native static library.

```sh
python3 tools/calendar-library-benchmark/run-live-metal-device.py \
  --device AUTHORIZED_DEVICE_UDID --density 100 --max-inflight 2 \
  --derived-data PATH_TO_BUILT_DERIVED_DATA --out NEW_DIRECTORY
```

Add `--metal-display-link` to select Apple's pacing API. Add
`--release-on-gpu-completion` only for the distinct admission-control ablation.
The runner installs only `com.boris.banana.calendar-metal-review`, verifies fixture
and policy identity, retains logs and screenshots, and never overwrites an output
directory. A functional pass never changes the performance verdict to accepted.

```sh
python3 tools/calendar-library-benchmark/report-live-metal.py LOG.jsonl --out NEW_SUMMARY.json
python3 -m unittest discover -s tools/calendar-library-benchmark -p 'test_*.py'
```

Reporter exit 1 is observed budget failure; 2 means full acceptance is unmeasured.
The diagnostic reporter never emits an overall acceptance pass.

## Native API references

- [Drawable presentation timestamps](https://developer.apple.com/documentation/metal/mtldrawable/presentedtime):
  zero represents an unpresented/dropped frame.
- [Metal display-link sample](https://developer.apple.com/documentation/metal/achieving-smooth-frame-rates-with-a-metal-display-link)
  and [CAMetalDisplayLink](https://developer.apple.com/documentation/quartzcore/cametaldisplaylink).
- [Preferred frame latency](https://developer.apple.com/documentation/quartzcore/cametaldisplaylink/preferredframelatency):
  the supported values are 1 and 2; the system can impose greater latency. This
  experiment uses 1, not an undocumented zero-latency setting.


## GPU completion, capture overhead and native scrolling

With the Metal display link enabled, admitting the next frame at GPU completion
instead of waiting for presentation reduced the measured scroll callback p95 from
34.09 to 33.03 ms at one event/day, and 34.28 to 33.31 ms at 100/day. Dense maximum
latency remained 50.52 ms. Without the display link this admission change had no
meaningful benefit (42.49 versus 42.61 ms p95). These diagnostic runs all fail the
input budget, before accounting for input delivery before the callback.

XCTest capture was controlled separately using the same binary. Video capture gave
33.03 / 33.31 ms p95 at 1 / 100 events/day; screenshots gave 41.43 / 41.61 ms. Thus
switching to screenshots did not remove the floor. Neither variant disables all
system capture. Keep this measurement overhead explicit.

`--native-surfaces` rasterizes eight immutable IOSurface-backed CVPixelBuffers on a
background Metal context, then assigns them to eight layers inside the native scroll
view. Scrolling changes the native viewport without re-encoding calendar drawing
commands. CVMetalTexture wrappers remain alive until the background GPU submission
completes. This is a separate ablation, not a production renderer.

| Density | Direct cold readiness max | Native surfaces cold readiness max | Direct / native sampled footprint |
| ---: | ---: | ---: | ---: |
| 1/day | 16.77 ms | 24.75 ms | 58.4 / 110.1 MiB |
| 100/day | 85.18 ms | 92.82 ms | 98.3 / 146.6 MiB |

Readiness ends at publication, **before display**. Native layer assignment itself
was below 0.5 ms in these two runs; that does not prove fast visible response.
Pre-rendering all eight tiles increases cold work and retained memory. The fixture
still holds its history in memory; this experiment does not replace the shipping
disk-backed repository or certify unbounded history.

Partial eight-second Animation Hitches captures matched app updates to compositor
records. Sparse direct drawing had render-interval p95 9.52 ms / max 11.69 ms;
sparse native surfaces had 9.75 / 11.06 ms. Both fail the conservative interval gate.
GPU intervals were below 1.6 ms. Render intervals can overlap GPU work and extend
beyond it; their entire duration is not proven CPU execution. Frame lifetime (often
25–33 ms) is a pipelined interval, not single-frame work or input latency. Device-wide
VSync often ran at approximately 8.34 ms even when app presentation was slower.
No app-attributed HID-to-visible measurement is available. One dense native capture
has incomplete GPU attribution and remains invalid/unmeasured.

## Job-local text reuse

`--memo-text` retains shaped SkTextBlobs in separate title/hour maps during a single
page's command recording. It reuses text across overlapping tiles, releases the maps
with the job, and stays disabled by default. Same-binary physical comparisons:

| Density / trial | Control cold readiness max | Memo cold readiness max | Control / memo footprint |
| --- | ---: | ---: | ---: |
| 100/day, 1 | 92.42 ms | 64.22 ms | 146.0 / 144.1 MiB |
| 100/day, 2, reversed order | 92.63 ms | 64.80 ms | 145.8 / 143.5 MiB |
| 300/day, 1 | 185.69 ms | 113.08 ms | 183.8 / 177.9 MiB |

Each run retains the initial cold page, cache eviction, warm navigation and memory
samples. Warm readiness maxima remained below 1 ms. The 300/day candidate still
fails the 100 ms ceiling before display; the 100/day candidate misses the 50 ms goal.
Thermal state was nominal and Low Power Mode was false. These are measured preparation
reductions, not an accepted UI improvement or an established supported density.

Exact-pixel results remain blocking:

- Native BGRA surfaces versus original RGBA offscreen rendering: 0/12 complete cases
  exact, maximum channel difference 16.
- Memo versus no memo on the same native-surface backend: 6/12 complete cases exact;
  failing cases contain 18–472 differing pixels, maximum channel difference 6.
- Repeating the uncached native backend without memo: also 6/12 exact; 12–462 differing
  pixels, maximum channel difference 3. This demonstrates independent nondeterminism,
  but does not excuse the additional candidate differences.
- The final rebuilt default four-tile lifecycle oracle validates all 18 runs but only
  284/288 exact-image comparisons. The earlier 286/288 result is retained as well.

No pixel tolerance was relaxed, no failed image replaced, and no baseline was promoted.
A cross-run screenshot comparison with different final scroll offsets is explicitly
invalidated in `gpu-final-page-pixels-verdict.json`; it is not correctness evidence.
The new `--scenario pixels` runs a separate fresh-process physical test at offset zero:
next-page pixels must change, and returning/evicting must restore the original pixels.

## Additional reproduction and scope

Add `--native-surfaces`, optionally `--memo-text`, to the physical runner. The native
presentation-policy ablation accepts `--presentation-policy system|immediate|prefer120|both`.
It uses UIKit UIUpdateLink without a continuous idle redraw loop. Low-latency event
dispatch is not enabled: Apple's documented eligibility concerns Pencil events,
not the finger scrolling measured here.

`profile-live-metal.py` accepts the same options plus `--instruments-device`, and
retains both the physical XCTest result and partial Instruments tables. Every new
functional verdict requires exactly the requested test to pass on the requested
device, with no skipped/expected failures. A successful xcodebuild exit alone is
insufficient. The runner preserves the selected capture configuration and uses
unique paths even when nested profile output directories share the name `touch`.

The renderer still lacks event hit testing, editing, event accessibility, robust
preparation failure recovery and production cache invalidation. These capabilities
must be preserved before any adoption; a fast picture alone cannot replace a calendar.
The next investigation must separate compositor scheduling/waits from actual work
and obtain attributable input-to-visible evidence. Lowering event density has not
established a passing positive density for the direct redraw implementation.

Additional primary references:

- [CVMetalTextureCacheCreateTextureFromImage](https://developer.apple.com/documentation/corevideo/cvmetaltexturecachecreatetexturefromimage(_:_:_:_:_:_:_:_:_:))
- [UIUpdateLink immediate presentation](https://developer.apple.com/documentation/uikit/uiupdatelink/wantsimmediatepresentation)
- [UIUpdateLink preferred frame rate](https://developer.apple.com/documentation/uikit/uiupdatelink/preferredframeraterange)
- [Low-latency event eligibility](https://developer.apple.com/documentation/uikit/uiupdatelink/wantslowlatencyeventdispatch)


A considered opacity-only optimization was not implemented: Apple's
[CALayer.isOpaque documentation](https://developer.apple.com/documentation/quartzcore/calayer/isopaque)
says it changes Core Animation-managed backing storage, while supplied contents keep
their own alpha channel. Our layers receive CVPixelBuffers. That documentation does
not establish that toggling the property would eliminate blending for these buffers.


## Presentation-policy and physical pixel follow-up

At 100 events/day, partial native-surface traces compared UIKit system policy,
immediate presentation, preferred 120 Hz, and both. All retain inclusive render
interval overruns (maxima 13.01, 11.83, 11.49, and 10.65 ms respectively). The system
run also has two app-update intervals over 8.3 ms. These single traces do not establish
policy superiority. Sparse policy controls are retained separately; an interrupted
Documents transfer after one successful XCTest is preserved, with the original
process log recovered from the next successful export. It is not a new trial.

Explicit frame-wait attribution changes the diagnosis, **not the gate**. In the dense
“both” trace, all 656 matched render intervals have frame-wait records. Intersecting
those waits with each render interval yields p95 4.34 / max 5.03 ms outside explicit
waits, versus inclusive p95 9.72 / max 10.65 ms. This derived interval is not CPU
execution time, and subtraction cannot establish input latency. The persistent
reporter now includes this optional diagnostic while keeping the original inclusive
failures. Unit tests prevent overlapping waits from being subtracted twice or
turning an inclusive failure into a pass.

The separate physical pixel scenario at 100 events/day passed for native surfaces
both with and without text memoization: paging changes content, and returning plus
cache eviction restores exact captured pixels. This covers only the visible phone
viewport at the fixed seed; it does not erase the broader offscreen oracle failures.
The native no-memo run still exceeds a measured readiness budget.

The direct renderer failed this stronger test with 110,692 differing pixels, much
larger than the small offscreen raster differences. Its initial drawable was stretched
when the newly populated status label reduced viewport height. Page geometry was
keyed by width/scale, so a height-only change did not request another draw. The isolated
AppKit/UIKit adapter now redraws when drawable size changes and the prepared page
matches width/scale. The unchanged-size guard prevents layout-triggered redraw loops.
The original failing screenshots and binary remain in `phone-pixels-direct`; matched
fix validation is recorded in `phone-resize-*`.


The corrected direct adapter passes the unchanged physical pixel test, including
return and eviction (`phone-resize-pixels`). Both iOS and native Mac Release builds
compile after the fix. This is a verified correctness repair in the experiment,
not a latency win; the matched control/fixed scroll timing remains separately reported.

The full persistent app component suite was attempted twice. `component-suite`
refused measurement because of a competing Xcode job; `component-suite-idle` compiled
but its first `simctl launch` exceeded 300 seconds. The latter directory name does
not establish idle conditions: its retained host note records overlapping builds.
No complete component result or regression pass is claimed. Mac XCTest remains
blocked before test execution and the iPad remains passcode-locked. The run's own
simulator was shut down and deleted; other workspaces' simulators were preserved.


At 100/day, the final direct-renderer control/fix pair measured scroll callback p95
42.631 / 42.629 ms, maximum 50.564 / 58.780 ms; CPU encode p95 8.079 / 8.054 ms,
maximum 22.821 / 22.794 ms. Cold readiness maxima were 82.51 / 83.18 ms and sampled
footprints 98.64 / 98.72 MiB. Thus the resize repair has no measured latency benefit;
retain the worse candidate tail. Both unchanged scroll/paging/eviction tests pass,
and both performance verdicts fail. No baseline reduction is proposed.

Final local checks: 59 calendar-harness policy/reporter tests and 30 performance
policy tests pass; iOS and Mac Release builds compile. The full app component suite
and physical Mac/iPad acceptance remain missing as described above. Cleanup retained
all binaries, failures, traces and source snapshots, removed 134.7 MiB of this run's
rebuildable iOS intermediates/caches, and deleted its disposable simulator. Workspaces,
worktrees and other agents' simulators were preserved.
