# Event alerts from the service

Decided 19 Oct 2026. Event notifications matter more than anything else the calendar does. The
silent push can't be relied on to wake a closed iPhone, so an event someone adds a few minutes out
(The author, Gmail, a colleague, an invitation) could ring nowhere until the app was opened. The Banana
service, which Google tells about every change within seconds (docs/design/ACCOUNTS.md), now reads
the changed events itself and sends the alerts, visibly, to every device. The devices keep their
own local alerts as the fallback for when the service can't reach them.

## What is visible, and when

| Change | Shown |
|---|---|
| Any timed event he attends | at his lead times (default 5 min before and at the start, `eventAlertLeads`), sent by the service |
| Event added inside the lead window | at once ("Starting now" / "Starts in 3 minutes") |
| New invitation (he is `needsAction`) | always, any date, with Accept / Decline |
| Someone else adds, moves or cancels an event, any date | at once |
| Gmail-created event (`eventType: fromGmail`, or a `source`) | at once |
| His own change, anywhere | silent, but its starting-soon alerts still come |
| Banana's own busy blocks and write-backs (`extendedProperties.private.bananaVariant`) | always silent |

Google has no "last modified by". Who did it is read from `creator.self` / `organizer.self`
(the calendar's owner) and the event's attendee marked `self` (his reply), plus `eventType` and
`source`. A device that has just written an event marks the write as its own, as the change poll
already does, so its own edits never ring as "someone else's".

## How it works

1. **Reading.** A Google notice names the channel, so the calendar. After the usual silent push,
   the service reads that calendar with the link's own token (`events.list`, `singleEvents`, a
   sync token per calendar in `calendar_sync`; the first read covers yesterday to thirty days out
   and plans alerts silently for what is already there). A `410` drops the token and reads again.
   Starting-soon alerts are kept only a month ahead: the change feed hands out every instance of a
   changed recurring series, years of them, and those further out plan nothing. Once a day per
   calendar the service reads the next month again (`planAhead`) and plans, silently, the events
   that came within it. A watched calendar
   the service has never read is read once within the minute by the dispatcher (`firstReads`, five a
   run), so the first change Google reports is already a change and rings.
2. **Deciding** (`src/alerts.js`, pure, tested): each changed event, with what the service knew
   of it before (`event_state`: times, status, his reply, a hash of the title), becomes a set of
   alerts, each with a shared id `calendarId|eventId|lead` where lead is the minutes (`5`, `0`)
   or `now`, `invite`, `changed`, `cancelled`. Pending lead alerts of an event are replaced
   whole when it moves; they go when it is cancelled, declined, becomes all-day, or is Banana's.
   Recurring invitations announce once per series, not once per expanded occurrence. A hashed
   account/series receipt in `series_invitations` survives the one-day alert cleanup; iCalUID
   shares that receipt across connected calendars. Existing and baseline series seed it silently.
   The earliest occurrence in a new batch supplies the notification, whose body says “Recurring
   series”. Accept/Decline route to the series master, rather than only that occurrence.
   Automatically accepted invitations follow the same rule. Each occurrence still gets
   its own lead reminders, and genuine changes to known occurrences remain independent.
3. **Sending.** Immediate kinds go out as they are decided. Lead alerts wait in `alerts` and a
   dispatcher runs every minute, sleeping to the exact second each is due. A visible push
   (`apns-push-type: alert`, priority 10, time-sensitive, sound) goes to each device of the
   account **that rings for that calendar and doesn't hold the alert itself** (see below). The
   same meeting on two calendars (same lead, second and title, as the devices show it once) rings
   once per device. The push carries the shared id, the calendar
   and event ids and the kind in `b`, and a collapse id so a resend replaces. Alerts are kept a
   day after they are sent or cleared, then deleted.
4. **Devices keep their own alerts** (`EventAlertPlan`, unchanged in substance) with the same
   shared ids, as the fallback for a service that can't reach them. After every recompute a device
   tells the service which alert ids it holds, which calendars it rings for (the ones it reads:
   not hidden, not set not to count) and which events ahead were skipped (`PUT /v1/alerts/held`);
   the service skips those devices for those alerts and rings nothing else. The watches cover the
   same calendars. A device skips scheduling a local alert whose id the service has
   already delivered to it, so nothing rings twice on one device.
5. **Every device rings. Clearing one clears the others.** Dismissing or opening an alert on one
   device (`customDismissAction` categories) tells the service (`POST /v1/alerts/clear`), which
   marks it cleared and sends a background push `{"b":{"k":"alert-clear","id"}}` to the other
   devices; each removes the delivered notification with that id (its own local one or the
   service's) and any pending local one. The Mac does it at once; an iPhone when iOS delivers
   the push. Clearing the 5-minute alert never touches the at-start one: different ids.
6. **Accept / Decline** on an invitation alert replies through the device's own Google access
   (`GoogleCalendarService.respondToInvite`), the Beta only for its test accounts.

## What the service holds for this

`calendar_sync` (sync token per calendar), `event_state` (times, status, his reply, title hash: to
tell a move from a reply), `alerts` (the title and body of each alert until a day after it is sent
or cleared), `held_alerts` (which device holds which alert), and on the account the lead times and
time zone the devices report. This is the first place the service holds event titles at all: an alert's title waits in
`alerts` until a day after it is sent, so up to a month for an event a month out. ACCOUNTS.md and the
privacy policy (19 Oct 2026) say so. All of it lives only as long as a watch on its calendar
(`forgetUnwatched`): closing the last channel, disconnecting the Google account, Google refusing,
deleting the account, or the 15-minute job finding a calendar nobody watches removes it.

## In the app

- `EventAlerts` (Banana/Model): shared ids from an event's info id, the notification categories
  (`EVENT_ALERT`, `EVENT_INVITE`), the delivered set, the held report, clearing, the reply.
- `NotificationService.scheduleEventAlerts` names each local alert by its shared id, skips the
  delivered ones, and reports what it holds.
- Pushes: `b.k == "alert"` is shown by the system (and by the app in front); `alert-clear` runs
  `EventAlerts.cleared(id)`; the existing `calendar` push is unchanged.
- Settings' lead times (`AppSettings.eventAlertLeads`) and the device's time zone go to the service
  (`PUT /v1/account/alerts`) whenever they change. No new control anywhere.

## Where it stands (19 Oct 2026)

On for both services since 19 Oct 2026, once the privacy policy said so. The author's four Google
accounts gave the service its own access that morning (build 59 with the client-id fix).

Two gates (`58b203ed`):
- `EVENT_ALERTS` (`on` for both). With it `off` the service reads no event and sends no alert.
- A device gets the service's alerts and clears only once it has reported the alerts it holds and
  the calendars it rings for (`devices.alert_calendars`, build 61 on). A build from before keeps
  its own alerts and never hears one twice.

19 Oct, with build 60 on the Mac and iPad: the service would have rung for calendars the devices
leave out (a partner's, a rocket-launch calendar) and held 372 alerts for a recurring series up to
2030. Hence the calendar report, the month, and the once-per-meeting rule (service `0c2eb319`).
