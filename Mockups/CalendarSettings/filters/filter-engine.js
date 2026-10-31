// Review prototype only: a small deterministic vocabulary, never a production NL parser.
export const people = [{id:'alex-morgan',name:'Alex Morgan',detail:'Trainer · alex.morgan@example.com'}, {id:'alex-chen',name:'Alex Chen',detail:'Work · alex.chen@example.com'}];
export const ranges = {today:['2026-10-21','2026-10-22'],thisWeek:['2026-10-19','2026-10-26'],nextWeek:['2026-10-26','2026-11-02'],lastWeek:['2026-10-12','2026-10-19']};
export const rangeLabels = {today:'Today',thisWeek:'This week',nextWeek:'Next week',lastWeek:'Last week'};
export const records = {
 plan:[
  {id:1,title:'Product review',date:'2026-10-26',time:'10–11 AM',calendar:'work',kind:'meeting',status:'accepted',person:'alex-chen',detail:'Work · Alex Chen'},
  {id:2,title:'Team planning',date:'2026-10-27',time:'9–10 AM',calendar:'work',kind:'meeting',status:'accepted',person:'jules',detail:'Work · Jules Rivera'},
  {id:3,title:'Design check-in',date:'2026-10-28',time:'2–2:30 PM',calendar:'work',kind:'meeting',status:'declined',person:'alex-chen',detail:'Work · Declined'},
  {id:4,title:'Physical therapy',date:'2026-10-27',time:'4–5 PM',calendar:'personal',kind:'meeting',status:'accepted',person:'alex-morgan',detail:'Personal · Alex Morgan'},
  {id:5,title:'Lunch with Sam',date:'2026-10-21',time:'12–1 PM',calendar:'personal',kind:'meeting',status:'accepted',person:'sam',detail:'Personal · Sam Lee'},
  {id:6,title:'Budget review',date:'2026-10-30',time:'11–11:30 AM',calendar:'work',kind:'meeting',status:'accepted',person:'alex-chen',detail:'Work · Alex Chen'}],
 mail:[
  {id:11,title:'Your revised training plan',date:'2026-10-21',time:'8:42 AM',unread:true,person:'alex-morgan',starred:false,detail:'Alex Morgan · Updated exercises for next week'},
  {id:12,title:'Notes from our session',date:'2026-10-20',time:'Yesterday',unread:false,person:'alex-morgan',starred:true,detail:'Alex Morgan · A few things to keep in mind'},
  {id:13,title:'Review agenda',date:'2026-10-21',time:'9:15 AM',unread:true,person:'alex-chen',starred:false,detail:'Alex Chen · Three items for Monday'}],
 notes:[
  {id:21,title:'Physical therapy — shoulder mobility',date:'2026-10-21',time:'Today',archived:false,detail:'Keep the movement slow. Stop before pain.'},
  {id:22,title:'Physical therapy — first appointment',date:'2026-10-12',time:'Oct 12',archived:true,detail:'Baseline measurements and range of motion.'},
  {id:23,title:'Ideas for the next product review',date:'2026-10-20',time:'Yesterday',archived:false,detail:'Show the constraints before proposing a change.'}],
 body:[
  {id:31,title:'Upper-body strength',date:'2026-10-20',time:'45 min',kind:'strength',duration:45,detail:'6 exercises · Completed'},
  {id:32,title:'Recovery session',date:'2026-10-21',time:'20 min',kind:'strength',duration:20,detail:'3 exercises · Completed'},
  {id:33,title:'Morning run',date:'2026-10-21',time:'38 min',kind:'running',duration:38,detail:'5.2 km · Outdoor run'},
  {id:34,title:'Full-body strength',date:'2026-10-16',time:'55 min',kind:'strength',duration:55,detail:'8 exercises · Completed'}]
};
export function criterion(field,op,value){return {field,op,value};}
export function parse(text,scope){
 let rest=text.trim(), filters=[], issues=[];
 const take=(regex,fn)=>{rest=rest.replace(regex,(...args)=>{fn?.(...args);return ' ';});};
 const dateHits=[];
 for(const [value,pattern] of [['nextWeek',/\bnext week\b/ig],['thisWeek',/\bthis week\b/ig],['lastWeek',/\blast week\b/ig],['today',/\btoday\b/ig]])
  take(pattern,()=>dateHits.push(value));
 if(new Set(dateHits).size>1) issues.push({kind:'date',message:'Choose one date range: the sentence contains more than one.'});
 else if(dateHits.length) filters.push(criterion('date','in',dateHits[0]));
 if(scope==='plan'){
  take(/\b(?:(not|except|excluding)\s+)?(work|personal|family)(?:\s+calendar)?\b/ig,(_,neg,value)=>filters.push(criterion('calendar',neg?'not':'is',value.toLowerCase())));
  take(/\b(excluding|except|not|without)\s+(declined|canceled|cancelled)(?:\s+(?:events|meetings))?\b/ig,(_,neg,status)=>filters.push(criterion('status','not',status==='declined'?'declined':'canceled')));
  take(/\bmeetings?\b/ig,()=>filters.push(criterion('kind','is','meeting')));
 }
 if(scope==='mail'){
  take(/\bunread\b/ig,()=>filters.push(criterion('unread','is',true)));
  take(/\bstarred\b/ig,()=>filters.push(criterion('starred','is',true)));
 }
 if(scope==='notes'){
  take(/\b(?:unarchived|not archived|excluding archived)\b/ig,()=>filters.push(criterion('archived','is',false)));
  if(!filters.some(f=>f.field==='archived'))take(/\barchived\b/ig,()=>filters.push(criterion('archived','is',true)));
 }
 if(scope==='body'){
  take(/\b(strength|running)\b/ig,(_,kind)=>filters.push(criterion('kind','is',kind.toLowerCase())));
  take(/\b(?:longer than|over|more than)\s+(\d+)\s*(?:minutes?|mins?)\b/ig,(_,n)=>filters.push(criterion('duration','gt',Number(n))));
 }
 if(scope==='mail'||scope==='plan') take(/\b(?:with|from)\s+(alex(?:\s+(?:morgan|chen))?)\b/ig,(_,name)=>{
  const matches=people.filter(p=>p.name.toLowerCase().startsWith(name.toLowerCase()));
  if(matches.length===1)filters.push(criterion('person','is',matches[0].id));
  else issues.push({kind:'person',message:'Which Alex did you mean?',options:matches});
 });
 // Remove only grammatical scaffolding. Every remaining word is retained as literal text.
 rest=rest.replace(/\b(?:show me|show|my|emails?|notes?|workouts?|events?|about)\b/ig,' ').replace(/[,;.!?]/g,' ').replace(/\s+/g,' ').trim();
 if(rest)filters.push(criterion('text','contains',rest));
 const unique=[...new Map(filters.map(f=>[JSON.stringify(f),f])).values()];
 return {version:1,scope,match:'all',filters:unique,issues,source:text};
}
export function matches(row,filters){return filters.every(f=>{
 if(f.field==='date'){const [start,end]=ranges[f.value]||[];return row.date>=start&&row.date<end;}
 if(f.field==='text')return (row.title+' '+row.detail).toLowerCase().includes(String(f.value).toLowerCase());
 const value=row[f.field];return f.op==='not'?value!==f.value:f.op==='gt'?value>f.value:value===f.value;
});}
export function describe(f){
 const label={calendar:'Calendar',kind:'Type',status:'Status',date:'Date',person:'Person',text:'Text',duration:'Duration',unread:'Read state',archived:'Archive',starred:'Star'}[f.field];
 let value=f.field==='date'?rangeLabels[f.value]:f.field==='person'?people.find(p=>p.id===f.value)?.name:f.field==='unread'?(f.value?'Unread':'Read'):f.field==='archived'?(f.value?'Archived':'Unarchived'):f.field==='starred'?(f.value?'Starred':'Not starred'):String(f.value);
 if(f.op==='not')value='Not '+value;if(f.op==='gt')value='Over '+value+' min';
 return [label,value.charAt(0).toUpperCase()+value.slice(1)];
}
