import {sha256Hex} from './crypto.js';
export const operationFailure=(status,message)=>({status,body:{error:{code:status,message}}});
function sort(x) { return Array.isArray(x)?x.map(sort):x&&typeof x==='object'?Object.fromEntries(Object.keys(x).sort().map(k=>[k,sort(x[k])])):x; }
export const canonical=x=>JSON.stringify(sort(x));

/** Shared SQLite/D1 delivery journal. Provider adapters supply validation and read-only reconciliation. */
export async function providerOperation(deps,vault,options) {
 const {account,operationID,googleSub,provider,resource,request,enabled,prepare,prepareDispatch,dispatch,reconcile}=options;
 if(!await enabled())return operationFailure(403,'Feature access is unavailable.');
 const key=[account,operationID],aad='provider-operation:'+account;
 const hash=await sha256Hex(canonical({provider,request})),resourceKey=await sha256Hex(canonical({provider,resource}));
 const t=deps.now();
 await deps.db.run("INSERT OR IGNORE INTO provider_operations(account_id,operation_id,google_sub,resource_key,request_hash,request_cipher,state,created_at,updated_at) VALUES (?,?,?,?,?,?,'pending',?,?)",
  ...key,googleSub,resourceKey,hash,await vault.seal(aad,JSON.stringify(request)),t,t);
 const row=await deps.db.first('SELECT * FROM provider_operations WHERE account_id=? AND operation_id=?',...key);
 if(row.request_hash!==hash||row.google_sub!==googleSub)return operationFailure(409,'This operation identity belongs to a different request.');
 if(row.state==='done')return {status:row.response_status,body:JSON.parse(await vault.open(aad,row.response_cipher))};
 if(row.state==='running'&&row.lease_until>t)return operationFailure(409,'Operation is still running. Retry with the same operation identity.');
 const preparation=await prepare();
 if(preparation)return preparation; // no provider mutation has begun; leave the pending intent intact
 const save=async(answer,lease)=>{
  // Only a persisted terminal receipt can let a client forget an unsuccessful delivery.
  // A preflight refusal (for example revoked eligibility) says nothing about an earlier write.
  if(answer.status>=400)answer={...answer,body:{...answer.body,bananaOperation:{id:operationID,state:'done'}}};
  const result=await deps.db.run("UPDATE provider_operations SET state='done',response_status=?,response_cipher=?,updated_at=? WHERE account_id=? AND operation_id=? AND lease IS ?",
   answer.status,await vault.seal(aad,JSON.stringify(answer.body)),deps.now(),...key,lease);
  return result.changes?answer:operationFailure(409,'Outcome changed; read the operation again.');
 };
 let dispatchContext=row.dispatch_cipher?JSON.parse(await vault.open(aad,row.dispatch_cipher)):null;
 let retrySafe=false;
 if(row.state!=='pending') {
  try {
   // No persisted dispatch context means this operation never reached its provider write.
   const answer=dispatchContext===null?{retry:true}:await reconcile(dispatchContext);
   if(answer?.retry===true)retrySafe=true;
   else if(answer)return await save(answer,row.lease);
  }catch{/* Read failure is not absence. */}
  if(!retrySafe) {
  await deps.db.run("UPDATE provider_operations SET state='uncertain',updated_at=? WHERE account_id=? AND operation_id=? AND state='running' AND lease_until<=?",deps.now(),...key,deps.now());
  return operationFailure(409,'Outcome is not confirmed. The saved operation has not been repeated.');
  }
 }
 const lease=crypto.randomUUID();
 const claimed=await deps.db.run("UPDATE provider_operations SET state='running',lease=?,lease_until=?,updated_at=? WHERE account_id=? AND operation_id=? AND lease IS ? AND (state='pending' OR state='uncertain' OR (state='running' AND lease_until<=?)) AND NOT EXISTS (SELECT 1 FROM provider_operations other WHERE other.account_id=? AND other.resource_key=? AND other.operation_id<>? AND other.state IN ('running','uncertain'))",
  lease,t+60_000,t,...key,row.lease,t,account,resourceKey,operationID);
 if(!claimed.changes)return operationFailure(409,'An earlier operation on this item is still unresolved.');
 if(!await enabled()) {
  await deps.db.run("UPDATE provider_operations SET state='pending',lease=NULL,lease_until=NULL WHERE account_id=? AND operation_id=? AND lease=?",...key,lease);
  return operationFailure(403,'Feature access is unavailable.');
 }
 try {
  if(dispatchContext===null) {
   dispatchContext=prepareDispatch?await prepareDispatch({lease}):{};
   const persisted=await deps.db.run("UPDATE provider_operations SET dispatch_cipher=? WHERE account_id=? AND operation_id=? AND lease=? AND state='running'",
    await vault.seal(aad,JSON.stringify(dispatchContext)),...key,lease);
   if(!persisted.changes)return operationFailure(409,'Operation ownership changed before dispatch.');
  }
  const answer=await dispatch(dispatchContext);
  if(answer.status>=500||[408,429].includes(answer.status))throw new Error('provider outcome unknown');
  return await save(answer,lease);
 }catch{
  await deps.db.run("UPDATE provider_operations SET state='uncertain',updated_at=? WHERE account_id=? AND operation_id=? AND lease=? AND state='running'",deps.now(),...key,lease);
  return operationFailure(502,'Outcome is not confirmed. Retry with the same operation identity to reconcile.');
 }
}
