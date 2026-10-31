# Banana design system

The source of truth is `Shared/BananaDesign.swift` (`DS`). This page says how to use it.
Rule zero: **views name roles, never numbers.** If a value you need is missing, add a role to
`DS` — don't write the number inline.

## The standard (16 Oct 2026)
The author approved a direction from guiding images (https://claude.ai/artifact/FYgD2Ft6qsDnhsALKp1567,
round 4): Apple's current look, Liquid Glass as iOS 27 and macOS 27 ship it, and "as many out of
the box UI components as possible so we auto update as apple changes things and so that we are
integrated into things like user set glass transparency". Every page, including the ones the
images didn't show, meets it:

1. **Glass is the system's and only on navigation.** Toolbars, the tab bar, the sidebar, sheets
   and their buttons come from SwiftUI (`.toolbar`, `TabView`, `NavigationSplitView`, `.sheet`),
   so their glass, and the person's transparency setting, are the OS's. No custom bar
   backgrounds, materials or glass drawn by hand. Content never wears glass: lists, cards, tiles
   and rows are solid, on the grouped background.
2. **No coloured stripes.** No spine, left border or bar of colour on anything: event blocks,
   macro tiles, notes, workouts, Review, the clash card. Identity colour is a small tinted icon
   tile, a dot, or (event blocks only) the block's own soft fill.
3. **Density stays.** Nothing goes in a card or a taller row just to look tidy. Plan's all-day
   items and reminders belong to the calendar: on its white, not on the header.
4. **Real thumbnails.** A workout with a route shows the route; a meal with a photo shows it.
5. **The Mac has one toolbar.** Every page in the main window: back, forward and Today, then the
   title with its day or period (pages that show a time); the page's switch in the middle;
   search, + and … at the right. Pages without dates keep the same places. Settings is its own
   window (⌘,), a `Settings` scene with its sections as toolbar icons.
6. **Judge at real size.** A design is right only at a real phone width and a real window size.


## Spacing — `DS.Space`
A 4-pt scale: `hair 2 · xs 4 · s 8 · m 12 · l 16 · xl 24 · xxl 32`. Panel and sheet content
insets are `l`; rows inside a panel are 32–36 pt tall; the planner header is 44 pt.

## Radii — `DS.Radius` (always `.continuous`)
`block 5` event blocks and grid chips · `chip 6` tags, key caps · `control 8` buttons, fields,
list selection · `card 12` cards, toasts · `panel 16` palettes, sheets. A shape nested inside
another steps down one size so the curves stay concentric.

## Type — `DS.Typeface`
Grid and chrome sizes are fixed (they sit on a time ruler): `periodTitle 17 semibold`,
`dayHeader 12`, `gutter 10 medium, monospaced digits`, `eventTitle 11 semibold`,
`eventMeta 10`, `eyebrow 10 semibold + 0.6 tracking, UPPERCASE`, `keyCap 11 medium`.
Elsewhere use the system text styles. SF Pro everywhere on the calendar; SF Rounded is reserved
for large numerals.

## Colour — `DS.Palette`, `DS.Tint`, `CalendarColor`
- **Accent** (`accent`, the system's: the Mac's chosen accent, blue on a phone or iPad): Banana itself — today, now, primary
  actions, selection marks. Never used for "unknown".
- **Roles:** `success` (done, accepted, connected) · `danger` (delete, declined, failed, overdue)
  · `warning` · `info` · `task` (reminders) · `travel` (leave-by, travel legs).
- **Neutrals:** `separator`, `gridHour`, `gridHalfHour`, `selection`, `todayWash`.
- **Tints** — the only opacities for a wash of a colour: `wash 0.04 · subtle 0.08 · soft 0.14 ·
  fill 0.2 · strong 0.35`.
- **Calendar colours** go through `calendarTint(hex)` → `CalendarColor`: hue kept, saturation
  and brightness pulled into one band per appearance, so mixed calendars read as one surface.
  No colour → neutral grey.

- **Brand** (`Palette.Brand`): yellow, orange, coral, green, purple, blue, ink, ivory, from the
  brand board and the website. For the product's four areas (Plan yellow, Listen blue, Food
  purple, Move green) and for Banana introducing itself. Never a status, never text on a plain
  background.
- **On the accent** (`onAccent`): a label or glyph on the accent is white, as on the system's
  prominent button.

