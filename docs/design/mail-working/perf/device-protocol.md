# Device baseline protocol — Beta build on the real iPhone and Mac

**Nothing in this file has been run.** It is the exact, ordered procedure to take the same baseline
the Simulator gate takes, on the owner's hardware, with the **Beta** variant, when he says go.
Every command is from the repo's own tooling (`tools/ios-install.sh`, `tools/mac-install.sh`,
`perfctl`) or the recipe that worked on 2026-09-02 (memory note *banana-device-perf-verification*).

Standing rules that apply (docs/DEV-CYCLE.md, memory notes):
- Beta only (`com.boris.banana.beta`, Mac `com.boris.banana.mac.beta`). Never `prod` without a fresh,
  explicit yes for that install. The 2026-09-02 prod authorisation was for that install only.
- Always install-over. **Never `devicectl device uninstall`.**
- The phone must be unlocked for build-for-device and for `devicectl install`.
- Two iPhones are paired to this Mac; the device id is mandatory on every command.
- A Beta launch is a *production-shaped* launch of the Beta app: it syncs the Beta iCloud namespace
  (`iCloud.com.boris.banana.beta`) and, if a Google account is connected in Beta, runs calendar
  write-back against that account's calendars. Say so before the first launch; it is his data.

Identifiers (from the memory notes; confirm with `xcrun devicectl list devices` before use):

| What | Value |
|---|---|
| Owner's iPhone 15 Pro Max | `F0E8AAC8-17D1-5853-A522-7B1F3EE65646` |
| "AyePad" iPad Pro 12.9 (hardware UDID) | `<device-udid>` |
| Beta bundle (iPhone) | `com.boris.banana.beta` |
| Beta journal path (iPhone container) | `Library/Application Support/Banana Beta/playback.log` |
| Beta app (Mac) | `/Applications/Banana Beta.app` |
| Beta data root (Mac) | `~/Library/Application Support/Banana Beta/` |
| Beta prefs (Mac) | `~/Library/Preferences/com.boris.banana.mac.beta.plist` (use PlistBuddy, not `defaults read`) |

What the device numbers are compared against:
- The §4b rig medians (iPhone 14 Pro, Debug, no permissions): `root.appear` 203 ms, `today.content` 239 ms.
- The 2026-09-02 Beta numbers on the daily phone: `wireUp.done` 3.8 s, no storms (prod before the fix: 8–32 s, RootView×91/15 s).
- The Simulator baseline in `baseline.md` — direction only, never magnitude.
- Each later milestone: the same commands, the same journal lines, medians of ≥5 launches.

---

## A. iPhone (Beta, Release)

### A1. Build + install over (Release is the script's default since 29 Sep)

```sh
cd ~/repo/abrega/gtfuwgth          # or the worktree that holds the milestone commit
uptime; pgrep -x xcodebuild | wc -l           # record host load — another session may be building
git rev-parse --short HEAD                    # record the commit in the results file
tools/ios-install.sh beta F0E8AAC8-17D1-5853-A522-7B1F3EE65646
```
`tools/ios-install.sh` runs `xcodegen generate`, builds `BananaBeta` Release into `.build/ios-beta`,
and `devicectl device install app` (install-over). It passes `-quiet`; on this Xcode `-quiet`
prints a fake "command failed with exit code 0" on successful builds — judge by the `Installed …`
line, not by that message. Record the build wall time (`time tools/ios-install.sh …`).

### A2. Cold-launch marks (×5, medians; discard the post-install first launch)

Repeat 6 times, terminating between runs (lock/unlock is not a termination; use the app switcher
swipe-up, or `xcrun devicectl device process terminate --device <id> --pid <pid>` after reading the
pid from the launch output):

```sh
D=F0E8AAC8-17D1-5853-A522-7B1F3EE65646
xcrun devicectl device process launch --device $D com.boris.banana.beta
sleep 20
xcrun devicectl device copy from --device $D --domain-type appDataContainer \
  --domain-identifier com.boris.banana.beta \
  --source "Library/Application Support/Banana Beta/playback.log" \
  --destination ./device-runs/iphone-launch-$(date +%H%M%S).log
```
Read the `⏱` lines of the newest `launch  app started` block. Marks to tabulate, in order:
`app.init.body`, `app.init.done`, `smart.init`, `alarms.init`, `settings.init`, `history.init`,
`root.body`, `root.appear` (≈ first frame), `today.body`, `today.content`, `fitness.loaded`,
`library.loaded`, `wireUp.start`, `wireUp.done`, plus `occurrences.snapshot` / `weather.snapshot` /
`planningWindows.snapshot` (they must land BEFORE `root.appear` — that is the §4b stale-while-
revalidate guarantee). Also note any `⚠️ PREVIOUS RUN DIED WHILE PLAYING`, `📊 MetricKit`,
`📊 CPU EXCEPTION`, `📊 HANG`, `📊 CRASH` lines — those are yesterday's verdicts.

