import test from 'node:test';
import assert from 'node:assert/strict';
import {calendarAgenda,calendarSettings,includesCalendar,normalizedTitle,flightDestination,mirrorID} from '../src/web/calendar.js';
import {visibleDays,eventOnDay,layoutEvents} from '../public/app/assets/plan-model.js';
const cal=(id='personal',overrides={})=>({id,summary:id,accessRole:'owner',...overrides});
const event=(id='one',overrides={})=>({id,summary:'Design review',start:{dateTime:'2026-10-05T15:00:00Z'},end:{dateTime:'2026-10-05T16:00:00Z'},...overrides});
const fetched=(e,calendar=cal())=>({event:e,calendar,email:'me@example.com'});
const build=(events,settings)=>calendarAgenda(events,settings);

test('native agenda parity: every Banana variant’s titled block and foreign bare Busy are excluded',()=>{
  const a=['banana','banana-beta','quarters'].map(v=>fetched(event(v,{summary:'Travel home',extendedProperties:{private:{bananaVariant:v,bananaItemID:'travel-42'}}})));
  a.push(fetched(event('busy',{summary:'Busy'})));
  assert.deepEqual(build(a),[]);
  assert.equal(build([fetched(event('other',{extendedProperties:{private:{bananaVariant:'another-app',bananaItemID:'x'}}}))]).length,1);
  assert.equal(build([fetched(event('incomplete',{extendedProperties:{private:{bananaVariant:'banana'}}}))]).length,1);
});
test('native agenda parity: privacy placeholders are coverage, but a Busy invitation with human guests shows',()=>{
  for(const summary of ['', 'Busy','Private','Reserved','No title','(no title)'])assert.equal(build([fetched(event('p',{summary}))]).length,0,summary);
  assert.equal(build([fetched(event('invite',{summary:'Busy',attendees:[{self:true,responseStatus:'accepted'},{email:'friend@example.com'}]}))]).length,1);
  assert.equal(build([fetched(event('room',{summary:'Busy',attendees:[{email:'room@resource.calendar.google.com'}]}))]).length,0);
});
test('native agenda parity: declined, cancelled and invalid times are hidden; free events still show',()=>{
  const declined=event('declined',{attendees:[{self:true,responseStatus:'declined'}]});
  assert.equal(build([fetched(declined),fetched(event('cancelled',{status:'cancelled'})),fetched(event('broken',{end:{dateTime:'2026-10-05T14:00:00Z'}}))]).length,0);
  const free=build([fetched(event('dinner',{transparency:'transparent'}))]);assert.equal(free.length,1);assert.equal(free[0].showsAsFree,true);
});
test('native agenda parity: one invitation across accounts keeps the richer copy and remembers every calendar',()=>{
  const rows=build([fetched(event('bare'),cal('a')),fetched(event('rich',{location:'HQ 4th floor',attendees:[{email:'friend@example.com'}]}),cal('b'))]);
  assert.equal(rows.length,1);assert.equal(rows[0].id,'rich');assert.equal(rows[0].location,'HQ 4th floor');assert.deepEqual(rows[0].alsoOn.map(c=>c.calendarID),['a']);
});
test('native agenda parity: scheduling prefixes and leading symbols collapse, but different meetings at the same time stay',()=>{
  assert.equal(normalizedTitle(' 📅 Re: nope'),'re: nope'); // symbols are stripped after prefixes, as in Swift
  assert.equal(normalizedTitle('Re: Fwd: Accepted: 🗓 Design review'),'design review');
  const a=build([fetched(event('bare'),cal('a')),fetched(event('prefixed',{summary:'Accepted: Design review'}),cal('b')),fetched(event('dentist',{summary:'Dentist'}),cal('c'))]);
  assert.equal(a.length,2);assert.deepEqual(a.map(e=>e.title),['Design review','Dentist']);
});
test('native agenda parity: flight copies key by destination with the native confidence gate',()=>{
  assert.equal(flightDestination('EWR → MIA'),'MIA');assert.equal(flightDestination('United flight to Miami'),'MIA');
  assert.equal(flightDestination('Flight to Miami'),null);assert.equal(flightDestination('MIA sync','https://zoom.us/x'),null);
  assert.equal(flightDestination('JAN-MAR'),null);assert.equal(flightDestination('Talk to Jackson about the Delta flight'),null);
  const a=build([fetched(event('route',{summary:'UA 123 EWR → MIA'}),cal('a')),fetched(event('city',{summary:'United flight to Miami',location:'Newark EWR'}),cal('b'))]);
  assert.equal(a.length,1);assert.equal(a[0].id,'city');
});
test('native agenda parity: all-day visibility follows owned/shared calendars and synced choices',()=>{
  const all=event('trip',{summary:'Day trip',start:{date:'2026-10-05'},end:{date:'2026-10-08'}});
  assert.equal(build([fetched(all)]).length,1);
  assert.equal(build([fetched(all,cal('shared',{accessRole:'reader'}))]).length,0);
  assert.equal(build([fetched(all,cal('shared',{accessRole:'reader'}))],{v:{settings:{allDayShownCalendarIDs:['shared']}}}).length,1);
  for(const settings of [{allDayHiddenCalendarIDs:['personal']},{allDayHiddenTitles:['day trip']}])assert.equal(build([fetched(all)],{v:{settings}}).length,0);
  assert.equal(build([fetched({...all,eventType:'workingLocation'})]).length,0);
  assert.equal(build([fetched({...all,eventType:'birthday'})],{v:{settings:{showsBirthdays:false}}}).length,0);
});
test('native agenda parity: read exclusions are independent from write-back exclusions and use Google calendar identities',()=>{
  const encoded='google-calendar:'+btoa('personal');
  assert.equal(includesCalendar(cal(),'me@example.com',{v:{settings:{excludedCalendarIDs:[encoded]}}}),false);
  assert.equal(includesCalendar(cal(),'me@example.com',{v:{settings:{writeBackExcludedCalendarIDs:[encoded]}}}),true);
  assert.equal(includesCalendar(cal(),'me@example.com',{v:{excludedCalendars:[{sourceTitle:'Google · me@example.com',calendarTitle:'Personal'}]}}),false);
  assert.equal(includesCalendar(cal(),'me@example.com',{v:{excludedCalendars:[{sourceTitle:'Google · other@example.com',calendarTitle:'Personal'}]}}),true);
});
test('native Day/Week parity: Monday default, synced Sunday start, seven actual dates and next week',()=>{
  assert.equal(calendarSettings(null).weekStartWeekday,2);
  assert.deepEqual(visibleDays('2026-10-07','day'),['2026-10-07']);
  assert.deepEqual(visibleDays('2026-10-07','week'),['2026-10-05','2026-10-06','2026-10-07','2026-10-08','2026-10-09','2026-10-10','2026-10-11']);
  assert.equal(visibleDays('2026-10-07','week',1)[0],'2026-10-04');
  assert.equal(visibleDays('2026-11-01','week',1).at(-1),'2026-11-07');
});
test('Day/Week: all-day end is exclusive, multi-day spans show on each covered date, distinct overlaps get separate lanes',()=>{
  const trip={start:{date:'2026-10-05'},end:{date:'2026-10-08'}};
  assert.equal(eventOnDay(trip,'2026-10-07'),true);assert.equal(eventOnDay(trip,'2026-10-08'),false);
  const rows=layoutEvents([event('one'),event('two',{summary:'Dentist'})],'2026-10-05');
  assert.equal(rows.length,2);assert.equal(rows[0].lanes,2);assert.notEqual(rows[0].lane,rows[1].lane);
});

