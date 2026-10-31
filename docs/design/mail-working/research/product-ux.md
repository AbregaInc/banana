# Mail in Banana: product and UX research

5 Oct 2026. Research that precedes the design of a Gmail-only mail client inside Banana, good
enough that the owner can stop using Superhuman. Nothing here is built. Read-only on the repo.

Companion files in this folder: `gmail-api.md` (what the Gmail API can and cannot do) and
`integration-map.md` (what the codebase already has). This file refers to them instead of
repeating them.

**How sure each claim is**

| Mark | Meaning |
|---|---|
| (PDF) | Read directly from Superhuman's own "Mail Keyboard Shortcuts v8, Mac Edition" PDF. |
| (blog) | Read directly from the cited page. |
| (help) | From a search-engine summary of a help.superhuman.com page. The help centre returned 403 to a direct fetch, so the wording is second-hand. |
| (Mobbin) | Seen in a Mobbin screenshot; link in section 0.3. |
| (opinion) | My recommendation or inference. Not a finding. |

Evidence is thin in four places, and I say so where they come up: Superhuman's iPhone app is
not in Mobbin (its gestures come from help summaries and one blog post); Superhuman's undo
depth and whether Mark Done also marks read are not documented anywhere I could read; the
per-day usage figures in section A are estimates for a heavy triager, not the owner's telemetry;
and three platform assumptions need an engineering spike (listed at the end of section A).

---

## 0. Research findings

### 0.1 Superhuman, concretely

**Keyboard map.** The full v8 Mac map is reproduced, key by key, in section C with a
keep-or-diverge decision on each. Three facts that changed since older references: `?` is
now *Ask AI* (shortcuts moved into ⌘K) (PDF); calendar keys are `0` day, `0` then `0` week,
`T` today, `P`/`-` and `N`/`=` previous and next, `B` create event (PDF); `⌘A` is "select all
from here" and `⌘⇧A` is "select all" (PDF).

**The triage loop, and why it feels fast.**
- One conversation has the cursor at all times. `J`/`K` move it, `Enter` opens, `Esc` goes
  back (PDF).
- `E` marks Done (archive). "As soon as you action an email, you'll immediately move to the
  next conversation… Continue until you complete the final conversation and you'll return to
  your inbox" (help). So the action and the navigation are one keystroke.
- `H` opens *Remind Me*, `Z` undoes the last action within 10 seconds on desktop, and the
  window can't be extended (help).
- The window shows one thing: a full-width one-line list, or one conversation. There is no
  reading pane. The right-hand pane holds the contact, the calendar or "Recent Opens"
  (Mobbin).
- Why it feels fast (opinion, from the evidence): (1) every read comes from a local store
  and every write is optimistic (blog); (2) single unmodified keys, no confirmation dialogs;
  (3) auto-advance removes the "now what" step; (4) Split Inbox turns the list into batches
  of the same kind of mail, so the same decision repeats and a rhythm forms; (5) animation is
  minimal (blog); (6) ⌘K finds any command and shows its key, so the palette is needed less each
  time (Mobbin); (7) the threads you are likely to open next are preloaded and prerendered (blog).

**Split Inbox.**
- Default splits: *Important • Other*, *Team*, *VIP*, *Calendar* (help). Mobbin's capture
  shows the tab row as "Important 411 · Shared · Calendar 61 · Other".
- *Important* holds "person-to-person and high priority messages"; *Other* holds "automated
  messages and emails sent to mailing lists" (help). The classifier is Superhuman's own,
  server-side.
- A custom split is a saved search: `from:`, `to:`, `label:`, `category:`,
  `subject:"…"`, joined with `OR` (help). Quick creation: ⌘K → New Split Inbox, then pick
  the sender's address, domain, recipient or subject from the current conversation (help).
- `Tab` / `⇧Tab` move right and left through splits (PDF).
- A conversation lives in one split unless the split's setting "Also show conversations that
  match this Split Inbox in Important or Other" is ticked (help).

**Remind Me (snooze).**
- `H`, or `⌘⇧H` from a draft. A palette with a free-text field ("Try: 8 am, 3 days, aug 7"),
  a "last used" row first, presets with the resolved time right-aligned, and an "if no reply"
  toggle (Mobbin).
- Default is "if no reply": a reply lands in the inbox and cancels the reminder (help).
- Returned conversations appear in a *Reminders* split, or in Important/Other if that split
  is turned off (help).
- *Auto Reminders* (Business plan): AI picks sent mail that needs a follow-up (help).

**Send Later, Undo Send, Instant Send.**
- `⌘⇧L`. Same palette shape: "tomorrow morning THU 8:00 AM", "tomorrow afternoon", "Monday
  morning", "Unschedule" (Mobbin). After choosing, the composer's primary button changes
  from *Send* to *Schedule* and the footer reads back "Send: Thu 8:00 AM · Remind: Thu
  9:00 AM" (Mobbin). A scheduled message shows a "Scheduled: Thursday, August 28 2025 at
  8:00 AM" line with ×, and a palette offering Reschedule / Edit Message / Discard (Mobbin).
- The schedule is held on Superhuman's servers: "if you scheduled an email to send before
  going offline, the email will send at the scheduled time" (help). This is the behaviour a
  no-server client cannot match.
- *Smart Send* proposes a time when the recipient is likely to open (help). Needs open
  tracking.
- Undo: `Z` within 10 s on desktop (help). `⌘⇧Z` is *Instant Send*, which skips the hold
  (PDF).

**Snippets.** `⌘;` picks one, typing `;` inserts inline, `G` then `;` lists them (PDF).
Variables such as first name; team sharing; per-snippet counts of sends, opens and replies
(help).

**AI.** *Auto Summarize*: a one-line summary under the subject, expandable. *Instant Reply*:
three draft replies under the latest message. *Ask AI* (`?`): a question over the mailbox,
answered with citations. *Auto Drafts*: follow-ups written without being asked. *Auto
Labels*: marketing, cold pitches, social. *Write with AI* (`⌘J`): draft or edit in the
composer, able to insert availability (help; `⌘J` hint seen in Mobbin). All of it runs on
their servers.

**Read Statuses.** Shows the time, the device and each person who opened a message, plus a
"Recent Opens" feed in the right pane (help, Mobbin). Works only for mail sent from
Superhuman, because it depends on a tracking pixel served by them.

**Calendar inside mail.**
- When a message mentions a date, the right pane shows that day's schedule (blog). `0`
  toggles the pane (PDF).
- `B` creates an event from the email, pre-filled with the thread's attendees and a
  suggested time (*Instant Event*) (blog).
- *Share Availability*: pick slots on the calendar, they are inserted into the email as
  text plus a booking link that stays live and adapts to the recipient's time zone (blog).
  The link is a server product.
- On the phone, a detected date appears bottom-left of the message; tap it to create an
  event (help).

**The iPhone app.** (help and blog only; not in Mobbin)
- Swipe left on a row marks Done, swipe right sets a reminder. Both are configurable, with
  several actions per side (help).
- Pull straight down to search; pull down then right (an "L") for the command palette; pull
  down then left to refresh. A two-finger tap on a row opens the palette for that row
  (help, blog).
- Splits are a row at the bottom of the inbox; swipe it to see more (help).
- An open message has a triage bar along the bottom. Swiping that bar right-to-left goes to
  the next email; swiping left-to-right mid-screen returns to the inbox (help).
- Notifications: All, High Priority, chosen splits, or Off (help).
- Reviews consistently say the phone app lags the desktop one.

**Speed.** "Every interaction should be faster than 100 ms", after Paul Buchheit; Superhuman
aims for under 50 ms and reports a renderer at 1–2 frames (under 32 ms) (blog). Means: a
local database of mail, preloading and prerendering likely-next threads, minimal animation,
keyboard first, continuous measurement (blog).

**Offline.** The write path is a queue of "modifiers" per thread: `modify()` updates local
data synchronously, `persist()` saves over the network later; a failed persist retries, a
permanently failed one is removed and the UI rolls back (blog). The cache holds anything
opened, searched or received in the last 30 days and up to 1,250 conversations per split,
with attachments (help). So Superhuman is offline-capable but not a full local mailbox.

**Onboarding: what to keep, what is theatre.**

| Keep | Why |
|---|---|
| Teach `E`, `H`, ⌘K by doing, with key caps on screen ("Hit E to mark messages Done. [E][E][E]") (Mobbin) | Three presses build the habit; a tooltip doesn't. |
| *Get Me To Zero*: archive everything older than seven days in one command (help) | Makes an empty inbox reachable on day one, which is what makes the loop worth keeping up. |
| The palette as the place where shortcuts are learned (Mobbin) | No separate tutorial to maintain. |
| Setting splits from your own mail in the first session (help) | The first triage pass is already batched. |

| Theatre | Why not |
|---|---|
| Wait-list, pre-call survey, a live 30-minute call with a specialist | Sales and commitment devices. One expert user needs none of it. |
| Full-screen "Congratulations! You hit Inbox Zero." (Mobbin) | A reward for the product, not the person. |
| A synthetic demo inbox | the owner's real mail is the better tutorial. |
| Full-bleed nature photograph at zero (Mobbin) | Pleasant, but it says nothing. Banana can say what is next on the day instead (section D8). |

**Mac versus iOS, in one table.**

| | Mac | iPhone |
|---|---|---|
| Primary input | Single keys, ⌘K | Row swipes, bottom triage bar |
| Layout | Full-width one-line list, or one conversation; right context pane | Stacked rows; conversation pushed |
| Splits | Text tabs, top-left, `Tab` to cycle | Row at the bottom |
| Palette | ⌘K | Hidden pull-down "L", two-finger tap |
| Undo | `Z`, 10 s | Toast (duration not documented) |
| Quality | The product | Widely described as behind the desktop |

### 0.2 The rest of the field: what each does better than Superhuman

**Mimestream** (Mac, native, Gmail API, no intermediary server: the closest architectural
cousin). It treats Gmail as Gmail: real labels with colours, inbox categories, server-side
filter editing, aliases and signatures from Gmail's own settings, vacation responder, and
calendar-invitation replies. "Only stores your data and tokens on your device." It also
shows the limit Banana will hit: snooze is a *Labs* feature that "will show only in
Mimestream and won't sync to Gmail", because "the Gmail API does not expose snooze
functionality". It strips tracking from 75+ services and reformats HTML mail for dark mode.
Lesson: use Gmail's own machinery (labels, categories, filters, send-as) as the shared state
between devices, and be plain about what is local-only.

