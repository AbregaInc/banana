+++
title = "We cut initial calendar drawing work by 60% with an AI agent"
description = "100 new events a day, 3,000 retained events: replacing a full-day view tree with reusable cells cut measured drawing and cache work from 95.05 ms to 38.22 ms."
published = 2026-10-28
updated = 2026-10-28
author = "Banana team"
category = "Engineering"
draft = true
# Proposed public URL: /blog/optimizing-calendar-rendering-with-ai/
+++
We’re building Banana, a native planning app that brings Google calendars from multiple accounts into one unified day across iPhone, iPad, and Mac.

**100 new events a day. 3,000 events stored. Preparing the calendar’s event blocks went from 95.05 ms of work to 38.22 ms.**

[Day and Week performance fixtures](calendar-demo.html)

We want to build the smoothest interface we can. Our goal is 120 fps throughout the application, at all times on displays that support it. We know we are not there yet. This calendar work is part of how we get there.

Each event view contains its title, time, icons, and background. We measured the work needed to draw and cache those elements. Our old Day view hosted the full day’s SwiftUI event-view tree inside a `UIScrollView`. We replaced that host with a `UICollectionView` that creates and reuses event cells as they are needed.

The event geometry and block-drawing code stayed the same in this comparison. Building fewer event views reduced the number of blocks we had to prepare.

This came out of an **AI-driven performance hill climb**. We set the calendar workload and performance requirements, then used a coding agent to implement alternatives, run comparisons, investigate failures, and iterate. The agent worked on the renderer and the tests used to judge it.

## Before and after

| | Old Day view | New Day view |
| --- | --- | --- |
| Scroll host | `UIScrollView` | `UICollectionView` |
| Event views | Full day’s SwiftUI event-view tree | Reusable cells requested by the viewport |
| Event placement | Existing calendar geometry | Same geometry |
| Block drawing | Prepared event blocks | Same prepared-block path |
| Measured preparation work | 95.05 ms | 38.22 ms |

The numbers come from an October 10 experiment using the same optimized app binary and a 30-day fixture with 100 new events per day. We alternated old/new/new/old rather than taking one run of each:

| Run | Day view | Blocks drawn | Total preparation work |
| --- | --- | ---: | ---: |
| 1 | Old | 107 | 96.231 ms |
| 2 | New | 45 | 39.168 ms |
| 3 | New | 44 | 37.263 ms |
| 4 | Old | 106 | 93.871 ms |

The two old-path runs average 95.05 ms; the new ones average 38.22 ms. That is a 59.8% reduction. Memory held by the displayed block images fell from about 2.65 MB to 1.11 MB.

Individual blocks did not become faster to draw in this experiment. We reduced the number that needed drawing. The total includes drawing and cache insertion across multiple preparation jobs; it is not a single frame or the elapsed time until the calendar appears. These are historical results from that experiment, not a fresh measurement of today’s build.

## View virtualization and cell recycling

This is **view virtualization**: keep the event data and geometry, but create views only when the viewport needs them. **Cell recycling** lets the scroll container reuse views as events enter and leave the screen.

We split the calendar into event placement, view lifetime, and drawing. The placement rules still handle overlap lanes and event frames. The collection view manages the cells. A cell asks for its SwiftUI content when needed.

A shortened version of the descriptor passed to the viewport is:

```swift
struct CalendarViewportItem {
    let id: String
    let frame: CGRect
    let content: () -> AnyView
}
```

