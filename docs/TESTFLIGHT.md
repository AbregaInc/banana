# TestFlight release

Banana's iPhone app contains an iPhone widget, a Watch app, and a Watch complication.
All four bundles must use the same marketing version and build number.

The Mac app ships to TestFlight too, under the SAME bundle id (`com.boris.banana`,
shared App Store record). Build and upload with `tools/mac-testflight.sh` — it
archives sandboxed (`BananaMacAppStore.entitlements`), cloud-signs with the API key,
and uploads. First Mac upload: `1.0 (6)` on July 24, 2026. In App Store Connect,
confirm the macOS platform appears on the Banana app and add the build to the beta
group; testers install via TestFlight for Mac. See docs/MAC-VARIANTS.md for the
sandbox/data-location caveats.

## Public beta

- Group: `Banana Public Beta`
- Public link: https://testflight.apple.com/join/47yxmU8U
- Current build: `1.0 (56)` — uploaded October 18, 2026 (iOS with iPad, Watch, and macOS), from
  `7965ece6`, both halves VALID, added to `Banana Public Beta` and submitted for Beta App Review
  the same day (`tools/asc-public-beta.py 56 … --apply`, texts in `tools/app-store/testflight/`).
  New: the Banana account and instant calendar updates through the Banana service
  (`api.bananatheapp.com`, docs/design/ACCOUNTS.md), Delete account after a fresh Google sign-in,
  modules (Settings › Modules), push on every app, Apple Weather's mark and legal link, privacy
  manifests declaring what the service receives. App Store Connect's privacy, support and
  marketing addresses now point at bananatheapp.com; the App Privacy answers are entered by hand.
- Previous build: `1.0 (54)` — uploaded October 9, 2026 (iOS with iPad, Watch, and macOS), from
  `7bb57d0`. Apple accepted both halves within ten minutes (`tools/asc-builds.py`: VALID). NOT
  yet assigned to the public beta group: see "What the public beta still needs" below, and
  `tools/asc-public-beta.py`, which does that step when it is decided. Since build 53:
  - **Reminders.** The circle ticks, the words open the reminder, and a tick has Undo (nothing is
    written to Reminders until the toast goes). A reminder can be answered from its notification.
  - **Calendar.** Guests can be added to and removed from an existing event; a trip's second
    time zone shows on every device; flights are recognised through every airport; the calendar
    is checked every 2 minutes in front, every 5 behind (25 in Low Power Mode), and a change is
    planned for once; the wake alarm moves earlier for a meeting that lands while Banana is closed.
  - **Workouts.** A trim or a revert made on any device changes the workout everywhere, Apple
    Health included; a Watch workout can be paused and resumed; deleting has Undo.
  - **Podcasts.** The Watch plays at the show's speed and has a speed button; a transcript can
    say who is speaking; listening history and the Listen Map open from the Library.
  - **Routines.** A routine can be started right now (button, Plan, Siri); the words say what
    each kind does.
  - **iPad.** Settings and Notes use the system's split view; Library, Routines and Settings use
    the room a wide screen has.
  - **Sync.** A change made on another device is fetched even when it was made while the app was
    closed, or when the first fetch failed; a Mac started with no window still syncs.
  - **Removed:** the List view (Plan is Day and Week), guided workout plans, the Today and
    Tomorrow screens with Re-plan and the assistant, the bedside clock on a sideways iPhone, and
    the workout flyover. The store copy, screenshots and `HANDOFF.md` still describe some of
    these: they are to be updated once the owner has approved the changes.
  - The sandboxed Mac build now has the Contacts entitlement (guest suggestions from Contacts
    were silently empty there).
- Previous build: `1.0 (53)` — uploaded October 6, 2026 (iOS with iPad, Watch, and macOS). NOT
  assigned to the public beta group. `1.0 (52)` exists for
  macOS only; Apple refused its iOS half. Everything since build 25, which is a great deal:
  - **Calendar is Google Calendar.** Banana reads and writes calendars only through Google's API;
    Apple Calendar is no longer read. Testers must connect a Google account (onboarding, or
    Settings) or the plan shows reminders and routines only. Events can be created, edited, moved,
    repeated, deleted and answered; an event can be typed the way it is said; all-day events show
    and a Busy one blocks its day; every calendar keeps its own colour. Cross-calendar busy blocks
    are **on by default** once an account is connected.
  - **iPad.** One adaptive app; the iPhone stays the hub.
  - **Nutrition.** Meals from a photo, a barcode, a sentence or a name search of the bundled USDA
    database; your own foods from scanned packages; any amount in the food's measures, grams or
    ounces; supplements and medication ("Taken") due on a schedule or around a moment; meals on any
    day; Nutrition on the Mac and iPad.
  - **Sleep and Trends** pages, on the phone and the Mac.
  - **Plan** is one switch (List · Day · Week); overdue reminders lead today's line in Day and
    Week; badges for overdue reminders, meals to log and doses due.
  - **Sync.** Library, history, routines, meals, supplements and settings sync between devices
    through iCloud without waiting for a push.
  - **Podcasts.** Three-zone player with Up next and the transcript inside it; written notes.
  - Fixes worth knowing: the Day grid no longer squeezes events left or loses a new blocker, a
    calendar read no longer holds the app for seconds, and Settings no longer crashes in an
    optimized build.
