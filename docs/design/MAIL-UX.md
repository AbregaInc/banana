# Mail: the screens and how they behave

Status: specification, revised 6 Oct 2026 to the owner's rulings on the direction (section 1
has them in his words), after review and verification against the contract. Nothing here is built. This is the UX
half of Mail. The engine half is `MAIL-ENGINE.md`; the order of work, the gates and the
decisions for the author are `MAIL-PLAN.md`.

Who this is for: an implementer building one UI package (MAIL-PLAN section 7), with this file,
`MAIL-ENGINE.md` section 13, the design system (`DESIGN-SYSTEM.md`,
`Shared/BananaDesign.swift`), `ADAPTIVE-LAYOUT.md` and the code. Every rule is numbered so a
test or a review can cite it.

The bar: The author stops using Superhuman. His requirements: performant, very easy to use, every
email cached so it works offline; every action shown at once with Undo, never a confirmation
dialog; one general rule instead of many special cases; standard components before hand-built
ones; keyboard on the Mac, one thumb on the phone. The Mac is built first, and every screen
is built for narrow widths in the same package, not later.

Three things to know before reading:

- **One contract, and it is the engine's.** Every type a screen may name and the one protocol
  it calls (`MailSource`) are declared in `Banana/Model/Mail/MailContract.swift`, whose text is
  MAIL-ENGINE section 13. This document declares no such type. Section 12 says what each screen
  asks of that contract and how fast it needs the answer.
- **Labels are per document.** T, K, G, O, A and U numbers here are this document's. Decisions
  are numbered once, in MAIL-PLAN section 8.
- **Five things rest on platform behaviour that had not been tried.** Each is gated on a
  prototype (14.1): the list's host (P1 — run for iPhone and iPad, its result is in 6.1.8;
  the Mac's half is still to run), keys and type-ahead (P2), message bodies (P3), the phone's
  bars (P4), the composer (P6). Where a section depends on one that has not run, it says what
  the prototype must show and what changes if it shows otherwise.

| § | | § | |
|---|---|---|---|
| 0 | Words | 9 | What only Banana can do (after the first release) |
| 1 | The shape; where the research is overruled | 10 | Accessibility and input |
| 2 | Where Mail lives | 11 | The first release, and what is out of it |
| 3 | The triage loop (T0–T54; 3.12 is the reading pane) | 12 | What each screen asks of the contract |
| 4 | Keyboard (K1–K12, the map, collisions, ⌘K) | 13 | Preview routes, fixtures, and how a screen is checked |
| 5 | Design system additions | 14 | Prototypes and packages |
| 6 | Screens (6.0 is the columns) | 15 | Decisions |
| 7 | Every state, and what it says | 16 | What became of each review finding |
| 8 | Speed | | |

---

## 0. Words

| Word | Meaning |
|---|---|
| **Conversation** | A Gmail thread in one account. The thing a row shows and an action acts on. |
| **Message** | One email inside a conversation. |
| **Done** | Archived: out of the inbox, still in All mail. Never "Archive" in the interface. |
| **Place** | What a list shows: a *split* (a tab of the inbox), a *mailbox* (Inbox, Starred, Important, Drafts, Snoozed, Sent, Outbox, Done, All mail, Spam, Trash, Muted), a *label*, a *search*, or the list behind a held removal (7.5). |
| **Scope** | A place plus the filters on it plus an account, if narrowed to one (`MailScope`). A scope is exactly one list. |
| **Key** | A row's position in its list (`MailOrderKey`). The engine makes keys and decides what order means in each place; the UI only compares and stores them. |
| **Cursor** | The conversation the next action applies to. An open conversation is always the cursor. |
| **Column** | One of Mail's four side-by-side parts: the *control column* (places), the *list*, the *reading pane* and the *details column*. Mail's measured width decides which show (6.0). |
| **Showing** | What the reading pane has on screen: the target (T47). A conversation that is showing is not yet open. |
| **Open** | A conversation that has the keys: it is showing and focus is in it (T49). Where there is no pane, an open conversation covers the list. |
| **Direction** | Which way the person is travelling through a list: *older* (down) or *newer* (up). |
| **Target** | What an action acts on (T15). |
| **Idle** (also: *at rest*) | Three seconds with no key press, touch, scroll or pointer movement over the list, and no row mid-swipe. Entering a place and closing a conversation are inputs like any other, so the three seconds start from them. A list covered by an open conversation is at rest whatever the clock says (T7). |
| **Compact / regular** | The two arrangements of Mail's chrome and of the inside of a column (`LayoutClass`): under 600 pt, and 600 pt and up. How many columns show is a separate rule, also by width (6.0). Never "iPhone layout" or "Mac layout". |

---

## 1. The shape, in one page

1. **Mail is columns, and a column shows when there is room for it.** Left to right: the
   control column (places), the list, the reading pane, the details column. Mail's measured
   width decides which show, never the device, and as it narrows they drop in a fixed order —
   details, control, pane — until what is left is a phone's list, then conversation (6.0).
   The pane and the two side columns are options he can switch off; the choice is
   remembered. (The owner's ruling. It replaces this document's first rule, which was that a
   Mail screen shows one thing.)
2. **Everything on screen is read from the device.** No view asks the network for anything or
   waits for it. A wait is shown only for something that has never been on this device.
3. **One action model** (T0): every action is applied at once and remembered for Undo; an
   action that finishes with a conversation also moves the cursor to the nearest one left.
   The same on every device, online or off, in a split, a label or a search.
4. **Nothing moves under the hand.** What a row *says* is always current. Rows are added,
   removed or moved by something other than the person's own action only when the list is
   idle (T7), and never the row that has the cursor (T8).
5. **An action acts on what was shown** (T45). Mail that arrived and was not drawn is never
   marked Done or read by a key pressed before it was seen.
6. **Keys are Superhuman's, scoped.** A key belongs to the section in front and, inside Mail,
   to what has focus (section 4). A letter typed is never run as a command, including in the
   moment before a text field appears (K12).
7. **The screen says how much it knows.** One status line says when the list is not live; a
   count that may be incomplete ends in "+"; the foot of a list says why it ends (section 7).

### Where this overrules the research (`mail-working/research/product-ux.md`), and why

| # | Research said | This spec says | Why |
|---|---|---|---|
| O1 | New mail never moves the cursor row; a "2 new" chip shows instead. | New mail joins the top of a list that is at its top and idle; otherwise it waits in the chip (T9). | An inbox left open must show the mail, not a chip about it. Three seconds of idleness is long enough that a thumb or a pointer is not already on its way. |
| O2 | No session-long undo on touch; the toast is the undo. | One undo stack on every device, with a button for it on the phone for two minutes after an action (T44). | One rule. The stack exists for the Mac. |
| O3 | Swipes built as row gestures. | The system's list swipe actions only (6.1.6). | A drag gesture on a row stops the list scrolling on iOS 26 (measured; owner note `banana-ui-test-and-gesture-gotchas`). |
| O4 | iPad by touch gets the Mac layout plus the phone's bottom bar. | Regular has header actions and no bottom bar. | A choice, not a law: an iPad is held in two hands or stands on a keyboard, and a third arrangement costs every screen. To be looked at again after a week on an iPad. |
| O5 | Pull down to search, and pull down to check mail. | Pull checks mail. Search is a button in the phone's bottom slot. | One gesture, one meaning; and search was out of reach at the top. |
| O6 | A floating compose button; splits at the top. | One bottom slot on the phone holding splits, Search and Compose; the same slot holds a conversation's actions (6.1.3). Its exact form is prototype P4's to settle. | Everything a thumb needs in one strip that stays where it is within a screen. |
| O7 | Answering an invitation marks the email Done. | Answering restyles the card and moves nothing; the answer is the calendar's and so is its Undo (T14, 9.1). | `Z` does what the toast on screen offers (T26), so there is one undo to reason about, not two. |
| O8 | A late rule chosen per scheduled message. | One rule and no setting: up to 30 minutes late it goes and says so; later, it asks (6.5.5). | A late send is the one thing that cannot be taken back, and it can only be late when he has just opened the device. |
| O9 | `Tab` steps through links and dates in a conversation. | `Tab` reaches the invitation's buttons, attachments and the reply field; links are clicked. | Focus inside rendered HTML is a project of its own. |
| O10 | Snippets, ⌘J, lists and quote formatting in the first release. | Out (section 11). Find in a conversation, which the first draft also left out, is back in. | Each is real work that does not decide whether Superhuman can be dropped; find does. |
| O11 | "Done marks as read" and "Reply key" as settings. | Done marks what was shown read; Enter is reply-all. No settings. | Fewer switches. Both are what Superhuman does. T45 is what makes the first safe. |
| O12 | A scheduled message is sent by whichever device is awake. | By the device it was scheduled on — and every device shows a late one as late and can take it over (6.5.5). | The engine's rule: with no server and no lock between devices, one owner is the only arrangement that cannot send twice. The interface tells the truth about it. |
| O13 | Remote pictures load when a conversation is opened. | Ask first (6.2.6). | Without a server to fetch through, a picture tells its sender his address and the minute he opened the mail. |

### Where the owner has overruled this document

His words, 6 Oct 2026, on seeing the direction for the first time.

| | This document said | He said | Now |
|---|---|---|---|
| R1 | The Mac first; the phone's screens last. | "For now we can focus on Mac but we should be building to support Mobile from the get go." | The order stands. Every package builds its screen for narrow widths as well (14.2); only the phone's bottom slot and its seat still wait, for a prototype and for his choice. |
| R2 | A Mail screen shows one thing; no reading pane; no second sidebar. | "I think a reading pane should be a valid option. I kind of expect a 3 or even 4 column layout? 1. Control Column 2. Mail list 3. reading pane 4 metadata, enrichment, etc." | Columns by width (6.0); the triage rules with a pane (3.12); the control column (6.6); the details column (6.10). |
| R3 | Superhuman's keys and triage model. | "Ok." | Stands. |
| R4 | The whole mailbox on every device; what only Gmail finds in a second group. | "We should allow a sync limit, so lets say 6 months by default. Also we should merge local search with cloud search if duration is not unlimited." | A limit per device, six months by default (6.8.1); the edge of it in a list and in a conversation (6.1.7, 6.2.11); one merged list of results (6.4.3). |
| R5 | Send later and Remind me if no reply after the first release. | "I want these...." | Both in the first release (6.3.6, 6.5.5, section 11), with every statement of their limits kept. |
| R6 | Pictures: ask first, or always from a domain. | "Default to ask, but allow to set always for this sender, always for this domain, and always period." | Four levels (6.2.6, 6.8.1). |

---

## 2. Where Mail lives

### 2.1 One order, everywhere

`AppSection` gains `case mail`, second in the enum:

`plan, mail, workouts, sleep, trends, nutrition, notes, routines, library, settings`

- Title "Mail", symbol `envelope.fill`, `DS.Palette.Feature.mail` (5.1) for its Settings tile.
- The enum's order is the Mac sidebar's order, the iPad sidebar's order and the phone's bar
  order. That is already true today and stays true: the phone shows five of the ten.
- Raw value `mail` is what `--tab` and `--mac-section` use.

### 2.2 The Mac and the iPad first; the iPhone's seat last, from a picture

Mail is built Mac-first (section 11). The seat follows the same order.

**Package U1a** adds the section where a sidebar exists and changes nothing on the phone:

- **Mac:** a sidebar row, second. `macShortcuts` derives the numbers from position: **⌘1 Plan ·
  ⌘2 Mail · ⌘3 Workouts · ⌘4 Sleep · ⌘5 Trends · ⌘6 Nutrition · ⌘7 Notes · ⌘8 Routines ·
  ⌘9 Library**. Seven sections move down one number. That is nine, which is all there are: a
  tenth traps today (`KeyEquivalent(Character(String(index + 1)))`, `MacRootView.swift:523`),
  so U1a changes the loop to `AppSection.macShortcuts.prefix(9)`.
