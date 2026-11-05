// A durable operation receipt, using the same SQLite/D1 transaction port as booking.
// Never replay a mutation after an ambiguous outcome without reconciling provider state.
import {providerOperation,operationFailure as failure} from './provider-operation.js';
import {featureAllowed,googleCapabilities} from './feature-access.js';
import {GoogleRefused} from './google.js';
import {busyBlockIdentity,busyIdentity} from './busy-block-identity.js';
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const id=x=>typeof x==='string'&&x.length>0&&x.length<=2048&&!/[\x00-\x1f]/.test(x);
const object=x=>x&&typeof x==='object'&&!Array.isArray(x);
const marker='bananaCloudOperation';
export function parseCalendarOperation(x) {
 if(!object(x)||!uuid.test(x.operationID)||!id(x.email)||!id(x.calendarID)||!['insert','patch','delete','move'].includes(x.action))return null;
 if(x.action!=='insert'&&!id(x.eventID))return null;
 if(x.action==='insert'&&x.eventID!=null)return null;
 if(x.action==='move'&&!id(x.destination))return null;
 if(x.action!=='move'&&x.destination!=null)return null;
 if(x.ifMatch!=null&&(!id(x.ifMatch)||/[\r\n]/.test(x.ifMatch)))return null;
 if(['insert','patch'].includes(x.action)?!object(x.body):x.body!=null)return null;
 if(!Array.isArray(x.query)||x.query.length>4)return null;
 const seen=new Set();
 for(const q of x.query) {
  if(!object(q)||seen.has(q.name))return null;
  seen.add(q.name);
  if(q.name==='sendUpdates'?!['all','externalOnly','none'].includes(q.value):q.name==='conferenceDataVersion'?!['0','1'].includes(q.value):q.name==='supportsAttachments'?q.value!=='true':true)return null;
 }
 if(x.body?.extendedProperties!=null&&(!object(x.body.extendedProperties)||(x.body.extendedProperties.private!=null&&!object(x.body.extendedProperties.private))))return null;
 if(x.action==='insert'&&x.body.id!=null&&!/^[0-9a-v]{5,1024}$/.test(x.body.id))return null;
 return {operationID:x.operationID.toLowerCase(),email:x.email.toLowerCase(),calendarID:x.calendarID,
  action:x.action,eventID:x.eventID??null,destination:x.destination??null,ifMatch:x.ifMatch??null,
  body:x.body??null,query:x.query.map(({name,value})=>({name,value})).sort((a,b)=>a.name.localeCompare(b.name))};
}

export async function calendarOperation(deps,vault,account,request) {
 if(!await featureAllowed(deps,account,'calendarCloud'))return failure(403,'Calendar access is unavailable.');
 const link=await deps.db.first("SELECT sub,refresh_token,scopes,status FROM google_links WHERE account_id=? AND email=? AND status<>'unlinked'",account,request.email);
 if(!link||!googleCapabilities({...link,has_token:Boolean(link.refresh_token)}).calendarWrite)return failure(403,'Reconnect this Google account.');
 const busy=await busyBlockIdentity(deps,vault,account,request);
 const busyInsert=request.action==='insert'&&busyIdentity(request.body);
 const eventID=request.action==='insert'?(request.body.id??request.operationID.replaceAll('-','')):request.eventID;
 const outbound=structuredClone(request);
 if(['insert','patch'].includes(request.action)) {
  if(request.action==='insert')outbound.body.id=eventID;
  outbound.body.extendedProperties??={};outbound.body.extendedProperties.private??={};
  outbound.body.extendedProperties.private[marker]=request.operationID;
 }
 let accessToken;
 const answer=await providerOperation(deps,vault,{account,operationID:request.operationID,googleSub:link.sub,
  provider:'calendar',resource:busy?.resource??[request.calendarID==='primary'?request.email:request.calendarID,eventID],request,
  enabled:async()=>{
   if(!await featureAllowed(deps,account,'calendarCloud'))return false;
   const current=await deps.db.first('SELECT refresh_token,status FROM google_links WHERE account_id=? AND sub=?',account,link.sub);
   return current?.status==='ok'&&current.refresh_token===link.refresh_token;
  },
  prepare:async()=>{
   try {({accessToken}=await deps.google.refresh(await vault.open(link.sub,link.refresh_token)));return null;}
   catch(e){return failure(e instanceof GoogleRefused?403:502,e instanceof GoogleRefused?'Reconnect this Google account.':'Calendar temporarily unavailable.');}
  },
  prepareDispatch:async(claim)=>{
   if(busyInsert)return busy.prepare(accessToken,claim);
   if(request.action==='insert')return {};
   const event=await deps.google.getEvent(accessToken,request.calendarID,eventID);
   if(!event||event.status==='cancelled')return {absent:true};
   if(busy&&(!busy.matches(event)||!busy.acceptsRequest))return {ownershipChanged:true};
   if(busy&&!request.ifMatch)return {missingVersion:true};
   if(typeof event.etag!=='string'||!event.etag)throw new Error('missing provider version');
   return {ifMatch:request.ifMatch??event.etag,uid:event.iCalUID??null};
  },
  dispatch:async(context)=>{
   if(busyInsert)return busy.dispatch(accessToken,context,outbound);
   if(context.missingVersion)return failure(428,'Refresh this busy block before changing it.');
   if(context.ownershipChanged)return failure(409,'Busy-block ownership changed. Refresh before changing it.');
   if(context.absent)return request.action==='delete'?{status:204,body:null}:failure(404,'This event no longer exists.');
   const answer=await deps.google.calendarMutation(accessToken,{...outbound,ifMatch:context.ifMatch??outbound.ifMatch});
   if(request.action==='delete'&&[404,410].includes(answer.status))return {status:204,body:null};
   if(['insert','patch'].includes(request.action)&&[409,412].includes(answer.status)) {
    const event=await deps.google.getEvent(accessToken,request.calendarID,eventID);
    if(event?.extendedProperties?.private?.[marker]===request.operationID)return {status:200,body:event};
   }
   return answer;
  },
  reconcile:async(context)=>{
   if(busyInsert)return busy.reconcile(accessToken,context);
   if(context.missingVersion)return failure(428,'Refresh this busy block before changing it.');
   if(context.ownershipChanged)return failure(409,'Busy-block ownership changed. Refresh before changing it.');
   const event=await deps.google.getEvent(accessToken,request.calendarID,eventID);
   if(request.action==='delete'&&(!event||event.status==='cancelled'))return {status:204,body:null};
   if(['insert','patch'].includes(request.action)&&event?.extendedProperties?.private?.[marker]===request.operationID)
    return {status:200,body:event};
   if(request.action==='insert')return event?failure(409,'An event already uses this identity.'):{retry:true};
   if(['patch','delete'].includes(request.action)) {
    if(!event)return failure(404,'This event no longer exists.');
    // Repeating the same conditional modification cannot overwrite a later event version.
    return event.etag===context.ifMatch?{retry:true}:failure(412,'This event changed elsewhere.');
   }
   if(request.action==='move'&&(!event||event.status==='cancelled')&&context.uid) {
    const answer=await deps.google.calendarRead(accessToken,{resource:'events',calendarID:request.destination,eventID:null,
     query:[{name:'iCalUID',value:context.uid},{name:'maxResults',value:'2'}]});
    const matches=answer.body?.items?.filter(e=>e.status!=='cancelled'&&e.iCalUID===context.uid)??[];
    if(answer.status===200&&matches.length===1&&!answer.body.nextPageToken)return {status:200,body:matches[0]};
   }
   return null;
  },
 });
 return busy?busy.finish(answer):answer;
}
