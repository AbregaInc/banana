# Prepared calendar snapshot day boundary

The opt-in `--calendar-cache-layout` path used 24 elapsed hours as its day filter.
The actual Day/Week ruler uses local midnight to next local midnight. At New York's
fall-back transition the snapshot omitted an event at 23:45; on the 23-hour spring
day its filter also accepted next-day records if supplied. Lord Howe's half-hour
transitions reproduced both mismatches. This is a snapshot-initializer finding;
the default recomputing path was not using this incorrect filter.

`WeekView.DayData` now reuses `CalendarDayRange`'s existing local boundaries.
The calendar/Agenda distinction, strict start/end comparisons, lane allocation,
cache ownership and default-off reuse policy are unchanged.

The persistent [snapshot checks](../../../../tools/calendar-day-snapshot-tests/README.md)
compile the actual initializer and allocator with minimal occurrence values.
The extracted source is retained beside the reports. The frozen initializer
failed four of 15 checks; the corrected initializer passed all 15. This covers
UTC, 23/25-hour and 23.5/24.5-hour days, carry-in, exact boundaries, untimed/blocked
items, Agenda's separate policy and immutable snapshot replacement. It does not
instantiate the real app service graph or prove a DST interaction on a device.

Both reports retain 21 fresh snapshot preparations at 100 and 1,000 events for
each date. The maximum corrected component sample was 0.340 ms. These sequential,
unmonitored samples are not a controlled speed comparison: the old policy omits
valid events on long days, and timing tails differ. This is a correctness fix,
not a claimed optimization. No new retained cache, eviction policy or baseline
change is introduced.

## App validation

Release + DEBUG iPhone 17 Pro and iPad Pro 13-inch (M5) / iOS 26.5 Simulator
runs each passed these three UI tests, with zero failures/skips:

- `testCachedVariedNativeDayScroll`: opt-in layout preparation, 3,000 retained
  events, 12 calendars, scrolling, exact event detail identity and next-day content.
- `testPreparedDenseCalendarScroll`: opt-in prepared Week layout and scrolling.
- `testNativeDayPagingAndZoom`: default native Day behavior after the shared change.

These fixtures use the current date, not a DST transition. The extracted initializer
checks supply the DST failure/correction evidence. UI gesture wall time includes
automation and is not a frame/input measurement. The full eight-case component
gate passed against unchanged baseline version 1. That standard suite uses the
default policy, so it does not establish the cached layout's rendering performance.
All 38 Python regression-harness checks also passed.

The Mac Release + DEBUG app compiled and linked successfully after the Simulator
measurements finished. It was not launched; this supplies no native Mac UI timing.

Raw logs, six-test result bundles and build/source identity remain in
`.build/calendar-snapshot-boundary-20261010/`. Summaries and the component gate are
retained beside this report. Source hashes stayed unchanged through verification;
the gate's rebuild changed the executable hash, so the iPhone and iPad phases are
not claimed to use a bit-identical executable. Both identities are retained.
Both owned test Simulators were shut down; 14 isolated
temporary app fixtures (2.079 GiB logical) were removed. Reports, previous failure
databases and worktrees were preserved.

Physical 120 Hz frame and input-to-visible acceptance remain unmeasured. The broader
[integration status](../../calendar-integration-status.md) separates enabled paths
from remaining work; this repair does not complete the renderer integration.
