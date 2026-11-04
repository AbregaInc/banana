import test from 'node:test';
import assert from 'node:assert/strict';
import {period,inPeriod,readings,summary,nights,awakeMinutes,clockSpread,sleepVariation,refreshKind,doseInPeriod,displayMetric,latestReading,defaultHiddenMetrics,metrics,shouldCheckStatus,STATUS_INTERVAL_MS} from '../public/app/assets/health-model.js';
const swift=ms=>ms/1000-978307200;
const at=s=>+new Date(s);
test('day/week windows use calendar boundaries, including DST, and respect week start',()=>{
  const day=period('2026-11-01','day');
  assert.equal(inPeriod(day.start,day),true);assert.equal(inPeriod(day.end,day),false);
  assert.deepEqual(period('2026-11-01','week',2).days,['2026-10-26','2026-10-27','2026-10-28','2026-10-29','2026-10-30','2026-10-31','2026-11-01']);
  assert.equal(period('2026-11-01','week',1).days[0],'2026-11-01');
  if(process.env.TZ==='America/New_York')assert.equal(day.end-day.start,25*3600000);
});
test('daily snapshots decode the Swift epoch, retain zero, exclude invalid and out-of-period samples',()=>{
  const window=period('2026-11-03','week'),points=[{date:swift(window.start),value:0},{date:swift(window.start+86400000),value:100},{date:swift(window.end),value:99},{date:swift(window.start),value:null}];
  const rows=readings({trends:{steps:points}},'steps',window);
  assert.equal(rows.length,2);assert.deepEqual(summary('steps',rows),{value:100,kind:'Total',days:2});
  assert.deepEqual(summary('restingHR',rows),{value:50,kind:'Average',days:2});assert.equal(summary('steps',[]),null);
});
test('nights belong to wake day and preserve interruptions without assuming native classifications',()=>{
  const bedtime=at('2026-11-02T23:00:00'),wake=at('2026-11-03T07:00:00');
  const rows=nights({trends:{nights:[{bedtime:swift(bedtime),wake:swift(wake),asleepMinutes:450,wakes:[{start:swift(bedtime+3600000),end:swift(bedtime+4200000),steps:20}]}]}},period('2026-11-03','day'));
  assert.equal(rows.length,1);assert.equal(rows[0].bedtime,bedtime);assert.equal(awakeMinutes(rows[0]),30);assert.equal(rows[0].wakes[0].start,bedtime+3600000);
  assert.equal(sleepVariation(rows),null);
});
test('timing variation crosses midnight correctly, equal nights have zero spread, missing nights are not zero',()=>{
  assert.equal(clockSpread([at('2026-11-02T23:50:00'),at('2026-11-04T00:10:00')]),20);
  const rows=[{bedtime:at('2026-11-02T23:50:00'),wake:at('2026-11-03T07:00:00'),asleepMinutes:400},{bedtime:at('2026-11-04T00:10:00'),wake:at('2026-11-04T07:30:00'),asleepMinutes:420}];
  assert.deepEqual(sleepVariation(rows),{bedtime:20,wake:30,duration:20,count:2});
  assert.equal(clockSpread([rows[0].bedtime,rows[0].bedtime]),0);
});
test('background data changes defer redraw, while permission/consent changes require immediate invalidation',()=>{
  const a={lastSync:1,counts:{meal:1},consents:{health:true},views:['health'],allowedTypes:['health.snapshot'],shareVersion:1};
  assert.equal(refreshKind(a,{...a,now:999}), 'none');
  assert.equal(refreshKind(a,{...a,lastSync:2}), 'none');
  assert.equal(refreshKind(a,{...a,contentVersion:'changed'}),'data');
  assert.equal(refreshKind(a,{...a,counts:{meal:2}}), 'none');
  for(const change of [{consents:{health:false}},{views:[]},{allowedTypes:[]},{shareVersion:2}])assert.equal(refreshKind(a,{...a,...change}),'access');
});

test('dose day remains the authored day across time zones; old logs fall back to timestamp',()=>{
  const window=period('2026-11-03','day');
  assert.equal(doseInPeriod({day:'20261103',date:window.start-3600000},window),true);
  assert.equal(doseInPeriod({day:'20261102',date:window.start+3600000},window),false);
  assert.equal(doseInPeriod({date:window.start+3600000},window),true);
});
test('body and walking metrics honor native display units without changing recorded values',()=>{
  assert.deepEqual(displayMetric('bodyMassKg','kg',true),{unit:'lb',factor:2.2046226});
  assert.deepEqual(displayMetric('walkingSpeedMetersPerSecond','m/s',false),{unit:'km/h',factor:3.6});
  assert.deepEqual(displayMetric('hrv','ms',true),{unit:'ms',factor:1});
});

test('status checks share a five-minute budget across timer and tab-return triggers',()=>{
  assert.equal(shouldCheckStatus(100,100,false),false);
  assert.equal(shouldCheckStatus(100+STATUS_INTERVAL_MS-1,100,false),false);
  assert.equal(shouldCheckStatus(100+STATUS_INTERVAL_MS,100,false),true);
  assert.equal(shouldCheckStatus(100+STATUS_INTERVAL_MS,100,true),false);
});

test('all Health units follow the snapshot contract, with fractions converted to percentage points',()=>{
  const factors={bodyFatPercentage:[100,100],bodyMassKg:[1,2.2046226],leanBodyMassKg:[1,2.2046226],heightMeters:[100,1/0.0254],walkingSpeedMetersPerSecond:[3.6,2.2369363]};
  for(const [key,,unit]of metrics)for(const imperial of [false,true])assert.equal(displayMetric(key,unit,imperial).factor,(factors[key]??[1,1])[Number(imperial)],key);
  assert.equal(.21*displayMetric('bodyFatPercentage','%',true).factor,21);
  assert.deepEqual(displayMetric('heightMeters','m',false),{unit:'cm',factor:100});
  assert.equal(metrics.find(([key])=>key==='bodyMassKg')[1],'Weight');
  assert.ok(defaultHiddenMetrics.includes('heightMeters'));
});
test('latest daily reading includes today, ignores future/invalid points, and leaves source units unchanged',()=>{
  const today=at('2026-11-04T00:00:00'),now=at('2026-11-04T12:00:00');
  const points=[{date:swift(today),value:.21},{date:swift(today-86400000),value:.22},{date:swift(now+86400000),value:.23},{date:swift(now),value:null}];
  const data={trends:{bodyFatPercentage:points}};
  assert.deepEqual(latestReading(data,'bodyFatPercentage',100,now),{date:today,value:21});
  assert.equal(points[0].value,.21);
  assert.equal(latestReading(data,'unknown',1,now),null);
});
