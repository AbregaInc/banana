# Design climb brief: Pi in the fixed app

You are reviewing **Banana**, a personal iOS/iPadOS app (calendar plan, meals and
nutrition, notes, workouts, podcasts). Banana is a **fixed interface**: its pages (Plan,
Body, Notes, Library) are home. An on-device assistant ("Pi") is **a method of putting data
in or getting answers out**, never a chat screen that replaces the pages:

- **In:** the page's **+** opens one sheet. Its first line takes words ("2 eggs and a
  banana", "lunch Friday at 1"); Pi turns them into the app's own editor (meal, event) in
  the sheet; the person approves; the sheet closes onto the page where the item now lives.
  Every kind of thing can still be added by hand from the same sheet.
- **Out:** **Review** (chart button, top left) is for looking back. Its first row takes a
  question; the answer opens as a page with the app's own view (a chart, results).

The goal is the best possible experience for three readers:

- **UX — the person.** Get a job done (log a meal, add an event, find something, see
  progress) with the fewest steps, always knowing what happened and what is saved.
- **AX — the agent experience.** How well the fixed app carries the assistant's work: is
  the way in (the +) and out (Review) obvious, is what Pi proposes legible and easy to
  correct, honest about draft versus saved, and does a saved result land where the person
  expects it? The agent should feel like a fast input method, not a destination.
- **DX — the builder.** Consistency that makes the next screen easy to build right: one
  pattern for each job (one way to show a draft, a saved result, an error, an action),
  the same components reused rather than near-duplicates.

**Do not spend findings on corner radii, shadows or pixel nudges** unless they break
comprehension. Look for the structural problems: wrong hierarchy, missing or confusing
state, extra steps, dead ends, duplicated controls, unclear ownership of a screen, copy
that explains instead of designing, iPad wasting its width, things that look tappable and
aren't (or the reverse). Do not propose making the assistant the home screen or a chat
transcript the main surface: that direction is decided against.

Each screenshot is a real state from a fixed walk through the app. Its name and the
step that reached it are listed with it. Read `OWNER-CALLS.md` (included) first: those
are decided and not up for debate.

## Categories (score 0–10, one decimal)

1. **Task flow** — steps, taps and screens to finish each job; is the next action obvious?
2. **State and feedback** — working, draft, saved, failed: always clear, never ambiguous.
3. **Hierarchy** — the most important thing reads first; density without noise.
4. **Agent legibility (AX)** — what Pi did and proposes is visible, correctable, honest.
5. **Trust and control** — approve, edit, undo, dismiss; confirmations only where they earn it.
6. **Discoverability** — the empty state teaches; capabilities and Browse are findable; no dead ends.
7. **Copy** — few, plain words; labels say what happens.
8. **Platform fit** — native components, accessibility, iPad uses its space well.
9. **Consistency (DX)** — one pattern per job across states.
