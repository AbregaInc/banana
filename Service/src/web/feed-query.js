const DAY = 86_400_000;
const refused = (code, status = 400) => { throw Object.assign(new Error(code), { status }); };

// Query values select within a grant. They are never used to construct or widen the grant.
export function feedQuery(url, available, now) {
  const query = new URL(url).searchParams;
  const keys = new Set(['signature', 'types', 'format', 'limit', 'cursor', 'from', 'to', 'calendarDays']);
  for (const key of query.keys()) if (!keys.has(key) || query.getAll(key).length !== 1) refused('bad_feed_query');
  const format = query.get('format') ?? 'json';
  if (!['json', 'csv'].includes(format)) refused('bad_format');
  const rawLimit = query.get('limit') ?? '100';
  if (!/^\d+$/.test(rawLimit) || +rawLimit < 1 || +rawLimit > 100) refused('bad_limit');
  const rawTypes = query.get('types') ?? 'all';
  if (!rawTypes || rawTypes.length > 2048) refused('bad_types');
  const types = rawTypes === 'all' ? [...available] : rawTypes.split(',');
  if (types.some(type => !available.includes(type))) refused('not_shared', 403);
  if (new Set(types).size !== types.length) refused('bad_types');
  types.sort();
  let from = null, to = null;
  if (types.includes('calendar')) {
    if (query.has('from') || query.has('to')) {
      if (query.has('calendarDays') || !query.has('from') || !query.has('to')) refused('bad_calendar_window');
      from = Number(query.get('from')); to = Number(query.get('to'));
      if (!Number.isSafeInteger(from) || !Number.isSafeInteger(to) || from <= 0 || to <= from || to - from > 8 * DAY || Math.abs(from - now) > 366 * DAY) refused('bad_calendar_window');
    } else {
      const days = query.get('calendarDays') ?? '7';
      if (!/^[1-8]$/.test(days)) refused('bad_calendar_window');
      from = Math.floor(now / DAY) * DAY; to = from + Number(days) * DAY;
    }
  } else if (['from','to','calendarDays'].some(key => query.has(key))) refused('calendar_not_selected');
  const cursor = query.get('cursor');
  if (cursor && (cursor.length > 4096 || !/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]{22}$/.test(cursor))) refused('bad_cursor');
  return { types, format, limit: +rawLimit, from, to, cursor };
}
