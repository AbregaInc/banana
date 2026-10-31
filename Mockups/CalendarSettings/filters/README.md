# Filter interaction prototype

Review: http://<review-host>:8898/filters/

Local: http://localhost:8898/filters/ (served by the existing calendar mockup server).

Type a sentence; chips and results update automatically. Edit a chip to update results immediately. “Meetings with Alex next week” demonstrates clarification. Module tabs preserve separate queries.

This uses sample data, a fixed October 21, 2026 clock and a limited demonstration parser. It is not connected to accounts or installed apps. Production design: `docs/design/TEXT-FILTERS.md`.

Run the small parser/result checks with `node Mockups/CalendarSettings/filters/checks.mjs` from the repo root. Browser checks cover live typing, ambiguous names, editing, module restoration and a 390 px viewport without horizontal overflow.

Native iPhone review: http://<review-host>:8898/filters/mobile/

Real SwiftUI captures from the isolated CalendarSettingsReview target. Launch with `--filters`, `--filters --filter-edit`, or `--filters --filter-results` to select a capture state. The native sample supports the displayed sentence and editable filters; it is not a production parser.
