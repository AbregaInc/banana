import assert from 'node:assert/strict';
import test from 'node:test';
import {routeGeneration} from './capability-routing.js';

const start = '2026-11-25T12:00:00-05:00';
const end = '2026-11-25T15:00:00-08:00';
const range = start + ' to ' + end;
const names = ['read_mail_thread', 'prepare_event_from_email', 'check_calendar_interval', 'list_notes'];
const tool = name => ({name,parameters:{type:'object',properties:{},additionalProperties:false}});
const request = prompt => ({instructions:'Context',messages:[{role:'user',text:prompt}],tools:names.map(tool)});
const eventRequest = 'Use my flight confirmation email to prepare a calendar draft.';
const paraphrase = 'Put the flight from my confirmation email on my calendar as a draft.';
const conditional = 'Check if I’m free for the time proposed in the confirmation email and prepare a calendar draft if I am.';
const confirmed = 'Confirmed for ' + range + '.';

function model(query = 'flight confirmation', workflow = 'draft_event_from_mail') {
  return async input => {
    const names = input.tools.map(tool => tool.name);
    if (names.includes('select_capability')) return {content:[{type:'toolCall',id:'selection',name:'select_capability',
      arguments:{section:'mail',operation:workflow,requirements:[]}}]};
    if (names.includes('read_mail_thread')) return {content:[{type:'toolCall',id:'extraction',name:'read_mail_thread',arguments:{query}}]};
    assert.fail('Unexpected model tools: ' + names.join(', '));
  };
}

function appendResult(r, call, data, isError = false) {
  r.messages.push({role:'assistant',content:[call]},
    {role:'toolResult',toolName:call.name,toolCallId:call.id,isError,text:JSON.stringify(data)});
}

function evidence(texts, matches = ['Flight confirmation']) {
  return {matches,messages:texts.map((text,index) => ({
    text,sender:'Booking desk',sent:index ? '2026-11-21' : '2026-11-22',coverage:'cached excerpt'
  }))};
}

async function read(r, promptModel = model()) {
  const [call] = (await routeGeneration(r,promptModel)).content;
  assert.equal(call.name,'read_mail_thread');
  return call;
}

function onlyText(value) {
  assert.ok(value.content.length > 0);
  assert.ok(value.content.every(part => part.type === 'text' && part.text.trim()), 'Expected an informative stop without app actions');
}

test('a selected email-to-calendar job survives paraphrasing and supplies the exact review range', async () => {
  const r = request(paraphrase);
  const call = await read(r,model('confirmation'));
  assert.match(call.arguments.query,/confirmation/i);
  appendResult(r,call,evidence([confirmed]));
  const out = await routeGeneration(r,model());
  assert.equal(out.content.length,1);
  assert.equal(out.content[0].name,'prepare_event_from_email');
  assert.equal(out.content[0].arguments.sourceStart,start);
  assert.equal(out.content[0].arguments.sourceEnd,end);
});

for (const [label,texts] of [
  ['cancellation repeating the original range',['Your flight scheduled ' + range + ' has been cancelled.']],
  ['newer cancellation without a replacement',['This booking has been cancelled.',confirmed]],
  ['competing ranges in one excerpt',[confirmed + ' Alternate: 2026-11-26T12:00:00-05:00 to 2026-11-26T15:00:00-08:00.']],
  ['reversed interval',['Confirmed for ' + end + ' to ' + start + '.']],
  ['invalid calendar date',['Confirmed for 2026-11-31T12:00:00-05:00 to 2026-11-31T13:00:00-05:00.']],
  ['unqualified local times',['Confirmed for 2026-11-25 12:00 to 2026-11-25 15:00.']]
]) {
  test('the app withholds an email draft for ' + label, async () => {
    const r = request(eventRequest);
    appendResult(r,await read(r),evidence(texts));
    onlyText(await routeGeneration(r,model()));
  });
}

test('a newer confirmed range supersedes an older range', async () => {
  const r = request(eventRequest);
  const replacement = '2026-11-26T15:00:00-05:00';
  const replacementEnd = '2026-11-26T16:00:00-05:00';
  appendResult(r,await read(r),evidence(['Your new confirmed slot is ' + replacement + ' to ' + replacementEnd + '.',confirmed]));
  const [call] = (await routeGeneration(r,model())).content;
  assert.equal(call.name,'prepare_event_from_email');
  assert.equal(call.arguments.sourceStart,replacement);
  assert.equal(call.arguments.sourceEnd,replacementEnd);
});

