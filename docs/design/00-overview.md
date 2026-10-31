# Unified Timeline — Design Overview (L1–L4)

Status: **design only, not built.** This is the north-star architecture for evolving
Banana from four features sharing a screen (merged calendar + derived wake/commute +
audio cues + workouts) into **one cohesive system** — a fusion of WorkOutDoors, Podcasts,
Reclaim, and Reminders.

## The spine

Everything the user sees is one **`Occurrence`** on a single timeline, described by four axes:

- **Source** — `.external` (calendar, read via EventKit) · `.derived` (computed: wake,
  wind-down, commute) · `.authored` (the user's cues, events, tasks).
- **Behavior** — `.event` · `.cue` (audio routine) · `.task` · `.block` (reserved time).
- **Schedule mode** — `.fixed` · `.derived` · `.flexible`, plus a `moveable` flag.
- **Time** — a concrete time or a placement window.

Tabs become *filters over occurrences*, not separate apps. A flexible workout **block** that
**carries a cue** and is placed by the **scheduler**, then confirmed by the **watch** — that
one sentence is WorkOutDoors + Podcasts + Reclaim fused.

## Locked product decisions

1. **Write-back:** yes — into the user's **existing calendars** (round-trip identity required).
2. **Stickiness:** **sticky by default**; `moveable` is opt-in per item.
3. **Reflow:** **manual only** ("Re-plan my day"); nothing auto-shuffles.
4. **What's written:** **everything, including cues**.
5. **Hold intent:** **Busy** (defend the time).

Assumed defaults: phone is the scheduling brain (results push to watch); **user edits in
Calendar always win**; derived items recompute automatically (that's derivation, not
reflow); ~2–4 week materialization horizon; tasks bind to Apple Reminders.

## The layers

| Layer | Deliverable | Doc |
|---|---|---|
| **L1** | The `Occurrence` model, source producers, cue↔source binding, and the write-back sync contract (round-trip identity) | [L1-occurrence-model.md](L1-occurrence-model.md) |
| **L2** | Per-occurrence exceptions — move / skip / add — and "this one vs. the series" | [L2-exceptions.md](L2-exceptions.md) |
| **L3** | Tasks from Apple Reminders as first-class occurrences (inbox / deadline / placed) | [L3-tasks.md](L3-tasks.md) |
| **L4** | The manual flexible scheduler — "Re-plan my day/week" | [L4-scheduler.md](L4-scheduler.md) |

## Buildable order & the through-line

L1 is the unlock: until meetings, cues, derived items, and tasks are literally the same
object with different axes, you have four features sharing a screen. After L1, each later
capability *attaches to the spine* rather than being a fifth app:

- **L1** consolidates today's pieces into one `Occurrence` + establishes write-back.
- **L2** makes "move Thursday's gym this week / skip Saturday / add an extra" work, uniformly.
- **L3** folds in to-dos.
- **L4** adds Reclaim-style placement — and because reflow is manual and stickiness is the
  default, it's a bounded, on-demand engine rather than a continuous optimizer.

Two cross-cutting invariants hold across every layer:

- **User edits win.** External is the source of truth; the app adapts, never clobbers.
- **Never silently drop a commitment.** Anything that can't be placed/resolved is surfaced,
  not dropped.
