/** Small bounded serializer, not a CSV parser. Arrays remain JSON; scalar fields are columns. */
export function feedCSV(records, { typed = records.some(r => r.type != null) } = {}) {
  function flatten(value, prefix = '', result = Object.create(null), depth = 0) {
    for (const [key, item] of Object.entries(value ?? {})) {
      const name = prefix ? `${prefix}.${key}` : key;
      if (item && typeof item === 'object' && !Array.isArray(item) && depth < 4) flatten(item, name, result, depth + 1);
      else {
        if (Object.hasOwn(result, name)) throw new Error('csv_field_collision');
        result[name] = item;
      }
    }
    return result;
  }
  const rows = records.map(r => ({ ...(typed ? { type: r.type } : {}), id: r.id, ...Object.fromEntries(Object.entries(flatten(r.data)).map(([k, v]) => [`data.${k}`, v])),
    assets: r.assets ?? [] }));
  const headers = [...(typed ? ['type'] : []), 'id', ...[...new Set(rows.flatMap(r => Object.keys(r)))].filter(k => k !== 'id' && k !== 'type').sort()];
  if (headers.length > 1024) throw new Error('csv_too_wide');
  const cell = v => {
    let text = v == null ? '' : typeof v === 'object' ? JSON.stringify(v) : String(v);
    // Keep numeric values numeric, but do not turn untrusted strings into spreadsheet formulas.
    if (typeof v === 'string' && /^[\s\u0000-\u001f]*[=+@-]/.test(text)) text = "'" + text;
    return '"' + text.replaceAll('"', '""') + '"';
  };
  return [headers.map(cell).join(','), ...rows.map(r => headers.map(h => cell(r[h])).join(','))].join('\r\n') + '\r\n';
}
