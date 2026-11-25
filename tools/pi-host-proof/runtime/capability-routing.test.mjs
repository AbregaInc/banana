import test from 'node:test';
import assert from 'node:assert/strict';
import {routeGeneration} from './capability-routing.js';
const tool=name=>({name,parameters:{type:'object',properties:{day:{type:'string'},time:{type:'string'}},additionalProperties:false}});
const request=(text,tools=['prepare_event','create_note','open_page'])=>({instructions:'Context',messages:[{role:'user',text}],tools:tools.map(tool)});
const response=(name,args)=>({content:[{type:'toolCall',id:'test',name,arguments:args}]});
const pick=(operation,extra={})=>response('select_capability',{requirements:[],operation,section:'plan',...extra});
test('unsupported requests never expose app tools or execute a second generation',async()=>{
 let calls=0;const out=await routeGeneration(request('Cancel tomorrow’s meeting'),async r=>{calls++;assert.deepEqual(r.tools.map(t=>t.name),['select_capability']);return pick('unavailable');});
 assert.equal(calls,1);assert.equal(out.content[0].type,'text');assert.match(out.content[0].text,/can’t/);
});
test('time-only requests remove the model date and expose only the chosen tool',async()=>{
 let calls=0;const out=await routeGeneration(request('Dinner at 5pm'),async r=>{
 if(calls++===0)return pick('prepare_event');
 assert.deepEqual(r.tools.map(t=>t.name),['prepare_event']);assert.ok(r.tools[0].parameters.required.includes('dayEvidence'));
 return response('prepare_event',{title:'Dinner',time:'17:00',day:'today',dayEvidence:''});
 });assert.equal(out.content[0].arguments.day,undefined);
});
test('explicit continuation date is preserved from user context',async()=>{
 const r=request('At 7pm');r.messages.unshift({role:'user',text:'Dinner tomorrow'},{role:'assistant',content:[{type:'text',text:'What time should it start?'}]});let calls=0;
 const out=await routeGeneration(r,async()=>calls++===0?pick('prepare_event',{dateText:'tomorrow'}):response('prepare_event',{title:'Dinner',time:'19:00',day:'tomorrow',dayEvidence:'tomorrow'}));
 assert.equal(out.content[0].arguments.day,'tomorrow');
});
test('missing clock time cannot become an event draft',async()=>{
 let calls=0;const out=await routeGeneration(request('Dinner'),async()=>calls++===0?pick('prepare_event'):response('prepare_event',{title:'Dinner',dayEvidence:''}));
 assert.equal(out.content[0].type,'text');assert.match(out.content[0].text,/time/);
});
test('wrong second-stage tool is rejected',async()=>{
 let calls=0;const out=await routeGeneration(request('Create a note: text'),async()=>calls++===0?pick('create_note',{section:'notes'}):response('prepare_event',{title:'text',time:'17:00'}));
 assert.equal(out.content[0].type,'text');
});
test('malformed or multiple classifications fail closed',async()=>{
 for(const selection of [{content:[]},{content:[...pick('create_note').content,...pick('open_page').content]},pick('nonexistent')]){
 const out=await routeGeneration(request('do it'),async()=>selection);assert.equal(out.content[0].type,'text');
 }
});
test('general conversation has no app tools',async()=>{
 let calls=0;await routeGeneration(request('Explain an agenda'),async r=>{if(calls++===0)return pick('conversation');assert.deepEqual(r.tools,[]);return {content:[{type:'text',text:'An agenda lists planned activities.'}]};});
});
test('cancellation stops before extraction',async()=>{
 const controller=new AbortController();let calls=0;
 await assert.rejects(routeGeneration(request('Dinner at 5pm'),async()=>{calls++;controller.abort();return pick('prepare_event');},controller.signal));assert.equal(calls,1);
});
test('clarification requires no second inference',async()=>{
 let calls=0;const out=await routeGeneration(request('I had some rice'),async()=>{calls++;return pick('clarify',{missing:'amount',section:'nutrition'});});
 assert.equal(calls,1);assert.match(out.content[0].text,/How much/);
});

