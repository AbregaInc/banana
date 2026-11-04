# Owner calls

<redacted>'s standing decisions. Judges treat these as fixed: they may point out a problem
these rules create, but never propose breaking one.

1. **System components first.** Use Apple's standard controls, lists, sheets, menus and
   toolbars so the app follows the platform (Liquid Glass, user transparency, Dynamic Type).
   No hand-built replacement for something SwiftUI already provides.
2. **Fewest taps to success, instant feedback.** Every extra screen, sheet, review tap or
   wait is a cost. A change shows at once (optimistic) and is fixed up if it fails; no
   sheet waits on a network write.
3. **Less copy.** Short, plain words. No reassuring small print, no grey explanatory
   sentence under a row or title, no ", never X." contrast tails. Cut by half.
4. **Keep density.** No cards or padding that cost vertical space for decoration. Judge at
   real device size.
5. **No colour stripes.** No vertical colour spines or bars on rows.
6. **No plumbing controls.** Never add UI whose job is to make infrastructure work
   (sync buttons, reload, connect-this-service toggles). It happens automatically.
7. **Glass is the navigation layer only.** Content sits on solid, opaque surfaces.
8. **A save the person must approve stays approved by them.** Meals keep their explicit
   review before saving; the model never writes a meal or event without that approval.
9. **A fixed interface; the agent is an input method.** The pages are home. The agent is
   reached from them (the +, Review) and puts data in or gets answers out. No chat-first
   home, no transcript as the main surface.
10. **The words in the screenshots come from a fixture model** ("Pi UI breakfast",
    "Saved your note."). Judge how the UI presents them, not the fixture's wording. The
    meals, notes and plans are fictional sample data.

## Decided patterns across the app (<redacted>'s rulings, 9–18 Oct 2026)

11. **Doing vs looking back.** Tabs (Plan, Body, Notes, Library) are for now and next.
    Everything about the past lives in Review, opened by the chart button at the top left
    of every page. Review has the app's only Week · Month · Year switch.
12. **One control per job, the same everywhere.** One + per page, in its top bar. One switch
    in the top bar (four words or fewer). One date line (Plan's layout; swipe to step, tap the
    name for now). "…" at the top right, ending with Settings.
13. **Sheets:** Cancel left and the verb right when changing something; Done right when only
    looking. Rows: tap opens, swipe deletes. An empty page is one line plus the + action as
    a button. One primary button style. Small centred titles, sentence case.
14. **A symbol beside a line of text sits on a solid icon tile**, never a bare outline glyph in
    the accent colour. Sizes and colours come from the design system's roles.
15. **Plan's all-day items and reminders are part of the calendar**, on its white, not in the
    header. A due dose is amber across its whole row.
16. **Mac and iPad follow the phone's decisions** with platform-native chrome (one toolbar on
    every Mac page; sidebar on iPad).

Judges may point out where a screen breaks one of these. They must not propose replacing one.
