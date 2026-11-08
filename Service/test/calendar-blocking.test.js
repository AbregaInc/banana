import {test} from 'node:test';
import assert from 'node:assert/strict';
import {calendarBlocksTime} from '../src/calendar-preferences.js';

test('shared visibility does not grant availability; explicit choices override ownership', () => {
  const viewer = 'noor@plan.example';
  const managed = {id:'team@group.calendar.google.com', accessRole:'owner', dataOwner:'colleague@plan.example'};
  assert.equal(calendarBlocksTime(null, managed, viewer), false);
  assert.equal(calendarBlocksTime(null, {...managed,dataOwner:viewer}, viewer), true);
  assert.equal(calendarBlocksTime(null, {id:'colleague@plan.example',accessRole:'owner'}, viewer), false);
  assert.equal(calendarBlocksTime(null, {id:viewer,accessRole:'owner',primary:true}, viewer), true);
  assert.equal(calendarBlocksTime({settings:{calendarBlockingOverrides:{[managed.id]:true}}}, managed, viewer), true);
  assert.equal(calendarBlocksTime({settings:{calendarBlockingOverrides:{[viewer]:false}}}, {id:viewer,accessRole:'owner',primary:true}, viewer), false);
});

test('a calendar is the account’s own only when it is its primary or Google names the account as data owner', () => {
  const viewer = 'noor@plan.example';
  const owned = calendar => calendarBlocksTime(null, calendar, viewer);
  assert.equal(owned({id:viewer, accessRole:'owner', primary:true}), true, 'primary');
  assert.equal(owned({id:'noor-fitness@group.calendar.google.com', accessRole:'owner', dataOwner:'Noor@plan.example'}), true, 'secondary she owns');
  assert.equal(owned({id:'household@group.calendar.google.com', accessRole:'owner'}), false, 'owner role, no data owner: a group calendar');
  assert.equal(owned({id:'partner-work@group.calendar.google.com', accessRole:'owner', dataOwner:'partner@plan.example'}), false, 'shared with manage sharing');
  assert.equal(owned({id:viewer, accessRole:'owner'}), false, 'an id that looks like her address proves nothing without the primary flag');
  assert.equal(calendarBlocksTime({settings:{calendarBlockingOverrides:{'household@group.calendar.google.com':true}}}, {id:'household@group.calendar.google.com', accessRole:'owner'}, viewer), true, 'Blocks my time turns it on');
});
