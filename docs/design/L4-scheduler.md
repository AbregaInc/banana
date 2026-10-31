# L4 — Flexible scheduler & "Re-plan" (manual)

Status: **design only, not built.** The largest layer; depends on L1–L3. Bounded by the
decision that **reflow is manual only** — there is no continuous placement engine.

## Purpose

On demand ("Re-plan my day" / "Re-plan this week"), place all **moveable** occurrences
(flexible blocks + placeable tasks) into open time around the fixed skeleton, honoring each
item's constraints. The output is deterministic and explainable.

## 1. Inputs

- **Fixed skeleton (immovable obstacles):** external events + sticky items + **derived
  items** (wake / wind-down / sleep — you never schedule *into* sleep; meals if modeled).
  Derived items recompute *first* (they define the skeleton), then placement fills the gaps.
- **Moveable set:** occurrences with `moveable == true` and their constraints:
  `duration, window, deadline, priority, frequency`.
- **Scope:** today or the week (within the ~2–4 week horizon).

## 2. Algorithm — a predictable heuristic, not a global optimizer

1. **Free intervals** = horizon − fixed obstacles − derived (sleep, etc.).
2. **Order** moveable items by `priority`, then deadline urgency, then duration
   (hardest-to-fit first).
3. **Place** each with earliest-fit inside its `window` that satisfies constraints; honor
   deadlines; spread `frequency` items across days.
4. The chosen slot becomes an obstacle for the next item.

Deterministic (same inputs → same plan) and **explainable**: record *why* each item landed
where it did ("earliest morning slot before your 9:00", "last fit before Friday's deadline").
Legibility and trust outweigh marginal optimality — a plan the user can reason about beats a
tighter plan they can't.

## 3. Stickiness & pinning

- Sticky items are obstacles; **never moved** by a re-plan.
- The user can **pin** any placed item → it becomes sticky (recorded as an L2 override), so
  future re-plans respect it.
- `moveable` items keep their prior placement when it's still valid (**stability**); a
  re-plan relocates them only to make everything fit or when the user explicitly asks for a
  fresh plan.

## 4. Legibility & trust (hard requirements)

- **Never silently drop a commitment.** If something can't fit, surface it —
  "Couldn't place: N items" with the reason (window too tight / no free time before
  deadline) — and leave it in the inbox. Dropping is never allowed.
- Every placed item answers **"why here?"**
- **One-tap override** on any placement; the next re-plan honors prior pins.

## 5. Write-back (given the locked decisions)

A re-plan produces a **batch of calendar deltas**: create/update **Busy**, AppItemID-stamped
events for newly placed or moved items; delete events for anything un-placed. Any calendar
edits the user made since the last plan are **adopted first** (they win) as pins/overrides,
then placement runs around them.

## 6. Scope & interactions

- **"Re-plan today"** vs **"Re-plan this week"** — same engine, different horizon.
- Derived items always resolve before placement (skeleton first).
- A placement that collides with a *newly discovered* fixed event (e.g. a meeting added
  after planning) is **not** auto-moved (manual reflow); instead it's flagged as a conflict
  for the user to resolve or re-plan.

## 7. Out of scope / future

- **Continuous auto-reflow** — explicitly deferred by decision (manual only).
- Cross-day optimization beyond simple frequency spreading.
- Learning preferred times from history (could inform `preferredWindow` later).
