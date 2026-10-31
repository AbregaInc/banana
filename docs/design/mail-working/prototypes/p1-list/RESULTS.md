# P1: which list host can an email inbox be built on?

Throwaway prototype in `p1-list/`: standalone app `com.boris.banana.proto.p1list`, one multiplatform SwiftUI target
(iOS 26.1 / macOS 26, Swift 5 mode), Release builds. Nothing in the main repository was touched or built.

**Status.** The iPhone Simulator matrix is complete (3 runs of every host x scenario, plus a one-run sweep of every
SwiftUI variant, plus the XCUITest). **The Mac matrix has not been run.** The coordinator stopped Mac runs after a first,
partial attempt because the window kept taking the owner's focus. The Mac host code (an `NSTableView`) compiles in Release
and the app was rebuilt to be safe to run unattended, but that safe launch path has never been exercised. The one command
that runs the Mac matrix is in section 6, with its duration. Every Mac number in this file is marked partial.

## 0. Answer

**Native wins and nothing else comes close.** A `UICollectionView` list layout hosting SwiftUI rows through
`UIHostingConfiguration` passed every positional scenario (prepend 0.00 pt on 30 of 30 inserts, restore 0.33 pt, 3 of 3 window
re-centres without a jump), re-evaluated nothing but the two leaf views per cursor move, idled flat and fired 20 of 20
system swipes per edge without ever blocking a scroll. SwiftUI `List` failed all three positional scenarios in every variant
tried, and `LazyVStack` fails each in one way or another (one displaced frame per insert; or only whole rows; or a scroll
that always lands a frame late); none of the three SwiftUI hosts could hold a re-centre.
The reviewer's expectation was right, and it is now a measurement.

| pass / fail, iPhone Simulator, 3 runs each | prepend 3 above (0 pt) | rebuild (within 1 pt, first frame) | slide (no jump) | held key (no per-move container work, <= 3 hitches/10 s) | idle flat | 20/20 swipes per edge, scroll never blocked |
|---|---|---|---|---|---|---|
| **native** `UICollectionView` list layout | **pass** 0.00 pt | **pass** 0.33 pt | **pass** 0 frames | **pass** | **pass** | **pass** 20/20, 20/20, drags 10/10 |
| SwiftUI `List` (best variant: `reader`) | fail 156 pt, permanent | fail, restores the wrong row | fail, 7 jump frames, up to 1,212 pt | pass * | pass | pass 20/20, 20/20, drags 10/10 |
| `LazyVStack`, `ScrollPosition` y (`positionY`) | fail 192 pt for 1 frame per insert | pass 0.33 pt | fail, 1,180 frames (scroll one frame late, plus 6 jump frames) | pass * | pass | no `.swipeActions`; a drag-gesture swipe fires 20/20 and does not block scrolling here |
| `LazyVStack`, `scrollPosition(id:)` (`id`) | pass 0.00 pt (see caveat, 3.2) | fail 47.7 pt | fail, 1,120 frames | pass * | pass | same as above |

\* The SwiftUI hosts take the rows as input, so their container re-evaluates once per window re-centre (14 times in the
2,000-move run, exactly the 14 re-centres) and not once per move. Native observes the rows itself and re-evaluates 0 times. Read
literally ("rises by 0"), the SwiftUI hosts fail by 14; read as intended ("no per-move work"), they pass. The strict number is
in the table in section 2.

## 1. How the numbers were taken

**Machine and build.** MacBookPro18,2 (M1 Max, 10 cores), macOS 26.6.2, Xcode 27.0 (iOS 27 SDK, deployment target 26.1),
simulator "Mail iPhone" (iPhone 17 Pro, iOS 26.5, 402x874 pt at 3x, 60 Hz, so a frame is 16.67 ms), Release (-O, whole
module). The simulator ran headless; Simulator.app was never opened.

**Instruments.** The app's `FrameProbe` is `#if DEBUG && os(iOS)` and reports through `PlaybackDiagnostics`, and `RenderStats`
is a lock-guarded dictionary inside `PerfWatchdog`: neither is self-contained enough to copy. The prototype rebuilds the two
ideas (`Sources/Instruments.swift`, `Sources/Model.swift`): a `CADisplayLink` on the main run loop (a hitch is an interval over
twice `link.duration`, `FrameProbe`'s definition, but every frame's sample is kept instead of one-second windows) and plain
static counters at the top of the bodies (`Counters.container`, `.rowBody`, `.markBody`). So the numbers share the app's
definitions, not its code.

**What "the marked row's y" is.** Two independent probes, sampled on every display frame:
- *Ground truth* where rows are cells (`native`, and `List`, which is a `UICollectionView` underneath): the realised cell's
  window position, from the layers' model values plus how far any in-flight animation has the presentation layer from the
  model. It decides for `native` and `list`.
- *SwiftUI's own report*: an `onGeometryChange` that exists only on the one marked row (a conditional modifier inside the row's
  leaf view, so no other row pays for it). It decides for `lazy` (a `ScrollView` has no cells) and cross-checks `list`; the two
  agreed on every `prepend` rep of every `list` run (156 pt / 192 pt in both) and on native's 0. Inside the native host's hosting cells it is not usable while scrolling (UIKit
  moves the cell and SwiftUI is not told), which is a finding in itself (section 4).
