import {localDay, visibleDays, stepDay} from './plan-model.js';
import {swiftMillis} from './workout-model.js';

export const metrics = [
  ['sleepHours','Sleep duration','hours'],['restingHR','Resting heart rate','bpm'],
  ['hrv','Heart rate variability','ms'],['steps','Steps','steps'],['vo2Max','VO₂ max','mL/kg/min'],
  ['respiratory','Respiratory rate','/min'],['bodyMassKg','Body mass','kg'],['bodyFatPercentage','Body fat','%'],
  ['activeEnergyKcal','Active energy','kcal'],['exerciseMinutes','Exercise','min'],['walkingHeartRate','Walking heart rate','bpm'],
  ['basalEnergyKcal','Resting energy','kcal'],['leanBodyMassKg','Lean body mass','kg'],['bodyMassIndex','Body mass index',''],
  ['heightMeters','Height','m'],['flightsClimbed','Flights climbed','flights'],['walkingSpeedMetersPerSecond','Walking speed','m/s'],
];
const cumulative = new Set(['steps','activeEnergyKcal','basalEnergyKcal','exerciseMinutes','flightsClimbed']);
export function period(selected, mode, firstWeekday=2) {
  const days=visibleDays(selected,mode,firstWeekday);
  return {days,start:+new Date(days[0]+'T00:00:00'),end:+new Date(stepDay(days.at(-1),1)+'T00:00:00')};
}
export const inPeriod=(value,window)=>Number.isFinite(value)&&value>=window.start&&value<window.end;
export function readings(data,key,window) {
  return (data?.trends?.[key]??[]).filter(p=>Number.isFinite(p.value)&&Number.isFinite(p.date))
    .map(p=>({...p,date:swiftMillis(p.date)})).filter(p=>inPeriod(p.date,window)).sort((a,b)=>a.date-b.date);
}
export function summary(key,points) {
  if(!points.length)return null;
  const total=points.reduce((n,p)=>n+p.value,0);
  return {value:cumulative.has(key)?total:total/points.length,kind:cumulative.has(key)?'Total':'Average',days:new Set(points.map(p=>localDay(p.date))).size};
}
export function nights(data,window) {
  return (data?.trends?.nights??[]).filter(n=>Number.isFinite(n.bedtime)&&Number.isFinite(n.wake)&&Number.isFinite(n.asleepMinutes)&&n.asleepMinutes>=0)
    .map(n=>({...n,bedtime:swiftMillis(n.bedtime),wake:swiftMillis(n.wake),wakes:(n.wakes??[]).filter(w=>Number.isFinite(w.start)&&Number.isFinite(w.end)).map(w=>({...w,start:swiftMillis(w.start),end:swiftMillis(w.end)}))}))
    .filter(n=>n.wake>n.bedtime&&inPeriod(n.wake,window)).sort((a,b)=>b.wake-a.wake);
}
export const awakeMinutes=n=>Math.max(0,(n.wake-n.bedtime)/60000-n.asleepMinutes);
// Descriptive range, not a clinical score. The shortest clock arc handles midnight.
export function clockSpread(values) {
  if(values.length<2)return null;
  const minutes=values.map(v=>{const d=new Date(v);return d.getHours()*60+d.getMinutes();}).sort((a,b)=>a-b);
  let gap=minutes[0]+1440-minutes.at(-1);
  for(let i=1;i<minutes.length;i++)gap=Math.max(gap,minutes[i]-minutes[i-1]);
  return 1440-gap;
}
export function sleepVariation(rows) {
  if(rows.length<2)return null;
  const durations=rows.map(n=>n.asleepMinutes);
  return {bedtime:clockSpread(rows.map(n=>n.bedtime)),wake:clockSpread(rows.map(n=>n.wake)),duration:Math.max(...durations)-Math.min(...durations),count:rows.length};
}
export function refreshKind(previous,next) {
  if(['email','shared','shareVersion','allowedTypes','views','consents'].some(k=>JSON.stringify(previous[k])!==JSON.stringify(next[k])))return 'access';
  return ['contentVersion'].some(k=>JSON.stringify(previous[k])!==JSON.stringify(next[k]))?'data':'none';
}

export function doseInPeriod(fields,window) {
  // Match native SupplementLog.day: travel must not move a dose to another day.
  const day=typeof fields.day==='string'&&/^\d{8}$/.test(fields.day)?`${fields.day.slice(0,4)}-${fields.day.slice(4,6)}-${fields.day.slice(6,8)}`:null;
  return day?window.days.includes(day):inPeriod(fields.date,window);
}
export function displayMetric(key,unit,imperial) {
  if(imperial&&['bodyMassKg','leanBodyMassKg'].includes(key))return {unit:'lb',factor:2.2046226};
  if(key==='walkingSpeedMetersPerSecond')return {unit:imperial?'mph':'km/h',factor:imperial?2.2369363:3.6};
  if(imperial&&key==='heightMeters')return {unit:'in',factor:1/0.0254};
  return {unit,factor:1};
}

export const STATUS_INTERVAL_MS=5*60_000;
export const shouldCheckStatus=(now,last,hidden)=>!hidden&&now-last>=STATUS_INTERVAL_MS;
