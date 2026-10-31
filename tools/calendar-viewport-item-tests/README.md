# Calendar viewport descriptors

Run `python3 tools/calendar-viewport-item-tests/run.py --out NEW_DIRECTORY` on Mac.
The runner extracts the real viewport descriptor definitions, compiles them with
SwiftUI, and preserves sources, compiler output and the result. It avoids the app's
service graph and UIKit. Calendar-core CI runs the same check.

Checks cover distinct overnight cell identities, preservation of move callbacks
and interaction flags, whole/partial/outside column geometry, and deferred artwork
construction. These are component correctness checks; they do not prove pixel
parity, cell recycling, app scrolling speed or physical frame/input performance.
Real-app Week checks use `ScaleStressUITests.testNativeWeekCalendarScroll` with no renderer opt-in flag and the unchanged stress workload.
The DEBUG `--calendar-reference-week` flag preserves the comparison host.
