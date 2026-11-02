import {test} from 'node:test';
import assert from 'node:assert/strict';
import {calendarBlocksTime} from '../src/calendar-preferences.js';

test('shared visibility does not grant availability; explicit choices override ownership', () => {
  const viewer = 'noor@plan.example';
  const managed = {id:'team@group.calendar.google.com', accessRole:'owner', dataOwner:'colleague@plan.example'};
  assert.equal(calendarBlocksTime(null, managed, viewer), false);
  assert.equal(calendarBlocksTime(null, {...managed,dataOwner:viewer}, viewer), true);
  assert.equal(calendarBlocksTime(null, {id:'colleague@plan.example',accessRole:'owner'}, viewer), false);
  assert.equal(calendarBlocksTime(null, {id:viewer,accessRole:'owner'}, viewer), true);
  assert.equal(calendarBlocksTime({settings:{calendarBlockingOverrides:{[managed.id]:true}}}, managed, viewer), true);
  assert.equal(calendarBlocksTime({settings:{calendarBlockingOverrides:{[viewer]:false}}}, {id:viewer,accessRole:'owner'}, viewer), false);
});
