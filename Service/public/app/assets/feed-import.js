// Dependency-free importer for browsers and Node 24. No credentials enter logs or saved metadata.
import {normalizeAnalysis} from './analysis-model.js';
export class FeedImportError extends Error {constructor(message,status=0){super(message);this.name='FeedImportError';this.status=status;}}
const delay=(ms,signal)=>new Promise((resolve,reject)=>{signal?.throwIfAborted();const done=()=>{signal?.removeEventListener('abort',abort);resolve();};const id=setTimeout(done,ms);const abort=()=>{clearTimeout(id);reject(new DOMException('Cancelled','AbortError'));};signal?.addEventListener('abort',abort,{once:true});});
const messages={400:'The feed request is invalid. Rebuild it using the feed controls.',401:'The credential is invalid. Create a new connection.',403:'Access or consent changed. Refresh the type list and start again.',404:'The connection or attachment is unavailable, expired or revoked.',409:'Data or access changed during the export. Start again; no partial download was saved.',413:'The export page is too large. Reduce the page limit or selected types.',429:'The request budget is busy. Wait and retry.',503:'Shared data or a selected calendar is unavailable. Retry later.'};
const signature=page=>JSON.stringify([page.contentVersion,page.access,page.types,page.analysis??null]);
export async function collectFeed(url,{fetcher=fetch,signal,onProgress=()=>{},wait=delay,paceMs=1100,maxBytes=64*1024*1024,maxRecords=100000,token=null,credentials='omit'}={}){
  const first=new URL(url);if(!['http:','https:'].includes(first.protocol))throw new FeedImportError('Use an HTTP or HTTPS feed URL.');
  first.searchParams.delete('view');first.searchParams.delete('cursor');first.searchParams.set('format','json');
  if(token)first.searchParams.delete('signature');
  let bytes=0,requests=0,pages=0,expected=null,initial=null;
  const seen=new Set(),ids=new Set(),records=[],calendarIssues=new Map();
  async function request(target,binary=false){
    const u=new URL(target);if(u.origin!==first.origin||u.username||u.password)throw new FeedImportError('The feed returned an unexpected URL origin.');
    for(let attempt=0;attempt<4;attempt++){
      signal?.throwIfAborted();
      if(requests++)await wait(paceMs,signal);
      const response=await fetcher(u.href,{headers:token?{Authorization:`Bearer ${token}`}:{},credentials,cache:'no-store',signal,redirect:'error'});
      if(response.status===429&&attempt<3){const raw=response.headers.get('Retry-After');const seconds=/^\d+$/.test(raw??'')?Number(raw):Math.ceil((Date.parse(raw)-Date.now())/1000);const ms=Math.max(1000,Math.min(3600000,(Number.isFinite(seconds)?seconds:60)*1000));onProgress({stage:'waiting',pages,records:records.length,retryAfterSeconds:Math.ceil(ms/1000)});await wait(ms,signal);continue;}
      if(response.status===503){
        let detail=null;
        try{const reader=response.body?.getReader(),chunks=[];let size=0;if(reader){try{for(;;){const {value,done}=await reader.read();if(done)break;size+=value.byteLength;if(size>16384){await reader.cancel();break;}chunks.push(value);}if(size<=16384){const bytes=new Uint8Array(size);let offset=0;for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.length;}detail=JSON.parse(new TextDecoder().decode(bytes));}}finally{reader.releaseLock();}}}catch{}
        if(detail?.error==='calendar_unavailable'){
          const issues=Array.isArray(detail.issues)?detail.issues:[];
          const message=issues.some(i=>i.reason==='reconnect')?'The owner needs to reconnect a selected Google account.':issues.some(i=>i.reason==='unavailable')?'Google no longer provides access to a selected calendar. The owner must restore access or remove it from the share.':'A selected calendar is temporarily unavailable. Retry later.';
          const error=new FeedImportError(message+' You can also exclude calendar from the requested types. No partial export was saved.',503);error.issues=issues;throw error;
        }
      }
      if(!response.ok)throw new FeedImportError(messages[response.status]??`Feed request failed (HTTP ${response.status}).`,response.status);
      const declared=Number(response.headers.get('Content-Length'));if(declared>maxBytes-bytes)throw new FeedImportError('The export exceeds the 64 MiB browser download limit. Select fewer types or use the developer importer with a larger maxBytes limit.');
      // Bound streamed reads before decoding/parsing a response; servers may omit Content-Length.
      const chunks=[];let length=0;
      const reader=response.body?.getReader();
      if(reader){try{for(;;){const {value,done}=await reader.read();if(done)break;length+=value.byteLength;if(bytes+length>maxBytes){await reader.cancel();throw new FeedImportError('The export exceeds the configured size limit. Select fewer types or increase maxBytes in the developer importer.');}chunks.push(value);}}finally{reader.releaseLock();}}
      bytes+=length;const data=new Uint8Array(length);let offset=0;for(const c of chunks){data.set(c,offset);offset+=c.length;}
      if(binary)return {bytes:data,mediaType:(response.headers.get('Content-Type')??'').split(';')[0]};
      try{return JSON.parse(new TextDecoder().decode(data));}catch{throw new FeedImportError('The feed did not return valid JSON.');}
    }
  }
  let next=first.href;
  while(next){
    signal?.throwIfAborted();
    if(seen.has(next))throw new FeedImportError('The feed repeated a page. No partial download was saved.');seen.add(next);
    const page=await request(next);
    if(page.schema!=='banana.feed.v2'||!Array.isArray(page.records)||!Array.isArray(page.types))throw new FeedImportError('Unsupported feed response schema.');
    if(initial==null){initial=page;expected=signature(page);}else if(signature(page)!==expected)throw new FeedImportError(messages[409],409);
    for(const issue of page.calendarIssues??[])calendarIssues.set(issue.calendarRef??issue.calendarIndex,issue);
    for(const record of page.records){if(!page.types.includes(record.type)||typeof record.id!=='string'||!record.data||typeof record.data!=='object'||Array.isArray(record.data))throw new FeedImportError('The feed returned an invalid record.');const id=JSON.stringify([record.type,record.id]);if(ids.has(id))throw new FeedImportError('Records changed or repeated while paging. Start again.',409);ids.add(id);records.push(record);if(records.length>maxRecords)throw new FeedImportError('The export exceeds the configured record limit. Select fewer types or increase maxRecords in the developer importer.');}
    pages++;onProgress({stage:'reading',pages,records:records.length,bytes});next=page.next;
    if(next!=null&&typeof next!=='string')throw new FeedImportError('The feed returned an invalid next-page URL.');
  }
  const verifyURL=new URL(first);if(initial.calendarWindow){verifyURL.searchParams.delete('calendarDays');verifyURL.searchParams.set('from',initial.calendarWindow.from);verifyURL.searchParams.set('to',initial.calendarWindow.to);}
  const verify=await request(verifyURL.href);if(signature(verify)!==expected)throw new FeedImportError(messages[409],409);
  const result=normalizeAnalysis(records,{types:initial.types,access:initial.access,ownBundleID:initial.analysis?.ownBundleID??null});
  result.generatedAt=new Date().toISOString();result.access=initial.access;result.types=initial.types;result.calendarWindow=initial.calendarWindow??null;result.contentVersion=initial.contentVersion;
  if(calendarIssues.size){
    result.calendarIssues=[...calendarIssues.values()];
    result.warnings.push('Calendar is incomplete. Preserve existing data for unavailable calendars when reconciling this export.');
  }
  result.collection={pages,records:records.length,bytes,verifiedAt:result.generatedAt};
  // request() remains closed over the auth/session context for optional asset downloads.
  return {result,request,verify:async()=>{const page=await request(verifyURL.href);if(signature(page)!==expected)throw new FeedImportError(messages[409],409);},get bytes(){return bytes;}};
}
export async function importFeed(url,options={}){return (await collectFeed(url,options)).result;}
