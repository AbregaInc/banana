# Native Mac calendar overflow and performance — October 9, 2026

Work in progress. The native app **does not meet the performance contract**.

## Baseline

Isolated Release stress preview, 180,000 emails, 36,500 calendar events, 5,000 notes and 20,000 podcast episodes. Calendar warm; visible Mac window; no competing build or benchmark. CUA performed four alternating half-page down/up pairs, four forward-page keys and four backward-page keys. The app remained running throughout the 60-second trace.

`mac-before-summary.json` retains all commit and run-loop samples. Main-thread commit work: 283 samples, p95 39.334 ms, p99 151.933 ms, maximum 166.203 ms. The 8.3 ms commit budget fails. This measures commit work, not input-to-visible latency or display delivery. A main-run-loop interval maximum of 99.818 ms does not excuse the slower commits. Raw Instruments trace and XML remain local in `.build/calendar-overflow/mac-before-trace`; they include process environment metadata.

## Correctness failure

The three-lane display cap omitted all placements with lane >=3, but overflow controls grouped only identical start times. Four staggered overlapping events could therefore hide the fourth without any way to open it. `red.log` reproduces this with the copied old rule in `CalendarOverflowRules-before.swift`.

The new rule groups connected intervals using the lane allocator's one-minute display tolerance, counts actual omitted IDs and preserves all events in each group. A day-header control keeps the hidden events reachable when the group's first hidden event is above the viewport. The popover uses a bounded scroll view with lazy rows.

Initial visible Mac verification recovered all 100 events for the first day, but exposed the pre-existing whole-calendar popover anchor placing the list above the window. A header anchor correction is being verified. Failed build/interaction artifacts remain in `.build/calendar-overflow`; no native performance improvement is claimed yet.

## Corrected UI verification and repeated trace

The header-anchored list is visibly inside the window. The native scrollbar reached event 99; clicking it opened the correct event detail (Thursday, October 8, 4:30–5 PM). Wheel scrolling through CUA did not change the list, so a successful scrollbar action is not being reported as wheel/trackpad verification. That input path still needs a dedicated native check.

The same 60-second paging/scrolling recipe after the correctness fix yielded commit p95 47.761 ms and maximum 161.329 ms (229 samples). Main-run-loop maximum was 102.097 ms. Both traces fail; no rendering improvement is claimed. Two older idle isolated previews remained running in both recordings (observed CPU 0% afterward); no build or other benchmark ran during either recording. Raw after trace remains local at `.build/calendar-overflow/mac-after-trace`.

Apple's [popover API](https://developer.apple.com/documentation/swiftui/view/popover(item:attachmentanchor:arrowedge:content:)) respects the anchor edge on macOS. Moving the anchor to the header and choosing its bottom edge fixed the off-window placement.

## Final control-local presentation check

Overflow presentation now belongs to the button that opened it, including its popover anchor.
Native CUA inspection confirmed it appears beneath that control. Native XCTest
`.build/native-ui-performance/uitests-20261009-004745/ui.xcresult` then passed wheel scrolling
to Stress event 99 and opening it, alongside Mail and normal Plan interaction tests. CUA's
popover wheel route had not moved this list; the actual XCTest wheel succeeds. The later stricter
inspector-specific title assertion still requires a fresh run. See the observation report for
the successful suite summary and the preserved setup/selector failures.
