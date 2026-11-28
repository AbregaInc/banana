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
export function nutritionCommand(value, activeChart, today) {
  const total = value.trim().match(/^how (?:much|many) (protein|calories?|carbs|carbohydrates|fat) (?:have i|did i) (?:logged|log|recorded|record) (today|this month|last month)[?.!]*$/i);
  if (total) {
    const metric = {calorie:'calories',carbohydrates:'carbs'}[total[1].toLowerCase()] ?? total[1].toLowerCase();
    const range = total[2].toLowerCase();
    const period = range === 'today' ? null : range.replace(' ', '_');
    if (period || /^\d{4}-\d{2}-\d{2}$/.test(today ?? '')) {
      return {name:'nutrition_view',arguments:{metric,responseMode:'answer',...(period ? {period} : {start:today,end:today})}};
    }
  }
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

const eventTitle = '["“](?<title>[^"”\\n]{1,200})["”]';
const eventDay = '(?<day>today|tomorrow|[0-9]{4}-[0-9]{2}-[0-9]{2})';
const calendarClause = ' on (?:my |the )?calendar';
const review = '(?:[.!?]+\\s*| and | )(?:let me review first|leave it (?:in|for) review|show me the draft|prepare (?:it|the draft) for review)(?:[,;]\\s*(?:do not|don[’\x27]t) save(?: it)?(?: yet)?)?';
const eventStart = '(?:please )?(?:draft|prepare|create|add|schedule|put|make)(?: me)?';
const draftKind = '(?:a |an )?(?:(?:review |calendar )?draft|(?:calendar )?event)(?: for| called| titled)?';
const hourWords = ['twelve','one','two','three','four','five','six','seven','eight','nine','ten','eleven'];
const allDayForms = [
  `${eventStart} (?:a |an )?all[- ]day(?: (?:calendar )?(?:event|draft)(?: called| titled)?)? ${eventTitle} (?:event )?(?:(?:on|for) )?${eventDay}`,
  `${eventStart} ${eventTitle} (?:as )?(?:a |an )?all[- ]day (?:calendar )?(?:event|draft) (?:on |for )?${eventDay}`,
  `(?:please )?block ${eventDay} as (?:a |an )?all[- ]day (?:calendar )?event (?:called|titled) ${eventTitle}`,
].map(pattern => new RegExp(`^${pattern}(?:${review})?[.!?]*$`,'i'));
const spokenTime = `(?:noon|midnight|(?:(?:quarter|half) past )?(?:${hourWords.join('|')}|[0-9]{1,2})(?::[0-5][0-9])?(?: ?[ap]\\.?m\\.?| in the (?:morning|afternoon|evening)))`;
const clockTime = '(?:[01][0-9]|2[0-3]):[0-5][0-9]';
// An unquoted title needs an explicit new-event noun and title boundary.
const namedEvent = '(?:a |an )?(?:calendar )?(?:event|draft) (?:called|named|titled|for) (?<plainTitle>[\\p{L}\\p{N}][\\p{L}\\p{N} ’\x27&-]{0,199}?)';

const timedEvent = new RegExp(
  `^${eventStart} (?:(?:${draftKind} )?${eventTitle}|${namedEvent})(?:${calendarClause})?(?: (?:on |for )?${eventDay})? at `+
  `(?<time>${spokenTime}|${clockTime})(?:${calendarClause})?(?: for (?<minutes>[0-9]{1,4}) minutes?)?`+
  `(?: (?:in|at) (?<location>[^.?!,]+))?`+
  `(?:(?:[.!?]+\\s*add (?<note>["“][^"”\\n]+["”]) as (?:the |a )?note)|(?:, with (?<inlineNote>["“][^"”\\n]+["”]))|${review})?[.!?]*$`, 'iu'
);

function eventClock(raw) {
  const time = raw.toLowerCase().replaceAll('.', '');
  if (time === 'noon' || time === 'midnight') return time === 'noon' ? '12:00' : '00:00';
  if (/^\d\d:\d\d$/.test(time)) return time;
  const parts = time.match(/^(?:(quarter|half) past )?([a-z]+|\d\d?)(?::([0-5]\d))?\s*(am|pm|in the morning|in the afternoon|in the evening)$/);
  if (!parts || (parts[1] && parts[3])) return null;
  const hours = /^\d/.test(parts[2]) ? Number(parts[2]) : (parts[2] === 'twelve' ? 12 : hourWords.indexOf(parts[2]));
  if (hours < 1 || hours > 12) return null;
  const afternoon = parts[4] !== 'am' && parts[4] !== 'in the morning';
  const minutes = parts[1] === 'quarter' ? '15' : parts[1] === 'half' ? '30' : parts[3] ?? '00';
  return String(hours % 12 + (afternoon ? 12 : 0)).padStart(2, '0') + ':' + minutes;
}

export function explicitTimedEvent(value) {
  const raw = value.trim();
  for (const pattern of allDayForms) {
    const match = raw.match(pattern);
    if (match?.groups.title.trim()) return {title:match.groups.title.trim(),day:match.groups.day.toLowerCase(),isAllDay:true};
  }
  const match = raw.match(timedEvent);
  if (!match) return null;
  const {plainTitle, day, time:rawTime, minutes, location, note, inlineNote} = match.groups;
  if (plainTitle && /\b(?:every|each|recurr\w*|weekly|daily|monthly|invite|remind|repeat|from (?:my |the )?(?:e-?mail|thread))\b/i.test(plainTitle)) return null;
  const title = match.groups.title ?? plainTitle;
  const time = eventClock(rawTime);
  const durationMinutes = minutes ? Number(minutes) : 60;
  if (!time || !title.trim() || durationMinutes < 15 || durationMinutes > 1440 ||
      /\b(?:every|each|recurr\w*|weekly|weekdays?|weekends?|daily|monthly|until|time\s?zone|(?:[ECMP][SD]T|UTC|GMT|CET|CEST|AEST|AEDT|IST)|invite|send|email|remind|instead|move|reschedule|and|then)\b/i.test(location ?? '')) return null;
  const notes = (note ?? inlineNote)?.slice(1,-1);
  return {title:title.trim(),...(day ? {day:day.toLowerCase()} : {}),time,durationMinutes,
    ...(location ? {location:location.trim()} : {}),...(notes ? {notes} : {})};
}

export function availabilityPeriod(value) {
  const text = hideQuotedData(value).toLowerCase();
  const periods = [
    [/\bthis week\b/, 'thisWeek'],
    [/\bnext week\b/, 'nextWeek'],
    [/\bnext (?:7|seven) days\b/, 'next7days'],
  ].filter(([pattern]) => pattern.test(text));
  return periods.length === 1 ? periods[0][1] : null;
}

export function availabilityCommand(value) {
  if (hideQuotedData(value) !== value) return null;
  const date = '(today|tomorrow|tmrw|[0-9]{4}-[0-9]{2}-[0-9]{2})';
  const period = '(after lunch|in the morning|in the afternoon|morning|afternoon)';
  const question = value.trim().toLowerCase().replace(/[?.!]+$/, '').replace(/’/g,"'");
  const longest = question.match(/^(?:what(?:'s| is)) (?:the|my) longest (?:uninterrupted|free) (?:block|slot)(?: i have)? (?:on )?(sunday|monday|tuesday|wednesday|thursday|friday|saturday|today|tomorrow)$/);
  if (longest) return {date:longest[1],durationMinutes:1,limit:1,longestFirst:true};
  const weekday = question.match(/^(?:find|show me) (?:a|one) weekday with (one|two|three|four|[1-8]) (?:free|open) hours?(?: between 9 and 5)?(?: (?:this|next) week)?$/);
  if (weekday) {
    const hours = {one:1,two:2,three:3,four:4}[weekday[1]] ?? Number(weekday[1]);
    return {period:availabilityPeriod(question) ?? 'next7days',durationMinutes:hours*60,limit:1,weekdaysOnly:true};
  }
  const week = question.match(/^(?:find|show(?: me)?) (one|two|three|four|[1-8]) (\d+)[ -]minute (?:openings|slots) (?:this week|next week|(?:the )?next (?:7|seven) days)$/);
  if (week) {
    const limit = {one:1,two:2,three:3,four:4}[week[1]] ?? Number(week[1]);
    const durationMinutes = Number(week[2]);
    if (durationMinutes >= 1 && durationMinutes <= 720)
      return {period:availabilityPeriod(question),durationMinutes,limit};
  }
  const first = question.match(new RegExp(`^(?:what|when)(?:'s| is) my (first|next) (?:free|available) (hour|\\d+ minutes?)(?: ${period})? ${date}$`));
  const any = question.match(new RegExp(`^when am i (?:free|available) ${date}(?: ${period})?$`));
  if (!first && !any) return null;
  const day = first?.[4] ?? any[1];
  const part = first?.[3] ?? any?.[2] ?? '';
  const amount = first?.[2];
  const durationMinutes = amount === 'hour' ? 60 : amount ? Number.parseInt(amount, 10) : 30;
  if (durationMinutes < 1 || durationMinutes > 720) return null;
  const bounds = part === 'after lunch' ? {after:'13:00',before:'17:00'} :
    part.endsWith('morning') ? {after:'09:00',before:'12:00'} :
    part.endsWith('afternoon') ? {after:'12:00',before:'17:00'} : {};
  return {date:day === 'tmrw' ? 'tomorrow' : day,durationMinutes,...bounds,...(first ? {limit:1} : {})};
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
