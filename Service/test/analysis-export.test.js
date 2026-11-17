import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {normalizeAnalysis,tableCSV} from '../public/app/assets/analysis-model.js';
import {analysisSchema} from '../public/app/assets/analysis-schema.js';
import {collectFeed,importFeed} from '../public/app/assets/feed-import.js';
import {exportFeed} from '../public/app/assets/feed-export.js';
import {unzipSync,strFromU8} from '../public/app/assets/vendor/fflate.js';
import {mergeWorkouts} from '../public/app/assets/workout-model.js';
const start=Date.parse('2026-11-17T12:00:00Z'),swift=ms=>ms/1000-978307200;
const record=(type,id,data,assets=[])=>({type,id,data,assets});
const records=[
 record('food.meal','meal',{date:start,name:'Lunch',items:[{id:'item',name:'Rice',grams:100,macros:{calories:130,proteinGrams:3,carbohydrateGrams:28,fatGrams:1}}],photoIDs:['photo']}),
 record('food.myFood','food',{name:'Rice',addedAt:start,per100g:{calories:130},servingGrams:200}),
 record('health.workout','summary',{start,end:start+3600000,activity:'Run',totalDistance:5000,totalEnergy:350}),
 record('health.snapshot','snapshot',{workouts:[{id:'watch',start:swift(start+1000),end:swift(start+3600000),activity:'Run',duration:3500,distanceMeters:5100,energyKcal:400,source:'Apple Watch'},{id:'other',start:swift(start+2000),end:swift(start+3600000),duration:3400,source:'Whoop'}],trends:{bodyFatPercentage:[{date:swift(start),value:0.2}],bodyMassKg:[{date:swift(start),value:75}],nights:[{night:swift(start),bedtime:swift(start-36000000),wake:swift(start),asleepMinutes:400,wakes:[{start:swift(start-100000),end:swift(start),steps:12,kind:'bathroom',labelled:true}]}]}}),
 record('plan.routine','routine',{name:'Walk',enabled:true,triggerKind:'time',hour:8,minute:30,weekdays:[2,4],extraSlots:[{id:'pm',hour:17,minute:0,weekdays:[]}]}),
 record('plan.override','routine|main|2026-11-17',{completed:{at:start,scheduledStart:start-60000}}),
 record('health.workoutPlan','plan',{title:'Strength',createdAt:start,focus:'strength',exercises:[{id:'prescription',exerciseID:'squat',sets:3,reps:8,restSeconds:60}]}),
 record('health.workoutCompletion','completion',{planID:'plan',startedAt:start,endedAt:start+60000,completedExerciseIDs:['prescription']}),
 record('food.mealPhoto','photo',{v:{url:'https://feed.test/photo'}},[{type:'food.mealPhoto',id:'photo',field:'v',url:'https://feed.test/photo',expiresAt:'2026-11-17T13:00:00Z'}]),
];
const page=(rows,next=null,version='v1')=>({schema:'banana.feed.v2',contentVersion:version,analysis:{ownBundleID:null},access:{sections:['nutrition','workouts','health','personalPlan'],calendars:{busy:0,details:0}},types:[...new Set(records.map(r=>r.type))].sort(),records:rows,next});
const response=(value,status=200,headers={})=>new Response(JSON.stringify(value),{status,headers:{'Content-Type':'application/json',...headers}});
const options={paceMs:0,wait:async()=>{}};
test('analysis dates, nutrient units, relationships, no duplicate workouts and stable scalar columns',()=>{
 const result=normalizeAnalysis(records),t=result.tables;
 assert.equal(t.meals[0].date,'2026-11-17T12:00:00.000Z');assert.equal(t.meals[0].energy_kcal,130);assert.equal(t.meal_items[0].meal_id,'meal');
 assert.equal(t.saved_foods[0].energy_kcal,130);assert.equal(t.saved_foods[0].protein_g,null);
 assert.equal(t.health_readings.find(r=>r.metric==='bodyFatPercentage').value,20);assert.equal(t.health_readings.find(r=>r.metric==='bodyMassKg').unit,'kg');assert.equal(t.health_readings[0].date,t.meals[0].date);
 assert.equal(t.workouts.length,1);assert.equal(t.workouts[0].summary_id,'summary');assert.equal(t.workouts[0].health_id,'watch');assert.equal(t.workouts[0].distance_m,5100);assert.equal(t.workouts[0].duration_s,3500);
 const web=mergeWorkouts([{id:'summary',fields:records[2].data}],records[3].data);assert.equal(t.workouts[0].id,web[0].id);assert.equal(t.workouts[0].energy_kcal,web[0].fields.totalEnergy);
 assert.equal(t.routine_slots.length,3);assert.equal(t.routine_slots[2].weekday,null);assert.equal(t.routine_overrides[0].status,'completed');assert.equal(t.routine_overrides[0].local_day,'2026-11-17');
 assert.equal(t.workout_completions[0].plan_id,'plan');assert.equal(t.completed_exercises[0].exercise_id,'prescription');assert.equal(t.sleep_wakes[0].night_id,t.sleep_nights[0].id);
 assert.equal(t.meal_photos[0].asset_id,t.assets[0].id);
 for(const [name,rows]of Object.entries(t))for(const row of rows){assert.deepEqual(Object.keys(row),Object.keys(analysisSchema.tables[name].columns));assert.ok(Object.values(row).every(v=>v===null||['string','number','boolean'].includes(typeof v)),name);}
 assert.deepEqual(result.sourceRecords,records);
 const empty=normalizeAnalysis([],{types:['food.meal']});assert.deepEqual(empty.tables.meals,[]);assert.equal(empty.tables.workouts,undefined);assert.equal(tableCSV('meals',[]).split('\r\n').length,2);
 assert.ok(tableCSV('meals',[{name:'=EVIL()'}]).includes("'=EVIL()"));
});
test('analysis uses exact website source preference, not a second reconciliation policy',()=>{
 const own=normalizeAnalysis(records,{ownBundleID:'own'});const changed=structuredClone(records);changed[3].data.workouts.push({id:'own',start:swift(start),end:swift(start+10000),duration:10,sourceBundleID:'own',source:'App'});
 const actual=normalizeAnalysis(changed,{ownBundleID:'own'});assert.equal(own.tables.workouts.length,1);assert.equal(actual.tables.workouts[0].health_id,'own');
 const narrow=normalizeAnalysis([record('health.snapshot','s',{workouts:[],trends:{}})],{types:['health.snapshot']});assert.equal(narrow.tables.health_readings.length,0);assert.equal(narrow.tables.workouts.length,0);
});
test('import follows empty pages, paces, verifies consistency and preserves every record',async()=>{
 let calls=0,waits=0;const fetcher=async(url,init)=>{assert.equal(init.redirect,'error');assert.equal(init.credentials,'omit');calls++;return response(calls===1?page([], 'https://feed.test/next'):calls===2?page(records):page([],'https://feed.test/next'));};
 const result=await importFeed('https://feed.test/data?signature=EXAMPLE&types=all&format=csv',{...options,fetcher,wait:async()=>waits++});assert.equal(calls,3);assert.equal(waits,2);assert.equal(result.sourceRecords.length,records.length);assert.equal(result.collection.pages,2);
});
test('no partial export on changed access/content, forbidden URLs, duplicates, schema errors, quota exhaustion or size overflow',async()=>{
 for(const [name,fetcher,pattern,extra]of[
  ['change',(()=>{let i=0;return async()=>response(page(records,null,++i===1?'v1':'v2'));})(),/changed/],
  ['origin',async()=>response(page([], 'https://evil.test/next')),/origin/],
  ['loop',async()=>response(page([], 'https://feed.test/data?format=json')),/repeated/],
  ['duplicate',async()=>response(page([records[0],records[0]])),/repeated/],
  ['schema',async()=>response({schema:'unknown'}),/schema/],
  ['revoked',async()=>response({},404),/revoked/],
  ['size',async()=>response(page(records)),/size|limit/,{maxBytes:10}],
  ['records',async()=>response(page(records)),/record limit/,{maxRecords:1}],
 ])await assert.rejects(importFeed('https://feed.test/data',{...options,fetcher,...extra}),pattern,name);
 let calls=0;await assert.rejects(importFeed('https://feed.test/data',{...options,fetcher:async()=>{calls++;return response({},429,{'Retry-After':'1'});}}),/budget/);assert.equal(calls,4);
 const controller=new AbortController();controller.abort();await assert.rejects(importFeed('https://feed.test/data',{signal:controller.signal,...options,fetcher:async()=>response(page(records))}),/abort/i);
});
test('rate-limit recovery, bearer credentials and frozen calendar verification',async()=>{
 const seen=[],waits=[];let calls=0;
 const fetcher=async(url,init)=>{seen.push(url);assert.equal(init.headers.Authorization,'Bearer TOKEN');assert.ok(!url.includes('signature'));if(++calls===1)return response({},429,{'Retry-After':'2'});return response({...page([]),calendarWindow:{from:1,to:2}});};
 await importFeed('https://feed.test/data?signature=EXAMPLE&calendarDays=7',{...options,fetcher,token:'TOKEN',wait:async ms=>waits.push(ms)});
 assert.ok(waits.includes(2000));assert.ok(seen.at(-1).includes('from=1'));assert.ok(!seen.at(-1).includes('calendarDays'));
});
test('complete ZIP includes all pages, normalized scalar CSV, schema, raw provenance, photos and counts',async()=>{
 let calls=0;
 const fetcher=async url=>{if(url==='https://feed.test/photo')return new Response(new Uint8Array([255,216,255]),{headers:{'Content-Type':'image/jpeg'}});return response(++calls===1?page(records.slice(0,2),'https://feed.test/next'):calls===2?page(records.slice(2)):page(records.slice(0,2),'https://feed.test/next'));};
 const bytes=await exportFeed('https://feed.test/data',{...options,fetcher});const files=unzipSync(bytes);
 const result=JSON.parse(strFromU8(files['analysis.json']));assert.equal(result.sourceRecords.length,records.length);assert.equal(result.tables.assets[0].file_path,'images/photo-1.jpg');assert.equal(files['images/photo-1.jpg'].length,3);
 assert.equal(JSON.parse(strFromU8(files['manifest.json'])).rows.workouts,1);assert.equal(JSON.parse(strFromU8(files['schema.json'])).schema,'banana.analysis.v1');assert.ok(strFromU8(files['tables/health_readings.csv']).includes('20'));assert.ok(files['tables/workouts.csv']);assert.ok(files['README.txt']);
});
test('published machine schema matches executable contract',async()=>{
 assert.deepEqual(JSON.parse(await readFile(new URL('../public/app/assets/analysis-schema.json',import.meta.url),'utf8')),analysisSchema);
});