- A frame with no sample (the row left the screen) counts as a failure, never as "did not move".

**Scenarios** run inside the app from `--scenario`, 1.5 s after launch, one JSON per run. The run script writes `uptime` and
`pgrep -x xcodebuild | wc -l` taken immediately before each launch into every file.
- `prepend`: row 50 at the top (set through the host's own API), 3 rows inserted at index 0, ten times, the row's y for 2 s
  each time. Pass: worst shift <= 0.5 pt and the row never absent.
- `rebuild`: row 137 plus 23.68 pt. Every host is put at the fractional position the way a drag leaves it (a platform-level scroll,
  not the API under test); the host stamps (first row key, whole points into it) outside the tree; the whole content becomes a
  blank view for 3 s; then it is restored. Pass: the marked row within 1 pt of where it was on the first frame it is on screen,
  and no frame showing the list without it. One frame in which the host does not yet exist is SwiftUI's own latency, the same for
  every host, and is reported as `framesBeforeHost`.
- `slide`: cursor down 600 rows at 30/s; the 400-row window re-centres (cursor within 100 rows of an edge goes back to row 200),
  3 times. Every frame where the cursor row is not at previous y + 64 per move minus the points the app intended to scroll is
  recorded, and that strict count is the pass number. A second count lets a scroll land one frame late (a latency, not a jump) and
  shows what is left.
- `heldkey`: 2,000 moves (down 1,000, up 1,000) at 30/s from a `DispatchSourceTimer`, scrolling to keep the cursor visible with one
  row beyond it. `heldkey-still` (extra): 300 moves among the rows already on screen, no scrolling, which isolates the highlight
  cost from row realisation.
- `idle`: 20 s, every counter flat.
- Rows are `Equatable` (`.equatable()`), 64 pt, built from leaf views. The cursor is drawn by a leaf view observing the row's own
  `RowMark` (`ObservableObject`, the app's `PlaybackClock` pattern); nothing the container reads changes on a cursor move. Data:
  5,200 seeded conversations, a 400-row window.

**Load.** The machine was shared with other sessions' test runs: a load average of 300-800 when I started, 5-15 in quiet spells,
and bursts to 400-900 during the matrix. Positional results (does a row move, by how many points) do not depend on load and are
used as is. Frame timing, hitch counts and turn times do. The tables give the 1-minute load average at each run's launch,
run 1 / 2 / 3; only a run whose load is about 12 or under is trustworthy for timing. The timing scenarios (`heldkey`, `heldkey-still`, `idle`) were run twice: the first copies of runs 2 and 3 were taken at a load of 250-900 and were
repeated when the machine was quiet; the loaded copies are kept in `results/ios-loaded-timing/` and are not in the tables (they show the same pass/fail
and the same hitch counts within a few frames, so the simulator's frame delivery was not very sensitive to the load, but they are not evidence).
In the tables, timing runs were launched at a load of 5-15, except three launches where another session's burst began as the run started: `list` held key run 2
(95), `lazy positionY` held key run 2 (44) and `list` held-key-still run 1 (15). Treat those three as unreliable for timing.

## 2. Results

### 2.1 The matrix (iPhone Simulator, 3 runs; the deciding number is median [min-max])

| host | variant | scenario | platform | pass | deciding number: median [range] | other numbers | load (1-min avg at launch, run 1 / 2 / 3) |
|---|---|---|---|---|---|---|---|
| lazy | id | prepend | iOS Simulator | 3/3 | 0.00 [0.00-0.00] pt | frames displaced/insert (worst rep): [0, 0, 0] | 7 / 224 / 524 |
| lazy | id | rebuild | iOS Simulator | 0/3 | 47.67 [47.67-47.67] pt (first frame row is on screen) | blank-list frames [0, 0, 0], frames before host [1, 1, 1] | 6 / 344 / 596 |
| lazy | id | slide | iOS Simulator | 0/3 | 1120 [1120-1126] jump frames | worst error 5824.0 [5824.0-5824.0] pt, re-centres [3, 3, 3], compared [1212, 1215, 1213] | 9 / 406 / 658 |
| lazy | id | heldkey | iOS Simulator | 3/3 | container +14 [14-14] (re-centres: 14 [14-14]) | hitches/10s 0.60 [0.00-0.89], rows/move 1.13 [1.13-1.13], marks/move 2.98 [2.98-2.98], turn p95 ms 2.72 [2.61-3.07], call p95 ms 0.14 [0.14-0.26] | 7 / 20 / 7 |
| lazy | id | heldkey-still | iOS Simulator | 3/3 | container +0 [0-0] | hitches/10s 0.00 [0.00-0.00], rows/move 0.00 [0.00-0.00], marks/move 2.00 [2.00-2.00], turn p95 ms 0.76 [0.74-0.78], call p95 ms 0.13 [0.13-0.17] | 11 / 10 / 8 |
| lazy | id | idle | iOS Simulator | 3/3 | bodies +0 [0-0] | cpu s/20 s 0.17 [0.16-0.19] | 9 / 8 / 5 |
| lazy | positionY | prepend | iOS Simulator | 0/3 | 192.00 [192.00-192.00] pt | frames displaced/insert (worst rep): [1, 1, 1] | 9 / 9 / 456 |
| lazy | positionY | rebuild | iOS Simulator | 3/3 | 0.33 [0.33-0.33] pt (first frame row is on screen) | blank-list frames [0, 0, 0], frames before host [1, 1, 1] | 5 / 442 / 627 |
| lazy | positionY | slide | iOS Simulator | 0/3 | 1180 [1178-1182] jump frames | worst error 1633.0 [1441.0-1633.0] pt, re-centres [3, 3, 3], compared [1218, 1217, 1219] | 12 / 431 / 660 |
| lazy | positionY | heldkey | iOS Simulator | 3/3 | container +14 [14-14] (re-centres: 14 [14-14]) | hitches/10s 0.00 [0.00-0.15], rows/move 1.07 [1.07-1.07], marks/move 3.07 [3.07-3.07], turn p95 ms 1.77 [1.70-1.83], call p95 ms 0.12 [0.12-0.13] | 8 / 44 / 7 |
| lazy | positionY | heldkey-still | iOS Simulator | 3/3 | container +0 [0-0] | hitches/10s 0.00 [0.00-0.00], rows/move 0.00 [0.00-0.00], marks/move 2.00 [2.00-2.00], turn p95 ms 0.79 [0.74-0.85], call p95 ms 0.15 [0.13-0.22] | 12 / 9 / 8 |
| lazy | positionY | idle | iOS Simulator | 3/3 | bodies +0 [0-0] | cpu s/20 s 0.17 [0.16-0.18] | 11 / 10 / 5 |
| list | reader | prepend | iOS Simulator | 0/3 | 156.00 [156.00-156.00] pt | frames displaced/insert (worst rep): [119, 119, 119] | 10 / 9 / 384 |
| list | reader | rebuild | iOS Simulator | 0/3 | -1.00 [-1.00--1.00] pt (first frame row is on screen) | blank-list frames [55, 54, 54], frames before host [1, 1, 1] | 5 / 380 / 589 |
| list | reader | slide | iOS Simulator | 0/3 | 7 [7-7] jump frames | worst error 1212.0 [1212.0-1212.0] pt, re-centres [3, 3, 3], compared [1210, 1212, 1213] | 7 / 404 / 628 |
| list | reader | heldkey | iOS Simulator | 3/3 | container +14 [14-14] (re-centres: 14 [14-14]) | hitches/10s 1.04 [1.04-1.04], rows/move 1.05 [1.05-1.05], marks/move 3.11 [3.11-3.11], turn p95 ms 0.90 [0.83-1.09], call p95 ms 0.40 [0.39-0.48] | 10 / 95 / 7 |
| list | reader | heldkey-still | iOS Simulator | 3/3 | container +0 [0-0] | hitches/10s 0.00 [0.00-0.00], rows/move 0.00 [0.00-0.00], marks/move 2.00 [2.00-2.00], turn p95 ms 0.69 [0.58-0.75], call p95 ms 0.21 [0.14-0.21] | 15 / 11 / 8 |
| list | reader | idle | iOS Simulator | 3/3 | bodies +0 [0-0] | cpu s/20 s 0.17 [0.15-0.18] | 6 / 11 / 6 |
| native | - | prepend | iOS Simulator | 3/3 | 0.00 [0.00-0.00] pt | frames displaced/insert (worst rep): [0, 0, 0] | 6 / 9 / 437 |
| native | - | rebuild | iOS Simulator | 3/3 | 0.33 [0.33-0.33] pt (first frame row is on screen) | blank-list frames [0, 0, 0], frames before host [1, 1, 1] | 7 / 255 / 574 |
| native | - | slide | iOS Simulator | 3/3 | 0 [0-0] jump frames | worst error 0.0 [0.0-0.0] pt, re-centres [3, 3, 3], compared [1215, 1212, 1214] | 6 / 242 / 632 |
| native | - | heldkey | iOS Simulator | 3/3 | container +0 [0-0] (re-centres: 14 [14-14]) | hitches/10s 0.30 [0.15-0.60], rows/move 1.08 [1.08-1.08], marks/move 3.12 [3.12-3.12], turn p95 ms 7.19 [7.10-7.26], call p95 ms 7.13 [7.00-7.16] | 12 / 10 / 8 |
| native | - | heldkey-still | iOS Simulator | 3/3 | container +0 [0-0] | hitches/10s 0.00 [0.00-0.95], rows/move 0.00 [0.00-0.00], marks/move 2.00 [2.00-2.00], turn p95 ms 0.81 [0.73-0.82], call p95 ms 0.32 [0.30-0.33] | 8 / 12 / 8 |
| native | - | idle | iOS Simulator | 3/3 | bodies +0 [0-0] | cpu s/20 s 0.17 [0.16-0.19] | 7 / 12 / 7 |

Reading the rows: `prepend` is the worst shift of the marked row in points over 10 inserts; `rebuild` is the marked row's
distance from where it was on the first frame it is on screen (-1 = never came back inside the second; "blank-list frames" =
frames showing the list without the row); `slide` is the number of frames off the expected position (strict), with the largest
error and how many frames it was compared over; `heldkey` shows the container's evaluations (and the window re-centres that
account for them), then hitches per 10 s, row bodies per move (about 1 is the one newly scrolled-in row), mark bodies per move
(2 = the two highlight leaves, plus about 1 for the new row), the main-thread turn time per move and the synchronous part of it.

**Mac: not run.** Every row above has a Mac counterpart that is still to be measured (section 6 lists them and the command); the partial
prepend results taken before the stop are in section 6.

### 2.2 Every SwiftUI variant (1 run each; positional numbers are deterministic, compare with the 3-run rows above)

These came from the development sweeps (some on earlier builds of the same harness; the two `slide` readers for `lazy` before the
keep-visible change did not change the verdict). `none` = nothing compensates; `positionY` / `positionID` = `ScrollPosition` as
`@State` with `scrollTo(y:)` / `scrollTo(id:anchor:)` in the same transaction as the data change; `reader` = `ScrollViewReader`
proxy, `scrollTo(id, anchor:)` from `.onChange` of the rows (during SwiftUI's update); `readerNow` = the same call synchronously
right after publishing; `readerAsync` = one run-loop turn later; `anchor` = `.defaultScrollAnchor(.bottom, for: .sizeChanges)`;
`id` = `.scrollPosition(id:)` with the top id in `@State` and `scrollTargetLayout`; `idBox` = the same with a plain reference as
the binding.

| host | variant | scenario | platform | pass | deciding number: median [range] | other numbers | load (1-min avg at launch, run 1 / 2 / 3) |
|---|---|---|---|---|---|---|---|
| lazy | anchor | prepend | iOS Simulator | 0/1 | 192.00 pt | frames displaced/insert (worst rep): [120] | 8 |
| lazy | idBox | prepend | iOS Simulator | 0/1 | 192.00 pt | frames displaced/insert (worst rep): [120] | 8 |
| lazy | none | prepend | iOS Simulator | 0/1 | 192.00 pt | frames displaced/insert (worst rep): [120] | 12 |
| lazy | positionID | prepend | iOS Simulator | 0/1 | 192.00 pt | frames displaced/insert (worst rep): [120] | 19 |
| lazy | positionID | rebuild | iOS Simulator | 0/1 | -1.00 pt (first frame row is on screen) | blank-list frames [59], frames before host [1] | 27 |
| lazy | positionID | slide | iOS Simulator | 0/1 | 6 jump frames | worst error 64.0 pt, re-centres [3], compared [31] | 32 |
| lazy | reader | prepend | iOS Simulator | 0/1 | 192.00 pt | frames displaced/insert (worst rep): [1] | 15 |
| lazy | reader | rebuild | iOS Simulator | 0/1 | 1.67 pt (first frame row is on screen) | blank-list frames [0], frames before host [1] | 26 |
| lazy | reader | slide | iOS Simulator | 0/1 | 1179 jump frames | worst error 1505.0 pt, re-centres [3], compared [1216] | 6 |
| lazy | readerAsync | prepend | iOS Simulator | 0/1 | 192.00 pt | frames displaced/insert (worst rep): [120] | 11 |
| lazy | readerAsync | rebuild | iOS Simulator | 0/1 | 1.67 pt (first frame row is on screen) | blank-list frames [0], frames before host [1] | 34 |
| lazy | readerAsync | slide | iOS Simulator | 0/1 | 1173 jump frames | worst error 1569.0 pt, re-centres [3], compared [1214] | 7 |
| lazy | readerNow | prepend | iOS Simulator | 0/1 | 192.00 pt | frames displaced/insert (worst rep): [120] | 14 |
| lazy | readerNow | rebuild | iOS Simulator | 0/1 | 1.67 pt (first frame row is on screen) | blank-list frames [0], frames before host [1] | 28 |
| lazy | readerNow | slide | iOS Simulator | 0/1 | 1174 jump frames | worst error 1313.0 pt, re-centres [3], compared [1215] | 19 |
| list | id | prepend | iOS Simulator | 0/1 | marked row never reached the screen (this API cannot scroll the host) |  | 13 |
| list | idBox | prepend | iOS Simulator | 0/1 | 192.00 pt | frames displaced/insert (worst rep): [119] | 11 |
| list | none | prepend | iOS Simulator | 0/1 | 192.00 pt | frames displaced/insert (worst rep): [119] | 23 |
| list | positionID | prepend | iOS Simulator | 0/1 | marked row never reached the screen (this API cannot scroll the host) |  | 6 |
| list | readerAsync | prepend | iOS Simulator | 0/1 | 192.00 pt | frames displaced/insert (worst rep): [119] | 41 |
| list | readerAsync | rebuild | iOS Simulator | 0/1 | -1.00 pt (first frame row is on screen) | blank-list frames [54], frames before host [1] | 23 |
| list | readerAsync | slide | iOS Simulator | 0/1 | 8 jump frames | worst error 1534.0 pt, re-centres [3], compared [1205] | 7 |
| list | readerNow | prepend | iOS Simulator | 0/1 | 192.00 pt | frames displaced/insert (worst rep): [119] | 43 |
| list | readerNow | rebuild | iOS Simulator | 0/1 | -1.00 pt (first frame row is on screen) | blank-list frames [54], frames before host [1] | 9 |
| list | readerNow | slide | iOS Simulator | 0/1 | 8 jump frames | worst error 1212.0 pt, re-centres [3], compared [1200] | 10 |

Notes on rows that read oddly. `positionID` and `id` on `List`: nothing moves the list, so the marked row never reached the screen and
there was no baseline (a failure, not a "0"). `lazy positionID` `slide` compared only 31 frames: the cursor row left the screen
because the id-anchored scroll did not follow the cursor. `lazy positionID` `rebuild`: the row never came back. `reader` on `lazy`
`rebuild` misses the 1 pt line by 0.7 pt (the anchor-based fraction is slightly off). The loads in this table are 1-minute averages at
launch and only matter for timing, which this table does not report.

### 2.3 Swipes and scrolling (XCUITest, real touches, `results/uitest-*.txt`)

| host | 20 full trailing swipes | 20 full leading swipes | 10 vertical drags starting on a row scrolled | swipe actions fired by the drags |
|---|---|---|---|---|
| native (`UICollectionLayoutListConfiguration` swipe actions) | 20/20 | 20/20 | 10/10 (250 pt each) | 0 |
| SwiftUI `List` (`.swipeActions`) | 20/20 | 20/20 | 10/10 | 0 |
| `LazyVStack`, no gesture | not possible: `.swipeActions` exists only in `List` | | 10/10 | 0 |
| `LazyVStack`, `.gesture(DragGesture(minimumDistance: 24))` swipe | 20/20 | 20/20 | 10/10 | 0 |
| `LazyVStack`, `.simultaneousGesture(DragGesture(...))` swipe | 20/20 | 20/20 | 10/10 | 0 |

The app's own earlier measurement (a simultaneous drag gesture on a row moved the enclosing scroll view 0 pt) **did not
reproduce in this form**: a drag gesture with only `.onEnded`, `minimumDistance: 24`, on a `LazyVStack` row, drag started by
`XCUICoordinate.press(thenDragTo:)`, iOS 26.5. That is not a disproof: the app's measured gesture was a drag-to-scrub with
`onChanged` and `minimumDistance: 4` on a different view. And a hand-built swipe is no substitute for the system's (no revealed
buttons, no commit haptic, no full-swipe affordance, no accessibility action), so O3 / 6.1.6 stand either way. What the
test does show is that the native host's system swipe actions and `List`'s `.swipeActions` both work and never block scrolling.

## 3. Why each SwiftUI host failed, frame by frame, and what was tried

Every number below is from the files in `results/ios/` (and `results/ios-drag-emulation/` where stated).

### 3.1 SwiftUI `List`

What it is here: `UpdateCoalescingCollectionView`, a `UICollectionView` list. Two things decide everything:
1. **Rows are self-sized from an estimate.** The list layout (the same machinery the native host uses; I measured it there:
   `contentSize` 20,944 pt for 400 rows of which 13 had been drawn, undrawn rows 52 pt, drawn rows 64 pt, `contentSize` growing
   as rows are drawn) does not know that every row is 64 pt, so a content offset is not "row x 64". `defaultMinListRowHeight`
   is set and changes nothing. Any code that turns an offset into a row, or a row into an offset, is wrong until the rows
   have been drawn.
2. **`ScrollPosition` does nothing on `List`.** `.scrollPosition($position)` with `scrollTo(y:)` and with `scrollTo(id:anchor:)`
   left the offset at 0 on iOS 26.5 (`positionID` rows in 2.2: the marked row never reached the screen). The Mac probe before the
   stop showed the same on macOS 26's `List` (an `NSOutlineView`, `SwiftUIOutlineListView`; offset stayed 0, and its undrawn rows are
   estimated at 24 pt against 32 pt drawn). `.scrollPosition(id:)` did nothing either (`id`, `idBox`). The iOS 26 `ScrollPosition.x`/`.y`
   getters were not tried as a way to read the offset: nothing moved when written, and a read would be in the same estimated space.
   The only thing that scrolls a `List` is the reader's `scrollTo(id, anchor:)`.

*prepend.* Frame of the insert: the marked row is where it was (frame 0). Frame 1: it is **192 pt** lower, and stays there for
the whole 2 s (118-119 frames) with `none`, `readerNow`, `readerAsync`. With `reader` (the compensation called from `.onChange`) the
scroll offset moves 2,756 -> 2,792 pt (+36) and the row ends **156 pt** off, permanently, ten times out of ten: `scrollTo(id)` is
resolved against the estimated layout (3 x 52 = 156). `readerNow` (before SwiftUI has seen the rows) does nothing; `readerAsync` does nothing.

*rebuild.* The host can only read its position back as a content offset (`onScrollGeometryChange`); in the estimated space that
maps to the wrong row: it stamped row 116 + 48 pt where the list was at row 137 + 24 pt, restored there, and the marked row
was never on screen again within the second: the list was on screen for 54-55 frames without it, the "blank list followed by
rows" case, but with the wrong rows. (A first version of the harness that stamped from the app's own memory of where it had put
the list, and positioned to an exact row boundary, restored with 0.0 pt and no blank frames through `scrollTo(id)` in `onAppear`:
`results/ios-sweep2.log`, first four lines. `List` can restore a row-aligned position it was *told*; it cannot be *asked* where it
is, and it cannot be placed at a fractional offset: the anchor fraction is not honoured.)

