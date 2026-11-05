import test from 'node:test';
import assert from 'node:assert/strict';
import {composeMail,parseMailComposition} from '../src/mail-compose.js';
const input=()=>({from:{address:'noor@plan.example',name:'Noor'},to:[{address:'reader@plan.example',name:'Reader'}],cc:[],bcc:[{address:'hidden@plan.example'}],subject:'Review café',plain:'Plain body',html:'<p>Rich body</p>',attachments:[]});
test('MIME preserves Unicode, reply identity, Bcc and alternative bodies',async()=>{
 const draft=parseMailComposition({...input(),inReplyTo:'<original@plan.example>',references:['<original@plan.example>']},'noor@plan.example');assert.ok(draft);
 const raw=await new Response(composeMail(draft,{messageID:'<stable@plan.example>',date:Date.UTC(2026,10,5),attachment:async function*(){}})).text();
 assert.match(raw,/Bcc: hidden@plan.example/);assert.match(raw,/Message-ID: <stable@plan.example>/);
 assert.match(raw,/In-Reply-To: <original@plan.example>/);assert.match(raw,/multipart\/alternative/);
 assert.match(raw,/text\/plain/);assert.match(raw,/text\/html/);assert.match(raw,/Subject: =\?UTF-8\?/i);
});
test('attachments stream through the MIME writer without file or URL access',async()=>{
 const data=Buffer.from([0,1,2,3,255]);const description=parseMailComposition({...input(),attachments:[{name:'fixture.bin',mimeType:'application/octet-stream',bytes:data.length,chunks:['a'.repeat(64)]}]},'noor@plan.example');
 let reads=0;
 const raw=await new Response(composeMail(description,{messageID:'<attachment@plan.example>',date:0,attachment:async function*(a){assert.equal(a.name,'fixture.bin');reads++;yield data;}})).text();
 assert.equal(reads,1);assert.match(raw,/Content-Disposition: attachment; filename=fixture.bin/);assert.ok(raw.includes(data.toString('base64')));
});
test('unsafe headers, sender substitution and malformed attachment references are refused',()=>{
 for(const change of [{subject:'subject\r\nBcc: attacker@plan.example'},{from:{address:'other@plan.example'}},{to:[{address:'reader@plan.example\nBcc:x@y'}]},
  {attachments:[{name:'x',mimeType:'text/plain',bytes:1,chunks:['https://foreign.example']}]}]) {
  assert.equal(parseMailComposition({...input(),...change},'noor@plan.example'),null);
 }
 const parsed=parseMailComposition({...input(),path:'/etc/passwd',headers:{Bcc:'attacker@plan.example'}},'noor@plan.example');assert.equal(parsed.path,undefined);assert.equal(parsed.headers,undefined);
});
