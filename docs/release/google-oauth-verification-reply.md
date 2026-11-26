# Google OAuth verification: reply and demo video

Google's Trust & Safety team asked for three things on the Gmail and Contacts scopes: a justification
that ties each scope to user-facing features, Console scopes that exactly match what the app
requests, and a new demo video. Below: what to fix before replying, the reply, and the recording
script.

## 0. Before replying

Done in code (26 Nov 2026):

- Every Google sign-in in the app is cut to `GoogleScopes.submitted`
  (`Banana/Model/GoogleReconnectPermissions.swift`); a request for anything else is dropped and
  asserts in Debug. Reconnect now asks for `gmail.modify` and the two contacts scopes whatever the
  account held before, so an older `gmail.readonly` or full-Gmail grant comes back as `gmail.modify`.
- The Privacy Policy's Email section describes the cloud mailbox, Gmail push, drafts and sending,
  and what turning Email off deletes. It still has to be deployed (`LandingPage/`, `check_site.py`
  passes).

Still to do by hand:

1. **Console › Data Access must list exactly these**, and nothing else (remove `gmail.readonly`,
   `https://mail.google.com/` and `.../auth/calendar` if they are there):

   | Scope | Asked by |
   |---|---|
   | `openid`, `.../auth/userinfo.email`, `.../auth/userinfo.profile` | sign-in (Google Sign-In adds them; `Service/src/web/routes.js`) |
   | `.../auth/calendar.events` | `GoogleScopes.calendarEvents` |
   | `.../auth/calendar.calendarlist.readonly` | `GoogleScopes.calendarList` |
   | `.../auth/calendar.events.freebusy` | booking pages (`Service/src/booking/routes.js`, same project's web client) |
   | `.../auth/gmail.modify` | `MailScopes.gmailModify` |
   | `.../auth/contacts.readonly` | `MailScopes.senderPhotos` |
   | `.../auth/contacts.other.readonly` | `MailScopes.senderPhotos` |

2. **Reviewers need a way in.** The Beta app is installed by hand. Give them a notarized Mac Beta
   download and a test Google account that the service already marks as a Mail test account.

## 1. The reply

> Subject: Re: OAuth verification — Banana — project `<project id>`

Hello,

Thank you for the review. This reply covers the aligned scope list, what each scope does for the
user and why a narrower one cannot, the new demo video, and test access.

**1. Scopes: code and Console now match**

Banana requests exactly these scopes, and the Data Access page lists exactly these:

- `openid`, `userinfo.email`, `userinfo.profile`: sign in
- `calendar.events`, `calendar.calendarlist.readonly`: the calendar
- `calendar.events.freebusy`: booking pages
- `gmail.modify`: Email
- `contacts.readonly`, `contacts.other.readonly`: sender pictures in Email

We removed `<removed scopes>` from the Console, and the app no longer requests any Gmail scope other
than `gmail.modify`.

Gmail and Contacts are requested only when a user turns on Email in the Banana Beta app. The two
Contacts boxes are optional on Google's consent screen; Email works fully with them unticked. The
App Store build of Banana is calendar-only and never requests these scopes (our release check
rejects any build that contains them). Email is enabled on the server only for accounts marked as
test accounts, so no production traffic requests unverified scopes.

**2. `https://www.googleapis.com/auth/gmail.modify`**

Banana Beta is a Gmail client for iPhone, iPad and Mac built for fast inbox triage. Every write
below happens only when the user takes the action.

Reading:
- the inbox, labels and splits, with each conversation's messages, bodies and attachments
- search across the mailbox
- live updates: Gmail push notifications (`users.watch`) and `users.history.list` keep every device
  current without polling

Changing messages (`users.messages.modify`, `users.messages.trash`, `users.messages.untrash`,
`users.labels.create`):
- **Done** (archive): removes the message from the Inbox
- **Mark read / unread**
- **Star / unstar**
- **Label**, **Move to** a label, **Remove this label**
- **Spam / Not spam**
- **Trash / Restore**, and **Undo** for every one of these
- **Snooze**: Banana puts a `Banana/Snoozed/<time>` label on the conversation and takes it out of
  the Inbox. At that time it goes back to the Inbox on every device and in Gmail itself.

Writing (`users.drafts.create`, `.update`, `.delete`, `.send`):
- reply, reply all, forward and new message. A draft is saved to Gmail Drafts, so it also shows in
  Gmail on the web and other clients. Sending sends the draft; discarding deletes it.

Why no narrower scope works:
- `gmail.readonly` and `gmail.metadata` cannot change labels, so no archive, read/unread, star,
  label, spam, trash or snooze. `gmail.metadata` also cannot read bodies or search.
- `gmail.labels` only manages label definitions. It cannot apply labels to messages or read them.
- `gmail.compose` and `gmail.send` cover drafts and sending only. They cannot read the inbox or
  change messages.
- Even `gmail.readonly` + `gmail.compose` + `gmail.labels` together cannot call
  `users.messages.modify` or `users.messages.trash`. Only `gmail.modify` or full access
  (`https://mail.google.com/`) can.

We chose `gmail.modify` over full access on purpose. Banana never permanently deletes mail; Trash
stays recoverable in Gmail for 30 days. Banana never touches settings, filters, forwarding or
delegates.

**3. `https://www.googleapis.com/auth/contacts.readonly` and `https://www.googleapis.com/auth/contacts.other.readonly`**

Feature: sender pictures in the message list and conversation headers. If a message comes from
someone in the user's Google Contacts, Banana shows the photo the user set on that contact. If it
comes from one of Gmail's saved "Other contacts", Banana shows the photo Google holds for that
address. Without these scopes, people the user knows show up as initials. No other source has the
photos the user set on their own contacts.

What is requested and kept:
- `people.connections.list` with `personFields=emailAddresses,photos`, and `otherContacts.list`
  with `readMask=emailAddresses,photos`. No names, phone numbers, postal addresses or notes.
- Read on our server at most once a day. We keep a hash of each address and its photo's link,
  shown only to that user and never to other users. Both are deleted when the user turns Email
  off, disconnects the Google account or deletes their Banana account.
- Read-only. Banana never creates, edits or deletes contacts.

Why no narrower scope works: no scope returns contact photos by email address. The People API
needs `contacts.readonly` for the user's contacts and `contacts.other.readonly` for Other contacts.
Neither scope covers the other's list, so a sender in either one needs its own scope.

**4. Limited Use**

Turning Email off deletes the Gmail permission, our copy of the mailbox and the contact photos from our server at once. Gmail and Contacts data is used only for the features above. It is not used for advertising, not
sold, not used to train AI models, and not read by people except with the user's explicit consent
(a problem report they send), for security, or to comply with the law. Banana complies with the
Google API Services User Data Policy, including the Limited Use requirements:
https://bananatheapp.com/privacy

**5. Demo video**

`<unlisted YouTube link>`

- 0:00 Console: Data Access scopes and the OAuth client
- `<t>` Consent screen with every scope expanded
- `<t>` Reading: inbox, conversation, attachment, search, live update
- `<t>` Every change, shown in Gmail on the web: read/unread, star, label, archive, snooze, spam,
  trash, restore
- `<t>` Drafts in Gmail Drafts, sending, deleting a draft
- `<t>` Contacts: contact photo and Other-contacts photo shown beside the sender
- `<t>` Calendar: the calendar list, and an event created, moved and deleted in Google Calendar
- `<t>` Turning Email off, and removing access in the Google Account

**6. Test access**

Banana Beta for Mac (Apple silicon, macOS `<version>`+): `<notarized download link>`

Test Google account (Email is already enabled for it on our server; no phone verification and no
payment needed):
- Email: `<test account>`
- Password: `<password>`

Steps:
1. Open Banana Beta and click **Continue with Google**. Sign in with the test account.
2. On Google's screen, leave every box ticked and click **Continue**.
3. Choose **Email** in the module list, or open the module switcher at the bottom left and choose
   **Mail**.
4. Open any conversation. Use the toolbar or keys: `E` Done, `U` read/unread, `S` star, `L` label,
   `V` move, `H` snooze, `!` spam, `#` trash, `⌘Z` undo. Check each change in Gmail on the web.
5. Press `R` to reply. The draft appears in Gmail Drafts; **Send** sends it.
6. Senders saved in the test account's Google Contacts show their contact photos in the list.

If you'd rather use your own account, send us its address and we'll enable Email for it.

Kind regards,
`<name>`, Abrega, Inc.

## 2. Recording script

Target length: 6–8 minutes, 1080p or higher, uploaded to YouTube as **Unlisted**. Record on the Mac:
the text is readable and Gmail can sit beside the app. Add on-screen captions naming the scope at
each section. Captions are enough, but a short voice-over helps.

### Prepare (before you hit record)

- **Account.** A fresh Gmail test account, already marked as a Mail test account on the service. Use
  the same account you give the reviewers.
- **Seed mail** (send from a second account, so it arrives naturally):
  - 2 from **Alex Rivera**: add Alex to the test account's Google Contacts with a loud, unmistakable
    photo (a solid orange square with "AR"). Use an address with no Gravatar or BIMI logo, so the
    picture can only have come from Contacts.
  - 1 from an address in **Other contacts** that has a Google profile photo (reply to it once from
    the test account so Gmail saves it).
  - 1 from an address that is in neither, so it shows initials (the contrast).
  - 1 with a PDF attachment, 1 newsletter, 1 receipt, 1 spammy one, and a few fillers.
- **Clean slate.** Remove Banana at myaccount.google.com › Security › Third-party connections, so the
  full consent screen appears. Remove the account from Banana Beta.
- **Screen.** One Chrome profile with no bookmarks or extensions showing. Turn on Do Not Disturb.
  Arrange Banana Beta on the left half and Chrome on the right. Open tabs: Cloud Console Data Access,
  Gmail (test account), Google Contacts, Google Account › Third-party connections.
- **Rehearse once** without recording; every action below takes one key or one click.

### Shots

| # | Time | On screen | Do | Caption |
|---|---|---|---|---|
| 1 | 0:00 | Cloud Console | Show the project id, **Google Auth Platform › Data Access** with the full scope list (scroll slowly), then **Clients** with the iOS/macOS client id. | "Scopes configured for verification" |
| 2 | 0:30 | Banana Beta | Click **Continue with Google**, choose Email. | — |
| 3 | 0:45 | Google consent | Hold 3 s on the app name and the developer email. Click each scope line, or **Show all** / the expander, so every one is fully readable: Gmail "Read, compose, send…", "See and download contact info…", "See and download contact info automatically saved…". Hold 2 s on each. Point out the Contacts boxes are optional. Leave them ticked; **Continue**. | "Consent screen: all requested scopes" |
| 4 | 1:30 | Banana Mail + Gmail | Inbox loads. Open a conversation, open the PDF, run a search. Send a new mail from the second account (phone) and let it appear in Banana without touching it. | "gmail.modify: read, search, live updates" |
| 5 | 2:15 | both | For each, act in Banana, then refresh Gmail and show the result in Gmail: **U** unread → bold in Gmail · **S** star → starred in Gmail · **L** "Receipts" → label in Gmail · **E** Done → gone from Gmail Inbox, present in All Mail · **H** snooze → `Banana/Snoozed/…` label in Gmail, out of Inbox · **!** spam → in Gmail Spam, then Not spam → back · **#** trash → in Gmail Trash, then Restore → back in Inbox · one **⌘Z** undo. | "gmail.modify: changes reflected in the user's Gmail" |
| 6 | 4:30 | both | **R** reply, type a line, pause: show it in Gmail Drafts. **Send**: show it in Gmail Sent (and arriving on the second account). Start another reply, discard it: show it gone from Gmail Drafts. | "gmail.modify: drafts and sending" |
| 7 | 5:30 | Banana + Contacts | Show Alex Rivera in Google Contacts with the orange photo, then the same photo on Alex's rows in Banana. Show the Other-contacts sender (contacts.google.com › Other contacts) and their photo in Banana. Show the sender in neither, with initials. | "contacts.readonly / contacts.other.readonly: sender photos" |
| 7b | 6:15 | Banana + Google Calendar | The calendar scopes are on the same consent screen, so show them in use too: Banana's calendar list with every Google calendar (`calendar.calendarlist.readonly`). Create an event in Banana, move it, delete it, and show each change in Google Calendar on the web (`calendar.events`). Keep it under a minute. | "calendar.events, calendar.calendarlist.readonly" |
| 8 | 6:30 | Banana + Google Account | Banana Settings: turn Email off; Mail is gone from Banana. Then Google Account › Third-party connections: open Banana, show Gmail and Contacts listed, **Remove all access**. | "Turning Email off and revoking access" |

### Don'ts

- Don't cut inside the consent screen or a before/after pair; reviewers want each change shown
  unbroken.
- Don't record against a site whose Privacy Policy is older than 26 Nov 2026; deploy it first.
- Don't record with your own mailbox or real contacts.
- Don't speed the video up.
