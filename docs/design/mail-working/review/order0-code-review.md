# Code review — commits `e3e63d3..f7391d0` (order 0)

STATUS: FINAL.

Worktree `~/orca/workspaces/gtfuwgth/stingray`, branch `google-email-functionality`.
Read-only review by reading the code: nothing was modified, built, launched or run, so every
statement below is from the source, not from a device. Line numbers are for `f7391d0`.

Commits, oldest first: `604db00` (cascade split), `a2d31f8` (background timers + heartbeat),
`d949563` (dotted key, two sinks, timer tolerance), `f7391d0` (render notes, sinks, Nutrition lets).

## Verdict per commit

| Commit | Verdict |
|---|---|
| `604db00` | Keep as is. Two optional one-line follow-ups (MINOR 3, MINOR 6). |
| `a2d31f8` | Keep with the listed fix: decide MAJOR 1 (the home-screen icon badge) before relying on it. The poll half and the heartbeat half are correct. |
| `d949563` | Keep as is. |
| `f7391d0` | Keep as is. One note site will log a storm for ordinary typing and hovering (MINOR 2). |

No BLOCKER found. One MAJOR, six MINOR.

## The two specific questions

1. **Does `CalendarWriteBack.refreshCalendars` hit the network on every activation? No.**
   `Banana/Model/CalendarWriteBack.swift:193-226` reads `GoogleCalendarService.isConnected`
   (`!accounts.isEmpty`), `allCalendarInfos` and `writeBackCandidates`
   (`GoogleCalendarService.swift:266,287,309`), all computed from the in-memory `calendars` array.
   Its one side effect is `enableDefaultWriteBackIfNeeded()` (`CalendarWriteBack.swift:410-423`),
   which writes the synced setting the first time a Google account with a writable calendar is
   seen and no device has chosen yet; after that its guard is false on every call. Keeping it on
   every activation is right, and the commit achieves its purpose for this call.
   The rest of the every-activation half is local too: `restoreIfNeeded` returns at once after the
   launch restore (`GoogleCalendarService.swift:333-334`); the three authorization syncs read a
   recorded status and only work when it moved; `setPeerServingAllowed` and `setInterfaceActive`
   return on an unchanged value (`DownloadManager.swift:447-448`, `PlayerController.swift:181-182`).

2. **Is making the heartbeat Mac-only observable to anyone? Not to a person, and not to routing.**
   `MealEstimators.shared.all` has two readers, both `MealBacklogRouting.macTakes`
   (`MealBacklogProcessor.swift:124,156`), which requires `status.device == "Mac"`
   (`MealBacklog.swift:404-411`). No view observes the list, no settings screen lists devices,
   there is no "last seen" display, and no election reads a phone's or iPad's entry (grep of
   `Banana`, `Shared`, `BananaTests` and the docs for `MealEstimators`, `MealEstimatorStatus`,
   `mealEstimators`). The only trace is diagnostic: the journal no longer records an iPhone or
   iPad power or capability change between launches (`MealEstimators.swift:35-37,57-60`), and that
   device's `at` in iCloud stays at its launch time. One side effect in the good direction: the
   key is a single blob for all devices, last writer wins, so a phone that no longer rewrites it
   every 15 min can no longer overwrite the Mac's fresh heartbeat with its older copy.

## Findings, most severe first

### MAJOR 1 — `a2d31f8` — the home-screen icon badge stops following the clock while audio plays in the background

`Banana/Model/ActionBadges.swift:46-49` (`pause()`), called from `Banana/Views/RootView.swift:332`.

What is wrong. The commit says the 60 s recount ran "for a count nobody could look at". That holds
for the tab and sidebar badges, not for the third thing `recount()` feeds: the app icon.
`ActionBadges.swift:74-80` calls `UNUserNotificationCenter.setBadgeCount` when the total moves, and
it is the only writer of the icon badge in the tree (grep: `setBadgeCount` has one caller, and no
notification sets `content.badge`). The home screen is where that badge is looked at while the app
is in the background. The dose count moves with the clock, not with a publisher:
`ActionItems.dueSince` is `due <= now` (`ActionItems.swift:39-42`), and "today's doses" changes at
midnight. The class's own doc gives that as the reason for the minute tick
(`ActionBadges.swift:10-12`). The overdue-reminder count is not affected: `Occurrence.overdue` is a
stored flag (`Occurrence.swift:119`) that moves on a recompute, which still recounts.