To get `perf N%` lines every 5 s with body counts (the loop-class instrument), launch with
`--perf-trace` as a trailing argument. `xcrun devicectl device process launch --help` shows the
positional `[<arguments>…]` form; if this Xcode's devicectl does not pass arguments through, set the
argument on the BananaBeta scheme in Xcode instead. Do not use `--perf-trace` for the idle-CPU
number itself (it adds a 5 s sampling timer and a 4 Hz DEBUG probe in Debug builds).

### A3. Idle on each section, 60 s (the "should be ~0" number)

With the app in front, open Plan (Day), then Week, then Workouts, Nutrition, Notes, Library — leave
each on screen for ≥ 80 s without touching it (the watchdog samples every 15 s in the foreground
and writes one `⚡ POWER 60s` line per minute). Pull the journal once at the end:

```sh
xcrun devicectl device copy from --device $D --domain-type appDataContainer \
  --domain-identifier com.boris.banana.beta \
  --source "Library/Application Support/Banana Beta/playback.log" --destination ./device-runs/iphone-idle.log
grep -E "⚡ POWER|🌀 STORM|🔥 HIGH CPU|🌡 THERMAL" ./device-runs/iphone-idle.log
```
Per section record: `cpu=… avg/… max`, `mem=…MB`, `wakeups=`, `syscalls=`, `activity=` (must read
`none` or a handful of bodies, never a `↻` publisher at a rate), and the STORM/HIGH CPU count
(must be 0). Compare with the Simulator route of the same name.

### A4. Background playback soak (PERF-PLAN §4.2; the budget that an email client must not touch)

Start a downloaded episode, lock the phone, leave it ≥ 1 h (2 h is the protocol). Pull the journal:
only 30 s heartbeats and `⚡ POWER` lines with `scene=background audio=playing…`, `cpu` avg ≤ ~2 %,
no STORM, no `app → background` followed by a death. Next morning: the `📊 MetricKit` line must show
no `CPU-LIMIT KILLS`.

### A5. Backgrounded idle (no playback) — "suspended in seconds; no timers alive"

Open the app, background it (home), wait 5 min, pull the journal. Between `app → background` and the
next `app → foreground` there must be **no** `⚡ POWER`/`perf` lines (a suspended process writes
nothing). Any line there means a timer kept the process alive. `ActionBadges`' 60 s timer and the
Google change poll are the two to look for (see findings.md).

### A6. Release-only failure classes (the 1 MB main-thread stack)

Run the screens smoke test in Release on a device where overwriting the **production** bundle is
acceptable (the `Banana` scheme builds `com.boris.banana`, not Beta — that is why it was run on the
iPad "AyePad", never on the daily phone):
```sh
xcodebuild test -project Banana.xcodeproj -scheme Banana -configuration Release \
  -destination 'id=<device-udid>' -derivedDataPath .build/ipad-uitest \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  -only-testing:BananaUITests/ScreensOpenUITest
```
Note (READ-IN-CODE, BananaApp.swift:7-30, 262-276): a Release build has no `VisualAuditRoute`, so this
test launches the production graph on that device (its real data, sync, write-back). State that
before running it.

### A7. Crash logs, if anything died
```sh
xcrun devicectl device info files --device $D --domain-type systemCrashLogs
xcrun devicectl device copy from --device $D --domain-type systemCrashLogs --source . --destination ./device-crashes
```
`cpu_resource_fatal-*.ips` = the background CPU kill class; symbolicate per memory note
*banana-crash-stack-symbolication* (Release: against the dSYM in `.build/ios-beta`).

### A8. Overnight, unattended (optional; the repo's own harness)

