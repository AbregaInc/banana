import {hideQuotedData} from './request-language.js';
const polite=new Set(['hi','hello','hey','please','help','with','this','quick','question','could','would','can','you','i','want','like','to','me']);
function command(value, verbs) {
  const words=value.toLowerCase().match(/[a-z]+(?:['’][a-z]+)?|\d+/g)??[];
  const at=words.findIndex(word=>verbs.includes(word));
  if(at<0 || !words.slice(0,at).every(word=>polite.has(word)))return null;
  const tail=words.slice(at+1);
  while(['thanks','thank','you','please'].includes(tail.at(-1)))tail.pop();
  return {verb:words[at],tail};
}
function literalCommand(value,verbs) {
  return hideQuotedData(value)===value ? command(value,verbs) : null;
}
export function nutritionCommand(value, activeChart) {
  // These are the native chart's finite controls. An entity or extra clause
  // prevents the shortcut, so routine schedules and energy comparisons stay queries.
  const c=literalCommand(value,['show','chart','plot','graph','only','compare','stop']);
  if(!c)return null;
  const tail=[...c.tail];
  if(c.verb==='show' || ['chart','plot','graph'].includes(c.verb)) {
    while(['me','my','the'].includes(tail[0]))tail.shift();
    const metric=tail.shift();
    if(['protein','calories','carbs','fat'].includes(metric)) {
      let period;
      const range=tail.join(' ').replace(/^(?:over|for|in) (?:the )?/,'').replace(/^the /,'');
      if(range==='this month')period='this_month';
      else if(range==='last month')period='last_month';
      else if(/^last (?:7|seven) days$/.test(range))period='last_7_days';
      else if(/^last (?:30|thirty) days$/.test(range))period='last_30_days';
      else if(range)return null;
      return {name:'nutrition_view',arguments:{metric,...(period?{period}:{})}};
    }
  }
  if(!activeChart)return null;
  const instruction=[c.verb,...c.tail].join(' ');
  let change;
  if(/^(?:only (?:show )?weekdays|show only weekdays)$/.test(instruction))change='weekdays_only';
  else if(/^show all days$/.test(instruction))change='all_days';
  else if(/^compare(?: it| this)? (?:with|to) (?:the )?previous period$/.test(instruction))change='compare_previous';
  else if(instruction==='stop comparing')change='stop_comparing';
  return change ? {name:'filter_nutrition',arguments:{changes:[change]}} : null;
}
export function requestsUnsupportedAction(value) {
  // Recognize an explicit action on stored state; never scan quoted note/search data
  // for commands. The model cannot grant a create tool authority to replace a record.
  const c=command(hideQuotedData(value),['replace','edit','update','change','move','remove','delete','cancel','reschedule','rename','rewrite','archive','invite','download','skip','seek','fast','rewind','pause','resume','start','stop']);
  if(!c)return false;
  if(c.verb==='download')return true;
  if(['skip','seek','fast','rewind','pause','resume','start','stop'].includes(c.verb))return c.tail.slice(0,c.tail.includes('about')?c.tail.indexOf('about'):undefined).some(w=>['episode','podcast','playback','seconds','minute','minutes','workout'].includes(w));
  if(c.verb==='invite')return c.tail.includes('to');
  if(['cancel','reschedule'].includes(c.verb))return true;
  if(c.tail.includes('draft'))return false;
  const content=c.tail.filter(w=>!['my','our','the','this','that','a','an','latest','last','recent','saved','existing','all','every'].includes(w));
  // Editing prose supplied in chat is not an app-record mutation.
  if(['word','phrase','sentence','paragraph','string','spelling','grammar'].includes(content[0]))return false;
  return c.tail.some(w=>['note','notes','entry','entries','event','events','appointment','appointments','calendar','routine','routines','workout','workouts','meal','meals','record','records','account','accounts','history','settings','goal','target','conversation','conversations'].includes(w));
}