Sequence. The phone is playing a podcast in a pocket, so the process is alive. 08:00: the morning
doses come due. Before: the icon shows the count by 08:01. Now: the icon keeps the number it had
when the app was left, until a store happens to publish or the app is opened. In reverse at
midnight: yesterday's unmarked doses stop counting, and the icon keeps showing them.
With no audio the process is suspended and the icon was already frozen, so this changes only the
audio case, which is the case the commit targets.

What stopping it buys. In that same case the process is already awake for audio, so the saving is
one recount a minute. `docs/PERF-PLAN.md` §5 asks for "no timers alive" in the row for
backgrounded idle with no playback, where a suspended process fires no timer either way.

Smallest fix, one of:
- (a) Take `ActionBadges` out of the background stop: delete `RootView.swift:293` and `:332`, keep
  the Google-poll half, and give the 60 s timer a tolerance. Restores the old behaviour exactly.
- (b) Keep the saving: in `pause()` replace the repeating timer with one non-repeating timer for
  the next moment a count can move (the earliest unmarked dose due today, else midnight), recount
  there and re-arm. Nothing fires on a day with nothing coming.
- (c) Accept the stale icon, and correct the two comments that say nobody can see the count
  (`ActionBadges.swift:43-45`, `ForegroundCascadeRules.swift:45-47`).

### MINOR 2 — `f7391d0` — the note in `WideNutritionView` counts every keystroke and row hover, so ordinary use on the iPad and Mac can log a storm

`Banana/Views/WideNutritionView.swift:56`.

What is wrong. The view's own body reads `phrase` (`:171`, `:183` via `trimmedPhrase`, bound at
`:178`), `hoveredMeal` (`:291,297`) and `hoveredSupplement` (`:430,431`), all `@State` on this
view, so the body runs once per keystroke and once or twice per row the pointer crosses. The
watchdog calls anything at 2/s over its window a storm and falls back to a view name when no
publisher is over the line (`PerfWatchdog.swift:284-292`). The window is 15 s on an iPad in front
and 20 s on the Mac (`:333-343`), so 30 or 40 body runs in one window is enough.

Sequence. On the Mac, type "greek yogurt with granola and blueberries, black coffee" (54
characters) into "What did you eat?" in about 12 s. The next sample logs
`🌀 STORM: WideNutritionView at 2/s`, writes a `publisher_storm` record to the journal, and returns
before the HIGH CPU check (`:306`). Running the pointer down and up a long meal list does the same.
`docs/PERF-PLAN.md` §4 step 8 gates on "storm log silent" and §5 on "no 2/s storms".

This is in the watchdog's stated bargain ("the cost of catching a legitimate burst is one log
line", `:117-119`), which is why it is MINOR. It is the one new site that fires in everyday use.
The other eight do not: NotesView's 5 Hz ticker is `@State` on `VoiceNoteDetailView`
(`NotesView.swift:465-478,544`), a separate view, so playing a note does not re-run
`NotesView.body`. `NotesView.search` (`:13`) and `SettingsView.settingsSearch` (`:117`) re-run
their bodies per keystroke too, but a search is rarely 30 characters in 15 s.

Smallest fix. Move the text field with its Log button into a small private view that owns
`phrase`, and the hover highlight into the row view. The page then stops re-evaluating per
keystroke, which is also the cheaper render. Or accept the line and say so beside the note.

### MINOR 3 — `604db00` — the Watch "N to send" count is now refreshed only on a real return

`Banana/Views/RootView.swift:290`.

What is wrong. `watchEpisodesPending` has no other writer (grep). The call is a local count and a
key-value write only when the number moved (`HubStatus.swift:162-172`), not a network request, so
it did not need gating. `handleRequests()` (`:288`) is local as well, but gating it loses nothing:
the key-value change notification runs it on arrival (`HubStatus.swift:116-124`).

Sequence. The phone stays open while episodes finish transferring to the Watch. Before, any glance
republished the count. Now the iPad and Mac keep showing the old "N to send" until the phone has
been to the background and back.

Smallest fix. Move line 290 out of the `if plan.runsNetworkAndSync` block.

