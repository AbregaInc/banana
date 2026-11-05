// Native Calendar reads keep their existing Google wire models and incremental cache.
// Only this service holds Google credentials; cursors are encrypted and account/resource bound.
import { sha256Hex } from './crypto.js';
import { googleCapabilities } from './feature-access.js';
import { GoogleRefused } from './google.js';

const PREFIX = 'banana-calendar:';
const DAY = 86_400_000;
const keys = new Set(['timeMin', 'timeMax', 'singleEvents', 'orderBy', 'maxResults', 'pageToken',
  'syncToken', 'showDeleted', 'showHiddenInvitations', 'privateExtendedProperty', 'sharedExtendedProperty',
  'q', 'iCalUID', 'fields', 'timeZone', 'maxAttendees', 'updatedMin', 'originalStart']);
const resourceKeys = {
  calendarList: new Set(['maxResults', 'pageToken', 'syncToken', 'showDeleted', 'showHidden', 'minAccessRole', 'fields']),
  events: keys,
  acl: new Set(['maxResults', 'pageToken', 'fields', 'showDeleted']),
  event: new Set(['fields', 'timeZone', 'maxAttendees']),
  instances: new Set(['timeMin', 'timeMax', 'maxResults', 'pageToken', 'showDeleted', 'timeZone', 'maxAttendees', 'originalStart', 'fields']),
};
const id = value => typeof value === 'string' && value.length > 0 && value.length <= 2048 && !/[\x00-\x1f]/.test(value);
export function parseCalendarRead(value) {
  if (!value || !Object.hasOwn(resourceKeys, value.resource) || !id(value.email)) return null;
  if (value.resource !== 'calendarList' && !id(value.calendarID)) return null;
  if (['event', 'instances'].includes(value.resource) && !id(value.eventID)) return null;
  if (!['event', 'instances'].includes(value.resource) && value.eventID != null) return null;
  if (value.resource === 'calendarList' && value.calendarID != null) return null;
  if (!Array.isArray(value.query) || value.query.length > 30) return null;
  const seen = new Set();
  for (const item of value.query) {
    if (!item || !resourceKeys[value.resource].has(item.name) || typeof item.value !== 'string' || item.value.length > 16384) return null;
    if (seen.has(item.name) && !['privateExtendedProperty', 'sharedExtendedProperty'].includes(item.name)) return null;
    seen.add(item.name);
    if (item.name === 'maxResults' && (!/^\d+$/.test(item.value) || +item.value < 1 || +item.value > (value.resource === 'calendarList' ? 250 : value.resource === 'acl' ? 1000 : 2500))) return null;
  }
  return { resource: value.resource, email: value.email.toLowerCase(), calendarID: value.calendarID ?? null,
    eventID: value.eventID ?? null, query: value.query.map(({name, value}) => ({name, value})) };
}

export async function calendarRead(deps, vault, account, request) {
  const link = await deps.db.first("SELECT sub, email, refresh_token, scopes, status FROM google_links WHERE account_id=? AND email=? AND status<>'unlinked'", account, request.email);
  const capabilities = googleCapabilities({ ...link, has_token: Boolean(link?.refresh_token) });
  if (!link || !(request.resource === 'calendarList' ? capabilities.calendarList : capabilities.calendarRead)) {
    return { status: 403, body: { error: { message: 'Reconnect this Google account.', code: 403 } } };
  }
  const base = { account, sub: link.sub, grant: await sha256Hex(link.refresh_token), resource: request.resource, calendarID: request.calendarID, eventID: request.eventID };
  const binding = async kind => sha256Hex(JSON.stringify({ ...base, kind,
    query: request.query.filter(item => kind === 'page' ? item.name !== 'pageToken'
      : !['pageToken','syncToken','timeMin','timeMax','updatedMin','orderBy','q','iCalUID','privateExtendedProperty','sharedExtendedProperty'].includes(item.name))
      .sort((a,b) => a.name.localeCompare(b.name) || a.value.localeCompare(b.value)),
  }));
  const unseal = async (wrapped, kind) => {
    if (!wrapped.startsWith(PREFIX)) throw new Error('cursor');
    const value = JSON.parse(await vault.open(link.sub, wrapped.slice(PREFIX.length)));
    if (value.binding !== await binding(kind) || value.until <= deps.now() || typeof value.token !== 'string') throw new Error('cursor');
    return value.token;
  };
  const query = [];
  try {
    for (const item of request.query) query.push({ ...item, value: ['pageToken','syncToken'].includes(item.name)
      ? await unseal(item.value, item.name === 'pageToken' ? 'page' : 'sync') : item.value });
  } catch { return { status: 410, body: { error: { message: 'Calendar cursor expired. Read again.', code: 410 } } }; }
  let answer;
  try {
    const { accessToken } = await deps.google.refresh(await vault.open(link.sub, link.refresh_token));
    answer = await deps.google.calendarRead(accessToken, { ...request, query });
  } catch (error) {
    return { status: error instanceof GoogleRefused ? 403 : 502,
      body: { error: { message: error instanceof GoogleRefused ? 'Reconnect this Google account.' : 'Calendar temporarily unavailable.' } } };
  }
  if (answer.status >= 200 && answer.status < 300) {
    const body = { ...answer.body };
    for (const [field, kind] of [['nextPageToken','page'],['nextSyncToken','sync']]) {
      if (typeof body[field] === 'string') body[field] = PREFIX + await vault.seal(link.sub, JSON.stringify({
        binding: await binding(kind), token: body[field], until: deps.now() + (kind === 'page' ? DAY : 7 * DAY),
      }));
    }
    return { status: answer.status, body };
  }
  return answer;
}
