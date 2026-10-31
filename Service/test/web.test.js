import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { setup, device, DAY, START } from './helpers.js';
import { sha256Hex } from '../src/crypto.js';
import { readBusy } from '../src/booking/busy.js';
import { calendarInfoID } from '../src/calendar-preferences.js';
import { createVault } from '../src/crypto.js';
import { createSigner } from '../src/booking/sign.js';
import { lzfseDecompress } from '../public/app/assets/vendor/lzfse.js';

async function fixture() {
  const s=setup();
  s.google.person('ann','ann-sub','ann@example.com',null,{name:'Ann'});
  const who=(await s.signIn('ann',device('phone-ann-0001'))).json;
  const space=`sp_${who.account.id}`;
  async function login() {
    const start=await s.app.request('/app/auth/google');
    const redirect=new URL(start.headers.get('location'));
    const nonce=start.headers.get('set-cookie').split(';')[0];
    const end=await s.app.request(`/v1/google/callback?${new URLSearchParams({state:redirect.searchParams.get('state'),code:'ann'})}`,{headers:{cookie:nonce}});
    const cookies=end.headers.getSetCookie();
    const cookie=cookies.find(c=>c.startsWith('__Host-banana-web=')).split(';')[0];
    return {start,redirect,end,cookie};
  }
  const auth=await login();
  const get=(path,cookie=auth.cookie)=>s.app.request(path,{headers:{cookie}});
  const put=async(type,id,fields)=>{
    const clocks=Object.fromEntries(Object.keys(fields).map(k=>[k,`${s.now()}.0000.phone`]));
    return s.call('POST','/v2/sync',{session:who.session,body:{device:'phone-ann-0001',changes:[{type,id,set:fields,clocks}]}});
  };
  return {s,who,space,auth,get,put,login};
}

test('web: shell is public, personal reads need a distinct web session; nothing is cached',async()=>{
  const {s,who,get}=await fixture();
  const shell=await s.app.request('/app/');
  assert.equal(shell.status,200);assert.match(await shell.text(),/Continue with Google/);
  assert.equal(shell.headers.get('cache-control'),'no-store');
  assert.match(shell.headers.get('content-security-policy'),/frame-ancestors 'none'/);
  assert.equal((await s.app.request('/app/api/account')).status,401);
  assert.equal((await s.call('GET','/app/api/account',{session:who.session})).status,401);
  const r=await get('/app/api/account');assert.equal(r.status,200);assert.equal((await r.json()).email,'ann@example.com');
  assert.equal(r.headers.get('cache-control'),'no-store');
});

test('web: Google state is browser-bound, short-lived, signed, and separate from booking',async()=>{
  const {s,auth}=await fixture();
  assert.equal(auth.redirect.searchParams.get('redirect_uri'),'https://service.test/v1/google/callback');
  assert.equal(auth.redirect.searchParams.get('scope'),'openid email profile');
  assert.match(auth.start.headers.get('set-cookie'),/HttpOnly/);assert.match(auth.start.headers.get('set-cookie'),/Secure/);
  const state=auth.redirect.searchParams.get('state');
  for(const cookie of ['', '__Host-banana-web-login=wrong']) {
    const r=await s.app.request(`/v1/google/callback?${new URLSearchParams({state,code:'ann'})}`,{headers:{cookie}});
    assert.match(r.headers.get('location'),/error=expired/);
  }
  const start=await s.app.request('/app/auth/google');
  const cookie=start.headers.get('set-cookie').split(';')[0],nonce=cookie.split('=')[1];
  const signed=await createSigner(s.deps.config.tokenKey).seal('connect',{n:nonce},s.now()+600_000);
  const wrong=await s.app.request(`/v1/google/callback?${new URLSearchParams({state:signed,code:'ann'})}`,{headers:{cookie}});
  assert.match(wrong.headers.get('location'),/error=expired/);
  s.advance(601_000);
  const expired=await s.app.request(`/v1/google/callback?${new URLSearchParams({state:new URL(start.headers.get('location')).searchParams.get('state'),code:'ann'})}`,{headers:{cookie}});
  assert.match(expired.headers.get('location'),/error=expired/);
});

