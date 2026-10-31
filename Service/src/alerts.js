// Event alerts: what one changed event means for the alerts the service sends
// (docs/design/EVENT-ALERTS.md). Pure: an event as Google returns it, what was known of it before,
// the clock, the person's lead times and time zone → the alerts to have, and the new state.
//
// Shared ids: `calendarId|eventId|lead`, lead being the minutes ahead (5, 0) or a word (now,
// invite, changed, cancelled). The devices name their own local alerts the same way.

export const DEFAULT_LEADS = [5, 0];
const MINUTE = 60 * 1000;
/** A title kept only as a hash in `event_state`: enough to tell a rename from a reply. */
export const titleHash = (title) => {
  let h = 0;
  for (const ch of String(title ?? "")) h = (h * 31 + ch.codePointAt(0)) >>> 0;
  return h.toString(16);
};

export const alertId = (calendarId, eventId, lead) => `${calendarId}|${eventId}|${lead}`;
export const BANANA_MARKER = "bananaVariant";

const lower = (s) => (typeof s === "string" ? s.toLowerCase() : null);

/** What matters about an event, read once. */
export function readEvent(event, selfEmail) {
  const self = lower(selfEmail);
  const attendees = Array.isArray(event.attendees) ? event.attendees : [];
  const me = attendees.find((a) => a.self === true) ?? attendees.find((a) => lower(a.email) === self) ?? null;
  const creator = event.creator ?? null;
  const organizer = event.organizer ?? null;
  const isSelf = (who) => who && (who.self === true || (self && lower(who.email) === self));
  // Who made the change, as far as Google says: the creator when there is one, else the organizer.
  const byOther = creator ? !isSelf(creator) : organizer ? !isSelf(organizer) : false;
  const start = event.start?.dateTime ? Date.parse(event.start.dateTime) : null;
  const end = event.end?.dateTime ? Date.parse(event.end.dateTime) : null;
  return {
    id: event.id,
    series: Boolean(event.recurringEventId || event.recurrence?.length),
    cancelled: event.status === "cancelled",
    timed: Number.isFinite(start),
    start, end,
    title: typeof event.summary === "string" && event.summary.trim() ? event.summary.trim() : "(No title)",
    banana: Boolean(event.extendedProperties?.private?.[BANANA_MARKER]),
    response: me?.responseStatus ?? null,
    invited: me?.responseStatus === "needsAction",
    attends: me ? me.responseStatus !== "declined" : true,
    byOther,
    fromGmail: event.eventType === "fromGmail" || Boolean(event.source),
    who: creator?.displayName ?? creator?.email ?? organizer?.displayName ?? organizer?.email ?? "Someone",
    organizerName: organizer?.displayName ?? organizer?.email ?? creator?.displayName ?? creator?.email ?? null,
    timeZone: event.start?.timeZone ?? null,
  };
}

/** "10:30 AM" in the person's zone. */
export function clock(ms, timeZone) {
  try {
    return new Intl.DateTimeFormat("en-US", { hour: "numeric", minute: "2-digit", timeZone: timeZone || "UTC" }).format(new Date(ms));
  } catch {
    return new Intl.DateTimeFormat("en-US", { hour: "numeric", minute: "2-digit", timeZone: "UTC" }).format(new Date(ms));
  }
}

/** "Today 10:30 AM", "Tue 21 Oct, 10:30 AM". */
export function when(ms, now, timeZone) {
  const tz = timeZone || "UTC";
  const day = (t) => { try { return new Intl.DateTimeFormat("en-CA", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date(t)); } catch { return new Date(t).toISOString().slice(0, 10); } };
  const sameDay = day(ms) === day(now);
  const tomorrow = day(ms) === day(now + 24 * 60 * MINUTE);
  if (sameDay) return `Today ${clock(ms, tz)}`;
  if (tomorrow) return `Tomorrow ${clock(ms, tz)}`;
  let date;
  try { date = new Intl.DateTimeFormat("en-GB", { timeZone: tz, weekday: "short", day: "numeric", month: "short" }).format(new Date(ms)); }
  catch { date = new Date(ms).toISOString().slice(0, 10); }
  return `${date}, ${clock(ms, tz)}`;
}

/** The body of a lead alert, as the devices word theirs. */
export function leadBody(start, now, timeZone) {
  const minutes = Math.round((start - now) / MINUTE);
  if (minutes <= 0) return "Starting now.";
  if (minutes === 1) return `Starts in 1 minute, at ${clock(start, timeZone)}.`;
  if (minutes < 60) return `Starts in ${minutes} minutes, at ${clock(start, timeZone)}.`;
  return `Starts at ${clock(start, timeZone)}.`;
}

