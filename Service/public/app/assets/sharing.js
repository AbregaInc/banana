// Owner controls only. Preview opens the normal viewer against the server's guest projection.
const sections = {
  personalPlan: ['Routines & reminders', 'Your own routines, alarms and day plans.'],
  workouts: ['Workouts', 'Recorded sessions, Apple Health workout history and workout plans.'],
  health: ['Health trends', 'The health measurements synced from your iPhone.'],
  nutrition: ['Food', 'Meals, photos and saved foods.'],
  taken: ['Taken', 'Supplements, medications and dose history.'],
  notes: ['Notes', 'Voice notes, recordings and transcripts.'],
  listening: ['Listening', 'Shows, listening history, progress and available transcripts.'],
};
const blank = () => ({ calendars: [], sections: Object.fromEntries(Object.keys(sections).map(k => [k, false])) });
const key = (sub, id) => JSON.stringify([sub, id]);

export function sharingControls({ request, escape: esc, notice, rerender }) {
  let list = [], accounts = [], received = [], emailEnabled = false, draft = null, dirty = false, selected = '', busy = false;
  const json = async (url, method = 'GET', data) => (await request(url, { method,
    ...(data == null ? {} : { headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data) }) })).json();
  const picked = (sub, id) => draft.policy.calendars.find(c => c.sub === sub && c.id === id)?.access ?? 'none';
  const hasData = () => draft.policy.calendars.length || Object.values(draft.policy.sections).some(Boolean);
  const validEmail = () => /^[^\s<>@]+@[^\s<>@]+\.[^\s<>@]+$/.test(draft.email.trim());
  function choose(sub, id, access) {
    draft.policy.calendars = draft.policy.calendars.filter(c => key(c.sub, c.id) !== key(sub, id));
    if (access !== 'none') draft.policy.calendars.push({ sub, id, access });
    dirty = true;
  }
  function buttons() {
    for (const control of document.querySelectorAll('.share-editor input,.share-editor select')) control.disabled = busy || control.id === 'share-email' && Boolean(draft.publishedVersion);
    for (const button of document.querySelectorAll('[data-share-bulk],[data-share-body],[data-share-revoke],[data-share-action="new"]')) button.disabled = busy;
    const preview = document.querySelector('[data-share-action="preview"]');
    if (preview) preview.disabled = busy || !validEmail() || !hasData();
    for (const button of document.querySelectorAll('[data-share-publish]')) button.disabled = busy || dirty || !draft.previewed || !emailEnabled && button.dataset.sharePublish === 'send';
    const summary = document.querySelector('#share-scope-summary');
    if (summary) {
      const full = draft.policy.calendars.filter(c => c.access === 'details').length, privateBusy = draft.policy.calendars.filter(c => c.access === 'busy').length;
      const names = Object.entries(draft.policy.sections).filter(([, enabled]) => enabled).map(([id]) => sections[id][0]);
      summary.textContent = [full ? `${full} full calendar${full === 1 ? '' : 's'}` : '', privateBusy ? `${privateBusy} busy-only calendar${privateBusy === 1 ? '' : 's'}` : '', ...names].filter(Boolean).join(' · ') || 'Nothing selected yet.';
    }
  }
  async function render(id = '') {
    const [data, calendars, session] = await Promise.all([json('/app/api/shares'), json('/app/api/calendars'), json('/app/api/session')]);
    list = data.shares; emailEnabled = data.emailEnabled; accounts = calendars.accounts; received = session.shares;
    if (!draft || selected !== id) {
      selected = id;
      const existing = list.find(s => s.id === id && s.status !== 'revoked');
      draft = existing ? { ...existing, policy: structuredClone(existing.draftPolicy) } : { id: null, email: '', policy: blank(), previewed: false };
      dirty = !existing;
    } else if (!dirty && draft.id) {
      const current = list.find(s => s.id === draft.id);
      if (current) draft = { ...current, policy: structuredClone(current.draftPolicy) };
    }
    const checkbox = id => `<label class="share-section"><input type="checkbox" data-share-section="${id}" ${draft.policy.sections[id] ? 'checked' : ''}><span><strong>${sections[id][0]}</strong><small>${sections[id][1]}</small></span></label>`;
    const calendarHTML = accounts.map(a => `<fieldset class="share-account"><legend>${esc(a.email)}</legend>
      ${a.error ? `<p class="notice">${a.error === 'reconnect' ? 'Reconnect this account in Banana to choose its calendars.' : 'This account could not be read. Try Refresh.'}</p>` : ''}
      ${a.calendars.length ? `<div class="share-bulk"><span>Set all in this account:</span>${[['none', 'Off'], ['busy', 'Busy only'], ['details', 'Full details']].map(([mode, label]) => `<button class="text-button" data-share-bulk="${mode}" data-share-sub="${esc(a.sub)}">${label}</button>`).join('')}</div>` : ''}
      ${a.calendars.map(c => `<label class="share-calendar"><span>${esc(c.title)}</span><select data-share-calendar="${esc(c.id)}" data-share-sub="${esc(a.sub)}" aria-label="${esc(c.title)} access">
        ${[['none', 'Not shared'], ['busy', 'Busy only'], ['details', 'Full details']].map(([value, label]) => `<option value="${value}" ${picked(a.sub, c.id) === value ? 'selected' : ''}>${label}</option>`).join('')}</select></label>`).join('')}
      </fieldset>`).join('');
    const current = list.filter(s => s.status !== 'revoked');
    const entries = current.map(s => `<article class="share-invitation"><div><h3>${esc(s.guestName || s.email)}</h3>${s.guestName ? `<p>${esc(s.email)}</p>` : ''}<span class="share-status">${s.status === 'draft' ? 'Draft · not sent' : s.sendStatus === 'failed' ? 'Email failed · permissions saved' : s.status === 'active' ? 'Connected' : 'Invited'}</span></div><div class="share-row-actions"><a class="text-button" href="#sharing/${s.id}">${s.status === 'draft' ? 'Continue draft' : 'Edit access'}</a>${s.policy ? `<button class="text-button" data-share-revoke="${s.id}">Remove access</button>` : ''}</div></article>`).join('');
    const body = ['workouts', 'health', 'nutrition', 'taken'];
    return `<div class="sharing-intro"><p>Invite someone to a read-only view of the parts of Banana you choose. They sign in with their own Google account.</p><button class="text-button" data-share-action="new">New invitation ↗</button></div>
      <section class="share-editor" aria-labelledby="share-editor-title"><div class="section-title"><h2 id="share-editor-title">${draft.publishedVersion ? 'Edit guest access' : 'Invite a guest'}</h2><span class="share-status">${draft.publishedVersion ? 'Changes stay private until you publish them' : 'Nothing has been sent'}</span></div>
      <label class="share-email">Google sign-in email<input type="email" id="share-email" autocomplete="email" placeholder="trainer@example.com" value="${esc(draft.email)}" ${draft.publishedVersion ? 'disabled' : ''}><small>Use the email they sign in to Google with. The link alone does not grant access.</small></label>
      <h3>Calendars</h3><p class="subtle">Full details includes titles, notes, locations and meeting links. Busy only shares occupied time. New calendars are not shared automatically.</p>
      ${calendarHTML || '<p class="subtle">Connect Google Calendar in Banana to choose calendars here.</p>'}
      <div class="share-extra">${checkbox('personalPlan')}</div>
      <div class="share-section-heading"><h3>Body</h3><div><button class="text-button" data-share-body="all">Select all</button><button class="text-button" data-share-body="none">Clear</button></div></div>
      <div class="share-sections">${body.map(checkbox).join('')}</div>
      <h3>Other parts of Banana</h3><div class="share-sections">${['notes', 'listening'].map(checkbox).join('')}</div>
      <div class="share-review"><h3>This guest will see</h3><p id="share-scope-summary"></p><p class="subtle">Preview the complete guest view first. Changing any permission requires a new preview.</p>
      <div class="share-actions"><button class="button" data-share-action="preview" ${busy || !validEmail() || !hasData() ? 'disabled' : ''}>Preview as guest ↗</button>
      ${draft.publishedVersion ? `<button class="button secondary" data-share-publish="publish" ${dirty || !draft.previewed || busy ? 'disabled' : ''}>Save access</button>` : ''}
      <button class="button secondary" data-share-publish="send" ${dirty || !draft.previewed || busy || !emailEnabled ? 'disabled' : ''}>${draft.publishedVersion ? 'Send invitation again' : 'Send invitation'}</button></div>
      ${!emailEnabled ? '<p class="notice">Email delivery is not configured. You can prepare and preview a draft.</p>' : ''}</div></section>
      <section><div class="section-title"><h2>Your guests</h2></div>${entries || '<p class="subtle">No guests yet. Start with a preview above.</p>'}</section>
      ${received.length ? `<section><div class="section-title"><h2>Shared with you</h2></div>${received.map(s => `<a class="record" href="/share/${s.id}"><strong>${esc(s.owner)}</strong><span>Open shared view ↗</span></a>`).join('')}</section>` : ''}`;
  }
  function change(target) {
    if (!draft) return false;
    if (target.id === 'share-email') { draft.email = target.value; dirty = true; }
    else if (target.dataset.shareSection) { draft.policy.sections[target.dataset.shareSection] = target.checked; dirty = true; }
    else if (target.dataset.shareCalendar) choose(target.dataset.shareSub, target.dataset.shareCalendar, target.value);
    else return false;
    buttons(); return true;
  }
  async function click(target) {
    const button = target.closest('[data-share-action],[data-share-publish],[data-share-bulk],[data-share-body],[data-share-revoke]');
    if (!button) return false;
    if (busy) return true;
    if (button.dataset.shareAction === 'new') {
      draft = null; dirty = false; selected = '';
      if (location.hash === '#sharing') await rerender(); else location.hash = 'sharing';
      return true;
    }
    if (button.dataset.shareBulk) {
      const account = accounts.find(a => a.sub === button.dataset.shareSub);
      for (const calendar of account?.calendars ?? []) choose(account.sub, calendar.id, button.dataset.shareBulk);
      await rerender(); return true;
    }
    if (button.dataset.shareBody) {
      for (const key of ['workouts', 'health', 'nutrition', 'taken']) draft.policy.sections[key] = button.dataset.shareBody === 'all';
      dirty = true; await rerender(); return true;
    }
    busy = true; buttons();
    let navigating = false;
    try {
      if (button.dataset.shareRevoke) {
        await json(`/app/api/shares/${button.dataset.shareRevoke}/revoke`, 'POST', {});
        if (draft?.id === button.dataset.shareRevoke) { draft = null; selected = ''; }
        notice('Access removed. The guest can no longer open this shared view.');
      } else if (button.dataset.shareAction === 'preview') {
        const saved = await json(draft.id ? `/app/api/shares/${draft.id}/draft` : '/app/api/shares', draft.id ? 'PUT' : 'POST',
          { email: draft.email, policy: draft.policy, ...(draft.id ? { version: draft.version } : {}) });
        draft = { ...saved, policy: saved.draftPolicy }; selected = saved.id; dirty = false;
        const preview = await json(`/app/api/shares/${saved.id}/preview`, 'POST', { version: saved.version });
        navigating = true; location.assign(preview.url); return true;
      } else if (button.dataset.sharePublish) {
        const action = button.dataset.sharePublish;
        const saved = await json(`/app/api/shares/${draft.id}/${action}`, 'POST', { version: draft.version });
        draft = { ...saved, policy: saved.draftPolicy }; dirty = false;
        notice(action === 'send' ? 'Invitation sent. They can sign in with their Google account.' : 'Guest access updated.');
      }
    } catch (e) { notice(e.message, true); }
    finally { busy = false; if (!navigating) await rerender(); }
    return true;
  }
  return { render, change, click, mounted: buttons, isDirty: () => dirty };
}