- Previous build: `1.0 (25)` — uploaded September 9, 2026 (iOS, Watch, and macOS). Calendar event
  notifications: Banana announces every event itself, at the start and five minutes before, with
  the lead times configurable in Settings. It deliberately does NOT inspect whether an event
  carries a calendar alarm — an alarm on the data says nothing about whether any app is permitted
  to show it, and an earlier version that guessed failed both ways (silent when Calendar was
  muted, doubled up on Google events fetched directly). Silencing another app's notifications is
  done in that app. Also: per-show ad skipping (Use default / Always / Never); an app-wide
  AccentColor, so menus, sheets and alerts stop falling back to the system blue; the app-switcher
  snapshot no longer shows a black rectangle; and new bookings snap to the hour or half hour from
  a click, tap or drag on both platforms.
- Previous build: `1.0 (21)` — uploaded September 7, 2026 (iOS and Watch). Fixes creating a calendar
  event on the week grid. Drag-to-create did not exist there at all, and the tap gesture that was
  there opened nothing, because on iOS 26 a SwiftUI gesture inside the grid's nested scroll views
  loses to the scroll view. That left the toolbar button as the only route, which opens at the next
  half hour, so every event needed its start time corrected by hand. The week grid now takes both
  gestures through a UIKit bridge (`CalendarCreateGesture`), the same approach the day view already
  used: tap to create at that time, or hold briefly and drag to set the duration. Measured opening
  at 1:40 PM and 7:35 PM from two different tap heights, snapped to five minutes.
  NOT yet assigned to the public beta group.
- Previous build: `1.0 (20)` — uploaded September 5, 2026 (iOS, Watch, and macOS). Automatic
  podcast ad skipping. Four detectors, each kept only because it measured no false positives on
  real subscriptions: the ad server's own declared byte ranges, MP3 encoder seams left by the
  stitcher, wording that recurs across a show's episodes, and host-read sponsor slots corroborated
  by a sponsor slate learned from earlier episodes. Where two detectors disagree the plan narrows
  and stops skipping silently rather than guessing. Works on a first streamed listen with no
  download and no transcript, because the ad server declares its slots in headers the app was
  already receiving and discarding. Steering always wins: scrubbing into a skipped stretch plays
  it, and rewinding straight back out of a skip retires that detector for that show. Off switch in
  Settings → Podcasts, on by default.
- Previous build: `1.0 (19)` — uploaded September 4, 2026 (iOS, Watch, and macOS). A large
  session: natural-language food entry on the on-device model, the supplement barcode cascade
  (bundled catalog, then Open Food Facts, then the NIH label database, then UPCitemdb) with
  label photography as a fallback, the swim hand-path cylinder and a rewritten motion section,
  five-minute calendar time entry, running cadence corrected from arm-swing to step rate, and
  data-safety work across every JSON store so one unreadable record can no longer wipe a file.
  Also fixes a workout-detail freeze: the stroke signature moved off Swift Charts 3D, which
  stalled the UI for roughly 12 s drawing 2,900 points, onto the Canvas renderer at 59 fps.
- Previous build: `1.0 (16)` — uploaded August 21, 2026 (iOS, Watch, and macOS). Adds
  seekable elapsed/total progress for voice-note recordings on iPhone and Mac.
- Previous: `1.0 (15)` — uploaded August 20, 2026 (iOS, Watch, and macOS). Includes
  activity-correct HealthKit workout persistence, formatted podcast episode notes, and the
  corrected Watch hold-to-start progress surface.
- Current build: `1.0 (9)` — uploaded July 29, 2026 (iOS + macOS). Adds the Watch
  inventory reconcile: the Watch now reports what it actually holds on activation, and
  the phone forgets any transfer the Watch can't confirm, so a wiped or reinstalled
  Watch re-syncs its episodes by itself instead of being skipped by backfill forever.
