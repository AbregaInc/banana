import {googleCapabilities,featureAllowed} from './feature-access.js';
import {GoogleRefused} from './google.js';
export async function mailLink(deps,account,email) {
 const link=await deps.db.first("SELECT * FROM google_links WHERE account_id=? AND email=? AND status<>'unlinked'",account,email.toLowerCase());
 if(!link)return null;
 const mail=await deps.db.first('SELECT * FROM mail_grants WHERE google_sub=?',link.sub);
 return mail?{...link,refresh_token:mail.refresh_token,scopes:mail.scopes,status:mail.status,client_id:mail.client_id,mailGrant:true}:link;
}
export async function mailWriteLink(deps,account,email) {
 if(!await featureAllowed(deps,account,'email'))return null;
 const link=await mailLink(deps,account,email);
 if(!link||!googleCapabilities({...link,has_token:Boolean(link.refresh_token)}).mailModify)return null;
 if(link.client_id&&link.client_id!==deps.config.googleClientId)return null;
 return link;
}
export async function connectMail(deps,vault,account,code,email) {
 if(!await featureAllowed(deps,account,'email'))return {status:403,error:'feature_unavailable'};
 const link=await deps.db.first("SELECT * FROM google_links WHERE account_id=? AND email=? AND status<>'unlinked'",account,email.toLowerCase());
 if(!link)return {status:404,error:'unknown_google'};
 let grant;
 try {grant=await deps.google.exchangeCode(code);}
 catch(e){return {status:e instanceof GoogleRefused?403:502,error:e instanceof GoogleRefused?'google_refused':'google_unavailable'};}
 if(grant.sub!==link.sub||grant.email.toLowerCase()!==link.email.toLowerCase())return {status:409,error:'different_account'};
 const prepared=await mailGrantStatements(deps,vault,account,grant);
 if(prepared.status!==200)return prepared;
 await deps.db.batch([...prepared.statements,...await calendarGrantStatements(vault,link,grant,deps.now())]);
 return {status:200,capabilities:prepared.capabilities};
}

// Both first consent and the existing combined Reconnect use this persistence rule.
// A code is exchanged once; Mail-only consent never replaces the Calendar grant.
export async function mailGrantStatements(deps,vault,account,grant) {
 const existing=await deps.db.first('SELECT * FROM mail_grants WHERE google_sub=?',grant.sub);
 const client=deps.config.googleClientId??'';
 if(!client)return {status:503,error:'not_configured'};
 const sealed=grant.refreshToken?await vault.seal(grant.sub,grant.refreshToken):existing?.client_id===client&&existing?.status==='ok'?existing.refresh_token:null;
 const capabilities=googleCapabilities({scopes:grant.scopes,status:'ok',has_token:Boolean(sealed)});
 if(!capabilities.mailRead)return {status:403,error:'mail_access_missing'};
 return {status:200,capabilities,statements:[{
  sql:`INSERT INTO mail_grants(google_sub,refresh_token,scopes,client_id,status,granted_at,updated_at)
   VALUES (?,?,?,?,'ok',?,?) ON CONFLICT(google_sub) DO UPDATE SET refresh_token=excluded.refresh_token,
   scopes=excluded.scopes,client_id=excluded.client_id,status='ok',granted_at=excluded.granted_at,updated_at=excluded.updated_at`,
  params:[grant.sub,sealed,grant.scopes,client,deps.now(),deps.now()]
 },{
  // Re-consent retries an API that was disabled earlier; keep photos until refresh.
  sql:'DELETE FROM sender_contact_syncs WHERE account_id=? AND google_sub=?',params:[account,grant.sub]
 }]};
}

// Every consent asks for every scope (the app's GoogleScopes.all), so Mail's consent usually
// carries the calendar's too: it then renews the Calendar grant as a sign-in would, and a calendar
// waiting on a refused grant works again. Only a grant with all the calendar access the app needs
// replaces it; anything less leaves the Calendar grant as it was.
export async function calendarGrantStatements(vault,link,grant,now) {
 if(!grant.refreshToken)return [];
 const c=googleCapabilities({scopes:grant.scopes,status:'ok',has_token:true});
 if(!c.calendarRead||!c.calendarWrite||!c.calendarList)return [];
 return [{
  sql:"UPDATE google_links SET refresh_token=?,scopes=?,status='ok',updated_at=? WHERE sub=?",
  params:[await vault.seal(grant.sub,grant.refreshToken),grant.scopes,now,link.sub],
 },{sql:'UPDATE watches SET retry_at=NULL,failures=0 WHERE google_sub=?',params:[link.sub]}];
}