test('web: sign-in sets a host-only cookie, stores a hash, creates no device, grants no native API access',async()=>{
  const {s,auth,who}=await fixture();
  assert.equal(auth.end.status,303);assert.equal(auth.end.headers.get('location'),'https://service.test/app/');
  const raw=auth.cookie.split('=')[1];
  const row=await s.db.first("SELECT * FROM sessions WHERE token_hash = ?",await sha256Hex(raw));
  assert.equal(row.kind,'web');assert.equal(row.account_id,who.account.id);
  assert.equal(await s.count('devices'),1);
  assert.equal((await s.call('GET','/v1/account',{session:raw})).status,401);
  assert.equal((await s.call('DELETE','/v1/account',{session:raw})).status,401);
  const header=auth.end.headers.getSetCookie().find(c=>c.startsWith('__Host-banana-web='));
  assert.match(header,/HttpOnly/);assert.match(header,/SameSite=Lax/);assert.match(header,/Secure/);assert.doesNotMatch(header,/Domain=/);
});

test('web: an unknown Google identity cannot create or view an account',async()=>{
  const {s}=await fixture();s.google.person('other','other-sub','other@example.com');
  const start=await s.app.request('/app/auth/google');
  const r=await s.app.request(`/v1/google/callback?${new URLSearchParams({state:new URL(start.headers.get('location')).searchParams.get('state'),code:'other'})}`,{headers:{cookie:start.headers.get('set-cookie').split(';')[0]}});
  assert.match(r.headers.get('location'),/error=no_account/);assert.equal(await s.count('accounts'),1);
});

test('web: private reads are account-scoped even if another space is requested',async()=>{
  const {s,get,put}=await fixture();await put('plan.routine','routine-a',{name:'Ann routine'});
  s.google.person('bob','bob-sub','bob@example.com');const bob=(await s.signIn('bob',device('phone-bob-0001'))).json;
  await s.deps.spaces.get(`sp_${bob.account.id}`).sync({platform:'iphone',device:'bob',now:s.now(),changes:[{type:'plan.routine',id:'routine-b',set:{name:'Bob private routine'},clocks:{name:`${s.now()}.0000.bob`}}]});
  const r=await(await get(`/app/api/records?type=plan.routine&space=sp_${bob.account.id}`)).json();
  assert.deepEqual(r.records.map(r=>r.fields.name),['Ann routine']);
});

test('web: pagination crosses tombstones without losing later records and rejects uncatalogued reads',async()=>{
  const {s,space,get}=await fixture();
  const changes=Array.from({length:205},(_,i)=>({type:'plan.routine',id:`r-${String(i).padStart(3,'0')}`,set:{name:`Routine ${i}`},clocks:{name:`${s.now()}.0000.phone`},...(i<100?{delete:`${s.now()}.0001.phone`}:{})}));
  await s.deps.spaces.get(space).sync({platform:'iphone',device:'phone',now:s.now(),changes});
  const a=await(await get('/app/api/records?type=plan.routine')).json();assert.equal(a.records.length,0);assert.equal(a.next,'r-099');
  const b=await(await get(`/app/api/records?type=plan.routine&after=${a.next}`)).json();assert.equal(b.records.length,100);
  const c=await(await get(`/app/api/records?type=plan.routine&after=${b.next}`)).json();assert.equal(c.records.length,5);assert.equal(c.next,null);
  assert.equal((await get('/app/api/records?type=google_links')).status,400);
  assert.equal((await get('/app/api/records?type=core.appSettings')).status,400);
});

