import test from 'node:test';
import assert from 'node:assert/strict';
import { feedGuide } from '../public/app/assets/feed-guide.js';
const escape = text => String(text).replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;').replaceAll("'",'&#39;');
test('feed instructions show the exact shared groups, request parameters, paging and separate credentials', () => {
  const guide = feedGuide({access:{sections:['personalPlan','workouts','health','nutrition'],calendars:{busy:0,details:0}},escape});
  for (const text of ['Routines &amp; reminders','Workouts','Health trends','Food','Calendar events are not included','signature','not the API token','Authorization: Bearer','calendarDays','rel="next"','Meal-photo','403','409','503']) assert.ok(guide.includes(text),text);
  assert.equal(guide.includes('<dt>Notes</dt>'),false);assert.equal(guide.includes('<dt>Taken</dt>'),false);
  const preview = feedGuide({access:{sections:['nutrition'],calendars:{busy:0,details:0}},url:'https://service.test/?signature=EXAMPLE&types=food.meal&format=json',preview:true,escape});
  assert.match(preview,/Example feed URLs do not grant access/);assert.match(preview,/signed-in owner session/);
  assert.equal(feedGuide({url:'https://service.test/?x=<script>',escape}).includes('<script>'),false);
});
