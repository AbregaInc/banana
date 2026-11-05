// Account eligibility is independent of module preference and provider consent.
// The server checks its current grant on every protected operation; a client's
// short-lived policy is for presentation/offline availability, never authorization.
export const FEATURES = Object.freeze(['email', 'calendarCloud']);
export const POLICY_TTL = 15 * 60 * 1000;

export async function featureAllowed(deps, account, feature) {
  if (!account || !FEATURES.includes(feature) || !await providerDevicesReady(deps, account)) return false;
  const row = await deps.db.first(
    'SELECT enabled, expires_at FROM feature_access WHERE account_id = ? AND feature = ?', account, feature);
  return Number(row?.enabled) === 1 && (row.expires_at == null || Number(row.expires_at) > deps.now());
}

export async function featurePolicy(deps, account) {
  const now = deps.now();
  const rows = await deps.db.all(
    'SELECT feature, enabled, expires_at FROM feature_access WHERE account_id = ?', account);
  const ready = await providerDevicesReady(deps, account);
  const active = rows.filter(r => ready && FEATURES.includes(r.feature) && Number(r.enabled) === 1
    && (r.expires_at == null || Number(r.expires_at) > now));
  return { version: 1, issuedAt: now,
    expiresAt: Math.min(now + POLICY_TTL, ...active.filter(r => r.expires_at != null).map(r => Number(r.expires_at))),
    enabled: active.map(r => r.feature).sort() };
}

export function googleCapabilities(link) {
  const scopes = new Set(String(link.scopes ?? '').split(/\s+/));
  const has = suffix => scopes.has(`https://www.googleapis.com/auth/${suffix}`);
  const connected = Boolean(link.has_token) && link.status === 'ok';
  return {
    calendarRead: connected && ['calendar', 'calendar.readonly', 'calendar.events', 'calendar.events.readonly'].some(has),
    calendarWrite: connected && ['calendar', 'calendar.events'].some(has),
    calendarList: connected && ['calendar', 'calendar.readonly', 'calendar.calendarlist', 'calendar.calendarlist.readonly'].some(has),
    mailRead: connected && (has('gmail.modify') || has('gmail.readonly') || scopes.has('https://mail.google.com/')),
    mailModify: connected && (has('gmail.modify') || scopes.has('https://mail.google.com/')),
    mailSend: connected && (has('gmail.modify') || has('gmail.send') || has('gmail.compose') || scopes.has('https://mail.google.com/')),
  };
}


/** Mail may have a separate server grant so incremental consent cannot replace Calendar access. */
export function linkedGoogleCapabilities(link) {
  const calendar = googleCapabilities(link);
  if (link.mail_status == null) return calendar;
  const mail = googleCapabilities({status:link.mail_status,scopes:link.mail_scopes,has_token:link.mail_has_token});
  return {...calendar,mailRead:mail.mailRead,mailModify:mail.mailModify,mailSend:mail.mailSend};
}


export async function providerDevicesReady(deps, account) {
  return !(await deps.db.first('SELECT 1 AS legacy FROM devices WHERE account_id=? AND provider_protocol<1 LIMIT 1',account));
}
