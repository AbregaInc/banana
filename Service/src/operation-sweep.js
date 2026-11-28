import {parseMailOperation,mailOperation} from './mail-operation.js';
import {parseCalendarOperation,calendarOperation} from './calendar-operation.js';

/** A stuck operation is left alone this long, so a device that is only slow finishes it first. */
export const SWEEP_AFTER=5*60*1000;
/** Operations resumed per run; the rest wait for the next. */
export const SWEEP_BATCH=25;
/**
 * A calendar change that never went out is never applied by the service: it reads the event's current version when it
 * sends, so a late replay could overwrite a newer edit or notify guests days later. The device re-reads the event and
 * sends again with a fresh version if it is still wanted. One that already went out carries its stored version
 * (Google refuses it if the event changed), so it is still resumed.
 */
export const NEVER_REPLAY_UNSENT=0;

/**
 * What the sweep may finish on its own. Mail label changes set labels after reading the message, in order per item,
 * so they are replayed at any age. A calendar change that never went out is answered "changed since" (412), the answer
 * a device already understands, and never applied. Anything else (a draft, a send) is never sent late by the service.
 */
export const HANDLERS=[
 {parse:parseMailOperation,run:mailOperation,maxUnsentAge:null},
 {parse:parseCalendarOperation,run:calendarOperation,maxUnsentAge:NEVER_REPLAY_UNSENT},
];

/**
 * An operation that settles itself. A device that retries it gets this saved answer and drops its copy
 * (the `bananaOperation` receipt is what its journal looks for).
 */
export async function settleOperation(deps,vault,account,operationID,status,message) {
 const body={error:{code:status,message},bananaOperation:{id:operationID,state:'done'}};
 await deps.db.run("UPDATE provider_operations SET state='done',response_status=?,response_cipher=?,lease=NULL,lease_until=NULL,updated_at=? WHERE account_id=? AND operation_id=? AND state<>'done'",
  status,await vault.seal('provider-operation:'+account,JSON.stringify(body)),deps.now(),account,operationID);
}

/**
 * The job's second half: operations nothing is finishing (never sent, a lease that ran out, an outcome never
 * confirmed) are resumed by the service itself, oldest first, one per item so changes to one item stay in order.
 * Same operation identity as the device's, so nothing runs twice: a device that retries gets the saved answer.
 * An item whose later change already went out is left alone; replaying the earlier one would undo it.
 * @returns {{replayed:number,settled:number,skipped:number,failed:number}}
 */
export async function sweepStaleOperations(deps,vault,handlers=HANDLERS) {
 const t=deps.now(),quiet=t-SWEEP_AFTER,out={replayed:0,settled:0,skipped:0,failed:0};
 const rows=await deps.db.all(`SELECT p.account_id,p.operation_id,p.request_cipher,p.created_at,(p.dispatch_cipher IS NOT NULL) AS dispatched
  FROM provider_operations p
  WHERE p.state<>'done'
   AND ((p.state='pending' AND p.dispatch_cipher IS NULL AND p.updated_at<?) OR (p.state='running' AND p.lease_until<?) OR (p.state='uncertain' AND p.updated_at<?))
   AND NOT EXISTS (SELECT 1 FROM provider_operations e WHERE e.account_id=p.account_id AND e.resource_key=p.resource_key AND e.state<>'done'
     AND (e.created_at<p.created_at OR (e.created_at=p.created_at AND e.operation_id<p.operation_id)))
   AND NOT EXISTS (SELECT 1 FROM provider_operations d WHERE d.account_id=p.account_id AND d.resource_key=p.resource_key AND d.state='done'
     AND d.response_status BETWEEN 200 AND 299 AND d.created_at>p.created_at)
  ORDER BY p.created_at,p.operation_id LIMIT ?`,quiet,quiet,quiet,SWEEP_BATCH);
 for(const row of rows) {
  try {
   const request=JSON.parse(await vault.open('provider-operation:'+row.account_id,row.request_cipher));
   const handler=handlers.find(h=>h.parse(request));
   if(!handler){out.skipped++;continue;}
   if(handler.maxUnsentAge!=null&&!row.dispatched&&t-row.created_at>handler.maxUnsentAge) {
    await settleOperation(deps,vault,row.account_id,row.operation_id,412,'This changed since you made your edit. Open it again, then make yours.');
    out.settled++;continue;
   }
   const answer=await handler.run(deps,vault,row.account_id,request);
   // A refusal of the service's own (access gone, a provider outage) leaves it for the next run.
   if(answer?.status>=200&&answer.status<300)out.replayed++;else out.failed++;
  } catch { out.failed++; }
 }
 return out;
}
