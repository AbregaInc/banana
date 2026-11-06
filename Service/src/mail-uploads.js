import {mailWriteLink} from './mail-grant.js';
import {sha256Hex} from './crypto.js';
const UUID=/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/;
const SHA=/^[0-9a-f]{64}$/;
const CHUNK=1024*1024, QUOTA=100*CHUNK, DAY=24*60*60*1000;
const key=async(account,operation,hash)=>`mail-pending/${await sha256Hex(account)}/${operation}/${hash}`;

/** Only one bounded part is held in memory. The existing blob adapter verifies its SHA-256. */
export async function uploadMailPart(deps,account,email,operation,hash,body) {
 if(typeof email!=='string'||email.length>320||!UUID.test(operation)||!SHA.test(hash))return 400;
 if(!await mailWriteLink(deps,account,email))return 403;
 const done=await deps.db.first("SELECT response_status FROM provider_operations WHERE account_id=? AND operation_id=? AND state='done'",account,operation);
 if(done?.response_status>=200&&done.response_status<300){await body?.cancel();return 204;}
 const reader=body?.getReader();if(!reader)return 400;
 const parts=[];let bytes=0;
 try {
  for(;;){const item=await reader.read();if(item.done)break;bytes+=item.value.length;
   if(bytes>CHUNK){await reader.cancel();return 413;}parts.push(item.value);}
 } finally {reader.releaseLock();}
 const now=deps.now(), args=[account,operation,hash];
 // Reserve quota atomically before writing any object. Repeated parts never consume it twice.
 const inserted=await deps.db.run(`INSERT OR IGNORE INTO mail_uploads
 SELECT ?,?,?,?,'uploading',? WHERE COALESCE((SELECT SUM(bytes) FROM mail_uploads WHERE account_id=?),0)+?<=?`,
 ...args,bytes,now,account,bytes,QUOTA);
 const row=await deps.db.first('SELECT * FROM mail_uploads WHERE account_id=? AND operation_id=? AND chunk_hash=?',...args);
 if(!row)return 413;
 if(row.bytes!==bytes)return 409;
 if(row.state==='deleting')return 409;
 if(row.state==='ready' && await deps.blobs.head(await key(...args)))return 204;
 if(!inserted.changes) {
  const claimed=await deps.db.run(`UPDATE mail_uploads SET state='uploading',updated_at=?
   WHERE account_id=? AND operation_id=? AND chunk_hash=? AND (state='ready' OR (state='uploading' AND updated_at<?))`,now,...args,now-5*60*1000);
  if(!claimed.changes)return 409;
 }
 const object=await key(...args);
 const ok=await deps.blobs.put(object,new Blob(parts).stream(),{sha256:hash});
 if(!ok){await deps.db.run("UPDATE mail_uploads SET state='ready' WHERE account_id=? AND operation_id=? AND chunk_hash=?",...args);return 400;}
 const stillAuthorized=await mailWriteLink(deps,account,email);
 const finished=await deps.db.first("SELECT response_status FROM provider_operations WHERE account_id=? AND operation_id=? AND state='done'",account,operation);
 const current=await deps.db.first('SELECT state FROM mail_uploads WHERE account_id=? AND operation_id=? AND chunk_hash=?',...args);
 if(!stillAuthorized || !current || current.state==='deleting' || (finished?.response_status>=200&&finished.response_status<300)) {
  await deps.blobs.delete(object);
  await deps.db.run('DELETE FROM mail_uploads WHERE account_id=? AND operation_id=? AND chunk_hash=?',...args);
  return stillAuthorized ? (finished?.response_status>=200&&finished.response_status<300 ? 204 : 409) : 403;
 }
 await deps.db.run("UPDATE mail_uploads SET state='ready',updated_at=? WHERE account_id=? AND operation_id=? AND chunk_hash=?",deps.now(),...args);
 return 204;
}

export async function mailPartsReady(deps,account,operation,attachments) {
 for(const attachment of attachments) {
  let bytes=0;
  for(const hash of attachment.chunks) {
   const row=await deps.db.first("SELECT bytes FROM mail_uploads WHERE account_id=? AND operation_id=? AND chunk_hash=? AND state='ready'",account,operation,hash);
   if(!row)return false;
   const object=await deps.blobs.head(await key(account,operation,hash));
   if(!object||object.size!==row.bytes)return false;
   bytes+=row.bytes;
  }
  if(bytes!==attachment.bytes)return false;
 }
 return true;
}

export async function* mailAttachment(deps,account,operation,attachment) {
 let bytes=0;
 for(const hash of attachment.chunks) {
  const object=await deps.blobs.get(await key(account,operation,hash));
  if(!object)throw new Error('mail attachment part unavailable');
  const reader=object.body.getReader();
  try {for(;;){const item=await reader.read();if(item.done)break;bytes+=item.value.length;
   if(bytes>attachment.bytes)throw new Error('mail attachment size changed');yield item.value;}}
  finally {await reader.cancel().catch(()=>{});reader.releaseLock();}
 }
 if(bytes!==attachment.bytes)throw new Error('mail attachment incomplete');
}

export async function removeMailParts(deps,account,operation) {
 const rows=await deps.db.all('SELECT * FROM mail_uploads WHERE account_id=? AND operation_id=?',account,operation);
 for(const row of rows) {
  await deps.db.run("UPDATE mail_uploads SET state='deleting' WHERE account_id=? AND operation_id=? AND chunk_hash=?",account,operation,row.chunk_hash);
  await deps.blobs.delete(await key(account,operation,row.chunk_hash));
  await deps.db.run('DELETE FROM mail_uploads WHERE account_id=? AND operation_id=? AND chunk_hash=?',account,operation,row.chunk_hash);
 }
}

export async function sweepMailParts(deps) {
 const rows=await deps.db.all(`SELECT u.* FROM mail_uploads u WHERE u.updated_at<?
  AND NOT EXISTS(SELECT 1 FROM provider_operations p WHERE p.account_id=u.account_id AND p.operation_id=u.operation_id AND p.state<>'done')
  ORDER BY u.updated_at LIMIT 100`,deps.now()-DAY);
 for(const row of rows) {
  const claimed=await deps.db.run(`UPDATE mail_uploads SET state='deleting' WHERE account_id=? AND operation_id=? AND chunk_hash=? AND updated_at=?
   AND NOT EXISTS(SELECT 1 FROM provider_operations p WHERE p.account_id=? AND p.operation_id=? AND p.state<>'done')`,
   row.account_id,row.operation_id,row.chunk_hash,row.updated_at,row.account_id,row.operation_id);
  if(!claimed.changes)continue;
  await deps.blobs.delete(await key(row.account_id,row.operation_id,row.chunk_hash));
  await deps.db.run("DELETE FROM mail_uploads WHERE account_id=? AND operation_id=? AND chunk_hash=? AND state='deleting'",row.account_id,row.operation_id,row.chunk_hash);
 }
}
