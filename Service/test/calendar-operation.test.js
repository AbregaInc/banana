import test from 'node:test';
import assert from 'node:assert/strict';
import {setup,device} from './helpers.js';
import {parseCalendarOperation} from '../src/calendar-operation.js';
const id='10000000-0000-4000-8000-000000000001';
const request=(extra={})=>({operationID:id,email:'noor@plan.example',calendarID:'work',action:'insert',body:{summary:'Review',start:{date:'2026-11-05'},end:{date:'2026-11-06'}},query:[],...extra});
async function signed(s,grant=true,name='noor') {
 s.google.person('code-'+name,'sub-'+name,name+'@plan.example');
 const a=(await s.signIn('code-'+name,device('device-'+name))).json;
 if(grant)await s.db.run('INSERT INTO feature_access VALUES (?,?,1,NULL,?)',a.account.id,'calendarCloud',s.now());
 return a;
}
const call=(s,a,r=request())=>s.call('POST','/v1/calendar/operation',{session:a?.session,body:r});
test('operations require signed account, eligibility and that account linked write grant',async()=>{
 const s=setup(),a=await signed(s,false),b=await signed(s,true,'other');let writes=0;
 s.google.calendarMutation=async()=>{writes++;return {status:200,body:{}};};
 assert.equal((await call(s,null)).status,401);assert.equal((await call(s,a)).status,403);
 assert.equal((await call(s,b)).status,403);assert.equal(writes,0);
});
test('request shape rejects unsupported operations, host injection fields, invalid IDs and unsafe headers',()=>{
 for(const extra of [{action:'arbitrary'},{operationID:'not-an-id'},{query:[{name:'access_token',value:'secret'}]},
  {ifMatch:'etag\r\nAuthorization: x'},{body:{id:'BAD-ID'}},{body:{extendedProperties:{private:'wrong'}}}])assert.equal(parseCalendarOperation(request(extra)),null);
 assert.equal(parseCalendarOperation({...request(),url:'https://evil.example'}).url,undefined);
});
test('intent is durable before dispatch and same identity returns one encrypted receipt',async()=>{
 const s=setup(),a=await signed(s);let writes=0;
 s.google.calendarMutation=async(token,r)=>{
  const row=await s.db.first('SELECT * FROM provider_operations WHERE operation_id=?',id);
  assert.equal(row.state,'running');assert.equal(row.request_cipher.includes('Review'),false);
  writes++;return {status:200,body:{...r.body,etag:'accepted'}};
 };
 const first=await call(s,a),again=await call(s,a);
 assert.equal(first.status,200);assert.deepEqual(again.json,first.json);assert.equal(writes,1);
 assert.equal(first.json.id,id.replaceAll('-',''));
 assert.equal((await call(s,a,request({body:{summary:'Changed'}}))).status,409);
 assert.equal(writes,1);
});
test('lost insert acknowledgement reconciles by marker without another mutation',async()=>{
 const s=setup(),a=await signed(s);let writes=0,event;
 s.google.calendarMutation=async(token,r)=>{writes++;event=structuredClone(r.body);throw new Error('response lost');};
 s.google.getEvent=async()=>event;
 assert.equal((await call(s,a)).status,502);
 const retried=await call(s,a);assert.equal(retried.status,200);assert.equal(retried.json.id,event.id);assert.equal(writes,1);
});
test('unknown and expired in-flight moves never blindly replay',async()=>{
 const s=setup(),a=await signed(s);let writes=0;
 s.google.calendarMutation=async()=>{writes++;throw new Error('network');};
 s.google.getEvent=async()=>({id:'event',etag:'original',iCalUID:'uid'});
 const move=request({action:'move',eventID:'event',destination:'other',body:null});
 assert.equal((await call(s,a,move)).status,502);assert.equal((await call(s,a,move)).status,409);assert.equal(writes,1);
 await s.db.run("UPDATE provider_operations SET state='running',lease_until=?",s.now()-1);
 assert.equal((await call(s,a,move)).status,409);assert.equal(writes,1);
});
test('concurrent dispatch claims a single operation and revocation blocks retries',async()=>{
 const s=setup(),a=await signed(s);let writes=0,release;
 const gate=new Promise(r=>release=r);let started;const ready=new Promise(r=>started=r);
 s.google.calendarMutation=async(token,r)=>{writes++;started();await gate;return {status:200,body:r.body};};
 const first=call(s,a);await ready;
 assert.equal((await call(s,a)).status,409);release();assert.equal((await first).status,200);
 await s.db.run('UPDATE feature_access SET enabled=0 WHERE account_id=?',a.account.id);
 assert.equal((await call(s,a)).status,403);assert.equal(writes,1);
});
test('delete absence after a lost acknowledgement confirms completion without repeating delete',async()=>{
 const s=setup(),a=await signed(s);let writes=0;
 let deleted=false;
 s.google.calendarMutation=async()=>{writes++;deleted=true;throw new Error('lost');};
 s.google.getEvent=async()=>deleted?null:{id:'event1',etag:'original'};
 const r=request({action:'delete',eventID:'event1',body:null});
 assert.equal((await call(s,a,r)).status,502);assert.equal((await call(s,a,r)).status,204);assert.equal(writes,1);
});

