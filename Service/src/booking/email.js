// Booking email (docs/design/BOOKING.md §12 "Email"): the `deps.email` port and the messages.
// Cloudflare Email Service on Workers (`[[send_email]] name = "EMAIL"`, Workers Paid and the domain
// onboarded); a memory outbox on Node and in tests. From `Banana <book@ce.bananatheapp.com>`, reply-to
// the host. Every time is in the guest's zone at the meeting's instant ("3:00 pm, New York time").
//
// Never logged: addresses, names, notes, links.

import { whenLine } from "./slots.js";

/** The port on Cloudflare Email Service: env.EMAIL.send({...}) (the structured builder form). */
export function cloudflareEmail(binding) {
  return {
    enabled: true,
    async send(message) {
      const { messageId } = await binding.send({
        to: message.to, from: address(message.from), subject: message.subject, html: message.html, text: message.text,
        ...(message.replyTo ? { replyTo: address(message.replyTo) } : {}),
        ...(message.attachments?.length ? { attachments: message.attachments } : {}),
      });
      return { id: messageId ?? null };
    },
  };
}

/** "Banana <book@ce.bananatheapp.com>" as the binding's EmailAddress, {email, name}: the documented way
 * to give a display name. A bare address stays a string. */
export function address(text) {
  const m = /^\s*(.*?)\s*<([^<>\s]+@[^<>\s]+)>\s*$/.exec(String(text));
  if (!m) return String(text).trim();
  return m[1] ? { email: m[2], name: m[1].replace(/^"|"$/g, "") } : m[2];
}

/** The port with nowhere to send: kept in memory (Node without a provider, the tests). */
export function memoryEmail({ log = true, enabled = false } = {}) {
  const sent = [];
  return {
    sent,
    /** No provider: the pages offer nothing that needs an email (codes, "we emailed you"). */
    enabled,
    async send(message) {
      sent.push(message);
      if (log) console.log(`email: ${message.kind ?? "message"} kept (no provider here)`);
      return { id: `memory-${sent.length}` };
    },
  };
}

const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
const base64 = (text) => { let s = ""; for (const b of new TextEncoder().encode(text)) s += String.fromCharCode(b); return btoa(s); };

/** The landing page's look, in mail-safe HTML: cream, ink, Plex Mono where the client has it. */
function layout({ title, lines, button, after }) {
  const body = lines.map((l) => `<p style="margin:0 0 12px">${l}</p>`).join("");
  const action = button ? `<p style="margin:20px 0"><a href="${esc(button.url)}" style="display:inline-block;background:#221d38;color:#fbf6ea;text-decoration:none;padding:12px 18px;border-radius:10px;font-weight:600">${esc(button.label)}</a></p>` : "";
  return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><meta name="color-scheme" content="light"><title>${esc(title)}</title></head>
<body style="margin:0;background:#fbf6ea;color:#221d38;font-family:'IBM Plex Mono',ui-monospace,Menlo,Consolas,monospace;font-size:15px;line-height:1.5">
<div style="max-width:520px;margin:0 auto;padding:28px 20px">
<p style="margin:0 0 20px;font-weight:700;font-size:17px">Banana</p>
<h1 style="margin:0 0 16px;font-size:20px;line-height:1.3">${esc(title)}</h1>
${body}${action}${after ? `<p style="margin:16px 0 0;color:#766f90;font-size:13px">${after}</p>` : ""}
</div></body></html>`;
}

const plain = ({ title, lines, button, after }) =>
  [title, "", ...lines.map((l) => l.replace(/<[^>]+>/g, "").replace(/&#(\d+);/g, (_, n) => String.fromCharCode(Number(n)))), button ? `\n${button.label}: ${button.url}` : "", after ? `\n${after.replace(/<[^>]+>/g, "")}` : ""]
    .join("\n").trim() + "\n";

/** The place in words, after booking: the Meet link, the number, the address. */
function placeLine(b) {
  switch (b.place_kind) {
    case "meet": return b.place_detail ? `Google Meet: <a href="${esc(b.place_detail)}">${esc(b.place_detail)}</a>` : "Google Meet (the link is in the invite)";
    case "zoom": return `Zoom: <a href="${esc(b.place_detail)}">${esc(b.place_detail)}</a>`;
    case "link": return `Join: <a href="${esc(b.place_detail)}">${esc(b.place_detail)}</a>`;
    case "phone_host_calls": return `Phone: ${esc(b.hostName)} calls you on ${esc(b.guest_phone ?? "")}`;
    case "phone_guest_calls": return `Phone: call ${esc(b.hostName)} on ${esc(b.place_detail ?? "")}`;
    case "in_person": return `Where: ${esc(b.place_detail ?? "")}`;
    default: return "";
  }
}

/**
 * One booking email. `b` is the booking row with `hostName`, `hostEmail`, `manageUrl`, `pageUrl`
 * and, for a confirmation, `ics` (the calendar file's text).
 * @param {"confirmed"|"reminder24"|"reminder1"|"moved"|"cancelled"|"taken"|"failed"|"existing"} kind
 */
export function bookingEmail(kind, b, { from }) {
  const zone = b.guest_zone || "UTC";
  const when = whenLine(Number(b.start_at), Number(b.end_at), zone);
  const what = `${b.type_title} with ${b.hostName}`;
  const change = { label: "Change or cancel", url: b.manageUrl };
  const shapes = {
    confirmed: { subject: `Booked: ${what}, ${when}`, title: "You're booked", lines: [esc(what), esc(when), placeLine(b)], button: change,
      after: "The invite from Google Calendar is on its way too." },
    reminder24: { subject: `Tomorrow: ${what}`, title: "Tomorrow", lines: [esc(what), esc(when), placeLine(b)], button: change },
    reminder1: { subject: `In an hour: ${what}`, title: "In an hour", lines: [esc(what), esc(when), placeLine(b)], button: change },
    moved: { subject: `Moved: ${what}, ${when}`, title: "Your time moved", lines: [`${esc(b.hostName)} moved it to:`, esc(when), placeLine(b)], button: change },
    cancelled: { subject: `Cancelled: ${what}`, title: "Cancelled", lines: [`${esc(what)}, ${esc(when)}, is off.`], button: b.pageUrl ? { label: "Pick a new time", url: b.pageUrl } : null },
    taken: { subject: `Pick another time: ${what}`, title: "That time just went", lines: [`Someone booked ${esc(when)} a moment before you.`], button: { label: "Pick another time", url: b.pageUrl } },
    failed: { subject: `Not booked: ${what}`, title: "That didn't go through", lines: [`${esc(what)}, ${esc(when)}, couldn't be booked.`], button: { label: "Pick another time", url: b.pageUrl } },
    existing: { subject: `Your time: ${what}`, title: "You already have a time", lines: [esc(what), esc(when), placeLine(b)], button: change },
  };
  const s = shapes[kind];
  const message = {
    kind, to: b.guest_email, from, subject: s.subject, html: layout(s), text: plain(s),
    ...(b.hostEmail ? { replyTo: b.hostEmail } : {}),
  };
  if (kind === "confirmed" && b.ics) {
    message.attachments = [{ content: base64(b.ics), filename: "invite.ics", type: "text/calendar", disposition: "attachment" }];
  }
  return message;
}

/** The 6-digit code. */
export function codeEmail(to, code, { from }) {
  const s = { title: `${code} is your Banana code`, lines: [`Enter <b>${esc(code)}</b> on the booking page. It works for 10 minutes.`], after: "Didn't ask for it? Ignore this email." };
  return { kind: "code", to, from, subject: s.title, html: layout(s), text: plain(s) };
}