for (const [label,result,isError] of [
  ['a provider reporting incomplete coverage',{answer:'Coverage incomplete.'},true],
  ['a malformed success without an availability verdict',{answer:'Coverage incomplete.'},false],
  ['a conflict',{available:false,start,end,answer:'A calendar is busy.'},false],
  ['an availability result for another date',{available:true,start,end:'2026-11-26T15:00:00-08:00',answer:'Clear.'},false]
]) {
  test('a conditional workflow stops after ' + label, async () => {
    const r = request(conditional);
    appendResult(r,await read(r,model('confirmation','draft_if_free_from_mail')),evidence([confirmed]));
    const [check] = (await routeGeneration(r,model())).content;
    assert.equal(check.name,'check_calendar_interval');
    appendResult(r,check,result,isError);
    onlyText(await routeGeneration(r,model()));
  });
}

async function ambiguousWorkflow(titles = ['Flight confirmation – outbound','Flight confirmation – return']) {
  const r = request(eventRequest);
  const first = await read(r);
  const data = {...evidence([],titles),choices:[
    {key:'first-thread',detail:'Booking desk · Nov 20'}, {key:'second-thread',detail:'Travel desk · Nov 22'}
  ]};
  appendResult(r,first,JSON.stringify(data));
  const clarification = await routeGeneration(r,model());
  onlyText(clarification);
  assert.ok(titles.every(subject => clarification.content.some(part => part.text.includes(subject))));
  r.messages.push({role:'assistant',content:clarification.content});
  return {r,first};
}

test('an ordinal resumes the original workflow even when thread subjects are identical', async () => {
  const {r,first} = await ambiguousWorkflow(['Flight confirmation','Flight confirmation']);
  r.messages.push({role:'user',text:'The second one.'});
  const resolved = await read(r);
  assert.equal(resolved.arguments.query,first.arguments.query);
  assert.equal(resolved.arguments.selectionKey,'second-thread');
  appendResult(r,resolved,JSON.stringify(evidence([confirmed])));
  const [draft] = (await routeGeneration(r,model())).content;
  assert.equal(draft.name,'prepare_event_from_email');
  assert.equal(draft.arguments.sourceStart,start);
});

test('a duplicate subject by itself cannot select one of two different matching threads', async () => {
  const {r} = await ambiguousWorkflow(['Flight confirmation','Flight confirmation']);
  r.messages.push({role:'user',text:'Flight confirmation'});
  onlyText(await routeGeneration(r,model()));
});

test('a new task supersedes an unfinished email workflow', async () => {
  const {r} = await ambiguousWorkflow();
  r.messages.push({role:'user',text:'Show my recent notes.'});
  const [next] = (await routeGeneration(r,model())).content;
  assert.equal(next.name,'list_notes');
});

test('double-encoded tool results complete only a verified free conditional draft', async () => {
  const r = request(conditional);
  appendResult(r,await read(r,model('confirmation','draft_if_free_from_mail')),JSON.stringify(evidence([confirmed])));
  const [check] = (await routeGeneration(r,model())).content;
  assert.equal(check.name,'check_calendar_interval');
  appendResult(r,check,JSON.stringify({available:true,start,end,answer:'No conflicts in included calendars.'}));
  const [draft] = (await routeGeneration(r,model())).content;
  assert.equal(draft.name,'prepare_event_from_email');
  assert.equal(draft.arguments.sourceStart,start);
  assert.equal(draft.arguments.sourceEnd,end);
});

for (const suffix of ['only if it conflicts with another event','unless I am free','if the quote is under budget',
                      'only if I’m free and the fare is under budget']) {
  test('an unsupported draft condition remains in force: ' + suffix, async () => {
    const r = request('Use the confirmation email to prepare a calendar draft ' + suffix + '.');
    const provider = model('confirmation','draft_if_free_from_mail');
    let result = await routeGeneration(r,provider);
    if (result.content[0].name === 'read_mail_thread') {
      appendResult(r,result.content[0],evidence([confirmed]));
      result = await routeGeneration(r,provider);
      if (result.content[0].name === 'check_calendar_interval') {
        appendResult(r,result.content[0],{available:true,start,end,answer:'Free.'});
        result = await routeGeneration(r,provider);
      }
    }
    onlyText(result);
  });
}

