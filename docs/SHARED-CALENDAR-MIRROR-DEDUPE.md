# Shared Dinner and Busy duplicates

## October 22 investigation

The supplied screenshots show a shared Personal Dinner from 6–9 PM and a Fitness
Busy block over precisely the same interval. Dinner has two calendar indicators;
Busy remains a separate column. Source inspection explains this behavior. The
partner's raw Calendar API responses have not been captured. The owner's phone
cache was subsequently recovered: it contains **two Dinner copies and four
Banana-written Busy copies** for October 23, 6–9 PM. Recomputing the writer's
exact fingerprint from Dinner's title and start/end Double bit patterns matches
all four stored mirror item IDs. Private evidence is retained as
`PhoneLag-20261022/dinner-mirror-evidence.json` and
`dinner-mirror-confirmation.json` under the local Banana logs directory. This
confirms the owner-side mirror relationship; it does not prove which metadata
Google returned to the partner.

The two detailed Dinner copies share an iCalendar UID. The Busy mirrors have
different UIDs from Dinner because they are independently created events, not
attendee copies of Dinner. Their Banana mirror item ID supplies the owner-side
relationship, while the shared-calendar display rule intentionally keeps each
availability placeholder separate.

`GoogleEventWindowBuilder.dedupe` groups exact start/end intervals, then merges
matching normalized titles and records the losing calendar in `alsoOn`. However,
`Normalized.isSharedAvailability` treats a privacy placeholder on a non-owned
calendar as availability, and gives it a unique calendar/event key. It does not
merge with Dinner or with another shared Busy event. This was intentionally
introduced to preserve availability when another person's original event is not
shared. Existing `GoogleEventWindowTests` cover that safety case.

The write-back side deliberately creates private Busy events on other selected
calendars. Its `mirror-…` item identifier is a hash of title and exact times,
stored in private extended properties. It is not an explicit original-event
reference. Normalization retains only a shared/owned flag, rather than the
original person's identity and the source-instance relationship needed here.

## Required reconciliation rules

| Visible data | Presentation |
| --- | --- |
| Detailed Dinner plus a proven mirror of that instance, from the same person's calendars | One Dinner, retaining every contributing calendar indicator |
| Only that person's private Busy block | Keep Busy; it is the only availability information |
| Several proven mirrors of that person's same hidden source instance | One Busy block with all contributing calendar indicators; reveal no source details |
| Another person's event at the same time | Keep separate; simultaneous does not mean identical |
| Two unrelated detailed events with identical titles/times | Keep separate unless identity establishes that they are copies |
| Linked source and mirror with different intervals | Preserve unexplained coverage; do not hide time outside the visible source |
| A source calendar is turned off, removed, or loses detail permission | Re-evaluate and retain Busy when the visible source no longer accounts for it |
| Recurring events | Match the individual occurrence, not just the series UID |

This should be display reconciliation. Preserve the actual Google Busy event and
raw busy intervals, which protect booking availability on the individual
calendars. Do not delete events, change sharing permissions, or reveal titles,
locations or attendees that the viewer cannot independently read. A shared Busy
block must not become a new event that the viewer mirrors onto their own calendars.

Use original event/instance identity for actual copies. For existing
Banana-created mirrors, the matching mirror fingerprint can establish a
relationship where its metadata is available, but must also be scoped to a
contributing source person's calendars and the exact instance/interval. A rich
event's merged calendar contributions matter here: the winning copy may be the
partner's own invitation while another copy belongs to the owner. Carry that
provenance through normalization. Future writes should carry an explicit opaque
source-instance reference rather than depending solely on title/time hashes.
Do not merge solely by time, title, color, the viewer's connected Google account,
or the generic Banana writer marker. Without trustworthy provenance, keep the
block and treat the relationship as unknown.

