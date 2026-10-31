// Read-side ports of WorkoutEntry.merge, WorkoutSourcePreference, WorkoutPauses and WorkoutSplits.
export const swiftMillis=v=>typeof v==='number'?(v+978307200)*1000:v;
export const pausedSeconds=f=>(f.pauses??[]).reduce((n,p)=>n+Math.max(0,p.end-p.start),0);
export const activeSeconds=f=>Math.max(0,((f.end??f.start)-f.start)/1000-pausedSeconds(f));
export function sourceRank(w,ownBundleID){
  if(ownBundleID&&w.sourceBundleID===ownBundleID)return 100;
  const s=String(w.source??'').toLowerCase();
  if(s==='banana')return 95;if(s.includes('apple watch')||s.includes('apple\u00a0watch'))return 90;
  if(s.includes('workoutdoors'))return 80;if(['nike','slopes','daypart'].some(x=>s.includes(x)))return 70;
  if(s.includes('strava'))return 40;if(s.includes('whoop'))return 20;return 50;
}
const completeness=w=>((w.distanceMeters??0)>0?4:0)+(w.avgHeartRate!=null?2:0)+((w.energyKcal??0)>0?1:0);
function prefers(a,b,own){const ar=sourceRank(a,own),br=sourceRank(b,own);if(ar!==br)return ar>br;const ac=completeness(a),bc=completeness(b);return ac!==bc?ac>bc:String(a.id)<String(b.id);}
export function mergeWorkouts(records,payload,ownBundleID){
  const summaries=records.map(r=>({...r.fields,id:r.id})),hidden=new Set(payload?.hiddenWorkoutIDs??[]);
  const health=(payload?.workouts??[]).filter(w=>!hidden.has(w.id)).map(w=>({...w,start:swiftMillis(w.start),end:swiftMillis(w.end)}));
  const buckets=[];
  const start=e=>e.health?.start??e.summary?.start;
  const near=t=>buckets.map((e,i)=>({i,d:Math.abs(start(e)-t)})).filter(e=>e.d<90_000).sort((a,b)=>a.d-b.d)[0]?.i;
  for(const s of summaries)if(near(s.start)==null)buckets.push({summary:s,health:null});
  for(const w of health){const i=near(w.start);if(i==null)buckets.push({health:w,summary:null});else if(!buckets[i].health||prefers(w,buckets[i].health,ownBundleID))buckets[i].health=w;}
  return buckets.map(({health:h,summary:s})=>({id:s?.id??h.id,type:'workout.entry',summary:s,health:h,fields:{...s,
    activity:h?.activity??s?.activity??'Workout',start:h?.start??s?.start,end:h?.end??s?.end,
    durationSeconds:h?.duration??activeSeconds(s),totalDistance:h?.distanceMeters??s?.totalDistance,
    totalEnergy:h?.energyKcal??s?.totalEnergy,avgHeartRate:h?.avgHeartRate??s?.avgHeartRate,maxHeartRate:h?.maxHeartRate,
    source:h?.source??'Banana',poolLengthMeters:s?.poolLengthMeters??h?.lapLengthMeters}})).sort((a,b)=>b.fields.start-a.fields.start);
}
export function lapRows(laps=[],strokeSeries=[]){
  const sorted=[...strokeSeries].sort((a,b)=>a.t-b.t);let previous=0,boundary=0,index=0;
  return laps.map((lap,i)=>{
    let mark;
    if(sorted.length===laps.length)mark=sorted[i].value;
    else{boundary+=lap.duration;while(index<sorted.length&&sorted[index].t<=boundary+2)mark=sorted[index++].value;}
    const strokes=mark!=null&&previous!=null&&mark>=previous?Math.round(mark-previous):null;previous=mark;
    return {...lap,strokes,swolf:strokes==null?null:strokes+Math.round(lap.duration)};
  });
}
export function distanceSplits(series=[],interval=1000){
  const a=[...series].filter(p=>Number.isFinite(p.t)&&Number.isFinite(p.meters)).sort((a,b)=>a.t-b.t),rows=[];
  if(a.length<2)return rows;let target=interval,lastTime=0;
  for(let i=1;i<a.length;i++){
    const p=a[i-1],q=a[i];if(q.meters<=p.meters||q.t<p.t)continue;
    while(target<=q.meters){if(target>=p.meters){const at=p.t+(q.t-p.t)*(target-p.meters)/(q.meters-p.meters);rows.push({number:rows.length+1,distanceMeters:interval,duration:at-lastTime});lastTime=at;}target+=interval;}
  }
  const last=a.at(-1),remainder=last.meters-(target-interval);
  if(remainder>=50&&last.t>lastTime)rows.push({number:rows.length+1,distanceMeters:remainder,duration:last.t-lastTime,partial:true});
  return rows;
}
const KINDS=['heartRate','energy','distance','accel','gyro','location','altitude','cadence','power','strideLength','verticalOscillation','groundContactTime','strokeCount','speed','orientation','stepCount','physicalEffort','effortScore','perfusionIndex','underwaterDepth','waterTemperature','barometricAltitude','strokeStyle'];
// The exact 33-byte little-endian wire format in Shared/FitnessModels.swift. Keep bounded chart
// samples per signal; an hour's 100 Hz motion stream must not create a million DOM points.
export function decodeRecording(buffer){
  if(buffer.byteLength%33!==0)throw new Error('This recording is incomplete. Try syncing it again from Banana.');
  const data=new DataView(buffer),counts={},series={},route=[];
  for(let i=0;i<data.byteLength;i+=33){const kind=KINDS[data.getUint8(i)];if(!kind)continue;counts[kind]=(counts[kind]??0)+1;}
  const seen={},stride=Object.fromEntries(Object.entries(counts).map(([k,n])=>[k,Math.max(1,Math.ceil(n/600))]));
  for(let i=0;i<data.byteLength;i+=33){
    const kind=KINDS[data.getUint8(i)];if(!kind)continue;const n=seen[kind]=(seen[kind]??0)+1;
    if((n-1)%stride[kind]!==0&&n!==counts[kind])continue;
    const t=data.getFloat64(i+1,true),v1=data.getFloat64(i+9,true),v2=data.getFloat64(i+17,true),v3=data.getFloat64(i+25,true);
    if(!Number.isFinite(t)||!Number.isFinite(v1))continue;
    if(kind==='location'){if(Number.isFinite(v2)&&Math.abs(v1)<=90&&Math.abs(v2)<=180)route.push({lat:v1,lon:v2});continue;}
    const value=['accel','gyro','orientation'].includes(kind)&&Number.isFinite(v2)&&Number.isFinite(v3)?Math.hypot(v1,v2,v3):v1;
    (series[kind]??=[]).push({t,value});
  }
  return {counts,series,route};
}