*slide.* Keeping the cursor visible works, and better than in `LazyVStack`: `scrollTo(id, anchor: .bottom/.top)` is applied in the
same frame as the move (0 late frames). Each of the 3 re-centres then shows the cursor row **1,212 pt** away for a frame, a
second frame at -1,076 and a third at -136: 7 jump frames per run, ending 136 pt off.

*heldkey / idle.* Container +14 = the 14 re-centres, 0 per move; 1.05 row bodies and 3.11 mark bodies per move (the new row plus
the two leaves); about 1 hitch per 10 s (frames of 68-75 ms at the re-centres); 16.7-17.2 s of CPU in the 67 s run (native: 13.0-13.1 s).
Idle flat. Swipes and drags fine.

Nothing idiomatic fixed it. The things not tried: tracking the first visible row with per-row `onAppear` (it cannot give the
fraction), and reading the underlying `UICollectionView` (which is the native host with extra steps).

### 3.2 `LazyVStack` in a `ScrollView`

Here row heights are exact (offsets read 8,791.67 for 137 rows + 23.68 pt) and `ScrollPosition(y:)` works, including fractions.
The failure is timing, and one mechanism that works only partly.
- **`positionY`** (the natural way). *prepend:* on the frame of the insert the content is already 3 rows lower and the offset still
  reads 3,200; on the next frame it reads 3,392 and the row is back: **one frame displaced by 192 pt on every one of 30 inserts**
  (16.7 ms; the Mac partial runs show the same at 120 Hz with 96 pt). It is a visible flash, not a measurement artefact: the
  scroll view's own offset and the SwiftUI probe agree. *rebuild:* passes (0.33 pt, the whole-point stamp's rounding; no blank frames).
  *slide:* every move's scroll lands one frame after the cursor move (about 585 frames per run), so the cursor row sits 64 pt off
  for a frame on every move; and at each re-centre the content jumps 993-1,633 pt for one frame before the compensation arrives (6
  jump frames per run, `realJumpsAfterLagAllowance`).
