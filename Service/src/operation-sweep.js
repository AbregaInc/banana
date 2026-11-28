import {parseMailOperation,mailOperation} from './mail-operation.js';
import {parseCalendarOperation,calendarOperation} from './calendar-operation.js';
import {createVault} from './crypto.js';

/** A stuck operation is left alone this long, so a device that is only slow finishes it first. */
export const SWEEP_AFTER=5*60*1000;
/** Operations resumed per run (a minute), and the most of them one account may take, so a big backlog never starves another. */
export const SWEEP_BATCH=25, SWEEP_PER_ACCOUNT=10;
/** Stuck operations looked at per run; the checks per one are indexed, but the work per run stays bounded. */
export const SWEEP_SCAN=400;
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

// The sweep's three queries. Each runs against an indexed range (tested: test/operation-sweep.test.js reads the plan).
export const CANDIDATES_SQL=`SELECT account_id,operation_id,resource_key,created_at,(dispatch_cipher IS NOT NULL) AS dispatched
  FROM provider_operations
  WHERE (state='pending' AND dispatch_cipher IS NULL AND updated_at<?) OR (state='running' AND lease_until<?) OR (state='uncertain' AND updated_at<?)
  ORDER BY created_at,operation_id LIMIT ?`;
export const EARLIER_SQL="SELECT 1 AS x FROM provider_operations WHERE account_id=? AND resource_key=? AND state<>'done' AND (created_at<? OR (created_at=? AND operation_id<?)) LIMIT 1";
export const SUPERSEDED_SQL="SELECT 1 AS x FROM provider_operations WHERE account_id=? AND resource_key=? AND created_at>? AND state='done' AND response_status BETWEEN 200 AND 299 LIMIT 1";

/**
 * The job's second half: operations nothing is finishing (never sent, a lease that ran out, an outcome never
 * confirmed) are resumed by the service itself, oldest first, one per item so changes to one item stay in order.
 * Same operation identity as the device's, so nothing runs twice: a device that retries gets the saved answer.
 * An item whose later change already went out is left alone; replaying the earlier one would undo it.
 * @returns {{replayed:number,settled:number,skipped:number,failed:number}}
 */
export async function sweepStaleOperations(deps,vault,handlers=HANDLERS) {
 const t=deps.now(),quiet=t-SWEEP_AFTER,out={replayed:0,settled:0,skipped:0,failed:0};
 // Phase 1: the few operations nothing is finishing, from the (state, updated_at) index; no ciphertext, bounded.
 const candidates=await deps.db.all(CANDIDATES_SQL,quiet,quiet,quiet,SWEEP_SCAN);
 const taken=new Set(),perAccount=new Map();
 let picked=0;
 for(const row of interleave(candidates)) {
  if(picked>=SWEEP_BATCH)break;
  if((perAccount.get(row.account_id)??0)>=SWEEP_PER_ACCOUNT)continue;
  const item=row.account_id+'\n'+row.resource_key;
  if(taken.has(item))continue; // one per item per run: changes to an item stay in order
  // Phase 2: each check is a range inside one item's rows (provider_operations_item), never a table scan.
  const earlier=await deps.db.first(EARLIER_SQL,
   row.account_id,row.resource_key,row.created_at,row.created_at,row.operation_id);
  if(earlier)continue;
  // A later change on this item already went out: replaying this one would undo it.
  const superseded=await deps.db.first(SUPERSEDED_SQL,
   row.account_id,row.resource_key,row.created_at);
  if(superseded)continue;
  taken.add(item);picked++;perAccount.set(row.account_id,(perAccount.get(row.account_id)??0)+1);
  try {
   const stored=await deps.db.first("SELECT request_cipher FROM provider_operations WHERE account_id=? AND operation_id=?",row.account_id,row.operation_id);
   const request=JSON.parse(await vault.open('provider-operation:'+row.account_id,stored.request_cipher));
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

/** Oldest first within an account, and accounts taking turns: one account's backlog cannot crowd out the others. */
export function interleave(rows) {
 const queues=new Map();
 for(const row of rows) {
  if(!queues.has(row.account_id))queues.set(row.account_id,[]);
  queues.get(row.account_id).push(row);
 }
 const lists=[...queues.values()],out=[];
 for(let i=0;lists.some(l=>i<l.length);i++)for(const l of lists)if(i<l.length)out.push(l[i]);
 return out;
}

/** What a minute's schedule calls, in the Worker and in the self-hosted service alike. */
export async function runOperationSweep(deps,handlers=HANDLERS) {
 return sweepStaleOperations(deps,createVault(deps.config.tokenKey,deps.random),handlers);
}
