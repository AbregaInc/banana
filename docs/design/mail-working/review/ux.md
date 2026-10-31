# Review of MAIL-UX.md

5 Oct 2026. Independent review of `docs/design/MAIL-UX.md` (all 3,459 lines), read against the
research (`research/product-ux.md`), `DESIGN-SYSTEM.md`, `ADAPTIVE-LAYOUT.md`, `IA-2026-09.md`,
`Shared/BananaDesign.swift`, `NotesView.swift`, `PodcastsView.swift`, `MacCommandCenter.swift`,
`RootView.swift` (the shell), and `MAIL-ENGINE.md` sections 1, 2, 12, 13, 14, 20 and 22.
Nothing in the repository was changed and nothing was run.

**Counts:** 5 BLOCKER · 21 MAJOR · 14 MINOR.

**How sure each claim is.** Claims about what the spec says are quoted with line numbers.
Claims about what SwiftUI, iOS 26 or macOS will do were not run here; where a finding rests on
one, it names the prototype that settles it (P1–P6, listed under "Buildability"). Three screens
were checked on Mobbin — two of Superhuman, one of Apple Mail — and are linked where used.

Line numbers are MAIL-UX.md's unless a file is named.

---

## Findings, most severe first

### U-1 · BLOCKER · The list promises four kinds of positional stability that SwiftUI `List` has no mechanism for, and the document specifies two different lists

- **Where:** T3, T9, T11, T26 (lines 258–262, 295–300, 309–311, 394–400); 6.1.7–6.1.8
  (1091–1125); 8.4 (2204–2206); 12.4 `observeList` (2802); 12.7 X5 (2934); engine 13.2
  (`MAIL-ENGINE.md` 2445, 2457) and its section 22 (3432).
- **Problem:**
  1. *Two lists.* Sections 6.1.7, 6.1.8, 11, 12.4, 13.2 and the performance lines of U3 and U4
     describe a list that grows 100 rows at a time to 5,000 and then says "Older conversations
     are in search." Row X5 of 12.7 gives that up ("A sliding window is better; the 5,000-row
     foot goes") and the engine has since confirmed "a sliding window of at most 400 rows". The
     implementer of U4 reads section 6 and builds the first list; U18 has to fit the second.
  2. *Neither can be built as written on the chosen control.* 6.1.8 fixes the control: "The
     list is a `List` (swipe actions need it)". The spec then requires that:
     - no row on screen moves when rows are added above it (T9);
     - the list returns to "the recorded first row at the recorded offset, within one point"
       after undo (T26), after closing a conversation in the regular arrangement, where "the
       surface is replaced" (T11, 5.3), and after ⌘1/⌘2, where the Mac rebuilds a section's view;
     - the first frame after the 2.5-second background discard shows "exactly what was
       showing" and "never a blank list followed by rows" (8.4);
     - under X5, pages are dropped and added above the viewport as the window slides.

     `List` offers a jump to a row id through `ScrollViewReader` (row precision, and only after
     the first layout, so one frame at the top is drawn first) and nothing else. It has no way
     to set an offset and no compensation when rows are inserted or removed above the viewport:
     the collection view underneath keeps its offset, so the visible rows shift by the height
     that was inserted.
- **Evidence:** T9 "no row on screen moves"; T26 "within one point"; 8.4 "Never a blank list
  followed by rows"; 6.1.8 "The list is a `List`"; X5 as quoted.
- **Smallest change:**
  1. Decide the list once, in section 6, and delete the other description.
  2. Take the insert-above case off the screen: T9's second branch becomes "arrivals are held
     out of the rows and counted in the chip; they join the list the next time its first row
     is on screen." `MailListProjection` already holds outside changes until rest; this is the
     same hold with a second condition.
  3. In the regular arrangement keep the list mounted under an open conversation instead of
     replacing it, and keep Mail's view alive across ⌘-number switches with its observation
     stopped (G10). That removes restoration from the two commonest cases.
  4. Change T11 and T26 to "the recorded first row is the first row" unless the prototype
     shows an offset can be set.
  5. Gate U4 on prototype P1 (see "Prototypes" below). If `List` fails it — I expect it to —
     host the rows in a `UICollectionView` list (which has the system's leading and trailing
     swipe actions) and an `NSTableView`, with each row still a SwiftUI view. That is the
     approach that will hold, and every rule in section 3 survives it.

### U-2 · BLOCKER · The rules give contradictory answers in six places, including what Esc does

- **Where:** T0 against T17 (229–238, 347–354); T11 against T23 and K9 (309–311, 380–382,
  605–608); T23 against T16 step 2 (339); T32 against K9 (431–432); T14 and T25 against O7 and
  9.1 (330, 388, 87, 2266–2271); T24 against T22 and E4 (375–384, 2538–2540).
- **Problem:** each of these is a test that fails whichever way it is written.
  1. `S` on the cursor row. T0 step 2 moves the cursor "to the nearest conversation … that was
     not a target" for *every* action. T17 says a marking action changes "not the cursor". T0
     as written is T16; it does not govern marking.
  2. Select three rows, open one, press Esc. T11: the list is shown. T23: "Esc with a
     selection clears it and does nothing else." K9: clear the selection, *then* close the
     conversation. So the first Esc in the reader does nothing a person can see.
  3. The same state, press `E`. T23: the selection is kept and the action "act[s] on that
     conversation only". T16 step 2: "The selection is cleared."
  4. Search results with the Unread filter on, press Esc. T32: clear the filters. K9: leave
     search first.
  5. `I` then `Y`. T14 calls it a marking action. T25 says every marking action except
     reading-by-opening pushes an undo entry. O7 and 9.1 say its Undo is the calendar's and is
     deliberately not Mail's.
  6. ⌘⇧A shows "12 selected"; a message arrives; `E`. T24: an outside change never alters the
     selection. E4: the scope is "resolved by the engine at the moment of the call". Thirteen
     conversations are marked Done.
- **Evidence:** the rules as quoted.
- **Smallest change:**
  - T0 claims only what is true of every action — Apply and Remember — and says "Settle: T16
    for a disposing action; nothing for a marking one."
  - K9's order becomes: close a picker → close the open conversation → clear the selection →
    leave search → clear filters. T23 drops "and does nothing else"; T32 drops its Esc
    sentence. K9 is the only Esc rule.
  - T16 step 2: "The selection is cleared when the selection was the target."
  - T14 gains a third row for actions that belong to another feature (see U-9).
  - T22 and T24: the scope carries an upper bound (see U-10).

### U-3 · BLOCKER · Keys typed between a compose key and the caret appearing are carried out as triage commands

- **Where:** K2 (572–578), K10 (610–613), T38 (457–460), 6.3.9 (1452–1453), 8.1 "Composer
  open, caret blinking · Next frame · 100 ms" (2146); `MacCommandCenter.swift:136`.
- **Problem:** K2 decides that the person is typing from one fact: the first responder is
  text. After `R`, `F`, `Enter` (reply), `C`, `/`, ⌘F, `G` `L` and each picker's key, the text
  view becomes first responder only once SwiftUI has built it and AppKit has focused it. That
  is one to several frames, and the spec's own ceiling is 100 ms. A key in that gap is resolved
  as a Mail key. A reply that begins "Sure" stars the conversation. One that begins "Each" or
  "Excellent" marks it Done, opens the next conversation, and types the rest into nothing. "Hi"
  opens the Snooze picker. After `/`, the `v` of "invoice" opens the Move picker. T18 promises
  that an action key is never dropped; nothing promises that a letter is never misread.
  Superhuman does not fail this way, and this is the most-used path in the product with a
  destructive result.

  The second half of the same rule: K10 gives the keys back when "a row or the reader's
  background" is clicked. If SwiftUI's selectable text counts as an `NSText` (to be checked),
  clicking a message's text puts Mail in the Typing scope and the single keys stop. On an iPad
  the `MailKeyHost` loses focus to a tapped web body in the same way.
- **Evidence:** K2's table: "Typing — True when: The first responder is text"; `MailSession.focus`
  has two values, `.list` and `.reader`.
- **Smallest change:**
  - K2: Typing is true when an *editable* text view is first responder, **or when Mail has
    asked for one and it has not appeared yet.**
  - Add **K12, type-ahead:** "After a key that opens a text field, every later key press is
    delivered to that field, in order, even if it arrives before the field exists. None is
    resolved as a Mail key."
  - K10: selecting text in a message never takes the single keys away.
  - Tests in U5 and U9: `R` followed by "Each" at 5 ms intervals types "Each" and marks nothing
    Done; click in a message body, then `J` moves the cursor.

### U-4 · BLOCKER · A message scheduled from a laptop is late by design, and at 8:05 no device says so

- **Where:** 6.5.5 (1656–1678), 6.1.1 reason lines (950), 7.6 (2028), 7.7 (2053–2066), O8, O12,
  D9; engine 7.6 (`MAIL-ENGINE.md` 1750–1783), its D8 and its section 22 row X9.
