# Baseline — build 51, `google-email-functionality` @ `1155270`, 2026-10-05

**These are Simulator numbers. They are for relative before/after comparison on this Mac only.
They are not device numbers** (no device install was authorised; see `device-protocol.md`).

## What was measured, and how

- **Build:** `Banana` scheme, **Release** configuration (`-O`, whole-module) for the iOS Simulator,
  with the `DEBUG` compilation condition **added** so the `VisualAuditRoute` launch flags exist
  (they are `#if DEBUG && os(iOS)`, `BananaApp.swift:7-30`; a pure Release build has no safe route
  and can only be launched into the production graph). `ONLY_ACTIVE_ARCH=YES` (arm64 slice only).
  Own derived data: `.build/mail-perf-dd`. Not byte-identical to a shipping Release; the optimiser
  settings are.
  ```
  xcodebuild -project Banana.xcodeproj -scheme Banana -configuration Release \
    -destination 'platform=iOS Simulator,id=E5232BE0-8F82-4E85-A03B-5CA7160571E2' \
    -derivedDataPath .build/mail-perf-dd \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) DEBUG' ONLY_ACTIVE_ARCH=YES build
  ```
- **Launch (every route):** `xcrun simctl launch <udid> com.boris.banana <route flags> --disable-icloud
  -onboardingCompleted YES`. Audit routes skip `wireUp()` and the scenePhase cascade
  (`RootView.swift:270`), so **no `wireUp.*` marks, no `CloudSyncPoll`, no Google sync, no write-back,
  no notifications occur** in these runs; `CloudControlsSync.isAvailable` is hard-false on the
  Simulator (`CloudControlsSync.swift:102-108`). One CloudKit call still happens per launch
  (`MealBacklogWake.subscribe`, findings L1) and errors harmlessly.
- **Simulators:** "Mail iPhone" `E5232BE0-…` and "Mail iPad" `7CE990BF-…`, iOS 26.5, both measured
  in parallel. Before measuring, each gets `simctl location set` + `simctl privacy grant location`:
  without a responsive `locationd` the app never reaches its first frame (findings F1).
- **Cold-launch marks:** 1 warm-up launch (discarded) + 5 measured launches per route; the journal
  (`<container>/Library/Application Support/playback.log`) is deleted before each launch and read
  6 s after; `⏱ <mark> +<ms>` lines are LaunchClock's milliseconds from kernel process creation.
  `root.appear` = `RootView.onAppear` ≈ first frame (`RootView.swift:225`). Medians, with min–max.
- **Idle:** one launch per route, 15 s settle, then a 65 s window: process CPU = Δ `ps -o cputime`
  over the window (external to the app); RSS from `ps`; the app's own `⚡ POWER 72s` line gives
  phys footprint, wakeups/syscalls/csw and the busiest bodies (`activity=`), and its CPU avg/max
  **include the launch burst** (first rollup covers the first 72 s); `🌀 STORM` / `🔥 HIGH CPU` lines
  counted; a `simctl io screenshot` and a `du` of the data container are taken at the end.
