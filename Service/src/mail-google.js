import {Readable} from 'node:stream';
import {GoogleError} from './google.js';
const root='https://gmail.googleapis.com/gmail/v1/users/me';
async function body(response) {
 const reader=response.body?.getReader();if(!reader)throw new GoogleError('mail response missing',502);
 const chunks=[];let bytes=0;
 try {for(;;){const r=await reader.read();if(r.done)break;bytes+=r.value.length;if(bytes>256*1024)throw new GoogleError('mail response too large',502);chunks.push(r.value);}}
 catch(e){await reader.cancel().catch(()=>{});throw e;}
 const all=new Uint8Array(bytes);let offset=0;for(const c of chunks){all.set(c,offset);offset+=c.length;}
 try{return JSON.parse(new TextDecoder().decode(all));}catch{throw new GoogleError('mail response invalid',502);}
}
/** Gmail-only routes. MIME bytes stream; an upload is attempted once, never retried here. */
export function mailGoogle(fetch) {
 const get=async(token,path)=>{
  const response=await fetch(`${root}/${path}`,{headers:{authorization:`Bearer ${token}`},redirect:'error'});
  if(!response.ok)throw new GoogleError('mail reconciliation unavailable',response.status);
  return body(response);
 };
 const matchingHeader=(message,messageID)=>Array.isArray(message?.payload?.headers)&&message.payload.headers.some(h=>h.name?.toLowerCase()==='message-id'&&h.value?.trim()===messageID);
 return {
  async mailDraftUpload(token,action,metadata,mime) {
   if(!['create','send'].includes(action))throw new Error('unsupported draft action');
   const boundary=`banana_${crypto.randomUUID().replaceAll('-','')}`;
   const info={...(metadata.id?{id:metadata.id}:{}),message:{...(metadata.threadID?{threadId:metadata.threadID}:{})}};
   const encoder=new TextEncoder();
   async function* parts() {
    yield encoder.encode(`--${boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n${JSON.stringify(info)}\r\n--${boundary}\r\nContent-Type: message/rfc822\r\n\r\n`);
    const reader=mime.getReader();let complete=false;
    try{for(;;){const r=await reader.read();if(r.done){complete=true;break;}yield r.value;}}
    finally{if(!complete)await reader.cancel().catch(()=>{});reader.releaseLock();}
    yield encoder.encode(`\r\n--${boundary}--\r\n`);
   }
   const response=await fetch(`https://gmail.googleapis.com/upload/gmail/v1/users/me/drafts${action==='send'?'/send':''}?uploadType=multipart`,{
    method:'POST',headers:{authorization:`Bearer ${token}`,'content-type':`multipart/related; boundary=${boundary}`},
    body:Readable.toWeb(Readable.from(parts())),duplex:'half',redirect:'error',
   });
   const result=await body(response);
   if(response.ok&&(typeof result?.id!=='string'||(action==='send'&&!result.labelIds?.includes('SENT'))))throw new GoogleError('mail handoff response invalid',502);
   return {status:response.status,body:result};
  },
  async mailFindDraft(token,messageID) {
   const query=new URLSearchParams({q:`rfc822msgid:${messageID}`,maxResults:'100'});
   const result=await get(token,`drafts?${query}`);
   // Absence, duplicate matches or incomplete pages cannot authorize another create.
   if(result.nextPageToken||!Array.isArray(result.drafts)||result.drafts.length!==1)return null;
   const draft=await get(token,`drafts/${encodeURIComponent(result.drafts[0].id)}?format=metadata`);
   return typeof draft.id==='string'&&draft.message?.labelIds?.includes('DRAFT')&&matchingHeader(draft.message,messageID)?{status:200,body:draft}:null;
  },
  async mailFindSent(token,messageID) {
   const query=new URLSearchParams({q:`rfc822msgid:${messageID}`,labelIds:'SENT',maxResults:'100'});
   const result=await get(token,`messages?${query}`);
   if(result.nextPageToken||!Array.isArray(result.messages)||result.messages.length!==1)return null;
   const message=await get(token,`messages/${encodeURIComponent(result.messages[0].id)}?format=metadata`);
   return typeof message.id==='string'&&message.labelIds?.includes('SENT')&&matchingHeader(message,messageID)?{status:200,body:message}:null;
  },
 };
}
