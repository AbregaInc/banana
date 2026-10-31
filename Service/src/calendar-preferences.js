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
