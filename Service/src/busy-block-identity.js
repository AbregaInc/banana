import {sha256Hex} from './crypto.js';
import {canonical,operationFailure as failure} from './provider-operation.js';

const properties=event=>event?.extendedProperties?.private;
const valid=x=>typeof x==='string'&&x.length>0&&x.length<=1024;
export const busyIdentity=body=>{
 const p=properties(body);
 return valid(p?.bananaItemID)&&valid(p?.bananaVariant)
  ?{item:p.bananaItemID,variant:p.bananaVariant}:null;
};

/** Use the existing durable-operation claim to serialize a logical block, not a device's UUID.
 * Reserve its provider identity before dispatch. An uncertain insert is never repeated merely
 * because a provider read has not yet found it. Explicit deletion permits a fresh generation.
 */
export async function busyBlockIdentity(deps,vault,account,request) {
 const calendar=request.calendarID==='primary'?request.email:request.calendarID;
 const eventKey=id=>sha256Hex(canonical([calendar,id]));
 const identity=request.action==='insert'?busyIdentity(request.body):null;
 let row,claim;
 const logicalKey=identity?await sha256Hex(canonical([calendar,identity.variant,identity.item])):null;
 if(!identity) {
  if(!request.eventID)return null;
  row=await deps.db.first('SELECT * FROM busy_block_identities WHERE account_id=? AND event_key=?',account,await eventKey(request.eventID));
  if(!row)return null;
 }
 const key=logicalKey??row.logical_key;
 const aad='busy-block:'+account+':'+key;
 const owned=identity??JSON.parse(await vault.open(aad,row.event_cipher)).identity;
 const matches=event=>properties(event)?.bananaItemID===owned.item&&properties(event)?.bananaVariant===owned.variant;
 const extension=request.body?.extendedProperties,declared=extension?.private;
 const acceptsRequest=request.action!=='move'&&extension!==null&&declared!==null&&
  (!declared||((!Object.hasOwn(declared,'bananaItemID')||declared.bananaItemID===owned.item)&&
   (!Object.hasOwn(declared,'bananaVariant')||declared.bananaVariant===owned.variant)));
 const reserve=async(eventID,established)=>{
  const hash=await eventKey(eventID),cipher=await vault.seal(aad,JSON.stringify({eventID,identity:owned}));
  const saved=await deps.db.run(`INSERT INTO busy_block_identities(account_id,logical_key,event_key,event_cipher,owner_operation,established,retired)
   SELECT ?,?,?,?,?,?,0 WHERE EXISTS (SELECT 1 FROM provider_operations WHERE account_id=? AND operation_id=? AND lease=? AND state='running')
   ON CONFLICT(account_id,logical_key) DO UPDATE SET
   event_key=excluded.event_key,event_cipher=excluded.event_cipher,owner_operation=excluded.owner_operation,
   established=excluded.established,retired=0`,account,key,hash,cipher,request.operationID,established?1:0,account,request.operationID,claim.lease);
  if(!saved.changes)throw new Error('Busy operation ownership changed');
  return eventID;
 };
 return {
  resource:['busy-block',key],
  matches,
  acceptsRequest,
  async prepare(token,currentClaim) {
   claim=currentClaim;
   row=await deps.db.first('SELECT * FROM busy_block_identities WHERE account_id=? AND logical_key=?',account,key);
   if(row&&!row.retired) {
    const {eventID}=JSON.parse(await vault.open(aad,row.event_cipher));
    if(!row.established&&row.owner_operation===request.operationID)return {eventID};
    const event=await deps.google.getEvent(token,request.calendarID,eventID);
    if(event?.status==='cancelled')return {eventID:await reserve(crypto.randomUUID().replaceAll('-',''),false)};
    // Null can be an eventually consistent read after another device's successful insertion.
    // Neither null nor a foreign marker is permission to create another copy.
    return {eventID,existing:true};
   }
   if(!row) {
    const query=[{name:'privateExtendedProperty',value:'bananaVariant='+identity.variant},
     {name:'privateExtendedProperty',value:'bananaItemID='+identity.item},{name:'maxResults',value:'2500'}];
    const page=await deps.google.calendarRead(token,{resource:'events',calendarID:request.calendarID,eventID:null,query});
    if(page.status!==200||!Array.isArray(page.body?.items)||page.body.nextPageToken)
     throw new Error('Busy ownership requires a complete bounded read');
    const events=page.body.items.filter(e=>e.status!=='cancelled'&&valid(e.id)&&matches(e));
    if(events.length) {
     const eventID=events.map(e=>e.id).sort()[0];
     await reserve(eventID,true);
     return {eventID,existing:true};
    }
   }
   return {eventID:await reserve(crypto.randomUUID().replaceAll('-',''),false)};
  },
  async dispatch(token,context,outbound) {
   if(context.existing)return failure(409,'This busy block already exists. Refresh before changing it.');
   return deps.google.calendarMutation(token,{...outbound,body:{...outbound.body,id:context.eventID}});
  },
  async reconcile(token,context) {
   if(context.existing)return failure(409,'This busy block already exists. Refresh before changing it.');
   const event=await deps.google.getEvent(token,request.calendarID,context.eventID);
   if(matches(event)&&properties(event)?.bananaCloudOperation===request.operationID)return {status:200,body:event};
   return null;
  },
  async finish(answer) {
   if(request.action==='delete'&&answer.status>=200&&answer.status<300) {
    await deps.db.run('UPDATE busy_block_identities SET retired=1 WHERE account_id=? AND event_key=?',account,await eventKey(request.eventID));
   }else if(identity&&answer.status>=200&&answer.status<300&&answer.body?.id) {
    await deps.db.run('UPDATE busy_block_identities SET established=1 WHERE account_id=? AND event_key=?',account,await eventKey(answer.body.id));
   }else if(identity&&answer.body?.bananaOperation?.state==='done') {
    // A persisted definitive refusal is safe to abandon; an unknown outcome is not.
    await deps.db.run('UPDATE busy_block_identities SET retired=1 WHERE account_id=? AND logical_key=? AND owner_operation=? AND established=0',account,key,request.operationID);
   }
   return answer;
  },
 };
}
