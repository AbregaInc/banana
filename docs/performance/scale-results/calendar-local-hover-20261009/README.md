# Mac calendar hover observation — October 9, 2026

The original inline hover implementation reevaluated the whole week 32 times during 12 native
XCTest pointer movements. An extracted modifier using a parent Binding and one using local State
both recorded zero whole-week reevaluations. The original optimized app binary is preserved and
identified in runs.json. Each run uses the isolated 180k-mail / 36.5k-event workload.

The initial experiment's “parent” control had already moved the observation boundary into the
modifier. It therefore did **not** preserve the original invalidation path. The subsequent original
binary probe establishes the before/after redraw difference, but same-binary timing comparisons
require restoring the original inline control. The corrected same-binary control and local variant now have a [follow-up report](../calendar-interaction-local-20261009/README.md); no latency improvement
or performance acceptance is claimed from these counts. The default remains experimental control
until measured validation supports adoption.

Both initial extracted variants passed all six native functional checks (Mail typing/selection,
overflow reachability, paging/scrolling, event-action rebinding, palette invalidation and hover).
The original binary ran only the hover probe. Test wall clock includes automation overhead and is
not response latency. Raw xcresult bundles and desktop recordings stay local. Only test logs,
small summaries, redraw attachments and exact initial implementation sources are retained here.

The local variant also binds a retained pointer coordinate to the currently displayed day; stationary
pointer and right-click behavior after keyboard paging was subsequently verified in that follow-up. System
VoiceOver navigation, input-to-visible timing and 120 Hz delivery remain unmeasured.
