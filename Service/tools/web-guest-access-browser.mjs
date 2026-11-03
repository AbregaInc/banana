// Fictional local preview only. No invitation email is sent.
import assert from 'node:assert/strict';
const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
const origin = process.env.PREVIEW_URL || 'http://localhost:18999';
const browser = await chromium.launch({ headless: true, ...(process.env.PLAYWRIGHT_CHANNEL ? { channel: process.env.PLAYWRIGHT_CHANNEL } : {}) });
try {
  const context = await browser.newContext(), page = await context.newPage(), errors = [];
  page.on('pageerror', e => errors.push(e.message));
  await page.goto(origin + '/__preview/login');
  await page.locator('a.nav-link[href="#sharing"]').click();
  await page.locator('.share-invitation').waitFor();
  assert.equal(await page.locator('.share-editor').count(), 0);
  await page.getByRole('button', { name: 'Add new guest', exact: true }).click();
  await page.getByRole('heading', { name: 'Invite a guest', exact: true }).waitFor();
  assert.equal(await page.locator('#share-email').inputValue(), '');
  await page.locator('.share-invitation').first().getByRole('link', { name: 'Edit access' }).click();
  await page.getByRole('heading', { name: 'Edit guest access' }).waitFor();
  const expiresOn = new Date(Date.now() + 30 * 86400000).toISOString().slice(0, 10);
  await page.locator('#share-expiry').fill(expiresOn);
  await page.getByRole('button', { name: 'Preview as guest' }).click();
  await page.getByText('Guest preview', { exact: true }).waitFor();
  assert.match(await page.locator('#share-banner').innerText(), /draft permissions/);
  await page.getByRole('link', { name: 'Back to invitation' }).click();
  assert.equal(await page.locator('#share-expiry').inputValue(), expiresOn);
  await page.getByRole('button', { name: 'Save access', exact: true }).click();
  await page.waitForFunction(() => [...document.querySelectorAll('.share-invitation')].some(e => e.textContent.includes('Access through')));
  await page.locator('a.nav-link[href="#sharing"]').click();
  await page.locator('.share-invitation').waitFor();
  assert.equal(await page.locator('.share-editor').count(), 0);
  await page.locator('.share-invitation').first().getByRole('link', { name: 'Preview access' }).click();
  await page.getByText('Guest preview', { exact: true }).waitFor();
  assert.match(await page.locator('#share-banner').innerText(), /currently access/);
  assert.match(page.url(), /preview=published/);
  await page.goto(origin + '/__preview/coach');
  await page.locator('#share-banner').getByText('Shared by', { exact: false }).waitFor();
  assert.match(await page.locator('#share-banner').innerText(), new RegExp(expiresOn));
  await page.goto(origin + '/__preview/login');
  await page.locator('a.nav-link[href="#sharing"]').click();
  await page.locator('.share-invitation').waitFor();
  await page.setViewportSize({ width: 390, height: 844 });
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
  // Simulate the genuine empty-list response to verify first-guest discovery.
  await page.route('**/app/api/shares', async route => {
    if (route.request().method() === 'GET') await route.fulfill({ json: { shares: [], emailEnabled: true } });
    else await route.continue();
  });
  await page.reload();
  await page.getByRole('heading', { name: 'Invite a guest', exact: true }).waitFor();
  assert.deepEqual(errors, []);
  console.log(JSON.stringify({ passed: true, checks: ['collapsed guest form', 'Add new guest', 'empty-list default form', 'expiry draft and publish', 'published access preview', 'guest expiry banner', 'mobile list'] }, null, 2));
} finally { await browser.close(); }