### MINOR 4 — `a2d31f8` — after a short trip away, a calendar change is noticed 120 s after the return instead of at a random point within those 120 s

`Banana/Model/SmartScheduleStore.swift:1487` (the loop sleeps first), restarted from `:1522-1525`.

What still notices a change on return. `smart.recomputeIfStale()` reads Google when the last
recompute is over 60 s old and Smart Schedule is on (`:652-664`, `:690`). The rebuilt Today and
Week run `occurrences.recomputeIfStale()` with a 45 s guard (`TodayView.swift:480-504`,
`OccurrenceStore.swift:293-300`), and only when the tree was rebuilt, which needs more than the
2.5 s grace. So for an absence longer than about a minute nothing is slower.

What is slower. An absence shorter than those guards: leave for 30 s, accept an invitation in
another app, come back. Neither guard fires, so the poll is the only detector. Before, in a process
audio kept alive, the next tick was 0 to 120 s away (mean 60 s). Now it is exactly 120 s. The worst
case is unchanged.

`lastGoogleChangeCheck` is correct: it advances only on an answer (`:1496-1497`), a pause does not
touch it, so the first check after a return still covers the whole absence. It is in memory only;
after a relaunch it starts at store init, and the launch recompute covers the gap, as before.

Smallest fix, optional. On restart make the first sleep
`max(0, interval - now.timeIntervalSince(lastGoogleChangeCheck))`. A long absence then checks at
once, sharing the cascade's Google read through the 45 s cache.

### MINOR 5 — `a2d31f8` — the restart depends on the flag alone, and the stop never reaches a process launched without a window

`Banana/Views/RootView.swift:292-295`.

What is wrong. I found no sequence that leaves the timers off (traces below). The pairing still
rests on one flag in view state, where `ActionBadges.resume()` and
`resumeCalendarChangePolling()` are both no-ops unless paused (`ActionBadges.swift:54-55`,
`SmartScheduleStore.swift:1523`). Calling them on every `.active` costs nothing and makes "in
front means running" true whatever the flag says.

Separately, the stop lives only in `RootView`. A process launched headless (the alarm's Stop
intent starting the wake podcast, a background task) has no `RootView`, so its 60 s timer keeps
running as it did before the commit. And `AppVisibility.isActive` starts `true`
(`AppVisibility.swift:21`), so if the store exists there the Google poll does real requests.
Neither is introduced here; the commit title claims more than it delivers for that path.

Smallest fix. Drop the `if plan.restartsTimers` condition around lines 293-294.

### MINOR 6 — `604db00`, `a2d31f8` — the tests assert one thing the app never asks, and nothing covers the stores' pause and resume

`BananaTests/ForegroundCascadeRulesTests.swift:29,46,74,119`; `ForegroundCascadeRules.swift:41`.

What is wrong. `RootView` consults `runsNetworkAndSync`, `restartsTimers` and `stopsTimers`
(`RootView.swift:287,292,299,311,331`). It never reads `rereadsPermissions`: the permission
re-reads are unconditional inside `case .active` (`:305-310`). The test named "a glance re-reads
permissions" therefore passes whatever the view does.

Sequence. Someone moves `Task { await smart.syncCalendarAuthorization() }` inside the
`if plan.runsNetworkAndSync` block. "Calendar isn't connected" after a grant is back, and all 14
rule tests pass.

Also untested: `ActionBadges.pause/resume` and the two poll methods (neither file is in the test
target), and the view's wiring. `testEveryStopIsFollowedByARestart` proves the plan, not the timers.
The rule tests themselves are sound and would fail on a regression of the rule. The heartbeat tests
pin the real reader and the real rule (`FoodPortionTextTests.swift:232-246`); the migration tests
call the function the app calls.

Smallest fix. Wrap `RootView.swift:302-310` in `if plan.rereadsPermissions` (true for every
`.active`, so behaviour does not change), or delete the property and its four assertions.

### MINOR 7 — `f7391d0` — `registerLateSinks` gains two sinks and can still be registered more than once

`Banana/Model/PerfWatchdog.swift:235-240`; caller `Banana/BananaApp.swift:575,629`.

What is wrong. `wireUp()` runs from the root view's `.task` with no once-guard, so each new root
appends the sinks again. This was already so for the four older sinks; the commit adds
`shell↻` and `sync↻` to the same list.

