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

Background geometry checks cover both scrollbar styles, clip scrolling and a
windowless resize. A controlled narrower background host reproduces the native
host/descriptor width mismatch: background chrome must retain the descriptor
width and leading origin. This proves the coordinate invariant under that
proposal; it does not reproduce AppKit's visible-window scrollbar lifecycle.

## Scroll query comparison

Run `python3 tools/calendar-mac-viewport-tests/queries/run.py --out /tmp/calendar-queries` with a fresh output path. The runner uses the current production descriptor types and value-frame query, native layout attributes, 24 moving viewports, and zero through 10,000 descriptors on AppKit and the stock iPad Simulator. Each trial verifies object identity and paint order against native frame lookup, including an offscreen pinned cell. It records wall time, fixed-work CPU time, and storage for the alternative frame array. This isolates lookup cost within a layout pass.
