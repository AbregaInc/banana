import { feedLink } from './feed-link.js';
import { feedGuide, feedTypeName as typeName } from './feed-guide.js';
// Connection credentials stay in this page's memory. Listings never return them again.

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
  async function mount(element, base, { policy, preview = false, previewManifest, previewVersion, sharedAccess, sharedTypes, editShareURL, heading = true } = {}) {
    if (!element) return;
    const ticket = ++generation, epoch = credentialEpoch;
    const state = states.get(base) ?? { busy: false, feeds: [], selectedTypes: null, format: 'json', calendarDays: 7, name: '' };
    states.set(base, state);
    const alive = () => ticket === generation && element.isConnected;
    const example = preview ? { url: `${location.origin}/app/feeds/example?signature=EXAMPLE_ONLY`, manifest: previewManifest, preview: true } : null;
    const previewBase = preview ? new URL(base.replace(/\/feeds$/, '/feed-preview'), location.origin) : null;
    if (previewBase) previewBase.searchParams.set('preview', previewVersion);
    const session = sharedTypes ? {session:true, manifest:{scope:'share',access:sharedAccess,types:sharedTypes.map(type=>({type})),calendar:sharedAccess?.calendars.busy || sharedAccess?.calendars.details ? {} : null},dataURL:new URL(base.replace(/\/feeds$/, '/export-data'),location.origin).href} : null;
    const saved = () => preview ? example : secrets.get(base) ?? session;
    const permittedTypes = () => {
      const current = saved();
      if (current && !current.manifest) return null;
      const manifest = current?.manifest;
      const types = manifest ? manifest.types.map(t => t.type) : sharedTypes;
      if (types == null) return null;
      const calendar = manifest ? manifest.calendar : sharedAccess?.calendars.busy || sharedAccess?.calendars.details;
      return [...types, ...(calendar ? ['calendar'] : [])];
    };
    function selectedURL(current, source = false) {
      if (!current?.manifest) return '';
      const available = [...current.manifest.types.map(t => t.type), ...(current.manifest.calendar ? ['calendar'] : [])];
      const selected = state.selectedTypes == null ? available : state.selectedTypes.filter(t => available.includes(t));
      if (!selected.length) return '';
      return feedLink(source && preview ? previewBase.href : current.dataURL ?? current.url,
        { types: state.selectedTypes == null ? 'all' : selected, format: state.format, calendarDays: selected.includes('calendar') ? state.calendarDays : undefined });
    }

    function draw() {
      if (!alive()) return;
      const active = element.contains(document.activeElement) ? document.activeElement : null;
      const focus = active?.matches('[data-feed-type]') ? `[data-feed-type="${CSS.escape(active.dataset.feedType)}"]`
        : active?.matches('[data-feed-format]') ? '[data-feed-format]' : active?.matches('[data-feed-days]') ? '[data-feed-days]'
        : active?.matches('[data-feed-url]') ? '[data-feed-url]' : active?.name === 'feed-name' ? '[name="feed-name"]' : null;
      const exportFocus = active?.matches('[data-feed-images]') ? '[data-feed-images]' : active?.matches('[data-feed-export-cancel]') ? '[data-feed-export-cancel]' : null;
      const selection = active?.tagName === 'INPUT' && active.type === 'text' ? [active.selectionStart, active.selectionEnd] : null;
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

      const calendarRecovery = state.calendarIssue ? `<div class="notice" role="alert"><strong>Calendar access needs attention</strong><p>${esc(state.calendarIssue.message)}</p><ul>${state.calendarIssue.issues.map(issue=>`<li><strong>${esc(issue.calendar||'Shared calendar')}</strong>: ${esc(issue.message||'Could not read this calendar.')}${issue.ownerCalendarID?`<br><code>${esc(issue.ownerCalendarID)}</code>`:''}${issue.ownerAccount?`<br>${esc(issue.ownerAccount)}`:''}</li>`).join('')}</ul><div class="share-actions"><button class="text-button" data-feed-response>Retry</button>${selected.some(t=>t!=='calendar')?'<button class="text-button" data-feed-exclude-calendar>Exclude Calendar from this request</button>':''}${editShareURL?`<a class="text-button" href="${esc(editShareURL)}">Edit shared calendars</a>`:''}</div></div>` : '';
      const responseHTML = `<section class="feed-response" aria-label="Response preview"><h3>Response preview</h3>${calendarRecovery}
          ${state.responseLoading ? '<p role="status">Loading shared data…</p>' : ''}${state.responseText != null ? `<p>HTTP ${state.responseStatus}${state.responseClipped ? ' · Display limited to 65,536 characters' : ''}</p><pre tabindex="0" aria-label="Feed response"><code>${esc(state.responseText)}</code></pre><div class="share-actions"><a class="text-button" href="${esc(state.responseURL)}" target="_blank" rel="noreferrer noopener">Open full response ↗</a>${state.responseNext ? `<button class="text-button" data-feed-next ${state.responseLoading ? 'disabled' : ''}>Next page</button>` : ''}</div>` : state.responseError ? '<p>Could not read the response. Use Preview data to retry.</p>' : state.responseLoading ? '' : '<p>Preview data shows one real response page.</p>'}
          </section>`;

      element.innerHTML = `${heading ? '<div class="section-title"><h3>Data feeds</h3></div>' : ''}
        ${preview ? '<p class="subtle">Owner preview: actual shared data, without creating a recipient connection.</p>' : ''}
        ${!preview ? `<form data-feed-form class="feed-connection-form"><label class="share-email">Connection name <input name="feed-name" value="${esc(state.name)}" required maxlength="100" placeholder="Coaching app" autocomplete="off" ${preview || busy ? 'disabled' : ''}></label>
        <button class="button secondary" type="submit" ${preview || busy ? 'disabled' : ''}>Create private feed</button></form>` : ''}
        ${current ? `<div class="feed-secret"><p>${preview ? 'Example connection. The URL below is non-working; the response preview reads your actual shared data.' : current.session ? 'Download shared data below. Create a private feed when connecting another system.' : 'Read-only connection created. Copy these credentials now; they are shown once.'}</p>
          ${scope ? `<p><strong>${current.manifest.scope === 'share' ? 'Shared access' : 'Selected access'}:</strong> ${esc(scope)}</p>` : ''}
          ${types.length ? `<fieldset class="feed-types"><legend>Included data types</legend>${types.map(t => `<label><input type="checkbox" data-feed-type="${esc(t.type)}" ${selected.includes(t.type) ? 'checked' : ''}>${esc(typeName(t.type, access))} <code>${esc(t.type)}</code></label>`).join('')}</fieldset>` : current.manifest ? '<p>No data types are currently available under this connection’s access and consent.</p>' : current.manifestError ? '<p>Could not load connection permissions.</p><button class="text-button" data-feed-retry>Retry</button>' : '<p role="status">Reading connection permissions…</p>'}
          <div class="feed-options"><label>Format <select data-feed-format><option value="json" ${state.format === 'json' ? 'selected' : ''}>JSON</option><option value="csv" ${state.format === 'csv' ? 'selected' : ''}>CSV</option></select></label>
          ${hasCalendar ? `<label>Calendar window <select data-feed-days>${[1,2,3,4,5,6,7,8].map(n => `<option value="${n}" ${state.calendarDays === n ? 'selected' : ''}>Next ${n} day${n === 1 ? '' : 's'}</option>`).join('')}</select></label>` : ''}</div>
          ${preview ? responseHTML : ''}
          ${!current.session ? `<label class="feed-url">${preview ? 'Example feed URL' : 'Feed URL'}<input readonly data-feed-url value="${esc(url)}"></label>
          <div class="share-actions"><button class="button" data-feed-copy="url" ${busy || !url ? 'disabled' : ''}>${preview ? 'Copy example URL' : 'Copy feed URL'}</button>
          ${!preview ? `<button class="text-button" data-feed-copy="token" ${busy ? 'disabled' : ''}>Copy API token</button>` : ''}<button class="text-button" data-feed-response ${busy || !url ? 'disabled' : ''}>Preview data</button></div>` : '<button class="text-button" data-feed-response>Preview data</button>'}
          ${!preview ? responseHTML : ''}
          <section class="feed-export" aria-label="Complete export"><h3>Complete download</h3><p>All pages of the selected data, with spreadsheet tables, normalized JSON and a field dictionary. Source records are retained separately.</p>
          <label><input type="checkbox" data-feed-images ${state.includeImages !== false ? 'checked' : ''}> Include meal image files</label>
          <div class="share-actions"><button class="button" data-feed-export ${busy || !url || state.exportWorker ? 'disabled' : ''}>Download complete ZIP</button>${state.exportWorker ? '<button class="text-button" data-feed-export-cancel>Cancel download</button>' : ''}</div><p role="status" data-export-status>${esc(state.exportStatus ?? '')}</p></section></div>` : ''}
        ${feedGuide({ access: current?.manifest?.access ?? sharedAccess, types: permittedTypes(), url: current?.session ? '' : url, manifestURL: current?.manifestURL, preview, escape: esc })}
        ${feeds.length ? `<div class="feed-connections">${feeds.map(f => `<div class="share-invitation"><div><strong>${esc(f.name)}</strong>
          ${f.access || f.policy ? `<p>${esc(f.access ? accessName(f.access) : scopeName(f.policy))}</p>` : ''}<span class="share-status">${f.revokedAt != null ? 'Revoked' : f.expiresOn ? `Expires ${esc(f.expiresOn)}` : 'Active'}${f.createdByYou ? ' · Created by you' : ''}</span></div>
          ${f.revokedAt == null ? `<button class="text-button" data-feed-revoke="${esc(f.id)}" ${busy ? 'disabled' : ''}>Revoke</button>` : `<button class="text-button" data-feed-delete="${esc(f.id)}" ${busy ? 'disabled' : ''}>Delete</button>`}</div>`).join('')}</div>` : ''}`;
      if (focus || exportFocus) { const control = element.querySelector(focus || exportFocus); control?.focus({ preventScroll: true }); if (selection && control) control.setSelectionRange(...selection); }
    }
    function cancelExport(message = 'Download cancelled.') {
      if (!state.exportWorker) return;
      state.exportWorker.terminate(); state.exportWorker = null;
      state.exportObserver?.disconnect(); state.exportObserver = null; state.exportStatus = message;
    }
    function exportAll() {
      if (state.exportWorker) return;
      const url = selectedURL(saved(), true); if (!url) return;
      const worker = new Worker(new URL('./feed-export-worker.js', import.meta.url), {type:'module'});
      state.exportWorker = worker; state.exportStatus = 'Reading shared data…'; draw();
      element.querySelector('[data-feed-export-cancel]')?.focus();
      state.exportObserver = new MutationObserver(() => { if (!element.isConnected) cancelExport(); });
      state.exportObserver.observe(document.body, {childList:true,subtree:true});
      const finish = () => { worker.terminate(); if(state.exportWorker === worker)state.exportWorker=null; state.exportObserver?.disconnect();state.exportObserver=null; };
      worker.onmessage = ({data}) => {
        if (epoch !== credentialEpoch || state.exportWorker !== worker) { finish(); return; }
        if (data.error) { finish(); state.exportStatus=data.error; draw(); return; }
        if (data.progress) {
          const p=data.progress;
          state.exportStatus=p.stage==='waiting'?`Request limit reached. Waiting ${p.retryAfterSeconds} seconds…`:p.stage==='images'?`Downloaded ${p.completed} of ${p.total} photos.`:p.stage==='packaging'?'Preparing ZIP…':`Read ${p.records} records across ${p.pages} pages.`;
          const status=element.querySelector('[data-export-status]');if(status)status.textContent=state.exportStatus;return;
        }
        finish();
        if(!alive())return;
        const blob=new Blob([data.bytes],{type:'application/zip'}), href=URL.createObjectURL(blob),link=document.createElement('a');
        document.body.appendChild(link);link.href=href;link.download='banana-analysis-'+new Date().toISOString().slice(0,10)+'.zip';link.click();link.remove();setTimeout(()=>URL.revokeObjectURL(href),60000);
        state.exportStatus='Complete download ready.';draw();
      };
      worker.onerror=()=>{finish();state.exportStatus='The download could not be prepared. Try again; no partial file was saved.';draw();};
      worker.postMessage({url,preview:preview||saved()?.session,images:state.includeImages!==false});
    }
    function invalidateResponse() {
      if(state.exportWorker)cancelExport('Selection changed. Start the download again.');else state.exportStatus='';
      state.responseAbort?.abort(); state.responseAbort = null;
      state.responseEpoch = (state.responseEpoch ?? 0) + 1; state.responseText = null; state.responseError = false; state.responseLoading = false;state.calendarIssue=null;
    }
    async function loadResponse(next = null) {
      const url = next ?? selectedURL(saved(), true); if (!url) return;
      state.responseAbort?.abort();
      const controller = new AbortController(); state.responseAbort = controller;
      const owner = state.responseEpoch = (state.responseEpoch ?? 0) + 1;
      state.responseLoading = true; state.responseError = false;state.calendarIssue=null; state.redraw?.();
      try {
        const target = new URL(url); if (target.origin !== location.origin) throw new Error('Feed origin changed.');
        const response = await fetch(target, { credentials: preview || saved()?.session ? 'same-origin' : 'omit', cache: 'no-store', signal: controller.signal });
        const text = await response.text();
        if (epoch !== credentialEpoch || state.responseEpoch !== owner) return;
        if(response.status===503&&text.length<=65536){try{const issue=JSON.parse(text);if(issue.error==='calendar_unavailable')state.calendarIssue={message:issue.message||'A selected calendar could not be read. Retry, edit the share or exclude Calendar from this request.',issues:Array.isArray(issue.issues)?issue.issues:[]};}catch{}}
        let display = text.slice(0, 65536);
        if (text.length <= 65536 && state.format === 'json') { try { display = JSON.stringify(JSON.parse(text), null, 2); } catch {} }
        state.responseText = display.slice(0, 65536); state.responseClipped = text.length > 65536 || display.length > 65536;
        state.responseStatus = response.status; state.responseURL = target.href;
        const nextURL = response.headers.get('Link')?.match(/<([^>]+)>;\s*rel="next"/)?.[1];
        state.responseNext = response.ok && nextURL && new URL(nextURL).origin === location.origin ? nextURL : null;
      } catch { if (epoch === credentialEpoch && state.responseEpoch === owner) state.responseError = true; }
      finally { if (epoch === credentialEpoch && state.responseEpoch === owner) { state.responseLoading = false; state.responseAbort = null; state.redraw?.(); } }
    }
    state.redraw = draw;
    async function refreshManifest(current) {
      invalidateResponse();
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
    async function reload(refresh = true) { const data = await json(base); if (epoch === credentialEpoch) { state.feeds = data.feeds; if (refresh && secrets.get(base)) await refreshManifest(secrets.get(base)); state.redraw?.(); } }
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
        if (epoch === credentialEpoch) { state.busy = false; void loadResponse().catch(error => { if (alive()) notice(error.message, true); }); }
      } catch (error) { if (alive()) notice(error.message, true); }
      finally { state.busy = false; state.redraw?.(); }
    };
    element.onchange = event => {
      const target = event.target;
      if (target.matches('[data-feed-images]')) { state.includeImages=target.checked;cancelExport('Photo selection changed. Start the download again.');draw();return; }
      if (target.matches('[data-feed-type]')) {
        const current = saved(), available = [...(current?.manifest?.types ?? []).map(t => t.type), ...(current?.manifest?.calendar ? ['calendar'] : [])];
        const picked = new Set(state.selectedTypes ?? available);
        if (target.checked) picked.add(target.dataset.feedType); else picked.delete(target.dataset.feedType);
        state.selectedTypes = [...picked]; invalidateResponse(); draw(); if (preview) loadResponse(); element.querySelector(`[data-feed-type="${CSS.escape(target.dataset.feedType)}"]`)?.focus();
      } else if (target.matches('[data-feed-format]')) { state.format = target.value; invalidateResponse(); draw(); if (preview) loadResponse(); element.querySelector('[data-feed-format]')?.focus(); }
      else if (target.matches('[data-feed-days]')) { state.calendarDays = Number(target.value); invalidateResponse(); draw(); if (preview) loadResponse(); element.querySelector('[data-feed-days]')?.focus(); }
    };
    element.onclick = async event => {
      const button = event.target.closest('[data-feed-copy],[data-feed-revoke],[data-feed-retry],[data-feed-response],[data-feed-next],[data-feed-export],[data-feed-export-cancel],[data-feed-delete],[data-feed-exclude-calendar]');
      if (!button || state.busy) return;
      try {
        if (button.hasAttribute('data-feed-exclude-calendar')) {
          const selected=state.selectedTypes??permittedTypes()??[];state.selectedTypes=selected.filter(t=>t!=='calendar');invalidateResponse();draw();await loadResponse();
          if(alive())notice('Calendar excluded from this request. The saved share was not changed.');
        }
        else if (button.hasAttribute('data-feed-delete')) {
          if (!confirm('Delete this revoked connection from the list? Your Banana data will be kept.')) return;
          state.busy=true;draw();await json(`${base}/${button.dataset.feedDelete}`, 'DELETE', {});
          if (epoch===credentialEpoch) { await state.reload?.();if(alive())notice('Revoked connection deleted.'); }
        }
        else if (button.hasAttribute('data-feed-export')) { exportAll(); }
        else if (button.hasAttribute('data-feed-export-cancel')) { cancelExport();draw(); }
        else if (button.hasAttribute('data-feed-response')) { await loadResponse(); }
        else if (button.hasAttribute('data-feed-next')) { await loadResponse(state.responseNext); }
        else if (button.hasAttribute('data-feed-retry')) { if (saved()) await refreshManifest(saved()); }
        else if (button.dataset.feedCopy) {
          const current = saved();
          const value = button.dataset.feedCopy === 'types' ? permittedTypes()?.join(',') : button.dataset.feedCopy === 'token' ? current?.token : element.querySelector('[data-feed-url]')?.value;
          if (!value) return;
          await navigator.clipboard.writeText(value);
          if (alive()) notice(button.dataset.feedCopy === 'types' ? 'Valid data types copied.' : preview ? 'Example URL copied. It does not grant access.' : button.dataset.feedCopy === 'token' ? 'API token copied.' : 'Private feed URL copied.');
        } else {
          state.busy = true; draw();
          await json(`${base}/${button.dataset.feedRevoke}/revoke`, 'POST', {});
          if (saved()?.id === button.dataset.feedRevoke) secrets.delete(base);
          if (epoch === credentialEpoch) { await state.reload?.(); if (alive()) notice('Connection revoked. Existing URLs no longer work.'); }
        }
      } catch (error) { if (alive()) notice(error.message, true); }
      finally { if (state.busy) { state.busy = false; state.redraw?.(); } }
    };
    invalidateResponse(); draw();
    if (preview) { invalidateResponse(); await loadResponse(); return; }
    try { await reload(); } catch (error) { if (alive()) notice(error.message, true); }
  }
  return { mount, clear() { credentialEpoch++; generation++; for (const state of states.values()) {state.responseAbort?.abort();state.exportWorker?.terminate();state.exportObserver?.disconnect();} secrets.clear(); states.clear(); } };
}
