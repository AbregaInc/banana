import test from 'node:test';
import assert from 'node:assert/strict';
import {mailGoogle} from '../src/mail-google.js';
const json=x=>new Response(JSON.stringify(x),{headers:{'content-type':'application/json'}});
test('Gmail upload streams MIME and frozen draft metadata only to the draft endpoint',async()=>{
 const calls=[];const api=mailGoogle(async(url,options)=>{calls.push({url,options,raw:await new Response(options.body).text()});return json({id:'sent',labelIds:['SENT']});});
 const answer=await api.mailDraftUpload('token','send',{id:'draft',threadID:'thread'},new Response('From: noor@plan.example\r\n\r\nMessage').body);
 assert.equal(answer.status,200);assert.match(calls[0].url,/\/upload\/gmail\/v1\/users\/me\/drafts\/send\?uploadType=multipart$/);
 assert.match(calls[0].raw,/"id":"draft","message":\{"threadId":"thread"\}/);assert.match(calls[0].raw,/Content-Type: message\/rfc822/);
 assert.equal(calls[0].options.redirect,'error');assert.equal(calls[0].options.duplex,'half');
 await assert.rejects(api.mailDraftUpload('token','messages.send',{},new Response('').body));assert.equal(calls.length,1);
});
test('Sent reconciliation verifies label and exact Message-ID; partial or duplicate listings stay unresolved',async()=>{
 let listing={messages:[{id:'sent'}]},message={id:'sent',labelIds:['SENT'],payload:{headers:[{name:'Message-ID',value:'<stable@plan.example>'}]}};
 const api=mailGoogle(async url=>json(url.includes('/messages/sent?')?message:listing));
 assert.equal((await api.mailFindSent('token','<stable@plan.example>')).body.id,'sent');
 message.labelIds=['INBOX'];assert.equal(await api.mailFindSent('token','<stable@plan.example>'),null);
 message.labelIds=['SENT'];message.payload.headers[0].value='<other@plan.example>';assert.equal(await api.mailFindSent('token','<stable@plan.example>'),null);
 listing.nextPageToken='next';assert.equal(await api.mailFindSent('token','<stable@plan.example>'),null);
 listing={messages:[{id:'one'},{id:'two'}]};assert.equal(await api.mailFindSent('token','<stable@plan.example>'),null);
});
test('draft reconciliation requires one complete owned Message-ID match',async()=>{
 let draft={id:'draft',message:{id:'message',labelIds:['DRAFT'],payload:{headers:[{name:'message-id',value:'<stable@plan.example>'}]}}};
 const api=mailGoogle(async url=>json(url.includes('/drafts/draft?')?draft:{drafts:[{id:'draft'}]}));
 assert.equal((await api.mailFindDraft('token','<stable@plan.example>')).body.id,'draft');
 draft.message.payload.headers=[];assert.equal(await api.mailFindDraft('token','<stable@plan.example>'),null);
});
test('unreadable provider bodies and false send success remain uncertain',async()=>{
 const api=mailGoogle(async()=>json({id:'wrong',labelIds:['DRAFT']}));
 await assert.rejects(api.mailDraftUpload('token','send',{id:'draft'},new Response('x').body));
 await assert.rejects(mailGoogle(async()=>new Response('x'.repeat(300000))).mailFindSent('token','<x@plan.example>'));
});