**Shortwave** (Gmail-only, AI-first). *Bundles*: similar low-value mail collapses into one
row that can be cleared in one action. Search that understands meaning, not just words.
A reply-writer trained on your sent mail. Lesson: bundling inside *Other* is the biggest
triage accelerator Superhuman lacks; AI search is a server product and out of reach.

**Spark** (Readdle). Smart Inbox groups Notifications and Newsletters into two rows with the
senders shown as chips and a count ("Notifications 99+") (Mobbin). *Gatekeeper* screens
first-time senders. Its reminder sheet shows the resolved time next to every preset
(Mobbin). Lesson: grouped rows with sender chips; preset rows that state the exact time.

**Notion Mail** (Gmail-only; shut down 22 Sep 2026). Views were saved filters with visible
filter chips ("Categories: Not Promotions… · Labels · Is unread · Show archived") (Mobbin).
Its reminder sheet had the cleanest "Remind if: No reply | Regardless" control, and its swipe
settings showed a live picture of the row with the chosen actions (Mobbin). Notion's stated
reason for closing: more than half its users handled mail without opening the inbox, so it
went "all in on using agents". Lesson: its mobile reminder and swipe-settings patterns are
the best in the field and nobody ships them now; and a mail client for a keyboard triager is
a different product from the one Notion is building instead.

**Apple Mail, iOS 26.** Categories (Primary, Transactions, Updates, Promotions) as a chip row
with the selected one expanded to a label and the rest icon-only; a time-sensitive message
from another category is also shown in Primary; tapping a commercial sender opens a digest
of everything from that sender; search and compose sit in a floating bar at the bottom
(Mobbin). Send Later there has the same limit Banana will have: it is "an on-device feature
that only works from the originating device", and the device must be on and online at the
time. Lesson: the bottom-bar layout is the current platform idiom; and a first-party client
already ships client-held scheduled send, so the limit is acceptable if stated.

**Gmail's own app.** Swipe actions are a setting with one action per side from a short list
(Archive, Trash, Read/unread, Snooze, Move). The inbox shows a category as a single row with
its newest sender and a "1 new" pill (Mobbin). Schedule-send is a 2×2 grid of presets with
the time zone stated underneath (Mobbin). Lesson: one action per swipe side is enough; state
the time zone when scheduling.

**HEY.** *The Screener* (yes or no per first-time sender), *Reply Later* and *Set Aside* as
piles separate from the inbox, *Focus & Reply* to answer the pile in one sitting, and a
floating action bar in the thumb zone on every thread (Reply · Later · Aside · More)
(Mobbin). It tells you which mail is kept offline (Mobbin). Lesson: the thumb-zone action
bar, and the idea that "I need to reply to this" is a different state from "bring this
back later". Banana can express that state as a task on the plan (section E1).

**Fastmail and Spike.** Fastmail's apps now work fully offline through a caching layer that
answers the app's requests locally first and replays changes on reconnect; the user chooses
between caching recent mail or all mail, and attachments are cached only once opened.
Lesson: "recent or all" is the right storage question to ask per device. Spike's chat-bubble
rendering of threads is not relevant to a triage tool.

### 0.3 Reference screens (Mobbin)

Mobbin was reachable. Superhuman Mail is covered on web; its iPhone app is not in the
library. "Detail worth copying" is the reason each one is here.

**iPhone**

