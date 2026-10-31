# Calendar day snapshot boundaries

Run `python3 tools/calendar-day-snapshot-tests/run.py --out NEW_DIRECTORY`.
The runner compiles the actual `WeekView.DayData` initializer and
`CalendarLaneAllocator` with a minimal occurrence adapter. It retains the extracted
source, compiler command/output and all timing samples. This verifies the opt-in
snapshot preparation without constructing the app's service graph.

Fifteen checks cover UTC, New York's 23/25-hour days, Lord Howe's 23.5/24.5-hour
days, carry-in, exact midnight exclusion, the last quarter hour, untimed/block
filtering, the separate Agenda policy and replacement of immutable snapshot data.
Timing samples include fresh preparation at 100/1,000 events; they exclude real
Occurrence adaptation, views, gestures and presentation. No UI speed claim follows.
Use `--source PATH_TO_OLD_WEEKVIEW` to preserve a before-fix failure.

The full-app counterpart is
`ScaleStressUITests.testCachedVariedNativeDayScroll`, plus the existing
`testPreparedDenseCalendarScroll` for Week. These verify scrolling, event details
and paging on the prepared path; their current fixture date is not a DST transition.
Physical 120 Hz and input-to-visible performance remain separate acceptance work.
