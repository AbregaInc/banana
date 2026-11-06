import test from 'node:test';
import assert from 'node:assert/strict';
import {setup,device} from './helpers.js';
import {mailReadUnits,reserveMailRead} from '../src/mail-read-pacing.js';
const read=(resource='thread',format='full')=>({resource,query:format?[{name:'format',value:format}]:[]});
async function identity(s,name='noor') {
 s.google.person(name,'sub-'+name,name+'@plan.example');
 await s.signIn(name,device('device-'+name));
 return 'sub-'+name;
}
test('read costs cover current Gmail metadata, body and default formats',()=>{
 for(const [resource,cost] of Object.entries({profile:1,labels:1,history:2,messages:5,drafts:5,attachment:20,message:60,draft:60,thread:120}))assert.equal(mailReadUnits(read(resource,null)),cost);
 for(const resource of ['message','draft']) {
  for(const format of ['minimal','metadata'])assert.equal(mailReadUnits(read(resource,format)),20);
  for(const format of ['full','raw','html'])assert.equal(mailReadUnits(read(resource,format)),60);
 }
 assert.equal(mailReadUnits(read('thread','metadata')),40);
 assert.throws(()=>mailReadUnits(read('unsupported')));
});
test('concurrent devices share atomic weighted slots and rejected work does not extend the queue',async()=>{
 const s=setup(),sub=await identity(s);
 const reservations=await Promise.all(Array.from({length:12},()=>reserveMailRead({...s.deps},sub,read())));
 assert.deepEqual(reservations.filter(Boolean).map(x=>x.waitMS).sort((a,b)=>a-b),[0,1600,3200,4800,6400,8000,9600]);
 assert.equal(reservations.filter(x=>x===null).length,5);
 const before=await s.db.first('SELECT next_at FROM mail_read_pacing WHERE google_sub=?',sub);
 assert.equal(await reserveMailRead(s.deps,sub,read()),null);
 assert.deepEqual(await s.db.first('SELECT next_at FROM mail_read_pacing WHERE google_sub=?',sub),before);
 s.advance(60_000);
 assert.deepEqual(await reserveMailRead(s.deps,sub,read()),{waitMS:0});
});
test('identities are independent and idle time cannot accumulate a burst allowance',async()=>{
 const s=setup(),a=await identity(s),b=await identity(s,'other');
 await reserveMailRead(s.deps,a,read());
 assert.deepEqual(await reserveMailRead(s.deps,b,read()),{waitMS:0});
 s.advance(3600_000);
 assert.deepEqual(await reserveMailRead(s.deps,a,read()),{waitMS:0});
 assert.deepEqual(await reserveMailRead(s.deps,a,read()),{waitMS:1600});
});
