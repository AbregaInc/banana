import { feedLink } from './feed-link.js';
import { feedGuide, feedReference } from './feed-guide.js';
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
    const state = states.get(base) ?? { busy: false, feeds: [], selectedTypes: null };
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
        { types: state.selectedTypes == null ? 'all' : selected, format: 'json', calendarDays: selected.includes('calendar') ? 7 : undefined });
    }

    function draw() {
      if (!alive()) return;
      // Native disclosure state and keyboard position survive metadata/response refreshes.
      for(const panel of element.querySelectorAll('details[data-feed-panel]'))(state.panels??={})[panel.dataset.feedPanel]=panel.open;
      const active=element.contains(document.activeElement)?document.activeElement:null;
      const focus = ['[data-feed-url]', '[data-feed-images]', '[data-feed-export-cancel]', '[data-feed-response]']
        .find(selector => active?.matches(selector));
      const selection=active?.tagName==='INPUT'&&active.type==='text'?[active.selectionStart,active.selectionEnd]:null;
      const current=saved(),created=preview?state.previewCreated:Boolean(secrets.get(base)),{busy}=state;
      const access=current?.manifest?.access??sharedAccess;
      const feeds=preview?[]:state.feeds;
      const url=created?feedLink(current?.dataURL??current?.url,{types:'all',format:'json'}):'';
      const scope=access?accessName(access):'';
      const apiURL = url ? new URL(url) : null;
      apiURL?.searchParams.delete('signature');
      function credentialRow(key, label, value, button) {
        return `<label class="feed-url-label" for="feed-credential-${key}">${label}</label>
          <div class="feed-link-row">
            <input id="feed-credential-${key}" ${key==='url'?'data-feed-url':''}
              type="${key==='token'?'password':'text'}" readonly value="${esc(value)}">
            <button class="button" data-feed-copy="${key}" ${preview||busy||!value?'disabled':''}>${button}</button>
          </div>`;
      }
      const credentials = created ? `
        ${credentialRow('url', 'Private feed URL', preview ? 'Preview of the recipient’s URL' : url, 'Copy URL')}
        <p class="feed-footnote">This link includes its own access key. Use it directly in a browser or tool.</p>
        <div class="feed-api-credentials">
          <h3>For tools that ask for an API token</h3>
          ${credentialRow('endpoint', 'API URL', preview ? 'Preview of the API URL' : apiURL?.href ?? '', 'Copy API URL')}
          ${credentialRow('token', 'API token', preview ? 'EXAMPLE' : current?.token ?? '', 'Copy token')}
          <p class="feed-footnote">Use both together. For HTTP requests, send <code>Authorization: Bearer &lt;token&gt;</code>.</p>
        </div>
        <p class="feed-footnote">${preview ? 'Your recipient creates their own credentials.' : 'Save your credentials now. They’re shown when you create the feed.'}</p>` : '';
      const createForm=label=>`<form data-feed-form><button class="button" type="submit" ${busy?'disabled':''}>${busy?'Creating…':label}</button></form>`;
      const recovery=state.calendarIssue?`<div class="feed-warning" role="alert"><strong>Calendar export is incomplete</strong><p>${esc(state.calendarIssue.issues.some(i=>i.reason==='unavailable')?'The owner needs to restore or remove an unavailable calendar.':state.calendarIssue.issues.some(i=>i.reason==='reconnect')?'The owner needs to reconnect Google Calendar in Banana.':'Some calendar data could not be read. Try again.')}</p><div class="share-actions"><button class="text-button" data-feed-response>Retry</button>${editShareURL?`<a class="text-button" href="${esc(editShareURL)}">Edit shared calendars</a>`:''}${permittedTypes()?.some(type=>type!=='calendar')?'<button class="text-button" data-feed-exclude-calendar>Preview without Calendar</button>':''}</div><details><summary>Calendar details</summary><ul>${state.calendarIssue.issues.map(i=>`<li>${esc(i.calendar||'Shared calendar')}${i.ownerCalendarID?`<br><code>${esc(i.ownerCalendarID)}</code>`:''}</li>`).join('')}</ul></details></div>`:'';
      const open=name=>state.panels?.[name]?'open':'';
      element.innerHTML=`<div class="feed-page">
        ${heading?'<h3>Data feed</h3>':''}
        <section class="feed-main" aria-label="Data feed">
          ${scope?`<p class="feed-scope">${esc(scope)}</p>`:''}
          ${created ? credentials : createForm('Create data feed')}
          ${feedGuide({access,created})}
        </section>
        <details class="feed-reference-panel" data-feed-panel="reference" ${open('reference')}><summary>Developer reference</summary><div class="feed-reference-content">
          <div class="share-actions feed-developer-links">
            <a class="text-button" href="/app/assets/analysis-schema.json" target="_blank" rel="noopener noreferrer">Schema ↗</a>
            ${created&&!preview&&current?.manifestURL?`<a class="text-button" href="${esc(current.manifestURL)}" target="_blank" rel="noreferrer noopener">Feed metadata ↗</a>`:''}
          </div>
          ${current?.manifestError?'<p>Feed details could not be loaded. <button class="text-button" data-feed-retry>Retry</button></p>':''}
          ${current?`<details data-feed-panel="response" ${open('response')}><summary>Response preview</summary><div class="feed-response"><button class="text-button" data-feed-response ${busy?'disabled':''}>${state.responseText==null?'Load response':'Refresh response'}</button>${state.responseLoading?'<p role="status">Loading…</p>':''}${recovery}${state.selectedTypes?'<p>Calendar excluded from this preview and download. The private feed URL still requests all shared data.</p><button class="text-button" data-feed-restore-calendar>Include Calendar again</button>':''}${state.responseText!=null?`<p>HTTP ${state.responseStatus}${state.responseClipped?' · Preview truncated':''}</p><pre tabindex="0" aria-label="Feed response"><code>${esc(state.responseText)}</code></pre><div class="share-actions"><a class="text-button" href="${esc(state.responseURL)}" target="_blank" rel="noreferrer noopener">Open full response ↗</a>${state.responseNext?`<button class="text-button" data-feed-next ${state.responseLoading?'disabled':''}>Next page</button>`:''}</div>`:state.responseError?'<p>Could not load the response. Try again.</p>':''}</div></details>
          <details data-feed-panel="archive" ${open('archive')}><summary>Download a copy</summary><div class="feed-export"><label><input type="checkbox" data-feed-images ${state.includeImages!==false?'checked':''}> Include meal photos</label><div class="share-actions"><button class="button" data-feed-export ${busy||state.exportWorker?'disabled':''}>Download ZIP</button>${state.exportWorker?'<button class="text-button" data-feed-export-cancel>Cancel download</button>':''}</div><p role="status" data-export-status>${esc(state.exportStatus??'')}</p></div></details>`:''}
          <details data-feed-panel="api-details" ${open('api-details')}><summary>Parameters, data types and examples</summary></details>
        </div></details>
        ${(feeds.length||created&&!preview)?`<details class="feed-manage-panel" data-feed-panel="manage" ${open('manage')}><summary>Manage feeds</summary><div class="feed-managed-list">${feeds.map(f=>`<div class="feed-managed-row"><div><strong>${esc(f.name)}</strong><p>${f.revokedAt!=null?'Revoked':f.expiresOn?'Expires '+esc(f.expiresOn):'Active'} · ${esc(new Date(f.createdAt).toLocaleDateString())}</p></div>${f.revokedAt==null?`<button class="text-button" data-feed-revoke="${esc(f.id)}" ${busy?'disabled':''}>Revoke</button>`:`<button class="text-button" data-feed-delete="${esc(f.id)}" ${busy?'disabled':''}>Delete</button>`}</div>`).join('')}</div></details>`:''}
      </div>`;
      const apiDetails = element.querySelector('[data-feed-panel="api-details"]');
      function renderReference() {
        if (apiDetails.open && !apiDetails.querySelector('.feed-guide')) {
          apiDetails.insertAdjacentHTML('beforeend', feedReference({
            access, types: permittedTypes(), manifestURL: created&&!preview?current?.manifestURL:'', preview, escape: esc,
          }));
        }
      }
      renderReference();
      apiDetails.addEventListener('toggle', renderReference);
      if(focus){const control=element.querySelector(focus);control?.focus({preventScroll:true});if(selection&&control)control.setSelectionRange(...selection);}
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
      let calendarIncomplete = false;
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
          calendarIncomplete ||= Boolean(p.calendarIncomplete);
          state.exportStatus=p.stage==='waiting'?`Request limit reached. Waiting ${p.retryAfterSeconds} seconds…`:p.stage==='images'?`Downloaded ${p.completed} of ${p.total} photos.`:p.stage==='packaging'?'Preparing ZIP…':`Read ${p.records} records across ${p.pages} pages.`;
          const status=element.querySelector('[data-export-status]');if(status)status.textContent=state.exportStatus;return;
        }
        finish();
        if(!alive())return;
        const blob=new Blob([data.bytes],{type:'application/zip'}), href=URL.createObjectURL(blob),link=document.createElement('a');
        document.body.appendChild(link);link.href=href;link.download='banana-analysis-'+new Date().toISOString().slice(0,10)+'.zip';link.click();link.remove();setTimeout(()=>URL.revokeObjectURL(href),60000);
        state.exportStatus=calendarIncomplete?'Download ready. Calendar is incomplete.':'Complete download ready.';draw();
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
        if(response.ok&&response.headers.has('Banana-Calendar-Unavailable')){
          let issues=[];
          try{issues=JSON.parse(text).calendarIssues??[];}catch{}
          state.calendarIssue={issues};
        }
        let display = text.slice(0, 65536);
        if (text.length <= 65536) { try { display = JSON.stringify(JSON.parse(text), null, 2); } catch {} }
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
    element.onsubmit = async event => {
      if (!event.target.matches('[data-feed-form]')) return;
      event.preventDefault(); if (state.busy) return;
      if (preview) { state.previewCreated = true; draw(); element.querySelector('[data-feed-url]')?.focus(); return; }
      const name = 'Data feed';
      state.busy = true; draw();
      try {
        const created = await json(base, 'POST', { name, ...(policy ? { policy: policy() } : {}) });
        if (epoch !== credentialEpoch) return;
        // Preserve the one-time result even if navigation removes this view during the request.
        secrets.set(base, created);
        state.selectedTypes = null;
        await refreshManifest(created);
        if (epoch === credentialEpoch) await state.reload?.(false);
        if (epoch === credentialEpoch) { state.busy = false; }
      } catch (error) { if (alive()) notice(error.message, true); }
      finally { state.busy = false; state.redraw?.(); if (alive()) (element.querySelector('[data-feed-copy=url]') ?? element.querySelector('[data-feed-form] button'))?.focus(); }
    };
    element.onchange = event => {
      const target = event.target;
      if (target.matches('[data-feed-images]')) { state.includeImages=target.checked;cancelExport('Photo selection changed. Start the download again.');draw();return; }
    };
    element.onclick = async event => {
      const button = event.target.closest('[data-feed-copy],[data-feed-revoke],[data-feed-retry],[data-feed-response],[data-feed-next],[data-feed-export],[data-feed-export-cancel],[data-feed-delete],[data-feed-exclude-calendar],[data-feed-restore-calendar]');
      if (!button || state.busy) return;
      try {
        if (button.hasAttribute('data-feed-exclude-calendar')) {
          const selected=state.selectedTypes??permittedTypes()??[];state.selectedTypes=selected.filter(t=>t!=='calendar');invalidateResponse();draw();await loadResponse();
          if(alive())notice('Calendar excluded from this request. The saved share was not changed.');
        }
        else if (button.hasAttribute('data-feed-restore-calendar')) {
          state.selectedTypes = null; invalidateResponse(); draw(); await loadResponse();
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
          const value = button.dataset.feedCopy === 'types' ? permittedTypes()?.join(',') : button.dataset.feedCopy === 'token' ? current?.token : element.querySelector('#feed-credential-' + CSS.escape(button.dataset.feedCopy))?.value;
          if (!value) return;
          await navigator.clipboard.writeText(value);
          if (alive()) notice(button.dataset.feedCopy === 'types' ? 'Valid data types copied.' : preview ? 'Example URL copied. It does not grant access.' : button.dataset.feedCopy === 'token' ? 'API token copied.' : button.dataset.feedCopy === 'endpoint' ? 'API URL copied.' : 'Private feed URL copied.');
        } else {
          state.busy = true; draw();
          await json(`${base}/${button.dataset.feedRevoke}/revoke`, 'POST', {});
          if (saved()?.id === button.dataset.feedRevoke) secrets.delete(base);
          if (epoch === credentialEpoch) { invalidateResponse(); await state.reload?.(); if (alive()) notice('Connection revoked. Existing URLs no longer work.'); }
        }
      } catch (error) { if (alive()) notice(error.message, true); }
      finally { if (state.busy) { state.busy = false; state.redraw?.(); } }
    };
    invalidateResponse(); draw();
    if (preview) return;
    try { await reload(); } catch (error) { if (alive()) notice(error.message, true); }
  }
  return { mount, clear() { credentialEpoch++; generation++; for (const state of states.values()) {state.responseAbort?.abort();state.exportWorker?.terminate();state.exportObserver?.disconnect();} secrets.clear(); states.clear(); } };
}
