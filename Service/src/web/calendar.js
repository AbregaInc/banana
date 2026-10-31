// Port of GoogleEventWindowBuilder, CalendarEventTitlePolicy and AllDayEvents.
// Keep these decisions aligned with Banana/Model; web-calendar.test.js mirrors their native cases.
import { calendarSettings } from '../calendar-preferences.js';
export { calendarSettings } from '../calendar-preferences.js';
import flightData from './flight-data.json' with { type:'json' };
const markers=new Set(['banana','banana-beta','quarters']);
const placeholders=new Set(['','busy','private','reserved','no title','(no title)']);
const trim=(v)=>String(v??'').trim();
export const normalizedTitle=(raw)=>{
  let s=trim(raw).toLowerCase(),before;
  do{before=s;s=s.replace(/^(appointment:|invitation:|invite:|canceled:|cancelled:|accepted:|declined:|tentative:|updated:|fwd:|re:)\s*/,'');}while(s!==before);
  return s.replace(/^[^\p{L}\p{N}]+/u,'').trim();
};
const folded=(s)=>s.normalize('NFD').replace(/\p{M}/gu,'').toLowerCase().replaceAll('.','');
const cities=new Map();
for(const code of Object.keys(flightData.airports).sort()){
  const a=flightData.airports[code],city=folded(a.city);
  if(a.size==='L'&&city.length>=3&&!cities.has(city))cities.set(city,code);
}
for(const [city,code]of Object.entries(flightData.mainAirport))if(flightData.airports[code])cities.set(city,code);
const airlineCodes=new Set(flightData.airlineCodes),ordinary=new Set(flightData.everydayCapitals),months=new Set(flightData.months),weekdays=new Set(flightData.weekdays);
// The native parser's confidence gate. Flights at the same times key by destination, not title.
export function flightDestination(title,location='',notes=''){
  const hay=`${title}\n${notes}\n${location}`,low=hay.toLowerCase();
  let confidence=/http:\/\/|https:\/\/|zoom\.|meet\.google|teams\.microsoft|webex/i.test(location)?-5:0;
  let destination=null,best=null;
  const numbered=[...hay.matchAll(/(?<![A-Za-z0-9])([A-Z]{2}|[A-Z][0-9]|[0-9][A-Z])\s?([0-9]{1,4})(?![A-Za-z0-9])/g)]
    .some(m=>airlineCodes.has(m[1])&&!(m[1]==='AM'&&/\d $/.test(hay.slice(0,m.index))));
  const strength=(a,b)=>[a,b].some(c=>months.has(c)||weekdays.has(c))||[a,b].every(c=>ordinary.has(c))?1:flightData.airports[a].size==='L'&&flightData.airports[b].size==='L'?3:2;
  for(const m of hay.replace(/[()]/g,' ').matchAll(/(?<![A-Za-z])([A-Z]{3})\s*(?:→|->|—|–|>|-|[Tt][Oo])\s*([A-Z]{3})(?![A-Za-z])/g)){
    if(m[1]===m[2]||!flightData.airports[m[1]]||!flightData.airports[m[2]])continue;
    const score=strength(m[1],m[2]);if(!best||score>best.score)best={destination:m[2],score};
  }
  if(!best){const codes=[...new Set([...hay.matchAll(/\(([A-Z]{3})\)/g)].map(m=>m[1]).filter(c=>flightData.airports[c]))];if(codes.length>=2)best={destination:codes[1],score:strength(codes[0],codes[1])};}
  if(best){destination=best.destination;confidence+=best.score;}
  if(!destination&&low.includes('to '))for(const line of hay.split(/\r?\n/)){
    const words=folded(line).split(/[^\p{L}'✈]+/u).filter(Boolean);
    for(let i=0;i<words.length-1;i++)if(words[i]==='to'&&(numbered||words.slice(0,i).some(w=>['flight','flights','fly','flying','✈'].includes(w)))){
      for(let n=Math.min(4,words.length-i-1);n>=1;n--){const code=cities.get(words.slice(i+1,i+1+n).join(' '));if(code){destination=code;confidence++;break;}}
      if(destination)break;
    }
    if(destination)break;
  }
  if(numbered)confidence+=2;
  if(flightData.airlineWords.some(w=>low.includes(w)))confidence++;
  if(low.includes('flight')||low.startsWith('fly ')||low.includes('\nfly ')||low.includes('flying to ')||hay.includes('✈'))confidence++;
  return confidence>=3?destination:null;
}
export function includesCalendar(cal,email,record){
  const {settings,excludedCalendars}=calendarSettings(record);
  // A write-back exclusion only stops writing; it must not hide the calendar from Plan.
  const encoded='google-calendar:'+btoa(String.fromCharCode(...new TextEncoder().encode(cal.id)));
  if((settings.excludedCalendarIDs??[]).includes(encoded))return false;
  if ((record?.v ?? record)?.calendarIDsAreGoogle === true) return true;
  const titles=[cal.summary,cal.summaryOverride].filter(Boolean).map(t=>t.toLowerCase());
  return !excludedCalendars.some(c=>titles.includes(trim(c.calendarTitle).toLowerCase())&&trim(c.sourceTitle).toLowerCase().includes(email.toLowerCase()));
}
export function isViewerOwnedCalendar(cal,email){
  if(cal.accessRole!=='owner')return false;
  const viewer=trim(email).toLowerCase();
  if(trim(cal.dataOwner))return trim(cal.dataOwner).toLowerCase()===viewer;
  if(cal.primary)return true;
  if(String(cal.id).includes('@')&&!String(cal.id).endsWith('.calendar.google.com'))return String(cal.id).toLowerCase()===viewer;
  return true;
}
// Keep the writer's exact legacy FNV fingerprint, including Foundation's reference-date bits.
export function mirrorID(title,start,end){
  const bits=value=>{const b=new ArrayBuffer(8),v=new DataView(b);v.setFloat64(0,value/1000-978307200);return v.getBigUint64(0).toString();};
  const text=[trim(title).toLowerCase(),bits(start),bits(end)].join('\u001f');
  let hash=14695981039346656037n;
  for(const byte of new TextEncoder().encode(text))hash=BigInt.asUintN(64,(hash^BigInt(byte))*1099511628211n);
  return `mirror-${hash.toString(16)}`;
}
const calendarOwner=cal=>trim(cal.dataOwner).toLowerCase()||(String(cal.id).includes('@')&&!String(cal.id).endsWith('.calendar.google.com')?String(cal.id).toLowerCase():null);
export function calendarAgenda(fetched,record,options={}){
  const {settings}=calendarSettings(record),events=[];
  for(const {event:e,calendar:cal,email} of fetched){
    if(e.status==='cancelled'||!e.id)continue;
    const allDay=Boolean(e.start?.date),start=Date.parse(e.start?.dateTime??`${e.start?.date}T00:00:00Z`),end=Date.parse(e.end?.dateTime??`${e.end?.date}T00:00:00Z`);
    if(!Number.isFinite(start)||!Number.isFinite(end)||end<=start)continue;
    const me=e.attendees?.find(a=>a.self===true);if(!options.includeDeclined&&me?.responseStatus==='declined')continue;
    const p=e.extendedProperties?.private, ownCalendar=options.ownedCalendarIDs ? options.ownedCalendarIDs.has(cal.id) : isViewerOwnedCalendar(cal,email);
    if(!options.mirrors&&ownCalendar&&markers.has(p?.bananaVariant)&&trim(p?.bananaItemID))continue;
    const title=trim(e.summary),others=(e.attendees??[]).filter(a=>!a.self&&!String(a.email??'').endsWith('resource.calendar.google.com'));
    const sharedAvailability=!ownCalendar&&placeholders.has(title.toLowerCase())&&others.length===0;
    if(allDay){
      const shows=cal.accessRole==='owner'?!(settings.allDayHiddenCalendarIDs??[]).includes(cal.id):(settings.allDayShownCalendarIDs??[]).includes(cal.id);
      if(!options.allDay&&(!shows||e.eventType==='workingLocation'||(settings.allDayHiddenTitles??[]).includes(title.toLowerCase())||(settings.showsBirthdays===false&&e.eventType==='birthday')))continue;
    }else if(!options.includeBusy&&ownCalendar&&placeholders.has(title.toLowerCase())&&others.length===0)continue;
    events.push({id:e.id,calendarID:cal.id,title:sharedAvailability?'Busy':title||(allDay?'All day':'your meeting'),start:e.start,end:e.end,
      location:sharedAvailability?'':trim(e.location),description:sharedAvailability?'':trim(e.description),url:e.htmlLink||'',joinURL:sharedAvailability?'':e.hangoutLink||e.conferenceData?.entryPoints?.find(p=>p.entryPointType==='video')?.uri||'',
      meeting:others.length>0,calendar:cal.summaryOverride||cal.summary||'Calendar',email,allDay,showsAsFree:e.transparency==='transparent',response:me?.responseStatus??null,
      recurring:Boolean(e.recurringEventId||e.recurrence?.length),othersAllDeclined:others.length>0&&others.every(a=>a.responseStatus==='declined'),
      ...(options.details?{attendees:(sharedAvailability?[]:e.attendees??[]).map(a=>({email:a.email??'',name:a.displayName??'',response:a.responseStatus??'',organizer:Boolean(a.organizer),self:Boolean(a.self)})),
        organizer:!sharedAvailability&&e.organizer?{email:e.organizer.email??'',name:e.organizer.displayName??''}:null,
        attachments:(sharedAvailability?[]:e.attachments??[]).map(a=>({title:a.title??'Attachment',url:a.fileUrl??''}))}:{}),
      alsoOn:[],_ownCalendar:ownCalendar,_uid:e.iCalUID?`uid:${e.iCalUID}\u001f${e.originalStartTime?Date.parse(e.originalStartTime.dateTime??e.originalStartTime.date):''}`:null,_owner:calendarOwner(cal),_mirror:markers.has(p?.bananaVariant)?p?.bananaItemID:null,_start:start,_end:end,_attendees:e.attendees?.length??0,_sharedAvailability:sharedAvailability,_placeholder:ownCalendar&&placeholders.has(title.toLowerCase())&&others.length===0});
  }
  events.sort((a,b)=>a._start-b._start||(a.calendarID<b.calendarID?-1:a.calendarID>b.calendarID?1:a.id<b.id?-1:a.id>b.id?1:0));
  const groups=new Map();for(const e of events){const key=`${e._start}-${e._end}-${e.allDay}`;if(!groups.has(key))groups.set(key,[]);groups.get(key).push(e);}
  const result=[];
  const richness=e=>(e.location?2:0)+(e.description?1:0)+(e._attendees>0?1:0);
  for(const group of groups.values()){
    const real=group.filter(e=>!e._placeholder),candidates=real.length?real:group,merged=new Map(),sources=new Map();
    if(candidates.length===1){result.push(candidates[0]);continue;}
    const hasMirrors=candidates.some(e=>e._sharedAvailability&&e._mirror?.startsWith('mirror-'));
    const add=(key,e)=>{
      const existing=merged.get(key);if(!existing){merged.set(key,e);return;}
      const preferNew=(existing._sharedAvailability&&!e._sharedAvailability)||(existing._sharedAvailability===e._sharedAvailability&&richness(e)>richness(existing));
      const winner=preferNew?e:existing,loser=preferNew?existing:e;
      winner.alsoOn=[...new Map([...winner.alsoOn,{calendarID:loser.calendarID,calendar:loser.calendar,email:loser.email},...loser.alsoOn].filter(c=>c.calendarID!==winner.calendarID).map(c=>[c.calendarID,c])).values()];
      merged.set(key,winner);
    };
    for(const e of candidates.filter(e=>!e._sharedAvailability)){
      const flight=flightDestination(e.title,e.location,e.description),scope=e._owner||e.calendarID;
      const key=flight?`✈${flight}`:e._uid?e._uid:`title:${e._ownCalendar?'':scope}:${normalizedTitle(e.title)}`;
      add(key,e);
      if(hasMirrors&&!e.showsAsFree&&e._owner){const source=`${e._owner}\u001f${mirrorID(e.title,e._start,e._end)}`;if(!sources.has(source))sources.set(source,new Set());sources.get(source).add(key);}
    }
    for(const e of candidates.filter(e=>e._sharedAvailability)){
      let key=`availability:${e.calendarID}:${e.id}`;
      if(e._uid&&merged.has(e._uid))key=e._uid;
      else if(e._owner&&e._mirror?.startsWith('mirror-')){
        const source=`${e._owner}\u001f${e._mirror}`,matches=sources.get(source);
        key=matches?.size===1?[...matches][0]:`mirror:${source}`;
      }
      add(key,e);
    }
    result.push(...merged.values());
  }
  return result.sort((a,b)=>a._start-b._start).map(({_start,_end,_attendees,_placeholder,_sharedAvailability,_uid,_owner,_mirror,_ownCalendar,...event})=>event);
}
