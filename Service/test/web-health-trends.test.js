import test from 'node:test';
import assert from 'node:assert/strict';
import {healthTrend,trendSpans,trendChartHTML} from '../public/app/assets/health-trends.js';
import {stepDay} from '../public/app/assets/plan-model.js';
const swift=key=>(+new Date(key+'T00:00:00'))/1000-978307200;
const data=(key,values)=>({trends:{[key]:values.map(([date,value])=>({date:swift(date),value}))}});
const options={through:'2026-11-02',today:'2026-11-03',days:90,group:'day'};
test('range and grouping are independent; preceding equal range excludes today across DST',()=>{
  const span=trendSpans('2026-11-03',90,'2026-11-03');
  assert.equal(span.current.endDay,'2026-11-03');assert.equal(span.current.days.length,90);
  assert.equal(span.previous.end,span.current.start);assert.equal(span.previous.days.length,90);
  const series=data('hrv',Array.from({length:180},(_,i)=>[stepDay(span.previous.startDay,i),40+i/10]));
  const day=healthTrend(series,'hrv',options),week=healthTrend(series,'hrv',{...options,group:'week'}),month=healthTrend(series,'hrv',{...options,group:'month'});
  assert.equal(day.currentBuckets.length,90);assert.equal(week.currentBuckets.length,13);assert.equal(month.currentBuckets.length,4);
  assert.deepEqual(day.windows,month.windows);assert.deepEqual(day.current,month.current);
  assert.deepEqual(day.previous,week.previous);
  assert.equal(month.currentBuckets.at(-1).endDay,'2026-11-03');
  assert.equal(month.currentBuckets[1].startDay,'2026-09-01');
});
test('native cumulative parity: daily averages count gaps after first reading, never before it',()=>{
  const t=healthTrend(data('steps',[['2026-10-29',100],['2026-11-01',300],['2026-11-03',9999]]),'steps',{...options,days:7});
  assert.equal(t.current.value,400/5);assert.equal(t.current.recorded,2);assert.equal(t.previous.value,null);
  assert.equal(t.currentBuckets[0].value,null);assert.equal(t.currentBuckets[3].value,0);
});
test('sampled metrics leave gaps unknown and comparisons handle zero/missing safely',()=>{
  const t=healthTrend(data('hrv',[['2026-10-20',0],['2026-10-30',60],['2026-11-01',40]]),'hrv',{...options,days:7});
  assert.equal(t.current.value,50);assert.equal(t.previous.value,0);assert.equal(t.change,null);
  assert.equal(t.currentBuckets[0].value,null);
  assert.equal(healthTrend({trends:{}},'hrv',options).current.value,null);
});
test('calendar-month grouping handles leap days and partial edge months',()=>{
  const o={through:'2024-03-02',today:'2024-03-03',days:30,group:'month'};
  const t=healthTrend(data('hrv',[['2024-02-03',30],['2024-02-29',50],['2024-03-01',60]]),'hrv',o);
  assert.deepEqual(t.currentBuckets.map(p=>[p.startDay,p.endDay,p.length]),[['2024-02-02','2024-03-01',28],['2024-03-01','2024-03-03',2]]);
  assert.equal(t.currentBuckets[0].value,40);assert.equal(t.currentBuckets[1].value,60);
});
test('ghost traces use a shared scale, include lone points, and escape labels',()=>{
  const t=healthTrend(data('hrv',[['2026-10-20',20],['2026-10-30',60]]),'hrv',{...options,days:7});
  const html=trendChartHTML(t,'<script>','ms');
  assert.match(html,/trend-previous/);assert.match(html,/trend-current/);assert.match(html,/<circle/);
  assert.ok(!html.includes('<script>'));assert.match(html,/&#60;script/);
  const ys=[...html.matchAll(/cy="([\d.]+)"/g)].map(m=>+m[1]);assert.ok(ys[0]>ys[1]);
});