`PerformanceInfrastructure/README.md` documents `perfctl prepare-device … --scenario control.idle|
planner.refresh --personal-device`. **It temporarily replaces the installed production binary**
(Release + `-DPERFORMANCE_TESTING`, same bundle id, no uninstall) and requires Power Profiler
set-up on the phone; that is a production install and needs its own explicit yes. The result
bundle (`Documents/PerformanceRuns/<run-id>/result.json`) gives CPU-seconds, footprint, wakeups,
syscalls, context switches for the locked-standby interval — the reference is
`docs/PERFORMANCE-DEVICE-AUDIT-2026-07-23.md` (5 s idle control: 0.0129 CPU-s, 10 wakeups, 13.94 MB).

---

## B. Mac (Beta, Release)

### B1. Build + install
```sh
tools/mac-install.sh beta          # Release, ONLY_ACTIVE_ARCH=YES, → /Applications/Banana Beta.app
```
The script quits a running Beta first (pkill) and replaces the bundle. It does **not** touch
`/Applications/Banana.app` (prod).

### B2. Launch and verify it is alive (the MenuBarExtra hang class)
```sh
open -a "Banana Beta"; sleep 5
PID=$(pgrep -f "/Applications/Banana Beta.app/Contents/MacOS/" | head -1)
sample $PID 3 -file ./device-runs/mac-launch-sample.txt     # main thread must be in mach_msg2_trap (idle)
grep -E "⏱|launch" "$HOME/Library/Application Support/Banana Beta/playback.log" | tail -30
```
`wireUp.done` must appear; medians over 5 launches (`osascript -e 'quit app "Banana Beta"'`
between runs, or Cmd-Q).

### B3. Idle on each section, 60 s
Click through Plan (Day), Week, Workouts, Nutrition, Notes, Library, Trends, Settings; ≥ 80 s each
(Mac watchdog interval is 20 s; one `⚡ POWER` line per minute). Then, with the window hidden
(Cmd-H) and miniaturised, another 5 min — the Mac has no visibility gate (findings.md), so this is
where a shell storm would show. External cross-check per section:
```sh
ps -p $PID -o cputime=,rss=     # before and after 60 s; Δcputime/60 = avg %
grep -E "⚡ POWER|🌀 STORM|🔥 HIGH CPU" "$HOME/Library/Application Support/Banana Beta/playback.log"
```
If a STORM names `MacRootView`/`MacWeekView`/`SettingsView`: `sample $PID 5` — CA::Transaction
commit roots = layout/invalidation loop (the dotted-AppStorage class), AttributeGraph body
re-evaluation = a publisher (see PerfWatchdog's `↻` counters; note the Mac blind spot in findings.md).

### B4. Headless offscreen snapshot (Debug only — the installed Release Beta cannot do this)
`--snapshot-app-store <png> --snapshot-view <name>` is `#if DEBUG && os(macOS)` (BananaApp.swift:236,
314). It exists only in a Debug build run from `.build/`, and even then `App.init` reads every live
store from `~/Library/Application Support/Banana Beta/` and appends `launch` to that
`playback.log` and `events.ndjson` (BananaApp.swift:81,134; DiagnosticsTracing.swift:601-611). It
skips `wireUp()` and, because `--snapshot-app-store` is in `CalendarWriteBack.diagnosticArguments`
(CalendarWriteBack.swift:891-895), write-back, the exclusion migration and the menu-bar item. With
`--disable-icloud` it also skips the Controls/Wellness/Fitness/Progress/Meals CloudKit starts
(CloudControlsSync.swift:106 and siblings). It is therefore read-mostly, not write-free. A way to make
it write-free, **to be approved before use**: run the Debug binary with `HOME=$(mktemp -d)` so
`AppSupport.directory` resolves to an empty root (AppSupport.swift:42-52 derives from
`.applicationSupportDirectory`, which honours `HOME`); caveats: `UserDefaults` still resolves through
cfprefsd to the real `com.boris.banana.mac.beta` domain (tiny writes: migration flags, LWW stamps),
and the keychain (Google credentials) is read, not written, by `GoogleAccountStore` at init
(INFERRED — not fully traced).

---

## C. What to write down for each milestone

One row per (device, section): median of `root.appear` / `today.content` / `wireUp.done`,
`⚡ POWER` cpu avg/max, mem, wakeups, STORM count, HIGH CPU count, host load at build time, commit.
Keep the raw journals beside the table. Compare like with like: iPhone-Beta against iPhone-Beta,
never against the Simulator's milliseconds.
