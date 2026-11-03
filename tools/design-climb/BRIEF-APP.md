# Design climb brief: the whole app

You are reviewing **Banana**, a personal iOS/iPadOS app: Plan (calendar, reminders,
travel, routines), Body (workouts, food and nutrition, what's taken), Notes, Library
(podcasts) and Review (looking back). It is a **fixed interface**: its pages are home. An
on-device assistant is one way to put data in (the + sheet) or get answers out (Review);
it is not judged here.

The screenshots come from the screen atlas: every page and state, opened on fictional
sample data with a fixed day. Each is named `<area>__<state>` and listed with what it is
meant to show.

The goal is the best possible experience for three readers:

- **UX — the person.** Each page answers "what now?" at a glance and does its job in the
  fewest taps, always clear about what is saved, due or done.
- **AX — the agent experience.** Where the app shows things an agent or automation made
  or will do (busy blocks, suggestions, estimates, reminders moved), are they legible,
  honest and easy to correct?
- **DX — the builder.** One pattern per job across all pages (lists, sheets, empty states,
  headers, actions), so the next screen is easy to build right.

**Do not spend findings on corner radii, shadows or pixel nudges** unless they break
comprehension. Look for structure: wrong hierarchy, missing or confusing state, extra
steps, dead ends, duplicated or inconsistent controls between pages, copy that explains
instead of designing, iPad wasting its width, things that look tappable and aren't.

Read `OWNER-CALLS.md` (included) first: those are decided and not up for debate.

## Categories (score 0–10, one decimal)

1. **Task flow** — steps, taps and screens to finish each job; is the next action obvious?
2. **State and feedback** — due, done, saved, syncing, failed: always clear.
3. **Hierarchy** — the most important thing reads first; density without noise.
4. **Agent legibility (AX)** — anything automated is visible, honest and correctable.
5. **Trust and control** — edit, undo, dismiss; confirmations only where they earn it.
6. **Discoverability** — empty states teach; features are findable; no dead ends.
7. **Copy** — few, plain words; labels say what happens.
8. **Platform fit** — native components, accessibility, iPad uses its space well.
9. **Consistency (DX)** — one pattern per job across pages.
