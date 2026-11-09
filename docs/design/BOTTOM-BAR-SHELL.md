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
| **Plan** Day · Week switch | Under the period picker's chevron ("Week ⌄"), with what needs attention first and its count beside the name |
| **Plan** date line (back, name, Today, weather, forward); then (6–8 Nov) a title ("Today ⌄", "This week ⌄") with "‹ Today ›" at the right | The paging group every shell has (`PlanPagingRow`, the toolbar's `PlanPagingToolbar` drawn as a row; the owner, 8 Nov 2026): "‹", the period picker ("Week ⌄" with the dates beside it, "Nov 2–8"), "›", then Today only away from the current period (`PlanPaging.showsToday`, one rule on every device, the owner, 9 Nov 2026); the weather beside it; "…" at the right. On the current period the weather is in the row at every width; paged away, Today comes back and, where both don't fit, the weather gives way first. Then the dates move under the name, and only on the narrowest go (`PlanPaging.topRowLayouts`); the targets stay 44 pt and the name is never cut. The row is Plan's own view, not the bar's toolbar (which moved its items into an overflow menu with room to spare). Swiping still steps |
| **Plan** list icon beside each day number (Week) | Gone: the day's letter and number select the day and, with anything on it, open its whole list, as the icon did |
| **Plan** "Needs attention" row | A count beside the title; the first item under its chevron opens the same list |
| **Plan** magnifier (Google Calendar search) | The field. Plan results come from the timeline on the device; "Search all calendars" under them opens the same calendar search with the words in it |
| **Plan** booking share button | "…" |
| **Plan** all-day band and reminders band | One row of chips that scrolls sideways: the day's all-day events (Day), routines with no time, reminders. None wait behind "+N more" |
| **Body** Workouts · Food · Taken switch | "Workouts ⌄" title menu, with what is waiting in each |
| **Notes**, **Library** | Their name at the left; "…" at the right |
| **Mail** search row | The field; Mail's results open the conversation inside Mail's own search of the same words, so Back and the cursor work; an × beside the place's name returns to the inbox |
| **Mail** Accounts menu row | The place menu under the title ("Inbox ⌄") › Accounts |
| **Mail** conversation: Back and six icons | Back with the place's name, and "…" (newer, older, reply, reply to all, forward, star, unread, archive). On the bar the field reads "Reply or ask" and starts a reply; a round Archive sits beside it |
| **Mail** conversation read oldest first, reply under the last message | Newest first on every layout (`MailReadingOrder`): it opens at the top on the latest message, older ones going down; bodies load in that order. A reply being written, or the mark of a kept draft, sits under the subject, above the newest message it answers. The sender of each message opens Details |

The bar steps away while a keyboard is up for anything but the field (a note, a form), and the
switcher and sparkle step aside while the field is in use so it is as wide as the bar.

## Wide: the rail and one toolbar (iPad, Mac)

Approved the same evening as direction B ("ipad rail plus top bar B and Mac also same. same for
mail"), and narrowed on 7 Nov to an iPad on its side and the Mac. No bottom bar there.

| Before | Now |
|---|---|
| iPad sidebar / floating top tab strip; Mac source list | The rail (`ShellRail`, 72 pt) pinned to the left edge: round page buttons, no labels, only the modules that are on; Settings at its foot on an iPad, in the app menu (⌘,) on the Mac. It hides and shows like a system sidebar and stays as left (the owner, 9 Nov 2026): on the Mac it is the split view's sidebar column under the traffic lights, with the system's sidebar button and View › Hide Sidebar (⌃⌘S); on an iPad a sidebar button at the toolbar's leading edge (⌃⌘S) |
| Review row | A rail button (the page Review, as before) |
| Routines row / tab | "…" on every page (`MoreMenu`), and the menu bar's section commands |
| Assistant row (iPad) / "Ask or add" toolbar button (Mac) | The round sparkle button beside the field (⌘J kept on the Mac) |
| The +, top right | The field, focused with nothing typed (as on the phone). C still creates on the Mac |
| **Plan** (iPad) Day · Week switch; then (7–8 Nov) back, forward, Today and "Week ⌄" in the toolbar with the date line's back, name, Today and forward again under it | The Mac's toolbar, three groups (HIG, Toolbars; the owner, 9 Nov 2026; `PlanPagingToolbar`, one view on both): "‹", Today only away from the current period, "›"; then "Week ⌄" with the dates beside it ("Nov 2–8"; Day and Week under the chevron) and the weather; then the field, the sparkle and "…" (booking share, refresh, briefing, availability, setup, Routines) at the right, where the field is on every page. The rail hides like a system sidebar (its button at the toolbar's leading edge, ⌃⌘S) and stays as left. No date line under the toolbar (the owner, 8 Nov 2026: "duplicate week controls") |
| **Plan** (Mac) toolbar: back/forward/Today, a second back/Today/forward group, Day · 3 · 5 · Week switch, magnifier, weather, share, availability, + | The same three groups as the iPad's: "‹", Today away from the current period, "›"; "Week ⌄" with the dates beside it (Day, 3 days, 5 days, Week under the chevron) and the weather; the field, the sparkle and "…" with Share booking link, Share availability and Refresh. The window's title stays out of the toolbar. The rail hides with the system's sidebar button and View › Hide Sidebar (⌃⌘S) and stays as left; Settings is the app menu's (⌘,), not a rail button. View and Go carry Day, 3 Days, 5 Days, Week (⌥⌘1/3/5/7), Previous, Next (⌥⌘←/→) and Today (⌘T); ⌘F goes to the field. K, J and T page, ⇧⌘L (copy the booking link), S (availability), C (new event) and D, 2–7, W (spans) are unchanged |
| **Body** switch (Workouts · Food) | "Workouts ⌄" title menu |
| **Mail** (iPad on its side): search row, accounts row, the column of places, the place's name over the list | One row: "Inbox ⌄" (places, accounts), the field, the sparkle, "…" (reply, reply to all, forward, archive, star, unread, new message); then the list and the reader, with the details closed until `]`. Swipes and keys unchanged |
| **Mail** (Mac) | "Inbox ⌄" and "…" in the window toolbar, beside the window's field and sparkle |

## Badges

The old tab bar's badges, from the same counts (`ActionItems.Counts`, kept by `ActionBadges`),
plus Mail's (`ShellBadge`):

- **Plan**: overdue reminders.
- **Body**: meals to log or check, and doses due and not yet marked (the old Body tab's count).
- **Mail**: the unified Inbox's unread conversations (across accounts), as the mail source
  publishes them with the places (`MailPlaces.mailboxCounts[.inbox].unread`, a `MailCount`):
  the live source counts them on the index's queue (`unread = 1` on the view's partial index,
  capped at 10,000 with "+"), at most once a second and after each commit that touches a view,
  only while the places are observed; kept in `ActionBadges.mailInbox`. The Inbox title keeps
  its own number (conversations, read or not). Mail's store opens two seconds after launch when
  Mail is on, so the badge is there before Mail is opened: it opens the index and reads; no
  network, no sync starts until Mail is shown. Not on the app icon.
- **Notes, Library, Review, Settings**: none.

The closed switcher circle carries the pages that are on, added up; open, each page's circle
carries its own. On the rail (iPad on its side, Mac), always in view, each circle carries its
own and nothing is added up. A red capsule, "99+" past 99. VoiceOver: "Pages, 3 need attention"
on the switcher, "3 need attention" as a page's value.

## Mail's Details

One rule for every layout (`MailArrangement.detailsPlacement`): Details open as the column at the
right of the reading pane where the page lays out beside itself and has room for it (an iPad on
its side, the Mac), and as a sheet everywhere else (a phone, an iPad upright, a conversation open
full width): half height to start, pulled to full, with Done. Two ways in, the same everywhere:
"…" › Details (the reader's "…", or Mail's "…" in the toolbar), and a tap on a message's sender.
`]` and the reader's icon row still toggle the column on its side.

What the field finds hangs under the toolbar's middle (`ShellWideResults`), a solid panel; a
click beside it puts it away, and Esc does on the Mac.

## Mail's composer (direction A, 7 Nov 2026)

The owner chose direction A: the bottom field grows into the composer. `MailComposerBox`
(`Banana/Views/Mail/MailComposerBox.swift`) is the one box; `MailComposerDock` (pure,
`Banana/Model/MailUI/Pure`) says where it is, and `MailNavigation.dock` holds it.

- **Reply** ("Reply or ask", or "…" › Reply): a solid box docked over the keyboard, To and the text
  growing to four lines, then the tools (paperclip, photo, Aa, sparkle) and Send. The text starts
  right under the To line: the typing field shares the chips' line. The thread scrolls on its own
  above it, inset by the box and the keyboard; when the box opens or grows the message answered
  (the newest, at the top) is brought up under the top row, its top first, so its text reads above
  the box. Once he moves the thread himself it stays where he put it until the box folds. On a phone the switcher and
  the sparkle step away; on an upright iPad the switcher stays and the box takes the field's place
  beside it, growing upward.
- **Reply all is the default.** A small "Reply all ⌄" at the start of To switches to Reply or
  Forward (the source makes the draft again by `MailReplyRules`; the text and anyone added by hand
  stay). With one other person on the thread it reads "Reply" and offers Reply and Forward. `R`
  stays Reply and Return Reply all, as `MailKeymap` had them.
- **Expand**: the grab handle up, or ⤢: the box at full height over the thread; ⤡ or a pull down
  brings it back. A new message opens at full height, To first, with a Subject row.
- **Folded while reading**: pulling the thread down, or putting the keyboard away, folds the box into
  the bottom field: the switcher back at its left, the draft on one line and Send in the field. A tap
  resumes. Pulled all the way down the box goes away and the draft is kept (the conversation's mark).
  No Cancel, no "Delete draft?": discard is "…" › Discard draft.
- **Recipients**: To only, with one "Cc" at its end that brings Cc and Bcc. From, with several
  addresses, is in the To line's menu.
- **Send** is one split button: the word sends (⌘↩), the chevron opens send later (⇧⌘L).
- **The sparkle** (only where the assistant is, `ShellAssistant.isAvailable`) turns the tools row
  into one line ("say yes, Friday instead"); the draft is written into the body with one Undo,
  through the on-device model the assistant runs on (`MailDraftAssistant`).
- **Wide** (an iPad on its side, the Mac): the same box docked at the foot of the reader, or filling
  it at full height; the same keys.
- The standalone `--mail` route keeps the card and the sheet (`MailComposerView`), without the
  colour stripe it had.

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
