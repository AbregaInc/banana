import test from 'node:test';
import assert from 'node:assert/strict';
import { feedQuery } from '../src/web/feed-query.js';
import { feedLink } from '../public/app/assets/feed-link.js';
const now = Date.UTC(2026, 10, 17, 12);

test('one feed URL selects multiple types or all granted data with format and a rolling calendar window', () => {
  const base = 'https://service.test/app/feeds/example?signature=credential';
  const link = feedLink(base, { types: ['food.myFood', 'food.meal'], format: 'csv' });
  const url = new URL(link);
  assert.equal(url.pathname, '/app/feeds/example'); assert.equal(url.searchParams.get('signature'), 'credential');
  assert.equal(url.searchParams.get('format'), 'csv'); assert.equal(url.searchParams.get('types'), 'food.meal,food.myFood');
  assert.equal(url.searchParams.has('calendarDays'), false);
  assert.deepEqual(feedQuery(link, ['food.meal', 'food.myFood'], now).types, ['food.meal', 'food.myFood']);
  const all = feedLink(base);
  assert.equal(new URL(all).searchParams.get('types'), 'all');
  const parsed = feedQuery(all, ['food.meal', 'calendar'], now);
  assert.equal(parsed.from, Date.UTC(2026, 10, 17)); assert.equal(parsed.to - parsed.from, 7 * 86400000);
  assert.throws(() => feedLink(base, { types: [] }), /Select/);
});

test('query parameters cannot select an unshared type, ignore a typo, duplicate a key or create an unbounded request', () => {
  const available = ['food.meal', 'calendar'];
  for (const query of ['types=notes.voiceNote','types=food.meal,notes.voiceNote'])
    assert.throws(() => feedQuery('https://service.test/?'+query, available, now), e => e.status === 403);
  for (const query of ['type=food.meal','types=food.meal&types=calendar','types=food.meal,food.meal','format=xml','limit=0','limit=101','calendarDays=9','calendarDays=0','types=food.meal&from=1&to=2','from=1&to=99999999999999','cursor=forged'])
    assert.throws(() => feedQuery('https://service.test/?'+query, available, now));
});