| # | App | What it shows | Link | Detail worth copying |
|---|---|---|---|---|
| 1 | Apple Mail | Inbox, iOS 26 | [ad256b93](https://mobbin.com/screens/ad256b93-334f-43ab-baf7-42441e740e7c) | Category chips: selected chip has a label, the rest are icons. Unread dot in the leading gutter. Floating bottom bar: filter, search, compose. |
| 2 | Outlook | Inbox | [91fa256d](https://mobbin.com/screens/91fa256d-f72b-4a86-828b-c68480db9ebf) | A next-meeting card pinned above the list ("in 9 min · View"). Date-group headers. Attachment and @ glyphs on the subject line. |
| 3 | Notion Mail | Inbox | [7a35d0c0](https://mobbin.com/screens/7a35d0c0-4ec2-4289-b21b-b7e4553a8cc2) | Unread shown by weight plus a small dot after the sender. Label chip as a fourth line only when present. |
| 4 | Spark | Smart inbox, "Seen" group | [30d3b79e](https://mobbin.com/screens/30d3b79e-d77c-4f0c-935d-f8bbd180b4e8) | A collapsed "Seen · 70" group header: read mail is one line until asked for. |
| 5 | Spark | Full swipe, bundles | [549157c4](https://mobbin.com/screens/549157c4-7a1f-4905-99e6-c3022deb5cb4) | A full swipe shows label and icon together. Bundle rows list senders as chips. Thread count as a small badge after the subject. |
| 6 | Notion Mail | Swipe settings | [0abd5c81](https://mobbin.com/screens/0abd5c81-4cd1-450b-bf9a-1cb0990bdca5) | A live picture of a row with the chosen actions above the lists. |
| 7 | Gmail | Inbox | [6424b58f](https://mobbin.com/screens/6424b58f-dfa3-489d-b535-a37dead4a950), [ecadc8f0](https://mobbin.com/screens/ecadc8f0-a5b3-4ab9-8212-e70e97c02ba8) | A category as one row with its newest sender and a "1 new" pill. |
| 8 | Gmail | Mailbox drawer | [f85e5dd8](https://mobbin.com/screens/f85e5dd8-a8cb-4973-afd8-079b2393736f) | The canonical mailbox order, including Snoozed, Scheduled and Outbox as first-class places. |
| 9 | Gmail | Conversation | [34c97b56](https://mobbin.com/screens/34c97b56-6ce9-4031-be4d-672471fd3898) | Label chip beside the subject. "to me ⌄" expands recipients. One-tap reply chips under the last message. |
| 10 | Apple Mail | Conversation | [523cc9d8](https://mobbin.com/screens/523cc9d8-8627-4ca4-9fc0-8010e11dbfd1) | An earlier message collapsed to one row (sender, date, one line). Quoted text behind "See More". "Found in All Mail" note. |
| 11 | Outlook | Conversation | [86c0098c](https://mobbin.com/screens/86c0098c-39ff-4de8-a7bf-09513312e204) | Messages as separate cards. Persistent bottom bar with a wide Reply and three icons. |
| 12 | HEY | Conversation action bar | [fe08f40c](https://mobbin.com/screens/fe08f40c-1d35-4a8d-946c-d7ed4f209f5b) | Four labelled actions floating in the thumb zone. |
| 13 | HEY | Reply Later list | [80eb0a9b](https://mobbin.com/screens/80eb0a9b-022e-4982-b3dd-3b3400815f35) | One sentence under the title says what the pile is for. A card says what is kept offline. |
| 14 | HEY | Multi-select | [d3e6ee55](https://mobbin.com/screens/d3e6ee55-707e-4efe-b83d-7ea33e5566cd) | Leading glyphs become check circles; a floating bar acts on "2 selected". |
| 15 | HEY | The Screener | [6a306e56](https://mobbin.com/screens/6a306e56-f080-4f5d-9292-2b494a5eee16) | Yes (with a destination menu) or No per sender. For a later version. |
| 16 | HEY | Ignored thread | [f79e047b](https://mobbin.com/screens/f79e047b-4b56-44be-811a-3aae224522d2) | A muted thread says so in a banner with "Stop ignoring". |
| 17 | Outlook | Compose | [86a6fea1](https://mobbin.com/screens/86a6fea1-8a22-4d29-a696-a9abc2d3fbd2) | The sending identity is the sheet's title. Tools float in one bar at the bottom. |
| 18 | Notion Mail | Compose | [e94a065f](https://mobbin.com/screens/e94a065f-81e5-49cb-955f-3f6934f24ad2) | Formatting bar appears above the keyboard only when text is selected. A calendar button beside Send. |
| 19 | Gmail | Compose | [f2f7c87e](https://mobbin.com/screens/f2f7c87e-1dc9-4bf3-bb28-785b728d5974) | Recipient chips with a monogram. From row only when there is a choice. |
| 20 | Spark | Compose | [3e96beb2](https://mobbin.com/screens/3e96beb2-3c2c-4c52-afe3-93e1ef7374cc) | Keyboard accessory with attach, template, follow-up reminder, send later. |
| 21 | Spark | Reminder sheet | [2a057e6d](https://mobbin.com/screens/2a057e6d-b622-467e-9bbf-1bb8fd00093e) | Every preset states its resolved time on the right. |
| 22 | Notion Mail | Reminder sheet | [6f7733e5](https://mobbin.com/screens/6f7733e5-1235-40e1-85df-6920dad70973) | "Remind if: No reply / Regardless" as one control at the bottom. |
| 23 | Gmail | Schedule send | [a06e5620](https://mobbin.com/screens/a06e5620-2acc-4192-897d-e145434cd02c) | "All times are in …" under the presets. |
| 24 | Outlook | Snooze | [946c0a3b](https://mobbin.com/screens/946c0a3b-6b40-4070-8e80-805f3303c02d) | Five rows, no more. "Choose a time ›" last. |
| 25 | Outlook | Search | [636b4df6](https://mobbin.com/screens/636b4df6-0df1-4b56-b627-2369136ed095) | People as the first row of suggestions before anything is typed. |
| 26 | Slack | Search results | [6118c194](https://mobbin.com/screens/6118c194-92c4-49e5-9685-98c072c35f5b) | Filter chips that are menus ("From ⌄"). Matched words highlighted. |
| 27 | GitHub | Search with filters | [379412b8](https://mobbin.com/screens/379412b8-1f49-47cd-8fe2-1a86a8b4a610) | Filter menus in a row directly under the field, above the keyboard's reach. |

**Desktop**

| # | App | What it shows | Link | Detail worth copying |
|---|---|---|---|---|
| 28 | Superhuman | Inbox with calendar pane | [23872261](https://mobbin.com/screens/23872261-bbe4-4f8d-9cd0-576c0a3524e9) | Three text columns on one line. Splits as text tabs with counts. Date-group dividers. The day in the right pane with a now-line. |
| 29 | Superhuman | Command palette | [85dc5994](https://mobbin.com/screens/85dc5994-9360-428d-9092-7425e070ed7f) | Each command shows its key, so the palette teaches. |
| 30 | Superhuman | Palette over inbox | [1f3fb485](https://mobbin.com/screens/1f3fb485-0f95-4826-bca2-74fed2449f6f) | The cursor row swaps its date for three quick actions without moving anything else. |
| 31 | Superhuman | Conversation | [03ef7e31](https://mobbin.com/screens/03ef7e31-4442-40c3-8882-39ebe33a9e56) | A centred column of fixed measure. One-line message headers ("Sahar to Me"). Quoted text as "…". |
| 32 | Superhuman | Inline reply | [4cbeae40](https://mobbin.com/screens/4cbeae40-1b58-4248-91b6-2de0c9c97a72) | The reply is a card in the thread with an accent spine. Footer: Send · Send later · Remind me. |
| 33 | Superhuman | Recipient autocomplete | [a4100266](https://mobbin.com/screens/a4100266-4130-40cb-ab31-7d0904cffda9) | Two columns, name and address, with the typed prefix emphasised. |
| 34 | Superhuman | New message | [137d4e7f](https://mobbin.com/screens/137d4e7f-1e36-4b62-a98b-b300134083ba) | A strip of key hints under the composer ("⌘ Enter to send"). |
| 35 | Superhuman | Remind me | [66ae0f27](https://mobbin.com/screens/66ae0f27-4959-41c6-8b81-dcd24a25afe2) | Free text first, "last used" as the first preset, "if no reply" in the field's trailing edge. |
| 36 | Superhuman | Send later | [8d7acd3f](https://mobbin.com/screens/8d7acd3f-f24e-4c3e-8ba9-035d8c25751a) | The same palette as Remind me. "Unschedule" as the last row. |
| 37 | Superhuman | Scheduled composer | [3c3a9045](https://mobbin.com/screens/3c3a9045-c913-4aff-bc21-30f59318d150) | The button says *Schedule* and the footer reads the times back. |
| 38 | Superhuman | Scheduled message | [e2537fe3](https://mobbin.com/screens/e2537fe3-11ff-44eb-a721-38ca90c372ba) | A "Scheduled: …" line on the message, with ×. |
| 39 | Superhuman | Inbox Zero photo | [535b097f](https://mobbin.com/screens/535b097f-547d-44dc-88c9-93d041053752) | Reference for what not to do: nothing on it helps. |
| 40 | Superhuman | "Congratulations!" | [08b8e810](https://mobbin.com/screens/08b8e810-572c-45b5-91ec-4f76bc6e6a0d) | Theatre. |
| 41 | Superhuman | Empty Drafts, undo toast | [23660193](https://mobbin.com/screens/23660193-1d87-4462-9b18-a9f0dc06ccf5) | "Draft discarded. UNDO ×": the same shape as Banana's toast. |
| 42 | Superhuman | Onboarding coach bar | [af8441c9](https://mobbin.com/screens/af8441c9-cd3c-4a9e-bfe8-d58abe695cb8) | Three key caps that fill as you press `E`. |
| 43 | Superhuman | Onboarding, ⌘K | [a290fbce](https://mobbin.com/screens/a290fbce-8900-4285-b670-af77f2a6b51e) | The palette is introduced by needing it. |
| 44 | Notion Mail | List and reading pane | [9d8e58ec](https://mobbin.com/screens/9d8e58ec-3d37-432d-9af9-76ad8a83fe47) | Filter chips above the list. Thread count after the sender ("Lindsey .. Sam 3"). "Thread moved to Trash · Undo" at the list's foot. |
| 45 | Front | Three panes, shortcut panel | [6b6a701f](https://mobbin.com/screens/6b6a701f-8589-415c-9c52-c91d4feade1c) | The shortcut list as a side panel that leaves the mail visible. |
| 46 | Intercom | Send menu | [60778106](https://mobbin.com/screens/60778106-fa33-4231-95a2-ce3362d8ff06) | "Send and close", and "Send and snooze" with presets, under the Send button. |
| 47 | Plain | Shortcut panel | [9ff26374](https://mobbin.com/screens/9ff26374-0540-4196-be39-6f54bef334cf) | Grouped "Everywhere" and "On a thread": the grouping Banana's shortcut sheet already uses. |

---

## A. What "replaces Superhuman" means for one person

Ranked by how often the thing is used in a day. The counts are my estimates for someone
clearing 100 to 200 conversations a day; the order matters more than the numbers.

Tags: **CLIENT** = feasible client-only. **SUBSTITUTE** = needs a substitute, named.
**LOST** = not feasible; what is lost is named.

| # | Must-have | Uses a day (est.) | Tag | What it takes, or what is lost |
|---|---|---|---|---|
| 1 | **Instant inbox from cache, moved through with J/K/Enter/Esc** | 300+ | CLIENT | Every list and conversation is read from the local store. Better than Superhuman: the whole mailbox is local, not 30 days. |
| 2 | **Mark Done with auto-advance and Undo** | 50–150 | CLIENT | Remove the `INBOX` label, optimistically, through a queue that works offline. Undo adds it back. |
| 3 | **Split Inbox, cycled with Tab** | 20–60 | CLIENT | A split is a saved query evaluated on the local store. Superhuman's Important/Other classifier is theirs; the substitute is Gmail's own `CATEGORY_*` and `IMPORTANT` labels plus one local rule (section D6). The split will not match Superhuman's message for message. |
| 4 | **Reply, reply-all, forward; Send; Send and Done; Undo Send** | 20–50 | CLIENT | Undo Send is a hold on the device before the message is handed to Gmail. |
| 5 | **⌘K command palette that teaches the keys** | 20–40 | CLIENT | The palette exists (`MacCommandMenu`); it needs per-section commands. |
| 6 | **Search as you type, including offline** | 10–30 | CLIENT | A local full-text index over the cache. Gmail's server search is merged in when online, for whatever is not on the device yet. |
| 7 | **Snooze, including "if no reply"** | 5–20 | SUBSTITUTE | Gmail's snooze is not in the API. Substitute: Banana hides the conversation (label change in Gmail, wake time in Banana's own sync) and each device schedules a local notification for the wake time. See "Honest limits" below. |
| 8 | **Knowing new mail has arrived** | all day | SUBSTITUTE, partly LOST | Gmail push needs a server. Substitute: polling while a device is awake, iOS background refresh, and optionally a Mac relaying through iCloud. Lost: a guaranteed, immediate notification on a phone when no other device is awake. |
| 9 | **Compose with recipient autocomplete** | 5–15 | CLIENT | Addresses come from the headers of cached mail, ranked by recency and frequency. No contacts permission needed for v1. |
| 10 | **Label, move, star, unread, trash, spam** | 5–15 | CLIENT | Plain label changes. |
| 11 | **The day beside the mail; RSVP; event from an email; free times into a reply** | 3–10 | CLIENT, and better | Section E. The one piece lost is Superhuman's live booking link, which is a hosted page. Substitute: free times as text, or the owner's existing Calendly link as a snippet. |
| 12 | **Send Later** | 1–5 | SUBSTITUTE | Gmail's schedule-send is not in the API. Substitute: the message waits as a Gmail draft and whichever Banana device is awake sends it. See "Honest limits". |
| 13 | **Snippets** | 1–5 | CLIENT | Local, synced between devices like other Banana settings. Team sharing and usage metrics are lost and not wanted. |
| 14 | **Summarise a thread; draft a reply** | 1–5 | SUBSTITUTE | On-device model (small context, so long threads are summarised in parts), or Apple's Private Cloud Compute where `Intelligence.route` allows it. Lost: drafts that are already written when you wake up, and questions answered across the whole mailbox with citations. |
| 15 | **Unsubscribe, mute** | 0–3 | CLIENT / SUBSTITUTE | Unsubscribe uses the message's `List-Unsubscribe` header. Mute is not a documented API label; substitute is a Banana rule that re-archives new mail in that thread on sync. |
| — | Read Statuses | — | LOST | Needs a server to host the pixel and record opens. Lost: knowing whether and when someone opened a message. I recommend no substitute: "if no reply" does the real job, and Apple's Mail Privacy Protection has made opens unreliable anyway. |
| — | Team comments, shared drafts, shared snippets | — | LOST | Irrelevant to one person. |
| — | Smart Send, Auto Reminders, Auto Labels by AI | — | LOST | All depend on server-side models or open tracking. Gmail's categories cover the labelling. |

### Honest limits of having no server

**Snooze when every device is asleep.**
- What still works: the notification. Each device that learned of the snooze before going
  to sleep has a local notification scheduled, and iOS and macOS deliver those on time
  without the app running.
- What lags: Gmail's own state. The conversation goes back into the Gmail inbox only when a
  Banana device next runs. Until then Gmail on the web shows it archived under a
  `Banana/Snoozed` label.
- What fails: a device that never heard about the snooze (set on the Mac, phone not opened
  since) stays silent. Banana has no push between its own devices today
  (`integration-map.md` §8), so the phone learns on its next foreground or background
  refresh. Banana is opened many times a day for other reasons, which narrows this gap more
  than it would for a stand-alone mail app.
- "If no reply" has one more gap: the notification is scheduled in advance and cannot check
  for a reply at the moment it fires. A reply that arrived while the phone was asleep still
  produces "Follow up with Sam?". The wording must stay a question, and opening it shows the
  truth at once.

**Send Later when every device is asleep.**
- The message is safe: it is a real Gmail draft, visible in any Gmail client.
- An awake Mac sends it on time.
- If nothing is awake at the time, it does not go. The phone shows a time-sensitive
  notification at the scheduled minute with a **Send now** action, so one tap on the lock
  screen sends it. If nobody taps, it goes when a device next wakes.
- So every scheduled message needs a stated late rule, chosen when scheduling: *send as soon
  as possible* (default) or *ask me if it is more than 30 minutes late*. A birthday wish
  that goes out three hours late is worse than one that asks.
- Two devices must never both send. Sending the Gmail draft is the lock: Gmail deletes a
  draft when it is sent, so the second device's attempt finds nothing (`gmail-api.md` §5.2;
  the 404 on replay is inferred there and needs the spike).
- Apple Mail's Send Later has the same limit with one device; Banana has three chances.

**New mail without push.**
- Mac, app or menu-bar item running: polling every 15–30 s, so notifications within about
  half a minute. Effectively solved.
- iPhone in the foreground: the same.
- iPhone in the background: iOS decides when background refresh runs, and "the delay… can
  be many hours". Low Power Mode stops it. Notifications from this path are late by an
  unknowable amount.
- A relay is possible: an awake Mac that sees new mail writes a small record to the owner's
  private iCloud database, and a CloudKit subscription turns that into a visible push on the
  phone. No server of our own, but it needs a Mac awake, the push entitlement (today on iOS
  prod only, per `integration-map.md` §8), and the sender and subject passing through
  iCloud. Worth a spike, not a promise.
- So the design must never pretend to be live. The mail list states how fresh it is
  ("Checked 14 min ago") whenever it is not live, pull-to-refresh means "check now", and
  the badge counts only what the device has actually seen.
- Fallback if this is not good enough in practice: leave Gmail's own app installed with
  notifications for important mail only. Tapping one opens Gmail, not Banana. It is a
  stopgap, and should be described to the owner as one.

**Needs an engineering spike before the design relies on it.**
1. Whether `drafts.send` on an already-sent draft fails cleanly (the double-send guard).
2. Whether a CloudKit visible push can be used from this app's entitlements on every build.
3. Whether Gmail-native snoozes are visible to the API through `q=in:snoozed` (so the
   Snoozed view could show them read-only). `gmail-api.md` marks this unverified.

---

## B. The interaction model

Words used below. A **conversation** is a Gmail thread. A **split** is one tab of the inbox.
The **cursor** is the highlighted row. **Older** means the next row down in the list's
order; **newer** the next row up. **Done** means archived: the `INBOX` label removed.

### B1. Mac (and iPad with a keyboard)

One rule shapes the window: **it shows one thing, a list or a conversation.** No reading
pane. The right-hand pane is for the day (section E2), not for a preview. This is
Superhuman's model and the muscle memory being replaced; it also gives the one-line row the
width it needs.

**Cursor**
1. A list with rows has exactly one cursor. An empty list has none.
2. Entering a split for the first time in a session puts the cursor on the top row.
   Returning to a split restores its cursor: the same conversation if it is still there,
   otherwise the row now at that position.
3. `J` moves to the older row, `K` to the newer. At either end the key does nothing: no
   wrap, no beep. (The planner beeps at a dead end; in a list worked at speed a beep is
   noise.)
4. Moving the cursor never marks anything read.
5. The list remembers the direction of the last `J` or `K`. It starts as *older* and resets
   to *older* on entering a split.

**Open and close**
6. `Enter` opens the cursor conversation in place of the list. `Esc` returns to the list
   with the cursor on the conversation that was open, at the same scroll position as
   before.
7. Opening marks the conversation read at once.
8. `J`/`K` in an open conversation open the older or newer conversation directly.

**Done**
9. `E` in the list: the cursor row disappears. The cursor moves in the remembered direction
   (rule 5). Going older, the rows below slide up under a cursor that does not move on
   screen. If there is no row in that direction, the cursor takes the other neighbour. If
   the split is now empty, its zero state shows and focus stays in the split.
10. `E` in an open conversation: it is marked Done and the next conversation in the
    remembered direction opens in the same frame. If there is none in that direction, the
    conversation closes to the list, cursor as in rule 9.
11. Done also marks the conversation read. (opinion; otherwise unread counts grow in All
    Mail and in every other Gmail client. Superhuman's behaviour here is undocumented.)
12. With rows selected (rule 20), `E` acts on the selection and the cursor lands on the row
    after the last selected one, else the row before the first.
13. Keys are never dropped or blocked by an animation. Ten presses of `E` inside one second
    mark exactly ten conversations Done, in order.

**Undo**
14. `Z` (and `⌘Z` when no text field has focus) undoes the most recent change. Each press
    undoes one more, back through the session's changes.
15. Undo restores the conversation to its place in the list **and** the cursor to it,
    **and** whatever was showing: if the conversation was open when the action was taken,
    it is open again, scrolled where it was.
16. If the action happened in a different split from the one now showing, undo switches
    back to that split first. An undo you cannot see is not trustworthy.
17. Every change except Send can be undone at any time in the session, not only while the
    toast is up. Send can be undone only during its hold (rule 27). One rule: *everything
    is reversible except a message that has left.*
18. The toast shows the latest change and one action, as everywhere in Banana ("Marked
    Done · Undo").

**Splits**
19. `Tab` goes to the next split, `⇧Tab` to the previous, wrapping. Each tab shows its
    count of conversations.

**Selection**
20. `X` toggles the cursor row's selection. `⇧J`/`⇧K` extend it. `⌘A` selects from the
    cursor to the end; `⌘⇧A` selects everything in the split. `Esc` clears a selection
    before it does anything else.

**Incoming mail**
21. New mail never changes which row has the cursor, and never moves that row on screen.
    New rows are inserted above; if that would push the cursor row down, the list keeps
    its position and shows a "2 new" chip at the top instead. `⌘↑` or a click on the chip
    goes to the top.
22. A conversation that changes elsewhere while it is open (archived on the phone, say)
    stays open. The list is corrected silently.

**Reply and send**
23. `R`, `Enter` (reply all) and `F` open a composer as the last card of the open
    conversation, with the caret in the body. From the list they open the conversation
    first, then the composer, in one step.
24. `Esc` in a composer keeps the draft and returns focus to the conversation. It never
    asks. `⌘⇧,` discards, with Undo.
25. `⌘↩` sends. `⌘⇧↩` sends and marks Done, then advances as in rule 10.
26. On send the composer closes in the same frame and the message appears in the thread
    marked "Sending…". Nothing waits on the network.
27. The message is held for the undo window (10 s; a setting) before it goes to Gmail. `Z`
    or the toast's Undo within the window reopens the composer exactly as it was, caret
    included. `⌥⌘↩` sends with no hold.
28. Quitting or backgrounding during the hold sends the message rather than losing it.
29. Offline, the toast reads "Will send when online" and the message waits in Outbox.
    Everything Banana has promised to send is listed in Outbox until Gmail confirms it.

**Snooze**
30. `H` opens the time palette over the list or conversation. `Enter` on a time hides the
    conversation and the cursor advances as in rules 9 and 10. Toast: "Snoozed until
    Thu 08:00 · Undo".
31. "If no reply" is offered only when the newest message in the conversation is the owner's.
32. A conversation that returns goes back to the split it came from, at the top, with a
    clock glyph and the reason in place of the snippet ("Snoozed on Mon · no reply").
    There is no separate Reminders split: a thing comes back to where it was.

**Tests these rules imply** (a sample; each rule above is meant to be one test)
- Cursor on row 3 of 10, press `E`: 9 rows; the cursor is on what was row 4; that row's
  screen position equals row 3's former position.
- Cursor on the last row, press `E`: the cursor is on the new last row.
- `K`, `K`, `E`: the cursor is on the row that was above the removed one.
- Open a conversation, `E`, `Z`: the same conversation is open at the same scroll offset.
- `E` in Important, `Tab`, `Z`: Important is showing, with the cursor on the restored row.
- Mail arrives while the cursor is on row 1: the cursor conversation's id and its y
  position are unchanged.
- `⌘↩`, then `Z` within the window: the composer is open with the same text and selection;
  nothing was sent.

### B2. iPhone

Three rules shape it. **Every action used more than a few times a day is reachable by the
thumb of the hand holding the phone. The Done button never moves** (the same idea as "the
transport never moves" in the podcast player). **A swipe always means the same thing,
wherever the row is.**

**List**
1. Full swipe left on a row: Done. The right thumb travels inward, the easiest stroke, so
   the commonest action gets it. Superhuman's default is the same.
2. Full swipe right: Snooze. The row stays half-open while the time sheet is up; choosing a
   time completes it, dismissing the sheet returns the row.
3. A short swipe reveals the buttons instead of committing: Done and Trash on the trailing
   side, Snooze and Unread on the leading side. Two per side, fixed in v1.
4. A light haptic marks the point where a full swipe will commit. The row closes up and the
   toast appears above the tab bar with Undo, inside thumb reach.
5. Tap opens. Long-press starts multi-select: the unread gutter becomes a check circle and
   a floating bar offers Done, Snooze and More for "3 selected". A two-finger drag selects
   a run, as in system lists.
6. Pull down to check for mail now. The line under the split chips then says what happened
   ("Checked just now · 3 new").
7. Splits are chips across the top, each with its count. The top is out of thumb reach, so
   the end of every split carries the way onward: a footer row, and the zero state, both
   name the next split with mail and its count ("Other · 12").
8. Compose is a floating button at the bottom trailing corner, above the tab bar.

**Conversation**
9. Pushed full-screen; the tab bar is hidden. A bar at the bottom holds, in this order:
   **Done**, **Snooze**, a wide **Reply**, **More**. It is in the same place on every
   conversation.
10. Done marks the conversation Done and shows the next older one, as on the Mac (B1 rule
    10). The bar does not move, so clearing a run is tap, tap, tap in one spot. After the
    last one, the view pops to the list.
11. Swiping the bar itself left shows the next older conversation without acting on this
    one; swiping it right shows the newer one. This is `J`/`K` for a thumb, and it is the
    only way to skip without going back to the list.
12. The system back swipe from the left edge returns to the list.
13. Reply is a tap for reply-all (or reply, per the setting) and a long-press for a menu:
    Reply, Reply all, Forward.
14. More holds Star, Unread, Label, Move, Add to plan, Create event, Mute, Unsubscribe,
    Trash, Spam.

**Compose**
15. A sheet with the keyboard up and the caret in the body. Recipients are one summary line
    ("To Sam, Jane · Cc 2") that expands on tap.
16. Send is the trailing button of the bar above the keyboard, not a button at the top of
    the sheet. Long-press on Send: Send later, Send and Done, Send without undo.
17. Swiping the sheet down keeps the draft. It never asks.

**Undo**
18. The toast is the undo on the phone: one action, 6 seconds, 10 for Send. There is no
    session-long undo on touch in v1.

**Tests**
- Full swipe left removes exactly that row and shows a toast whose Undo restores it at the
  same index.
- The Done button's frame is identical across two consecutive conversations.
- From a conversation, tapping Done on the last conversation of a split pops to the list.
- With a draft open, swipe down, reopen the conversation: the draft is there.

### B3. iPad

Regular width with a keyboard attached behaves as the Mac (B1), with the same keys. Regular
width by touch uses the Mac's layout with the phone's gestures: rows swipe, and the
conversation carries the phone's bottom bar. Compact width (Slide Over, narrow split) is
the phone. This is the existing rule: layout follows room, not device.

---

## C. Complete keyboard map

Base: Superhuman Mail v8, Mac Edition (PDF). **Same** means identical to Superhuman.
Everything else is justified.

Ground rules, all from how `MacKeyMonitor` already works:
- Single keys act only when Mail is the front section, no text field has focus, and no
  sheet or palette is up. A letter is never stolen from typing.
- Keys are scoped by section. Today every calendar key is global; that has to change before
  any mail key is added (`integration-map.md` §5).
- Two-key sequences use the existing 1.5-second prefix. In Mail only `G` and `I` are
  prefixes. `E` is never a prefix in Mail: it is pressed more than any other key and must
  act at once.
- These keys mean the same thing in every section of Banana: `J`/`K` next and previous,
  `C` create, `?` shortcuts, ⌘K the command menu, `Esc` back.

### Anywhere in Mail

| Key | Action | Versus Superhuman |
|---|---|---|
| ⌘K | Command menu | Same |
| `/` | Search (also ⌘F from the list) | Same |
| `Z`, ⌘Z | Undo | Same; ⌘Z added because it is Banana's undo key already |
| `?` | Keyboard shortcuts | **Differs.** v8 gives `?` to Ask AI. Banana uses `?` for shortcuts everywhere, and AI has ⌘J. |
| ⌘J | Ask about this conversation; in a composer, write or rewrite | Same |
| ⌘R | Check mail now | Banana: the section's version of the existing Refresh |
| ⌃1…9, ⌃0 | Show only account *n*; all accounts | **Differs slightly.** Superhuman switches accounts; Banana's inbox is all accounts, so the key narrows it. |
| ⌘1…9 | App sections | **Differs.** Superhuman uses these for tabs; Banana already uses them for the sidebar. |
| `Esc` | Back one level: clear selection, then close a picker, then close the conversation, then clear a filter or search | Same |

### List

| Key | Action | Versus Superhuman |
|---|---|---|
| `J` / `↓` | Older conversation | Same |
| `K` / `↑` | Newer conversation | Same |
| `Enter` / `→` | Open | Same |
| `Esc` / `←` | Back to the list | Same |
| `Tab` / `⇧Tab` | Next / previous split | Same |
| ⌘↑ / ⌘↓ | Top / bottom | Same |
| `Space` / `⇧Space` | Page down / up | Same |
| `X` | Select | Same |
| `⇧J` / `⇧K` | Extend selection | Same |
| ⌘A | Select all from here | Same |
| ⌘⇧A | Select all | Same |

### In an open conversation

| Key | Action | Versus Superhuman |
|---|---|---|
| `J` / `K` | Open the older / newer conversation | Same |
| `N` / `P` | Next / previous message | Same |
| `O` / `⇧O` | Expand message / all messages | Same |
| `Tab` / `⇧Tab` | Step through links, dates, attachments and reply buttons; `Enter` activates | Same ("cycle through links and dates"), extended to attachments and RSVP |
| ⌘O | List this conversation's links and attachments | Same |
| ⌘F | Find in conversation | Banana: standard on the Mac |
| `Space` / `⇧Space` | Scroll | Same |

### Triage

| Key | Action | Versus Superhuman |
|---|---|---|
| `E` | Done | Same |
| `⇧E` | Not done (back to the inbox) | Same |
| `H` | Snooze | Same key. **Name differs:** "Snooze", not "Remind me", because "reminder" already means a task in Banana. |
| `S` | Star | Same |
| `U` | Read / unread | Same |
| `#` | Trash | Same |
| `!` | Spam | Same |
| `⇧M` | Mute | Same |
| ⌘U | Unsubscribe | Same |
| `L` | Add or remove a label | Same |
| `V` | Move | Same |
| `Y` | Remove the label being viewed | Same |
| `[` `]` `⇧Y` | — | **Left out.** "Remove label and go to next/previous" is what `E` with a remembered direction already does; "remove all labels" is rare and risky on one key. Reachable from ⌘K. |

### Filters (toggle on the current list; `Esc` clears)

| Key | Action | Versus Superhuman |
|---|---|---|
| `⇧U` | Unread | Same |
| `⇧S` | Starred | Same |
| `⇧I` | Important | Same |
| `⇧R` | No reply | Same |

### Go to (`G`, then)

| Key | Place | Versus Superhuman |
|---|---|---|
| `I` | Inbox / Important | Same |
| `O` | Other | Same |
| `S` | Starred | Same |
| `D` | Drafts | Same |
| `T` | Sent | Same |
| `E` | Done | Same |
| `H` | Snoozed | Same (their "Reminders") |
| `M` | Muted | Same |
| `;` | Snippets | Same |
| `!` | Spam | Same |
| `#` | Trash | Same |
| `A` | All mail | Same |
| `L` | A label (opens the label picker) | Same |
| `U` | Outbox and scheduled | **Added.** Sends are held on the device, so where they wait must be one keystroke away. |

### Compose and reply

| Key | Action | Versus Superhuman |
|---|---|---|
| `C` | New message | Same |
| `R` | Reply | Same |
| `Enter` | Reply all (conversation open) | Same |
| `F` | Forward | Same |
| ⌘↩ | Send | Same |
| ⌘⇧↩ | Send and Done | Same |
| ⌥⌘↩ | Send now, no undo hold | **Differs.** Superhuman uses ⌘⇧Z, which is Redo in every Mac text field. Banana does not take keys from typing. |
| ⌘⇧L | Send later | Same |
| ⌘⇧H | Snooze after sending (if no reply) | Same |
| ⌘⇧O / ⌘⇧C / ⌘⇧B | To / Cc / Bcc | Same |
| ⌘⇧F | From | Same |
| ⌘⇧S | Subject | Same |
| ⌘⇧M | — | **Left out.** It is Morning Briefing in Banana's menu bar. `Tab` from the subject reaches the body. |
| ⌘⇧A | Attach | Same |
| ⌘⇧, | Discard draft (with Undo) | Same |
| ⌘⇧I | Move the To line to Bcc | Same |
| ⌘; | Insert snippet | Same |
| `;` + name | Insert snippet inline | Same, with one rule: the list appears only when `;` starts a word and the next letters match a snippet's name |
| ⌘⇧T | Insert free times | **Added** (section E2) |
| ⌘J | Write with AI | Same |
| ⌘D | Jump to the most recent open draft, and back | Same |
| `Esc` | Leave the composer; the draft is kept | Same |
| `⇧C` `⇧R` `⇧Enter` `⇧F`, ⌘⇧P, ⌘/ | Pop-out composer windows | **Reserved, not in v1** (section G) |
| `:name` | Emoji | **Left out.** The system picker (⌃⌘Space) already exists. |

### Formatting (in a composer)

| Key | Action | Versus Superhuman |
|---|---|---|
| ⌘B / ⌘I / ⌘U | Bold / italic / underline | Same |
| ⌘K | Link, when text is selected or the caret is in a link; otherwise the command menu | Same |
| ⌘⇧X | Strikethrough | Same |
| ⌘⇧7 / ⌘⇧8 / ⌘⇧9 | Numbered list / bullets / quote | Same |
| `Tab` / `⇧Tab` | Indent / outdent in a list | Same |
| ⌘] / ⌘[ | Indent / outdent | Same |
| ⌘O | — | **Left out.** Text colour is not in v1. |

### Calendar and plan

| Key | Action | Versus Superhuman |
|---|---|---|
| `0` | Show or hide the day pane | Same |
| `-` / `=` | Previous / next day in the pane | Same |
| `T` | Pane back to today | Same |
| `0` then `0` | — | **Left out.** The week is the Plan section, ⌘1. |
| `B` | Create an event from this email | Same |
| `A` | Add to plan: a task or a time block linked to this conversation | **Added** (section E1). `A` is unused in Superhuman's map. |
| `I` then `Y` / `N` / `M` | Reply Yes / No / Maybe to an invitation | **Added.** The planner uses `E` then `Y`/`N`/`M`, which cannot work where `E` means Done. I suggest `I` works in both sections and `E`-then stays in Plan as an alias. |

### Open decisions about existing Banana keys

- **⌘N** is "New event" from anywhere today. A mail user will expect ⌘N to mean a new
  message while in Mail. Recommendation: ⌘N makes a new item of the current section, and
  "New event" stays available everywhere through ⌘K.
- **`/`** opens the shortcut sheet in the planner as an alias of `?`. In Mail it must be
  search. Recommendation: drop the alias in the planner too, so `/` means search wherever
  there is something to search.

### iPad with a hardware keyboard

The same map. Holding ⌘ shows the system's shortcut overlay, which should list the ⌘ keys;
the single keys are listed in the `?` sheet. Single keys act under the same condition: no
text field has focus.

### The ⌘K menu in Mail

The existing rule holds: with nothing typed, commands are grouped; while typing, one ranked
list. The current section's groups come first. Commands that need a conversation appear
only when one has the cursor or is open, as invitation replies already do in the planner.

| Group | Commands (key) |
|---|---|
| Conversation | Mark Done (`E`) · Mark not done (`⇧E`) · Snooze… (`H`) · Add to plan… (`A`) · Create event… (`B`) · Star (`S`) · Mark unread (`U`) · Label… (`L`) · Move… (`V`) · Remove label (`Y`) · Remove all labels · Mute (`⇧M`) · Unsubscribe (⌘U) · Trash (`#`) · Spam (`!`) · Copy link to conversation · Open in Gmail · Show original · Print |
| Reply | Reply (`R`) · Reply all (`↵`) · Forward (`F`) · Ask about this conversation (⌘J) |
| Invitation (only on an invitation) | Reply Yes (`I Y`) · Reply No (`I N`) · Reply Maybe (`I M`) · Show in Plan |
| Compose | New message (`C`) · Insert snippet (⌘;) · Insert free times (⌘⇧T) · Send later… (⌘⇧L) · Attach file (⌘⇧A) · Discard draft (⌘⇧,) · Write with AI (⌘J) · Save as snippet |
| Go to | Important (`G I`) · Other (`G O`) · each custom split · Starred (`G S`) · Drafts (`G D`) · Sent (`G T`) · Done (`G E`) · Snoozed (`G H`) · Outbox and scheduled (`G U`) · All mail (`G A`) · Spam (`G !`) · Trash (`G #`) · Label… (`G L`) · Snippets (`G ;`) · Next split (`Tab`) · Previous split (`⇧Tab`) |
| Filter | Unread (`⇧U`) · Starred (`⇧S`) · Important (`⇧I`) · No reply (`⇧R`) · Has attachment · From this sender |
| Select | Select all from here (⌘A) · Select all (⌘⇧A) · Mark all Done · Get me to zero (Done for everything older than 7 days) |
| Splits | New split from this sender · New split from this domain · Save this search as a split · Edit splits |
| Day | Show day (`0`) · Today (`T`) · Next day (`=`) · Previous day (`-`) |
| Mail | Check mail now (⌘R) · Search (`/`) · Show only *account* (⌃*n*) · Mail settings (⌘,) · Keyboard shortcuts (`?`) · Undo (`Z`) |

Rows made from what is typed, above the matches:
- A date or time ("fri 9", "3 days") → "Snooze until Fri 9 Oct, 09:00". The parser exists
  (`CommandMenuDateParser`).
- A person's name or address → "New message to Sam Lee" and "Mail from Sam Lee".
- A label's name → "Go to *label*" and, with a conversation, "Label as *label*".
- Anything else → "Search mail for '…'".

---

## D. Screens

For each: what is on it, the order of importance, the references (numbers from 0.3), and
what the design system already supplies. **DS ✓** marks an existing pattern; **DS +** marks
a role that would have to be added to `DS` (rule zero: views name roles, never numbers).

Two arrangements, as everywhere in Banana: **compact** (iPhone; a narrow iPad split) and
**regular** (Mac; a full iPad). No third layout.

### D1. Inbox list

**What is on a row, in order of importance**
1. Who it is from. Semibold when unread, regular when read.
2. What it is about: the subject.
3. One line of what it says: the snippet. Replaced by a *reason line* when there is one:
   "Snoozed on Mon · no reply", "Sends Thu 08:00", "Draft", "Couldn't send".
4. When: the date, in tabular digits, secondary.
5. State glyphs, in a fixed order so each has a fixed place: attachment, invitation,
   returned snooze, star. A thread count as a small number after the sender ("Sam, Jane 3").
6. Unread: a dot in the leading gutter, in `info` blue. Not the accent: the accent means
   "now" and "selected" in Banana, and unread is neither.

No avatars in lists. They cost a network fetch per sender, leak which mail was looked at,
and the text hierarchy does the work (ref 28, and Apple Mail's default). A 32-pt monogram
appears in the conversation header only.

**Compact (iPhone)**
- Three lines: sender and date; subject and glyphs; snippet. About nine rows visible.
- Above the list: the split chips (D6), then one status line only when the list is not live
  ("Offline · 3 changes waiting", "Checked 14 min ago").
- Floating compose button, bottom trailing. Search is revealed by a short pull down.
- Refs: 1 (gutter dot, chips), 3 (weight plus dot), 2 (glyph placement), 5 (thread count).
- DS ✓ rows at least 44 pt; `DS.Row.statusDot` 8 pt for the unread dot; `StatusDot` and
  `ConnectionStatus` for the status line; `toastHost()` per tab.
- DS + `DS.Mail` roles for the row's line spacing and gutter width.

**Regular (Mac, iPad)**
- One line, three columns: sender (fixed width) · subject then snippet in secondary,
  truncating · date (fixed width, right-aligned). About 25 rows on a 13-inch screen.
- Rows are grouped by date under eyebrow labels (TODAY, YESTERDAY, LAST 7 DAYS).
- The cursor row has the selection fill and a 3-pt accent spine. Its date is replaced by
  three quick actions (Done, Snooze, More) in the same fixed width, so nothing shifts.
- Header, 44 pt: split tabs with counts at the leading edge; search and compose at the
  trailing edge.
- The right pane, when shown (`0`), is the day (E2). It reuses the Mac shell's existing
  in-content side panel, the one the event inspector and Share Availability use.
- Refs: 28 (the whole arrangement), 30 (quick actions swap in place), 44 (count after
  sender).
- DS ✓ panel rows 32–36 pt; the 44-pt header; `DS.Palette.selection` with the accent as a
  mark rather than a fill ("a quiet fill, not a slab of accent"); `DS.Typeface.eyebrow` for
  date groups; the right-hand panel in `MacRootView`.
- DS + a cursor-spine role; a fixed sender-column width.

**Bundles in Other** (v1.1, but the row should be designed for it now). Mail from one
automated sender on one day collapses to a single row with a count, and Done clears the
lot. Refs: 5, 7; Apple Mail's sender digest.

### D2. Conversation

**What is on it, in order**
1. The subject, once, at the top. Label chips beside it.
2. For a long thread only (three or more messages, or more than a screen of text): one line
   saying what it is about and what is being asked, written on the device. It is marked as
   generated and can be expanded. Short threads get nothing: reading them is faster.
3. An invitation card, when the conversation is one (E3).
4. The messages, oldest first. The newest, and any unread, are open. Earlier read messages
   are one line each (sender, first line, date); more than three of those in a row fold
   into "5 earlier messages".
5. Within a message: who to whom on one line ("Sam to me, Jane"), the time, the body.
   Quoted text and signatures are folded behind "…".
6. Attachments as chips under the message that carries them: icon, name, size. A chip shows
   whether the file is on this device.
7. The reply affordance: on the Mac, a one-line "Reply to all…" field as the last card; on
   touch, the bottom bar.

**Compact**: pushed full-screen; top bar is Back and nothing else. Bottom bar: Done,
Snooze, Reply (wide), More (B2 rule 9). Refs: 12 (bar), 11 (cards, wide Reply), 10
(collapsed rows, "See More"), 9 (label chip, recipients on demand).

**Regular**: a centred column capped at a reading measure; back, older and newer controls
at the top leading corner mirroring `Esc`, `J`, `K`. The right pane shows the day, or with
no dates in play, other recent mail with the same person (found locally). Refs: 31, 32.

- DS ✓ `Radius.card` for message cards with `Space.l` insets; `Radius.chip` for label and
  attachment chips; label colour as a wash of the label's own colour run through the same
  normalisation as calendar colours (`calendarTint`), never as text colour; the readable
  width cap that `SleepView` already uses; `DS.Row.avatar` 32 pt.
- DS + a reading-measure role; a `DS.Palette.Feature.mail` colour for Mail's icon tile.

**Rendering, because it decides the speed budget.** A message between people is drawn as
native text. Only designed HTML (newsletters, receipts) is drawn in a web view, inside a
frame whose height is already known from the last time it was laid out. Headers and
collapsed rows are native and appear first. Remote images load when a conversation is
opened and are kept; known tracking pixels are dropped. The consequence, stated honestly:
a newsletter never opened while online has no pictures offline.

### D3. Compose

**What is on it, in order**
1. To. Chips; autocomplete in two columns, name and address, with the typed part
   emphasised (ref 33).
2. Cc and Bcc: hidden until asked for.
3. From: shown only when there is more than one account or alias. A reply is always from
   the address the mail was sent to.
4. Subject. In a reply, hidden until asked for (⌘⇧S).
5. Body. Quoted thread folded.
6. Footer or accessory: **Send**; Send later; Snooze if no reply; then tools: snippet,
   attach, free times, AI, discard.
7. Read-back: once a time is chosen, the button says **Schedule** and the footer says
   "Sends Thu 08:00 · Snoozes Thu 09:00 if no reply" (ref 37).

**Compact**: a sheet; identity as the title when there is a choice (ref 17); the tools and
Send in the bar above the keyboard (ref 20), with formatting appearing there only while
text is selected (ref 18).

**Regular**: a reply is the last card of the conversation with an accent spine (ref 32). A
new message is the same card alone on the conversation surface. A strip of key hints sits
under it (ref 34).

- DS ✓ `KeyCap` and `KeyCombo` for the hints; the toast for "Sent · Undo" and "Draft
  discarded · Undo" (ref 41).
- Not DS-conformant on purpose: FUTURE.md reserves Cancel/Done for edit sheets. A composer
  is not an edit sheet: closing it keeps the draft, so there is nothing to cancel.

### D4. Search

**What is on it, in order**
1. The field, focused, keyboard up.
2. Before typing: recent searches, then people (ref 25).
3. While typing: suggestion rows first ("From Sam Lee", "Label: Invoices", a saved split),
   then results in the list's own row style with the matched words emphasised (ref 26).
4. Filter chips that are menus, directly under the field: From, To, Has attachment, Unread,
   Label, Date (refs 26, 27). A typed operator (`from:sam`) turns into the same chip.
5. One scope line: "All mail · 1,204". While the mailbox is still downloading: "On this
   device back to 12 Aug · Gmail is searching the rest…". Offline: "This device only".
6. Results from Gmail's servers are added below what is already showing. They never
   reorder rows the cursor could be on.

One grammar serves search, splits and filters: a subset of Gmail's operators that can be
evaluated on the device (`from:` `to:` `cc:` `subject:` `label:` `category:`
`has:attachment` `is:unread` `is:starred` `filename:` `list:` `older_than:` `newer_than:`
`OR` `-` and quotes). A search can be saved as a split.

**Compact**: full-screen. **Regular**: the field takes the place of the split tabs in the
header; the list below becomes the results; `Esc` clears, then leaves.

- DS ✓ the existing settings search shows where a result lives; the same idea applies to
  the label or mailbox a result is in.

### D5. Snooze and Send-later pickers

One picker, two uses, as in Superhuman (refs 35, 36).

**What is on it, in order**
1. A free-text time: "Try: 8am, 3 days, fri". The top row shows how it was read ("Fri 9
   Oct, 08:00").
2. Presets, each with its resolved time on the right in tabular digits (refs 21, 24): last
   used; later today; tomorrow morning; this weekend; next week. Five, not more.
3. Banana-only presets, from the plan (E7): "After Standup · 09:30", "Tomorrow, first free
   hour · 10:00".
4. Snooze only: "If no reply | Regardless" (ref 22), shown when the newest message is
   the owner's.
5. Send later only: the late rule ("Send as soon as possible | Ask me if over 30 min
   late"), and one honest line: "Sent by whichever of your devices is awake. Mac: awake
   now." Plus the time zone when it differs from the recipient's usual one (ref 23).
6. Unschedule or Unsnooze as the last row when there is something to undo (ref 36).

**Regular**: the command-menu chrome, centred, with a key-hint footer. **Compact**: a
half-height sheet; "Pick a date and time" pushes a wheel inside the sheet.

- DS ✓ `MacCommandMenu`'s frame, `Radius.panel`, footer hints; `TimeRangeText` for every
  time shown; `CommandMenuDateParser` for the free text.

### D6. Split and label navigation

**Default splits**, in order. They partition the inbox: every conversation is in exactly
one, the first whose rule it matches. No "also show in" option.

| Split | Rule | Note |
|---|---|---|
| Important | In the inbox, Gmail category Primary, and not sent by a mailing list (no `List-Unsubscribe` or bulk-precedence header) | The nearest client-only equivalent of Superhuman's Important. |
| Calendar | Invitations and replies to them | Mostly clears itself (E3). |
| Other | Everything else in the inbox | |

Library of optional splits: VIPs (a list of people), Newsletters, Receipts, GitHub, one per
label, one per account. A custom split is "from this sender", "from this domain", or a
saved search.

**The mailbox list** (everything that is not a split): Starred, Drafts, Sent, Done,
Snoozed, Outbox and scheduled, All mail, Spam, Trash; then labels, nested, each with its
colour; then accounts. Same order as Gmail's drawer (ref 8), so nothing has to be
relearned.

- **Compact**: chips under the title for splits (ref 1). Tapping the title opens the
  mailbox list as a sheet.
- **Regular**: text tabs with counts in the header (ref 28). The mailbox list opens as a
  popover from a button at the head of the tabs, and through `G` keys and ⌘K. There is no
  second sidebar inside Mail: Banana already has one.
- Which split and mailbox is showing, and each one's cursor, live in `ShellNavigation`, not
  in view state (the existing rule; the iOS tree is discarded in the background).

**Where Mail sits in the app.** On the Mac and iPad it is a sidebar row, second after Plan
(the ⌘ numbers follow sidebar order, so it becomes ⌘2). On the iPhone the tab bar is full
and the IA record forbids a sixth tab, with a UI test asserting it. Mail is used more times
a day than anything but Plan, so it needs a tab; one of the five has to give up its seat.
That is the owner's decision and it should be made before any phone screen is drawn.

### D7. Settings

A "Mail" row among the feature rows on the Settings root, with the current value trailing
("2 accounts"). One page, two levels at most.

| Group | Rows (trailing value) |
|---|---|
| Accounts | The existing account cards gain a Mail toggle and a status ("Live", "Downloading 62%", "Sign in again"). |
| Inbox | Splits (3) · Done marks as read (On) · Reply key (Reply all) |
| Sending | Undo send (10 seconds) · Send later ("Any awake device") · Signature (From Gmail) · Snippets (12) |
| Notifications | Notify me about (Important) · a footnote: "This iPhone learns about new mail when it checks. With your Mac awake, within a minute." |
| This device | Keep on this iPhone (All mail / Last year) · Attachments (Recent) · Remote images (On open) · Storage used (3.2 GB) |
| Keyboard | Shortcuts (opens the `?` sheet) |

- Everything syncs between devices except the "This device" group. That matches the
  existing rule: the only per-device things are the device's own, and downloads are named
  there.
- DS ✓ `IconTile`, `DS.Row`, trailing current value, footnotes under non-obvious toggles,
  the account card with per-service toggles, `StatusDot` with a word, the permission
  priming template for notifications (asked when a notification setting is first turned
  on, not at launch).

### D8. States

**Empty split.** One line, one hint, one action, per the design system.
- "Important is clear." · "Other has 12." · [Go to Other]
- With the whole inbox clear: "Inbox clear." · "Next: Standup, 09:00." · [Open Plan]. The
  reward for an empty inbox is the rest of the day, which Banana happens to know. No
  photograph (ref 39), no congratulation (ref 40).

**Offline.** Nothing is disabled. The status line reads "Offline · 3 changes waiting" with
an `off` dot. Send becomes "Send when online". Search says "This device only". Changes made
offline look exactly like changes made online.

**First sync.** The inbox is readable within seconds: newest conversations first, then
their bodies, then the last 30 days, then everything backwards in time.
- Progress is a card in place at the foot of the list, never a blocking screen:
  "Downloading mail · 12,400 of about 86,000 · searchable back to 12 Aug".
- Rows whose content has not arrived are skeletons with the row's own geometry, so nothing
  jumps.
- Search works throughout and says what it covers (D4).
- "Get me to zero" is offered once, on the first visit, as a card: "Mark everything older
  than 7 days Done? You can undo it."

**Errors.**
- Sign-in expired: the account's dot turns to "Sign in again", and one alert card sits at
  the top of the list with a single button. One alert card at a time, as on Today.
- A send failed: the message stays in Outbox with the reason in `danger` on its reason
  line, and a toast offers Retry (the toast already supports a Retry action).
- A change was refused by Gmail: the row comes back and a toast says which and why.
- Rate limits and brief network failures: silent retry. The status line mentions it only
  after a minute ("Sync paused · retrying").
- A conversation whose body is not on the device while offline: headers and snippet are
  shown, with "Not on this iPhone yet. It will download when you're online."

- DS ✓ for all of it: "layouts never jump", skeletons with the result's geometry,
  background work as a card, the empty-state rule, `StatusDot`, `ToastCenter` with Undo or
  Retry.
- One gap: `ToastCenter` holds one change at a time and commits it when the next arrives.
  Rule B1.14 (undo back through the session) needs a history behind the same toast.

---

## E. Banana-only advantages

Ranked by value: how often it would be used, times how far it is beyond what Superhuman can
do.

**1. An email becomes a task or a time block on the plan (`A`).**
The conversation is linked to a reminder or a block of time on the timeline, and leaves the
inbox, because the commitment now lives on the day. This is a different thing from snooze:
snooze brings mail back to be looked at again; a task puts the work at a time, next to the
meetings it has to fit around. HEY needed a separate "Reply Later" pile for this; Banana
already has the place. It also avoids the weakest part of client-held snooze: a task is
an Apple Reminder, and Reminders syncs and notifies on every device without Banana running.
Builds on `RemindersService.createTask` and the anchored-timing work.

**2. The real day beside the reply (`0`), and free times typed in for you (⌘⇧T).**
Superhuman shows a calendar. Banana shows the day as Banana knows it: meetings, travel time
and leave-by, tasks, workouts, busy blocks. When a message names a date, the pane goes to
it. ⌘⇧T inserts "I'm free Tue 14:00–16:00 or Wed 10:00–12:00" from `AvailabilityFinder`,
with the offered slots outlined on the pane, which is the existing Share Availability flow
moved into the composer. What it cannot do is Superhuman's live booking link.

**3. Invitations answered in place, with the conflict visible.**
An invitation shows a card: the time, a strip of that day with the new event drawn in
outline, what it collides with ("overlaps Standup 09:00–09:30"), and Yes / No / Maybe.
The reply goes through the calendar (`InvitationReply`), not through mail. Then one general
rule: **mail whose question has been answered elsewhere in Banana marks itself Done.**
Answer in Plan, and the email leaves the inbox; answer in Mail, and the block restyles.

**4. Mail with the people in your next meeting.**
The event inspector, and the "next" card on Today, list recent conversations with that
meeting's attendees, found by joining the calendar to the local mail index. Superhuman
lists "AI Meeting Prep" as planned; the plain version needs no model at all.

**5. Bookings feed the trip.**
Flight, hotel and ticket confirmations carry what `FlightParser` and the travel features
already want: flight number, airports, confirmation code, address, the boarding pass PDF.
Many airlines embed this as structured data in the email, so no model is needed for the
common case. The trip on the plan gains "UA 123 · ABC123 · boarding pass". A booking with
no calendar event can offer to make one.

**6. Summaries and drafts on the device.**
A one-line summary for long threads, a first draft for a reply, "what is being asked of me"
turned into suggested actions (Reply, Add to plan, Create event). On the device nothing
leaves it. Honest limits: the on-device model reads little at a time, so long threads are
summarised in parts; the better model is Apple's Private Cloud Compute, which does leave
the device and is quota-limited (`Intelligence.swift` already routes between the two and
words the privacy note). Dates are never worked out by the model: `EventPhrase` does that.

**7. Snooze until a moment, not just a time.**
The picker can offer times that come from the plan: "after Standup", "after my workout",
"tomorrow's first free hour". The anchored-timing model for reminders already expresses
this.

**8. Mail on Today and in the morning briefing.**
One card, three rows at most, with a footer link: "3 need a reply · 1 snooze returns at
10:00 · All". Refs: Outlook's next-meeting card in the inbox (ref 2) is the same idea
pointed the other way.

**9. A message, or a selection from one, saved as a note** with a link back.

---

## F. Speed as a design requirement

The test of every budget: it must hold offline, on the phone, with the whole mailbox
downloaded.

| Interaction | Target | Ceiling | What makes it reachable |
|---|---|---|---|
| Key or tap → first visible response (cursor moves, row starts to leave) | Next frame: 8 ms at 120 Hz, 16 ms at 60 Hz | 50 ms | The change is applied to local state on the same run-loop turn. The network is never awaited. |
| `E` → row gone, cursor settled | 100 ms | 150 ms | A short, interruptible collapse. Input is never blocked by it (B1 rule 13). |
| Holding `J` | Follows key repeat with no dropped frame | — | Fixed row heights; the list observes only its own split's rows. |
| Open a conversation that is the next or previous one | Next frame | 50 ms | The two conversations either side of the cursor are loaded and laid out in advance. |
| Open any cached conversation | 50 ms | 100 ms | Headers and plain-text bodies are native. HTML bodies fill a frame whose height is already known. |
| ⌘K, or a picker, opens | Next frame | 50 ms | Commands are a static list per section. |
| Composer ready, caret blinking | 50 ms | 100 ms | The composer is native; the quoted thread is folded and not laid out until opened. |
| Search results per keystroke | 30 ms | 100 ms | A local full-text index; prefix queries; server results arrive later and only append. |
| Switch to the Mail tab → real rows | The same frame as the switch | 100 ms | The list's first screen is kept as a snapshot; the store is opened off the main thread at launch and is never needed for the first frame of Plan. |
| Cold launch from a mail notification → that message readable | 600 ms | 1 s | The notification carries the conversation's id; the body is already on disk. |
| Send → composer gone | Next frame | 50 ms | The send is a row in Outbox; the network call comes later. |
| New mail appears (app in front) | Within 30 s of arrival | 60 s | A cheap change-history poll every 15–30 s. |

**Design choices that follow.**
- **Everything on screen is read from the local store.** A view never asks the network for
  anything and never waits on it.
- **Every change is optimistic and queued.** Apply locally, record the intent, send later,
  retry on failure, and roll back with a plain message only if Gmail finally refuses. This
  is Superhuman's "modifier" queue and Banana's own "show the change at once, fix up on
  error" rule.
- **No spinner for anything that is cached.** A spinner is allowed only for something that
  has never been on this device.
- **Nothing jumps.** Rows have fixed heights. Incoming mail does not move the cursor row
  (B1 rule 21). Late content fills a frame of the right size.
- **Animation is short, interruptible and optional to the input.** On the Mac, opening and
  closing a conversation has none.
- **Work is done at sync time, not at view time.** Snippets, the plain-text form of each
  body, the search index, thread counts and split membership are all computed when mail
  arrives.
- **The list observes little.** Banana has had CPU kills from views that re-rendered at the
  rate of I/O. The existing rule, "publish at the rate of meaning", applies: sync progress is a
  narrow observable of its own, and a row redraws only when that row changes.
- **Speed is measured in the app,** against the table above, with the existing signposts
  and render counters, on a real phone in a Release build.

---

## G. What to leave out of v1, and why

| Left out | Why |
|---|---|
| Read statuses | Impossible without a server; unreliable since Mail Privacy Protection; "if no reply" does the job. |
| Anything for teams | One person. |
| Providers other than Gmail | The brief. This design depends on Gmail's labels and categories. |
| A reading pane; tabs; pop-out composer windows | "The window shows one thing" is the rule that makes the keys simple. The pop-out keys are reserved. |
| Mailbox-wide AI questions; drafts written overnight; AI labels | Server-scale models and indexes. Local search and Gmail's categories cover the need. |
| Bundles in Other | Valuable (section 0.2) but a second list model. v1.1, with the row designed for it now. |
| A screener for first-time senders | Worth having later (ref 15). Needs a new mail state and its own triage surface. |
| Swipe customisation | Two fixed actions a side match Superhuman's defaults. Notion Mail's settings screen (ref 6) is the model when it comes. |
| Arbitrary Gmail search operators in splits | A split must be evaluable on the device. The subset in D4 is the contract. |
| Editing Gmail filters | Gmail's filters are reachable through the API and are a real asset (they run with every device asleep), but a filter editor is a product of its own. v1 creates one only for "unsubscribe and block". |
| Text colour, tables, image resizing in the composer | Rare in person-to-person mail; each adds formatting bugs. |
| Signature editing, vacation responder, delegation, confidential mode, encryption | Use Gmail's signature as it is; the rest are Gmail settings, used rarely, available on the web. |
| Contact cards with social profiles | Superhuman's come from its servers. The right pane shows recent mail with the person instead. |
| Session-long undo on the phone | The toast is enough for a thumb. The Mac has it. |
| Watch app, widgets, notification actions beyond Done and Snooze | After the core loop is proven. |
| Onboarding theatre | Sign in, choose accounts, see mail arrive, a coach line for `E` and ⌘K, and "Get me to zero". Nothing else. |

Not left out, though Superhuman lacks it: **one inbox across accounts.** With every account
in one local store, an account is just another filter, and its absence is a standing
complaint about Superhuman.

---

## H. Sources

**Superhuman, primary**
- Superhuman Mail Keyboard Shortcuts v8, Mac Edition (PDF, read directly):
  https://download.superhuman.com/Superhuman%20Keyboard%20Shortcuts.pdf
- Why Superhuman Mail is built for speed: https://blog.superhuman.com/superhuman-is-built-for-speed/
- Architecting a web app to "just work" offline: https://blog.superhuman.com/architecting-a-web-app-to-just-work-offline-part-1/
- Superhuman Mail for iPhone, now faster than ever: https://blog.superhuman.com/superhuman-for-iphone-now-faster-than-ever/
- Feature spotlight: Superhuman Calendar: https://blog.superhuman.com/feature-spotlight-superhuman-calendar/
- Listed by search, not read: https://blog.superhuman.com/instant-event/ ·
  https://blog.superhuman.com/find-time/ · https://blog.superhuman.com/inbox-zero-in-7-steps/ ·
  https://blog.superhuman.com/the-fastest-way-to-inbox-zero-a-single-coaching-session/

**Superhuman help centre** (search summaries only; direct fetch returned 403)
- Default Split Inbox: https://help.superhuman.com/hc/en-us/articles/38458392810643-Default-Split-Inbox
- Custom Split Inbox: https://help.superhuman.com/hc/en-us/articles/38458483333907-Custom-Split-Inbox
- Remind Me: https://help.superhuman.com/hc/en-us/articles/43822934607251-Remind-Me
- Auto Reminders & Auto Drafts: https://help.superhuman.com/hc/en-us/articles/40144492186515-Auto-Reminders-Auto-Drafts
- Undo: https://help.superhuman.com/hc/en-us/articles/47278253460499-Undo
- Smart Send: https://help.superhuman.com/hc/en-us/articles/38456924099347-Smart-Send
- Offline Access: https://help.superhuman.com/hc/en-us/articles/38458300297875-Offline-Access
- Read Statuses and Recent Opens Feed: https://help.superhuman.com/hc/en-us/articles/38457566867347-Read-Statuses-and-Recent-Opens-Feed
- Snippets: https://help.superhuman.com/hc/en-us/articles/38450007523475-Snippets
- Create Event: https://help.superhuman.com/hc/en-us/articles/46005621734669-Create-Event
- Mobile Navigation: https://help.superhuman.com/hc/en-us/articles/38458290528531-Mobile-Navigation
- Customizing Swipes and Triage Bar: https://help.superhuman.com/hc/en-us/articles/38458431506067-Customizing-Swipes-and-Triage-Bar
- Email Notifications: https://help.superhuman.com/hc/en-us/articles/44790851872019-Email-Notifications
- Achieve Inbox Zero: https://help.superhuman.com/hc/en-us/articles/46005833597709-Achieve-Inbox-Zero
- Mark Done: https://help.superhuman.com/hc/en-us/articles/47439134613773-Mark-Done
- Speed Up With Shortcuts: https://help.superhuman.com/hc/en-us/articles/45191759067411-Speed-Up-With-Shortcuts
- Superhuman AI: https://help.superhuman.com/hc/en-us/sections/46130591612173-Superhuman-AI

**Superhuman, third party**
- Shortcut lists used to cross-check the PDF: https://usethekeyboard.com/superhuman/ ·
  https://pie-menu.com/shortcuts/superhuman (this one has J and K the wrong way round) ·
  https://danielmiessler.com/blog/my-favorite-superhuman-shortcuts
- AI feature review: https://www.fast.io/resources/superhuman-ai-review-2026.md
- Onboarding teardown (its figures are unverified and not relied on):
  https://www.flowjam.com/blog/superhuman-onboarding-teardown-30-minute-wow-session
- Reviews and alternatives: https://mailmeteor.com/blog/superhuman-alternatives ·
  https://www.asianefficiency.com/email-management/superhuman-vs-shortwave/

**The field**
- Mimestream: https://mimestream.com/ · https://mimestream.com/help/user-guide/snoozing ·
  https://mimestream.com/ios-beta
- Shortwave: https://www.shortwave.com/pricing/ · https://shortwave.com/docs/migrations/migrating-from-superhuman/
- Spark: https://sparkmailapp.com/features/smart_inbox · https://sparkmailapp.com/features/priority-email
- Notion Mail: https://www.eesel.ai/en/blog/notion-mail-overview ·
  https://www.notion.com/help/guides/organize-your-inbox-with-notion-ai-auto-labeling ·
  shutdown: https://www.androidauthority.com/notion-mail-is-shutting-down-3681674/
- Apple Mail: https://knak.com/blog/apple-intelligence-ios18-2/ ·
  Send Later being on-device: https://iphonelife.com/content/how-to-send-email-specific-time-iphone
- Gmail swipe actions: https://workspaceupdates.googleblog.com/2019/03/take-action-faster-with-customizable.html
- HEY: https://www.hey.com/features/ · https://thesweetsetup.com/hey-email-disrupted-my-email-workflow/
- Fastmail offline: https://www.fastmail.com/blog/offline-architecture/ ·
  https://www.fastmail.com/blog/fastmail-works-offline/
- Spike: https://www.spikenow.com/glossary/email/conversational-email/

**Platform limits**
- Gmail push needs Cloud Pub/Sub: https://developers.google.com/workspace/gmail/api/guides/push
- Background refresh is at the system's discretion: https://developer.apple.com/forums/thread/770479 ·
  https://developer.apple.com/forums/thread/725675
- CloudKit subscriptions and visible pushes:
  https://www.hackingwithswift.com/read/33/8/delivering-notifications-with-cloudkit-push-messages-ckquerysubscription
- Everything else about the Gmail API: `gmail-api.md` in this folder (§5.2 sending once,
  §6.6 no snooze or schedule, §10 no push to devices, §11 search operators).

**This codebase** (read, not changed)
- `docs/design/DESIGN-SYSTEM.md`, `ADAPTIVE-LAYOUT.md`, `FUTURE.md`, `IA-2026-09.md`
- `Shared/BananaDesign.swift`, `Banana/Views/MacCommandCenter.swift`, `Banana/Views/RootView.swift`
- `Banana/Model/ToastCenter.swift`, `AppSection.swift`, `Intelligence.swift`,
  `AvailabilityFinder.swift`, `EventPhrase.swift`, `FlightParser.swift`,
  `InvitationReply.swift`, `RemindersService.swift`
- `integration-map.md` in this folder (§4 the five-tab cap, §5 key scoping, §8 no push
  between devices)

**Mobbin.** All 47 screens are linked in section 0.3.
