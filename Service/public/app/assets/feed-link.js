// One endpoint; query parameters select a subset of the server-enforced grant.
export function feedLink(base, { types = 'all', format = 'json', calendarDays } = {}) {
  const url = new URL(base);
  if (!['json', 'csv'].includes(format)) throw new Error('Choose JSON or CSV.');
  const selected = Array.isArray(types) ? [...new Set(types)].sort() : types;
  if (Array.isArray(selected) && !selected.length) throw new Error('Select at least one data type.');
  url.searchParams.delete('view'); url.searchParams.delete('cursor');
  url.searchParams.delete('from'); url.searchParams.delete('to');
  url.searchParams.set('types', Array.isArray(selected) ? selected.join(',') : selected);
  url.searchParams.set('format', format);
  const calendar = Array.isArray(selected) ? selected.includes('calendar') : selected === 'all' && calendarDays != null;
  if (calendar) url.searchParams.set('calendarDays', String(calendarDays ?? 7));
  else url.searchParams.delete('calendarDays');
  return url.href;
}