test('a copied continuation URL restarts the complete selected dataset rather than exporting a suffix',async()=>{
 const urls=[];
 const result=await importFeed('https://feed.test/data?types=food.meal&cursor=tail',{...options,fetcher:async url=>{urls.push(url);return response({...page([records[0]]),types:['food.meal']});}});
 assert.ok(urls.every(url=>!new URL(url).searchParams.has('cursor')));assert.equal(result.tables.meals.length,1);
});
test('image errors, changed data after photos and invalid workout dates cannot produce a partial ZIP',async()=>{
 let calls=0;
 await assert.rejects(exportFeed('https://feed.test/data',{...options,fetcher:async url=>url==='https://feed.test/photo'?new Response('<html>',{headers:{'Content-Type':'text/html'}}):response(page(records))}),/supported image/);
 await assert.rejects(exportFeed('https://feed.test/data',{...options,fetcher:async url=>url==='https://feed.test/photo'?new Response(new Uint8Array([1]),{headers:{'Content-Type':'image/jpeg'}}):response(page(records,null,++calls<3?'v1':'v2'))}),/changed/);
 assert.throws(()=>normalizeAnalysis([record('health.workout','bad',{start:'not a date'})]),/invalid start/);
 const narrow=normalizeAnalysis([record('health.snapshot','s',{workouts:[],trends:{}})],{types:['health.snapshot'],access:{sections:['health']}});assert.equal(narrow.tables.workouts,undefined);
});

