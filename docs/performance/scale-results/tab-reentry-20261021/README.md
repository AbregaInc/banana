# Plan and Notes tab return — October 21

Build 67 gives the phone's Day/Week switch its own row, uses native Calendar search,
and keeps overdue reminders in their existing completion/edit row. Needs attention
covers routines, meals and doses, so it no longer repeats those reminders.

The calendar retains one prepared input for its current planning window. Data,
range, calendar/timezone and midnight changes invalidate it. Notes retains its
shown page keyed by repository revision, search, archive filter and page offset;
canceled or failed loads never become a valid cached page. Reuse also clears stale
loading/error presentation. These are bounded view-owned working sets, not new
history limits. Allocation/RSS overhead and memory-pressure recovery are unmeasured.
An appearance refresh within 45 seconds reuses the prior calendar read; explicit
refresh, navigation, settings and live data updates remain separate refresh paths.
Provider traffic reduction for that appearance policy has not been measured.

## Controlled comparison

`PlanHeaderUITest.testTabReturnReusesCalendarPreparationAndNotesPage` launches the
same binary with and without `--calendar-reprepare-on-appear` and
`--notes-reload-on-appear`, warms Plan and Notes, then makes two return visits to
each. `--tab-reentry-probe` samples counters in an isolated subtree. Fixtures use
sample data, disable provider services, and retain the normal tab shell.

| Work across two return visits | Reference | Reuse |
| --- | ---: | ---: |
| Calendar day preparations | 2 | 0 |
| Notes page loads | 2 | 0 |
| Calendar body evaluations | 4 | 4 |
| Notes body evaluations | 14 | 12 |
| Automation wall time, ms | 28,070 | 17,252 |

This establishes skipped preparation/query work. Calendar body evaluations did
not decrease. Automation includes XCTest/AX overhead and competing host work;
it is not input-to-visible latency, frame work or a calibrated speed comparison.
Cold initial loading is exercised before warming. Eviction and physical frame/input
acceptance remain unmeasured. No persistent baseline or budget was changed.

## Correctness and retained results

iPhone 17 Pro Simulator / iOS 27.0, Xcode 27.1. All eight targeted cases pass across
the final source run and focused control rerun: header/search presentation,
controlled tab reuse, Day/Week switching, reminders, routine completion/Undo and
relaunch persistence, Calendar search entry/Return/clear/dismissal, Notes paging,
and calendar date paging. Native search's focused presentation exposes Close
(on earlier iOS, Cancel) before the sheet's Done; tests exercise that transition.
Restored SwiftUI list rows can change accessibility role, so completion is located
by its exact accessible label across roles.

All raw xcresults, summaries, attachments, logs and the unsuccessful performance
runner invocation are retained under `~/Library/Logs/Banana/Build67-Review/`.

- `phone-20261021-132718.xcresult`: 4 pass / 2 fail; isolated Plan preview's redundant
  navigation stack hid its toolbar. The debug route now uses the calendar's stack.
- `phone-20261021-133446.xcresult`: 6 pass / 2 fail; native search dismissal and
  Undo-restored row queries needed native control/role handling.
- `phone-20261021-134715.xcresult`: both focused cases pass after those test fixes.

The persistent component runner reports **unmeasured**: the checked-in reference
uses Xcode 27.0; this machine has 27.1. It was not replaced or loosened. Calendar
query URL correctness checks pass independently. Host native-window tests and
physical 120 Hz acceptance remain open; these Simulator results do not close them.
This change performs no TestFlight/App Store upload; the full release regression
and existing store submission checklist remain separate gates.

Sample screenshots: [Plan](../../../../Mockups/CalendarSettings/plan-header.png),
[Search](../../../../Mockups/CalendarSettings/calendar-search.png).

## Local rollout and worktree recovery

Build 67 main and Beta apps are installed and independently version-checked on
Mac, iPhone and iPad. Signed main products pass the unreleased-module check;
Beta products retain Gmail endpoints and the unreleased marker. The Watch was
unavailable for direct installation. No TestFlight/App Store upload was performed.

The former email workspace's complete working tree matches merged snapshot
`e4f4ca9c71a81e1f43a93dd83acaf8a577215bf6` exactly (tree
`4ec443c00cd0c42fb7be2615c3d46555b339d6ca`). The snapshot is reachable through
`integration/email-working-20261021` and this branch's history. Its ignored test
results/traces, loose evidence and products from all three `.keep-build` folders
are preserved under `~/Library/Logs/Banana/ArchivedEmailWorktree-20261021/` before
the user-authorized workspace removal. Other workspaces are outside that removal.