## Time — `TimeRangeText`
"9–10:30 AM", "11:30 AM–12:15 PM", "9 AM"; 24-hour locales "09:00–10:30". Every time shown on
the calendar, inspector, menu bar and widgets goes through it.

## Event blocks
No spine (the standard, 2): the block's fill says its calendar, `Tint.fill`
(`quietFill` for free / unanswered), title `eventTitle`, time `eventMeta` in compact form.
Blocks shorter than 34 pt are one line: title, then start time. The kind icon is shown per
**column** (≥ 132 pt), never per block. A block never extends into the next one in its lane.
States: tentative = stripes, unanswered = outline, everyone else declined = warning mark,
free = dashed.

## Sections and casing
- Section headers sit **outside** cards, sentence case, `.headline` in secondary (the native
  grouped-list style). UPPERCASE is only the `eyebrow`: panel section labels and grid chrome.
  Never both styles on one screen.
- A card is `Radius.card`, inset `Space.l`, at most 3 rows, then a footer link ("All ›").

## Rows — `DS.Row`, `IconTile`
Every row is at least 44 pt. The leading element decides the kind of row:
- **Settings / feature row:** `IconTile` (28 pt, solid) · title · trailing *current value*
  ("Transit", "Off", "3 accounts") · chevron, or ↗ for an external link. Non-obvious toggles get a
  footnote.
- **Record row** (workout, meal, dose): `IconTile(style: .soft)` at 40 pt · title · meta line
  ("Tue 07:50 · Place") · one trailing `StatValue(size: .row)`.
- **Media row** (episode): date line · title (2 lines) · description (2 lines) · footer with the
  *progress capsule* (▶ + inline bar + time left), a quiet download glyph, ⋯. Artwork follows
  `DS.artworkRadius` tiers with a hairline.
- **Account card:** 32-pt avatar · email · role tag · `StatusDot` + word · per-service toggles ·
  ••• (Resync, Remove). Removal is last, in `danger`, with a caption saying what it removes.
- **Identity colour** (a calendar, a macro, a workout type) is a small tinted `IconTile` or a dot
  — never a stripe, never the colour of the text.

## Numbers — `StatValue`
One shape for every figure: label above (caption, sentence case) · value in tabular digits ·
unit at ~0.58× in secondary on the value's baseline · optional `footnote` for the comparison (a
goal "of 2,041", an average, a change). Sizes: `row`, `tile`, `hero` (hero alone uses SF
Rounded). No colour on the number itself. Unknown or not applicable → `DS.placeholder` ("—"),
never "0" and never a gap; a metric that can't apply to this record (pace on a strength
session) is hidden, not dashed.

## Status — `StatusDot`, `ConnectionStatus`
An 8-pt dot plus a word; the word carries the meaning. `ok` = success ("Live", "Allowed"),
`working` = accent ("Syncing"), `attention` = danger ("Sign in again", "Off – Fix"), `off` =
secondary.

## Goals
A goal has a direction: *at least*, *at most*, or a *range*. The target is a tick or a band at
`Tint.subtle`. `danger` appears only when a limit is exceeded — never for beating a target
you want to exceed.

## Charts
No vertical grid; 2–3 horizontal hairlines at `Tint.subtle`; min/max labelled on the right
only; 3–4 x-axis labels; a dashed, labelled average; a pill for the scrubbed value. Series
colours name a metric (heart rate, pace), not a judgement. Effort and heart-rate zones share
one 5-stop ramp, blue → cyan → green → yellow → red, across charts, routes and bars.

## Confirming and undoing — `ToastCenter`
Anything recoverable happens at once and confirms with a toast; "Are you sure?" is only for
what can't be undone. A toast is one line (two at most), at most **one** action (Undo wins over
View), and a ×. Removals are *deferred*: the item hides (`hiddenIDs`) and the removal is sent
when the toast closes, the app backgrounds, or the next change is made. Every tab and the Mac
content pane already host it (`toastHost()`); features only call `ToastCenter.shared`.
**Deletes** (`DeleteUndo`): the action is "Delete", it happens at once, and the toast reads
"Deleted <name>" with Undo. A store that can put the thing back exactly does (`Removed`: same
id, same place); what can't be rebuilt (a note's recording, a show's downloads) is hidden and
removed when the toast closes. A sheet that deletes hosts its own toast.

## Loading and empty
Layouts never jump when data arrives: fixed-size placeholders ("—"), and skeletons with the
result's own geometry for anything slower (photo analysis, a first sync). Background work shows
as a card in place, not a blocking spinner. An empty state is one line, one hint, one action.