test('streamed oversized data and cross-origin photos are rejected before creating an archive',async()=>{
 const long=new ReadableStream({start(controller){controller.enqueue(new Uint8Array(32));controller.close();}});
 await assert.rejects(importFeed('https://feed.test/data',{...options,maxBytes:10,fetcher:async()=>new Response(long)}),/size limit/);
 const foreign=structuredClone(records);foreign.at(-1).assets[0].url='https://other.test/photo';
 await assert.rejects(exportFeed('https://feed.test/data',{...options,fetcher:async()=>response(page(foreign))}),/origin/);
});

test('malformed scalar source fields never become object-valued analysis cells',()=>{
 const result=normalizeAnalysis([record('food.meal','meal',{name:{nested:'unexpected'},date:false,items:[]})]);assert.equal(result.tables.meals[0].name,null);assert.equal(result.tables.meals[0].date,null);assert.match(result.warnings.join(' '),/meals.name/);assert.deepEqual(result.sourceRecords[0].data.name,{nested:'unexpected'});
});

test('calendar errors preserve actionable structured recovery instead of suggesting blind retries',async()=>{
 await assert.rejects(importFeed('https://feed.test/data',{...options,fetcher:async()=>response({error:'calendar_unavailable',issues:[{calendar:'Shared calendar 1',reason:'unavailable'}]},503)}),error=>error.status===503&&error.issues.length===1&&/restore access or remove/.test(error.message));
});