- **`reader`, `readerAsync`**: the same one frame late; **`readerNow`, `none`, `anchor`, `idBox`**: no compensation at all
  (192 pt for the whole 2 s). `.defaultScrollAnchor(.bottom, for: .sizeChanges)` does not hold rows when rows are added above.
- **`id`** (`.scrollPosition(id:)` with the top id in `@State`, the binding the position): the only SwiftUI mechanism that holds a
  row through an insert above: **0.00 pt, 0 displaced frames, 30 of 30** (the offset moves 3,200 -> 3,392 on the very frame of the
  insert). It fails elsewhere: whole rows only, so the fractional restore is **47.7 pt** off; at each re-centre the content moves
  by the 101 removed rows (-6,464 pt) for a frame; scroll still lands a frame late (1,120 jump frames). *Caveat on the pass:* it
  holds the **bound** id. When I positioned the list with a platform-level scroll (as a finger would, but not a real touch) instead
  of through the binding, the marked row ended 64 pt off, because the binding still named the row above it
  (`results/ios-drag-emulation/`, 1 run). Whether SwiftUI's own drag tracking keeps the binding current under a real finger could not
  be tested in the simulator from inside the app; see section 5.
- Cost of the state-based variants: none per move. `@State` `ScrollPosition` and top id are only passed as bindings, never read in the
  body, so writing them re-evaluates nothing (container +14 = re-centres, as for `List`).