test('web: Health and food records, counts and files follow the same consent gate',async()=>{
  const {s,space,get,put}=await fixture();
  const stub=s.deps.spaces.get(space);await stub.setConsent('health',{version:'1',at:START});
  const bytes=new TextEncoder().encode('photo'),sha=await sha256Hex('photo');
  await s.deps.blobs.put(`s/${space}/${sha}`,new Blob([bytes]).stream(),{sha256:sha});
  await stub.recordBlob(sha,bytes.length,s.now(),'food.mealPhoto');
  await put('food.meal','meal',{name:'Lunch'});await put('food.mealPhoto','photo',{v:{$blob:sha,ext:'jpg',size:bytes.length}});
  assert.equal((await(await get('/app/api/account')).json()).counts['food.meal'],1);
  assert.equal((await(await get('/app/api/records?type=food.meal')).json()).records.length,1);
  const photo='/app/api/blob?type=food.mealPhoto&id=photo&field=v';
  const found=await get(photo);assert.equal(found.status,200);assert.equal(found.headers.get('content-type'),'image/jpeg');assert.equal(found.headers.get('cache-control'),'no-store');
  await stub.withdrawConsent('health');
  assert.equal((await(await get('/app/api/records?type=food.meal')).json()).records.length,0);
  assert.equal((await get(photo)).status,404);
  assert.equal((await(await get('/app/api/account')).json()).counts['food.meal'],undefined);
});

test('web: files must be referenced by a live record, arbitrary hashes and deleted records do not expose blobs',async()=>{
  const {s,space,get,put}=await fixture();
  const sha=await sha256Hex('audio');await s.deps.blobs.put(`s/${space}/${sha}`,new Blob(['audio']).stream(),{sha256:sha});
  await s.deps.spaces.get(space).recordBlob(sha,5,s.now(),'notes.voiceNote');
  await put('notes.voiceNote','note',{transcript:'A thought',audio:{$blob:sha,ext:'m4a',size:5}});
  const path='/app/api/blob?type=notes.voiceNote&id=note&field=audio';
  const found=await get(path);assert.equal(found.status,200);assert.equal(await found.text(),'audio');
  assert.equal((await get('/app/api/blob?type=notes.voiceNote&id=other&field=audio')).status,404);
  assert.equal((await get(`/app/api/blob?sha=${sha}`)).status,400);
  await s.deps.spaces.get(space).sync({platform:'iphone',device:'phone',now:s.now(),changes:[{type:'notes.voiceNote',id:'note',delete:`${s.now()}.0001.phone`}]});
  assert.equal((await get(path)).status,404);
});

test('web: logout checks origin, revokes only this browser, and sessions expire after thirty days',async()=>{
  const {s,auth,get,who}=await fixture();
  assert.equal((await s.app.request('/app/auth/logout',{method:'POST',headers:{cookie:auth.cookie,origin:'https://attacker.test'}})).status,403);
  assert.equal((await get('/app/api/account')).status,200);
  const other=await fixture();other.s.advance(31*DAY);assert.equal((await other.get('/app/api/account')).status,401);
  const out=await s.app.request('/app/auth/logout',{method:'POST',headers:{cookie:auth.cookie,origin:'https://service.test'}});
  assert.equal(out.status,204);assert.equal((await get('/app/api/account')).status,401);
  assert.equal((await s.call('GET','/v1/account',{session:who.session})).status,200);
});

test('web: record writes are not exposed and signed-out HTML contains no personal data',async()=>{
  const {s,auth}=await fixture();
  for(const method of ['POST','PUT','DELETE'])assert.equal((await s.app.request('/app/api/records',{method,headers:{cookie:auth.cookie},body:'{}'})).status,404);
  const html=await(await s.app.request('/app/')).text();assert.doesNotMatch(html,/ann@example.com/);assert.doesNotMatch(html,/localStorage/);
});

test('web: browser LZFSE decoder reads actual Apple-compressed snapshots and transcripts',()=>{
  const packed=readFileSync(new URL('./fixtures/web-health.lzfse',import.meta.url));
  assert.equal(packed.subarray(0,6).toString(),'LZFSE1');
  const health=JSON.parse(new TextDecoder().decode(lzfseDecompress(packed.subarray(6))));
  assert.equal(health.trends.restingHR.length,30);assert.equal(health.trends.restingHR[0].value,55);
  const transcript=JSON.parse(new TextDecoder().decode(lzfseDecompress(readFileSync(new URL('./fixtures/web-transcript.lzfse',import.meta.url)))));
  assert.equal(transcript.words.length,3000);assert.equal(transcript.words[2999].text,'word2999');
  assert.throws(()=>lzfseDecompress(new Uint8Array([1,2,3,4])));
});

