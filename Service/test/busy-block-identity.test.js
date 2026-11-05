import test from 'node:test';
import assert from 'node:assert/strict';
import {setup,device} from './helpers.js';
const op=n=>`${String(n).padStart(8,'0')}-0000-4000-8000-000000000001`;
const body={summary:'Busy',start:{date:'2026-11-05'},end:{date:'2026-11-06'},extendedProperties:{private:{bananaItemID:'task-1',bananaVariant:'banana'}}};
async function fixture() {
 const s=setup();s.google.person('code','sub','noor@plan.example');
 const a=(await s.signIn('code',device('device-phone'))).json;
 await s.db.run('INSERT INTO feature_access VALUES (?,?,1,NULL,?)',a.account.id,'calendarCloud',s.now());
 const events=new Map();let writes=0;
 s.google.calendarRead=async()=>({status:200,body:{items:[...events.values()]}});
 s.google.getEvent=async(token,calendar,id)=>events.get(id)??null;
 s.google.calendarMutation=async(token,r)=>{
  if(r.ifMatch&&events.get(r.eventID)?.etag!==r.ifMatch)return {status:412,body:{error:{message:'Changed'}}};
  writes++;
  if(r.action==='delete'){events.delete(r.eventID);return {status:204,body:null};}
  const event={...r.body,id:r.body.id??r.eventID,etag:'etag-'+writes};events.set(event.id,event);
  return {status:200,body:event};
 };
 const call=(n,extra={})=>s.call('POST','/v1/calendar/operation',{session:a.session,body:{operationID:op(n),email:'noor@plan.example',calendarID:'work',action:'insert',body:structuredClone(body),query:[],...(extra.eventID?{ifMatch:events.get(extra.eventID)?.etag??'deleted-version'}:{}),...extra}});
 return {s,a,events,call,writes:()=>writes};
}
test('two device operation identities create only one logical busy block',async()=>{
 const f=await fixture();const first=await f.call(1);assert.equal(first.status,200);
 assert.equal((await f.call(2)).status,409);assert.equal(f.writes(),1);assert.equal(f.events.size,1);
 const row=await f.s.db.first('SELECT * FROM busy_block_identities');
 assert.equal(row.established,1);assert.equal(JSON.stringify(row).includes('task-1'),false);
 assert.equal(row.event_cipher.includes(first.json.id),false);
});
test('concurrent inserts are serialized even with distinct operation IDs',async()=>{
 const f=await fixture();let release,started;const wait=new Promise(r=>release=r),ready=new Promise(r=>started=r);
 const original=f.s.google.calendarMutation;f.s.google.calendarMutation=async(...args)=>{started();await wait;return original(...args);};
 const first=f.call(1);await ready;
 assert.equal((await f.call(2)).status,409);release();assert.equal((await first).status,200);
 assert.equal((await f.call(2)).status,409);assert.equal(f.writes(),1);
});
test('lost acknowledgement reconciles without repeating an insert',async()=>{
 const f=await fixture();const original=f.s.google.calendarMutation;
 f.s.google.calendarMutation=async(...args)=>{await original(...args);throw new Error('lost');};
 assert.equal((await f.call(1)).status,502);assert.equal((await f.call(1)).status,200);
 assert.equal((await f.call(2)).status,409);assert.equal(f.writes(),1);
});
test('temporarily missing provider read cannot trigger a second insertion',async()=>{
 const f=await fixture();const original=f.s.google.calendarMutation;
 f.s.google.calendarMutation=async(...args)=>{await original(...args);throw new Error('lost');};
 assert.equal((await f.call(1)).status,502);
 const read=f.s.google.getEvent;f.s.google.getEvent=async()=>null;
 assert.equal((await f.call(1)).status,409);assert.equal((await f.call(2)).status,409);assert.equal(f.writes(),1);
 f.s.google.getEvent=read;assert.equal((await f.call(1)).status,200);
});
test('known identity survives an empty read after successful insertion',async()=>{
 const f=await fixture();assert.equal((await f.call(1)).status,200);
 f.s.google.getEvent=async()=>null;f.s.google.calendarRead=async()=>({status:200,body:{items:[]}});
 assert.equal((await f.call(2)).status,409);assert.equal(f.writes(),1);
});
test('explicit completed deletion allows a fresh provider generation',async()=>{
 const f=await fixture();const first=await f.call(1);
 assert.equal((await f.call(2,{action:'delete',eventID:first.json.id,body:null})).status,204);
 const next=await f.call(3);assert.equal(next.status,200);assert.notEqual(next.json.id,first.json.id);
 assert.equal(f.events.size,1);assert.equal(f.writes(),3);
});
test('Google tombstone allows recreation without reusing the deleted event ID',async()=>{
 const f=await fixture();const first=await f.call(1);f.events.set(first.json.id,{id:first.json.id,status:'cancelled'});
 const next=await f.call(2);assert.equal(next.status,200);assert.notEqual(next.json.id,first.json.id);
});
test('legacy blocks are adopted without another insertion and incomplete reads fail closed',async()=>{
 const f=await fixture();f.events.set('legacy',{...structuredClone(body),id:'legacy',etag:'old'});
 assert.equal((await f.call(1)).status,409);assert.equal(f.writes(),0);
 const g=await fixture();g.s.google.calendarRead=async()=>({status:200,body:{items:[],nextPageToken:'more'}});
 assert.equal((await g.call(1)).status,502);assert.equal(g.writes(),0);
});
test('an uncertain deletion fences recreation of the same logical block',async()=>{
 const f=await fixture();const first=await f.call(1);const original=f.s.google.calendarMutation;
 f.s.google.calendarMutation=async(...args)=>{await original(...args);throw new Error('lost');};
 const deletion={action:'delete',eventID:first.json.id,body:null,ifMatch:first.json.etag};
 assert.equal((await f.call(2,deletion)).status,502);assert.equal((await f.call(3)).status,409);
 assert.equal((await f.call(2,deletion)).status,204);
 f.s.google.calendarMutation=original;assert.equal((await f.call(3)).status,200);assert.equal(f.events.size,1);
});
test('definitive refusal releases only the reserved generation',async()=>{
 const f=await fixture();const original=f.s.google.calendarMutation;
 f.s.google.calendarMutation=async()=>({status:403,body:{error:{message:'refused'}}});
 assert.equal((await f.call(1)).status,403);
 f.s.google.calendarMutation=original;assert.equal((await f.call(2)).status,200);
 // Replaying the old refusal must not retire the newly established block.
 assert.equal((await f.call(1)).status,403);assert.equal((await f.call(3)).status,409);assert.equal(f.writes(),1);
});
test('a removed ownership marker prevents patching or deleting a formerly owned event',async()=>{
 const f=await fixture();const first=await f.call(1);
 f.events.set(first.json.id,{id:first.json.id,etag:'external',summary:'Foreign now'});
 assert.equal((await f.call(2,{action:'delete',eventID:first.json.id,body:null})).status,409);
 assert.equal((await f.call(3,{action:'patch',eventID:first.json.id})).status,409);
 assert.equal(f.writes(),1);
});
test('a different logical item cannot take over an established busy identity',async()=>{
 const f=await fixture();const first=await f.call(1);const changed=structuredClone(body);
 changed.extendedProperties.private.bananaItemID='other-task';
 assert.equal((await f.call(2,{action:'patch',eventID:first.json.id,body:changed})).status,409);
 assert.equal(f.writes(),1);
});
test('stale device versions cannot overwrite or delete a newer busy block',async()=>{
 const f=await fixture();const first=await f.call(1);const current=f.events.get(first.json.id);
 f.events.set(first.json.id,{...current,summary:'Newer',etag:'new-version'});
 assert.equal((await f.call(2,{action:'patch',eventID:first.json.id,ifMatch:first.json.etag})).status,412);
 assert.equal((await f.call(3,{action:'delete',eventID:first.json.id,body:null,ifMatch:first.json.etag})).status,412);
 assert.equal(f.events.get(first.json.id).summary,'Newer');assert.equal(f.writes(),1);
});
test('a client without an observed version cannot mutate a service-owned busy block',async()=>{
 const f=await fixture();const first=await f.call(1);
 assert.equal((await f.call(2,{action:'delete',eventID:first.json.id,body:null,ifMatch:null})).status,428);
 assert.equal(f.writes(),1);
});
test('an expired preparer cannot replace the identity reserved by its successor',async()=>{
 const f=await fixture();let started,release,reads=0;
 const ready=new Promise(r=>started=r),wait=new Promise(r=>release=r);
 f.s.google.calendarRead=async()=>{if(++reads===1){started();await wait;}return {status:200,body:{items:[]}};};
 const old=f.call(1);await ready;
 await f.s.db.run("UPDATE provider_operations SET lease_until=? WHERE operation_id=?",f.s.now()-1,op(1));
 const current=await f.call(1);assert.equal(current.status,200);
 release();assert.equal((await old).status,502);
 assert.equal((await f.call(2)).status,409);assert.equal(f.writes(),1);assert.equal(f.events.size,1);
 const row=await f.s.db.first('SELECT established FROM busy_block_identities');assert.equal(row.established,1);
});
test('patches cannot strip the ownership marker using null or partial properties',async()=>{
 const f=await fixture();const first=await f.call(1);
 for(const [i,extendedProperties] of [null,{private:null},{private:{bananaItemID:null}},{private:{bananaVariant:'other'}}].entries()) {
  assert.equal((await f.call(i+2,{action:'patch',eventID:first.json.id,body:{extendedProperties}})).status,409);
 }
 assert.equal(f.writes(),1);
});
test('account deletion removes the encrypted provider identity',async()=>{
 const f=await fixture();assert.equal((await f.call(1)).status,200);
 f.s.google.person('delete-code','sub','noor@plan.example');
 assert.equal((await f.s.call('DELETE','/v1/account',{session:f.a.session,body:{code:'delete-code'}})).status,204);
 assert.equal((await f.s.db.first('SELECT count(*) AS n FROM busy_block_identities')).n,0);
});
