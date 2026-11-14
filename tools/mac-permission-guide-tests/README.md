# Mac permission guide checks

`python3 tools/mac-permission-guide-tests/run.py --out NEW_DIRECTORY` compiles the
actual guide and checks adjacent placement, small-screen fallback, secondary
screens, coordinate conversion, permission action routing, and deduplicated status
publication. It renders the actual view without opening a window or System Settings.

Build and run results and source hashes are retained. These checks do not establish
visible window following, system permission prompts, keyboard/accessibility
interaction, or physical frame/input performance. Run those on an idle test desktop.
