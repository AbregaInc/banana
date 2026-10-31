import rules from './live-filter-rules.js';
const compiled=rules.map(r=>[r,new RegExp(r.pattern,'gi')]);
const trim=s=>s.replace(/\s+/g,' ').trim();
const escaped=s=>s.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');
export function parseFilters(sentence,scope,sources=[]){
  const result={version:1,scope,terms:[],issues:[]};
  if(sentence.length>2000){result.issues.push('Use a shorter filter sentence (up to 2,000 characters).');return result;}
  if(!['plan','mail','notes','workouts'].includes(scope)){if(sentence.trim())result.terms.push({field:'text',op:'contains',value:sentence.trim()});return result;}
  let rest=sentence;
  const take=(re,consume)=>{rest=rest.replace(re,(...m)=>{consume(m);return ' ';});};
  take(/"([^"]+)"/g,m=>result.terms.push({field:'text',op:'contains',value:m[1]}));
  if(/\b(?:or|either)\b/i.test(rest))result.issues.push('Use one set of conditions at a time; alternatives joined by ‘or’ are not supported yet.');
  if(scope==='plan'){
    const names=new Map();for(const s of sources){const key=s.name.toLowerCase();if(key)names.set(key,[...(names.get(key)??[]),s]);}
    for(const name of [...names.keys()].sort((a,b)=>b.length-a.length)){
      take(new RegExp('(?<![\\p{L}\\p{N}])(?:(not|except|excluding)\\s+)?(?:on\\s+(?:the\\s+)?)?'+escaped(name)+'(?:\\s+calendar)?(?![\\p{L}\\p{N}])','giu'),m=>{
        const choices=names.get(name);
        if(choices.length!==1){result.issues.push(`Choose a calendar: ‘${choices[0].name}’ matches more than one account. Include its account in the calendar name.`);return;}
        result.terms.push({field:'calendar',op:m[1]?'not':'is',value:choices[0].id,label:choices[0].name});
      });
    }
  }
  for(const [r,re] of compiled)if(r.scopes.includes(scope))take(re,m=>result.terms.push({field:r.field,op:r.op,value:r.value.replace('$1',typeof m[1]==='string'?m[1].toLowerCase():'').replace(/^cancelled$/,'canceled')}));
  if(['mail','plan'].includes(scope))take(/\b(?:from|with)\s+([^,;]+?)(?=\s+(?:about|excluding|except)\b|[,;]|$)/gi,m=>{
    const value=trim(m[1]);if(value)result.terms.push({field:'person',op:'contains',value,label:`Containing “${value}”`});
  });
  rest=trim(rest.replace(/\b(?:show me|show|my|all|emails?|notes?|workouts?|events?|about)\b/gi,' ').replace(/[,;]\s*/g,' '));
  if(rest)result.terms.push({field:'text',op:'contains',value:rest});
  result.terms=[...new Map(result.terms.map(t=>[t.field+':'+t.op+':'+t.value,t])).values()];
  for(const field of ['date','archived','unread','starred','kind'])if(new Set(result.terms.filter(t=>t.field===field).map(t=>t.value)).size>1)result.issues.push(`Choose one ${field} condition.`);
  if(result.terms.some(t=>t.field==='status'&&t.op==='is'&&t.value==='canceled'))result.issues.push('Canceled events are not available from calendar search. You can exclude canceled events instead.');
  return result;
}
export const dateLabels={today:'Today',yesterday:'Yesterday',tomorrow:'Tomorrow',thisWeek:'This week',nextWeek:'Next week',lastWeek:'Last week',thisMonth:'This month',lastMonth:'Last month','7days':'Last 7 days','30days':'Last 30 days'};
export function filterTitle(t){
  const names={date:'Date',calendar:'Calendar',text:'Text',person:'Person',kind:'Type',status:'Status',duration:'Minutes',archived:'Archive',unread:'Read state',starred:'Star',important:'Important',allDay:'All day'};
  const bool=t.field==='archived'?(t.value==='true'?'Archived':'Unarchived'):t.field==='unread'?(t.value==='true'?'Unread':'Read'):t.value;
  return `${names[t.field]??t.field}: ${t.op==='not'?'Not ':t.op==='gt'?'Over ':t.op==='lt'?'Under ':''}${t.label??dateLabels[t.value]??bool}`;
}
export function filterInterval(filter,now=new Date(),firstWeekday=2){
  const key=filter.terms.find(t=>t.field==='date')?.value;if(!key)return null;
  const start=new Date(now);start.setHours(0,0,0,0);let end=new Date(start);
  const add=(d,n)=>{const x=new Date(d);x.setDate(x.getDate()+n);return x;};
  if(['today','yesterday','tomorrow'].includes(key)){const offset=key==='yesterday'?-1:key==='tomorrow'?1:0;return [add(start,offset),add(start,offset+1)];}
  if(['7days','30days'].includes(key))return [add(start,key==='7days'?-6:-29),add(start,1)];
  const offset=key.startsWith('next')?1:key.startsWith('last')?-1:0;
  if(key.includes('Month')){start.setDate(1);start.setMonth(start.getMonth()+offset);end=new Date(start);end.setMonth(end.getMonth()+1);}
  else{start.setDate(start.getDate()-((start.getDay()-(firstWeekday-1)+7)%7)+offset*7);end=add(start,7);}
  return [start,end];
}
export function prepareFilters(filter,{now=new Date(),firstWeekday=2}={}){
  if(filter.version!==1||filter.issues.length)return ()=>false;
  if(!filter.terms.length)return ()=>true;
  const range=filterInterval(filter,now,firstWeekday);
  const aliases={strength:['strength','weight','resistance'],running:['running','run'],walking:['walking','walk'],cycling:['cycling','bike','biking'],swimming:['swimming','swim']};
  return row=>{
  if(range&&!(row.end!=null?row.date<+range[1]&&row.end>+range[0]:row.date>=+range[0]&&row.date<+range[1]))return false;
  return filter.terms.every(t=>{
    if(t.field==='date')return true;
    if(t.field==='text')return String(row.text??'').toLocaleLowerCase().includes(t.value.toLocaleLowerCase());
    if(t.field==='calendar'){const ids=row.calendarIDs??[];return t.op==='not'?!ids.includes(t.value):ids.includes(t.value);}
    if(t.field==='kind')return (aliases[t.value]??[t.value]).some(v=>String(row.kind??'').toLowerCase().includes(v));
    if(t.field==='person')return String(row.person??'').toLocaleLowerCase().includes(t.value.toLocaleLowerCase());
    if(t.field==='duration')return t.op==='gt'?row.duration>Number(t.value)*60:row.duration<Number(t.value)*60;
    const value=typeof row[t.field]==='boolean'?String(row[t.field]):row[t.field];
    return t.op==='not'?value!==t.value:value===t.value;
  });
  };
}
export function matchesFilters(filter,row,options){return prepareFilters(filter,options)(row);}