- Previous: `1.0 (8)` — uploaded July 29, 2026 (iOS + macOS). Travel times on
  Week and Tomorrow (the horizon was computed and then discarded), travel drawn as an
  occupied band on both week grids, rain in the departure nudge, five-minute task
  picker, calendar/reminders authorization fixes (a granted permission no longer reads
  as not connected), a Permissions section in Settings so no grant can strand you, the
  Flighty-standard onboarding pass (nothing gates the app, calendar leads), App Intents
  for Siri and Shortcuts, and a banana-shaped screenshot run out of Los Altos.
  **Install this one to recover a Watch app or Watch downloads** — a TestFlight build
  installs to the Watch from the Watch app on iPhone, which a development build cannot.
- Previous: `1.0 (7)` — uploaded July 26, 2026 (iOS + macOS). Automatic feed
  refresh + auto-downloads (launch, foreground, overnight charger BG task,
  pull-to-refresh), Watch sync escalation to file transfers + stalled-download
  watchdog, episode-list listened folds, configurable week start (synced, default
  Monday), archived-notes toggle (synced), Vimcal-style Mac event inspector, iOS week
  header sync + pinch zoom, settings search, three-tier settings sync.
- Previous: `1.0 (6)` — full-bleed icon crop fix (build 5's icon shipped as a
  tile-within-a-tile), custom-symbol complication, real-podcast screenshot fixtures.
  Prefer the newest build when assigning testers.

The link is already open to anyone without a tester limit, but Apple will not allow
new testers to join until the external build is approved.

## What the public beta still needs

Read from App Store Connect on October 9, 2026 (`tools/asc-builds.py`, and the beta groups and
build details through the same API key):

- `Banana Public Beta` has five testers and the public link is on, with no tester limit. Builds
  8, 9, 10, 19, 20 and 25 were added to the group and **never submitted to Beta App Review**. The
  only build Apple has approved for outside testers is iOS `1.0 (4)`, approved July 19, 2026,
  which expires on October 16, 2026 (90 days after its upload). After that the public link has
  nothing to install.
- No macOS build has ever been through Beta App Review: the first one gets a full review.
- To put a build in front of the public: add it to `Banana Public Beta` (iOS and macOS are
  separate builds), fill in "What to Test", and submit it for Beta App Review. A review usually
  takes about a day for the first build of a version.
- Test information: the description and the feedback address (support@abrega.com) are filled in;
  there is no privacy policy link and no marketing link. The review contact is filled in; the
  notes for the reviewer are empty. Say there that the app needs no account, and that the
  calendar needs a Google account the reviewer can skip.
- Google sign-in: the owner reported on October 9, 2026 that Google approved the OAuth consent
  screen. Until then only listed test users could connect a calendar.
- iCloud: the daily builds and TestFlight builds use the same Production CloudKit environment
  (`Banana.entitlements`), so the record types testers need are already deployed there.

## Status of builds 52 and 53

`1.0 (53)` was uploaded on October 6, 2026 from `beb3c5f`, for iOS (with the iPad, the Watch app
and both widgets) and macOS. It is build 52 plus two purpose strings in the iPhone app's
Info.plist.

Still to do in App Store Connect: add both builds to `Banana Public Beta` when they should reach
the public (that is a separate step and, for outside testers, a Beta App Review). Before doing
so, settle the Google sign-in: with the OAuth consent screen in Testing, only listed test users
can connect a calendar, and calendars are Google-only from this build on.

What the release ran into, for next time:

- **A pending agreement refuses everything.** The first upload of 52 failed with
  `403 FORBIDDEN.REQUIRED_AGREEMENTS_MISSING_OR_EXPIRED`, as did every other request made with the
  API key, until the Account Holder accepted the agreement at appstoreconnect.apple.com
  (Business). The key worked again about four minutes later, and the archives already built were
  exported and uploaded without a rebuild (`xcodebuild -exportArchive -archivePath … -exportPath …
  -exportOptionsPlist TestFlightExportOptions.plist -allowProvisioningUpdates` with the key).
  `python3 tools/asc-builds.py` shows the refusal in a second, before a twenty-minute archive.
- **"Upload succeeded" is not "Apple kept it".** Build 52's iOS upload succeeded and was then
  turned away in processing (ITMS-90683): the iPhone app calls `CMMotionActivityManager` and asks
  for Always location, for "Learn from my trips", and declared neither `NSMotionUsageDescription`
  nor `NSLocationAlwaysAndWhenInUseUsageDescription`. An upload refused this way never becomes a
  build, so it simply fails to appear. `tools/asc-builds.py` prints what became of the latest
  uploads, with Apple's reasons. `PurposeStringTests` now checks that every protected API the
  sources call has its key in `project.yml`. The Mac half of 52 was accepted, which is why a
  macOS-only `1.0 (52)` exists.
