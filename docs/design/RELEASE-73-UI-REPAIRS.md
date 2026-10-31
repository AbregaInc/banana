# Build 73 UI checks

The initial full run was stopped after 22 passes, eight failing cases and two
cancellations. Raw results, worker logs and the stop reason are retained privately
under `~/Library/Logs/Banana/RecentMeals-20261022/`. Nothing was uploaded.

One failure exposed a real food entry routing error in WideNutritionView: the global
By hand and Describe actions both opened food search. They now open the corresponding
existing capture modes. AddButtonRowUITest checks the actual blank food-name field
and phrase editor, including the Recent meals shortcut in Describe.

Plan's List was removed in commit `462fbb35` on October 8. Seven remaining tests tried
to select that nonexistent third mode: AgendaEarlyEventIdentity,
PreparedAgendaEarlyEventIdentity, PreparedArtworkAgendaGridScroll,
DenseAgendaGridScroll, UngroupedAgendaGridScroll, GroupedAgendaGridScroll and
GroupedPreparedArtworkAgendaGridScroll. Their historical results remain historical;
they cannot measure a current user interface. Two replacement UI cases launch the
real populated planner with saved `planMode=list` and old `mobileWeekLayout=agenda`
preferences, require Day and its native viewport, and open an actual fixture event.
Current Day/Week workloads, timing limits and performance baselines are unchanged.

Reference Day uses an unnamed UIScrollView, not the retired SwiftUI parent identifier.
The old duplicate-label negative control is also obsolete: `7d3733519` made the outer
cell ignore child accessibility, so the inner-artwork legacy flag no longer reproduces
three announcements, even in the reference viewport. Its replacement retains both
reference flags and requires a single announcement for short and tall events. It is a
current correctness check, not a frozen historical performance control.

The stress launcher also appended its default Calendar layout after an explicitly
requested legacy Agenda preference. It now supplies that default only when absent,
so the migration check actually exercises the saved legacy layout.

Onboarding now includes the explicitly requested Email module. The copy check requires
one status-bearing Email row and keeps the original nine-element allowance for the
rest of the welcome. The wind-down check scrolls to the real virtualized routine and
accepts the clock's compact 10 PM format while still requiring the selected time.

Fresh targeted and full results must be recorded before TestFlight publication.
Simulator correctness does not establish physical frame or input latency acceptance.

The subsequent full run also exposed old editor names and a standalone calorie-text
selector. Creation checks use the current New event sheet and stable event.title
identifier; the Food overview checks the actual saved 800 kcal meal row. A More-to-Add
transition waits for menu dismissal rather than assuming its animation has finished.

The exclusive-drag policy is explicitly documented as a negative control in
`docs/performance/scale-results/calendar-native-drag-20261010/README.md`. Its test now
requires the blocked move and a recorded gesture-prevention audit, unchanged event
position, and no accidental detail opening. Production cooperative movement still
must reach failure routing and rollback. No production gesture policy or timing
limit is changed by these test repairs.

The completed full run (phone-20261022-141350.xcresult) recorded 210 passes,
30 failures and 23 skips. Its original bundle, summary and recordings are retained.
The release remains held until the failed scenarios and affected production paths
pass again on the final source.

Three production parity corrections are under verification: the native grid applies
the existing outstanding-reminder exclusion before allocating lanes (including its
cached-layout path), supplies actual lane width to task-circle layout, and preserves
the selected weekday when paging weeks. The short-event failure was an incorrect
one-dimensional overlap assertion: its recording shows two blocks in separate lanes.
The test now checks rectangle intersection.

