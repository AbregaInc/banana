# Local editorial draft only

Article: [ai-hill-climb.md](ai-hill-climb.md). Nothing deployed, committed or pushed.

## Updated brief

State the owner’s ambition for the smoothest possible interface, targeting120fps throughout
the application at all times on capable displays, explicitly as an unfinished goal. Keep the
article itself calendar-only. Lead with measured calendar performance at a defined workload, explain the changes and
AI-driven hill climb, include actual host/spare-phone/iPad hardware, and stay entirely within
the calendar view. The earlier benchmark-bug story is supporting detail rather than the hook.

## Headline result and calculation

Source: `docs/performance/scale-results/calendar-native-day-20261010/preparation-comparison.json`.
Sum the retained `artwork.samplesMS` per run, then average each policy's two run totals:

- Reference:96.230666 and93.871163ms; mean95.0509145ms.
- Native:39.168414 and37.263458ms; mean38.215936ms.
- Reduction:59.7942469%, rounded to60% in the headline.
- Metric: aggregate main-actor cache-miss preparation, including rasterization/cache insertion.
  It is not wall-clock day readiness, per-frame drawing, FPS or input-to-visible response.
- Individual rasterization maxima did not improve; fewer preparation jobs account for the gain.
- Source report/collector: `calendar-native-day-20261010/README.md` and
  `tools/calendar-artwork-tests/profile-app.py`. Collector selects30days; legacy fixture
  in `Banana/Model/ScaleStress.swift` creates100new events/day (3,000retained events).
- Model/source hashes are retained in the experiment reports. No new benchmark was run here.

## Hardware and physical results

Current machine: MacBookPro18,2, M1Max,10CPU cores(8performance/2efficiency),32GPU cores,
64GBunified memory, verified via filtered system_profiler output on2026-10-28.
`docs/performance/regression-baseline.json` also identifies MacBookPro18,2.
Only model/specs are used; no serial, deviceUDID, account or network identifiers are published.

- Spare iPhone14Pro/A16: `calendar-live-metal-20261009/README.md` and
  `merged-device-regression-20261010/README.md`.
- Physical iPadPro12.9inch5thgen/M1: `calendar-ipad-20261009/environment.json`,
  `calendar-ipad-followup-20261010/README.md` and `calendar-capacity-20261009/README.md`.
- The physical app-update maxima come from merged-device and iPad-followup reports.
  They are not drawing-only metrics or before/after evidence.
- Do not confuse physical M1iPad with the M5iPad Simulator also used elsewhere.

## Public source link

`gh repo view AbregaInc/banana --json url,visibility,isPrivate` reports PRIVATE.
No other Banana/calendar repository appeared in the organization's repository list.
The draft contains the real URL plus an explicit editorial blocker. Do not represent it as
publicly reproducible or publish the whole private app without a separate owner decision.
A focused renderer/benchmark extract is the suggested option, not something published here.

Exact AI model/version, prompts, cost, elapsed time and number of attempts remain unverified
and are omitted. The AI-driven attribution comes from the owner's account of the project.

HN rules: https://news.ycombinator.com/newsguidelines.html. This is a website draft; no HN
submission, generated on-site post/comment, automated posting or vote solicitation occurs.

## Screenshots, social image, and proposed URL

Proposed canonical: `/blog/optimizing-calendar-rendering-with-ai/`.
Readable subject words and hyphens follow Google's URL guidance:
https://developers.google.com/search/docs/crawling-indexing/url-structure
No claim of an AI-answer ranking boost from the slug. On eventual publication, redirect the
currently published `/blog/building-a-measurable-calendar-renderer/` to the chosen URL,
and synchronize canonical, og:url, schema, archive links, RSS and sitemap. Nothing live changed.

`preview.py` renders outside the served production folder; it writes only `/tmp/banana-hn-draft-*`.
It inserts the screenshot figure and diagram into the local HTML without modifying the public
Markdown renderer. The old local `/blog/ai-hill-climb/` link remains usable for review.

