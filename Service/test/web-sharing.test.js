import test from 'node:test';
import assert from 'node:assert/strict';
import { setup, device, DAY } from './helpers.js';
import { emptyPolicy, sharedCalendar } from '../src/web/sharing-policy.js';
import { sha256Hex } from '../src/crypto.js';
import { memoryEmail } from '../src/booking/email.js';
import { feedCSV } from '../src/web/feed-format.js';

async function fixture() {
  const email = memoryEmail({ enabled: true, log: false });
  const s = setup({ deps: { email } });
  s.email = email;
  s.google.person('owner', 'owner-sub', 'owner@example.com', 'owner-refresh', { name: 'Alex' });
  const owner = (await s.signIn('owner', device('phone-owner-0001'))).json;
  s.google.person('trainer', 'trainer-sub', 'trainer@example.com', null, { name: 'Trainer' });
  s.google.person('stranger', 'stranger-sub', 'stranger@example.com', null);
  const calendars = [1, 2, 3, 4].map(i => ({ id: `calendar-${i}`, summary: i === 4 ? 'PRIVATE CALENDAR NAME' : `Calendar ${i}`, accessRole: 'owner' }));
  s.google.calendars.set('owner-refresh', calendars);
  const space = s.deps.spaces.get(`sp_${owner.account.id}`);
  await space.setConsent('health', { version: '1', at: s.now() });
  async function login(code, share) {
    const start = await s.app.request(`/app/auth/google${share ? `?share=${share}` : ''}`);
    const state = new URL(start.headers.get('location')).searchParams.get('state');
    const nonce = start.headers.get('set-cookie').split(';')[0];
    const end = await s.app.request(`/v1/google/callback?${new URLSearchParams({ state, code })}`, { headers: { cookie: nonce } });
    return { end, cookie: end.headers.getSetCookie().find(c => c.startsWith('__Host-banana-web='))?.split(';')[0] };
  }
  const ownerCookie = (await login('owner')).cookie;
  const call = (method, path, input, cookie = ownerCookie, origin = 'https://service.test') => s.app.request(path, {
    method, headers: { cookie: cookie ?? '', Origin: origin, 'Content-Type': 'application/json' },
    ...(input != null ? { body: JSON.stringify(input) } : {}),
  });
  async function put(type, id, fields) {
    return s.call('POST', '/v2/sync', { session: owner.session, body: { device: 'phone-owner-0001', changes: [
      { type, id, set: fields, clocks: Object.fromEntries(Object.keys(fields).map(k => [k, `${s.now()}.0000.phone`])) },
    ] } });
  }
  async function draft(policy, email = 'trainer@example.com') {
    const response = await call('POST', '/app/api/shares', { email, policy });
    assert.equal(response.status, 201, await response.clone().text());
    return response.json();
  }
  async function preview(d) {
    const response = await call('POST', `/app/api/shares/${d.id}/preview`, { version: d.version });
    assert.equal(response.status, 200); return response.json();
  }
  async function send(d) {
    await preview(d);
    const response = await call('POST', `/app/api/shares/${d.id}/send`, { version: d.version });
    assert.equal(response.status, 200, await response.clone().text());
    return response.json();
  }
  async function blob(type, bytes, ext = 'json') {
    const data = new TextEncoder().encode(typeof bytes === 'string' ? bytes : JSON.stringify(bytes));
    const sha = await sha256Hex(new TextDecoder().decode(data));
    await s.deps.blobs.put(`s/sp_${owner.account.id}/${sha}`, new Blob([data]).stream(), { sha256: sha });
    await space.recordBlob(sha, data.length, s.now(), type);
    return { $blob: sha, size: data.length, ext };
  }
  return { s, owner, ownerCookie, space, login, call, put, draft, preview, send, blob };
}
const policy = (...sections) => { const p = emptyPolicy(); for (const section of sections) p.sections[section] = true; return p; };
const view = (id, endpoint, preview) => `/app/api/shared/${id}/${endpoint}${endpoint.includes('?') ? '&' : '?'}${preview ? `preview=${preview}` : ''}`;

test('feeds: opt-in is published, owner or the actual guest issues a separate read-only credential', async () => {
  const f = await fixture(), p = policy('nutrition'), d = await f.draft(p);
  await f.send(d);
  assert.equal((await f.call('POST', `/app/api/shares/${d.id}/feeds`, { name: 'Coach system' })).status, 403);
  p.allowFeeds = true;
  const edited = await (await f.call('PUT', `/app/api/shares/${d.id}/draft`, { email: d.email, version: d.version, policy: p })).json();
  await f.preview(edited);
  assert.equal((await f.call('POST', `/app/api/shares/${d.id}/feeds`, { name: 'Coach system' })).status, 403, 'draft opt-in grants nothing');
  assert.equal((await f.call('POST', `/app/api/shares/${d.id}/publish`, { version: edited.version })).status, 200);
  const guest = await f.login('trainer', d.id), stranger = await f.login('stranger');
  const path = `/app/api/shared/${d.id}/feeds`;
  assert.equal((await f.call('POST', path, { name: 'Other system' }, stranger.cookie)).status, 403);
  assert.equal((await f.call('POST', path, { name: 'Wrong origin' }, guest.cookie, 'https://other.example')).status, 403);
  const response = await f.call('POST', path, { name: 'Coach system' }, guest.cookie);
  assert.equal(response.status, 201, await response.clone().text());
  const feed = await response.json();
  assert.equal(feed.token.length, 43);
  const stored = await f.s.deps.db.first('SELECT token_hash FROM web_share_feeds WHERE id = ?', feed.id);
  assert.equal(stored.token_hash, await sha256Hex(feed.token));
  const listed = await (await f.call('GET', path, null, guest.cookie)).json();
  assert.equal(listed.feeds.length, 1); assert.equal(JSON.stringify(listed).includes(feed.token), false);
  assert.equal(JSON.stringify(listed).includes(new URL(feed.url).searchParams.get('signature')), false);
  const manifest = await f.s.app.request(feed.url);
  assert.equal(manifest.status, 200); assert.match(manifest.headers.get('cache-control'), /no-store/);
  const metadata = await manifest.json();
  assert.equal(metadata.types.some(t => t.type === 'food.meal'), true);
  assert.equal(metadata.types.some(t => t.type === 'food.dose'), false);
  assert.equal((await f.s.app.request(feed.url + 'tamper')).status, 401);
  const bearer = await f.s.app.request(`/app/feeds/${feed.id}`, { headers: { Authorization: `Bearer ${feed.token}` } });
  assert.equal(bearer.status, 200);
  assert.equal((await f.s.call('GET', '/v1/account', { session: feed.token })).status, 401, 'feed credentials are not native sessions');
});

