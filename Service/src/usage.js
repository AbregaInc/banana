// What a batch may hold. Anything not on these lists is dropped, so the app can never send more
// than this, whatever a future build tries.

export const NAMES = {
  active: [""],
  onboarding: ["welcome", "wake", "winddown", "calendar", "otherCalendar", "done"],
  feature: ["mealLogged", "labelRead", "groceriesScanned", "eventCreated", "eventEdited", "reminderCreated",
            "routineStarted", "podcastPlayed", "noteCreated", "workoutOpened", "reviewOpened", "calendarConnected"],
  failure: ["googleSignIn", "mealEstimate", "labelRead", "calendarWrite"],
  setup: ["googleAccounts", "calendars", "busyBlocks", "reminders", "notifications", "location", "watch",
          "appleIntelligence", "routines", "podcasts", "notes",
          "allModules", "workoutsModule", "foodModule", "notesModule", "podcastsModule",
          "os", "region", "language", "textSize", "appearance"],
};
// A setup fact's answer: a range, a state, or for these three a number or a code.
export const ANSWERS = ["0", "1", "2", "3-5", "6-10", "11-20", "21+", "on", "off", "granted", "denied", "notAsked",
                        "paired", "none", "standard", "smaller", "larger", "accessibility", "light", "dark"];
const CODES = { os: /^[0-9]{1,3}$/, region: /^[A-Z]{2}$/, language: /^[a-z]{2,3}$/ };
export const DETAILS = ["", "shown", "continued", "skipped", "photo", "describe", "search", "scan", "byHand",
                        "groceries", "parser", "model", "failed", "voice", "written"];
export const PLATFORMS = ["iphone", "ipad", "mac"];
export const CHANNELS = ["appstore", "testflight", "dev"];

const word = (value, list) => (typeof value === "string" && list.includes(value) ? value : null);

// One batch: { platform, channel, version, cohort, since, calendar, events: [{event, name, detail, count}] }.
// Returns the rows to add, or null when the batch itself isn't one of ours.
export function rows(batch) {
  if (!batch || typeof batch !== "object") return null;
  const platform = word(batch.platform, PLATFORMS);
  const channel = word(batch.channel, CHANNELS);
  const version = typeof batch.version === "string" && /^[0-9.]{1,12} \([0-9]{1,6}\)$/.test(batch.version) ? batch.version : null;
  const cohort = typeof batch.cohort === "string" && /^20[0-9]{2}-W[0-5][0-9]$/.test(batch.cohort) ? batch.cohort : null;
  const since = Number.isInteger(batch.since) && batch.since >= 0 ? Math.min(batch.since, 400) : null;
  if (!platform || !channel || !version || !cohort || since === null || !Array.isArray(batch.events)) return null;
  const calendar = batch.calendar === true ? 1 : 0;
  const out = [];
  for (const e of batch.events.slice(0, 64)) {
    const names = NAMES[e && e.event];
    if (!names) continue;
    const name = word(e.name ?? "", names);
    const detail = e.event !== "setup" ? word(e.detail ?? "", DETAILS)
      : CODES[name] ? (typeof e.detail === "string" && CODES[name].test(e.detail) ? e.detail : null)
      : word(e.detail ?? "", ANSWERS);
    const count = Number.isInteger(e.count) && e.count > 0 ? Math.min(e.count, 500) : null;
    if (name === null || detail === null || !count) continue;
    out.push({ event: e.event, name, detail, platform, channel, version, cohort, since, calendar, count });
  }
  return out;
}