test('an uncertain event mutation fences later operations on the same event',async()=>{
 const s=setup(),a=await signed(s);let writes=0;
 s.google.calendarMutation=async()=>{writes++;throw new Error('lost');};s.google.getEvent=async()=>({id:'event1',etag:'original'});
 const first=request({action:'patch',eventID:'event1',body:{summary:'First'}});
 assert.equal((await call(s,a,first)).status,502);
 const later=request({operationID:'20000000-0000-4000-8000-000000000002',action:'patch',eventID:'event1',body:{summary:'Later'}});
 assert.equal((await call(s,a,later)).status,409);assert.equal(writes,1);
 assert.equal((await s.db.first('SELECT state FROM provider_operations WHERE operation_id=?',later.operationID)).state,'pending');
});

test('a registered legacy client prevents cutover and cannot silently rejoin a cloud writer account',async()=>{
 const s=setup(),a=await signed(s);let writes=0;
 s.google.calendarMutation=async(token,r)=>{writes++;return {status:200,body:r.body};};
 await s.call('PUT','/v1/devices/legacy-device',{session:a.session,body:device('legacy-device',{providerProtocol:0})});
 assert.equal((await call(s,a)).status,403);
 assert.deepEqual((await s.call('GET','/v1/account',{session:a.session})).json.featureAccess.enabled,[]);
 await s.call('PUT','/v1/devices/legacy-device',{session:a.session,body:device('legacy-device',{providerProtocol:1})});
 assert.equal((await call(s,a)).status,200);assert.equal(writes,1);
});

test('retry of an unacknowledged patch keeps its original conditional version',async()=>{
 const s=setup(),a=await signed(s);let writes=0;
 s.google.getEvent=async()=>({id:'event1',etag:'original'});
 s.google.calendarMutation=async(token,r)=>{
  assert.equal(r.ifMatch,'original');writes++;
  if(writes===1)throw new Error('connection lost before write');
  return {status:200,body:{id:'event1',...r.body,etag:'updated'}};
 };
 const r=request({action:'patch',eventID:'event1',body:{summary:'Updated'}});
 assert.equal((await call(s,a,r)).status,502);
 assert.equal((await call(s,a,r)).status,200);
 assert.equal(writes,2);
});

test('uncertain patch does not overwrite a subsequent external edit',async()=>{
 const s=setup(),a=await signed(s);let writes=0,etag='original';
 s.google.getEvent=async()=>({id:'event1',etag});
 s.google.calendarMutation=async()=>{writes++;etag='external-edit';throw new Error('lost');};
 const r=request({action:'patch',eventID:'event1',body:{summary:'Updated'}});
 assert.equal((await call(s,a,r)).status,502);
 assert.equal((await call(s,a,r)).status,412);
 assert.equal(writes,1);
});

test('lost move acknowledgement is recovered only from a unique destination UID match',async()=>{
 const s=setup(),a=await signed(s);let moved=false,writes=0;
 s.google.getEvent=async()=>moved?null:{id:'event1',etag:'original',iCalUID:'shared-uid'};
 s.google.calendarMutation=async()=>{writes++;moved=true;throw new Error('lost');};
 s.google.calendarRead=async(token,r)=>{
  assert.equal(r.calendarID,'destination');
  assert.deepEqual(r.query,[{name:'iCalUID',value:'shared-uid'},{name:'maxResults',value:'2'}]);
  return {status:200,body:{items:[{id:'moved-event',iCalUID:'shared-uid'}]}};
 };
 const r=request({action:'move',eventID:'event1',destination:'destination',body:null});
 assert.equal((await call(s,a,r)).status,502);
 const result=await call(s,a,r);
 assert.equal(result.status,200);assert.equal(result.json.id,'moved-event');assert.equal(writes,1);
});
