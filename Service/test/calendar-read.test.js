import test from 'node:test';
import assert from 'node:assert/strict';
import {setup,device,DAY} from './helpers.js';
import {parseCalendarRead} from '../src/calendar-read.js';

async function signed(s,name='noor',grant=true) {
 s.google.person('code-'+name,'sub-'+name,name+'@plan.example');
 const a=(await s.signIn('code-'+name,device('device-'+name))).json;
 if(grant) await s.db.run('INSERT INTO feature_access VALUES (?, ?, 1, NULL, ?)',a.account.id,'calendarCloud',s.now());
 return a;
}
const read=(extra={})=>({email:'noor@plan.example',resource:'events',calendarID:'work',query:[{name:'singleEvents',value:'true'},{name:'maxResults',value:'2500'}],...extra});
const call=(s,a,r)=>s.call('POST','/v1/calendar/read',{session:a.session,body:r});

test('calendar reads require authentication, eligibility and a grant linked to the calling account',async()=>{
 const s=setup(),a=await signed(s,'noor',false),b=await signed(s,'other');let calls=0;
 s.google.calendarRead=async()=>{calls++;return {status:200,body:{items:[]}};};
 assert.equal((await s.call('POST','/v1/calendar/read',{body:read()})).status,401);
 assert.equal((await call(s,a,read())).status,403);
 assert.equal((await call(s,b,read())).status,403);
 assert.equal(calls,0);
});

test('typed request cannot inject hosts, paths, methods or unsupported query parameters',()=>{
 for(const bad of [read({resource:'https://evil.example'}),read({resource:'__proto__'}),read({calendarID:''}),
   read({query:[{name:'access_token',value:'secret'}]}),read({query:[{name:'maxResults',value:'2501'}]}),
   read({query:[{name:'pageToken',value:'a'},{name:'pageToken',value:'b'}]})]) assert.equal(parseCalendarRead(bad),null);
 const good=parseCalendarRead({...read(),host:'https://evil.example',method:'DELETE',path:'/calendars/other'});
 assert.equal(good.method,undefined);assert.equal(good.host,undefined);assert.equal(good.path,undefined);
});

test('native paging and incremental sync use encrypted bound cursors and preserve event data',async()=>{
 const s=setup(),a=await signed(s);const requests=[];
 s.google.calendarRead=async(token,r)=>{requests.push(r); return {status:200,body:{items:[{id:'event',etag:'etag',reminders:{useDefault:true}}],
   ...(r.query.some(q=>q.name==='pageToken')?{nextSyncToken:'provider-sync'}:{nextPageToken:'provider-page'})}};};
 const first=await call(s,a,read());assert.equal(first.status,200);
 assert.match(first.json.nextPageToken,/^banana-calendar:/);assert.equal(JSON.stringify(first.json).includes('provider-page'),false);
 const second=await call(s,a,read({query:[...read().query,{name:'pageToken',value:first.json.nextPageToken}]}));
 assert.equal(second.status,200);assert.equal(requests[1].query.at(-1).value,'provider-page');
 assert.match(second.json.nextSyncToken,/^banana-calendar:/);
 assert.equal(second.json.items[0].etag,'etag');assert.equal(second.json.items[0].reminders.useDefault,true);
 await call(s,a,read({query:[...read().query,{name:'syncToken',value:second.json.nextSyncToken}]}));
 assert.equal(requests[2].query.at(-1).value,'provider-sync');
});

test('cursors cannot cross account, calendar, query, kind, expiry or provider grant',async()=>{
 const s=setup(),a=await signed(s),b=await signed(s,'other');let calls=0;
 s.google.calendarRead=async()=>{calls++;return {status:200,body:{items:[],nextPageToken:'provider-page',nextSyncToken:'provider-sync'}};};
 const first=await call(s,a,read());const q={name:'pageToken',value:first.json.nextPageToken};
 for(const request of [read({calendarID:'other',query:[...read().query,q]}),
   read({query:[...read().query,{name:'q',value:'different'},q]}),
   read({query:[...read().query,{name:'syncToken',value:first.json.nextPageToken}]}),
   read({query:[...read().query,{name:'syncToken',value:'native-old-token'}]})]) {
  assert.equal((await call(s,a,request)).status,410);
 }
 assert.equal((await call(s,b,read({email:'other@plan.example',query:[...read().query,q]}))).status,410);
 assert.equal(calls,1);
 s.advance(DAY+1);assert.equal((await call(s,a,read({query:[...read().query,q]}))).status,410);
 assert.equal(calls,1);
});

test('scope and provider failures remain failures, never empty calendars',async()=>{
 const s=setup(),a=await signed(s);
 s.google.calendarRead=async()=>({status:410,body:{error:{message:'Gone',code:410}}});
 assert.equal((await call(s,a,read())).status,410);
 s.google.calendarRead=async()=>{throw new Error('network');};
 assert.equal((await call(s,a,read())).status,502);
 await s.db.run("UPDATE google_links SET scopes='openid email' WHERE account_id=?",a.account.id);
 assert.equal((await call(s,a,read())).status,403);
 assert.deepEqual(s.google.booking,{insert:[],get:[],patch:[],delete:[]});
});


test('reconnecting the grant invalidates previously issued cursors',async()=>{
 const s=setup(),a=await signed(s); let calls=0;
 s.google.calendarRead=async()=>{calls++;return {status:200,body:{nextSyncToken:'old-sync'}};};
 const first=await call(s,a,read());
 await s.db.run("UPDATE google_links SET refresh_token='replacement-encrypted-grant' WHERE account_id=?",a.account.id);
 const result=await call(s,a,read({query:[...read().query,{name:'syncToken',value:first.json.nextSyncToken}]}));
 assert.equal(result.status,410);assert.equal(calls,1);
});
