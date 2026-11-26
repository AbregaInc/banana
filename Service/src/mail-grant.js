import {googleCapabilities,featureAllowed} from './feature-access.js';
// One Google account, one grant. Mail is connected when that grant has gmail.modify; there is no
// Mail grant of its own, no Mail-only consent and no Mail-only disconnect.
export async function mailLink(deps,account,email) {
 return await deps.db.first("SELECT * FROM google_links WHERE account_id=? AND email=? AND status<>'unlinked'",account,email.toLowerCase())??null;
}
export async function mailWriteLink(deps,account,email) {
 if(!await featureAllowed(deps,account,'email'))return null;
 const link=await mailLink(deps,account,email);
 if(!link||!googleCapabilities({...link,has_token:Boolean(link.refresh_token)}).mailModify)return null;
 return link;
}
