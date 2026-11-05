// Shared provider read for the existing web agenda and gated native cloud reader.
// Read-only: no event, watch or write-back ownership changes occur here.
import { GoogleRefused } from './google.js';
import { canRead } from './booking/busy.js';
import { calendarAgenda, calendarSettings, includesCalendar } from './web/calendar.js';

const DAY = 86_400_000;
export function validCalendarWindow(from, to, now) {
  return Number.isFinite(from) && Number.isFinite(to) && from > 0 && to > from
    && to - from <= 8 * DAY && Math.abs(from - now) <= 366 * DAY;
}

async function readCalendarSources(deps, { vault, account, settings, from, to, native = false }) {
    const links = await deps.db.all("SELECT sub, email, refresh_token, scopes, status FROM google_links WHERE account_id = ? AND status <> 'unlinked' ORDER BY created_at, sub", account);
    const results = await Promise.all(links.map(async (link) => {
      const result = { sources: [], unavailable: [] };
      if (!link.refresh_token || link.status !== "ok" || !canRead(link.scopes)) {
        result.unavailable.push({ email: link.email, reason: "reconnect" }); return result;
      }
      try {
        const { accessToken } = await deps.google.refresh(await vault.open(link.sub, link.refresh_token));
        const calendars = (await deps.google.calendarList(accessToken)).filter(cal => !cal.deleted && !cal.hidden && (native || includesCalendar(cal, link.email, settings)));
        // In bounded groups so a large account does not exhaust the Worker's outgoing connections.
        for (let i = 0; i < calendars.length; i += 4) {
          const group = await Promise.all(calendars.slice(i, i + 4).map(async (cal) => {
            try {
              const { events } = await deps.google.listEvents(accessToken, cal.id, {
                timeMin: new Date(from).toISOString(), timeMax: new Date(to).toISOString(),
                fields: `items(id,iCalUID,originalStartTime,summary,start,end,status,location,description,htmlLink,transparency,attendees,organizer,attachments,extendedProperties,hangoutLink,conferenceData,eventType,recurrence,recurringEventId${native ? ",etag,reminders" : ""}),nextPageToken,nextSyncToken`,
              });
              return { email: link.email, calendar: cal, events };
            } catch { result.unavailable.push({ email: link.email, calendar: cal.summary || "Calendar", ...(native ? { calendarID: cal.id } : {}), reason: "retry" }); return null; }
          }));
          result.sources.push(...group.filter(Boolean));
        }
      } catch (error) {
        result.unavailable.push({ email: link.email, reason: error instanceof GoogleRefused ? "reconnect" : "retry" });
      }
      return result;
    }));
    return { sources: results.flatMap(r => r.sources), unavailable: results.flatMap(r => r.unavailable) };
}

export async function readCalendarWindow(deps, options) {
    const result = await readCalendarSources(deps, options);
    const events = result.sources.flatMap(source => source.events.map(event => ({
      event, calendar: source.calendar, email: source.email,
    })));
    return { events: calendarAgenda(events, options.settings, {
      details: true, includeDeclined: options.includeDeclined ?? false, allDay: options.includeDeclined ?? false,
    }), weekStartWeekday: calendarSettings(options.settings).weekStartWeekday, unavailable: result.unavailable };
}

// Native caches need provider identities, edit versions and successful empty calendars.
// Never expose refresh/access tokens or a provider sync token for devices to continue themselves.
export async function readCalendarSnapshot(deps, options) {
    return readCalendarSources(deps, { ...options, native: true });
}