test('a conflict-free condition checks the precise interval before drafting', async () => {
  const r = request('Use the confirmation email to prepare a calendar draft only if there are no conflicts.');
  appendResult(r,await read(r,model('confirmation','draft_if_free_from_mail')),evidence([confirmed]));
  const [check] = (await routeGeneration(r,model())).content;
  assert.equal(check.name,'check_calendar_interval');
  appendResult(r,check,{available:true,start,end,answer:'Free.'});
  const [draft] = (await routeGeneration(r,model())).content;
  assert.equal(draft.name,'prepare_event_from_email');
  assert.equal(draft.arguments.sourceStart,start);
});

for (const [prompt,extracted,expected] of [
  ['Find the invoice thread even if I archived it.',{query:'invoice',period:'lastWeek',unread:false},{query:'invoice'}],
  ['Find unread invoice emails from Noor from last week.',{query:'invoice',sender:'Noor',period:'lastWeek',unread:true},
    {query:'invoice',sender:'Noor',period:'lastWeek',unread:true}]
]) {
  test('mail search enforces the filters supplied in ' + prompt, async () => {
    const r = request(prompt);
    r.tools.push(tool('search_mail'));
    const result = await routeGeneration(r,async input => {
      if (input.tools.some(candidate => candidate.name === 'select_capability'))
        return {content:[{type:'toolCall',id:'select',name:'select_capability',arguments:{operation:'search_mail',section:'mail',requirements:[]}}]};
      assert.ok(input.tools.some(candidate => candidate.name === 'search_mail'));
      return {content:[{type:'toolCall',id:'extract',name:'search_mail',arguments:extracted}]};
    });
    assert.deepEqual(result.content[0].arguments,expected);
  });
}

for (const [label,goal,question] of [
  ['draft','draft_event_from_mail',eventRequest],
  ['conditional draft','draft_if_free_from_mail',conditional]
]) {
  test('a user-supplied absolute interval can finish the pending ' + label, async () => {
    const r = request(question);
    const original = await read(r,model('confirmation',goal));
    const details = {...evidence(['The booking is confirmed. See you on Wednesday.']),
      choices:[{key:'confirmed-booking',detail:'Booking desk · Nov 22'}]};
    appendResult(r,original,details);
    const clarification = await routeGeneration(r,model());
    onlyText(clarification);
    r.messages.push({role:'assistant',content:clarification.content},{role:'user',text:range});
    const fresh = await read(r);
    assert.equal(fresh.arguments.query,original.arguments.query);
    appendResult(r,fresh,details);
    let [next] = (await routeGeneration(r,model())).content;
    if (goal === 'draft_if_free_from_mail') {
      assert.equal(next.name,'check_calendar_interval');
      assert.deepEqual(next.arguments,{start,end});
      appendResult(r,next,{start,end,available:true,answer:'No conflict.'});
      [next] = (await routeGeneration(r,model())).content;
    }
    assert.equal(next.name,'prepare_event_from_email');
    assert.equal(next.arguments.sourceStart,start);
    assert.equal(next.arguments.sourceEnd,end);
  });
}

test('a missing email subject is requested once and the reply continues the same draft', async () => {
  const r = request('Use that email to prepare a calendar draft.');
  const clarification = await routeGeneration(r,async () => ({content:[{type:'text',text:'What is the subject?'}]}));
  onlyText(clarification);
  r.messages.push({role:'assistant',content:clarification.content},{role:'user',text:'It’s about flight confirmation.'});
  const call = await read(r);
  assert.match(call.arguments.query,/flight confirmation/i);
  appendResult(r,call,evidence([confirmed]));
  assert.equal((await routeGeneration(r,model())).content[0].name,'prepare_event_from_email');
});

