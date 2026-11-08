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

test('a family calendar is the family’s: it blocks time only when switched on, whoever Google calls its owner', () => {
  const viewer = 'noor@plan.example';
  const family = {id:'family00000000000000000001@group.calendar.google.com', accessRole:'owner'};
  assert.equal(calendarBlocksTime(null, family, viewer), false);
  assert.equal(calendarBlocksTime(null, {...family, dataOwner:viewer}, viewer), false);
  assert.equal(calendarBlocksTime({settings:{calendarBlockingOverrides:{[family.id]:true}}}, family, viewer), true);
  assert.equal(calendarBlocksTime(null, {id:'familyplanning@group.calendar.google.com', accessRole:'owner', dataOwner:viewer}, viewer), true,
    'only Google’s family calendar id, not any calendar whose name starts with family');
});
