# Code review — package P03a, Gmail's wire models, addresses and headers (uncommitted)

Worktree `~/orca/workspaces/gtfuwgth/stingray`, branch `google-email-functionality`,
on top of `532f7b1`. Read-only review by reading the code. Nothing was built or run, so the
implementer's numbers (1,923 tests, 4,260 repeats, Thread Sanitizer, Release builds) are not
confirmed here.

**The document moved during the review.** The architect's rulings on the seven questions
(section 22, rows L1–L10; 10.6; 10.8; 5.6; appendix A; the P03a entry's "Before it is
committed") reached `MAIL-ENGINE.md` at 06:20. The sources were last written at 05:38, so
**the code reviewed is the code from before the rulings**.

Files: `Banana/Model/Mail/` — `MailAddress` (899), `GmailWire` (677), `MailAuthRules` (208),
`MailHeaders` (182), `MailFileName` (163), `Testing/Hostile/MailHostileMessages` (180); nine
test classes, 213 tests.

## Verdict

**Commit with the listed fixes.** No BLOCKER.

- The eight changes the entry lists under "Before it is committed" are not in the code. They
  come first, with what reading the code adds.
- Four MAJOR of my own, all on who a message is shown to be from, and none touched by the
  rulings. Twelve MINOR.

The package is careful where it says it is: every reader is iterative and linear, nothing can
index out of range, a name is decoded only after the list is split, and what was cut is said.
What is wrong is at the three places where the reader is *kinder* than its own rule.

---

## Ruled, and not yet in the code

1. **`MailAuthRules` (L1).** Reads `header.d` only (`MailAuthRules.swift:49-54`); a test pins
   that `header.i` authenticates nobody (`MailAuthRulesTests.swift:195-202`). The implementer
   is right about Gmail, and the ruling — `dmarc=pass` with `header.from` first, then
   `header.d` or the domain after `header.i`'s last `@`, then SPF — is right. As built the
   DKIM branch can only ever be met by text Gmail did not mean as `header.d`. See MAJOR 4.
2. **`MIMEStructure` (L2).** No `htmlPartID`, `plainPartID`, `invite`, `cut`
   (`GmailWire.swift:609-677`). See MINOR 4 for two more things about the shape.
3. **`cleaned` (L3).** Still the two lists (`MailFileName.swift:22-44`). The ruling says an
   address holding any default-ignorable character is not one, "and that stands" — it does
   not, yet: MAJOR 3.
4. **Mixed scripts (L4).** Still the hand table and whole-name test
   (`MailAddress.swift:208-271`). The ruling is right. Apply it to an address's local part
   too (MAJOR 3).
5. **Unknown charset (L6).** Still left as written (`MailAddress.swift:827`). Either answer is
   safe: a name is judged after it is decoded, so a made-up charset buys a sender nothing he
   could not write in UTF-8.
6. **`MessageHeaders` past the cut (L7).** Still stops at line 1,000 (`MailHeaders.swift:61`).
7. **The two envelopes (L9).** Not declared.
8. **The fence test (L10).** Not written. The fence itself is there
   (`MailHostileMessages.swift:1, 180`).

---

## MAJOR

### MAJOR 1 — without brackets, a display name can become the sender's address

`MailAddress.swift:560-581` (`flush`, the no-bracket path), `:515-520`; the contract at
`:340-348`.

The reader's rule is that a name is never an address: "words before an angle bracket are the
name, always". That holds when there are brackets. When there are none, every word is tried
as an address — **a quoted string among them**, which by the standard can only be a name —
and every word that passes becomes a mailbox.

| `From:` as written | What the reader returns |
|---|---|
| `"ceo@victim.example" attacker@evil.example` | two mailboxes, `ceo@victim.example` **first** |
| `"ceo@victim.example" x` | **one** mailbox: `ceo@victim.example`, named "x" |
| `"ceo@victim.example": a@evil.example;` | two mailboxes, the victim first (a standard reader sees a group of one: `a@evil.example`) |
| `ceo@victim.example a@evil.example` | two mailboxes, the victim first (pinned: `MailAddressListTests.swift:59-63`) |

The second row makes a sender out of text that holds no address at all outside its quoted
name. The first and third are the dangerous ones: if Gmail takes the bare address as the
sender and authenticates `evil.example`, the screen has the victim's address in the sender's
place and a pass to go with it. Which of these Gmail accepts is not known (below); the
reader must not depend on it.

Smallest fix: remember which words came from quotes, and never try those as an address. With
that, row 1 is one mailbox, `attacker@evil.example`, whose *name* is an address and is not
shown; row 2 is unreadable; row 3 likewise one mailbox. Tests for the four rows.

### MAJOR 2 — nothing says who the sender is when `From` is not exactly one mailbox

`MailHeaders.swift:132-144`; `MailAddressList` (`MailAddress.swift:296-323`); 10.8's "A sender
that cannot be read".

The list keeps everything in order — "which one a screen is to believe is not decided here"
(`MailHeaders.swift:16-17`). It is decided nowhere. The ruled text names three ways a sender
is unreadable (no `From`; no valid address; cut before its address) and not the fourth:
**more than one**. The index has one `from_addr`, and the next package will write
`from.mailboxes.first`. Every one of these puts the forged address first:

- `Sam <sam@plan.example> <x@evil.example>` (pinned as two mailboxes: `MailAddressListTests.swift:204-208`)
- `<sam@plan.example>x@evil.example`
- two `From` headers (joined in order, `MailHeaders.swift:136-140`)
- the rows of MAJOR 1 that remain two

Gmail is believed to refuse mail whose `From` holds no address or more than one (its SMTP
error list says so; ASSUMED). If that is so, a `From` that reads here as two is one that
Banana and Gmail read *differently* — which is exactly the case in which what Gmail
authenticated is not what the screen would show.

Smallest fix, here, because here is where the knowledge is: one reading on `MessageHeaders` —
the sender is the single mailbox of `From` when the list is complete, has exactly one mailbox
and nothing unreadable; otherwise the unreadable sender of 10.8 — and 10.8 says so. Tests:
each shape above is unreadable; no test may assert on `from.mailboxes.first` as "the sender".

For the architect, one step further and cheap: Gmail's own header names the domain it took
as the sender (`dmarc=… header.from=`). When it is there and is not the domain read from
`From`, the sender is unreadable. That closes the whole class for every domain that
publishes DMARC, whatever either parser does.

### MAJOR 3 — an address may hold a look-alike `@` and characters nobody can see

`MailAddress.swift:52-73` (`normalized`), `:116-129` (`isForbidden`).

The address is what is shown *instead of* a suspicious name, so it is the last thing that may
deceive. A name is checked after compatibility folding (`:93-98`); the address is not.

- **`noor＠plan.example@evil.example` is a valid address.** U+FF20 (fullwidth `＠`) is punctuation,
  not `@`, so the one real `@` is the last, and the local part is `noor＠plan.example`. Shown beside
  a name, or in place of one, it reads as his own address with a tail — and a narrow column
  cuts the tail. The same for U+FE6B, and for the fullwidth and small `<` `>`.
- **`sam` + U+FE00 + `@plan.example` is a valid address** that cannot be told from `sam@plan.example`. The
  filter refuses *format* characters; variation selectors and the grapheme joiner are marks,
  and the Hangul fillers (U+3164, U+115F, U+1160, U+FFA0) are letters. None is in the test's
  list (`MailAddressRulesTests.swift:38-45`). L3 rules that such an address is unreadable.
- A local part may mix Latin with Cyrillic or Greek in one word (`bоris@…`), which is the
  exact shape L4 refuses in a name.

Smallest fix: the local part gets the tests the name gets — nothing that is `@`, `<` or `>`
after folding; nothing `isDefaultIgnorableCodePoint`; no word mixing the three scripts — and
does not begin with a combining mark (which would attach to whatever the screen draws before
it). Any failure is unreadable, never repaired. While there: the ASCII characters no
unquoted local part may hold (`"`, `(`, `)`, `[`, `]`, `\`, `:`) pass today, and `<mailto:x@y.z>`
reads as the address `mailto:x@y.z`.

### MAJOR 4 — "topmost" is not enforced: the reader looks past other servers' headers for one that says it is Google's

`MailAuthRules.swift:42-46`; pinned by `MailAuthRulesTests.swift:131-138`.

The comment says "ignored, not skipped past"; the code is `first(where:)` over every
`Authentication-Results`, which skips. For mail Gmail received, its own header is above every
other, so the two readings agree. They differ for mail that did not come through Gmail's
servers — fetched by POP from another provider, imported — where that provider's header is
on top and a line the sender wrote, `Authentication-Results: mx.google.com; dmarc=pass
header.from=…`, sits below it and is now the first that "is Google's". With the new rule 1 a
forged line needs only that one result.

Smallest fix: the **first** `Authentication-Results` header of the message, and only if its
authserv-id is `mx.google.com`; anything else on top means Gmail wrote none. Turn the test
round. (A message with no other server's header and a forged one — an import — cannot be
told from a real one by any reading; say so in 10.6.)

---

## MINOR

1. **A list that was sent and could not be read is nil, the same as one that was not sent**
   (`GmailWire.swift:35-37`). For a message's labels that is right: unknown. For a page it is
   not: Gmail leaves out `history` and `messages` when there are none, so a page whose list
   arrived in a shape the reader could not take reads as "nothing happened" and the
   checkpoint moves (`:416`, `:505`; pinned at `GmailWireTests.swift:239-246`). Let the page
   types throw when the key is present and unreadable; elements stay lenient.
2. **"No `labelIds` means not read" is an unverified Gmail behaviour** (`GmailWire.swift:11-12,
   289-293`; `GmailWireTests.swift:64-69`). Google's JSON commonly omits an empty list. If a
   per-message read of a message with no labels carries no `labelIds`, its labels are unknown
   for ever, and one whose last label was removed elsewhere keeps it after a reconcile. The
   wire type cannot tell; the reader that knows it asked for one message must. A probe item,
   and a switch on the fake.
3. **The only bound on `GmailPart`'s recursion is Foundation's** (`:276-284`). The depth test
   passes because the JSON reader refuses first. If that limit ever rises, a thousand-deep
   tree is a thousand frames of this type's own `init`. Count depth in `userInfo` and throw
   past a number of our own.
4. **Two things about `MIMEStructure`, while its shape can still change.** `Attachment.size`
   is `Int`, so a part Gmail gave no size for is a file of 0 bytes (`:650`; `Part.size` is
   optional). And `Attachment.name` is "as written" and unbounded (`:644-646`), though 10.8
   has file names cleaned *when stored* so that no screen has to remember: store
   `MailFileName.safe(name)` there — bounded at 255 bytes too — and leave `Part.filename` raw.
5. **A file name can come back as a hidden file** (`MailFileName.swift:141-145`). One letter
   followed by three hundred combining marks, then `.pdf`: the cluster does not fit, nothing
   is kept, and the answer is `.pdf`. The comment says this cannot happen. Return
   `Attachment` + extension.
6. **Two source files hold a raw direction override** — `MailFileName.swift:60`, in a comment,
   and `MailHostileMessages.swift:61` — and `:71` a raw Cyrillic `а`. The rest of each line
   is drawn reversed in an editor and a diff. Write `\u{202E}` in the comment and JSON's
   `‮` / `а` in the fixtures, and have the fence test refuse the raw characters.
7. **`MailHostileMessages.all` is a closed list in a closed file** (`:23-33`). P20a, P20b and
   P21a add fixtures and cannot add to it. Name it for what it is (the seven of this package)
   and gather the sets in `MailSlices`, as 18.2 does for everything else of this kind.
8. **`displayName` is not cheap** — a compatibility fold and the system's link detector
   today, a regular expression per word after L4 (`MailAddress.swift:88-102, 197-203`). It
   must be asked once, when a message is stored, never per row of a list.
9. **One name test pins a system heuristic** (`MailAddressRulesTests.swift:110-115`):
   whether `bank.xyz` is a link is Apple's list of endings, and can change with an OS.
10. **Private-use characters stay in a name.** On Apple's systems U+F8FF draws the Apple logo.
    For the architect; `cleaned` could drop the private-use planes from names.
11. **Right-to-left letters are allowed in a local part** (honestly so). The screen must draw
    an address isolated and left-to-right, or its parts can change places.
12. **Gmail's `snippet` is believed to arrive HTML-escaped**, and nothing here unescapes or
    cleans it (`GmailWire.swift:298`). P06a's, and a probe item.

---

## The seven questions

| | Judgement |
|---|---|
| 1. `header.i` | The implementer is right about Gmail; the ruling is right. Add MAJOR 4. |
| 2. `MIMEStructure` | The ruled shape is right, `cut` above all. Two small additions (MINOR 4). |
| 3. U+200D, U+200C | The ruling is right: remove what cannot be seen, except where it is doing its work. |
| 4. Mixed scripts | The ruling is right. Read literally it hid every bilingual name, and a flag that fires on honest mail is not read. |
| 5. Unknown charset | Safe either way. Nothing to exploit: the text is judged after decoding. |
| 6. Cut headers | The ruling is right: the sender must not choose which headers are seen. |
| 7. Depth, envelopes | Both rulings are right. Bound our own recursion as well (MINOR 3). |

## What reading could not rule out

- **How Gmail itself reads a malformed `From`**: which address it authenticates in each row
  of MAJOR 1 and 2, and which it refuses. The probe should send them.
- **Whether Gmail escapes sender-written text inside its own `Authentication-Results`**: the
  local part of a DKIM `i=` and of the envelope sender. If a space or `;` can arrive raw,
  a sender can write a result. Taking the domain after the *last* `@` (ruled) defeats the
  space; nothing in the reader defeats a `;`. A probe item, with a hostile `i=`.
- **Whether header values arrive decoded, whether an empty `labelIds` is omitted, whether
  `snippet` is escaped.**
- **That `\p{Script=…}` and the join-type classes compile on the system's ICU** (L3, L4).
- **That `URLComponents.encodedHost` gives the same `xn--` form on every system the app runs
  on.** The tests pin it on this one.

## For the next packages

- **P05, P06a.** The sender is one reading (MAJOR 2), not `mailboxes.first`. Judge a name once,
  at store (MINOR 8). An `unreadable` item's text is never put where a sender goes: it can be
  `Noor <noor@plan.example`. Clean and unescape the snippet.
- **P10a.** The fake writes Gmail's believed header *above* everything a sender wrote, and
  needs a message that carries a forged one below another server's. A switch for an omitted
  empty `labelIds`.
- **P03b.** Cap what it copies from a part: `filename`, `mimeType` and `Content-ID` are the
  sender's and are as long as he likes. Its walk is bounded by depth 20; the decode before it
  is not (MINOR 3).
- **P16.** Build a reply's headers from parsed values, never from a header's text; an address
  that passes `isValid` may still need quoting until MAJOR 3's last sentence is done.

## Checked and correct

- **Kept apart.** With brackets, every word before them is the name, an address among them
  included. A name is decoded after the list is split, so nothing an encoded word says can
  add an address, a comma or a group. An address is never decoded and never cleaned: one
  with a hidden format character is refused, not repaired.
- **A domain** is lower-cased, converted by the system to `xn--` when it is not ASCII, and
  then held to letters, digits, hyphen and underscore in at least two labels; whatever the
  conversion cannot do fails that test.
- **Bounded work.** No recursion in any reader: comments are matched once with a stack;
  a quote or bracket that never closes is looked for once and never again; each start of an
  encoded word scans to the next `?` and no further than 1,024 characters. No repeated
  `append(contentsOf:)` on a scalar view remains. The header limits are applied before any
  value is read; an address over 320 bytes is refused unread. No index can leave its array.
- **Unknown is not absent.** `isComplete` on headers and on a list; a cut value drops its last
  piece; a missing `headers` key is unknown and an empty one is not; a number that does not
  parse is nil, never zero; an unknown label or type is kept as sent.
- **`Authentication-Results`.** A comment cannot hold a result; a `;` in a comment or a quote
  does not split; anything but `pass` is nothing; a parent counts only on a dot boundary and
  never the reverse; the ARC header is not this one.
- **File names.** No separator, no leading dot, no direction or control character survives;
  padding before a second extension collapses to one space; the real extension is kept when
  the name is cut.
- **Structure.** Foundation only (`GmailWire` and the rest); nothing logged; the fixtures are
  wholly inside `#if DEBUG || MAIL_FIXTURES`.
- **Tests** assert literal answers, shape by shape. The ratio test is a timing test and says
  so; its floor cannot hide quadratic work at these sizes, and it retries before it fails.
