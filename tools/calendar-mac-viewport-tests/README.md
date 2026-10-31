# AppKit Calendar viewport checks

`python3 tools/calendar-mac-viewport-tests/run.py --out NEW_DIRECTORY` compiles the
actual AppKit adapter and checks visible-region queries, active-item inclusion,
item lookup and empty replacement without opening a window. Reports retain source
hashes and compiler/runtime output. It does not time scrolling or verify AppKit
cell recycling, gestures, backgrounds, accessibility or integration with the app.
Those require the actual Mac Calendar and visible native UI checks.

The probe also mounts the actual coordinator without a window: 1,000 descriptors
must create content for a nonempty subset, and replacement with an empty snapshot
must clear visible items. The retained diagnostic initially instantiated 12 cells.
Off-window programmatic clip scrolling did not deliver the collection's visible
scroll lifecycle, even when explicitly requesting layout; those attempts are kept
under `.build/calendar-mac-integration-20261010/host-probe`. They do not demonstrate
successful scrolling or recycling, and the persistent check makes no such claim.
