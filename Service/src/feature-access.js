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
  const persistent = active.filter(row => row.expires_at == null).map(row => row.feature).sort();
  return { version: 1, issuedAt: now,
    expiresAt: Math.min(now + POLICY_TTL, ...active.filter(r => r.expires_at != null).map(r => Number(r.expires_at))),
    enabled: active.map(r => r.feature).sort(),
    ...(persistent.length > 0 ? { persistent } : {}) };
}

export function googleCapabilities(link) {
  const scopes = new Set(String(link.scopes ?? '').split(/\s+/));
  const has = suffix => scopes.has(`https://www.googleapis.com/auth/${suffix}`);
  const connected = Boolean(link.has_token) && link.status === 'ok';
  return {
    calendarRead: connected && ['calendar', 'calendar.readonly', 'calendar.events', 'calendar.events.readonly'].some(has),
    calendarWrite: connected && ['calendar', 'calendar.events'].some(has),
    calendarList: connected && ['calendar', 'calendar.readonly', 'calendar.calendarlist', 'calendar.calendarlist.readonly'].some(has),
    // Mail is connected or not: the grant has gmail.modify, or it doesn't. The three fields stay
    // for the devices' wire format and are always equal.
    mailRead: connected && has('gmail.modify'),
    mailModify: connected && has('gmail.modify'),
    mailSend: connected && has('gmail.modify'),
  };
}


/** One Google account, one grant: Calendar and Mail both read it. */
export function linkedGoogleCapabilities(link) {
  return googleCapabilities(link);
}


export async function providerDevicesReady(deps, account) {
  return !(await deps.db.first('SELECT 1 AS legacy FROM devices WHERE account_id=? AND provider_protocol<1 LIMIT 1',account));
}

/** The grant's scopes. `calendar` and `mail` are the same one grant, kept as two keys for the devices. */
export function linkedGoogleScopes(link) {
 const scopes=[...new Set(String(link.scopes??'').split(/\s+/).filter(Boolean))].sort();
 return {calendar:scopes,mail:scopes};
}