test('web: agenda reads only the signed-in account’s calendars, skips cancelled events, and retains no event data',async()=>{
  const {s,get,who}=await fixture();
  // Give Ann a server-side calendar grant, as the native app does. Bob's grant stays isolated.
  s.google.person('ann-grant','ann-sub','ann@example.com','ann-refresh');
  await s.signIn('ann-grant',device('phone-ann-0001'));
  s.google.calendars.set('ann-refresh',[{id:'ann-cal',summary:'Personal',selected:true},{id:'hidden-cal',summary:'Hidden',hidden:true}]);
  s.google.events.set('ann-cal',[{id:'event',summary:'A private meeting',start:{dateTime:'2026-10-15T14:00:00Z'},end:{dateTime:'2026-10-15T15:00:00Z'},location:'Office'}, {id:'cancelled',summary:'Gone',status:'cancelled'}]);
  s.google.person('bob-grant','bob-sub','bob@example.com','bob-refresh');
  await s.signIn('bob-grant',device('phone-bob-0001'));
  const response=await get(`/app/api/calendar?from=${START}&to=${START+DAY}`);
  assert.equal(response.status,200);const body=await response.json();
  assert.equal(body.events.length,1);assert.equal(body.events[0].title,'A private meeting');assert.equal(body.events[0].email,'ann@example.com');
  assert.deepEqual(body.unavailable,[]);assert.equal(response.headers.get('cache-control'),'no-store');
  assert.deepEqual(s.google.listCalls.map(c=>c.calendarId),['ann-cal']);
  assert.equal(await s.count('event_state'),0);
  assert.equal((await s.db.first('SELECT account_id FROM google_links WHERE sub = ?', 'ann-sub')).account_id,who.account.id);
});

test('web: Google identity and moved occurrence fields survive the real agenda request', async () => {
  const {s,get}=await fixture();
  s.google.person('ann-grant','ann-sub','ann@example.com','ann-refresh');
  await s.signIn('ann-grant',device('phone-ann-0001'));
  s.google.calendars.set('ann-refresh',[{id:'ann-cal',summary:'Personal',primary:true,accessRole:'owner'}]);
  const base={summary:'Same title',start:{dateTime:new Date(START).toISOString()},end:{dateTime:new Date(START+3_600_000).toISOString()}};
  s.google.events.set('ann-cal',[
    {...base,id:'one',iCalUID:'one'}, {...base,id:'copy',iCalUID:'one',summary:'Renamed invitation'},
    {...base,id:'unrelated',iCalUID:'two'},
    ...[1,2].map(day=>({...base,id:`moved-${day}`,iCalUID:'series',recurringEventId:'series',
      originalStartTime:{dateTime:new Date(START-day*DAY).toISOString()}})),
  ]);
  const list=s.google.listEvents.bind(s.google);
  s.google.listEvents=async(access,id,params)=>{
    // Google omits fields outside the requested mask; the usual fake returns everything.
    const result=await list(access,id,params);
    const names=new Set(params.fields.match(/[A-Za-z]+/g));
    return {...result,events:result.events.map(e=>Object.fromEntries(Object.entries(e).filter(([key])=>names.has(key))))};
  };
  const response=await get(`/app/api/calendar?from=${START}&to=${START+DAY}`);
  assert.equal(response.status,200);
  const body=await response.json();
  assert.equal(body.events.length,4,'one invitation copy folds; unrelated and moved instances remain');
  const request=s.google.listCalls.at(-1);
  for(const field of ['iCalUID','originalStartTime','organizer','attachments'])
    assert.match(request.fields,new RegExp(`\\b${field}\\b`),`Google must return ${field}`);
});