- **Host load:** recorded per route (`load-before.txt`). Run 1 started at a 1-min load average of
  **420** (another session's test run) and ended near 8; run 2 ran at ~8–15 throughout. The
  noise-floor table therefore includes a load swing of that size — a realistic bound for this Mac.
- **Script:** `perf/perf-gate.sh` (`run` / `compare` / `routes`); results in `perf/results/<stamp>-<label>.json|.tsv`
  plus a folder per run with every journal, screenshot, `idle-ps.txt`, `idle-sample.txt`,
  `container-sizes.txt` and the exact launch command. Run twice here (`baseline-run1`, `baseline-run2`).

## Headline numbers (iPhone simulator, Release+DEBUG, medians)

| What | Value | Source |
|---|---|---|
| Clean Release build, Simulator, Watch app + widget embedded | **355 s wall** (user 548 s) at 1-min load 145–200; n=1 | `logs/build-release-1.log`, `.meta` |
| App bundle / main executable (arm64 Simulator slice, DEBUG routes compiled in) | **185 MB / 55.8 MB**; largest parts: `BarcodeProducts.sqlite` 55 MB, `NarratorVoiceModel.mlmodelc` 31 MB, `Foods.sqlite` 20 MB, `whistle.cact` 17 MB, Watch app 8 MB | `du` of `Banana.app` |
| First frame, shell (`--ui-preview --tab plan`) | **1,014 ms** (iPhone), 1,094 ms (iPad), measured under load 405 | run 1 |
| First frame, populated Day grid (`--day`) | **1,251 ms** (iPhone), 1,332 ms (iPad) | run 1 |
| First frame, populated Today (`--today`) / `today.content` | **1,091 / 1,095 ms** | run 1 |
| Store inits (`app.init.body` → `history.init`) | ≈ 490 → 715 ms, i.e. ~225 ms of `@StateObject` construction on the first render pass | run 1, every route |
| Idle CPU on every section, 65 s | **0.00–0.05 %** on all 15 iPhone routes and 18 of 19 iPad routes; **1.02 % on iPad `shell-workouts`** (10,343 wakeups/72 s; location alert on screen — see run 2 / findings L12) | run 1 |
| Footprint after settle | 33–52 MB (Week grid highest, 52 MB iPhone / 57 MB iPad) | `⚡ POWER mem=` |
| STORM / HIGH CPU lines | **0 / 0** across all 34 idle runs | journals |
| Persisted stores after a preview launch | Application Support 20–28 KB (`routines.json` 2 KB, journal, diagnostics), Documents 0, Caches 164 KB–1.1 MB (artwork from the library fixtures), Preferences < 1 KB | `container-sizes.txt` |
| Unit tests (`BananaTests`, Debug config per the scheme, Mail iPhone) | **1,422 executed, 3 skipped, 0 failures, 58.2 s** test time (`xcodebuild test` wall 245 s incl. the Debug build, at 1-min load 400–800) vs. the stated 73.9 s baseline | `logs/tests.log`, `logs/tests.meta` |

Caveat on `today.*` marks: `TodayView` is mounted only by the DEBUG `--today` route since 27 Sep
(`PlannerTab` mounts `WeekView(dayMode: true)`), so `today.content` is not a shipping-path mark any more;
`root.appear` on `--day`/`shell-plan` is the Plan-tab first frame that matters.

## Noise floor (run 1 vs run 2, same binary)

See the generated table below (`baseline-tables.py run1.json run2.json`). The `compare` rule in
`perf-gate.sh` flags a regression when `new − base > max(floor, k·max(spread_base, spread_new))`,
with floors 40 ms (launch marks), 0.5 % (CPU), 8 MB (memory), and any STORM/HIGH CPU > 0 fails.
Set the floors from the table below when re-running at a milestone.

**Measured noise floor (run 1 vs run 2, same binary, 34 routes):**
- `root.appear`: median |Δ| 39 ms, within-run spread (max−min over 5 launches) median 35 ms at
  stable load; but when host load differs between runs **every** mark shifts together (`app.init.body`
  +80–120 ms on the 10 routes measured at load ~250–400 vs ~10), while the ratio
  `root.appear ÷ app.init.body` stays within ±0.05 (1.91–2.00 on shell routes, 2.5–2.6 on Day/Week,
  both runs). `compare` therefore normalises launch marks by `app.init.body` whenever that anchor
  moved by more than the floor, and says so.
- `fitness.loaded` / `library.loaded` (async decode completions): median |Δ| 68 ms → their floor is 100 ms.
- Idle CPU (`ps` Δcputime over 65 s): |Δ| median 0.00 %, every route 0.00–0.05 % in both runs **except two
  one-offs** — iPad `shell-workouts` 1.02 % / 10,343 wakeups in run 1 (0.03 % / 274 in run 2) and iPad
  `trends` 0.97 % / 48 wakeups in run 2 (0.03 % in run 1); a 2 s `sample` after the window showed an
  idle main thread in both; cause unknown, not reproduced. Rule for the gate: a non-zero idle must
  reproduce on a re-run of that route before it counts as a finding; two in a row is one.
- Footprint (`⚡ mem=`): |Δ| median 0 MB; the one +19 MB (iPad `shell-workouts`, 54 → 73 MB) is a
  different screen state under the alert (see caveat). Simulator RSS swings ±12–39 MB and is not used.
- Wakeups: |Δ| median 8 per 72 s.
- `compare` with the floors above on these two runs: **2 "regressions"** (the two idle one-offs), 27
  "improvements" (routes measured under lighter load, normalised away where the anchor moved).
  `logs/compare-run1-run2.txt` has the full output.

**Caveats that apply to these numbers**
1. **iPad routes were measured with the Simulator's location prompt on screen.** `simctl privacy grant
   location` suppresses it on the iPhone simulator but not on the iPad one (tested: `reset` +
   `grant location-always` + `grant location` still prompts; `locationd`'s `clients.plist` shows
   `Authorization => 2`). The prompt is raised by the Plan tab's `weather.refreshIfStale()` →
   `WeatherStore.swift:592` on every `--ui-preview` launch (the shell opens on Plan before `--tab`
   switches). It costs no measurable idle CPU (0.02–0.05 % with it up) but it is an extra system window
   in the process. Fix for the next run: find the simctl incantation that sticks on iPad, or answer the
   prompt once by hand on the booted simulator.
2. The build has the DEBUG condition; Release-only stack behaviour (the 1 MB main-thread stack) is
   not exercised here — that needs `ScreensOpenUITest` on hardware (device-protocol.md A6).
3. `wireUp.*`, `CloudSyncPoll`, Google sync, write-back and notifications never run in audit routes;
   the device protocol is the only way to measure those.
4. Run 1's first five routes on each device were measured at a 1-min load of 90–405; everything
   from `shell-sleep`/`today` onward at 5–50; run 2's last eight routes at 250–400. Per-route loads
   are in each route folder.

**Store sizes after a preview launch** (`container-sizes.txt`, Simulator data container):
`Library/Application Support` 20–28 KB (`routines.json` 2.1 KB, `playback.log` ≤ 2 KB,
`com.boris.banana/Diagnostics/events.ndjson` ≤ 1 KB, `occurrences-snapshot.json` + `planning-windows.json`
after a Day/Today route — decoded in ~1 ms on the next launches, `⏱ *.snapshot` ≈ 517 ms vs `app.init.body`
490 ms), `Documents` 0, `Library/Caches` 164 KB → 1.1 MB as the library fixtures' artwork accumulates
(`Artwork/`), `Library/Preferences` < 1 KB. No podcast catalogue, history or fitness files exist in an
audit launch; real-data store sizes need the device protocol.

## Re-running

```
perf/perf-gate.sh run --label <milestone> [--skip-build] [--only route,route] [--no-ipad]
perf/perf-gate.sh compare perf/results/20261005-165711-baseline-run1.json perf/results/<new>.json
```
Default floors: 40 ms launch (100 ms for `*.loaded`), 0.5 % idle CPU, 8 MB footprint; STORM/HIGH CPU > 0
fails. Add mail routes to the table at the top of the script (see mail-budgets.md §2).

---

Run: baseline-run1 @ 1155270 2026-10-05T17:40:22; runs=5 settle=15s idle=65s

### iphone — cold-launch marks, median ms from process creation (min–max over n launches)

| route | app.init.body | app.init.done | weather.snapshot | smart.init | alarms.init | settings.init | history.init | root.body | root.appear | fitness.loaded | library.loaded | today.content | planningWindows.snapshot | occurrences.snapshot |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| day | **499** (494–503) | **601** (595–604) | **559** (553–561) | **661** (653–662) | **690** (683–692) | **714** (707–716) | **715** (708–717) | **831** (826–844) | **1251** (1243–1266) | **1383** (1373–1398) | **1383** (1374–1399) | — | — | — |
| library | **490** (489–493) | **595** (590–602) | **552** (548–560) | **657** (652–661) | **684** (664–701) | **710** (690–727) | **711** (691–728) | **839** (826–862) | **965** (957–996) | **1131** (1120–1162) | — | — | — | — |
| notes | **503** (499–509) | **609** (605–612) | **565** (562–571) | **670** (666–673) | **700** (698–703) | **725** (723–729) | **726** (724–730) | **847** (841–858) | **998** (991–1007) | **1185** (1183–1207) | **1186** (1184–1208) | — | — | — |
| settings | **490** (483–504) | **595** (591–610) | **554** (547–568) | **652** (649–669) | **681** (671–700) | **705** (695–726) | **706** (696–727) | **822** (820–850) | **971** (965–998) | **1152** (1149–1179) | **1152** (1149–1180) | — | **518** (511–531) | **517** (510–530) |
| shell-library | **490** (486–497) | **592** (584–607) | **552** (544–560) | **648** (645–665) | **677** (651–695) | **728** (701–745) | **729** (702–746) | **849** (819–868) | **934** (909–953) | **1104** (1097–1122) | **1105** (1097–1122) | — | — | — |
| shell-notes | **489** (486–493) | **592** (588–602) | **549** (546–559) | **651** (646–659) | **681** (676–688) | **734** (726–738) | **735** (727–739) | **852** (847–859) | **939** (936–947) | **1194** (1192–1201) | **1195** (1193–1203) | — | — | — |
| shell-nutrition | **490** (482–500) | **591** (583–599) | **549** (541–558) | **648** (639–657) | **677** (669–687) | **730** (719–739) | **731** (720–740) | **853** (841–860) | **942** (929–949) | **1234** (1221–1244) | **1236** (1222–1245) | — | — | — |
| shell-plan | **506** (494–671) | **623** (604–791) | **579** (558–744) | **688** (664–862) | **696** (694–895) | **749** (748–955) | **750** (749–956) | **916** (868–1090) | **1014** (960–1190) | **1600** (1534–1778) | **1602** (1535–1780) | — | — | — |
| shell-workouts | **493** (485–564) | **598** (591–681) | **556** (546–636) | **658** (651–746) | **687** (682–753) | **737** (735–807) | **738** (736–808) | **860** (855–965) | **948** (945–1066) | **1248** (1234–1407) | **1250** (1236–1410) | — | — | — |
| sleep | **489** (484–495) | **601** (592–604) | **557** (552–561) | **659** (649–663) | **689** (678–694) | **739** (729–746) | **740** (729–747) | **855** (842–869) | **1034** (1023–1054) | **1136** (1121–1149) | **1137** (1122–1150) | — | **518** (513–523) | **517** (512–522) |
| today | **494** (486–508) | **597** (593–623) | **554** (549–580) | **655** (653–687) | **685** (662–719) | **709** (686–746) | **710** (687–747) | **829** (816–869) | **1091** (1077–1147) | **1378** (1365–1447) | **1379** (1366–1448) | **1095** (1081–1151) | — | — |
| trends | **488** (480–490) | **595** (585–602) | **553** (544–558) | **651** (641–659) | **680** (648–689) | **730** (698–742) | **731** (699–743) | **848** (817–866) | **1021** (1001–1039) | **1096** (1089–1116) | **1097** (1090–1116) | — | **516** (507–520) | **515** (506–519) |
| week | **527** (521–534) | **638** (627–646) | **595** (585–602) | **704** (688–711) | **729** (718–738) | **756** (745–764) | **757** (746–765) | **878** (866–891) | **1311** (1287–1323) | **1481** (1457–1500) | **1482** (1458–1500) | — | — | — |
| wellness | **520** (517–526) | **636** (634–641) | **588** (588–594) | **701** (696–706) | **734** (726–738) | **761** (753–765) | **762** (754–766) | **895** (879–901) | **1025** (1001–1034) | **1183** (1151–1191) | **1184** (1152–1192) | — | — | — |
| workouts | **508** (506–522) | **621** (617–633) | **575** (572–588) | **685** (683–699) | **716** (715–731) | **772** (771–786) | **773** (772–787) | **909** (900–915) | **1052** (1038–1058) | **1209** (1191–1226) | **1211** (1192–1228) | — | — | — |

### iphone — idle on screen after 15 s settle, 65 s window

| route | CPU % (ps Δcputime) | RSS MB | footprint MB (⚡) | ⚡ avg/max % (incl. launch) | wakeups/72 s | STORM | HIGH CPU | activity | Caches KB |
|---|---|---|---|---|---|---|---|---|---|
| day | 0.02 | 299.4 | 41 | 3.8/15.1 | 69 | 0 | 0 | none | 292 |
| library | 0.05 | 287.8 | 34 | 2.6/10.3 | 54 | 0 | 0 | none | 724 |
| notes | 0.03 | 289.7 | 35 | 2.8/11.1 | 166 | 0 | 0 | none | 724 |
| settings | 0.02 | 289.7 | 36 | 2.5/9.9 | 54 | 0 | 0 | none | 724 |
| shell-library | 0.0 | 279.2 | 33 | 2.4/9.4 | 226 | 0 | 0 | none | 164 |
| shell-notes | 0.02 | 290.3 | 36 | 2.7/10.6 | 246 | 0 | 0 | none | 164 |
| shell-nutrition | 0.02 | 290.6 | 38 | 2.5/10.0 | 251 | 0 | 0 | none | 164 |
| shell-plan | 0.02 | 292.2 | 39 | 3.4/13.6 | 47 | 0 | 0 | none | 164 |
| shell-workouts | 0.02 | 289.0 | 38 | 3.4/13.4 | 177 | 0 | 0 | none | 164 |
| sleep | 0.03 | 290.2 | 38 | 3.0/11.8 | 73 | 0 | 0 | none | 804 |
| today | 0.02 | 305.5 | 44 | 3.9/15.6 | 158 | 0 | 0 | none | 220 |
| trends | 0.03 | 279.7 | 36 | 2.0/8.0 | 42 | 0 | 0 | none | 724 |
| week | 0.02 | 312.0 | 52 | 4.1/16.3 | 88 | 0 | 0 | none | 292 |
| wellness | 0.02 | 281.6 | 35 | 2.3/9.0 | 37 | 0 | 0 | none | 292 |
| workouts | 0.02 | 282.6 | 34 | 2.6/10.5 | 52 | 0 | 0 | none | 292 |

### ipad — cold-launch marks, median ms from process creation (min–max over n launches)

| route | app.init.body | app.init.done | weather.snapshot | smart.init | alarms.init | settings.init | history.init | root.body | root.appear | fitness.loaded | library.loaded | today.content | planningWindows.snapshot | occurrences.snapshot |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| day | **518** (508–525) | **633** (632–639) | **588** (586–595) | **741** (738–746) | **718** (715–723) | **751** (748–756) | **752** (749–757) | **891** (890–896) | **1332** (1328–1335) | **1549** (1547–1564) | **1550** (1547–1565) | — | **549** (540–554) | **548** (539–553) |
| library | **496** (493–510) | **605** (602–616) | **563** (560–575) | **708** (696–713) | **686** (670–688) | **717** (704–722) | **718** (705–723) | **847** (841–853) | **971** (968–984) | **1142** (1130–1154) | — | — | **525** (520–537) | **524** (519–536) |
| notes | **492** (486–494) | **598** (588–600) | **558** (549–558) | **694** (680–706) | **672** (656–682) | **702** (689–714) | **703** (690–715) | **833** (817–840) | **987** (981–997) | **1157** (1148–1164) | **1158** (1148–1165) | — | **521** (513–522) | **520** (512–521) |
| settings | **494** (491–500) | **599** (596–605) | **560** (557–564) | **698** (679–712) | **676** (654–688) | **706** (687–721) | **707** (688–722) | **837** (816–852) | **988** (976–1005) | **1145** (1145–1161) | **1146** (1145–1162) | — | **522** (520–528) | **521** (519–527) |
| shell-library | **492** (491–497) | **592** (591–599) | **551** (551–557) | **724** (700–733) | **674** (649–681) | **732** (709–742) | **733** (710–743) | **868** (849–876) | **991** (976–1003) | **1178** (1174–1184) | **1179** (1175–1185) | — | — | — |
| shell-notes | **496** (491–501) | **595** (591–610) | **554** (551–566) | **725** (718–740) | **675** (671–691) | **733** (727–748) | **735** (728–749) | **862** (853–874) | **982** (972–994) | **1255** (1241–1265) | **1257** (1243–1267) | — | — | — |
| shell-nutrition | **492** (491–503) | **599** (591–609) | **555** (551–565) | **731** (704–747) | **682** (649–695) | **740** (713–756) | **741** (714–757) | **865** (844–898) | **988** (967–1012) | **1421** (1412–1449) | **1423** (1414–1451) | — | — | — |
| shell-plan | **550** (523–732) | **657** (638–848) | **612** (592–803) | **795** (780–989) | **743** (727–936) | **806** (789–1000) | **807** (790–1001) | **959** (936–1142) | **1094** (1074–1274) | **1676** (1665–1873) | **1678** (1667–1875) | — | — | — |
| shell-routines | **499** (498–507) | **602** (600–607) | **560** (558–568) | **735** (728–740) | **684** (680–690) | **744** (736–749) | **745** (737–750) | **874** (864–880) | **997** (993–1008) | **1299** (1287–1305) | **1301** (1289–1306) | — | — | — |
| shell-settings | **500** (493–515) | **616** (597–631) | **571** (557–588) | **750** (727–765) | **699** (678–714) | **760** (736–774) | **761** (738–775) | **900** (867–908) | **1025** (989–1034) | **1342** (1291–1364) | **1344** (1292–1366) | — | **531** (520–547) | **530** (519–545) |
| shell-sleep | **513** (503–521) | **629** (605–630) | **583** (563–587) | **743** (737–763) | **691** (688–713) | **753** (745–772) | **754** (746–773) | **895** (883–913) | **1021** (1004–1038) | **1337** (1297–1353) | **1338** (1299–1355) | — | — | — |
| shell-trends | **496** (492–504) | **599** (591–604) | **558** (551–564) | **730** (722–735) | **680** (673–685) | **738** (731–744) | **739** (732–745) | **872** (862–879) | **993** (983–1002) | **1448** (1438–1463) | **1449** (1440–1465) | — | — | — |
| shell-workouts | **515** (492–557) | **616** (591–684) | **574** (551–633) | **751** (722–838) | **700** (672–782) | **760** (730–849) | **761** (732–850) | **889** (860–1031) | **1018** (984–1161) | **1388** (1350–1550) | **1390** (1351–1552) | — | — | — |
| sleep | **489** (484–494) | **598** (591–601) | **557** (552–562) | **725** (718–728) | **677** (669–679) | **734** (726–736) | **735** (727–738) | **858** (851–878) | **1044** (1034–1057) | **1142** (1128–1156) | **1142** (1129–1157) | — | **518** (513–522) | **517** (512–521) |
| today | **512** (500–514) | **627** (614–635) | **579** (569–588) | **737** (700–748) | **712** (673–721) | **746** (710–756) | **747** (711–758) | **894** (852–902) | **1202** (1169–1217) | **1479** (1463–1493) | **1481** (1464–1494) | **958** (915–965) | **540** (529–545) | **539** (528–543) |
| trends | **515** (491–528) | **637** (596–654) | **590** (555–607) | **752** (723–794) | **698** (674–741) | **762** (731–806) | **763** (732–807) | **908** (862–959) | **1108** (1042–1153) | **1327** (1241–1356) | **1327** (1242–1357) | — | **547** (518–557) | **546** (517–556) |
| week | **492** (490–500) | **601** (596–608) | **561** (556–566) | **706** (699–713) | **684** (677–689) | **714** (708–721) | **715** (709–722) | **845** (839–857) | **1283** (1275–1304) | **1591** (1576–1620) | **1592** (1577–1621) | — | **524** (519–528) | **523** (517–527) |
| wellness | **497** (493–501) | **602** (600–605) | **562** (560–565) | **703** (683–707) | **681** (659–684) | **712** (692–715) | **713** (693–716) | **838** (827–844) | **965** (962–976) | **1226** (1224–1236) | **1227** (1225–1237) | — | **525** (523–528) | **524** (521–527) |
| workouts | **492** (486–499) | **597** (592–604) | **557** (551–564) | **725** (704–738) | **676** (653–687) | **733** (713–748) | **734** (713–749) | **865** (849–878) | **1004** (996–1018) | **1182** (1172–1194) | **1183** (1174–1196) | — | **520** (515–526) | **519** (514–525) |

### ipad — idle on screen after 15 s settle, 65 s window

| route | CPU % (ps Δcputime) | RSS MB | footprint MB (⚡) | ⚡ avg/max % (incl. launch) | wakeups/72 s | STORM | HIGH CPU | activity | Caches KB |
|---|---|---|---|---|---|---|---|---|---|
| day | 0.03 | 298.9 | 41 | 3.9/15.5 | 86 | 0 | 0 | none | 644 |
| library | 0.03 | 285.7 | 34 | 2.5/9.9 | 44 | 0 | 0 | none | 1092 |
| notes | 0.03 | 287.5 | 34 | 2.6/10.6 | 130 | 0 | 0 | none | 1092 |
| settings | 0.02 | 287.2 | 35 | 2.3/9.3 | 146 | 0 | 0 | none | 1092 |
| shell-library | 0.02 | 284.4 | 34 | 2.5/9.9 | 231 | 0 | 0 | none | 460 |
| shell-notes | 0.02 | 291.8 | 36 | 2.9/11.5 | 274 | 0 | 0 | none | 460 |
| shell-nutrition | 0.02 | 297.9 | 41 | 2.8/11.2 | 277 | 0 | 0 | none | 460 |
| shell-plan | 0.05 | 297.4 | 40 | 3.5/13.8 | 50 | 0 | 0 | none | 164 |
| shell-routines | 0.02 | 294.8 | 39 | 2.9/11.7 | 259 | 0 | 0 | none | 588 |
| shell-settings | 0.02 | 298.3 | 39 | 2.8/11.2 | 298 | 0 | 0 | none | 588 |
| shell-sleep | 0.02 | 301.3 | 41 | 3.0/12.1 | 280 | 0 | 0 | none | 588 |
| shell-trends | 0.02 | 300.2 | 44 | 2.9/11.7 | 297 | 0 | 0 | none | 588 |
| shell-workouts | 1.02 | 346.5 | 54 | 4.5/14.9 | 10343 | 0 | 0 | none | 460 |
| sleep | 0.03 | 288.4 | 37 | 3.0/11.8 | 73 | 0 | 0 | none | 1092 |
| today | 0.03 | 306.2 | 43 | 4.0/15.9 | 153 | 0 | 0 | none | 588 |
| trends | 0.03 | 285.2 | 40 | 2.3/9.1 | 36 | 0 | 0 | none | 1092 |
| week | 0.03 | 316.5 | 57 | 4.2/16.8 | 83 | 0 | 0 | none | 660 |
| wellness | 0.02 | 286.8 | 38 | 2.6/10.2 | 48 | 0 | 0 | none | 660 |
| workouts | 0.02 | 285.6 | 37 | 2.6/10.3 | 45 | 0 | 0 | none | 660 |

### Noise floor: baseline-run1 vs baseline-run2 (same build, same routes)

| metric | routes | median |Δ| | max |Δ| | median within-run spread (max−min) | max within-run spread |
|---|---|---|---|---|---|
| launch.app.init.body | 34 | 14.5 | 118.0 | 13.0 | 209.0 |
| launch.app.init.done | 34 | 24.5 | 150.0 | 17.0 | 210.0 |
| launch.weather.snapshot | 34 | 19.5 | 141.0 | 15.5 | 211.0 |
| launch.smart.init | 34 | 28.5 | 195.0 | 23.5 | 209.0 |
| launch.alarms.init | 34 | 27.0 | 183.0 | 30.5 | 209.0 |
| launch.settings.init | 34 | 29.0 | 197.0 | 33.0 | 211.0 |
| launch.history.init | 34 | 29.0 | 197.0 | 33.0 | 211.0 |
| launch.root.body | 34 | 37.0 | 245.0 | 31.0 | 222.0 |
| launch.root.appear | 34 | 39.0 | 268.0 | 35.0 | 286.0 |
| launch.fitness.loaded | 34 | 68.5 | 289.0 | 34.0 | 359.0 |
| launch.library.loaded | 32 | 68.0 | 290.0 | 33.5 | 359.0 |
| idle.cpu_pct_ps | 34 | 0.0 | 1.0 | 0.0 | 0.0 |
| idle.rss_mb | 34 | 1.3 | 39.0 | 0.0 | 0.0 |
| idle.power_mem_mb | 34 | 0.0 | 19.0 | 0.0 | 0.0 |
| idle.power_wakeups | 34 | 8.0 | 10069.0 | 0.0 | 0.0 |
| launch.planningWindows.snapshot | 14 | 95.5 | 131.0 | 16.5 | 108.0 |
| launch.occurrences.snapshot | 14 | 95.5 | 130.0 | 16.0 | 107.0 |
| launch.today.content | 2 | 130.0 | 201.0 | 48.0 | 70.0 |
