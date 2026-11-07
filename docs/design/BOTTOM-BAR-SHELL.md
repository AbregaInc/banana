# One navigation layer: the bottom bar (phone) and the rail (wide)

6 Nov 2026. The owner approved the phone direction from image mockups ("i love it for the
iphone"): too many buttons on iOS, and they overlapped. One bar at the bottom replaces the tab bar
and every top button row: a round page switcher at the left ("tapping it expands and closes it
… upwards"), a "Search or ask" field across the middle ("the search box acts as the AI entry space
kind of"), and the assistant at the right. The podcast player "needs to be hideable or
dismissable". The same evening: "ipad rail plus top bar B and Mac also same. same for mail".

## Where it applies

By width (`ShellLayout`, measured at the root of the shell), never by device:

- **Under 1,100 pt** (a phone either way up, an iPad upright, any split or Slide Over): the
  bottom-bar shell. An iPad upright is the phone's layout with wider pages: Plan shows its week,
  Mail its list and reader side by side under one top row ("Inbox ⌄ 40" … "•••"), and the reader
  has the subject with one "•••" in place of the row of icons (approved images, 7 Nov 2026).
- **1,100 pt and up** (an iPad on its side) and the Mac's window: the rail and one top toolbar
  (*Wide*, below).

In the shells Mail has no sample-mail strip and no rule under its top rows; the standalone
`--mail` page keeps both.

The standalone screenshot and test routes (`--plan`, `--wellness`, `--mail`, …) draw a page
without the shell and keep its own controls; `--ui-preview` draws the shell.

## The pieces

| Piece | Where | What |
|---|---|---|
| `ShellRules.swift` | `Banana/Model` | Pure: which pages are listed (`ShellPage.listed`), what the field shows (`ShellFieldMode`), where the player sits (`ShellPlayerPlacement`), how a plan title matches (`ShellSearchRules`). Unit-tested. |
| `ShellSearch` | `Banana/Views/Shell/ShellSearch.swift` | The field's words and results. Its own object: a keystroke redraws the field and the results, never the shell or the page. |
| `ShellBottomBar`, `ShellSwitcherOverlay`, `ShellResultsOverlay`, `ShellPlayerCapsule`, `ShellPlayerChip` | `Banana/Views/Shell/PhoneShell.swift` | The compact shell. |
| `PageTitleMenu`, `PageTitleText`, `BodyTitleMenu`, `\.bottomBarShell` | `Banana/Views/PageChrome.swift` | A page's one top row. With `bottomBarShell` set, `ReviewToolbarItem` and the + draw nothing, and "…" loses Settings and Assistant. |

Glass is the system's (`.glassEffect`, `.buttonStyle(.glass)`), on the bar, the switcher, the
player and the top row only. Results, rows and the page stay solid.

## Every old control and its new place (phone)

| Before | Now |
|---|---|
| Tab bar: Plan, Mail, Body, Notes, Library | The switcher (bottom left): a column of round page buttons with labels rises from it, only the modules that are on; tap again, the X, or the dimmed page closes it |
| Review: the chart button at the top left of every page | The switcher's **Review**, on the subject of the page showing (a sheet, as before) |
| "…" › Settings | The switcher's **Settings** (a sheet, as before) |
| "…" › Assistant | The sparkle button (bottom right) |
| "…" › Routines | Stays in "…" |
| The + at the top right of every page (the one list of everything) | **The field**: focused with nothing typed, it lists what can be added, this page's kinds first. Picking one opens it on its page (`onAdd`), as the + list did. `PageChrome`'s one-add rule holds: there is one way to add per page, and it is the same on every page. Mail's compose stays at the inbox's top right (the design) |
| Now-playing bar (`tabViewBottomAccessory`) | A glass capsule just above the bar: artwork, show and episode, play/pause, a chevron that hides it. Hidden, it is a round artwork with a progress ring at the left end of the field: tap brings it back, a swipe left stops playback (VoiceOver: "Stop playback" action) |
| Apple Music wake bar | The same place, as a glass capsule |
| **Plan** Day · Week switch | Under the title's chevron ("Today ⌄") |
| **Plan** date line (back, name, Today, weather, forward) | The title is the name ("Today", "Wed, Nov 4", "This week" with its dates under it); the date and weather sit beside it; back, forward and Today are under the chevron. Swiping the day sideways still steps days |
| **Plan** "Needs attention" row | A count beside the title; the first item under its chevron opens the same list |
| **Plan** magnifier (Google Calendar search) | The field. Plan results come from the timeline on the device; "Search all calendars" under them opens the same calendar search with the words in it |
| **Plan** booking share button | "…" |
| **Plan** all-day band and reminders band | One row of chips that scrolls sideways: the day's all-day events (Day), routines with no time, reminders. None wait behind "+N more" |
| **Body** Workouts · Food · Taken switch | "Workouts ⌄" title menu, with what is waiting in each |
| **Notes**, **Library** | Their name at the left; "…" at the right |
| **Mail** search row | The field; Mail's results open the conversation inside Mail's own search of the same words, so Back and the cursor work; an × beside the place's name returns to the inbox |
| **Mail** Accounts menu row | The place menu under the title ("Inbox ⌄") › Accounts |
| **Mail** conversation: Back and six icons | Back with the place's name, and "…" (newer, older, reply, reply to all, forward, star, unread, archive). On the bar the field reads "Reply or ask" and starts a reply; a round Archive sits beside it |

The bar steps away while a keyboard is up for anything but the field (a note, a form), and the
switcher and sparkle step aside while the field is in use so it is as wide as the bar.

## Wide: the rail and one toolbar (iPad, Mac)

Approved the same evening as direction B ("ipad rail plus top bar B and Mac also same. same for
mail"), and narrowed on 7 Nov to an iPad on its side and the Mac. No bottom bar there.

| Before | Now |
|---|---|
| iPad sidebar / floating top tab strip; Mac source list | The rail (`ShellRail`, 72 pt) pinned to the left edge: round page buttons, no labels, only the modules that are on, Settings at its foot. On the Mac it is the split view's sidebar column, fixed, under the traffic lights, with no sidebar toggle |
| Review row | A rail button (the page Review, as before) |
| Routines row / tab | "…" on every page (`MoreMenu`), and the menu bar's section commands |
| Assistant row (iPad) / "Ask or add" toolbar button (Mac) | The round sparkle button beside the field (⌘J kept on the Mac) |
| The +, top right | The field, focused with nothing typed (as on the phone). C still creates on the Mac |
| **Plan** (iPad) Day · Week switch | Back, forward and Today at the left, then "Day ⌄"/"Week ⌄"; the field in the middle; the sparkle and "…" (booking share, refresh, briefing, availability, setup, Routines). The date line row stays under the toolbar, with the weather |
| **Plan** (Mac) toolbar: back/forward/Today, a second back/Today/forward group, Day · 3 · 5 · Week switch, magnifier, weather, share, availability, + | Back, forward and Today; "Week ⌄" (Day, 3 days, 5 days, Week) with the weather beside it; the field; the sparkle; "…" with Share booking link, Share availability and Refresh. ⇧⌘L (copy the booking link), S (availability), C (new event) and D, 2–7, W (spans) are unchanged |
| **Body** switch (Workouts · Food) | "Workouts ⌄" title menu |
| **Mail** (iPad on its side): search row, accounts row, the column of places, the place's name over the list | One row: "Inbox ⌄" (places, accounts), the field, the sparkle, "…" (reply, reply to all, forward, archive, star, unread, new message); then the list and the reader, with the details closed until `]`. Swipes and keys unchanged |
| **Mail** (Mac) | "Inbox ⌄" and "…" in the window toolbar, beside the window's field and sparkle |

What the field finds hangs under the toolbar's middle (`ShellWideResults`), a solid panel; a
click beside it puts it away, and Esc does on the Mac.

## Search or ask

Typing waits 120 ms for a burst of keys, then runs the searches the pages already have:

- **Plan**: the occurrences already in memory (the same list the assistant searches), by word
  prefix; what is next first, then the most recent past. Five shown.
- **Mail**: `MailSource.observeList` on a search scope of the words, five rows — the same path
  Mail's own search runs, so the sample mailbox and Gmail answer alike. Only with Mail on.
- **Notes**: `VoiceNoteStore.matchingNotes`, the list's own search.

With an assistant in the build (`BANANA_AI`: Debug and local installs; never TestFlight or the
App Store), "Ask Banana: <words>" is the first row and Return asks when nothing was found; the
words are handed to `AssistantView`, which sends them as soon as the model is ready. Without one
the sparkle button and the Ask row are not there and the field only searches.

## Not done / open

- Notes and Workouts keep their own filter rows under the top row (`LiveFilterSearch`): they
  filter by date, kind and more than the field's words. Whether the field should take them over
  is the owner's call.
- Week mode steps weeks from the title menu only; the date line's swipe went with it.
