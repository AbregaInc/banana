import { newId, newSessionToken, sha256Hex, hmacHex, constantTimeEqual } from '../crypto.js';
import { allowedTypes, feedPolicy, normalizePolicy, policyExpired } from './sharing-policy.js';
import { feedCSV } from './feed-format.js';
import { CATALOG } from '../catalog.js';
import { contentVersion } from './status.js';
import { createSigner } from '../booking/sign.js';
import { feedQuery } from './feed-query.js';

const HOUR = 3_600_000;
const parse = text => { try { return JSON.parse(text); } catch { return null; } };

/** Independent read-only credentials. All content still uses the normal guest projection. */
export function sharingFeeds(app, deps, { owner, signedIn, shared, ownerRow, body, spaceFor, webOrigin,
  recordsResponse, blobResponse, calendarResponse, checkedPolicy }) {
  const { db, now } = deps;
  const signer = createSigner(deps.config.tokenKey);
  const fail = (c, status = 404, error = 'feed_unavailable') => c.json({ error }, status);
  const published = row => row && ['invited', 'active'].includes(row.status) && row.policy
    && !policyExpired(parse(row.policy), now()) && parse(row.policy)?.allowFeeds === true;
  const urlSignature = feed => hmacHex(deps.config.tokenKey, JSON.stringify(['share-feed-url-v1', feed.id, feed.token_hash]));
  const baseURL = id => `${webOrigin}/app/feeds/${id}`;
  function issuedURLs(url) {
    const manifest = new URL(url), data = new URL(url);
    manifest.searchParams.set('view', 'manifest'); data.searchParams.set('types', 'all'); data.searchParams.set('format', 'json');
    return { url: url.href, manifestURL: manifest.href, dataURL: data.href };
  }
  const accessSummary = policy => ({ sections: Object.entries(policy.sections).filter(([, on]) => on).map(([key]) => key),
    calendars: { busy: policy.calendars.filter(c => c.access === 'busy').length, details: policy.calendars.filter(c => c.access === 'details').length } });
  const management = ownerMode => async (c, next) => {
    const row = ownerMode ? await ownerRow(c) : c.get('share')?.row;
    if (!published(row) || (!ownerMode && c.get('share')?.preview)) return fail(c, 403);
    c.set('feedOwner', ownerMode); c.set('feedShare', row); return next();
  };
  const summary = (f, who) => ({ id: f.id, name: f.name, createdAt: f.created_at,
    lastUsedAt: f.last_used_at, revokedAt: f.revoked_at, expiresOn: parse(f.policy)?.expiresOn ?? null,
    createdByYou: f.creator_sub === who.sub });
  for (const ownerMode of [true, false]) {
    const prefix = `/app/api/${ownerMode ? 'shares' : 'shared'}/:id/feeds`;
    const guards = ownerMode ? [owner, management(true)] : [signedIn, shared, management(false)];
    app.get(prefix, ...guards, async c => {
      const row = c.get('feedShare'), who = c.get('web');
      const feeds = await db.all(`SELECT * FROM web_share_feeds WHERE share_id = ?${ownerMode ? '' : ' AND creator_sub = ?'} ORDER BY created_at, id`,
        row.id, ...(ownerMode ? [] : [who.sub]));
      return c.json({ feeds: feeds.map(f => {
        const effective = f.revoked_at == null ? feedPolicy(parse(f.policy), parse(row.policy)) : null;
        return { ...summary(f, who), ...(effective ? { access: accessSummary(effective), expiresOn: effective.expiresOn ?? null } : {}) };
      }) });
    });
    app.post(prefix, ...guards, async c => {
      const input = await body(c), row = c.get('feedShare'), who = c.get('web');
      if (!input) return fail(c, 403);
      const name = typeof input?.name === 'string' ? input.name.trim() : '';
      if (!name || name.length > 100 || /[\u0000-\u001f]/.test(name)) return fail(c, 400, 'Choose a name for this connection.');
      const id = newId(deps.random), token = newSessionToken(deps.random), hash = await sha256Hex(token);
      const result = await db.run(`INSERT INTO web_share_feeds (id, share_id, creator_sub, name, token_hash, policy, issued_version, created_at)
        SELECT ?, ?, ?, ?, ?, ?, ?, ? WHERE (SELECT COUNT(*) FROM web_share_feeds WHERE share_id = ? AND revoked_at IS NULL) < 10
        AND EXISTS (SELECT 1 FROM web_shares WHERE id = ? AND published_version = ? AND policy = ? AND status IN ('invited', 'active'))`,
        id, row.id, who.sub, name, hash, row.policy, row.published_version, now(), row.id, row.id, row.published_version, row.policy);
      if (!result.changes) return fail(c, 409, 'Access changed or the connection limit was reached. Refresh or revoke an old connection.');
      const feed = await db.first('SELECT * FROM web_share_feeds WHERE id = ?', id);
      const url = new URL(baseURL(id)); url.searchParams.set('signature', await urlSignature(feed));
      // The bearer secret and signed URL are returned only on creation, never in listings.
      return c.json({ ...summary(feed, who), ...issuedURLs(url), token }, 201);
    });
    app.post(`${prefix}/:feed/revoke`, ...guards, async c => {
      if (!await body(c)) return fail(c, 403);
      const result = await db.run(`UPDATE web_share_feeds SET revoked_at = ? WHERE id = ? AND share_id = ?${ownerMode ? '' : ' AND creator_sub = ?'}`,
        now(), c.req.param('feed'), c.get('feedShare').id, ...(ownerMode ? [] : [c.get('web').sub]));
      return result.changes ? c.json({ revoked: true }) : fail(c);
    });
  }

  // A person can export their own explicitly selected data without a guest identity.
  app.get('/app/api/feeds', owner, async c => {
    const who = c.get('web');
    const feeds = await db.all('SELECT * FROM web_personal_feeds WHERE owner_id = ? ORDER BY created_at, id', who.account);
    return c.json({ feeds: feeds.map(f => ({ ...summary(f, who), policy: parse(f.policy) })) });
  });
  app.post('/app/api/feeds', owner, async c => {
    const input = await body(c), who = c.get('web');
    if (!input) return fail(c, 403);
    const name = typeof input.name === 'string' ? input.name.trim() : '';
    if (!name || name.length > 100 || /[\u0000-\u001f]/.test(name)) return fail(c, 400, 'Choose a name for this connection.');
    let policy;
    try { policy = await checkedPolicy(c, { ...input.policy, allowFeeds: true }); }
    catch (error) { return fail(c, 400, error.message); }
    const id = `p_${newId(deps.random)}`, token = newSessionToken(deps.random), hash = await sha256Hex(token);
    const result = await db.run(`INSERT INTO web_personal_feeds (id, owner_id, creator_sub, name, token_hash, policy, created_at)
      SELECT ?, ?, ?, ?, ?, ?, ? WHERE (SELECT COUNT(*) FROM web_personal_feeds WHERE owner_id = ? AND revoked_at IS NULL) < 10`,
      id, who.account, who.sub, name, hash, JSON.stringify(policy), now(), who.account);
    if (!result.changes) return fail(c, 409, 'Revoke an old connection before creating another.');
    const feed = await db.first('SELECT * FROM web_personal_feeds WHERE id = ?', id);
    const url = new URL(baseURL(id)); url.searchParams.set('signature', await urlSignature(feed));
    return c.json({ ...summary(feed, who), ...issuedURLs(url), token }, 201);
  });
  app.post('/app/api/feeds/:feed/revoke', owner, async c => {
    if (!await body(c)) return fail(c, 403);
    const result = await db.run('UPDATE web_personal_feeds SET revoked_at = ? WHERE id = ? AND owner_id = ?',
      now(), c.req.param('feed'), c.get('web').account);
    return result.changes ? c.json({ revoked: true }) : fail(c);
  });

  async function grant(id) {
    if (!/^(?:p_)?[A-Za-z0-9_-]{22}$/.test(id ?? '')) return null;
    const personal = id.length === 24;
    const table = personal ? 'web_personal_feeds' : 'web_share_feeds';
    const feed = await db.first(`SELECT * FROM ${table} WHERE id = ? AND revoked_at IS NULL`, id);
    if (!feed) return null;
    if (personal) {
      let policy;
      try { policy = normalizePolicy(parse(feed.policy)); } catch { return null; }
      if (!policy.allowFeeds || policyExpired(policy, now())) return null;
      return { feed, policy, personal: true, preview: false, table,
        row: { id: feed.id, owner_id: feed.owner_id, published_version: null } };
    }
    const row = await db.first('SELECT * FROM web_shares WHERE id = ?', feed.share_id);
    if (!published(row)) return null;
    let policy;
    try { policy = feedPolicy(normalizePolicy(parse(feed.policy)), normalizePolicy(parse(row.policy))); }
    catch { return null; }
    if (!policy || policyExpired(policy, now())) return null;
    return { feed, row, policy, preview: false, table };
  }
  async function authenticate(c, next) {
    const value = await grant(c.req.param('feed'));
    if (!value) return fail(c);
    const authorization = c.req.header('Authorization'), signature = c.req.query('signature');
    let valid = false;
    if (authorization) {
      const token = /^Bearer ([A-Za-z0-9_-]{43})$/.exec(authorization)?.[1];
      valid = Boolean(token && constantTimeEqual(await sha256Hex(token), value.feed.token_hash));
    } else if (signature) valid = constantTimeEqual(signature, await urlSignature(value.feed));
    if (!valid) { c.header('WWW-Authenticate', 'Bearer realm="Banana share feed"'); return fail(c, 401); }
    if (!await deps.limit('share', value.personal ? `personal:${value.row.owner_id}` : value.row.id)) { c.header('Retry-After', '60'); return fail(c, 429, 'rate'); }
    c.set('feed', value.feed); c.set('share', value);
    if (!authorization) c.set('feedSignature', signature);
    await db.run(`UPDATE ${value.table} SET last_used_at = ? WHERE id = ? AND revoked_at IS NULL`, now(), value.feed.id);
    return next();
  }
  const privateResponse = async (c, next) => {
    c.header('Cache-Control', 'private, no-store'); c.header('Referrer-Policy', 'no-referrer');
    c.header('X-Robots-Tag', 'noindex, nofollow'); c.header('X-Content-Type-Options', 'nosniff');
    await next();
  };
  app.use('/app/feeds/*', privateResponse);
  function endpoint(c, suffix = '', query = {}) {
    const url = new URL(baseURL(c.get('feed').id) + suffix);
    const signature = c.get('feedSignature'); if (signature) url.searchParams.set('signature', signature);
    for (const [key, value] of Object.entries(query)) if (value != null) url.searchParams.set(key, value);
    return url.href;
  }
  app.get('/app/feeds/:feed', authenticate, async c => {
    const { row, policy } = c.get('share');
    const state = await spaceFor(row.owner_id).webStatus([...allowedTypes(policy)]);
    const types = [...allowedTypes(policy)].filter(t => CATALOG.get(t)?.tier !== 'T2' || state.consents.health);
    const params = new URL(c.req.url).searchParams;
    if (params.has('view') && (params.get('view') !== 'manifest' || [...params.keys()].some(k => !['view', 'signature'].includes(k)))) return fail(c, 400, 'bad_feed_query');
    if (!params.has('view') && [...params.keys()].some(k => k !== 'signature'))
      return unifiedResponse(c, [...types, ...(policy.calendars.length ? ['calendar'] : [])]);
    return c.json({ schema: 'banana.share-feed.v1', access: accessSummary(policy), dataURL: endpoint(c, '', { types: 'all', format: 'json' }), scope: c.get('share').personal ? 'personal' : 'share', generatedAt: new Date(now()).toISOString(), expiresOn: policy.expiresOn ?? null,
      contentVersion: await contentVersion(state, types), shareVersion: row.published_version, grantVersion: c.get('feed').issued_version,
      types: types.map(type => ({ type, json: endpoint(c, '/records.json', { type }), csv: endpoint(c, '/records.csv', { type }) })),
      calendar: policy.calendars.length ? { json: endpoint(c, '/calendar.json'), csv: endpoint(c, '/calendar.csv'), requires: ['from', 'to'] } : null });
  });

  async function asset(c, type, id, field) {
    const policy = c.get('share').policy;
    const expires = Math.min(now() + HOUR, policy.expiresOn ? Date.parse(policy.expiresOn) + 24 * HOUR : Infinity), feed = c.get('feed');
    const sig = await hmacHex(deps.config.tokenKey, JSON.stringify(['share-feed-blob-v1', feed.id, type, id, field, expires]));
    const url = new URL(baseURL(feed.id) + '/blob');
    for (const [k, v] of Object.entries({ type, id, field, expires, sig })) url.searchParams.set(k, v);
    return { type, id, field, url: url.href, expiresAt: new Date(expires).toISOString() };
  }
  async function exportRecord(c, type, record) {
    const fields = { ...record.fields }, assets = [];
    for (const [field, value] of Object.entries(fields)) {
      if (!value?.$blob) continue;
      if (type === 'health.snapshot') {
        // Reuse the bounded, consent-aware, workout/trend-projected blob response.
        const response = await blobResponse(c, { type, id: record.id, field });
        if (!response.ok) throw new Error('blob_unavailable');
        fields[field] = await response.json();
      } else {
        const link = await asset(c, type, record.id, field); assets.push(link);
        fields[field] = { url: link.url, expiresAt: link.expiresAt, bytes: value.size ?? null, extension: value.ext ?? null };
      }
    }
    const data = fields.v && typeof fields.v === 'object' && !Array.isArray(fields.v) ? fields.v : fields;
    if (type === 'food.meal' && Array.isArray(data.photoIDs)) {
      for (const id of data.photoIDs) if (typeof id === 'string' && id.length <= 200) assets.push(await asset(c, 'food.mealPhoto', id, 'v'));
    }
    return { id: record.id, data, assets };
  }
  // One bounded stream across the selected datasets. Legacy URLs below remain compatible.
  async function unifiedResponse(c, available) {
    let query;
    try { query = feedQuery(c.req.url, available, now()); }
    catch (error) { return fail(c, error.status ?? 400, error.message); }
    const { types, format, limit, from, to } = query;
    const { row, policy, personal } = c.get('share'), feed = c.get('feed');
    const context = JSON.stringify({ types, format, limit, from, to, policy: await sha256Hex(JSON.stringify(policy)) });
    let index = 0, after = '', offset = 0, calendarVersion = null;
    if (query.cursor) {
      const value = await signer.unseal('share-feed-page', query.cursor, now());
      if (!value || value.feed !== feed.id || value.context !== context) return fail(c, 409, 'Feed selection or access changed. Start again from the original feed URL.');
      if (!Number.isInteger(value.index) || value.index < 0 || value.index >= types.length
        || typeof value.after !== 'string' || value.after.length > 200 || !Number.isSafeInteger(value.offset) || value.offset < 0) return fail(c, 400, 'bad_cursor');
      ({ index, after, offset, calendarVersion } = value);
    }
    const records = []; let bytes = 0, continuation = false;
    while (index < types.length && records.length < limit) {
      const type = types[index], remaining = limit - records.length;
      if (type === 'calendar') {
        const response = await calendarResponse(c, { from, to }); if (!response.ok) return response;
        const text = await response.text();
        if (new TextEncoder().encode(text).byteLength > 8 * 1024 * 1024) return fail(c, 413, 'Use a shorter calendar window.');
        const page = JSON.parse(text);
        if (page.unavailable?.length) return fail(c, 503, 'calendar_unavailable');
        const version = await sha256Hex(text);
        if (calendarVersion && calendarVersion !== version) return fail(c, 409, 'Calendar changed. Start again from the original feed URL.');
        const selected = page.events.slice(offset, offset + remaining);
        for (const event of selected) records.push({ type, id: event.id, data: event, assets: [] });
        offset += selected.length;
        if (offset < page.events.length) { calendarVersion = version; continuation = true; break; }
        offset = 0; calendarVersion = null; index++; after = '';
      } else {
        const response = await recordsResponse(c, { type, after }); if (!response.ok) return response;
        const page = await response.json(), selected = page.records.slice(0, remaining);
        try {
          for (const record of selected) {
            const exported = { type, ...await exportRecord(c, type, record) };
            bytes += new TextEncoder().encode(JSON.stringify(exported)).byteLength;
            if (bytes > 8 * 1024 * 1024) return fail(c, 413, 'Use a smaller page size.');
            records.push(exported);
          }
        } catch { return fail(c, 503, 'data_unavailable'); }
        if (page.records.length > remaining) { after = selected.at(-1).id; continuation = true; break; }
        if (page.next != null) { after = page.next; continuation = true; break; }
        index++; after = '';
      }
    }
    let next = null;
    if (continuation || index < types.length) {
      const cursor = await signer.seal('share-feed-page', { feed: feed.id, context, index, after, offset, calendarVersion }, now() + HOUR);
      next = endpoint(c, '', { types: types.join(','), format, limit, ...(types.includes('calendar') ? { from, to } : {}), cursor });
    }
    const state = await spaceFor(row.owner_id).webStatus([...allowedTypes(policy)]);
    const result = { schema: 'banana.feed.v2', scope: personal ? 'personal' : 'share', access: accessSummary(policy),
      generatedAt: new Date(now()).toISOString(), expiresOn: policy.expiresOn ?? null,
      contentVersion: await contentVersion(state, available.filter(t => t !== 'calendar')), types,
      ...(types.includes('calendar') ? { calendarWindow: { from, to } } : {}), records, next };
    const text = JSON.stringify(result);
    if (new TextEncoder().encode(text).byteLength > 8 * 1024 * 1024) return fail(c, 413, 'Use a smaller page size.');
    if (next) c.header('Link', `<${next}>; rel="next"`);
    if (format === 'json') return c.json(result);
    try { return c.body(feedCSV(records, { typed: true }), 200, { 'Content-Type': 'text/csv; charset=utf-8', 'Content-Disposition': 'attachment; filename="banana-feed.csv"' }); }
    catch { return fail(c, 413, 'Use JSON for this record structure.'); }
  }

  for (const format of ['json', 'csv']) {
    app.get(`/app/feeds/:feed/records.${format}`, authenticate, async c => {
      const rawLimit = c.req.query('limit') ?? '25', limit = Number(rawLimit);
      if (!/^\d+$/.test(rawLimit) || limit < 1 || limit > 100) return fail(c, 400, 'bad_limit');
      const response = await recordsResponse(c);
      if (!response.ok) return response;
      const page = await response.json(), type = c.req.query('type');
      const selected = page.records.slice(0, limit);
      const next = page.records.length > limit ? selected.at(-1).id : page.next;
      const records = []; let bytes = 0;
      try {
        // Decode one bounded blob at a time, stopping before a page can retain many snapshots.
        for (const raw of selected) {
          const record = await exportRecord(c, type, raw);
          bytes += new TextEncoder().encode(JSON.stringify(record)).byteLength;
          if (bytes > 8 * 1024 * 1024) return fail(c, 413, 'Use a smaller page size.');
          records.push(record);
        }
      }
      catch { return fail(c, 503, 'data_unavailable'); }
      const result = { schema: 'banana.share-feed.v1', type, generatedAt: new Date(now()).toISOString(), records,
        next: next == null ? null : endpoint(c, `/records.${format}`, { type, limit, after: next }) };
      const text = JSON.stringify(result);
      if (new TextEncoder().encode(text).byteLength > 8 * 1024 * 1024) return fail(c, 413, 'Use a smaller page size.');
      if (format === 'json') return c.json(result);
      if (result.next) c.header('Link', `<${result.next}>; rel="next"`);
      try { return c.body(feedCSV(records), 200, { 'Content-Type': 'text/csv; charset=utf-8', 'Content-Disposition': 'attachment; filename="banana-feed.csv"' }); }
      catch { return fail(c, 413, 'Use JSON for this record structure.'); }
    });
    app.get(`/app/feeds/:feed/calendar.${format}`, authenticate, async c => {
      const response = await calendarResponse(c); if (!response.ok || format === 'json') return response;
      const result = await response.json();
      if (result.unavailable?.length) return fail(c, 503, 'calendar_unavailable');
      try { return c.body(feedCSV(result.events.map(e => ({ id: e.id, data: e, assets: [] }))), 200, { 'Content-Type': 'text/csv; charset=utf-8' }); }
      catch { return fail(c, 413, 'Use JSON for this record structure.'); }
    });
  }
  app.get('/app/feeds/:feed/blob', async c => {
    const value = await grant(c.req.param('feed'));
    if (!value) return fail(c);
    const type = c.req.query('type'), id = c.req.query('id'), field = c.req.query('field');
    const expires = Number(c.req.query('expires')), sig = c.req.query('sig');
    if (!Number.isSafeInteger(expires) || expires <= now() || expires > now() + HOUR
      || !allowedTypes(value.policy).has(type) || !id || id.length > 200 || !field || field.length > 200) return fail(c);
    const expected = await hmacHex(deps.config.tokenKey, JSON.stringify(['share-feed-blob-v1', value.feed.id, type, id, field, expires]));
    if (!constantTimeEqual(sig, expected)) return fail(c, 401);
    if (!await deps.limit('share', value.personal ? `personal:${value.row.owner_id}` : value.row.id)) { c.header('Retry-After', '60'); return fail(c, 429, 'rate'); }
    c.set('share', value);
    return blobResponse(c);
  });
}
