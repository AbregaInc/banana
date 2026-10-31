// SPDX-License-Identifier: GPL-3.0-only
// Render the original SVG fixture sources, never a third-party podcast's cover.
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { resolve, dirname } from 'node:path';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const require = createRequire(resolve(root, 'LandingPage/package.json'));
const { chromium } = require('playwright-core');
const browser = await chromium.launch({ channel: 'chromium-headless-shell' });
try {
  const page = await browser.newPage({ viewport: { width: 600, height: 600 }, deviceScaleFactor: 1 });
  for (const name of ['acq2', 'acquired', 'complex-systems', 'gamecraft', 'get-sleepy', 'step-change']) {
    await page.goto(pathToFileURL(resolve(root, `tools/publication/fixture-artwork/${name}.svg`)).href);
    await page.screenshot({ path: resolve(root, `Banana/PreviewArtwork/${name}.jpg`), type: 'jpeg', quality: 92 });
  }
} finally { await browser.close(); }
