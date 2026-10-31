import { CalendarWindowCache } from './calendar-window-cache.js';
import {parseFilters,filterTitle,filterInterval,prepareFilters,dateLabels} from './live-filters.js';
import { lzfseDecompress } from './vendor/lzfse.js';
import { activeSeconds, mergeWorkouts } from './workout-model.js';
import { workoutHTML, recordingHTML, distanceText, exactDuration } from './workout-view.js';
import { visibleDays, eventOnDay, layoutEvents, stepDay, authoredEvents } from './plan-model.js';
import { sharingControls } from './sharing.js';

const appHome = document.querySelector('meta[name="app-home"]').content;
const $ = (s) => document.querySelector(s);
const escape = (v) => String(v ?? '').replace(/[&<>"']/g, (c) => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const num = (v, digits = 0) => Number.isFinite(Number(v)) ? Number(v).toLocaleString(undefined, { maximumFractionDigits: digits }) : '—';
const date = (v, options = { month:'short', day:'numeric' }) => {
  if (v == null || v === '') return '—';
  const d = new Date(v);
  return Number.isFinite(d.getTime()) ? d.toLocaleDateString(undefined, options) : '—';
};
const time = (v) => v == null ? '' : new Date(v).toLocaleTimeString(undefined, { hour:'numeric', minute:'2-digit' });
const duration = (seconds) => {
  if (!Number.isFinite(seconds) || seconds < 0) return '—';
  const minutes = Math.round(seconds / 60);
  return minutes >= 60 ? `${Math.floor(minutes/60)}h ${minutes%60}m` : `${minutes} min`;
};
const clock = (h, m) => { const d = new Date(); d.setHours(h ?? 0,m ?? 0,0,0); return time(d); };
const human = (s) => String(s ?? '').replace(/([a-z])([A-Z])/g, '$1 $2').replace(/[_-]/g, ' ');
const fields = (r) => r.fields.v && !r.fields.v.$blob && typeof r.fields.v === 'object' ? r.fields.v : r.fields;
const shareMatch = location.pathname.match(/^\/share\/([A-Za-z0-9_-]{22})$/);
const sharedContext = shareMatch ? { id:shareMatch[1], preview:new URL(location.href).searchParams.get('preview') } : null;
function dataURL(path) {
  if(!sharedContext)return `/app/api/${path}`;
  const url=new URL(`/app/api/shared/${sharedContext.id}/${path}`,location.origin);
  if(sharedContext.preview!=null)url.searchParams.set('preview',sharedContext.preview);
  return url.pathname+url.search;
}
const blobURL = (r, field) => dataURL(`blob?${new URLSearchParams({ type:r.type, id:r.id, field })}`);
const section = (title, body, link = '') => `<section><div class="section-title"><h2>${escape(title)}</h2>${link}</div>${body}</section>`;
const empty = (title, description) => `<div class="empty"><h2>${escape(title)}</h2><p>${escape(description)}</p></div>`;
const stat = (label, value, unit='') => `<div><dt>${escape(label)}</dt><dd>${escape(value)}${unit ? ` <small>${escape(unit)}</small>` : ''}</dd></div>`;
const metric = (v, unit = '') => v == null ? '—' : `${num(v,1)}${unit ? ` ${unit}` : ''}`;
const dayKey = (v) => {const d=new Date(v);return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;};
const pages = {
  overview:{name:'Overview',kicker:'A LITTLE ROOM FOR EVERYTHING',description:'Your Banana, from all your devices.'},
  calendars:{name:'Calendars',kicker:'YOUR ACCOUNTS & CALENDARS',description:'Choose what appears and which calendars notify you. Synced with iPhone and Mac.'},
  plans:{name:'Plans',kicker:'THE SHAPE OF YOUR DAY',description:'Your day and week, across all your calendars.'},
  nutrition:{name:'Food',kicker:'WHAT KEEPS YOU GOING',description:'Meals, photos and the foods you keep coming back to.'},
  taken:{name:'Taken',kicker:'BODY · TAKEN',description:'Supplements, medications and dose history.'},
  workouts:{name:'Workouts',kicker:'TIME WELL SPENT',description:'Your sessions and the details behind them.'},
  health:{name:'Health',kicker:'THE LONGER VIEW',description:'Your Health trends, shared from your iPhone.'},
  podcasts:{name:'Listening',kicker:'SOMETHING GOOD IN YOUR EARS',description:'Your shows, listening history and transcripts.'},
  notes:{name:'Notes',kicker:'THOUGHTS WORTH KEEPING',description:'Your voice notes and the words that came with them.'},
  sharing:{name:'Sharing',kicker:'GUEST ACCESS',description:'Choose what a guest can see. Preview it before inviting them.'},
};
let renderId = 0;
let account, view = 'overview', generation = 0, refreshing = false, detailRecords = [], detailGeneration = 0;
let query = '', podcastTab = 'history', planDay = dayKey(Date.now());
const agendas = new CalendarWindowCache();
const filterStates=new Map();
let liveFilter=parseFilters('', 'plan'), filterSources=[];
let livePredicate=prepareFilters(liveFilter);
let filterSourcesPromise,filterSourcesLoaded=false;
async function loadFilterSources(){
  if(account.shared||filterSourcesLoaded)return;
  const epoch=generation;
  filterSourcesPromise??=(async()=>{const data=await(await request(dataURL('calendars'))).json();if(epoch!==generation)return;filterSources=data.accounts.flatMap(a=>a.calendars.filter(c=>c.included).flatMap(c=>[{id:c.id,name:c.title},{id:c.id,name:c.title+' ('+a.email+')'}]));filterSourcesLoaded=true;})();
  const work=filterSourcesPromise;
  try{await work;}finally{if(filterSourcesPromise===work)filterSourcesPromise=null;}
}
const filterScope=()=>({plans:'plan',notes:'notes',workouts:'workouts'}[view]??'text');
let planMode='day';try{planMode=localStorage.getItem('banana.plan.mode')==='week'?'week':'day';}catch{}
const calendarScroll = new Map();
const cache = new Map(), pending = new Map();
let workoutHistoryError='', healthSnapshot, snapshotPromise, workoutEntries=[], currentWorkout=null, recordingWorker=null;
let guestHomeSession=null;
const sharing=sharingControls({request,escape,notice:showNotice,rerender:render});
const canView=id=>!account?.shared || account.views.includes(id);

async function request(path, options = {}) {
  const r = await fetch(path, { credentials:'same-origin', cache:'no-store', ...options });
  if (r.status === 401) { signedOut(); throw new Error('Sign in again to open your space.'); }
  if (!r.ok) {
    const data=await r.json().catch(()=>({}));
    if(sharedContext&&r.status===403&&data.error==='access_unavailable')showAccessUnavailable();
    const message=typeof data.error==='string'&&!/^[a-z_]+$/.test(data.error)?data.error:r.status===404?'This file is not available yet.':r.status===403?'This view is not available to this Google account.':'Could not reach Banana. Please try again.';
    const error=new Error(message);error.status=r.status;throw error;
  }
  return r;
}
async function records(type) {
  if(account?.shared&&!account.allowedTypes.includes(type))return [];
  if (cache.has(type)) return cache.get(type);
  if (pending.has(type)) return pending.get(type);
  const current = generation;
  const work = (async () => {
    const all = []; let after = '';
    do {
      const data = await (await request(dataURL(`records?${new URLSearchParams({ type, after })}`))).json();
      all.push(...data.records.map((r) => ({ ...r, type })));
      after = data.next;
      if (current !== generation) throw new Error('View changed.');
    } while (after != null);
    cache.set(type,all); return all;
  })();
  pending.set(type,work);
  try { return await work; } finally { if(pending.get(type) === work) pending.delete(type); }
}
async function packed(r, field, marker = false) {
  const bytes = new Uint8Array(await (await request(blobURL(r,field))).arrayBuffer());
  let data = bytes;
  if(marker) { if(new TextDecoder().decode(bytes.subarray(0,6)) === 'LZFSE1') data = lzfseDecompress(bytes.subarray(6)); }
  else data = lzfseDecompress(bytes);
  return JSON.parse(new TextDecoder().decode(data));
}
async function snapshot() {
  if (healthSnapshot) return healthSnapshot;
  if (snapshotPromise) return snapshotPromise;
  const current = generation;
  snapshotPromise = (async () => {
    const rows = await records('health.snapshot');
    const r = rows.find((r) => r.fields.v?.$blob);
    const result = r ? await packed(r,'v',true) : null;
    if(current === generation) healthSnapshot = result;
    return result;
  })();
  try { return await snapshotPromise; } finally { snapshotPromise = null; }
}
function openAttr(r) { const i=detailRecords.push(r)-1; return `data-open="${i}"`; }
function row(r, title, sub = '', stamp = '', meta = '', foot = '') {
  return `<button class="record" ${openAttr(r)}><span class="record-date">${escape(stamp)}</span><span class="record-body">${r.type==='food.meal'&&fields(r).photoIDs?.length?`<span class="meal-thumbnail"><img src="${escape(blobURL({type:'food.mealPhoto',id:fields(r).photoIDs[0]},'v'))}" width="76" height="76" loading="lazy" alt="Photo of this meal"></span>`:''}<span class="record-copy"><span class="record-title">${escape(title)}</span>${sub ? `<span class="record-sub">${escape(sub)}</span>` : ''}</span></span><span class="record-meta">${escape(meta || '↗')}${foot ? `<small>${escape(foot)}</small>` : ''}</span></button>`;
}
function matches(r) {
  if(!liveFilter.terms.length)return liveFilter.version===1&&!liveFilter.issues.length;
  const f=fields(r);
  const text=view==='notes'?[f.transcript,f.context?.episodeTitle,f.context?.podcastTitle,f.context?.transcriptExcerpt].filter(Boolean).join('\n'):view==='workouts'?f.activity:JSON.stringify(f);
  return livePredicate({text,date:f.createdAt??f.date??f.start,kind:f.activity,duration:view==='workouts'?activeDuration(f):undefined,archived:Boolean(f.archivedAt)});
}
function filterControls(){
  livePredicate=prepareFilters(liveFilter,{firstWeekday:account?.weekStartWeekday??2});
  const mount=$('#live-filters');if(!mount)return;
  if(mount.contains(document.activeElement)&&document.activeElement.classList.contains('filter-inline-editor'))return;
  mount.hidden=$('#tools').hidden;
  mount.innerHTML=`<div class="filter-chips">${liveFilter.terms.map((t,i)=>`<span class="filter-chip"><button data-edit-filter="${i}" title="Edit filter">${escape(filterTitle(t))}</button><button data-remove-filter="${i}" aria-label="Remove ${escape(filterTitle(t))}">×</button></span>`).join('')}</div>${liveFilter.issues.map(s=>`<p class="filter-issue" role="status">${escape(s)}</p>`).join('')}`;
}
function rememberFilters(){filterStates.set(view,{query,filter:structuredClone(liveFilter)});}
function updateFilter(next){liveFilter=next;rememberFilters();render(true);}

function sortDate(list,key='date') { return [...list].sort((a,b) => (Number(fields(b)[key]) || 0)-(Number(fields(a)[key]) || 0)); }
function macros(f) { return (f.items ?? []).reduce((t,i) => { for(const k of Object.keys(t)) t[k] += Number(i.macros?.[k]) || 0; return t; }, {calories:0,proteinGrams:0,carbohydrateGrams:0,fatGrams:0}); }
function mealRow(r) { const f=fields(r),m=macros(f);return row(r,f.name || (f.items??[]).map(i=>i.name).join(', ') || 'Meal', (f.items??[]).map(i=>i.name).join(' · '), date(f.date), `${num(m.calories)} kcal`, time(f.date)); }
function workoutRow(r) {const f=fields(r);return row(r,f.activity || f.name || 'Workout',[f.totalDistance!=null?distanceText(f.totalDistance,account.preferences?.distanceUnit):'',f.source].filter(Boolean).join(' · '),date(f.start),duration(activeDuration(f)),f.avgHeartRate != null ? `${num(f.avgHeartRate)} bpm` : '');}
function activeDuration(f) { return f.durationSeconds ?? activeSeconds(f); }
function listenRow(r) { const f=fields(r); return row(r,f.episodeTitle || 'Listening session',f.podcastTitle || f.place || '',date(f.date), f.endedAt ? duration((f.endedAt-f.date)/1000) : 'Listening',time(f.date)); }
function noteRow(r) { const f=fields(r); return row(r,f.transcript?.slice(0,100) || human(f.kind) || 'Voice note',f.context?.podcastTitle || human(f.status),date(f.createdAt),f.archivedAt ? 'Archived' : '',time(f.createdAt)); }
function routineRow(r) { const f=fields(r),day=view==='plans'?planDay:dayKey(Date.now()),done=(cache.get('plan.override')??[]).some(o=>o.id===`${r.id}|main|${day}`&&fields(o).completed); return row(r,f.name || f.title || 'Routine', routineDescription(f), clock(f.hour,f.minute),done?'✓ Completed':f.enabled === false ? 'Off' : 'On'); }
function routineDescription(f) { const trigger=f.triggerKind; return [trigger && trigger !== 'time' ? human(trigger) : days(f.weekdays), f.sourceLabel].filter(Boolean).join(' · '); }
function days(a) { return !a?.length ? 'Every day' : a.map(n=>['Sun','Mon','Tue','Wed','Thu','Fri','Sat'][n-1] || '').join(', '); }
function listHTML(rows,renderer) { return `<div class="record-list">${rows.map(renderer).join('')}</div>`; }
function viewCount(n,word='records') { $('#result-count').textContent = `${num(n)} ${word}`; }

async function overview() {
  if(account.shared)return `<p class="sharing-intro">${escape(account.ownerName)} chose these parts of Banana to share with you. This view is read-only.</p><div class="summary-grid">${account.views.filter(id=>id!=='overview').map(id=>`<a class="summary" href="#${id}"><span class="summary-label">${pages[id].name}</span><span class="summary-arrow" aria-hidden="true">↗</span><span class="summary-number">Open</span><span class="summary-foot">${id==='plans'?'Shared calendars & availability':'Shared with you'}</span></a>`).join('')}</div>`;
  const counts=account.counts;
  const definitions = [['plans','Routines',counts['plan.routine']??0,'Ready for your day'],['nutrition','Meals',counts['food.meal']??0,'Your food, remembered'],['workouts','Workouts',counts['health.workout']??0,'Every session counts'],['podcasts','Listening sessions',counts['podcast.listen']??0,'A little company'],['notes','Voice notes',counts['notes.voiceNote']??0,'Picked up along the way'],['health','Health','↗',account.consents.health ? 'The longer view' : 'Not shared yet']];
  const summary=`<div class="summary-grid">${definitions.map(([id,label,n,foot])=>`<a class="summary" href="#${id}"><span class="summary-label">${label}</span><span class="summary-arrow" aria-hidden="true">↗</span><span class="summary-number">${typeof n==='number'?num(n):n}</span><span class="summary-foot">${foot}</span></a>`).join('')}</div><div class="overview-note"><span>Made on your devices. Ready here.</span><span>Viewing only · make changes in Banana.</span></div>`;
  $('#content').innerHTML=summary+`<div id="overview-recent" class="split"><p class="subtle">Reading your latest activity…</p></div>`;
  const current=generation;
  try {
    const [routines,meals,listens,workouts] = await Promise.all([records('plan.routine'),records('food.meal'),records('podcast.listen'),combinedWorkouts(),records('plan.override')]);
    if(view!=='overview' || generation!==current) return;
    const recent=$('#overview-recent');if(!recent)return;const count=$('#content a[href="#workouts"] .summary-number');if(count)count.textContent=num(workouts.length);
    recent.innerHTML = `<div>${section('Your routines',routines.length ? listHTML(routines.filter(r=>fields(r).enabled!==false).sort((a,b)=>(fields(a).hour*60+fields(a).minute)-(fields(b).hour*60+fields(b).minute)).slice(0,4),routineRow) : empty('Room for a routine','The routines you make in Banana will appear here.'),'<a href="#plans">All plans ↗</a>')}</div><div>${section(meals.length?'Latest meals':'Latest listening',meals.length?listHTML(sortDate(meals).slice(0,3),mealRow):listens.length?listHTML(sortDate(listens).slice(0,3),listenRow):empty('Nothing here yet','Open Banana on a device to sync your data.'),`<a href="#${meals.length?'nutrition':'podcasts'}">View all ↗</a>`)}</div>`;
  } catch(e) { if(view==='overview' && generation===current && $('#overview-recent')) $('#overview-recent').innerHTML=`<p class="subtle">${escape(e.message)}</p>`; }
}
function dayStep(key,by){return stepDay(key,by);}
function saveCalendarScroll(){const el=$('.calendar-shell');if(el)calendarScroll.set(el.dataset.period,{top:el.scrollTop,left:el.scrollLeft});}
function applyCalendarLayout(){
  const grid=$('.calendar-grid');if(!grid)return;
  grid.style.setProperty('--days',grid.dataset.days);
  for(const el of document.querySelectorAll('[data-grid-start]')){
    const start=Number(el.dataset.gridStart),end=Number(el.dataset.gridEnd),lanes=Number(el.dataset.lanes||1),lane=Number(el.dataset.lane||0);
    el.style.top=`${start/60*58}px`;el.style.height=`${Math.max(23,(end-start)/60*58)}px`;
    el.style.left=`calc(${lane/lanes*100}% + 3px)`;el.style.width=`calc(${100/lanes}% - 6px)`;
  }
  for(const el of document.querySelectorAll('[data-hour]'))el.style.top=`${Number(el.dataset.hour)*58}px`;
  for(const el of document.querySelectorAll('[data-now]'))el.style.top=`${Number(el.dataset.now)/60*58}px`;
  const shell=$('.calendar-shell'),kept=calendarScroll.get(shell.dataset.period);
  shell.scrollTop=kept?.top??(8*58);shell.scrollLeft=kept?.left??0;
}
async function agenda(){
  const requestView=view,requestFilter=liveFilter,requestQuery=query,requestGeneration=generation,requestPass=renderId;
  if(query)await loadFilterSources();else loadFilterSources().catch(()=>{});
  if(requestPass!==renderId||requestView!==view||requestFilter!==liveFilter||requestQuery!==query||requestGeneration!==generation)return undefined;
  if(query){liveFilter=parseFilters(query,filterScope(),filterSources);rememberFilters();filterControls();}
  if(liveFilter.issues.length){viewCount(0,'items');return empty('Clarify your filter',liveFilter.issues.join(' '));}
  const interval=filterInterval(liveFilter,new Date(),account.weekStartWeekday??2);
  const days=interval?[]:visibleDays(planDay,planMode,account.weekStartWeekday??2);
  if(interval){for(let d=new Date(interval[0]);d<interval[1];d.setDate(d.getDate()+1))days.push(dayKey(+d));}
  const filterMode=liveFilter.terms.length?'1':'0';
  const key=(filterMode==='1'?'filter/':'')+days.join('/');
  const data=await agendas.read(key,async(signal)=>{
    const pages=[];
    for(let i=0;i<days.length;i+=7){
      const from=new Date(days[i]+'T00:00:00'),to=new Date(dayStep(days[Math.min(i+6,days.length-1)],1)+'T00:00:00');
      pages.push(await(await request(dataURL(`calendar?${new URLSearchParams({from:String(+from),to:String(+to),filter:filterMode})}`),{signal})).json());
    }
    const unique=new Map(pages.flatMap(p=>p.events).map(e=>[e.calendarID+':'+e.id,e]));
    return {events:[...unique.values()],unavailable:pages.flatMap(p=>p.unavailable)};
  });
  if(requestPass!==renderId||requestView!==view||requestQuery!==query||requestGeneration!==generation)return undefined;
  const available=(data.events??[]).flatMap(e=>[{id:e.calendarID,name:e.calendar},...(e.alsoOn??[]).map(c=>({id:c.calendarID,name:c.calendar}))]).filter(s=>s.id);
  const known=new Set(filterSources.map(s=>s.id));for(const s of available)if(!known.has(s.id)){filterSources.push(s);known.add(s.id);}
  if(query){const next=parseFilters(query,filterScope(),filterSources);if(JSON.stringify(next)!==JSON.stringify(liveFilter)){liveFilter=next;rememberFilters();filterControls();}}
  const [routines,alarms,extras,overrides,wakes]=await Promise.all(['plan.routine','plan.alarm','plan.extra','plan.override','core.wakePlan'].map(records));
  if(requestPass!==renderId)return undefined;
  const authored=authoredEvents({routines,alarms,extras,overrides,wakePlan:wakes[0]?fields(wakes[0]):null,meetings:data.events,days});
  const shown=[...data.events,...authored].filter(e=>!liveFilter.terms.length?livePredicate():livePredicate({text:[e.title,e.description,e.location].filter(Boolean).join(' '),date:+new Date(e.start.dateTime??e.start.date+'T00:00:00'),end:+new Date(e.end.dateTime??e.end.date+'T00:00:00'),calendarIDs:[e.calendarID,...(e.alsoOn??[]).map(x=>x.calendarID)],kind:e.cue?'routine':e.meeting?'meeting':'event',status:e.response??'accepted',allDay:e.allDay,person:(e.attendees??[]).map(a=>a.name+' '+a.email).join(' ')}));viewCount(shown.length,'items');
  if(liveFilter.terms.length||liveFilter.issues.length) {
    const unavailable=data.unavailable.length?'<p class="notice">Some calendars could not be read. Results are incomplete.</p>':'';
    const rows=shown.map(e=>`<button class="record" ${openAttr(e.record??{id:e.id,type:'calendar.event',fields:e})}><span class="record-date">${escape(date(e.start.dateTime??e.start.date))}</span><span class="record-body"><span class="record-copy"><span class="record-title">${escape(e.title)}</span><span class="record-sub">${escape(e.calendar)} · ${escape(e.allDay?'All day':time(e.start.dateTime))}</span></span></span></button>`).join('');
    return section(`Matching events · ${escape(date(+new Date(days[0]+'T12:00:00')))}–${escape(date(+new Date(days.at(-1)+'T12:00:00')))}`,unavailable+(rows?`<div class="record-list">${rows}</div>`:empty('No matching events',liveFilter.issues.length?'Clarify the filter above.':'Try widening the date range or removing a filter.')));
  }

  const amount=planMode==='week'?7:1;
  const toolbar=`<div class="agenda-toolbar"><div class="period-controls"><button class="text-button" data-plan-day="${dayStep(planDay,-amount)}" aria-label="Previous ${planMode}">←</button><button class="text-button" data-plan-day="${dayKey(Date.now())}">Today</button><button class="text-button" data-plan-day="${dayStep(planDay,amount)}" aria-label="Next ${planMode}">→</button></div><div class="tabs view-switch" aria-label="Plan view">${['day','week'].map(mode=>`<button data-plan-mode="${mode}" aria-pressed="${mode===planMode}">${mode==='day'?'Day':'Week'}</button>`).join('')}</div><label class="date-picker">Date <input type="date" id="plan-day" value="${planDay}" min="${dayStep(dayKey(Date.now()),-365)}" max="${dayStep(dayKey(Date.now()),365)}"></label></div>`;
  const errors=data.unavailable.length?`<p class="notice">${escape([...new Set(data.unavailable.map(e=>e.email))].join(', '))}: ${data.unavailable.some(e=>e.reason==='reconnect')?'sign in again in Banana on your device to reconnect the calendar.':'some calendars could not be read. Try Refresh.'}</p>`:'';
  const from=new Date(days[0]+'T00:00:00');
  const title=planMode==='day'?date(+from,{weekday:'long',month:'long',day:'numeric'}):`${date(+from)} – ${date(new Date(days.at(-1)+'T12:00:00'))}`;
  const hours=Array.from({length:24},(_,hour)=>`<span class="clock-label" data-hour="${hour}">${escape(clock(hour,0))}</span>`).join('');
  const grid=`<div class="calendar-shell" tabindex="0" role="region" aria-label="${planMode==='week'?'Week':'Day'} calendar, scroll to see all hours" data-period="${planMode}/${days[0]}"><div class="calendar-grid ${planMode==='week'?'week-grid':'day-grid'}" data-days="${days.length}"><div class="calendar-corner"></div>${days.map(day=>`<button class="calendar-day-head ${day===dayKey(Date.now())?'is-today':''}" data-select-day="${day}" aria-label="Open ${escape(date(new Date(day+'T12:00:00'),{weekday:'long',month:'long',day:'numeric'}))}"><span>${escape(date(new Date(day+'T12:00:00'),{weekday:'short'}))}</span><strong>${new Date(day+'T12:00:00').getDate()}</strong></button>`).join('')}<div class="calendar-all-label">All day</div>${days.map(day=>`<div class="calendar-all">${shown.filter(e=>e.allDay&&eventOnDay(e,day)).sort((a,b)=>Number(a.showsAsFree)-Number(b.showsAsFree)).map(e=>`<button class="all-day-event ${e.showsAsFree?'event-free':''}" ${openAttr({id:e.id,type:'calendar.event',fields:e})}>${escape(e.title)}</button>`).join('')}</div>`).join('')}<div class="calendar-hours">${hours}</div>${days.map(day=>{const list=shown.filter(e=>!e.allDay&&eventOnDay(e,day));return `<div class="calendar-day" aria-label="${escape(day)}">${layoutEvents(list,day).map(({event:e,start,end,lane,lanes})=>`<button class="calendar-event ${e.showsAsFree?'event-free':''} ${e.cue?'event-cue':''} ${e.skipped?'event-skipped':''} ${e.completed?'event-completed':''}" ${openAttr(e.record??{id:e.id,type:'calendar.event',fields:e})} data-grid-start="${start}" data-grid-end="${end}" data-lane="${lane}" data-lanes="${lanes}" aria-label="${escape(`${e.title}, ${time(e.start.dateTime)} to ${time(e.end.dateTime)}, ${e.calendar}${e.alsoOn?.length?', also on '+e.alsoOn.map(c=>c.calendar).join(', '):''}`)}"><span class="event-time">${escape(time(e.start.dateTime))}</span><strong>${e.completed?'✓ ':''}${escape(e.title)}</strong><span>${e.completed?'Completed · ':''}${escape(e.calendar)}${e.alsoOn?.length?` +${e.alsoOn.length}`:''}</span>${e.location?`<span>${escape(e.location)}</span>`:''}</button>`).join('')}${day===dayKey(Date.now())?`<div class="now-line" role="img" data-now="${new Date().getHours()*60+new Date().getMinutes()}" aria-label="Current time"></div>`:''}</div>`;}).join('')}</div></div>`;
  return section(title,toolbar+errors+grid+(shown.length?'':`<p class="subtle">${query?'No events match your search.':data.unavailable.length?'Some calendars need reconnecting.':'No calendar events in this '+planMode+'.'}</p>`));
}
async function plans() {
  const [routines,alarms,extras,workoutPlans,calendarHTML] = await Promise.all([...['plan.routine','plan.alarm','plan.extra','health.workoutPlan'].map(records),agenda()]);
  if(calendarHTML===undefined)return undefined;
  const overrides=await records('plan.override');
  const completed=new Set(overrides.filter(r=>fields(r).completed&&r.id.endsWith('|'+planDay)).map(r=>r.id.split('|')[0]));
  const all=liveFilter.terms.some(t=>t.field!=='text')?[]:[...routines,...alarms,...extras,...workoutPlans].filter(matches);
  if(!all.length)return calendarHTML;
  const filtered=(rows)=>rows.filter(matches);
  return calendarHTML+(filtered(routines).length ? section('Routines',listHTML(filtered(routines).sort((a,b)=>(fields(a).hour*60+fields(a).minute)-(fields(b).hour*60+fields(b).minute)),r=>completed.has(r.id)?row(r,fields(r).name||'Workout',routineDescription(fields(r)), '', '✓ Completed'):routineRow(r))) : '')
    +(filtered(alarms).length?section('Alarms',listHTML(filtered(alarms),(r)=>{const f=fields(r);return row(r,f.label||'Alarm','One-off alarm',date(f.fire),time(f.fire));})): '')
    +(filtered(extras).length?section('Day plans',listHTML(filtered(extras),(r)=>{const f=fields(r);const routine=routines.find(r=>r.id===f.seriesID);return row(r,routine?fields(routine).name:'Added routine','Added occurrence',date(f.start),time(f.start));})): '')
    +(filtered(workoutPlans).length?section('Workout plans',listHTML(filtered(workoutPlans),(r)=>{const f=fields(r);return row(r,f.name||f.title||'Workout plan',f.notes||f.note||'', '', '↗');})): '');
}
async function nutrition() {
  const [meals,saved]=await Promise.all(['food.meal','food.myFood'].map(records));
  const shown=sortDate(meals.filter(matches));viewCount(shown.length,'meals');
  let html=shown.length?listHTML(shown,mealRow):empty('Your meals belong here',query?'No meals match your search.':account.consents.health?'Log a meal in Banana and it will appear here.':'Turn on Sync Health in Banana to share your meals and Health data.');
  if(saved.filter(matches).length)html+=section('Saved foods',listHTML(saved.filter(matches),(r)=>{const f=fields(r);return row(r,f.name||'Saved food',f.servingLabel||'', '',`${num(f.per100g?.calories)} kcal`, 'per 100 g');}));
  return html;
}
async function taken() {
  const [supplements,doses]=await Promise.all(['food.supplement','food.dose'].map(records));
  const sups=supplements.filter(matches),logs=sortDate(doses.filter(matches));viewCount(logs.length,'doses');
  const names=new Map(supplements.map(r=>[r.id,fields(r).name]));
  return (sups.length?section('Supplements & medications',listHTML(sups,r=>{const f=fields(r);return row(r,f.name||'Supplement',[f.dose,human(f.kind)].filter(Boolean).join(' · '),clock(f.hour,f.minute),f.enabled===false?'Off':'On');})):empty('Taken',query?'No entries match your search.':'No supplements or medications in this view.'))
    +(logs.length?section('Dose history',listHTML(logs,r=>{const f=fields(r);return row(r,names.get(f.supplementID)||'Dose',human(f.status),date(f.date),time(f.date));})): '');
}
async function combinedWorkouts(){
  const summaries=await records('health.workout');
  let data=null;workoutHistoryError='';
  try{data=account.consents.health?await snapshot():null;}catch(error){workoutHistoryError=error.message;}
  workoutEntries=mergeWorkouts(summaries,data,account.preferences?.ownBundleID);
  return workoutEntries;
}
async function workouts(){
  const pass=renderId,epoch=generation;
  const all=await combinedWorkouts();
  if(pass!==renderId||epoch!==generation)return undefined;
  const rows=all.filter(matches);viewCount(rows.length,'workouts');
  if(!rows.length)return empty('Your workouts',query?'No workouts match your search.':account.consents.health?'Your recordings and Apple Health history appear here after your iPhone syncs.':'Turn on Sync Health in Banana to see your workouts here.');
  const total=rows.reduce((n,r)=>n+r.fields.durationSeconds,0),recorded=rows.filter(r=>r.summary).length;
  return (workoutHistoryError?`<p class="notice">Apple Health history could not be loaded. Showing available recordings. ${escape(workoutHistoryError)}</p>`:'')+`<div class="workout-readout"><span><strong>${num(rows.length)}</strong> workouts</span><span><strong>${duration(total)}</strong> active time</span><span><strong>${num(recorded)}</strong> with detailed recordings</span></div>`+listHTML(rows,workoutRow);
}
function spark(series, valueKey='value') {
  const a=series.map(x=>Number(x[valueKey])).filter(Number.isFinite);
  if(a.length<2)return '';
  const lo=Math.min(...a), hi=Math.max(...a),range=hi-lo || 1;
  const points=a.map((v,i)=>`${(i/(a.length-1)*300).toFixed(1)},${(55-(v-lo)/range*45).toFixed(1)}`).join(' ');
  return `<svg class="spark" viewBox="0 0 300 65" preserveAspectRatio="none" role="img" aria-label="${escape(`${a.length} readings, from ${num(a[0],1)} to ${num(a.at(-1),1)}`)}"><polyline points="${points}"/></svg>`;
}
async function health() {
  if(!account.consents.health)return empty('Your Health stays with you','Turn on Sync Health in Banana on your iPhone to see your trends here.');
  const data=await snapshot();
  if(!data)return empty('Waiting for your iPhone','Your Health snapshot will appear once your iPhone finishes syncing.');
  // Snapshot blobs use JSONEncoder's 2001-epoch seconds; record fields use Unix milliseconds.
  const swiftDate=(v)=> typeof v==='number'?(v+978307200)*1000:v;
  const definitions=[['sleepHours','Sleep','hours'],['restingHR','Resting heart rate','bpm'],['hrv','Heart rate variability','ms'],['steps','Steps','steps'],['vo2Max','VO₂ max','mL/kg/min'],['respiratory','Respiratory rate','/min'],['bodyMassKg','Body mass','kg'],['bodyFatPercentage','Body fat','%'],['activeEnergyKcal','Active energy','kcal'],['exerciseMinutes','Exercise','min'],['walkingHeartRate','Walking heart rate','bpm'],['basalEnergyKcal','Resting energy','kcal'],['leanBodyMassKg','Lean body mass','kg'],['bodyMassIndex','Body mass index',''],['heightMeters','Height','m'],['flightsClimbed','Flights climbed','flights'],['walkingSpeedMetersPerSecond','Walking speed','m/s']];
  const cards=definitions.filter(([key])=>data.trends?.[key]?.length).map(([key,label,unit])=>{
    const a=[...data.trends[key]].filter(x=>Number.isFinite(x.value)).sort((a,b)=>a.date-b.date).slice(-30),last=a.at(-1);if(!last)return '';
    return `<article class="measure"><p class="measure-label">${label}</p><p class="measure-value">${num(last.value,1)} <small>${unit}</small></p>${spark(a)}<p class="chart-caption">${date(swiftDate(a[0].date))} – ${date(swiftDate(last.date))} · ${a.length} readings</p></article>`;
  }).join('');
  let html=`<p class="health-intro">From Apple Health on your iPhone. Showing the latest reading and up to 30 points per trend.</p>${cards?`<div class="measure-grid">${cards}</div>`:empty('No trends shared yet','Open Banana on your iPhone to refresh your Health data.')}`;
  const hidden=new Set(data.hiddenWorkoutIDs??[]);
  const history=(data.workouts??[]).filter(w=>!hidden.has(w.id)).sort((a,b)=>b.start-a.start);
  if(history.length)html+=section('From Apple Health',listHTML(history.slice(0,100).map(w=>({id:w.id,type:'health.history',fields:{...w,start:swiftDate(w.start),end:swiftDate(w.end)}})),r=>{const f=fields(r);return row(r,f.activity||'Workout',f.source||'',date(f.start),duration(f.duration),f.energyKcal==null?'':`${num(f.energyKcal)} kcal`);}));
  return html;
}
async function podcasts() {
  const [listens,shows,transcripts,progress]=await Promise.all(['podcast.listen','podcast.show','podcast.transcript','podcast.progress'].map(records));
  const tabs=`<div class="tabs" aria-label="Listening views">${[['history','History',listens],['shows','Shows',shows],['transcripts','Transcripts',transcripts],['progress','Progress',progress]].map(([id,label,a])=>`<button data-podcast-tab="${id}" aria-pressed="${podcastTab===id}">${label} · ${num(a.length)}</button>`).join('')}</div>`;
  const episodeNames=new Map(listens.map(r=>[fields(r).episodeID,fields(r).episodeTitle]));
  const data={history:listens,shows,transcripts,progress}[podcastTab];
  const shown=data.filter(r=>matches(r)||Boolean(query&&episodeNames.get(r.id)?.toLowerCase().includes(query.toLowerCase())));
  viewCount(shown.length);
  let body;
  if(podcastTab==='history')body=listHTML(sortDate(shown),listenRow);
  if(podcastTab==='shows')body=listHTML(shown.sort((a,b)=>String(fields(a).title).localeCompare(String(fields(b).title))),r=>{const f=fields(r);return row(r,f.title||'Podcast',f.author||'','','↗');});
  if(podcastTab==='transcripts')body=listHTML(shown,r=>row(r,episodeNames.get(r.id)||'Episode transcript',human(fields(r).source),'','Read ↗'));
  if(podcastTab==='progress')body=listHTML(sortDate(shown,'updatedAt'),r=>{const f=fields(r);return row(r,episodeNames.get(r.id)||'Episode progress',f.completed?'Finished':'In progress',date(f.updatedAt),duration(f.position));});
  return tabs+(shown.length?body:empty('A little space for listening',query?'No listening matches your search.':'Your listening will appear after your devices sync.'));
}
async function notes() { const pass=renderId,epoch=generation;const data=await records('notes.voiceNote');if(pass!==renderId||epoch!==generation)return undefined;const rows=sortDate(data.filter(matches),'createdAt');viewCount(rows.length,'notes');return rows.length?listHTML(rows,noteRow):empty('A thought can start anywhere',query?'No notes match your search.':'Capture a voice note in Banana and find it here, with its transcript.'); }
const renders={calendars,overview,plans,nutrition,taken,workouts,health,podcasts,notes,sharing:()=>sharing.render(location.hash.split('/')[1]||'')};

async function calendars() {
  const data = await (await request('/app/api/calendars')).json();
  const warning = data.ready ? '' : '<p class="notice">Open Banana on your iPhone or Mac to finish syncing settings before changing calendars here.</p>';
  const body = data.accounts.map(a => section(a.email,
    (a.error ? `<p class="notice">${a.error==='reconnect'?'Reconnect this account in Banana on your device.':'Calendars could not be loaded. Try Refresh.'}</p>` : '') +
    a.calendars.map(c => `<div class="calendar-choice"><h3>${escape(c.title)}</h3><div class="calendar-switches"><label><input type="checkbox" data-calendar-choice="included" data-calendar-id="${escape(c.id)}" ${c.included?'checked':''} ${data.ready?'':'disabled'}> Include in Banana<span class="sr-only">: ${escape(c.title)}</span></label><label><input type="checkbox" data-calendar-choice="notifications" data-calendar-id="${escape(c.id)}" ${c.notifications?'checked':''} ${data.ready&&c.included?'':'disabled'}> Notify me<span class="sr-only">: ${escape(c.title)}</span></label></div></div>`).join('')
  )).join('');
  return warning + (body || empty('No connected calendars', 'Connect Google Calendar in Banana on your iPhone or Mac.')) + '<p class="subtle">Turn off Include in Banana to exclude events and availability. Turn off Notify me to keep events and busy time without Banana alerts. Other calendar apps manage their own notifications.</p>';
}
async function render(keepContent=false) {
  const current=generation,selected=view,pass=++renderId;
  const info=pages[view];
  $('#page-title').textContent=view==='overview'?(account.shared?`Shared by ${account.ownerName}`:`Hello${account.name?`, ${account.name.split(' ')[0]}`:''}.`):info.name;
  $('#page-kicker').textContent=info.kicker;$('#page-description').textContent=info.description;
  $('#page-date').textContent=date(Date.now(),{weekday:'short',month:'short',day:'numeric'});
  document.title=`Banana · ${info.name}`;
  $('#tools').hidden=['overview','health','calendars','sharing'].includes(view);
  $('#search').placeholder=filterScope()==='text'?`Search ${info.name.toLowerCase()}`:`Filter ${info.name.toLowerCase()} in your own words…`;
  filterControls();
  $('#navigation').innerHTML=Object.entries(pages).filter(([key])=>canView(key)).map(([key,p],i)=>`<a class="nav-link" href="#${key}" ${view===key?'aria-current="page"':''}><span class="nav-num">${String(i+1).padStart(2,'0')}</span>${p.name}</a>`).join('');
  $('#content').setAttribute('aria-busy','true');
  if(!keepContent)$('#content').innerHTML='<p class="loading" role="status">Reading your data…</p>';
  $('#content').inert=true;
  detailRecords=[];
  try {
    const html=await renders[view]();
    if(pass===renderId && current===generation && selected===view && html!==undefined){ $('#content').innerHTML=html; if(selected==='plans')applyCalendarLayout();if(selected==='sharing')sharing.mounted(); }
  }catch(e){if(pass===renderId && current===generation && selected===view && account)$('#content').innerHTML=empty('A small pause',e.message)+'<button class="button error-action" data-retry>Try again</button>';}
  finally{if(pass===renderId && current===generation && selected===view){$('#content').setAttribute('aria-busy','false');$('#content').inert=false;}}
}
function navigate() {
  if(!account)return;
  clearTimeout(searchTimer);
  if($('#search').value!==query){query=$('#search').value;liveFilter=parseFilters(query,filterScope(),filterSources);}
  const next=location.hash.slice(1).split('/')[0];rememberFilters();view=Object.hasOwn(pages,next)&&canView(next)?next:'overview';const kept=filterStates.get(view);query=kept?.query??'';liveFilter=kept?.filter??parseFilters('',filterScope(),filterSources);$('#search').value=query;
  render();
}
function showNotice(text,error=false) {$('#notice').textContent=text;$('#notice').hidden=!text;$('#notice').classList.toggle('error',error);}
function applyPreferences(next){
  next.preferences??={};
  if(!['miles','kilometers'].includes(next.preferences.distanceUnit)){
    let region='';try{region=new Intl.Locale(navigator.language).maximize().region;}catch{}
    next.preferences.distanceUnit=['US','GB','LR','MM'].includes(region)?'miles':'kilometers';
  }
  return next;
}
function updateAccount() {
  $('#account-email').textContent=account.email;
  $('#sync-time').textContent=account.lastSync?`Last device sync: ${date(account.lastSync)} ${time(account.lastSync)}`:'Waiting for a device sync';
  $('#sync-source-label').textContent=account.shared?'Shared with you':'From your devices';
  $('#share-banner').hidden=!account.shared;
  if(account.shared)$('#share-banner').innerHTML=account.preview?`<p><strong>Guest preview</strong> · What ${escape(account.audience)} will see. No invitation is sent from this preview.</p><a class="button secondary" href="${escape(account.previewBack)}">Back to invitation ↗</a>`:`<p>Shared by <strong>${escape(account.ownerName)}</strong> · Read only</p><a class="text-button" href="${appHome}">Other shared views ↗</a>`;
}
function signedOut() {
  generation++;detailGeneration++;account=null;filterSources=[];filterSourcesPromise=null;filterSourcesLoaded=false;filterStates.clear();clearTimeout(searchTimer);query='';liveFilter=parseFilters('','text');livePredicate=prepareFilters(liveFilter);cache.clear();pending.clear();healthSnapshot=null;snapshotPromise=null;detailRecords=[];agendas.clear();workoutEntries=[];currentWorkout=null;recordingWorker?.terminate();recordingWorker=null;
  $('#detail').close();$('#detail-content').replaceChildren();$('#content').replaceChildren();
  $('#workspace').hidden=true;$('#account-controls').hidden=true;$('#login').hidden=false;
  guestHomeSession=null;$('#shared-home').hidden=true;$('#share-banner').hidden=true;
  $('#google-signin').href=`/app/auth/google${sharedContext?`?share=${sharedContext.id}`:''}`;
  $('#login-hint').textContent=sharedContext?'Sign in with the Google account this invitation was sent to.':'Use a Google account connected to Banana or invited to a shared view.';
  if(sharedContext){$('#login-title').innerHTML='A shared view.<br>Just for you.';$('#login-kicker').textContent='AN INVITATION TO BANANA';$('#login-description').textContent='See the parts of Banana someone chose to share with you. Your access is read-only.';}
  $('.skip').href='#welcome';
}
function showGuestHome(session) {
  signedOut();guestHomeSession=session;$('#login').hidden=true;$('#account-controls').hidden=false;$('#shared-home').hidden=false;
  $('#shared-home').innerHTML=`<main class="shared-landing"><p class="eyebrow">SHARED WITH YOU</p><h1>A little room<br>to work together.</h1><p class="description">Signed in as ${escape(session.email)}. Choose a shared view.</p><div class="shared-views">${session.shares.length?session.shares.map(s=>`<a class="summary" href="/share/${s.id}"><span class="summary-label">${escape(s.owner)}</span><span class="summary-arrow" aria-hidden="true">↗</span><span class="summary-number">Open</span><span class="summary-foot">Read-only access</span></a>`).join(''):empty('No shared views','An invitation will appear here when someone shares with this Google account.')}</div></main>`;
  $('.skip').href='#shared-home';
}
function showAccessUnavailable() {
  signedOut();$('#login').hidden=true;$('#account-controls').hidden=false;$('#shared-home').hidden=false;
  $('#shared-home').innerHTML=`<main class="shared-landing"><p class="eyebrow">GUEST ACCESS</p><h1>This view is<br>not available.</h1><p class="description">Access may have been removed, or the invitation belongs to another Google account.</p><a class="button" href="/app/auth/google?share=${sharedContext.id}">Switch Google account ↗</a><p><a href="${appHome}">Back to Banana</a></p></main>`;
  $('.skip').href='#shared-home';
}
async function refresh({quiet=false}={}) {
  if(guestHomeSession)return boot();
  if(refreshing)return;refreshing=true;$('#refresh').disabled=true;
  try {
    const next=applyPreferences(await(await request(dataURL('account'))).json());
    if(!account)return;
    const changed=next.shareVersion!==account.shareVersion || next.calendarSettingsUpdatedAt!==account.calendarSettingsUpdatedAt || next.lastSync!==account.lastSync || JSON.stringify(next.counts)!==JSON.stringify(account.counts) || next.consents.health!==account.consents.health || next.weekStartWeekday!==account.weekStartWeekday || JSON.stringify(next.preferences)!==JSON.stringify(account.preferences);
    account=next;if(!canView(view)){view="overview";location.hash="overview";}updateAccount();
    if(!quiet || changed){generation++;detailGeneration++;$('#detail').close();$('#detail-content').replaceChildren();cache.clear();pending.clear();healthSnapshot=null;snapshotPromise=null;agendas.clear();filterSources=[];filterSourcesPromise=null;filterSourcesLoaded=false;await render();}
    if(!quiet)showNotice(account.shared?'The shared view is up to date.':'Up to date. Changes made in Banana appear here after your devices sync.');
  }catch(e){if(!quiet&&account)showNotice(e.message,true);}
  finally{refreshing=false;$('#refresh').disabled=false;}
}

async function showDetail(r) {
  if(!r)return;
  const current=++detailGeneration;const f=fields(r),dialog=$('#detail');
  currentWorkout=r.type==='workout.entry'?r:null;recordingWorker?.terminate();recordingWorker=null;dialog.classList.toggle('workout-detail',r.type==='workout.entry');
  $('#detail-kind').textContent=r.type==='workout.entry'?'WORKOUT':human(r.type.split('.').at(-1)).toUpperCase();
  const heading=(title,sub='')=>`<h2>${escape(title)}</h2>${sub?`<p class="muted">${escape(sub)}</p>`:''}`;
  let html='';
  if(r.type==='workout.entry'){
    html=workoutHTML(r,{unit:account.preferences?.distanceUnit,entries:workoutEntries});
  }else if(r.type==='calendar.event'){
    const url=String(f.url||'');const allowed=/^https:\/\/(calendar\.google\.com|www\.google\.com)\//.test(url);
    html=heading(f.title||'Event',[f.calendar,...(f.alsoOn??[]).map(c=>c.calendar)].join(' · '))+`<dl class="detail-data">${stat('When',f.start?.date?f.start.date:`${date(f.start?.dateTime)} · ${time(f.start?.dateTime)} – ${time(f.end?.dateTime)}`)}${f.location?stat('Where',f.location):''}${f.email?stat('Account',[f.email,...(f.alsoOn??[]).map(c=>c.email)].filter((v,i,a)=>a.indexOf(v)===i).join(', ')):''}${f.showsAsFree?stat('Availability','Shows as free'):''}${f.response?stat(account.shared?'Calendar account reply':'Your reply',human(f.response)):''}${f.recurring?stat('Repeats','Recurring event'):''}</dl>`+(f.description?`<p class="detail-note">${escape(f.description)}</p>`:'')+(allowed?`<a class="button" href="${escape(url)}" target="_blank" rel="noopener noreferrer">Open in Google Calendar ↗</a>`:'');
    if(f.busyOnly)html+='<p class="subtle">Only occupied time is shared. Event details and calendar accounts are private.</p>';
    const link=(url,label)=>{try{const u=new URL(url);return u.protocol==='https:'?`<a class="text-button" href="${escape(u.href)}" target="_blank" rel="noopener noreferrer">${escape(label)} ↗</a>`:'';}catch{return '';}};
    if(f.joinURL)html+=link(f.joinURL,'Join meeting');
    if(f.organizer)html+=`<p class="subtle">Organized by ${escape(f.organizer.name||f.organizer.email)}</p>`;
    if(f.attendees?.length)html+=`<h3>Guests</h3><ul class="calendar-guests">${f.attendees.map(a=>`<li><span>${escape(a.name||a.email)}${a.name&&a.email?` <small>${escape(a.email)}</small>`:''}</span><span class="muted">${escape(human(a.response))}</span></li>`).join('')}</ul>`;
    if(f.attachments?.length)html+=`<h3>Attachments</h3>${f.attachments.map(a=>link(a.url,a.title)).join(' ')}`;
  }else if(r.type==='food.meal'){
    const m=macros(f);
    html=heading(f.name||(f.items??[]).map(i=>i.name).join(', ')||'Meal',`${date(f.date,{weekday:'long',year:'numeric',month:'long',day:'numeric'})} · ${time(f.date)}`)
      +`<dl class="detail-data">${stat('Energy',`${num(m.calories)} kcal`)}${stat('Protein',`${num(m.proteinGrams,1)} g`)}${stat('Carbohydrates',`${num(m.carbohydrateGrams,1)} g`)}${stat('Fat',`${num(m.fatGrams,1)} g`)}</dl>`
      +`<table class="table"><thead><tr><th>Food</th><th>Serving</th><th>kcal</th></tr></thead><tbody>${(f.items??[]).map(i=>`<tr><td>${escape(i.name)}</td><td>${escape(i.serving|| (i.grams!=null?`${num(i.grams)} g`:''))}</td><td>${escape(num(i.macros?.calories))}</td></tr>`).join('')}</tbody></table>`
      +(f.note?`<p class="detail-note">${escape(f.note)}</p>`:'')
      +(f.photoIDs??[]).map(id=>`<img class="detail-photo" src="${escape(blobURL({type:'food.mealPhoto',id},'v'))}" alt="Photo of this meal" loading="lazy">`).join('');
  }else if(['health.workout','health.history'].includes(r.type)){
    html=heading(f.activity||'Workout',`${date(f.start,{weekday:'long',month:'long',day:'numeric',year:'numeric'})} · ${time(f.start)}`)
      +`<dl class="detail-data">${stat('Duration',duration(r.type==='health.history'?f.duration:activeDuration(f)))}${stat('Energy',metric(f.totalEnergy??f.energyKcal,'kcal'))}${stat('Distance',(f.totalDistance??f.distanceMeters)==null?'—':`${num((f.totalDistance??f.distanceMeters)/1000,2)} km`)}${stat('Average heart rate',metric(f.avgHeartRate,'bpm'))}</dl>`;
    if(f.heartRateSeries?.length)html+=`<h3>Heart rate</h3>${spark(f.heartRateSeries,'bpm')}<p class="chart-caption">Recorded heart rate during this session</p>`;
    if(f.laps?.length)html+=`<h3>Laps</h3><p class="body-copy">${num(f.laps.length)} laps${f.poolLengthMeters?` · ${num(f.poolLengthMeters)} m pool`:''}</p>`;
    if(f.distanceSplits?.length)html+=`<h3>Distance splits</h3><table class="table"><thead><tr><th>Split</th><th>Details</th></tr></thead><tbody>${f.distanceSplits.map((s,i)=>`<tr><td>${i+1}</td><td>${escape(`${num(s.distanceMeters/1000,2)} km · ${duration(s.duration)}`)}</td></tr>`).join('')}</tbody></table>`;
  }else if(r.type==='notes.voiceNote'){
    html=heading(human(f.kind)||'Voice note',`${date(f.createdAt,{month:'long',day:'numeric',year:'numeric'})} · ${time(f.createdAt)}`)
      +`<p class="detail-note">${escape(f.transcript||'No transcript yet. Transcription happens on your device.')}</p>`
      +(f.context?`<p class="body-copy">${escape([f.context.podcastTitle,f.context.episodeTitle].filter(Boolean).join(' · '))}</p>`:'')
      +(f.audio?.$blob?`<audio controls preload="none" src="${escape(blobURL(r,'audio'))}"></audio>`:'');
  }else if(r.type==='podcast.transcript'){
    html=heading('Episode transcript',human(f.source))+'<div id="transcript-body" class="body-copy"><p class="loading" role="status">Opening transcript…</p></div>';
  }else if(r.type==='podcast.listen'){
    html=heading(f.episodeTitle||'Listening session',f.podcastTitle||'')+`<dl class="detail-data">${stat('Listened',`${date(f.date)} · ${time(f.date)}`)}${stat('Duration',f.endedAt?duration((f.endedAt-f.date)/1000):'In progress')}${f.place?stat('Place',f.place):''}</dl>`;
    if(f.episodeID && (cache.get('podcast.transcript')??[]).some(t=>t.id===f.episodeID)){
      const t=cache.get('podcast.transcript').find(t=>t.id===f.episodeID);html+=`<button class="button" ${openAttr(t)}>Read transcript ↗</button>`;
    }
  }else if(r.type==='podcast.progress'){
    html=heading('Episode progress')+`<dl class="detail-data">${stat('Position',duration(f.position))}${stat('Status',f.completed?'Finished':'In progress')}${stat('Updated',date(f.updatedAt))}</dl>`;
  }else if(r.type==='podcast.show'){
    html=heading(f.title||'Podcast',f.author||'')+`<p class="body-copy">Your show is in your Banana library.</p>`;
  }else if(r.type==='plan.routine'){
    html=heading(f.name||'Routine',routineDescription(f))+`<dl class="detail-data">${stat('Time',clock(f.hour,f.minute))}${stat('Status',f.enabled===false?'Off':'On')}${stat('Duration',f.durationMinutes?`${num(f.durationMinutes)} min`:'—')}${stat('Days',days(f.weekdays))}</dl>`;
  }else if(r.type==='plan.alarm'){
    html=heading(f.label||'Alarm')+`<dl class="detail-data">${stat('Rings',`${date(f.fire)} · ${time(f.fire)}`)}</dl>`;
  }else if(r.type==='plan.extra'){
    const routine=(cache.get('plan.routine')??[]).find(r=>r.id===f.seriesID);html=heading(routine?fields(routine).name:'Added routine','Added occurrence')+`<dl class="detail-data">${stat('When',`${date(f.start)} · ${time(f.start)}`)}</dl>`;
  }else if(r.type==='food.myFood'){
    const m=f.per100g??{};
    html=heading(f.name||'Saved food',f.servingLabel||'')+`<p class="subtle">Nutrition per 100 g</p><dl class="detail-data">${stat('Energy',metric(m.calories,'kcal'))}${stat('Protein',metric(m.proteinGrams,'g'))}${stat('Carbohydrates',metric(m.carbohydrateGrams,'g'))}${stat('Fat',metric(m.fatGrams,'g'))}${stat('Serving',metric(f.servingGrams,'g'))}</dl>`;
  }else if(r.type==='health.workoutPlan'){
    html=heading(f.title||'Workout plan',`${num(f.targetMinutes)} min · ${human(f.focus)}`)+(f.rationale?`<p class="detail-note">${escape(f.rationale)}</p>`:'')+`<table class="table"><thead><tr><th>Exercise</th><th>Sets</th><th>Reps / time</th></tr></thead><tbody>${(f.exercises??[]).map(e=>`<tr><td>${escape(human(e.exerciseID))}</td><td>${escape(e.sets)}</td><td>${escape(e.reps!=null?`${e.reps} reps`:e.durationSeconds!=null?`${e.durationSeconds} sec`:'—')}</td></tr>`).join('')}</tbody></table>`;
  }else if(r.type==='food.supplement'){
    html=heading(f.name||'Supplement',human(f.kind))+`<dl class="detail-data">${stat('Dose',f.dose||'—')}${stat('Time',clock(f.hour,f.minute))}</dl>`+(f.note?`<p class="detail-note">${escape(f.note)}</p>`:'');
    const logs=(cache.get('food.dose')??[]).filter(d=>fields(d).supplementID===r.id).sort((a,b)=>String(fields(b).day).localeCompare(String(fields(a).day)));
    if(logs.length)html+=`<h3>Recent doses</h3><p class="body-copy">${logs.slice(0,30).map(d=>escape(fields(d).day)).join(' · ')}</p>`;
  }else{
    html=heading(f.name||f.title||human(r.type.split('.').at(-1)))+(f.note||f.notes?`<p class="detail-note">${escape(f.note||f.notes)}</p>`:'');
    html+=`<dl class="detail-data">${Object.entries(f).filter(([k,v])=>!['id','name','title','note','notes'].includes(k)&&v!=null&&['string','number','boolean'].includes(typeof v)).map(([k,v])=>stat(human(k),typeof v==='boolean'?(v?'Yes':'No'):v)).join('')}</dl>`;
  }
  $('#detail-content').innerHTML=html;
  if(!dialog.open)dialog.showModal();
  if(r.type==='podcast.transcript'){
    try{
      const data=await packed(r,'body');
      if(current!==detailGeneration || !account)return;
      const text=data.text || (data.segments??[]).map(s=>s.text||'').join('\n\n') || (data.words??[]).map(w=>w.text||w.word||'').join(' ');
      const body=$('#transcript-body');if(body)body.textContent=text||'The transcript has no readable text yet.';
    }catch(e){if(current===detailGeneration && $('#transcript-body'))$('#transcript-body').textContent=e.message;}
  }
}

$('#content').addEventListener('click',(e)=>{
  if(view==='sharing'){sharing.click(e.target).catch(error=>showNotice(error.message,true));return;}
  const open=e.target.closest('[data-open]');if(open){showDetail(detailRecords[Number(open.dataset.open)]);return;}
  const mode=e.target.closest('[data-plan-mode]');if(mode){saveCalendarScroll();planMode=mode.dataset.planMode;try{localStorage.setItem('banana.plan.mode',planMode);}catch{}render();return;}
  const selected=e.target.closest('[data-select-day]');if(selected){saveCalendarScroll();planDay=selected.dataset.selectDay;planMode='day';render();return;}
  const day=e.target.closest('[data-plan-day]');if(day){saveCalendarScroll();planDay=day.dataset.planDay;render();return;}
  const tab=e.target.closest('[data-podcast-tab]');if(tab){podcastTab=tab.dataset.podcastTab;render();return;}
  if(e.target.closest('[data-retry]'))render();
});
$('#content').addEventListener('change',async e => {
  const input=e.target.closest('[data-calendar-choice]');if(!input)return;
  const enabled=input.checked;
  const controls=[...$('#content').querySelectorAll('[data-calendar-choice]')];controls.forEach(c=>c.disabled=true);
  try {
    await request('/app/api/calendars',{method:'PUT',headers:{'Content-Type':'application/json'},body:JSON.stringify({calendarID:input.dataset.calendarId,preference:input.dataset.calendarChoice,enabled})});
    agendas.clear();await refresh({quiet:true});await render();showNotice('Saved across your devices.');
  } catch(error) { await render();showNotice(error.message,true); }
});
$('#content').addEventListener('change',(e)=>{if(view==='sharing'&&sharing.change(e.target))return;if(e.target.id==='plan-day'&&/^\d{4}-\d{2}-\d{2}$/.test(e.target.value)){planDay=e.target.value;render();}});
$('#content').addEventListener('input',e=>{if(view==='sharing')sharing.change(e.target);});
$('#detail-content').addEventListener('click',async(e)=>{
  const target=e.target.closest('[data-open]');if(target){showDetail(detailRecords[Number(target.dataset.open)]);return;}
  const button=e.target.closest('[data-load-recording]');if(!button||!currentWorkout?.summary)return;
  const current=detailGeneration,r=currentWorkout;button.disabled=true;button.textContent='Loading recording…';
  try{
    const buffer=await(await request(blobURL({type:'health.workout',id:r.summary.id},'samples'))).arrayBuffer();
    if(current!==detailGeneration)return;
    const data=await new Promise((resolve,reject)=>{const worker=recordingWorker=new Worker(new URL('./recording-worker.js',import.meta.url),{type:'module'});worker.onmessage=({data})=>{worker.terminate();recordingWorker=null;data.error?reject(new Error(data.error)):resolve(data.result);};worker.onerror=()=>{worker.terminate();recordingWorker=null;reject(new Error('Could not read this recording. Please try again.'));};worker.postMessage(buffer,[buffer]);});
    if(current!==detailGeneration||!$('#recording-content'))return;
    $('#recording-content').innerHTML=recordingHTML(data,account.preferences?.distanceUnit);button.remove();
  }catch(error){if(current===detailGeneration){button.disabled=false;button.textContent='Try loading again';const content=$('#recording-content');if(content)content.textContent=error.message;}}
});
$('#close-detail').addEventListener('click',()=>$('#detail').close());
$('#detail').addEventListener('close',()=>{detailGeneration++;currentWorkout=null;recordingWorker?.terminate();recordingWorker=null;$('#detail-content').replaceChildren();});
$('#detail').addEventListener('click',(e)=>{if(e.target===$('#detail')){const b=$('#detail').getBoundingClientRect();if(e.clientX<b.left||e.clientX>b.right||e.clientY<b.top||e.clientY>b.bottom)$('#detail').close();}});
$('#refresh').addEventListener('click',()=>refresh());
$('#signout').addEventListener('click',async()=>{try{await request('/app/auth/logout',{method:'POST'});signedOut();}catch(e){if(account)showNotice(e.message,true);}});
document.addEventListener('error',(e)=>{const img=e.target;if(img instanceof HTMLImageElement&&img.closest('.meal-thumbnail')){const holder=img.parentElement;holder.textContent='Photo pending';holder.classList.add('photo-pending');}},true);
let searchTimer;
$('#search').addEventListener('input',event=>{
  clearTimeout(searchTimer);if(event.isComposing)return;
  searchTimer=setTimeout(()=>{query=$('#search').value;updateFilter(parseFilters(query,filterScope(),filterSources));},200);
});
$('#search').addEventListener('compositionend',()=>{clearTimeout(searchTimer);searchTimer=setTimeout(()=>{query=$('#search').value;updateFilter(parseFilters(query,filterScope(),filterSources));},200);});
$('#live-filters').addEventListener('click',event=>{
  const remove=event.target.closest('[data-remove-filter]'),edit=event.target.closest('[data-edit-filter]');
  if(remove){liveFilter.terms.splice(Number(remove.dataset.removeFilter),1);query='';$('#search').value='';clearTimeout(searchTimer);updateFilter(liveFilter);}
  if(edit){
    const i=Number(edit.dataset.editFilter),term=liveFilter.terms[i];
    const options=term.field==='date'?Object.entries(dateLabels):term.field==='calendar'?filterSources.map(s=>[s.id,s.name]):['archived','unread','starred','allDay'].includes(term.field)?[['true','Yes'],['false','No']]:term.field==='kind'&&view==='workouts'?['strength','running','walking','cycling','swimming','yoga'].map(v=>[v,v]):null;
    const input=document.createElement(options?'select':'input');input.className='filter-inline-editor';input.setAttribute('aria-label','Edit '+filterTitle(term));if(term.field==='duration'){input.type='number';input.min='0';}
    if(options){for(const [value,label]of options){const o=document.createElement('option');o.value=value;o.textContent=label;input.append(o);}input.value=term.value;}
    else input.value=term.value;
    edit.replaceWith(input);input.focus();
    let editTimer;
    const commit=()=>{if(!input.value.trim()||!input.checkValidity()||term.value===input.value)return;term.value=input.value;delete term.label;if(term.field==='calendar')term.label=filterSources.find(s=>s.id===term.value)?.name;query='';$('#search').value='';clearTimeout(searchTimer);updateFilter(liveFilter);};
    if(options)input.addEventListener('change',()=>{commit();input.blur();filterControls();});
    else input.addEventListener('input',()=>{clearTimeout(editTimer);editTimer=setTimeout(commit,150);});
    input.addEventListener('blur',()=>{clearTimeout(editTimer);commit();filterControls();});
  }
});
window.addEventListener('hashchange',navigate);
window.addEventListener('pageshow',(e)=>{if(e.persisted)location.reload();});
document.addEventListener('visibilitychange',()=>{if(!document.hidden&&account)refresh({quiet:true});});
setInterval(()=>{if(!document.hidden&&account&&!$('#detail').open)refresh({quiet:true});},60_000);

async function boot(){
  try{
    account=applyPreferences(await(await request(dataURL('account'))).json());
    guestHomeSession=null;$('#shared-home').hidden=true;
    $('#login').hidden=true;$('#workspace').hidden=false;$('#account-controls').hidden=false;$('.skip').href='#main';
    updateAccount();navigate();
  }catch(e){
    if(e.status===403){
      if(sharedContext)return;
      try{const session=await(await request('/app/api/session')).json();if(session.kind==='guest'){showGuestHome(session);return;}}catch{/* show sign-in below */}
    }
    signedOut();
    const error=new URL(location.href).searchParams.get('error');
    const messages={expired:'That sign-in expired. Please try again.',cancelled:'Sign-in cancelled. You can try again when you’re ready.',refused:'Google could not complete that sign-in. Please try again.',unavailable:'Sign-in is temporarily unavailable. Please try again.',no_account:'Use a Google account connected to Banana or invited to a shared view.'};
    if(error || e.message!=='Sign in again to open your space.'){$('#login-error').hidden=false;$('#login-error').textContent=messages[error]||e.message;}
    if(error)history.replaceState(null,'',appHome);
  }
}
boot();