- **Problem:** scheduling a message and closing the laptop is what Send later is for. Under
  the spec's rule the message then cannot go at 8:00. Walk-through (e) at 8:05, phone in hand:
  - No notification. 7.7's notification is only for "a phone that owns a scheduled message".
  - No badge.
  - If he looks, the row reads "Sends Thu 8 AM · from the owner's Mac" and the card "Scheduled ·
    Thu 8 AM · from the owner's Mac": future tense about a time that has passed. A device that is
    not the owner has no late state.
  - Getting it sent is five taps — Mail, ≡ at the top-leading corner, Outbox, the row, Send
    from here instead — if he thinks to look. What that button does once the time has passed
    is not stated ("The time is kept").
  - Left alone, the Mac sends it whenever it is next opened — 40 minutes or four days late —
    without asking. The two documents disagree on when to ask: this one never by default, with
    a switch for 30 minutes; the engine after 24 hours.
  - The other-device card depends on Gmail keeping two custom headers on a draft, which the
    engine marks UNVERIFIED. If Gmail drops them the phone shows an ordinary draft.

  Superhuman: three keys, sent at 8:00, nothing afterwards.
- **Evidence:** 7.7 "On a phone that owns a scheduled message…"; engine 7.6 "UNVERIFIED: that
  Gmail keeps unknown headers on a draft."
- **Smallest change:**
  1. Every device that knows of the schedule gets the late state: after the due time the row
     reads "Was due 8 AM · waiting for the owner's Mac" in warning, the card offers **Send from this
     iPhone now**, it counts in Mail's badge, and the device posts 7.7's notification at due + 5
     minutes, withdrawn if a sync sees the message sent. The action checks that the draft still
     exists before taking it over, so a notification that turns out wrong costs nothing.
  2. One late rule and no setting: up to 30 minutes late it goes and says so; later, it asks.
     It can only be late when he has just opened the device, so the question costs one click,
     and a late send is the one thing that cannot be taken back.
  3. A late message that does go gets the ordinary undo hold and a toast ("Sending “Q3 numbers”
     · was due 8 AM · Undo") when Mail is in front.
  4. "Send from here instead" after the due time sends now, through the hold. Say so.
  5. Before D9 goes to the owner, run the engine's probe W4 and one more: a draft deleted and sent
     in the same instant. If Gmail spends a draft atomically, any device that runs after the
     due time can take a late message over by the same delete-then-create the button uses, and
     walk-through (e) ends with the phone sending it the moment Banana is opened.
  6. Show him this as three pictures — the picker's footer, the 8:05 lock screen, the late
     card — not as a sentence in a table.

### U-5 · BLOCKER · The reader's body cannot be built as specified

- **Where:** 6.2.4 (1216–1226), 6.2.5 (1228–1271), 6.2.7 (1294–1302), 12.3 `MailBody` (2641–2645),
  13.2 fixture `big-image` (3076), 12.7 X1 (2930).
- **Problem:**
  1. "`Text` over an `AttributedString` … selectable." On iOS and iPadOS, text selection on a
     `Text` offers Copy and Share for the whole text; a range cannot be selected (so Apple's
     documentation of `textSelection` says; P3 confirms it on iOS 26.1). On the phone he could
     not copy one tracking number, one address
     or one sentence out of a message between people. There are no data detectors either:
     phone numbers, addresses and dates stay inert.
  2. The native kind is defined to include "lists, quoted blocks", and by the `big-image`
     fixture an inline image. One `Text` draws none of them: it ignores paragraph-level
     structure (no hanging indent, no quote bar) and cannot hold a sized picture. "Native" is
     therefore a stack of block views, and selection then stops at each block, on the Mac too.
  3. "A pool of two (one showing, one being prepared for the next conversation)" contradicts
     6.2.4, "Every unread message is open", and `⇧O`. A thread with three unread designed
     messages needs three web views at once. Inside a `LazyVStack` they would also be created
     and destroyed during scrolling, each time replaying the placeholder.
  4. Until a web body paints, "the frame shows the message's plain text in native type". Every
     designed message therefore changes from one layout to another 150–300 ms after it opens.
     That is a jump inside the frame, on every `J` through Other.
  5. A recorded height is keyed by message and width only. It is wrong after pictures arrive
     (fetched on open by default, D6), after Show pictures, and after a text-size change (10.1
     zooms web bodies).
- **Evidence:** as quoted; X1's own cost line: "more than one web view can exist (a pool of
  two; a thread of several designed messages is rare)".
- **Smallest change:**
  - Native bodies: one self-sizing TextKit view per message (`UITextView` / `NSTextView`, not
    scrollable, not editable), given attributed text prepared off the main thread, with its
    measured height recorded as web heights are. It provides range selection, data detectors,
    lists, quotes and inline pictures in one view. Nothing else in 6.2 changes.
  - Web bodies: one web view per *open* designed message, created when its card nears the
    viewport, with a cap (six, say) beyond which a card reads "Show this message".
  - Placeholder: an empty paper card at the recorded height. The plain text stays for
    VoiceOver and for a body that never paints.
  - Height key: message, width bucket, text size, pictures shown.
  - The reader is a `VStack` in a `ScrollView`, not a `LazyVStack`. Forty folded rows cost
    nothing, positions are exact, and `N`, `P` and "first unread" land where they should.
  - Prototype P3 before U6.

### U-6 · MAJOR · On the iPhone the list has three bars at the bottom, and the one that "never moves" moves

- **Where:** 6.1.3 (1016–1060), 5.2 `MailBottomBar` (887), O6 (86); `RootView.swift:489–490`.
- **Problem:** the shell shows a now-playing bar on every tab whenever an episode is loaded
  (`tabViewBottomAccessory`) and collapses the tab bar on scroll
  (`tabBarMinimizeBehavior(.onScrollDown)`). The wireframe draws neither. With an episode
  loaded, the bottom of the Mail list is: the toast, Mail's bar (52 pt), the now-playing bar,
  the tab bar. That is about 190 pt of chrome and about seven rows, not "about eight … nine".
  Because Mail's bar is a safe-area inset inside the tab, it slides down when the tab bar
  collapses and up when it expands. Search, Compose and, while selecting, Done · Snooze · Label
  · More change height under the thumb during a scroll. A `.bar` strip with a hairline, above
  iOS 26's two floating glass bars, is also a third visual idiom. In a conversation "the tab
  bar is hidden"; nothing in the app hides the tab bar today, so how the now-playing bar and
  the collapsed state behave across that push is unknown.
