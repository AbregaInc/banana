import {mailWriteLink} from './mail-grant.js';
import {mailPartsReady,mailAttachment,removeMailParts} from './mail-uploads.js';
import {providerOperation,operationFailure as fail} from './provider-operation.js';
import {sha256Hex} from './crypto.js';
import {GoogleRefused} from './google.js';
import {parseMailComposition,composeMail} from './mail-compose.js';
import {pokeMailbox} from './mail-sync.js';
const uuid=x=>typeof x==='string'&&/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(x);
const id=x=>typeof x==='string'&&/^[a-zA-Z0-9_-]{1,200}$/.test(x);
export function parseMailDraftRequest(x) {
 if(!x||typeof x.email!=='string'||x.email.length>320||!uuid(x.operationID)||!['create','update','delete','send'].includes(x.action))return null;
 const request={email:x.email.toLowerCase(),action:x.action,operationID:x.operationID.toLowerCase()};
 if(x.action!=='create') {
  if(!id(x.id)||!id(x.expectedMessageID))return null;
  request.id=x.id;request.expectedMessageID=x.expectedMessageID;
 } else if(x.id!=null||x.expectedMessageID!=null)return null;
 if(['create','update'].includes(x.action)) {
  request.content=parseMailComposition(x.content,request.email);if(!request.content)return null;
 } else if(x.content!=null)return null;
 return request;
}
const metadata=draft=>({id:draft.id,message:{id:draft.message.id,threadId:draft.message.threadId}});
const header=(draft,name)=>draft?.message?.payload?.headers?.find(h=>h.name?.toLowerCase()===name)?.value?.trim();
/** Gmail holds editable drafts. Banana holds encrypted pending operations and compact receipts. */
export async function mailDraft(deps,vault,account,request) {
 const link=await mailWriteLink(deps,account,request.email);
 if(!link)return fail(403,'Connect Email with draft access for this account.');
 const {action,operationID}=request;
 const messageID=`<${await sha256Hex(`${account}:${operationID}`)}@mail.banana.app>`;
 let token;
 const read=()=>deps.google.mailDraftGet(token,request.id);
 const enabled=async()=>{const current=await mailWriteLink(deps,account,request.email);return current?.sub===link.sub&&current?.refresh_token===link.refresh_token;};
 const answer=await providerOperation(deps,vault,{account,operationID,googleSub:link.sub,provider:'mail-draft',
  // Clients persist one create identity with their local draft before first delivery. Subsequent
  // edits, deletes and sends from every device serialize on the resulting Gmail draft ID.
  resource:[link.sub,request.id??operationID],request,enabled,
  prepare:async()=>{
   if(request.content&&!await mailPartsReady(deps,account,operationID,request.content.attachments))return fail(409,'Upload all attachment parts before saving this draft.');
   try{token=(await deps.google.refresh(await vault.open(link.sub,link.refresh_token))).accessToken;return null;}
   catch(e){return fail(e instanceof GoogleRefused?403:502,'Reconnect Email or retry when the service is available.');}
  },
  prepareDispatch:async()=>{
   if(action==='create')return {messageID,date:deps.now()};
   const draft=await read();
   if(!draft)return {refusal:fail(409,'The Gmail draft no longer exists. Refresh before continuing.')};
   if(draft.message?.id!==request.expectedMessageID)return {refusal:fail(409,'The Gmail draft changed. Keep your local edit and refresh before continuing.')};
   return {messageID:action==='update'?messageID:header(draft,'message-id'),date:deps.now()};
  },
  dispatch:async context=>{
   if(context.refusal)return context.refusal;
   if(action==='delete')return deps.google.mailDraftDelete(token,request.id);
   if(action==='send') {
    if(!context.messageID)return fail(409,'This draft has no Message-ID for safe send reconciliation. Save it before sending.');
    const answer=await deps.google.mailDraftSend(token,request.id);
    if(answer.status===404)throw new Error('draft disappearance does not prove non-delivery');
    return answer;
   }
   const mime=composeMail(request.content,{messageID:context.messageID,date:context.date,attachment:a=>mailAttachment(deps,account,operationID,a)});
   const result=await deps.google.mailDraftUpload(token,action,{id:request.id,threadID:request.content.threadID},mime);
   return result.status>=200&&result.status<300?{status:result.status,body:metadata(result.body)}:result;
  },
  reconcile:async context=>{
   if(context.refusal)return context.refusal;
   if(action==='send')return context.messageID?deps.google.mailFindSent(token,context.messageID):null;
   if(action==='delete')return await read()===null?{status:200,body:{deleted:true}}:null;
   if(action==='create') {
    const found=await deps.google.mailFindDraft(token,context.messageID);
    return found?{status:200,body:metadata(found.body)}:null;
   }
   const draft=await read();
   return draft&&header(draft,'message-id')===context.messageID?{status:200,body:metadata(draft)}:null;
  },
 });
 // Acknowledged content lives in Gmail. Keep only the request hash and metadata needed for
 // idempotent replies. Failed/uncertain edits retain their encrypted pending content for recovery.
 if(answer.status>=200&&answer.status<300) {
  await deps.db.run("UPDATE provider_operations SET request_cipher=? WHERE account_id=? AND operation_id=? AND state='done' AND response_status BETWEEN 200 AND 299",
   await vault.seal('provider-operation:'+account,JSON.stringify({action,id:request.id??null,operationID})),account,operationID);
  await removeMailParts(deps,account,operationID).catch(()=>{}); // The retention job retries object cleanup.
  await pokeMailbox(deps,link.sub);
 }
 return answer;
}