/**
 * The alerts an event should have now.
 * @param {object} args
 * @param {object} args.event Google's event JSON
 * @param {string} args.calendarId
 * @param {string} args.selfEmail the link's email
 * @param {number} args.now ms
 * @param {number[]} args.leads minutes
 * @param {string|null} args.timeZone the person's zone, for the words
 * @param {object|null} args.previous the event_state row (start_at, end_at, status, response, title_hash) or null
 * @param {boolean} args.baseline a first full read: plan ahead, ring for nothing
 * @returns {{alerts: {id: string, kind: string, dueAt: number, title: string, body: string}[],
 *            state: object|null, dropPending: boolean}}
 *   `alerts`: every alert the event should have (pending lead alerts not in it are dropped);
 *   `state`: the new event_state row, null when the event should be forgotten;
 *   `dropPending`: whether pending lead alerts for the event go.
 */
export function decide({ event, calendarId, selfEmail, now, leads = DEFAULT_LEADS, timeZone = null, previous = null, baseline = false }) {
  const e = readEvent(event, selfEmail);
  const id = (lead) => alertId(calendarId, e.id, lead);
  const tz = timeZone ?? e.timeZone;
  const title = e.title;
  const none = { alerts: [], state: null, dropPending: true };
  if (!e.id || e.banana) return none;

  const state = {
    start_at: e.start, end_at: e.end, status: e.cancelled ? "cancelled" : "confirmed",
    response: e.response, title_hash: titleHash(title),
  };

  if (e.cancelled) {
    const alerts = [];
    // Someone else cancelled it: say so, once, if it was ahead and known.
    if (!baseline && previous && previous.status !== "cancelled" && e.byOther && previous.start_at && previous.start_at > now) {
      alerts.push({ id: id("cancelled"), kind: "cancelled", dueAt: now, title,
        body: `Cancelled by ${e.who} · was ${when(previous.start_at, now, tz)}` });
    }
    return { alerts, state: null, dropPending: true };
  }

  const alerts = [];
  const moved = previous && (previous.start_at !== e.start || previous.end_at !== e.end);
  const isNew = !previous;

  // An invitation he hasn't answered: always visible, any date, with Accept / Decline.
  if (e.invited && !baseline && (isNew || previous.response !== "needsAction")) {
    alerts.push({ id: id("invite"), kind: "invite", dueAt: now, title,
      body: `${e.organizerName ? `Invitation from ${e.organizerName}` : "Invitation"}${e.series ? " · Recurring series" : ""}${e.start ? ` · ${when(e.start, now, tz)}` : ""}` });
  }

  // Someone else added or moved it, or Gmail made it: visible at once, any date.
  if (!baseline && !e.invited && (isNew || moved) && (e.byOther || e.fromGmail) && e.attends) {
    const what = (e.fromGmail && isNew ? "From Gmail" : isNew ? `Added by ${e.who}` : `Moved by ${e.who}`) + (e.series ? " · Recurring series" : "");
    alerts.push({ id: id("changed"), kind: "changed", dueAt: now, title,
      body: e.start ? `${what} · ${when(e.start, now, tz)}` : `${what} · all day` });
  }

  // Starting-soon alerts: timed, attends (not declined, not an unanswered invitation), ahead.
  if (e.timed && e.attends && !e.invited && e.start > now) {
    const ordered = [...new Set(leads.map(Number).filter(Number.isFinite))].sort((a, b) => b - a);
    const ahead = [];
    for (const lead of ordered) {
      const dueAt = e.start - lead * MINUTE;
      if (dueAt > now) ahead.push({ id: id(lead), kind: "lead", dueAt, title, body: leadBody(e.start, dueAt, tz) });
    }
    alerts.push(...ahead);
    // Added or moved to inside the lead window: say so at once, whatever still lies ahead (the
    // at-start alert may still come). A first read plans, it doesn't ring.
    const window = ordered.length ? ordered[0] * MINUTE : 0;
    if (ordered.length && !baseline && (isNew || moved) && e.start - window <= now) {
      alerts.push({ id: id("now"), kind: "now", dueAt: now, title, body: leadBody(e.start, now, tz) });
    }
  }
  return { alerts, state, dropPending: true };
}

/** The visible push for an alert. */
export function alertPayload(alert, { calendarId, eventId, email }) {
  return {
    aps: {
      alert: { title: alert.title, body: alert.body },
      sound: "default",
      category: alert.kind === "invite" ? "EVENT_INVITE" : "EVENT_ALERT",
      "thread-id": `${calendarId}|${eventId}`,
      "interruption-level": "time-sensitive",
    },
    b: { k: "alert", id: alert.id, kind: alert.kind, cal: calendarId, event: eventId, email },
  };
}

/** The background push that clears an alert on the other devices. */
export const clearPayload = (id) => ({ aps: { "content-available": 1 }, b: { k: "alert-clear", id } });

/** APNs's collapse id is 64 bytes at most: a short hash of the alert id. */
export function collapseId(id) {
  let h1 = 0x811c9dc5, h2 = 0x01000193;
  for (const ch of String(id)) { const c = ch.codePointAt(0); h1 = ((h1 ^ c) * 16777619) >>> 0; h2 = ((h2 + c) * 2654435761) >>> 0; }
  return `a-${h1.toString(16)}${h2.toString(16)}`;
}