- **Evidence:** the shell's own comment, "inside a tab the bottom safe area already clears the
  tab bar and the now-playing accessory". Apple Mail's bar of filter, search and compose
  ([Mobbin](https://mobbin.com/screens/eb7804b9-b66c-4e97-aa83-b330e2c43cdd)) is the only bar
  on its screen; that app has no tab bar.
- **Smallest change:** redraw 6.1.3 with the now-playing bar, tab bar expanded and collapsed,
  and decide from prototype P4 on a phone. Candidates in the spec's terms: (a) the bar's
  contents float as two glass controls with no strip; (b) the slot holds the splits, one
  search button and Compose (see U-7); (c) the tab bar does not collapse on the Mail tab. O6
  should say that "never moves" means "across conversations, within one screen".

### U-7 · MAJOR · The splits, Places and the filter are at the top of the phone, out of one thumb's reach

- **Where:** 2.5 (183–185), 6.1.3 (1050–1059), 6.1.7 (1097); research 0.1 (line 124).
- **Problem:** triage across four splits needs three split changes a session. The chips,
  Places (≡, top-leading, the hardest corner for a right thumb) and the filter menu are all in
  the header. The spec's answer is a row at the foot of a split and the empty state's button.
  Both exist only once he has scrolled to the end or emptied the split; leaving five rows in
  Important means reaching. Outbox, where failed and late messages are listed, is also behind
  ≡. Superhuman's phone app has the split row at the bottom ("Splits are a row at the bottom
  of the inbox; swipe it to see more"), so this is a step back from the app being replaced.
- **Evidence:** 6.1.3's own sentence: "the top is out of a thumb's reach".
- **Smallest change:** on compact, put the split chips in the bottom slot, with Places as the
  first chip, one Search button and Compose; the header keeps the place's name, the filter and
  the status line. Or keep the layout and add the list's counterpart of T42: swiping Mail's
  bar moves to the next or previous split, with a visible page mark. Either goes in the
  picture U-6 asks for.

### U-8 · MAJOR · On touch the undo stack cannot be reached from the list once the toast has gone

- **Where:** O2 (82), T27, T44 (482–483), 6.1.3, 6.7 (1740), 10.2 (2408–2409).
- **Problem:** O2 promises one undo stack on every device. On the phone's list the only door
  to it is a six-second toast. The list's bar holds Search and Compose; More exists only in a
  conversation and while selecting. After a wrong swipe noticed late, or to undo the action
  *before* the last one, he must open some conversation → More → Undo (which then jumps back
  to the list), or long-press a row to start selecting → More. After Undo the toast shows
  nothing, so a second step is never one tap. For VoiceOver, focus is moved to the next row
  and the toast is gone before it can be found.
- **Evidence:** T44: "reachable after the toast has gone from More › Undo".
- **Smallest change:** while the newest entry is under two minutes old, the list's bar shows a
  44-pt Undo button beside Compose (the slot keeps its height). After an undo the toast reads
  "Undone" with the action **Undo previous: Marked Done** when there is one. Rows gain the
  VoiceOver action "Undo last action". Otherwise adopt the research's rule — the toast is the
  undo on touch — and say so.

### U-9 · MAJOR · `Z` does not undo what the toast on screen offers to undo

- **Where:** 4.3, the ⌘Z row (746); T26; O7 (87); 9.1 (2266–2271); 6.8.2 "Mail off for … ·
  Undo" (1823); 6.4.4 split removal (1552–1553); 6.5.5 "This iPhone will send it · Undo"
  (1671); 12.5 `saveSplits` (2906).
- **Problem:** several toasts with Undo are not entries on Mail's stack: an invitation reply
  (the calendar's), a removed split and Mail turned off (kept "for the toast's Undo"), a
  takeover. ⌘Z is ruled "Mail's undo stack; if it is empty, the toast's Undo". So after `I`
  `Y`, with "Accepted · Undo" showing, `Z` brings back whatever was marked Done a minute ago
  and the screen jumps to that list. O7 declined to chain the two undos because "two undo
  systems disagree"; this is that disagreement.
- **Evidence:** the ⌘Z row as quoted; T26 "if another scope is showing, the entry's scope is
  shown".
- **Smallest change:** one rule: "`Z` and ⌘Z do what the showing toast's Undo does; with no
  toast, the top of Mail's stack." Or push an entry for each of these whose undo calls its
  owner's undo. O7's objection then goes, and answering can stay a marking action.

### U-10 · MAJOR · An action can reach mail the screen has never shown

- **Where:** T7, T8(b), T13 (280–293, 317–321), T22, T24, E4 (2538–2540), O11, 12.5
  `MailTarget` (2878–2881).
- **Problem:** the screen lags the store on purpose. T7 holds outside changes while hands are
  busy; T8(b) and T13 hold a new message in the cursor's or the open conversation. A target is
  a conversation id or a scope, resolved against the store when the command is called.
  1. `E` on a conversation whose new reply has arrived and is being held marks the whole
     conversation Done *and read* (O11). The reply is archived unseen. Under T13 the chip "1
     new message" may be off screen when `E` is pressed.
  2. ⌘⇧A, a pause, `E` includes mail that arrived after "12 selected" (U-2, item 6).
  3. Select all in a place that is still downloading acts on a set nobody can state.
- **Evidence:** T8(b): "It updates where it is … the next time changes are applied"; E4
  "resolved by the engine at the moment of the call".
- **Smallest change:** a target carries what had been drawn. Add **T45**: "An action applies
  to the messages that had been drawn. A message that had arrived and had not been drawn keeps
  its conversation in the inbox, or returns it there, unread." `MailTarget` gains the reading
  it was taken from (`appliedThrough`, or the newest drawn message per conversation), and a
  scope gains an upper bound: the first key at the time of selecting. The engine's
  per-message assertions make this cheap. During a first sync the header reads "1,204
  selected · on this iPhone".

### U-11 · MAJOR · New mail entering at the top after 400 ms of rest moves rows under a thumb or a pointer (O1)

- **Where:** O1 (81), T7–T9, 3.9 case 24.
- **Problem:** "at rest" is 400 ms without input. Reading a row and deciding takes one to
  three seconds, so the list is at rest in almost every gap between two triage actions. On
  touch, and with a mouse, the target is a place on the glass, not the cursor. When mail
  arrives with the list at its top, every row moves down one as the thumb comes in, and the
  swipe lands on the row above the one that was read. The toast says "Marked Done" without
  saying what, so the slip is easy to miss. T7 protects a hand that is already moving; it does
  not protect a decision already made. On the keyboard the action is safe (the cursor is a
  conversation) but the cursor row still drops 32 pt under the eye, which the research's rule
  B1.21 forbade.
- **Evidence:** O1's reason: "The cursor is a conversation, not a row number, so a row moving
  cannot cause a wrong action" — true of keys only.
- **Smallest change:** keep O1 for a list that is really idle. Arrivals join the top only
  after three seconds without input, and never while a row is hovered or mid-swipe; sooner
  than that they wait in the chip, which U-1 already makes the general mechanism. A toast
  about one conversation names it: "Marked “Q3 numbers” Done".

### U-12 · MAJOR · Leaning on `J` in an open conversation marks every conversation it passes as read, and nothing can undo it

- **Where:** T10 (304–307), T12 (313–315), T18 and K7 (356–360, 599–600), T25.
- **Problem:** `J` repeats while held. In a conversation it opens the next one "in the same
  frame"; opening marks read "at once" and "is not an undo step". One second on `J` marks
  about thirty conversations read. Only `U` reverses it, one conversation at a time, on
  conversations he would first have to find.
- **Evidence:** the three rules together.
- **Smallest change:** T10: read is marked when the conversation has been showing at rest
  (the spec's own 400 ms), not at open. K7: `J` and `K` repeat in the list only. Passing
  through a conversation then no longer counts as reading it.

### U-13 · MAJOR · Add to plan marks the mail Done before the task is known to exist

- **Where:** T14 (329), 9.2 (2288–2318), T0 ("in one run-loop turn").
- **Problem:** `A` and `B` are disposing actions: the conversation is marked Done in the same
  turn. The other half is a write to Reminders or the calendar. It can ask for permission
  ("choosing Task asks for it there"), be refused, or fail. Nothing says what happens then.
  The mail has left the inbox and the task does not exist — the one failure a triage tool must
  not have.
- **Evidence:** 9.2 step 3 and the paragraph on Reminders access.
- **Smallest change:** 9.2 step 3 runs only once the task or block exists (the reminder write
  is local; the block uses the optimistic create). On failure or refusal nothing is marked
  Done and the toast reads "Couldn't add to your plan: …". When permission is missing, the
  priming sheet comes first and the action follows it. Add both to 3.9.

### U-14 · MAJOR · A message sent offline is promised to go "when you're online"; it goes when that device next runs Banana

- **Where:** 6.3.6 (1427–1428), 6.3.7, 7.2 rows 1–3, 7.6 (2027); engine 7.5 (P29), 12.2.
- **Problem (walk-through b):** the toast reads "Will send when you're online" and the card
  "Waiting to send · goes when you're online". On an iPhone in a pocket after landing, it goes
  when iOS next runs the refresh task or when he opens the app; the engine's words are "often
  within the hour, sometimes much longer, never if Banana was force-quit". On a Mac it needs
  the lid open. The message exists only on that device, so no other device can show it or send
  it. Also:
  - A waiting message's card has no control. Failed has Try again · Edit, Scheduled has ×,
    Waiting has nothing. After two hours on a plane he will want to change it.
  - "Nothing announces success" is right after a ten-second hold and wrong after five hours.
- **Evidence:** the 7.6 table; engine 7.6, "What he will experience".
- **Smallest change:**
  - Copy: "Waiting to send · goes the next time Banana is open and online" on a phone; "…when
    this Mac is online" on a Mac.
  - The waiting card gets **Edit** and **Don't send**.
  - A message that waited more than a minute is confirmed once when it goes ("Sent “Q3
    numbers” · 2:14 PM" in the status line's place; a notification if Banana is not in front).
  - The "still waiting to send" notice covers messages queued offline, on both platforms.
  - Bring the engine's P29 (the final send on a background `URLSession`) into the first
    release, or keep the honest copy.

### U-15 · MAJOR · The first-sync card states Gmail's limit and hides the phone's

- **Where:** 7.1 (1909–1928), 6.9 (1841–1853); engine section 1 (48–53), 12.1, 12.2, invariant 15.
- **Problem:** the card says "About 3 hours to go". The engine says a 100,000-message mailbox
  is "four to seven hours of Google's per-user quota and … about two days", per device, and
  that on iOS nothing of Mail's runs in the background except a short refresh task and an
  overnight task on external power. On a phone the download advances only while Banana is in
  front, or overnight on a charger. An estimate in clock time cannot be true there, and the
  card names Gmail's limit while leaving out the larger one.
- **Evidence:** engine 12.2: "This is how a phone's copy gets complete without being held
  open."
- **Smallest change:** on iPhone and iPad the card's third line reads "Downloads while Banana
  is open, and overnight while charging." Drop the estimate there, or word it as open time.
  The turning-on screen's footnote says the same.

### U-16 · MAJOR · On touch, going to the next conversation without acting on this one is an invisible gesture that iOS 26's back swipe may take

- **Where:** T42 (476–478), 6.2.1 (1164–1166), T12.
- **Problem:** in a conversation on the phone the only way onward without disposing of it is
  to swipe the action bar. Nothing shows that it can be swiped. At the end of the list it does
  nothing at all (T12), which reads as broken. On iOS 26 a rightward drag anywhere in a pushed
  screen also begins the system's back swipe, and a custom horizontal drag on a bar inside
  that screen has to win against it. The owner's notes already record one iOS 26 drag-gesture
  conflict.
- **Evidence:** research B2.11: "it is the only way to skip without going back to the list."
- **Smallest change:** the conversation's navigation bar gets older and newer arrows at its
  trailing edge, disabled at the ends, as Apple Mail has. The bar swipe stays only if
  prototype P4 shows it and the back swipe do not interfere. At an end, the swipe rubber-bands.

### U-17 · MAJOR · The Mac's cursor row loses its date and glyphs; a selected row has no drawing at all

- **Where:** 6.1.2 (993–999; wireframe line 974), T2 (252–256), 3.10 `MailRowMark` (530).
- **Problem:**
  1. The cursor row's "glyph slots and date are replaced by three quick actions". With a
     keyboard some row always has the cursor, and it is the row being decided. It loses when
     it arrived, its star, its attachment and its invitation mark, in exchange for buttons a
     keyboard user does not click. In Superhuman the swap follows the pointer: the
     [cursor row keeps its date](https://mobbin.com/screens/e1f653c9-2997-457a-bea6-2a2707e01fe5)
     and a [hovered row shows the icons](https://mobbin.com/screens/fdcc6981-35ec-4489-b155-142754a66dfd).
  2. How a *selected* row is drawn in the regular arrangement is specified nowhere. 6.1.5
     covers compact only, and the cursor already uses the selection fill, so a cursor inside a
     selection cannot be told from its neighbours. U4 cannot be built without this.
  3. T2 draws the cursor "in the regular arrangement always". On an iPad used by touch one row
     is permanently highlighted, with three buttons and no date.
- **Evidence:** as quoted and linked.
- **Smallest change:** quick actions on hover only; the cursor row keeps every item. A
  selected row in regular: a check in the gutter (compact's rule) and an accent wash at
  `Tint.soft`. The cursor: selection fill and spine. Both can show at once. T2: in regular the
  cursor is drawn once a keyboard or pointer has been used; always on the Mac.

### U-18 · MAJOR · The composer cannot hold Gmail's signature or an edited quote as specified

- **Where:** 6.3.1–6.3.4 (1313, 1396–1403), 12.3 `MailIdentity.signature: AttributedString?`
  (2711), 6.3.2.
- **Problem:**
  1. A Gmail signature is HTML: pictures, tables, colours, links. "Placed under the caret" in
     an `AttributedString` editor it loses its logo and its layout, and what is sent no longer
     matches what Gmail sends.
  2. "Unfolding makes it editable": received HTML turned into editor text and back is lossy.
     A reply to a designed message would re-send a damaged quote.
  3. Compact: "Dragging it to the medium detent shows the thread behind it, which still
     scrolls." With the keyboard up a sheet's medium detent is not available in practice; this
     probably works only once the keyboard is dismissed.
- **Evidence:** as quoted.
- **Smallest change:** the signature and the quote are prepared blocks under the editor,
  joined when the message is built. They are shown read-only (natively when simple, as a
  small web body when not) with **Remove signature** and **Edit quoted text**, which converts
  the quote to plain quoted text and says so. Prototype P6 settles the detent; failing it, the
  rule is "drag down to read; the keyboard goes; tap the body to return".

### U-19 · MAJOR · "Everything is reversible except a message that has left" is not true, and one reversal is missing

- **Where:** T28 (412), T14 (327–330), 4.2.4 ⌘U (685), 7.9 (2104), 6.6 "Create" (1729), 9.1,
  section 11 (2481), 12.5 `notSpam` (2872).
- **Problem:** Unsubscribe cannot be undone, shows no Undo, is not in T14's table at all, and
  sits on ⌘U beside `U`. Whether it also marks the conversation Done, as Superhuman's does, is
  not said. A label created from the picker cannot be deleted in Banana. An invitation reply
  tells the organiser. "Remove here" (7.5) removes thousands of local messages. And one way
  back is missing: there is no "Not spam" or "Restore from Trash" in the map or in ⌘K,
  although `MailChange.notSpam` exists. Checking Spam for a false positive is a weekly job.
- **Evidence:** T28's italic sentence; the Conversation group of 4.5 (784).
- **Smallest change:** T28 lists its exceptions. Unsubscribe is classified as disposing
  (unsubscribe, then Done, with Undo for the Done and a toast that says the unsubscribe
  stands), and as the one irreversible key it takes a second press: ⌘U, then ↵ on "Unsubscribe
  from Stratechery". `⇧E` in Spam and in Trash is "Not spam" and "Restore", named so in ⌘K and
  in the row's menu.

### U-20 · MAJOR · A change Gmail refuses stays applied on the device and is reported where nobody looks (O13)

- **Where:** O13 (93), T36 (445–452), 7.6 (2044–2046), 2.6 (210).
- **Problem:** a refused Done stays applied here while Gmail and every other device keep the
  conversation in the inbox. The notice is a six-second toast, only "if Mail is on screen"; a
  reason line on a row that has just left the list in front of him; and a group in Outbox,
  behind ≡. The tab's badge counts failed sends, not refused changes. The device can disagree
  with Gmail for as long as he does not open Outbox. Superhuman rolls the change back; so did
  the research.
- **Opposite case, the engine's:** what he did must never vanish silently. That is right for
  a message or a draft. For a label change the work is one key, and the truthful notice is the
  conversation reappearing where he triages.
- **Smallest change:** for changes to conversations, the change is reversed on screen at rest
  and the toast offers Retry: "Couldn't mark “Q3 numbers” Done: that label no longer exists ·
  Retry". The engine may keep the intent in Outbox for Retry; the list shows what Gmail has.
  If T36 stays, refused changes count in the Mail badge and raise an alert card.

### U-21 · MAJOR · Undo Send is buried by the next action

- **Where:** 6.3.6–6.3.7 (1415–1440), T25–T28, 7.9.
- **Problem:** the hold is ten seconds and the toast shows only the latest change. Send, then
  `E`, `E` — the ordinary rhythm — and the toast reads "Marked Done". Taking the message back
  now means `Z` three times, bringing two conversations back into the inbox on the way. The
  only action that cannot be reversed afterwards has the hardest undo to reach.
- **Evidence:** 7.9: "The toast shows the latest change".
- **Smallest change:** during the hold, the message's card and its row's reason line carry
  their own Undo ("Sending… · Undo"), and ⌘K lists "Undo send".

### U-22 · MAJOR · A returning snooze can ring for a finished conversation, land in the middle of the list, and come back read

- **Where:** T1 (246–250), 6.1.1 (952), 7.10 (2118), 2.6; engine D10.
- **Problem (walk-through d):**
  1. Snooze notifications are scheduled ahead on each device. Nothing says they are withdrawn
     or re-timed when a sync shows the snooze ended early: a reply came, it was unsnoozed or
     marked Done elsewhere, or it was snoozed again on another device. The new-mail row of
     7.10 has that clause and this row does not. "No reply yet?" can ring for a conversation
     he finished yesterday on the Mac.
  2. A returned conversation sorts by its wake time. If no device ran at 8:00 it appears at
     11:00 beneath three hours of newer mail, not "at the top" as the research had it.
  3. Whether it returns unread is not said. The engine recommends yes. If it returns read, in
     Other, mid-list, only a secondary-colour line marks it, and the badge does not count it.
- **Evidence:** 7.10's two rows side by side.
- **Smallest change:** 7.10: "withdrawn or re-timed when a sync shows the snooze changed."
  Adopt the engine's D10: it returns unread. T1: `sortDate` uses the time this device brought
  it back when that is later than the wake time.

### U-23 · MAJOR · Things the engine reports or decided have no screen, and the contract disagrees with section 6

- **Where:** 7.5, 7.6, 6.8.1, 3.10, T30, 12.3, 12.7; engine section 14 (2659–2662), 13.8, 13.9,
  D3, D6, D10, section 22.
- **Problem:**
  - "Banana couldn't read changes that hadn't been sent yet. 4 were recovered; some may be
    lost." This is the worst state in the product and section 7 has no words and no place for
    it. Likewise `wrongAccount` and an unavailable store.
  - Beta: "a send from Beta is a real send." Nothing on screen marks a Beta composer.
  - Settings offers "Keep on this iPhone: All mail · The last year". The engine keeps header
    and text for everything and bodies, newest first, to a 4 GB ceiling. "All mail on this
    iPhone" (7.3) is then untrue of bodies.
  - T30 still cites "twenty changes for ten minutes"; the engine now keeps fifty groups for a
    day.
  - `MailShellState.cursor` (3.10) against engine 13.8, "Not here: the cursor".
  - 6.9 pre-ticks every connected account; the engine's D6 is opt-in per account.
  - Inside this document: 6.1.1 lists reason lines for a refused change, an unconfirmed send
    and a message scheduled "from the owner's Mac", and `MailRowReason` in 12.3 has no case for
    any of them. `MailDelivery` has no "not sure it was sent" and no owner. `MailEvent` lacks
    the engine's `sendUnconfirmed`. U0 is told to copy 12.3 "verbatim".
- **Evidence:** the engine's table of true things to say, lines 2644–2662.
- **Smallest change:** add the missing rows to 7.5 and 7.6 with their copy and a route each in
  13.3; add the missing cases to 12.3; add one line per item to 12.7 naming which side moves.

### U-24 · MAJOR · The case for taking Notes's tab rests on a fact that is not so

- **Where:** 2.2 (118–122), D1, "Not decisions" (3451–3452); `NotesView.swift:112–128, 228–254`.
- **Problem:** the argument is that Notes is "the one tab whose daily job already happens
  elsewhere … What is left in the tab is reading notes back." The Notes tab's first row is the
  capture card — "Capture a thought" when nothing is playing — and its second is "Write a note
  instead". The tab is where a note is started when no episode is on. Under Library › Notes
  that is two taps, and the summary written for the owner ("Reading notes back goes from one tap
  to two") leaves it out.
- **Evidence:** `NotesView.swift:237`.
- **Smallest change:** D1 says what happens to capture: Library's navigation bar carries the
  capture and write buttons in both segments, or Plan's "…" menu gains New note. He sees the
  new tab bar and the Library screen before he agrees.

### U-25 · MAJOR · The plan meets the real engine last and measures nothing until the end

- **Where:** section 14 (diagram 3173–3183; U18 3406–3415), 8.1 (2133–2134).
- **Problem:** seventeen packages are built on fixtures. The engine arrives in U18, with
  "everything in 12.7 … settled before this starts". Every budget in 8.1 is first measured
  there or in P2. The riskiest parts — the list's host, the key scope, the body renderer, the
  adapter's seventeen differences — are found at the end. Five screens rest on platform
  behaviour nobody has tried, and no package is a prototype.
- **Evidence:** the diagram.
- **Smallest change:** see "Recommended first-release scope and order": six prototypes first,
  a thin U18 on the Mac straight after U6, the phone's seat after that.

### U-26 · MAJOR · Accessibility: capped bars, fixed columns, missing actions, and a keyboard host with no rule

- **Where:** 10.1–10.3 (2385–2434), 5.1 `dateColumn` and `glyphSlot` (849–851), 6.1.1, 4.4.
- **Problem:**
  - "Headers, bars and chips keep their heights; their labels truncate." At accessibility
    sizes the split names, the place's title and the action bar's words stay small. The
    system's answer for a bar that cannot grow is the Large Content Viewer, which is not
    mentioned.
  - One-line rows hold "to the largest standard size", but the date column (72 pt) and the
    glyph slots (20 pt) do not scale. "12 Aug 2024" in body text at the largest standard size
    does not fit 72 pt, and 6.1.1 says the date is never truncated.
  - VoiceOver has no Select action (long-press is the only way into selecting), no Undo
    action (U-8) and no Reply. A row's label reads a long snippet before the date.
  - Split counts and message counts are tertiary: the numbers a triager reads all day are at
    the lowest contrast in the system.
  - iPad by keyboard alone rests on one focusable host keeping focus. A tap in a web body or
    a field closing can leave no view that hears keys, and `Tab` (next split) competes with
    the system's focus key. K10 says focus returns; nothing says how.
  - The Mac: "text does not scale; its row is fixed", and the reader has no zoom. Superhuman
    has ⌘+ and ⌘−.
- **Evidence:** as quoted.
- **Smallest change:** a line each in section 10: Large Content Viewer on every capped
  control; `@ScaledMetric` on the date and glyph columns; actions Select, Reply and Undo; date
  before snippet in the label; counts in secondary; a host rule ("when nothing editable has
  focus, the host has it", re-checked on every focus change) with a UI test; ⌘+, ⌘− and ⌘0
  scale the reader on the Mac.

### U-27 · MINOR · Strings in section 7 that are vague, alarming, falsely reassuring or contradict themselves

| String | Problem | Rewrite |
|---|---|---|
| "Rebuilding mail on this iPhone" (7.2 row 10) | Alarming: no cause, no duration, no assurance. | "Rebuilding the mail index · your mail and unsent changes are safe" |
| "Checked 14 min ago" while the foreground check runs (row 11) | Says stale while it is checking; invites a needless pull. | "Checked 14 min ago · checking" |
| "Couldn't mark “Q3 numbers” Done: Gmail refused it." (7.9) | No reason. | Use the reason, as the batch toast does. |
| "“Q3 numbers” hasn't gone yet" · "…Open Banana to send it." with the action **Send now** (7.7) | The body says to open the app; the action says there is no need. | "…Send it now, or open Banana to change it." |
| "Gmail no longer lists 4,210 messages that are on this Mac" · Remove here · Keep for now (7.5) | He cannot know what they are or what "for now" means. | Add **Show them** (a list), and "Keep for now" says when it asks again. |
| "Not allowed by plan.example" — "No retry, no button." (7.5) | A state with no way out. | Add **Turn Mail off for this account**. |
| "Marked Done" on a conversation that was not in the inbox (T16; search results, All mail) | Says something happened when nothing did. | No toast and no undo entry for a change that changes nothing; the cursor still advances. |
| "On this iPhone back to 12 Aug · Gmail is searching the rest…" (7.3) | About 59 characters in a 28-pt line on a phone. | "Back to 12 Aug here · asking Gmail…" |
| Search with nothing found, still downloading, offline (7.8) | No row for it; the online hint would be false. | "Mail before 12 Aug isn't on this iPhone yet, and you're offline." |
| "Already sent. It can't be unsent." | Longer than needed. | "Already sent." |
| "Notifications can be late." (6.8.1) | Understates: the engine says "typically tens of minutes, sometimes hours". | "On an iPhone that isn't open, often tens of minutes late." |
| "Done · 3 conversations · the label no longer exists" (7.6) | Done involves no label; the example teaches the wrong thing. | Use a Move. |

No spinner was found for anything already on the device. Settings › Storage showing "—" until
a local figure arrives is the nearest case and is acceptable.

### U-28 · MINOR · Cases no rule covers, and rules that cannot be tested as written

- `Space` and `⇧Space` in the list (4.2.2): does the cursor move with the page? T4 covers `J`
  and `K` only.
- ⌘↓ "bottom": the last row loaded, or the last in the place? And the direction afterwards?
- `Tab` from a place that is not a split (Starred). Whether `Tab` skips an empty split.
- `G` keys and filter keys while a conversation is open.
- `R` or `F` with several rows selected.
- `X` on one row after ⌘A: `MailTarget.scope` has no exclusions.
- T21: when the anchor resets; whether an earlier run survives a plain `J`.
- T17: "stays until the list is next entered" — is switching a filter, `Tab` away and back, or
  returning from the background an entry? A row kept after it stops matching needs a named
  set and a rule for when it is cleared.
- T38's Send and Done after the hold: T28 drops the entry, so the Done can no longer be undone.
- `-`, `=` and `T` when the day pane is hidden.
- K8: `#` and `!` are shifted digits on a US keyboard and `#` is ⌥3 on a British one. "The
  Shift flag and the unshifted character" is right for letters and wrong for symbols; symbols
  must match the produced character.
- 6.5: which row is highlighted when the picker opens with nothing typed (so that `H` `↵`
  means something), and the key that toggles the footer's control.
- 6.1.1: a stale draft's reason line hides the snippet of a newer unread message.
- 6.4.3: how a row "from Gmail" looks before its sender and subject have been fetched.
- 6.3.5: forwarding a message whose attachment is not on the device, offline.
- The Calendar split fills with invitations already answered in Plan (O7). A reason line
  "You said Yes" would let them be cleared from the list without opening.
- T26 does not say that undoing Done restores unread; E3 says the engine does. Say it in T26.

### U-29 · MINOR · A stray `I` followed by `N` declines an invitation

- **Where:** K6 (594–597), 4.2.3 (663, 669).
- **Problem:** in a conversation `N` is "next message". `I` starts a 1.5-second prefix, shown
  only at the header's trailing edge. `I`, then `N` meaning "next message", sends No to the
  organiser.
- **Smallest change:** the `I` prefix exists only when the open conversation has an
  unanswered invitation, and its pending state is drawn on the invitation card.

### U-30 · MINOR · On the phone, search leaves room for about two results while typing

- **Where:** 6.4.2 (1487–1504), 6.4.3 (1512).
- **Problem:** with the keyboard up, the field's bar, the chips, the scope line and "up to
  four suggestions" at 44 pt each leave roughly 180 pt for results on a 6.3-inch phone.
- **Smallest change:** on compact, suggestions are chips in the chip row, or at most two rows.

### U-31 · MINOR · "Banana never fetches the ones that exist only to track you" promises more than can be kept

- **Where:** 6.8.1 footnote (1789–1790), 6.2.5 (1259–1261), D6.
- **Problem:** tracking today is mostly a per-recipient address on an ordinary picture. With
  pictures fetched on open and no proxy, every such sender learns the time and his IP
  address. The first sentence of the footnote says so; the second takes it back.
- **Smallest change:** "Banana skips known trackers. Any other picture can still tell its
  sender that you opened the mail, and roughly where." The default is in the decisions table.

### U-32 · MINOR · Turning Mail on means Google's warning and an unticked box, once per account, and the screen does not say so

- **Where:** 6.9 (1848–1861), 6.8.2 (1818–1822); engine D1, D6.
- **Problem:** with the recommended publishing status every account shows Google's
  "unverified app" screen, then a consent screen whose Gmail box must be ticked. With every
  account pre-ticked that is three or four of these in a row, each able to fail silently
  ("the Gmail box was unticked").
- **Smallest change:** tick only the default account. Add one icon row to the priming screen:
  "Google will warn that Banana isn't verified, and ask you to tick Gmail." The not-granted
  line gains "Tick the Gmail box" beside Try again.

### U-33 · MINOR · What only a long press, or knowing Superhuman, reveals

- **Where:** 6.2.1 (1161–1162), 6.3.2 (1364–1366), T39, T42, 6.9 hints (1876–1878).
- **Problem:** on the phone, Send later, Send and Done, Remind me if no reply and Send now
  are all behind a long press on Send. Reply to sender and Forward are behind a long press on
  Reply. Selecting is a long press on a row. The two hints teach `E`, `H`, ⌘K and the two
  swipes and nothing else. The bin sits against Send in the bar above the keyboard.
- **Smallest change:** a clock button in the composer's bar opens the picker (there is room
  beside `Aa`); More lists Forward, Reply to sender, Select and Next conversation; the bin
  moves to the leading end of the bar.

### U-34 · MINOR · The one-line row is starved at the narrow end of "regular", and the day pane takes the width it was promised

- **Where:** 5.1 (847–863), 6.1.2 (985–989, 1008–1012), rule 1 of section 1.
- **Problem:** fixed columns take about 350 pt. At 600 pt the subject and snippet share about
  250 pt: forty characters, no snippet. That is roughly the Mac's default window with the day
  pane open (1120 pt, less the sidebar, less 320), and an 11-inch iPad in landscape, where the
  pane also floats over the dates. On a 27-inch display there is no maximum: the date sits two thousand
  points from the sender.
- **Smallest change:** the row type follows the list's own width — one line from about 720 pt
  — rather than `LayoutClass`'s 600. The list has a maximum width, about 1,100 pt, and the
  rest is margin. The day pane starts hidden.

### U-35 · MINOR · Design-system fit

- `Feature.mail = Color.teal` sits beside `icloud = .cyan` on the Settings root and is the
  same colour as `Macro.carbs`. Choose a hue nothing else has.
- `oneLineRow` under `#if os(macOS)`: ADAPTIVE-LAYOUT's rule 6 allows `#if os` for "what the
  OS can do". "No finger can be the pointer" qualifies, narrowly; `DSCard`, the cited
  precedent, forks a background, not a size. Record it by amending DESIGN-SYSTEM's "Every row
  is at least 44 pt" to "wherever a finger can be the pointer", not as a ruling local to Mail.
- Date groups as eyebrows in main content: DESIGN-SYSTEM reserves the eyebrow for panels and
  grid chrome. Acceptable for a dense list; say so there.
- Mail hosting its own toast is an exception to "features only call `ToastCenter.shared`".
  Record it.
- The regular arrangement on a Mac and on an iPad differ in row height, target size, hover,
  and (after U-17) when the cursor is drawn. All are tokens, so rule 2 holds in letter; the
  spec should list them in one table so the next reader sees what differs.

| Primitive (5.2) | Needed? |
|---|---|
| `DateText` | Yes. No date role exists; screens format dates inline today. |
| `DSChip` | Yes. No chip view exists. Specify the control form (with ×) now: recipients and attachments need it. |
| `Monogram` | Yes; a lift of the account card's avatar. |
| `KeyHintRow` | Yes; a lift of the command menu's footer. |
| `ToastCenter.present` | Yes, after U-9 settles who owns Undo. |
| `MailBottomBar` | Not until U-6's picture exists. |

### U-36 · MINOR · One Undo for thousands of conversations lasts only until iOS evicts the app

- **Where:** T22, 4.5 "Mark everything older than a week Done" (790), 6.9 (1879–1881), T27.
- **Problem:** "It is one action with one Undo." The stack is in memory. On a phone the app
  is evicted routinely, and the engine can still reverse the change for a day.
- **Smallest change:** after a cold launch, More › Undo and ⌘K offer the engine's newest
  reversible groups by their descriptions, without restoring the screen.

### U-37 · MINOR · `Tab` in a conversation will not reach the buttons on a Mac by default

- **Where:** O9 (89), 4.2.3 (668).
- **Problem:** macOS moves `Tab` only between text fields and lists unless Keyboard
  navigation is switched on in System Settings. As written, `Tab` reaches the reply field and
  nothing else, and there is no key that opens an attachment.
- **Smallest change:** the invitation's buttons and the attachment chips are declared
  focusable regardless of that setting. ⌘K lists "Open attachment…" for the open conversation.

### U-38 · MINOR · ⌘F in an open conversation searches all mail, and there is no find within a conversation

- **Where:** 4.2.1 (629), section 11 (2476); research C had "⌘F Find in conversation".
- **Problem:** on a Mac ⌘F means "find in what I am looking at". In a forty-message thread
  there is no way to find a word.
- **Smallest change:** with TextKit bodies (U-5) the system's find works for native messages;
  bind ⌘F to it in a conversation and leave `/` as search. Also check with the owner which Send he
  uses: after ⌘↩ Banana stays in the conversation.

### U-39 · MINOR · Waiting for a sign-in code means waiting for the next poll

- **Where:** 8.1 "New mail on screen · 30 s · 60 s" (2155); engine 12.1 (20 s).
- **Problem:** a code or a link he is waiting for arrives up to twenty seconds late.
  Superhuman has push.
- **Smallest change:** after ⌘R or a pull, and for a minute after Mail comes to the front,
  poll every five seconds. A poll costs two quota units.

### U-40 · MINOR · O4's argument is applied to one decision and not to another

- **Where:** O4 (84), D14, 5.1 (841–845).
- **Problem:** O4 rejects a bottom bar on a touch iPad as "the layout-by-device the app
  forbids", while `oneLineRow` forks by operating system for the same reason: what the
  pointer is.
- **Smallest change:** none to the design; header actions on an iPad are acceptable and match
  Apple Mail. Word O4 as a choice and revisit it after a week on an iPad.

---

## Six choices, argued the other way

**No reading pane (section 1, rule 1).** *The other case:* a pane shows content while `J`
moves, so triage needs no open and no close; nothing is marked read by a glance; the list
never leaves the screen, which removes most of U-1; pointer users get the layout of every
other Mac mail client; and on a wide display there is room for the list, the message and the
day. *Verdict:* the spec is right for this person. His habit is list-or-conversation, and
`J`/`K` in the reader (T12) do the pane's work. It holds on two conditions: opening is truly
next-frame (U-5), and the list stays mounted (U-1). The claim that the spare width goes to the
day needs care: in the default window there is none (U-34).

**Mail takes Notes's tab (D1).** *The other case:* the IA record is a month old and kept Notes
a tab; Notes is a capture surface (U-24); a mail badge visible from every tab brings the inbox
into every visit to log a meal; voice notes made without a podcast are not Library's subject.
*Verdict:* Mail needs a seat, since one-thumb triage does not survive a second tap, and Notes
is the least costly seat — provided capture stays one tap away and he sees the result first.

**System swipe actions only (O3).** *The other case:* a custom gesture keeps the row
half-open while the picker is up, allows two swipe lengths, and frees the list from `List`,
which is where U-1 comes from. *Verdict:* the spec is right; the measured iOS 26 scrolling bug
decides it, and a `UICollectionView` list keeps the system's swipes while curing U-1. Declare
Done's action with the destructive role, tinted `success`, so the row leaves in one motion
instead of snapping back and then collapsing.

**Search in a bottom bar (O5).** *The other case:* pull-to-search is Superhuman's habit; a
permanent bar costs 52 pt on every screen for something used a few dozen times a day; with the
tab bar and the now-playing bar it is a third strip (U-6); results sit above a keyboard with
little room (U-30). *Verdict:* the bottom is right — it is the iOS 26 idiom and within reach —
and "pull means check mail, nothing else" is right. Make it a control in one strip, not a
strip of its own.

**New mail enters at the top of an idle list (O1).** *The other case* is U-11. *Verdict:*
right for the keyboard and for a list that is really idle; wrong at 400 ms for a thumb or a
pointer. Three seconds, and never under a hover or a swipe.

**Done always marks read (O11).** *The other case:* unread is his own mark; some people keep
archived mail unread as "read later"; Done from a notification marks unseen mail read; a mass
Done marks thousands read; a switch is cheap. *Verdict:* right for someone who works from what
is left. Two conditions: undo restores unread (say it in T26), and T45 (U-10) so Done never
marks read a message that was not drawn.

### The other overrulings, briefly

| # | Verdict |
|---|---|
| O2 one undo stack everywhere | Right in principle; not delivered on touch (U-8). |
| O4 no bottom bar on a touch iPad | Acceptable; the argument is inconsistent (U-40). |
| O6 one bottom slot | Right as a rule; wrong as drawn in this shell (U-6). |
| O7 answering does not mark Done | Right result, wrong reason: fix the undo rule (U-9) and show the answer on the row (U-28). |
| O8 one late rule, not per message | Right; better still with no setting (U-4). |
| O9 `Tab` is the system's key | Acceptable with U-37. |
| O10 snippets and formatting out | Acceptable; find-in-conversation should come back (U-38); snippets is a question for him. |
| O12 only the owner sends | The engine's rule; revisit after W4 (U-4). |
| O13 a refused change is kept | Right for messages, wrong for label changes (U-20). |

---

## Buildability, behaviour by behaviour

| Behaviour | Stated approach | Will it hold? | What would | Prototype |
|---|---|---|---|---|
| A windowed list that keeps its place when rows are inserted above | SwiftUI `List`; window per X5 | No (U-1). | Hold arrivals in the chip; a `UICollectionView` / `NSTableView` host with SwiftUI rows. | P1 |
| A cursor that moves under a held key without re-evaluating the list | One small observable per row; scrolling as an effect from the model | Yes. It is the app's `PlaybackClock` pattern, and a scroll-to per repeat is cheap. | — | part of P1 |
| Rows at 32 pt on the Mac | Fixed row height; the whole row is the target | Yes. Needs the selected and cursor drawings (U-17). | — | — |
| A bottom bar shared by three modes | A safe-area inset per screen, toast hosted inside | Partly. It moves when the tab bar collapses, stacks on the now-playing bar, and needs the app's first hidden tab bar (U-6). | One strip, decided on a device. | P4 |
| Per-message bodies, native and web, with heights known | `Text`; a pool of two web views; a height cache | No, as written (U-5). | TextKit bodies; a web view per open designed message; a fuller height key; boxes reserved from each picture's width and height when the document is prepared. | P3 |
| A composer in the same frame as the key press | Model built synchronously; SwiftUI editor | The card, yes. Focus in the same frame is not guaranteed, hence U-3. Signature and quote need U-18. | K12; prepared blocks. | P2, P6 |
| State across the 2.5-second discard | Models in `MailSession`; `cursor` and `top` stamped on backgrounding | Models and composer text, yes. The list's offset, no, with `List` (U-1). Web bodies are rebuilt and repaint on every return. | The list host; empty paper placeholders. | P1, P3 |
| The iPad's key host | `.focusable()` and `.onKeyPress` | Unproven (U-26). | A focus rule and a UI test. | P2 |

### Prototypes that settle these before a screen is built

| | What it is | What it answers |
|---|---|---|
| P1 | The 5,200-row fixture in `List`, on a phone and a Mac, Release. Prepend three rows at depth 50; rebuild the tree at row 137; slide a 400-row window; hold `J`; full swipes. | Whether `List` can stay. Measure the marked row's position frame by frame. |
| P2 | The key monitor with a scope decided by intent, and a type-ahead buffer. `R` then "Each" at 5 ms. Click in selectable text and in a web body, then `J`. The same on an iPad with `Tab`. | U-3 and the iPad host. |
| P3 | `forty` with `⇧O`, `plain-chain`, `big-image`, three unread `newsletter`s, with TextKit bodies and per-message web views, on a phone. | `mail.open`, memory with six web views, jumps while scrolling up. |
| P4 | Mail's bar on a phone with an episode loaded: tab bar expanded, collapsed, and hidden in a conversation; the bar swipe against the back swipe. | U-6, U-7, U-16. |
| P5 | The engine's W4, plus a draft deleted and sent at the same instant. | Whether any device may take over a late scheduled message (U-4). |
| P6 | A Gmail signature with a picture and a quoted newsletter through the editor and back; the reply sheet's detents with the keyboard up. | U-18. |

---

## The five walk-throughs

Counts are for the core path. "SH" is Superhuman, by the research's account of it.

### (a) Morning triage: 40 conversations, two accounts

Assumed mix: 28 Done from the list, 6 opened then Done, 3 snoozed, 3 quick replies, 3 split
changes, 1 accidental Done.

| Step | Rule | Mac | iPhone | Issue |
|---|---|---|---|---|
| Enter Mail | T3, 8.4 | ⌘2 · 1 | Mail tab · 1 | After a section switch or the discard the list's position is not restorable (U-1). |
| Done from the list ×28 | T16, T18 | `E` · 1 each | Full swipe left · 1 each | Same as SH. |
| Open, read, Done ×6 | T10, T16 step 4 | `↵`, `E` · 2 | Tap, Done · 2 | Same as SH. Held `J` hazard (U-12). |
| Snooze ×3 | T40, 6.5 | `H`, a row or phrase, `↵` · 3–5 | Swipe right, a preset · 2 | Same as SH. The default row is unspecified (U-28). |
| Quick reply ×3 | T38, 6.3.6 | `R`, text, ⌘⇧↩ · 2 + text | Tap, Reply, text, Send, Done · 4 + text | Type-ahead (U-3). Send and Done is behind a long press (U-33). Undo Send is buried by the next `E` (U-21). |
| Accidental Done, undone | T26, T44 | `Z` · 1, any time this session | Toast's Undo · 1, within 6 s; then no path from the list | U-8. On the Mac better than SH's ten seconds. |
| New mail mid-triage | T7–T9, O1 | The row slides in; the cursor row drops 32 pt | Rows move under the thumb | U-11. If it is a reply to the cursor's conversation, `E` archives it unseen (U-10). |
| Next split ×3 | T31, 6.1.7 | `Tab` · 1 | A chip at the top · 1, out of reach; or scroll to the foot | U-7. SH's phone has splits at the bottom. |
| Two accounts | 2.5, 6.3.3 | Nothing; `⌃1` narrows | Nothing; the filter menu narrows | Label and Move refuse a selection that spans accounts (6.6). |

**Totals:** Mac about 62 keys plus typing; SH the same, since the map is the same. iPhone
about 62 touches plus typing; SH about the same, with every split change in reach.

### (b) A reply with an attachment on a plane, then landing

| Step | Rule | Mac | iPhone | Issue |
|---|---|---|---|---|
| Open, reply to all | T10, 6.2.2 | `↵`, `↵` · 2 | Tap, Reply · 2 | U-3. |
| Write | 6.3.9 | Text | Text | Saved every 800 ms, on the device. The signature (U-18). |
| Attach a local file | 6.3.5 | ⌘⇧A, the panel | Paperclip, Photos or Files, pick · 3–4 | Forwarding an attachment that is not on the device is unspecified. |
| Send | 6.3.6, T35 | ⌘↩ · 1 | Send · 1 | "Will send when you're online" (U-14). The status line and Outbox are truthful. |
| Change it an hour later | — | `Z` only if still the top entry; else `G` `U`, `↵`, then nothing | Places, Outbox, the row, then nothing | A waiting card has no Edit and no Don't send (U-14). |
| Land | engine 12.1, 12.2 | Lid open: goes in seconds, silently | In a pocket: when iOS next runs Banana, or when opened | The hidden limit; silent success (U-14). |
| It fails | 7.6 | Toast or notification, badge | The same | Fine. |

**Totals:** Mac 4 chords, typing, one file; iPhone about 7 taps and typing. SH the same. The
difference is what the copy promises.

### (c) A three-year-old email, twenty minutes into a first sync

| Step | Rule | Mac | iPhone | Issue |
|---|---|---|---|---|
| Search | 4.2.1, 6.4 | `/` · 1 | Tap the pill · 1 | U-3. |
| Type two words | 6.4.3, 7.3 | Text | Text | Device results at once; "On this iPhone back to 12 Aug · Gmail is searching the rest…" is truthful. On the phone about two results show (U-30). |
| Gmail's results arrive | T1 group 1 | — | — | Under FROM GMAIL, below every device result. How a row looks before its details are fetched is unspecified (U-28). |
| Reach the old one | T33, 6.4.4 | `↵`, then ⌘↓ or `J`; or `before:2024` | Scroll; or the Date chip | ⌘↓ with paging is unspecified (U-28). |
| Open it | T10, 6.2.5 | `↵` · 1 | Tap · 1 | "Getting this message…": the one allowed wait, used correctly. |

**Totals:** Mac 4 keys and typing; iPhone 2 taps, typing, a scroll. SH the same. The scope
line is better than SH's silence about coverage.

### (d) A snooze returning; "remind me if no reply" firing

| Step | Rule | Mac | iPhone | Issue |
|---|---|---|---|---|
| The time comes, device locked | 7.10 | Notification | Notification | Only on devices that had synced the snooze; no screen says so. |
| The time comes, Mail in front | T7, T8(b), T1 | Row appears at rest, "Back from snooze · set Mon" | The same | Sorted at its wake time, so mid-list when late; unread or not is unspecified (U-22). |
| Open from the notification | 8.1 | Click · 1 | Tap · 1 | Fine. |
| Set "remind me if no reply" | 6.3.6, 6.5 | ⌘⇧H, a phrase, `↵`, ⌘↩ | Long-press Send, Remind me…, a row, Send | Hidden on the phone (U-33). |
| It fires | 7.10 | "No reply yet?" | The same | Honest as a question. Never withdrawn if a reply came or he finished it elsewhere (U-22). |

**Totals:** nothing to press to see it return; SH the same, and reliable on every device.

### (e) Scheduled on the Mac for 8 am, lid closed, phone at 8:05

| Step | Rule | Mac | iPhone | Issue |
|---|---|---|---|---|
| Send later | 6.3.6 | ⌘⇧L · 1 | — | |
| 8 am tomorrow | 6.5 | "8am" `↵`, or `↓` `↓` `↵` | — | The footer is truthful: "It has to be awake and running Banana then." |
| Schedule | 6.3.6 | ⌘↩ · 1 | — | Same three steps as SH. |
| Close the lid | 6.5.5 | — | — | The ordinary thing to do. It guarantees lateness. |
| 8:00 | 7.7 | Nothing | Nothing | The notification is for the owner only (U-4). |
| 8:05 | 6.5.5, 7.6 | — | Mail, ≡, Outbox, the row, Send from here instead · 5, if he looks | The row and card still say "Scheduled · Thu 8 AM". Depends on unverified headers (U-4). |
| The Mac is opened at 9:15 | 7.7 | Sends at once; "Sent 9:15 AM · was due 8 AM" | — | Or four days later, without asking. |

**Totals:** 3 keys to schedule, as SH. Afterwards SH needs nothing and sends at 8:00. Banana
needs 5 taps and for him to remember. This is the largest gap of the five.

---

## Recommended first-release scope and order

**The smallest set that replaces Superhuman for morning triage and reply.** Mac first: it is
where he is keyboard-heavy, it needs no tab decision, and the engine fills completely there.

1. **Prototypes P1–P6.** A day or two each. P5 is the engine's.
2. **U0** contract, fixtures, session — with 12.3 corrected (U-23).
3. **U2** tokens and the row; **U3** the triage model, with U-2, U-10 and U-12 folded into
   the rules first.
4. **U5** the keymap, with K12 (U-3). It moves the calendar's key table, so it carries the
   test that every existing key still resolves as today.
5. **U1, Mac half only**: sidebar row, ⌘2, the badge.
6. **U4** the list, on whatever host P1 chose. **U6** the conversation, with TextKit bodies.
7. **U18, thin, now:** list, open, Done, Undo, read — on the real engine, on the Mac. Measure
   8.1 here, not at the end.
8. **U9** the composer: reply, reply all, forward, new, Send, Send and Done, the undo hold.
   Not Send later.
9. **U8, snooze only.** **U11** search, device and Gmail.
10. **U7** web bodies. Until then a designed message shows its text and "Open in Gmail".
11. **U10, minimal:** Places as a list of mailboxes; the label and move pickers.
12. **U14 and U15, minimal:** turn Mail on per account; offline, failed send, signed out, the
    first-sync card.
13. **U1, phone half**, once D1 is decided from a picture; then the compact screens on the
    layout that P4 chose.

**Not needed for that, and should wait:** U13 (the invitation card and the day pane — the
best Banana-only features, but not parity); Add to plan; Send later and "remind me if no
reply" until P5 reports; U17; custom-split editing and "Save this search as a split"; ⌘K's
ranking, recents and typed rows (the menu and the shortcut sheet from the registry are
enough); the iPad's key host; unsubscribe, mute, creating labels; the hints and the "older
than a week" offer; new-mail notifications; U16 as a separate pass (identifiers and labels
belong in each package).

**Missing, and he will miss it on day one:**
- A Send later he can trust (U-4).
- Find in a conversation (U-38).
- Selecting and copying part of a message on the phone; tappable phone numbers and addresses
  (U-5).
- Not spam and Restore from Trash (U-19).
- Next and previous conversation as buttons on the phone (U-16).
- Undo on the phone after the toast (U-8).
- Recipients he has never exchanged mail with: autocomplete is built from mail's own headers,
  so a contact with no mail history has to be typed in full.
- Zoom in the reader on the Mac (U-26).
- A code or sign-in link within a few seconds (U-39).
- Snippets, if he uses them weekly (D10).

---

## Decisions for the owner, consolidated

"UX Dn" and "Engine Dn" are the two documents' own numbers. **Bold** marks where this review
disagrees with one or both documents.

| Decision | The one recommendation | Runner-up | Picture? |
|---|---|---|---|
| Where Mail sits on the iPhone (UX D1) | Mail takes Notes's seat, **with capture kept one tap away** (U-24). | Mail inside Plan behind an envelope button. | **Yes**: the new bar; Library with its switch and a capture button. |
| The phone's bottom layout (new; U-6, U-7, U-16) | **One strip: splits, a search button, Compose; arrows for next and previous in a conversation.** | The spec's bar as drawn. | **Yes**, from P4, with an episode loaded. |
| Mail's place in the Mac sidebar (UX D2) | Second, ⌘2. | Last, ⌘9. | No. Tell him seven shortcuts move. |
| ⌘N, `/`, ⌘R, `I` then `Y`/`N`/`M` (UX D3, D4, D11) | As the spec. | — | No. **Do not ask**: one answer is clearly right. |
| Unread mail on the app icon (UX D5, Engine D4) | No, **and no switch**: the spec says of its own switch that the icon "stops meaning due". Failed and unanswered sends do count. | The UX's switch, off. | No. **Do not ask**; both documents already agree on the answer. |
| Remote pictures (UX D6, Engine D2) | **Neither default.** Pictures load for people he has written to and for senders he has allowed; everyone else shows "Show pictures · Always from this sender". Nothing is fetched before a message is opened. If it must be one of the two: the engine's, because without a proxy the UX's default tells every sender his address and the time. | The engine's: off, per message. | **Yes**: a newsletter with pictures held back. |
| Swipe actions (UX D7) | As the spec; it is Superhuman's default. | Apple Mail's. | No. Ask only whether he has changed Superhuman's. |
| List density on the Mac (UX D8) | 32 pt. | 36 pt. | **Yes**, and it is cheap: the row gallery at both heights. |
| A late scheduled message (UX D9, Engine D8 and `askIfLateBy`) | **Neither.** Run P5 first. Then: up to 30 minutes late it goes and says so; later it asks; no setting. If the probe allows, any device that runs after the time takes a late message over. Every device shows the late state and notifies (U-4). | The engine's: only the owner sends; ask after 24 hours. | **Yes**: the picker's footer, the 8:05 lock screen, the late card. This is the product risk he should see before agreeing. |
| Snippets in the first release (UX D10) | No. | Yes, after U9. | No. Ask how often he uses them; it is a fact only he has. |
| Done marks read (UX D12) | Yes, no setting, with T45 (U-10). | A setting. | No. **Do not ask.** |
| The undo hold (UX D13, Engine D9) | Ten seconds; leaving the app sends. | Five. | No. **Do not ask**; it is Superhuman's. |
| iPad: actions in the header (UX D14) | As the spec. | A bottom bar on touch. | No. Revisit after a week on an iPad. |
| New-mail notifications (UX D15, Engine D13) | Important only, with the row saying how late they can be; approve the Push capability so a running Mac wakes the phone. | Off, with Gmail's app kept for alerts. | No. |
| A returning snooze is unread (Engine D10; the UX is silent) | Yes. | No. | No. |
| A change Gmail refuses (O13; new) | **Reverse it on screen, with Retry**, for changes to conversations; keep it for messages. | The spec's: kept, in Outbox. | No. |
| When arriving mail joins the list (O1; new) | **After three seconds idle, never under a hover or swipe.** | The spec's 400 ms. | No. |
| How far back bodies are kept (Engine D3; UX 6.8.1) | The engine's ceilings; **reword the UX's setting to match** ("Bodies on this iPhone: the newest 4 GB · Everything"). | Everything, everywhere. | No. |
| Mail per account, opt-in (Engine D6; UX 6.9 pre-ticks all) | Opt-in; **the turning-on screen ticks only the default account.** | All ticked. | No. |
| The consent screen's publishing status; the quota check (Engine D1, D7) | Actions, not choices: In production, unverified; read the quota. The turning-on screen warns about Google's warning (U-32). | — | No. |
| Mail-only accounts; seeding from another device; the search index (Engine D5, D12, D14) | As the engine: not now; later; keep the prefix index. | — | No. **Do not ask** D5 or D14. |
| Live access and a test account for Beta (Engine D11) | His call. A Beta composer must be marked "sends real mail" (U-23). | — | No. |
