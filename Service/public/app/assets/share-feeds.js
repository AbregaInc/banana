import { feedLink } from './feed-link.js';
// Connection credentials stay in this page's memory. Listings never return them again.
const typeName = type => ({ 'food.meal': 'Meals', 'food.mealPhoto': 'Meal photos', 'food.myFood': 'Saved foods',
  'food.dose': 'Dose history', 'food.supplement': 'Supplements', 'health.snapshot': 'Health data',
  'health.workout': 'Workouts', 'health.workoutPlan': 'Workout plans', 'health.workoutCompletion': 'Workout completions',
  'plan.routine': 'Routines', 'plan.alarm': 'Alarms', 'plan.extra': 'Plan items', 'plan.override': 'Plan adjustments', 'core.wakePlan': 'Wake plans',
  'podcast.show': 'Podcasts', 'podcast.listen': 'Listening history', 'podcast.progress': 'Listening progress', 'podcast.transcript': 'Transcripts',
  calendar: 'Calendar', 'notes.voiceNote': 'Voice notes' })[type] ?? type;

const scopeName = policy => [
  ...Object.entries(policy.sections).filter(([, on]) => on).map(([key]) => ({ personalPlan: 'Routines & reminders', workouts: 'Workouts', health: 'Health trends', nutrition: 'Food', taken: 'Taken', notes: 'Notes', listening: 'Listening' })[key]),
  ...(policy.calendars.length ? [`${policy.calendars.length} calendar${policy.calendars.length === 1 ? '' : 's'}`] : []),
].join(' · ');

const accessName = access => [scopeName({ sections: Object.fromEntries(access.sections.map(k => [k, true])), calendars: [] }),
  ...[['busy', 'busy only'], ['details', 'full details']].filter(([kind]) => access.calendars[kind]).map(([kind, label]) => `${access.calendars[kind]} calendar${access.calendars[kind] === 1 ? '' : 's'} (${label})`)].filter(Boolean).join(' · ');

