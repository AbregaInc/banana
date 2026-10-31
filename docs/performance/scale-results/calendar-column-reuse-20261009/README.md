# Native SwiftUI column identity experiment — October 9, 2026

DEBUG `--calendar-reuse-columns` retains the time-grid columns by their visible slot instead
of replacing the entire subtree when its date changes. Events and overflow groups retain their
own content IDs, so those children still change with their actual events. The default remains
date-based columns; this is an opt-in experiment, not an adopted improvement.

The first pair uses the same optimized binary, Rectangle grid, default narrow observation fix,
no audit footer, and one isolated visible preview. Workload: 180,000 mail, 36,500 events, 5,000
notes, 20,000 episodes. Recipe: four alternating half-page wheel pairs, four J pages forward,
four K pages back. CUA accessibility snapshots are part of both recipes. No competing developer
processes were detected during either recording; other host contention remains possible.

| Variant | Commit samples | p95 ms | Maximum ms | Main busy maximum ms |
| --- | ---: | ---: | ---: | ---: |
| Date identity | 252 | 52.613 | 164.641 | 109.863 |
| Stable column slots | 253 | 54.937 | 143.962 | 104.784 |

Both fail the unchanged 8.3 ms work budget. The lower maximum and higher p95 do not establish a
reliable improvement from one pair. Repeated pairs and the stricter event-action rebinding test
remain pending. A retained column may also require explicit handling of stationary-pointer hover
state across keyboard paging; that interaction must be checked before adoption. Commit work is
not input-to-visible latency or compositor delivery, and the window's actual refresh rate is not
verified. Raw Instruments traces remain local under `.build/calendar-column-reuse/`.
