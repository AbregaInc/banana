// Portable native settings: keep these IDs and defaults aligned with SmartScheduleSettings.
export const calendarInfoID = id => 'google-calendar:' + btoa(String.fromCharCode(...new TextEncoder().encode(id)));
export function calendarSettings(record){
  const value=record?.v??record??{},settings=value.settings??{};
  return {settings,excludedCalendars:value.excludedCalendars??[],weekStartWeekday:settings.weekStartWeekday>=1&&settings.weekStartWeekday<=7?settings.weekStartWeekday:2};
}

export function calendarNotifies(record, calendarID) {
  const { settings } = calendarSettings(record);
  return !(settings.mutedCalendarIDs ?? []).includes(calendarID)
    && !(settings.excludedCalendarIDs ?? []).some(id => id === calendarID || id === calendarInfoID(calendarID));
}

// Google's family calendar: every family member manages it, so its "owner" role is everyone's.
// Mirrors GoogleCalendar.isFamilyCalendarID.
export const isFamilyCalendar = id => /^family[0-9]+@group\.calendar\.google\.com$/i.test(String(id ?? ''));

// Manager permission alone does not establish personal ownership.
export function calendarBlocksTime(record, calendar, accountEmail) {
  const {settings} = calendarSettings(record);
  const override = settings.calendarBlockingOverrides?.[calendar.id];
  if (typeof override === 'boolean') return override;
  if (calendar.accessRole !== 'owner' || isFamilyCalendar(calendar.id)) return false;
  const viewer = String(accountEmail ?? '').trim().toLowerCase();
  const owner = String(calendar.dataOwner ?? '').trim().toLowerCase();
  if (owner) return owner === viewer;
  if (calendar.primary) return true;
  if (calendar.id.includes('@') && !calendar.id.endsWith('.calendar.google.com')) return calendar.id.toLowerCase() === viewer;
  return true;
}
