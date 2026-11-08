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

// The account's own calendar: its primary, or one whose Google data owner is the account. The owner
// role alone is not ownership (manage-sharing access grants it, group calendars have no data owner).
// Mirrors GoogleCalendar.isOwnedByAccount.
export function isAccountOwnedCalendar(calendar, accountEmail) {
  if (calendar?.primary === true) return true;
  const viewer = String(accountEmail ?? '').trim().toLowerCase();
  const owner = String(calendar?.dataOwner ?? '').trim().toLowerCase();
  return Boolean(owner) && Boolean(viewer) && owner === viewer;
}

export function calendarBlocksTime(record, calendar, accountEmail) {
  const {settings} = calendarSettings(record);
  const override = settings.calendarBlockingOverrides?.[calendar.id];
  if (typeof override === 'boolean') return override;
  return isAccountOwnedCalendar(calendar, accountEmail);
}
