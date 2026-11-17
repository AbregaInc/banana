import {mergeWorkouts,swiftMillis} from './workout-model.js';
import {analysisSchema} from './analysis-schema.js';
export const iso = (value, swift = false) => {
  if(value==null||!['string','number'].includes(typeof value))return null;
  const ms=swift?swiftMillis(value):value;
  const date=new Date(ms);return Number.isFinite(+date)?date.toISOString():null;
};
const n=value=>typeof value==='number'&&Number.isFinite(value)?value:null;
const macroNames={energy_kcal:'calories',protein_g:'proteinGrams',carbohydrate_g:'carbohydrateGrams',fat_g:'fatGrams'};
const macros=f=>Object.fromEntries(Object.entries(macroNames).map(([to,from])=>[to,n(f?.[from])]));
const assetKey=a=>`${a.type}:${a.id}:${a.field}`;
export function normalizeAnalysis(records,{ownBundleID=null,access=null,types=[...new Set(records.map(r=>r.type))]}={}){
  const selected=new Set(types),tables={},warnings=[];
  const group=type=>records.filter(r=>r.type===type);
  const add=(table,row)=>{const columns=analysisSchema.tables[table].columns;(tables[table]??=[]).push(Object.fromEntries(Object.entries(columns).map(([key,column])=>{
    const value=row[key]??null;
    if(value!==null&&(typeof value!==column.type||(column.type==='number'&&!Number.isFinite(value)))){
      const warning=`Invalid ${table}.${key} value was left null; the original remains in sourceRecords.`;if(!warnings.includes(warning))warnings.push(warning);return [key,null];
    }
    return [key,value];
  })));};
  const enable=(source,names)=>{if(source.some(t=>selected.has(t)))for(const name of names)tables[name]=[];};
  enable(['food.meal'],['meals','meal_items','meal_photos']);enable(['food.myFood'],['saved_foods']);
  enable(['health.workout','health.snapshot'],['workouts']);enable(['health.workoutPlan'],['workout_plans','workout_exercises']);enable(['health.workoutCompletion'],['workout_completions','completed_exercises']);
  enable(['health.snapshot'],['health_readings','sleep_nights','sleep_wakes']);enable(['plan.routine'],['routines','routine_slots','routine_keywords']);enable(['plan.alarm'],['alarms']);enable(['plan.extra'],['plan_extras']);enable(['plan.override'],['routine_overrides']);enable(['core.wakePlan'],['wake_days']);enable(['calendar'],['calendar_events']);
  tables.assets=[];
  const seenAssets=new Set();for(const r of records)for(const a of r.assets??[]){const id=assetKey(a);if(seenAssets.has(id))continue;seenAssets.add(id);add('assets',{id,record_type:a.type,record_id:a.id,field:a.field,url:a.url,expires_at:a.expiresAt});}
  for(const r of group('food.meal')){
    const f=r.data,items=f.items??[];
    const totals=Object.fromEntries(Object.keys(macroNames).map(k=>{const a=items.map(i=>macros(i.macros)[k]).filter(v=>v!=null);return [k,a.length===items.length&&a.length?a.reduce((a,b)=>a+b,0):null];}));
    add('meals',{id:r.id,date:iso(f.date),name:f.name,note:f.note,source:f.source,...totals});
    items.forEach((i,index)=>add('meal_items',{id:i.id??`${r.id}:${index}`,meal_id:r.id,position:index,name:i.name,serving:i.serving,grams:n(i.grams),confidence:n(i.confidence),reference_id:i.reference?.id,...macros(i.macros)}));
    for(const id of f.photoIDs??[])add('meal_photos',{meal_id:r.id,photo_id:id,asset_id:seenAssets.has(`food.mealPhoto:${id}:v`)?`food.mealPhoto:${id}:v`:null});
  }
  for(const r of group('food.myFood')){const f=r.data;add('saved_foods',{id:r.id,name:f.name,added_at:iso(f.addedAt),serving_label:f.servingLabel,serving_g:n(f.servingGrams),package_g:n(f.packageGrams),...macros(f.per100g)});}
  const snapshots=group('health.snapshot');
  if(snapshots.length>1)warnings.push('Multiple Health snapshots were returned; workouts use the first snapshot in feed record order, as the shared website does. All snapshots remain in sourceRecords.');
  const snapshot=snapshots[0]?.data??null;
  const invalidSummaries=group('health.workout').filter(r=>n(r.data.start)==null);
  if(invalidSummaries.length)throw new Error('A recorded workout has an invalid start time. No partial analysis export was saved.');
  if((snapshot?.workouts??[]).some(w=>n(w.start)==null||n(w.end)==null))throw new Error('A Health workout has invalid dates. No partial analysis export was saved.');
  const summaries=group('health.workout').filter(r=>n(r.data.start)!=null).map(r=>({id:r.id,fields:r.data}));
  const payload=snapshot?{...snapshot,workouts:(snapshot.workouts??[]).filter(w=>n(w.start)!=null&&n(w.end)!=null)}:null;
  for(const r of mergeWorkouts(summaries,payload,ownBundleID)){const f=r.fields;add('workouts',{id:r.id,summary_id:r.summary?.id,health_id:r.health?.id,activity:f.activity,start:iso(f.start),end:iso(f.end),duration_s:n(f.durationSeconds),distance_m:n(f.totalDistance),energy_kcal:n(f.totalEnergy),avg_hr_bpm:n(f.avgHeartRate),max_hr_bpm:n(f.maxHeartRate),source:f.source,pool_length_m:n(f.poolLengthMeters)});}
  if(snapshot){
    const id=snapshots[0].id;
    for(const [key,points] of Object.entries(snapshot.trends??{})){
      if(key==='nights')continue;
      if(!Object.hasOwn(analysisSchema.metrics,key)){warnings.push(`Unrecognized Health metric ${key} is retained in sourceRecords only.`);continue;}
      for(const p of points??[])if(n(p.date)!=null&&n(p.value)!=null)add('health_readings',{snapshot_id:id,metric:key,date:iso(p.date,true),value:p.value*(key==='bodyFatPercentage'?100:1),unit:analysisSchema.metrics[key]});
    }
    for(const night of snapshot.trends?.nights??[]){const nid=`${id}:${night.night??night.wake}`;add('sleep_nights',{snapshot_id:id,id:nid,night:iso(night.night,true),bedtime:iso(night.bedtime,true),wake:iso(night.wake,true),asleep_min:n(night.asleepMinutes)});for(const w of night.wakes??[])add('sleep_wakes',{night_id:nid,start:iso(w.start,true),end:iso(w.end,true),steps:n(w.steps),kind:w.kind,labelled:w.labelled});}
  }
  for(const r of group('health.workoutPlan')){const f=r.data;add('workout_plans',{id:r.id,title:f.title,created_at:iso(f.createdAt),focus:f.focus,target_minutes:n(f.targetMinutes),rationale:f.rationale});(f.exercises??[]).forEach((e,i)=>add('workout_exercises',{id:e.id??`${r.id}:${i}`,plan_id:r.id,position:i,exercise_id:e.exerciseID,sets:n(e.sets),reps:n(e.reps),duration_s:n(e.durationSeconds),rest_s:n(e.restSeconds)}));}
  for(const r of group('health.workoutCompletion')){const f=r.data;add('workout_completions',{id:r.id,plan_id:f.planID,start:iso(f.startedAt),end:iso(f.endedAt)});for(const id of f.completedExerciseIDs??[])add('completed_exercises',{completion_id:r.id,exercise_id:id});}
  for(const r of group('plan.routine')){const f=r.data;add('routines',{id:r.id,name:f.name,enabled:f.enabled,trigger:f.triggerKind,hour:n(f.hour),minute:n(f.minute),duration_min:n(f.durationMinutes),lead_min:n(f.leadMinutes)});for(const s of [{id:'main',hour:f.hour,minute:f.minute,weekdays:f.weekdays},...(f.extraSlots??[])])for(const day of s.weekdays?.length?s.weekdays:[null])add('routine_slots',{routine_id:r.id,slot_id:s.id,weekday:day,hour:n(s.hour),minute:n(s.minute)});for(const keyword of f.matchKeywords??[])add('routine_keywords',{routine_id:r.id,keyword});}
  for(const r of group('plan.alarm'))add('alarms',{id:r.id,label:r.data.label,fire:iso(r.data.fire)});
  for(const r of group('plan.extra'))add('plan_extras',{id:r.id,routine_id:r.data.seriesID,start:iso(r.data.start)});
  for(const r of group('plan.override')){const f=r.data,[routine,slot,day]=r.id.split('|');add('routine_overrides',{id:r.id,routine_id:routine,slot_id:slot,local_day:day,status:f.completed?'completed':f.skip?'skipped':f.reschedule?'rescheduled':'other',completed_at:iso(f.completed?.at),scheduled_start:iso(f.completed?.scheduledStart),rescheduled_to:iso(f.reschedule?._0)});}
  for(const r of group('core.wakePlan'))for(const d of r.data.plan?.days??[])add('wake_days',{plan_id:r.id,date:iso(d.date),wake:iso(d.wake)});
  for(const r of group('calendar')){const f=r.data;add('calendar_events',{id:r.id,title:f.title,start:f.start?.dateTime?iso(f.start.dateTime):null,end:f.end?.dateTime?iso(f.end.dateTime):null,start_day:f.start?.date,end_day:f.end?.date,all_day:f.allDay??Boolean(f.start?.date),calendar:f.calendar,location:f.location});}
  if(access&&!access.sections.includes('workouts')&&!selected.has('health.workout'))delete tables.workouts;
  if(access&&!access.sections.includes('health'))for(const key of ['health_readings','sleep_nights','sleep_wakes'])delete tables[key];
  return {schema:analysisSchema.schema,tables,warnings,sourceRecords:records};
}
export function tableCSV(name,rows){
  const headers=Object.keys(analysisSchema.tables[name].columns);
  const cell=v=>{let s=v==null?'':String(v);if(typeof v==='string'&&/^[\s\u0000-\u001f]*[=+@-]/.test(s))s="'"+s;return '"'+s.replaceAll('"','""')+'"';};
  return '\uFEFF'+[headers.map(cell).join(','),...rows.map(r=>headers.map(k=>cell(r[k])).join(','))].join('\r\n')+'\r\n';
}
