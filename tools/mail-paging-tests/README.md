# Persistent Mail paging checks

On the dedicated Simulator host:

```sh
python3 tools/mail-paging-tests/run.py --device SIMULATOR_UUID --out .build/mail-paging/NEW_RUN
```

Builds Release + DEBUG fixtures, runs all Mail session/list-model/paging tests and
the real-screen scroll/open checks. Requires the session growth/handoff cases, the
continuous-scrolling cases (a whole mailbox and a whole search walked by scrolling
in a bounded window, the edge asked ahead of the screen with Retry after a failure,
a held J/K across window edges) and the UI cases to pass, with zero failures, skips
or runtime warnings, on the requested Simulator. The exact older message is beyond
the initial 100-row page; the two scrolling UI cases use `--mail-window-rows 100`
so a few flings cross several slides of the window.
The nightly/manual dedicated performance workflow runs this after the unchanged
component suite, even if that suite fails, and retains both sets of artifacts.
It does not open/focus Simulator or launch native Mac windows.

Use `--verify-results UNIT.xcresult UI.xcresult` to validate retained results
without rebuilding or launching. Results from multiple bundles retain their paths;
this mode does not establish that the bundles used an identical app build.
The gate's failure handling is covered by `tools/tests/test_mail_paging_gate.py`.

This is correctness coverage, not an input-latency or 120 Hz gate. Keep physical
frame/input measurements separate. The app still needs bounded history beyond
2,000 rows, production account integration, and Mac/iPad interaction acceptance.