### 3.3 What no SwiftUI host could do
Hold a row while rows are *removed above the viewport* (the re-centre), in the same frame, and be asked where it is. `List` cannot be
told a fraction and cannot say where it is; `LazyVStack` can do both but applies every programmatic scroll a frame after the data change.

## 4. What the passing host cost, and what to write into the design

**Size.** `Sources/NativeHost_iOS.swift` is 205 lines (about 35 are comments and a debug dump); `Sources/NativeHost_macOS.swift` is 160. The
row (`Row.swift`, 80 lines) and the model are shared with the SwiftUI hosts unchanged. The cell is `UICollectionViewListCell` with
`UIHostingConfiguration { MailRow(...).equatable() }`: no hosting controller, no `AnyView`.

**What was awkward, and was in no document.**
1. **The list layout's row heights are estimates** (52 pt undrawn, 64 pt drawn). Absolute offsets are not row multiples
   (`contentSize` grows 20,944 -> 21,400 as rows are drawn). The host therefore keeps positions as *(row key, points into the row)*
   everywhere (anchor before a window change, re-assert after it; restore stamp), places with `layoutAttributesForItem` and re-asserts
   once after a layout pass, and never multiplies. A `FixedHeightCell` that answers `preferredLayoutAttributesFitting` with 64 pt
   spares measuring the SwiftUI content but does not remove the estimate. "Fixed row height" in 6.1.8 is a visual fact, not a layout
   fact.
