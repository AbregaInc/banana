// The booking as a calendar file (RFC 5545), for "Add to calendar" and the confirmation email. Its
// UID is the Google event's, so a calendar that also takes Google's invite keeps one event.

const stamp = (ms) => new Date(ms).toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
/** TEXT values: backslash, semicolon, comma and newlines escaped, control characters dropped. */
const text = (s) => String(s ?? "").replace(/[\u0000-\u0009\u000b-\u001f\u007f]/g, "").replace(/\\/g, "\\\\").replace(/;/g, "\;").replace(/,/g, "\\,").replace(/\r?\n/g, "\\n");
/** Lines folded at 73 characters (RFC 5545 says 75 octets; calendar apps read longer multi-byte lines). */
const fold = (line) => { const out = []; let s = line; while (s.length > 73) { out.push(s.slice(0, 73)); s = ` ${s.slice(73)}`; } out.push(s); return out.join("\r\n"); };

/**
 * @param {{id: string, start: number, end: number, title: string, description?: string,
 *          location?: string|null, url?: string|null, now: number, cancelled?: boolean,
 *          sequence?: number, modified?: number}} e   sequence: one more at each move or cancel
 */
export function icsFile(e) {
  const lines = [
    "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Banana//Booking//EN", "CALSCALE:GREGORIAN", "METHOD:PUBLISH",
    "BEGIN:VEVENT",
    `UID:${e.id}@google.com`,
    `DTSTAMP:${stamp(e.now)}`,
    `LAST-MODIFIED:${stamp(e.modified ?? e.now)}`,
    `SEQUENCE:${Number.isInteger(e.sequence) && e.sequence >= 0 ? e.sequence : 0}`,
    `DTSTART:${stamp(e.start)}`,
    `DTEND:${stamp(e.end)}`,
    `SUMMARY:${text(e.title)}`,
    ...(e.description ? [`DESCRIPTION:${text(e.description)}`] : []),
    ...(e.location ? [`LOCATION:${text(e.location)}`] : []),
    ...(e.url ? [`URL:${text(e.url)}`] : []),
    `STATUS:${e.cancelled ? "CANCELLED" : "CONFIRMED"}`,
    "END:VEVENT", "END:VCALENDAR",
  ];
  return lines.map(fold).join("\r\n") + "\r\n";
}
