# Pi sample workspace

Pi development builds open a labeled, fictional sample workspace by default. The normal data directory (`Banana Pi`) is preserved; sample work uses `Banana Pi Samples`. Assistant options → Sample data switches workspaces after reopening. Verification and UI-test runs retain their existing isolated directories.

The sample graph includes calendar events and tasks, routines, a recorded workout and guided workout plan, imported health workouts, 730 days of health/sleep trends, 90 days of meal history, supplements, notes, podcasts, listening history, and weather. The graph is seeded after asynchronous local stores load. Opening chat no longer inserts meals into personal history.

These are development fixtures: the banner states that they reset on reopening. Calendar fixtures do not create external calendar events or real scheduled alerts. Catalogue fixtures test browsing/layout; they do not provide downloaded episode audio. Test actual integrations separately with connected accounts/devices.

Run the installed app executable with `--pi-sample-check -assistant.sampleWorkspace YES --ui-preview --disable-icloud` for a bounded smoke check of all populated categories; it prints counts and exits. This check uses `Banana Pi Sample Verification`. Real-model event checks run through `tools/pi-mac-inference/run-app.py APP --workspace`; they cover a time-only dinner request plus fixed-clock morning/evening and explicit-date cases.

Calendar grids read the sample occurrence snapshot through the shared planning-window API, ignoring provider caches in sample mode. The smoke check inserts an empty cached day and verifies that today’s and tomorrow’s meetings remain visible before and after refresh/recompute. Fixture publication also increments the planning-window revision after installing the snapshot, so an already-mounted grid rebuilds.

Travel fixtures include a JFK–LHR flight three days ahead and a return flight, with absolute instants and distinct source IANA zones. They also feed the calendar’s secondary-timezone column. The native checks cover provider import, serialization, differing US/UK DST schedules, a repeated US clock hour, all-day labels, and overnight-flight inclusion on the arrival day. The Assistant displays daily results as native agenda rows with labeled timezone and flight endpoints.
