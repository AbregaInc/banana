import test from 'node:test';
import assert from 'node:assert/strict';
import {setup,device} from './helpers.js';
import {GoogleRefused,createGoogle} from '../src/google.js';
import {parseMailRead} from '../src/mail-read.js';
const request=(extra={})=>({email:'noor@plan.example',resource:'messages',query:[],...extra});
async function signed(s,name='noor') {
 s.deps.sleep=async ms=>s.advance(ms);
 s.google.person(name,'sub-'+name,name+'@plan.example');
 const a=(await s.signIn(name,device('device-'+name))).json;
 await s.db.run('INSERT INTO feature_access VALUES (?,?,1,NULL,?)',a.account.id,'email',s.now());
 s.google.person('mail-'+name,'sub-'+name,name+'@plan.example','mail-'+name,{scopes:'https://www.googleapis.com/auth/gmail.modify'});
 assert.equal((await s.call('POST','/v1/google/mail',{session:a.session,body:{email:name+'@plan.example',code:'mail-'+name}})).status,200);
 return a;
}
const call=(s,a,r=request())=>s.call('POST','/v1/mail/read',{session:a?.session,body:r});
test('cloud mail reads use the Mail grant and preserve the provider page without exposing credentials',async()=>{
 const s=setup(),a=await signed(s);let credential;
 s.google.mailRead=async(token,r)=>{credential=token;assert.equal(r.resource,'messages');return {status:200,body:{messages:[{id:'m1',threadId:'t1'}],nextPageToken:'page'}};};
 const result=await call(s,a);assert.equal(result.status,200);assert.equal(credential,'access-mail-noor');
 assert.deepEqual(result.json,{messages:[{id:'m1',threadId:'t1'}],nextPageToken:'page'});
 const response=await s.app.request('/v1/mail/read',{method:'POST',headers:{authorization:'Bearer '+a.session,'content-type':'application/json'},body:JSON.stringify(request())});
 assert.equal(response.headers.get('cache-control'),'no-store');
});
test('mail requests cannot cross Banana accounts or bypass expired tester eligibility',async()=>{
 const s=setup(),a=await signed(s),b=await signed(s,'other');let reads=0;
 s.google.mailRead=async()=>{reads++;return {status:200,body:{}};};
 assert.equal((await call(s,null)).status,401);assert.equal((await call(s,b)).status,403);
 await s.db.run('UPDATE feature_access SET expires_at=? WHERE account_id=?',s.now()-1,a.account.id);
 assert.equal((await call(s,a)).status,403);assert.equal(reads,0);
});
test('revoked Mail grants never revoke the Calendar grant or return an empty inbox success',async()=>{
 const s=setup(),a=await signed(s);const before=await s.db.first('SELECT refresh_token,status FROM google_links');
 s.google.refused.add('mail-noor');
 assert.equal((await call(s,a)).status,403);
 assert.equal((await s.db.first('SELECT status FROM mail_grants')).status,'refused');
 assert.deepEqual(await s.db.first('SELECT refresh_token,status FROM google_links'),before);
});
test('typed mail resources reject arbitrary paths, methods and malformed pagination',()=>{
 for(const extra of [{resource:'__proto__'},{resource:'send'}, {resource:'message',id:'..'},
  {query:[{name:'maxResults',value:'501'}]},{query:[{name:'access_token',value:'token'}]}])assert.equal(parseMailRead(request(extra)),null);
 const good=parseMailRead({...request(),url:'https://evil.example',method:'POST'});
 assert.equal(good.url,undefined);assert.equal(good.method,undefined);
});
test('Google Mail transport streams a bounded body and encodes individual resource identifiers',async()=>{
 let captured;
 const google=createGoogle({},async(url,init)=>{captured={url,init};return Response.json({id:'message'});});
 const answer=await google.mailRead('access',{resource:'message',id:'a/b',query:[]});
 assert.equal(captured.url,'https://gmail.googleapis.com/gmail/v1/users/me/messages/a%2Fb?');
 assert.equal(captured.init.redirect,'manual');
 assert.deepEqual(await new Response(answer.stream).json(),{id:'message'});
 const oversized=createGoogle({},async()=>new Response('small',{headers:{'content-length':String(41*1024*1024)}}));
 await assert.rejects(oversized.mailRead('access',{resource:'profile',query:[]}),{name:'GoogleError'});
});
test('queued reads recheck revoked grants before contacting Gmail',async()=>{
 const s=setup(),a=await signed(s);let reads=0;
 s.google.mailRead=async()=>{reads++;return {status:200,body:{}};};
 assert.equal((await call(s,a)).status,200);
 s.deps.sleep=async ms=>{s.advance(ms);await s.db.run("UPDATE mail_grants SET status='unlinked'");};
 assert.equal((await call(s,a)).status,403);
 assert.equal(reads,1);
});
test('excess queued reads return retry guidance without contacting Gmail',async()=>{
 const s=setup(),a=await signed(s);let reads=0;
 s.google.mailRead=async()=>{reads++;return {status:200,body:{}};};
 await s.db.run('INSERT INTO mail_read_pacing VALUES (?,?)','sub-noor',s.now()+20_000);
 const response=await s.app.request('/v1/mail/read',{method:'POST',headers:{authorization:'Bearer '+a.session,'content-type':'application/json'},body:JSON.stringify(request())});
 assert.equal(response.status,429);assert.equal(response.headers.get('retry-after'),'1');assert.equal(reads,0);
});
