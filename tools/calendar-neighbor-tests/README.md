# Mobile calendar neighbor geometry

This runs the production per-snapshot neighbor preparation against the frozen
preparation-free scans formerly used by Day/Week. It preserves lane geometry,
five-minute end joining, strict later-start checks, optimistic moves and minimum
projected Y across repeated DST hours. No persistent cache is introduced.

```sh
mkdir -p .build/calendar-neighbors
swiftc -O -parse-as-library \
  Banana/Model/CalendarMobileNeighbors.swift \
  Banana/Model/CalendarDayClockGeometry.swift Banana/Model/CalendarLanePlan.swift \
  tools/calendar-library-benchmark/Shared/Fixtures.swift \
  tools/calendar-neighbor-tests/main.swift -o .build/calendar-neighbors/checks
.build/calendar-neighbors/checks .build/calendar-neighbors/parity-and-ablation.json
```

The 444 geometry parity checks cover narrow/wide layouts, zoom, clipping, mixed lane counts,
optimistic time shifts, DST zones and strict joining boundaries. Timings alternate
policies with 12 samples each for unchanged uniform/varied fixtures, at mean daily
densities 10/100/300/1000. The busiest generated day includes overnight carry-in;
its actual visible event count is retained. The component does not render titles
or calendar colors and cannot establish UI capacity. Preparation includes the
production ID dictionary and consumer lookups, plus a result-array gather for the
oracle. Four additional boundary checks require duplicate source IDs to return no index,
with empty and singleton indices still valid. Both mobile renderers then use their existing
per-placement scans; no occurrence is removed or assigned another placement’s geometry.
All samples, including failures to meet product-sized budgets, are retained.

Fresh-process first invocation and 12 repeats, with process peak memory:

```sh
/usr/bin/time -l .build/calendar-neighbors/checks NEW_REPORT.json reference 100
/usr/bin/time -l .build/calendar-neighbors/checks OTHER_NEW_REPORT.json prepared 100
```

Run reference/prepared/prepared/reference sequentially, on an idle host, and retain
all logs. Fixture/lane construction precedes the timed neighbor operation; this is
not cold app startup. Each call rebuilds all values: there is no cross-update cache
or eviction behavior to time. Array stride measurements exclude dictionary/String
storage; use the matched process/app memory measurements for overall tradeoffs.

The optimized DEBUG app supports `--calendar-reference-neighbors`. Persistent UI
checks `testReferenceNeighborsVariedNativeDayScroll` and `testVariedNativeDayScroll`
compare the same native host with the same varied fixture. Week uses
`testReferenceNeighborsWeekScroll` / `testDenseCalendarScroll`. Include paging,
zoom, overnight move recovery, the full component gate and iPad coverage. Automation
wall-clock or scrolling signpost duration is not physical frame/input evidence.
