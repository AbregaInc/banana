import {mailLink} from './mail-grant.js';
import {featureAllowed,googleCapabilities} from './feature-access.js';
import {canonical,providerOperation,operationFailure as fail} from './provider-operation.js';
import {sha256Hex,createVault} from './crypto.js';
import {GoogleRefused} from './google.js';
import {parseMailComposition,composeMail} from './mail-compose.js';
const uuid=x=>typeof x==='string'&&/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(x);
const aad=(account,id)=>`mail-draft:${account}:${id}`;
const key=(account,id)=>[account,id];
export function parseMailDraftRequest(x) {
 if(!x||typeof x.email!=='string'||x.email.length>320||!['list','get','save','delete','queue','cancel','deliver'].includes(x.action))return null;
 const request={email:x.email.toLowerCase(),action:x.action};
 if(x.action==='list') {
  if(x.after!=null&&!uuid(x.after))return null;
  return {...request,after:x.after?.toLowerCase()??''};
 }
 if(!uuid(x.id))return null;request.id=x.id.toLowerCase();
 if(['save','delete','queue'].includes(x.action)) {
  if(!Number.isSafeInteger(x.revision)||x.revision<0)return null;request.revision=x.revision;
 }
 if(x.action==='save') {
  request.content=parseMailComposition(x.content,request.email);
  if(!request.content)return null;
 }
 if(x.action==='queue') {
  if(!uuid(x.sendID)||!Number.isSafeInteger(x.sendAt))return null;
  request.sendID=x.sendID.toLowerCase();request.sendAt=x.sendAt;
 }
 if(['cancel','deliver'].includes(x.action)) {
  if(!uuid(x.sendID))return null;request.sendID=x.sendID.toLowerCase();
 }
 return request;
}
async function authorization(deps,account,email) {
 if(!await featureAllowed(deps,account,'email'))return null;
 const link=await mailLink(deps,account,email);
 if(!link||!googleCapabilities({...link,has_token:Boolean(link.refresh_token)}).mailModify)return null;
 if(link.client_id&&link.client_id!==deps.config.googleClientId)return null;
 return link;
}
async function rowFor(deps,account,id) {return deps.db.first('SELECT * FROM mail_drafts WHERE account_id=? AND draft_id=?',...key(account,id));}
async function value(vault,row) {
 return {id:row.draft_id,revision:row.revision,state:row.state,sendID:row.send_id,sendAt:row.send_at,updatedAt:row.updated_at,
  content:JSON.parse(await vault.open(aad(row.account_id,row.draft_id),row.content_cipher)),
  result:row.result_cipher?JSON.parse(await vault.open(aad(row.account_id,row.draft_id),row.result_cipher)):null};
}
/** Compare-and-swap saves preserve another device's edits; queue freezes the reviewed revision. */
export async function mailDraft(deps,vault,account,request) {
 const link=await authorization(deps,account,request.email);
 if(!link)return fail(403,'Connect Email with draft access for this account.');
 const {action,id,revision}=request;
 if(action==='list') {
  const rows=await deps.db.all('SELECT * FROM mail_drafts WHERE account_id=? AND google_sub=? AND draft_id>? ORDER BY draft_id LIMIT 11',account,link.sub,request.after);
  return {status:200,body:{drafts:await Promise.all(rows.slice(0,10).map(r=>value(vault,r))),next:rows.length>10?rows[9].draft_id:null}};
 }
 let row=await rowFor(deps,account,id);
 if(row&&row.google_sub!==link.sub)return fail(404,'Draft not found.');
 if(action==='save') {
  // Attachment transport is a separate acceptance gate. Refuse explicitly rather than dropping
  // a file or allowing a caller to inject an arbitrary object-store reference into a send.
  if(request.content.attachments.length)return fail(422,'Attachment upload is not available yet. Your draft has not been changed.');
  const hash=await sha256Hex(canonical(request.content));
  if(row?.state==='editing'&&row.content_hash===hash&&row.revision===revision+1)return {status:200,body:await value(vault,row)};
  const cipher=await vault.seal(aad(account,id),JSON.stringify(request.content));
  if(revision===0) {
   await deps.db.run(`INSERT OR IGNORE INTO mail_drafts(account_id,draft_id,google_sub,revision,content_hash,content_cipher,state,updated_at)
    SELECT ?,?,?,1,?,?,'editing',? WHERE (SELECT count(*) FROM mail_drafts WHERE account_id=? AND state NOT IN ('sent','deleted'))<200`,
    account,id,link.sub,hash,cipher,deps.now(),account);
  } else {
   await deps.db.run("UPDATE mail_drafts SET revision=revision+1,content_hash=?,content_cipher=?,updated_at=? WHERE account_id=? AND draft_id=? AND revision=? AND state='editing'",hash,cipher,deps.now(),account,id,revision);
  }
  row=await rowFor(deps,account,id);
  if(!row)return fail(409,'Draft limit reached.');
  if(row.revision!==revision+1||row.content_hash!==hash||row.state!=='editing')return {status:409,body:{error:{code:409,message:'Draft changed elsewhere. Keep your local copy.'},draft:await value(vault,row)}};
 } else {
  if(!row)return fail(404,'Draft not found.');
  if(action==='queue') {
   if(row.send_id===request.sendID&&row.send_at===request.sendAt&&row.revision===revision+1&&row.state!=='editing')return {status:200,body:await value(vault,row)};
   if(row.send_id===request.sendID)return fail(409,'A cancelled handoff needs a new send identity.');
   if(request.sendAt<deps.now()-60_000||request.sendAt>deps.now()+366*86400_000)return fail(400,'Choose a current or future send time.');
   const content=JSON.parse(await vault.open(aad(account,id),row.content_cipher));
   if(!content.to.length&&!content.cc.length&&!content.bcc.length)return fail(422,'Add a recipient before sending.');
   const changes=await deps.db.batch([
    {sql:"INSERT OR IGNORE INTO mail_handoffs(account_id,send_id,draft_id,revision) SELECT ?,?,?,? WHERE EXISTS (SELECT 1 FROM mail_drafts WHERE account_id=? AND draft_id=? AND revision=? AND state='editing')",params:[account,request.sendID,id,revision,account,id,revision]},
    {sql:"UPDATE mail_drafts SET state='queued',revision=revision+1,send_id=?,send_at=?,send_started_at=NULL,result_cipher=NULL,updated_at=? WHERE account_id=? AND draft_id=? AND revision=? AND state='editing' AND EXISTS (SELECT 1 FROM mail_handoffs WHERE account_id=? AND send_id=? AND draft_id=? AND revision=?)",params:[request.sendID,request.sendAt,deps.now(),account,id,revision,account,request.sendID,id,revision]},
   ]);
   if(!changes[1].changes)return fail(409,'Draft changed or this handoff identity was already used. Refresh before sending.');
  } else if(action==='delete') {
   if(row.state==='deleted'&&row.revision===revision+1)return {status:200,body:await value(vault,row)};
   const changed=await deps.db.run("UPDATE mail_drafts SET state='deleted',revision=revision+1,content_cipher=?,content_hash='',result_cipher=NULL,updated_at=? WHERE account_id=? AND draft_id=? AND revision=? AND state='editing'",await vault.seal(aad(account,id),'null'),deps.now(),account,id,revision);
   if(!changed.changes)return fail(409,'Only an editable draft can be discarded.');
  } else if(action==='cancel') {
   const changed=await deps.db.run("UPDATE mail_drafts SET state='editing',revision=revision+1,updated_at=? WHERE account_id=? AND draft_id=? AND send_id=? AND state IN ('queued','late')",deps.now(),account,id,request.sendID);
   if(!changed.changes&&!(row.state==='editing'&&row.send_id===request.sendID))return fail(409,'The send has already been handed off; cancellation is not confirmed.');
  } else if(action==='deliver')return deliverDraft(deps,vault,account,id,request.sendID);
  row=await rowFor(deps,account,id);
 }
 return {status:200,body:await value(vault,row)};
}
const operationID=async(text)=>{const h=await sha256Hex(text);return `${h.slice(0,8)}-${h.slice(8,12)}-4${h.slice(13,16)}-a${h.slice(17,20)}-${h.slice(20,32)}`;};
/** Once sending, no edit/cancel/new send identity may bypass an uncertain provider outcome. */
export async function deliverDraft(deps,vault,account,id,sendID) {
 let row=await rowFor(deps,account,id);
 if(!row||row.send_id!==sendID)return fail(404,'Send not found.');
 if(['sent','failed'].includes(row.state))return {status:200,body:await value(vault,row)};
 if(!['queued','sending','uncertain'].includes(row.state))return fail(409,'Draft is not queued.');
 const content=JSON.parse(await vault.open(aad(account,id),row.content_cipher));
 const link=await authorization(deps,account,content.from.address);
 if(!link||link.sub!==row.google_sub)return fail(403,'Reconnect Email before continuing this send.');
 if(row.state==='queued'&&deps.now()-row.send_at>30*60_000) {
  await deps.db.run("UPDATE mail_drafts SET state='late',updated_at=? WHERE account_id=? AND draft_id=? AND send_id=? AND state='queued'",deps.now(),account,id,sendID);
  return {status:409,body:await value(vault,await rowFor(deps,account,id))};
 }
 if(row.send_at>deps.now())return {status:202,body:await value(vault,row)};
 await deps.db.run("UPDATE mail_drafts SET state='sending',send_started_at=COALESCE(send_started_at,?),updated_at=? WHERE account_id=? AND draft_id=? AND send_id=? AND state='queued'",deps.now(),deps.now(),account,id,sendID);
 row=await rowFor(deps,account,id);
 if(!row||!['sending','uncertain'].includes(row.state)||row.send_id!==sendID)return fail(409,'Send changed before handoff.');
 let token;
 const messageID=`<${await sha256Hex(canonical([account,id,sendID]))}@mail.banana.app>`;
 const common={account,googleSub:link.sub,provider:'mail-send',
  enabled:async()=>{const current=await authorization(deps,account,content.from.address);return current?.sub===link.sub&&current?.refresh_token===link.refresh_token;},
  prepare:async()=>{try{token=(await deps.google.refresh(await vault.open(link.sub,link.refresh_token))).accessToken;return null;}
   catch(e){return fail(e instanceof GoogleRefused?403:502,'Reconnect Email or retry when the service is available.');}},
 };
 const mime=()=>composeMail(content,{messageID,date:row.send_started_at,attachment:async function*(){throw new Error('attachments unavailable');}});
 const create=await providerOperation(deps,vault,{...common,operationID:await operationID(`${account}:${id}:${sendID}:create`),resource:[link.sub,id,'create'],request:{id,sendID,contentHash:row.content_hash,messageID},
  dispatch:()=>deps.google.mailDraftUpload(token,'create',{threadID:content.threadID},mime()),
  reconcile:()=>deps.google.mailFindDraft(token,messageID),
 });
 let outcome=create;
 if(create.status>=200&&create.status<300&&typeof create.body?.id==='string') {
  outcome=await providerOperation(deps,vault,{...common,operationID:await operationID(`${account}:${id}:${sendID}:send`),resource:[link.sub,id,'send'],request:{id,sendID,providerDraftID:create.body.id,contentHash:row.content_hash,messageID},
   // Include the frozen MIME in drafts.send. An external edit to the Gmail draft cannot
   // replace the content/recipients that the Banana user reviewed at queue time.
   dispatch:async()=>{
    const sent=await deps.google.mailFindSent(token,messageID);if(sent)return sent;
    const answer=await deps.google.mailDraftUpload(token,'send',{id:create.body.id,threadID:content.threadID},mime());
    if(answer.status===404)throw new Error('draft disappearance does not prove non-delivery');
    return answer;
   },
   reconcile:()=>deps.google.mailFindSent(token,messageID),
  });
 }
 const success=outcome.status>=200&&outcome.status<300&&typeof outcome.body?.id==='string';
 const terminal=outcome.body?.bananaOperation?.state==='done';
 const state=success?'sent':terminal?'failed':'uncertain';
 await deps.db.run("UPDATE mail_drafts SET state=?,result_cipher=?,updated_at=? WHERE account_id=? AND draft_id=? AND send_id=? AND state IN ('sending','uncertain')",
  state,await vault.seal(aad(account,id),JSON.stringify(outcome)),deps.now(),account,id,sendID);
 return {status:success||terminal?200:outcome.status,body:await value(vault,await rowFor(deps,account,id))};
}
/** Cron drains durable handoffs even when every app is closed. Unknown sends are read-only reconciled. */
export async function deliverMailDrafts(deps) {
 const vault=createVault(deps.config.tokenKey,deps.random);
 const rows=await deps.db.all("SELECT account_id,draft_id,send_id FROM mail_drafts WHERE state IN ('queued','sending','uncertain') AND send_at<=? ORDER BY COALESCE(checked_at,0),updated_at LIMIT 20",deps.now());
 for(const row of rows) {
  try{await deps.db.run('UPDATE mail_drafts SET checked_at=? WHERE account_id=? AND draft_id=?',deps.now(),row.account_id,row.draft_id);await deliverDraft(deps,vault,row.account_id,row.draft_id,row.send_id);}catch{/* durable row remains for the next run */}
 }
 return {checked:rows.length};
}
