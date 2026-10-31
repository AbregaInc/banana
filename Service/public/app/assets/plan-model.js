// Day and Week are the same clock grid (PlannerTab/WeekView); week start is the synced setting.
export const localDay=(date)=>{const d=new Date(date);return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;};
export function stepDay(key,by){const d=new Date(key+'T12:00:00');d.setDate(d.getDate()+by);return localDay(d);}
export function visibleDays(selected,mode,firstWeekday=2){
  const start=mode==='week'?stepDay(selected,-((new Date(selected+'T12:00:00').getDay()-(firstWeekday-1)+7)%7)):selected;
  return Array.from({length:mode==='week'?7:1},(_,i)=>stepDay(start,i));
}
export function eventOnDay(e,key){
  if(e.start?.date)return e.start.date<=key&&(e.end?.date??stepDay(e.start.date,1))>key;
  const from=new Date(key+'T00:00:00'),to=new Date(stepDay(key,1)+'T00:00:00');
  return +new Date(e.start?.dateTime)<+to&&+new Date(e.end?.dateTime)>+from;
}
export function eventMinutes(e,key){
  const start=new Date(e.start.dateTime),end=new Date(e.end.dateTime),from=new Date(key+'T00:00:00'),to=new Date(stepDay(key,1)+'T00:00:00');
  return {start:start<from?0:start.getHours()*60+start.getMinutes(),end:end>=to?1440:end.getHours()*60+end.getMinutes()};
}
// Partition overlapping intervals, so two distinct meetings in one slot both remain readable.
export function layoutEvents(events,key){
  const ordered=events.map(event=>({event,...eventMinutes(event,key)})).sort((a,b)=>a.start-b.start||a.end-b.end||String(a.event.id).localeCompare(String(b.event.id)));
  const groups=[];let group=[],until=-1;
  for(const item of ordered){if(group.length&&until-item.start<1){groups.push(group);group=[];until=-1;}group.push(item);until=Math.max(until,item.end);}
  if(group.length)groups.push(group);
  return groups.flatMap(group=>{const lanes=[];for(const item of group){let lane=lanes.findIndex(end=>end-item.start<1);if(lane<0)lane=lanes.length;lanes[lane]=item.end;item.lane=lane;}return group.map(item=>({...item,lanes:lanes.length}));});
}
// OccurrenceProducers.authored/calendarBoundCues/oneOffAlarms and ExceptionStore's read side.
// Untimed/manual/workout-start cues remain in the routines list, never assigned a guessed time.
export function authoredEvents({routines=[],alarms=[],extras=[],overrides=[],wakePlan=null,meetings=[],days=[]}){
  const plain=r=>r.fields.v??r.fields,byID=new Map(routines.map(r=>[r.id,{...plain(r),id:r.id}])),exceptions=new Map(overrides.map(r=>[r.id,plain(r)]));
  const wakeDays=wakePlan?.plan?.days??[],out=[];
  function add(r,start,day,slot='main',label='Routine',id){
    if(!Number.isFinite(+start))return;
    const original=new Date(start),exception=exceptions.get(`${r.id}|${slot}|${day}`);
    const moved=exception?.completed?.scheduledStart?new Date(exception.completed.scheduledStart):exception?.reschedule?new Date(exception.reschedule._0):original;
    if(!Number.isFinite(+moved))return;
    out.push({id:id??`${r.id}:${slot}:${day}`,title:r.name||r.label||'Routine',start:{dateTime:moved.toISOString()},end:{dateTime:new Date(+moved+600000).toISOString()},
      calendar:label,email:'',alsoOn:[],allDay:false,cue:true,completed:Boolean(exception?.completed),completedAt:exception?.completed?.at,skipped:Boolean(exception?.skip),record:{type:label==='Alarm'?'plan.alarm':'plan.routine',id:r.id,fields:r}});
  }
  for(const day of days){
    const base=new Date(day+'T00:00:00'),weekday=base.getDay()+1,at=(h,m)=>{const t=new Date(base);t.setHours(h??0,m??0,0,0);return t;};
    const wakeDay=wakeDays.find(d=>localDay(d.date)===day),planned=wakeDay?.wake!=null?new Date(wakeDay.wake):null;
    for(const r of byID.values()){
      if(r.enabled===false)continue;
      switch(r.triggerKind){
        case 'time':
          for(const slot of [{id:'main',hour:r.hour,minute:r.minute,weekdays:r.weekdays},...(r.extraSlots??[])])if(!slot.weekdays?.length||slot.weekdays.includes(weekday))add(r,at(slot.hour,slot.minute),day,slot.id);
          break;
        case 'earliestMeeting':add(r,planned??at(r.hour,r.minute),day);break;
        case 'wakeUp':{
          if(r.weekdays?.length&&!r.weekdays.includes(weekday))break;
          const wake=[...byID.values()].find(w=>w.enabled!==false&&w.cueType==='wake'&&w.id!==r.id);
          const start=planned??(wake?at(wake.hour,wake.minute):null);
          add(r,start?new Date(+start+Math.max(0,r.leadMinutes??0)*60000):at(r.hour,r.minute),day);break;
        }
        case 'workoutStart': {
          const override=exceptions.get(`${r.id}|main|${day}`);
          const booked=override?.completed?.scheduledStart??override?.reschedule?._0;
          if(booked!=null)add(r,at(r.hour,r.minute),day);
          break;
        }
        case 'calendarMatch':
          for(const event of meetings.filter(e=>!e.allDay&&eventOnDay(e,day)))if(r.matchKeywords?.some(k=>event.title.toLowerCase().includes(k.toLowerCase())))add(r,new Date(+new Date(event.start.dateTime)-(r.leadMinutes??0)*60000),day,`cal:${event.id}`);
          break;
      }
    }
  }
  for(const r of alarms){const f=plain(r);if(f.fire!=null)add({...f,id:r.id},new Date(f.fire),localDay(f.fire),'main','Alarm');}
  for(const extra of extras){const f=plain(extra),r=byID.get(f.seriesID);if(r)add(r,new Date(f.start),localDay(f.start),`extra:${extra.id}`,'Routine',`extra:${extra.id}`);}
  return out.filter(e=>days.some(day=>eventOnDay(e,day)));
}
