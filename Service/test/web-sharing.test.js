import test from 'node:test';
import assert from 'node:assert/strict';
import { setup, device, DAY } from './helpers.js';
import { emptyPolicy, sharedCalendar } from '../src/web/sharing-policy.js';
import { sha256Hex } from '../src/crypto.js';
import { memoryEmail } from '../src/booking/email.js';

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
