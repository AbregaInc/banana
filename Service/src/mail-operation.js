import {mailLink} from './mail-grant.js';
import {featureAllowed,googleCapabilities} from './feature-access.js';
import {providerOperation,operationFailure as failure} from './provider-operation.js';
import {GoogleRefused} from './google.js';
import {noteMailAction,noteMailLabel} from './mail-sync.js';
import {BANANA_LABEL,parseBananaLabel} from './mail-snooze.js';
const uuid=x=>typeof x==='string'&&(/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i).test(x);
const absent=x=>x===undefined||x===null;
const id=x=>typeof x==='string'&&x.length>0&&x.length<=2048&&!['.','..'].includes(x)&&!/[\x00-\x1f]/.test(x);
const labels=x=>Array.isArray(x)&&x.length<=100&&x.every(id)&&new Set(x).size===x.length;
export function parseMailOperation(x) {
 // createLabel makes only Banana's hidden snooze/mute labels (MAIL-ENGINE §8), never a label of his.
 if(x?.action==='createLabel') {
  if(!id(x.email)||typeof x.name!=='string'||!BANANA_LABEL.test(x.name)||!parseBananaLabel(x.name)||!uuid(x.operationID)||!absent(x.id)||!absent(x.add)||!absent(x.remove))return null;
  return {email:x.email.toLowerCase(),action:'createLabel',name:x.name,operationID:x.operationID.toLowerCase()};
 }
 if(!x||!id(x.email)||!id(x.id)||!['modify','trash','untrash'].includes(x.action)||!uuid(x.operationID))return null;
 const add=x.action==='trash'?['TRASH']:x.action==='untrash'?[]:x.add;
 const remove=x.action==='untrash'?['TRASH']:x.action==='trash'?[]:x.remove;
 if(!labels(add)||!labels(remove)||add.some(v=>remove.includes(v)))return null;
 return {email:x.email.toLowerCase(),id:x.id,action:x.action,operationID:x.operationID.toLowerCase(),add:[...add].sort(),remove:[...remove].sort()};
}
export async function mailOperation(deps,vault,account,request) {
 if(!await featureAllowed(deps,account,'email'))return failure(403,'Email access is unavailable.');
 const link=await mailLink(deps,account,request.email);
 if(!link||!googleCapabilities({...link,has_token:Boolean(link.refresh_token)}).mailModify)return failure(403,'Connect Email for this Google account.');
 if(link.client_id&&link.client_id!==deps.config.googleClientId)return failure(403,'Reconnect Email for this service.');
 let token;
 const enabled=async()=>{
  if(!await featureAllowed(deps,account,'email'))return false;
  const current=await mailLink(deps,account,request.email);
  return current?.status==='ok'&&current.refresh_token===link.refresh_token;
 };
 const prepare=async()=>{
  try {token=(await deps.google.refresh(await vault.open(link.sub,link.refresh_token))).accessToken;return null;}
  catch(e){return failure(e instanceof GoogleRefused?403:502,e instanceof GoogleRefused?'Reconnect Email.':'Email temporarily unavailable.');}
 };
 if(request.action==='createLabel')return createLabel(deps,vault,account,request,link,{enabled,prepare,token:()=>token});
 const matches=event=>Array.isArray(event?.labelIds)&&request.add.every(x=>event.labelIds.includes(x))&&request.remove.every(x=>!event.labelIds.includes(x));
 const read=()=>deps.google.mailMessage(token,request.id);
 const answer=await providerOperation(deps,vault,{account,operationID:request.operationID,googleSub:link.sub,
  provider:'mail',resource:[link.sub,request.id],request,enabled,prepare,
  dispatch:async()=>{
   const before=await read();
   if(matches(before))return {status:200,body:before};
   return deps.google.mailMutation(token,request);
  },
  reconcile:async()=>{const event=await read();return matches(event)?{status:200,body:event}:null;},
 });
 // The shared mailbox reads the message back, so every other device gets the result in order;
 // a label it added that the mailbox has no name for is read again.
 if(answer.status>=200&&answer.status<300)await noteMailAction(deps,link.sub,[request.id],request.add);
 return answer;
}
// A label is the same label whoever made it: an existing one of the name is the answer, and a
// device that lost the race (409) gets the one the other made.
async function createLabel(deps,vault,account,request,link,{enabled,prepare,token}) {
 const named=list=>list.find(l=>l?.name===request.name&&typeof l.id==='string')??null;
 const answer=await providerOperation(deps,vault,{account,operationID:request.operationID,googleSub:link.sub,
  provider:'mail',resource:[link.sub,'label:'+request.name],request,enabled,prepare,
  dispatch:async()=>{
   const existing=named(await deps.google.mailLabels(token()));
   if(existing)return {status:200,body:existing};
   const made=await deps.google.mailCreateLabel(token(),{name:request.name,labelListVisibility:'labelHide',messageListVisibility:'hide'});
   if(made.status!==409)return made;
   const raced=named(await deps.google.mailLabels(token()));
   if(!raced)throw new Error('label conflict unresolved');
   return {status:200,body:raced};
  },
  reconcile:async()=>{const label=named(await deps.google.mailLabels(token()));return label?{status:200,body:label}:null;},
 });
 if(answer.status>=200&&answer.status<300)await noteMailLabel(deps,link.sub,{id:answer.body.id,name:answer.body.name});
 return answer;
}
