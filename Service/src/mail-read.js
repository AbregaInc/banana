import {mailLink} from './mail-grant.js';
import {featureAllowed,googleCapabilities} from './feature-access.js';
import {GoogleRefused} from './google.js';
const id=x=>typeof x==='string'&&x.length>0&&x.length<=2048&&!['.','..'].includes(x)&&!/[\x00-\x1f]/.test(x);
const rules={drafts:['q','includeSpamTrash','pageToken','maxResults'],draft:['format'],profile:[],labels:[],messages:['labelIds','q','includeSpamTrash','pageToken','maxResults'],
 history:['startHistoryId','pageToken','maxResults'],message:['format','metadataHeaders'],thread:['format','metadataHeaders'],attachment:[]};
export function parseMailRead(x) {
 if(!x||!Object.hasOwn(rules,x.resource)||!id(x.email)||!Array.isArray(x.query)||x.query.length>40)return null;
 const needsID=['draft','message','thread','attachment'].includes(x.resource);
 if(needsID?!id(x.id):x.id!=null)return null;
 if(x.resource==='attachment'?!id(x.attachmentID):x.attachmentID!=null)return null;
 const seen=new Set();
 for(const q of x.query) {
  if(!q||!rules[x.resource].includes(q.name)||typeof q.value!=='string'||q.value.length>16384)return null;
  if(seen.has(q.name)&&!['labelIds','metadataHeaders'].includes(q.name))return null;seen.add(q.name);
  if(q.name==='maxResults'&&(!/^\d+$/.test(q.value)||+q.value<1||+q.value>500))return null;
  if(q.name==='format'&&!['minimal','metadata','full','raw'].includes(q.value))return null;
  if(q.name==='startHistoryId'&&!/^\d+$/.test(q.value))return null;
 }
 return {email:x.email.toLowerCase(),resource:x.resource,id:x.id??null,attachmentID:x.attachmentID??null,
  query:x.query.map(({name,value})=>({name,value}))};
}
export async function mailRead(deps,vault,account,request) {
 const fail=(status,message)=>({status,body:{error:{code:status,message}}});
 if(!await featureAllowed(deps,account,'email'))return fail(403,'Email access is unavailable.');
 const link=await mailLink(deps,account,request.email);
 if(!link||!googleCapabilities({...link,has_token:Boolean(link.refresh_token)}).mailRead)return fail(403,'Connect Email for this Google account.');
 if(link.client_id&&link.client_id!==deps.config.googleClientId)return fail(403,'Reconnect Email for this service.');
 try {
  const {accessToken}=await deps.google.refresh(await vault.open(link.sub,link.refresh_token));
  return await deps.google.mailRead(accessToken,request);
 } catch(error) {
  if(error instanceof GoogleRefused&&link.mailGrant)await deps.db.run("UPDATE mail_grants SET status='refused',updated_at=? WHERE google_sub=? AND refresh_token=?",deps.now(),link.sub,link.refresh_token);
  return fail(error instanceof GoogleRefused?403:502,error instanceof GoogleRefused?'Reconnect Email for this Google account.':'Email temporarily unavailable.');
 }
}
