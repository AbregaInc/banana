import test from 'node:test';
import assert from 'node:assert/strict';
import {setup, device, START, DAY, TOKEN_KEY} from './helpers.js';
import {createVault} from '../src/crypto.js';
import {readCalendarWindow} from '../src/calendar-window.js';

async function person(s, name = 'noor', grant = true) {
  s.google.person(`code-${name}`, `sub-${name}`, `${name}@plan.example`);
  const auth = (await s.signIn(`code-${name}`, device(`device-${name}`))).json;
  if (grant) await s.db.run('INSERT INTO feature_access VALUES (?, ?, 1, NULL, ?)', auth.account.id, 'calendarCloud', s.now());
  return auth;
}
const path = `/v1/calendar/window?from=${START}&to=${START+DAY}`;
const event = (id, title) => ({id, summary:title, start:{dateTime:new Date(START+3600000).toISOString()}, end:{dateTime:new Date(START+7200000).toISOString()}});

test('cloud calendar checks authentication and current eligibility before contacting Google', async () => {
  const s=setup(), auth=await person(s, 'noor', false);
  assert.equal((await s.call('GET',path)).status,401);
  assert.equal((await s.call('GET',path,{session:auth.session})).status,403);
  assert.deepEqual(s.google.calls.refresh,[]);
  await s.db.run('INSERT INTO feature_access VALUES (?, ?, 1, ?, ?)',auth.account.id,'calendarCloud',s.now()+10,s.now());
  assert.equal((await s.call('GET',path,{session:auth.session})).status,200);
  const calls=s.google.calls.refresh.length;
  s.advance(10);
  assert.equal((await s.call('GET',path,{session:auth.session})).status,403);
  assert.equal(s.google.calls.refresh.length,calls);
});

test('cloud calendar cannot select another account and agrees with the shared web reader', async () => {
  const s=setup(), a=await person(s), b=await person(s,'other');
  s.google.events.set('primary-refresh-sub-noor',[event('own','Own event')]);
  s.google.events.set('primary-refresh-sub-other',[event('other','Other event')]);
  const response=await s.call('GET',`${path}&account=${b.account.id}`,{session:a.session});
  assert.equal(response.status,200);
  assert.equal(response.json.events.length,1);
  assert.equal(response.json.events[0].title,'Own event');
  const shared=await readCalendarWindow(s.deps,{vault:createVault(TOKEN_KEY,s.deps.random),account:a.account.id,settings:null,from:START,to:START+DAY});
  assert.deepEqual(response.json,{version:1,from:START,to:START+DAY,...shared});
  assert.deepEqual(s.google.booking,{insert:[],get:[],patch:[],delete:[]});
});

test('cloud calendar reports reconnect instead of treating absent grants as an empty calendar', async () => {
  const s=setup(), auth=await person(s);
  await s.db.run('UPDATE google_links SET refresh_token=NULL WHERE account_id=?',auth.account.id);
  const response=await s.call('GET',path,{session:auth.session});
  assert.equal(response.status,200);
  assert.deepEqual(response.json.unavailable,[{email:'noor@plan.example',reason:'reconnect'}]);
  assert.deepEqual(s.google.calls.refresh,[]);
});

test('cloud calendar bounds windows and never forwards arbitrary provider paths', async () => {
  const s=setup(), auth=await person(s);
  for(const query of ['',`from=${START}&to=${START}`,`from=${START}&to=${START+9*DAY}`,'from=Infinity&to=Infinity']) {
    assert.equal((await s.call('GET',`/v1/calendar/window?${query}`,{session:auth.session})).status,400);
  }
  assert.deepEqual(s.google.calls.refresh,[]);
  const response=await s.app.request(path,{headers:{authorization:`Bearer ${auth.session}`}});
  assert.equal(response.headers.get('cache-control'),'no-store');
});

test('one provider failure is explicit while the other linked account still returns events', async () => {
  const s=setup(), auth=await person(s);
  s.google.person('code-work','sub-work','work@plan.example');
  await s.signIn('code-work',device('device-work'),auth.session);
  s.google.refused.add('refresh-sub-noor');
  s.google.events.set('primary-refresh-sub-work',[event('work','Work event')]);
  const response=await s.call('GET',path,{session:auth.session});
  assert.equal(response.status,200);
  assert.deepEqual(response.json.unavailable,[{email:'noor@plan.example',reason:'reconnect'}]);
  assert.equal(response.json.events[0].title,'Work event');
});
