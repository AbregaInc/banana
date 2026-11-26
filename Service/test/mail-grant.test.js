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
test('Mail consent carrying every scope renews the Calendar grant from the same code',async()=>{
 const s=setup(),a=await user(s);
 await s.db.run("UPDATE google_links SET status='refused' WHERE sub=?",'sub-noor');
 const all='openid email https://www.googleapis.com/auth/calendar.events https://www.googleapis.com/auth/calendar.calendarlist.readonly https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/contacts.readonly https://www.googleapis.com/auth/contacts.other.readonly';
 s.google.person('all','sub-noor','noor@plan.example','all-refresh',{scopes:all});
 const before=s.google.calls.exchange;
 assert.equal((await connect(s,a,'all')).status,200);
 assert.equal(s.google.calls.exchange,before+1);
 const link=await s.db.first('SELECT refresh_token,scopes,status FROM google_links WHERE sub=?','sub-noor');
 assert.equal(link.scopes,all);assert.equal(link.status,'ok');assert.notEqual(link.refresh_token,'all-refresh');
 const grant=await s.db.first('SELECT scopes,status FROM mail_grants WHERE google_sub=?','sub-noor');
 assert.equal(grant.scopes,all);assert.equal(grant.status,'ok');
 const account=(await s.call('GET','/v1/account',{session:a.session})).json.google[0].capabilities;
 assert.equal(account.calendarWrite,true);assert.equal(account.calendarList,true);assert.equal(account.mailModify,true);
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

test('existing reconnect atomically upgrades Calendar and Mail with one code exchange',async()=>{
 const s=setup(),a=await user(s);
 s.google.person('mail','sub-noor','noor@plan.example','mail-refresh',{scopes:mail});await connect(s,a);
 await s.db.run('INSERT INTO sender_contact_syncs VALUES (?,?,?)',a.account.id,'sub-noor',s.now());
 const scopes=calendar+' https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/contacts.readonly https://www.googleapis.com/auth/contacts.other.readonly';
 s.google.person('upgrade','sub-noor','noor@plan.example','combined-refresh',{scopes});
 const before=s.google.calls.exchange;
 const result=await s.signIn('upgrade',device('device-noor'),a.session);
 assert.equal(result.status,200);assert.equal(s.google.calls.exchange,before+1);
 const grant=await s.db.first('SELECT * FROM mail_grants WHERE google_sub=?','sub-noor');
 assert.equal(grant.scopes,scopes);assert.equal(grant.status,'ok');
 assert.equal(result.json.account.google[0].capabilities.calendarRead,true);
 assert.equal(result.json.account.google[0].capabilities.mailRead,true);
 assert.ok(result.json.account.google[0].permissionScopes.mail.includes('https://www.googleapis.com/auth/contacts.readonly'));
 assert.equal(await s.db.first('SELECT * FROM sender_contact_syncs WHERE google_sub=?','sub-noor'),null);
});

test('Calendar-only reconnect preserves an existing separate Mail grant and reports each grant accurately',async()=>{
 const s=setup(),a=await user(s);
 s.google.person('mail','sub-noor','noor@plan.example','mail-refresh',{scopes:mail});await connect(s,a);
 const before=await s.db.first('SELECT * FROM mail_grants');
 s.google.person('calendar-only','sub-noor','noor@plan.example','calendar-refresh-2',{scopes:calendar});
 const result=await s.signIn('calendar-only',device('device-noor'),a.session);
 assert.equal(result.status,200);assert.deepEqual(await s.db.first('SELECT * FROM mail_grants'),before);
 assert.deepEqual(result.json.account.google[0].permissionScopes.mail,mail.split(' ').sort());
 assert.deepEqual(result.json.account.google[0].permissionScopes.calendar,calendar.split(' ').sort());
});

test('refused Mail retains reconnect intent without reporting usable access',async()=>{
 const s=setup(),a=await user(s);
 s.google.person('mail','sub-noor','noor@plan.example','mail-refresh',{scopes:mail});await connect(s,a);
 await s.db.run("UPDATE mail_grants SET status='refused' WHERE google_sub=?",'sub-noor');
 const result=await s.call('GET','/v1/account',{session:a.session});
 assert.equal(result.json.google[0].capabilities.mailRead,false);
 assert.deepEqual(result.json.google[0].permissionScopes.mail,mail.split(' ').sort());
});

test('Calendar reconnect cannot re-enable explicitly disconnected Mail from aggregate Google scopes',async()=>{
 const s=setup(),a=await user(s);
 s.google.person('mail','sub-noor','noor@plan.example','mail-refresh',{scopes:mail});await connect(s,a);
 await s.call('DELETE','/v1/google/mail',{session:a.session,body:{email:'noor@plan.example'}});
 const before=await s.db.first('SELECT * FROM mail_grants');
 s.google.person('aggregate','sub-noor','noor@plan.example','combined-refresh',{scopes:calendar+' '+mail});
 const result=await s.signIn('aggregate',device('device-noor'),a.session);
 assert.equal(result.status,200);
 assert.equal(result.json.account.google[0].capabilities.mailRead,false);
 assert.deepEqual(await s.db.first('SELECT * FROM mail_grants'),before);
});
