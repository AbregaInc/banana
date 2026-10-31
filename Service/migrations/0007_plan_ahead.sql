-- When the service last read a calendar's next month to plan its alerts (once a day): alerts are
-- kept only a month ahead, so an event further out is planned as it comes within the month.
ALTER TABLE calendar_sync ADD COLUMN planned_at BIGINT;

-- What a device rings for, as it reports with its held alerts (build 61 on): the calendars it
-- alerts for (JSON ids; the ones it reads, less hidden and the ones set not to count) and the
-- events it was told to skip (JSON `calendarId|eventId`). A device that hasn't said gets no
-- alert from the service: it would otherwise ring for calendars it leaves out.
ALTER TABLE devices ADD COLUMN alert_calendars TEXT;
ALTER TABLE devices ADD COLUMN quiet_events TEXT;
