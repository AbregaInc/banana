import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import rules from '../public/app/assets/live-filter-rules.js';
import {parseFilters,matchesFilters,filterInterval} from '../public/app/assets/live-filters.js';
const cases=JSON.parse(readFileSync(new URL('../../tools/live-filter-tests/fixtures.json',import.meta.url)));
test('live filters: Apple and web use the same grammar and phrase fixtures',()=>{
 assert.deepEqual(rules,JSON.parse(readFileSync(new URL('../../Shared/LiveFilterRules.json',import.meta.url))));
 for(const c of cases){const result=parseFilters(c.text,c.scope,[{id:'work-id',name:'Work'}]);if(c.terms)assert.deepEqual(result.terms.map(t=>`${t.field}:${t.op}:${t.value}`).sort(),c.terms.sort(),c.text);assert.equal(result.issues.length,c.issues??0,c.text);}
});
test('live filters: ambiguity blocks results; unknown words stay visible; bounds are exclusive',()=>{
 const q=parseFilters('Work today','plan',[{id:'a',name:'Work'},{id:'b',name:'Work'}]);assert.equal(q.issues.length,1);assert.equal(matchesFilters(q,{date:Date.now()}),false);
 const workout=parseFilters('strength workouts over 30 minutes','workouts');assert.equal(matchesFilters(workout,{kind:'Traditional Strength Training',duration:1801}),true);assert.equal(matchesFilters(workout,{kind:'strength',duration:1800}),false);
 const now=new Date(2026,2,8,12),range=filterInterval(parseFilters('today','notes'),now);assert.equal(range[0].getHours(),0);assert.equal(range[1].getDate(),9);
 const week=filterInterval(parseFilters('next week','notes'),now,2);assert.equal(week[0].getDay(),1);
 const excluded=parseFilters('not Work','plan',[{id:'w',name:'Work'}]);assert.equal(matchesFilters(excluded,{calendarIDs:['w']}),false);assert.equal(matchesFilters(excluded,{calendarIDs:['p']}),true);
});

test('live filters: today includes overnight events but excludes the next midnight',()=>{
 const q=parseFilters('today','plan'),now=new Date(2026,9,21,12),range=filterInterval(q,now);
 assert.equal(matchesFilters(q,{date:+range[0]-3600000,end:+range[0]+3600000},{now}),true);
 assert.equal(matchesFilters(q,{date:+range[1],end:+range[1]+3600000},{now}),false);
});

test('live filters: prepared predicates retain the per-row results at retained-history scale',async()=>{
 const {prepareFilters}=await import('../public/app/assets/live-filters.js');
 const {writeFileSync}=await import('node:fs');
 const q=parseFilters('strength workouts over 30 minutes this month','workouts'),now=new Date(2026,9,21,12);
 const rows=Array.from({length:10000},(_,i)=>({date:+new Date(2026,9,1+i%30,12),kind:i%2?'Running':'Traditional Strength Training',duration:i%3600}));
 const perRow=[],prepared=[];
 for(let i=0;i<7;i++){
  const counts=[];
  for(const once of i%2?[true,false]:[false,true]){
   const start=performance.now(),match=prepareFilters(q,{now});
   counts.push(rows.filter(r=>once?match(r):matchesFilters(q,r,{now})).length);
   (once?prepared:perRow).push(performance.now()-start);
  }
  assert.equal(counts[0],counts[1]);
 }
 if(process.env.LIVE_FILTER_BENCHMARK_REPORT)writeFileSync(process.env.LIVE_FILTER_BENCHMARK_REPORT,JSON.stringify({scope:'Node predicate components, not browser frame/input latency',rows:rows.length,perRowMS:perRow,oncePerQueryMS:prepared},null,2));
});