test('native authored occurrence parity: weekday slots, extra slots, one-off alarm dates, skipped/moved occurrences and manual cues',async()=>{
  const {authoredEvents}=await import('../public/app/assets/plan-model.js');
  const routine={id:'r',fields:{name:'Morning',enabled:true,triggerKind:'time',hour:7,minute:30,weekdays:[2],extraSlots:[{id:'later',hour:10,minute:0,weekdays:[3]}]}};
  const a=authoredEvents({routines:[routine,{id:'manual',fields:{name:'When ready',triggerKind:'manual',hour:12}}],alarms:[{id:'a',fields:{label:'One-off',fire:Date.parse('2026-10-06T11:00:00Z')}}],overrides:[{id:'r|main|2026-10-05',fields:{v:{skip:{}}}}],days:['2026-10-05','2026-10-06']});
  assert.equal(a.length,3);assert.equal(a.find(e=>e.id==='r:main:2026-10-05').skipped,true);assert.ok(a.some(e=>e.id==='r:later:2026-10-06'));assert.equal(a.filter(e=>e.calendar==='Alarm').length,1);assert.ok(!a.some(e=>e.title==='When ready'));
  const moved=authoredEvents({routines:[routine],overrides:[{id:'r|main|2026-10-05',fields:{v:{reschedule:{_0:Date.parse('2026-10-05T12:00:00Z')}}}}],days:['2026-10-05']});
  assert.equal(moved[0].start.dateTime,'2026-10-05T12:00:00.000Z');
});


