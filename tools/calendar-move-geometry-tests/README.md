# Relative calendar move checks

Run the exact date arithmetic used by mobile and Mac drag commits, and the
optimistic end calculation used by mobile Day/Week:

```sh
swiftc -O Banana/Model/CalendarMoveGeometry.swift \
  tools/calendar-move-geometry-tests/main.swift -o .build/calendar-move-geometry
.build/calendar-move-geometry --out .build/calendar-move-geometry.json
```

`--reference` deliberately fails the continuation/no-op/duration assertions against
frozen pre-fix calculations. Both reports retain matched reference/relative timing
samples for ordinary moves; neither measures UI response or frame time. Horizontal
moves use Calendar day arithmetic; vertical movement retains the existing elapsed
minute rule. This does not certify wall-clock drag behavior across DST gaps.

`ScaleStressUITests.testNativeDayContinuationMove` independently drags an actual
24-hour event's next-day continuation, then checks the durable failure's destination
in the recovery sheet. It must move the start by one hour, not 25 hours. Calendar-core
CI runs the component checks; the real-app UI test needs the owned fixture Simulator.
