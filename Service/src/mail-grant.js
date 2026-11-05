import {googleCapabilities,featureAllowed} from './feature-access.js';
import {GoogleRefused} from './google.js';
export async function mailLink(deps,account,email) {
 const link=await deps.db.first("SELECT * FROM google_links WHERE account_id=? AND email=? AND status<>'unlinked'",account,email.toLowerCase());
 if(!link)return null;
 const mail=await deps.db.first('SELECT * FROM mail_grants WHERE google_sub=?',link.sub);
 return mail?{...link,refresh_token:mail.refresh_token,scopes:mail.scopes,status:mail.status,client_id:mail.client_id,mailGrant:true}:link;
}
export async function connectMail(deps,vault,account,code,email) {
 if(!await featureAllowed(deps,account,'email'))return {status:403,error:'feature_unavailable'};
 const link=await deps.db.first("SELECT * FROM google_links WHERE account_id=? AND email=? AND status<>'unlinked'",account,email.toLowerCase());
 if(!link)return {status:404,error:'unknown_google'};
 let grant;
 try {grant=await deps.google.exchangeCode(code);}
 catch(e){return {status:e instanceof GoogleRefused?403:502,error:e instanceof GoogleRefused?'google_refused':'google_unavailable'};}
 if(grant.sub!==link.sub||grant.email.toLowerCase()!==link.email.toLowerCase())return {status:409,error:'different_account'};
 const existing=await deps.db.first('SELECT * FROM mail_grants WHERE google_sub=?',link.sub);
 const client=deps.config.googleClientId??'';
 if(!client)return {status:503,error:'not_configured'};
 const sealed=grant.refreshToken?await vault.seal(link.sub,grant.refreshToken):existing?.client_id===client&&existing?.status==='ok'?existing.refresh_token:null;
 const capabilities=googleCapabilities({scopes:grant.scopes,status:'ok',has_token:Boolean(sealed)});
 // A declined or incomplete new consent leaves the working grants untouched.
 if(!capabilities.mailRead)return {status:403,error:'mail_access_missing'};
 await deps.db.run(`INSERT INTO mail_grants(google_sub,refresh_token,scopes,client_id,status,granted_at,updated_at)
 VALUES (?,?,?,?,'ok',?,?) ON CONFLICT(google_sub) DO UPDATE SET refresh_token=excluded.refresh_token,
 scopes=excluded.scopes,client_id=excluded.client_id,status='ok',granted_at=excluded.granted_at,updated_at=excluded.updated_at`,
 link.sub,sealed,grant.scopes,client,deps.now(),deps.now());
 return {status:200,capabilities};
}