2. **The window change must be applied inside the model's publish**, before any frame: the host subscribes to `@Published rows`
   (whose sink runs before the value is stored, on the main thread, synchronously), applies a diffable snapshot with
   `animatingDifferences: false`, and the model calls `restoreAnchor` right after. That is what makes 0.00 pt possible; an
   asynchronous apply would be the one-frame lag of the SwiftUI hosts.
3. **First-frame restore** needs a hook in the collection view's first layout pass that has a size (`RestoringCollectionView.layoutSubviews`
   sets the offset and lays out again). Before it, the host is created with zero size and the offset cannot be set.
4. **The native host does not re-evaluate its container on rows changing**: it subscribes itself, so `Counters.container` is 0 for the whole
   held-key run (14 window changes included). The SwiftUI hosts re-evaluate once per re-centre. For the design's `mail.list.renderCount`
   probe this means the wrapper's body and `updateUIView` are what is counted, and "+0 while `J` is held" is easy to meet.
5. **SwiftUI-side geometry inside a hosted row is not a source of truth while scrolling**: `onGeometryChange` in a hosting cell does not
   update when UIKit moves the cell. Anything that depends on position ("is the first row on screen", T9) must come from
   `scrollViewDidScroll` / `UIScrollView`, never from a SwiftUI geometry callback in a row.
