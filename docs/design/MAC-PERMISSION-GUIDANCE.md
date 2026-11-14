# Mac permission guidance

## What Rex does

Inspected Rex Beta 0.1.0 (1973), using a supplied recording plus the installed
bundle's Objective-C/Swift metadata, string table, imported APIs and relevant
ARM64 disassembly. The recording and extracted evidence stay private; no Rex
assets or implementation source are included in Banana.

Rex's permission flow is composed of separate native pieces:

| Piece | Evidence | Behavior |
| --- | --- | --- |
| Permission window | `RexPermissions.PanelController`, `Panel: NSPanel` | A separate permissions panel rather than resizing the terminal |
| Settings follower | `SystemSettingsWindow`, `SystemSettingsSidecar` | Finds System Settings with window-server metadata; sidecar state includes search/follow timers, a display link, a background read queue, screen-change handling and a remembered follower origin |
| Real draggable icon | `DraggableAppIcon.IconView: NSImageView`, `NSDraggingSource` callbacks | Bridges an app URL to `NSURL`, constructs `NSDraggingItem`, and starts a native drag session |
| Demonstration | `GhostDrag`, `Flight`, `OverlayPanel: NSPanel` | A separate visual flight, with start/control/end points, icon, icon size and playback state; the single control point suggests a quadratic curve |
| Drop guidance | `DropGuide`, `SpotlightPanel` | Tracking, screen-cover panels, dim/rim/caption layers and haptic state |
| Grant detection | `server.apple.privacy_status`, server bundle URL/responsible-app state | Checks the permission held by the server process; the animation itself grants nothing |

The dragged URL is important: Rex explains that the ordinary Settings **+** button
can add the client instead of **Rex Server**. The real drag supplies the server app
bundle. The ghost flight teaches that gesture; the user still performs the drag
and any system authentication. Exact animation timing and every positioning
heuristic have not been recovered.

These pieces correspond to public AppKit capabilities: [native drag sessions](https://developer.apple.com/documentation/appkit/nsview/begindraggingsession(with:event:source:)),
[drag item frames](https://developer.apple.com/documentation/appkit/nsdraggingitem/setdraggingframe(_:contents:)),
[window frame positioning](https://developer.apple.com/documentation/appkit/nswindow/setframe(_:display:animate:)),
and [window-server metadata](https://developer.apple.com/documentation/coregraphics/cgwindowlistcopywindowinfo(_:_:)).
AppKit supplies the window, controls, animation and display scheduling directly.
The app-specific work is geometry, permission routing and lifecycle coordination;
no third-party rendering or automation layer is needed.

## Banana's adaptation

Banana's existing permissions use system prompts, switches and access selectors.
They do not require dragging an app into Full Disk Access. First-run completion
therefore offers an optional **Permissions** panel. Existing **Open Settings**
actions for Reminders, Location, Notifications, Apple Music and Photos open the
same guide at the relevant permission.

The panel offers the native request only when it has never been asked, opens
Settings after a denial, and reports restricted access without pretending another
request will fix it. Opening the panel itself never requests permission. It reads
actual authorization status; a local animated switch/access-menu illustration
is decorative and cannot change the displayed grant state. Reduce Motion shows
a static illustration.

The guide positions only its own window. Settings window bounds are read off the
main actor, with one read in flight, cached window IDs, and bounded discovery.
A screen display link follows movement without invalidating SwiftUI's status
rows. Pointer-button state and elapsed input times select frame-cadence reads
during interaction; quiet window reads are capped at four per second. The
controlled schedule check records 120 reads/second for the unthrottled control,
four for a quiet follower, and 120 during active input. This is query-count
evidence, not measured CPU savings or physical interaction acceptance. No screen images, Accessibility permission, Apple Events, or injected mouse
events are used. If metadata is unavailable or neither side fits, the panel leaves
Settings unobstructed; returning to Banana brings the guide back. Other foreground
apps hide the panel and pause following/animation. Closing it stops polling,
invalidates the display link, cancels follower reads, removes observers and invalidates
outstanding status updates.

The deep-link anchors were also checked against the installed macOS 27.2
Security & Privacy extension's English search-term metadata (including
`Privacy_Reminders`, `Privacy_Photos`, and `Privacy_Media`). Those routes are
system implementation details, so actual pane navigation remains a native
acceptance check on supported macOS releases.

Location remains in a checking state until its delegate supplies a real standing,
rather than interpreting the store's initial placeholder as permission to ask.

Permission reads are independent, so a slow notification daemon cannot hold up
Reminders. Unchanged status is not published. A stale read cannot overwrite the
result of a newer explicit permission request.

## Validation scope

`tools/mac-permission-guide-tests/run.py` checks actual model behavior, geometry,
secondary-screen conversion, narrow-screen fallback, status deduplication,
independent reads, stale-result rejection, and a windowless rendering. The check
runs in the persistent macOS component workflow. It does not verify actual System
Settings layout, permission prompts, visible following, keyboard/VoiceOver use or
physical frame/input timing. Those remain an idle-desktop acceptance run. The
shared persistent performance suite retains its own results and failures separately.