Screenshot originals are retained unchanged in `assets/`; hashes/sizes/source paths are in
`assets/provenance.json` and match AppStore/Generated/capture-status.json. Day is an iPhone
capture, Week an iPad capture. CSS clips the iPad sidebar and phone bottom navigation to focus
on the calendar; no event labels or interface pixels were fabricated or repainted.
They show demo data, not the 100-event/day stress fixture.

`og-image.html` lays out the actual screenshots, current Banana mascot, local IBM Plex Mono
fonts and cream/ink/yellow/pastel palette at1200×630. Headless Playwright captures it into
`assets/calendar-rendering-ai-og.png`. Metadata in the local preview points at the planned
public `/assets/img/blog/calendar-rendering-ai-og.png`, with dimensions, image MIME, alt text,
Twitter image/card and BlogPosting image. The file is also served at that path on localhost.
The public path does not exist until this draft is approved and deployed.

Named concepts: view virtualization, cell recycling, lazy view construction, cache invalidation.
Library provenance: `docs/performance/rendering-research-20261009.md`,
`docs/performance/regression-testing.md` (library evaluation sections), and pinned packages in
`tools/calendar-library-benchmark/project.yml`. Only CalendarKit/KVK were placed in the
isolated calendar-library benchmark; Horizon/JZ/ScheduleKit were source-screened. Skia is a
separate nonshipping experiment. Instruments/XCTest/xctrace/simctl are the actual measurement
and interaction tools recorded in the reports. No benchmark or library-performance rerun was
performed for this editorial revision.

## Current imagery: populated performance fixtures

The active screenshots now use the populated calendar test attachments from the retained
October27 full UI result, replacing the light AppStore demo captures in the article and OG.
Both current images are iPhone Simulator captures; the Week image is no longer an iPad image.
The dataset is varied-v1:30days,3,000events,12calendars,100new events/day on average.
These are populated passing-test attachments, with real truncation/overlap behavior intact.
No loading placeholders, personal calendar data, or repainted UI were substituted.

`assets/performance-provenance.json` records exact original-image hashes and test identifiers.
The original demo-image provenance is retained as history; those files are no longer selected.
The figure now shows each full screenshot rather than cropping it with the demo iPad geometry.
The 60% headline remains the separate matched legacy-fixture experiment described in the text;
these varied-fixture screenshots illustrate the stress view, not a new timing run.

Editorial follow-ups applied: removed the benchmark-bug section and GitHub scheduling paragraph;
replaced the rectangle explanation with a direct sentence about event views; preserved the
owner's multi-account/unified-day blurb and explicit unfinished120fps goal.

## iPad video revision — October 28

Current article hero is an iPad-only muted looping MP4, with native controls and a Day poster.
Autoplay is disabled when prefers-reduced-motion is enabled; manual playback remains available.
The social image now uses the iPad Day and Week stills. Older phone captures remain as history.

Captured headlessly on the canonical iPad Pro 13-inch (M5) Simulator, iOS26.5, retained main
Banana build81, with varied-v1 (30days,3,000events,12calendars). stress.ready confirmed the
installed fixture checksum aa2459c218d7dcb3 before recording. This is a visual fixture
demonstration, not a new benchmark, physical-iPad capture, or FPS measurement.

The revised approximately20-second edit uses the first9seconds of the Day moving capture,
followed by the complete11-second moving Week capture. Both views scroll down and back at
recorded speed. The Week segment shows Nov2–8 with all seven days populated, verified in
accessibility before capture. The earlier static Week edit is preserved only in the private
capture log as v1. No repeated-frame Week hold is used in the current video.
There is a cut between views; no speedup, UI repainting or fabricated calendar content.
Web encode: H.264,1600×1200,30fps container,silent,faststart. The container rate is an
encoding choice, not the app's measured rendering rate. The asset URL carries a revision
query to avoid reusing the earlier static segment in a browser cache.

Raw recordings and capture script are preserved in the private local log folder
~/Library/Logs/Banana/CalendarBlogVideo-20261028. Source/output hashes are in
assets/video-provenance.json. Simulator was shut down and released to Pi; no physical
devices, app sources, production website, or Apple submission state were changed.
