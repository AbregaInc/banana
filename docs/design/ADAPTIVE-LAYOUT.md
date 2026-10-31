# One app, every screen size

How Banana runs on an iPhone, an iPad, a foldable phone, the Mac and the Watch from one codebase
without a custom build of every screen for every device. Decided September 2026, when the iPad
build started.

## The rules

1. **Layout follows room, not device.** A screen asks how wide it is (`LayoutClass`), never which
   device it's on. An iPad in a third of the screen, a folded phone and an iPhone all get the
   compact arrangement; a full iPad, an unfolded phone and a Mac window get the regular one. A
   layout that asks "am I on an iPad?" breaks the first time the iPad is split, and every new
   device shape would need another branch.
2. **Two arrangements at most.** `LayoutClass` has two values, split at 600 pt: `compact` (one
   column, phone-shaped) and `regular` (sidebar, tables, side-by-side). A feature has at most one
   view per arrangement, and most need only one view that adapts (see *Views*). No third
   "iPad" layout.
3. **Measure the column, not the window.** Each section measures its own content
   (`.measuresLayoutClass()`), so a section beside an iPad sidebar, or in a split, lays itself
   out for the room it actually has.
4. **What a device is for is separate from how it's laid out.** `DeviceRole` says which device
   is the hub: the iPhone, which reads and publishes Apple Health, writes workouts, talks to the
   Watch, rings alarms and writes the calendar holds. The iPad and the Mac work from what the
   phone syncs. `#if os(iOS)` must never stand in for "the iPhone" — on an iPad it's true too, and
   the iPad would become a second hub publishing the same records.
5. **Every control is everywhere, and synced.** A setting is one value, synced across devices,
   with the same control on the iPhone, the iPad and the Mac — change it anywhere, it changes
   everywhere. Only the *doing* is the hub's (arming alarms, writing calendar holds, learning
   trips, reading Health): the phone acts on the synced value, and publishes how it went
   (armed, permission missing) so every device's control can show it. A control is never
   hidden or made read-only because a device isn't the hub. The only per-device things are the
   device's own: its audio output, its notification permission, its downloads.
6. **`#if os(...)` is for what the OS can do, never for layout.** HealthKit, WatchConnectivity,
   AlarmKit, AppKit/UIKit bridges, menu-bar commands. If a view is fenced to one platform only
   because of how it's laid out, the fence is wrong.
7. **State lives outside the view tree** (`ShellNavigation`), so rotating an iPad, unfolding a
   phone or resizing a window — which swaps a section's arrangement — doesn't lose where you were.

## The pieces

| Piece | What it is |
|---|---|
| `LayoutClass` (`Banana/Views/AdaptiveLayout.swift`) | `compact` / `regular` from a width; `EnvironmentValues.layoutClass`; `.measuresLayoutClass()`. |
| `DeviceRole` (`Banana/Model/DeviceRole.swift`) | `phone` / `pad` / `mac`; `isHub`; `name` for copy ("stays on this iPad"). |
| `AppSection` | The app's sections — one list for the phone tab bar, the iPad sidebar and the Mac sidebar. |
| The shell (`RootView.mainTabs`) | One `TabView`, `.sidebarAdaptable`: a tab bar when narrow, a sidebar with every section when there's room. Phone tabs: Plan, Workouts, Nutrition, Notes, Library; Sleep, Trends, Routines and Settings are sidebar-only (reached from inside those tabs on a phone). |
| `DS` tokens (`Shared/BananaDesign.swift`) | Spacing, type, colour roles — the same on every device; never hard-coded per device. |

## Views: one per feature, adapting

Preferred: **one view whose parts rearrange by width**, like `TrendsView` (cards when narrow, a
table with every window when wide) or `SleepView` (one column, capped at a readable width). When
the two arrangements are genuinely different screens, a feature may have one view per
arrangement, chosen in exactly one place by `layoutClass`:

| Feature | Compact | Regular |
|---|---|---|
| Workouts | `FitnessView` | `WideWorkoutsView` (+ `WideWorkoutDetailView`) |
| Nutrition | `WellnessView` | `WideNutritionView` |
| Plan | `WeekView` (1 day, or 3/5/7 days by width) | same; the Mac still uses `MacWeekView` |
| Trends, Sleep | one adaptive view | same view |
| Notes | the list; a note is pushed | the list beside the open note |
| Library | a list of shows | a grid of shows |
| Routines | a list | the same list as a readable column (`.readableColumn()`) |
| Settings | a list; a page is pushed | pages beside their list, each a readable column |

