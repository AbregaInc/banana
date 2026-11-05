import test from 'node:test';
import assert from 'node:assert/strict';
import {setup,device} from './helpers.js';
const calendar='openid email https://www.googleapis.com/auth/calendar';
const mail='openid email https://www.googleapis.com/auth/gmail.modify';
async function user(s,grant=true) {
 s.google.person('calendar','sub-noor','noor@plan.example','calendar-refresh',{scopes:calendar});
 const a=(await s.signIn('calendar',device('device-noor'))).json;
 if(grant)await s.db.run('INSERT INTO feature_access VALUES (?,?,1,NULL,?)',a.account.id,'email',s.now());
 return a;
}
const connect=(s,a,code='mail')=>s.call('POST','/v1/google/mail',{session:a.session,body:{email:'noor@plan.example',code}});
test('mail eligibility is decided before provider consent is redeemed',async()=>{
 const s=setup(),a=await user(s,false),before=s.google.calls.exchange;
 assert.equal((await connect(s,a)).status,403);assert.equal(s.google.calls.exchange,before);
});
test('Mail consent and forgetting Mail preserve the Calendar grant byte for byte',async()=>{
 const s=setup(),a=await user(s);
 const before=await s.db.first('SELECT refresh_token,scopes,status FROM google_links WHERE sub=?','sub-noor');
 s.google.person('mail','sub-noor','noor@plan.example','mail-refresh',{scopes:mail});
 assert.equal((await connect(s,a)).status,200);
 assert.deepEqual(await s.db.first('SELECT refresh_token,scopes,status FROM google_links WHERE sub=?','sub-noor'),before);
 const account=await s.call('GET','/v1/account',{session:a.session});
 assert.equal(account.json.google[0].capabilities.calendarWrite,true);
 assert.equal(account.json.google[0].capabilities.mailModify,true);
 const row=await s.db.first('SELECT * FROM mail_grants');
 assert.equal(row.client_id,'web-client');assert.notEqual(row.refresh_token,'mail-refresh');
 assert.equal((await s.call('DELETE','/v1/google/mail',{session:a.session,body:{email:'noor@plan.example'}})).status,204);
 assert.deepEqual(await s.db.first('SELECT refresh_token,scopes,status FROM google_links WHERE sub=?','sub-noor'),before);
 const after=await s.call('GET','/v1/account',{session:a.session});
 assert.equal(after.json.google[0].capabilities.mailRead,false);
 assert.equal(after.json.google[0].capabilities.calendarRead,true);
 assert.equal(s.google.calls.revoke.length,0);
});
test('declined scope upgrade and a different Google identity leave existing grants intact',async()=>{
 const s=setup(),a=await user(s);
 s.google.person('mail','sub-noor','noor@plan.example','mail-refresh',{scopes:mail});await connect(s,a);
 const before=await s.db.first('SELECT * FROM mail_grants');
 s.google.person('declined','sub-noor','noor@plan.example','new-token',{scopes:'openid email'});
 assert.equal((await connect(s,a,'declined')).status,403);
 s.google.person('other','sub-other','other@plan.example','other-refresh',{scopes:mail});
 assert.equal((await connect(s,a,'other')).status,409);
 assert.deepEqual(await s.db.first('SELECT * FROM mail_grants'),before);
});