## Pages that ask for one thing — `OnePage`
The first run, a permission's explanation, the confirmation after a sign-in. One reading column
(`DS.Page.readingWidth`, 520 pt, centred on anything wider), content that scrolls so the largest
text fits, and the actions pinned to the bottom: **one** main button, a full-width capsule
(`.primaryCapsule`, 52 pt, ink on the accent), with the quiet choice as centred words under it
(`.quiet`, on a 44-pt target). Back is a chevron at the top. No page dots, no corner text.
Parts: `BrandMark`, `ReasonCard` (two or three reasons as one card, never a box each),
`GoogleButton` (Google's own mark on a white capsule).
**Less is more.** A page is its picture, a title, the reasons and the buttons. No paragraph
under the title, no small print under the card or the button, no grey sentence under a row's
name. A reason is a few words that fit one line on a phone. If a sentence only reassures
("Nothing is required", "Change this whenever you like"), it goes.
Every symbol on these pages sits on a solid `IconTile`, the tile a Settings row has: 28 pt
beside a reason, 40 pt beside a row with a headline, 64 pt (`DS.Page.heroTile`) to open a
page. A filled symbol, white; ink (`glyph:`) only on the brand's yellow and on the accent,
where the page's main button is ink on the accent too. Never a bare outline in the accent:
three of those in a column are thin, one colour, and easy to pass over.

## First run — `OnboardingView`, `OnboardingFlow`
The same on a phone, an iPad and a Mac, and **one path** for everyone: a welcome (the mark, the
headline, what Banana does as four lines of a few words, one button), then two questions that
build a day in front of the person ("When do you wake up?", "When do you wind down?"), then the
calendar, shown by what Banana does between two of them (`BusyBeforeAfter`: a meeting on Work
leaves that hour "Looks free" on Personal before, "Busy" after), then the other calendar (the
account that is in, ticked, and a dashed row for "Work or personal"), then the app on the plan.
Nothing to choose between on the way. Nothing is required on any device, and no screen exists only to say it is
over.

Changed 17 Oct 2026: the welcome asks "What should Banana look after?" instead of listing the
four areas. Plan is always on (a fixed tick); Workouts and sleep, Food, Notes and Podcasts are
rows to tick, and a last "Everything" row ticks them all. It starts at Plan alone, since the
calendar is the way in; the author, an integrator, picks Everything. Still one path: the choice
only decides what is shown. Settings › Modules changes it later, and off only hides.

What the flow is built on (research of 9 Oct 2026: published results, 43 flows read on Mobbin):
1. **Count the outcome first.** The measure is daily active users, with a connected calendar
   as the least that counts as activated. A flow can win the next tap and change nothing.
2. **The connection is the onboarding.** Google Calendar is the one step that makes the plan
   work; the first run leads to it.
3. **One step between the sign-in and the person's own day, and only this one: the other
   calendar.** Busy blocks between work and personal are the reason to connect at all (the author,
   10 Oct 2026), and they need two accounts. With two in, that step's button ("Block busy
   time") is the yes; with one, the plan's card asks later. Nothing is written to a calendar
   until there is a yes (`WriteBackStart`). This costs a screen where the research says people
   are lost; count it.
4. **Ask only what changes the next screen, and show it changing.** Each of the two questions
   moves a block on the day above it (`DayDraft`) and is a starter routine's time when the app
   opens (`DayAnchors`). A question whose answer the person cannot see on the plan is not asked.
5. **Ask for a permission when its reason is on screen** (see Permissions).
6. **Steps that matter go in the flow; the rest lives in the product.**
7. **The first screen is never silently blank.**
8. **Cut what only explains or decorates.** No tour, no carousel, no progress bar.

A page's big title is centred (`pageTitle()`), as is the mark or tile above it; lists and cards
under it stay left-aligned.

## Permissions — `SetupChecklist`, `SetupSheet`, `SetupPrimerPage`
Ask where the feature is first used, or from the setup list; never by itself, and never in a
batch at launch (`LocationUse`: a forecast Banana fetches on its own does not show the system's
location question). From the plan, a connected calendar raises its asks one card at a time
(`PlanPrompt`): which calendars keep each other busy, then alerts, opened by a sample made from
the person's next real meeting in the alert's own words (`NextAlertSample`), then Reminders.
Each card is one line and one button with a × that sends it to the setup list for good, and
none shows on a guess: only when the system is known never to have been asked. One priming
template, built on `OnePage`: a symbol tile or a real preview
(a small day, for the calendar) · a `.title2` title · 2–3 reasons of a few words in one card
· a main button with a specific verb ("Turn on notifications") · "Not now" under it. Skipping
is *deferred*, not *denied*; once the system says no, the main button is "Open Settings",
with one line saying what to turn on there. Never draw a fake system alert.

The setup list shows **every** item in one order, ticked when done: a finished row keeps its
place. A row is a Settings row: the solid tile and the name. "Set up" means really on: a refusal doesn't count, and neither does Apple Health once
asked, since it won't say what was answered (that row reads "Asked" and opens Health). The line
above the plan is there with or without a calendar; its × hides the line only, and "Finish
setup" stays in the plan's menu while anything has never been asked for.

## Travel — `TravelLegDetail`, `PlacePickerView`, `GettingThereView`
A travel band is always `travel` blue; its icon is the **mode glyph** (a mode is a glyph, never a
colour), and with room it reads **minutes · place** ("24 min · Chelsea Piers"). A place that is
only a guess ends in "?". The detail is display only: block titles and ids, which the calendar
write-back keys on, never change. Where a trip goes is asked once, inline (the Today card, "Where
is this?" in the inspector and event sheet), never in a modal that interrupts; the answer is a
`SavedPlace`, synced, covering every event with that location text. Distances are one decimal
in the local unit (`PlaceDistance`).

## One control for each job — `PageChrome`, `PageChromeRules`

10 Oct 2026. The author: the controls were "different … all over the place", and the cause under it,
"we [are] intermixing action and analysis". Every screen's controls were listed; the same job was
done five or six ways. Now there is one way for each, and a page never draws its own variant.

**Doing and looking back are apart.** Plan, Workouts, Nutrition, Notes and Library are for now
and next. Everything about the past, across all of them, is **Review** (`ReviewView`): opened by
the chart button at the top left of every tab on a phone (the corner hardest to reach, for the
thing opened least), a sidebar row on the iPad and the Mac. Review has the app's only time-span
switch: Week · Month · Year. Workouts' period bar and trends, Sleep, Trends, listening history
and its map, and Nutrition's logs-against-weight card all moved there.

| Job | The one control | Where |
|---|---|---|
| Switch between a page's views | `PageSwitch`: a segmented switch, four words at most, remembered | The top bar, where the title would be. Plan: Day · Week. Nutrition: Food · Taken. Review: Week · Month · Year |
| Step through dates | `DateLine`: back, name and dates, a pill home when away, forward. Swiping left goes forward; tapping the name goes home | The row under the top bar. Plan, Nutrition, Review |
| Add | `.addButton` / `.addMenu` / `.addListButton`: the top bar's +, beside "…". On a phone it opens the one list of everything (`AddList`), this page's own first; on an iPad and the Mac the page's own (one kind at once, several a short menu) | Top right of every main page, on every device (16 Oct 2026: as the tab bar's search slot it stuttered, iOS treating it as a page). In a sheet, adding is the last row of its list |
| Look back | `ReviewToolbarItem` | Top left of every main page |
| More | `MoreMenu`: "…", ending with Routines and Settings | Top right of every main page. On a detail page "…" holds Edit, Share, Delete |
| Close or save a sheet | Changes something: Cancel left, a verb right. Only looked at: Done right, plain weight. A list to pick from: Cancel left | |
| Act on a row | Tap opens. Swipe left deletes. Press-and-hold offers the same. No extra icons on rows | |
| An empty page | One line, and one button that does what + does | |
| Titles | Inline everywhere; a capital on the first word only | |
| Words | reminder (not task), routine (not cue), listening | |

Not done, on purpose: Plan's blocks are not list rows, so they have no swipe. Now Playing has no
Done (it is dragged away, like the system's player). On the Mac the date line is the toolbar's
(the standard, 5), on every dated page.

## One look for each control — `Controls.swift`

10 Oct 2026. The author: "our buttons, inputs, etc are all over the place". Three audits found the main
action drawn six ways, "Join" seven, selected chips seven, icon buttons twelve, clock time entered
five ways. The rule: **every control is the system's, with the app's choices set once** in
`Controls.swift`. A page never draws a button, chip, field or card of its own, so the OS the app
runs on decides how they look.

| Job | The one look | How |
|---|---|---|
| The main action of a page or sheet's content | Filled capsule, full width, ink on the accent | `.buttonStyle(.primaryPage)` |
| The main action of a card or row | The same, at the size of its words | `.buttonStyle(.primary)`; `.primarySmall` in a dense line |
| An action beside or under it | The system's bordered button, capsule | `.buttonStyle(.secondary)`, `.secondarySmall`, `.secondaryPage` |
| The way out ("Not now") | Words, secondary colour, full-size target | `.buttonStyle(.quiet)` |
| A small action in a line ("Undo", "Edit", "+3 more") | Words in the accent, no font of its own | `.buttonStyle(.inline)` |
| Destructive | `role: .destructive` and nothing else: no colour by hand | |
| A symbol alone, in content | Borderless, 44-point target | `.iconButton()`. Toolbars size their own |
| Floating over content (the +, a photo viewer's Done) | The system's glass | `.buttonStyle(.glass)` |
| A whole row or card that opens something | `.buttonStyle(.plain)`, or a `NavigationLink` in a list | |
| A clock time | The system's compact hour-and-minute field, in five-minute steps on every device; its wheels only where the time is the page's whole question (onboarding) | `TimeField`, `.wheels()`; minutes stored: `ClockTime.binding` |
| A day and a time | The same field with the day, in the same five-minute steps | `MomentField` |
| Search | The system's search field | `.searchable`, with `.searchPresentationToolbarBehavior(.avoidHidingContent)` in a sheet so its Cancel stays |
| A sheet's Cancel and Save | The toolbar's, on the Mac too: `.cancellationAction` / `.confirmationAction` | no row of buttons drawn in the content |
| Several on/off choices (weekdays, filters) | The system's toggle button, capsule | `ChoiceChip`; weekdays: `WeekdayToggleRow` |
| One of a few | `Picker`: segmented for two or three in a form row, a menu beyond that; `PageSwitch` for a page's views | |
| A label that says what something is | Capsule, caption, soft wash of its colour | `Tag` |
| A switch | `Toggle`, a switch, on in the accent: set on the form, never per switch | `editingFormStyle()` / `settingsFormStyle()` |
| An editing sheet | The system's grouped form | `.editingFormStyle()` |
| Notes in a form | A field that grows, 2 to 8 lines | `NotesField` |
| A card | One: radius `card`, inset `l` | `.dsCard()`; `.groupedCard()` adds the inset |
| Floating for a moment (toast, notice, legend) | The system's glass capsule | `.floatingCapsule()` |
| On the accent | Ink (`DS.Palette.onAccent`), never white | |
| A warning or an estimate | `DS.Palette.warning`. The accent never judges | |

Not done yet (they change behaviour or a Mac layout that has to be seen first): deletes that have
neither Undo nor a question (routines, notes in a list, podcasts, alarms, listening history); the
Mac sheets that draw their own Cancel and Save (new event, routine, availability); hand-made
search rows (food search, Mac settings); clock time entered five ways; the Mac routine editor,
which is not a form.

## Navigation and state — `ShellNavigation`
The iOS tree is thrown away in the background (the CPU guard in `AppVisibility`), and the Mac
rebuilds a section's view when the sidebar leaves it. So nothing that says *where the person
is* may live in a view's `@State`: the tab, each tab's stack and a tab's segment live in
`ShellNavigation`. Pushes are value-based (`NavigationLink(value:)` with
`navigationDestination(for:)` at the stack root) so the path can be stored. A relaunch within
an hour of leaving restores it; later launches open on Plan.

## Keyboard
Shortcuts are drawn with `KeyCombo` — one `KeyCap` per key. Palettes have a footer of key hints.

## Flows
- **Create:** drag on the grid, event appears in place.
- **Reply:** Yes / No / Maybe in the inspector (also E then Y/N/M); the block restyles at once.
- **Share availability (Mac):** a side panel; the calendar stays visible, jumps to the first
  offered day, and outlines every offered slot; Copy (⌘C) confirms with a toast.

## Verifying
Offscreen snapshots: `--snapshot-app-store <png> --snapshot-view <name>` (views in
`MacDebugSnapshotViews`), planner with sample data: `--ui-audit` (+ `--event-states-sample`,
`--trip-sample`, `--open-availability`). The offscreen renderer can't draw system materials
(toolbar, sidebar show white) — judge those from a real `screencapture -l <window>`.
iPhone widgets: `--widgets` (`--home-only`) in the Simulator.
