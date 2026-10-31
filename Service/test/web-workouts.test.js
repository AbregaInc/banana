import test from 'node:test';
import assert from 'node:assert/strict';
import {mergeWorkouts,activeSeconds,lapRows,distanceSplits,decodeRecording,swiftMillis} from '../public/app/assets/workout-model.js';
import {workoutHTML,recordingHTML} from '../public/app/assets/workout-view.js';
const start=Date.UTC(2026,9,20,8),swift=ms=>ms/1000-978307200;
const summary=(id='s',extra={})=>({id,type:'health.workout',fields:{activity:'Outdoor run',start,end:start+3600000,totalDistance:8000,...extra}});
const health=(id='h',extra={})=>({id,activity:'Outdoor run',start:swift(start+30000),end:swift(start+3600000),duration:3500,distanceMeters:8100,source:'Apple Watch',...extra});

test('native WorkoutEntry parity: summaries pair with Health within 90 seconds; Health-only history appears and copies collapse',()=>{
  const payload={workouts:[health(),health('whoop',{source:'WHOOP',distanceMeters:null}),health('old',{start:swift(start-86400000),end:swift(start-82800000)})]};
  const entries=mergeWorkouts([summary()],payload);
  assert.equal(entries.length,2);assert.equal(entries[0].summary.id,'s');assert.equal(entries[0].health.id,'h');
  assert.equal(entries[0].fields.totalDistance,8100);assert.equal(entries[0].fields.durationSeconds,3500);assert.equal(entries[1].summary,null);
});
test('native WorkoutEntry parity: hidden Health records are removed before pairing and 90 seconds is a strict boundary',()=>{
  const entries=mergeWorkouts([summary()],{hiddenWorkoutIDs:['hidden'],workouts:[health('hidden'),health('boundary',{start:swift(start+90000)})]});
  assert.equal(entries.length,2);assert.equal(entries.find(e=>e.summary)?.health,null);
  assert.equal(swiftMillis(swift(start)),start);
});
test('native WorkoutSourcePreference parity: recorder beats WHOOP/Strava, completeness breaks ties, id breaks final ties',()=>{
  const rows=mergeWorkouts([],{workouts:[health('z',{source:'WHOOP'}),health('x',{source:'Strava'}),health('b',{source:'Apple Watch',avgHeartRate:130}),health('a',{source:'Apple Watch',avgHeartRate:130})]});
  assert.equal(rows.length,1);assert.equal(rows[0].health.id,'a');
});
test('native WorkoutPauses parity: saved pause offsets are seconds, not dates or milliseconds',()=>{
  assert.equal(activeSeconds({start,end:start+3600000,pauses:[{start:100,end:160},{start:500,end:620}]}),3420);
});
test('native WorkoutSplits parity: lap strokes are deltas of cumulative counts and missing/reset counters stay unknown',()=>{
  const laps=[{number:1,duration:30},{number:2,duration:32}];
  assert.deepEqual(lapRows(laps,[{t:30,value:20},{t:62,value:41}]).map(l=>[l.strokes,l.swolf]),[[20,50],[21,53]]);
  assert.deepEqual(lapRows(laps,[]).map(l=>l.strokes),[null,null]);
  assert.deepEqual(lapRows(laps,[{t:30,value:20},{t:62,value:4}]).map(l=>l.strokes),[20,null]);
});
test('distance splits interpolate measurement times and include a final partial in the selected unit',()=>{
  const a=distanceSplits([{t:0,meters:0},{t:100,meters:1000},{t:250,meters:2500}],1000);
  assert.deepEqual(a.map(s=>[s.distanceMeters,s.duration]),[[1000,100],[1000,100],[500,50]]);assert.equal(a[2].partial,true);
  const mile=distanceSplits([{t:0,meters:0},{t:100,meters:2000}],1609.344);assert.equal(mile[0].distanceMeters,1609.344);
});
test('recording decoder reads the native 33-byte binary contract, ignores future kinds and keeps charts bounded',()=>{
  const buffer=new ArrayBuffer(33*2000),v=new DataView(buffer);
  for(let i=0;i<2000;i++){const p=i*33;v.setUint8(p,i===0?250:0);v.setFloat64(p+1,i,true);v.setFloat64(p+9,120+i%20,true);v.setFloat64(p+17,NaN,true);v.setFloat64(p+25,NaN,true);}
  const data=decodeRecording(buffer);assert.equal(data.counts.heartRate,1999);assert.ok(data.series.heartRate.length<=601);assert.equal(data.series.heartRate.at(-1).t,1999);
  assert.throws(()=>decodeRecording(new ArrayBuffer(7)),/incomplete/);
});
test('workout detail exposes all recorded metrics, route, pool laps, SWOLF, weather and raw recording access, with escaped content',()=>{
  const entries=mergeWorkouts([summary('s',{activity:'Pool swim',avgHeartRate:130,route:[{lat:40,lon:-74},{lat:40.1,lon:-74.1}],heartRateSeries:[{t:0,bpm:100},{t:60,bpm:130}],powerSeries:[{t:0,value:100},{t:60,value:120}],laps:[{number:1,duration:30},{number:2,duration:32}],strokeSeries:[{t:30,value:20},{t:62,value:41}],poolLengthMeters:25,insights:{averagePower:110},outdoorConditions:{temperatureF:70,humidity:.4,condition:'<script>alert(1)</script>'},samples:{$blob:'a'.repeat(64),size:2000},sampleCount:60})],null);
  const html=workoutHTML(entries[0]);
  for(const text of ['Active time','Average heart rate','Recorded route','Heart rate','Power','Pool laps','SWOLF','Weather','Humidity','Load full recording'])assert.ok(html.includes(text),text);
  assert.ok(html.includes('&lt;script&gt;'));assert.ok(!html.includes('<script>'));
  assert.match(recordingHTML({counts:{accel:2},route:[],series:{accel:[{t:0,value:1},{t:1,value:2}]}},'miles'),/Acceleration magnitude/);
});

test('native split parity: stored distances are cumulative kilometres, never relabelled as miles',()=>{
  const entry=mergeWorkouts([summary('s',{distanceSplits:[{number:1,distanceMeters:1000,duration:400},{number:2,distanceMeters:2000,duration:410}]})],null)[0];
  const km=workoutHTML(entry,{unit:'kilometers'}),miles=workoutHTML(entry,{unit:'miles'});
  assert.ok(km.includes('Distance splits'));assert.equal((km.match(/<td>1 km<\/td>/g)??[]).length,2);
  assert.ok(!miles.includes('Distance splits'));
});
test('a shared workout cannot carry markup into the dialog: every split value is escaped',()=>{
  const entry=mergeWorkouts([summary('x',{totalDistance:1000,distanceSplits:[{number:'<b data-x>INJECT</b>',distanceMeters:1000,duration:300}]})],null)[0];
  const html=workoutHTML(entry,{unit:'kilometers'});
  assert.ok(!html.includes('<b data-x>INJECT</b>'));
  assert.ok(html.includes('&lt;b data-x&gt;INJECT&lt;/b&gt;'));
});
