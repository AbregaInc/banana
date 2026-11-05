import MailComposer from 'nodemailer/lib/mail-composer/index.js';
import {Readable} from 'node:stream';

const address=x=>typeof x==='string'&&x.length<=320&&/^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$/.test(x);
const text=(x,max)=>typeof x==='string'&&x.length<=max;
const header=x=>text(x,998)&&!/[\r\n\0]/.test(x);
const people=x=>Array.isArray(x)&&x.length<=100&&x.every(p=>p&&address(p.address)&&(p.name==null||header(p.name)));
/** A data-only MIME description: never accept filesystem paths, URLs or arbitrary headers. */
export function parseMailComposition(x,email) {
 if(!x||!address(email)||!people(x.to)||!people(x.cc)||!people(x.bcc)||!header(x.subject)
  ||!text(x.plain,262144)||!text(x.html,524288)||!Array.isArray(x.attachments)||x.attachments.length>100)return null;
 if(!address(x.from?.address)||x.from.address.toLowerCase()!==email.toLowerCase()||(x.from.name!=null&&!header(x.from.name)))return null;
 if(x.inReplyTo!=null&&(!header(x.inReplyTo)||!/^<[^<>\s]+@[^<>\s]+>$/.test(x.inReplyTo)))return null;
 if(x.references!=null&&(!Array.isArray(x.references)||x.references.length>100||x.references.some(v=>!header(v)||!/^<[^<>\s]+@[^<>\s]+>$/.test(v))))return null;
 if(x.threadID!=null&&(typeof x.threadID!=='string'||!/^[a-zA-Z0-9_-]{1,200}$/.test(x.threadID)))return null;
 let bytes=0;
 for(const a of x.attachments) {
  if(!a||!header(a.name)||!a.name||(!text(a.mimeType,200)||!/^[-\w.+]+\/[-\w.+]+$/.test(a.mimeType))||!Number.isSafeInteger(a.bytes)||a.bytes<0
   ||!Array.isArray(a.chunks)||a.chunks.length>100||a.chunks.some(h=>typeof h!=='string'||!(/^[a-f0-9]{64}$/).test(h)))return null;
  bytes+=a.bytes;
 }
 if(bytes>25*1024*1024||new TextEncoder().encode(JSON.stringify(x)).length>512*1024)return null;
 const recipients=xs=>xs.map(p=>({address:p.address,name:p.name??''}));
 return {from:{address:email.toLowerCase(),name:x.from.name??''},to:recipients(x.to),cc:recipients(x.cc),bcc:recipients(x.bcc),subject:x.subject,
  plain:x.plain,html:x.html,attachments:x.attachments.map(({name,mimeType,bytes,chunks})=>({name,mimeType,bytes,chunks})),
  inReplyTo:x.inReplyTo??null,references:x.references??[],threadID:x.threadID??null};
}
/** Streams attachments from the authenticated store. No SMTP transport is imported or used. */
export function composeMail(description,{messageID,date,attachment}) {
 const options={from:description.from,to:description.to,cc:description.cc,bcc:description.bcc,
  subject:description.subject,text:description.plain,html:description.html||undefined,
  messageId:messageID,date:new Date(date),inReplyTo:description.inReplyTo??undefined,references:description.references,
  disableFileAccess:true,disableUrlAccess:true,attachments:description.attachments.map(a=>({
   filename:a.name,contentType:a.mimeType,content:Readable.from(attachment(a)),
  }))};
 const message=new MailComposer(options).compile();
 // Gmail derives its delivery envelope from MIME headers, including Bcc. Gmail removes Bcc
 // from recipients' copies; the composer must not discard it before the Gmail API sees it.
 message.keepBcc=true;
 return Readable.toWeb(message.createReadStream());
}
