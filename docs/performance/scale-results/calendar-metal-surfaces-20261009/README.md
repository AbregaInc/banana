# Shared IOSurface textures versus texture copies

The controlled offscreen experiment shows a **texture-setup improvement**, with exact pixels,
but does not establish UI or frame-delivery acceptance. No shipping renderer, baseline or
performance budget changed.

## Matched comparison

Both variants rasterize the same varied-v1 calendar into immutable BGRA IOSurface-backed
CVPixelBuffers. The control allocates a Metal texture and copies the buffer bytes; the
candidate obtains a live Metal texture binding through CVMetalTextureCache. Both use the
same shaders, output format, offsets, reference images and synchronous completion probe.
Source preparation is identical and timed separately. CGImage reference conversion is also
separate; it is not hidden in the candidate's preparation/upload metric.

The matrix includes 1/100/300 events per day, 365 retained days, 12 calendars, two seeds and
three alternating fresh-process pairs per seed/density. Each process checks 393-point/3x and
1366-point/2x surfaces, three internal trials, cold binding/copy, warm reuse, and texture
eviction/recreation, with four offsets per state. These are viewport-sized surfaces on the
Mac GPU, **not iPhone/iPad GPU measurements**.

All **2,592 pixel comparisons were byte-exact**. All 36 matched viewport/workload pairs had
lower median texture-setup cost with sharing. Fixture checksums match within each pair.
The harness's 46 Python tests passed, including rejection of ignored source flags, wrong
pixels, missing eviction coverage and nonfinite timing data. All retained reports also
pass the final, stricter phase-multiplicity and required-metric validation.

| Metric | Copied surface, 393pt | Shared surface, 393pt | Copied surface, 1366pt | Shared surface, 1366pt |
| --- | ---: | ---: | ---: | ---: |
| Texture setup median | 2.810 ms | 0.063 ms | 3.799 ms | 0.060 ms |
| Texture setup maximum | 10.087 ms | 0.958 ms | 13.803 ms | 2.237 ms |
| Render completion median | 0.838 ms | 0.803 ms | 1.007 ms | 0.867 ms |
| Render completion maximum | 13.938 ms | 7.945 ms | 30.512 ms | 22.167 ms |
| Warm completion maximum | 5.684 ms | 7.533 ms | 28.186 ms | 11.359 ms |

Setup statistics count one measurement per trial/state, not its four repeated copies in the
offset records. Completion statistics include all samples and failures. The narrow warm tail
**worsened**; do not describe the result as a universal rendering improvement. The 22.167 ms
wide completion outlier remains above the direct-manipulation ceiling, although this probe
does not itself measure direct input. Source preparation still reached 267.278 ms in the
shared variant, so avoiding texture copies does not solve text/raster preparation.

Whole-process peak RSS medians were **191.03 MiB copied / 147.80 MiB shared**; maxima were
204.36 / 160.81 MiB. These include fixture, CPU reference, readback and GPU-related resources,
and are not production-app memory budgets. Logical resource accounting separates retained
source surfaces from additional textures; the shared path does not double-count aliases as
new pixel storage. The system may retain driver allocations beyond object release.

## Lifetime, eviction and limits

The probe retains both CVMetalTexture wrappers and source CVPixelBuffers until command
completion. It releases texture owners and flushes the Core Video texture cache before
recreating bindings. Sources remain immutable. This follows the lifetime requirement in
Apple's `CVMetalTextureCache.h`: retaining only an extracted MTLTexture is not used as the
ownership contract here. An asynchronous implementation must keep owners per in-flight
command and prevent source reuse while the GPU reads it.

Eviction here means GPU texture/binding eviction while retaining the source pixels, not
full source-cache eviction or an OS memory-pressure event. Pipeline and output allocation
are separately reported. Runtime shader compilation still occurs offscreen at initialization;
this experiment does not measure precompiled-pipeline startup improvements.

Host monitoring found no sampled competing developer processes. It cannot exclude other
shared-Mac CPU/GPU activity. No outliers were dropped. This does not compare Core Animation
presentation to Metal presentation, allocate a drawable, or measure input/VoiceOver behavior.
The deliberate serial GPU wait is a measurement device, not a proposed main-thread UI loop.

## Reproduction

```sh
swiftc -O -parse-as-library tools/calendar-library-benchmark/Shared/*.swift \
  tools/calendar-library-benchmark/MetalTests/main.swift -o .build/calendar-metal-surface-probe
python3 tools/calendar-library-benchmark/run-metal-tiles.py \
  --binary .build/calendar-metal-surface-probe --comparison surfaces --out NEW_DIRECTORY
python3 -m unittest discover -s tools/calendar-library-benchmark -p 'test_*.py'
```

The original comparison remains available without `--comparison surfaces`. All raw reports,
commands, timing/memory logs and host-monitor records accompany this report.
[Aggregate](analysis.json), [run status](summary.json), [source/binary identity](environment.json),
[harness checks](final-harness-tests.log). The runner returns 2 for unmeasured UI acceptance.

The justified next candidate uses shared textures, retaining this copying control. It still
needs presentation, asynchronous lifetime/cancellation, native interaction/accessibility and
real-device evidence before adoption. Skia's Metal/Core Text build is being evaluated separately
for rasterization; it must not be mixed into this single-variable comparison. Full-app tests
were not rerun for this isolated prototype-only change; integration requires the persistent
app regression suite. No baseline reduction is proposed until an integrated improvement is verified.
