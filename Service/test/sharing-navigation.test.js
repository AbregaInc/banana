import test from 'node:test';
import assert from 'node:assert/strict';
import { canViewPage } from '../public/app/assets/sharing-navigation.js';

test('shared feed navigation follows published feed permission and preserves content scope', () => {
  const guest = { shared: true, views: ['overview', 'nutrition'] };
  assert.equal(canViewPage(guest, 'feeds'), false);
  assert.equal(canViewPage({ ...guest, dataFeedsAllowed: true }, 'feeds'), true);
  assert.equal(canViewPage({ ...guest, preview: true, dataFeedsAllowed: true }, 'feeds'), true);
  assert.equal(canViewPage({ ...guest, dataFeedsAllowed: false }, 'feeds'), false);
  assert.equal(canViewPage(guest, 'nutrition'), true);
  assert.equal(canViewPage(guest, 'notes'), false);
  assert.equal(canViewPage(guest, 'sharing'), false);
  assert.equal(canViewPage({ shared: false, dataFeedsAllowed: true }, 'feeds'), false);
  assert.equal(canViewPage({ shared: false }, 'sharing'), true);
});
