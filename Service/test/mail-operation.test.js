import test from 'node:test';
import assert from 'node:assert/strict';
import {setup,device} from './helpers.js';
const operationID='10000000-0000-4000-8000-000000000001';
async function ready(s) {
 s.google.person('sign-in','sub-noor','noor@plan.example','refresh',{scopes:'https://www.googleapis.com/auth/gmail.modify'});
 const a=(await s.signIn('sign-in',device('device-noor'))).json;
 await s.db.run('INSERT INTO feature_access VALUES (?,?,1,NULL,?)',a.account.id,'email',s.now());
 return a;
}
const call=(s,a,extra={})=>s.call('POST','/v1/mail/operation',{session:a.session,body:{operationID,email:'noor@plan.example',id:'message',action:'modify',add:['STARRED'],remove:['UNREAD'],...extra}});
test('Mail changes are journaled and a lost response is reconciled without repeating a mutation',async()=>{
 const s=setup(),a=await ready(s);let labels=['UNREAD'],writes=0;
 s.google.mailMessage=async()=>({id:'message',labelIds:labels,historyId:'10'});
 s.google.mailMutation=async(token,r)=>{
  assert.equal((await s.db.first('SELECT state FROM provider_operations')).state,'running');
  writes++;labels=['STARRED'];throw new Error('response lost');
 };
 assert.equal((await call(s,a)).status,502);
 const recovered=await call(s,a);assert.equal(recovered.status,200);assert.deepEqual(recovered.json.labelIds,['STARRED']);assert.equal(writes,1);
 assert.equal((await call(s,a)).status,200);assert.equal(writes,1);
});
test('already-satisfied Mail intent needs no provider mutation',async()=>{
 const s=setup(),a=await ready(s);let writes=0;
 s.google.mailMessage=async()=>({id:'message',labelIds:['STARRED'],historyId:'10'});
 s.google.mailMutation=async()=>{writes++;};
 assert.equal((await call(s,a)).status,200);assert.equal(writes,0);
});
test('unknown Mail outcome blocks later writes on that message and revocation blocks recovery',async()=>{
 const s=setup(),a=await ready(s);let writes=0;
 s.google.mailMessage=async()=>({id:'message',labelIds:['UNREAD'],historyId:'10'});
 s.google.mailMutation=async()=>{writes++;throw new Error('network');};
 assert.equal((await call(s,a)).status,502);
 assert.equal((await call(s,a,{operationID:'20000000-0000-4000-8000-000000000002',add:[],remove:['STARRED']})).status,409);
 assert.equal(writes,1);
 await s.db.run('UPDATE feature_access SET enabled=0');
 assert.equal((await call(s,a)).status,403);
});
test('mail access never authorizes arbitrary provider sends or another linked account',async()=>{
 const s=setup(),a=await ready(s);
 assert.equal((await call(s,a,{action:'send'})).status,400);
 assert.equal((await call(s,a,{email:'other@plan.example'})).status,403);
 assert.equal((await call(s,a,{add:['UNREAD'],remove:['UNREAD']})).status,400);
});