Google documents private extended properties as belonging to a specific calendar
copy, while shared properties travel between attendee copies. Neither is an
automatic linkage between independently created mirror events. Private events
also restrict detail visibility, so any proposed metadata channel needs a
viewer-permission check rather than assuming shared metadata survives redaction:
[event reference](https://developers.google.com/workspace/calendar/api/v3/reference/events),
[extended properties](https://developers.google.com/workspace/calendar/api/guides/extended-properties).

No calendar deduplication change is included in build 71's podcast work. This
document records the cause and the rules for a subsequent correction.


## Build 72 correction

The native and cloud readers now reconcile a shared Busy mirror only when the
calendar data owner and existing `mirror-…` fingerprint match a single visible
source group over the exact same interval. The writer and reader use the same
fingerprint implementation, preserving existing Google records. Source
provenance is collected before selecting the richest invitation copy, so a
viewer-owned winning invitation retains the shared owner's relationship.

Google iCalendar UIDs identify actual invitation copies, scoped to the exact
occurrence interval, original occurrence start (including moved instances), and all-day/timed form. Different known UIDs no longer merge
merely because their titles match. The existing flight-route reconciliation remains unchanged. Legacy title fallback remains for
payloads without UIDs; shared title fallback is scoped to the calendar owner.

Known mirrors of a hidden source form one private Busy entry. Missing metadata,
unknown owners, ambiguous fingerprints, other people's blocks, extended intervals,
and stale/renamed-source fingerprints remain visible. Free originals do not absorb
opaque mirrors. Raw busy intervals and actual Google records are unchanged.

Google can redact private-event metadata for readers. Such a payload remains Busy
unless an independently visible copy has the same UID; we do not guess a match
from timing. Confirmation on the partner's current API response/device remains
necessary to establish that this particular viewer receives the linkage metadata.
Calendar owners are Google data owners (or primary-calendar email IDs), not the
viewer's connected account. Different Google account emails are conservatively
separate until an explicit person relationship exists.

Validation artifacts are in the private local `CalendarMirror-20261022` log
folder. The native regression suite passed 33 tests; the service passed 264 tests
in each of UTC and America/New_York. The persistent component gate is unmeasured
because installed Xcode 27.1 differs from the checked-in Xcode 27.0 reference;
no budget or baseline was changed. Both targeted iPhone UI cases pass: one detailed Dinner with its mirrors and unrelated shared Busy remaining visible. Screenshots are retained with the test results. Physical frame/input timing is unmeasured. Rollout status is recorded separately as it completes.

## October 23 follow-up: remaining viewer case

The owner confirmed that the new screenshot is from a different phone than the
paired device named by its owner. App Store Connect's tester device record for the
actual viewer reports `1.0 (73)`. The old paired spare's build 18 is irrelevant.
The previous correction therefore reached the viewer; this case remains open.
The screenshot cannot establish whether ownership differs, private metadata is
redacted, or a fingerprint is stale. Do not attribute it to a missed update.

A separate cloud request defect was reproduced: the owner and guest routes used
Google field masks without `iCalUID` and `originalStartTime`, despite the agenda
projection requiring those fields. The normal Google fake returned every property
and hid that integration gap. A route test now projects only requested properties:
before correction five records incorrectly become two rows; afterward they become
four (one invitation copy folds, an unrelated event and two moved instances remain).
Owner requests also retain organizer and attachment details used by the UI.
Both cloud environments have this correction. The full service suite passes 267
cases in each of UTC and America/New_York. This is not a fix or live-provider
acceptance for the remaining native viewer case.

The native follow-up adds an explicitly shared Settings troubleshooting report
from the same cached calendar inputs as Plan. Within-report anonymous labels
preserve owner, UID and mirror-fingerprint equality, plus calendar access roles
and missing-metadata flags. It omits titles, emails, locations, notes, provider
identifiers and property values. Event times remain, disclosed beside the share
action. Nothing is sent automatically. Viewer evidence and native rollout status
must be checked before claiming this remaining case resolved.

### Owner-side sharing API attempt

At the owner's request, a read-only signed native probe queried Google's calendar
ACL endpoint using Banana's existing sign-ins. All six owned calendars across four
accounts returned `Request had insufficient authentication scopes.` No ACL was
changed and no failed lookup was interpreted as absence of sharing. Google
requires `calendar.acls.readonly`, `calendar.acls`, or the broad `calendar` scope
for this endpoint. An explicit additional read-only consent is pending; ordinary
app sign-ins have not been changed to request it. The temporary Mac question build
was deleted after collecting the result. Private evidence is
`ProductionReadiness-20261022/calendar-sharing-owner-api.log` under Banana's logs.

The owner's own calendar-list `accessRole` describes the owner's access, not the
partner's permission. It cannot substitute for the ACL check. Group membership is
also separate from calendar ACLs, so the probe reports group grants as unresolved
rather than assuming that the viewer belongs to them.

## November 8: a family calendar event and its Busy copy

The partner reported the same pair again on build 110: an event on the Google family calendar and a
read-only "Busy" on the owner's Personal calendar over exactly the same interval. The owner's Mac
cache and write-back ledger settle the writer: the owner's Stable Mac created a `mirror-…` copy of
the family event five seconds after it was made, on all five of the owner's calendars, and the
fingerprint recomputed from the event's title and times matches the copies' item id. No copy was
on the partner's calendars.

Two rules made it:

- **Creation.** Google lists the family calendar with the `owner` role for every member of the
  family group, so `GoogleCalendar.isOwnedByAccount` called it the owner's own. Its events then
  blocked the owner's time by default (Blocks my time defaults to ownership since build 107) and
  were mirrored into every calendar the owner writes to, Personal included, which the partner can
  read. Build 113 special-cased the family calendar's id; that is replaced by the rule below
  ("Ownership is the primary or the data owner").
- **Display.** A shared Busy mirror folded into its source only when both calendars had the same
  data owner. A writer copies what it can see, calendars shared with it included, so the copy's
  owner (the owner) and the source's calendar (the family's) differ. A mirror now folds into the
  one visible event with its fingerprint over the same interval: the same owner's first, then
  anyone's. Two visible events with the fingerprint still leave it separate, and the copy's
  calendar stays on the merged entry.

Ownership on calendars the account doesn't own: a write-back pass reads every writable calendar,
and every person's Banana marks its copies the same way. A pass now treats a marked block on such a
calendar as this person's only when the ledger recorded it or one of this person's connected
accounts created it (`BusyBlockCleanupPolicy.isOurs`); it never updates, deduplicates or removes
another person's copy.

## November 8, later: ownership is the primary or the data owner

The rule the family case broke: a calendar is the account's own only if it is the account's
primary calendar, or Google names the account as its data owner (`dataOwner`). The owner role is
not ownership (it is also what "make changes and manage sharing" grants), and an id that looks like
the account's address is not the primary flag. A secondary calendar Google names no data owner for
(a group's, the family calendar among them) is no one account's. A calendar that isn't the
account's own blocks time only when Blocks my time is on for it, and receives Busy copies only when
opted in. The same rule is `isAccountOwnedCalendar` in the service, for the web reader and booking
availability. When a calendar is listed by several connected accounts, the owning account's entry
is the one kept (`GoogleCalendar.onePerCalendar`). Each load notes in the playback journal which
owner-role calendars are not the account's own, so the cost of the rule shows on real lists.

## Why the copies stayed after build 113

- Both Mac apps had written and removed nothing since the direct build replaced the App Store one
  on 3 Nov: legacy adoption's dry run found nothing to tag (every Apple-Calendar-era block already
  gone from Google) and still waited for a confirmation nobody was shown. A dry run that would tag
  nothing now finishes on its own (`LegacyAdoptionDecision`).
- The phone's first pass on 113 found the upcoming copies unwanted; `BlockRemovalGate` removes
  them on a second complete pass at least 90 seconds later, and that pass had not yet run.
- Copies of events that are over were never judged: the pass plans from today.

## Copies whose source no longer qualifies, at any date

A copy that should never have been written is wrong data whether its event is over or not. The
pass judges current and future copies against what it plans. A sweep (`sweepCopiesIfDue`,
`BusyCopySweep`, `MirrorSources`) judges the rest: every Busy copy of an event (`mirror-…`) that is
this person's (the calendar is the account's own, the ledger recorded it, or one of the person's
accounts created it) and whose event is over is removed unless an event read back over that time
still calls for it, the same way the writer decides (`MeetingInfo.shouldMirrorBusyTime`, or an
all-day event that blocks the day). There is no date limit: copies are found with one query per
calendar filtered by Banana's private property over all dates, and events are read back from the
start of the earliest copy judged. It runs every six hours, and on the next pass while removals wait
for their second look. Safety is the pass's: nothing is removed unless every read was complete, two
reads at least 90 seconds apart agree, and a removal that is a large share of every copy is held for
confirmation. Past travel and task copies are left: their routes and reminders can't be re-derived.