test('web: agenda reports missing connections and bounds its time range',async()=>{
  const {s,get}=await fixture();
  const body=await(await get(`/app/api/calendar?from=${START}&to=${START+DAY}`)).json();
  assert.deepEqual(body.events,[]);assert.deepEqual(body.unavailable,[{email:'ann@example.com',reason:'reconnect'}]);
  for(const query of ['',`from=${START}&to=${START+9*DAY}`,`from=${START}&to=${START-1}`,`from=oops&to=${START}`,`from=${START+400*DAY}&to=${START+401*DAY}`]) {
    assert.equal((await get(`/app/api/calendar?${query}`)).status,400);
  }
  assert.equal((await s.app.request(`/app/api/calendar?from=${START}&to=${START+DAY}`)).status,401);
});

test('app domain: root and legacy redirects, browser-bound one-time handoff, cookie isolation and logout origin',async()=>{
  const s=setup({config:{publicUrl:'https://api.service.test',webUrl:'https://app.service.test'}});
  s.google.person('ann','ann-sub','ann@example.com',null);await s.signIn('ann',device('phone-ann-domain'));
  const root=await s.app.request('https://app.service.test/');assert.equal(root.status,200);assert.match(await root.text(),/name="app-home" content="\/"/);
  assert.equal((await s.app.request('https://api.service.test/app/')).headers.get('location'),'https://app.service.test/');
  assert.equal((await s.app.request('https://api.service.test/')).status,404);
  const page=await(await s.app.request('https://app.service.test/')).text();assert.doesNotMatch(page,/YOUR BANANA|YOUR SPACE, ON THE WEB/);
  async function handoff(){
    const start=await s.app.request('https://app.service.test/app/auth/google');
    const appNonce=start.headers.get('set-cookie').split(';')[0];
    const atApi=await s.app.request(start.headers.get('location'));
    const apiNonce=atApi.headers.get('set-cookie').split(';')[0],google=new URL(atApi.headers.get('location'));
    assert.equal(google.searchParams.get('redirect_uri'),'https://api.service.test/v1/google/callback');
    const callback=await s.app.request(`https://api.service.test/v1/google/callback?${new URLSearchParams({state:google.searchParams.get('state'),code:'ann'})}`,{headers:{cookie:apiNonce}});
    return {url:callback.headers.get('location'),appNonce};
  }
  const flow=await handoff();assert.ok(flow.url.startsWith('https://app.service.test/app/auth/complete?code='));
  assert.equal(await s.count('sessions',"kind = 'web'"),0);
  const stolen=await s.app.request(flow.url);assert.match(stolen.headers.get('location'),/error=expired/,'a handoff from another browser cannot sign you in');
  const finish=await s.app.request(flow.url,{headers:{cookie:flow.appNonce}});assert.equal(finish.headers.get('location'),'https://app.service.test/');
  const cookie=finish.headers.getSetCookie().find(c=>c.startsWith('__Host-banana-web=')).split(';')[0];
  const replay=await s.app.request(flow.url,{headers:{cookie:flow.appNonce}});assert.match(replay.headers.get('location'),/error=expired/);
  assert.equal((await s.app.request('https://app.service.test/app/api/account',{headers:{cookie}})).status,200);
  assert.equal((await s.app.request('https://app.service.test/app/auth/logout',{method:'POST',headers:{cookie,origin:'https://api.service.test'}})).status,403);
  assert.equal((await s.app.request('https://app.service.test/app/auth/logout',{method:'POST',headers:{cookie,origin:'https://app.service.test'}})).status,204);
  const expired=await handoff();s.advance(61_000);assert.match((await s.app.request(expired.url,{headers:{cookie:expired.appNonce}})).headers.get('location'),/error=expired/);
});