export function shareFeedControls({ request, escape: esc, notice }) {
  const secrets = new Map(), states = new Map(); let generation = 0, credentialEpoch = 0;
  const json = async (path, method = 'GET', data) => (await request(path, { method,
    ...(data == null ? {} : { headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data) }) })).json();
  async function mount(element, base, { policy, preview = false, heading = true } = {}) {
    if (!element) return;
    const ticket = ++generation, epoch = credentialEpoch;
    const state = states.get(base) ?? { busy: false, feeds: [], selectedTypes: null, format: 'json', calendarDays: 7, name: '' };
    states.set(base, state);
    const alive = () => ticket === generation && element.isConnected;
    const saved = () => preview ? null : secrets.get(base);
    function draw() {
      if (!alive()) return;
      const current = saved(), types = [...(current?.manifest?.types ?? []), ...(current?.manifest?.calendar ? [{ type: 'calendar', ...current.manifest.calendar }] : [])];
      const available = types.map(t => t.type);
      const selected = state.selectedTypes == null ? available : state.selectedTypes.filter(t => available.includes(t));
      const { busy } = state;
      const feeds = preview ? [] : state.feeds;
      const all = state.selectedTypes == null;
      const hasCalendar = selected.includes('calendar');
      let url = '';
      if (current && selected.length) url = feedLink(current.dataURL ?? current.url, { types: all ? 'all' : selected, format: state.format, calendarDays: hasCalendar ? state.calendarDays : undefined });
      const access = current?.manifest?.access;
      const scope = access ? accessName(access) : '';

      element.innerHTML = `${heading ? '<div class="section-title"><h3>Data feeds</h3></div>' : ''}
        ${preview ? '<p class="subtle">The recipient can create a connection here. Preview controls are disabled.</p>' : ''}
        <form data-feed-form class="feed-connection-form"><label class="share-email">Connection name <input name="feed-name" value="${esc(state.name)}" required maxlength="100" placeholder="Coaching app" autocomplete="off" ${preview || busy ? 'disabled' : ''}></label>
        <button class="button secondary" type="submit" ${preview || busy ? 'disabled' : ''}>Create private feed</button></form>
        ${current ? `<div class="feed-secret"><p>Read-only connection created. Copy these credentials now; they are shown once.</p>
          ${scope ? `<p><strong>${current.manifest.scope === 'share' ? 'Shared access' : 'Selected access'}:</strong> ${esc(scope)}</p>` : ''}
          ${types.length ? `<fieldset class="feed-types"><legend>Included data types</legend>${types.map(t => `<label><input type="checkbox" data-feed-type="${esc(t.type)}" ${selected.includes(t.type) ? 'checked' : ''}>${esc(typeName(t.type))}</label>`).join('')}</fieldset>` : current.manifest ? '<p>No data types are currently available under this connection’s access and consent.</p>' : current.manifestError ? '<p>Could not load connection permissions.</p><button class="text-button" data-feed-retry>Retry</button>' : '<p role="status">Reading connection permissions…</p>'}
          <div class="feed-options"><label>Format <select data-feed-format><option value="json" ${state.format === 'json' ? 'selected' : ''}>JSON</option><option value="csv" ${state.format === 'csv' ? 'selected' : ''}>CSV</option></select></label>
          ${hasCalendar ? `<label>Calendar window <select data-feed-days>${[1,2,3,4,5,6,7,8].map(n => `<option value="${n}" ${state.calendarDays === n ? 'selected' : ''}>Next ${n} day${n === 1 ? '' : 's'}</option>`).join('')}</select></label>` : ''}</div>
          <label class="feed-url">Feed URL<input readonly data-feed-url value="${esc(url)}"></label>
          <div class="share-actions"><button class="button" data-feed-copy="url" ${busy || !url ? 'disabled' : ''}>Copy feed URL</button>
          <button class="text-button" data-feed-copy="token" ${busy ? 'disabled' : ''}>Copy API token</button></div>
          <p class="subtle">JSON uses next-page URLs; CSV uses the Link response header. Image links expire within an hour.</p></div>` : ''}
        ${feeds.length ? `<div class="feed-connections">${feeds.map(f => `<div class="share-invitation"><div><strong>${esc(f.name)}</strong>
          ${f.access || f.policy ? `<p>${esc(f.access ? accessName(f.access) : scopeName(f.policy))}</p>` : ''}<span class="share-status">${f.revokedAt != null ? 'Revoked' : f.expiresOn ? `Expires ${esc(f.expiresOn)}` : 'Active'}${f.createdByYou ? ' · Created by you' : ''}</span></div>
          ${f.revokedAt == null ? `<button class="text-button" data-feed-revoke="${esc(f.id)}" ${busy ? 'disabled' : ''}>Revoke</button>` : ''}</div>`).join('')}</div>` : ''}`;
    }
    state.redraw = draw;
    async function refreshManifest(current) {
      const request = (current.metadataRequest ?? 0) + 1; current.metadataRequest = request;
      current.manifest = null; current.manifestError = false; state.redraw?.();
      try {
        const url = new URL(current.manifestURL ?? current.url);
        if (url.origin !== location.origin) throw new Error('Feed origin changed.');
        const response = await fetch(url, { credentials: 'omit', cache: 'no-store' });
        if (!response.ok) throw new Error('Feed metadata unavailable.');
        const manifest = await response.json();
        if (epoch === credentialEpoch && current.metadataRequest === request) current.manifest = manifest;
      } catch {
        if (epoch === credentialEpoch && current.metadataRequest === request) current.manifestError = true;
      }
      if (epoch === credentialEpoch) state.redraw?.();
    }
    async function reload(refresh = true) { const data = await json(base); if (epoch === credentialEpoch) { state.feeds = data.feeds; if (refresh && saved()) await refreshManifest(saved()); state.redraw?.(); } }
    state.reload = reload;
    element.oninput = event => { if (event.target.name === 'feed-name') state.name = event.target.value;
      else if (event.target.name === 'feed-from') state.from = event.target.value;
      else if (event.target.name === 'feed-to') state.to = event.target.value; };
    element.onsubmit = async event => {
      if (!event.target.matches('[data-feed-form]')) return;
      event.preventDefault(); if (state.busy || preview) return;
      const name = new FormData(event.target).get('feed-name');
      state.busy = true; draw();
      try {
        const created = await json(base, 'POST', { name, ...(policy ? { policy: policy() } : {}) });
        if (epoch !== credentialEpoch) return;
        // Preserve the one-time result even if navigation removes this view during the request.
        secrets.set(base, created);
        state.name = ''; state.selectedTypes = null;
        await refreshManifest(created);
        if (epoch === credentialEpoch) await state.reload?.(false);
      } catch (error) { if (alive()) notice(error.message, true); }
      finally { state.busy = false; state.redraw?.(); }
    };
    element.onchange = event => {
      const target = event.target;
      if (target.matches('[data-feed-type]')) {
        const current = saved(), available = [...(current?.manifest?.types ?? []).map(t => t.type), ...(current?.manifest?.calendar ? ['calendar'] : [])];
        const picked = new Set(state.selectedTypes ?? available);
        if (target.checked) picked.add(target.dataset.feedType); else picked.delete(target.dataset.feedType);
        state.selectedTypes = [...picked]; draw(); element.querySelector(`[data-feed-type="${CSS.escape(target.dataset.feedType)}"]`)?.focus();
      } else if (target.matches('[data-feed-format]')) { state.format = target.value; draw(); element.querySelector('[data-feed-format]')?.focus(); }
      else if (target.matches('[data-feed-days]')) { state.calendarDays = Number(target.value); draw(); element.querySelector('[data-feed-days]')?.focus(); }
    };
    element.onclick = async event => {
      const button = event.target.closest('[data-feed-copy],[data-feed-revoke],[data-feed-retry]');
      if (!button || state.busy) return;
      try {
        if (button.hasAttribute('data-feed-retry')) { if (saved()) await refreshManifest(saved()); }
        else if (button.dataset.feedCopy) {
          const current = saved();
          const value = button.dataset.feedCopy === 'token' ? current?.token : element.querySelector('[data-feed-url]')?.value;
          if (!value) return;
          await navigator.clipboard.writeText(value);
          if (alive()) notice(button.dataset.feedCopy === 'token' ? 'API token copied.' : 'Private feed URL copied.');
        } else {
          state.busy = true; draw();
          await json(`${base}/${button.dataset.feedRevoke}/revoke`, 'POST', {});
          if (saved()?.id === button.dataset.feedRevoke) secrets.delete(base);
          if (epoch === credentialEpoch) { await state.reload?.(); if (alive()) notice('Connection revoked. Existing URLs no longer work.'); }
        }
      } catch (error) { if (alive()) notice(error.message, true); }
      finally { if (state.busy) { state.busy = false; state.redraw?.(); } }
    };
    draw();
    if (preview) return;
    try { await reload(); } catch (error) { if (alive()) notice(error.message, true); }
  }
  return { mount, clear() { credentialEpoch++; generation++; secrets.clear(); states.clear(); } };
}