test('feeds: JSON and CSV paginate, and food photos use signed scoped expiring paths', async () => {
  const f = await fixture(), p = policy('nutrition'); p.allowFeeds = true;
  const d = await f.draft(p); await f.send(d);
  const photo = await f.blob('food.mealPhoto', 'sample image', 'jpg');
  await f.put('food.mealPhoto', 'photo-1', { v: photo });
  for (const id of ['meal-a', 'meal-b', 'meal-c']) await f.put('food.meal', id, { name: '=not a formula', protein: 24, photoIDs: ['photo-1'] });
  const feed = await (await f.call('POST', `/app/api/shares/${d.id}/feeds`, { name: 'Analysis' })).json();
  const manifest = await (await f.s.app.request(feed.url)).json();
  const urls = manifest.types.find(t => t.type === 'food.meal');
  const firstURL = new URL(urls.json); firstURL.searchParams.set('limit', '1');
  const first = await (await f.s.app.request(firstURL)).json();
  assert.equal(first.records.length, 1); assert.equal(first.records[0].data.protein, 24);
  const second = await (await f.s.app.request(first.next)).json();
  assert.notEqual(second.records[0].id, first.records[0].id);
  const image = first.records[0].assets[0];
  assert.equal((await f.s.app.request(image.url)).status, 200);
  const imageURL = new URL(image.url); imageURL.searchParams.set('id', 'other-photo');
  assert.equal((await f.s.app.request(imageURL)).status, 401);
  const csv = await f.s.app.request(urls.csv);
  assert.match(csv.headers.get('content-type'), /text\/csv/);
  assert.match(await csv.text(), /'=not a formula/);
  const denied = new URL(urls.json); denied.searchParams.set('type', 'food.dose');
  assert.equal((await f.s.app.request(denied)).status, 403);
  await f.call('POST', `/app/api/shares/${d.id}/feeds/${feed.id}/revoke`, {});
  assert.equal((await f.s.app.request(firstURL)).status, 404);
  assert.equal((await f.s.app.request(image.url)).status, 404, 'image revocation is immediate too');
});

test('feeds: old credentials never inherit broader sharing and disabling permanently revokes them', async () => {
  const f = await fixture(), p = policy('nutrition'); p.allowFeeds = true;
  const d = await f.draft(p); await f.send(d);
  const feed = await (await f.call('POST', `/app/api/shares/${d.id}/feeds`, { name: 'Food connection' })).json();
  async function publish(value, version) {
    const edited = await (await f.call('PUT', `/app/api/shares/${d.id}/draft`, { email: d.email, version, policy: value })).json();
    await f.preview(edited);
    const response = await f.call('POST', `/app/api/shares/${d.id}/publish`, { version: edited.version });
    assert.equal(response.status, 200); return edited.version;
  }
  p.sections.taken = true;
  let version = await publish(p, d.version);
  const manifest = await (await f.s.app.request(feed.url)).json();
  assert.equal(manifest.types.some(t => t.type === 'food.dose'), false);
  const listed = await (await f.call('GET', `/app/api/shares/${d.id}/feeds`)).json();
  assert.deepEqual(listed.feeds[0].access.sections, ['nutrition']);
  p.allowFeeds = false; version = await publish(p, version);
  assert.equal((await f.s.app.request(feed.url)).status, 404);
  p.allowFeeds = true; await publish(p, version);
  assert.equal((await f.s.app.request(feed.url)).status, 404, 're-enabling must not resurrect an old key');
});

test('feed CSV preserves quoting and neutralizes formulas without changing negative numbers', () => {
  const text = feedCSV([{ id: 'a', data: { title: 'comma, "quote"\nline', value: -2, formula: ' \t=1+1' }, assets: [] }]);
  assert.match(text, /comma, ""quote""\nline/); assert.match(text, /"-2"/); assert.match(text, /' \t=1\+1/);
  assert.throws(() => feedCSV([{ id: 'a', data: { 'x.y': 1, x: { y: 2 } } }]), /collision/);
});

test('sharing: a draft sends nothing; only its owner can preview, and sending requires the current preview', async () => {
  const f = await fixture(), d = await f.draft(policy('nutrition'));
  assert.equal(f.s.email.sent.length, 0);
  assert.equal((await f.call('POST', `/app/api/shares/${d.id}/send`, { version: d.version })).status, 409);
  assert.equal((await f.login('trainer', d.id)).cookie, undefined, 'a draft does not register or admit a guest');
  await f.preview(d);
  const preview = await f.call('GET', view(d.id, 'account', d.version));
  assert.equal(preview.status, 200);
  const metadata = await preview.json();
  assert.deepEqual(metadata.views, ['overview', 'nutrition']); assert.equal(metadata.preview, true);
  assert.equal(metadata.allowedTypes.includes('food.dose'), false);
  const changed = await f.call('PUT', `/app/api/shares/${d.id}/draft`, { email: d.email, version: d.version, policy: policy('workouts') });
  const next = await changed.json(); assert.equal(next.version, 2);
  assert.equal((await f.call('GET', view(d.id, 'account', d.version))).status, 403);
  assert.equal((await f.call('POST', `/app/api/shares/${d.id}/send`, { version: next.version })).status, 409);
});

test('sharing: Google-only guests receive read-only web access, never native sync membership or owner APIs', async () => {
  const f = await fixture(), d = await f.draft(policy('nutrition'));
  await f.put('food.meal', 'meal-one', { name: 'Shared meal', items: [] });
  await f.put('food.supplement', 'taken-secret', { name: 'PRIVATE TAKEN NAME' });
  await f.send(d);
  assert.equal(f.s.email.sent.length, 1); assert.equal(f.s.email.sent[0].to, 'trainer@example.com');
  const guest = await f.login('trainer', d.id);
  assert.equal(guest.end.headers.get('location'), `https://service.test/share/${d.id}`);
  const metadata = await (await f.call('GET', view(d.id, 'account'), null, guest.cookie)).json();
  assert.equal(metadata.shared, true); assert.equal(metadata.preview, false);
  assert.equal(JSON.stringify(metadata).includes('food.supplement'), false);
  const records = await (await f.call('GET', view(d.id, 'records?type=food.meal'), null, guest.cookie)).json();
  assert.equal(records.records[0].fields.name, 'Shared meal');
  for (const endpoint of ['records?type=food.supplement', 'records?type=food.dose', 'blob?type=food.supplement&id=taken-secret&field=v'])
    assert.equal((await f.call('GET', view(d.id, endpoint), null, guest.cookie)).status, 403);
  for (const path of ['/app/api/records?type=food.meal', '/app/api/calendars', '/app/api/shares'])
    assert.equal((await f.call('GET', path, null, guest.cookie)).status, 403);
  const raw = guest.cookie.split('=')[1];
  assert.equal((await f.s.call('POST', '/v2/sync', { session: raw, body: { device: 'phone-owner-0001', changes: [] } })).status, 401);
  assert.equal((await f.s.call('GET', '/v1/account', { session: raw })).status, 401);
  assert.equal((await f.s.db.first("SELECT COUNT(*) AS n FROM space_members WHERE role <> 'owner'")).n, 0);
  assert.equal((await f.call('GET', '/app/api/session', null, guest.cookie)).status, 200);
  assert.equal((await f.call('POST', '/app/auth/logout', {}, guest.cookie)).status, 204);
});

test('sharing: the link alone grants nothing, and an accepted invitation is bound to the verified Google subject', async () => {
  const f = await fixture(), d = await f.draft(policy('nutrition'));
  await f.send(d);
  assert.equal((await f.call('GET', view(d.id, 'account'), null, '')).status, 401);
  assert.equal((await f.login('stranger', d.id)).cookie, undefined);
  const trainer = await f.login('trainer', d.id);
  assert.equal((await f.call('GET', view(d.id, 'account'), null, trainer.cookie)).status, 200);
  f.s.google.person('recycled', 'different-google-subject', 'trainer@example.com', null);
  assert.equal((await f.login('recycled', d.id)).cookie, undefined);
  assert.equal((await f.call('GET', view(d.id, 'account', d.version), null, trainer.cookie)).status, 403, 'a guest cannot request the owner preview');
});

test('sharing: three full calendars and busy-only others use the same projection for preview and guest', async () => {
  const f = await fixture(), p = policy('workouts', 'health', 'nutrition');
  p.calendars = [1, 2, 3, 4].map(i => ({ sub: 'owner-sub', id: `calendar-${i}`, access: i === 4 ? 'busy' : 'details' }));
  const start = new Date(f.s.now()).toISOString(), end = new Date(f.s.now() + 3_600_000).toISOString();
  for (const i of [1, 2, 3]) f.s.google.events.set(`calendar-${i}`, [{ id: `public-${i}`, summary: `Shared event ${i}`, description: `Shared details ${i}`,
    start: { dateTime: new Date(f.s.now() + i * 3_600_000).toISOString() }, end: { dateTime: new Date(f.s.now() + (i + 1) * 3_600_000).toISOString() } }]);
  f.s.google.events.set('calendar-4', [{ id: 'PRIVATE EVENT ID', summary: 'PRIVATE TITLE', description: 'PRIVATE NOTES', location: 'PRIVATE LOCATION',
    hangoutLink: 'https://PRIVATE-CALL.test', attendees: [{ email: 'PRIVATE-PERSON@example.com' }], start: { dateTime: start }, end: { dateTime: end } }]);
  const d = await f.draft(p); await f.preview(d);
  const endpoint = `calendar?from=${f.s.now()}&to=${f.s.now() + DAY}`;
  const preview = await (await f.call('GET', view(d.id, endpoint, d.version))).json();
  assert.equal(preview.events.length, 4);
  for (const request of f.s.google.listCalls) {
    for (const field of ['iCalUID', 'originalStartTime'])
      assert.match(request.fields, new RegExp(`\\b${field}\\b`), `guest and preview reads need ${field}`);
  }
  assert.match(JSON.stringify(preview), /Shared details 3/);
  assert.doesNotMatch(JSON.stringify(preview), /PRIVATE|calendar-4|owner-sub/);
  const busy = preview.events.find(e => e.busyOnly); assert.equal(busy.title, 'Busy'); assert.equal(busy.start.dateTime, start);
  await f.send(d);
  const trainer = await f.login('trainer', d.id);
  const actual = await (await f.call('GET', view(d.id, endpoint), null, trainer.cookie)).json();
  assert.deepEqual(actual, preview);
});

test('sharing: a combined Health blob is projected before download, including hidden and future private fields', async () => {
  const f = await fixture(); await f.space.setConsent('health', { version: '1', at: f.s.now() });
  const ref = await f.blob('health.snapshot', { workouts: [{ id: 'visible', activity: 'Run' }, { id: 'hidden', activity: 'PRIVATE HIDDEN WORKOUT' }],
    hiddenWorkoutIDs: ['hidden'], trends: { PRIVATE_HEALTH_METRIC: 42 }, futurePrivateField: 'PRIVATE FUTURE' });
  await f.put('health.snapshot', 'health', { v: ref });
  const d = await f.draft(policy('workouts')); await f.send(d);
  const trainer = await f.login('trainer', d.id);
  const response = await f.call('GET', view(d.id, 'blob?type=health.snapshot&id=health&field=v'), null, trainer.cookie);
  assert.equal(response.status, 200);
  const content = await response.text(); assert.match(content, /Run/); assert.doesNotMatch(content, /PRIVATE/);
  await f.space.withdrawConsent('health');
  assert.equal((await f.call('GET', view(d.id, 'blob?type=health.snapshot&id=health&field=v'), null, trainer.cookie)).status, 404);
});

test('sharing: draft edits cannot expand live access; publishing requires preview, and revocation takes effect on every read', async () => {
  const f = await fixture(), d = await f.draft(policy('nutrition')); await f.send(d);
  const guest = await f.login('trainer', d.id);
  const changed = await (await f.call('PUT', `/app/api/shares/${d.id}/draft`, { email: d.email, version: d.version, policy: policy('nutrition', 'taken') })).json();
  assert.equal((await f.call('GET', view(d.id, 'records?type=food.dose'), null, guest.cookie)).status, 403);
  assert.equal((await f.call('POST', `/app/api/shares/${d.id}/publish`, { version: changed.version })).status, 409);
  await f.preview(changed);
  assert.equal((await f.call('POST', `/app/api/shares/${d.id}/publish`, { version: changed.version })).status, 200);
  assert.equal((await f.call('GET', view(d.id, 'records?type=food.dose'), null, guest.cookie)).status, 200);
  assert.equal((await f.call('POST', `/app/api/shares/${d.id}/revoke`, {})).status, 200);
  for (const endpoint of ['account', 'records?type=food.meal', 'calendar?from=1&to=2', 'blob?type=food.mealPhoto&id=photo&field=v'])
    assert.equal((await f.call('GET', view(d.id, endpoint), null, guest.cookie)).status, 403);
});

test('sharing: origin, permission shape and calendar ownership are checked before saving or emailing', async () => {
  const f = await fixture();
  assert.equal((await f.call('POST', '/app/api/shares', { email: 'trainer@example.com', policy: policy('nutrition') }, f.ownerCookie, 'https://attacker.test')).status, 403);
  for (const p of [{ ...policy('nutrition'), secretAccess: true }, { calendars: [], sections: { taken: 'false' } },
    { ...policy('nutrition'), calendars: [{ sub: 'somebody-else', id: 'private-calendar', access: 'details' }] }])
    assert.equal((await f.call('POST', '/app/api/shares', { email: 'trainer@example.com', policy: p })).status, 400);
  assert.equal(f.s.email.sent.length, 0);
});

test('sharing: Health-only and inline snapshots cannot expose workouts or unknown fields', async () => {
  const f = await fixture();
  await f.put('health.snapshot', 'health', { v: { workouts: [{ id: 'PRIVATE-WORKOUT' }], trends: { steps: { today: 123 } }, future: 'PRIVATE' } });
  const d = await f.draft(policy('health')); await f.send(d);
  const guest = await f.login('trainer', d.id);
  const result = await (await f.call('GET', view(d.id, 'records?type=health.snapshot'), null, guest.cookie)).json();
  assert.match(JSON.stringify(result), /123/); assert.doesNotMatch(JSON.stringify(result), /PRIVATE/);
  assert.equal((await f.call('GET', view(d.id, 'records?type=health.workout'), null, guest.cookie)).status, 403);
});

test('sharing: failed delivery is recorded and resend is throttled without losing approved scope', async () => {
  const f = await fixture(), d = await f.draft(policy('nutrition'));
  f.s.deps.email.send = async () => { throw new Error('provider unavailable'); };
  await f.preview(d);
  const failed = await f.call('POST', `/app/api/shares/${d.id}/send`, { version: d.version });
  assert.equal(failed.status, 502); assert.equal((await failed.json()).share.sendStatus, 'failed');
  assert.equal((await f.call('POST', `/app/api/shares/${d.id}/send`, { version: d.version })).status, 429);
  const saved = await (await f.call('GET', '/app/api/shares')).json();
  assert.equal(saved.shares[0].policy.sections.nutrition, true);
});


test('a guest sees the owner’s personal Busy mirror even with routines shared and the work calendar off',async()=>{
  const policy=emptyPolicy();policy.sections.personalPlan=true;
  policy.calendars=[{sub:'owner-sub',id:'personal',access:'details'}];
  const event={id:'mirror',summary:'Busy',start:{dateTime:'2026-10-21T12:00:00Z'},end:{dateTime:'2026-10-21T13:00:00Z'},
    location:'PRIVATE WORK LOCATION',description:'PRIVATE WORK NOTES',extendedProperties:{private:{bananaVariant:'banana',bananaItemID:'work-copy'}}};
  const rows=await sharedCalendar([{event,calendar:{id:'personal',accessRole:'owner'},email:'owner@example.com',sub:'owner-sub'}],policy,{secret:'test-secret',shareID:'test-share',settings:null});
  assert.equal(rows.length,1);assert.equal(rows[0].title,'Busy');
  assert.equal(rows[0].location,'');assert.equal(rows[0].description,'');
});

test('a share is read so many times a minute, and a Health snapshot far larger than a snapshot is not decoded in the Worker (audit run-1)', async () => {
  const f = await fixture();
  const big = new Uint8Array(9 * 1024 * 1024);
  const sha = await sha256Hex(new TextDecoder().decode(big));
  await f.s.deps.blobs.put(`s/sp_${f.owner.account.id}/${sha}`, new Blob([big]).stream(), { sha256: sha });
  await f.space.recordBlob(sha, big.length, f.s.now(), 'health.snapshot');
  await f.put('health.snapshot', 'health', { v: { $blob: sha, size: big.length, ext: 'json' } });
  const d = await f.draft(policy('workouts'));
  await f.preview(d);
  assert.equal((await f.call('GET', view(d.id, 'blob?type=health.snapshot&id=health&field=v', d.version))).status, 404);
  let status;
  for (let i = 0; i < 60; i++) status = (await f.call('GET', view(d.id, 'account', d.version))).status;
  assert.equal(status, 429);
});

test('sharing status excludes unshared record changes and enforces revocation',async()=>{
  const f=await fixture(),d=await f.draft(policy('nutrition'));await f.send(d);
  const guest=await f.login('trainer',d.id);
  const read=async()=>{const r=await f.call('GET',view(d.id,'status'),null,guest.cookie);assert.equal(r.status,200);return r.json();};
  const original=await read();
  assert.match(original.contentVersion,/^[0-9a-f]{64}$/);
  await f.put('food.supplement','private-one',{name:'Example private supplement'});
  assert.equal((await read()).contentVersion,original.contentVersion);
  await f.put('food.meal','meal-one',{name:'Lunch',items:[]});
  const updated=await read();assert.notEqual(updated.contentVersion,original.contentVersion);
  f.s.advance(1000);await f.put('food.meal','meal-one',{name:'Lunch',items:[]});
  assert.equal((await read()).contentVersion,updated.contentVersion);
  const metadata=await(await f.call('GET',view(d.id,'account'),null,guest.cookie)).json();
  assert.equal(metadata.contentVersion,updated.contentVersion);
  assert.equal((await f.call('POST','/app/api/shares/'+d.id+'/revoke',{})).status,200);
  assert.equal((await f.call('GET',view(d.id,'status'),null,guest.cookie)).status,403);
});

test('sharing: expiration includes the UTC date, blocks guest endpoints and can be extended', async () => {
  const f = await fixture(), expiresOn = new Date(f.s.now()).toISOString().slice(0, 10);
  const d = await f.draft({ ...policy('nutrition'), expiresOn }); await f.send(d);
  const guest = await f.login('trainer', d.id);
  assert.equal((await f.call('GET', view(d.id, 'account'), null, guest.cookie)).status, 200);
  f.s.advance(Date.parse(expiresOn) + DAY - f.s.now() - 1);
  assert.equal((await f.call('GET', view(d.id, 'status'), null, guest.cookie)).status, 200);
  f.s.advance(1);
  for (const endpoint of ['account', 'status', 'records?type=food.meal', 'blob?type=food.meal&id=x&field=photo', 'calendar'])
    assert.equal((await f.call('GET', view(d.id, endpoint), null, guest.cookie)).status, 403, endpoint);
  assert.equal((await (await f.call('GET', '/app/api/session', null, guest.cookie)).json()).shares.length, 0);
  const updated = await (await f.call('PUT', `/app/api/shares/${d.id}/draft`, { email: d.email, version: d.version, policy: policy('nutrition') })).json();
  await f.preview(updated);
  assert.equal((await f.call('POST', `/app/api/shares/${d.id}/publish`, { version: updated.version })).status, 200);
  assert.equal((await f.call('GET', view(d.id, 'account'), null, guest.cookie)).status, 200);
});

test('sharing: invalid or elapsed expiration cannot be saved or published', async () => {
  const f = await fixture();
  for (const expiresOn of ['2026-02-30', 'not-a-date', '2020-01-01', 123])
    assert.equal((await f.call('POST', '/app/api/shares', { email: 'trainer@example.com', policy: { ...policy('nutrition'), expiresOn } })).status, 400);
  const expiresOn = new Date(f.s.now()).toISOString().slice(0, 10);
  const d = await f.draft({ ...policy('nutrition'), expiresOn });
  f.s.advance(Date.parse(expiresOn) + DAY - f.s.now()); await f.preview(d);
  assert.equal((await f.call('POST', `/app/api/shares/${d.id}/send`, { version: d.version })).status, 409);
  assert.equal(f.s.email.sent.length, 0);
});

test('sharing: list preview shows published access, not unpublished edits, and remains owner-only', async () => {
  const f = await fixture(), d = await f.draft(policy('nutrition')); await f.send(d);
  const guest = await f.login('trainer', d.id);
  const changed = await (await f.call('PUT', `/app/api/shares/${d.id}/draft`, { email: d.email, version: d.version, policy: policy('health') })).json();
  const result = await f.call('GET', view(d.id, 'account', 'published')); assert.equal(result.status, 200);
  const account = await result.json(); assert.deepEqual(account.views, ['overview', 'nutrition']);
  assert.equal(account.publishedPreview, true); assert.equal(account.shareVersion, d.version);
  assert.equal((await f.call('GET', view(d.id, 'account', 'published'), null, guest.cookie)).status, 403);
  assert.equal((await f.call('POST', `/app/api/shares/${d.id}/publish`, { version: changed.version })).status, 409);
  await f.call('POST', `/app/api/shares/${d.id}/revoke`, {});
  assert.equal((await f.call('GET', view(d.id, 'account', 'published'))).status, 403);
});


test('feeds: Health projection, withdrawn consent and parent revocation apply to every request', async () => {
  const f = await fixture(), p = policy('workouts'); p.allowFeeds = true;
  const ref = await f.blob('health.snapshot', { workouts: [{ id: 'visible', activity: 'Run' }, { id: 'hidden', activity: 'PRIVATE' }], hiddenWorkoutIDs: ['hidden'], trends: { PRIVATE: 42 } });
  await f.put('health.snapshot', 'snapshot', { v: ref });
  const d = await f.draft(p); await f.send(d);
  const feed = await (await f.call('POST', `/app/api/shares/${d.id}/feeds`, { name: 'Training' })).json();
  const metadata = await (await f.s.app.request(feed.url)).json();
  const endpoint = metadata.types.find(t => t.type === 'health.snapshot').json;
  const response = await f.s.app.request(endpoint); assert.equal(response.status, 200);
  const text = await response.text(); assert.match(text, /Run/); assert.doesNotMatch(text, /PRIVATE|\$blob/);
  await f.space.withdrawConsent('health');
  const withdrawn = await f.s.app.request(endpoint); assert.equal(withdrawn.status, 200);
  assert.deepEqual((await withdrawn.json()).records, []);
  assert.equal((await (await f.s.app.request(feed.url)).json()).types.some(t => t.type.startsWith('health.')), false);
  await f.call('POST', `/app/api/shares/${d.id}/revoke`, {});
  assert.equal((await f.s.app.request(feed.url)).status, 404);
});

test('feeds: guests manage only their connections, and expired parent and image grants stop working', async () => {
  const f = await fixture(), p = policy('nutrition'); p.allowFeeds = true;
  p.expiresOn = new Date(f.s.now()).toISOString().slice(0, 10);
  const d = await f.draft(p); await f.send(d);
  const guest = await f.login('trainer', d.id), ownerPath = `/app/api/shares/${d.id}/feeds`, guestPath = `/app/api/shared/${d.id}/feeds`;
  const ownerFeed = await (await f.call('POST', ownerPath, { name: 'Owner analysis' })).json();
  assert.equal((await (await f.call('GET', guestPath, null, guest.cookie)).json()).feeds.length, 0);
  assert.equal((await f.call('POST', `${guestPath}/${ownerFeed.id}/revoke`, {}, guest.cookie)).status, 404);
  const guestFeed = await (await f.call('POST', guestPath, { name: 'Coach analysis' }, guest.cookie)).json();
  assert.equal((await (await f.call('GET', ownerPath)).json()).feeds.length, 2);
  await f.put('food.mealPhoto', 'photo', { v: await f.blob('food.mealPhoto', 'image', 'jpg') });
  const metadata = await (await f.s.app.request(guestFeed.url)).json();
  const url = metadata.types.find(t => t.type === 'food.mealPhoto').json;
  const readAsset = async () => (await (await f.s.app.request(url)).json()).records[0].assets[0];
  const image = await readAsset(); f.s.advance(3_600_001);
  assert.equal((await f.s.app.request(image.url)).status, 404);
  f.s.advance(Date.parse(p.expiresOn) + DAY - f.s.now() - 1000);
  const last = await readAsset(); assert.equal(Date.parse(last.expiresAt), Date.parse(p.expiresOn) + DAY);
  f.s.advance(1000);
  assert.equal((await f.s.app.request(guestFeed.url)).status, 404);
  assert.equal((await f.s.app.request(last.url)).status, 404);
});

test('feeds: calendar busy projection is preserved in JSON and CSV, and scope narrowing is immediate', async () => {
  const f = await fixture(), p = policy('nutrition'); p.allowFeeds = true;
  p.calendars = [{ sub: 'owner-sub', id: 'calendar-1', access: 'busy' }];
  f.s.google.events.set('calendar-1', [{ id: 'PRIVATE-ID', summary: 'PRIVATE-TITLE', description: 'PRIVATE-NOTES', start: { dateTime: new Date(f.s.now()).toISOString() }, end: { dateTime: new Date(f.s.now() + 3600000).toISOString() } }]);
  const d = await f.draft(p); await f.send(d);
  const feed = await (await f.call('POST', `/app/api/shares/${d.id}/feeds`, { name: 'Schedule' })).json();
  const metadata = await (await f.s.app.request(feed.url)).json();
  for (const format of ['json', 'csv']) {
    const url = new URL(metadata.calendar[format]); url.searchParams.set('from', f.s.now()); url.searchParams.set('to', f.s.now() + DAY);
    const response = await f.s.app.request(url); assert.equal(response.status, 200);
    const text = await response.text(); assert.match(text, /Busy/); assert.doesNotMatch(text, /PRIVATE/);
  }
  const mealURL = metadata.types.find(t => t.type === 'food.meal').json;
  p.sections.nutrition = false;
  const edited = await (await f.call('PUT', `/app/api/shares/${d.id}/draft`, { email: d.email, version: d.version, policy: p })).json();
  await f.preview(edited); await f.call('POST', `/app/api/shares/${d.id}/publish`, { version: edited.version });
  assert.equal((await f.s.app.request(mealURL)).status, 403);
});


test('feeds: issuance is bounded and bearer pagination does not turn a supplied query into a credential', async () => {
  const f = await fixture(), p = policy('nutrition'); p.allowFeeds = true;
  const d = await f.draft(p); await f.send(d);
  const path = `/app/api/shares/${d.id}/feeds`;
  const issued = await Promise.all(Array.from({ length: 11 }, (_, i) => f.call('POST', path, { name: `Connection ${i}` })));
  assert.equal(issued.filter(r => r.status === 201).length, 10);
  assert.equal(issued.filter(r => r.status === 409).length, 1);
  const feed = await issued.find(r => r.status === 201).json();
  for (const id of ['a', 'b']) await f.put('food.meal', id, { name: 'Lunch' });
  const url = `/app/feeds/${feed.id}/records.json?type=food.meal&limit=1&signature=invalid`;
  const response = await f.s.app.request(url, { headers: { Authorization: `Bearer ${feed.token}` } });
  assert.equal(response.status, 200);
  const next = (await response.json()).next;
  assert.equal(new URL(next).searchParams.has('signature'), false);
  assert.equal((await f.s.app.request(next)).status, 401);
  assert.equal((await f.s.app.request(next, { headers: { Authorization: `Bearer ${feed.token}` } })).status, 200);
  assert.equal((await f.s.app.request(feed.url, { headers: { Authorization: 'Bearer wrong' } })).status, 401);
});

test('personal feeds: selected JSON, CSV and images without a guest, invitation or native credential', async () => {
  const f = await fixture();
  const photo = await f.blob('food.mealPhoto', 'photo-bytes', 'jpg');
  await f.put('food.mealPhoto', 'photo-one', { v: photo });
  await f.put('food.meal', 'lunch', { v: { name: 'Lunch', photoIDs: ['photo-one'] } });
  await f.put('food.supplement', 'private', { name: 'Not selected' });
  const response = await f.call('POST', '/app/api/feeds', { name: 'My analysis', policy: policy('nutrition') });
  assert.equal(response.status, 201, await response.clone().text());
  const feed = await response.json();
  assert.match(feed.id, /^p_[A-Za-z0-9_-]{22}$/);
  const manifest = await (await f.s.app.request(feed.url)).json();
  assert.equal(manifest.scope, 'personal'); assert.equal(manifest.shareVersion, null);
  const meals = manifest.types.find(t => t.type === 'food.meal');
  assert.ok(meals); assert.equal(manifest.types.some(t => t.type === 'food.supplement'), false);
  const page = await (await f.s.app.request(meals.json)).json();
  assert.equal(page.records[0].data.name, 'Lunch');
  const image = page.records[0].assets[0].url;
  assert.equal(await (await f.s.app.request(image)).text(), 'photo-bytes');
  assert.match(await (await f.s.app.request(meals.csv)).text(), /Lunch/);
  assert.equal((await f.s.app.request(`/app/feeds/${feed.id}`, { headers: { Authorization: `Bearer ${feed.token}` } })).status, 200);
  assert.equal((await f.s.call('GET', '/v1/account', { session: feed.token })).status, 401);
  const listing = await (await f.call('GET', '/app/api/feeds')).json();
  assert.equal(listing.feeds.length, 1); assert.ok(listing.feeds[0].policy.sections.nutrition);
  assert.doesNotMatch(JSON.stringify(listing), new RegExp(feed.token));
  assert.equal((await f.s.deps.db.first('SELECT COUNT(*) AS n FROM web_shares')).n, 0);
  assert.equal((await f.s.deps.db.first('SELECT COUNT(*) AS n FROM guests')).n, 0);
  assert.equal(f.s.email.sent.length, 0);
  assert.equal((await f.call('POST', `/app/api/feeds/${feed.id}/revoke`, {})).status, 200);
  assert.equal((await f.s.app.request(feed.url)).status, 404);
  assert.equal((await f.s.app.request(image)).status, 404);
});

test('personal feeds: guest, signed-out, cross-origin and other-owner management is denied', async () => {
  const f = await fixture(), input = { name: 'Private', policy: policy('nutrition') };
  const shared = await f.draft(policy('nutrition')); await f.send(shared);
  const guest = await f.login('trainer', shared.id); assert.ok(guest.cookie);
  assert.equal((await f.call('POST', '/app/api/feeds', input, guest.cookie)).status, 403);
  assert.equal((await f.call('GET', '/app/api/feeds', null, guest.cookie)).status, 403);
  assert.equal((await f.call('POST', '/app/api/feeds', input, null)).status, 401);
  assert.equal((await f.call('POST', '/app/api/feeds', input, f.ownerCookie, 'https://elsewhere.example')).status, 403);
  const feed = await (await f.call('POST', '/app/api/feeds', input)).json();
  f.s.google.person('other-owner', 'other-owner-sub', 'noor@plan.example');
  await f.s.signIn('other-owner', device('phone-other-0001'));
  const other = await f.login('other-owner');
  assert.deepEqual((await (await f.call('GET', '/app/api/feeds', null, other.cookie)).json()).feeds, []);
  assert.equal((await f.call('POST', `/app/api/feeds/${feed.id}/revoke`, {}, other.cookie)).status, 404);
  assert.equal((await f.call('POST', `/app/api/feeds/${feed.id}/revoke`, {}, f.ownerCookie, 'https://elsewhere.example')).status, 403);
  assert.equal((await f.s.app.request(feed.url)).status, 200);
  assert.equal((await f.s.app.request(feed.url + 'tampered')).status, 401);
});

test('personal feeds: scope validation, expiration, health projection and withdrawn consent', async () => {
  const f = await fixture();
  for (const p of [emptyPolicy(), { ...policy('nutrition'), expiresOn: '2020-01-01' },
    { ...policy('nutrition'), calendars: [{ sub: 'owner-sub', id: 'unknown', access: 'details' }] }])
    assert.equal((await f.call('POST', '/app/api/feeds', { name: 'Invalid', policy: p })).status, 400);
  const ref = await f.blob('health.snapshot', { workouts: [{ id: 'run', activity: 'Run' }], trends: { PRIVATE: 42 } });
  await f.put('health.snapshot', 'snapshot', { v: ref });
  const p = { ...policy('workouts'), expiresOn: new Date(f.s.now()).toISOString().slice(0, 10) };
  const feed = await (await f.call('POST', '/app/api/feeds', { name: 'Training', policy: p })).json();
  const manifest = await (await f.s.app.request(feed.url)).json();
  const endpoint = manifest.types.find(t => t.type === 'health.snapshot').json;
  const text = await (await f.s.app.request(endpoint)).text();
  assert.match(text, /Run/); assert.doesNotMatch(text, /PRIVATE/);
  await f.space.withdrawConsent('health');
  assert.deepEqual((await (await f.s.app.request(endpoint)).json()).records, []);
  f.s.advance(DAY);
  assert.equal((await f.s.app.request(feed.url)).status, 404);
});

test('personal feeds: ten live connections, revocation frees capacity and account deletion removes credentials', async () => {
  const f = await fixture(), input = { name: 'Analysis', policy: policy('nutrition') };
  let feed;
  for (let i = 0; i < 10; i++) {
    const response = await f.call('POST', '/app/api/feeds', input);
    assert.equal(response.status, 201); feed = await response.json();
  }
  assert.equal((await f.call('POST', '/app/api/feeds', input)).status, 409);
  await f.call('POST', `/app/api/feeds/${feed.id}/revoke`, {});
  const replacement = await f.call('POST', '/app/api/feeds', input);
  assert.equal(replacement.status, 201);
  const url = (await replacement.json()).url;
  f.s.google.person('delete-owner', 'owner-sub', 'owner@example.com');
  assert.equal((await f.s.call('DELETE', '/v1/account', { session: f.owner.session, body: { code: 'delete-owner' } })).status, 204);
  assert.equal((await f.s.app.request(url)).status, 404);
  assert.equal((await f.s.deps.db.first('SELECT COUNT(*) AS n FROM web_personal_feeds')).n, 0);
});

test('sharing: unavailable published calendars can be retained or reduced during unrelated edits, never newly granted or widened', async () => {
  const f = await fixture(), p = policy('nutrition');
  p.calendars = [{ sub: 'owner-sub', id: 'calendar-1', access: 'details' }, { sub: 'owner-sub', id: 'calendar-2', access: 'busy' }];
  let d = await f.draft(p); await f.send(d);
  f.s.google.failList = true;
  p.allowFeeds = true;
  let response = await f.call('PUT', `/app/api/shares/${d.id}/draft`, { email: d.email, version: d.version, policy: p });
  assert.equal(response.status, 200, await response.clone().text()); d = await response.json();
  await f.preview(d);
  const preview = await (await f.call('GET', view(d.id, 'account', d.version))).json();
  assert.equal(preview.canPublish, true);
  assert.equal((await f.call('POST', `/app/api/shares/${d.id}/publish`, { version: d.version })).status, 200);
  assert.deepEqual((await (await f.call('GET', '/app/api/shares')).json()).shares[0].policy.calendars, p.calendars);
  p.calendars[0].access = 'busy';
  response = await f.call('PUT', `/app/api/shares/${d.id}/draft`, { email: d.email, version: d.version, policy: p });
  assert.equal(response.status, 200); d = await response.json();
  p.calendars[1].access = 'details';
  assert.equal((await f.call('PUT', `/app/api/shares/${d.id}/draft`, { email: d.email, version: d.version, policy: p })).status, 400);
  p.calendars = [{ sub: 'owner-sub', id: 'calendar-new', access: 'busy' }];
  assert.equal((await f.call('PUT', `/app/api/shares/${d.id}/draft`, { email: d.email, version: d.version, policy: p })).status, 400);
  assert.equal((await f.call('POST', '/app/api/feeds', { name: 'New grant', policy: p })).status, 400);
  const fresh = await f.draft(policy('nutrition'));
  await f.preview(fresh);
  assert.equal((await (await f.call('GET', view(fresh.id, 'account', fresh.version))).json()).canPublish, false);
});

test('unified feed: one URL combines only shared types with bounded JSON/CSV pages and working images', async () => {
  const f = await fixture(), p = policy('nutrition'); p.allowFeeds = true;
  const photo = await f.blob('food.mealPhoto', 'shared-photo', 'jpg');
  await f.put('food.mealPhoto', 'photo', { v: photo });
  await f.put('food.meal', 'meal-a', { name: 'Lunch', photoIDs: ['photo'] });
  await f.put('food.meal', 'meal-b', { name: 'Dinner' });
  await f.put('food.myFood', 'saved', { name: 'Rice' });
  await f.put('notes.voiceNote', 'private-note', { transcript: 'PRIVATE NOTE' });
  await f.put('food.supplement', 'private-dose', { name: 'PRIVATE DOSE' });
  const d = await f.draft(p); await f.send(d);
  const guest = await f.login('trainer', d.id); assert.ok(guest.cookie);
  const feed = await (await f.call('POST', `/app/api/shared/${d.id}/feeds`, { name: 'Coach' }, guest.cookie)).json();
  assert.equal(new URL(feed.dataURL).pathname, new URL(feed.url).pathname);
  assert.equal((await (await f.s.app.request(feed.manifestURL)).json()).access.sections.includes('nutrition'), true);
  const url = new URL(feed.dataURL); url.searchParams.set('limit', '1');
  let next = url.href, rows = [], pages = 0, image;
  while (next) {
    const response = await f.s.app.request(next); assert.equal(response.status, 200, await response.clone().text());
    const page = await response.json(); assert.equal(page.schema, 'banana.feed.v2');
    assert.ok(page.records.length <= 1); assert.deepEqual(page.access.sections, ['nutrition']);
    rows.push(...page.records); image ??= page.records.find(r => r.type === 'food.meal' && r.assets.length)?.assets[0].url;
    next = page.next; assert.ok(++pages < 12);
  }
  assert.deepEqual(rows.map(r => r.type+':'+r.id).sort(), ['food.meal:meal-a','food.meal:meal-b','food.mealPhoto:photo','food.myFood:saved'].sort());
  assert.equal(await (await f.s.app.request(image)).text(), 'shared-photo');
  const csv = new URL(feed.dataURL); csv.searchParams.set('types', 'food.meal,food.myFood'); csv.searchParams.set('format', 'csv');
  const text = await (await f.s.app.request(csv)).text(); assert.match(text, /^"type","id"/); assert.match(text, /Rice/); assert.match(text, /Lunch/); assert.doesNotMatch(text, /PRIVATE/);
  for (const type of ['notes.voiceNote','food.supplement','food.meal,notes.voiceNote','calendar']) {
    const bad = new URL(feed.dataURL); bad.searchParams.set('types', type);
    assert.equal((await f.s.app.request(bad)).status, 403);
  }
  const bad = new URL(feed.dataURL); bad.searchParams.set('owner', 'another-account');
  assert.equal((await f.s.app.request(bad)).status, 400);
  const bearer = new URL(feed.dataURL); bearer.searchParams.delete('signature'); bearer.searchParams.set('limit', '1');
  const first = await (await f.s.app.request(bearer, { headers: { Authorization: `Bearer ${feed.token}` } })).json();
  assert.equal(new URL(first.next).searchParams.has('signature'), false);
  assert.equal((await f.s.app.request(first.next)).status, 401);
  assert.equal((await f.s.app.request(first.next, { headers: { Authorization: `Bearer ${feed.token}` } })).status, 200);
  await f.call('POST', `/app/api/shared/${d.id}/feeds/${feed.id}/revoke`, {}, guest.cookie);
  assert.equal((await f.s.app.request(feed.dataURL)).status, 404);
  assert.equal((await f.s.app.request(image)).status, 404);
});

test('unified feed: narrowed and withdrawn access is rechecked for queries, pages and image links', async () => {
  const f = await fixture(), p = policy('nutrition', 'notes'); p.allowFeeds = true;
  await f.put('food.meal', 'a', { name: 'Lunch' }); await f.put('food.meal', 'b', { name: 'Dinner' });
  await f.put('notes.voiceNote', 'a', { transcript: 'Shared then removed' });
  const d = await f.draft(p); await f.send(d);
  const feed = await (await f.call('POST', `/app/api/shares/${d.id}/feeds`, { name: 'Limited' })).json();
  const one = new URL(feed.dataURL); one.searchParams.set('limit', '1');
  const first = await (await f.s.app.request(one)).json(); assert.ok(first.next);
  const other = await (await f.call('POST', `/app/api/shares/${d.id}/feeds`, { name: 'Other' })).json();
  const replay = new URL(first.next); replay.pathname = new URL(other.url).pathname; replay.searchParams.set('signature', new URL(other.url).searchParams.get('signature'));
  assert.equal((await f.s.app.request(replay)).status, 409);
  const changed = new URL(first.next); changed.searchParams.set('format', 'csv');
  assert.equal((await f.s.app.request(changed)).status, 409);
  const forged = new URL(first.next); forged.searchParams.set('cursor', forged.searchParams.get('cursor').slice(0,-1)+'!');
  assert.equal((await f.s.app.request(forged)).status, 400);
  p.sections.notes = false;
  const edited = await (await f.call('PUT', `/app/api/shares/${d.id}/draft`, { email: d.email, version: d.version, policy: p })).json();
  await f.preview(edited); await f.call('POST', `/app/api/shares/${d.id}/publish`, { version: edited.version });
  const current = await (await f.s.app.request(feed.dataURL)).json();
  assert.ok(current.records.every(r => r.type !== 'notes.voiceNote'));
  assert.equal((await f.s.app.request(first.next)).status, 403);
  const listed = await (await f.call('GET', `/app/api/shares/${d.id}/feeds`)).json();
  assert.ok(listed.feeds.every(item => !item.access.sections.includes('notes')));
  const privateQuery = new URL(feed.dataURL); privateQuery.searchParams.set('types', 'notes.voiceNote');
  assert.equal((await f.s.app.request(privateQuery)).status, 403);
  await f.space.withdrawConsent('health');
  const withdrawn = await (await f.s.app.request(feed.dataURL)).json(); assert.deepEqual(withdrawn.records, []);
});

test('unified feed: rolling calendar pages freeze their window, redact busy details and reject calendar changes', async () => {
  const f = await fixture(), p = policy('nutrition'); p.allowFeeds = true;
  p.calendars = [{ sub: 'owner-sub', id: 'calendar-1', access: 'busy' }];
  const events = [1,2,3].map(i => ({ id: 'private-'+i, summary: 'PRIVATE TITLE', description: 'PRIVATE NOTES', start: { dateTime: new Date(f.s.now()+i*3600000).toISOString() }, end: { dateTime: new Date(f.s.now()+i*3600000+1800000).toISOString() } }));
  f.s.google.events.set('calendar-1', events);
  f.s.google.events.set('calendar-4', [{...events[0], summary:'UNSHARED CALENDAR'}]);
  const d = await f.draft(p); await f.send(d);
  const feed = await (await f.call('POST', `/app/api/shares/${d.id}/feeds`, { name: 'Availability' })).json();
  f.s.advance(12*3600000-60000);
  const url = new URL(feed.dataURL); url.searchParams.set('types','calendar');url.searchParams.set('limit','1');
  const first = await (await f.s.app.request(url)).json(); assert.equal(first.records.length,1);assert.ok(first.next);
  assert.doesNotMatch(JSON.stringify(first), /PRIVATE|UNSHARED|private-/);
  f.s.advance(120000);
  const second = await (await f.s.app.request(first.next)).json();
  assert.deepEqual(second.calendarWindow, first.calendarWindow);assert.notEqual(first.records[0].id, second.records[0].id);
  const csv = new URL(url); csv.searchParams.set('format','csv');
  const response = await f.s.app.request(csv);assert.equal(response.status,200);assert.match(response.headers.get('link'), /rel="next"/);
  assert.doesNotMatch(await response.text(), /PRIVATE|UNSHARED/);
  f.s.google.events.set('calendar-1', events.slice(1));
  assert.equal((await f.s.app.request(first.next)).status,409);
  f.s.google.failList=true;
  assert.equal((await f.s.app.request(url)).status,503);
});

test('unified personal feed cannot reach types outside its selected scope', async () => {
  const f = await fixture(); await f.put('food.meal','one',{name:'Lunch'});await f.put('notes.voiceNote','secret',{transcript:'PRIVATE'});
  const feed = await (await f.call('POST','/app/api/feeds',{name:'My export',policy:policy('nutrition')})).json();
  const data = await (await f.s.app.request(feed.dataURL)).json();assert.equal(data.scope,'personal');assert.equal(data.records.length,1);
  const widened = new URL(feed.dataURL);widened.searchParams.set('types','notes.voiceNote');
  assert.equal((await f.s.app.request(widened)).status,403);
});