for (const [label,excerpt,claim,shouldDraft] of [
  ['grounded event and interval',
    'Thanks for following up. The flight is confirmed for ' + range + '.',
    {event:'flight',status:'current',sourceQuote:'The flight is confirmed for ' + range + '.'},true],
  ['a different event with an apparently valid timestamp',
    'The booking desk is scheduled for ' + range + '. Your flight details will follow.',
    {event:'flight',status:'current',sourceQuote:'The booking desk is scheduled for ' + range + '.'},false],
  ['an affirmative quotation excised from a hypothetical',
    'If approved, the flight is confirmed for ' + range + '.',
    {event:'flight',status:'current',sourceQuote:'the flight is confirmed for ' + range + '.'},false],
  ['invented supporting evidence',
    'We expect to confirm the flight for ' + range + '.',
    {event:'flight',status:'current',sourceQuote:'The flight is confirmed for ' + range + '.'},false]
]) {
  test('email interpretation verifies ' + label, async () => {
    const r = request(eventRequest);
    appendResult(r,await read(r),evidence([excerpt]));
    const out = await routeGeneration(r,async input => {
      assert.deepEqual(input.tools.map(tool => tool.name),['interpret_email_interval']);
      return {content:[{type:'toolCall',id:'review',name:'interpret_email_interval',arguments:claim}]};
    });
    if (shouldDraft) {
      assert.equal(out.content[0].name,'prepare_event_from_email');
      assert.equal(out.content[0].arguments.sourceStart,start);
      assert.equal(out.content[0].arguments.sourceEnd,end);
    } else onlyText(out);
  });
}

for (const [prompt,query,accepted] of [
  ['Look up invoices in my archived mail too','invoice',true],
  ['Find the boxes in my email','box',true],
  ['Look up invoices in my archived mail too','inv',false],
  ['Search my email for "Invoices"','invoice',false],
  ['Search my email for "Invoices"','Invoices',true],
  ['Find the boxes in my email','parcel',false]
]) {
  test('email lookup checks ' + JSON.stringify(query) + ' against ' + prompt, async () => {
    const r = request(prompt);
    r.tools.push(tool('search_mail'));
    const result = await routeGeneration(r,async input => {
      const select = input.tools.some(t => t.name === 'select_capability');
      return {content:[{type:'toolCall',id:select?'select':'extract',name:select?'select_capability':'search_mail',
        arguments:select?{section:'mail',operation:'search_mail',requirements:[]}:{query}}]};
    });
    if (accepted) {
      assert.equal(result.content[0].name,'search_mail');
      assert.equal(result.content[0].arguments.query,query);
    } else onlyText(result);
  });
}

test('an explicitly named one-off event opens review with the exact requested fields', async () => {
  for (const [prompt,args] of [
    ['Create a calendar event called Project lunch tomorrow at 13:00 for 30 minutes at Main Cafe. Prepare it for review, do not save.',
      {title:'Project lunch',day:'tomorrow',time:'13:00',durationMinutes:30,location:'Main Cafe'}],
    ['Create an event for Map review tomorrow at 16:00 for 45 minutes at West Hall.',
      {title:'Map review',day:'tomorrow',time:'16:00',durationMinutes:45,location:'West Hall'}]
  ]) {
    const r=request(prompt);r.tools.push(tool('prepare_event'));
    const out=await routeGeneration(r,async () => assert.fail('The requested draft is fully specified'));
    assert.equal(out.content.length,1);
    assert.equal(out.content[0].name,'prepare_event');
    assert.deepEqual(out.content[0].arguments,args);
  }
});

for (const prompt of ['Could you put my weekly planning time on the calendar?','I would like a note about the plan for next month.']) {
  test('a source-free request cannot select an email-derived action: ' + prompt, async () => {
    const r=request(prompt);r.tools.push(tool('prepare_event'),tool('create_note'));
    let calls=0;
    const out=await routeGeneration(r,async input => {
      calls++;
      const selector=input.tools.find(t=>t.name==='select_capability');
      assert.ok(selector);
      const operations=selector.parameters.properties.operation.enum;
      assert.ok(!operations.some(op=>op.endsWith('_from_mail')));
      return {content:[{type:'toolCall',id:'forged',name:selector.name,
        arguments:{section:'mail',operation:'draft_event_from_mail',requirements:[]}}]};
    });
    onlyText(out);
    assert.equal(calls,1);
  });
}
