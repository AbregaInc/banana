# Native Core Text inside raster tiles — October 9, 2026

This opt-in experiment draws each raster-job line with native `CTLineDraw`, avoiding extraction of copied glyph, position and ink-bound arrays that are useful only when prepared text crosses threads. The line and bitmap context stay on the same worker. It changes neither geometry, glyph shaping, colors, clipping, cache limits nor the stress workloads. The production renderer and prototype defaults are unchanged.

Apple documents [CTLineDraw](https://developer.apple.com/documentation/coretext/ctlinedraw%28_%3A_%3A%29) as the native complete-line drawing API. The existing prepared-glyph path remains the matched control.

All 1,630 tile checks passed. Native-text versus prepared-text tiles are byte-exact; the pre-existing translated tile/full-page comparison retains its separate one-channel rounding bound. Checks cover 1x/2x/3x scales, 400/1200-point widths, 128/256/512-point tiles, visible IDs, scrolling, resizing, eviction and empty pages.

All 12 physical iPhone 14 Pro cases completed with valid evidence and budget failures. Three alternating-order trials use the same binary, both densities, and the original phases plus directional/32-ms rapid paging. No competing build or performance test ran concurrently. Values below are maxima in milliseconds over all trials.

| Density | Policy | Cold | Revisit | Scroll | Forward | Return | Rapid forward | Rapid return | Uncached | Recovery | Resize | RSS MiB |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 100 | budgeted | 34.519 | 9.097 | 3.870 | 61.886 | 8.560 | 27.306 | 15.992 | 64.249 | 32.733 | 21.073 | 43.44 |
| 100 | native-text | 32.472 | 9.845 | 4.631 | 60.175 | 9.484 | 24.897 | 14.593 | 60.644 | 33.964 | 20.930 | 43.62 |
| 300 | budgeted | 56.875 | 18.652 | 9.060 | 91.932 | 14.984 | 46.440 | 41.839 | 88.305 | 41.418 | 39.868 | 48.45 |
| 300 | native-text | 53.390 | 18.793 | 8.313 | 88.277 | 15.195 | 43.976 | 38.847 | 85.931 | 38.481 | 37.249 | 48.34 |

These component results do not establish input-to-visible latency or 120 Hz delivery. Native text gives only a small reduction in most uncached/rapid drawing costs, while other tails remain mixed. It does not resolve synchronous cold/miss work. Simulator, AppKit visible UI and full-client accessibility comparisons of this particular variant remain pending. No baseline or budget changed.

Reproduce with `run-device.py --matrix native-text --navigation-stress`; `--tile-native-text-only` selects the corresponding focused subset in the Simulator and AppKit runners. Exact sources and all failed samples are retained.
