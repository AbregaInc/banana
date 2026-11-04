import { test } from 'node:test';
import assert from 'node:assert/strict';
import { setup, device } from './helpers.js';
import { featureAllowed, featurePolicy, googleCapabilities, POLICY_TTL } from '../src/feature-access.js';
async function account(s, suffix) {
  s.google.person(`code-${suffix}`, `sub-${suffix}`, `${suffix}@plan.example`);
  return (await s.signIn(`code-${suffix}`, device(`device-${suffix}`))).json;
}
async function grant(s, id, feature, enabled = 1, expires = null) {
  await s.db.run('INSERT INTO feature_access VALUES (?, ?, ?, ?, ?) ON CONFLICT(account_id, feature) DO UPDATE SET enabled=excluded.enabled, expires_at=excluded.expires_at, updated_at=excluded.updated_at', id, feature, enabled, expires, s.now());
}
test('no implicit eligibility from Google login, scopes, or another account', async () => {
  const s = setup(); const a = await account(s, 'noor'), b = await account(s, 'other');
  assert.deepEqual(a.account.featureAccess.enabled, []);
  await grant(s, a.account.id, 'email');
  assert.equal(await featureAllowed(s.deps, a.account.id, 'email'), true);
  assert.equal(await featureAllowed(s.deps, b.account.id, 'email'), false);
  assert.equal(await featureAllowed(s.deps, a.account.id, 'unknown'), false);
  const response = await s.call('GET', '/v1/account', {session: a.session});
  assert.deepEqual(response.json.featureAccess.enabled, ['email']);
  assert.equal(response.json.google[0].capabilities.mailRead, false);
});
test('expiry and revocation take effect immediately and bound the client policy', async () => {
  const s = setup(); const a = await account(s, 'noor');
  await grant(s, a.account.id, 'email', 1, s.now() + 1000);
  assert.equal((await featurePolicy(s.deps, a.account.id)).expiresAt, s.now() + 1000);
  s.advance(1000);
  assert.equal(await featureAllowed(s.deps, a.account.id, 'email'), false);
  assert.deepEqual((await featurePolicy(s.deps, a.account.id)).enabled, []);
  await grant(s, a.account.id, 'email');
  assert.equal((await featurePolicy(s.deps, a.account.id)).expiresAt, s.now() + POLICY_TTL);
  await grant(s, a.account.id, 'email', 0);
  assert.equal(await featureAllowed(s.deps, a.account.id, 'email'), false);
});
test('linked Google identities and other devices use the same Banana eligibility', async () => {
  const s = setup(); const a = await account(s, 'noor');
  await grant(s, a.account.id, 'email');
  s.google.person('second', 'sub-second', 'second@plan.example');
  const linked = await s.signIn('second', device('device-second'), a.session);
  assert.equal(linked.json.account.id, a.account.id);
  assert.deepEqual(linked.json.account.featureAccess.enabled, ['email']);
  const anotherDevice = await s.signIn('second', device('device-third'));
  assert.deepEqual(anotherDevice.json.account.featureAccess.enabled, ['email']);
});
test('deleting an account removes its feature grants', async () => {
  const s = setup(); const a = await account(s, 'noor');
  await grant(s, a.account.id, 'email');
  const r = await s.call('DELETE', '/v1/account', {session: a.session, body: {code: 'code-noor'}});
  assert.equal(r.status, 204);
  assert.equal((await s.db.first('SELECT COUNT(*) AS n FROM feature_access')).n, 0);
});
test('provider capabilities require a server grant and appropriate scopes', () => {
  const link = {has_token: 1, status: 'ok', scopes: 'https://www.googleapis.com/auth/calendar.events.readonly https://www.googleapis.com/auth/gmail.send'};
  assert.deepEqual(googleCapabilities(link), {calendarRead: true, calendarWrite: false, calendarList: false, mailRead: false, mailModify: false, mailSend: true});
  for (const invalid of [{...link, has_token: 0}, {...link, status: 'refused'}]) assert.ok(Object.values(googleCapabilities(invalid)).every(v => v === false));
});
