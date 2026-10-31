# First offscreen Metal tile-compositing experiment

**Pixel correctness passed; UI acceptance is unmeasured. No production change or measured
end-to-end improvement is claimed.** This is the first building block for a presentation
comparison, not the CALayer-versus-CAMetalLayer comparison itself.

The standalone Swift probe uses the existing calendar geometry and RasterPage output.
Four prepared RGBA tiles are composited by CGContext and by a Metal triangle-strip pipeline
with nearest sampling. The inputs, clipping and integer offsets are identical. It covers
393-point/3x and 1366-point/2x surfaces on this Mac GPU, not an iPhone/iPad GPU.

The retained matrix has 1/100/300 events/day, 365 days, 12 calendars and two varied-fixture
seeds. Each process runs three trials, three resource states (initial upload, warm reuse,
eviction/reupload), and four offsets including a return to the initial viewport. CPU/Metal
measurement order alternates by trial. **All 432 comparisons were byte-exact**, stricter than
the existing one-channel tolerance. No events were decimated or simplified.

Across the matrix:

- GPU execution maximum: **0.402 ms**.
- CPU encode/submit plus waiting for GPU completion reached **109.61 ms**.
- Texture allocation/upload reached **130.61 ms**.
- CGContext compositing reached **42.80 ms**.
- Preparing the source tiles reached **405.41 ms** at 300 events/day.
- Whole-process peak RSS was approximately **150–174 MiB**, including fixture data, reference
  pixels, readback storage, CPU output and GPU resources; this is not an app memory budget.

The [initial probe](initial-probe-100.json) also retained first pipeline/target setup at
478.79 ms. Matrix pipeline/target setup ranged up to 152.19 ms. Runtime shader compilation is
included there and excluded from subsequent composition samples; caches are not forcibly
cleared between processes. A shipping implementation should prepare its pipeline off the
input path/use compiled shaders, but this experiment does not measure that optimization.

These tails are not discarded. The host monitor found no sampled competing developer
processes, but that does not mean the shared Mac was idle or free of scheduling/GPU contention.
The sample does not establish why each stall happened. It demonstrates why a tiny GPU duration
cannot stand in for complete response latency.

## Limits and next comparison

This offscreen probe waits synchronously for each command solely to attribute serial completion.
It is not a proposed main-thread render loop. It does not allocate a drawable, present, receive
touch/wheel input, integrate accessibility or measure display delivery. The CGContext reference
is offscreen CPU composition, not Core Animation's existing hardware composition. Therefore
these figures must not be presented as a speedup over our current CALayer renderer.

Uploads copy the prepared CGImage bytes into shared Metal textures. A controlled next step is
to compare IOSurface-backed texture sharing before drawing conclusions about presentation;
retain ownership until GPU completion and validate pixel format, color space and cache eviction.
Do not mix that optimization with glyph/text changes. The separate Skia evaluation should
address text/vector rasterization only after preserving font and layout fidelity.

## Persistent reproduction

```sh
swiftc -O -parse-as-library tools/calendar-library-benchmark/Shared/*.swift \
  tools/calendar-library-benchmark/MetalTests/main.swift -o .build/calendar-metal-tile-probe
python3 tools/calendar-library-benchmark/run-metal-tiles.py \
  --binary .build/calendar-metal-tile-probe --out NEW_DIRECTORY
```

The runner retains source/binary hashes, OS, all samples, host-monitor records, process memory
logs and nonzero exits. It deliberately returns 2 because UI acceptance is unmeasured.
No simulator or visible Mac test window is opened. Raw matrix files and logs accompany this
report. Initial build logs remain in `.build/calendar-capacity-20261009/`; the first compile
was interrupted after a source-edit/build overlap, and the subsequent build succeeded.

No shipping behavior changed, so the full-app regression suite was not rerun for this isolated
probe. The pixel oracle and persistent Python harness checks passed; physical Metal rendering,
energy/thermal behavior and production accessibility remain unmeasured.