- **The Mac archive is universal.** `generic/platform=macOS` builds arm64 and x86_64, unlike the
  local installs. A vendored library with no Intel slice (Needle, for the speech lab) compiled and
  then failed to link, with `Undefined symbols for architecture x86_64`. Fence such code with
  `arch(arm64)` as `SpeechLabEngines.swift` does. `tools/mac-testflight.sh` archives with `-quiet`,
  which hides the linker's reason: rerun the archive without it to see.

## One-time Xcode setup

1. Open Xcode → Settings → Accounts.
2. Add an Apple ID that belongs to the development team (`DEVELOPMENT_TEAM` in Config/Local.xcconfig) and can manage signing assets.
3. Open `Banana.xcodeproj`, select each of these targets, and confirm that
   **Automatically manage signing** resolves without an error:
   - `Banana`
   - `BananaWidgetExtension`
   - `BananaWatch`
   - `BananaWatchWidget`

The project currently has no App Store Connect account available to command-line Xcode.
Use the existing `Banana TestFlight` App Store Connect API key with Xcode's
`-authenticationKeyPath`, `-authenticationKeyID`, and `-authenticationKeyIssuerID` options, or
add the account in Xcode. The API key is also sufficient for automatic profile regeneration.

Banana's App ID is assigned both `iCloud.com.boris.banana` and the legacy
app's iCloud container. Keep both on the iOS target until the Quarters → Banana
migration window is over. The app reads the richest valid backup from either container, then writes
the restored data into Banana's container.

## Prepare a build

`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` live in `project.yml`. Every upload
must use a `CURRENT_PROJECT_VERSION` higher than the previous upload.

The generated Info plists reference those build settings, so this remains safe:

```sh
xcodegen generate
```

`project.yml` is currently at version `1.0 (56)`.

The working CLI path: archive, then export with `TestFlightExportOptions.plist`
(`destination: upload` uploads during export) authenticating with the
`Banana TestFlight` API key `AuthKey_<key id>.p8`
(`-authenticationKeyID <key id>`,
`-authenticationKeyIssuerID <issuer id>`).
The other local key (`5WTYV6375B`, used for lfc notarization) authenticates but
lacks cloud-signing permission and fails export with
"No signing certificate iOS Distribution found".

## Archive

```sh
xcodebuild \
  -project Banana.xcodeproj \
  -scheme Banana \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath /tmp/Banana-1.0-4.xcarchive \
  -allowProvisioningUpdates \
  archive
```

The `Banana` archive includes the Watch app and both widget extensions. Do not archive
the Watch or widget scheme separately for TestFlight.

Never pass `BANANA_UNRELEASED=YES` to an archive. Unreleased modules (Mail first) are built only
into Debug and the author's own installs, so nothing Apple receives has a feature review can't
see. Check every archive before exporting it; `tools/mac-testflight.sh` does this for the Mac:

```sh
tools/check-release.sh /tmp/Banana-1.0-4.xcarchive
```

## Export an upload-ready IPA

```sh
xcodebuild \
  -exportArchive \
  -archivePath /tmp/Banana-1.0-4.xcarchive \
  -exportPath /tmp/Banana-TestFlight-1.0-4 \
  -exportOptionsPlist TestFlightExportOptions.plist \
  -allowProvisioningUpdates
```

Upload the resulting IPA with Transporter, or open Xcode → Window → Organizer, select
the archive, and choose **Distribute App → App Store Connect → Upload**.

## App Store Connect

Before inviting testers:

1. Complete export-compliance questions. `ITSAppUsesNonExemptEncryption` is `false`.
2. Complete the app privacy questionnaire based on Banana's actual server/iCloud data
   practices. The bundled privacy manifests cover required-reason API declarations but
   do not replace the App Store Connect questionnaire.
3. Add internal testers after build processing completes.

## Verify build 5

The complication mark is now a custom SF Symbol (`BananaMark.symbolset`) — the only
content type that reliably renders on the live face; rasters over ~120px and opaque
PNGs draw as a grey disc. The kind is `BananaLaunch.v8`; it must be bumped whenever
the archived complication view changes, because faces cache one render per kind.

1. Install build 5 from TestFlight on the iPhone. Delete any old Daypart/Quarters
   watch app first — stale installs leave dead entries in the complication picker.
2. Confirm the Watch app installs; use the Watch app on iPhone if automatic installation
   is disabled.
3. Remove the old Banana complication from the face and add Banana again. The old
   entry is bound to a dead kind and will stay blank forever if left in place.
4. Exit face-edit mode and verify that the icon remains visible on the live face.
5. Open Banana on the Watch once. The complication also requests a fresh timeline every
   hour, so a stale render can recover without another app release.

The complication logs use subsystem
`com.boris.banana.watchkitapp.watchface` and category `timeline`; `snapshot requested`
identifies edit/gallery rendering, while `live timeline requested` proves the watch face
requested the real timeline.
