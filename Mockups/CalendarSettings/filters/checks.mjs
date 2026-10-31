import assert from 'node:assert/strict';
import {parse,matches,records} from './filter-engine.js';
const checks=[['Work meetings next week, excluding declined','plan',[1,2,6]],['Not work today','plan',[5]],['Unread emails from Alex Morgan','mail',[11]],['Unarchived notes about physical therapy','notes',[21]],['Strength workouts longer than 30 minutes this week','body',[31]]];
for(const [text,scope,expected] of checks){const q=parse(text,scope);assert.equal(q.issues.length,0);assert.deepEqual(records[scope].filter(r=>matches(r,q.filters)).map(r=>r.id),expected);}
assert.equal(parse('Meetings with Alex next week','plan').issues[0].kind,'person');
assert.equal(parse('Meetings this week next week','plan').issues[0].kind,'date');
assert.equal(parse('notes about a completely unknown subject','notes').filters[0].value,'a completely unknown subject');
console.log('8 prototype parser/result checks passed');