test('unsupported requirements cannot be bypassed by selecting an event',async()=>{
 for(const requirement of ['recurrence','multiple_timezones','existing_record_change']){
 let calls=0;const out=await routeGeneration(request('a compound request'),async()=>{calls++;return pick('prepare_event',{requirements:[requirement]});});
 assert.equal(calls,1);assert.match(out.content[0].text,/can’t/);
 }
});
test('domain mismatch cannot substitute a meal or event for another module',async()=>{
 let calls=0;const out=await routeGeneration(request('complete routine'),async()=>{calls++;return pick('prepare_event',{section:'routines'});});
 assert.equal(calls,1);assert.equal(out.content[0].type,'text');
});
test('read continuations cannot acquire write tools',async()=>{
 const r=request('read');r.messages.push({role:'toolResult',toolName:'list_notes',text:'[]'});
 await routeGeneration(r,async next=>{assert.deepEqual(next.tools,[]);return {content:[{type:'text',text:'No notes found.'}]};});
});
test('conversation cannot smuggle a draft call through the provider',async()=>{
 let calls=0;const out=await routeGeneration(request('Just saying hello'),async()=>calls++===0?pick('conversation'):response('create_note',{text:'invented'}));
 assert.equal(out.content[0].type,'text');
});
test('nutrition follow-ups retain current chart data and exclude unrelated tools',async()=>{
 const r=request('Compare with the previous period',['nutrition_view','filter_nutrition','prepare_event']);
 r.instructions='<nutrition-view>Revision 2\nCurrent native nutrition view: {"surface":{"metric":"protein"}}. nutrition_view opens charts.</nutrition-view>';
 let calls=0;const out=await routeGeneration(r,async next=>{
 assert.match(next.instructions,/"metric":"protein"/);
 if(calls++===0)return pick('filter_nutrition',{section:'nutrition'});
 assert.deepEqual(next.tools.map(t=>t.name),['nutrition_view','filter_nutrition']);
 return response('filter_nutrition',{changes:['compare_previous']});
 });assert.equal(out.content[0].name,'filter_nutrition');
});
test('navigation retains the unique inference call ID',async()=>{
 const out=await routeGeneration(request('Take me where my notes are'),async()=>({content:[{...pick('open_page',{section:'notes'}).content[0],id:'unique-navigation-id'}]}));
 assert.equal(out.content[0].id,'unique-navigation-id');
});

test('invented evidence cannot introduce today or override an explicit day',async()=>{
 for(const [words,expected] of [['Dinner at 5pm',undefined],['Dinner tomorrow at 5pm','tomorrow']]){
 let calls=0;const out=await routeGeneration(request(words),async()=>calls++===0?pick('prepare_event'):response('prepare_event',{title:'Dinner',time:'17:00',dayEvidence:'today',day:'today'}));
 assert.equal(out.content[0].arguments.day,expected);
 }
});
test('an old unrelated date does not leak into a new time-only event',async()=>{
 const r=request('Dinner at 5pm');r.messages.unshift({role:'user',text:'What happened yesterday?'},{role:'assistant',content:[{type:'text',text:'No events.'}]});
 let calls=0;const out=await routeGeneration(r,async()=>calls++===0?pick('prepare_event'):response('prepare_event',{title:'Dinner',time:'17:00',dayEvidence:'yesterday',day:'yesterday'}));
 assert.equal(out.content[0].arguments.day,undefined);
});

test('missing input is not an unsupported capability',async()=>{
 const out=await routeGeneration(request('some rice'),async()=>pick('clarify',{section:'nutrition',requirements:['amount']}));
 assert.equal(out.content[0].text,'How much did you have?');
});

test('direct page commands need no inference and retain unique call IDs',async()=>{
 const never=async()=>{throw Error('Unexpected inference');};
 const a=await routeGeneration(request('Open Notes'),never),b=await routeGeneration(request('Please open the Notes page'),never);
 assert.equal(a.content[0].arguments.section,'notes');assert.notEqual(a.content[0].id,b.content[0].id);
});
test('a partial data source cannot stand in for the complete requested answer',async()=>{
 let calls=0;const out=await routeGeneration(request('Compare energy used with food eaten'),async()=>{calls++;return pick('nutrition_view',{section:'nutrition',needsUnavailableData:true});});
 assert.equal(calls,1);assert.match(out.content[0].text,/can’t read all/);
});
test('quoted data is hidden from selection but preserved for extraction',async()=>{
 let calls=0;const out=await routeGeneration(request('Create a note: "Cancel my flight"'),async next=>{
 if(calls++===0){assert.equal(next.messages[0].text,'Create a note: [quoted text]');return pick('create_note',{section:'notes'});}
 assert.equal(next.messages[0].text,'Create a note: "Cancel my flight"');return response('create_note',{text:'Cancel my flight'});
 });assert.equal(out.content[0].arguments.text,'Cancel my flight');
});
test('model prose cannot claim a native effect before its tool runs',async()=>{
 let calls=0;const out=await routeGeneration(request('Create a note: hello'),async()=>calls++===0?pick('create_note',{section:'notes'}):{content:[{type:'text',text:'Saved your note.'},...response('create_note',{text:'hello'}).content]});
 assert.deepEqual(out.content.map(p=>p.type),['toolCall']);
});
test('an omitted clarification field is repaired without exposing app capabilities',async()=>{
 let calls=0;
 const out=await routeGeneration(request('I ate rice; ask how much first',['prepare_meal']),async next=>{
  if(calls++===0)return pick('clarify',{section:'nutrition'});
  assert.deepEqual(next.tools.map(t=>t.name),['clarify_input']);
  assert.deepEqual(next.tools[0].parameters.required,['missing']);
  return response('clarify_input',{missing:'amount'});
 });assert.equal(out.content[0].text,'How much did you have?');assert.equal(calls,2);
});