Sequence. On the Mac, close the window and reopen it from the Dock, or press ⌘N (no
`CommandGroup(replacing: .newItem)` in the tree). Every publish of those stores is now counted
twice, so their storm threshold is halved, and again on the next reopen.

Also, `sync↻` is decided once: if the meal engine is not running at that moment the sink is never
added (`:238`).

Smallest fix. A static `lateSinksRegistered` flag at the top of `registerLateSinks`.

## Commit 1 — the flag through every scene-phase sequence

Rule: `ForegroundCascadeRules.swift:59-73`. Flag starts `true`; `.background` sets it; `.active`
clears it and returns `fullReturn` if it was set or `previous == .background`.

| Sequence | Result |
|---|---|
| Cold launch, `… → active` | First `.active` is `fullReturn` whatever came before it. Everything runs, in the old order. |
| Launched in the background, opened later | With no window there is no `RootView` and no call. On opening, `.inactive` is `none`, `.active` is `fullReturn`. If `.background` is delivered first it only re-sets a flag that is already set. |
| `active → inactive → active` | `glance`. `cascade == foregroundCascade`, so nothing is written to `@State`. |
| `active → inactive → background → inactive → active` | `.background` sets the flag and stops the timers; `.inactive` keeps it; `.active` is `fullReturn`, once. The next glance is a glance. |
| `active → background → active` with no `inactive` | `fullReturn`. |
| `.background` not delivered, `previous == .background` on return | `fullReturn` by the second clause. |
| iPad Split View resize, Slide Over, Stage Manager | A resize is a glance. A window whose stage is hidden goes to `.background` and comes back as `fullReturn`. One scene only (`UIApplicationSupportsMultipleScenes: false`, `project.yml:113`), so one flag per process. |
| Full-screen cover at launch (the morning briefing) | The cover is a modifier on `RootView`, which stays installed and keeps receiving the phase. The flag is not involved. |
| Tree blanked 2.5 s after backgrounding and rebuilt | Only `gatedContent`'s children are replaced (`RootView.swift:368-371`). `RootView` and its `@State` survive. |

It cannot stick: every `.background` sets the flag in the same handler that stops the timers, with
no early return between them in a release build (the DEBUG audit-route return at `:273` is before
both). It cannot run twice: `.active` clears the flag before returning.
`RootView` consults the type itself (`:277-279`); there is no inline copy of the rule.

Where each of the 20 old `.active` calls is now:
- Every activation: `AppVisibility.set`, `TripLearningService.appBecameActive`,
  `setPeerServingAllowed`, `setInterfaceActive`, the journal line, `reconcileWakeState`,
  `handleWakeIfNeeded`, `syncCalendarAuthorization`, `syncRemindersAuthorization`,
  `music.syncAuthorization`, `refreshCalendars`, `onboarding.refresh`.
- Real return only: `handleRequests`, `CloudSyncPoll.resume`, the watch count,
  `adoptGoogleAccountsAddedElsewhere`, `recomputeIfStale`, `flushNow("foreground")`,
  `refreshFeedsAndReconcile`.

Stale after a permission grant? No. Each authorization sync does its own refresh when the status
moved: `SmartScheduleStore.swift:591-596` calls `refreshCalendarAuthorization` (agenda and
timeline); `OccurrenceStore.swift:229-234` recomputes; `MusicController.swift:29-37` loads the
library; the in-app request paths await their own result and then apply
(`SmartScheduleStore.swift:599-613`, `:627-633`). None relied on the `recomputeIfStale` that used
to follow. A grant made in the Settings app is a real return.

## Commit 2 — stop and restart paths

| Path | Result |
|---|---|
| Backgrounded during launch, before the first start | `ActionBadges.start()` runs in `App.init` (`BananaApp.swift:139`), before any phase. The poll starts in `SmartScheduleStore.init` (`:454`); touching `smart` in the `.background` handler builds the store, starts the poll, then cancels it. |
| Paused twice | Both pauses are idempotent. |
| Resumed without having been started | `guard started` (`ActionBadges.swift:55`); the poll handle is nil only after a pause. |
| Launch | Both resumes are no-ops, as claimed. |
| Paused while a check is in flight | The cancelled task finishes its request, records the answer, and exits at the loop test. A change found then stays pending and the return consumes it (`:1539-1547`, `:658-660`). |
| Pause then a quick resume | The old task exits; one loop runs. Both are on the main actor. |
| Tree discarded and rebuilt | Both objects are singletons outside the tree. `BananaApp`'s `@StateObject` and `RootView.smart` are the same `.shared` (`BananaApp.swift:49`, `RootView.swift:22`). |

