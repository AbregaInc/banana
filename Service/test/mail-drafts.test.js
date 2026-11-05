import test from 'node:test';
import assert from 'node:assert/strict';
import {setup,device} from './helpers.js';
import {deliverMailDrafts} from '../src/mail-drafts.js';
const id='10000000-0000-4000-8000-000000000001',sendID='20000000-0000-4000-8000-000000000002';
const content=()=>({from:{address:'noor@plan.example',name:'Noor'},to:[{address:'reader@plan.example'}],cc:[],bcc:[],subject:'Private draft',plain:'Private body',html:'<p>Private body</p>',attachments:[]});
async function ready(){
 const s=setup();s.google.person('signin','sub-noor','noor@plan.example','refresh',{scopes:'https://www.googleapis.com/auth/gmail.modify'});
 const a=(await s.signIn('signin',device('device-noor'))).json;
 await s.db.run('INSERT INTO feature_access VALUES (?,?,1,NULL,?)',a.account.id,'email',s.now());
 const call=(action,extra={})=>s.call('POST','/v1/mail/draft',{session:a.session,body:{email:'noor@plan.example',id,action,...extra}});
 let creates=0,sends=0;const uploads=[];
 s.google.mailDraftUpload=async(token,action,metadata,mime)=>{
  uploads.push({action,metadata,raw:await new Response(mime).text()});
  if(action==='create'){creates++;return {status:200,body:{id:'gmail-draft',message:{id:'draft-message',labelIds:['DRAFT']}}};}
  sends++;return {status:200,body:{id:'sent-message',labelIds:['SENT']}};
 };
 s.google.mailFindDraft=async()=>null;s.google.mailFindSent=async()=>null;
 return {s,a,call,uploads,counts:()=>({creates,sends})};
}
async function queue(t){assert.equal((await t.call('save',{revision:0,content:content()})).status,200);return t.call('queue',{revision:1,sendID,sendAt:t.s.now()});}
test('draft saves are encrypted, account scoped, replayable and compare-and-swap across devices',async()=>{
 const t=await ready();let r=await t.call('save',{revision:0,content:content()});assert.equal(r.json.revision,1);
 assert.equal((await t.call('save',{revision:0,content:content()})).json.revision,1);
 const changed={...content(),plain:'Edited elsewhere'};
 assert.equal((await t.call('save',{revision:1,content:changed})).json.revision,2);
 r=await t.call('save',{revision:1,content:{...content(),subject:'Stale edit'}});assert.equal(r.status,409);assert.equal(r.json.draft.content.plain,'Edited elsewhere');
 const row=await t.s.db.first('SELECT * FROM mail_drafts');assert.ok(!JSON.stringify(row).includes('Private body'));assert.ok(!JSON.stringify(row).includes('reader@'));
 t.s.google.person('other','sub-other','other@plan.example');const other=(await t.s.signIn('other',device('device-other'))).json;
 await t.s.db.run('INSERT INTO feature_access VALUES (?,?,1,NULL,?)',other.account.id,'email',t.s.now());
 assert.equal((await t.s.call('POST','/v1/mail/draft',{session:other.session,body:{action:'get',email:'noor@plan.example',id}})).status,403);
 assert.equal((await t.call('list')).json.drafts.length,1);
});
test('queue freezes a revision and two deliverers create/send exactly once',async()=>{
 const t=await ready();assert.equal((await queue(t)).json.state,'queued');
 assert.equal((await t.call('save',{revision:2,content:{...content(),subject:'Too late'}})).status,409);
 await Promise.all([t.call('deliver',{sendID}),t.call('deliver',{sendID})]);
 const result=await t.call('deliver',{sendID});assert.equal(result.json.state,'sent');assert.deepEqual(t.counts(),{creates:1,sends:1});
 assert.match(t.uploads[0].raw,/Private body/);assert.match(t.uploads[1].raw,/Private body/);
 assert.equal(t.uploads[1].metadata.id,'gmail-draft');
 assert.equal(t.uploads[0].raw.match(/Message-ID:\s*(<[^>]+>)/)[1],t.uploads[1].raw.match(/Message-ID:\s*(<[^>]+>)/)[1]);
 assert.equal((await t.call('cancel',{sendID})).status,409);
});
test('lost draft creation is reconciled without creating a replacement',async()=>{
 const t=await ready();await queue(t);const upload=t.s.google.mailDraftUpload;let found=false;
 t.s.google.mailDraftUpload=async(...args)=>{const result=await upload(...args);if(args[1]==='create'){found=true;throw new Error('lost');}return result;};
 assert.equal((await t.call('deliver',{sendID})).json.state,'uncertain');
 t.s.google.mailFindDraft=async()=>found?{status:200,body:{id:'gmail-draft'}}:null;
 assert.equal((await t.call('deliver',{sendID})).json.state,'sent');assert.deepEqual(t.counts(),{creates:1,sends:1});
});
test('an unknown send never repeats even when Sent search is delayed; later evidence resolves it',async()=>{
 const t=await ready();await queue(t);const upload=t.s.google.mailDraftUpload;
 t.s.google.mailDraftUpload=async(...args)=>{const result=await upload(...args);if(args[1]==='send')throw new Error('lost');return result;};
 assert.equal((await t.call('deliver',{sendID})).json.state,'uncertain');
 assert.equal((await t.call('deliver',{sendID})).json.state,'uncertain');assert.deepEqual(t.counts(),{creates:1,sends:1});
 assert.equal((await t.call('queue',{revision:2,sendID:'30000000-0000-4000-8000-000000000003',sendAt:t.s.now()})).status,409);
 t.s.google.mailFindSent=async()=>({status:200,body:{id:'sent-message',labelIds:['SENT']}});
 assert.equal((await t.call('deliver',{sendID})).json.state,'sent');assert.deepEqual(t.counts(),{creates:1,sends:1});
});
test('cancel before handoff wins durably; a future schedule is not sent early',async()=>{
 const t=await ready();await t.call('save',{revision:0,content:content()});
 const sendAt=t.s.now()+60_000;
 assert.equal((await t.call('queue',{revision:1,sendID,sendAt})).status,200);
 assert.equal((await t.call('deliver',{sendID})).status,202);
 assert.equal((await t.call('cancel',{sendID})).json.state,'editing');
 assert.equal((await t.call('deliver',{sendID})).status,409);assert.deepEqual(t.counts(),{creates:0,sends:0});
});
test('cron handoff obeys revocation and resumes with the same identity after access returns',async()=>{
 const t=await ready();await queue(t);await t.s.db.run('UPDATE feature_access SET enabled=0');
 await deliverMailDrafts(t.s.deps);assert.deepEqual(t.counts(),{creates:0,sends:0});
 await t.s.db.run('UPDATE feature_access SET enabled=1');await deliverMailDrafts(t.s.deps);
 assert.equal((await t.call('get')).json.state,'sent');assert.deepEqual(t.counts(),{creates:1,sends:1});
});
test('draft deletion, missing recipients and unsupported attachments fail explicitly',async()=>{
 const t=await ready();assert.equal((await t.call('save',{revision:0,content:{...content(),to:[]}})).status,200);
 assert.equal((await t.call('queue',{revision:1,sendID,sendAt:t.s.now()})).status,422);
 assert.equal((await t.call('save',{revision:1,content:{...content(),attachments:[{name:'file',mimeType:'text/plain',bytes:1,chunks:['a'.repeat(64)]}]}})).status,422);
 assert.equal((await t.call('delete',{revision:1})).json.state,'deleted');assert.equal((await t.call('save',{revision:2,content:content()})).status,409);
});
test('cancelled identities cannot be reused after subsequent edits and cancellation cycles',async()=>{
 const t=await ready();await queue(t);await t.call('cancel',{sendID});
 const second='30000000-0000-4000-8000-000000000003';
 assert.equal((await t.call('queue',{revision:3,sendID:second,sendAt:t.s.now()})).status,200);
 await t.call('cancel',{sendID:second});
 assert.equal((await t.call('queue',{revision:5,sendID,sendAt:t.s.now()})).status,409);
 assert.deepEqual(t.counts(),{creates:0,sends:0});
});
test('a schedule over thirty minutes late asks instead of unexpectedly sending after reconnect',async()=>{
 const t=await ready();await queue(t);t.s.advance(31*60_000);
 assert.equal((await t.call('deliver',{sendID})).json.state,'late');assert.deepEqual(t.counts(),{creates:0,sends:0});
 await deliverMailDrafts(t.s.deps);assert.deepEqual(t.counts(),{creates:0,sends:0});
 assert.equal((await t.call('cancel',{sendID})).json.state,'editing');
});
test('a missing Gmail draft is an unknown send outcome, not evidence that nothing was sent',async()=>{
 const t=await ready();await queue(t);const upload=t.s.google.mailDraftUpload;
 t.s.google.mailDraftUpload=async(...args)=>args[1]==='send'?{status:404,body:{error:{message:'not found'}}}:upload(...args);
 assert.equal((await t.call('deliver',{sendID})).json.state,'uncertain');
 assert.equal((await t.call('deliver',{sendID})).json.state,'uncertain');
});
test('discard erases draft content but retains a tombstone against stale offline recreation',async()=>{
 const t=await ready();await t.call('save',{revision:0,content:content()});
 assert.equal((await t.call('delete',{revision:1})).json.content,null);
 assert.equal((await t.call('save',{revision:0,content:content()})).status,409);
 t.s.google.person('delete','sub-noor','noor@plan.example');assert.equal((await t.s.call('DELETE','/v1/account',{session:t.a.session,body:{code:'delete'}})).status,204);
 assert.equal((await t.s.db.first('SELECT count(*) AS n FROM mail_drafts')).n,0);
 assert.equal((await t.s.db.first('SELECT count(*) AS n FROM mail_handoffs')).n,0);
});
