// Record types surfaced by the web client. Keep polling revisions out of private/native-only streams.
export const WEB_TYPES = new Set(["plan.routine", "plan.alarm", "plan.wake", "plan.extra", "plan.override", "plan.bookingType", "core.wakePlan",
  "food.meal", "food.mealPhoto", "food.supplement", "food.dose", "food.myFood",
  "health.workout", "health.workoutPlan", "health.snapshot", "health.workoutCompletion",
  "podcast.show", "podcast.listen", "podcast.progress", "podcast.transcript", "notes.voiceNote"]);
export const WEB_STATUS_TYPES=new Set([...WEB_TYPES,"core.smartSettings","core.appSettings"]);
