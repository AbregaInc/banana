# Native SwiftUI hour-line experiment — October 9, 2026

Work in progress; default remains the existing Rectangle-based grid. `--calendar-canvas-grid`
selects native SwiftUI Canvas for decorative hour and half-hour lines in MacWeekView. Events,
time labels, input handlers and event accessibility remain separate. Apple's [Canvas guidance](https://developer.apple.com/documentation/swiftui/canvas)
identifies noninteractive drawing as a suitable use. This is a different experiment from the
previous isolated AppKit image-backed grid; the production calendar currently has separate
SwiftUI shapes for these lines.

Pixel comparisons using the production primary-color opacities passed at widths 172/215.5/900,
scales 1/2/3 and light/dark appearances (18 exact image pairs). Images and command are in the
[tile correctness results](../calendar-tiles-20261009/checks/hour-lines/). Native performance
measurements and functional checks remain pending; fewer view nodes do not establish a win.

## First native pair (not sufficient for adoption)

Both apps use the same optimized binary, 180,000 mail fixtures, 36,500 calendar events,
5,000 notes and 20,000 podcast episodes. The observation fix is enabled. The recipe is four
alternating half-page wheel down/up pairs, four J pages forward and four K pages back.
Two older idle isolated previews remained running during both recordings. Sampled developer
process monitoring was clean; that does not establish an otherwise idle host.

| Variant | Commit samples | p95 ms | Maximum ms | Maximum main busy interval ms |
| --- | ---: | ---: | ---: | ---: |
| Rectangle control, shapes-trace-2 | 216 | 57.903 | 167.629 | 102.097 |
| Canvas, canvas-trace-1 | 230 | 50.579 | 145.540 | 100.956 |

Both **fail** the unchanged 8.3 ms commit-work budget. One pair does not establish a reliable
improvement. CUA accessibility snapshots are part of both recipes and contribute CPU work.
Commit intervals are not input-to-visible latency or proof of display delivery. The first
Rectangle recording, shapes-trace-1, ended before interactions during context recovery; its
failure and explicit incomplete-recipe record are retained and excluded from paired inference.

A separate 45-second `sample` capture during Canvas scrolling/paging is local at
`.build/calendar-hour-lines/cpu-canvas/sample.txt`. It points to SwiftUI layout, view-list creation/
destruction and accessibility traversal; repeated layout computation also appears. It is a
sampling diagnostic with automation observation overhead, not another acceptance measurement.
Raw Instruments traces stay local because they contain process environment metadata.
