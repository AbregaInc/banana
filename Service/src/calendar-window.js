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

export async function readCalendarWindow(deps, { vault, account, settings, from, to, includeDeclined = false }) {
    const links = await deps.db.all("SELECT sub, email, refresh_token, scopes, status FROM google_links WHERE account_id = ? AND status <> 'unlinked' ORDER BY created_at, sub", account);
    const results = await Promise.all(links.map(async (link) => {
      const result = { events: [], unavailable: [] };
      if (!link.refresh_token || link.status !== "ok" || !canRead(link.scopes)) {
        result.unavailable.push({ email: link.email, reason: "reconnect" }); return result;
      }
      try {
        const { accessToken } = await deps.google.refresh(await vault.open(link.sub, link.refresh_token));
        const calendars = (await deps.google.calendarList(accessToken)).filter(cal => !cal.deleted && !cal.hidden && includesCalendar(cal, link.email, settings));
        // In bounded groups so a large account does not exhaust the Worker's outgoing connections.
        for (let i = 0; i < calendars.length; i += 4) {
          const group = await Promise.all(calendars.slice(i, i + 4).map(async (cal) => {
            try {
              const { events } = await deps.google.listEvents(accessToken, cal.id, {
                timeMin: new Date(from).toISOString(), timeMax: new Date(to).toISOString(),
                fields: "items(id,iCalUID,originalStartTime,summary,start,end,status,location,description,htmlLink,transparency,attendees,organizer,attachments,extendedProperties,hangoutLink,conferenceData,eventType,recurrence,recurringEventId),nextPageToken,nextSyncToken",
              });
              return events.map(event => ({ event, calendar: cal, email: link.email }));
            } catch { result.unavailable.push({ email: link.email, calendar: cal.summary || "Calendar", reason: "retry" }); return []; }
          }));
          result.events.push(...group.flat());
        }
      } catch (error) {
        result.unavailable.push({ email: link.email, reason: error instanceof GoogleRefused ? "reconnect" : "retry" });
      }
      return result;
    }));
    return { events: calendarAgenda(results.flatMap(r => r.events), settings, { details: true, includeDeclined: includeDeclined, allDay: includeDeclined }),
      weekStartWeekday: calendarSettings(settings).weekStartWeekday,
      unavailable: results.flatMap(r => r.unavailable) };
}