The Mac. `pause`/`resume` have four call sites, all in `RootView.swift`, an `#if os(iOS)` file.
`MacRootView` calls neither. `repeatsStatus(on: .mac)` is true (`MealBacklog.swift:386`).
`ActionBadges.start()` arms and recounts in the old order. The poll loop is the same code; its
stamp starts at store init instead of at the task's first line. The Mac is unaffected.

The iPad runs `RootView` too, so it pauses like the phone, and it stops repeating its status
(`DeviceRole.pad`). Both follow from the code; "iOS only" in the message includes the iPad.

## Checked and found correct

- `d949563` migration, every state: never set (nothing written, both readers default to `true`:
  `SettingsView.swift:129`, `MenuBarAgenda.swift:43-45`); old `true`; old `false`; already
  migrated (not overwritten); old key rewritten later by an older build (ignored, by design, and
  the old key is left for that build). It runs after the bundle-identity carry-over and before
  any reader (`BananaApp.swift:72-82`). No reader of the old key remains (grep).
- `d949563` sinks: on iOS both existed at the same point already. On the Mac the player is built
  by `BananaApp`'s stored property before `init`'s body (`BananaApp.swift:60`), and
  `CloudBackup.init` is two defaults reads and at most a one-time `cloudBackupEnabled = true`
  (`CloudBackup.swift:145-161`); at most it moves from the first window render to `App.init`.
  `PlayerController` publishes state, not ticks, so `player↻` will not storm on the Mac.
- `d949563` tolerance: 3 s on a 30 s timer.
- `f7391d0` sinks build nothing early in the app: `ToastCenter` is built by `OccurrenceStore.init`
  (`OccurrenceStore.swift:150`), which `ActionBadges.start()` reaches one line earlier, along with
  `WellnessStore` and `MealInboxStore`; `SyncProgress` is built by `CloudControlsSync.start`
  (`:188`), so it exists exactly when `isRunning` is true; `ShellNavigation` is held by `RootView`
  before its `.task` runs `wireUp`. Exception outside the app proper: the `PERFORMANCE_TESTING`
  `playback.local` scenario runs `wireUp` without `RootView`, so there the sink builds
  `ShellNavigation` (a defaults read).
- `f7391d0` retains nothing new: the sinks capture nothing and subscribe to singletons.
- `f7391d0` Nutrition `let`s are equivalent. `visible` and `dayMeals` are taken when `list` is
  evaluated, in the same pass that reads them. The one lazily evaluated reader is the `ForEach`
  closure (`WellnessView.swift:257-258`), which now sees that pass's snapshot instead of the live
  value; any change to the meals, the hidden ids or the day publishes and replaces the closure in
  the next pass. The `.onAppear` and `.task` hooks still read the live property (`:368,380,400`),
  which they must, since they wait on it. `@ViewBuilder` with `let`s and one expression leaves the
  view type unchanged, so the Settings-style stack growth does not apply. The filter still runs
  three times a pass (`visible`, `today`, `total`), not once; down from about a dozen.
- Debug-only code: none of the new code depends on a `#if DEBUG` symbol. The new `let`s are used
  outside the DEBUG blocks.
- Actor and thread use: timers are created and invalidated on the main thread; `pause`/`resume`
  and the poll task are main-actor isolated.
- Test target: `ForegroundCascadeRules.swift`, `MenuBarAgendaSetting.swift`, `DeviceRole.swift`
  and `MealBacklog.swift` are all listed in `project.yml` (`:419,421,440,489`).

## Limits of this review

- Nothing was built or run, so "compiles in Release" is from reading: I found no DEBUG-only
  dependency, but did not compile.
- Scene-phase behaviour (what `onChange` delivers at launch, under a cover, on a scene
  reconnect) is from the code's own comments and SwiftUI's documented behaviour, not from a device.
- The 0 to 120 s figure for the old poll assumes a process kept alive by audio. For a suspended
  process the old first tick was either immediate or 120 s later, depending on which ran first on
  resume; I did not establish which.