test('workout routine completion stays visible at its booked time and never completes another day', async()=>{
  const {authoredEvents}=await import('../public/app/assets/plan-model.js');
  const booked=Date.parse('2026-10-05T12:00:00Z'), at=booked+300000;
  const rows=authoredEvents({routines:[{id:'workout',fields:{name:'Workout',enabled:true,triggerKind:'workoutStart',hour:7,minute:0}}],
    overrides:[{id:'workout|main|2026-10-05',fields:{v:{completed:{at,scheduledStart:booked}}}}],days:['2026-10-05','2026-10-06']});
  assert.equal(rows.length,1);assert.equal(rows[0].completed,true);assert.equal(rows[0].skipped,false);
  assert.equal(rows[0].start.dateTime,'2026-10-05T12:00:00.000Z');assert.equal(rows[0].completedAt,at);
});


test('shared calendars retain another person’s private Busy mirrors; ownership markers are not viewer ownership',()=>{
  for(const role of ['reader','writer','freeBusyReader']) for(const marker of [null,'banana','banana-beta','quarters']) {
    const e=event('private-block',{summary:'Busy',location:'Private address',description:'Private notes',hangoutLink:'https://meet.google.com/private',
      organizer:{email:'work@example.com'},attachments:[{title:'Private',fileUrl:'https://example.com/private'}],
      ...(marker?{extendedProperties:{private:{bananaVariant:marker,bananaItemID:'travel-owner-one'}}}:{})});
    const rows=calendarAgenda([fetched(e,cal('person-one@gmail.com',{accessRole:role}))],null,{details:true});
    assert.equal(rows.length,1,`${role} ${marker}`);assert.equal(rows[0].title,'Busy');assert.equal(rows[0].showsAsFree,false);
    assert.equal(rows[0].calendarID,'person-one@gmail.com');assert.equal(rows[0].location,'');assert.equal(rows[0].description,'');assert.equal(rows[0].joinURL,'');
    assert.deepEqual(rows[0].attachments,[]);assert.equal(rows[0].organizer,null);
    assert.equal(build([{event:e,calendar:cal('person-one@gmail.com',{accessRole:'owner'}),email:'person-one@gmail.com'}]).length,0,'the owner’s mirror remains hidden');
  }
});
test('shared privacy availability stays separate from unrelated simultaneous meetings and other people’s availability',()=>{
  const rows=build([fetched(event('mine',{summary:'Dentist'})),
    fetched(event('hers',{summary:'Busy'}),cal('wife',{accessRole:'reader'})),
    fetched(event('theirs',{summary:''}),cal('coach',{accessRole:'freeBusyReader'}))]);
  assert.equal(rows.length,3);assert.deepEqual(rows.filter(r=>r.title==='Busy').map(r=>r.calendarID).sort(),['coach','wife']);
});


test('shared manager access is not ownership; the data owner still keeps a clean calendar',()=>{
  const calendar=cal('secondary@group.calendar.google.com',{accessRole:'owner',dataOwner:'person-one@gmail.com'});
  const e=event('mirror',{summary:'Busy',extendedProperties:{private:{bananaVariant:'banana',bananaItemID:'work'}}});
  assert.equal(build([{event:e,calendar,email:'person-two@gmail.com'}]).length,1);
  assert.equal(build([{event:e,calendar,email:'PERSON-ONE@gmail.com'}]).length,0);
});