- **The Mac measures.** `MailSection` chooses its arrangement from `\.layoutClass`, whose
  default is compact and which nothing on the Mac sets. U1a's `case .mail` in `MacRootView`
  applies `.measuresLayoutClass()`, and gives Mail's column a minimum width of
  `LayoutClass.regularWidth` (the window already sizes to its content's minimum), so on a Mac
  Mail is always regular. The offscreen snapshot views do the same.
- **iPad:** a sidebar row, second, added inside the existing `if showsSidebarSections` with
  `.tabPlacement(.sidebarOnly)`. In a narrow split it is not in the bar until U1b.
- **The first frame.** `.measuresLayoutClass()` starts at compact and corrects itself after
  the first layout. `MailSection` therefore takes its first frame's arrangement from the one
  it last measured (kept in `MailSession`), or, with none yet, from the horizontal size class.
- **The Mac's calendar gate** (`MacGatedRootView`) is unchanged: Mail needs a connected Google
  account, and so does it.

**The iPhone's bar is full** (five tabs; `AdaptiveShellUITest` asserts it) and the IA record
forbids a sixth. Mail needs a seat: one-thumb triage does not survive a second tap, and its
badge has to be visible from every tab.

**Recommendation: Mail takes Notes's seat, with capture kept one tap away.** The bar becomes
Plan · Mail · Workouts · Nutrition · Library.

- Notes is the least costly seat, not a free one. The Notes tab is where a note is started
  when nothing is playing: its first row is the capture card and its second is "Write a note
  instead" (`NotesView.swift:112–128`). So the move is only acceptable if starting a note
  costs no more than it does now.
- **What Notes becomes on a phone.** Library, compact, gets a two-part switch in its
  navigation bar — **Podcasts | Notes** (the Food | Supplements pattern) — and **Record** and
  **Write** buttons in that bar *in both parts*. From anywhere: Library, Record — two taps
  where today it is two (Notes, capture card). Reading a note back goes from one tap to two.
  On an iPad sidebar and the Mac, Notes keeps its own row.
- **Runner-up: Mail inside Plan**, behind an envelope button with the count in Plan's header.
  The five tabs stay. Every visit to Mail is two taps and the count shows only from Plan.

**He chooses from a picture** (MAIL-PLAN section 8). U1a makes the picture possible without
changing his phone: in DEBUG the launch argument `--mail-seat` swaps the bar to the
recommended five and shows Library with its switch. On a phone `--tab mail` implies it
until U1b, so the gate's phone route runs as MAIL-PLAN writes it.

**Package U1b**, last in the first release, makes the choice real. It is one line —

```swift
/// The phone's bar, in bar order. Sections not listed live under `tabBarHome`.
static let iOSTabs: [AppSection] = [.plan, .mail, .workouts, .nutrition, .library]

/// Where a section lives when it has no seat. Inert for a section that has one.
private static let homes: [AppSection: AppSection] =
    [.sleep: .workouts, .trends: .workouts, .routines: .plan, .settings: .plan,
     .notes: .library, .mail: .plan]
var tabBarHome: AppSection { Self.iOSTabs.contains(self) ? self : (Self.homes[self] ?? .plan) }
```

— because U1a already made `RootView.mainTabs` declare every section's `Tab` once, in enum
order, placed by whether `iOSTabs` contains it. The doorway for whichever section loses its
seat is the only other code: the Library switch for the recommendation, the envelope button
for the runner-up. `AdaptiveShellUITest` keeps its assertion (five tabs, no More) with the
chosen five.

### 2.3 Accounts, splits, labels

One inbox across accounts. An account is a filter, not a place to switch to.

| What | Where the control column shows | Where it does not: narrower, or switched off |
|---|---|---|
| **Splits** | Its first group, each with its count. `Tab` / `⇧Tab` cycle them. | Regular: text tabs with counts at the leading edge of the list's header. Compact: chips in the bottom slot (6.1.3). |
| **Everything else** (mailboxes, labels, accounts) | The rest of the column (6.6). `G` keys; ⌘K. | The same view as **Places**: a popover from the ≡ button (regular), a sheet from the ≡ chip (compact). |
| **Narrow to one account** | The column's Accounts group; `⌃1`…`⌃9`, `⌃0` for all. | Places › Accounts; in compact also the header's filter menu. |
| **Which account a row belongs to** | A short chip on the row, only when two or more accounts have Mail and the list is not narrowed (6.1.1). | Same. |

**Mail has a control column of its own**, beside Banana's sidebar (6.6). That is the
recommendation, and it is a question for the author, with a picture: the other way is to nest
Mail's places under the Mail row of Banana's own sidebar, which makes his four columns
exactly four on the Mac (6.0.6).

The splits partition the inbox: every conversation in it is in exactly one.

| Split, in the order shown | Holds |
|---|---|
| **Important** | In the inbox and marked important by Gmail — and not claimed by a split below. |
| **Calendar** | Invitations and replies to them. |
| *Custom splits, in the order the person put them* | What a saved query matches (6.4.4). |
| **Other** | Everything else in the inbox. Always last; cannot be removed. |

Which split a conversation is in is decided most specific first (the engine's 9.3): the
first custom split whose query matches it; else Calendar; else Important or Other. The order
*shown* is the person's own, with Important first by default; "the first split" in this
document (badges, `G` `I`, a cold launch) means the first shown.

### 2.4 Badges

| Where | Number | Rule |
|---|---|---|
| Mail tab (iPhone), Mail sidebar row (iPad, Mac) | Unread conversations in the **first** split, plus things waiting on his answer (`MailBadgeCounts`). | Read by `ActionBadges` through `MailBadgeCounts.mirrored(in:)`. The mirror's key and its reader are in the contract file, so the seat reads it before any engine has written it; no store is opened and no engine is made to draw a badge. |
| App icon, Dock | Things waiting on his answer only. Unread mail does not count, and there is no switch for it. | The icon keeps meaning "something needs you today". |
| Split chips and tabs | Conversations in the split, read or not. "40+" while the count may be incomplete (7.4). | Triage is about what is left, not what is unread. (`MailPlaces.splitCounts[id].total`.) |
| Places: Drafts, Snoozed, Outbox | Their counts. Outbox also shows an attention dot while something in it needs him. | |
| Places: accounts; the account card | `StatusDot` and a word (7.5). | |
| Settings root, "Mail" row | Trailing value: "2 accounts", or "Off". | |

"Waiting on his answer" is `MailBadgeCounts.needsAnswer`: a send that failed for good, and
the open questions about a send — one Banana cannot confirm, one that has waited more than a
day, and a late scheduled message (7.6, 7.7). A held removal and lost changes raise a
card (7.5), not the badge. Nothing is badged for mail that is merely unread in Other, in a
label, or snoozed.

---

## 3. The triage loop

Rules are written *Given … when … then …* so each is one test. They are implemented once, in
a model with no views (`MailListModel`, 3.11), and tested there, before any screen is built;
the UI tests check that the screens obey the model. K9 (section 4) is the only rule about
`Esc`.

### 3.0 The governing rule

**T0.** Every action, in one run-loop turn and with no knowledge of the network:

1. **Apply.** The change is made in what the screen shows, by handing it to the source, which
   has shown it in every list before the call returns (the contract's promise 2), stores it,
   and delivers it to Gmail when it can.
2. **Remember.** What was showing — the list, the cursor, the selection, the open
   conversation and where it was scrolled — goes on the undo stack with the change.

An action that finishes with a conversation — a *disposing* action (T14) — also:

3. **Settles.** The cursor moves to the nearest conversation, at or beyond its place in the
   direction of travel, that was not a target; failing that, the nearest the other way. The
   view follows the cursor as T4 says: its row shown whole, with one more row beyond it.

A *marking* action moves nothing (T17). First, last and only rows; a split, a label, a
filtered list and search results; one conversation or five hundred; online or offline: none
of these is a case.

### 3.1 The list and the cursor

**T1. Order.** *Given* any list, *then* its rows are in the order the source delivered them
(descending `MailOrderKey`). The UI never sorts, and compares positions by key, never by row
number. What order means is the engine's: newest first in the inbox; in a search, what only
Gmail found comes after what the device found; a conversation back from snooze is first when
it comes back.

**T2. There is one cursor.** *Given* a list with at least one conversation, *then* exactly one
of them has the cursor; an empty list has none. It is drawn (6.1.2) always on the Mac; on an
iPad or a phone, from the first key pressed on a hardware keyboard or the first pointer
movement until the next touch. On touch alone it is not drawn, but it exists: it is the row
last tapped, and the open conversation.

*Given* a list that has rows and no cursor — every row was a target and some stayed, or an
open conversation that had left the list was closed — *then* the cursor is put on the row
nearest the place it last had, by key, whether or not that row was a target. It is never put
on the first row for want of a place. The one time a list with rows has no cursor is while a
conversation that has left it is still open (T13).

**T3. Entering a place.** *Given* a place not yet visited since launch, *when* it is shown,
*then* the cursor is on the first conversation, the list is at the top and the direction is
*older*. *Given* a place visited before, *when* it is shown again, *then* the cursor is on the
conversation it was on if that is still in the list, otherwise on its successor (T6); the list
is where it was, to the point (T46); and the direction is *older*.

Entering a place is an input. What was waiting for that place is applied as it is shown, and
the reading that answers the entry is taken whole, because he asked for it (T7). But the list
is not at rest because he has just arrived: mail that comes in the next three seconds waits
in the chip (T9). Otherwise every row would move down as a thumb comes in to tap one.

**T4. Moving.** *Given* the cursor on a conversation, *when* `J` (or `↓`) is pressed, *then*
the cursor moves to the next older conversation and the direction becomes *older*. `K` (or
`↑`) moves to the next newer and the direction becomes *newer*. At either end nothing
happens: no wrap, no beep. The list scrolls only as far as needed to show the cursor row
whole, with one more row beyond it in the direction of travel when there is one. `Space` and
`⇧Space` scroll a page (with the reading pane showing they scroll the pane instead: T50); if that leaves the cursor row off screen, the cursor moves to the
first row fully on screen. `⌘↓` puts the cursor on the oldest row loaded and `⌘↑` on the
first row (T9); both set the direction to *older*.

**T5.** Moving the cursor never marks anything read and is never an undo step.

**T6. Successor.** The successor of a place in a list, for a set of *targets* (possibly
empty), is: the nearest conversation **at or beyond** that place in the direction of travel
that is in the list and is not a target; if there is none, the nearest such conversation in
the other direction; if there is none at all (every conversation was a target), the cursor
stays where it is if that row is still in the list, and otherwise goes to the row nearest
that place, target or not (T2). There is no cursor only when the list is empty. So a cursor
conversation that was not a target and is still in the list is its own successor.

**T7. What a row says is always current; where rows are changes only when idle.** *Given* a
change that did not come from this device's own hands (new mail, a change made on another
device, a snooze coming back): what a row *says* — unread, snippet, date, labels, star, its
reason line — is redrawn at once, where the row is. Rows are added, removed or moved only
when the list is idle (section 0), and then all at once. The person's own actions, and the
engine's reversal of one (T36), are never delayed by this.

**Only a change from elsewhere waits.** A reading the person asked for is applied at once,
idle or not: the next rows as the list grows towards its end (6.1.7); the row that fills the
foot after his own action; the reading that answers entering a place (T3); a check he asked
for (⌘R, a pull); an undo (T26). And in every reading, rows that belong after the last row
shown are appended at once, because adding below the last row moves nothing. So a held `J`
never runs out of rows it could have had, and ten `E`s in a long place leave the foot
filled. The one thing an asked-for reading cannot do is put a row above a list that is not
showing its top (T9).

**A list covered by an open conversation is at rest.** While a conversation is open, outside
changes are applied to the list beneath it at once, and whatever was waiting is applied as
the conversation opens: nothing can move under a hand that cannot reach it. Closing is a key
press, so the three seconds start again from it.

**T8. What an outside change does when it is applied.**
- (a) A conversation that left the list disappears. If it had the cursor, the cursor moves to
  its successor (T6, no targets) — unless it is the open conversation, which stays open with
  no row (T13).
- (b) A new conversation, or one with new mail, takes its place in the order. One exception:
  **the conversation under the cursor does not move.** It has already been redrawn where it
  is (T7); it takes its new position the next time changes are applied after the cursor has
  left it.

**T9. Arrivals at the top.** *Given* new rows that belong above the first row: *if* the
list's first row is on screen and the list is idle, *then* they join the top and are seen
arriving; the cursor stays on its conversation, which moves down. *Otherwise* they are not
added: a chip at the top edge of the list counts them ("2 new"). They join when the chip is
used or `⌘↑` is pressed (both go to the top; `⌘↑` also puts the cursor on the first row), or
the next time the first row is on screen and the list is idle. **No row is ever inserted
above a list that is not showing its top.** Whether the first row is on screen is the scroll
view's fact, reported by the host (6.1.8).

*Given* a list that has been emptied (T19) and is not yet at rest, *when* mail arrives,
*then* its row does not appear at once — the last `E` of a run would mark Done something he
has not seen — and the chip shows over the empty state, which gives way to it: a place never
says it is clear while mail is waiting. With no rows on screen, every row of a waiting
reading counts as an arrival.

**T46. A position is a row and points.** Wherever a list's position is recorded, restored or
handed to the host — entering a place (T3), closing (T11), an undo entry (T25, T26), a
rebuilt view tree and a cold launch (8.4, 3.11) — it is the key of the row that was first on
screen and whole points into that row. Never an id alone: when that row has left, the first
row at or after its key stands in for it, at offset 0. Never an offset from the top, and
never a row number times a height: the list estimates the rows it has not drawn (52 pt
against 64 pt drawn, in prototype P1), so an absolute offset cannot be restored. (Numbered
out of order: this rule was written down after the model was first built.)

### 3.2 Opening and closing

**T10. Open.** *Given* the cursor on a conversation, *when* `Enter` or `→` is pressed, or its
row is clicked or tapped, *then* the conversation is shown over the list (regular) or pushed
(compact). It is marked read once it has been showing for 400 ms; a conversation passed
through with `J` or `K` sooner than that is not. Being marked read by opening is not an undo
step; `U` reverses it. What is marked read is what has been on screen: with a message below
the fold that has not been seen (T13), the messages seen are marked (`MailTarget.message`),
and that message is marked in its turn once it has been on screen for 400 ms. A conversation
that Undo reopens unread starts its 400 ms like any other. (With the reading pane a
conversation is showing before it is opened: T49 says what opens it, T51 when it is read.)

**T11. Close.** *Given* an open conversation, *when* it is closed (K9, `←`, Back), *then* the
list is where it was (T46) — in the regular arrangement it never left — with whatever
changed while it was covered already applied (T7), and the cursor on that conversation if it
is still in the list, otherwise on its successor (T6).

**T12. Next and previous.** *Given* an open conversation, *when* `J` or `K` is pressed, or
the older or newer button is used (T42), *then* the next older or newer conversation opens in
its place in the same frame and the direction is set. At the end of the list nothing happens
and the button is disabled. Held down, the key acts once (K7).

**T13. Reading is not interrupted.** *Given* an open conversation, *when* an outside change
removes it from the list, *then* it stays open. A new message in it is added as a card at the
end at once: nothing above it moves and the reader does not scroll; if the end is not on
screen, a chip at the bottom edge reads "1 new message". While it is open and no longer in the list, no
row has the cursor and its place is remembered by key; the next `J`, `K`, close or action is
worked out from that place against the list as it then is. An action on it still acts on it,
though it has no row (T15). The same holds for a conversation showing in the pane (T52).

### 3.3 Actions

**T14. Three kinds of action.**

| Kind | Actions | What it means |
|---|---|---|
| **Disposing** | Done `E` · Trash `#` · Spam `!` · Move `V` + a label · Remove this label `Y` · Send and Done · in Done, Spam and Trash: `⇧E` (Back to the inbox, Not spam, Restore) · Snooze `H` + a time (with package U8) · *after the first release:* Mute `⇧M` · Add to plan `A` + a time · Unsubscribe ⌘U | "I am finished with this one, here." The cursor advances. |
| **Marking** | Read/unread `U` · Star `S` · Label `L` · elsewhere: Not done `⇧E` | "Note this about it." Nothing moves. |
| **Another feature's** | Answering an invitation (9.1) | Done by the calendar. Its confirmation and its Undo are the calendar's toast. Nothing in Mail moves and nothing goes on Mail's undo stack. |

**T15. Target.** The open conversation, if one is open; otherwise the selected conversations,
if any are selected; otherwise the cursor conversation. The reading pane, when it shows,
always draws this target (T47). `R` and `F` with a selection do
nothing.

**T16. A disposing action.** *Given* a target, *when* a disposing action is taken, *then* in
one turn:
1. Each target the place no longer holds leaves the list (the contract's `MailRowRules`
   decides, from the row and the scope alone). A target that stays shows what changed: Done
   in All mail or a label removes its inbox glyph (6.1.1). Where the rule cannot say whether
   the target still belongs — a search, Drafts, a custom split — it answers
   `unknown(MailRow)` with the row as changed: the row is drawn as changed, where it is, in
   the same turn, and the next reading decides whether it stays.
2. The selection is cleared, when the selection was the target.
3. The cursor moves to the successor of its place (T6) with the targets as targets. So it
   advances even when its row stays.
4. If a conversation was open: the new cursor conversation opens in its place when it lies in
   the direction of travel; otherwise the view returns to the list (the run has reached its
   end).
5. An undo entry is pushed (T25) and the toast shows (7.9).

*Given* an action that would change nothing (Done on a conversation that is not in the
inbox and is read), *then* nothing is sent, no toast shows and no undo entry is pushed; steps
3 and 4 still happen. Whether it would change nothing is read from `MailRowRules`' answer for
the rows named — the row it hands back equals the row it was given, **its pending mark
aside** — and is not a guess from one flag. Done on a snoozed conversation ends the snooze,
so it is sent. Done on a conversation that is out of the inbox and unread marks it read, so
it is sent, and says "Marked “…” Done". And an action whose whole effect a row cannot show is
never "nothing": a move, a label put on, a snooze, a send. It is never decided on the device for a
selection by scope, which includes rows that are not loaded: that change is always sent. And
an action that names a conversation whose row has left the list is still sent: a picker acts
on the conversation it was opened for, wherever the cursor has moved since.

**T17. A marking action.** *Given* a target, *when* a marking action is taken, *then* the
targets update where they are and nothing else changes: not the cursor, not the selection,
not the view. A row that no longer matches the list's filter is **kept**: `MailRowRules`
answers `leaves(MailRow)`, carrying the row as changed, and the list goes on drawing that row
until the scope changes (another place, a filter turned on or off, an
account narrowed) or the list is refreshed (⌘R, a pull). **A marked row is kept by the action,
whatever the next reading says** — not only when the rule answered `leaves`: the rule has no
custom split's query, so it may answer `stays` or `unknown(MailRow)` for a row that a custom
split then claims, and that row is kept in the same way. Closing a conversation, or coming
back from the background, does not drop it. A kept row is drawn like any other until a
reading omits it; from that reading on it is dimmed (6.1.1), which says "kept, though it no
longer belongs here". A reading that includes a kept row makes it an ordinary row again.

Toggles act on the whole target: `U` makes all unread if all are read, otherwise all read;
`S` stars all if any is unstarred, otherwise unstars all. **In an open conversation `U` is
not a toggle**: it always means "leave this unread and go back". The conversation is made
unread and the view returns to the list, because staying would be reading it. If it is
still unread — the 400 ms of T10 have not passed — nothing is sent, the pending read is
dropped, and the view returns all the same. It is decided from the conversation, not from a
row, so it holds when the row has left the list.

**T18. Keys are never dropped, and never repeat by accident.** *Given* ten presses of `E`
within one second, *then* exactly ten conversations are marked Done, in list order, each
press acting on the cursor the previous press left. No animation delays or absorbs a key or a
tap. *Given* any action key held down, *then* it acts once (K7).

**T19. Emptying a list.** *Given* an action that removes the last conversation, *then* the
place's empty state shows (7.8) and the place stays in front; `Tab` moves on.

### 3.4 Selection

**T20.** `X` adds the cursor conversation to the selection, or removes it. The cursor does not
move.

**T21. A run.** The first `⇧J` or `⇧K` after any other key or click sets the *anchor* at the
cursor conversation **and moves the cursor one row**: one `⇧J` from C selects C and D, as in
Superhuman and as `⇧↓` does in every list on a Mac. (At the end of the list the cursor
cannot move, and the press selects its conversation alone.) Each further `⇧J` or `⇧K` moves
the cursor one row; the run is every conversation from the anchor to the cursor, and
reversing shrinks it to the anchor alone and then grows it the other way. Any other key ends
the run: its rows stay selected, and the next `⇧J` starts a new run from wherever the cursor
then is. Conversations selected with `X` outside the run stay selected.

**T22. Selecting by scope.** `⌘A` selects from the cursor down; `⌘⇧A` selects the whole list.
Both mean **the list as it stood when the key was pressed**: the selection is the scope and
the key of its first selected row (`MailTarget.scope(_:from:)`), so it includes rows not
loaded on screen and excludes anything that arrives afterwards (T45). The header reads back
the count from that moment ("1,204 selected"; "1,204+ selected" while the count may be short;
"· on this iPhone" appended while that account is still downloading). A selection by scope is
all or nothing: `X` inside it does nothing. On screen, a row is in it only if its key in the
newest reading is at or after the selection's key; and the count read back leaves out
arrivals waiting in the chip, which it does not include.

**T23. Lifetime.** Leaving the place clears a selection. Opening a conversation keeps it;
actions taken inside the open conversation act on that conversation only (T15) and leave the
selection as it was.

**T24.** An outside change never alters a selection made row by row except to drop
conversations that left. A run that is still live (T21) is fixed to its rows as soon as a
row is added or removed under it, so what is selected is always exactly what is drawn as
selected.

### 3.5 Undo

**T25. What is remembered.** Every disposing action, every marking action, every send and
every discarded draft pushes one entry: the source's receipt for the change; one line
describing it; the scope that was showing; the cursor; the selection; the conversation that
was open or showing in the pane, if any, with the message at the top of the reader, its
offset, and whether it was open; the list's position (T46);
and the row values of the conversations that left. For Send and Done the entry is made in two
halves (T38). Not pushed: being marked
read by opening; another feature's action (T14); an action that changed nothing (T16).

**T26. What `Z` does.** `Z` (and ⌘Z outside a text field) **does what the toast on screen
offers; with no toast showing, it undoes the top of Mail's stack.** So after an invitation is
declined `Z` undoes the decline, because that is the toast showing; a minute later `Z` is
Mail's.

*Given* an entry being undone, *then* in one turn: the change is reversed for every target,
each conversation getting back exactly what it had (its labels; unread, if Done had marked it
read); if another scope is showing, the entry's scope is shown; the rows are back in their
places; the cursor, the selection and the list's position are as recorded; and the open
conversation is as recorded — if one was open it is open again at the recorded position, and
**if none was open then and one is open now, it is closed**, because the cursor is going
back to a row and an open conversation is always the cursor. Undoing a send within its hold
is the one undo that waits: it awaits `cancelSend`, a few milliseconds, and then reopens the
composer. One press undoes one action, whether it touched one conversation or five hundred.
The toast then reads "Undone", with the action **Undo previous: Marked Done** when the stack
has another entry.

**The rows come back from the entry, not from a reading.** The entry holds the rows as they
were, and they are put back in the same turn — also in a place that was not in front and has
not been read since. A reading older than the undo cannot take them away again: the undo's
receipt becomes the floor below which the list accepts no reading. A row that the next
reading does not have is then removed (T30).

**T27. How deep.** Fifty entries, for as long as the app stays in memory, per device — the
same fifty the engine can still reverse. The toast shows the top entry for six seconds; the
entry outlives the toast. Mail puts nothing in the shared toast's single pending slot: its
changes are already stored when the toast shows, it shows its toasts through
`ToastCenter.present` (5.2), and it keeps its history here.

**T28. What cannot be undone.** Everything in Mail is reversible except:
- **a message that has left.** *Given* the top entry is a send whose hold (6.3.7) has ended,
  *when* undo is asked for, *then* nothing is unsent, the entry is dropped and the toast
  reads "Already sent." If it was Send and Done, `undo(receipt)` after the hold reverses the
  Done alone: nothing is unsent, the row is put back and the cursor restored from the entry
  (T26), and the toast reads "Already sent. “Q3 numbers” is back in the inbox.";
- **an unsubscribe**; **an answer to an invitation** once the organiser has been told (change
  the answer instead); **a label once created** (it can be taken off conversations, not
  deleted, in Banana); and **"Remove here"** for mail Gmail says was deleted (7.5).

Each of these says so where it is offered, and none of them is a single unconfirmed key.

**T29.** There is no redo. `⇧⌘Z` does nothing outside a text field.

**T30. Undo meets a changed world.** Undo reverses only its own change. A target that no
longer exists is skipped. *Given* `undo` answers with a count of zero — every target is gone,
or the engine can no longer reverse the change — *then* nothing changes, the entry is
dropped, and the toast reads "That can no longer be undone." The two causes cannot be told
apart, so there is one toast.

### 3.6 Places, filters, search

**T31.** `Tab` shows the next split and `⇧Tab` the previous, wrapping; an empty split is not
skipped. From a place that is not a split, `Tab` shows the first split and `⇧Tab` the last.
Each place keeps its own cursor and position (T3). **`Tab` changes the split and nothing
else**: the account the list is narrowed to and the filters that are on carry to the next
split, where the header shows them, and `Esc` clears the filters (K9). A `G` key (4.2.5)
keeps the account and drops the filters.

**T32. Filters.** *Given* a filter turned on or off (`⇧U` unread, `⇧S` starred, `⇧I`
important, `⇧R` no reply), *then* the list is the filtered list, and the cursor is on its
conversation if that is in it, otherwise on its successor by key (T6). The view shows the
cursor row (T4); it does not go to the top. Filter keys act in the list only.

**T33. Search results are a list.** Same keys, same actions, same rules.

**T34.** Narrowing to an account is a filter (T32).

### 3.7 Offline, waiting, failing

**T35. Offline is not a mode.** *Given* no network, *then* every rule above behaves
identically and every result looks identical. The status line (7.2) says how many changes are
waiting. Undoing a change that has not been delivered cancels both.

**T36. A change that cannot stand.** *Given* a change Gmail refuses for good, or one the
device could not save, *then* at once — this is the answer to his own action, so T7 does not
delay it — the conversation is shown as Gmail has it, back where the order puts it, with the
reason on its row (6.1.1) for a refusal; the toast says what and why ("Couldn't move “Q3
numbers”: that label no longer exists." with **Retry** — but no Retry when Gmail's limit for
the day was reached, which trying again cannot help; "Couldn't save that: this iPhone is
full."); its undo entry is removed; and a refused change is listed in Outbox with **Retry**
and **Discard** until he chooses — from `status.value.refused`, one `MailRefusedChange` per
action, so the list is still there after a relaunch. Brief failures are retried in silence and never reach this
rule. A conversation Gmail no longer has is not a refusal: the change counts as done.

**T37. The device's own changes are not news.** *Given* the next reading includes a change
this device made, *then* nothing on screen changes and no chip appears.

**T38. Replying from the list.** *Given* the cursor on a conversation in the list, *when* `R`
or `F` is pressed, *then* the conversation opens with the composer open and the caret in the
body, in one step, and what is typed next goes into it (K12). *Send and Done* (`⌘⇧↩`) is a
send followed by Done on that conversation as one action with one undo entry. **The composer
pushes that entry.** The model moves the cursor and the open conversation as for any Done
(T16) and hands the composer the screen half of the entry — what was showing, and the row as
it was — without a receipt; the composer completes it with the send's receipt and pushes it.
Undone within the hold, the send is cancelled and the Done reversed: the conversation and
the composer are open again as they were. Undone after the hold: T28.

### 3.8 Touch

**T39.** Tap opens (T10). Long-press on a row starts selecting: that row is selected, the
unread lane shows check circles, taps now toggle rows, and the bottom slot shows the
selection's actions (6.1.5). The header's Cancel, or acting, ends it. More › Select and the
VoiceOver action "Select" start it too.

**T40. Swipes** (system list swipe actions, 6.1.6). A full swipe from the trailing edge is
Done. Either swipe is T16 with that row as the target.

**T41. The action bar** in a conversation (6.2.1) holds its actions in fixed positions. Done
is T16; the next conversation appears under a bar that has not moved.

**T42. Next and previous by touch.** The conversation's navigation bar has an older and a
newer button at its trailing edge, disabled at the ends of the list (T12). They act on
nothing. A swipe along the action bar for the same thing is added only if prototype P4 shows
it does not fight the system's back swipe.

**T43.** Pulling the list down checks for mail now (7.2).

**T44. Undo by touch.** The toast's Undo is T26. For two minutes after the newest entry the
bottom slot shows an **Undo** button (6.1.3), so a wrong swipe noticed late, or the action
before the last, is one tap each. After that the stack is in More › Undo, titled with the
entry's description.

### 3.9 What was shown

**T45. An action acts on what was shown.**
- *Given* a conversation in a list, *then* an action on it is as of what its row says, which
  is current (T7).
- *Given* an open conversation with a message that has not yet been on screen (T13's chip is
  showing), *when* a disposing action or Read is taken, *then* it applies to the messages
  that have been on screen (`MailTarget.message`): the conversation stays in the inbox, or
  returns to it, unread, with the new message, and the toast says so (7.9). Being marked
  read by opening obeys the same bound (T10).
- *Given* a selection by scope, *then* it is bounded by the key it was made at (T22): mail
  that arrived afterwards, and a conversation that new mail has moved above that key, are not
  in it.

So nothing is marked Done or read by a key pressed before it was seen.

### 3.10 Worked cases

A list of ten, A (newest) to J (oldest). Direction is *older* unless stated.

| # | Given | When | Then |
|---|---|---|---|
| 1 | Cursor on C, in a split | `E` | Nine rows. Cursor on D. D is where C was on screen. Toast "Marked “…” Done". |
| 2 | Cursor on A | `E` | Cursor on B, at the top. |
| 3 | Cursor on J | `E` | Nothing older. Cursor on I. |
| 4 | A list of one | `E` | Empty state. No cursor. |
| 5 | `K`, `K` from E (cursor on C, direction newer) | `E` | Cursor on B. |
| 6 | Cursor on A, direction newer | `E` | Nothing newer. Cursor on B. |
| 7 | C open | `E` | D is open. |
| 8 | J open | `E` | The list, cursor on I. |
| 9 | A open, direction newer | `E` | The list, cursor on B. |
| 10 | C, D, E selected; cursor on E | `E` | Seven rows, cursor on F, nothing selected. Toast "3 marked Done". |
| 11 | B, C selected; cursor on H | `E` | Eight rows. Cursor still on H. |
| 12 | H, I, J selected; cursor on J | `E` | Cursor on G. |
| 13 | Everything selected (`⌘⇧A`) | `E` | Empty state. One undo entry. |
| 14 | Case 1, then | `Z` | Ten rows, cursor on C, C at its former screen position, unread if it was. |
| 15 | C open, scrolled to its fourth message | `E`, `Z` | C is open, fourth message at the same offset. |
| 16 | `E` on C in Important, then `Tab` | `Z` | Important is showing, cursor on C. |
| 17 | Unread filter on, cursor on C (unread) | `U` | C is read and still in the list: kept, and dimmed from the first reading that omits it. Cursor on C. |
| 18 | Case 17, then `Tab`, `⇧Tab` | — | C is no longer in the filtered list. |
| 19 | Search results, cursor on C (in the inbox) | `E` | C stays, without its inbox glyph. Cursor on D. |
| 20 | Search results, cursor on J (not in the inbox, and read) | `E` | Nothing is sent; no toast; cursor on I. |
| 21 | Cursor on C; D is marked Done on the phone while `J` is held | — | D stays until the list has been idle three seconds; then it is gone. |
| 22 | Cursor on E; new mail arrives in E's conversation | at once | E is where it was, now unread with the new snippet. |
| 23 | Case 22, then `J` to F, then idle | — | E's conversation is first in the list. Cursor on F. |
| 24 | List at the top and idle, cursor on A; mail N arrives | — | N is the first row. Cursor on A, now second. |
| 25 | List at the top, `E` pressed one second ago; mail N arrives | — | No row moves. Chip "1 new". Two seconds later N joins. |
| 26 | List scrolled so A is off screen; mail N arrives | — | No row moves. Chip "1 new", until the top is reached. |
| 27 | C open; C is marked Done on the phone | — | C stays open. Closing shows the list with the cursor on D. |
| 28 | `⌘↩` on a reply, then within the hold | `Z` | The composer is open with the same text, caret and attachments. Nothing was sent. |
| 29 | `⌘↩`, hold ended, then | `Z` | "Already sent." Nothing else changes. |
| 30 | Offline; case 1 | — | Identical to case 1. Status line "Offline · 1 change waiting". |
| 31 | `E` held down for two seconds | — | One conversation marked Done. |
| 32 | Cursor on C | `S` | C is starred. Cursor on C. Nothing else changes. |
| 33 | C, D, E selected; D open | `Esc` | The list, with C, D, E still selected. A second `Esc` clears the selection. |
| 34 | The same; D open | `E` | D is Done; the next conversation opens; C and E are still selected. |
| 35 | Search with the Unread filter on | `Esc` | Search is left; the place it was started from is showing. |
| 36 | `⌘⇧A` ("12 selected"); a message arrives | `E` | Twelve are Done. The arrival is in the inbox, unread: the chip says "1 new" over the empty state until the list is at rest, and then it is the list. |
| 37 | C open; a reply arrives in it, below the fold, unseen | `E` | C's earlier messages are Done and read; C is in the inbox, unread, with the reply. |
| 38 | C open | `J`, `J`, `J` within a second | F is open. D and E were not marked read. |
| 39 | C open | `J` held down | D is open. |
| 40 | A Move that Gmail refuses for good | — | The conversation is back in the list with "Couldn't apply · label gone"; toast with Retry; listed in Outbox. |
| 41 | Cursor on C | `⇧J` | C and D are selected. Cursor on D. |
| 42 | Cursor on C; `E`; `Enter` (D is open) | `Z` | The list, ten rows, cursor on C. D is not open. |
| 43 | `E` on C in Important; `Tab`; nothing has been read for Important since | `Z` | Important is showing with C in its place, in that turn. Cursor on C. |
| 44 | A list of one; `E`; mail N arrives one second later | — | The empty state gives way to the chip "1 new". Two seconds later N is the list. |
| 45 | The place was entered one second ago, list at the top; mail N arrives | — | No row moves. Chip "1 new". Two seconds later N joins. |
| 46 | A place of 1,000 with 100 rows loaded | `J` held to the hundredth row and on | The cursor goes on past it: the next rows were taken in as they came, not three seconds later. |
| 47 | D is the first row on screen; `E` on D; `Tab`, `⇧Tab` | — | E is first on screen, at offset 0: the first row at or after D's place. |
| 48 | Cursor on the fortieth row | `⇧U` | The unread list, cursor on the same conversation and on screen; not at the top. |
| 49 | `Enter` on C (unread) | `U` within 400 ms | The list. C is still unread. Nothing was sent. |
| 50 | Unread filter on in Important | `Tab` | Calendar, with the Unread filter still on. |
| 51 | A reply to C sent with ⌘⇧↩ (C is Done, D is open); the hold has ended | `Z` | "Already sent. “…” is back in the inbox." C is back in its place and open again as it was, without the composer. Nothing is unsent. |
| 52 | 200 rows loaded, scrolled to the 150th; mail arrives (chip "1 new") | `J` held | The list goes on growing past its 300th row. The chip still says "1 new". |
| 53 | A pull to check finds nothing new; he keeps scrolling; mail N arrives four seconds later | — | No row moves. Chip "1 new". |
| 54 | A cold launch into Mail: the cached page shows; the first real reading has one more conversation | — | The list is the real reading when it arrives, a frame or two later; no chip, no three-second wait. |

### 3.11 Where the loop lives

Files a unit test must reach are in `Banana/Model/MailUI/Pure/`, which the test target
compiles as a folder: no view, and nothing named beyond Foundation, the contract and the app
files that target already compiles (12.1). Everything else of the UI's models is in
`Banana/Model/MailUI/`. Nothing in the engine's folder, `Banana/Model/Mail/`, names either.

| Piece | File | What it is |
|---|---|---|
| `MailListModel` | `MailUI/Pure/MailListModel.swift` | Holds, for one scope: the rows as last delivered; the outside changes waiting for the list to be idle (T7–T9); the kept rows (T17); the cursor (id and key), direction, selection and anchor. Inputs: a reading from the source; a key action; "at rest"; the host's two facts — whether the first row is on screen, and the position when scrolling stops (T46); and the two things only the session knows, below. Which readings he asked for (T7) the model works out for itself where it caused them — its own command (it holds the receipt), a growth (the rows after its last row), an undo — and is told where it cannot know: that a reading is the answer to entering a place, and that a check he asked for has finished. Output: every row delivered, in order — it cuts no window; that is done between it and the host (6.1.7) — with which rows are dimmed and the chip's count; and a list of effects (`perform`, `open`, `close`, show a row, restore a position, `toast`, and for Send and Done the screen half of an undo entry, T38). It keeps no overlay of pending changes: the source has applied a command to every list before the call returns. It assumes its rows are the first rows of the scope, which is what the contract delivers. Rules T1–T24, T31–T38, T45, T46. |
| `MailUndoStack` | `MailUI/Pure/MailUndoStack.swift` | T25–T30. |
| `MailSession` | `MailUI/MailSession.swift` | `@MainActor`, outside the view tree. Owns the source, one `MailListModel` per visited scope (the six most recent), the undo stack, the open conversation's model, the composer's model, the idle timer, and `MailNavigation`: a small observable holding the scope showing, the open conversation, the open composer and whether search is up. Only `MailSection` observes it. This is what survives the iOS tree being discarded and the Mac sidebar switching sections. |
| `MailRowMark` | `Views/Mail/MailRowMark.swift` | One small observable per visible row: "has the cursor", "is selected". Moving the cursor flips two of them. The list does not observe the cursor (8.3). |

**What the session must tell the model.** Two facts decide whether a reading is one he asked
for (T7), and only `MailSession` has them. They are requirements on the session, with a test
each:

- **Which reading answers an entry.** The session observes the list in front and no other:
  leaving a place lets its observation go, and entering one starts an observation. The first
  value that observation delivers is the answer to the entry. The session marks that one
  reading as such and no other, and the model takes it whole. Without the mark the model can
  only guess, and a wrong guess lets mail from elsewhere join a list he has just entered.
- **A cached page is not the answer.** On a cold launch the session shows `cachedFirstPage`
  as a first reading that is not marked; the observation's first value is the answer and
  replaces it when it comes, a frame or two later. Unmarked, the real reading would wait for
  the list to rest, and every launch into Mail would show the cached page and a chip for
  three seconds. A cold launch also enters the place before it reopens a conversation.
- **When a check he asked for has finished.** When he asks for a check (⌘R, a pull, "Check
  mail now") the session tells the model, and readings are his to have at once from then.
  The session sends *check finished*, once, when the check has answered: when
  `status.asked` becomes `.finished` — at once if it found nothing new, and otherwise after
  the next reading for the list in front, or after a second if none comes, since the new
  mail may belong to another place. From then a change from elsewhere waits again. The list
  coming to rest ends the allowance too. Nothing else does — not his next input, because the
  scroll that ends a pull is one. Without *check finished*, mail that arrives after a pull
  joins the list under his thumb for as long as he keeps moving.
- **After a growth**, a late delivery from the smaller observation never reaches the model:
  the old observation is let go once the new one has delivered, as the contract orders.

**What goes in `ShellNavigation`.** `ShellState` gains one optional field, decoded with
`decodeIfPresent`:

```swift
/// Where Mail was, for a cold launch within the hour. Ids, a limit and booleans only: never a
/// query, a subject, an address or a draft's text (MAIL-ENGINE 13.8).
struct MailShellState: Codable, Equatable {
    var scope: MailScope            // a search is stored as the place it was started from
    var open: String?               // MailConversationID.text of the open conversation
    var composer: String?           // the draft id of an open composer that has something in it
    var limit: Int?                 // how many rows had been asked for
    var top: String?                // the id of the row that was first on screen,
    var topKey: MailOrderKey?       // its key, so that the next row can stand in if it has left (T46),
    var topPoints: Int?             // and whole points into it
}
var mail: MailShellState?
var librarySection: String?         // "podcasts" | "notes" (2.2), written by U1b
```

`ShellNavigation.state` is published, saved on every change and observed by `RootView`. So
**Mail writes this field in exactly two moments: when the app goes to the background, and
when a composer opens or closes.** `J`, `K`, Done and opening a conversation change
`MailNavigation` in `MailSession`, which the shell does not observe. The cursor is not in it
at all: after a cold launch the cursor is on the restored open conversation, or on the first
row. A restored conversation that no longer exists is dropped.

### 3.12 With the reading pane

Everything above was written for a list that an open conversation covers. That is still what
happens where Mail has one column, and wherever the pane is switched off (6.0). Where the
pane shows, the rules below are added and a few of the rules above read differently; the
table at the end is the exact list. Nothing else changes: T0, the cursor and its successor,
arrivals, selection, the undo stack, places and filters are the same with a pane.

**T47. The pane shows the target.** *Given* the pane is showing, *then* it draws what the
next action would act on (T15): the cursor conversation; or, with a selection and nothing
open, the selection (T54); or nothing, when the list is empty. A conversation in the pane is
*showing*. It is not yet open: the keys are still the list's.

**T48. The pane follows the cursor when the cursor stops.** *Given* the cursor moves by one
press, a click, a tap or an action, *then* the pane shows the new cursor conversation at
once: in the next frame when it was prepared ahead (8.2), otherwise as soon as it has been
read. *Given* a key held down, *then* the pane waits for it: it shows the conversation the
cursor is on **150 ms after the last repeat**, and nothing is read, laid out or drawn for the
rows passed on the way. A conversation asked for and then overtaken by a newer cursor is
dropped before any view work. Until the new one is ready the pane keeps what it showed; it
never goes blank between two conversations.

**T49. Open is focus.** *Given* a conversation showing, *when* `Enter` or `→` is pressed, its
row is double-clicked, or anything inside the pane is clicked, *then* it is **open**: focus
is in the pane and the keys are the conversation's (4.2.3). `Esc` or `←` closes it: focus
returns to the list, and the pane goes on showing it, because it is still the cursor. Opening
and closing move nothing on screen. A single click or a tap on a row puts the cursor there
and shows it; it does not open it. (Where there is no pane to show it in, a click or a tap
opens, as T10 says.) **Where the keys are is drawn**: with focus in the list the cursor row
has its spine and full fill; with a conversation open the row keeps a quieter fill without
the spine, and the pane's header carries the spine instead (6.2.2).

**T50. Which keys are whose.** With the pane showing, the list and a conversation are both in
front, so both sets of keys work. Focus decides only the five that mean two things:

| Key | Focus in the list | Focus in the pane: open |
|---|---|---|
| `Enter` · `→` | Open (T49) | `Enter` replies to all; `→` does nothing |
| `Esc` · `←` | K9's order | Close: focus to the list |
| `J` · `K` | Move the cursor; repeat when held | Open the next conversation; once per press (K7) |
| `Tab` · `⇧Tab` | Next and previous split (T31) | Through the conversation's controls |
| `U` | Read or unread, a toggle (T17) | Leave it unread and go back to the list (T17) |

- **`Space` and `⇧Space` scroll the pane from either focus**: a long message is read with the
  space bar without leaving the list. At the end of the conversation `Space` does nothing.
- Keys that belong only to a conversation — `N`, `P`, `O`, ⌘F to find in it, the text-size
  keys — act on the conversation showing, from either focus. `R` and `F` open it with the
  composer (T38).
- Keys that belong only to the list — `X`, `⇧J`, `⇧K`, ⌘A, ⌘⇧A, the filter keys, the `G`
  keys — act on the list from either focus. Pressed while a conversation is open, they close
  it first and then act.
- Triage keys act on the target (T15), which is what the pane is showing.

**T51. Read.** One rule, with a pane or without: **a conversation is marked read when it has
had his attention long enough to have read something — 400 ms after it is opened, or two
seconds after it starts showing in the pane, whichever comes first.** Passing it sooner marks
nothing, so walking down the list with `J` does not mark what the pane showed on the way.
What is marked is what has been on screen (T10, T45). A conversation he has made unread with
`U` is not marked read again while it goes on showing; the count starts afresh the next time
it is shown. (Two seconds, because the pane shows a conversation whether or not he looks at
it. Gmail's own preview pane waits three by default; Banana can wait less because of the
next sentence.)

**Done marks read**, as it always did, and with a pane it means the same thing: Done says "I
am finished with this", so it marks read what was shown — the row in every case, and for a
conversation showing or open, the messages that have been on screen (T45). It waits for
neither delay.

**T52. A conversation showing is protected like an open one.** *Given* a conversation showing
in the pane, *when* an outside change removes it from the list, *then* it goes on showing:
T13 is about "showing", not only "open". Its row leaves when the list is at rest; no row has
the cursor; its place is remembered by key. A new message in it is added as a card at the
end, with the "1 new message" chip if the end is not on screen. The pane moves on only when
he does. And T45's second bullet covers a conversation showing as it covers an open one: with
a message in it that has not been on screen, Done and Read act on the messages that have.

**T53. What an action does to the pane.** *Given* a disposing action (T16) with focus in the
list, *then* the cursor moves to its successor and the pane shows it at once (T48): `E`,
read, `E`. With the conversation open, T16's fourth step is as written — the next
conversation opens in its place and focus stays in the pane; at the end of the run focus
returns to the list, and the pane shows the cursor conversation. Snooze, Trash, Spam and Move
are the same. A marking action changes nothing the pane shows but the mark. **Undo** (T26)
restores the conversation that was showing, where it was scrolled, and whether it was open.

**T54. A selection and the pane.** *Given* a selection and nothing open, *then* the pane
shows the selection: "3 selected", the subjects of the first eight, and its actions — Done ·
Label · Move · Snooze · Trash · More — with **Clear** (`Esc`). A selection by scope shows its
count ("1,204 selected") and no subjects. `Enter` opens the cursor conversation over that
summary, and T23 holds: actions inside it act on it alone, the selection is kept, and closing
shows the summary again.

**Worked cases with the pane showing.** The list of ten again; focus in the list unless
stated.

| # | Given | When | Then |
|---|---|---|---|
| 55 | Cursor on C; the pane shows C | `J` | Cursor on D. The pane shows D at once. Nothing is marked read. |
| 56 | Cursor on C | `J` held past twenty rows, then let go | The pane shows C until 150 ms after the last repeat, then the row the cursor stopped on. Nothing was read or drawn for the rows between. |
| 57 | The pane has shown C, unread, for two seconds | — | C is read. |
| 58 | `J`, `J`, `J`, each within two seconds of the last | — | Nothing passed is marked read. |
| 59 | The pane shows C | `E` | C is Done and read. Cursor on D; the pane shows D. Focus is still in the list. |
| 60 | The pane shows C | `Enter`, then `E` | C is open, then Done. D is open in the pane. |
| 61 | J, the last row, is open in the pane | `E` | Focus is back in the list. Cursor on I; the pane shows I. |
| 62 | The pane shows C, scrolled to its fourth message; `E` | `Z` | C is back with the cursor on it, showing in the pane at its fourth message. Focus in the list. |
| 63 | The pane shows C; C is marked Done on the phone; the list comes to rest | — | C's row is gone. The pane still shows C. `J` moves to the row at C's place. |
| 64 | The pane shows C; a reply arrives in it below the fold | `E` | As case 37: C's earlier messages are Done and read; C is in the inbox, unread, with the reply. |
| 65 | C, D, E selected | `E` | The pane showed "3 selected". The three are Done; the pane shows the cursor conversation. |
| 66 | C is open in the pane | `X` | Focus returns to the list. C is selected; the pane shows "1 selected". |
| 67 | The pane shows C, read | `U` | C is unread, and stays unread for as long as it goes on showing. |
| 68 | The pane shows C | `Space` | The pane scrolls a page. Neither the cursor nor the focus has moved. |
| 69 | A click on F's row | — | Cursor on F; the pane shows F; F is not open. |

**What this changes in the rules above.** The triage model was built to them, so this is the
whole list:

| Rule | With the pane showing |
|---|---|
| Section 0, T2 | A third state between "in the list" and "open": *showing*. The conversation showing is the cursor conversation, as an open one is. |
| T4 | `Space` and `⇧Space` scroll the pane, not the list. |
| T8(a), T13 | "Unless it is the open conversation" becomes "unless it is showing" (T52). |
| T10 | A click or a tap on a row places the cursor and does not open (T49). The read delay runs for a conversation showing — two seconds — as well as for an open one — 400 ms — and `U` stops it until the conversation is shown anew (T51). |
| T11, T16 step 4 | "Returns to the list" means focus returns to the list. Nothing is uncovered: the list never left. |
| T15, T23 | Unchanged in words. The pane draws the target, so a selection is drawn in the pane (T54). |
| T25, T26 | The entry records the conversation showing, its reading position and whether it was open; undo restores all three. |
| T45 | The second bullet covers a conversation showing in the pane (T52). |
| K7, K9 | By focus (T50). |

Unchanged: T0, T1, T3, T5–T7, T9, T12, T14, T17–T22, T24, T27–T44, T46.

**For the model**, that is: one new fact from the session — which conversation the pane has
on screen, and since when; the reader's facts (what has been seen, the reading position)
accepted for a showing conversation as they are for an open one; "showing" in place of
"open" in T8(a), T13 and T45; and the entry of T25. The rest belongs to the keymap and the
screens: the model's own inputs for placing the cursor, opening and closing do not change.

---

## 4. Keyboard

### 4.1 Who gets a key

Today `MacKeyMonitor` has one hard-coded table and never asks which section is in front; most
of its keys set `nav.section = .plan` first. Add a mail key to it and `J` in Mail pages the
calendar. The fix is a scope, decided once per key press. Prototype P2 proves K2, K10 and K12
on a Mac before package U5 is built.

**K1. One function decides.** `AppKeymap.resolve(_ stroke:, scope:, pendingPrefix:)` in
`Banana/Model/MailUI/Pure/AppKeymap.swift` returns what a key means. `MacKeyMonitor.handle`
builds the stroke and the scope, calls it and carries out the answer. There is no second
table.

**K2. The scope is the first of these that is true.**

| Scope | True when | Who handles keys |
|---|---|---|
| **Typing** | An *editable* text view is first responder — **or Mail has asked for one and it has not appeared yet** (K12). | The text. Single keys are never looked at. Chords belong to the field's owner (the composer declares its own, 4.2.6). `⌘Z` stays the text's. |
| **Overlay** | A sheet is attached, the window is a panel, ⌘K is open, a Mail picker is open, or the shortcuts sheet is up. | The overlay. The monitor returns `false` for everything, as it does today. |
| **Section** | Otherwise: `MacNavigator.section`, and for Mail also its focus — `.list` when no conversation is open, `.reader` when one is. | That section's keymap. |

A message's text can be selected and is not editable, so clicking or selecting in it is not
Typing: the single keys keep working (K10).

**K3. A section that declares a keymap owns the single keys while it is in front.** Mail
declares one (`MailKeymap`). In Mail a single key does what Mail's map says or does nothing.
It never reaches Plan's table, and Mail never changes `nav.section`.

**K4. A section that declares none inherits today's behaviour.** Plan, Workouts, Sleep,
Trends, Nutrition, Notes, Routines, Library and Settings go through the existing `switch`
unchanged, including that its keys navigate to Plan. Every existing calendar key works
exactly where it works today, except while Mail is in front. U5 carries the test that proves
it: a table written from the current `switch` before it is moved.

**K5. Unmapped keys.** In Mail, an unmodified letter, digit or punctuation key with no entry
is swallowed silently (no beep). Everything else unmapped (`Tab` in a conversation, function
keys, arrows inside a focused control) is passed on.

**K6. Prefixes.** `G` starts a two-key sequence in Mail, with the existing 1.5-second window.
A second key that completes nothing cancels the prefix and is then handled as a first key. A
pending prefix is shown: the header's trailing edge shows the key cap and "then…" until it
resolves or lapses. `E` is never a prefix in Mail. (`I`, for invitations, arrives with 9.1 and
exists only while the open conversation has an unanswered invitation, drawn as pending on the
card itself — so a stray `I` then `N` can never decline anything.)

**K7. Repeat.** Only `J`, `K`, `⇧J`, `⇧K`, `Space` and `⇧Space`, and only in the list, act on
auto-repeat. Every other Mail key, and `J` and `K` in an open conversation, act on the first
key-down only (T12, T18).

**K8. Letters and symbols.** A letter is matched by its unshifted character and the Shift
flag, so `E` and `⇧E` differ. A symbol (`#`, `!`, `?`, `/`, `-`, `=`) is matched by the
character the keyboard produced, whatever keys made it: `#` is ⇧3 on a US keyboard and ⌥3 on
a British one.

**K9. `Esc` goes back one level** — the first that applies, and this is the only rule about
`Esc`: close the open picker or menu (the overlay does this itself) → close the open
conversation → clear the selection → leave search → clear filters → nothing. In a composer
`Esc` leaves the composer and keeps the draft (the composer handles it; Typing scope).

**K10. Leaving text gives the keys back.** When a composer closes, search is dismissed or a
picker closes, Mail resigns the first responder (`window.makeFirstResponder(nil)`), so the
next key is a Mail key. Clicking a row or the reader's background does the same. Selecting
text in a message never takes the keys away.

**K11. Menu-bar chords follow the section.** `MacCommands` already observes `MacNavigator`.
Two of its items change title and action with the section in front (4.3): File › New, and
Refresh.

**K12. Type-ahead.** *Given* a key that opens a text field (`R`, `F`, `Enter` in a
conversation, `C`, ⌘N, `/`, ⌘F, `L`, `V`, `H`, `G` `L`), *then* every later key press is
delivered to that field, in order, even if it arrives before the field exists. None is
resolved as a Mail key. The monitor marks a field as *asked for* when it resolves such a key;
from then until the field is first responder it queues what is typed and inserts the queue
when the field takes focus. `Esc` before that cancels the field and discards the queue. If no
field has taken focus after one second the queue is discarded and the scope returns to the
section's (a fault, logged through `MailUILog`).

**Tests that pin this** (U5, repeated in U9a; the keys are pressed by script, `--mail-keys`
in 13.1, so no test needs a Mac window): `R` followed by "Each" at 5 ms intervals types
"Each" into the reply and marks nothing Done; `/` then "invoice" types "invoice" and opens no
picker; a click in a message's text, then `J`, moves the cursor.

**What P2 must show:** on a Mac, the time from a key event to the row mark changing is within
one frame at the 95th percentile; no character is lost or misread at 5 ms a character across
every key in K12's list; and after a click in selectable message text and in a designed
message's web view, `J` still moves the cursor. If it cannot be shown for the web view, a
designed body's clicks are forwarded to the reader's background and K10 says so.

### 4.2 The map

Base: Superhuman Mail v8, Mac Edition. **Same** means identical. Every difference has a
reason. *Later* marks a key whose feature is after the first release (section 11); the key is
reserved from the start.

#### 4.2.1 Anywhere in Mail (list or conversation, not typing)

| Key | Action | Versus Superhuman |
|---|---|---|
| ⌘K | Command menu | Same |
| `/` | Search | Same |
| ⌘F | In the list: search. In a conversation: find in this conversation (6.2.8). | Search is Superhuman's; find is the Mac's meaning of ⌘F where there is something to find in |
| `Z`, ⌘Z | Undo (T26) | Same; ⌘Z added because it is Banana's undo key |
| `?` | Keyboard shortcuts | **Differs**: v8 gives `?` to Ask AI. `?` is shortcuts everywhere in Banana. |
| `C`, ⌘N | New message | `C` same; ⌘N added (4.3) |
| ⌘R | Check mail now | Banana's refresh key, scoped (4.3) |
| `⌃1`…`⌃9`, `⌃0` | Show only account *n*; all accounts | **Differs slightly**: Superhuman switches accounts; Banana's inbox is all of them, so the key narrows it |
| ⌘+ · ⌘− · ⌘0 | Larger, smaller, normal text in a conversation (Mac) | Same |
| `Esc` | Back one level (K9) | Same |
| ⌘1…⌘9, ⌘, | App sections; Settings | **Differs**: Superhuman uses ⌘-numbers for tabs; Banana's are the sidebar |
| ⌥⌘S · ⌥⌘P · ⌥⌘I | Show or hide the control column · the reading pane · the details column (6.0.4) | **Added**: Superhuman has no columns. These are the Mac's own keys for a sidebar and an inspector |
| `0` · `-` · `=` · `T` | The day, in the details column: show it, previous day, next day, today. *Later*; until then they do nothing. | Same |

#### 4.2.2 List

With the reading pane showing, this table and the next apply at once: both the list and a
conversation are in front. Focus decides only the five keys that mean two things, and
`Space` scrolls the pane (T50).

| Key | Action | Versus Superhuman |
|---|---|---|
| `J` / `↓` | Older conversation | Same |
| `K` / `↑` | Newer conversation | Same |
| `Enter` / `→` | Open | Same |
| `Tab` / `⇧Tab` | Next / previous split (T31) | Same |
| ⌘↑ / ⌘↓ | Top / the oldest row loaded (T4) | Same |
| `Space` / `⇧Space` | Page down / up (T4) | Same |
| `X` | Select | Same |
| `⇧J` / `⇧K` | Extend selection | Same |
| ⌘A | Select all from here (T22) | Same |
| ⌘⇧A | Select all (T22) | Same |
| `R` / `F` | Open and reply / open and forward (T38). Nothing, with a selection. | Same |

#### 4.2.3 Conversation

| Key | Action | Versus Superhuman |
|---|---|---|
| `J` / `K` | Open the older / newer conversation, once per press | Same |
| `Esc` / `←` | Back to the list | Same |
| `N` / `P` | Next / previous message (scrolls to it and opens it) | Same |
| `O` / `⇧O` | Open or fold this message / open all | Same |
| `Enter` | Reply to all | Same |
| `R` / `F` | Reply to sender / forward | Same |
| `Space` / `⇧Space` | Scroll | Same |
| `Tab` | Moves focus through the invitation's buttons, the attachments and the reply field, which are focusable whatever the system's keyboard-navigation setting | **Differs** (O9) |
| `I` then `Y` / `N` / `M` | Answer an invitation. *Later* (K6). | **Added** |

`G` keys work from an open conversation: they close it and go. Filter keys act in the list
only.

#### 4.2.4 Triage (list or conversation; target per T15)

| Key | Action | Versus Superhuman |
|---|---|---|
| `E` | Done | Same |
| `⇧E` | Not done — in Done: Back to the inbox; in Spam: Not spam; in Trash: Restore (T14) | Same key; named for where it is |
| `S` | Star | Same |
| `U` | Read / unread | Same |
| `#` | Trash | Same |
| `!` | Spam | Same |
| `L` | Label… | Same |
| `V` | Move… | Same |
| `Y` | Remove the label being viewed (in a label's list only) | Same |
| `H` | Snooze… (first release, with package U8) | Same key. **Named** "Snooze", not "Remind me": a reminder is a task in Banana |
| `⇧M` | Mute. *Later.* | Same |
| ⌘U | Unsubscribe… — opens a confirmation naming the list; `↵` confirms (T28). *Later.* | Same key; the second press is added because it is the one thing here that cannot be undone |
| `A` · `B` | Add to plan, as a task · as a time block (9.2). *Later.* | `A` **added**; `B` is Banana's version of "create event" |
| `[` `]` `⇧Y` | — | **Left out**: `E` with a remembered direction does what `[` and `]` do; "remove all labels" on one key is a hazard. In ⌘K. |

#### 4.2.5 Filters and Go to

| Key | Action | Versus Superhuman |
|---|---|---|
| `⇧U` / `⇧S` / `⇧I` / `⇧R` | Filter: unread / starred / important / no reply | Same |
| `G` `I` | The first split | Same ("Inbox") |
| `G` `O` | Other | Same |
| `G` `S` / `D` / `T` / `E` | Starred / Drafts / Sent / Done | Same |
| `G` `U` | Outbox | **Added**: sends wait on the device, so where they wait is two keys away |
| `G` `A` / `!` / `#` | All mail / Spam / Trash | Same |
| `G` `L` | A label (Places, focus in its filter field) | Same |
| `G` `H` · `G` `M` | Snoozed (with `H`) · Muted (*later*) | Same |
| `G` `;` | — | **Left out** with snippets |

`Tab` between splits carries the account and the filters; a `G` key keeps the account and
drops the filters (T31).

#### 4.2.6 Composer (declared by the composer; Typing scope)

| Key | Action | Versus Superhuman |
|---|---|---|
| ⌘↩ | Send | Same |
| ⌘⇧↩ | Send and Done | Same |
| ⌥⌘↩ | Send now, with no undo hold | **Differs**: Superhuman's ⌘⇧Z is Redo in every Mac text field |
| ⌘⇧O / ⌘⇧C / ⌘⇧B | To / Cc / Bcc | Same |
| ⌘⇧F | From | Same |
| ⌘⇧S | Subject | Same |
| ⌘⇧A | Attach | Same |
| ⌘⇧I | Move the To line to Bcc | Same |
| ⌘⇧, | Discard the draft (with Undo) | Same |
| ⌘B / ⌘I / ⌘U | Bold / italic / underline | Same |
| ⌘⇧X | Strikethrough | Same |
| ⌘K | With text selected: link. Otherwise the command menu. | Same |
| ⌘⇧V | Paste without formatting | Mac standard |
| `Esc` | Leave the composer; the draft is kept | Same |
| ⌘⇧L · ⌘⇧H | Send later · Remind me if no reply (6.3.6) | Same |
| ⌘⇧T | Insert free times. *Later.* | **Added** |
| ⌘⇧M | — | **Left out**: Morning Briefing in Banana. `Tab` from the subject reaches the body. |
| ⌘; `;name` ⌘J ⌘D ⌘⇧7/8/9 ⌘] ⌘[ ⌘O `:emoji` and the pop-out keys | — | **Left out** (section 11); reserved, not reused |

### 4.3 Collisions, each with a ruling

| Key | Today | In Mail | Ruling |
|---|---|---|---|
| ⌘N | "New Event" from any section; jumps to Plan. | New message. | **File › New makes the thing the section in front makes**: "New Message" in Mail, "New Event" everywhere else, exactly as now. ⇧⌘N stays "New Task" everywhere. |
| `/` | Opens the shortcut sheet (an alias of `?`) in every section. | Search. | **Search in Mail.** Unchanged elsewhere (K4). |
| ⌘R | "Refresh Calendar"; jumps to Plan. | Check mail now. | **Refresh acts on the section in front.** "Check Mail" in Mail, with no jump. "Refresh Calendar" elsewhere, as now. |
| ⌘K | Command menu. | Command menu; in a composer with text selected, link. | The exception is declared by the composer (Typing scope) and is the Mac convention for links. |
| ⌘Z | The toast's Undo, unless typing. | What the toast on screen offers; with no toast, Mail's stack (T26). | One key, one answer: it undoes what the screen says it will. |
| ⌘F | Nothing. | Search in the list; find in a conversation. | By focus. |
| `E` | Prefix for `Y`/`N`/`M` when an event is inspected. | Done. | Scoped by section (K3). |
| `J` `K` | Next / previous week. | Older / newer. | Scoped. Same idea in both: forward and back. |
| `C` | New event. | New message. | Scoped. `C` creates the section's thing. |
| `S` | Share availability. | Star. | Scoped. |
| `N` `B` | Next / previous event. | Next message; (later) a time block. | Scoped. |
| `T` `D` `W` `1`–`7` | Today; day and week view; days shown. | Nothing in the first release (K5). | Scoped. They must not jump to Plan from Mail. |
| `?` | Shortcut sheet. | Shortcut sheet, Mail's groups first. | Same everywhere. The sheet's Mail rows come from the command registry (4.5), not a hand-kept table. |
| ⌘A, ⌘⇧A | The system's Select All. | Select from here; select all (list focus only). | Handled by the monitor in Mail's list scope; in text they are the text's. |
| ⌘U | Underline in text. | (Later) Unsubscribe. | Scoped by focus. |
| ⌘⇧M | Morning Briefing. | — | Briefing keeps it. |
| `⌃1`…`⌃9` | Free in Banana. macOS can bind them to "Switch to Desktop *n*". | Narrow to account *n*. | Kept for Superhuman's muscle memory. Where macOS takes them, ⌘K › "Show only …" does the same. |
| `Tab` | AppKit focus traversal. | Next split (list focus). | The monitor takes `Tab` in list focus only. |

These rulings are not put to the author as questions: each has one clearly right answer
(MAIL-PLAN section 8 says so).

### 4.4 iPad with a hardware keyboard

After the first release (package U5b). The same map from the same `MailKeymap`, through a
`MailKeyHost` (`.focusable()`, `.onKeyPress`, the `WideWorkoutDetailView` pattern), with one
rule that P2's iPad half must prove first: **when nothing editable has focus, the host has
it**, re-checked on every focus change, so a tap in a message or a closing field can never
leave the keys with nobody. ⌘ chords are attached to the controls that do the thing, so
holding ⌘ lists them. Until U5b an iPad has the system's own keys and nothing of Mail's.

### 4.5 The command menu in Mail

**One registry.** `MailCommands` (`MailUI/Pure/MailCommands.swift`) lists every Mail command:
id, title, symbol, key, group, and a predicate on the context (list or conversation, the
target, whether a composer is open, the place). It is built in U5a with the keymap, and a test
holds the two together: every key in `MailKeymap` is a command with that key, and the
reverse. Four things are drawn from it: the ⌘K menu, the shortcut sheet's Mail groups, the
More sheet on touch (6.7), and the tooltips on header buttons.

**On the Mac** it feeds the existing `MacCommandMenu`: when `nav.section == .mail`,
`MacCommand.all` is Mail's commands whose predicates hold, then the app's "Open …" commands,
then "Keyboard shortcuts". Filtering is the menu's existing one (every typed word is in the
title). Ranking by closeness, recents, and rows made from what is typed ("Snooze until Fri
9 AM", "New message to Sam Lee", "Search mail for …") are package U12, after the first
release.

| Group | Commands (key) — first release |
|---|---|
| Conversation *(when there is a target)* | Mark Done (`E`) · Not done / Not spam / Restore (`⇧E`) · Star (`S`) · Mark unread (`U`) · Label… (`L`) · Move… (`V`) · Remove label (`Y`) · Trash (`#`) · Spam (`!`) · Snooze… (`H`) · Open attachment… · Find in conversation (⌘F) · Open in Gmail · Copy link |
| Reply | Reply to all (`↵`) · Reply (`R`) · Forward (`F`) · Next conversation (`J`) · Previous conversation (`K`) |
| Compose | New message (`C`) · *in a composer:* Send (⌘↩) · Send and Done (⌘⇧↩) · Send now (⌥⌘↩) · Send later… (⌘⇧L) · Remind me if no reply… (⌘⇧H) · Attach file (⌘⇧A) · Discard draft (⌘⇧,) · *during a hold:* Undo send |
| Go to | Each split · Starred (`G S`) · Drafts (`G D`) · Sent (`G T`) · Outbox (`G U`) · Done (`G E`) · All mail (`G A`) · Spam (`G !`) · Trash (`G #`) · Label… (`G L`) |
| Filter | Unread (`⇧U`) · Starred (`⇧S`) · Important (`⇧I`) · No reply (`⇧R`) · Show only *account* (`⌃n`) · All accounts (`⌃0`) |
| Select | Select (`X`) · Select all from here (⌘A) · Select all (⌘⇧A) |
| View | Show or hide: Mailboxes (⌥⌘S) · Reading pane (⌥⌘P) · Details (⌥⌘I) · Larger text (⌘+) · Smaller text (⌘−) |
| Mail | Undo: *what* (`Z`) · Check mail now (⌘R) · Search (`/`) · Mail settings · Keyboard shortcuts (`?`) |

**Each row** is the existing command row: symbol, title, and the key as `KeyCombo`. The menu
opens in the next frame: the registry is static and the predicates are in-memory checks.

---

## 5. Design system additions

Rule zero holds: views name roles. Everything Mail needs that `DS` lacks is added to
`Shared/BananaDesign.swift` in U2, with a `BananaDesignTests` case each.

### 5.1 Tokens

```swift
extension DS.Palette.Feature {
    /// Mail's settings tile: a manila envelope. A hue nothing else in the system uses.
    static let mail = Color.brown
}

extension DS {
    /// Mail's own sizes. Everything else in Mail uses the shared roles.
    enum Mail {
        /// The leading lane of a row: the unread dot, or the check circle while selecting.
        static let gutter: CGFloat = 20
        /// The cursor's mark at the leading edge of its row: the event spine's width.
        static let cursorSpine: CGFloat = Event.spineWidth
        /// A one-line row. Where the pointer is a mouse it is the panel row; where it can be a
        /// finger it is the tap target.
        #if os(macOS)
        static let oneLineRow: CGFloat = 32
        #else
        static let oneLineRow: CGFloat = Row.minHeight
        #endif
        /// The list is one line per row from this width; narrower, three lines.
        static let oneLineMinWidth: CGFloat = 720
        /// With no pane beside it, the list is never wider than this; the rest is margin.
        static let listMaxWidth: CGFloat = 1_100
        /// Columns of a one-line row at the default text size. The row scales all three.
        static let senderColumn: CGFloat = 176
        static let dateColumn: CGFloat = 72
        static let glyphSlot: CGFloat = 20
        /// A date-group label row in a one-line list ("TODAY").
        static let groupHeader: CGFloat = 24
        /// The list's and the conversation's header: the planner header's height.
        static let header: CGFloat = 44
        /// The line under the header that says the list is not live.
        static let statusLine: CGFloat = 28
        /// The widest a conversation's column gets.
        static let readingMeasure: CGFloat = 680
        /// The control column: Mail's places (6.0).
        static let controlColumn: CGFloat = 220
        /// The list beside a reading pane: never narrower, never wider.
        static let listColumnMin: CGFloat = 320
        static let listColumnMax: CGFloat = 440
        /// The reading pane: the least it may be, and the least beside the details column.
        static let paneMin: CGFloat = 420
        static let paneBesideDetails: CGFloat = 560
        /// The details column, and the same view as a panel over the pane.
        static let detailsColumn: CGFloat = 280
        /// The bar at the bottom of a compact Mail screen.
        static let bottomBar: CGFloat = 52
        /// An icon button in a pointer row or a header on the Mac.
        static let pointerTarget: CGFloat = 28
    }
}
```

Colour roles Mail uses, all existing: unread dot `DS.Palette.info` (not the accent: the accent
means now and selected, and unread is neither) · cursor fill `DS.Palette.selection` with an
accent spine · a selected row `DS.Palette.accent` at `Tint.soft` · star `DS.Palette.accent`
(the person's own mark) · failed `DS.Palette.danger` · late or waiting on an answer
`DS.Palette.warning` · label colours through `calendarTint(hex)` as a `Tint.soft` wash, never
as text colour. Counts on split tabs and after names are in secondary, not tertiary: they are
what a triager reads all day.

**What differs between a Mac and an iPad in the regular arrangement.** All of it is tokens
or input, none of it layout:

| | Mac | iPad |
|---|---|---|
| One-line row height | 32 pt | 44 pt |
| Icon-button target | 28 pt | 44 pt |
| Cursor drawn | Always | After a hardware key or pointer movement, until the next touch |
| Quick actions on a row | On hover | On hover, with a pointer; otherwise swipe |
| Text size | Fixed; ⌘+ and ⌘− scale a conversation | Dynamic Type |

**Three things to record in `DESIGN-SYSTEM.md`** when U2 lands, so they are the system's
rules and not Mail's exceptions: "Every row is at least 44 pt" becomes "wherever a finger can
be the pointer; a pointer-only list on the Mac may use the panel row"; date groups in a dense
list may use the eyebrow; and Mail hosts its own toast on iPhone and iPad (5.2).

### 5.2 New primitives

| Primitive | Where | Spec |
|---|---|---|
| `DateText` | `Shared/BananaDesign.swift`, beside `TimeRangeText` | A rule over the system's formatters; it assembles nothing by hand. `DateText.row(_:now:calendar:locale:)`: today → `TimeRangeText.time` · yesterday → the locale's own word, from the system's relative formatter · two to six days ago → `Date.FormatStyle` weekday · this year → `.dateTime.day().month(.abbreviated)` · earlier → the same with the year. `DateText.column(…)` for the one-line row, which sits under a date-group label: today and yesterday → the time · this week → weekday and day · this year → day and month · earlier → month and year. `DateText.full(…)` for a message header: weekday, day, month and the time. Tested at fixed instants in a 12- and a 24-hour locale. |
| `DSChip` | `Shared/BananaDesign.swift` | A small labelled pill: optional leading symbol, text (`.caption`, one line, middle truncation when asked), `Radius.chip`, fill `tint.opacity(Tint.soft)` or `Color.primary.opacity(Tint.subtle)` with no tint. Two forms. *Display* (labels, the account, attachments): minimum height 22 pt. *Control* (recipients, filters, split chips): the same pill with an optional trailing × and a 44-pt (28 on the Mac) hit area. |
| `Monogram` | `Shared/BananaDesign.swift` | The account card's avatar made reusable: a circle of `DS.Row.avatar`, `Color.primary.opacity(Tint.soft)`, the first letter in `.subheadline.weight(.semibold)`. Conversation headers only. No remote pictures. |
| `KeyHintRow` | `Shared/BananaDesign.swift` | The command menu's footer hint (`KeyCap`s and a caption) lifted out of `MacCommandMenu` so the composer and pickers draw the same strip. |
| `ToastCenter.present` | `Banana/Model/ToastCenter.swift` | `func present(_ message: String, actionTitle: String = "Undo", duration: Duration? = nil, action: (@MainActor () -> Void)? = nil)`. Shows now and returns: it takes the previous pending commit, shows, and runs that commit in a detached task, as `notify` does. `duration` overrides `ToastCenter.window` for this toast (the send hold). Mail never calls `deferRemoval` or `offerUndo`: its changes are already stored when the toast shows, and a key handler must not await another feature's network call. |
| `MailBottomBar` | `Banana/Views/Mail/MailBottomBar.swift` | The compact arrangement's one bottom slot (6.1.3). Built only after prototype P4 has settled its form. Where it is a safe-area inset, the toast host is applied *inside* it so the toast sits just above. **Where the toast is hosted:** on iPhone and iPad `MailSection` applies `.toastHost()` itself and `RootView` adds none to the Mail tab; on the Mac the shell's one host serves Mail. |

Mail does **not** add: a list-row view shared with other features, a new spinner, a new
toast, a new confirmation style, or any inline number.

### 5.3 Motion

| What | Motion | Reduced motion |
|---|---|---|
| Cursor moving | None. The mark is on the new row in the next frame. | Same |
| A row leaving by a key | The list closes up in 0.18 s; the next key can arrive during it (T18). | The row is gone in the next frame |
| A row leaving by a swipe | The swipe's own motion carries it out (Done is declared with the destructive role, tinted `success`, so it does not snap back first). | The system's |
| Rows arriving at the top (T9) | Slide in over 0.2 s | Appear |
| Opening / closing a conversation, regular | None: it is shown over the list, or removed | Same |
| Opening / closing, compact | The system push | The system's reduced push |
| Next / previous conversation | Cross-fade 0.12 s; the bar and header do not animate | Replace |
| A picker or the command menu | Appears in place, no scale | Same |
| The composer, regular | The card is there in the next frame | Same |
| The composer, compact | The system sheet | Same |
| A folded message opening | Height over 0.18 s, anchored at its header | Opens in the next frame |
| The toast | As now (`.snappy(duration: 0.22)`) | As now |
| The "new" chips | Fade 0.15 s | Appear |

No animation in Mail is longer than 0.22 s, and none blocks input.

---

## 6. Screens

Mail is laid out in columns (6.0), and inside each column, and for Mail's chrome, in one of
two arrangements chosen by `\.layoutClass`: **compact** (under 600 pt: a bottom slot, sheets)
and **regular** (headers, popovers). All of it is by measured width, never by device (2.2
says how the Mac measures). The Mac is built first, and **every package builds its screen for
narrow widths as well** — the owner's ruling (14.2): no screen's phone form is added later.
Wireframes are to proportion, not to the point; the tokens named beside them are the
measurements.

Performance rules that apply to every screen are in 8.3; each screen adds its own under
"Must". A control whose target belongs to a later package is drawn and disabled, with its
accessibility label, never hidden: the layout is final from the first package that draws it.

### 6.0 The columns

#### 6.0.1 What each column holds

| Column | Holds | Width |
|---|---|---|
| **Control** | Places: the splits, the mailboxes, the labels and the accounts, with counts (6.6). What the Places popover and sheet were. | `DS.Mail.controlColumn`, 220 |
| **List** | The conversations of the place showing (6.1). | 320 to 440 beside a pane; all the width without one |
| **Reading pane** | The target (T47): the conversation the cursor is on (6.2), a selection's summary, or a new message being written (6.3). | At least 420; at least 560 beside the details column |
| **Details** | About the conversation showing: who is in it, its dates and labels, its attachments; later the invitation and its day (6.10). | `DS.Mail.detailsColumn`, 280 |

#### 6.0.2 Which columns show: one rule, by Mail's width

Mail measures the width it has: what is left beside Banana's sidebar on a Mac or an iPad, in
a split, on a phone. Then:

**A column that is switched on shows when there is room for it and for everything more
important than it. The order of importance is list, pane, control, details. So as Mail
narrows, the columns drop in the order details, control, pane.** Room means the list keeps
320 pt and the pane 420 — 560 when the details column is beside it.

With all three options on, which is the default:

| Mail's width | Shows | For example |
|---|---|---|
| 1,380 and up | control · list · pane · details | A 16-inch MacBook; an external display |
| 960 to 1,379 | control · list · pane | A 14-inch MacBook with Banana's sidebar showing; an 11-inch iPad in landscape |
| 740 to 959 | list · pane | An iPad in portrait; a narrow Mac window |
| under 740 | list, and a conversation replaces it | An iPhone; an iPad in a narrow split |

The same rule with an option off: with no control column the details column fits from 1,160;
with no pane the list takes the pane's place, a conversation opens over the list as it does
at a narrow width, and the control and details columns sit either side of the list from 820
(the control column alone from 540).

- **Widths.** The control and details columns are fixed. Of what is left, the list takes
  30 %, held between 320 and 440; the pane takes the rest, with its text held to
  `DS.Mail.readingMeasure` and centred. The dividers are not draggable in the first version.
- **A column with no room is still one tap or key away.** The control column becomes
  **Places**: a popover from ≡ in the list's header, or a sheet at compact width. The details
  column becomes a panel over the trailing edge of the pane (`dsFloatingPanel`, 280 wide;
  `Esc` closes it), or a sheet from the conversation's ⓘ where there is one column. The pane
  has no stand-in: the conversation replaces the list.
- **Under 740 the two older arrangements are what is left.** From 600 the conversation is
  drawn over the list, with its actions in a header (regular). Under 600 it is pushed, with
  the bottom slot (compact). Every rule in this document about a conversation that covers the
  list describes this case, and the case of the pane switched off.
- **Changing arrangement** — a window resized, an iPad rotated, a column switched off — keeps
  the place, the cursor, what is showing and where it is scrolled. Nothing is read again: the
  columns are the same views, shown or not. A conversation that was open stays open: over the
  list where the pane has gone, in the pane where it has come back.

#### 6.0.3 This replaces a rule of the layout system

`ADAPTIVE-LAYOUT.md` allows two arrangements at most, split at 600 pt. Mail has more than
that, and this section says so plainly rather than bending the words. The document's first
rule (layout follows room, not device) and its third (measure the column, not the window)
stand, and are what this section is built on. Its second is replaced, for Mail, by:

> **A section may be made of columns. Each shows when there is room for it, in one fixed
> order of importance. Inside a column there are still at most two arrangements.**

No view asks what device it is on. Which columns show is one pure function,
`MailColumns.showing(width:options:)`, with a test for each row of the table above and for
each option off. The package that builds the columns adds the quoted rule to
`ADAPTIVE-LAYOUT.md`.

#### 6.0.4 The pane and the side columns are options

| Option | Key on a Mac | Also | Default |
|---|---|---|---|
| Control column | ⌥⌘S | The sidebar button (◧) at the head of the column, or of the list's header when the column is hidden; the View menu; ⌘K | On |
| Reading pane | ⌥⌘P | The pane button (▥) at the trailing end of the list's header; the View menu; ⌘K | On |
| Details column | ⌥⌘I | The ⓘ button at the trailing end of the pane's header; the View menu; ⌘K | On |

- **Each choice is remembered on the device** (`MailPrefs`: `mailShowsControl`,
  `mailShowsPane`, `mailShowsDetails`; not synced, because screens differ). A choice means
  "show this when there is room": the rule of 6.0.2 still decides.
- **With the pane off**, Mail is as this document first drew it: the list takes the width,
  one line to a row from 720 pt, and a conversation opens over it (6.1.2, 6.2.2). Nothing is
  lost by turning the pane off, and nothing in section 3 before 3.12 changes.
- A key pressed for a column that has no room shows its stand-in: ⌥⌘S opens Places, ⌥⌘I the
  details panel. ⌥⌘P does nothing under 740.
- The keys are the Mac's own for these things: Finder's for a sidebar, the usual one for an
  inspector. On an iPad the buttons do it.

#### 6.0.5 The arrangements, drawn

Four columns, from 1,380:

```
┌──────────────────┬────────────────────────────┬──────────────────────────────────────────────┬──────────────────────┐
│ ◧                │ Important     ⏷   ⌕   ✎  ▥ │ ↑  ↓                          ✓  ⏱  ★  ⋯   ⓘ │ PEOPLE               │ headers 44
├──────────────────┼────────────────────────────┼──────────────────────────────────────────────┼──────────────────────┤
│ ⌕ Filter         │ ○ Offline · 3 changes wai… │  Q3 numbers before Thursday      ⟦Invoices⟧  │ (S) Sam Lee          │
│ SPLITS           │                            │  to noor@plan.example                              │     sam@lee.example  │
│▌Important     12 │ ● Sam, Jane 3      9:12 AM │ ┌──────────────────────────────────────────┐ │     You write to him │
│ Calendar       2 │▌  Q3 numbers before T… ⌇ ★ │ │ Jane Park  Looks fine to me, one…   Mon  │ │ (J) Jane Park        │
│ VIP            3 │   Can you look at the rev… │ ├──────────────────────────────────────────┤ │     jane@parkdesign… │
│ Other        40+ │                            │ │ (S) Sam Lee  to me, Jane        9:12 AM  │ │                      │
│ MAILBOXES        │   Jane Park      Yesterday │ │                                          │ │ ABOUT                │
│  ▣ Inbox         │   Invitation: Design re… ▦ │ │ Can you look at the revenue tab before   │ │ 3 messages           │
│  ☆ Starred       │   Tue 6 Oct, 9–9:45 AM · … │ │ Thursday? I think the March number is    │ │ Started Mon 28 Sep   │
│  ✎ Drafts      2 │                            │ │ off.                                     │ │ In Important         │
│  ➤ Sent          │   Stripe           8:31 AM │ │ ⟦•••⟧ ⟦▤ Q3.xlsx · 84 kB⟧ ⟦▧ chart.png⟧  │ │ ⟦Invoices ×⟧         │
│  ⇡ Outbox    1 ● │   Your receipt from Stripe │ └──────────────────────────────────────────┘ │                      │
│  ✓ Done          │   ⟦Invoices⟧ Amount paid … │ ┌ Reply to all…                            ┐ │ ATTACHMENTS          │
│  …               │                            │                                              │ ▤ Q3.xlsx      84 kB │
│ LABELS           │   Ana Ruiz         8:02 AM │                                              │ ▧ chart.png   212 kB │
│  ● Invoices      │   Contract draft        ⌇  │                                              │                      │
│ ACCOUNTS         │   Redlines attached, two … │                                              │ RECENT WITH SAM      │
│  ◉ All accounts  │                            │                                              │ Budget · 12 Aug      │
└──────────────────┴────────────────────────────┴──────────────────────────────────────────────┴──────────────────────┘
  control 220        list 320 to 440              reading pane, at least 560 here                details 280
```

Three columns, 960 to 1,379, with the details asked for:

```
┌──────────────────┬────────────────────────────┬────────────────────────────────────────────────────────┐
│ ◧                │ Important     ⏷   ⌕   ✎  ▥ │ ↑  ↓                                    ✓  ⏱  ★  ⋯   ⓘ │ headers 44
├──────────────────┼────────────────────────────┼────────────────────────────────────────────────────────┤
│ ⌕ Filter         │ ● Sam, Jane 3      9:12 AM │  Q3 numbers before Thursday   ┌──────────────────────┐ │
│ SPLITS           │▌  Q3 numbers before T… ⌇ ★ │  to noor@plan.example               │ PEOPLE            ✕  │ │ the details panel, on ⓘ or ⌥⌘I:
│▌Important     12 │   Can you look at the rev… │ ┌─────────────────────────────│ (S) Sam Lee          │ │ over the pane's trailing edge;
│ Calendar       2 │                            │ │ (S) Sam Lee  to me, Jane    │     sam@lee.example  │ │ Esc closes it
│ VIP            3 │   Jane Park      Yesterday │ │                             │ ABOUT                │ │
│ Other        40+ │   Invitation: Design re… ▦ │ │ Can you look at the revenue │ 3 messages           │ │
│ MAILBOXES        │   Tue 6 Oct, 9–9:45 AM · … │ │ tab before Thursday? I thin │ ATTACHMENTS          │ │
│  ▣ Inbox         │                            │ │ the March number is off.    │ ▤ Q3.xlsx      84 kB │ │
│  ☆ Starred       │   Stripe           8:31 AM │ └─────────────────────────────└──────────────────────┘ │
└──────────────────┴────────────────────────────┴────────────────────────────────────────────────────────┘
  control 220        list 320 to 440              reading pane, at least 420
```

Two columns, 740 to 959:

```
┌──────────────────────────────┬──────────────────────────────────────────────────┐
│ ≡  Important    ⏷   ⌕   ✎  ▥ │ ↑  ↓                              ✓  ⏱  ★  ⋯   ⓘ │ ≡ opens Places, a popover
├──────────────────────────────┼──────────────────────────────────────────────────┤
│ ● Sam, Jane 3        9:12 AM │  Q3 numbers before Thursday          ⟦Invoices⟧  │
│▌  Q3 numbers before Thu… ⌇ ★ │  to noor@plan.example                                  │
│   Can you look at the reven… │ ┌──────────────────────────────────────────────┐ │
│                              │ │ (S) Sam Lee  to me, Jane            9:12 AM  │ │
│   Jane Park        Yesterday │ │                                              │ │
│   Invitation: Design revi… ▦ │ │ Can you look at the revenue tab before       │ │
│   Tue 6 Oct, 9–9:45 AM · ov… │ │ Thursday? I think the March number is off.   │ │
│                              │ └──────────────────────────────────────────────┘ │
│   Stripe             8:31 AM │ ┌ Reply to all…                                ┐ │
└──────────────────────────────┴──────────────────────────────────────────────────┘
  list 320                       reading pane, at least 420
```

One column: 6.1.2 (the list at full width) and 6.2.2 (a conversation over it) from 600 pt;
6.1.3 and 6.2.1 under 600. The pane switched off at any width: the same two screens between
the control and details columns.

#### 6.0.6 A question for the author: where the control column lives

On the Mac the first column can be drawn two ways. He should see both before choosing; the
slice being built on sample mail produces the picture (MAIL-PLAN section 8).

- **A. A column inside Mail** — recommended, and what is drawn above. Banana's sidebar stays
  the app's: its ten sections. Mail's places are a column of Mail's own beside it. With
  everything showing that is five columns across; Banana's sidebar hides as it does today
  (the split view's own button), which leaves his four.
- **B. Banana's sidebar is the control column.** Mail's places are nested under the Mail row
  while Mail is in front. Four columns exactly, and about 220 pt more for reading on a
  laptop.

Why A:

1. **It is one rule on every device.** B exists only where Banana draws its own sidebar,
   which is the Mac. An iPad's sidebar is the system's and cannot hold the list, so the
   column inside Mail has to be built whichever he chooses.
2. **The app's main navigation stays a fixed set of targets.** In B the sections below Mail
   move every time Mail is entered or left, and whenever a label is added.
3. **The shell stays ignorant of Mail.** Today nothing of Mail's is drawn or observed by the
   shell (G3). In B the sidebar draws Mail's counts.
4. **A can still give the width back**: ⌥⌘S hides the column, and the list's header then
   carries the split tabs.

What B costs if he chooses it: one package, which puts the same `MailControlColumn` view
under the Mail row of the Mac's sidebar; the column inside Mail then shows only where there
is no such sidebar. Nothing else changes, because the column's content is one view either
way.

### 6.1 The list

#### 6.1.1 What a row says

In order of importance. Each item has one fixed position, so the eye learns where to look.
The strings are made once per row, off any view body (`MailRowDisplay`, pure), from the
contract's `MailRow`.

| # | Item | Content rule |
|---|---|---|
| 1 | **Who** | One other person → their name, or their address when the engine gives no name (it withholds a name that looks like an address or mixes scripts). Several → first names in order of first appearance, with "me" for the author when he is one of several authors ("Sam, me, Jane"); more than three → the first, "…", the last two. In Sent, Drafts and Outbox: "To: " and the recipients by the same rule. Semibold when the conversation is unread, regular when read. Truncates at the tail. |
| 2 | **How many** | The message count, when two or more, straight after the names: `.caption`, tabular, secondary. Never truncated. |
| 3 | **What about** | The subject with reply and forward prefixes removed ("Re: Fwd: Q3" → "Q3"). Empty → "(no subject)" in secondary. Truncates at the tail. |
| 4 | **What it says** | The snippet, white space collapsed, in secondary; in a search, the excerpt around the match. Replaced by a **reason line** when there is one (below). |
| 5 | **When** | `DateText.row` (three-line row) or `.column` (one-line row) of the row's date, secondary, tabular. Never truncated; its column scales with the text size. |
| 6 | **State glyphs** | Three slots of `DS.Mail.glyphSlot`, always in this order, empty when not applicable: attachment (`paperclip`) · invitation (`calendar`) · star (`star.fill`, accent). In places that are not the inbox (search, All mail, labels, Starred, Sent) a fourth slot leads them: in the inbox (`tray`). Secondary, `.footnote`. |
| 7 | **Unread** | A dot of `DS.Row.statusDot` in `DS.Palette.info`, in the gutter. With the semibold name: two signals, neither colour alone. |
| 8 | **Label** | At most one `DSChip` in the label's colour, then "+2". His own labels only (the row carries no others); never the label whose list this is. |
| 9 | **Account** | A plain `DSChip` with the account's short name. Only when two or more accounts have Mail and the list is not narrowed to one. |

**Reason lines** replace the snippet. One at a time, from the row's `reason`:

| `MailRowReason` | Text | Glyph · colour |
|---|---|---|
| `asking(_, .sendUnconfirmed)` | "Not sure this was sent" | `questionmark.circle` · warning |
| `asking(_, .sendLate)` — he pressed Send more than a day ago and it has not gone | "Not sent yet · waiting since Mon 2:02 PM" | `clock.badge.exclamationmark` · warning |
| `asking(_, .draftChangedElsewhere)` | "Changed on another device" | `questionmark.circle` · warning |
| `asking` about a schedule (`.scheduleOwnedElsewhere`, `.scheduleChangedElsewhere`) | "Was due 8 AM · not sent yet" · "Not sent · changed on another device" | `clock.badge.exclamationmark` · warning |
| `failedToSend` | "Couldn't send · " and the short reason (7.6) | `exclamationmark.circle.fill` · danger |
| `changeRefused` | "Couldn't apply · " and the short reason | `exclamationmark.circle` · danger |
| `held(until:)` — in the undo hold | "Sending…" — with **Undo** at the line's trailing edge in a one-line row, until the hold ends (6.3.7) | `arrow.up.circle` · secondary |
| `waitingToSend` | "Waiting to send" | `arrow.up.circle` · secondary |
| `sending` | "Sending…" | `arrow.up.circle` · secondary |
| `checkingSent` | "Checking whether this was sent" | `arrow.up.circle` · secondary |
| `scheduled` | "Sends Thu 8 AM" · on another device: "Sends Thu 8 AM · from another device" · late: "Was due 8 AM · not sent yet" in warning | `clock` |
| `draft` | "Draft · Thanks, I'll look at it tonight…" — only while the conversation is read; an unread conversation shows its snippet, led by a `pencil` glyph | `pencil` · secondary |
| `backFromSnooze` | "Back from snooze" · if it was "if no reply": "No reply by Thu 8 AM" | `clock.arrow.circlepath` · secondary |
| `snoozed` | "Until Thu 8 AM" · "Until Thu 8 AM, unless they reply" | `clock` · secondary |
| `keptAfterRemoval` | "Deleted in Gmail · kept on this Mac" | `tray.and.arrow.down` · secondary |

Every time is `TimeRangeText.time`; every date is `DateText`.

**No avatars in lists.** They cost a fetch per sender and tell the sender nothing they should
know. A `Monogram` appears in the conversation only.

**Skeleton row.** A conversation known to belong here whose first message has not arrived
(`stillLoading`) is the same row with bars in secondary at `Tint.subtle`: one per line, at
40 %, 70 % and 55 % of the line's width. Same height, so nothing jumps.

**A kept row.** A row kept by a marking action (T17) is drawn like any other until a reading
omits it. From then on it is dimmed: its texts one step down (primary to secondary, secondary
to tertiary), its glyphs and chip at half strength, no unread dot. Same height, same place.
VoiceOver adds "no longer in this list".

#### 6.1.2 Regular: beside the pane, and at full width

**Beside the pane** (the list column of 6.0.5) the list is 320 to 440 pt wide and uses the
three-line row of 6.1.3. Its header is `DS.Mail.header`: the place's name; a filter menu
(`line.3.horizontal.decrease`, filled when a filter is on); then, trailing, Search, Compose
and the pane button. When the control column is not showing, ≡ leads the header and opens
Places. Active filters are a row of removable `DSChip`s under the header, only while there
are any.

**At full width** — the pane switched off, or Mail between 600 and 739 pt wide — it is this:

```
┌──────────────────────────────────────────────────────────────────────────────────────────────┐
│ ≡  Important 12   Calendar 2   VIP 3   Other 40+                 ⟦Unread ×⟧   ⌕ Search   ✎   │ header 44
├──────────────────────────────────────────────────────────────────────────────────────────────┤
│ ○ Offline · 3 changes waiting                                                                │ status 28, only when not live
├──────────────────────────────────────────────────────────────────────────────────────────────┤
│   TODAY                                                                                      │ group 24
│   ●  Sam, Jane 3       Q3 numbers before Thursday  Can you look at the revenue t…  ⌇  · ★   9:12 AM │
│ ▌    Jane Park         Invitation: Design review  Tue 6 Oct, 9–9:45 AM · over…        ▦      8:40 AM │ ← cursor
│      Stripe            ⟦Invoices⟧ Your receipt from Stripe  Amount paid $49.00…    ✓  ⏱  ⋯          │ ← pointer over it
│ ✓    Ana Ruiz          Contract draft  Redlines attached, two questions on…        ⌇          8:02 AM │ ← selected
│   YESTERDAY                                                                                  │
│      no-reply@acc…     (no subject)  Your sign-in code is 481 220                     7:44 PM │
└──────────────────────────────────────────────────────────────────────────────────────────────┘
  ↑  ↑  └ sender ──────┘ └ subject, then snippet in secondary: one truncating run ┘ glyphs  date
  │  gutter 20                senderColumn 176                                       3 × 20   72
  cursorSpine 3
```

- **Which row.** The list measures its own width: from `DS.Mail.oneLineMinWidth` it uses the
  one-line row (`DS.Mail.oneLineRow` tall), narrower it uses the three-line row of 6.1.3 — so
  a list column beside a pane is always three lines to a row. At full width the list is
  never wider than `DS.Mail.listMaxWidth`; a wider room gets margins. The three fixed columns
  of a one-line row scale with the text size.
- **One line:** `.body` text. The subject is shown whole if it fits the run; the snippet gets
  what is left; a subject longer than the run truncates and no snippet shows.
- **How many are visible:** in a list column, about nine on a 14-inch MacBook and about
  eleven at full height on a 16-inch one. At full width with one-line rows, about 20 in the
  Mac's default window (1120 × 780).
- **Date groups:** eyebrow labels (`DS.Typeface.eyebrow`, tracked, tertiary): TODAY ·
  YESTERDAY · THIS WEEK · the month's name · the year. They are section headers, not rows:
  `J` and `K` pass over them. In a list column they are drawn only at full width's one-line
  rows; three-line rows carry their own dates.
- **The cursor row** (T2): `DS.Palette.selection` in a `Radius.control` shape inset
  `Space.xs` from the list's edges, with a `DS.Mail.cursorSpine` accent bar at its leading
  edge. **It keeps everything a row says**: its date, its star, its attachment mark. While a
  conversation is open in the pane the row keeps a quieter fill
  (`Color.primary.opacity(DS.Tint.soft)`) and gives its spine to the pane's header (T49).
- **A selected row:** a filled check circle in the gutter and `DS.Palette.accent` at
  `Tint.soft` across the row. A selected row that also has the cursor shows both: the wash
  and the spine.
- **The row under the pointer:** `Color.primary.opacity(DS.Tint.wash)`, and its glyph slots
  and date are replaced by three quick actions — Done, Snooze, More — in the same width, so
  nothing else in the row shifts. Each is a `DS.Mail.pointerTarget` button with a `.help`
  naming its key. Hover never moves the cursor.
- **A click** puts the cursor on the row, and the pane shows it; a double-click opens it
  (T49). With no pane a click opens (T10). **Right-click** opens the row's menu: the
  Conversation group of 4.5. A two-finger swipe on a trackpad, and a finger on iPad, give the
  swipe actions (6.1.6).
- **The header at full width:** `DS.Mail.header`. Leading: the Places button (≡) when the
  control column is not showing, then the split tabs — text, `.body`; the selected one
  primary and semibold, the rest secondary; the count after each, tabular, secondary — or,
  when the control column is showing, the place's name alone. Trailing: active filters as
  removable `DSChip`s, a search field (collapsed to "⌕ Search" until focused; 6.4), Compose
  (`square.and.pencil`), the pane button.
- **With a selection** the header reads "12 selected" with Cancel. Its actions — Done ·
  Label · Move · More — are in the pane (T54), or at the trailing side of the header where
  there is no pane.

#### 6.1.3 Compact

Recommended; **prototype P4 settles the bottom slot on a phone, and U4c builds its final
form.** Splits, Places, Search and Compose are in one strip at the bottom, under the thumb.
The header keeps what is read, not pressed.

Until P4 has run the compact list is not missing: every package builds its screen at this
width too (the owner's ruling), with the slot's controls where the system already puts them
— ≡ and the place's name at the leading side of the navigation bar, Search and Compose at
its trailing side, a conversation's four actions in a bottom toolbar. That fallback needs
nothing unproven; U4c replaces it with the slot.

```
┌─────────────────────────────────────────┐   ┌─────────────────────────────────────────┐
│ Important                             ⏷ │   │ Important                             ⏷ │ header 44: the place · filter menu
├─────────────────────────────────────────┤   ├─────────────────────────────────────────┤
│ ○ Checked 14 min ago                    │   │                                         │ status 28, only when not live
├─────────────────────────────────────────┤   │ ● Sam, Jane 3                   9:12 AM │
│ ● Sam, Jane 3                   9:12 AM │   │   Q3 numbers before Thursday     ⌇ · ★  │
│   Q3 numbers before Thursday     ⌇ · ★  │   │   Can you look at the revenue tab bef…  │
│   Can you look at the revenue tab bef…  │   ├─────────────────────────────────────────┤
├─────────────────────────────────────────┤   │   Jane Park                   Yesterday │
│   Jane Park                   Yesterday │   │   …                                     │
│   Invitation: Design review        ▦    │   │                                         │
│   Tue 6 Oct, 9–9:45 AM · overlaps Sta…  │   │      ( Marked “Q3 numbers” Done  Undo ×)│ toast, above the slot
│   …                                     │   ├─────────────────────────────────────────┤
├─────────────────────────────────────────┤   │ ≡ ⟦Important 12⟧ Calendar 2 ›  ↩  ⌕  ✎ │ the slot, with Undo (T44)
│ ≡ ⟦Important 12⟧ Calendar 2 VIP › ⌕  ✎ │   ├─────────────────────────────────────────┤
├─────────────────────────────────────────┤   │ ▶ Episode title              ❙❙   +30   │ now-playing bar (the shell's)
│  Plan   Mail  Workouts Nutrition Library│   ├─────────────────────────────────────────┤
└─────────────────────────────────────────┘   │  Plan   Mail  Workouts Nutrition Library│
   nothing playing                            └─────────────────────────────────────────┘
                                                 an episode loaded
```

- **Row:** three lines in system text styles, so it grows with Dynamic Type: line 1 names
  `.callout` and date `.footnote`; line 2 subject `.subheadline` with the glyph slots
  trailing; line 3 snippet or reason `.subheadline` secondary, with the label chip leading
  and the account chip trailing. Insets: `Space.s` above and below, `Space.hair` between
  lines, `DS.Mail.gutter` leading, `Space.l` trailing. About 76 pt at the default size.
- **How many are visible:** about eight on a 6.3-inch iPhone with nothing playing; about
  seven with an episode loaded.
- **Header:** `DS.Mail.header`: the place's name as an inline title, and a filter menu
  (`line.3.horizontal.decrease`, filled when a filter is on): Unread, Starred, Important, No
  reply, and the accounts.
- **The slot** (`MailBottomBar`, `DS.Mail.bottomBar`): Places (≡) as the first chip, then the
  split chips with their counts, scrolling sideways under a fade — the selected one a filled
  control chip, the rest plain; then, fixed at the trailing end, **Search** (`magnifyingglass`)
  and **Compose** (accent), 44 pt each. For two minutes after an action an **Undo** button
  (`arrow.uturn.backward`) sits before Search; while a send is in its hold it reads as "Undo
  send". The slot never changes height.
- **"Never moves" means within one screen.** P4 decides how the slot sits with the shell's
  two bars. Recommended: on the Mail tab the tab bar does not collapse on scroll
  (`tabBarMinimizeBehavior` follows the selected tab), so the slot stays put; the now-playing
  bar, when an episode is loaded, sits between them as it does on every tab.
- **Pull down** checks for mail (7.2). There is no pull-to-search.

**What P4 must show**, on a phone with an episode loaded: pictures of the list with the tab
bar expanded and (if it is allowed to collapse) collapsed, of a conversation with the tab bar
hidden — nothing in the app hides it today — and of the slot while selecting; that the slot
does not change position during a scroll; that no gesture is lost in twenty trials of each
swipe, including a swipe along the conversation's action bar against the system's back
swipe; and the idle CPU of the route unchanged. If the tab bar cannot be held still per tab,
the fallback is the slot's contents as two floating controls with no strip. If it cannot be
hidden in a conversation, the action bar sits above it. The author sees the pictures before the
layout is fixed (MAIL-PLAN section 8).

#### 6.1.4 The status line

One line of `DS.Mail.statusLine` under the header, in both arrangements: `StatusDot` and
`.footnote` secondary text. It is absent when the list is live. Its texts are in 7.2; it is
drawn by `MailStatusLine`, which with the foot card is the only view that observes the
source's status.

#### 6.1.5 Selecting

- **Compact.** Long-press, More › Select, or the VoiceOver action starts it (T39). The gutter
  shows a 22-pt check circle on every row (accent fill when selected). The header's title
  becomes "3 selected" with Cancel. The slot's content becomes **Done · Label · Move · More**,
  labelled 44-pt buttons, Done where a conversation's Done is (6.2.1). A two-finger drag down
  the list selects a run, as in system lists.
- **Regular.** `X`, `⇧J`/`⇧K`, ⌘A, ⌘⇧A, or ⌘-click and ⇧-click on rows. Drawing as in 6.1.2.
  With the pane showing, the selection's summary and its actions are in the pane (T54,
  6.2.2).

#### 6.1.6 Swipe actions

The system's list swipe actions, and nothing else. No `DragGesture` on or under a row,
simultaneous or otherwise: on iOS 26 it stops the list scrolling.

| Edge | Full swipe | Revealed by a short swipe |
|---|---|---|
| Trailing (finger moves left) | **Done** — `checkmark`, `DS.Palette.success`, declared destructive so the row leaves in one motion | Done · **Trash** (`trash`, `DS.Palette.danger`) |
| Leading (finger moves right) | **Unread / Read** — `envelope.badge`, `DS.Palette.info` — until Snooze is built; then **Snooze** (`clock`, accent), which opens the picker, with Unread behind it | |

Each button shows its symbol and its word. The inward stroke of the right thumb, the easiest
there is, belongs to the commonest action. The haptic at the commit point is the system's.
The same actions are on iPad rows and on a Mac trackpad's two-finger swipe.

#### 6.1.7 One list model

**A list is a window of rows, found by key.**

- **What the source gives.** `observeList(scope, limit:)` delivers the first `limit` rows of
  the scope, kept current, with `total`, `hasMore` and `stillLoading`. The model starts at
  `MailTuning.listStep` rows and asks for a step more whenever the viewport or the cursor
  comes within 30 rows of the last row delivered, up to `MailTuning.listCap`. It asks once a
  step: again only when the reading for the limit it last asked for has arrived. **That is
  decided from the reading's count, not from the rows on screen.** A row held back in the
  "new" chip is in the reading and not on screen, so counting the rows on screen would stop
  a list that is scrolled deep, with a chip waiting, from ever growing again. The rows a
  growth brings are taken in at once, at rest or not, because he asked for them (T7).
- **What the host is given.** At most 400 consecutive rows of those — the *window* — placed
  so the viewport is inside it. `MailListModel` holds every row delivered and cuts nothing;
  the window is cut between the model and the host (`MailListWindow`, package U4a), which
  also brings a row into the window when the model asks to show or restore one outside it. When the viewport comes within 100 rows of a window edge the
  window slides by 200, in one update that leaves every row on screen where it is. So what
  the host diffs and the main thread touches is bounded by 400 whatever the list's length.
- **Everything is found by key or id, never by row number**: the cursor, the selection, the
  row to restore, where arrivals belong. That is why a window sliding, a limit growing, or a
  rebuilt view tree changes no rule in section 3.
- **Restoring.** After the view tree is rebuilt (the iOS discard, the Mac's sidebar) the
  model still holds its rows; the host is told the position (T46): the key of the row that
  was first on screen and whole points into it. After a cold launch the model observes with
  the stored limit and finds the stored row by id (the contract's promise 11), or, if it has
  left, the first row at or after its stored key.
- **The foot** says why the list ends. One of:

| State | Foot |
|---|---|
| The whole place is on the device, and it is a split | A row naming the next split with mail: "Other · 40  ›" (`Tab` on a keyboard). Absent if no other split has mail. |
| Older mail is still downloading | The first-sync card (7.1). |
| The list has reached the edge of what this device keeps (`heldSince`) | "Mail before 5 Apr is in Gmail, not on this Mac." (`.footnote`, secondary), with **Get older from Gmail** — it asks Gmail for this place's next fifty (`askGmail(_:)`), which join below with the glyph of 6.4.3 and are fetched when he stops on one — and **Keep more…**, which opens the setting (6.8.1). While Gmail is being asked the foot is the skeleton row of 6.4.3; offline it says "Older mail can be shown when you're online." |
| The list has reached `MailTuning.listCap` and there is more | "Older conversations are in search." (`.footnote`, secondary), with a **Search** button |
| Otherwise | Nothing: more rows are asked for before the end is reached. |

Prototype P1 ran with exactly this window — 400 rows, re-centred by 200 — and the native
host held it without a jump (6.1.8). It did not measure 2,000 rows applied whole, so the
window stays.

#### 6.1.8 The host, and what the list must do

**The rows are SwiftUI; the scrolling container is the platform's.** `MailListHost` is one
type with two implementations: a `UICollectionView` with the system's list layout on iPhone
and iPad, its rows hosted through `UIHostingConfiguration` (which also gives the system's
leading and trailing swipe actions), and an `NSTableView` with hosting cells on the Mac. The
host is told three things — apply this window keeping this row where it is; show this row;
restore this position — and reports four: a tap, a swipe action, whether the first row is on
screen, and the position when scrolling stops.

**This was measured.** Prototype P1 (`mail-working/prototypes/p1-list/RESULTS.md`) ran the
5,200-row fixture in a Release build on the iPhone Simulator, three runs of each scenario:

| | Native collection view | SwiftUI `List` | `LazyVStack` |
|---|---|---|---|
| Three rows join above row 50 | Moves 0.00 pt, 30 of 30 times | 156 pt, for good | 192 pt for one frame, or whole rows only |
| The view tree is rebuilt at row 137 | Within 0.33 pt, on its first frame | Comes back at the wrong row | Within 0.33 pt, or 48 pt off |
| The 400-row window slides | No jump | 7 jump frames, up to 1,212 pt | Every scroll lands a frame late |
| `J` held for 2,000 moves | No container work; two leaf views a move | Passes | Passes |
| Twenty full swipes on each edge | 20 of 20; scrolling never blocked | 20 of 20 | No system swipe actions |

So the list is built on the native host, and SwiftUI's `List` and `LazyVStack` are not used
for it. **The Mac's half has not been measured.** The `NSTableView` host compiles; its run of
the same scenarios needs a slot at the owner's Mac (13.4). U4a builds both hosts to the rules
below, and the Mac's is accepted when its own run has passed.

**What the prototype's findings require of the host:**

- **A position is a row's key and whole points into that row** (T46), everywhere: the anchor
  taken before a window change and put back after it, the stamp taken for a restore, what is
  reported when scrolling stops. The list layout estimates the rows it has not drawn — 52 pt,
  against 64 pt drawn — so the content's height changes as rows are drawn, an offset from the
  top is not a row number, and nothing multiplies a row number by a height. A fixed row
  height is a fact about how a row looks, not about the layout.
- **A window change is applied in the same turn as the publish.** The host subscribes to the
  model's window itself, applies the new one without animation inside that delivery, and puts
  its anchor back before any frame is drawn. Nothing between the publish and the apply is
  deferred: no task, no hop to a later turn. That is what made 0.00 pt; a deferred apply is
  the one-frame slip the SwiftUI hosts showed.
- **Nothing in a hosted row reads its own geometry to decide anything about scrolling.**
  While the list scrolls, the collection view moves the cell and SwiftUI is not told, so a
  geometry callback inside a row is stale. Whether the first row is on screen (T9), and that
  scrolling has stopped, come from the scroll view's delegate.
- **The first restore waits for a size.** The host is made with no size; the position is set
  in its first layout pass that has one, and the list is laid out again.
- **What the prototype did not measure is U4a's to prove**: the cursor and selection on the
  native host, context menus, VoiceOver, the Mac's swipe actions, Dynamic Type sizes, and the
  cost of the real row. One cursor move took 7 ms of the main thread at the 95th percentile
  on the Simulator, which fits a 120 Hz frame with little to spare; a device run confirms it
  (13.4).

**And three things the triage model needs of the host**, found when it was built:

- An empty list is showing its top: with no rows the host reports "the first row is on
  screen" as true, or arrivals held back from an emptied list would never join. A
  conversation covering the list does not make it false.
- Closing a conversation restores a position and then shows the cursor row. The host applies
  the two as one move.
- A row the model asks to show or restore that lies outside the window is brought into the
  window first (6.1.7).

**Must**

- Rows are two small `Equatable` view types — `MailRowThreeLine` and `MailRowOneLine` — each
  built from leaf views and drawing a ready-made `MailRowDisplay`. No row creates a formatter
  or does string work.
- The cursor and the selection are **not** state of the list. Each row's background is a
  small view observing that row's own `MailRowMark` (3.11). A held `J` re-evaluates two small
  views per step and never the list's container.
- Scrolling to keep the cursor visible is the model's effect, carried out by the host, from
  outside any body.
- Two scroll facts are read and no others: whether the first row is on screen (T9), and the
  position when scrolling stops (T46). The host reports each from its scroll view, and only
  when it changes.
- The host observes one thing: the window, published once per applied change — his own
  action, a reading he asked for, or one application when the list is at rest. No SwiftUI
  container stands between the model and the host to be re-evaluated: `mail.list.renderCount`
  counts the host wrapper's body and its update call, and a window change does not raise it.
  The status line, the foot card and the badge are separate leaf observers.
- `listApply` — taking a snapshot into the model and the window into the host — is at most
  4 ms on the main thread at 400 rows on a phone, and at most 16 ms at 2,000.

### 6.2 The conversation

#### 6.2.1 Compact

```
┌─────────────────────────────────────────┐
│ ‹ Important                       ⌃  ⌄  │ navigation bar: Back · newer, older (T42)
├─────────────────────────────────────────┤
│ Q3 numbers before Thursday              │ subject, .title3 semibold, up to 3 lines
│ ⟦Invoices⟧  to noor@plan.example              │ labels · which account (when there are two)
├─────────────────────────────────────────┤
│ Jane Park   Looks fine to me, one…  Mon │ folded message: one row, 44
│ 5 earlier messages                      │ fold of folds
├─────────────────────────────────────────┤
│ (S) Sam Lee                     9:12 AM │ open message: Monogram 32 · name · date
│     to me, Jane                      ⌄  │ recipients, expandable · the message's menu
│                                         │
│ Can you look at the revenue tab before  │ body: text, .body, selectable
│ Thursday? I think the March number is   │
│ off.                                    │
│ ⟦•••⟧                                   │ quoted text, folded
│ ⟦▤ Q3.xlsx · 84 kB⟧ ⟦▧ chart.png⟧       │ attachments
│                                         │
│      ( Marked “Budget” Done   Undo  × ) │ toast, above the bar
├─────────────────────────────────────────┤
│  ✓ Done    ✉ Unread   ⟦  ↩ Reply  ⟧  ⋯  │ MailBottomBar: the action bar
└─────────────────────────────────────────┘
```

- Pushed full-screen; the tab bar is hidden (P4 confirms it can be).
- **The action bar** holds four controls in fixed positions: Done, a second action (Unread
  until Snooze is built, then Snooze; symbol over word, 44-pt targets), a wide **Reply** in
  the accent, More. Done is T16; the next conversation arrives under a bar that has not
  changed, so clearing a run is tap, tap, tap in one spot.
- **Older and newer** are buttons in the navigation bar (`chevron.down`, `chevron.up`),
  disabled at the ends of the list. They are how a conversation is skipped without acting on
  it. A swipe along the action bar for the same thing is added only if P4 allows (T42).
- **Reply** replies to everyone in the conversation (to the sender alone when there is no one
  else). More lists Reply to sender and Forward; so does a press and hold.
- **More** opens the command sheet (6.7).

#### 6.2.2 Regular: in the reading pane, and over the list

**In the pane** (drawn in 6.0.5) a conversation is the same view as below, in the pane's
column instead of over the list:

- **Header:** `DS.Mail.header`. Leading, newer and older (`K`, `J`). Trailing, the actions as
  icon buttons with tooltips that name their keys — Done (`E`), Snooze (`H`), Star (`S`),
  More (⌘K with this conversation as the target) — and ⓘ, which shows and hides the details
  (6.10). There is no Back: the list is beside it. 44-pt targets on iPad,
  `DS.Mail.pointerTarget` on the Mac.
- **Showing or open** (T49). A conversation that is only showing looks the same as an open
  one, but for where the spine is: on its row while the keys are the list's; at the leading
  edge of the pane's header once it is open. Nothing else moves or changes when it is opened.
- **It never blanks.** While the next conversation is being read, the pane keeps the one it
  had (T48). With nothing to show — an empty list — it is a plain surface with no words: the
  list says why it is empty (7.8).
- **A selection** is drawn here in place of a conversation (T54):

```
┌──────────────────────────────┬──────────────────────────────────────────────────┐
│ ≡  3 selected         Cancel │ 3 selected                                 Clear │
├──────────────────────────────┼──────────────────────────────────────────────────┤
│ ✓ Sam, Jane 3        9:12 AM │                                                  │
│   Q3 numbers before Thu… ⌇ ★ │   Q3 numbers before Thursday                     │
│   Can you look at the reven… │   Invitation: Design review                      │
│ ✓ Jane Park        Yesterday │   Your receipt from Stripe                       │
│▌  Invitation: Design revi… ▦ │                                                  │
│   Tue 6 Oct, 9–9:45 AM · ov… │   ⟦ ✓ Done ⟧  ⟦ Label ⟧  ⟦ Move ⟧  ⟦ ⏱ Snooze ⟧  │
│ ✓ Stripe             8:31 AM │   ⟦ Trash ⟧   ⟦ ⋯ More ⟧                         │
└──────────────────────────────┴──────────────────────────────────────────────────┘
```

- **A new message** (`C`) is written here: the composer card alone in the pane, with the list
  beside it (6.3.1).

**Over the list** — where there is no pane: Mail between 600 and 739 pt, or the pane switched
off:

```
┌──────────────────────────────────────────────────────────────────────────────────────────────┐
│ ‹ Important    ↑  ↓                                          ✓   ⏱   ★   ⋯                   │ header 44
├──────────────────────────────────────────────────────────────────────────────────────────────┤
│                 Q3 numbers before Thursday                          ⟦Invoices⟧               │
│                 to noor@plan.example                                                               │
│               ┌─────────────────────────────────────────────────────────────┐                │
│               │ Jane Park   Looks fine to me, one question about…      Mon  │                │
│               ├─────────────────────────────────────────────────────────────┤                │
│               │ (S) Sam Lee  to me, Jane                           9:12 AM  │                │
│               │                                                             │                │
│               │ Can you look at the revenue tab before Thursday? I think    │                │
│               │ the March number is off.                                    │                │
│               │ ⟦•••⟧   ⟦▤ Q3.xlsx · 84 kB⟧ ⟦▧ chart.png⟧                   │                │
│               └─────────────────────────────────────────────────────────────┘                │
│               ┌ Reply to all…                                               ┐                │
└──────────────────────────────────────────────────────────────────────────────────────────────┘
                 └──────────── one column, at most DS.Mail.readingMeasure ─────┘
```

- The conversation is drawn over the list, which stays mounted underneath, hidden from
  pointer and VoiceOver. Closing removes the conversation; the list has not moved.
- **Header:** leading, Back named for the place (`Esc`), then newer and older (`K`, `J`).
  Trailing, the same actions and ⓘ. There is no bottom bar in this arrangement (O4).

**In both:**

- **Messages** are cards: `dsCard()`, `Radius.card`, content inset `Space.l`, in one column
  at most `DS.Mail.readingMeasure` wide, centred in the room there is.
- **The reply field** is the last card: one line, "Reply to all…", secondary. Clicking it,
  `Enter` in an open conversation, `R` or `F` turns it into the composer (6.3.1) in place. If
  a draft exists it shows the draft's first line instead ("Draft · Thanks, I'll look…") and
  opens to it.

#### 6.2.3 The header says who, when and which account

- **Subject** once, at the top. `.title3`, semibold, up to three lines.
- **Under it,** one line: his label chips; "to noor@plan.example" (the address the newest message
  was delivered to), only when two or more accounts have Mail; and the conversation's state
  in words when it has one: "Snoozed until Thu 8 AM" · "In Trash" · "In Spam" · "Done" (in
  places that are not the inbox).
- **Each open message:** `Monogram` · the sender's name (`.headline`) · "to me, Jane"
  (`.subheadline`, secondary) · the date (`DateText.row`).
- **Who it really is.** The engine hands over names already cleaned of invisible and
  direction-changing characters, and withholds a name that looks like an address. On top of
  that: **when the sender is someone he has never written to (`isKnown` is false), the
  address is shown beside the name**, in secondary, on the header line — not one tap deeper.
  When a reply would go somewhere other than the address that wrote (a Reply-To), the
  recipients line says so: "replies go to billing@other.example".
- Tapping the recipients line expands it in place to every name with its address, Cc and Bcc
  on their own lines, the full date (`DateText.full`), and "via *list*" for list mail.
- **Each open message's menu** (⌄): Reply · Reply to all · Forward · Mark unread from here ·
  Open in Gmail. Open in Gmail, and Copy link in ⌘K, use the conversation's `gmailURL` and
  are absent while it is nil (a message not yet sent).

#### 6.2.4 Which messages are open

- The newest message is open. Every unread message is open.
- Every other message is **folded** to one row: sender (first name) · the first line of its
  text · date. 44 pt. Tapping, or `O` with it in view, opens it.
- A run of more than three folded rows becomes one row, "5 earlier messages", which opens
  into those folded rows.
- So a 40-message conversation opens as: the header, "39 earlier messages", and the newest
  message. `⇧O` opens everything — every text body at once, and designed bodies up to the cap
  of 6.2.5.
- On open the reader is positioned at the top of the first unread message, or of the newest
  when nothing is unread.

#### 6.2.5 The body

The contract gives each message a `MailBodyState` and, from `body(_:)`, a ready-made
`MailBody`. Bodies are prepared when mail is fetched, so opening reads prepared output; the
reader parses nothing.

| `MailBody` | What it is | How it is drawn |
|---|---|---|
| `.text` | Plain text, or HTML with no design of its own. Almost all mail between people. It arrives as `MailText`: blocks (paragraph, quote, list item, heading, preformatted, rule) of styled runs, with no fonts. | **One TextKit view per message** (`MailTextView`: a `UITextView` / `NSTextView`, not scrolling, not editable). `MailTextRendering` maps blocks and runs to attributed text with the design system's type, off the main thread, in one place: quotes indented with a bar, list items with hanging indents, links in `DS.Palette.info`. Its height is measured off the main thread and recorded. So a range can be selected and copied — one tracking number, one sentence — on the phone as on the Mac. |
| `.designed` | Designed HTML — newsletters, receipts, anything with layout, a picture or a table. It arrives as a whole document for one web view, with the box of every picture declared. | **One web view per open designed message** (`MailWebView`, built with the engine's package P26 to the engine's contract, 10.5 there: no script, no network, pictures only through the source), inside a "paper" card: light in both appearances, `Radius.card`. At most `MailTuning.maxOpenDesignedBodies` exist in a conversation; a designed message beyond that is a card reading **Show this message**, which loads it and empties the one furthest from the viewport. |
| `.notOnDevice` | The body has never been downloaded. | The header, the snippet, and one line: online, "Getting this message…" (the one wait Mail shows: it has never been here); offline, "The rest of this message isn't on this iPhone yet. It downloads when you're online." |

A message says which of these to expect before its body is read (`MailMessage.body`), and
two more states have a line each. **Preparing** — it has arrived and is being made ready:
the header and the snippet, with no words and no spinner; the body appears by itself.
**Too large** — the header, the snippet, and "This message is too large to show here." with
**Open in Gmail**.

- **Nothing jumps.** A body's frame is the height recorded the last time it was laid out
  (`MailRenderHeights`, keyed by message, width bucket, text size and whether its pictures
  are shown). A designed body that has not painted yet is **an empty paper card of that
  height** — not its text in another layout. Because every picture's box is declared, the
  height does not change when pictures arrive. A body never laid out before uses an estimate
  from its text's length, at most one and a half screens; when the real height arrives it is
  applied at once if the body's end is below the viewport, and otherwise when the reader is
  idle, keeping the top row where it is.
- **The reader is a `ScrollView` over a plain `VStack`** of message cards, not a lazy stack:
  forty folded rows cost nothing, positions are exact, and `N`, `P` and "first unread" land
  where they should. A designed message's web view is created when its card comes within a
  screen of the viewport and emptied when it leaves.
- **The text is kept for a designed body too** (`plain`): it is what VoiceOver reads, what
  find searches, and what is drawn if the web view cannot be made.
- **Notices** from the engine are one line above the body, in secondary: too large to show
  in full ("This message is too large to show whole. Open in Gmail."), cut short, or "Shown
  as text: its design couldn't be drawn safely."
- **Quoted text and signatures** are folded behind a `•••` control at the end of the body
  (44-pt target). The engine marks where the quote starts; the view never searches for it.
  In a designed body the fold is the document's own.
- **A very long text body** (over 20,000 characters) is drawn to its first paragraph break
  after that point, followed by "Show the whole message".
- **Dark appearance.** A text body follows the app. A designed body stays as its sender made
  it, on its light card.
- **Right-to-left text** takes its direction from the text itself. The card and header
  mirror with the interface language, not with the message.
- **Nothing in a message is made tappable except a link.** Phone numbers, addresses and
  dates are text: they can be selected and copied. (The security review's rule; see 11.)

**What P3 must show**, on a phone, with TextKit bodies and per-message web views: `mail.open`
within 50 ms at the 95th percentile of twenty opens for `forty` with `⇧O`, `plain-chain`,
and `three-newsletters`; a designed body painted within 150 ms on its second open; the app
within 100 MB of its baseline and the web content process under 150 MB with six web views,
and back within 60 MB a minute after leaving; no card moving more than a point while
scrolling up through `forty`; a range selected and copied, a link tapped, and a word found,
in a text body on iOS 26 and macOS 26. If six web views cannot be afforded, the cap in
`MailTuning` drops and nothing else changes. If a quote's bar costs more than its indent and
colour to draw, the bar goes.

#### 6.2.6 Remote pictures

A picture fetched from the device tells its sender his IP address and the moment the mail
was on his screen, and Banana has no server to fetch through. So the default is to ask, and
there are four levels, as the owner ruled:

| Level | Set from | Covers |
|---|---|---|
| **Ask** — the default | — | Nothing is fetched until he says so, message by message. |
| **Always for this sender** | The message | Mail from that address, when Gmail authenticated it. |
| **Always for this domain** | The message | Mail from any address at that domain, when Gmail authenticated it. |
| **Always, for everyone** | The message, or Settings | Every message, authenticated or not. |

- **The control on a message.** A designed message with pictures waiting shows one native
  line above its card, never inside it: "12 pictures aren't shown." with **Show pictures** —
  this message, this once — and a menu beside it (⌄):
  - "Always show from sam@dispatch.example"
  - "Always show from dispatch.example"
  - "Always show pictures, from everyone…"

  The boxes are already the right size, so showing them moves nothing.
- **The first two are offered only for a sender Gmail authenticated** (`MailPictures.offers`
  says which may be offered; its `sender` and `domain` are the words). A From line is free
  to forge, so otherwise they are greyed, with the reason under them: "This sender couldn't
  be verified." With "everyone" there is nothing to verify. Choosing one is
  `showPictures(in:always:)`.
- **Nothing reaches into Spam.** No level shows the pictures of a message in Spam; there the
  line offers **Show pictures** for that message and nothing else.
- **"From everyone" asks once**, because it cannot be taken back for mail already shown — one
  of the few questions in Mail: "Show pictures in every message? Every sender whose mail
  comes up on your screen will be able to see your IP address and when it did. With the
  reading pane, that includes mail you only pass on the way down the list." · **Show them
  always** · Cancel.
- **Every level has a way back.** Settings lists the senders and the domains he has allowed,
  each removable, and holds the switch for "everyone" (6.8.1; `pictureRules()`,
  `removePictureRule(_:)`). A message whose pictures were shown by a rule says which
  (`MailPictures.shownBy`) in its menu (⌄): "Pictures shown: always from dispatch.example ·
  Stop".
- **Tracking pixels are a separate switch, and it is on.** The pictures Banana recognises as
  trackers are never fetched at any level — also under "everyone" — unless he turns **Block
  tracking pixels** off in Settings. The line says so when there were any: "12 pictures
  aren't shown · 3 trackers removed"; with pictures showing, the message's menu carries "3
  trackers removed". Whether the switch should exist, and be on, is put to him (MAIL-PLAN
  section 8); the recommendation is yes to both.
- **Nothing is fetched for a message that is not on screen**, at any level. Preparing ahead —
  the cursor at rest on a row, the next conversation loaded in advance (8.2) — asks for
  pictures with `presentation: .warming`, which yields what is already on the device and
  nothing else. With a held key the pane shows only where the cursor stops (T48), so nothing
  is fetched for the rows passed.
- Pictures he has shown are kept with the message and are there offline. Offline with
  pictures never shown: "This message's pictures aren't on this iPhone." (no button until
  online).

#### 6.2.7 Links

A link never opens by itself, and one rule decides. A link in a text body calls
`MailLinkRules.decide(url:shownText:shownIsImage:)`. A link in a designed body awaits
`decideLink(_:in:)`, because the web view reports only the address and the engine knows what
was shown for it. The reader also installs the rule as its `openURL`, so nothing can go
round it:

- **Opens** in the default browser when the address does what its words say.
- **Asks first** — a sheet showing the whole destination with its host emphasised, **Open**
  and **Cancel** — when the words name one site and the address is another, when the host is
  not plain ASCII (shown in its `xn--` form), and always when the link is a picture. One of
  the few questions in Mail, because the visit cannot be undone.
- **`mailto:`** opens the composer with To and Subject filled and shown, and nothing else:
  a link cannot add a recipient he does not see.
- **Refused**, silently: any other scheme, an address with a user name in it, an address on
  his own network.
- Press and hold, or right-click, on any link: **Copy link · Open · Show destination**. On
  the Mac a link's address is also its tooltip.

#### 6.2.8 Find, and text size

- **⌘F in a conversation** (More › Find in conversation on touch) opens a find bar at the
  top of the reader: a field, a count ("3 of 12"), `↵` next, `⇧↵` previous, `Esc` closes. It
  searches every message's text, folded or not; a match in a folded message opens it.
  Matches are marked in text bodies with `DS.Palette.accent` at `Tint.fill`; in a designed
  body by the web view's own find. `/` remains search across mail.
- **⌘+, ⌘− and ⌘0 on the Mac** step a conversation's text through five sizes (85 % to
  150 %), remembered on the device. On iPhone and iPad Dynamic Type does this. Heights are
  recorded per size.

#### 6.2.9 Attachments

`DSChip`s under the message that carries them: a symbol for the kind (from the system's type
for what the bytes are; a plain document symbol when they are not what the sender said), the
name (middle truncation), the size (the system's byte-count format). An image is a chip with
a 40-pt thumbnail from the system's thumbnail generator. More than six: the first five and
"+7 more".

| State | Chip | Tap or click |
|---|---|---|
| On this device | As above | Quick Look, and only Quick Look: Banana never opens an attachment in another app by itself |
| Not downloaded, online | Trailing `arrow.down.circle`, secondary | Downloads, showing a progress ring in the chip, then Quick Look. Nothing else waits on it. |
| Not downloaded, offline | Dimmed to secondary | Toast: "Q3.zip isn't on this iPhone. It downloads when you're online." |
| A program (`isExecutable`) | A warning glyph | No preview. A sheet: "“setup.pkg” is a program. Save it only if you trust the sender." · **Save…** · Cancel |

Press and hold, or right-click: Save… · Share… · Copy. On the Mac a chip can be dragged out
to the Finder once it is on the device. `Tab` reaches the chips; ⌘K lists "Open attachment…".

#### 6.2.10 Must

- Opening the next or previous conversation shows its header, every message header and every
  text body in the first frame. The model for the conversation either side of the cursor is
  ready ahead (8.2).
- **No HTML is parsed, converted or measured in the UI at all**, and nothing is laid out in a
  view body. Text bodies come as `MailText`; `MailTextRendering` and height measurement run
  off the main thread. The forbidden calls of the engine's 10.4 (`NSAttributedString` from
  HTML, attributed strings from Markdown, data detectors, opening a URL that did not come
  from the link rule) are forbidden here too, and the same test greps these folders.
- Web views are made by one configuration, assigned a message before loading, never created
  during launch or inside a view body, and all released when the tree is discarded.
- `MailRenderHeights` is an LRU of 2,000 heights, saved off the main thread as
  `render-heights.json` beside the engine's cache through `SnapshotLoader` (a corrupt file is
  set aside, not fatal), and never needed to draw a body whose height is already in memory.
- Each message is its own small view type (`MailMessageCard`, `MailMessageFolded`).
- An attachment's download progress is a leaf observable read only by that chip.
- The reader's position is recorded in `MailSession` as (top message, offset in whole
  points) when scrolling stops, never per frame.

#### 6.2.11 Mail the device does not keep

The device keeps mail back to a limit he chooses, six months by default (6.8.1). Older mail
is in Gmail and one step away. The rules are the engine's (its 5.4); this is what he sees.

- **What is kept, whatever its age:** a conversation with mail inside the limit; one he has
  opened or changed inside it; and anything he has a claim on — starred, a draft, snoozed,
  scheduled or waiting to send, or with a change that has not reached Gmail. **Being in the
  inbox is not a claim**: an inbox that was never emptied would otherwise defeat the limit.
  So a split can end at the limit like any other list (6.1.7), and its count ends in "+"
  while Gmail has more (7.4).
- **A conversation is here whole or not at all.** One whose newest message is inside the
  limit has all its older messages too. No conversation is ever cut in the middle by a date.
- **A conversation that is not here, reached from outside the list** — the link back from a
  task, a notification, a row only Gmail found (6.1.7, 6.4.3) — opens like any other. What
  is known shows at once (the subject and people, from the row or the link); under it one
  line, "Getting this conversation from Gmail…"; then it is an ordinary conversation, kept
  as one he has looked at. Offline: "This conversation isn't on this Mac. It is older than
  the 6 months kept here, and downloads when you're online." with **Open in Gmail**.
- **An action on a conversation that is not here yet** waits for it: 6.4.3.

### 6.3 Compose and reply

One composer (`MailComposerView` over a `MailComposerModel`), in two frames. Prototype P6
proves its three risky parts — the system's rich-text editor, the signature and quote as
blocks, the sheet's detents with the keyboard up — before package U9a.

| | Regular | Compact |
|---|---|---|
| **Reply, reply-all, forward** | Written **in the conversation**, wherever it is showing — in the pane, or over the list: the reply field (6.2.2) becomes the composer card, with an accent spine. The thread stays readable above it. | A **sheet** over the conversation, at the large detent with the keyboard up. |
| **New message** | The same card alone, in the pane with the list beside it; over the list where there is no pane. | The same sheet. |

**First release:** reply, reply-all, forward, new message, attachments, the five formats,
Send, Send and Done, Send now, Undo Send, discard — and **Send later and Remind me if no
reply** (6.3.6), which the owner asked for in it. Those two rest on behaviour of Gmail that
the engine probes on a live account first (its 7.6 and 8); what they tell him when a device
was asleep is fixed in 6.5.5 and does not wait for the probes.

#### 6.3.1 Regular

```
┌▌ To  ⟦Sam Lee⟧ ⟦jane@parkdesign.example⟧ ▏              Cc   Bcc   Subject   From ⌄ ┐
│▌                                                                                      │
│▌ Thanks — I'll look at it tonight.▏                                                   │
│▌                                                                                      │
│▌ ┄ the author                                                    Remove signature ┄        │ signature block
│▌ ⟦•••⟧ On Mon, Sam Lee wrote…                               Quoted text ⌄    ┄        │ quote block, folded
│▌ ⟦▤ notes.pdf · 1.2 MB  ×⟧                                                            │
│▌──────────────────────────────────────────────────────────────────────────────────────│
│▌ 🗑        ⌇   B  I  U  S  ⌁                                              ⟦ Send ⟧   │
└───────────────────────────────────────────────────────────────────────────────────────┘
   ⌘ ↩ Send  ·  ⌘ ⇧ ↩ Send and Done  ·  Esc Keep draft                       (KeyHintRow)
```

- `dsCard()` with a `DS.Mail.cursorSpine` accent bar down its leading edge. Body at least
  120 pt tall, growing with the text.
- In a reply the Subject and From rows are hidden behind their words at the top trailing edge
  (⌘⇧S, ⌘⇧F); Cc and Bcc likewise (⌘⇧C, ⌘⇧B). A new message, and a composer opened from a
  `mailto:` link, show To and Subject rows from the start.
- Footer: the bin at the leading end, away from Send; attach; the four formats and link; and
  **Send** (`.borderedProminent`, accent) at the trailing end.
- In a Beta build the card's top edge carries a `DSChip` in warning: "Beta · sends real mail".

#### 6.3.2 Compact

```
┌─────────────────────────────────────────┐
│ ━━                                      │ grabber
│ Reply                    noor@plan.example ⌄  │ title · From, only when there is a choice
│ To  ⟦Sam Lee⟧ ⟦jane@parkdesign…⟧ Cc Bcc │
├─────────────────────────────────────────┤
│ Thanks — I'll look at it tonight.▏      │
│                                         │
│ ┄ the author                              ×  │ signature block
│ ⟦•••⟧ On Mon, Sam Lee wrote…         ⌄  │ quote block
│ ⟦▤ notes.pdf · 1.2 MB ×⟧                │
├─────────────────────────────────────────┤
│ 🗑   ⌇    Aa                 ⟦ Send ⟧   │ bar above the keyboard
├─────────────────────────────────────────┤
│              keyboard                   │
└─────────────────────────────────────────┘
```

- Title: "New message", "Reply", "Reply to all" or "Forward". No Cancel and no Done in the
  toolbar: closing a composer keeps the draft, so there is nothing to cancel. (The one sheet
  that departs from the Cancel/Done rule, and that is why.)
- **Send is in the bar above the keyboard**, at the trailing edge, as a word in an accent
  capsule; the bin is at the leading end. Press and hold Send: Send and Done · Send now,
  without undo. Both are also in More.
- `Aa` swaps the bar's tools for bold, italic, underline, strikethrough and link; it does so
  by itself while text is selected.
- **Reading the thread while replying.** P6 settles whether the sheet can be dragged to the
  medium detent with the keyboard up. If it cannot, the rule is: drag the sheet down to read
  — the keyboard goes and the thread scrolls behind it; tap the body to return.

#### 6.3.3 Recipients

- **Who a reply goes to is the engine's to decide** (`newDraft(_:)`, its `ReplyRules`): the
  draft arrives addressed, with its subject, identity, signature and quote. The UI computes
  none of it.
- **From** is shown only when there is more than one identity to choose.
- **Replying somewhere else.** When the draft's To is not the address the message came from
  (a Reply-To), the To row is shown expanded with the address, and one line under it in
  secondary: "Replying to billing@other.example, not the address this came from."
- **Autocomplete** from the first character: up to six rows under the field, two columns —
  name, then address in secondary — with the typed part in semibold. `↑` `↓` to move; `↵` or
  `Tab` takes the highlighted row (the first, by default). The order is the engine's
  (`people(matching:limit:)`): people he has written to first, then calendar guests and
  contacts, then people who have only written to him — and those last are shown **by address,
  marked "from their mail"** (`MailPerson.fromTheirMail`), so a look-alike cannot pass for
  someone he knows.
- **Chips.** A chosen person is a control `DSChip`: their name when he has written to them
  before (`isKnown`), **their address when he has not**. `,` `;` or `↵` after a complete
  address makes a chip; a pasted list makes several. Backspace at the start selects the last
  chip; again removes it. A chip's menu: Copy address · Move to Cc · Move to Bcc · Remove.
- **An address that cannot be one** is a chip in a danger wash. Sending with one moves focus
  to it and the toast reads "“sam@” isn't an address."
- **Nobody to send to:** focus moves to To; "Add someone to send to." **Nothing written and
  nobody addressed:** "Nothing to send yet." An empty subject is sent without a question.

#### 6.3.4 Body, signature, quote

- **The body** is the system's rich-text editor: `TextEditor` over an `AttributedString` with
  a formatting definition that admits bold, italic, underline, strikethrough and link, and
  nothing else, so paste is filtered by the same rule. ⌘⇧V pastes plain text. The view maps
  it to and from the contract's `MailText` (bold and italic are read from the resolved font,
  which needs the view's environment, so this mapping lives in the view layer, in one file).
  Turning it into HTML for sending is the engine's.
- Lists and quotes are typed as text in the first release (section 11).
- **The signature and the quoted original are blocks under the editor, not text inside it.**
  The draft carries each as a prepared fragment; it is shown as a message body is shown and
  sent exactly as shown, so a signature with a logo keeps its logo and a quoted newsletter is
  not re-typed into something else. Each block has one control:
  - Signature: **Remove signature** (×). Changing From swaps the signature.
  - Quote, folded behind `•••`: **Quoted text** › Remove · Edit as plain text. "Edit as plain
    text" turns the quote into editable text in the body and says what that costs: "The quote
    is now plain text. Its pictures and layout are gone."
  - Each block is a `MailDraftPart`: its `body` is drawn as a message's is, and its
    `fragment` is handed back untouched. "Edit as plain text" is `quoteAsText(in:)`;
    changing From is `changeIdentity(of:to:)`; a block's pictures come from
    `resource(_:forDraft:presentation:)`.
- **A draft written elsewhere** that Banana's editor cannot hold (`format == .foreign`) is
  shown as it is, sendable as it is, with **Edit as plain text** and **Open in Gmail**.
  Nothing is ever simplified without saying so.

#### 6.3.5 Attachments

- Add with ⌘⇧A or the paperclip. Mac: the system's file panel, or drop files on the composer,
  or paste an image. iPhone and iPad: a menu of Photos (the system's photo picker) and Files
  (the system's file importer).
- Each is a control `DSChip` with its size and an ×. The chip shows the name at once; the
  engine reads the file (`addAttachment`).
- **A forwarded attachment that is not on this device** is a chip marked "downloads before
  sending"; offline the message waits (7.6) rather than going without it.
- **Forwarding a program** (`isExecutable`) asks once: "“setup.pkg” is a program. Forward it
  anyway?" · Forward · Remove it.
- **Over Gmail's limit:** the engine reports what the message would weigh once encoded
  (`draft.encodedBytes`); it is over when that exceeds `MailTuning.maxEncodedBytes`. The
  words speak of attachments, which is what he can change: the chips' line ends in danger —
  "31 MB · Gmail takes about 25 MB of attachments" — and sending answers "Too large for
  Gmail, which takes about 25 MB of attachments. Remove one to send." The message is
  not sent and not lost.

#### 6.3.6 Send

| | Key · touch | What is seen, in the next frame |
|---|---|---|
| **Send** | ⌘↩ · Send | The composer is gone. The message is the last card of the conversation, reading "Sending… · **Undo**" where its date will be. Toast: "Sending · Undo", for the length of the hold. When Gmail has it, the line is replaced by the time. A send that completes inside a minute announces nothing more. |
| **Send and Done** | ⌘⇧↩ · hold Send, or More | The same, and the conversation is marked Done and the next one opens (T16, T38). Toast: "Sending · marked Done · Undo". After ⌘↩ alone, the conversation stays open. |
| **Send now** | ⌥⌘↩ · hold Send, or More | As Send, with no hold and so no Undo. Toast: "Sent." |
| **Offline** | | Toast: "Will send when Banana is next open and online · Undo". The card reads "Waiting to send", with **Edit** and **Don't send** (7.6). |

**With a time** — in the first release, on the picker snooze uses (6.5). Both say what they
depend on where the time is chosen and on the message afterwards: a scheduled message is
sent by the device it was scheduled on, which has to be awake and running Banana then
(6.5.5).

| | Key · touch | What is seen |
|---|---|---|
| **Send later** | ⌘⇧L · a clock button beside `Aa`, then a time (6.5), then Send | Choosing a time changes the button to **Schedule** and shows a read-back line, "Sends Thu 8 AM". Pressing it closes the composer; the message's card reads "Scheduled · Thu 8 AM · from this Mac" with an × that returns it to a draft. Toast: "Scheduled for Thu 8 AM · Undo". Late, and on other devices: 6.5.5. |
| **Remind me if no reply** | ⌘⇧H · the same clock button | Adds a time to whichever send follows: after the message goes, the conversation comes back at that time if nobody has answered. Read-back: "back Fri 8 AM if no reply". |

#### 6.3.7 Undo Send

- The message is held on the device for the **undo hold** — ten seconds unless Settings says
  otherwise — before it is handed to Gmail. The composer does not know the length: it sends
  with `hold: nil`, which is the setting's, and with `0` for Send now.
- **Undo is always within reach during the hold, whatever is done next**: on the message's
  own card ("Sending… · Undo"); on its row's reason line in a one-line list; as the bottom
  slot's Undo button on a phone, which reads as "Undo send" while a hold is running; as "Undo
  send" in ⌘K; and as `Z` while its toast is showing (T26). Marking two conversations Done
  after sending does not bury it.
- Undo reopens the composer exactly as it was: text, caret, attachments, recipients. Nothing
  was sent. The source answers whether it could still be taken back within a few
  milliseconds; if it had already left, the toast reads "Already sent." (T28).
- **Leaving ends the hold and sends.** Going to the background on a phone, or quitting or
  closing the lid on a Mac, sends the message then rather than cancelling it; a Mac that is
  quitting shows "Sending 1 message…" for up to twenty seconds. If it still could not go, a
  notification says so ten minutes later: "A message is still waiting to send."

#### 6.3.8 Leaving and discarding

- `Esc`, clicking elsewhere in the conversation, dragging the sheet down: **the draft is
  kept.** It never asks. A reply's draft stays with its conversation (the reply field shows
  it; the row's reason line reads "Draft · …"). A new message's draft is in Drafts.
- A composer nothing was typed into discards its draft as it closes (`discard(_:)`, with no
  undo entry and no toast).
- ⌘⇧, or the bin: the draft is gone and the toast reads "Draft discarded · Undo" (T25).
- A draft reaches Gmail, and so his other devices, when its composer closes, when the app
  goes to the background, and before sending — not as he types. Settings says so (6.8.1).

#### 6.3.9 Must

- **The composer is on screen, with a caret, in the next frame after the key.** The card or
  sheet is drawn at once; `newDraft(_:)` fills in recipients, subject, signature and quote a
  few milliseconds later, without disturbing what has been typed meanwhile. K12 makes the
  keys typed in between go into the body. No key waits for the draft.
- **A draft's text is never only in view state.** `MailComposerModel` lives in `MailSession`.
  It calls `save` 300 ms after the last edit, on leaving, on backgrounding and before
  sending; nothing waits for it.
- `ShellState.mail.composer` holds the draft's id while a composer is open *and has
  something in it*, and is cleared when the draft is sent or discarded, so it reopens after
  the tree is rebuilt or a relaunch within the hour and never over a later screen.
- Typing re-evaluates the composer's views only: nothing in the conversation or the list
  observes the composer's model.
- Autocomplete asks per keystroke and drops any answer that is not for the current text.
- **A save that fails is said.** On `MailEvent.draftNotSaved`, and when `addAttachment`
  returns nil, the composer shows "Not saved — this iPhone is full" above the body until a
  save succeeds; what he has typed stays in the composer meanwhile.

**What P6 must show:** the system editor with the five formats keeping the selection through
bold and link on iOS 26.1 and macOS 26, and mapping to `MailText` and back without loss; a
signature with a picture and a quoted newsletter shown as blocks under it; the composer open
within 50 ms with both present; the list's and the reader's render probes unmoved while
typing at ten characters a second; and what the sheet's detents do with the keyboard up.

### 6.4 Search

#### 6.4.1 Regular

Search happens in the list column. The field takes the place of the place's name; the
results are the list; the pane shows the result the cursor is on, as it does for any list.

```
┌──────────────────┬────────────────────────────────┬──────────────────────────────────────┐
│ ◧                │ ⟦⌕ q3 from:sam▏          ⟧  ✕  │ ↑  ↓                  ✓  ⏱  ★  ⋯   ⓘ │ the field replaces the place's name
├──────────────────┼────────────────────────────────┼──────────────────────────────────────┤
│ ⌕ Filter         │ ⟦From: Sam Lee ×⟧ To ⌄ Has… ›  │  Q3 numbers before Thursday          │ filter chips 28, scrolling sideways
│ SPLITS           │ 6 months here · asking Gmail…  │  to noor@plan.example                      │ scope line 28 (7.3)
│ Important     12 │ ⟦From Sam Lee⟧ ⟦Label: Invoi…  │                                      │ suggestions, while typing: chips
│ Calendar       2 │                                │ ┌──────────────────────────────────┐ │
│ VIP            3 │ ● Sam, Jane 3         9:12 AM  │ │ (S) Sam Lee  to me, Jane    9:12 │ │
│ Other        40+ │▌  **Q3** numbers before … ⌂ ★  │ │                                  │ │
│ MAILBOXES        │   Can you look at the reven…   │ │ Can you look at the revenue tab  │ │
│  ▣ Inbox         │                                │ │ before Thursday? I think the     │ │
│  ☆ Starred       │   Sam Lee              12 Aug  │ │ March number is off.             │ │
│  ✎ Drafts      2 │   Re: Budget                   │ └──────────────────────────────────┘ │
│  …               │   …the **Q3** forecast is a…   │                                      │
│                  │                                │                                      │ ↓ older than the limit: in Gmail only
│                  │   Sam Lee            Mar 2024  │                                      │
│                  │   Planning notes            ☁  │                                      │ ☁ in Gmail, not on this Mac
│                  │   …our **Q3** plan, as disc…   │                                      │
│                  │ ◌ Asking Gmail for older mail… │                                      │ the foot, while Gmail has not answered
└──────────────────┴────────────────────────────────┴──────────────────────────────────────┘
```

At full width, with no pane, it is the same in one column: the field in the header where the
split tabs were, the chips and the scope line under it, one-line rows.

#### 6.4.2 Compact

```
┌─────────────────────────────────────────┐
│ ⟦From Sam Lee⟧ ⟦Label: Invoices⟧ To ⌄ › │ one chip row: suggestions first, then filters
│ 6 months here · asking Gmail…           │ scope line
├─────────────────────────────────────────┤
│ ● Sam, Jane 3                   9:12 AM │ results: the list's own rows
│   **Q3** numbers before Thursday  ⌂ ⌇ ★ │
│   Can you look at the revenue tab bef…  │
│   Sam Lee                      Mar 2024 │
│   Planning notes                     ☁  │ in Gmail, not on this iPhone
│   …our **Q3** plan, as discussed…       │
├─────────────────────────────────────────┤
│ ⟦⌕ q3 from:sam▏              ⟧  Cancel  │ the slot becomes the field
├─────────────────────────────────────────┤
│              keyboard                   │
└─────────────────────────────────────────┘
```

The field is at the bottom, above the keyboard, where the thumb already is. Suggestions are
chips at the head of the one chip row, not rows of their own, so with the keyboard up there
is room for about three results, not two.

#### 6.4.3 Content rules

- **Before typing:** recent searches — the last eight of this session, kept in memory and
  gone when Banana quits; a query is never written to disk — then the six people he writes
  to most.
- **While typing** (from `MailTuning.searchMinimumCharacters`): up to four suggestions —
  "From *person*", "To *person*", "Label: *name*", "Split: *name*" — then results. Choosing
  a suggestion replaces the matching words with the operator.
- **Results** are a list like any other (T33): the same rows, keys and actions. The snippet
  is the excerpt around the match; matched words are semibold in primary, with no colour.
  The inbox glyph (⌂ above; `tray`) shows which results are still in the inbox.
- **Results come from the device, at once.** Each keystroke asks, and the rows are replaced
  when the answer arrives; an answer for an earlier keystroke is dropped. There is no
  debounce on the device's own search.
- **One list, from the device and from Gmail.** When the device keeps less than everything
  (6.8.1), Gmail is asked for every search with words in it, 400 ms after typing stops, and
  what only Gmail has joins the same list as ordinary rows: **below what the device found,
  newest first, with no heading between them.** Nothing already in the list moves when they
  come. Almost always that is also one date order, because what only Gmail has is what is
  older than the limit; where it is not — a first download still running — the row still
  joins below, because an order bought by moving rows under his cursor is not worth having.
- **Told apart by one glyph, and by nothing else.** A row for a conversation this device
  does not hold (`isOnDevice` is false) carries `icloud` in its first glyph slot, and
  VoiceOver says "in Gmail". What it shows is what Gmail's answer gave: the sender, the
  subject, the date and a snippet of the message that matched.
- **Stopping on one brings it here.** When the cursor stops on such a row (T48), or it is
  opened, the conversation is fetched whole and is then on the device like any other, for as
  long as the limit keeps what he has looked at (6.2.11). Its glyph goes.
- **A change needs the conversation.** Until it is here an action on it does nothing and
  says why: "Still getting this one from Gmail." — or, offline, "This one isn't on this Mac,
  so it can't be changed offline." In practice the row under the cursor is here a moment
  after the cursor stops. A selection by scope over a search acts on the conversations the
  device holds, and its count says so: "38 selected · on this Mac".
- **While Gmail's answer is on its way** the device's rows are already there. The scope line
  says so (7.3), and the list's foot is one skeleton row reading "Asking Gmail for older
  mail…". When the answer comes the foot gives way to its rows. If Gmail has more than it
  sent, the foot is **More from Gmail**, which asks for the next fifty (`askGmail(_:)`).
- **Offline**, the device's rows, and the foot says "Mail before 5 Apr is in Gmail. It can be
  searched when you're online." **If Gmail does not answer**, the foot says "Gmail didn't
  answer." with **Try again** (`askGmail(_:)`). A row only Gmail found is gone when the
  search is left: it was never stored.
- **When the device keeps everything**, Gmail is asked only while the device's copy of that
  account is still incomplete, and whenever he asks with the last row of the results,
  "Search Gmail for “q3 from:sam”" (`askGmail(_:)`; the snapshot's `remote` follows).
- **Filter chips are a view of the text.** A typed `from:sam` becomes the chip "From: Sam
  Lee"; removing the chip removes the words. Chips that are menus (From, To, Label, Date)
  write the operator into the field. Where each operator sits in the text comes from the
  source's one tokenizer (`queryTokens`); the UI has no parser of its own. In a list column
  the chip row scrolls sideways under a fade.
- **The scope line** says what was searched (texts in 7.3).
- **Keys:** `/` or ⌘F with focus in the list focuses the field (K12 applies: what is typed
  next goes into it); `↵` or `↓` moves to the results with the cursor on the first; `Esc`
  from the results leaves search (K9).
- **What is searched:** all mail except Spam and Trash, unless the query says otherwise.

#### 6.4.4 One grammar: search, filters, splits

The grammar is Gmail's, for the operators the engine knows (its 9.1): `from:` `to:` `cc:`
`subject:` `label:` `category:` `in:` `is:` `has:attachment` `filename:` `list:` `before:`
`after:` `older_than:` `newer_than:` `OR` `-` and quotation marks. Bare words match the start
of any word in the subject, the body, a name or an address.

- An operator Banana does not know is not an error: the words are matched on the device as
  plain words and sent to Gmail as typed.
- **A custom split is a name and a query with no free text** — senders, labels, categories,
  lists, flags and accounts — because a split has to be kept up to date as mail changes,
  without the search index. "New split from this sender" is `from:sam@example.com`; "from
  this domain" is `from:@example.com`. "Save this search as a split" is offered only when the
  search has no free words; when the engine declines a split (`saveSplits` says which), the
  editor says "A split works from senders and labels, not from words. Remove “q3”."
- **Edit splits** (Settings › Mail › Splits; Places › Edit): a list in the order shown —
  drag to reorder, tap to rename or change the query, swipe to remove (toast with Undo).
  Other is last and fixed. Splits sync between devices. While a new or changed split is being
  worked out, its list says "Sorting mail into VIP…" in the status line's place.
- Editing splits and saving a search as one are after the first release (section 11); the
  three built-in splits, and custom splits made on another device, work from the start.

#### 6.4.5 Must

- A keystroke never waits on a query, and nothing of search runs on the main thread.
- The list under the field is the ordinary `MailListModel` for the scope `.search(text)`;
  nothing about results is a second list implementation.
- The search text is never written to `ShellState` (3.11).

### 6.5 The time picker

One component, `MailTimePicker`, for four jobs: **Snooze** (`H`), **Send later** (⌘⇧L) and
**Remind me if no reply** (⌘⇧H) in the first release, built after search; and after it
**Add to plan** (`A`, `B`).

```
┌──────────────────────────────────────────────────────────┐
│ ⏱  Snooze until…        Try: 8am, 3 days, fri       Esc  │ field 48
├──────────────────────────────────────────────────────────┤
│   Fri 9 Oct, 8 AM                                    ↵   │ how the typed words were read
│ ▌ Last time · 3 days                          Thu 8 AM   │ ← highlighted when the picker opens
│   Later today                                     1 PM   │
│   Tomorrow morning                            Tue 8 AM   │
│   This weekend                                Sat 9 AM   │
│   Next week                                   Mon 8 AM   │
│   Pick a date and time…                                  │
├──────────────────────────────────────────────────────────┤
│ ↑ ↓ Navigate   ↵ Choose   ⇥ Switch   ⟦ If no reply | Always ⟧│ footer 36
└──────────────────────────────────────────────────────────┘
```

- **Regular:** the command menu's chrome, exactly: 560 pt wide, `Radius.panel`,
  `.regularMaterial`, 32-pt rows, `KeyHintRow` footer, centred near the top of the content.
- **Compact:** a sheet at the medium detent with the same rows at 44 pt; "Pick a date and
  time…" pushes a calendar and the existing `FiveMinuteTimeWheel` inside the sheet. The field
  is at the top and is not focused until tapped: the presets are the fast path for a thumb.

```
┌─────────────────────────────────────────┐
│ ━━                                      │
│ Snooze until…                           │ .headline
│ ⟦ Try: 8am, 3 days, fri              ⟧  │ field, 44
├─────────────────────────────────────────┤
│ Last time · 3 days            Thu 8 AM  │ rows, 44
│ Later today                       1 PM  │
│ Tomorrow morning              Tue 8 AM  │
│ This weekend                  Sat 9 AM  │
│ Next week                     Mon 8 AM  │
│ Pick a date and time…                ›  │
├─────────────────────────────────────────┤
│        ⟦ If no reply | Always ⟧         │ only when the newest message is his
└─────────────────────────────────────────┘
```

- **Every row states its time** at the trailing edge, tabular, secondary, through `DateText`
  and `TimeRangeText`. Nobody has to work out what "this weekend" means.
- **The first row is highlighted when the picker opens**, so `H` `↵` snoozes to the last
  time used (or, the first time, to "Later today"). Typing highlights the read-back row.

#### 6.5.1 Rows (`MailTimePresets`, pure)

| Row | Time | Shown |
|---|---|---|
| *What was typed* | As read | Only while something is typed. First, and chosen by `↵`. |
| Last time · *the phrase* | The last phrase or preset used for this job, worked out again from now | When there is one |
| Later today | Three hours from now, rounded up to the half hour | When that is before 9 PM |
| Tomorrow morning | Tomorrow, 8 AM | Always |
| This weekend | Saturday, 9 AM ("Next weekend" on a Saturday or Sunday) | Always |
| Next week | Monday, 8 AM | Always |
| After *event* | The end of the meeting in progress, or of the next one starting within two hours | When it ends today. *After the first release*, with 9. |
| Today, no time | — | Add to plan only; first |
| Pick a date and time… | | Always; last but one |
| Unsnooze · Unschedule | | When the conversation is snoozed or the message scheduled; last |

Five presets and no more. "Morning" is 8 AM; there is no setting for it.

#### 6.5.2 Typed times

There is no new parser. `MailTimePhrase.parse` calls the app's existing reader of typed event
times, `EventPhrase.takeDate` — which already holds the system's date detector and the two
rules a new parser would rediscover (an hour with no am or pm between 1 and 6 is the
afternoon; a time already past today is tomorrow) — and adds, in about eighty lines, what a
snooze needs and an event does not:

| Typed | Read as | By |
|---|---|---|
| A clock time: "8am", "17:30" | The next time the clock shows it | `takeDate` |
| A day and a time: "fri 3pm", "tomorrow 8am" | That | `takeDate` |
| A bare day: "fri", "tomorrow", "aug 7" | That day at 8 AM (the detector says noon) | `takeDate`, then the rule |
| A span: "3 days", "2 weeks" | That many days from today, at 8 AM | One pattern |
| A short span: "2h", "45 min" | From now, rounded to five minutes | The same pattern |
| "noon" · "next week" · "weekend" | 12 PM · Monday 8 AM · Saturday 9 AM | Three fixed words |
| A weekday and a number: "monday 9" | Monday, 9 AM (the detector reads the ninth of a month) | A guard |

A time in the past shows "That's in the past." and cannot be chosen. Words that are not a
time show nothing. `MailTimePhrase` is in the pure folder and tested there
(`EventPhrase.swift` is already compiled into the tests); mail's own folders still contain no
date detector.

#### 6.5.3 The control in the footer

`Tab` (⇥) switches it.

| Job | Control | Rule |
|---|---|---|
| Snooze | **If no reply · Always** | Shown only when the newest message is his — `newestIsMine` of `conversation(id)`, read as the picker opens — and then "If no reply" is selected. Otherwise absent: there is nothing to wait for a reply to. Never offered with several targets. |
| Add to plan *(later)* | **Task · Block** | 9.2 |
| Send later | A line of text instead, saying who will send it (6.5.5) | |

#### 6.5.4 Choosing

`↵` or a tap applies the row and closes the picker in the same frame. Snooze is then T16.
`Esc`, or dismissing the sheet, changes nothing.

A snoozed conversation comes back unread, at the top of the place it left, with the reason
line "Back from snooze" (6.1.1). Its notification is 7.10.

#### 6.5.5 Scheduled messages and sleeping devices

In the first release, by the owner's ruling, and the truth about it is fixed here. Gmail's own scheduled send
is not available to an app. A scheduled message waits in Gmail as a draft and is sent by
**the device it was scheduled on** (O12). Closing the laptop after scheduling is the ordinary
thing to do, and it makes the message late; so lateness is designed, not an error path.

| Where | Words |
|---|---|
| The picker's footer, on a Mac | "Sends from this Mac. If it's asleep then, the message is late." |
| The picker's footer, on an iPhone or iPad | "Sends from this iPhone: on time if Banana is open then, otherwise when iOS next lets it run." |
| The card, on the owning device, before the time | "Scheduled · Thu 8 AM · from this Mac" |
| The card on any other device, before the time | "Scheduled · Thu 8 AM · from another device" |
| **Every device, once the time has passed by five minutes** | Warning: "Was due 8 AM · not sent yet", with **Send now from this iPhone** |

- **Late is said everywhere.** Every device that knows of the schedule shows the late state
  on the row and the card, counts it in Mail's badge, and posts a notification five minutes
  after the time — "“Q3 numbers” hasn't gone yet" · "It was due at 8 AM. Send it now, or open
  Banana to change it." · **Send now** — withdrawn if the message goes first.
- **Send now from this device** takes the message over (the engine checks that it has not
  already gone) and sends it now, through the ordinary undo hold.
- **One late rule, no setting.** When the owning device next runs: up to 30 minutes late the
  message goes and says so ("Sending “Q3 numbers” · was due 8 AM · Undo", when Mail is in
  front); later than that it asks (7.7).
- Changing or unscheduling it from another device asks which is meant: send from here
  instead, or cancel the schedule. It never silently becomes an ordinary draft.
- He is shown three pictures of this — the picker's footer, the lock screen at 8:05, the
  late card — before it is built (MAIL-PLAN section 8).

### 6.6 The control column: places, labels, moving

**The control column** is every place Mail has, with its count: the splits first, then the
mailboxes, the labels and the accounts. Where it has room it is a column (6.0). Where it has
not, or it is switched off, the same view is **Places**, on ≡.

```
┌──────────────────────────────────────┐
│ ⌕ Filter                             │ regular only; `G L` puts the caret here
├──────────────────────────────────────┤
│ SPLITS                               │
│   Important                       12 │
│   Calendar                         2 │
│   VIP                              3 │
│   Other                          40+ │
│ MAILBOXES                            │
│   ▣ Inbox                            │
│   ☆ Starred                          │
│   ◆ Important                        │
│   ✎ Drafts                         2 │
│   ⏱ Snoozed                        4 │
│   ➤ Sent                             │
│   ⇡ Outbox                       1 ● │
│   ✓ Done                             │
│   ▤ All mail                         │
│   ⚠ Spam                             │
│   🗑 Trash                           │
│ LABELS                               │
│   ● Invoices                         │
│   ● Dewey  ›  Hiring                 │
│ ACCOUNTS                             │
│   ◉ All accounts                     │
│   ○ noor@plan.example            ● Live    │
│   ○ bberenberg@gmail.com   ● Downloading │
│   ○ noor@work.example  Calendar only · Turn on Mail │
└──────────────────────────────────────┘
```

- **As a column:** `DS.Mail.controlColumn` wide and the height of Mail, with the sidebar
  button (◧, ⌥⌘S) and a filter field at its head (`G` `L` puts the caret there). The place
  showing is marked as the cursor row is: `DS.Palette.selection` with the accent spine.
  Counts are trailing, tabular, secondary. Labels, and Mailboxes below Done, fold; what is
  folded is remembered. Choosing a place shows it and changes nothing else. The column
  observes the places only: it does not re-evaluate when the cursor moves or the list
  changes.
- **As Places:** at compact width a sheet (medium and large detents) from the ≡ chip in the
  bottom slot; otherwise a popover 320 pt wide from the ≡ button in the list's header.
  Choosing a place closes it.
- The order of mailboxes is Gmail's own drawer, so nothing is relearned. Inbox is every
  split together; Important is Gmail's own mark, not the split of that name. Outbox is there
  because sends wait on the device; its dot means something in it needs him. Snoozed appears
  with snooze and Muted with mute. The list behind a held removal is not in Places: it opens
  from its card (7.5).
- Labels are nested as Gmail nests them, each with a dot in its own colour (through
  `calendarTint`), grouped by account when accounts have different labels. Labels Banana
  makes for its own bookkeeping are never listed.
- Choosing a place closes Places and shows it. Choosing an account narrows the current list.
- An account's line is `StatusDot` and a word (7.5). An account without Mail offers
  "Turn on Mail".

**The label picker** (`L`) and **the move picker** (`V`) are the command menu's chrome on
regular and a medium sheet on compact: a field ("Label as…", "Move to…"), then labels with
their dots, nested names written out ("Dewey / Hiring"). A tick marks a label every target
has; a dash, one that some have. `↵` toggles the highlighted label and closes; `⌘↵` toggles
and stays. One use of the picker is one change and one Undo, however many labels it toggled.
Targets in more than one account: the picker lists nothing and says "These conversations are
in different accounts. Label one account's at a time." (A label's id is one account's, so the
change names it: `MailChange.label(account:add:remove:)`, `.move(account:to:from:)`.) Creating a label from the picker
("Create “*typed*”" as the last row) is after the first release.

### 6.7 More, on touch

```
┌─────────────────────────────────────────┐
│ ━━                                      │
│ ⟦ ⌕  Type a command                  ⟧  │ not focused until tapped
├─────────────────────────────────────────┤
│ ↩  Undo: Marked “Q3 numbers” Done       │ while the undo stack has an entry (T44)
│ CONVERSATION                            │ eyebrow
│ ★  Star                                 │ rows, 44: symbol · title
│ ✉  Mark unread                          │
│ 🏷  Label…                               │
│ ➜  Move…                                │
│ 🗑  Trash                                │
│ ⚠  Spam                                 │
│ ⌕  Find in conversation                 │
│ REPLY                                   │
│ ↩  Reply to sender                      │
│ ➦  Forward                              │
│ ⌄  Next conversation                    │
│ ☑  Select                               │
│ GO TO …                                 │
└─────────────────────────────────────────┘
```

`MailCommandSheet`: the command registry (4.5) as a sheet at the medium detent, growing to
large. Rows are 44 pt: symbol, title. A "Type a command" field sits at the top and is not
focused until tapped, so the keyboard does not jump up; typing filters as ⌘K does. What a
long press reaches elsewhere is listed here in words — Reply to sender, Forward, Select, Send
and Done — so nothing depends on knowing a gesture. Groups and predicates are the registry's;
there is no second list of commands for touch.

### 6.8 Settings

#### 6.8.1 Settings › Mail

A `SettingsPage.mail` ("Mail", `envelope.fill`, `DS.Palette.Feature.mail`), listed with the
features on the phone's root and in the Mac's list, with the trailing value "2 accounts" or
"Off". One page, two levels at most.

| Group | Row | Value | Kept |
|---|---|---|---|
| Accounts | One row per Google account | Dot and word; opens Accounts & calendars | — |
| Reading | Remote pictures | Ask first · Always, from everyone | Synced (the engine's setting) |
| | Always show pictures from | The senders and the domains he has allowed from a message, each removable; "None" when there are none | Synced |
| | Block tracking pixels | On | Synced |
| Sending | Undo send | 5 · 10 · 20 · 30 seconds | Synced (the engine's setting) |
| | New messages are from | The default account; only when there is a choice | Synced |
| Notifications | New mail | The first split · Everything in the inbox · Off | Synced |
| | Show a line of the message | Off | Synced |
| This iPhone | Keep mail from | The last month · 3 months · **6 months** · a year · Everything (`MailSyncLimit`) | This device only |
| | Storage | "3.2 GB" → what it is made of | — |
| | Remove downloaded mail… | In `danger`, last, with a caption | — |
| Keyboard | Shortcuts | Opens the `?` sheet | — |

Splits (a row under an Inbox group) arrive with split editing. There is no switch for unread mail on the app icon and none for late
messages: each has one answer (2.4, 6.5.5).

Footnotes, under the rows that need them. These are the words that ship:

- **Remote pictures:** "When pictures load, the sender's server can see your IP address and
  when the message was on your screen." Choosing **Always, from everyone** asks once, with
  the words of 6.2.6, and then reads: "Pictures load in every message. Every sender whose
  mail comes up on your screen can see your IP address and when." Switching back to Ask
  first takes effect at once, and leaves the senders and domains below as they are.
- **Block tracking pixels:** "Banana never fetches the pictures it recognises as trackers,
  whatever you choose above. It can't recognise them all: a picture made for you alone looks
  like any other." Off: "Tracking pixels load with a message's other pictures."
- **Sending:** "Signatures come from Gmail's settings. A draft is saved to Gmail when you
  close it, leave Banana or send — so it reaches your other devices then, not as you type."
- **New mail:** "Banana checks for mail while it's open and, in the background, when iOS
  allows. On an iPhone that isn't open, a notification is often tens of minutes late." A
  notification shows the sender and the subject; the line of the message only if the switch
  is on. Turning notifications on asks for permission with the priming template, if it has
  not been given.
- **Keep mail from** — the sync limit, six months unless he changes it, and each device has
  its own: "Mail from the last 6 months is kept on this iPhone, so it opens and searches
  without a connection. Older mail stays in Gmail: search asks Gmail for it, and a
  conversation is fetched when you open it. Starred mail, drafts, snoozed mail and anything
  waiting to send are kept whatever their age." With Everything: "All your mail is kept on
  this iPhone."
  - **Keeping less** asks once, with the number the engine gives (`conversationsBeyond`),
    because getting them back takes hours: "About 8,200 conversations will be removed from
    this iPhone. They stay in Gmail." · Remove · Cancel. While they go, the row says how
    many are left.
  - **Keeping more** asks nothing: the older mail starts downloading and the list's foot
    says so (7.1).
  - The engine's size ceilings stay behind this as a backstop (its 11.3). Where one bites on
    a phone, the footnote gains its sentence: "Full messages are kept for the newest 4 GB;
    an older one is fetched when you open it."
- **Storage, on a Mac only — the plain sentence:** "Mail on this Mac is stored in your
  Library folder. Any app you run can read it there; FileVault protects it when the Mac is
  off, not from software." (Whether to encrypt it instead is a decision for the author, MAIL-PLAN
  section 8; until he decides otherwise this sentence is shown.)
- **Remove downloaded mail:** "Removes this iPhone's copy. Nothing changes in Gmail, and
  changes you have made that haven't reached Gmail are kept. Downloading it again takes
  days." This one confirms with a dialog: it cannot be undone in less than days.

The engine owns the synced fields it reads — `mailAccounts`, `mailUndoSendSeconds`,
`mailPictures` and the two notification choices (`MailSettings.notifyFor` and the line of
the message) — added by its package P24; U14 adds only the one that is the screens' own, the
default account, as an optional field of `AppSettings.Snapshot`, after P24. Device values use dot-free keys. The page's sections are
separate properties and the page is type-erased like the others.

#### 6.8.2 The account card

Settings › Accounts & calendars. The section's header changes from "Google Calendar" to
"Google accounts". Each card gains a line per service and a Mail switch:

```
 (B)  noor@plan.example                                    ⋯
      ● Calendar · 3 calendars
      ● Mail · Live                           ( on )
```

- The Mail line is `StatusDot`, "Mail ·", and the account's state in a word (7.5).
- **Turning it on** is 6.9's flow for one account.
- **Turning it off** hides that account's mail at once and stops fetching it. Toast: "Mail
  off for noor@plan.example · Undo". Under the switch, once: "Turning Mail off doesn't withdraw
  Banana's permission at Google. To do that, remove Banana in your Google account." with
  **Manage at Google ↗**.
- The ⋯ menu keeps Reconnect and Disconnect, and gains **Forget Mail's permission on this
  iPhone**, the way out when a grant has gone wrong. Disconnect's own words are the
  calendar's to fix (MAIL-PLAN section 6); nothing Mail adds here says or implies that
  anything is revoked at Google.
- The section's footer becomes: "Banana talks to Google directly from your devices. Your
  mail is kept on each device; it doesn't pass through a server of Banana's, because there
  isn't one."
- The Settings root's account row reads "Live · 3 calendars · Mail on 2".
- Settings › Permissions gains a "Gmail" row: Allowed when every account with the Mail
  switch on is allowed on this device; otherwise "1 account needs permission" with Connect.

### 6.9 Turning Mail on

The first visit to Mail when no account has Mail on shows the permission priming template
(`DESIGN-SYSTEM.md`, "Permissions"), centred, at most 480 pt wide:

```
                    ✉                         56-pt symbol, Feature.mail
           Mail, next to your day             .title2
   Your Gmail in Banana: on this iPhone,      one body line
   offline, one key or one swipe at a time.

   ⚡  Reads from this iPhone. Works on a plane.
   ↩  Every action can be undone.
   ⚠  Google will warn that Banana isn't verified,
      then ask you to tick Gmail.

   ☑  noor@plan.example                             the default account is ticked;
   ☐  bberenberg@gmail.com                    the others are his to tick
   ☐  noor@work.example

   Banana talks to Gmail directly. Your mail is
   stored on your devices and nowhere else.    privacy footnote

            ⟦   Turn on Mail   ⟧              pinned to the bottom
                  Not now
```

- **Mail is opt-in per account.** Only the default account is ticked. Every further account
  is another of Google's warnings and another box to tick, so he chooses how many.
- **Turn on Mail** records the choice for each ticked account, then, for each one this
  device is not yet allowed to read, opens Google's consent with the address filled in. An
  account that grants Mail starts downloading at once. Otherwise the account's line says
  what happened, with **Try again**:

| Result | Line |
|---|---|
| Not granted | "Google didn't grant Mail. Tick the Gmail box when it asks." |
| Cancelled | "Not turned on." |
| A different account was chosen | "That was a different account. Mail wasn't turned on for this one." |
| No window to ask in (the Mac's menu-bar state) | "Open Banana's window and try again." |
| Failed | "Couldn't reach Google. Try again." |

- As soon as one account has Mail, this screen is replaced by the inbox, which fills as mail
  arrives (7.1). The others carry on behind it.
- **Not now** is *deferred*, not denied. Mail then shows its one-line empty state — "Mail is
  off." · "Turn it on for any of your Google accounts." · **Turn on Mail** — and nothing
  anywhere else in Banana mentions it.
- **An account that has only granted Calendar** is exactly this case for one account: Places
  lists it as "Calendar only · Turn on Mail", and the card in Settings has its switch off.
  Nothing nags.
- **A second device.** That Mail is on for an account is synced. Two things are per device,
  and the screens read correctly whichever way the credential is kept (a decision for the author,
  MAIL-PLAN section 8):
  - *Google's permission.* If this device is not yet allowed to read the account, its line
    reads "Allow Mail on this iPhone" with **Continue**, which opens Google's consent. With a
    credential kept on each device that is once per account per device, and again after a
    Google password change; with one shared through iCloud Keychain the line is seen only on
    the first device. The words are the same either way.
  - *The download.* Turning Mail on from the Mac does not make a phone in a pocket fetch
    gigabytes. A device starts the first time Mail is opened on it; until then its account
    card reads "Mail · On · starts when you open Mail here".
- **What a first download is, said once**, under the accounts on an iPhone or iPad: "Your
  newest mail is here in seconds. The rest downloads while Banana is open and overnight
  while charging; a large mailbox takes days."
- Two hints after the first mail arrives (the Mac: `KeyHintRow` "E Done · ⌘K Everything
  else"; touch: "Swipe left for Done."), each once, and the offer to mark everything older
  than a week Done, are after the first release.
- No tour, no sample inbox, no congratulation.

### 6.10 The details column

About the conversation showing (T47): who is in it and what is in it, without scrolling the
conversation. It is drawn in 6.0.5, at the trailing edge.

| Group | In the first release | From |
|---|---|---|
| **People** | Everyone in the conversation, the newest message's sender first: `Monogram`, name, and the address — always shown here — and one line of what Banana already knows: "You've written to them", or "First mail from this address"; "from their mail" where the name is only theirs (6.3.3). A click starts a search for mail with that person. | The conversation |
| **About** | How many messages; when it started and its latest (`DateText.full`); which account; where it is — "In Important", "Done", "Snoozed until Thu 8 AM", "Scheduled for Thu 8 AM"; its labels as chips, each removable. | The conversation |
| **Attachments** | Every attachment in the conversation, newest first: its type's symbol, name, size, and state (6.2.9). A click opens it in Quick Look, or downloads it. | The conversation's messages |
| **Recent with** *the sender* | The last three conversations with the newest message's sender, two lines each; a click goes to one; "All 41 ›" runs the search. Arrives with search (package U11). | `observeList` on a search for that address, three rows |

- With a selection it reads "3 selected" and nothing else. With nothing showing it is empty.
- **What "enrichment" means in the first version: facts already on this device, about these
  people and this conversation.** Nothing is fetched to fill the column, nothing is looked up
  about a person anywhere else, and no model writes in it.
- **Later, each as one more card in the column**, in this order: the invitation and its day,
  above People (9.1, 9.3); the trip a booking belongs to; the person's card from Contacts; a
  summary by a model (9.5). The column is an ordered list of cards, so adding one changes
  none of the others. Those are the seams; none is built now.
- **Where it has no room** it is a panel over the pane's trailing edge, and at one column a
  sheet from the conversation's ⓘ (6.0.2). The same view in all three.
- **Must:** it reads the conversation through the model the pane already has, and makes no
  read of its own except "Recent with". It changes when the conversation showing changes —
  which, with a held key, is only where the cursor stops (T48) — and not when the cursor
  moves. Typing in a composer does not re-evaluate it.

---

## 7. Every state, and what it says

Copy rules: plain and specific; no exclamation marks; the word carries the meaning and the
dot only supports it; a time is always `TimeRangeText.time` and a date `DateText`; the device
is `DeviceRole.current.name` ("this iPhone", "this Mac"); parts are joined with " · ".
Strings ship with typographic apostrophes and quotation marks. Examples use a 12-hour locale.
MAIL-ENGINE section 14 says what is true in each state and what the engine reports; the
words that ship are the ones here. Every state has a way out or says that there is none.

No spinner appears for anything that is on the device. A wait is shown in two places only —
a first sync's first seconds and a message body that has never been downloaded — and both are
things that have never been here. **No state is drawn as an empty list**: a list is empty only
when the place is (the contract's promise 8).

### 7.1 First sync: usable in seconds, complete in days

The newest mail is here in seconds. What the device is to keep — six months of mail, unless
he has chosen otherwise (6.8.1) — takes about an hour and a half on a Mac that stays on, and
one night on a charger or a few days of ordinary use on a phone. Everything, if he chooses
it, is hours on a Mac and a week or more on a phone: Google limits the pace, and an iPhone downloads only while Banana is open or
overnight on a charger. The inbox must not wait for any of that.

| Moment | The list | Says |
|---|---|---|
| Nothing has arrived yet (the first seconds) | Skeleton rows (6.1.1) | Status line, working dot: "Getting your newest mail…" |
| The newest mail is here; older mail is arriving | Real rows, fully usable: read, triage, reply, search | The **foot card** below. Nothing at the top. |
| Everything is here | — | The card is gone. Nothing announces it. |

The foot card, after the last row of any list that would be longer if everything were here:

```
┌──────────────────────────────────────────────────────────┐
│ ● Downloading older mail                                 │
│   Everything since 12 Aug is here · about 73,600 older messages to go │
│   It downloads while Banana is open, and overnight while charging.    │
└──────────────────────────────────────────────────────────┘
```

- `dsCard()`; working dot; title `.subheadline`; the two lines `.footnote`, secondary. It
  redraws at most every ten seconds, from its own observer.
- **The third line tells the truth for the device.** On an iPhone or iPad: "It downloads
  while Banana is open, and overnight while charging." — never an estimate in clock time. On
  a Mac: "Google limits how fast mail can be fetched. About 2 days to go." when the engine
  can estimate, and the first sentence alone when it cannot.
- **When it is paused, it says why** (`MailDownload.heldBy`), in place of the third line:

| Held by | Line |
|---|---|
| On battery | "Paused while on battery." |
| The device is warm | "Paused while this iPhone is warm." |
| Low Power Mode | "Paused in Low Power Mode." |
| Nearly full | "Paused: this iPhone is nearly full." |
| Waiting for Wi-Fi | "Carries on when you're on Wi-Fi." |
| Google's daily allowance spent | "Carries on tomorrow: today's download allowance from Google is used. New mail isn't affected." |
| Google asked for a pause | "Paused for a moment: Google asked Banana to slow down." |
| Mail is not on screen | "Carries on when Mail is open." |

- Offline: "Older mail downloads when you're online. Everything since 12 Aug is here."
- Several accounts downloading: one second line each, led by the address.
- It is at the foot because that is where the list is incomplete: the list ends here
  *because* older mail has not arrived. It is never a banner, a sheet, a percentage on the
  tab, or a notification.

Meanwhile: counts that may be short end in "+" (7.4); search says how much it covered (7.3);
Places shows the account as "Downloading"; a conversation whose body has not arrived shows
its header and snippet (6.2.5).

### 7.2 How fresh the list is

There is no push from Gmail to a device. Banana checks once a minute while Mail is on screen,
when it comes forward, when asked, and in the background when the system lets it. So the list
says when it is not live, in the status line (6.1.4), and says nothing when it is.

`MailStatusText.line(_ status:, accounts:, now:)` is pure, over the contract's
`MailStatusValue` and its accounts (row 9 reads an account's `health`). The first row that
applies:

| # | Condition | Dot | Text |
|---|---|---|---|
| 1 | The device is full (`store` cannot save) | attention | "This iPhone is full · changes can't be saved" |
| 2 | No network; messages and changes waiting | off | "Offline · 1 message and 3 changes waiting" |
| 3 | No network; changes waiting | off | "Offline · 3 changes waiting" |
| 4 | No network; messages waiting | off | "Offline · 1 message waiting to send" |
| 5 | No network; nothing waiting | off | "Offline · mail as of 9:12 AM" |
| 6 | Online, but Gmail has not answered for a minute | attention | "Can't reach Gmail since 9:12 AM" |
| 7 | Google has told Banana to slow down, for a minute or more | working | "Google asked Banana to slow down · 3 changes waiting" — or "· catching up" when none are |
| 8 | The store is being rebuilt | working | "Rebuilding the mail index · your mail and unsent changes are safe" |
| 9 | An account is being compared with Gmail | working | "Checking noor@plan.example against Gmail · nothing is removed meanwhile" |
| 10 | A check he asked for is running | working | "Checking…" |
| 11 | That check just finished (three seconds) | ok | "Checked just now · 3 new" — or "· nothing new" |
| 12 | A message that had waited more than a minute has just gone (five seconds) | ok | "Sent “Q3 numbers” · 2:14 PM" — after a relaunch (`MailEvent.sentLate`): "Sent “Q3 numbers” · it had been waiting since 2:02 PM" |
| 13 | Online, changes still waiting after five seconds | working | "Sending 3 changes to Gmail" |
| 14 | The last check was more than two minutes ago | off | "Checked 14 min ago" |
| 15 | Otherwise | — | *no line* |

- "as of" another day reads "mail as of Mon 9:12 AM".
- Row 14 is what is seen coming back to the app: the list is there at once, as it was, and
  the line says how old it is. It does not say "checking": the status value reports only a
  check he asked for. The check that coming forward starts replaces the line within seconds.
- Row 12 is the one row not read from those values. `MailSession` holds it for five seconds
  when `MailEvent.sent` arrives for a draft it had seen waiting for the network for over a
  minute, and the status line shows it when the function's own answer is row 13 or lower.
- Pull to refresh, ⌘R and "Check mail now" all mean rows 10 and 11.
- Brief failures and brief slow-downs are retried in silence. Rows 6 and 7 need a minute.
- The relative time changes once a minute, from a `TimelineView` inside the status line.

### 7.3 Search's scope line

From what the device keeps (6.8.1) and the snapshot's `coverage` and `remote`. "6 months" is
whatever the limit is; the device is named.

| Situation | Text |
|---|---|
| The device keeps everything, and has it; Gmail not asked | "All mail · 38" |
| The same, offline | "All mail on this iPhone · 38" |
| A limit; Gmail has not answered yet | "6 months on this Mac · asking Gmail for older…" |
| A limit; Gmail answered | "6 months on this Mac · 14 older from Gmail" — or "· nothing older in Gmail" |
| A limit; offline | "6 months on this Mac · older mail needs a connection" |
| A limit; Gmail did not answer | "6 months on this Mac · Gmail didn't answer" — the foot's **Try again** asks again (`askGmail(_:)`) |
| Still downloading what it is to keep; Gmail has not answered yet | "23,117 of 100,412 searched here · asking Gmail…" |
| Still downloading; Gmail answered | "23,117 of 100,412 searched here · 14 more from Gmail" |
| Still downloading; offline | "23,117 of 100,412 searched here · offline" |

### 7.4 Counts

A count the engine cannot yet vouch for (`MailCount.isAtLeast`) is drawn with a trailing "+":
"40+". VoiceOver reads "at least 40". Thousands are grouped ("1,204"). A count of zero is not
drawn. With a sync limit a count is of what the device holds, and it ends in "+" while
Gmail's own count for that place is larger: "12+" for a split whose older mail is in Gmail.

### 7.5 An account's state, and the questions only he can answer

A dot and a word — on the account card after "Mail ·", in Places, and on the Settings root —
from the account's `state` and, when it is connected, its `health`.

| State | Dot | Word | Way out |
|---|---|---|---|
| Connected, live | ok | "Live" | |
| Connected, first sync or catching up | working | "Downloading" · "Catching up" | |
| Connected, offline | off | "Offline · as of 9:12 AM" | |
| Connected, paused by Google | working | "Paused by Google until 2:07 PM" (after a minute) | |
| Connected, the day's allowance spent | working | "Older mail carries on tomorrow" | |
| Connected, being compared with Gmail | working | "Checking against Gmail" | |
| Mail not turned on | off | "Off" on the card; "Calendar only" in Places | **Turn on Mail** |
| Turned on; Mail not yet opened on this device | off | "On · starts when you open Mail here" | Open Mail |
| Turned on; this device is not allowed yet | attention | "Allow Mail on this iPhone" | **Continue** |
| Google stopped allowing Mail | attention | "Google stopped allowing Mail" | **Allow again** |
| The organisation forbids it | attention | "Not allowed by plan.example" — on the card, in full: "This organisation doesn't allow Banana to read mail." | **Turn Mail off for this account** |
| Google answered for a different address | attention | "Wrong account" — in full: "Google answered for a different address, so Banana has stopped this account's mail." | **Allow again** |
| Gmail is not enabled for Banana's Google project | attention | "Setup problem" — in full: "The Gmail API isn't enabled for Banana's Google project." For the author the developer. | **Turn Mail off for this account** |

Mail and the calendar each say this about themselves: an account the calendar shows as "Sign
in again" can have working mail, and the reverse.

Some things raise an **alert card** above the first row of the list. One at a time, as on
Today; the rest wait. A card about an account has an × that hides it until the next launch
(its dot keeps saying it); a question stays until it is answered.

| | Title | Body | Buttons |
|---|---|---|---|
| Google stopped allowing Mail | "Banana can't read noor@plan.example's mail any more" | "Google stopped allowing it — after a password change, or because Banana's access was removed. What's on this iPhone stays, and 3 changes are waiting." | Allow again |
| Many removals at once (a question; the engine holds them) | "Gmail says 4,210 messages in noor@plan.example were deleted" | "That is a lot at once, so nothing has been removed from this Mac. If you deleted them, remove them here too. If you didn't, keep them: they stay on this Mac, marked as deleted in Gmail. Removing them here can't be undone." | Remove here · Keep on this Mac · **Show them**, which opens the list of them (`MailPlace.heldRemoval(account:)`), an ordinary list |
| Changes lost (a question) | "Some changes that hadn't reached Gmail couldn't be read" | "4 were recovered and will be sent. The rest are lost. Look over the last things you did in Mail." | OK |
| A draft changed elsewhere (a question) | "“Q3 numbers” was changed on another device" | "Keep what you wrote here, or use the other version." | Keep mine · Use the other |

`dsCard()`, attention dot, title `.subheadline` semibold, body `.footnote` secondary, bordered
buttons, the first in the accent. An account in trouble is never removed from the list, and
its mail is never hidden: a failed read is not evidence of emptiness.

**When Mail cannot open its store**, the list's area says so instead of showing an empty
list:

| Store | Line | Hint | Action |
|---|---|---|---|
| Not opened yet (a moment at first use) | Skeleton rows | | |
| Written by a newer Banana | "Update Banana to use Mail on this iPhone." | "This iPhone's mail was last used by a newer version. Nothing has been reset." | — (there is none here) |
| Damaged or unavailable | "Mail can't open its files on this iPhone." | "Your mail in Gmail is not affected, and changes that hadn't reached Gmail are kept." | Remove downloaded mail and start again |

### 7.6 A message that is waiting, or failed

| State | On the message's card | The row's reason line | Elsewhere |
|---|---|---|---|
| In the undo hold (`held(until:)`) | "Sending… · **Undo**" | "Sending…", with Undo in a one-line row | Toast "Sending · Undo"; 6.3.7 |
| Waiting for the network | "Waiting to send · goes the next time Banana is open and online" on an iPhone or iPad; "…goes when this Mac is online" on a Mac. Buttons: **Edit** · **Don't send** | "Waiting to send" | Counted in the status line; listed in Outbox. When it goes after more than a minute's wait, the status line says so once (7.2 row 12), or a notification if Banana is not in front. |
| Being checked | "Checking whether this was sent" | The same | |
| **Not sure it was sent** (a question) | Warning dot: "Banana can't confirm this was sent. It isn't in Sent, and its draft is still in Gmail." — or "…and its draft is no longer in Gmail.", or the first sentence alone, as the question's `draftStillInGmail` says. Buttons: **Check again** · **Send again** · **Keep as a draft**. Under them: "Send again may deliver it twice." | "Not sure this was sent" | An alert card; counted in the badges |
| **Waited more than a day** (a question, `sendLate`): he pressed Send, and it had still not gone a day later | Warning dot: "Not sent yet. It has been waiting since Mon 2:02 PM." Buttons: **Send now** · **Keep as a draft** | "Not sent yet · waiting since Mon 2:02 PM" | An alert card; counted in the badges. Under a day, it goes without asking and says so (7.2 row 12). |
| **Failed** | In danger: "Couldn't send: " and the reason. Buttons: **Try again** · **Edit** | "Couldn't send · " and the short reason | Toast "Couldn't send “Q3 numbers”: " and the reason, with Retry, if Mail is on screen; a notification if it is not. Counted in the badges. |

Reasons, from the contract's `MailFailure` to words. Google's own words are never shown.

| Failure | After the colon | Short |
|---|---|---|
| Too large | "it's over Gmail's size limit." | "over the size limit" |
| An address was rejected | "Gmail rejected one of the addresses." | "bad address" |
| Signed out · access missing | "this account has to be allowed again." (the button is Allow again) | "allow again" |
| Not allowed by the organisation | "the organisation doesn't allow it." | "not allowed" |
| The label is gone | "that label no longer exists." | "label gone" |
| A limit was reached | "Gmail's limit for today was reached. Try again tomorrow." — in a toast the first sentence alone, and no Retry (7.9) | "limit reached" |
| Anything else | "Gmail refused it." | "refused" |

- **Don't send** makes a waiting message a draft again ("Kept as a draft · Undo").
- **Changes that didn't go through** (T36) are listed in Outbox under that heading from
  `status.value.refused`, one row per action — "Move to Invoices · 3 conversations · that
  label no longer exists" — with **Retry** and **Discard**, each called with that row's
  receipt. They are not conversations of the place and are not counted in its number. Changes for an account that is no longer connected are listed
  under "From an account no longer connected", each with Discard.
- A network error or a busy server is not a failure: the message stays "Waiting to send" and
  is retried without anything being said.
- A message he pressed Send on is never left unsent without telling him: one that has not
  gone ten minutes after he left the app raises "A message is still waiting to send", with
  **Send now**.

### 7.7 A scheduled message that is late

It is late because the device it was scheduled on was asleep or not running Banana (6.5.5).

| How late, when the owner next runs | What happens | On the card |
|---|---|---|
| Up to 30 minutes | It goes, through the undo hold, and says so. | "Sent 8:20 AM · was due 8 AM" (secondary). Toast when Mail is in front: "Sending “Q3 numbers” · was due 8 AM · Undo". |
| More | It is not sent; it asks. | Warning dot: "Not sent yet. It was due at 8 AM and this Mac wasn't running Banana." Buttons: **Send now** · **Keep as a draft**. An alert card; counted in the badges. |
| Changed elsewhere since it was scheduled | The owner does not send what it no longer recognises. | Warning dot: "Not sent. This draft was changed on another device after it was scheduled." Buttons: **Send from here instead** · **Cancel the schedule** |

Every other device shows "Was due 8 AM · not sent yet" from five minutes after the time, and
notifies (6.5.5).

### 7.8 An empty place

One line, one hint, one action (`DESIGN-SYSTEM.md`). Centred in the list's area; `.title3`
line, `.subheadline` secondary hint, one bordered button. No picture and no congratulation.

| Place | Line | Hint | Action |
|---|---|---|---|
| A split, others have mail | "Important is clear." | "Other has 12." | Go to Other |
| Every split | "Inbox clear." | "Next: Standup, 9 AM." — or "Nothing else on today's plan." | Open Plan |
| Drafts | "No drafts." | "A message you close without sending is kept here." | New message |
| Snoozed | "Nothing snoozed." | "Snooze brings a conversation back when you can deal with it." | — |
| Outbox | "Nothing waiting to send." | "Held and failed messages, and changes that didn't go through, are listed here." | — |
| Starred, Sent, Done, All mail, Spam, Trash, a label | "Nothing in Starred." | — | — |
| Search, nothing found, everything searchable | "No mail matches “q3 from:sam”." | — | Clear search |
| Search, nothing found, still downloading, online | The same | "Not all mail is on this iPhone yet, and Gmail found nothing either." | Clear search |
| Search, nothing found, still downloading, offline | The same | "Not all mail is on this iPhone yet, and you're offline." | Clear search |
| Search, nothing found, a limit, Gmail has answered | The same | "Nothing in the 6 months on this Mac, and nothing older in Gmail." | Clear search |
| Search, nothing found, a limit, offline | The same | "Nothing in the 6 months on this Mac. Older mail can be searched when you're online." | Clear search |
| A filter, nothing matches | "Nothing unread in Important." | — | Clear filter |
| Mail is off | "Mail is off." | "Turn it on for any of your Google accounts." | Turn on Mail |

An empty state gives way to the "1 new" chip while mail is waiting for the list to be at rest
(T9): the line, its hint and its button are not drawn over mail that is there.

The reward for an empty inbox is the rest of the day, which Banana happens to know.

### 7.9 Toasts

One line, at most one action, through `ToastCenter.present`. The toast shows the latest
change; the undo stack remembers the rest (T27). The words are made in one place
(`MailToastText`, pure), so a test holds every line of this section.

- **About one conversation, it names it**, so a slip is seen at once: the subject as the row
  shows it — one cleaner for both (6.1.1) — in curly quotes, **cut to 30 characters and "…"**.
  The outcome is the last word of the line, and on a phone a long subject would otherwise
  push it off the end, where "Done" and "as spam" read the same.
- **About several, it counts them**, with the number grouped as everywhere else (7.4):
  "1,204 marked Done", never "1204".
- **The device's name and a time's words are handed in** by the screen
  (`DeviceRole.current.name`, `TimeRangeText`, `DateText`). The words' own code has no
  default for either: a default says "this iPhone" on a Mac.
- **Every entry on the undo stack has a description**: what "Undo previous: …" and More ›
  Undo call it. It is the toast without the name, and with the count when there are several
  ("3 marked Done").

| After | One conversation | Several | The stack calls it |
|---|---|---|---|
| Done | "Marked “Q3 numbers” Done" | "12 marked Done" | "Marked Done" |
| Done on an open conversation with a reply not yet seen (T45) | "Marked Done · a new reply keeps “Q3 numbers” in the inbox" | — | "Marked Done" |
| Trash | "Moved “Q3 numbers” to Trash" | "12 moved to Trash" | "Moved to Trash" |
| Spam | "Marked “Q3 numbers” as spam" | "12 marked as spam" | "Marked as spam" |
| Move | "Moved “Q3 numbers” to Invoices" | "12 moved to Invoices" | "Moved to Invoices" |
| A label put on | "Labelled “Q3 numbers” Invoices" — several labels: their names with commas | "12 labelled Invoices" | "Labelled Invoices" |
| A label taken off — `Y`, or the picker | "Removed “Q3 numbers” from Invoices" | "12 removed from Invoices" | "Removed from Invoices" |
| Not done · Back to the inbox · Not spam | "“Q3 numbers” is back in the inbox" | "12 are back in the inbox" | "Back in the inbox" |
| Restore, from Trash | "Restored “Q3 numbers”" — where it returns to is Gmail's to say, and may not be the inbox | "12 restored" | "Restored" |
| Snooze | "Snoozed “Q3 numbers” until Thu 8 AM" · if no reply: "…until Thu 8 AM, unless they reply" | "12 snoozed until Thu 8 AM" | "Snoozed" |
| Mute *(later)* | "Muted “Q3 numbers”" | "12 muted" | "Muted" |
| Star · unstar · read · unread | *none — the row shows it* | *none* | "Starred" · "Unstarred" · "Marked read" · "Marked unread" |
| An action that changed nothing (T16) | *none* | *none* | *no entry* |

Each of these carries **Undo**. An action that is another feature's, or not yet built (an
invitation's answer, Add to plan, Unsubscribe), has no line here and no description: it puts
nothing on Mail's stack (T14), and the words' code must not invent one — least of all "Done",
which is this product's word for something else.

| After | Toast | Action |
|---|---|---|
| Send | "Sending" | Undo, for the hold |
| Send and Done | "Sending · marked Done" — the stack calls it "Sent and marked Done" | Undo |
| Send now | "Sent." | — |
| Send, offline | "Will send when Banana is next open and online" | Undo |
| Discard | "Draft discarded" | Undo |
| Undo | "Undone" | Undo previous: *its description* — when there is one |
| Undo, and nothing can be undone (T30) | "That can no longer be undone." | — |
| Undo of a send that has left (T28) | "Already sent." · after Send and Done: "Already sent. “Q3 numbers” is back in the inbox." | — |

**When a change cannot stand** (T36) the line is "Couldn't " and what he was doing, a colon,
and the reason from 7.6's table. About several: "12 conversations" in place of the name.

| He was | "Couldn't …" |
|---|---|
| Marking Done | "mark “Q3 numbers” Done" |
| Trashing · marking as spam | "move “Q3 numbers” to Trash" · "mark “Q3 numbers” as spam" |
| Moving | "move “Q3 numbers”" |
| Putting a label on | "label “Q3 numbers”" |
| Taking a label off (`Y`, or the picker) | "take Invoices off “Q3 numbers”" — never "label", which is the opposite of what he did |
| Not done · Back to the inbox · Not spam | "move “Q3 numbers” back to the inbox" |
| Restoring | "restore “Q3 numbers”" |
| Snoozing · muting | "snooze “Q3 numbers”" · "mute “Q3 numbers”" |
| Marking read or unread · starring or unstarring | "mark “Q3 numbers” read" (or "unread") · "star “Q3 numbers”" (or "unstar") |

- So: "Couldn't move “Q3 numbers”: that label no longer exists." · "Couldn't move 12
  conversations: that label no longer exists." The action is **Retry**.
- **No Retry when Gmail's limit for the day was reached**, and one sentence, not two:
  "Couldn't move “Q3 numbers”: Gmail's limit for today was reached." Trying again today cannot
  help; the change waits in Outbox, where Retry is still offered (7.6).

**When a change could not be saved on the device**, the line is "Couldn't save that: " and
one of four plain reasons, none of them with a button:

| The store | After the colon |
|---|---|
| The device is full | "this iPhone is full." |
| Its data is damaged | "Mail's data on this iPhone is being repaired." |
| It was made by a newer Banana | "this iPhone's mail was made by a newer Banana. Update Banana." |
| It cannot be opened just now | "Mail's data can't be opened right now." |

### 7.10 Notifications

Posted by the engine; the words are specified here. A tap on one is handed to
`MailSession.show(_:)`, which the conversation's package provides.

| Kind | What it shows | Rules |
|---|---|---|
| New mail | The sender's name · the subject. The first line of the message only if he has turned that on. With previews hidden by the system: "3 new messages". Actions: **Done** (asks for the device to be unlocked) · **Mark read**. More than five at once become one: "6 new messages" · the senders' names. | For the first split unless he chose everything. Not time-sensitive. Opening it lands on that conversation. Withdrawn when the mail is read or marked Done elsewhere, when Mail is turned off for the account, and by Remove downloaded mail. Each device notifies for itself. |
| Back from snooze | "Back from snooze" · the subject — for "if no reply": "No reply yet?", a question, because the device cannot know for certain when it rings | At the time, on every device that knew of it. **Withdrawn or re-timed when a sync shows the snooze changed**: a reply came, it was unsnoozed or finished elsewhere, or snoozed again. |
| Still waiting to send | "A message is still waiting to send" · the subject · action **Send now** | Ten minutes after he left with a send unfinished; withdrawn when it goes |
| Failed send | "Couldn't send “Q3 numbers”" · the reason | When it fails and Mail is not in front |
| A scheduled message is late | 6.5.5 | |

No sounds of Mail's own, and no other actions.

---

## 8. Speed

### 8.1 Budgets

What the person should feel, and what makes it reachable. Each must hold offline, on a
phone, in a Release build, with everything the device keeps on it. They are checked where
MAIL-PLAN says: by the prototypes at order 0, by each package's own check, and by the gate
of each order against the whole-app baseline. The engine's own budgets are its section 15.

| Interaction | Budget | What the design does to make it reachable | First checked |
|---|---|---|---|
| Key or tap → something visibly changes | The next frame at the 95th percentile | T0: the source has applied the change to every list before the call returns. Nothing is awaited. | P2; gate B |
| `E` → cursor on the next row | The next frame | The cursor is two leaf views flipping (6.1.8). | P2; gate B |
| `E` → the list has closed up | 180 ms | One short animation; the next key does not wait for it (T18). | Gate B |
| Holding `J` | Every repeat lands; no hitch over two frames in ten seconds; the list container is not re-evaluated | Fixed row heights; `MailRowMark`; the platform's scrolling container. | P1; gate B |
| Applying a list (`listApply`) | 4 ms on the main thread at 400 rows; 16 ms at 2,000 | The window (6.1.7); `Equatable` rows; one application per change. | Gate A (P1 did not measure it) |
| Open the next or previous conversation | The next frame | Its model is ready ahead (8.2). | P3; gate C |
| `J`, `E` or a click → the pane shows the new cursor conversation | The next frame when it was prepared ahead; 50 ms otherwise | T48; the next conversation in the direction of travel is always prepared. | Gate C |
| `J` held, with the pane showing | Nothing read, laid out or drawn for the rows passed; the pane changes 150 ms after the last repeat | T48; the pane and the details column observe what is showing, not the cursor. | Gate C |
| Open any conversation on the device | 50 ms at the 95th percentile | Bodies were prepared when fetched; text heights are recorded; a designed body's frame is known. | P3; gate C |
| A designed body painted | 150 ms on its second open | One configuration; a local document; no network; a paper placeholder meanwhile. | P3; gate C |
| App memory with six designed bodies open | Within 100 MB of the baseline; within 60 MB a minute after leaving | The cap; web views emptied off screen and released with the tree. | P3; gate C |
| ⌘K, a picker, Places | The next frame | Static registry; counts already in memory. | Each package |
| Composer on screen with a caret | The next frame; filled within 50 ms | Drawn at once; the draft arrives a few milliseconds later; K12 keeps what is typed meanwhile. | P6; gate D |
| Typing in the composer | The list and the reader are not re-evaluated | Nothing else observes the composer's model. | P6; gate D |
| Search results for a keystroke | 30 ms | The engine's index; stale answers dropped. | Gate E |
| Switch to Mail → real rows | The frame of the switch | `MailSession` holds the last list. | Gate A |
| Back from the background blank → the same screen | The first frame, the same row first, within a point | Models live in `MailSession`; the host restores a position (T46). | P1 (0.33 pt, iPhone Simulator); gate A |
| Cold launch with Mail restored → readable inbox | Banana's first frame; Mail adds at most 10 ms | `cachedFirstPage`: one small synchronous read. | Gate A |
| Send → composer gone | The next frame | A send is a row in the outbox. | Gate D |
| Undo → everything back | The next frame | The entry holds the rows and the view. | Gate B |
| New mail on screen | Within a minute of arriving; at once after ⌘R or a pull | The engine checks once a minute while Mail is on screen; then T7–T9. | Gate F |
| Mail in front, nobody touching it | No body evaluations; no STORM line; idle CPU within 0.5 % of the baseline | 8.3. | Every gate |

A sign-in code he is waiting for arrives in seconds. The engine does this (its 12.1): for a
minute after a check he asked for, and after Mail comes to the front, it checks every five
seconds — twelve polls at most, only while Mail is on screen, and not in Low Power Mode.

### 8.2 What is prepared ahead, and what is never waited for

**Prepared.** On a device where Mail has never been opened, nothing of Mail's runs at all.
Otherwise:

1. If Mail is the restored tab, its first page comes from `cachedFirstPage` before the first
   frame. If it is not, nothing is read until Mail is opened.
2. On entering a place: its first rows, and the first page of the next split.
3. More rows when the cursor or the viewport is within 30 rows of the last one delivered.
4. When the cursor has stopped on a row (T48: at once after a single press, 150 ms after
   the last repeat of a held key): `wants` for that conversation and the next in the
   direction of travel, so their models and bodies are ready. With the pane showing, this is
   also the moment the pane shows it.
5. While a conversation is showing or open: the next in the direction of travel and the one
   before. `MailSession` keeps the eight most recent conversation models.
6. When the next conversation ends in a designed body, and the device is not in Low Power
   Mode: that document is loaded into a web view ahead.
7. When search opens: the six people for the empty state.

**Preparing never fetches from a sender.** Items 4 to 6 ask for pictures as *warming*, which
yields what is already on the device and nothing else (6.2.6).

**Never waited for** by any view, key or tap: the network; a change reaching Gmail; a draft
being made or saved; an attachment; a remote picture; Gmail's search; a count; a body that
is not on the device (the header shows without it).

### 8.3 Requirements on every Mail view

Conditions of building any package, not advice. Each comes from an incident in this app or
from the performance review of this design.

| # | Requirement | Why here |
|---|---|---|
| G1 | Rows and message cards are small `Equatable` view types. No view type in Mail has more than about a screen of concrete children; `MailSection` hands each arrangement up as `AnyView`. | A giant view type overflowed the 1 MB main stack in Release and crashed Settings. |
| G2 | The cursor and the selection live in per-row leaf observables (`MailRowMark`), never in state the list reads. | A held `J` repeats far above twice a second. |
| G3 | The shells do not observe Mail. `RootView` and `MacRootView` read the badge from `ActionBadges`, which reads the engine's mirror, and nothing else. `ShellState.mail` is written when the app goes to the background and when a composer opens or closes — never for `J`, `K`, Done or opening a conversation (3.11). | `ShellNavigation.state` is published, saved on every change and observed by the root: writing it per key would re-evaluate the shell and write `UserDefaults` at key rate. |
| G4 | Publish at the rate of meaning: the list's window once per applied change; status, download figures and attachment progress each in their own leaf. Nothing of the UI's is registered with `PerfWatchdog` as a counted publisher: a list that rightly changes once per action would be logged as a storm during quick triage. | The protected pattern in `PERF-PLAN.md`. |
| G5 | Nothing un-quantised is read from scrolling: the list is told two things by its host (6.1.8) — whether the first row is on screen, and the position when scrolling stops, as a row's key and whole points (T46); the reader records whole points when scrolling stops. Every write is equality-guarded. | A fractional offset in a preference key ran a render loop. |
| G6 | No `@AppStorage` in a hot Mail view, and no dotted key anywhere. Hot views get a `MailPrefs` value. Keys: `mailTimeLastPhrase`, `mailReaderZoom`, `mailPaletteRecents`. | A dotted key re-rendered the week view five to seven times a second for ever. |
| G7 | The UI parses, converts and measures no HTML, and lays out nothing in a view body (6.2.10). | The HTML importer in a body froze the app three times. |
| G8 | No main-thread I/O except `cachedFirstPage`. | Unlock-to-Today budget. |
| G9 | No repeating timer in the view tree except the status line's once-a-minute `TimelineView`. The idle timer is one shot, restarted by input. The send hold is the toast's expiry, not a countdown. | Timers in the tree are how idle CPU creeps. |
| G10 | Mail does nothing when nobody can see it: `setVisible(false)` and the idle timer stopped when `AppVisibility.isActive` is false or Mail is not the section in front. Web views are released when the tree is discarded. | The background CPU kills. |
| G11 | `RenderStats.note("MailShell")` is the first line of `MailSection`'s container, which must not re-evaluate on a cursor move, an action, or a keystroke in the composer. The list, the reader and the composer are counted by probes the tests read (`mail.list.renderCount`, `mail.reader.renderCount`, `mail.composer.renderCount`), which exist only under `--perf-trace`. | So a real storm names the view, honest work does not, and the probes cost nothing otherwise. |
| G12 | The host's cells have fixed heights, self-sizing off, prefetching on, and show exactly what the model published: no hand-kept token decides when the list refreshes. | The Day grid's stale-content bug. |
| G13 | G1 is a review item in every view package: the reviewer checks that no view type holds more than about a screen of concrete children and that each arrangement is type-erased. The crash this prevents shows only in a Release build on a device, so it cannot be a step an implementer runs: `ScreensOpenUITest`, which gains Mail and Settings › Mail, is one of the owner's device runs at each gate (13.4). | A Simulator does not show the stack overflow, and nothing is installed on a device without him. |
| G14 | The UI logs counts and milliseconds through `MailUILog`, a closure `MailSession` is given at wiring (the engine's P24); it names no engine type. It never logs a subject, a name, an address, a snippet, a query or a file name. No file in `Views/Mail/` or `Model/MailUI/` names a logger or `print(` (the engine's test greps both). | The diagnostics privacy rule. |
| G16 | A held key does no work in the pane or the details column: nothing is read, laid out or drawn for a row the cursor only passes (T48). Their probes (`mail.reader.renderCount`, `mail.details.renderCount`) do not rise while `J` is held, and neither column observes the cursor. Which columns show is decided from one measured width, written only when it crosses a threshold of 6.0.2 — never per point of a window being resized. | A pane that followed every repeat would read thirty conversations a second. |
| G15 | Every preview route and every test launch runs with mail's network off: any `VisualAuditRoute` launch, and `--disable-mail-network`, make the engine refuse every request, and the gate asserts the transport saw none. | A route must never touch his mailbox. |

### 8.4 What the first frame shows

| Arriving by | First frame |
|---|---|
| Tapping the Mail tab, or ⌘2 | The list as it was left: same place, cursor, first row and offset. Never a blank list followed by rows. |
| Coming back after the tree was discarded | Exactly what was showing: the list at the same row and offset; an open conversation at its reading position, its designed bodies as paper placeholders of the right height until they repaint; an open composer with its text. |
| Cold launch, Mail restored | The first page of the restored place from `cachedFirstPage`, the status line reading "Checked … ago". An open conversation is restored one frame later. |
| Cold launch, first time ever | The turning-on screen (6.9). |
| Opening a conversation | The header, every message header, every text body. A designed body's frame at its recorded height. |
| A notification | The conversation, as above. |

### 8.5 Measuring

- Signposts: `mail.key`, `mail.listApply`, `mail.open`, `mail.webPaint`, `mail.composerOpen`,
  `mail.search`, `mail.undo`.
- Render counters: `MailShell` (`RenderStats`), and the three probes of G11 under
  `--perf-trace`.
- UI tests that assert a budget's shape, their keys pressed by `--mail-keys`:
  `MailCursorRenderUITest` (held `J`, the list's probe flat), `MailRapidDoneUITest` (ten `E` in a second, ten gone, ten list deliveries),
  `MailReaderScrollUITest` (the reader scrolls from a drag begun anywhere above the bar; no
  card moves after first paint except by the recorded-height rule).
- **Each package's performance line is its gate's line** (MAIL-PLAN sections 3 and 7), and
  each package runs the per-package checks of MAIL-PLAN section 4 before it is handed back:
  the gate script on its own routes, its benchmarks in Release, sixty seconds under
  `--perf-trace`, and the greps.
- The whole app is audited against the baseline at every gate, on every existing route as
  well as Mail's. The baseline is `mail-working/perf/results/`, re-run as P0′ after the four
  whole-app fixes land.

---

## 9. What only Banana can do — after the first release

None of this decides whether Superhuman can be dropped, so none of it is in the first
release (section 11). It is specified so the screens leave room, and corrected where the
first draft assumed things about the calendar that are not so.

| # | Advantage | Package |
|---|---|---|
| 1 | An invitation answered in place, with the day and the clash in view | U13 |
| 2 | An email becomes a task or a time block on the plan | U13 |
| 3 | The day beside the mail | U13 |
| 4 | Free times typed into a reply | U17 |
| 5 | Flights and bookings feed the trip · summaries and drafts on the device | Seams only (9.5) |

### 9.1 The invitation card

A conversation that carries an invitation (`MailConversation.invite`) shows a card first,
under the header and above the messages.

```
┌──────────────────────────────────────────────────────────────┐
│ ▦  Design review                                             │ .headline
│    Tue 6 Oct · 9–9:45 AM · Jane Park and 3 others            │ DateText · TimeRangeText.compact
│    Zoom                                                      │ place or platform
│ ──────────────────────────────────────────────────────────── │
│  8:30  ▌ Swim                                                │ ┐
│  9:00  ▌ Standup                                             │ │ MailDayStrip: that day around the event
│  9:00  ┆ Design review ┆                                     │ │ the invitation, drawn as unanswered
│  9:45    45 min free                                         │ ┘
│  Overlaps Standup, 9–9:30 AM                                 │ danger; or "Free then." in secondary
│ ──────────────────────────────────────────────────────────── │
│  ⟦ Yes ⟧   ⟦ No ⟧   ⟦ Maybe ⟧                  Show in Plan  │
└──────────────────────────────────────────────────────────────┘
```

- **Every fact on the card comes from the calendar, not from the file a sender wrote.** The
  mail carries only that it is an invitation and its identifier; the event is found by the
  calendar's own lookup on that identifier (`GoogleEvent.iCalUID`, which the calendar already
  indexes), and its title, time, place, guests and his answer are the calendar's. There is no
  calendar-file parser in Mail. An invitation whose event the calendar cannot find shows the
  message's subject and "This isn't on a calendar Banana can see, so it can't be answered
  here." with **Open in Gmail**.
- The strip is at most four rows of that day: the last thing before the event, what overlaps
  it (two at most, then "+1 more"), and what comes next or the gap after. Times in
  `DS.Typeface.gutter`; each event's spine in its calendar's tint; the invitation itself in
  the planner's unanswered style. Events shown as free do not clash.
- **Yes · No · Maybe**: the inspector's words and order; the current answer is filled.
  Answering is the calendar's (T14), as the week view and ⌘K behave today (the phone's event
  sheet answers without a notice; the card follows the week view): **Yes and Maybe are
  sent at once and confirmed with a notice ("Going to “Design review”") that has no Undo —
  changing the answer is the way back; No takes the event off the day at once, with the
  calendar's Undo for a few seconds.** The card restyles when the calendar's own state
  changes; a reply that fails says "Couldn't reply: …" and the card is as it was.
- **It moves nothing in Mail** (O7). `E` is still what finishes the conversation. Answered
  invitations should be clearable from the Calendar split without opening them: a reason
  line "You said Yes" on the row, which needs the row to carry the answer — to be asked of
  the contract when U13 is planned.
- **Keys:** `I` then `Y`, `N` or `M`, only while this card shows an unanswered invitation
  (K6), with the pending `I` drawn on the card.
- The UI test for this card runs on fixtures with the calendar's reply stubbed; it never
  calls Google.

### 9.2 Add to plan

`A` (a task) or `B` (a time block) on the target.

1. The time picker opens (6.5) with **Task · Block** in its footer.
2. Choosing a time **makes the task or block first**: a reminder titled with the subject
   (`RemindersService.createTask`, which is asynchronous and can fail or be refused), or a
   30-minute event through the calendar's optimistic create. Either carries Gmail's web
   address for the conversation in its notes — the conversation's `gmailURL`, the one
   implementation of that link — which opens the conversation anywhere today.
3. **Only when it exists is the conversation marked Done** (T16). Toast: "On your plan · Thu
   2 PM · Undo". If it could not be made, nothing is marked Done and the toast reads
   "Couldn't add to your plan: …". If Reminders access is missing, the priming sheet comes
   first and the action follows it.
4. Undo removes the task or block and brings the conversation back. That needs two small
   additions outside Mail, made by U13: `RemindersService.deleteTask`, and a form of the
   calendar's optimistic create that returns a handle to discard or delete what it made
   (today it returns nothing).

This is not snooze. Snooze brings mail back to be looked at again. A task puts the work at a
time, among the meetings it has to fit around, in Reminders — which notifies on every device
without Banana running.

### 9.3 The day beside the mail

A card in the details column (6.10), where the first draft had a pane of its own:
`MailDayCard`. `0` shows the details column with it; `-`, `=` and `T` move the day. It shows
today, or the open invitation's day. It lists the day as Banana knows it from
`OccurrenceStore.shared.occurrences(on:)`, leaving out ids in `ToastCenter.hiddenIDs` as
every other reader of the day does, with the now line and gap rows. Display only. It observes
the occurrence store from its own view; the list and the reader never do. At one column,
More › Show day presents the same card in the details sheet.

### 9.4 Free times in a reply

⌘⇧T in a composer opens the availability chooser that already exists (`MacAvailabilityPanel`
on the Mac, `AvailabilitySheet` elsewhere) with its main button reading **Insert**; it puts
`AvailabilityFinder.text(for:request:timeZone:)` at the caret as editable text.

### 9.5 Seams

| Later | Seam left now |
|---|---|
| Bookings feed the trip; a summary of a long conversation | The conversation's cards are an ordered list of kinds drawn above the messages; the invitation is the first. ⌘J is reserved. A model is never on a path that draws a list, and nothing it writes reaches Gmail without a key press. |
| Mail answered elsewhere marks itself Done | A rule the engine would run when Plan records an answer. Not built. |
| Snooze until a moment ("after my workout") | `MailTimePresets` takes the plan as an input (the "After *event*" row). |
| Mail on Today and in the morning briefing | The badge counts (2.4) are the data. |
| Snippets | The composer's tool slot; ⌘; and `G` `;` are reserved. |
| Preview fixtures on a fixed day | `OccurrenceStore.injectSampleForPreview` seeds from the real clock today; U13 gives it a `now:` parameter so the invitation's day and the fixture mailbox's day agree. |

---

## 10. Accessibility and input

Accessibility is part of every package, not a pass at the end: each package's "done" includes
the identifiers, labels, actions and text sizes of what it built (section 14). U16 is only
the sweep that checks the whole.

### 10.1 Text size

- **Three-line rows** are built from text styles and grow with Dynamic Type. Up to the
  largest standard size the three lines stay three lines. At accessibility sizes the row
  reflows: the date moves under the names, the glyph slots move to the end of the last line,
  and the snippet may take two lines. Heights are still fixed for a given size.
- **One-line rows** hold from the smallest size to the largest standard size. **All three
  fixed columns scale** (`@ScaledMetric` on the sender column, the date column and the glyph
  slot), so "12 Aug 2024" still fits at the largest standard size. At accessibility sizes on
  an iPad the list uses the three-line row.
- **Bars and headers keep their heights**, so their labels cannot grow. Every control in
  them — split tabs and chips, the place's title, the action bar's words, header buttons —
  supports the system's Large Content Viewer: press and hold shows the item large.
- **A conversation's text** follows Dynamic Type; a designed body is zoomed by the same
  factor. **On the Mac**, ⌘+, ⌘− and ⌘0 do it (6.2.8).

### 10.2 VoiceOver

- **A row is one element.** Its label, in this order: "Unread." (if so) · the names · "3
  messages" · the subject · **the date** · the snippet or the reason line · "Attachment." ·
  "Invitation." · "Starred." · the label · the account. Its value: "Selected", while
  selecting.
- **A row's actions** (the rotor's Actions): Done · Mark unread (or read) · Star · Reply ·
  **Select** · Label · Trash · Snooze when built · **Undo last action**, while the stack has
  one. They are T16 and T17; no gesture is the only way to anything.
- **After an action** focus moves to the cursor conversation (the successor), and an
  announcement says what happened with the toast's words: "Marked Q3 numbers Done. Undo
  available."
- **The columns** are four containers named "Mailboxes", "Conversations", "Message" and
  "Details", in that order; a column that is not showing is not in the order. The buttons
  that show and hide them say which they act on and its state ("Details, showing").
- **In a conversation:** the header is a heading; each message is a container whose label is
  "Sam Lee, Monday 9:12 AM, to you and Jane" and whose folded state is spoken; a designed
  body is read from its text; the action bar's buttons have their words as labels; older and
  newer are buttons.
- **Chips** (splits) are a tab list: "Important, 12 conversations, selected, tab 1 of 4".
  "40+" is read "at least 40".
- **Pickers and the command menu** announce the highlighted row with its time or its key.
- Every control has an accessibility identifier in the form `mail.<screen>.<thing>`
  (`mail.list.row.<fixture key>`, `mail.bar.done`; the toast's is the existing `toast.undo`).
  UI tests use these, never positions. They are constants in
  `MailUI/Pure/MailIdentifiers.swift` — `enum MailID`, with `static let list = "mail.list"`
  and `static func row(_ key: String) -> String`. The engine's C0a placed that file, with
  those two, so the pure folder exists; each package adds its own in
  `MailIdentifiers+<package>.swift`.

### 10.3 Targets: 44 points, and the Mac's dense list

- **44 pt is a rule about fingers.** Wherever a finger can be the pointer — compact always,
  regular on an iPad — every row and every control is at least 44 pt.
- **On the Mac, where the pointer is a mouse, the one-line row is the panel row: 32 pt.** The
  whole row is the target. Icon buttons in a row or a header are `DS.Mail.pointerTarget`
  (28 pt) with at least `Space.xs` between them.
- The number is decided in `DS.Mail.oneLineRow`, and the design system's own rule is amended
  to say so (5.1). No view checks the device.

### 10.4 Pointer and keyboard

- Rows wash on hover and show their quick actions; hover never moves the cursor or selects.
- Buttons and chips use the system hover effect on iPad and `.help` tooltips on the Mac; a
  tooltip always includes the key ("Done  E").
- Right-click on a row, a message, a chip, a link or an attachment opens its menu. Every
  menu item is also in ⌘K.
- **The Mac's `Tab`.** macOS moves `Tab` only between text fields unless keyboard navigation
  is switched on in System Settings. The invitation's buttons, the attachment chips and the
  reply field are declared focusable regardless, so `Tab` reaches them either way.
- An attachment on the device can be dragged out on the Mac. Rows are not draggable.

### 10.5 Reduced motion, contrast, colour

- Reduced motion: 5.3's right-hand column.
- Increased contrast: the cursor fill and separators step up one `Tint`, and the unread dot
  gains a 1-pt outline in the text colour.
- Nothing is said by colour alone: unread is a dot and a weight; a selected row is a check
  and a wash; failed is a symbol and words; a label is a chip with its name.

### 10.6 Right-to-left, and odd content

- The interface mirrors with the interface language. A message's own direction comes from
  its text (6.2.5).
- A sender with no usable name shows the address. A subject of only emoji is shown as it is.
  An empty subject reads "(no subject)". Names and subjects are never upper-cased or cleaned
  of emoji; **they arrive already cleaned of invisible and direction-changing characters**,
  which is the engine's work and not something a view may undo.

---

## 11. The first release, and what is out of it

### 11.1 The first release

**The smallest set that replaces Superhuman for morning triage and reply, on the Mac first,
and built for narrow widths from the first package.** The Mac is where he is keyboard-heavy,
it needs no tab decision, and the engine fills completely there. Every screen's compact form
is built in the same package as its wide one, so the iPad and the iPhone are never a second
project; only the phone's bottom slot and its seat in the tab bar come last, from pictures he
has seen.

| In, by the order it is built (MAIL-PLAN) | |
|---|---|
| The columns: control, list, pane, details, by width; the inbox and its splits, from the real store | Order 1 |
| Triage with Undo: Done, Trash, Spam, Star, Read, Label, Move, Not done, Not spam, Restore; selecting, by row and by scope; the Mac's keys | Order 2 |
| The conversation in the pane and over the list: text and designed bodies, pictures at four levels, links, attachments on demand, find, text size; the details column | Order 3 |
| Compose, reply and forward with attachments; Send, Send and Done, Send now; Undo Send; Outbox | Order 4 |
| Search — the device's results and Gmail's in one list; the label and move pickers | Order 5 |
| Turning Mail on per account; Settings, with how far back mail is kept; offline, signed-out and first-sync states; new-mail notifications | Order 6 |
| Snooze; Send later; Remind me if no reply | After search, each with its engine package and its probe |
| The iPhone's bottom slot and its seat in the tab bar | Last, after P4's pictures and his choice |

### 11.2 What he would miss on day one, item by item

The reviewer's list. The default is *in* where it is cheap.

| | First release? | How |
|---|---|---|
| Find in a conversation | **In** | ⌘F; 6.2.8. TextKit bodies make it cheap. |
| Selecting and copying part of a message on the phone | **In** | TextKit bodies; 6.2.5. |
| Tappable phone numbers, addresses and dates | **Out, on purpose** | The security review's rule: nothing in a message is made actionable except a link that has passed the link rule, and the engine forbids data detectors in mail. They can be selected and copied. To be reconsidered once the first release is in use, with a confirmation before anything is dialled or opened. |
| Not spam, and Restore from Trash | **In** | `⇧E` in Spam and Trash, named in ⌘K and in the row's menu (T14). |
| Next and previous conversation as buttons on the phone | **In** | The navigation bar's arrows (T42). |
| Undo on the phone after the toast | **In** | The slot's Undo button for two minutes; More › Undo after (T44). |
| Recipients he has never exchanged mail with | **In** | Autocomplete includes calendar guests and contacts, through the engine (6.3.3). |
| Zoom in the reader on the Mac | **In** | ⌘+, ⌘−, ⌘0 (6.2.8). |
| A sign-in code within seconds | **In** | ⌘R or a pull checks at once; five-second checks for a minute afterwards are the engine's (8.1). |
| Undo Send that is not buried | **In** | 6.3.7. |
| A Send later he can trust | **In** — the owner's ruling | 6.3.6, 6.5.5. It is honest rather than magic: a scheduled message needs the device it was scheduled on to be awake, and every device shows a late one as late. |
| Snippets | **Out** unless he says he uses them weekly | A fact only he has (MAIL-PLAN section 8). |

### 11.3 Out of the first release

| Left out | Why | Kept for it |
|---|---|---|
| The invitation card, Add to plan, the day's card in the details column, free times in a reply | The best things only Banana can do, and not parity (section 9). | `I` · `A` · `B` · `0` · ⌘⇧T |
| Mute; unsubscribe; creating a label from the picker | Used rarely; each needs engine bookkeeping or a confirmation flow of its own. | `⇧M` · ⌘U · the picker's last row |
| Editing splits; saving a search as a split | The three built-in splits, and custom ones made elsewhere, work from the start. | 6.4.4 |
| ⌘K's ranking, recents and rows made from what is typed | The menu and the shortcut sheet from the registry are enough to start. | U12 |
| Mail's keys on an iPad | The focus rule has to be proven first (4.4). | U5b |
| The two hints and the "older than a week" offer | Nice on day one; not needed to work. | 6.9 |
| Undo after a cold launch | Needs the engine to list what it can still reverse. | T27 |
| Tabs; pop-out composer windows; more than one composer open; draggable column dividers | One conversation showing and one composer at a time is what keeps the keys simple. | The pop-out keys are reserved |
| Snippets; summaries, drafts and questions by a model | Section 9.5. | ⌘; · ⌘J |
| Lists, quotes, colour, tables and image resizing in the composer | The system's editor has no list model; typed "- " lines read fine. | ⌘⇧7/8/9 reserved |
| `Tab` through links; ⌘O | Focus inside rendered HTML. | — |
| Bundles in Other; a screener for new senders | Each is a second list model. | — |
| Choosing swipe actions | Two fixed actions a side are Superhuman's defaults. | — |
| Editing Gmail's filters, signatures, vacation reply; delegation; confidential mode | Gmail's own settings, used rarely, on the web. | — |
| Deleting for ever; emptying Trash; renaming or deleting labels | Wider permission than Mail asks for, or Gmail's own. | — |
| Read statuses; send-time suggestions; redo; dragging rows onto labels; printing | Impossible without a server, or small with a path today. | — |
| Watch app, widgets | After the loop is proven. | — |
| Providers other than Gmail | The brief. | — |

Not left out, though Superhuman lacks it: **one inbox across accounts**, and **his mail on
the device, readable and searchable without a connection** — six months of it by default,
all of it if he chooses.

### 11.4 Standard components first

The owner's instruction: no parser or mechanism of our own where a standard one exists. On
the screens' side:

| Need | Uses | Not built |
|---|---|---|
| Typed times ("fri 3pm", "3 days") | The app's `EventPhrase.takeDate`, which holds the system's date detector; plus about eighty lines for spans and four fixed words (6.5.2) | A phrase parser |
| Dates and times on screen | `Date.FormatStyle`, the system's relative formatter, `TimeRangeText` (5.2) | Hand-assembled month order or a literal "Yesterday" |
| A message's text | The engine's one parse, delivered as `MailText`; mapped to attributed text in one file (6.2.5) | A second tokenizer; any HTML-to-text code in the UI |
| Showing and selecting text | TextKit views (`UITextView`, `NSTextView`) | A text layout of our own |
| Designed mail | `WKWebView` under the engine's configuration | Anything else |
| The composer's body | `TextEditor` over `AttributedString` with a formatting definition (6.3.4) | A rich-text editor; an HTML writer in the UI |
| Search operators in the field | The source's `queryTokens` (6.4.3) | A second tokenizer of the grammar |
| Which event an invitation is | The calendar's own lookup by identifier (9.1) | A calendar-file parser; matching by title and time |
| Open in Gmail, Copy link, the link back from a task | The conversation's `gmailURL`, made by the engine (6.2.3, 9.2) | A second place that builds or reads that address |
| Attachments | Quick Look, the system's thumbnail generator, `UniformTypeIdentifiers`, the byte-count format, the photo picker, the file importer, drop destinations (6.2.9, 6.3.5) | Type tables, previews, pickers |
| The list's scrolling container | `UICollectionView`'s list layout and `NSTableView`, hosting SwiftUI rows (6.1.8) | A scroller of our own; swipe gestures |
| Keys, the command menu, the toast | The app's `MacKeyMonitor`, `MacCommand`, `ToastCenter`, extended (section 4, 5.2) | A second monitor, menu or toast |
| A cache file that may be corrupt | `SnapshotLoader` (6.2.10) | Load-or-quarantine code |

**What remains hand-built, and why:** `MailListModel` and `MailUndoStack` (the rules of
section 3 are this product; nothing standard encodes them); `MailKeymap` and `MailCommands`
(Superhuman's map, as data); `MailTimePresets` (five rows of product judgement);
`MailTextRendering` (a mapping from the engine's blocks to this design system's type);
`MailRenderHeights` (a cache); `MailStatusText` and the other copy tables (words);
`MailListHost` (glue between two platform containers and the model); and four lifts into the
design system (`DateText`, `DSChip`, `Monogram`, `KeyHintRow`).

---

## 12. What each screen asks of the contract

### 12.1 One contract

- **`Banana/Model/Mail/MailContract.swift` is the only declaration of the types a screen may
  name and of the protocol it calls.** Its text is MAIL-ENGINE section 13; the engine's
  package C0 creates it. This document declares none of them and names them as that section
  does. What the screens asked of it after conforming is in it now (12.6); nothing is
  declared here.
- **Two things implement the protocol**: `MailEngine`, over the real stores, filled from the
  fake Gmail in previews and tests; and `MailFixtureSource`, in memory, which this document's
  package U0′ builds by running the engine's own pure rules over the same mailbox. The
  in-memory source comes first (U0′); the engine joins it with the engine's P23a, and from
  then on one contract suite (the engine's `MailContractTests`) runs against both. A
  behaviour a screen depends on is added to that suite first.
- **A member that is not built yet is nobody's stub.** The contract's
  `MailSource+NotYet.swift` (C0) gives every requirement a default — an empty list, `nil`,
  `.notOnDevice`, `.refuse`, a receipt with a count of zero. A source implements a member by
  declaring it in a file of its own; neither `MailFixtureSource.swift` nor `MailEngine.swift`
  holds a stub, and no file is edited to replace one. A screen whose call still reaches a
  default is drawn disabled (section 6).
- **One fixture mailbox**, defined once at Gmail's level by C0. Section 13.2 names the
  conversations the screens need; they are added to that mailbox.
- **There is no adapter and no package that "joins" the halves.** Every UI package from the
  first list (U4a) onward is accepted on the real engine over the fake, at its own gate. The
  packages before it have no screen or no engine to run on yet, and are accepted on the
  in-memory source.
- **Folders.** `Banana/Model/Mail/` is the engine's, and names nothing outside itself.
  `Banana/Model/MailUI/Pure/` is compiled into the tests as a folder (C0's one line in
  `project.yml`; no UI package edits that file), so everything a unit test must reach lives
  there: every rule, every table of words, and the in-memory source
  (`Pure/Testing/MailFixtureSource.swift`). A file there has no view and names only
  Foundation, the contract, and app files the test target already compiles (`EventPhrase`,
  `BananaDesign`, `ToastCenter`). The one exception is `Pure/Testing/MailFixtureSource*.swift`,
  which also names the engine's pure rules and wire models (its P03a and P05, and later
  slices' pure rules), so that both sources run the same rules. The UI's other models are in
  `Banana/Model/MailUI/`; views
  are in `Banana/Views/Mail/`. The first file in the pure folder, which C0a placed, is
  `MailIdentifiers.swift` (10.2).

### 12.2 What the rules lean on

The contract's promises (its 13.5), and the rule here that stands on each:

| Promise | Stands on it |
|---|---|
| 1, 2 · a command returns at once and is in every reading before it returns | T0, T16, T18: the second `E` of two sees the first's result. The UI keeps no overlay. |
| 3 · the engine owns the reverse of a change | T26, T30 |
| 4 · a target can be a scope, with one receipt | T22, T45 |
| 5 · one synchronous read, `cachedFirstPage` | 8.4's cold launch |
| 6 · readings arrive at the rate of meaning; his own changes are not new mail | T7, T37, G4 |
| 7 · bodies are ready-made | 6.2.5, G7 |
| 8 · nothing is represented by an empty list | Section 7 |
| 9 · the cursor is the UI's, and a leaf | T2, G2 |
| 10 · order is the engine's | T1 |
| 11 · a position is restored from a limit and a row's id | 6.1.7, 3.11 |

### 12.3 Reads, by screen, and how fast each is needed

"Needed within" is what the screen's budget (8.1) leaves for the source. Observed reads
deliver on the main actor.

| Screen | Asks for | Needed within |
|---|---|---|
| Entering Mail | `activate()`; `setVisible(true)` | Returns at once (the contract says 1 ms) |
| The list, cold launch | `cachedFirstPage(scope)` | 2 ms, synchronously, and only when Mail is the restored tab |
| The list | `observeList(scope, limit:)` — rows, `total`, `hasMore`, `stillLoading`, `isRebuilding`, `heldSince`, `remote`, `appliedThrough` | First value 16 ms for a step of rows from an open store; a step more, 30 ms; his own command, before `apply` returns |
| The control column, split tabs and chips, pickers | `observePlaces` — splits, counts for splits, mailboxes and labels, labels by account | First value 16 ms; then on change |
| The status line, the foot card, alert cards, Outbox's refused changes | `status` (a leaf): online, last check, waiting counts, downloads and what holds them, the store, open questions, and `refused` — one `MailRefusedChange` per action | In memory |
| The badge | `badges`; at launch `MailBadgeCounts.mirrored(in:)`, through `ActionBadges` | Under 1 ms at launch, no store opened |
| The reading pane, an open conversation, the details column | `observeConversation(id)`; `conversation(id)` for the ones prepared ahead; `decideLink(_:in:)` for a link tapped in a designed body | 30 ms when it is on the device; a link's answer within a frame or two |
| A message's body | `body(id)` | 10 ms: it was prepared when fetched |
| A designed body's pictures | `resource(url, for:, presentation:)`, called by the web view's scheme handler | Whatever the picture takes; the frame does not wait |
| An attachment | `attachmentProgress(id)` (a leaf) | In memory |
| The composer | `newDraft(kind)`; `draft(id)`; `accounts` for identities; `resource(_:forDraft:presentation:)` for a signature's or a quote's pictures | 30 ms — and the composer is on screen before it returns (6.3.9) |
| Recipients | `people(matching:limit:)` | 20 ms |
| Search | `observeList` on `.search(text)` — also `remote`, `coverage`; `suggestions(for:)`; `queryTokens(_:)` | The device's first rows 30 ms; suggestions 20 ms; tokens at once (pure) |
| Settings, turning Mail on | `accounts`, `observeAccounts`; `storageUsed()`; `pictureRules()`; `syncLimit`; `conversationsBeyond(_:)` for the one question | In memory; storage, the rules and the number whenever (the row shows "—" meanwhile) |

The UI never asks for a count by itself, a single row, anything by row number, or anything
the network would have to answer.

### 12.4 Commands, by screen

| Screen | Commands | What the screen assumes |
|---|---|---|
| Triage (list and conversation) | `apply(_:to:)` with `.conversations`, `.message` or `.scope`; `undo`; `retry` and `discard` of a refused change, with the receipt its `MailRefusedChange` carries | T0, T36, T45. `.done` also marks read. A conversation Gmail no longer has makes the change a success. |
| The list | `checkNow()`; `wants(_:)` | `status.asked` goes `.running`, then `.finished`, counting only mail from elsewhere. `wants` never fetches from a sender. |
| The conversation | `fetchBody`, `fetchAttachment`, `showPictures(in:always:)` | Results arrive as changes to what is observed. Offline they are remembered for the session. |
| The composer | `save`, `addAttachment`, `removeAttachment`, `rewriteAsText`, `quoteAsText(in:)`, `changeIdentity(of:to:)`, `discard`, `send(_:_:)`, `cancelSend`, `retrySend`; for the Mac's quit, `hasUnfinishedSends` and `finishSends(within:)` | `save` returns at once. `send` with `hold: nil` uses the setting's hold, and with `at:` it is Send later; Remind me if no reply is the draft's `remindIfNoReply`, saved with it. `cancelSend` answers truthfully within a few milliseconds. Leaving ends the hold and sends. |
| Search, and a list that ends at the limit | `askGmail(_:)` | "More from Gmail", "Try again", "Get older from Gmail", and the "Search Gmail for …" row on a device that keeps everything; the snapshot's `remote` follows. |
| Questions (7.5, 7.6) | `answer(_:_:)` | The question leaves `status` in the same turn. |
| Places, pickers, splits | `apply(.label…)`, `apply(.move…)`; later `saveSplits`, `createLabel` | One use of a picker is one receipt. |
| Settings, turning Mail on | `setWantsMail`, `requestPermission`, `forgetPermission`, `removeDownloadedMail`, `removePictureRule(_:)`, `setSyncLimit(_:)` | `requestPermission` is the one call that shows Google's sheet; it is never made from a key handler without the person having asked. |
| Everywhere | `observeEvents` | Events carry ids and closed kinds, never a subject or Google's words; the UI looks up what to say (section 7) and never logs it. |

### 12.5 What stays on the UI's side

Built in the UI packages and tested there: the screen half of undo (`MailUndoStack`); the
cursor, selection, direction, held changes and kept rows (`MailListModel`); the words of a
row (`MailRowDisplay`) and of every state (`MailStatusText`); typed times and presets
(`MailTimePhrase`, `MailTimePresets`); the keymap and the command registry (`MailKeymap`,
`MailCommands`); mapping the engine's text to attributed text (`MailTextRendering`); recorded
heights (`MailRenderHeights`); recent searches, in memory for the session only; the reader's
text size (UserDefaults, a dot-free key); and the settings that are the screens' own, as optional fields of
`AppSettings.Snapshot`. Not on the UI's side, though the first draft had them there: who a
reply goes to, the query grammar, the link back from a task, sanitising or converting HTML,
and any overlay of pending changes.

### 12.6 What the contract gained at the screens' request

Everything the screens asked for after conforming is in the contract. How each is used:

| # | For | In the contract | A screen |
|---|---|---|---|
| A1 | Split tabs and chips (2.4) | `MailPlaceCount`; `MailPlaces.splitCounts` | Draws `splitCounts[id].total`: what is left, read or not. |
| A2 | The composer's signature and quote (6.3.4) | `MailDraftPart`; `quoteAsText(in:)`; `changeIdentity(of:to:)`; `resource(_:forDraft:presentation:)` | Draws `draft.signature?.body` and `draft.quote?.body` as it draws a message's body and hands each `fragment` back untouched. "Edit as plain text" is `quoteAsText(in:)`; changing From is `changeIdentity(of:to:)`; their pictures come from `resource(_:forDraft:presentation:)`. |
| A3 | The badge (2.4) | `MailBadgeCounts.needsAnswer`, which counts a send that failed for good | Shows that number. |
| A4 | Settings (6.8.1) | A way back from every "always": since the owner's ruling, `pictureRules()` and `removePictureRule(_:)` | Lists the first; removes one with the second. |
| A5 | The removal card (7.5) | `MailPlace.heldRemoval(account:)` | "Show them" opens `MailScope(place: .heldRemoval(account:))`. |
| A6 | A sign-in code (8.1) | The engine's bounded burst (its 12.1) | Calls nothing. |

And what the final verification added, so that a screen is drawn from what the contract
gives and from nothing else:

| In the contract | Used by |
|---|---|
| `MailRowRules.Outcome.leaves(MailRow)` | A marked row that no longer matches a filter is kept (T17). |
| `MailRowRules.Outcome.unknown(MailRow)` | A change in a search, Drafts or a custom split shows at once, as the row carried; the next reading places it (T16, T17). |
| `MailStatusValue.refused`, one `MailRefusedChange` per action | Outbox's "Changes that didn't go through" (T36, 7.6). |
| `askGmail(_:)` | The "Search Gmail for …" row (6.4.3, 7.3). |
| `MailRowReason.asking(_, kind)` and `.held(until:)` | A row's reason line, from the row alone (6.1.1). |
| `MailPerson.fromTheirMail` | "from their mail" in autocomplete (6.3.3). |
| `MailConversationID.gmailURL` | Open in Gmail, Copy link (6.2.3). |
| `MailTuning.maxEncodedBytes` | The size limit (6.3.5). |
| `MailSendOptions.hold`, optional | The composer passes `nil` (6.3.7). |
| `MailBadgeCounts.mirrorKey` and `mirrored(in:)` | The seat's badge, before any engine exists (2.4). |

**What the contract gained for the owner's rulings** (MAIL-ENGINE 13.10; its package C0c),
and where each is used:

| In the contract | Used by |
|---|---|
| `MailSyncLimit`; `syncLimit`, `setSyncLimit(_:)`, `conversationsBeyond(_:)` | Settings' "Keep mail from", and the number in its one question (6.8.1). |
| `MailDownload.limitEdge` | The foot card and the first-sync words say how far back the device is to reach (7.1). |
| `MailListSnapshot.heldSince`; `askGmail(_:)` for any place | The foot of a list that ends at the limit, and "Get older from Gmail" (6.1.7). |
| `MailRow.isOnDevice`; `MailRemoteSearch` with `offline` and `more` | The one glyph on a row Gmail found; the foot of a search (6.4.3, 7.3). |
| `wants(_:)` fetches a conversation the device does not hold | Stopping on a row, or opening it, brings it here (6.2.11, T48). |
| `MailPlaces.labelCounts` | A count beside every label in the control column (6.6). |
| `MailPictureGrant`, `MailPictureRule`; `MailPictures.offers`, `shownBy`; `showPictures(in:always:)`, `pictureRules()`, `removePictureRule(_:)` | The four levels (6.2.6, 6.8.1). |
| `MailSendOptions.at`; `MailDraft.schedule`, `remindIfNoReply` | Send later and Remind me if no reply (6.3.6). |

The reading pane and the details column need nothing new: `wants`, `conversation(_:)` and
`observeConversation(_:)` are enough, a column's lists are folds over the conversation's
messages, and "Recent with" is a search scope.

**Nothing more is asked of the architect.** Two notes, so that the two documents are read
the same way: the control column lists accounts as a filter, with their state, so it needs no
counts per account; and the engine keeps Gmail's rows in a second group below the device's
(`MailOrderKey.group`), which this document draws as one list with no heading (6.4.3). The
group is an order, not a heading.

Later, with the features that need them: the invitation's answer on its row (9.1); what the
engine can still reverse after a relaunch (11.3). "Send now from this device", for a late
message another device owns, is `answer(_, .sendFromHere)`.

---

## 13. Preview routes, fixtures, and how a screen is checked

The Simulator cannot tap and the Mac's snapshot harness cannot be driven, so every screen
and every state in this document has a launch route that lands on it with fixture data.

### 13.1 Routes

**The rule.** `--mail` is the route: it shows `MailSection` alone, measured and with its
toast. It is in `VisualAuditRoute.flags`, so a launch with it starts none of the production
graph, and **mail's network is off** (G15): nothing a route does can reach Gmail, a picture
host or a token endpoint. Everything else is a modifier beside `--mail`, and works the same
in the whole shell (`--ui-preview --dummy-health --tab mail --disable-icloud`).

**Which source.** By default a route runs the real engine on temporary stores, filled from
the fake Gmail loaded with the fixture mailbox — what the gates measure.
`--mail-source memory` runs `MailFixtureSource` instead. `--mail-state` implies it: those are
states a real engine reaches only slowly or not on demand.

| Modifier | Values | Lands on |
|---|---|---|
| *(none)* | | The list: the first split, cursor on the first row |
| `--mail-source` | `engine` (default) · `memory` | Which implementation of the contract |
| `--mail-seat` | | On a phone, the recommended tab bar and Library's switch (2.2), until U1b makes it real. `--tab mail` on a phone implies it. |
| `--mail-width` | points, for the Mac's offscreen picture: `1400` (the default), `1100`, `800`, `640` | Mail drawn at that width, so each arrangement of 6.0.2 has a picture. On a Simulator the device and its orientation give the width. |
| `--mail-pane` · `--mail-control` · `--mail-details` | `on` (default) · `off`; details also `panel` | That option as he might have left it (6.0.4); `panel` shows the details over the pane |
| `--mail-focus` | `list` (default) · `pane` | With `pane`, the cursor conversation is open in the pane (T49) |
| `--mail-keep` | `1m` `3m` `6m` (default) `1y` `all` | The sync limit the fixture source reports; with anything but `all`, part of the mailbox is "in Gmail" |
| `--mail-keys` | a script in quotes: `"J*40@8 E*10@100"` is forty `J` 8 ms apart, then ten `E` 100 ms apart | Once the first frame has settled, these strokes go to the same dispatch the key monitor calls, at that pace. Every platform, the offscreen harness and an iPad before U5b included. It is how tests and gates press keys. Built by U5. |
| `--mail-place` | `important` `calendar` `vip` `other` (the splits) · `inbox` `starred` `marked-important` `drafts` `sent` `outbox` `done` `all` `spam` `trash` (`snoozed` with U8; `muted` with mute) · `label:Invoices` · `held-removal` | That place's list. `all` is the 5,200-row mailbox. `marked-important` is the mailbox of Gmail's mark, not the split. |
| `--mail-filter` | `unread` `starred` `important` `noReply` | The list with that filter on |
| `--mail-account` | an address | The list narrowed to it |
| `--mail-cursor` | a fixture key | The cursor on that conversation |
| `--mail-select` | a number, or `all` | That many rows selected from the top; `all` is a selection by scope |
| `--mail-open` | a fixture key | That conversation open |
| `--mail-find` | text in quotes | The find bar open over `--mail-open`, with that typed |
| `--mail-compose` | `new` `reply` `reply-all` `forward` | The composer (with `--mail-open` for a reply) |
| `--mail-compose-state` | `empty` `typed` `autocomplete` `attachments` `over-limit` `bad-address` `reply-to` `foreign` `program` | The composer in that state |
| `--mail-search` | text in quotes | Search with that text |
| `--mail-search-state` | `empty` `remote-pending` `remote-done` `remote-more` `remote-failed` `offline` `none` | Search's scope line, its merged results and its foot in that state (6.4.3) |
| `--mail-picker` | `label` `move` (`snooze` with U8) | That picker open over the list, or over `--mail-open` |
| `--mail-picker-text` | text in quotes | The picker with that typed |
| `--mail-places` · `--mail-menu` | | Places · ⌘K on regular, More on compact |
| `--mail-state` | see 13.3 | The list in that state |
| `--mail-toast` | `done` `sending` `refused` `undone` `too-late` | That toast showing |
| `--mail-rows` | | The row gallery: every row variant of 6.1.1, in both row types |
| `--mail-settings` · `--mail-accounts` | | Settings › Mail · Accounts & calendars with a Mail line in every state of 7.5 |
| `--mail-turn-on` | `first` `not-granted` `different-account` `second-device` | The turning-on screen (6.9) |

**On the Mac, offscreen only**: `--snapshot-app-store <png> --snapshot-view <name>` (cases
added to `MacDebugSnapshotViews`: `mail-rows` · `mail-list` · `mail-conversation` ·
`mail-composer` · `mail-picker` · `mail-menu` · `mail-places` · `mail-shortcuts`), or the
whole section with `--snapshot-app-store <png> --mac-section mail` and the modifiers above.

**In the gate.** Each package adds its routes as one file, `tools/perf-routes.d/<package>.routes`
(MAIL-PLAN section 2), so no two packages edit one table.

```sh
# iPhone Simulator: the 40-message conversation
xcrun simctl launch <SIM> com.boris.banana --mail --mail-open forty --disable-icloud
# iPad Simulator: the regular list in the shell
xcrun simctl launch <IPAD> com.boris.banana --ui-preview --dummy-health --tab mail --disable-icloud
# Mac, offscreen: a conversation, dark
"<app>/Contents/MacOS/Banana" --snapshot-app-store /tmp/x.png --mac-section mail \
    --mail-open q3 --appearance dark
```

### 13.2 The fixture conversations

**The mailbox is defined once, at Gmail's level, by the engine's package C0**
(`Banana/Model/Mail/Testing/MailFixtureMailbox.swift`): both sources are built from it. This
table is the list of conversations the screens need in it; a UI package that needs another
adds it in its own `MailFixtureMailbox+<package>.swift` and names that file in the engine's
one registry file, which is how a list that one file enumerates is added to. The hostile
messages the web view is tested against are the engine's (its 17.5).

**Some of it is the device's, not Gmail's.** A mailbox at Gmail's level cannot say that a
body has never been downloaded, that an attachment is here, or that a send is waiting,
failed, unconfirmed or two days old — and the screens need all of those. So the mailbox has
a small second part beside its Gmail part: the device facts for `headers-only`,
`attachments`, `failed-send`, `waiting`, `unsure-send`, `stale-send` and `refused-change`.
Each source applies it after loading — the in-memory source directly, the engine through
its fixture loader — so both show the same thing.

**Now** is fixed by the fixture clock: Monday 5 October 2026, 9:41 AM, in the machine's time
zone. Every fixture date is relative to it, so "9:12 AM", "Yesterday" and "Thu 8 AM" never
drift.

**Accounts:** `noor@plan.example` (short name "z0"; Mail on; the default; two identities, a
signature with a small picture) · `bberenberg@gmail.com` ("gmail"; Mail on; the one that is
downloading in first-sync states) · `noor@work.example` (Mail off).

**People:** Sam Lee `sam@lee.example` and Jane Park `jane@parkdesign.example` (written to
before) · Ana Ruiz, Tom Okafor and Mei Chen at `northwind.example` · senders with no name ·
one never written to. All domains end in `.example`.

**Places and counts:** Important 12 · Calendar 2 · VIP 3 (a custom split,
`from:@northwind.example`) · Other 40. Drafts 2. Outbox 4, by the contract's rule — every
conversation with a message that is held, waiting, being checked, asking or failed:
`failed-send`, `waiting`, `unsure-send`, `stale-send`; a refused change is not one of them.
Labels: Invoices (green), Dewey › Hiring (nested, purple). **Until the engine's query rules
exist (its P08a, order 5) a custom split is empty on both sources**: VIP shows no rows, its
three conversations are in Important (15), and the numbers above are checked from gate E. `--mail-place all` is the 5,200-conversation mailbox, for
the list host, scrolling and held-key tests.

Each conversation has a key; its accessibility identifier is `mail.list.row.<key>`.

| Key | Place | What it is | What it is for |
|---|---|---|---|
| `q3` | Important, first | Sam Lee and Jane Park, 3 messages, unread, "Q3 numbers before Thursday", an .xlsx and a .png, starred, label Invoices | The ordinary case; the wireframes |
| `plain-chain` | Important | Six plain-text messages between two people, quotes nested five deep | Text bodies; quote folding; selection |
| `forty` | Important | 40 messages, nine people, three unread | Folding; "39 earlier messages"; P3 |
| `long` | Important | Twelve recipients with long names; a 300-character subject; a 30,000-character body | Truncation; the long-body cut |
| `attachments` | Important | A 2.4 MB PDF and an 800 kB PNG on the device; a 48 MB ZIP that is not | Attachment chips in each state |
| `attachments-many` | Important | Twelve attachments | "+7 more" |
| `program` | Important | An attachment that is a program, named `invoice.pdf` | The program sheet; the plain symbol for a type that is not what it says |
| `big-image` | Important | A message with one 4,000-pixel inline image | A designed body by the contract's rule; picture boxes |
| `me-newest` | Important | The newest message is his | "If no reply" in the picker |
| `draft-reply` | Important | A conversation with an unsent reply | The reason line; the reply field showing a draft |
| `failed-send` | Important | His reply failed: too large | 7.6 |
| `unseen-reply` | Important | Opens with a newer message below the fold | T45; "1 new message" |
| `rtl` | Important | A Hebrew sender, subject and message, then an Arabic reply | Right-to-left |
| `lookalike` | Important | From a stranger whose name reads "noor@plan.example" | The address shown instead of the name (6.2.3) |
| `reply-to` | Important | Replies go to a different address | The "replies go to" line; the composer's line |
| `invite` | Calendar | An invitation to "Design review", Tue 6 Oct 9–9:45 AM | The invitation glyph; later, 9.1 |
| `vip-1` … `vip-3` | VIP | Mail from `northwind.example` | A custom split |
| `newsletter` | Other | One designed message: 1.2 MB of HTML, 60 remote pictures, three trackers, one-click unsubscribe, an authenticated sender (`dispatch.example`) | The web body; the pictures line; "Always from…" |
| `three-newsletters` | Other | Three unread designed messages in one conversation | Several web views; the cap; P3 |
| `receipt` | Other | A Stripe receipt in simple HTML, label Invoices, to the gmail account | Simple HTML as text; the account chip |
| `emoji` | Other | Subject "🎉🎉🎉" | An emoji-only subject |
| `no-name` | Other | From `no-reply@accounts.example.com`, no name | A sender with no name |
| `no-subject` | Other | No subject | "(no subject)" |
| `headers-only` | Other | The body has never been downloaded | 6.2.5 |
| `github-1` … `github-8` | Other | Eight notifications from one sender on one day | Multi-select |
| `nested-label` | Done | Labelled Dewey › Hiring | Nested label names |
| `draft-new` | Drafts | A new message to two people | Drafts |
| `foreign-draft` | Drafts | A draft written in Gmail with a table in it | 6.3.4 |
| `waiting` | Outbox | Waiting for the network | 7.6 |
| `unsure-send` | Outbox | Banana cannot tell whether it went | 7.6 |
| `stale-send` | Outbox | He pressed Send two days ago and it has not gone | The `sendLate` question, 7.6 |
| `refused-change` | — (`status.value.refused`) | "Move to Invoices · 3 conversations" that Gmail refused; not a conversation of any place | T36; Outbox's second section |

| `old-conversation` | In Gmail only | A conversation from last year, not on the device | 6.2.11; a Gmail-only result |

With their packages: `snoozed`, `snooze-back`, `noreply-back` (U8); `scheduled`,
`scheduled-elsewhere`, `late-asking`, `late-sent` (U9c); and, after the first release,
`invite-cancelled` (U13).

### 13.3 Every state has a route

`--mail-state` sets the in-memory source's status and accounts. One value at a time. Each is
owned by the package that draws it (MAIL-PLAN section 7), which adds its names to the UI's
one registry file (14.2).

| Value | Shows | Section | Package |
|---|---|---|---|
| `first-seconds` | Skeleton rows; "Getting your newest mail…" | 7.1 | U15b |
| `downloading` · `downloading-phone` | Real rows; counts with "+"; the foot card with a Mac's and an iPhone's third line | 7.1, 7.4 | U15b |
| `downloading-held` | The foot card paused, once per reason | 7.1 | U15b |
| `offline` · `offline-waiting` | "Offline · mail as of 9:12 AM" · "Offline · 1 message and 3 changes waiting" | 7.2 | U15b |
| `unreachable` · `slowed` | Rows 6 and 7 of 7.2 | 7.2 | U15b |
| `rebuilding` · `comparing` | Rows 8 and 9 | 7.2 | U15b |
| `checking` · `checked` · `checked-nothing` | Rows 10 and 11 | 7.2 | U4a |
| `sent-after-wait` | Row 12 | 7.2 | U15a |
| `sending-changes` | Row 13 | 7.2 | U4b |
| `stale` | "Checked 14 min ago" | 7.2 | U4a |
| `disk-full` | Row 1; an action answers "Couldn't save that" | 7.2, T36 | U15b |
| `store-newer` · `store-damaged` | The list's area says so | 7.5 | U15b |
| `access-withdrawn` | The alert card; "Google stopped allowing Mail" | 7.5 | U15b |
| `needs-access` · `first-open` | "Allow Mail on this iPhone" · "On · starts when you open Mail here" | 6.9, 7.5 | U14 |
| `admin` · `wrong-account` · `api-disabled` | Those three account states, each with its way out | 7.5 | U14 |
| `removal-held` · `changes-lost` · `draft-changed` | Those three questions | 7.5 | U15b |
| `mail-off` | "Mail is off." | 7.8 | U14 |
| `empty-split` · `inbox-clear` | The two empty inboxes | 7.8 | U4a |
| `new-chip` | A list scrolled down, with "2 new" | T9 | U4b |
| `undo-button` | The compact slot with Undo (and "Undo send" during a hold) | T44 | U4c |
| `prefix` | `G` pending in the header | K6 | U5 |
| `at-limit` | A label's list that ends at the limit, with its foot | 6.1.7 | U15b |

A failed, waiting or unconfirmed send is reached by opening its conversation or by
`--mail-place outbox`. An empty place other than the inbox: `--mail-place spam`.

### 13.4 How a screen is checked, and what is never done

- **iPhone and iPad: in the Simulator.** A route is launched with `simctl`, pictured with
  `simctl io … screenshot`, and exercised by `BananaUITests`. The regular arrangement is
  tested on an iPad Simulator. **Keys are pressed by script** (`--mail-keys`), which runs
  everything after the event itself; real hardware keys on an iPad arrive with U5b and are
  tested there with `typeKey`. One Simulator device per implementer, named in its brief.
- **The Mac: the offscreen snapshot harness, and nothing that shows a window.** No package's
  verification launches `--ui-audit` (it opens the real window), uses `screencapture`, drives
  the pointer or keyboard, or launches the app plainly. The harness cannot draw system
  materials, so the pickers and the command menu are judged for layout on the iPad
  Simulator, where the same views draw in full, and for the Mac's own sizes in the harness.
- **Never, without his say:** an install on a device; a launch outside a route; a call to
  Google.
- **What does need a visible Mac window, or his device — each needs a time slot from him:**

| What | Why it cannot be done offscreen | When |
|---|---|---|
| P1's Mac half: the table host measured on a display (about 70 minutes, one small panel) | Frame timing and scroll position need a real window | Before U4a's Mac host is accepted |
| P2's Mac half: real key events through the monitor; type-ahead | The monitor sees only events the window server delivers | Order 0, before U5 |
| One look at the Mac's hover states, the material panels, and ⌘K with Mail's commands | Materials and hover do not exist offscreen | Before gate B |
| Gate F's Mac window picture | MAIL-PLAN's gate | Order 6 |
| P1, P3 and P4 on his iPhone; the device runs of MAIL-PLAN | Release timing, memory, and gestures on real hardware | When he says go; each blocks the next order, not the current one |
| `ScreensOpenUITest` in Release on his iPad, walking Mail and Settings › Mail | The stack overflow it exists for does not show on a Simulator (G13) | At each gate |

---

## 14. Prototypes and packages

The order, the gates, the shared files and the full row for every package — files, seams,
routes, tests, performance line, the engine slice it needs — are in **MAIL-PLAN.md** (sections
1 to 5 and 7). This section says what the prototypes must show, the rules every UI package
follows, and what each package builds.

### 14.1 Prototypes, before the screens that rest on them

Each is a day or two, thrown away afterwards, built on the fixture mailbox with mail's
network off. Each records its numbers in the journal and in `mail-working/perf/results/`.

| | Settles | Must show | Blocks |
|---|---|---|---|
| **P1** the list's host — **run**, for iPhone and iPad | Whether rows can be kept still and restored (6.1.8) | Shown: the native collection view passed every positional test; `List` and `LazyVStack` failed (6.1.8). Still to run: the Mac's `NSTableView` half, at the owner's Mac | Now only the acceptance of U4a's Mac host |
| **P2** keys | The scope by intent, type-ahead, keys after a click in a message (4.1) | 4.1, "What P2 must show" | U5 |
| **P3** bodies | TextKit text bodies and a web view per designed message (6.2.5) | 6.2.5, "What P3 must show" | U6, and U7 with the engine's P26 |
| **P4** the phone's bars | The bottom slot with the shell's two bars; the hidden tab bar; the bar swipe (6.1.3) | 6.1.3, "What P4 must show" — and the pictures the author chooses from | U4c, U1b |
| **P6** the composer | The system editor, the signature and quote as blocks, the sheet's detents (6.3) | 6.3.9, "What P6 must show" | U9a |

(P5, the send probes on a live test account, is the owner's. It gates send later, which is
now in the first release: U9c is built on the fake with the probe's switches both ways, and
accepted for real mail only after the probe.)

### 14.2 Rules for every UI package

- **Narrow from the first package.** The owner's ruling: "we should be building to support
  Mobile from the get go." A package builds its screen at every width in 6.0.2 — in the
  pane and over the list, regular and compact — and is not done until its compact form is
  pictured on an iPhone Simulator. Where the compact form waits on prototype P4 (the bottom
  slot), the package builds the fallback of 6.1.3, which needs nothing unproven. No package
  exists to add a phone form to a screen built earlier.
- **One implementer at a time, one commit a package.** Implementers are scheduled one after
  another: whoever is building a package is the only one editing the tree. A package lands
  as one commit, after its checks and its review.
- **It is built on the contract, and from the first list onward it is accepted on the real
  engine.** U4a and every package after it: its routes run on `MailEngine` over the fake
  Gmail by default, the contract suite passes on both sources, and its UI tests pass on
  both. Nothing is accepted against behaviour only the in-memory source has. The packages
  before U4a have no screen, or no engine to run on yet, and are accepted on the in-memory
  source; where a package's row names a member the engine gains later, it says at which gate
  the engine's half is checked.
- **A member of the contract that is not built yet has the contract's default** (12.1). A
  package that needs a member on the in-memory source declares it in its own
  `MailFixtureSource+<package>.swift`; nothing is edited to replace a stub.
- **Files.** It creates files only where its row in MAIL-PLAN lists, and edits an existing
  file only if its row names it. Additions to another package's type go in an extension file
  of its own (`MailFixtureSource+<package>.swift`, `MailSession+<package>.swift`,
  `MailIdentifiers+<package>.swift`). Three kinds of file are edited by more than one
  package, each listed with its packages in MAIL-PLAN section 5: `MailSection.swift`, which
  gains a destination at a time; the *slot files* — a view an earlier package draws disabled
  and a later one fills; and **the UI's one registry, `MailSession+Parts.swift`**, where each
  package adds a line for its command handlers and its `--mail-state` names, because a list
  one file enumerates cannot be added to from another. Files a unit test must reach go in
  `Banana/Model/MailUI/Pure/` (12.1) with a test class each; no UI package edits
  `project.yml`.
- **A control whose target is a later package is drawn and disabled**, with its label, never
  hidden (section 6).
- **Accessibility is part of the package**: identifiers, labels, custom actions and Large
  Content Viewer for every control it adds (section 10), and one of its routes pictured at
  an accessibility text size.
- **Performance.** It meets the line of its gate (MAIL-PLAN section 3) and runs the
  per-package checks of MAIL-PLAN section 4. Every view obeys 8.3; G1 is checked by the
  package's reviewer (G13).
- **Checking** follows 13.4: Simulators for iPhone and iPad, the offscreen harness for the
  Mac, no window on the owner's desktop, no device, no call to Google.

### 14.3 The packages, in order

**A thin slice is being built first**, on sample mail, so that he can try the columns: the
list, the reading pane and the details column, with the cursor and the pane following it. It
is not a package of this list. When it lands, U1a, U2 and U4a are re-cut around what it
already has (MAIL-PLAN section 7 says so), and it produces the picture for the question of
6.0.6.

| Order | Package | Builds |
|---|---|---|
| 1 | **U0′** Fixture source and session | `MailFixtureSource` on the contract, from the one mailbox and the engine's pure rules: the reads a list needs, with every other member left to the contract's default until the package that needs it. Its own mapping of a thread's summary to a `MailRow`. `MailSession`, `MailNavigation`, the registry file, `MailRoute`, and what the session must tell the triage model (3.11). No screen. |
| 1 | **U2** Design system and the row | 5.1, 5.2 (but not the toast or the bottom bar); 6.1.1: `MailRowDisplay`, both row types, every variant; the row gallery. |
| 1 | **U3** The triage model — *built* | Section 3 as code with no views. |
| 1 | **U3b** The triage model's pane rules | 3.12's last table: "showing" as a state, the reader's facts for a showing conversation, the entry of T25, and cases 55–69. |
| 1 | **U5a** The keymap, as data | 4.2's map and 4.5's registry with no views, with focus as T50 has it. |
| 1 | **U1a** The seat and the columns | 2.2: the section on the Mac and in the iPad's sidebar; `MailSection`; **the columns of 6.0** — `MailColumns.showing(width:options:)`, the three options and their keys, the stand-ins — with placeholders in them; `ShellState.mail`; the badge; `LibraryHome` and `--mail-seat`. Adds 6.0.3's rule to `ADAPTIVE-LAYOUT.md`. |
| 1 | **U10a** The control column | 6.6: the column, and the same view as Places in a popover and a sheet; choosing a place. |
| 1 | **U4a** The list, read-only, with its cursor | 6.1.2 beside a pane and at full width, the compact list with 6.1.3's fallback, 6.1.4, 6.1.7, and 6.1.8 on the native host, to what P1 found; the status line and all of `MailStatusText`; the empty states; the test that the two sources give equal rows. |
| 2 | **U4b** Actions, swipes, selection, the toast | T14–T30 on screen: Done, Trash, Spam, Star, Read, Not done; swipes (6.1.6); selecting at every width (6.1.5), with the selection's summary where there is a pane (T54); `ToastCenter.present`; Undo; the "new" chip (T9). |
| 2 | **U5** Keys on the Mac, after U4b | Section 4 wired: the one dispatch every key goes through, the monitor's scope by intent, type-ahead (K12), focus between the list and the pane (T50), the View menu's three chords, Mail's rows in ⌘K and the shortcut sheet, `--mail-keys`. |
| 3 | **U6** The conversation | 6.2: in the pane, over the list and pushed; the pane following the cursor (T48), open as focus (T49), read (T51); text bodies; find and text size; the reply field; older and newer; the conversation's action bar and More at compact width; `MailSession.show(_:)`. |
| 3 | **U7** Designed bodies and attachments — *one package with the engine's P26* | The web body card; 6.2.6 (pictures at four levels), 6.2.7 (links), 6.2.9 (attachments). |
| 3 | **U20** The details column | 6.10: the column, the panel and the sheet; People, About, Attachments. "Recent with" joins in U11. |
| 4 | **U9a** The composer: the card, the sheet and sending | 6.3.1–6.3.4, 6.3.6–6.3.9: in the pane, over the list, and the compact sheet on the detents P6 found; recipients, the body, the signature and quote blocks; Send, Send and Done, Send now, Undo Send. |
| 4 | **U9b** The composer: attachments and formats | 6.3.5; the format tools; a foreign draft. |
| 4 | **U15a** Delivery and the Outbox | 7.6: delivery lines, the waiting card, a failed and an unconfirmed send, a send that waited a day, refused changes in Outbox. |
| 5 | **U11** Search | 6.4: the field in the list column and in the slot, chips from the source's tokens, suggestions, one merged list with Gmail's results, the scope line and the foot; "Recent with" in the details column. |
| 5 | **U10b** The label and move pickers | 6.6's two pickers. |
| 6 | **U14** Turning Mail on, and Settings | 6.8, 6.9: the priming screen, the account card's Mail line, Settings › Mail with the sync limit, the picture levels and the trackers switch, the account states of 7.5. |
| 6 | **U15b** States | The rest of section 7: first sync and its holds, offline, the store's states, the alert cards and questions, the edge of the limit (6.1.7, 6.2.11). Then a sweep of every route in 13.3 against section 7's words. |
| After 6 | **U8** The time picker and snooze — with the engine's P19a | 6.5: `MailTimePhrase`, `MailTimePresets`, the picker at every width; snooze; the leading swipe and the action bar's second button become Snooze. |
| After U8 | **U9c** Send later and Remind me if no reply — with the engine's P18b and P19b | 6.3.6's second table, 6.5.5 and 7.7: the clock button, the read-back, the scheduled card, every late state on every device, their notifications. Built on the fake with each probed behaviour tested both ways; used for real mail after the probes. |
| Last | **U4c** The phone's bottom slot | 6.1.3's slot in the form P4 chose and the author saw, in place of the fallback: splits and Places in it, Search, Compose, the Undo button (T44). |
| Last | **U1b** The phone's seat | 2.2: `iOSTabs`, Library's switch with Record and Write in both parts, `AdaptiveShellUITest`; `--mail-seat` is removed. After his choice. |

After the first release, each on its own decision: **U13** (the invitation card, Add to
plan, the day card in the details column) · **U12** (⌘K's ranking, recents, typed rows) ·
**U5b** (Mail's keys on an iPad) · **U17** (free times in a reply) · **U16** (the
accessibility sweep; the hints and the old-mail offer) · the control column inside Banana's
sidebar, if he chooses B (6.0.6).

---

## 15. Decisions

There is one list of decisions for the author, for both halves of mail: **MAIL-PLAN.md section
8.** This document keeps none of its own. Each entry there has one recommendation, the
runner-up, and what changes otherwise. What the owner has answered is there in his words.
Five of the open ones he should see as pictures before he is asked, and what makes each
picture is named there: where the control column lives (the slice); the iPhone's seat
(U1a's `--mail-seat`); the phone's bottom layout (P4); the Mac's row height at full width
(U2's gallery at two heights); and a late scheduled message (three mock pictures, before
U9c).

---

## 16. What became of each review finding

Every BLOCKER (B) and MAJOR (M) that concerns the screens, from the five reviews in
`mail-working/review/` and `mail-working/perf/`. "Fixed" names the section that now carries
the rule. Nothing is marked fixed that is only mentioned. Two findings are declined in part,
and say why.

**The UX review**

| | | Outcome |
|---|---|---|
| U-1 | B | **Fixed.** One list model, a window found by key (6.1.7); the platform's scrolling container hosting SwiftUI rows, which P1 has since measured (6.1.8); arrivals never inserted above a list that is not at its top (T9); the list stays mounted under an open conversation (6.2.2); restoring is a row and whole points (T3, T26, 8.4). The grow-to-5,000 list is gone: the window slides over what the contract delivers, which is the first rows up to `MailTuning.listCap`. |
| U-2 | B | **Fixed.** T0 claims only Apply and Remember; Settle is T16's. K9 is the only `Esc` rule, in the reviewer's order. T16 clears the selection only when it was the target. T14 has a third kind for the calendar's actions. A selection by scope is bounded by its key (T22, T24). Cases 32–36 of 3.10. |
| U-3 | B | **Fixed.** K2 (an editable field, or one asked for and not yet there), K10, K12 (type-ahead), with the tests named in 4.1 and P2 before U5. |
| U-4 | B | **Fixed in the design; built after the first release.** Late is shown on every device, notified, and can be taken over; one late rule, no setting; three pictures before he is asked (6.5.5, 7.7). |
| U-5 | B | **Fixed.** TextKit text bodies from the engine's `MailText`; one web view per open designed message with a cap; an empty paper placeholder; heights keyed by message, width, text size and pictures; a plain `VStack` reader; P3 before U6 (6.2.5, 6.2.10). |
| U-6 | M | **Fixed, pending P4.** 6.1.3 is redrawn with the shell's two bars, says what "never moves" means, and names the fallbacks; nothing compact is built until P4's pictures exist. |
| U-7 | M | **Fixed.** Splits and Places are in the bottom slot (6.1.3). |
| U-8 | M | **Fixed.** The slot's Undo button; "Undone · Undo previous"; a VoiceOver action (T44, T26, 10.2). |
| U-9 | M | **Fixed.** `Z` does what the toast on screen offers; otherwise Mail's stack (T26). |
| U-10 | M | **Fixed, by a different mechanism.** T45. What a row says is never held back (T7), so an action on a row is as of what it says; an open conversation with an unseen message acts as of the last message seen; a scope is bounded by the key it was made at. No change to the contract was needed. |
| U-11 | M | **Fixed, one clause declined.** Arrivals join only after three idle seconds and never mid-swipe (section 0, T9); a toast names its conversation (7.9). *Declined:* "never while a row is hovered". On a Mac the pointer usually rests over the list, so a hovered row would mean mail never arrives; pointer *movement* resets the three seconds instead. |
| U-12 | M | **Fixed.** Read is marked after 400 ms of showing (T10); `J` and `K` do not repeat in a conversation (K7). |
| U-13 | M | **Fixed** (after the first release): the task is made first; Done follows only if it exists (9.2). |
| U-14 | M | **Fixed, one part declined.** Truthful words per device; Edit and Don't send on a waiting message; a send that waited is confirmed once; the "still waiting" notice (6.3.6, 7.2, 7.6, 7.10). *Declined:* bringing the engine's background-session send into the first release — that is the engine's schedule; the copy tells the truth without it. |
| U-15 | M | **Fixed.** The foot card's third line is the device's truth, with every reason it pauses (7.1); the turning-on screen says the same (6.9). |
| U-16 | M | **Fixed.** Older and newer buttons in the navigation bar; the bar swipe only if P4 allows (T42, 6.2.1). |
| U-17 | M | **Fixed.** The cursor row keeps everything; quick actions on hover only; a selected row's drawing; when the cursor is drawn on an iPad (6.1.2, T2). |
| U-18 | M | **Fixed.** Signature and quote are blocks, sent as shown; "Edit as plain text" says what it costs; the detent is P6's with a stated fallback (6.3.2, 6.3.4). Drawn from `MailDraftPart`. |
| U-19 | M | **Fixed.** T28 lists what cannot be undone; unsubscribe takes a second press; Not spam and Restore are `⇧E` in their places (T14, 4.2.4). |
| U-20 | M | **Fixed.** A refused change is shown as Gmail has it, at once, with its reason on the row and Retry; it also waits in Outbox (T36). The first draft's overrule, which kept the row as he had made it, is withdrawn. |
| U-21 | M | **Fixed.** Undo for a send is on its card, its row, the slot and ⌘K for the whole hold (6.3.7). |
| U-22 | M | **Fixed.** A returning snooze is unread and first (6.5.4, T1); its notification is withdrawn or re-timed when the snooze changes (7.10). |
| U-23 | M | **Fixed.** The store's states, changes lost, the wrong account (7.5); a Beta composer is marked (6.3.1); storage says what is kept (6.8.1); undo depth matches the engine (T27, T30); no cursor in `ShellState` (3.11); Mail is opt-in per account (6.9); section 12 declares no types. |
| U-24 | M | **Fixed.** The reasoning is corrected: Notes is where a note is started, so Record and Write stay one tap away in Library, and he chooses from a picture (2.2). |
| U-25 | M | **Fixed.** Prototypes first; the real engine behind the first list; budgets checked at every gate (section 14, MAIL-PLAN). |
| U-26 | M | **Fixed.** Large Content Viewer; scaled columns; Select, Reply and Undo actions; the date before the snippet; counts in secondary; focusable controls on the Mac; ⌘+ and ⌘− (section 10, 6.2.8). The iPad's key host comes after the first release, with its focus rule (4.4). |

Of the fourteen minor findings, all are applied (U-27's strings throughout section 7) except
U-36, undo after a cold launch, which needs the engine to list what it can still reverse and
is after the first release (11.3).

**The engineering review, where it names this document**

| | | Outcome |
|---|---|---|
| E-2 | B | **Fixed.** One contract, the engine's; two implementations; one suite; one mailbox; no adapter package (12.1, 14.2). |
| E-8 | M | **Fixed.** Section 12 is written in the contract's names. What the screens asked for after conforming, A1–A6, is in the contract (12.6). |
| E-11 | M | **Fixed.** One list model (6.1.7); no overlay in the UI (3.11); the composer takes its draft from the engine (6.3.9). |
| E-19 | M | **Fixed.** The list is two packages; each state route names its package (13.3); unbuilt controls are drawn disabled (section 6); performance lines are measurable (8.1); pure files need no `project.yml` edit; fixtures are added in a package's own file (14.2). |
| E-28 | M | **Fixed.** The Mac's `case .mail` measures its column and has a minimum width; the first frame's arrangement is remembered (2.2). |
| E-29 | M | **Fixed, each of the eight re-verified against the code.** `ShellState.mail` is written on backgrounding and when a composer opens or closes, never per key (3.11, G3). The fixture clock is fixed, and the day's fixture gets a `now:` with U13 (13.2, 9.5). `ScreensOpenUITest` is the iPad's, and a device run of the owner's (G13). Answering an invitation is described as it behaves (9.1). Add to plan's undo names the two handles it needs (9.2). Nothing of the UI's is a counted publisher (G4). The baseline is `mail-working/perf/results/` (8.5). The engine has `activate()` (12.3). |
| E-30 | M | **Fixed.** One web view package, the engine's P26 with U7; the engine owns its settings fields (6.8.1); the badge is the engine's two numbers (2.4); pictures have one rule (6.2.6); the device's search has no debounce, as the contract says (6.4.3); a first sync's length is the engine's (7.1); nothing is launched plainly (13.4); a held action key acts once (T18). |

Minor, and fixed: E-42 ("Always from" is a domain in both documents, 6.2.6) and E-43 (each
package carries its own accessibility line, 14.2).

**The security and privacy review, where it lands on screens**

| | | Outcome |
|---|---|---|
| P-1 | B | **Fixed.** Ask first; trackers never; "Always from" an authenticated domain only; preparing ahead never fetches (6.2.6, 8.2). |
| N-1 | M | **Fixed.** The three passages are rewritten (6.2.6; the footnote in 6.8.1; the decision is in MAIL-PLAN section 8 with the same recommendation as the engine). Settings carries the plain sentence about the Mac's store (6.8.1); turning Mail off says nothing is revoked at Google (6.8.2); a notification shows the sender and subject (7.10); reply addressing is the engine's, with the "Replying to" line (6.3.3). |
| P-4 | M | **Fixed.** Text bodies come from `MailText`; the forbidden calls are forbidden in the UI's folders too; every link goes through one rule (6.2.5, 6.2.7, 6.2.10). |
| P-5 | M | **Fixed.** The warning sheet, long-press on a link, and a `mailto:` composer that shows To and Subject (6.2.7, 6.3.1). |
| P-13 | M | **Fixed.** The address beside an unknown sender's name; a Reply-To said on the message and in the composer; chips by address for people never written to; "from their mail" in autocomplete (6.2.3, 6.3.3, 10.6). |
| P-16 | M | **Fixed, on the screens' side.** The quote and signature are sent as shown, removable, or made plain text; forwarding a program asks; Settings says when a draft reaches Gmail (6.3.4, 6.3.5, 6.8.1). |

Minor, and fixed: P-18 (what a notification shows, what needs an unlock, when it is
withdrawn; 7.10) and P-22 (an invitation is answered only on the event the calendar finds by
the invitation's own identifier; no calendar file is parsed and nothing is matched by title;
9.1).

**The performance review**

| | | Outcome |
|---|---|---|
| R-1 | B | The engine's. The screens' half: bodies are read ready-made, nothing is prepared at open (6.2.5, 8.1). |
| R-2 | B | **Fixed.** The host was P1's to decide, and P1 has decided it: the native collection view, measured, with the Mac's half still to run (6.1.8); one list model; `listApply` budgeted at 400 and 2,000 rows (6.1.7, 8.1). |
| R-8 | M | **Fixed** in what the screens say about a first sync on a phone (7.1, 6.9). |

R-20 (minor) is G15: every route runs with mail's network off.

**The reuse review, the screens' rows** — all adopted (11.4): typed times through
`EventPhrase.takeDate` (B-9); the engine's one tokenizer, no `MailQueryRanges` (B-10); the
system's editor (B-11); Quick Look and the system pickers (B-12); no `MailNativeText`, no
second `MailLink`, no UI-side reply rules, `SnapshotLoader` for the heights file.

**The verification pass** (`mail-working/review/engineering-verify.md`, its T-changes). The
contract changes it proposed are made on the engine's side in the form it gave; this
document is written to them. Every change with a place in this document is applied; none is
declined.

| | Applied in |
|---|---|
| T1 | 12.6: the five requests and the burst are met; no workaround remains. |
| T2 · T30 · T60 | 2.4: chips draw `splitCounts[id].total`; what the badge counts; the badge is read through `MailBadgeCounts.mirrored(in:)` (also 12.3, 14.3). |
| T3 · T15 · T23 · T24 · T25 · T47 | 6.3.3–6.3.9: `MailDraftPart` and its calls; `fromTheirMail`; `encodedBytes` against `MailTuning.maxEncodedBytes`; an untouched composer discards its draft; a save that fails is said; the composer sends with `hold: nil`. |
| T4 · T5 | 8.1, 11.2: the five-second checks are the engine's. |
| T6 · T7 | This section. |
| T8 · T9 · T12 | 12.3, 12.4: the composer's, the conversation's, Settings' and search's calls are named. |
| T10 | T17: a kept row is `MailRowRules`' `leaves(MailRow)`. |
| T11 | T36, 7.6, 12.3, 13.2: refused changes are `status.value.refused`, one per action, and not rows of Outbox. |
| T13 · T14 | 6.1.1, 7.6: `asking` carries its kind; `held(until:)` is the row that offers Undo. |
| T16 | 7.2, 8.4, 13.3: `line(_ status:, accounts:, now:)`; row 12 is the session's; row 14 does not say "checking". |
| T17 | No change needed: row 13 of 7.2 and case 30 already match the meaning the engine now gives `waitingChanges`. |
| T20 | G14, K12: `MailUILog`; no engine type is named. |
| T21 | 6.2.3, 9.2, 11.4: `gmailURL`. |
| T22 | 6.8.1, 7.10: the notification choices are the engine's fields. |
| T26 | 6.5.3: `newestIsMine` is the conversation's; not offered with several targets. |
| T27 | 6.1.1, 7.6, 13.2: a send that has waited more than a day asks; fixture `stale-send`. |
| T28 | T26, T30, 7.9: undoing a send awaits `cancelSend`; one toast when nothing can be undone. |
| T29 | 6.2.7: `MailLinkRules.decide` for a text body, `decideLink(_:in:)` for a designed one. |
| T31 | 6.4.3, G6, 12.5: recent searches are in memory for the session — the coordinator's ruling. |
| T32 | 6.8.1: 4 GB on an iPhone, 8 GB on an iPad. |
| T33 | Section 0, 6.2.5, 6.4, 6.6, 13.1, 13.2: the four places; `rule`; `noReply`; Outbox counted by the contract's rule; the coverage line; `preparing` and `tooLarge`. |
| T52 · T59 | 12.1, 14.2: the contract's defaults instead of stubs; the fixture source may name the engine's pure rules. |
| T61 | 13.2: a custom split is empty on both sources until the engine's query rules exist. |
| T62 | No change needed: this document names no Mac app delegate. |
| T66 | 13.2, 14.2: fixtures are added through the engine's registry; the UI has one of its own, `MailSession+Parts.swift`. |

From the dry run of U0′ and the plan's table: which members U0′ implements, its own mapping
to a row and the test that holds it to the engine's, and acceptance on the in-memory source
before the engine exists (12.1, 14.2, 14.3); the mailbox's device part (13.2); the window
stays, since P1 ran with it (6.1.7); a first sync on a Mac is "about two days" (7.1); an
invitation's answer is described as the week view behaves (9.1); a notification's tap has an
entry point (7.10, 14.3). The coordinator's rulings: one implementer at a time and one commit
a package, with no lock and no guard (14.2); `ScreensOpenUITest` in Release is the owner's
device run, and small type-erased view types are a review item (G13, 8.5, 13.4); the three
partial declines above stand.

**The review of the triage model** (`mail-working/review/pkg-U3.md`): the first UI package
was built from section 3 and checked against it. All forty worked cases held as written; no
ruling contradicts one. Cases 17 and 36 are reworded to say what is drawn, and cases 41–51
pin what the text had left open. The rulings, accepted as product decisions:

| | Ruling | Written into |
|---|---|---|
| (a) | The first `⇧J` or `⇧K` sets the anchor and moves. | T21; case 41 |
| (b) | A list with rows always has a cursor, on the nearest row, unless an open conversation has left it. | T2, T6, T13 |
| (c) | A list covered by an open conversation is at rest. Case 27 stands. | Section 0, T7, T11 |
| (d) | Arrivals into an emptied list wait, and the chip shows over the empty state. | T9, 7.8; cases 36, 44 |
| (e) | A kept row is dimmed once a reading omits it. | T17, 6.1.1; case 17 |
| (f) | For Send and Done the composer pushes the entry and the model hands it the screen half; after the hold, undo reverses the Done alone. | T25, T28, T38; case 51 |
| (g) | The toast's words: descriptions, plurals, grouped numbers, a bounded subject, a label taken off, four store errors, no placeholder. | 7.9 |
| (h) | `Tab` changes the split only. | T31, 4.2.5; case 50 |
| — | T0 step 3 cites T4 for the view. | T0 |

What its findings imply, as rules:

| | Rule | Written into |
|---|---|---|
| P-1 | A reading he asked for applies at once; only a change from elsewhere waits. Rows after the last row shown are appended at once. Growth is asked once a step. | T7, 6.1.7; case 46 |
| P-2 | Undo closes a conversation opened since, when none was open then. | T26; case 42 |
| P-3 | Undo's rows come from the entry, in the same turn, and an older reading cannot take them back. | T26; case 43 |
| P-4 | As ruling (f). | T38 |
| P-5 | Entering a place does not make the list at rest. | Section 0, T3; case 45 |
| P-6 | As ruling (d). | T9 |
| P-7 | A position is a row's key and whole points. | T46, 3.11, 6.1.7, 6.1.8; case 47 |

The minors, each decided:

| | Decided as | Where |
|---|---|---|
| P-8 | The model's choice: how it finds a row is its own; the budgets are 8.1's. | — |
| P-9 | A rule: a filter turned on shows the carried cursor, not the top. | T32; case 48 |
| P-10 | A rule: Done on a snoozed conversation ends the snooze; "changes nothing" is the row rule's answer. | T16 |
| P-11 | A rule: "changes nothing" is never decided for a selection by scope. | T16 |
| P-12 | A rule: a row is in a selection by scope by its key in the newest reading, and the count leaves out waiting arrivals. | T22 |
| P-13 | A rule: read-by-opening marks what has been on screen; a later message after its own 400 ms. | T10, T45 |
| P-14 | A rule: a live run is fixed to its rows when rows change under it. | T24 |
| P-15 | A rule: as ruling (e), and a reading that includes a kept row un-keeps it. | T17 |
| P-16 | A rule: as ruling (b). | T2, T6 |
| P-17 | A rule: in an open conversation `U` always means "leave unread and go back". | T17; case 49 |
| P-18 | Rules: as ruling (g); "Restored", not "back in the inbox", after Restore; no Retry when the day's limit was reached; a Done that leaves an unseen reply says so; the device's name and a time's words are handed in; one subject cleaner. | 7.9, 7.6, T36 |
| P-19 | An action that names a row that has left is still sent: a rule (T16). A conversation Undo reopens unread starts its 400 ms: a rule (T10). Refusing a stale reading by raising the floor with each receipt, and counting arrivals when the first rows are held ones: the model's choice, to be covered by its tests. | T16, T10 |

**The list prototype** (`mail-working/prototypes/p1-list/RESULTS.md`): the native collection
view passed every positional test on the iPhone Simulator, and SwiftUI's `List` and
`LazyVStack` failed. 6.1.8 records the result and what it requires of U4a's host; the Mac's
half is still to be measured, at the owner's Mac.

**The second review of the triage model** (`mail-working/review/pkg-U3-fixes.md`): the model
was fixed to the rules above and cases 41–51 pass. Where the text and the code still
disagreed, the reviewer ruled, and the text moved:

| | Ruling | Written into |
|---|---|---|
| T16 | "Changes nothing" compares the rows with the pending mark aside; an action a row cannot wholly show is never nothing; Done on an unread conversation outside the inbox marks it read and is sent. | T16; case 20, now "not in the inbox, and read" |
| 3.11 | The model works out which readings its own actions caused. The session states the two things the model cannot know: which reading answers an entry (never a cached page), and that a check he asked for has finished. | 3.11, "What the session must tell the model"; cases 53, 54 |
| M-1 | Growing is decided from the reading's count, not from the rows on screen. | 6.1.7; case 52 |
| — | Three things the model needs of the host. | 6.1.8 |

**The owner's rulings** (6 Oct 2026; his words are in section 1). Where they left something
open, it was decided here, and the last column says so.

| | Ruling | Written into | Decided here, where he left it open |
|---|---|---|---|
| 1 | The Mac first; mobile from the start. | 6 (intro), 6.1.3, 11.1, 14.2, 14.3 | The phone's bottom slot keeps a fallback until P4 has run, so no screen waits for it. |
| 2 | A reading pane as an option; three or four columns. | Section 1, 2.3, 3.12, 4.2, 5.1, 6.0, 6.1.2, 6.2.2, 6.3, 6.4.1, 6.6, 6.10, 8, 13.1 | The widths and the order of dropping (6.0.2). All three options on by default. The pane follows a single press at once and a held key after 150 ms. Read: 400 ms open, two seconds showing. Keys ⌥⌘S, ⌥⌘P, ⌥⌘I. What "enrichment" is in a first version. Where the control column lives is put to him, with A recommended (6.0.6). |
| 3 | Superhuman's model: "Ok." | — | — |
| 4 | A sync limit, six months by default; local and cloud search merged. | 6.8.1, 6.1.7, 6.2.11, 6.4, 7.1, 7.3, 7.8, 12.6 | Gmail's results join below the device's with no heading, told apart by one glyph. A list that ends at the limit offers "Get older from Gmail". What the limit keeps is the engine's rule (its 5.4): per device; claims and recent attention kept, the inbox as such not; a conversation whole or not at all. |
| 5 | Send later and Remind me if no reply in the first release. | 6.3, 6.3.6, 6.5, 6.5.5, 7.7, 11, 13.2, 14.3 | Built on the fake before the live probes; every statement of their limits kept. |
| 6 | Pictures at four levels. | 6.2.6, 6.8.1, 12.6 | The sender and domain levels only for a sender Gmail authenticated. "Everyone" asks once. Trackers are a separate switch, on — put to him. |
| 7, 8 | The two packages and the performance commits approved. | MAIL-PLAN section 8 | — |

Three earlier statements in this table are superseded by these rulings and are left as they
were written: section 11's "no reading pane" (withdrawn); P-1's "'Always from' an
authenticated domain only" (now four levels, the sender and domain levels still only for an
authenticated sender); and U-4's "built after the first release" (now in it). U-1's and
R-2's one list model is unaffected by the columns.
