# Things due around other things

October 2026. Creatine is taken after the workout, not at 8 AM; levothyroxine 30 minutes before
breakfast; vitamin D with the biggest meal. A clock time was the only way to say any of that, so
Creatine went overdue at 8:01 on every day the workout came later.

## The rule

**Anything you do each day is due at a moment plus an offset; a clock time is just one kind of
moment.** Until its moment comes it's *waiting*, not late. If the moment doesn't come, it falls
back to its own time (8 PM for Creatine) or is skipped that day.

An item keeps the time it always had: that's the fallback. Tying it to a moment
(`TimingAnchor`) adds three things:

- **The moment.** A workout, waking, a meal (any, or breakfast/lunch/dinner), another reminder
  ticked, another dose taken, a calendar event whose title matches.
- **Before or after it, by how much.** "After, right away", "15 min after", "30 min before".
- **If it doesn't happen.** At its usual time anyway (the default), or skip that day.

`AnchoredTiming.due` decides, purely, from the day's signals: `.at(time)`, `.waiting("After your
workout")`, or `.skipped`.

## Where the moments come from

Read off what Banana already has — nothing new is stored or synced (`AnchoredTimingHub`):

- **Workouts:** whichever comes first today: a recorded workout (Health's, or the Watch's own),
  or ticking the reminder that *is* your workout — "Workout", "Gym", "Morning run", never
  "Post-workout protein" (`AnchorSuggestions.isWorkout`, the same words "before" plans by). A
  workout done without recording it is still done (4 Oct 2026: Creatine waited for a recording
  while "Workout" had been ticked). Recorded ones are counted once
  (`AnchoredTiming.todaysWorkouts`). When a Banana Watch workout ends, the Watch messages the
  phone (`workoutEnded`), which wakes the phone app in the background; the workout's file
  transfer alone waited until Banana was next opened, so "after your workout" didn't ring then
  (4 Oct 2026). A workout arriving as the app starts is held until startup has wired its
  handler, not dropped. Workouts from other apps are seen when Banana next runs (waking it from
  Health needs a capability not enabled yet).
  "Before" needs a predicted start: the Workout cue's or reminder's time, a calendar event like
  "Gym", or else the moment the Watch workout starts.
- **Waking:** last night's wake time from sleep.
- **Meals:** the meals logged today; "before breakfast" uses your usual breakfast time.
- **A reminder ticked:** its completion time from Reminders (`TaskInfo.completedAt`).
- **A dose taken:** today's Taken log.
- **An event:** today's calendar.

## What follows

- **Badges and Overdue** count an item only once it's due (`.at` and past). Waiting isn't late.
  Taken shows the same doses in light yellow, "Due since 8:00 AM" (`ActionItems.dueSince`).
- **On screen** a waiting item says what it waits for ("After your workout") instead of a time.
- **Notifications.** A Taken item's own-time notification becomes the fallback, one day at a
  time; when its moment comes, today's fallback is replaced by one at moment + offset. Taken's
  reminders show with the app in front too — the moment is often something done in the app.
- **Apple Reminders.** A reminder's anchor rule is Banana's (synced by its stable id); its due
  time in Reminders is the fallback, and when the moment comes Banana moves today's due time
  there, so Reminders and the Watch agree.
- **Repeating** is unchanged: each day has its own moment. A missed instance is overdue until
  the next one's day begins; then Banana moves the reminder on to that one in Reminders without
  completing anything, and keeps what was missed beside it ("Missed yesterday",
  `ReminderRollover`, `MissedRepeats`). An overdue one can be marked "Missed it": moved on, not
  done (16 Oct 2026).

## Learning it, and moving to Taken

- Banana sees when things are ticked. An item done 0–60 minutes after the same moment on at
  least 60% of the last three weeks' days both happened, and on at least four, is offered the
  anchor at the typical gap: "Creatine usually follows your workout — about 15 min after, on 6 of
  the last 8 days." [Make it so] [No] (`AnchorSuggestions`, `AnchorSuggestionStore`). Taken items
  are asked in Taken, repeating reminders above Plan's List. The strongest moment wins: most
  days, then the steadiest gap. Never one that's the item itself (a reminder called "Workout"
  and the workout), one already tied to it, or ticks a few seconds apart (one sitting, not one
  thing following another). "No" is kept per item and moment in iCloud key-value storage.
- A repeating reminder that's something you take (Creatine, vitamins, a pill) belongs in Taken,
  where it's logged taken or skipped, checked for clashes and anchored natively. Banana offers to
  move it (`ReminderToTaken`): the Taken item is made with its time, its anchor and its last 60
  days of ticks as doses, and in Reminders the repeat is removed and the reminder ticked — never
  deleted, its history kept. Undo puts the repeat back exactly and removes the Taken item.