Mail's forty-Done journey retains all forty swipes and Undo. Its row enumeration
reads one immutable list snapshot instead of resolving every identifier and frame
repeatedly during animation. Writing smoke coverage retains all twenty states and
both iPad orientations, split across four bounded tests; readiness replaces the
old guessed delay. No execution allowance or production performance threshold changes.
The original Mail timeout activity trees are retained privately. The forty-Done test
had performed nineteen swipes, with 506 Find and 329 existence activities, before
its three-minute allowance expired. The writing test had captured seventeen states
and started its eighteenth launch. These observations motivate reducing repeated
automation queries and splitting independent launches, rather than weakening the
forty-message journey or dropping writing states.

The first repair run passed 15 checks and failed three. It proved both reminder
layouts, the narrow task, Skip/Undo, pinch, both swipe behaviors, short-event
non-overlap, Day/Week creation and Week move recovery. The two historical controls
scroll downward with the finger by about 46 points; the incorrect repair expected
one upward and the other stationary. Their next check requires downward ruler
movement relative to the viewport and unchanged event-to-ruler alignment. This
proves whole-grid scrolling rather than an event move or header displacement.
Week navigation's retained audit showed x=244 before paging and x=366 after it:
the selected weekday and the leftmost visible column are distinct state. Paging
now preserves both independently. Those three checks are rerun with the remaining
failed scenarios; no failed result has been discarded.

The next menu check hit an actual main-thread stall, not just a selector failure.
A two-second `sample` of the live Simulator app (pid 20389) showed all 1,522 main
thread samples waiting for a synchronous HealthKit authorization reply, through
MorningBriefingView → refreshIfStale → refresh → noteWriteStanding. The sample is
retained privately as repair-release2-menu-idle-sample.txt. Permission reads now
run on a utility task; refresh coalescing begins before that read, and publishing
still resumes on the main actor. The same read boundary covers workout-save checks.
Slow completed checks log duration only. A blocked fake service test requires the
main actor to remain available, and a second check preserves each actual HealthKit
permission answer. No authorization result is invented, and no Health data is logged.

Remaining test repairs use the current dated Food header (rather than the retired
Yesterday label), Review's Month button without assuming a UIKit identifier on its
SwiftUI wrapper, and the actual Resting HR metric wording. Native menus remove their
underlying buttons from accessibility. The first measured-anchor repair was wrong:
recordings proved it selected Recent meals and Edit note where popup items covered
their anchors. Tests now reuse ControlRulesWalk's already-verified bare-toolbar
point, require menu dismissal, and reject unintended sheets. No calendar create
surface is used for dismissal.

The 20-case Health authorization/reminder/tick/block-height unit run passes, including
the blocked-service regression and all actual HKAuthorizationStatus answers. Recent
meals passes both end-to-end phone checks again on the Health fix. The isolated
--workout fixture does not own a PageChromeHost, so its Review button cannot present
Review; period/rotation coverage now uses the existing --review --dummy-health scene.
The full-run ControlRulesWalk already covers entry from the real Workouts tab.

A Day gesture diagnostic recording showed landscape despite a requested portrait.
The stress launcher now waits for actual window geometry and, if necessary, recovers
a missed Simulator turn through landscape and back; gestures start only in portrait.
The Mail forty-Done check retains all forty unique removals and Undo; it no longer
rechecks an already-removed row through a new accessibility query. Coordinates use
once-measured endpoints with unchanged gesture distance, speed, holds and time limit.

Final validation: every one of the original thirty full-run failures now has a
subsequent passing phone result. The additional Day paging/zoom diagnostic also
passes, so all thirty-one cases that failed during this repair sequence have later
passes. The final iPad calendar run passes 3/3 (both reminder layouts and exact Week
restoration). The Health/calendar unit run passes 20/20; the earlier meal/sync run
passes 94/94. Recent meals passes both phone journeys again and its retained iPad
run passes 2/2. Native and pure shared-calendar tests remain unchanged and passing.
The source-hashed evidence inventory and all raw failed/passed runs are retained in
~/Library/Logs/Banana/RecentMeals-20261022/. This is a full run plus targeted repairs,
not a claim that the entire suite was rerun green, nor physical latency acceptance.