test('web: calendar controls patch the synced native snapshot atomically and notify every device', async () => {
  const {s, get, put, auth, space} = await fixture();
  s.google.person('ann-grant','ann-sub','ann@example.com','ann-refresh');
  await s.signIn('ann-grant',device('phone-ann-0001'));
  const choices = await (await get('/app/api/calendars')).json();
  const id = choices.accounts[0].calendars[0].id;
  assert.equal(choices.ready, false);
  const edit = (body, origin='https://service.test', cookie=auth.cookie) => s.app.request('/app/api/calendars', {
    method:'PUT', headers:{cookie,Origin:origin,'Content-Type':'application/json'},body:JSON.stringify(body)});
  const change = {calendarID:id, preference:'notifications', enabled:false};
  assert.equal((await edit(change)).status,409);
  await put('core.smartSettings','smart-settings',{v:{updatedAt:1,calendarIDsAreGoogle:true,excludedCalendars:[],
    settings:{weekStartWeekday:1,mutedCalendarIDs:[],excludedCalendarIDs:[],futureSetting:{keep:true}}}});
  assert.equal((await edit(change,'https://evil.test')).status,403);
  assert.equal((await edit(change,'https://service.test','')).status,401);
  assert.equal((await edit({...change,calendarID:'someone-else'})).status,404);
  assert.equal((await edit({...change,preference:'futureSetting'})).status,400);
  assert.equal((await edit(change)).status,200);
  assert.equal((await edit({calendarID:id,preference:'included',enabled:false})).status,200);
  let record=await s.deps.spaces.get(space).read('core.smartSettings','smart-settings');
  assert.deepEqual(record.v.settings.mutedCalendarIDs,[id]);
  assert.equal(record.v.settings.excludedCalendarIDs.length,1);
  assert.equal(record.v.settings.weekStartWeekday,1);
  assert.deepEqual(record.v.settings.futureSetting,{keep:true});
  assert.ok(record.v.updatedAt>1);
  assert.equal((await edit({calendarID:id,preference:'included',enabled:true})).status,200);
  record=await s.deps.spaces.get(space).read('core.smartSettings','smart-settings');
  assert.deepEqual(record.v.settings.excludedCalendarIDs,[]);
  assert.deepEqual(record.v.settings.mutedCalendarIDs,[id], 'Re-enabling must preserve a mute');
  const native=await s.deps.spaces.get(space).sync({platform:'mac',device:'other',now:s.now(),since:0});
  assert.deepEqual(native.answer.changes.find(r=>r.type==='core.smartSettings').fields.v,record.v);
  const result=await (await get('/app/api/calendars')).json();
  assert.equal(result.accounts[0].calendars[0].included,true);
  assert.equal(result.accounts[0].calendars[0].notifications,false);
});


test('calendar choices apply to booking availability too; muting does not change busy time', async () => {
  const {s,who}=await fixture();
  s.google.person('ann-grant','ann-sub','ann@example.com','ann-refresh');
  await s.signIn('ann-grant',device('phone-ann-0001'));
  s.google.calendars.set('ann-refresh',[{id:'mine',summary:'Personal'},{id:'wife',summary:'Family'}]);
  for(const id of ['mine','wife']) s.google.events.set(id,[{id:'event',start:{dateTime:new Date(s.now()+3600000).toISOString()},end:{dateTime:new Date(s.now()+7200000).toISOString()}}]);
  const vault=createVault(s.deps.config.tokenKey,s.deps.random);
  const read=settings=>readBusy(s.deps,vault,who.account.id,{from:s.now(),to:s.now()+DAY,settings:{v:settings}});
  const muted=await read({calendarIDsAreGoogle:true,settings:{mutedCalendarIDs:['wife']}});
  assert.deepEqual(muted.calendars.map(c=>c.id).sort(),['mine','wife']);assert.equal(muted.busy.length,2);
  const excluded=await read({calendarIDsAreGoogle:true,settings:{excludedCalendarIDs:[calendarInfoID('wife')]}});
  assert.deepEqual(excluded.calendars.map(c=>c.id),['mine']);assert.equal(excluded.busy.length,1);
  const names=[{sourceTitle:'ann@example.com',calendarTitle:'Family'}];
  assert.equal((await read({calendarIDsAreGoogle:true,excludedCalendars:names,settings:{excludedCalendarIDs:[]}})).calendars.length,2,'Stale legacy names cannot undo re-enabling');
  assert.equal((await read({excludedCalendars:names})).calendars.length,1,'Legacy snapshots still migrate by name');
});
