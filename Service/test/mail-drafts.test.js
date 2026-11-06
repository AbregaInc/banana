import test from 'node:test';
import assert from 'node:assert/strict';
import {setup,device} from './helpers.js';
import {createVault} from '../src/crypto.js';
const first='10000000-0000-4000-8000-000000000001',second='20000000-0000-4000-8000-000000000002',third='30000000-0000-4000-8000-000000000003';
const content=()=>({from:{address:'noor@plan.example',name:'Noor'},to:[{address:'reader@plan.example'}],cc:[],bcc:[],subject:'Private draft',plain:'Private body',html:'<p>Private body</p>',attachments:[]});
async function ready(){
 const s=setup();s.google.person('signin','sub-noor','noor@plan.example','refresh',{scopes:'https://www.googleapis.com/auth/gmail.modify'});
 const a=(await s.signIn('signin',device('device-noor'))).json;
 await s.db.run('INSERT INTO feature_access VALUES (?,?,1,NULL,?)',a.account.id,'email',s.now());
 const call=(action,extra={})=>s.call('POST','/v1/mail/draft',{session:a.session,body:{email:'noor@plan.example',operationID:first,action,...extra}});
 let writes=0,sends=0,deletes=0;const drafts=new Map(),sent=new Map();
 s.google.mailDraftUpload=async(token,action,metadata,mime)=>{
  const raw=await new Response(mime).text();writes++;
  const id=action==='create'?'gmail-draft':metadata.id;
  const draft={id,message:{id:`message-${writes}`,threadId:'thread',labelIds:['DRAFT'],payload:{headers:[{name:'Message-ID',value:raw.match(/Message-ID:\s*(<[^>]+>)/)[1]}]}},snapshot:{raw}};
  drafts.set(id,draft);return {status:200,body:structuredClone(draft)};
 };
 s.google.mailDraftGet=async(token,id)=>structuredClone(drafts.get(id)??null);
 s.google.mailFindDraft=async(token,messageID)=>{const d=[...drafts.values()].filter(x=>x.message.payload.headers[0].value===messageID);return d.length===1?{status:200,body:structuredClone(d[0])}:null;};
 s.google.mailDraftSend=async(token,id)=>{sends++;const d=drafts.get(id);if(!d)return {status:404,body:{error:'missing'}};drafts.delete(id);const message={id:'sent-message',threadId:'thread',labelIds:['SENT']};sent.set(d.message.payload.headers[0].value,message);return {status:200,body:message};};
 s.google.mailDraftDelete=async(token,id)=>{deletes++;drafts.delete(id);return {status:200,body:{deleted:true}};};
 s.google.mailFindSent=async(token,id)=>sent.has(id)?{status:200,body:sent.get(id)}:null;
 return {s,a,call,drafts,sent,counts:()=>({writes,sends,deletes})};
}
const create=t=>t.call('create',{content:content()});
const edit=(t,extra={})=>t.call('update',{operationID:second,id:'gmail-draft',expectedMessageID:'message-1',content:{...content(),plain:'Edited'},...extra});
test('save creates a real Gmail draft immediately; acknowledged content is not a Banana draft store',async()=>{
 const t=await ready();const r=await create(t);assert.equal(r.status,200);assert.equal(r.json.id,'gmail-draft');
 assert.match(t.drafts.get('gmail-draft').snapshot.raw,/Private body/);
 assert.equal((await t.s.db.first('SELECT count(*) AS n FROM mail_drafts')).n,0);
 const row=await t.s.db.first('SELECT * FROM provider_operations');
 const vault=createVault(t.s.deps.config.tokenKey,t.s.deps.random);
 assert.equal(JSON.parse(await vault.open('provider-operation:'+t.a.account.id,row.request_cipher)).content,undefined);
 assert.equal(r.json.snapshot,undefined);assert.equal(r.json.message.payload,undefined);
 assert.equal((await create(t)).status,200);assert.equal(t.counts().writes,1);
});
test('two devices updating one observed Gmail revision cannot overwrite each other',async()=>{
 const t=await ready();await create(t);
 const results=await Promise.all([edit(t),edit(t,{operationID:third,content:{...content(),plain:'Other device'}})]);
 assert.equal(results.filter(x=>x.status===200).length,1);assert.equal(results.filter(x=>x.status===409).length,1);assert.equal(t.counts().writes,2);
 const loser=results[0].status===409?{}:{operationID:third,content:{...content(),plain:'Other device'}};
 assert.equal((await edit(t,loser)).status,409);
 assert.equal(t.counts().writes,2);
});
test('external Gmail edit is detected before dispatch and failed local content stays recoverable',async()=>{
 const t=await ready();await create(t);t.drafts.get('gmail-draft').message.id='external-version';
 assert.equal((await edit(t)).status,409);assert.equal(t.counts().writes,1);
 const row=await t.s.db.first('SELECT request_cipher FROM provider_operations WHERE operation_id=?',second);
 const vault=createVault(t.s.deps.config.tokenKey,t.s.deps.random);
 assert.equal(JSON.parse(await vault.open('provider-operation:'+t.a.account.id,row.request_cipher)).content.plain,'Edited');
});
test('lost create and update replies reconcile through Gmail without writing another copy',async()=>{
 const t=await ready();const upload=t.s.google.mailDraftUpload;
 t.s.google.mailDraftUpload=async(...args)=>{await upload(...args);throw new Error('lost acknowledgement');};
 assert.equal((await create(t)).status,502);assert.equal((await create(t)).status,200);assert.equal(t.counts().writes,1);
 assert.equal((await edit(t)).status,502);assert.equal((await edit(t)).status,200);assert.equal(t.counts().writes,2);
});
test('an uncertain update fences later device writes even if Gmail reads are delayed',async()=>{
 const t=await ready();await create(t);t.s.google.mailDraftUpload=async()=>{throw new Error('unknown');};
 assert.equal((await edit(t)).status,502);assert.equal((await edit(t)).status,409);
 assert.equal((await edit(t,{operationID:third})).status,409);assert.equal(t.counts().writes,1);
});
test('send consumes the existing Gmail draft without creating or uploading another draft',async()=>{
 const t=await ready();await create(t);
 const r=await t.call('send',{operationID:second,id:'gmail-draft',expectedMessageID:'message-1'});
 assert.equal(r.status,200);assert.equal(r.json.id,'sent-message');assert.deepEqual(t.counts(),{writes:1,sends:1,deletes:0});
 assert.equal((await t.call('send',{operationID:second,id:'gmail-draft',expectedMessageID:'message-1'})).status,200);assert.equal(t.counts().sends,1);
});
test('lost send replies never resend; delayed Sent evidence leaves a durable unknown outcome',async()=>{
 const t=await ready();await create(t);const send=t.s.google.mailDraftSend,find=t.s.google.mailFindSent;
 t.s.google.mailDraftSend=async(...args)=>{await send(...args);throw new Error('lost');};t.s.google.mailFindSent=async()=>null;
 const request={operationID:second,id:'gmail-draft',expectedMessageID:'message-1'};
 assert.equal((await t.call('send',request)).status,502);assert.equal((await t.call('send',request)).status,409);
 assert.equal((await t.call('send',{...request,operationID:third})).status,409);assert.equal(t.counts().sends,1);
 t.s.google.mailFindSent=find;assert.equal((await t.call('send',request)).status,200);assert.equal(t.counts().sends,1);
});
test('delete removes the Gmail draft and recovers a lost reply without another delete',async()=>{
 const t=await ready();await create(t);const remove=t.s.google.mailDraftDelete;
 t.s.google.mailDraftDelete=async(...args)=>{await remove(...args);throw new Error('lost');};
 const request={operationID:second,id:'gmail-draft',expectedMessageID:'message-1'};
 assert.equal((await t.call('delete',request)).status,502);assert.equal((await t.call('delete',request)).status,200);
 assert.equal(t.drafts.size,0);assert.equal(t.counts().deletes,1);
});
test('reads use Gmail including drafts created outside Banana',async()=>{
 const t=await ready();t.s.google.mailRead=async(token,request)=>({status:200,body:request.resource==='drafts'?{drafts:[{id:'external'}]}:{id:'external',message:{id:'outside',raw:'body'}}});
 const read=body=>t.s.call('POST','/v1/mail/read',{session:t.a.session,body:{email:'noor@plan.example',query:[],...body}});
 assert.equal((await read({resource:'drafts'})).json.drafts[0].id,'external');
 assert.equal((await read({resource:'draft',id:'external',query:[{name:'format',value:'raw'}]})).json.message.raw,'body');
});
test('no timer-owned mailbox, no attachment loss, no unversioned mutation or other-account access',async()=>{
 const t=await ready();
 for(const action of ['save','queue','cancel','deliver'])assert.equal((await t.call(action)).status,400);
 assert.equal((await t.call('update',{id:'gmail-draft',content:content()})).status,400);
 assert.equal((await t.call('create',{email:'other@plan.example',content:{...content(),from:{address:'other@plan.example'}}})).status,403);
 assert.equal((await t.call('create',{content:{...content(),attachments:[{name:'file',mimeType:'text/plain',bytes:1,chunks:['a'.repeat(64)]}]}})).status,422);
 await t.s.db.run('UPDATE feature_access SET enabled=0');assert.equal((await create(t)).status,403);assert.equal(t.counts().writes,0);
});