A list or a form never stretches from edge to edge of a wide screen: `.readableColumn()` makes
it a column 720 pt wide in the middle (`LayoutClass.readableWidth`), and changes nothing on a
phone.

Names say the arrangement (`Wide…`), not the platform. The wide views were `Mac…` until they ran
on iPad; nothing in them was Mac-specific except a fence and two strings.

## Devices

- **iPhone:** compact; the hub.
- **iPad:** regular full-screen and in wide splits, compact in narrow ones and Slide Over — the
  shell and every section follow automatically. Not a hub: no Health publishing, no Watch, no
  alarms, no calendar writes.
- **Foldable / "iPhone Duo":** nothing special. Folded is compact, unfolded is regular; the
  transition is a width change, which the shell and sections already handle, with state kept in
  `ShellNavigation`.
- **Mac:** regular (compact in a narrow window, once the Mac shell moves onto the shared one).
  Still has its own shell (`MacRootView`) for now: menu-bar commands, the event inspector drawer,
  `MacWeekView`.
- **Watch:** its own interface on purpose — a wrist is not a narrow phone. It shares the models
  (`Shared/`) and the design tokens, not views.

## Checking a layout

- iPhone Simulator: the usual `--` routes.
- iPad Simulator: `--ui-preview --tab <section>` opens any section in the shell
  (`--dummy-health` for sample Health data).
- Mac: the snapshot harness (`--snapshot-app-store … --mac-section <section>`).
- UI tests read positions, not devices (e.g. `PinchZoomUITest`).

## Who does what (September 2026)

Only the phone (`DeviceRole.current.isHub`), because only it can or because the result is one
snapshot that can't yet be merged: reading Apple Health and publishing the Health cache
(`queueHealth`, `HealthKitStore.isAvailable`), seeding the synced settings on first launch,
computing and publishing the wake plan (others adopt it), arming alarms
(`AlarmStore.ensureAuthorized`), trip learning, the Watch session, the post-workout review, the
automatic iCloud backup (one shared file; not from an iPad).

Every device: calendar busy blocks — on/off and the task calendar are synced settings
(`writeBackEnabled`, `writeBackCalendarID`). No device owns a block: each carries Banana's marker
and its plan item, every device reconciles all of them to the same wanted set, duplicates resolve
to the same copy everywhere (`BusyBlockDuplicates`), and deleting one already gone counts as done.
Turned off anywhere, every device withdraws them. Reminders
(bedtime, leave-by, events, supplements) ring on every device.

Every device, synced as one small record each (`CloudControlsSync`, zone "Controls"): routines,
one-off alarms, what each audio slot plays (sleep, wake, workout), and each show's settings
(`PodcastSettings`: speed, order, downloads, Sync to Apple Watch, ad skipping, muted voices —
never episodes or progress). The newer edit wins; a delete is a dated tombstone, so it beats an
older edit anywhere. The phone offers its set once; an iPad or Mac never offers what it had
before it first synced, and takes the phone's set of routines, alarms and slots in place of its
own leftovers. An alarm added on an iPad or the Mac is armed by the phone when it next syncs
(there's no push, so: when Banana next opens there), and its row says whether it has been
(`HubStatus.armedAlarms`).

The phone's status (Health, alarms, notifications, Watch, backup) is published over the
key-value store (`HubStatus`) and shown in each device's Settings; buttons for the phone's jobs
(resend to Watch, back up now) send a request (`HubRequests`) the phone carries out.

Still open: a pending voice note may be transcribed by more than one device; iPad notes are
labelled "iPhone"; subscribing or unsubscribing a show doesn't sync.

## Next

1. Push for the sync zones (an `aps-environment` entitlement), so the phone arms an alarm added
   elsewhere without being opened first.
2. Put the Mac on the shared shell (`TabView` `.sidebarAdaptable` works on macOS), keeping its
   menu commands and inspector; then `MacRootView` goes.
3. Fold `MacWeekView` and `WeekView` into one calendar grid with the two arrangements.
4. Converge the compact/regular pairs where they've drifted into one adaptive view each.
