import {mailLink} from './mail-grant.js';
import {featureAllowed,googleCapabilities} from './feature-access.js';
import {providerOperation,operationFailure as failure} from './provider-operation.js';
import {GoogleRefused} from './google.js';
const id=x=>typeof x==='string'&&x.length>0&&x.length<=2048&&!['.','..'].includes(x)&&!/[\x00-\x1f]/.test(x);
const labels=x=>Array.isArray(x)&&x.length<=100&&x.every(id)&&new Set(x).size===x.length;
export function parseMailOperation(x) {
 if(!x||!id(x.email)||!id(x.id)||!['modify','trash','untrash'].includes(x.action)
  ||typeof x.operationID!=='string'||!(/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i).test(x.operationID))return null;
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
 const matches=event=>Array.isArray(event?.labelIds)&&request.add.every(x=>event.labelIds.includes(x))&&request.remove.every(x=>!event.labelIds.includes(x));
 const read=()=>deps.google.mailMessage(token,request.id);
 return providerOperation(deps,vault,{account,operationID:request.operationID,googleSub:link.sub,
  provider:'mail',resource:[link.sub,request.id],request,
  enabled:async()=>{
   if(!await featureAllowed(deps,account,'email'))return false;
   const current=await mailLink(deps,account,request.email);
   return current?.status==='ok'&&current.refresh_token===link.refresh_token;
  },
  prepare:async()=>{
   try {token=(await deps.google.refresh(await vault.open(link.sub,link.refresh_token))).accessToken;return null;}
   catch(e){return failure(e instanceof GoogleRefused?403:502,e instanceof GoogleRefused?'Reconnect Email.':'Email temporarily unavailable.');}
  },
  dispatch:async()=>{
   const before=await read();
   if(matches(before))return {status:200,body:before};
   return deps.google.mailMutation(token,request);
  },
  reconcile:async()=>{const event=await read();return matches(event)?{status:200,body:event}:null;},
 });
}