const ownerCal=(id,owner='owner@example.com')=>cal(id,{accessRole:'writer',dataOwner:owner});
const dinner=()=>event('dinner',{summary:'Dinner',iCalUID:'dinner-uid'});
const mirror=(id='mirror',overrides={})=>event(id,{summary:'Busy',extendedProperties:{private:{bananaVariant:'banana',bananaItemID:mirrorID('Dinner',Date.parse(event().start.dateTime),Date.parse(event().end.dateTime))}},...overrides});
test('shared mirrors join a visible source through losing invite provenance and keep all calendar indicators',()=>{
  const rows=build([fetched({...dinner(),id:'invite',location:'Restaurant'},cal('me')),fetched(dinner(),ownerCal('personal')),fetched(mirror(),ownerCal('fitness')),fetched(mirror('b'),ownerCal('work'))]);
  assert.equal(rows.length,1);assert.equal(rows[0].title,'Dinner');assert.equal(rows[0].location,'Restaurant');
  assert.deepEqual(rows[0].alsoOn.map(c=>c.calendarID).sort(),['fitness','personal','work']);
  assert.equal(Object.keys(rows[0]).some(k=>k.startsWith('_')),false);
});
test('without a visible source, proven mirrors form one private Busy that restores on hiding the source',()=>{
  const input=[fetched(dinner(),ownerCal('personal')),fetched(mirror(),ownerCal('fitness')),fetched(mirror('b'),ownerCal('work'))];
  assert.equal(build(input)[0].title,'Dinner');const rows=build(input.slice(1));
  assert.equal(rows.length,1);assert.equal(rows[0].title,'Busy');assert.equal(rows[0].location,'');assert.equal(rows[0].alsoOn.length,1);
});
test('owner mismatch, missing owner, absent metadata and non-mirror markers never consume Busy',()=>{
  for(const c of [ownerCal('fitness','another@example.com'),cal('fitness',{accessRole:'reader'})])assert.equal(build([fetched(dinner(),ownerCal('personal')),fetched(mirror(),c)]).length,2);
  for(const e of [event('busy',{summary:'Busy'}),mirror('b',{extendedProperties:{private:{bananaVariant:'banana',bananaItemID:'travel-other'}}})])assert.equal(build([fetched(dinner(),ownerCal('personal')),fetched(e,ownerCal('fitness'))]).length,2);
});
test('ambiguous sources, stale fingerprints, extended coverage and free originals stay separate',()=>{
  const original=fetched(dinner(),ownerCal('personal')),busy=fetched(mirror(),ownerCal('fitness'));
  assert.equal(build([original,busy,fetched({...dinner(),id:'different',iCalUID:'another-uid'},ownerCal('work'))]).length,3);
  assert.equal(build([fetched({...dinner(),summary:'Supper'},ownerCal('personal')),busy]).length,2);
  assert.equal(build([original,fetched(mirror('long',{end:{dateTime:'2026-10-05T17:00:00Z'}}),ownerCal('fitness'))]).length,2);
  assert.equal(build([fetched({...dinner(),transparency:'transparent'},ownerCal('personal')),busy]).length,2);
});
test('redacted attendee copies with the same instance UID use independently visible details',()=>{
  const rows=build([fetched(dinner(),cal('me')),fetched(event('redacted',{summary:'Busy',iCalUID:'dinner-uid'}),ownerCal('personal'))]);
  assert.equal(rows.length,1);assert.equal(rows[0].title,'Dinner');assert.equal(rows[0].alsoOn.length,1);
});
test('legacy native Dinner mirror fingerprint matches exactly',()=>{
  assert.equal(mirrorID('Dinner',Date.parse('2026-10-23T22:00:00Z'),Date.parse('2026-10-24T01:00:00Z')),'mirror-acf52a72cdfbcbc5');
});

test('flight route reconciliation still handles independently created Google and airline UIDs',()=>{
  const rows=build([fetched(event('airline',{summary:'UA 123 EWR → MIA',iCalUID:'airline'})),fetched(event('google',{summary:'United flight to Miami',iCalUID:'google'}),cal('work'))]);
  assert.equal(rows.length,1);
});

test('moved recurring occurrences keep originalStartTime identity even at identical displayed times',()=>{
  const instance=(id,originalStart)=>({...dinner(),id,iCalUID:'series-uid',recurringEventId:'series',originalStartTime:{dateTime:originalStart}});
  const a=fetched(instance('a','2026-10-04T15:00:00Z'),ownerCal('personal'));
  assert.equal(build([a,fetched(instance('b','2026-10-05T15:00:00Z'),ownerCal('work')),fetched(mirror(),ownerCal('fitness'))]).length,3);
  assert.equal(build([a,fetched(instance('copy','2026-10-04T11:00:00-04:00'),ownerCal('work'))]).length,1);
});
