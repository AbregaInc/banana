// One projection for both the owner's preview and the invited person's view.
// No grant makes the guest a member of the underlying native sync space.
import { calendarAgenda } from './calendar.js';
import { hmacHex } from '../crypto.js';

export const SECTIONS = {
  personalPlan: { name: 'Routines & reminders', types: ['plan.routine', 'plan.alarm', 'plan.extra', 'plan.override', 'core.wakePlan'] },
  workouts: { name: 'Workouts', types: ['health.workout', 'health.workoutPlan', 'health.workoutCompletion'] },
  health: { name: 'Health trends', types: [] },
  nutrition: { name: 'Food', types: ['food.meal', 'food.mealPhoto', 'food.myFood'] },
  taken: { name: 'Taken', types: ['food.supplement', 'food.dose'] },
  notes: { name: 'Notes', types: ['notes.voiceNote'] },
  listening: { name: 'Listening', types: ['podcast.show', 'podcast.listen', 'podcast.progress', 'podcast.transcript'] },
};
export const emptyPolicy = () => ({ calendars: [], sections: Object.fromEntries(Object.keys(SECTIONS).map(k => [k, false])) });
const object = v => v && typeof v === 'object' && !Array.isArray(v);
export const calendarKey = (sub, id) => JSON.stringify([sub, id]);
export function normalizePolicy(value) {
  if (!object(value) || Object.keys(value).some(k => !['calendars', 'sections'].includes(k))
    || !Array.isArray(value.calendars) || value.calendars.length > 300 || !object(value.sections)
    || Object.keys(value.sections).some(k => !Object.hasOwn(SECTIONS, k))) throw new Error('Choose valid sharing permissions.');
  const sections = {};
  for (const key of Object.keys(SECTIONS)) {
    if (value.sections[key] != null && typeof value.sections[key] !== 'boolean') throw new Error('Choose valid sharing permissions.');
    sections[key] = value.sections[key] === true;
  }
  const seen = new Set();
  const calendars = value.calendars.map(c => {
    if (!object(c) || Object.keys(c).some(k => !['sub', 'id', 'access'].includes(k))
      || typeof c.sub !== 'string' || !c.sub || c.sub.length > 255
      || typeof c.id !== 'string' || !c.id || c.id.length > 1024
      || !['details', 'busy'].includes(c.access)) throw new Error('Choose valid calendar permissions.');
    const key = calendarKey(c.sub, c.id);
    if (seen.has(key)) throw new Error('Choose each calendar only once.');
    seen.add(key);
    return { sub: c.sub, id: c.id, access: c.access };
  }).sort((a, b) => calendarKey(a.sub, a.id).localeCompare(calendarKey(b.sub, b.id)));
  if (!calendars.length && !Object.values(sections).some(Boolean)) throw new Error('Choose at least one calendar or section to share.');
  return { calendars, sections };
}
export function allowedTypes(policy) {
  const types = new Set(Object.entries(SECTIONS).filter(([key]) => policy.sections[key]).flatMap(([, value]) => value.types));
  if (policy.sections.workouts || policy.sections.health) types.add('health.snapshot');
  return types;
}
export function allowedViews(policy) {
  return ['overview', ...(policy.calendars.length || policy.sections.personalPlan ? ['plans'] : []),
    ...['nutrition', 'taken', 'workouts', 'health', 'notes'].filter(k => policy.sections[k]),
    ...(policy.sections.listening ? ['podcasts'] : [])];
}
export function projectHealthSnapshot(payload, policy) {
  // A Health snapshot contains workout history AND trends. Never hand out the unfiltered blob
  // when only one of those was selected. Unknown future payload fields stay private.
  const hidden = new Set(Array.isArray(payload?.hiddenWorkoutIDs) ? payload.hiddenWorkoutIDs : []);
  return {
    workouts: policy.sections.workouts && Array.isArray(payload?.workouts) ? payload.workouts.filter(w => !hidden.has(w.id)) : [],
    hiddenWorkoutIDs: [],
    trends: policy.sections.health && object(payload?.trends) ? payload.trends : {},
  };
}

export async function sharedCalendar(fetched, policy, { secret, shareID, settings }) {
  const modes = new Map(policy.calendars.map(c => [calendarKey(c.sub, c.id), c.access]));
  const full = fetched.filter(r => modes.get(calendarKey(r.sub, r.calendar.id)) === 'details');
  const events = calendarAgenda(full, settings, { includeBusy: true, allDay: true, ownedCalendarIDs: new Set(), details: true });
  // Remove provenance for calendars the guest was not given. Full details are sourced only
  // from the selected full calendars; busy copies can never enrich a detailed meeting.
  const intervals = [];
  for (const r of fetched) {
    if (modes.get(calendarKey(r.sub, r.calendar.id)) !== 'busy') continue;
    const e = r.event;
    if (e.status === 'cancelled' || e.transparency === 'transparent'
      || e.attendees?.some(a => a.self && a.responseStatus === 'declined')) continue;
    const allDay = Boolean(e.start?.date);
    const start = Date.parse(e.start?.dateTime ?? `${e.start?.date}T00:00:00Z`);
    const end = Date.parse(e.end?.dateTime ?? `${e.end?.date}T00:00:00Z`);
    if (Number.isFinite(start) && Number.isFinite(end) && end > start) intervals.push({ start, end, allDay });
  }
  // Union busy time across private calendars. Event counts, calendar names, descriptions,
  // attendees, original IDs and account addresses never cross the permission boundary.
  intervals.sort((a, b) => Number(a.allDay) - Number(b.allDay) || a.start - b.start);
  const merged = [];
  for (const interval of intervals) {
    const last = merged.at(-1);
    if (last && last.allDay === interval.allDay && interval.start <= last.end) last.end = Math.max(last.end, interval.end);
    else merged.push({ ...interval });
  }
  for (const interval of merged) {
    if (events.some(e => !e.showsAsFree && Boolean(e.allDay) === interval.allDay
      && Date.parse(e.start.dateTime ?? `${e.start.date}T00:00:00Z`) <= interval.start
      && Date.parse(e.end.dateTime ?? `${e.end.date}T00:00:00Z`) >= interval.end)) continue;
    const id = `busy-${(await hmacHex(secret, JSON.stringify([shareID, interval]))).slice(0, 32)}`;
    const stamp = value => interval.allDay ? { date: new Date(value).toISOString().slice(0, 10) } : { dateTime: new Date(value).toISOString() };
    events.push({ id, title: 'Busy', start: stamp(interval.start), end: stamp(interval.end), allDay: interval.allDay,
      showsAsFree: false, calendar: 'Busy', calendarID: 'busy', email: '', alsoOn: [], busyOnly: true });
  }
  return events.sort((a, b) => Date.parse(a.start.dateTime ?? a.start.date) - Date.parse(b.start.dateTime ?? b.start.date));
}
