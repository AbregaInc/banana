import {localDay,stepDay} from './plan-model.js';
import {swiftMillis} from './workout-model.js';

const cumulative=new Set(['steps','activeEnergyKcal','basalEnergyKcal','exerciseMinutes','flightsClimbed']);
const midnight=key=>+new Date(key+'T00:00:00');
const dayDistance=(a,b)=>(Date.parse(b+'T00:00:00Z')-Date.parse(a+'T00:00:00Z'))/86400000;
function span(start,end){
  const count=dayDistance(start,end);
  return {start:midnight(start),end:midnight(end),startDay:start,endDay:end,days:Array.from({length:count},(_,i)=>stepDay(start,i))};
}
// Native MetricTrends: equal windows of finished days; today's partial totals are separate.
export function trendSpans(through,count,today=localDay(Date.now())){
  count=[7,30,90,365].includes(Number(count))?Number(count):90;
  if(!/^\d{4}-\d{2}-\d{2}$/.test(through)||through>=today)through=stepDay(today,-1);
  const end=stepDay(through,1),start=stepDay(end,-count);
  return {current:span(start,end),previous:span(stepDay(start,-count),start)};
}
function value(key,points,window,firstDay){
  const selected=points.filter(p=>p.day>=window.startDay&&p.day<window.endDay);
  const recorded=new Set(selected.map(p=>p.day)).size;
  const sum=selected.reduce((n,p)=>n+p.value,0);
  if(cumulative.has(key)){
    const from=firstDay&&firstDay>window.startDay?firstDay:window.startDay;
    const denominator=firstDay?dayDistance(from,window.endDay):0;
    return {value:denominator>0?sum/denominator:null,recorded,denominator:Math.max(0,denominator),kind:'Daily average'};
  }
  return {value:selected.length?sum/selected.length:null,recorded,denominator:selected.length,kind:'Average'};
}
export function trendBuckets(key,points,window,group,firstDay){
  const out=[];let index=0;
  while(index<points.length&&points[index].day<window.startDay)index++;
  for(let from=window.startDay;from<window.endDay;){
    let to;
    if(group==='month'){const d=new Date(from+'T12:00:00');d.setDate(1);d.setMonth(d.getMonth()+1);to=localDay(d);}
    else to=stepDay(from,group==='week'?7:1);
    if(to>window.endDay)to=window.endDay;
    const begin=index;while(index<points.length&&points[index].day<to)index++;
    const bucket=span(from,to),result=value(key,points.slice(begin,index),bucket,firstDay);
    out.push({...result,start:bucket.start,end:bucket.end,startDay:from,endDay:to,
      offset:dayDistance(window.startDay,from),length:bucket.days.length});
    from=to;
  }
  return out;
}
export function healthTrend(data,key,{through,days=90,group='day',factor=1,today=localDay(Date.now())}){
  const points=(data?.trends?.[key]??[]).filter(p=>Number.isFinite(p.date)&&Number.isFinite(p.value))
    .map(p=>({date:swiftMillis(p.date),day:localDay(swiftMillis(p.date)),value:p.value*factor})).sort((a,b)=>a.date-b.date);
  const first=points[0]?.day,windows=trendSpans(through,days,today);
  const current=value(key,points,windows.current,first),previous=value(key,points,windows.previous,first);
  return {key,group,windows,current,previous,isCumulative:cumulative.has(key),
    change:current.value!=null&&previous.value!=null&&previous.value!==0?(current.value/previous.value-1)*100:null,
    currentBuckets:trendBuckets(key,points,windows.current,group,first),
    previousBuckets:trendBuckets(key,points,windows.previous,group,first),
    points:points.filter(p=>p.day>=windows.current.startDay&&p.day<windows.current.endDay),
    previousPoints:points.filter(p=>p.day>=windows.previous.startDay&&p.day<windows.previous.endDay)};
}
const escape=v=>String(v??'').replace(/[&<>"']/g,c=>'&#'+c.charCodeAt(0)+';');
export function trendChartHTML(trend,label,unit){
  const all=[...trend.currentBuckets,...trend.previousBuckets].filter(p=>p.value!=null);
  if(!all.length)return '<p class="subtle">No readings in either period.</p>';
  const lo=Math.min(...all.map(p=>p.value)),hi=Math.max(...all.map(p=>p.value)),padding=(hi-lo)*.12||Math.max(1,Math.abs(hi)*.05);
  const bottom=trend.isCumulative?Math.min(0,lo):lo-padding,top=hi+padding,range=top-bottom||1;
  const count=trend.windows.current.days.length;
  const x=p=>30+(p.offset+(p.length-1)/2)/Math.max(1,count-1)*550;
  const y=p=>132-(p.value-bottom)/range*110;
  const trace=(rows,ghost)=>{
    let paths=[],path=[];const dots=[];
    const finish=()=>{if(path.length){paths.push(path.join(' '));if(rows.length>31&&path.length===1){const [cx,cy]=path[0].split(',');dots.push('<circle cx="'+cx+'" cy="'+cy+'" r="2"/>');}}path=[];};
    for(const p of rows){
      if(p.value==null){finish();continue;}
      path.push(x(p).toFixed(2)+','+y(p).toFixed(2));
      if(rows.length<=31)dots.push('<circle cx="'+x(p).toFixed(2)+'" cy="'+y(p).toFixed(2)+'" r="'+(rows.length>100?1:2)+'"/>');
    }
    finish();
    return '<g class="'+(ghost?'trend-previous':'trend-current')+'">'+paths.map(p=>'<polyline points="'+p+'"/>').join('')+dots.join('')+'</g>';
  };
  const n=v=>v.toLocaleString(undefined,{maximumFractionDigits:1});
  return '<svg class="trend-chart" viewBox="0 0 600 160" role="img" aria-label="'+escape(label+' in '+unit+'. Solid: selected period; dashed: preceding equivalent period. Shared vertical scale; aligned by elapsed days.')+'">'+
    '<text x="30" y="12">'+escape(n(top))+'</text><text x="30" y="151">'+escape(n(bottom))+'</text>'+
    trace(trend.previousBuckets,true)+trace(trend.currentBuckets,false)+'</svg>';
}
