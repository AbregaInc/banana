import test from 'node:test';
import assert from 'node:assert/strict';
import {clockInstructions,relativeDay} from './clock-context.js';
import {routeGeneration} from './capability-routing.js';
const tool={name:'day_plan',parameters:{type:'object',properties:{date:{type:'string'}},additionalProperties:false}};
test('an overnight continuation uses the new turn clock and keeps tomorrow relative',async()=>{
 const history=[{role:'user',text:'What is on tomorrow?'},{role:'assistant',content:[{type:'text',text:'Your agenda for 2026-11-03.'}]}];
 for(const clock of [{date:'2026-11-02',instant:'2026-11-03T04:59:00Z',timeZone:'America/New_York',utcOffsetSeconds:-18000},{date:'2026-11-03',instant:'2026-11-03T05:01:00Z',timeZone:'America/New_York',utcOffsetSeconds:-18000}]) {
  let calls=0;
  const request={instructions:clockInstructions(clock),messages:[...history,{role:'user',text:'what about tmrw'}],tools:[tool]};
  const result=await routeGeneration(request,async next=>{
   assert.ok(next.instructions.includes(JSON.stringify(clock)));
   return {content:[{type:'toolCall',id:'test',name:calls++===0?'select_capability':'day_plan',arguments:calls===1?{operation:'day_plan',section:'plan',requirements:[],needsUnavailableData:false}:{date:'2026-11-03'}}]};
  });
  assert.equal(result.content[0].arguments.date,'tomorrow');
 }
});
test('timezone changes refresh the request clock without resolving dates in JavaScript',()=>{
 const clock={date:'2026-11-04',timeZone:'Asia/Tokyo',utcOffsetSeconds:32400};
 assert.ok(clockInstructions(clock).includes('Asia/Tokyo'));
 for(const [input,expected] of [['tmrw','tomorrow'],['today','today'],['yesterday','yesterday'],['today and tomorrow',undefined],['tomorrow 2026-11-04',undefined],['Find notes containing "tomorrow"',undefined]])assert.equal(relativeDay(input),expected);
});
