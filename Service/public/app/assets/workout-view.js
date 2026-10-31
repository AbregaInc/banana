import { activeSeconds, pausedSeconds, lapRows, distanceSplits } from './workout-model.js';
const e=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const n=(v,d=0)=>Number(v).toLocaleString(undefined,{maximumFractionDigits:d});
export const exactDuration=s=>{const t=Math.max(0,Math.floor(s)),h=Math.floor(t/3600),m=Math.floor(t%3600/60),sec=String(t%60).padStart(2,'0');return h?`${h}:${String(m).padStart(2,'0')}:${sec}`:`${m}:${sec}`;};
export function distanceText(m,unit='kilometers'){if(m==null)return '—';if(unit==='miles')return m/1609.344>=.1?`${n(m/1609.344,2)} mi`:`${n(m*3.28084)} ft`;return m>=1000?`${n(m/1000,2)} km`:`${n(m)} m`;}
const speed=(v,unit)=>`${n(v*(unit==='miles'?2.236936:3.6),1)} ${unit==='miles'?'mph':'km/h'}`;
const pace=(meters,seconds,unit)=>meters>0?`${exactDuration(seconds/meters*(unit==='miles'?1609.344:1000))} /${unit==='miles'?'mi':'km'}`:'—';
const stat=(label,value)=>`<div><dt>${e(label)}</dt><dd>${e(value)}</dd></div>`;
const section=(title,body)=>`<section class="workout-section"><h3>${e(title)}</h3>${body}</section>`;
export function workoutChart(title,points,key='value',unit='',factor=1){
  const all=points.map((p,i)=>({x:Number(p.t??i),y:Number(p[key])*factor})).filter(p=>Number.isFinite(p.x)&&Number.isFinite(p.y));
  if(all.length<2)return '';
  let lo=Infinity,hi=-Infinity;for(const p of all){lo=Math.min(lo,p.y);hi=Math.max(hi,p.y);}const first=all[0].x,last=all.at(-1).x;
  const stride=Math.max(1,Math.ceil(all.length/500)),a=all.filter((_,i)=>i%stride===0||i===all.length-1);
  const path=a.map(p=>`${(12+(p.x-first)/(last-first||1)*576).toFixed(2)},${(116-(p.y-lo)/(hi-lo||1)*98).toFixed(2)}`).join(' ');
  return `<article class="workout-chart"><div class="chart-heading"><h4>${e(title)}</h4><span>${e(n(lo,1))}–${e(n(hi,1))} ${e(unit)}</span></div><svg viewBox="0 0 600 136" role="img" aria-label="${e(`${title}, ${n(lo,1)} to ${n(hi,1)} ${unit}`)}"><line x1="12" y1="116" x2="588" y2="116"/><polyline points="${path}"/></svg><div class="chart-axis"><span>${e(exactDuration(first))}</span><span>Time into workout</span><span>${e(exactDuration(last))}</span></div></article>`;
}
function onePlace(route){
  if(route.length<2)return false;const lat=route.reduce((n,p)=>n+p.lat,0)/route.length,lon=route.reduce((n,p)=>n+p.lon,0)/route.length,scale=Math.cos(lat*Math.PI/180);
  return route.every(p=>Math.hypot((p.lat-lat)*111320,(p.lon-lon)*scale*111320)<=100);
}
export function routeHTML(raw){
  const a=raw.filter(p=>Number.isFinite(p.lat)&&Number.isFinite(p.lon));if(!a.length)return '';
  const center=a.reduce((c,p)=>({lat:c.lat+p.lat/a.length,lon:c.lon+p.lon/a.length}),{lat:0,lon:0}),scale=Math.cos(center.lat*Math.PI/180),place=onePlace(a);
  let xmin=Infinity,xmax=-Infinity,ymin=Infinity,ymax=-Infinity;for(const p of a){const x=p.lon*scale,y=-p.lat;xmin=Math.min(xmin,x);xmax=Math.max(xmax,x);ymin=Math.min(ymin,y);ymax=Math.max(ymax,y);}
  const span=Math.max(xmax-xmin,(ymax-ymin)*2,0.0001);
  const coords=a.map(p=>({x:300+(p.lon*scale-(xmin+xmax)/2)/span*540,y:150+(-p.lat-(ymin+ymax)/2)/span*540}));
  const path=coords.map(p=>`${p.x.toFixed(2)},${p.y.toFixed(2)}`).join(' '),start=coords[0],end=coords.at(-1);
  return section(place?'Recorded location':'Recorded route',`<div class="route-plot"><svg viewBox="0 0 600 300" role="img" aria-label="${place?'Workout location':'Recorded GPS route, with start and finish'}"><defs><pattern id="route-grid" width="30" height="30" patternUnits="userSpaceOnUse"><path d="M 30 0 L 0 0 0 30"/></pattern></defs><rect width="600" height="300" fill="url(#route-grid)"/>${place?`<circle cx="300" cy="150" r="8" class="route-start"/>`:`<polyline points="${path}" class="route-path"/><circle cx="${start.x}" cy="${start.y}" r="6" class="route-start"/><circle cx="${end.x}" cy="${end.y}" r="6" class="route-end"/>`}</svg><p class="chart-caption">${place?'GPS stayed in one place.':`Start ● · Finish ○ · ${n(a.length)} recorded locations.`} ${e(center.lat.toFixed(4))}, ${e(center.lon.toFixed(4))}</p></div>`);
}
function summaryCharts(f,unit){
  const specs=[['Heart rate','heartRateSeries','bpm','bpm',1],['Speed','speedSeries','metersPerSecond',unit==='miles'?'mph':'km/h',unit==='miles'?2.236936:3.6],['Elevation','elevationSeries','value',unit==='miles'?'ft':'m',unit==='miles'?3.28084:1],['Cadence','cadenceSeries','value','rpm',1],['Power','powerSeries','value','W',1],['Stride length','strideLengthSeries','value','m',1],['Vertical oscillation','verticalOscillationSeries','value','cm',100],['Ground contact','groundContactSeries','value','ms',1000],['Calculated running cadence','derivedCadenceSeries','value','steps/min',1],['Distance','distanceSeries','meters',unit==='miles'?'mi':'km',unit==='miles'?1/1609.344:1/1000]];
  const stationary=onePlace(f.route??[]);
  return specs.filter(([,field])=>(field!=='cadenceSeries'||/cycl|bik/i.test(f.activity))&&(!stationary||!['speedSeries','elevationSeries','distanceSeries'].includes(field))).map(([title,field,key,suffix,factor])=>workoutChart(title,f[field]??[],key,suffix,factor)).join('');
}
function comparison(entry,entries,unit){
  const f=entry.fields,peers=entries.filter(r=>r.fields.activity.toLowerCase()===f.activity.toLowerCase()&&r.fields.start<f.start-90_000&&r.fields.start>=f.start-90*86400000).map(r=>r.fields);
  if(!peers.length)return '';
  const rows=[],add=(label,current,values,format)=>{if(current==null||!values.length)return;const base=values.reduce((n,v)=>n+v,0)/values.length;rows.push([label,format(current),format(base),base?Math.round((current-base)/base*100):0]);};
  add('Time',f.durationSeconds,peers.map(p=>p.durationSeconds).filter(v=>v>0),exactDuration);
  add('Distance',f.totalDistance,peers.map(p=>p.totalDistance).filter(v=>v!=null),v=>distanceText(v,unit));
  const paced=peers.filter(p=>p.totalDistance>0&&p.durationSeconds>0);
  if(f.totalDistance>0&&f.durationSeconds>0&&paced.length){const total=paced.reduce((n,p)=>n+p.totalDistance,0),seconds=paced.reduce((n,p)=>n+p.durationSeconds,0);const usesPace=!/swim|cycl|bik/i.test(f.activity),delta=Math.round((f.durationSeconds/f.totalDistance/(seconds/total)-1)*100);rows.push([usesPace?'Pace':'Speed',usesPace?pace(f.totalDistance,f.durationSeconds,unit):speed(f.totalDistance/f.durationSeconds,unit),usesPace?pace(total,seconds,unit):speed(total/seconds,unit),usesPace?delta:-delta]);}
  add('Average heart rate',f.avgHeartRate,peers.map(p=>p.avgHeartRate).filter(v=>v!=null),v=>`${n(v)} bpm`);
  return section('Compared with your last 90 days',`<p class="muted">${n(peers.length)} earlier ${e(f.activity.toLowerCase())} workouts</p><table class="table"><thead><tr><th>Metric</th><th>This workout</th><th>Usual</th><th>Change</th></tr></thead><tbody>${rows.map(([label,now,usual,delta])=>`<tr><td>${e(label)}</td><td>${e(now)}</td><td>${e(usual)}</td><td>${delta>0?'+':''}${delta}%</td></tr>`).join('')}</tbody></table>`);
}
export function workoutHTML(entry,{unit='kilometers',entries=[]}={}){
  const f=entry.fields,s=entry.summary,h=entry.health,ins=f.insights??{},pool=/pool|swimming/i.test(f.activity),stationary=onePlace(f.route??[]),stats=[];
  stats.push(stat('Active time',exactDuration(f.durationSeconds)));
  if(f.totalDistance!=null)stats.push(stat('Distance',distanceText(f.totalDistance,unit)));
  if(f.laps?.length){stats.push(stat('Laps',n(f.laps.length)),stat('Average lap',exactDuration(f.laps.reduce((n,l)=>n+l.duration,0)/f.laps.length)));}
  else if(f.totalDistance>0&&f.durationSeconds>0)stats.push(stat(!/swim|cycl|bik/i.test(f.activity)?'Pace':'Average speed',!/swim|cycl|bik/i.test(f.activity)?pace(f.totalDistance,f.durationSeconds,unit):speed(f.totalDistance/f.durationSeconds,unit)));
  if(f.avgHeartRate!=null)stats.push(stat('Average heart rate',`${n(f.avgHeartRate)} bpm`));
  if(f.maxHeartRate!=null)stats.push(stat('Max heart rate',`${n(f.maxHeartRate)} bpm`));
  if(f.totalEnergy!=null)stats.push(stat('Active energy',`${n(f.totalEnergy)} kcal`));
  if(s&&pausedSeconds(s)>0)stats.push(stat('Paused time',exactDuration(pausedSeconds(s))),stat('Elapsed time',exactDuration((s.end-s.start)/1000)));
  if(ins.movingDuration!=null&&!stationary)stats.push(stat('Moving time',exactDuration(ins.movingDuration)));
  if(ins.averagePower!=null)stats.push(stat('Average power',`${n(ins.averagePower)} W`));
  if(ins.averageCadence!=null&&/cycl|bik/i.test(f.activity))stats.push(stat('Average cadence',`${n(ins.averageCadence)} rpm`));
  for(const [key,label]of [['elevationGain','Elevation gain'],['elevationLoss','Elevation loss']])if(ins[key]!=null&&!stationary)stats.push(stat(label,`${n(ins[key]*(unit==='miles'?3.28084:1))} ${unit==='miles'?'ft':'m'}`));
  if(ins.maxSpeed!=null&&!stationary)stats.push(stat('Max speed',speed(ins.maxSpeed,unit)));
  if(f.poolLengthMeters!=null)stats.push(stat('Pool length',unit==='miles'?`${n(f.poolLengthMeters/0.9144,1)} yd`:`${n(f.poolLengthMeters,1)} m`));
  if(f.outdoorConditions){const w=f.outdoorConditions;stats.push(stat('Weather',`${n(unit==='miles'?w.temperatureF:(w.temperatureF-32)*5/9)}°${unit==='miles'?'F':'C'} · ${w.condition}`),stat('Humidity',`${n(w.humidity*100)}%`));}
  const when=new Date(f.start).toLocaleString(undefined,{weekday:'long',month:'long',day:'numeric',year:'numeric',hour:'numeric',minute:'2-digit'});
  let html=`<h2>${e(f.activity)}</h2><p class="muted">${e(when)} · ${e(f.source||'Banana')}${s?' · Recording available':' · Apple Health'}</p><dl class="detail-data workout-stats">${stats.join('')}</dl>`;
  html+=routeHTML(f.route??[]);
  const charts=summaryCharts(f,unit);if(charts)html+=section('Recorded metrics',`<div class="workout-charts">${charts}</div>`);
  if(f.laps?.length){const laps=lapRows(f.laps,f.strokeSeries??[]),fastest=Math.min(...laps.map(l=>l.duration));html+=section('Pool laps',`<table class="table"><thead><tr><th>Lap</th><th>Time</th><th>Strokes</th><th>SWOLF</th></tr></thead><tbody>${laps.map(l=>`<tr ${l.duration===fastest?'class="fastest-lap"':''}><td>${n(l.number)}</td><td>${exactDuration(l.duration)}</td><td>${l.strokes??'—'}</td><td>${l.swolf??'—'}</td></tr>`).join('')}</tbody></table>`);}
  // The native summary’s distanceMeters is cumulative at each boundary. A mile reader
  // needs the actual distance track; relabeling stored kilometre splits would change their meaning.
  const splits=f.distanceSeries?.length>1?distanceSplits(f.distanceSeries,unit==='miles'?1609.344:1000):unit==='kilometers'?(f.distanceSplits??[]).map((x,i,a)=>({...x,distanceMeters:x.distanceMeters-(i?a[i-1].distanceMeters:0)})):[];
  if(splits.length&&!pool)html+=section('Distance splits',`<table class="table"><thead><tr><th>Split</th><th>Distance</th><th>Time</th><th>Pace</th></tr></thead><tbody>${splits.map(x=>`<tr><td>${e(String(x.number??''))}${x.partial?' · partial':''}</td><td>${e(distanceText(x.distanceMeters,unit))}</td><td>${exactDuration(x.duration)}</td><td>${e(pace(x.distanceMeters,x.duration,unit))}</td></tr>`).join('')}</tbody></table>`);
  html+=comparison(entry,entries,unit);
  if(s?.samples?.$blob)html+=section('Full recording',`<p class="muted">${n(s.sampleCount??0)} recorded samples · ${n(s.samples.size/1024/1024,1)} MB</p><button class="button recording-button" data-load-recording>Load full recording</button><div id="recording-content"></div>`);
  if(s?.edit)html+=`<p class="subtle">Edited on ${e(new Date(s.edit.editedAt).toLocaleDateString())}. This view reflects the saved recording.</p>`;
  return html;
}
export function recordingHTML(data,unit){
  const specs={heartRate:['Heart rate','bpm',1],energy:['Cumulative energy','kcal',1],distance:['Cumulative distance',unit==='miles'?'mi':'km',unit==='miles'?1/1609.344:1/1000],accel:['Acceleration magnitude','g',1],gyro:['Angular velocity magnitude','rad/s',1],orientation:['Orientation magnitude','radians',1],altitude:['GPS altitude','m',1],barometricAltitude:['Barometric altitude','m',1],cadence:['Cycling cadence','rpm',1],power:['Power','W',1],strideLength:['Stride length','m',1],verticalOscillation:['Vertical oscillation','cm',100],groundContactTime:['Ground contact time','ms',1000],strokeCount:['Cumulative strokes','strokes',1],speed:['Speed',unit==='miles'?'mph':'km/h',unit==='miles'?2.236936:3.6],stepCount:['Cumulative steps','steps',1],physicalEffort:['Physical effort','kcal/(kg·hr)',1],effortScore:['Apple estimated effort','',1],perfusionIndex:['Perfusion index','%',1],underwaterDepth:['Underwater depth','m',1],waterTemperature:['Water temperature','°C',1]};
  return `<p class="subtle">${n(Object.values(data.counts).reduce((a,b)=>a+b,0))} samples across ${Object.keys(data.counts).length} signals. Charts use the recorded timestamps.</p>`+routeHTML(data.route)+`<div class="workout-charts">${Object.entries(data.series).map(([key,values])=>{const [name,suffix,factor]=specs[key]??[key,'',1];return workoutChart(name,values,'value',suffix,factor);}).join('')}</div>`;
}
