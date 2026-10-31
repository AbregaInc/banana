import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Hono } from 'hono';
import { sourceInfo, sourceRoutes } from '../src/source-offer.js';
import { configFrom } from '../src/config.js';
import { page } from '../src/web/page.js';
import { setup } from './helpers.js';

const revision = 'a'.repeat(40);
const archive = `https://github.com/example/banana/archive/${revision}.tar.gz`;
const config = { sourceRevision: revision, sourceArchiveUrl: archive };

test('source offer requires an exact revision and an HTTPS archive for that revision', () => {
  assert.deepEqual(sourceInfo(config), { license: 'AGPL-3.0-only', revision, archive });
  for (const bad of [
    {}, { ...config, sourceRevision: 'main' }, { ...config, sourceRevision: 'a'.repeat(7) },
    { ...config, sourceArchiveUrl: 'http://example.com/archive/' + revision },
    { ...config, sourceArchiveUrl: 'https://user:pass@example.com/archive/' + revision },
    { ...config, sourceArchiveUrl: archive + '?token=private' },
    { ...config, sourceArchiveUrl: archive + '#fragment' },
    { ...config, sourceArchiveUrl: 'https://github.com/example/banana/archive/main.tar.gz' },
  ]) assert.equal(sourceInfo(bad), null);
  assert.deepEqual(sourceInfo(configFrom({ SOURCE_REVISION: revision, SOURCE_ARCHIVE_URL: archive })), sourceInfo(config));
});

test('source offer is public on service and booking hosts and contains no account data', async () => {
  const s = setup({ config: { ...config, bookUrl: 'https://book.test' } });
  for (const host of ['https://service.test', 'https://book.test']) {
    const r = await s.app.request(host + '/source');
    assert.equal(r.status, 200);
    const html = await r.text();
    assert.ok(html.includes(archive)); assert.ok(html.includes(revision));
    assert.match(r.headers.get('content-security-policy'), /frame-ancestors 'none'/);
    assert.equal(r.headers.get('cache-control'), 'no-store');
    assert.equal(r.headers.get('set-cookie'), null);
    const api = await s.app.request(host + '/v1/source');
    assert.deepEqual(await api.json(), sourceInfo(config));
  }
  assert.equal(await s.count('accounts'), 0);
  assert.match(page(), /href="\/source"[^>]*>Source code/);
});

test('missing source configuration returns unavailable rather than claiming a source offer', async () => {
  const app = new Hono(); sourceRoutes(app, {});
  const r = await app.request('/v1/source');
  assert.equal(r.status, 503);
  assert.deepEqual(await r.json(), { error: 'source_unavailable' });
  assert.equal((await app.request('/source')).status, 503);
});
