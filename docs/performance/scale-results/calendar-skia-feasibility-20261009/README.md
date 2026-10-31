# Skia native Metal feasibility — October 9, 2026

The pinned Skia build and corrected offscreen Metal/Core Text smoke check passed
on Apple M1 Max. **Calendar performance and visual parity remain unmeasured.**
No shipping dependency, renderer or baseline changed.

The optimized native arm64 build completed 829 Ninja steps. Configuration keeps
Metal Ganesh and Core Text while disabling unrelated codecs, PDF and SVG.
The GPU resource-cache limit in this smoke check is 32 MiB; this is not a bound
on total process memory or a proposed application memory budget.

The first smoke run exited 139: multilingual font fallback reached
`SkFontMgr::matchFamilyStyleCharacter` with a null receiver. Inspection of the
pinned `SkShaper_coretext.cpp` legacy font overload confirmed it constructs a
font iterator with a null fallback manager. The adapter now supplies
`SkFontMgr_New_CoreText` explicitly through the iterator overload. All original
strings remain, including accents, Japanese, Arabic and emoji. The corrected run
exited 0, produced three nonempty shaped blobs and 52,090 nonwhite pixels.
This is an integration-path fix, not a measured optimization or a general claim
about Skia's font support. The check does not yet validate individual glyphs.

[Successful smoke result](smoke-fixed.json), [failed debug output](smoke-debug.log),
[build/source identity](identity.json), and
[configuration and reproduction](../../../../tools/calendar-library-benchmark/SkiaTests/README.md)
are retained. Initial empty output and error files remain alongside the successful
run. The full build log remains at `.build/calendar-skia-evaluation-20261009/build.log`.

Next comparison must draw the existing varied calendar fixtures with the same
geometry, labels, clipping, dimensions, cache states and seeds. Measure cold
shaping/atlas population, warm reuse, eviction, memory and completion tails
against the existing renderer; retain any visual mismatch. Only then add native
presentation and physical input/scrolling evidence. This smoke test has no UI
timing gate and cannot satisfy the 8.3 ms or input-to-visible requirements.
