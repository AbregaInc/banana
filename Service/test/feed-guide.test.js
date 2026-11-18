import test from 'node:test';
import assert from 'node:assert/strict';
import { feedReference as feedGuide, feedGuide as recipientGuide, FEED_TYPES } from '../public/app/assets/feed-guide.js';
const escape = text => String(text).replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;').replaceAll("'",'&#39;');
test('feed instructions show the exact shared groups, request parameters, paging and separate credentials', () => {
  const guide = feedGuide({access:{sections:['personalPlan','workouts','health','nutrition'],calendars:{busy:0,details:0}},escape});
  for (const text of ['Routines &amp; reminders','Workouts','Health trends','Food','Calendar events are not included','signature','not the API token','Authorization: Bearer','calendarDays','rel="next"','Meal-photo','403','409','503']) assert.ok(guide.includes(text),text);
  assert.equal(guide.includes('<dt>Notes</dt>'),false);assert.equal(guide.includes('<dt>Taken</dt>'),false);
  const preview = feedGuide({access:{sections:['nutrition'],calendars:{busy:0,details:0}},url:'https://service.test/?signature=EXAMPLE&types=food.meal&format=json',preview:true,escape});
  assert.match(preview,/Example feed URLs do not grant access/);assert.match(preview,/signed-in owner session/);
  assert.equal(feedGuide({url:'https://service.test/?x=<script>',escape}).includes('<script>'),false);
});


test('every server-supported feed type has an explicit reference entry', async () => {
  const { SECTIONS, allowedTypes } = await import('../src/web/sharing-policy.js');
  const types = [...allowedTypes({sections: Object.fromEntries(Object.keys(SECTIONS).map(k => [k,true]))}), 'calendar'];
  assert.deepEqual(Object.keys(FEED_TYPES).sort(), types.sort());
  const guide = feedGuide({types, escape});
  for (const type of types) {
    assert.ok(guide.includes(`<td><code>${type}</code></td>`), type);
    assert.ok(FEED_TYPES[type][1].length > 10, type);
  }
});

test('valid options follow exact consent-filtered metadata rather than broader section names', () => {
  const access = {sections:['nutrition','workouts','health'],calendars:{busy:0,details:1}};
  const guide = feedGuide({access,types:['food.meal','food.myFood','calendar'],manifestURL:'https://service.test/feed?view=manifest&signature=EXAMPLE',escape});
  const table = guide.split('<h3>Valid types for this connection</h3>')[1].split('<h3>Pages and images</h3>')[0];
  for (const text of ['<td><code>food.meal</code></td>','<td><code>calendar</code></td>','food.meal,food.myFood,calendar','Copy valid types','types[].type','view=manifest&amp;signature=EXAMPLE']) assert.ok(table.includes(text),text);
  assert.equal(guide.includes('<code>health.snapshot</code>'),false);
  assert.equal(guide.includes('<code>food.mealPhoto</code>'),false);
  assert.match(guide,/case-sensitive/);
  assert.match(feedGuide({access,types:[],escape}), /No types are currently available/);
  assert.match(feedGuide({access,escape}), /Create a connection to load its complete/);
  const healthOnly = feedGuide({access:{sections:['health'],calendars:{busy:0,details:0}},types:['health.snapshot'],escape});
  assert.ok(healthOnly.includes('data.trends'));
  assert.equal(healthOnly.includes('data.workouts'),false);
});


test('recipient explanation stays short and describes one private feed without setup instructions',()=>{
 const guide=recipientGuide({access:{sections:['personalPlan','workouts','health','nutrition'],calendars:{busy:0,details:0}},escape});
 for(const text of ['app, developer or AI tool','JSON','photo links','next','null','Revoke'])assert.ok(guide.includes(text),text);
 for(const text of ['<pre','<table','HTTP','API_TOKEN','food.meal','<input','<ol'])assert.equal(guide.includes(text),false,text);
 assert.ok(guide.replace(/<[^>]*>/g,' ').trim().split(/\s+/).length<100);
});