test('unsupported nutrient cannot be substituted with a default protein chart', async()=>{
 for(const evidence of [undefined, 'protein', 'coline']) {
  let n=0;
  const out=await routeGeneration(request('Have I had enough coline this week?', ['nutrition_view']),async()=>n++===0
   ? pick('nutrition_view',{section:'nutrition'})
   : response('nutrition_view',{metric:'protein',period:'this_month',...(evidence===undefined?{}:{metricEvidence:evidence})}));
  assert.equal(out.content[0].type,'text');
  assert.match(out.content[0].text,/calories.*protein.*carb.*fat/i);
 }
});

test('nutrition questions read facts and continue to a written answer',async()=>{
 let n=0;
 const out=await routeGeneration(request('How much protein did I log in the last seven days?', ['nutrition_view']),async()=>n++===0
  ? pick('nutrition_view',{section:'nutrition'})
  : response('nutrition_view',{metric:'protein',period:'last_7_days',metricEvidence:'protein'}));
 assert.equal(out.content[0].name,'nutrition_view');
 assert.equal(out.content[0].arguments.responseMode,'answer');
 assert.equal(out.content[0].arguments.metricEvidence,undefined);
});

test('explicit native chart command remains a view action',async()=>{
 const out=await routeGeneration(request('Show my protein this month',['nutrition_view']),async()=>{throw Error('No model needed');});
 assert.equal(out.content[0].name,'nutrition_view');
 assert.notEqual(out.content[0].arguments.responseMode,'answer');
});


test('micronutrient requests expose only the grounded read capability', async()=>{
 let calls=0;
 const out=await routeGeneration(request('Have I had enough coline this week?', ['nutrition_view','read_nutrients']),async r=>{
  if(calls++===0)return pick('read_nutrients',{section:'nutrition',needsUnavailableData:false});
  assert.deepEqual(r.tools.map(t=>t.name),['read_nutrients']);
  return response('read_nutrients',{nutrient:'coline',period:'this_week'});
 });
 assert.equal(out.content[0].name,'read_nutrients');
 assert.equal(out.content[0].arguments.nutrient,'coline');
});
test('a model cannot replace the requested micronutrient with another one',async()=>{
 let calls=0;
 const out=await routeGeneration(request('Check my choline intake', ['read_nutrients']),async()=>calls++===0
  ? pick('read_nutrients',{section:'nutrition',needsUnavailableData:false})
  : response('read_nutrients',{nutrient:'iron'}));
 assert.equal(out.content[0].type,'text');
});
test('nutrient names require whole-word evidence rather than a substring',async()=>{
 let calls=0;
 const out=await routeGeneration(request('What about ironing?', ['read_nutrients']),async()=>calls++===0
  ? pick('read_nutrients',{section:'nutrition',needsUnavailableData:false})
  : response('read_nutrients',{nutrient:'iron'}));
 assert.equal(out.content[0].type,'text');
});

test('relative nutrient periods discard model calendar arithmetic',async()=>{
 let calls=0;
 const out=await routeGeneration(request('Check choline this week',['read_nutrients']),async()=>calls++===0
  ? pick('read_nutrients',{section:'nutrition'})
  : response('read_nutrients',{nutrient:'choline',period:'this_week',end:'1999-01-01'}));
 assert.deepEqual(out.content[0].arguments,{nutrient:'choline',period:'this_week'});
});
test('explicit nutrient dates must be supplied by the person',async()=>{
 for(const supplied of [false,true]) {
  let calls=0;
  const out=await routeGeneration(request('Check choline'+(supplied?' 2026-11-01 to 2026-11-07':''),['read_nutrients']),async()=>calls++===0
   ? pick('read_nutrients',{section:'nutrition'})
   : response('read_nutrients',{nutrient:'choline',start:'2026-11-01',end:'2026-11-07'}));
  assert.equal(out.content[0].type,supplied?'toolCall':'text');
 }
});


test('named birthdays and anniversaries are read from Calendar before inference', async () => {
  for (const [question, query] of [["What's my aunt's birthday?", 'aunt birthday'],
    ['When is Noor’s anniversary?', 'Noor anniversary'],
    ['What’s my grandmas birthday', 'grandma birthday'],
    ['When is my neighbors anniversary?', 'neighbor anniversary'],
    ['When is Carlos’s birthday?', 'Carlos birthday']]) {
    const input = request(question, ['search_app', 'nutrition_view']);
    input.tools[0].parameters.properties.section = {const: 'plan'};
    const output = await routeGeneration(input, async () => assert.fail('A named lookup needs no model selection'));
    assert.equal(output.content[0].name, 'search_app');
    assert.deepEqual(output.content[0].arguments, {query, section: 'plan'});
  }
});

test('compound, quoted, and unsupported birthday questions remain with normal routing', async () => {
  for (const [question, scopedSearch] of [['When is my aunt’s birthday and can you send an email?', true],
    ['What is “my aunt’s birthday”?', true], ['When is my aunt’s birthday?', false]]) {
    const input = request(question, scopedSearch ? ['search_app', 'nutrition_view'] : ['nutrition_view']);
    if (scopedSearch) input.tools[0].parameters.properties.section = {const: 'plan'};
    const output = await routeGeneration(input, async (selection) => {
      assert.equal(selection.tools[0].name, 'select_capability');
      return pick('unavailable');
    });
    assert.equal(output.content[0].type, 'text');
  }
});