The closure lets us describe an event without constructing its view immediately. On iOS, [UIHostingConfiguration](https://developer.apple.com/documentation/swiftui/uihostingconfiguration) hosts the SwiftUI content inside the reusable UIKit cell. Mac has a separate AppKit `NSCollectionView` host.

[Diagram: how the calendar chooses which event views to build](calendar-viewport.html)

That separation gave the agent smaller changes to test. It could change the scroll host while retaining the placement rules and drawing code, then evaluate drawing changes separately.

It also made the remaining costs easier to name. Our fixed-frame layout still scans cached attributes to find intersecting events. Reusable cells reduce the live view tree; they do not remove placement work or make retained calendar history disappear.

## Libraries and tools we evaluated

We looked at existing calendar components before building our own host:

| Library | What we evaluated | What it meant for this calendar |
| --- | --- | --- |
| [CalendarKit](https://github.com/richardtop/CalendarKit) | Its day timeline, event pool, and overlap layout; pinned in our isolated benchmark | A useful iOS comparator. At the inspected revision, its event-view lifecycle would still need changes, and it did not provide an AppKit host. |
| [KVKCalendar](https://github.com/kvyatkovskys/KVKCalendar) | Its multi-day timeline and custom event-view/layout hooks; also pinned in the benchmark | The closest mobile week-view candidate. Those hooks did not supply the vertical event virtualization we wanted. |
| [HorizonCalendar](https://github.com/airbnb/HorizonCalendar) | Incremental visible-item lookup and view reuse | A useful architecture reference for virtualization. Its date/month grid was not a drop-in hourly event timeline. |

We also source-screened [JZCalendarWeekView](https://github.com/zjfjack/JZCalendarWeekView), which uses reusable collection-view cells, and the native macOS [ScheduleKit](https://github.com/gservera/ScheduleKit). Compatibility, maintenance, and the amount of rendering code we would still own were part of the decision. We reviewed the source, but did not fully benchmark each of these.

The path used for the headline result relies on UIKit/AppKit collection views and SwiftUI cell content. We separately investigated Core Graphics, Core Text, and [Skia with Metal](https://skia.org/docs/) for drawing. The Skia experiments still had visual-parity and cache-correctness failures, so they did not become a new shipping renderer.

For measurement, **XCTest** exercised scrolling, paging, selection, and reuse; **Instruments** supplied Time Profiler and Animation Hitches traces. We used `xctrace` and `simctl` in the collection scripts, plus image comparisons to check rendering changes. Gesture duration, drawing time, and frame delivery stayed separate measurements.

## What the agent had to preserve

Reusing cells introduces lifecycle problems. A drawing job can finish after its cell has been assigned to another event. A cached block can become stale after a title edit, resize, appearance change, or text-size change. That is the **cache invalidation** problem: reuse the drawing only while all of its inputs still match. Cache eviction must leave the current event visible until a replacement is ready.

We kept immutable drawing inputs separate from gestures, accessibility, and pending edits. The cell owns those interactions. The cached drawing does not.

An overnight event adds another complication: one occurrence can have visible pieces in two day columns. We give each displayed piece a day-specific identity while keeping its actions attached to the original occurrence. Otherwise reuse can confuse the two pieces with independent events.

The AI hill climb had to preserve those behaviors while changing performance. We kept reference paths and explicit comparison switches, fixed the workload, and retained failed runs. Raising the performance threshold was not a candidate improvement.

## Hardware behind the numbers

Our build and Simulator machine is a **MacBook Pro with an M1 Max, 10 CPU cores, 32 GPU cores, and 64 GB unified memory**. It is a shared development machine. Other builds can consume the same CPU, memory, and GPU resources, so run order and host activity matter.

The preparation comparison above ran in the **iPhone 17 Pro Simulator on iOS 26.5**, on that Mac. We also tested the calendar on:

| Physical device | Calendar tests |
| --- | --- |
| Spare iPhone 14 Pro, A16, iOS 27.0.1 | Scrolling, paging, cache recovery, renderer experiments, and Instruments captures |
| iPad Pro 12.9-inch, fifth generation, M1, iPadOS 27.0.1 | Scrolling, paging, cache recovery, renderer experiments, and Instruments captures |

The phone and tablet results are separate from the Simulator comparison. We do not use a fast run on the M1 Max as evidence that the same work is fast on an iPhone.

## We are still working toward the frame budget

At 120 fps, there is about 8.3 ms between frames. We also want direct input feedback under 10 ms at p95, with a 20 ms maximum. Saving drawing work gives us more room in that budget. We still need to show that the savings lead to consistently smooth scrolling and interaction on real devices.

The physical traces still show slow tails. In the integrated calendar tests, the iPhone 14 Pro’s Day app-update interval reached 33.686 ms; the iPad’s reached 53.992 ms. Week maxima were 13.327 ms and 77.400 ms respectively. These intervals include more than drawing, and the separate device runs are not a before/after comparison.

We need to keep measuring cold preparation, warm reuse, eviction, and real scrolling.

The result we can point to today is specific: replacing the full-day view tree with reusable cells cut initial block-preparation work by about 60% in the matched experiment. The next job is to make the calendar consistently meet its interaction and frame budgets on the physical devices.

## Source and reproduction

The calendar renderer and benchmark harness are in [AbregaInc/banana on GitHub](https://github.com/AbregaInc/banana).

*Local draft note: this repository is private. Before publication, replace this with a reviewed public renderer/benchmark repository or decide which source to make public.*
