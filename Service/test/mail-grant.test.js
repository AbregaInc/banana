import test from 'node:test';
import assert from 'node:assert/strict';
import {setup,device} from './helpers.js';
const ALL='openid email https://www.googleapis.com/auth/calendar.events https://www.googleapis.com/auth/calendar.calendarlist.readonly https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/contacts.readonly https://www.googleapis.com/auth/contacts.other.readonly';
const CALENDAR='openid email https://www.googleapis.com/auth/calendar.events https://www.googleapis.com/auth/calendar.calendarlist.readonly';
async function user(s,scopes=ALL) {
 s.google.person('first','sub-noor','noor@plan.example','first-refresh',{scopes});
 const a=(await s.signIn('first',device('device-noor'))).json;
 await s.db.run('INSERT INTO feature_access VALUES (?,?,1,NULL,?)',a.account.id,'email',s.now());
 return a;
}
const capabilities=async(s,a)=>(await s.call('GET','/v1/account',{session:a.session})).json.google[0];
test('one grant: every consent carries Calendar and Mail together',async()=>{
 const s=setup(),a=await user(s);
 const g=await capabilities(s,a);
 assert.deepEqual([g.capabilities.calendarWrite,g.capabilities.calendarList,g.capabilities.mailRead,g.capabilities.mailModify,g.capabilities.mailSend],[true,true,true,true,true]);
 assert.deepEqual(g.permissionScopes.calendar,g.permissionScopes.mail);
});
test('Gmail unticked is Mail not connected; the next consent with it connects Mail, no other step',async()=>{
 const s=setup(),a=await user(s,CALENDAR);
 assert.equal((await capabilities(s,a)).capabilities.mailModify,false);
 s.google.person('again','sub-noor','noor@plan.example','again-refresh',{scopes:ALL});
 assert.equal((await s.signIn('again',device('device-noor'),a.session)).status,200);
 assert.equal((await capabilities(s,a)).capabilities.mailModify,true);
});
test('the Mail-only routes are gone',async()=>{
 const s=setup(),a=await user(s);
 assert.equal((await s.call('POST','/v1/google/mail',{session:a.session,body:{email:'noor@plan.example',code:'x'}})).status,404);
 assert.equal((await s.call('DELETE','/v1/google/mail',{session:a.session,body:{email:'noor@plan.example'}})).status,404);
 assert.equal((await capabilities(s,a)).capabilities.mailModify,true);
});
test('a new grant reads contacts photos again',async()=>{
 const s=setup(),a=await user(s);
 await s.db.run('INSERT INTO sender_contact_syncs VALUES (?,?,?)',a.account.id,'sub-noor',s.now());
 s.google.person('again','sub-noor','noor@plan.example','again-refresh',{scopes:ALL});
 await s.signIn('again',device('device-noor'),a.session);
 assert.equal(await s.db.first('SELECT * FROM sender_contact_syncs WHERE google_sub=?','sub-noor'),null);
});
