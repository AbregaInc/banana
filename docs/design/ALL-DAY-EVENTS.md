# All-day events

October 2026. The author’s partner invited him to an all-day "Sam & Ana Fun Day Trip" on Saturday the 10th.
He accepted it, and she marked it Busy, but it didn't appear anywhere in Banana: every all-day
event was dropped (`occupiesTimeline` is timed-only). Even if it had appeared, it would have
blocked nothing. Google makes all-day events Free on each guest's copy, an accepted invitation's
included, and the organizer changing hers to Busy doesn't change yours.

## The rule

**An all-day event shows if it's yours, and blocks its day if your copy says Busy.** (`AllDayEvents`)

- **Yours:** it's on a calendar you own (`accessRole == "owner"`), which is where an invitation
  you've accepted lands, unless you've hidden that calendar's all-day events. Calendars you
  don't own (a partner's shared calendar, a subscribed feed of launches, F1 or holidays) show
  only if you switch them on. Settings › Accounts & calendars › All-day events;
  `SmartScheduleSettings.allDayHiddenCalendarIDs` / `allDayShownCalendarIDs`, raw Google ids,
  synced.
- **Busy:** Google's own "Show as", on your copy. Free ones show and block nothing. That covers
  birthdays and most invitations until you choose otherwise.
- **Never shown:** working-location markers ("Home", "Office"; `eventType == "workingLocation"`)
  are a status rather than an event. Declined events and Banana's own busy copies are also
  never shown.

## What follows

- **Read:** `GoogleEventWindowBuilder.window(allDayCalendarIDs:)` gives `allDayEvents` (each
  once across calendars, `alsoOn` kept), and a Busy one's whole day in `busyIntervals`. They
  are never in `meetings`, so wake plans, travel, prep and alerts stay timed-only. The main
  read and the per-week reads (`planningWindows`) both carry them.
- **Timeline:** one `.allDay` occurrence per day an event covers. It's untimed, spans the
  whole day, and `blocksWholeDay` is true when it's Busy.
- **Shown:** in the day's all-day band on the iPhone, the "No time" row on the Mac and iPad,
  and under "All day" at the top of Today. A Busy one is a solid chip and hatches its day in
  the calendar's colour. A Free one is an outlined chip.
- **A crowded day:** the ones that block the day come first (`AllDayEvents.busyFirst`), so
  where only two fit — a week's row — a Busy one is never behind "+N more". "+N more" opens the
  day's whole list, each event opening, blocking and hiding as it does in the row. The Day
  view has the room: it shows every one, wrapped onto as many lines as they take.
- **Blocks:** Re-plan places nothing on a blocked day (`Scheduler.isObstacle`); shared
  availability offers none of it; a new event that day is flagged as a conflict.
- **Your other calendars:** write-back copies a blocked day to each of your other writable
  calendars as an all-day "Busy" event (`GoogleBusyBlocks.body(isAllDay:)`), under every
  existing safety rule. Calendly reads bo@dewey.example, so a day blocked on the gmail
  calendar has to be blocked there too. It isn't copied to calendars that already have the
  same event.
- **Block this day:** an all-day event that's Free gets a one-tap "Block this day" in its event
  screen. It's also in the chip's context menu ("Don't block this day" undoes it). It writes
  `transparency` on your copy only (`GoogleCalendarService.setAvailability`, no one notified),
  shows the change at once, and offers Undo (`AllDayBlocking`). Banana never copies an
  organizer's Busy onto your copy on its own: your availability stays your choice.
