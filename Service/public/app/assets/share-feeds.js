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

export function shareFeedControls({ request, escape: esc, notice }) {
  const secrets = new Map(), states = new Map(); let generation = 0, credentialEpoch = 0;
  const json = async (path, method = 'GET', data) => (await request(path, { method,
    ...(data == null ? {} : { headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data) }) })).json();
  async function mount(element, base, { policy, preview = false, heading = true } = {}) {
    if (!element) return;
    const ticket = ++generation, epoch = credentialEpoch;
    const state = states.get(base) ?? { busy: false, feeds: [], selectedType: '', name: '' };
    states.set(base, state);
    const alive = () => ticket === generation && element.isConnected;
    const saved = () => preview ? null : secrets.get(base);
    function draw() {
      if (!alive()) return;
      const current = saved(), types = [...(current?.manifest?.types ?? []), ...(current?.manifest?.calendar ? [{ type: 'calendar', ...current.manifest.calendar }] : [])];
      if (!types.some(t => t.type === state.selectedType)) state.selectedType = types[0]?.type ?? '';
      const { busy, selectedType } = state;
      const feeds = preview ? [] : state.feeds;
      const selected = types.find(t => t.type === selectedType);
      element.innerHTML = `${heading ? '<div class="section-title"><h3>Data feeds</h3></div>' : ''}
        ${preview ? '<p class="subtle">The recipient can create a connection here. Preview controls are disabled.</p>' : ''}
        <form data-feed-form class="feed-connection-form"><label class="share-email">Connection name <input name="feed-name" value="${esc(state.name)}" required maxlength="100" placeholder="Coaching app" autocomplete="off" ${preview || busy ? 'disabled' : ''}></label>
        <button class="button secondary" type="submit" ${preview || busy ? 'disabled' : ''}>Create private feed</button></form>
        ${current ? `<div class="feed-secret"><p>Read-only connection created. Copy these credentials now; they are shown once.</p>
          ${types.length ? `<label>Data <select data-feed-type>${types.map(t => `<option value="${esc(t.type)}" ${t.type === selectedType ? 'selected' : ''}>${esc(typeName(t.type))}</option>`).join('')}</select></label>` : ''}
          ${selectedType === 'calendar' ? `<div class="feed-dates"><label>From <input type="date" name="feed-from" value="${esc(state.from ?? new Date().toISOString().slice(0, 10))}"></label><label>Until <input type="date" name="feed-to" value="${esc(state.to ?? new Date(Date.now() + 7 * 86400000).toISOString().slice(0, 10))}"></label></div>` : ''}
          <div class="share-actions"><button class="text-button" data-feed-copy="json" ${busy ? 'disabled' : ''}>Copy JSON URL</button>
          ${selected ? `<button class="text-button" data-feed-copy="csv" ${busy ? 'disabled' : ''}>Copy CSV URL</button>` : ''}
          <button class="text-button" data-feed-copy="token" ${busy ? 'disabled' : ''}>Copy API token</button></div>
          <p class="subtle">JSON uses next-page URLs; CSV uses the Link response header. Image links expire within an hour.</p></div>` : ''}
        ${feeds.length ? `<div class="feed-connections">${feeds.map(f => `<div class="share-invitation"><div><strong>${esc(f.name)}</strong>
          ${f.policy ? `<p>${esc(scopeName(f.policy))}</p>` : ''}<span class="share-status">${f.revokedAt != null ? 'Revoked' : f.expiresOn ? `Expires ${esc(f.expiresOn)}` : 'Active'}${f.createdByYou ? ' · Created by you' : ''}</span></div>
          ${f.revokedAt == null ? `<button class="text-button" data-feed-revoke="${esc(f.id)}" ${busy ? 'disabled' : ''}>Revoke</button>` : ''}</div>`).join('')}</div>` : ''}`;
    }
    state.redraw = draw;
    async function reload() { const data = await json(base); if (epoch === credentialEpoch) { state.feeds = data.feeds; state.redraw?.(); } }
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
        state.name = '';
        try {
          if (new URL(created.url).origin !== location.origin) throw new Error('Feed origin changed.');
          const response = await fetch(created.url, { credentials: 'omit', cache: 'no-store' });
          if (!response.ok) throw new Error('Feed metadata unavailable.');
          created.manifest = await response.json();
        }
        catch { if (alive()) notice('Connection created. Its JSON URL is available; data may need a moment to sync.'); }
        if (epoch === credentialEpoch) await state.reload?.();
      } catch (error) { if (alive()) notice(error.message, true); }
      finally { state.busy = false; state.redraw?.(); }
    };
    element.onchange = event => {
      if (event.target.matches('[data-feed-type]')) { state.selectedType = event.target.value; draw(); element.querySelector('[data-feed-type]')?.focus(); }
    };
    element.onclick = async event => {
      const button = event.target.closest('[data-feed-copy],[data-feed-revoke]');
      if (!button || state.busy) return;
      try {
        if (button.dataset.feedCopy) {
          const current = saved(), type = state.selectedType === 'calendar' ? current?.manifest?.calendar : current?.manifest?.types.find(t => t.type === state.selectedType);
          let value = button.dataset.feedCopy === 'token' ? current?.token
            : button.dataset.feedCopy === 'csv' ? type?.csv : type?.json ?? current?.url;
          if (!value) return;
          if (state.selectedType === 'calendar' && button.dataset.feedCopy !== 'token') {
            const from = Date.parse(state.from ?? new Date().toISOString().slice(0, 10)), to = Date.parse(state.to ?? new Date(Date.now() + 7 * 86400000).toISOString().slice(0, 10));
            if (!Number.isFinite(from) || !Number.isFinite(to) || to <= from || to - from > 8 * 86400000) throw new Error('Choose a calendar range of up to eight days.');
            const url = new URL(value); url.searchParams.set('from', from); url.searchParams.set('to', to); value = url.href;
          }
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
