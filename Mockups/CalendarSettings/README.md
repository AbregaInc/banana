# Calendar settings design review

Run `python3 -m http.server 8898 --bind 127.0.0.1 --directory Mockups/CalendarSettings` from the repository root, then open http://localhost:8898.

The review page compares two flows using real iOS SwiftUI captures:

- **A: Calendar details.** One colored row per calendar; open it for separate Show in Banana and Allow notifications switches. Family demonstrates visible events with alerts off.
- **B: Quick selection.** Switch between visibility and notifications, then select calendars with native checkmarks.

This is sample data, isolated from Banana and Google. The HTML navigates between captures; the Xcode project is the interactive native prototype. Generate with `xcodegen generate --spec Mockups/CalendarSettings/project.yml`, then run CalendarSettingsReview in an existing iPhone simulator. Launch arguments `--detail`, `--quick`, and `--quick --notifications` select the captured states.

B was selected for production, titled Calendar visibility. Visibility and Notifications remain separate controls.
