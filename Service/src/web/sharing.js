import { CATALOG } from '../catalog.js';
import { newId } from '../crypto.js';
import { personalSpace } from '../sync-routes.js';
import { canRead } from '../booking/busy.js';
import { calendarSettings } from './calendar.js';
import { GoogleRefused } from '../google.js';
import { lzfseDecompress } from '../../public/app/assets/vendor/lzfse.js';
const MOST_SNAPSHOT_BYTES = 8 * 1024 * 1024;   // a packed Health snapshot the Worker decodes
import { allowedTypes, allowedViews, calendarKey, normalizePolicy, projectHealthSnapshot, sharedCalendar } from './sharing-policy.js';

const DAY = 86_400_000, HOUR = 3_600_000;
const esc = v => String(v ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const parse = value => { try { return JSON.parse(value); } catch { return null; } };
const emailAddress = value => typeof value === 'string' && value.length <= 254 && /^[^\s<>@]+@[^\s<>@]+\.[^\s<>@]+$/.test(value.trim()) ? value.trim().toLowerCase() : null;

export function sharingRoutes(app, deps, { owner, signedIn, calendarChoices, vault, webOrigin, home }) {
  const { db, now } = deps;
  const spaceFor = account => deps.spaces.get(personalSpace(account));
  const error = (c, code, status = 400) => c.json({ error: code }, status);
  const ownerRow = c => db.first('SELECT * FROM web_shares WHERE id = ? AND owner_id = ?', c.req.param('id'), c.get('web').account);
  const ownerName = async account => (await db.first("SELECT COALESCE(name, email) AS name FROM google_links WHERE account_id = ? AND status <> 'unlinked' ORDER BY created_at LIMIT 1", account))?.name ?? 'A Banana member';
  const summary = row => ({ id: row.id, email: row.email, guestName: row.guest_name, status: row.status,
    policy: parse(row.policy), draftPolicy: parse(row.draft_policy), version: row.draft_version,
    publishedVersion: row.published_version, previewed: row.previewed_version === row.draft_version && Number(row.previewed_at) > now() - 30 * 60_000,
    sendStatus: row.send_status, lastSentAt: row.last_sent_at, acceptedAt: row.accepted_at, updatedAt: row.updated_at });
  const sameOrigin = async (c, next) => {
    if (!['GET', 'HEAD'].includes(c.req.method) && c.req.header('Origin') !== webOrigin) return error(c, 'origin', 403);
    return next();
  };
  app.use('/app/api/shares', sameOrigin);
  app.use('/app/api/shares/*', sameOrigin);
  async function body(c) {
    if (c.req.header('Origin') !== webOrigin) return null;
    const raw = await c.req.text();
    if (raw.length > 65_536) return null;
    return parse(raw);
  }
  async function checkedPolicy(c, value) {
    const policy = normalizePolicy(value);
    if (policy.calendars.length) {
      const choices = await calendarChoices(c);
      const available = new Set(choices.accounts.flatMap(a => a.calendars.map(cal => calendarKey(a.sub, cal.id))));
      if (policy.calendars.some(cal => !available.has(calendarKey(cal.sub, cal.id)))) throw new Error('A selected calendar is unavailable. Reconnect it or change the selection.');
    }
    return policy;
  }
  app.get('/app/api/session', signedIn, async c => {
    const who = c.get('web');
    const shares = await db.all(`SELECT s.id, s.status, s.updated_at,
      (SELECT COALESCE(g.name, g.email) FROM google_links g WHERE g.account_id = s.owner_id AND g.status <> 'unlinked' ORDER BY g.created_at LIMIT 1) AS owner
      FROM web_shares s WHERE s.status IN ('invited', 'active') AND s.policy IS NOT NULL
      AND (s.guest_sub = ? OR (s.guest_sub IS NULL AND s.email = ?)) ORDER BY s.updated_at DESC`, who.sub, who.authEmail);
    return c.json({ kind: who.kind, email: who.authEmail, shares: shares.map(s => ({ ...s, owner: s.owner ?? 'A Banana member' })) });
  });
  app.get('/app/api/shares', owner, async c => {
    const rows = await db.all('SELECT * FROM web_shares WHERE owner_id = ? ORDER BY created_at DESC', c.get('web').account);
    return c.json({ shares: rows.map(summary), emailEnabled: Boolean(deps.email?.enabled) });
  });
  app.post('/app/api/shares', owner, async c => {
    const input = await body(c), email = emailAddress(input?.email);
    if (!email) return error(c, 'Enter the guest’s Google sign-in email.');
    let policy;
    try { policy = await checkedPolicy(c, input.policy); } catch (e) { return error(c, e.message); }
    const count = await db.first("SELECT COUNT(*) AS n FROM web_shares WHERE owner_id = ? AND status <> 'revoked'", c.get('web').account);
    if (Number(count.n) >= 100) return error(c, 'Remove an old invitation before adding another.', 409);
    const id = newId(deps.random), t = now();
    await db.run('INSERT INTO web_shares (id, owner_id, email, draft_policy, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)',
      id, c.get('web').account, email, JSON.stringify(policy), t, t);
    return c.json(summary(await db.first('SELECT * FROM web_shares WHERE id = ?', id)), 201);
  });
  app.put('/app/api/shares/:id/draft', owner, async c => {
    const row = await ownerRow(c);
    if (!row || row.status === 'revoked') return error(c, 'not_found', 404);
    const input = await body(c), email = emailAddress(input?.email);
    if (!email || (row.policy && email !== row.email)) return error(c, 'The recipient of a published invitation cannot be changed.');
    if (input.version !== row.draft_version) return error(c, 'This invitation changed in another tab. Reopen it before editing.', 409);
    let policy;
    try { policy = await checkedPolicy(c, input.policy); } catch (e) { return error(c, e.message); }
    const updated = await db.run(`UPDATE web_shares SET email = ?, draft_policy = ?, draft_version = draft_version + 1,
      previewed_version = NULL, previewed_at = NULL, updated_at = ? WHERE id = ? AND owner_id = ? AND draft_version = ? AND status <> 'revoked'`,
      email, JSON.stringify(policy), now(), row.id, row.owner_id, input.version);
    if (!updated.changes) return error(c, 'This invitation changed. Reopen it before editing.', 409);
    return c.json(summary(await ownerRow(c)));
  });
  app.post('/app/api/shares/:id/preview', owner, async c => {
    const input = await body(c), row = await ownerRow(c);
    if (!row || row.status === 'revoked') return error(c, 'not_found', 404);
    if (input?.version !== row.draft_version) return error(c, 'Preview the latest version of this invitation.', 409);
    const result = await db.run(`UPDATE web_shares SET previewed_version = draft_version, previewed_at = ?
      WHERE id = ? AND owner_id = ? AND draft_version = ? AND status <> 'revoked'`, now(), row.id, row.owner_id, input.version);
    if (!result.changes) return error(c, 'This invitation changed. Preview it again.', 409);
    return c.json({ url: `${webOrigin}/share/${row.id}?preview=${row.draft_version}` });
  });
  async function publish(c, sendEmail) {
    const input = await body(c), row = await ownerRow(c);
    if (!row || row.status === 'revoked') return error(c, 'not_found', 404);
    if (input?.version !== row.draft_version || row.previewed_version !== row.draft_version || Number(row.previewed_at) <= now() - 30 * 60_000)
      return error(c, 'Preview the current permissions before publishing them.', 409);
    if (!sendEmail && !row.policy) return error(c, 'Send the invitation to publish it.', 409);
    if (sendEmail) {
      if (!deps.email?.enabled) return error(c, 'Email delivery is not configured. Your draft has been kept.', 503);
      if (row.last_sent_at != null && now() - Number(row.last_sent_at) < 60_000) return error(c, 'Wait a minute before sending this invitation again.', 429);
      const limit = await db.first(`INSERT INTO web_share_mail_limits (owner_id, window_at, sent) VALUES (?, ?, 1)
        ON CONFLICT(owner_id) DO UPDATE SET sent = CASE WHEN web_share_mail_limits.window_at = excluded.window_at THEN web_share_mail_limits.sent + 1 ELSE 1 END,
        window_at = excluded.window_at RETURNING sent`, row.owner_id, Math.floor(now() / HOUR) * HOUR);
      if (Number(limit.sent) > 20) return error(c, 'Too many invitations this hour. Try again later.', 429);
    }
    const sentAt = now();
    const changed = await db.run(`UPDATE web_shares SET policy = draft_policy, published_version = draft_version,
      status = CASE WHEN guest_sub IS NULL THEN 'invited' ELSE 'active' END, updated_at = ?,
      send_status = CASE WHEN ? THEN 'sending' ELSE send_status END, last_sent_at = CASE WHEN ? THEN ? ELSE last_sent_at END
      WHERE id = ? AND owner_id = ? AND draft_version = ? AND previewed_version = ? AND status <> 'revoked'
      AND (? = 0 OR last_sent_at IS NULL OR last_sent_at <= ?)`,
      sentAt, sendEmail, sendEmail, sentAt, row.id, row.owner_id, input.version, input.version, sendEmail, now() - 60_000);
    if (!changed.changes) return error(c, 'This invitation changed. Reopen and preview it again.', 409);
    if (sendEmail) {
      const name = await ownerName(row.owner_id), url = `${webOrigin}/share/${row.id}`;
      try {
        await deps.email.send({ kind: 'web-invitation', to: row.email, from: deps.config.emailFrom,
          replyTo: c.get('web').email, subject: `${name} invited you to Banana`,
          text: `${name} has shared part of their Banana with you.\n\nOpen ${url}\n\nSign in with Google using ${row.email}. Access is read-only and limited to what ${name} chose to share.`,
          html: `<h1>${esc(name)} invited you to Banana</h1><p>See the calendars and data they chose to share with you.</p><p><a href="${esc(url)}">Open your invitation</a></p><p>Sign in with Google using ${esc(row.email)}. Your access is read-only.</p>` });
        await db.run("UPDATE web_shares SET send_status = 'sent' WHERE id = ? AND last_sent_at = ? AND status <> 'revoked'", row.id, sentAt);
      } catch (error) {
        // Provider codes diagnose delivery without logging guest addresses or invitation URLs.
        const code = /^E_[A-Z_]+$/.test(String(error?.code)) ? error.code : 'UNKNOWN';
        console.warn(`web-invitation delivery failed: ${code}`);
        await db.run("UPDATE web_shares SET send_status = 'failed' WHERE id = ? AND last_sent_at = ? AND status <> 'revoked'", row.id, sentAt);
        return c.json({ error: 'The email could not be sent. Your approved permissions have been saved; you can retry the invitation.', share: summary(await ownerRow(c)) }, 502);
      }
    }
    return c.json(summary(await ownerRow(c)));
  }
  app.post('/app/api/shares/:id/send', owner, c => publish(c, true));
  app.post('/app/api/shares/:id/publish', owner, c => publish(c, false));
  app.post('/app/api/shares/:id/revoke', owner, async c => {
    if (!await body(c)) return error(c, 'origin', 403);
    const row = await ownerRow(c);
    if (!row) return error(c, 'not_found', 404);
    await db.run("UPDATE web_shares SET status = 'revoked', revoked_at = ?, updated_at = ? WHERE id = ? AND owner_id = ?", now(), now(), row.id, row.owner_id);
    return c.json(summary(await ownerRow(c)));
  });

  async function access(c) {
    const who = c.get('web'), row = await db.first('SELECT * FROM web_shares WHERE id = ?', c.req.param('id'));
    if (!row || row.status === 'revoked') return null;
    const preview = c.req.query('preview');
    if (preview != null) {
      if (who.kind !== 'person' || who.account !== row.owner_id || String(row.draft_version) !== preview
        || row.previewed_version !== row.draft_version) return null;
      return { row, policy: normalizePolicy(parse(row.draft_policy)), preview: true };
    }
    if (!row.policy || !['invited', 'active'].includes(row.status)) return null;
    if (row.guest_sub ? row.guest_sub !== who.sub : row.email !== who.authEmail) return null;
    if (!row.guest_sub) {
      const accepted = await db.run(`UPDATE web_shares SET guest_sub = ?, guest_name = ?, accepted_at = ?, status = 'active', updated_at = ?
        WHERE id = ? AND guest_sub IS NULL AND email = ? AND status = 'invited'`, who.sub, who.name, now(), now(), row.id, who.authEmail);
      if (!accepted.changes) {
        const current = await db.first('SELECT guest_sub, status FROM web_shares WHERE id = ?', row.id);
        if (current?.guest_sub !== who.sub || current.status !== 'active') return null;
      }
    }
    return { row, policy: normalizePolicy(parse(row.policy)), preview: false };
  }
  const shared = async (c, next) => {
    const grant = await access(c);
    if (!grant) return error(c, 'access_unavailable', 403);
    // The owner's Google quota and space sit behind these reads: a share gets so many a minute.
    if (!(await deps.limit('share', grant.row.id))) return error(c, 'rate', 429);
    c.set('share', grant);
    return next();
  };
  app.get('/app/api/shared/:id/account', signedIn, shared, async c => {
    const { row, policy, preview } = c.get('share'), stub = spaceFor(row.owner_id);
    const [consents, counts, smart, prefs, latest, name, phone] = await Promise.all([stub.consents(), stub.counts(), stub.read('core.smartSettings', 'smart-settings'),
      stub.read('core.appSettings', 'appSettings'), db.first('SELECT MAX(last_sync_at) AS at FROM devices WHERE account_id = ?', row.owner_id), ownerName(row.owner_id), db.first("SELECT bundle FROM devices WHERE account_id = ? AND platform = 'iphone' ORDER BY last_sync_at DESC, updated_at DESC, id LIMIT 1", row.owner_id)]);
    const types = [...allowedTypes(policy)].filter(type => CATALOG.get(type)?.tier !== 'T2' || consents.health);
    return c.json({ email: c.get('web').authEmail, name, ownerName: name, shared: true, preview, audience: preview ? row.email : undefined,
      shareVersion: preview ? row.draft_version : row.published_version, views: allowedViews(policy), allowedTypes: types,
      consents: { health: Boolean(consents.health && types.some(type => CATALOG.get(type)?.tier === 'T2')), transcripts: Boolean(consents.transcripts && policy.sections.listening) },
      counts: Object.fromEntries(Object.entries(counts).filter(([type]) => types.includes(type))),
      preferences: { distanceUnit: prefs?.distanceUnit ?? null, ownBundleID: phone?.bundle ?? null }, weekStartWeekday: calendarSettings(smart).weekStartWeekday,
      lastSync: latest?.at ?? null, now: now(), previewBack: preview ? `${home}#sharing/${row.id}` : undefined });
  });
  app.get('/app/api/shared/:id/records', signedIn, shared, async c => {
    const { row, policy } = c.get('share'), type = c.req.query('type'), after = c.req.query('after') ?? '';
    if (!allowedTypes(policy).has(type)) return error(c, 'not_shared', 403);
    if (after.length > 200) return error(c, 'bad_request');
    const result = await spaceFor(row.owner_id).browse(type, after);
    if (type === 'health.snapshot') result.records = result.records.map(record => ({ ...record,
      fields: { v: record.fields.v?.$blob ? { $blob: 'shared-health-snapshot', ext: 'json' }
        : projectHealthSnapshot(record.fields.v ?? record.fields, policy) } }));
    return c.json(result);
  });
  app.get('/app/api/shared/:id/calendar', signedIn, shared, async c => {
    const { row, policy } = c.get('share'), from = Number(c.req.query('from')), to = Number(c.req.query('to'));
    if (!Number.isFinite(from) || !Number.isFinite(to) || from <= 0 || to <= from || to - from > 8 * DAY || Math.abs(from - now()) > 366 * DAY) return error(c, 'bad_request');
    const links = await db.all("SELECT sub, email, refresh_token, scopes, status FROM google_links WHERE account_id = ? AND status <> 'unlinked' ORDER BY created_at, sub", row.owner_id);
    const fetched = [], unavailable = [];
    for (const link of links) {
      const selected = policy.calendars.filter(cal => cal.sub === link.sub);
      if (!selected.length) continue;
      if (!link.refresh_token || link.status !== 'ok' || !canRead(link.scopes)) { unavailable.push({ email: 'Shared calendars', reason: 'retry' }); continue; }
      try {
        const { accessToken } = await deps.google.refresh(await vault.open(link.sub, link.refresh_token));
        const calendars = (await deps.google.calendarList(accessToken)).filter(cal => !cal.deleted && !cal.hidden && selected.some(s => s.id === cal.id));
        if (calendars.length < selected.length) unavailable.push({ email: 'Shared calendars', reason: 'retry' });
        for (let i = 0; i < calendars.length; i += 4) {
          const group = await Promise.all(calendars.slice(i, i + 4).map(async calendar => {
            try {
              const { events } = await deps.google.listEvents(accessToken, calendar.id, { timeMin: new Date(from).toISOString(), timeMax: new Date(to).toISOString(),
                fields: 'items(id,iCalUID,originalStartTime,summary,start,end,status,location,description,htmlLink,transparency,attendees,organizer,attachments,extendedProperties,hangoutLink,conferenceData,eventType,recurrence,recurringEventId),nextPageToken,nextSyncToken' });
              return events.map(event => ({ event, calendar, sub: link.sub, email: link.email }));
            } catch { unavailable.push({ email: 'Shared calendars', reason: 'retry' }); return []; }
          }));
          fetched.push(...group.flat());
        }
      } catch (e) { unavailable.push({ email: 'Shared calendars', reason: e instanceof GoogleRefused ? 'reconnect' : 'retry' }); }
    }
    const settings = await spaceFor(row.owner_id).read('core.smartSettings', 'smart-settings');
    return c.json({ events: await sharedCalendar(fetched, policy, { secret: deps.config.tokenKey, shareID: row.id, settings }), unavailable,
      weekStartWeekday: calendarSettings(settings).weekStartWeekday });
  });
  app.get('/app/api/shared/:id/blob', signedIn, shared, async c => {
    const { row, policy } = c.get('share'), type = c.req.query('type'), id = c.req.query('id'), field = c.req.query('field');
    if (!allowedTypes(policy).has(type)) return error(c, 'not_shared', 403);
    if (!id || id.length > 200 || !field || field.length > 200) return error(c, 'bad_request');
    const ref = await spaceFor(row.owner_id).webBlob(type, id, field);
    if (!ref) return error(c, 'not_found', 404);
    const found = await deps.blobs.get(`s/${personalSpace(row.owner_id)}/${ref.$blob}`);
    if (!found) return error(c, 'not_found', 404);
    if (type === 'health.snapshot') {
      // The original combined snapshot must never be downloadable through a narrower grant. A real
      // snapshot is about a megabyte packed; anything far larger is not decoded in the Worker.
      if (Number(found.size) > MOST_SNAPSHOT_BYTES) return error(c, 'not_found', 404);
      try {
        let bytes = new Uint8Array(await new Response(found.body).arrayBuffer());
        if (new TextDecoder().decode(bytes.subarray(0, 6)) === 'LZFSE1') bytes = lzfseDecompress(bytes.subarray(6), MOST_SNAPSHOT_BYTES * 8);
        return c.json(projectHealthSnapshot(JSON.parse(new TextDecoder().decode(bytes)), policy));
      } catch { return error(c, 'not_found', 404); }
    }
    const mime = { jpg: 'image/jpeg', jpeg: 'image/jpeg', png: 'image/png', webp: 'image/webp', m4a: 'audio/mp4', wav: 'audio/wav', mp3: 'audio/mpeg' }[ref.ext] ?? 'application/octet-stream';
    return new Response(found.body, { headers: { 'content-type': mime, 'content-length': String(found.size), 'cache-control': 'no-store',
      'x-content-type-options': 'nosniff', 'content-security-policy': "default-src 'none'; sandbox" } });
  });
}