6. **Cost per move.** Held key: main-thread turn per move median 5.6-5.7 ms, p95 7.1-7.3 ms (the new cell's realisation and layout, done
   synchronously inside the move), against 0.6-2.2 ms (p95 0.8-3.1 ms) for the SwiftUI hosts, which defer that work to turns this metric does not see.
   Whole-run CPU is the fair comparison: native 13.0-13.1 s per 67 s run, `lazy` 14.5-15.0 s, `list` 16.7-17.2 s. At 120 Hz a 7 ms p95
   turn fits inside one 8.3 ms frame with little room on a slower CPU than this Mac's; that is the number a device must confirm (section 5).
7. **Not built, only expected:** selection (`didSelectItemAt` plus the app's own cursor), context menus
   (`contextMenuConfigurationForItemAt`), accessibility (SwiftUI identifiers inside hosting configurations did appear to XCUITest as elements:
   the swipe test found rows by `row-<id>`; VoiceOver was not exercised), Mac swipe actions
   (`tableView(_:rowActionsForRow:edge:)`), Mac quirks seen while writing it: `NSHostingView.sizingOptions = []`, rows via `removeRows`/
   `insertRows` from a `CollectionDifference`, `NSOutlineView` for SwiftUI's own `List`.

**Rules the design should say because of it.**
- 6.1.8: replace "The list is a `List`" with "the list is a collection view (`UICollectionLayoutListConfiguration`, system swipe actions) on iOS
  and iPadOS and an `NSTableView` on the Mac, rows hosted SwiftUI". The leaf-observable rule (`MailRowMark`) and `Equatable` rows stand unchanged.
- T9, T11, T26, 8.4 and G5: a list position is *(row key, whole points into the row)*. No code multiplies a row number by a height or reads
  a content offset as a row number. The host captures the anchor before a window change and re-asserts it in the same turn.
- 3.10 / X5: the model's window change is applied to the host synchronously with the publish (no `Task`, no `DispatchQueue.async` between).
- Nothing in a hosted row reads its own geometry to decide anything about scrolling (T9's "is the first row on screen" comes from the scroll
  view's delegate).
- Probe wording: `mail.list.renderCount` counts the host wrapper's `body` and `updateUIView`; a window change must not increment it.

## 5. What a Simulator could not measure, and what a device adds

- **Real hitches.** The simulator runs at 60 Hz on this Mac's CPU. A ProMotion iPhone has an 8.3 ms frame and a slower CPU; the p95 7 ms per
  move of the native host must be re-measured there, with `--frame-probe`-style windows. All hitch counts here are simulator counts.
- **A real finger.** The scenarios scroll programmatically or with a platform-level offset change. Momentum scrolling, a flick in progress when
  mail arrives, `scrollPosition(id:)` under a real drag (3.2's caveat), rubber-banding and the swipe's haptic cannot be reproduced; the XCUITest
  is the only real-touch evidence, and covers swipes and drag-from-a-row only.
- **The real background discard** (2.5 s blank after `.background`, the memory pressure and the process state around it), and the
  CPU-limit kill it guards against.
- **Memory and thermal:** footprint of 25 hosting cells, of the 400-row window, of the SwiftUI graphs; sustained held-key thermals.
- **A hardware keyboard:** real key-repeat cadence and latency (30 Hz here is a timer), `UIKeyCommand` repeat, iPad focus.
- **Dynamic Type and accessibility sizes** (rows here are fixed at default size), VoiceOver, Reduce Motion.
- **The real row** (avatars, accessories, async images, account tag): the cost per hosted row is for this small row.
- **The Mac, entirely** (section 6).

## 6. Mac: to run when the owner says go

The app was rebuilt to be safe to run unattended. Before any window exists it sets `NSApp.setActivationPolicy(.accessory)` (and the plist has
`LSUIElement`), never calls `activate`, and creates one borderless `NSPanel` (`.nonactivatingPanel`) whose `canBecomeKey` and `canBecomeMain`
are false, with `collectionBehavior = [.stationary, .ignoresCycle, .fullScreenNone]`, excluded from the Windows menu, `ignoresMouseEvents = true`,
`level = .floating`, fixed 380x520 pt in the bottom-right corner of the main screen's visible frame, ordered front with `orderFrontRegardless()`
(not `activate`). `--mac-window x,y,w,h` overrides the frame (AppKit coordinates: y from the bottom of the screen; the `MAC_WINDOW` environment
variable passes it through the scripts). `tools/run-mac.sh` launches it with `open -g -n ... --args ...` and waits for the result file.
**None of this has been launched since it was written**: it compiles in Release, and the first real run may need a fix. Smoke test first (30 s,
a small panel in the corner, nothing else): `tools/run-mac.sh native - idle 0`.

The window must be on screen and uncovered while a scenario runs (a covered window gets no display-link callbacks). The whole matrix, one command:

```
cd /private/tmp/claude-501/-Users-owner-orca-workspaces-gtfuwgth-stingray/a2258f59-13ec-4139-b1e4-fd8203198777/scratchpad/prototypes/p1-list && tools/build-mac.sh && tools/run-mac-matrix.sh
```

It takes about **70 minutes** (4 host variants x 3 runs x about 4 minutes of scenarios, plus a one-run sweep of all variants for prepend, rebuild
and slide, about 25 minutes), one panel at a time. It waits for the load average to fall under 12 (up to 10 minutes) before each run, and puts the
load in every file. Summarise with `tools/aggregate.py mac --md`. The Mac host variants are the ones the iPhone sweep singled out
(native, `List` `reader`, `LazyVStack` `positionY` and `id`).

**Partial Mac results from before the stop** (`results/mac-partial/`, prepend only, 10 inserts each, a regular window, load average 350-700 so
**positional numbers only**; the trackpad scrolled the window once during the first native attempt, which was discarded, the second is the one
listed):

| host | variant | run | worst shift | frames displaced per insert |
|---|---|---|---|---|
| native `NSTableView` | - | 1 | **0 pt** (10 of 10 pass) | 0 |
| `LazyVStack` | `ScrollPosition` y | 1 | 96 pt | 1 (8.3 ms at 120 Hz), 10/10 |
| `LazyVStack` | `reader` | 1 | 96 pt | 1 (9/10; once 0) |
| `LazyVStack` | `readerAsync` | 1 | 96 pt | 1 (first rep: no baseline) |
| `LazyVStack` | `readerNow`, `none`, `anchor` | 1 | 96 pt | all 240 frames |
| `LazyVStack` | `id` | 1 | **0 pt** (10 of 10 pass) | 0 |
| `List` | `ScrollPosition` y | 1 | not valid: the list never scrolled, so nothing was positioned | - |

The Mac `List` observations in 3.1 (offset stayed 0; rows estimated at 24 pt; `scrollTo(id)` landing ~216 pt off for row 50) came from a debug probe whose console output was not saved. Mac `List` was not run again with the reader variants. Frame timing, rebuild and slide on the Mac: **not run**. The whole Mac column of every
scenario in 2.1 remains to be run.

## 7. Recommendation

Build the inbox on a `UICollectionView` list layout hosting SwiftUI rows through `UIHostingConfiguration` on iPhone and iPad, and on an `NSTableView`
with hosting cells on the Mac (not yet measured), keeping every position as (row key, whole points) and applying each window change synchronously
with the model's publish. Do not use SwiftUI `List` (it fails prepend, rebuild and slide in every variant) or `LazyVStack` (one frame late on every
programmatic scroll, whole rows only with the id binding) for this screen, and gate the Mac host on its own run of the same scenarios.

## Files

- `Sources/NativeHost_iOS.swift` (the passing host), `Sources/NativeHost_macOS.swift`, `Sources/SwiftUIHosts.swift` (`List` and `LazyVStack` with every
  variant), `Sources/Row.swift`, `Sources/Model.swift`, `Sources/Scenarios.swift`, `Sources/Instruments.swift`, `Sources/Fixture.swift`.
- `UITests/SwipeUITests.swift`; `project.yml` (xcodegen).
- `tools/`: `build-ios.sh`, `build-mac.sh`, `run-ios.sh`, `run-mac.sh`, `matrix-ios.sh`, `run-mac-matrix.sh`, `sweep-ios.sh`, `aggregate.py` (the tables above), `brief.py` / `show.py` (one-line and per-rep views of a result file).
- `results/ios/*.json` (every run), `results/ios-loaded-timing/` (timing runs repeated because the first copies were taken at high load, kept for the
  record), `results/ios-drag-emulation/`, `results/mac-partial/`, `results/uitest-*.txt`, and the sweep logs.
