// Pure component comparison against a retained pre-optimization module.
import {readFileSync} from 'node:fs';
import {performance} from 'node:perf_hooks';
import assert from 'node:assert/strict';
import * as candidate from '../public/app/assets/health-trends.js';
import {metrics} from '../public/app/assets/health-model.js';
import {stepDay} from '../public/app/assets/plan-model.js';
const base=new URL('../public/app/assets/health-trends.js',import.meta.url);
const source=readFileSync(process.env.TREND_REFERENCE,'utf8').replaceAll("'./plan-model.js'",JSON.stringify(new URL('./plan-model.js',base).href)).replaceAll("'./workout-model.js'",JSON.stringify(new URL('./workout-model.js',base).href));
const reference=await import('data:text/javascript;base64,'+Buffer.from(source).toString('base64'));
const today='2026-11-03',start=stepDay(today,-730);
const data={trends:Object.fromEntries(metrics.map(([key],m)=>[key,Array.from({length:730},(_,i)=>({date:(+new Date(stepDay(start,i)+'T00:00:00'))/1000-978307200,value:50+m+Math.sin(i/5)*10})).filter((_,i)=>i%13!==0)]))};
const reports=[];
for(const days of [7,30,90,365])for(const group of ['day','week','month']){
  const options={through:'2026-11-02',today,days,group},expected=metrics.map(([key])=>reference.healthTrend(data,key,options));
  assert.deepEqual(metrics.map(([key])=>candidate.healthTrend(data,key,options)),expected);
  const results={reference:[],candidate:[]};
  for(let run=0;run<7;run++)for(const name of run%2?['candidate','reference']:['reference','candidate']){
    const implementation=name==='reference'?reference:candidate,start=performance.now();
    for(const [key]of metrics)implementation.healthTrend(data,key,options);
    results[name].push(performance.now()-start);
  }
  const chartCounts=Object.fromEntries([['reference',reference],['candidate',candidate]].map(([name,implementation])=>[name,metrics.reduce((n,[key])=>n+(implementation.trendChartHTML(implementation.healthTrend(data,key,options),key,'unit').match(/<circle/g)??[]).length,0)]));
  reports.push({days,group,chartCircles:chartCounts,samplesMS:results,maximumMS:Object.fromEntries(Object.entries(results).map(([k,v])=>[k,Math.max(...v)]))});
}
console.log(JSON.stringify({parity:true,metrics:17,retainedDays:730,reports,note:'Component model timings only; no new cache or eviction behavior. Physical frame/input latency and isolated memory cost are unmeasured.'},null,2));
